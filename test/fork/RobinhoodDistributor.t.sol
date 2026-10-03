// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {MerkleTree} from "../helpers/MerkleTree.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **真实标的上的领取与合并行权**（M1-8，issue #13）—— `docs/spec.zh.md` §7 的必做分叉测试之一。
///
/// 本地那份（`test/MerkleDistributor.t.sol`）已经把标志位的四个方向、root 冻结、许可级别
/// 都钉过一遍了，所以这里只做**替身证明不了的那一件事**：
///
/// > `claimAndExercise` 烧掉的是**全体未领取用户的共享余额**，而它同时动着两只**真实**代币。
///
/// 本地那两只是我们自己写的 —— 它们当然会老老实实地按参数转账，因为我们没写别的代码。
/// 在真实 GME（BeaconProxy → `Stock`，带发行方修饰器）与真实 `FlapTaxTokenV3` 上断言
///
/// - 「重放必被拒」，以及
/// - 🔴 「托管的权证余额**永不低于**全部未领取 leaf 之和」，
/// - 并且最后让一个**从未领取过**的持有人真的把她那一份兑出来 ——
///
/// 才是那条防线的实证形式。issue #13 描述的攻击后果是「那些人握着有效 proof，却已无货可兑」；
/// 这里证明的正是它的反面。
///
/// | 组件 | 用什么 |
/// |---|---|
/// | 抵押品 | **真实 GME** |
/// | MEME | **真实 `FlapTaxTokenV3`**（EIP-1167 → 0x7777…3333） |
/// | 我们的四个合约 | 真实部署 + 两处绑定（issue #5 的测试缝） |
/// | 金库 | `VaultStub` —— M2 才有真的 |
/// | merkle 树 | 测试侧独立构造（`test/helpers/MerkleTree.sol`），M4 的 Indexer 才是链下那一份 |
contract RobinhoodDistributorForkTest is ForkTest {
    /// @dev 与 `src/ClearingPool.sol` 的常量**独立**写死：拿被测对象自己的常量去验它自己，什么也证明不了。
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev 钉死高度上的样本 MEME 与 Flap Portal。🔴 **不在这里写地址字面量** ——
    ///      它们定义在 {ForkConfig}，这里只取别名。此前同一个样本散在四个分叉测试里各写一遍，
    ///      于是「更新了配置」与「更新了全部用到它的地方」是两件事（PR #29 复审 P2）。
    ///      样本的三条性质与「不可与 latest canary 的样本互换」见 {ForkConfig} 的注释。
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;

    /// @dev 整周铸给 distributor 的量 —— 恰好等于三张 leaf 之和。多铸一点会让托管断言变得不敏感。
    uint256 internal constant MINTED = 100e18;

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal publisher = makeAddr("publisher");
    address internal keeper = makeAddr("keeper");

    /// @dev 三个持有人：alice 走合并路径，bob 走领取路径，**carol 从头到尾不领** ——
    ///      她就是那个「握着有效 proof」的人，最后一条测试要让她真的兑出来。
    address[3] internal accounts;
    uint256[3] internal amounts;

    /// @dev 测试自己维护的「哪张 leaf 已经被消费掉了」。不读合约的 `claimed` —— 那会让
    ///      「余额 ≥ 未领取之和」用被测对象自己的记账来定义「未领取」。
    bool[3] internal consumed;

    uint64 internal expiry;
    uint256 internal seriesId;

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);
        meme = IERC20(FLAP_MEME);

        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(publisher);
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        // 身份根里登记这只真实 MEME 的金库 —— 开系列那道门认的就是这条绑定（M2-5 / #37）。
        //    真实绑定由 `WarrantVaultFactory` 在 Flap 建币的同一笔交易里写下，见
        //    `test/fork/RobinhoodWarrantVaultFactory.t.sol`；这里的标的是一只**早就发射过**的代币，
        //    没有那一刻可回放，所以用替身工厂补一条同形的绑定。
        factory.bind(address(meme), address(vault));

        deal(address(gme), address(vault), 1000e18);
        vault.approve(gme, type(uint256).max);

        accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        amounts = [uint256(50e18), 30e18, 20e18];

        expiry = uint64(block.timestamp + 7 days);
        seriesId = vault.openSeries(address(meme), address(gme), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), MINTED);

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.prank(FLAP_PORTAL);
            meme.transfer(accounts[i], 1_000_000e18);
            vm.prank(accounts[i]);
            meme.approve(address(pool), type(uint256).max);
        }
        // 🔴 carol **不签声明** —— 声明门那条测试要用她，而她的 leaf 也因此一直留在共享余额里。
        _attest(accounts[0]);
        _attest(accounts[1]);

        vm.prank(publisher);
        distributor.setRoot(seriesId, MerkleTree.root(_leaves()));
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    function _attest(address who) internal {
        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _leaves() internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            leaves[i] = MerkleTree.leafOf(seriesId, accounts[i], amounts[i]);
        }
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory) {
        return MerkleTree.proofFor(_leaves(), i);
    }

    function _memeCost(uint256 amount) internal pure returns (uint256) {
        return (amount * STRIKE) / 1e18;
    }

    function _unclaimed() internal view returns (uint256 total) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!consumed[i]) total += amounts[i];
        }
    }

    /// @dev 🔴 **本票的核心断言**，在真实 GME / 真实 MEME 之上：托管的权证永远兜得住
    ///      所有还没被领走的 leaf。每一次状态变化之后都要成立。
    function _assertCustodyCoversUnclaimed() internal view {
        assertGe(
            warrant.balanceOf(address(distributor), seriesId),
            _unclaimed(),
            unicode"🔴 distributor 的权证余额低于未领取 leaf 之和 —— 有人从共享余额里拿走了别人的份额"
        );
    }

    // ─────────────────── 前置条件：分叉上的两只代币都是真的 ───────────────────

    /// @dev 断言在真实合约上跑之前，先证明**跑的确实是真实合约**。
    ///      少了这一条，下面所有的绿色都可能是在一个空地址上得到的。
    function test_preconditions_bothTokensAreTheRealThing() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 地址上没有代码");
        assertEq(FLAP_MEME.code.length, 45, unicode"样本 MEME 应当是 EIP-1167 最小代理");
        assertEq(gme.balanceOf(address(pool)), MINTED, unicode"抵押品真的进了池子");
        assertEq(
            warrant.balanceOf(address(distributor), seriesId), MINTED, unicode"整周的权证在 distributor 手上"
        );
        assertEq(_unclaimed(), MINTED, unicode"三张 leaf 之和恰好等于铸造量");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"分叉高度上注册表不该是暂停的 —— 否则下面的成功路径测的不是它以为的东西"
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"池地址不该被封"
        );
    }

    // ──────────────────── 全路径：approve + claimAndExercise，两笔 ────────────────────

    /// @notice 验收条款：**用户路径为两笔（approve + claimAndExercise）**，在真实标的上跑通。
    ///
    /// @dev 两个「恰好等于」是这条测试的重点，它们各自防着一件事：
    ///      - `0xdead` 实收 == `memeAmount` ⟹ Flap 的销毁路径没有对我们收税；
    ///      - 受益人实收 == `amount` ⟹ GME 没有转账税，raw 记账口径成立。
    ///
    ///      再加一条只有这条路径才有的：**权证从头到尾没经过受益人的手** ——
    ///      它是从 distributor 的共享余额里直接销毁的。
    function test_fullPath_claimAndExerciseOnRealTokens() public {
        address alice = accounts[0];
        uint256 amount = amounts[0];
        uint256 memeCost = _memeCost(amount);
        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        // 第 1 笔在 setUp 里：alice 把 MEME 授权给**清算池**（不是 distributor）。
        // 第 2 笔：
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amount, _proof(0));
        consumed[0] = true;

        assertEq(warrant.balanceOf(alice, seriesId), 0, unicode"权证从头到尾没经过受益人的手");
        assertEq(warrant.balanceOf(address(distributor), seriesId), MINTED - amount, unicode"从共享余额里销毁");
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"受益人付出的 MEME");
        assertEq(meme.balanceOf(DEAD) - deadBefore, memeCost, unicode"🔴 0xdead 实收恰好等于转出额");
        assertEq(gme.balanceOf(alice), amount, unicode"🔴 受益人实收恰好等于行权量");
        assertEq(gme.balanceOf(address(pool)), MINTED - amount, unicode"池内只少了这么多");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
        _assertCustodyCoversUnclaimed();

        console2.log(
            string.concat(
                unicode"  合并行权 ",
                vm.toString(amount),
                unicode" raw GME · 烧掉 ",
                vm.toString(memeCost),
                unicode" raw MEME · 0xdead 实收 ",
                vm.toString(meme.balanceOf(DEAD) - deadBefore)
            )
        );
    }

    // ──────── 🔴 重放：两个方向都必须被拒，而未领取者的货必须还在 ────────

    /// @notice 验收条款三条并在一起，全部跑在真实标的上：
    ///         **同一 proof 第二次提交必 revert**；**`claim` 之后 `claimAndExercise` 必 revert，反向亦然**；
    ///         **distributor 的权证余额永不低于全部未领取 leaf 之和**。
    ///
    /// @dev 最后那几行才是这条测试真正的结论：carol 从头到尾没有做过任何事，
    ///      而在 alice 与 bob 各自反复尝试之后，她那 20 枚 GME **一枚不少**地还在，
    ///      并且她真的能把它兑出来。issue #13 描述的后果是「握着有效 proof 却已无货可兑」——
    ///      这里断言的是它的反面。
    function test_replaysAreRejectedOnBothPathsAndTheUnclaimedHoldersGoodsSurvive() public {
        address alice = accounts[0];
        address bob = accounts[1];
        address carol = accounts[2];

        _assertCustodyCoversUnclaimed();

        // ① alice 走合并路径
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));
        consumed[0] = true;
        _assertCustodyCoversUnclaimed();

        // ② 同一 proof 再提交一次 —— 必拒
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, alice));
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));
        _assertCustodyCoversUnclaimed();

        // ③ 换一条路径再来 —— 同样必拒（🔴 这个方向就是那个攻击：权证已经烧过了，
        //    再 claim 一次转出去的就是别人的那一份）
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, alice));
        vm.prank(keeper);
        distributor.claim(seriesId, alice, amounts[0], _proof(0));
        _assertCustodyCoversUnclaimed();

        // ④ bob 走领取路径（keeper 代提交，权证只进 bob）
        vm.prank(keeper);
        distributor.claim(seriesId, bob, amounts[1], _proof(1));
        consumed[1] = true;
        assertEq(warrant.balanceOf(bob, seriesId), amounts[1], unicode"权证进了 leaf 指定的账户");
        assertEq(warrant.balanceOf(keeper, seriesId), 0, unicode"代提交者一枚都拿不到");
        _assertCustodyCoversUnclaimed();

        // ⑤ 反向重放：领过之后再合并行权 —— 必拒
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, bob));
        vm.prank(bob);
        distributor.claimAndExercise(seriesId, bob, amounts[1], _proof(1));
        _assertCustodyCoversUnclaimed();

        // ⑥ 🔴 结论：carol 什么都没做，而她那一份一枚不少地还在，并且真的兑得出来。
        assertEq(
            warrant.balanceOf(address(distributor), seriesId),
            amounts[2],
            unicode"🔴 共享余额里剩下的恰好是 carol 的那一份"
        );

        _attest(carol);
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));
        consumed[2] = true;

        assertEq(gme.balanceOf(carol), amounts[2], unicode"🔴 从未领取的持有人一枚不少地兑到了货");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 0, unicode"整周的权证正好分完");
        assertEq(_unclaimed(), 0, unicode"没有未领取的 leaf 了");
        assertEq(gme.balanceOf(address(pool)), amounts[1], unicode"池内剩下的正好是 bob 还没行权的那份");
    }

    // ─────────────────── 声明门查受益人，不查调用方 ───────────────────

    /// @notice 验收条款：**未签声明的 `account` 在 distributor 路径下同样被拒。**
    ///
    /// @dev 🔴 这是「声明门查受益人」在代行权路径上的可观察后果。查调用方的话，distributor
    ///      本身签一次，全体用户就都过门了 —— 而它是我们对外承诺「合规不是伪装的冻结开关」时
    ///      唯一拿得出的东西。门**结构上锁不死任何人**（不变量 6③）：carol 自己签一次就过了。
    function test_theAttestationGateFollowsTheAccountThroughTheDistributorPath() public {
        address carol = accounts[2];

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, carol));
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));

        // 整笔回滚 ⟹ 她的 leaf 没有被那次失败吃掉
        assertFalse(distributor.claimed(seriesId, carol), unicode"被拒的那一笔没有消费她的 leaf");
        _assertCustodyCoversUnclaimed();

        _attest(carol);
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));
        consumed[2] = true;

        assertEq(gme.balanceOf(carol), amounts[2], unicode"签过之后照常");
        _assertCustodyCoversUnclaimed();
    }

    // ───────────────── 合并行权只有本人可调 ─────────────────

    /// @notice 验收条款：**非 `account` 本人调用 `claimAndExercise` 被拒。**
    ///
    /// @dev 每一个「其实都齐了」的条件都摆上：alice 已声明、已把 MEME 授权给池子、proof 也是真的。
    ///      挡住这一笔的只剩调用方本身 —— 授权额度表达的是「我愿意为自己的行权付款」，
    ///      不是「谁都可以替我择时」。
    function test_onlyTheAccountMayCombineClaimAndExercise() public {
        address alice = accounts[0];
        uint256 memeBefore = meme.balanceOf(alice);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, keeper, alice));
        vm.prank(keeper);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        assertEq(meme.balanceOf(alice), memeBefore, unicode"一枚真实 MEME 都没被别人替她烧掉");
        assertEq(gme.balanceOf(alice), 0, unicode"也没有被强制换成股票代币");
        assertFalse(distributor.claimed(seriesId, alice), unicode"leaf 没有被消费");
        _assertCustodyCoversUnclaimed();

        // 代提交**领取**仍然是允许的：它只是把本来就属于她的权证送到她手上。
        vm.prank(keeper);
        distributor.claim(seriesId, alice, amounts[0], _proof(0));
        consumed[0] = true;
        assertEq(warrant.balanceOf(alice, seriesId), amounts[0], unicode"代提交的领取照常");
        _assertCustodyCoversUnclaimed();
    }

    // ───────────── 超发的 root 会当场停住，而不是悄悄挪用别人的份额 ─────────────

    /// @notice 🔴 归属 root 是链下算的，而池子只铸出**实际到账**的抵押品那么多权证。
    ///         两者对不上（root 的总额超过铸造量）时，超出的那部分必须**当场停在 ERC-1155 的余额检查上**，
    ///         而不是先到先得地把别人的份额发掉。
    ///
    /// @dev 这条不是 issue #13 的验收条款，但它是同一条防线的另一面：托管余额兜不住 root 时，
    ///      合约的答复是「转不动」，不是「先来的多拿」。它也说明为什么那条断言写成 `≥` 而不是 `==`。
    function test_anOversizedRootStopsAtTheCustodyBoundary() public {
        uint256 fresh = vault.openSeries(address(meme), address(gme), expiry + 1 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), 10e18);

        address greedy = makeAddr("greedy");
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, greedy, 11e18); // 比铸出来的还多 1 枚
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(distributor), 10e18, 11e18, fresh
            )
        );
        vm.prank(keeper);
        distributor.claim(fresh, greedy, 11e18, MerkleTree.proofFor(leaves, 0));

        // 本周那三张 leaf 一枚都没被动过
        assertEq(warrant.balanceOf(address(distributor), seriesId), MINTED, unicode"别的系列没被殃及");
        _assertCustodyCoversUnclaimed();
    }
}
