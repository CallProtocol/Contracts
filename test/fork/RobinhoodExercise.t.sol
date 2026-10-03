// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **真实标的上的行权全路径**（M1-5，issue #10）。
///
/// 这个文件存在的理由只有一条：`docs/spec.zh.md` §11 里那三行「发行方冻结 ⟹ 全笔回滚，权证保留」
/// 是产品对用户的核心承诺，而它**只有在真合约上才测得准** —— 拦截逻辑是编译进 `Stock` 每条转账路径的
/// 修饰器，不是一个可以用 mock 复刻的模块。
///
/// 所以这里：
///
/// | 组件 | 用什么 |
/// |---|---|
/// | 抵押品 | **真实 GME**（BeaconProxy → `Stock`） |
/// | MEME | **真实 `FlapTaxTokenV3`**（EIP-1167 → 0x7777…3333），销毁路径见 {RobinhoodFlapBurnForkTest} |
/// | 门控状态 | 只 mock **注册表的两个 view**；`Stock` 自己的修饰器、revert 数据、执行路径全是真的 |
/// | 我们的四个合约 | 真实部署 + 两处绑定（issue #5 的测试缝） |
/// | 金库 | `VaultStub` —— M2 才有真的 |
///
/// 🔴 mock 只落在**注册表的读**上。发行方真要冻结时改的正是这两个读的返回值
/// （`BLOCKER_ROLE` / `PAUSER_ROLE`，见 `research/robinhood-stock-token-permissions.md` §5），
/// 角色持有人无法枚举因而 prank 不了 —— 换句话说，mock 在这里替代的是「谁按了那个开关」，
/// 不是「按下去之后会发生什么」。
contract RobinhoodExerciseForkTest is ForkTest {
    /// @dev 与 `src/ClearingPool.sol` 的常量**独立**写死：拿被测对象自己的常量去验它自己，什么也证明不了。
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev 钉死高度上的样本 MEME 与 Flap Portal。🔴 **不在这里写地址字面量** ——
    ///      它们定义在 {ForkConfig}，这里只取别名。此前同一个样本散在四个分叉测试里各写一遍，
    ///      于是「更新了配置」与「更新了全部用到它的地方」是两件事（PR #29 复审 P2）。
    ///      样本的三条性质与「不可与 latest canary 的样本互换」见 {ForkConfig} 的注释。
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev 发行方门控命中时 `Stock` 抛出的两个错误。写在这里而不是空 `expectRevert()` ——
    ///      后者连「因为别的原因失败」都会当成通过，而这条测试的全部意义就是失败的**原因**。
    error Blocked(address account);
    error IsPaused();

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant EXERCISE = 40e18;

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal alice = makeAddr("alice");
    uint64 internal expiry;
    uint256 internal seriesId;

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);
        meme = IERC20(FLAP_MEME);

        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
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

        expiry = uint64(block.timestamp + 7 days);
        seriesId = vault.openSeries(address(meme), address(gme), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        // 受益人侧：MEME 余额（从联合曲线上转一笔）、授权、一次性声明。
        vm.prank(FLAP_PORTAL);
        meme.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _memeCost(uint256 amount) internal pure returns (uint256) {
        return (amount * STRIKE) / 1e18;
    }

    // ─────────────────── 前置条件：分叉上的两只代币都是真的 ───────────────────

    /// @dev 断言在真实合约上跑之前，先证明**跑的确实是真实合约**。
    ///      少了这一条，下面所有的绿色都可能是在一个空地址上得到的。
    function test_preconditions_bothTokensAreTheRealThing() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 地址上没有代码");
        assertEq(FLAP_MEME.code.length, 45, unicode"样本 MEME 应当是 EIP-1167 最小代理");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"抵押品真的进了池子");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"分叉高度上注册表不该是暂停的 —— 否则下面的成功路径测的不是它以为的东西"
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"池地址不该被封"
        );
    }

    // ──────────────────────── 全路径：deposit → mint → exercise ────────────────────────

    /// @notice 验收条款：**真实 GME 下的完整 `deposit → mint → exercise`。**
    ///
    /// @dev 两个「恰好等于」是这条测试的重点，它们各自防着一件事：
    ///      - `0xdead` 实收 == `memeAmount` ⟹ Flap 的销毁路径没有对我们收税（若哪天收了，
    ///        用户付了钱却没烧够，通缩承诺无声退化）；
    ///      - 受益人实收 == `amount` ⟹ GME 没有转账税，raw 记账口径成立。
    function test_fullPath_depositMintExerciseOnRealTokens() public {
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"权证按实际到账量铸出");

        uint256 memeCost = _memeCost(EXERCISE);
        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);

        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT - EXERCISE, unicode"权证按行权量销毁");
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"受益人付出的 MEME");
        assertEq(meme.balanceOf(DEAD) - deadBefore, memeCost, unicode"🔴 0xdead 实收恰好等于转出额");
        assertEq(gme.balanceOf(alice), EXERCISE, unicode"🔴 受益人实收恰好等于行权量");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT - EXERCISE, unicode"池内只少了这么多");
        assertEq(pool.series(seriesId).exercised, EXERCISE, "exercised");

        console2.log(
            string.concat(
                unicode"  行权 ",
                vm.toString(EXERCISE),
                unicode" raw GME · 烧掉 ",
                vm.toString(memeCost),
                unicode" raw MEME · 0xdead 实收 ",
                vm.toString(meme.balanceOf(DEAD) - deadBefore)
            )
        );
    }

    // ──────────────────── 发行方冻结：干净 revert，且权证不丢 ────────────────────

    /// @notice 验收条款：**模拟发行方 `pause()`，行权干净 revert 且用户权证不丢失。**
    ///
    /// @dev 这里按的是**全局**暂停（`PAUSER_ROLE`，一次冻结全链所有股票代币）——
    ///      `Stock.paused()` 返回 `$.paused || registry.paused()`，所以它是覆盖面最大的那一档。
    ///
    ///      「不丢」不止是「没被烧掉」：解除之后那份权证还得真的能用。最后两行断言的是后者 ——
    ///      这正是 R2「冻结期间自动延期」承诺的兑现形态（延期本身在 #11）。
    function test_exerciseRevertsCleanlyWhenTheIssuerPausesGlobally() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY, abi.encodeCall(IRobinhoodAccessRegistry.paused, ()), abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(IsPaused.selector);
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        // 解除之后，那份权证还真的能用。
        vm.clearMockedCalls();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);
        assertEq(gme.balanceOf(alice), EXERCISE, unicode"解除暂停后照常行权");
    }

    /// @notice 同一件事的另一档：发行方**只封池地址**（`BLOCKER_ROLE`）。
    ///
    /// @dev 池子既收不到也付不出去 —— 行权停在第 3 步。这是 §11 表格里的第一行，
    ///      也是 #11 的门控延期真正要覆盖的场景：`pokeGating` 读的就是 `isBlocked(address(this))`。
    function test_exerciseRevertsCleanlyWhenTheIssuerBlocksThePool() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (address(pool))),
            abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, address(pool)));
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        vm.clearMockedCalls();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);
        assertEq(gme.balanceOf(alice), EXERCISE, unicode"解封后照常行权");
    }

    /// @notice 🔴 发行方**只封某个持有人**（不是池子）。
    ///
    /// @dev `spec.zh.md` §11 把这一档单列出来，因为它的后果与上面两档**不同**：池子是干净的，
    ///      所以 #11 的门控观测看不到任何东西，**不会有延期**，该持有人的权证到期即作废。
    ///      这是刻意的（封一个地址不该让全系列延期），但它是**真实且不可挽回的用户损失**。
    ///
    ///      合约层唯一还站得住的承诺是：**权证仍然是他的，而且仍然卖得掉** ——
    ///      ERC-1155 的转让不触及股票代币，因此不受封禁影响。最后三行钉的就是这条自救路径，
    ///      前端必须把它指出来（§11 / §10 的前端要求）。
    function test_blockingOneHolderStopsHisExerciseButNotHisWarrant() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (alice)),
            abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, alice));
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        // 自救路径：权证照常转让 —— 它不触及股票代币，因此不受封禁影响。
        address buyer = makeAddr("buyer");
        vm.prank(alice);
        warrant.safeTransferFrom(alice, buyer, seriesId, DEPOSIT, "");
        assertEq(warrant.balanceOf(buyer, seriesId), DEPOSIT, unicode"被封的持有人仍然卖得掉权证");
        assertEq(warrant.balanceOf(alice, seriesId), 0, unicode"权证真的转出去了");
    }

    /// @dev 三条冻结测试共用的断言：**什么都没发生。**
    ///      权证、MEME、抵押品、账目 —— 一个都不能动。
    function _assertNothingMoved(uint256 memeBefore) private view {
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"权证一枚没丢");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME 一枚没烧");
        assertEq(gme.balanceOf(alice), 0, unicode"也没提前拿到股票代币");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"抵押品还在池子里");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }
}
