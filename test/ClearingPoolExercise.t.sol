// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken, NoOpMemeToken, ReentrantMemeToken, SenderPaysFeeMemeToken} from "./helpers/MemeToken.sol";
import {
    GatedStockToken,
    NoOpStockToken,
    ReentrantStockToken,
    SenderPaysFeeStockToken,
    StockToken
} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice 一个**合约身份**的持有人。行权的两次外部调用都会把控制权交到它手上，
///         所以再入测试里的受益人必须是合约，不能是 EOA。
///
/// @dev 它继承 `ERC1155Holder` 是硬需求：权证铸给合约收款方时 ERC-1155 强制回调
///      `onERC1155Received` 并校验返回值。`exercise` 原样冒泡 revert，
///      好让注入回调的代币把失败原因记下来 —— 吞掉的话「被拒的理由是什么」就丢了。
contract ExerciseWallet is ERC1155Holder {
    function exercise(ClearingPool pool, uint256 seriesId, uint256 amount) external {
        pool.exercise(seriesId, amount, address(this));
    }
}

/// @notice **M1-5 行权路径**（issue #10）：销毁 MEME 换股票代币，原子完成。
///
/// 这条路径是整个产品的兑现动作，它同时也是唯一一处抵押品**离开池子**的地方。三件事决定了它的形状：
///
/// - **五道门，顺序固定** —— 调用方白名单 → 系列已开启 → 未结算 → 未过 deadline → 声明门；
///   🔴 声明门查的是 **`beneficiary`**，不是调用方，否则 distributor 代路径会把它整个掏空；
/// - **三步原子** —— 销毁权证 → 销毁受益人的 MEME（送往 `0xdead`）→ 股票代币直达受益人；
///   任何一步失败全部回滚，**发行方冻结时用户不会失去权证**；
/// - **销毁地址是 `0xdead` 不是 `0x0`** —— 后者在真实 `FlapTaxTokenV3` 上实测 revert。
///
/// 测试驱动的是真实的四合约（issue #5 的测试缝），替身只出现在外部依赖那一层：
/// 金库（M2 才存在）、股票代币、MEME。真实标的上的复核在 `test/fork/`。
contract ClearingPoolExerciseTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev 🔴 **字面量写死在测试里，不读 `pool.BURN_ADDRESS()`。** 拿被测对象自己的常量去验它自己，
    ///      什么也证明不了 —— 同 `ClearingPoolMinting.t.sol` 里独立算 `seriesId` 的理由。
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        meme = new MemeToken();
        expiry = uint64(block.timestamp + 7 days);

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定，见 {FactoryStub}。
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        // 受益人侧的两件准备工作，正是 §6.4 里前端要引导用户做的那两步。
        _attest(alice);
        _approveMeme(alice);
        meme.mint(alice, 1e31);
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    function _attest(address who) internal {
        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _approveMeme(address who) internal {
        vm.prank(who);
        meme.approve(address(pool), type(uint256).max);
    }

    /// @dev 开一个系列并把权证铸给 `to`。金库替身是本里程碑唯一允许的自建 mock（issue #5）。
    function _openAndMint(address to, uint256 amount) internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, to, amount);
    }

    /// @dev 期望的 MEME 销毁量，**独立算一遍**：不调合约、也不抄合约里的 `Math.mulDiv`。
    function _expectedMeme(uint256 amount, uint256 strike) internal pure returns (uint256) {
        return (amount * strike) / 1e18;
    }

    // ──────────────────────────── 成功路径 ────────────────────────────

    /// @dev 🔴 **本票的核心断言**：一次调用里三样东西同时变，且**只变这三样**。
    ///      权证从持有方消失、MEME 从受益人账上到 `0xdead`、股票代币从池子到受益人。
    function test_exercise_burnsWarrantBurnsMemeAndDeliversStock() public {
        uint256 amount = 100 ether;
        uint256 seriesId = _openAndMint(alice, amount);

        uint256 exerciseAmount = 40 ether;
        uint256 memeAmount = _expectedMeme(exerciseAmount, STRIKE);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Exercised(seriesId, alice, alice, exerciseAmount, memeAmount);
        vm.prank(alice);
        pool.exercise(seriesId, exerciseAmount, alice);

        assertEq(warrant.balanceOf(alice, seriesId), amount - exerciseAmount, unicode"权证按行权量销毁");
        assertEq(meme.balanceOf(alice), memeBefore - memeAmount, unicode"受益人付出的 MEME");
        assertEq(meme.balanceOf(DEAD), memeAmount, unicode"MEME 到了 0xdead");
        assertEq(stock.balanceOf(alice), exerciseAmount, unicode"股票代币直达受益人");
        assertEq(stock.balanceOf(address(pool)), amount - exerciseAmount, unicode"池内只少了这么多");

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.exercised, exerciseAmount, "exercised");
        assertEq(s.minted, amount, unicode"minted 不因行权而变");
        assertEq(s.deposited, amount, unicode"deposited 不因行权而变");
    }

    /// @dev 验收条款：**销毁地址是 `0xdead`，不是 `0x0`。** 已实测 `0x0` 在真实
    ///      `FlapTaxTokenV3` 上 revert（`ERC20: transfer to the zero address`），
    ///      而它没有原生 `burn()` —— 转给 `0xdead` 是唯一可用的销毁路径。
    ///
    ///      这里同时钉住对外公开的那个常量：链下与 M2 读的是它。
    function test_exercise_burnsToDeadAndNeverToTheZeroAddress() public {
        uint256 seriesId = _openAndMint(alice, 10 ether);

        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(meme.balanceOf(DEAD), _expectedMeme(10 ether, STRIKE), unicode"0xdead 收到了 MEME");
        assertEq(meme.balanceOf(address(0)), 0, unicode"零地址一枚都没有");
        assertEq(pool.BURN_ADDRESS(), DEAD, unicode"对外公开的常量就是 0xdead");
    }

    /// @dev 部分行权可以做很多次，账目一路累加；剩下的权证仍然是同质的。
    function test_exercise_accumulatesAcrossPartialExercises() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.startPrank(alice);
        pool.exercise(seriesId, 30 ether, alice);
        pool.exercise(seriesId, 20 ether, alice);
        vm.stopPrank();

        assertEq(pool.series(seriesId).exercised, 50 ether, "exercised");
        assertEq(warrant.balanceOf(alice, seriesId), 50 ether, unicode"权证余额");
        assertEq(stock.balanceOf(alice), 50 ether, unicode"两次领到的股票代币");
        assertEq(meme.balanceOf(DEAD), _expectedMeme(50 ether, STRIKE), unicode"两次烧掉的 MEME");
    }

    /// @dev 定价公式：`memeAmount = amount * strike / 1e18`，**向下取整**。
    ///      取整到 0 的那一档必须被拒 —— 否则等于白拿股票代币，见下一条测试。
    function testFuzz_exercise_memeCostIsAmountTimesStrikeOver1e18(uint128 amount, uint128 strike) public {
        amount = uint128(bound(amount, 1, 1e24));
        strike = uint128(bound(strike, 1, 1e24));

        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, strike);
        vault.depositAndMint(seriesId, alice, amount);

        uint256 expected = _expectedMeme(amount, strike);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.prank(alice);
        if (expected == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(ClearingPool.ExerciseRoundsToZeroMeme.selector, seriesId, amount, strike)
            );
            pool.exercise(seriesId, amount, alice);
            assertEq(stock.balanceOf(alice), 0, unicode"取整到 0 的行权一枚股票代币都拿不走");
            return;
        }

        pool.exercise(seriesId, amount, alice);
        assertEq(memeBefore - meme.balanceOf(alice), expected, unicode"付出的 MEME");
        assertEq(meme.balanceOf(DEAD), expected, unicode"烧掉的 MEME");
        assertEq(stock.balanceOf(alice), amount, unicode"领到的股票代币");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
    }

    /// @dev 🔴 向下取整让 `amount * strike < 1e18` 的行权**一枚 MEME 都不用烧**。
    ///      那正是 `openSeries` 里 `strike != 0` 要挡的事情的整数版本，所以这一档必须被拒。
    ///      拒绝的代价只是「换一个更大的 `amount`」——下面这两行把这条退路也钉住。
    function test_exercise_rejectsDustThatRoundsToZeroMeme() public {
        uint128 strike = 1e17; // 每 1e18 raw 股票代币烧 0.1 MEME ⟹ 少于 10 raw 单位就取整到 0
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, strike);
        vault.depositAndMint(seriesId, alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExerciseRoundsToZeroMeme.selector, seriesId, 9, strike));
        pool.exercise(seriesId, 9, alice);

        // 边界的另一侧照常工作：烧 1 wei MEME，换 10 wei 股票代币。
        vm.prank(alice);
        pool.exercise(seriesId, 10, alice);
        assertEq(meme.balanceOf(DEAD), 1, unicode"恰好烧得动的那一档");
        assertEq(stock.balanceOf(alice), 10, unicode"领到的股票代币");
    }

    /// @dev 权证**转让完全自由**（`Warrant` 的设计前提），所以行权的人不必是最初收到权证的人。
    ///      买到权证的人以**自己**为受益人行权：声明与 MEME 都查在他自己头上。
    function test_exercise_worksForWhoeverHoldsTheWarrant() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.prank(alice);
        warrant.safeTransferFrom(alice, bob, seriesId, 60 ether, "");

        _attest(bob);
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(bob);
        pool.exercise(seriesId, 60 ether, bob);

        assertEq(stock.balanceOf(bob), 60 ether, unicode"受让人领到股票代币");
        assertEq(warrant.balanceOf(bob, seriesId), 0, unicode"他的权证烧完了");
        assertEq(warrant.balanceOf(alice, seriesId), 40 ether, unicode"卖方剩下的那份没被动过");
        assertEq(pool.series(seriesId).exercised, 60 ether, "exercised");
    }

    // ─────────────────── 调用方白名单：本人，或 distributor ───────────────────

    /// @dev 验收条款：**第三方以他人为 beneficiary 调用被拒。**
    ///
    ///      🔴 这条限制是防御性的，不是形式主义：受益人给池子的 MEME 授权表达的是
    ///      「我愿意为**自己的**行权付款」，不是「谁都可以替我择时」。所以下面刻意
    ///      把每一个「其实都齐了」的条件都摆上 —— 受益人已声明、已授权、权证也在场，
    ///      挡住这一笔的只剩调用方本身。
    function test_exercise_rejectsThirdPartyCallers() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);
        _attest(carol); // 调用方自己也声明过 —— 仍然不行

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotExerciseCaller.selector, seriesId, carol, alice));
        pool.exercise(seriesId, 10 ether, alice);

        // 连金库都不行：它出的钱，但它不是受益人本人，也不是 distributor。
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotExerciseCaller.selector, seriesId, address(vault), alice)
        );
        vm.prank(address(vault));
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"两次尝试一枚权证都没动");
        assertEq(meme.balanceOf(DEAD), 0, unicode"也没烧掉任何 MEME");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }

    /// @dev 白名单的另一半：`distributor` 以受益人的名义行权。这是 `claimAndExercise`（issue #13）
    ///      在池子这一侧的样子 —— 权证从 **distributor 自己的余额**里烧，MEME 从**受益人**账上拉，
    ///      股票代币**直达受益人**。
    ///
    ///      distributor 合约本身要到 #13 才有调用池子的函数，所以这里用 `vm.prank` 顶着它的身份 ——
    ///      池子分不出这两者，而这条测试要钉的正是池子这一侧的判据。
    function test_exercise_distributorMayExerciseForTheBeneficiary() public {
        uint256 amount = 100 ether;
        uint256 seriesId = _openAndMint(address(distributor), amount);
        uint256 memeAmount = _expectedMeme(30 ether, STRIKE);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Exercised(seriesId, address(distributor), alice, 30 ether, memeAmount);
        vm.prank(address(distributor));
        pool.exercise(seriesId, 30 ether, alice);

        assertEq(warrant.balanceOf(address(distributor), seriesId), 70 ether, unicode"权证从 distributor 烧");
        assertEq(warrant.balanceOf(alice, seriesId), 0, unicode"受益人从头到尾没拿到过权证");
        assertEq(meme.balanceOf(DEAD), memeAmount, unicode"MEME 从受益人账上烧掉");
        assertEq(stock.balanceOf(alice), 30 ether, unicode"股票代币直达受益人");
    }

    // ─────────────────────────── 声明门查受益人 ───────────────────────────

    /// @dev 验收条款：**未签声明的 beneficiary 被拒。**
    function test_exercise_requiresTheBeneficiaryToHaveAttested() public {
        uint256 seriesId = _openAndMint(bob, 100 ether);
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, bob));
        pool.exercise(seriesId, 10 ether, bob);

        // 门**结构上锁不死任何人**（不变量 6③）：自己签一次就过了，不需要任何人批准。
        _attest(bob);
        vm.prank(bob);
        pool.exercise(seriesId, 10 ether, bob);
        assertEq(stock.balanceOf(bob), 10 ether, unicode"签过之后照常行权");
    }

    /// @dev 🔴 **这道门查的是 `beneficiary`，不是 `msg.sender`。** 两个方向都要钉住，
    ///      否则「查了谁」这件事只被证明了一半：
    ///
    ///      | 调用方 | 受益人 | 期望 |
    ///      |---|---|---|
    ///      | distributor（已声明） | 未声明 | **拒** —— 否则代路径会把这道门整个掏空 |
    ///      | distributor（未声明） | 已声明 | **过** —— 门不该落在代提交者头上 |
    function test_exercise_theAttestationGateFollowsTheBeneficiaryNotTheCaller() public {
        uint256 seriesId = _openAndMint(address(distributor), 100 ether);

        // ① 调用方签过、受益人没签 —— 必须拒
        _attest(address(distributor));
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(address(distributor));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, bob));
        pool.exercise(seriesId, 10 ether, bob);

        // ② 受益人签过（distributor 签没签都无所谓）—— 必须过
        vm.prank(address(distributor));
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(stock.balanceOf(alice), 10 ether, unicode"受益人已声明 ⟹ 代路径照常");
    }

    // ──────────────────────── 未结算 / 未过 deadline ────────────────────────

    /// @dev 验收条款里的第三道门。没有任何门控观测时 **`deadline` 就是 `expiry`**
    ///      （被观测到的门控如何把它后移，见 `ClearingPoolSettlement.t.sol`），
    ///      并且判据是 `block.timestamp < deadline` —— 到期那一秒**不再**可以行权。
    ///
    ///      🔴 这条边界不是风格问题：`settleExpired` 的判据是 `>= deadline`，
    ///      两者必须严格互补。差一秒就会出现一个「既不能行权、也不能结算」的窗口。
    function test_exercise_rejectsAtAndAfterTheDeadline() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        // 到期前一秒：照常
        vm.warp(expiry - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(stock.balanceOf(alice), 10 ether, unicode"到期前一秒仍可行权");

        // 到期那一秒：拒
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 10 ether, alice);

        // 之后：仍然拒
        vm.warp(uint256(expiry) + 30 days);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry) + 30 days
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(warrant.balanceOf(alice, seriesId), 90 ether, unicode"过期不销毁权证，只是用不了");
    }

    /// @dev 不变量 4①：**`settled ⟹ exercise() revert`**。
    ///
    ///      M1-6 之前这里用的是一个带 `forceSettle` 后门的子类；现在走**真实的**结算路径。
    ///      `stock` 没有发行方门控的那两个 view，所以观测落在 fail-open 那一档：先 `pokeGating`
    ///      起头，48 小时之后才可结算（边语义与理由都在 `ClearingPoolSettlement.t.sol`）。
    function test_exercise_rejectsSettledSeries() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"前置条件：真的结算了");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没动");
        assertEq(meme.balanceOf(DEAD), 0, unicode"MEME 一枚没烧");
    }

    /// @dev 🔴 未开启的系列**显式拒绝**。`expiry == 0` 那道 deadline 检查也会挡下它 ——
    ///      但那是巧合不是结构：deadline 现在是 `max(expiry, clearedAt + 48h)`，
    ///      未开启的系列读的是 `gating[address(0)]` 那份记录，一旦它上面有过 `clearedAt`，
    ///      deadline 检查反而先放行。
    ///
    ///      零地址调用方一并测掉，理由同 `depositAndMint`：`address(0)` 既是「尚未开启」的哨兵，
    ///      也是一个能出现在 `msg.sender` 位置的取值。
    function test_exercise_rejectsUnopenedSeries_includingAZeroAddressCaller() public {
        uint256 unopened = uint256(keccak256(abi.encode(address(meme), address(stock), expiry)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.exercise(unopened, 1 ether, alice);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.exercise(unopened, 1 ether, address(0));
    }

    /// @dev `amount` 是 `uint256`，而账上的 `exercised` 是 `uint128` —— 装不下的量必须被拒，
    ///      而且要**在乘法之前**被拒：先收窄，`amount × strike` 才结构上装得进 256 位。
    ///
    ///      🔴 这条同时钉住**拒绝的理由**。放在乘法后面的话，一笔 `2^128` 的行权会先算出一个
    ///      天文数字的 `memeAmount`，然后停在 MEME 的余额不足上 —— 同样是 revert，
    ///      但报错说的是「你 MEME 不够」，而真正的原因是「这个量根本记不进账」。
    function test_exercise_rejectsAmountsThatDoNotFitUint128() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        pool.exercise(seriesId, tooBig, alice);

        assertEq(pool.series(seriesId).exercised, 0, unicode"账目没被动过");
        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证也没被动过");
    }

    /// @dev 销毁不了自己没有的权证 —— 这就是「行权量不能超过未行权量」的全部实现。
    ///      池子不重复写一遍这个判据（见 `exercise` 的注释）；所以这里断言它真的由 ERC-1155 兜住。
    function test_exercise_cannotBurnMoreWarrantsThanHeld() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 100 ether, 101 ether, seriesId
            )
        );
        pool.exercise(seriesId, 101 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, unicode"账目也没被改过");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"抵押品一分没出去");
    }

    // ──────────────── 不变量 3：任一子步骤失败 ⟹ 权证与 MEME 不变 ────────────────

    /// @dev 🔴 **验收条款：发行方冻结时全部回滚，且权证不丢。** 这是产品对用户的核心承诺
    ///      （issue #5 的 User Story 2），也是不变量 3 的确定性形式。
    ///
    ///      「不丢」不止是「没被烧掉」—— 解冻之后那份权证还得真的能用。最后三行断言的是后者。
    ///      真实 GME 的门控（注册表 `isBlocked` / 双层 `paused`）在
    ///      `test/fork/RobinhoodExercise.t.sol` 上测，这里用的是本地的失败注入器。
    function test_exercise_isAtomicWhenTheIssuerFreezesTheStock() public {
        GatedStockToken gated = new GatedStockToken();
        gated.mint(address(vault), 1e24);
        vault.approve(gated, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(gated), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);

        uint256 memeBefore = meme.balanceOf(alice);
        gated.setFrozen(true);

        vm.prank(alice);
        vm.expectRevert(GatedStockToken.IssuerFrozen.selector);
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没丢");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME 一枚没烧");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead 什么也没收到");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(gated.balanceOf(address(pool)), 100 ether, unicode"抵押品还在池子里");

        // 解冻之后，那份权证还真的能用 —— 这才是「不丢」的完整含义。
        gated.setFrozen(false);
        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(gated.balanceOf(alice), 10 ether, unicode"解冻后照常行权");
    }

    /// @dev 第 2 步失败的两种真实样子：受益人没授权、受益人余额不够。
    ///      两次都必须**什么都没发生** —— 尤其是权证：它在第 1 步就已经销毁了，
    ///      靠的是整笔回滚把它带回来。
    function test_exercise_isAtomicWhenTheMemePaymentFails() public {
        uint256 seriesId = _openAndMint(bob, 100 ether);
        _attest(bob);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);

        // ① 没授权
        meme.mint(bob, 1e30);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, memeAmount)
        );
        pool.exercise(seriesId, 10 ether, bob);
        assertEq(warrant.balanceOf(bob, seriesId), 100 ether, unicode"权证没丢");

        // ② 授权了，但余额不够
        _approveMeme(bob);
        // 🔴 余额先读进局部变量：`vm.prank` 只作用于紧接着的**下一次**外部调用，
        //    写成 `meme.transfer(carol, meme.balanceOf(bob))` 的话它会被 `balanceOf` 吃掉。
        uint256 bobsMeme = meme.balanceOf(bob);
        vm.prank(bob);
        meme.transfer(carol, bobsMeme);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, memeAmount));
        pool.exercise(seriesId, 10 ether, bob);

        assertEq(warrant.balanceOf(bob, seriesId), 100 ether, unicode"权证仍然没丢");
        assertEq(stock.balanceOf(bob), 0, unicode"也没提前拿到股票代币");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }

    /// @dev ERC-20 的 `true` 只说明调用没有 revert，不说明抵押品真的离开池子。
    ///      检测发生在最后一步，因此还要证明此前的记账、权证销毁与 MEME 转账全部回滚。
    function test_exercise_revertsAtomicallyWhenStockReturnsTrueWithoutDebitingPool() public {
        NoOpStockToken noOpStock = new NoOpStockToken();
        noOpStock.mint(address(vault), 100 ether);
        vault.approve(noOpStock, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(noOpStock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = meme.balanceOf(alice);
        noOpStock.setNoOpTransfers(true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.StockTransferDebitMismatch.selector, seriesId, 10 ether, 100 ether, 100 ether
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没丢");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME 一枚没烧");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead 什么也没收到");
        assertEq(noOpStock.balanceOf(address(pool)), 100 ether, unicode"池内抵押品没动");
        assertEq(noOpStock.balanceOf(alice), 0, unicode"受益人没有凭空收到股票");
    }

    /// @dev 仅验证“余额变了”仍不够：若发送方额外付费，池子会比账上 `exercised` 多损失抵押品。
    function test_exercise_revertsAtomicallyWhenStockDebitsThePoolByMoreThanTheAmount() public {
        SenderPaysFeeStockToken senderPaysFeeStock = new SenderPaysFeeStockToken();
        senderPaysFeeStock.mint(address(vault), 100 ether);
        vault.approve(senderPaysFeeStock, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(senderPaysFeeStock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = meme.balanceOf(alice);
        senderPaysFeeStock.setSenderFeeBps(1000);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.StockTransferDebitMismatch.selector, seriesId, 10 ether, 100 ether, 89 ether
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没丢");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME 一枚没烧");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead 什么也没收到");
        assertEq(senderPaysFeeStock.balanceOf(address(pool)), 100 ether, unicode"超额扣款全部回滚");
        assertEq(senderPaysFeeStock.balanceOf(alice), 0, unicode"股票交付也被回滚");
        assertEq(senderPaysFeeStock.balanceOf(senderPaysFeeStock.TAX_SINK()), 0, unicode"额外手续费被回滚");
    }

    /// @dev `transferFrom` 返回 `true` 也可能没向受益人扣款；不能因此让用户零成本换走股票。
    function test_exercise_revertsAtomicallyWhenMemeReturnsTrueWithoutDebitingBeneficiary() public {
        NoOpMemeToken noOpMeme = new NoOpMemeToken();
        factory.bind(address(noOpMeme), address(vault));
        noOpMeme.mint(alice, 1e31);
        vm.prank(alice);
        noOpMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(noOpMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = noOpMeme.balanceOf(alice);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);
        noOpMeme.setNoOpTransfers(true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.MemeTransferDebitMismatch.selector, seriesId, memeAmount, memeBefore, memeBefore
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没丢");
        assertEq(noOpMeme.balanceOf(alice), memeBefore, unicode"受益人的 MEME 没动");
        assertEq(noOpMeme.balanceOf(DEAD), 0, unicode"0xdead 什么也没收到");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"抵押品仍在池子");
        assertEq(stock.balanceOf(alice), 0, unicode"受益人没有零成本拿走股票");
    }

    /// @dev beneficiary 必须恰好支付定价公式的结果；无限授权不能成为代币多扣款的许可。
    function test_exercise_revertsAtomicallyWhenMemeDebitsBeneficiaryByMoreThanThePrice() public {
        SenderPaysFeeMemeToken senderPaysFeeMeme = new SenderPaysFeeMemeToken();
        factory.bind(address(senderPaysFeeMeme), address(vault));
        senderPaysFeeMeme.mint(alice, 1e31);
        vm.prank(alice);
        senderPaysFeeMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(senderPaysFeeMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = senderPaysFeeMeme.balanceOf(alice);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);
        uint256 senderFee = memeAmount / 10;
        senderPaysFeeMeme.setSenderFeeBps(1000);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.MemeTransferDebitMismatch.selector,
                seriesId,
                memeAmount,
                memeBefore,
                memeBefore - memeAmount - senderFee
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(warrant.balanceOf(alice, seriesId), 100 ether, unicode"权证一枚没丢");
        assertEq(senderPaysFeeMeme.balanceOf(alice), memeBefore, unicode"超额 MEME 扣款全部回滚");
        assertEq(senderPaysFeeMeme.balanceOf(DEAD), 0, unicode"0xdead 什么也没收到");
        assertEq(senderPaysFeeMeme.balanceOf(senderPaysFeeMeme.TAX_SINK()), 0, unicode"额外手续费被回滚");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"抵押品仍在池子");
        assertEq(stock.balanceOf(alice), 0, unicode"股票交付也被回滚");
    }

    // ────────────────────────────── 再入 ──────────────────────────────

    /// @dev 🔴 行权把控制权交出去**两次**，这条测的是第 3 步（股票代币转给受益人）那一次。
    ///      受益人是合约、并且是**合法调用方**（以自己为受益人）—— 所以内层调用会通过白名单、
    ///      通过声明门、通过全部五道门。挡住它的只剩 `nonReentrant`，这正是要断言的。
    function test_exercise_isNotReentrantThroughTheStockTransfer() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        ExerciseWallet wallet = new ExerciseWallet();

        reentrant.mint(address(vault), 1e24);
        vault.approve(reentrant, type(uint256).max);
        _attest(address(wallet));
        meme.mint(address(wallet), 1e30);
        vm.prank(address(wallet));
        meme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(reentrant), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(wallet), 100 ether);

        // 存入之后才装回调：存入本身也会经过 `_update`，那一次不是本条测试的对象。
        reentrant.armReentrancy(address(wallet), abi.encodeCall(ExerciseWallet.exercise, (pool, seriesId, 10 ether)));

        wallet.exercise(pool, seriesId, 40 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"前置条件：回调真的打进来了");
        assertFalse(reentrant.reentrySucceeded(), unicode"内层行权必须被拒");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护，不是白名单或声明门"
        );

        assertEq(warrant.balanceOf(address(wallet), seriesId), 60 ether, unicode"只烧了外层那一次");
        assertEq(reentrant.balanceOf(address(wallet)), 40 ether, unicode"股票代币只出去一次");
        assertEq(meme.balanceOf(DEAD), _expectedMeme(40 ether, STRIKE), unicode"MEME 只烧了一次");
        assertEq(pool.series(seriesId).exercised, 40 ether, "exercised");
    }

    /// @dev 第 2 步（销毁受益人的 MEME）那一次交权。它比上一条更难看出来：此刻权证**已经销毁**、
    ///      股票代币**还没转出**，池子正处在整条路径上账最不平的那一瞬间。
    function test_exercise_isNotReentrantThroughTheMemeTransfer() public {
        ReentrantMemeToken reentrantMeme = new ReentrantMemeToken();
        factory.bind(address(reentrantMeme), address(vault));
        ExerciseWallet wallet = new ExerciseWallet();

        reentrantMeme.mint(address(wallet), 1e30);
        _attest(address(wallet));
        vm.prank(address(wallet));
        reentrantMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(reentrantMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(wallet), 100 ether);

        reentrantMeme.armReentrancy(
            address(wallet), abi.encodeCall(ExerciseWallet.exercise, (pool, seriesId, 10 ether))
        );

        wallet.exercise(pool, seriesId, 40 ether);

        assertGt(reentrantMeme.reentryAttempts(), 0, unicode"前置条件：回调真的打进来了");
        assertFalse(reentrantMeme.reentrySucceeded(), unicode"内层行权必须被拒");
        assertEq(
            reentrantMeme.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护"
        );

        assertEq(warrant.balanceOf(address(wallet), seriesId), 60 ether, unicode"只烧了外层那一次");
        assertEq(stock.balanceOf(address(wallet)), 40 ether, unicode"股票代币只出去一次");
        assertEq(reentrantMeme.balanceOf(DEAD), _expectedMeme(40 ether, STRIKE), unicode"MEME 只烧了一次");
        assertEq(pool.series(seriesId).exercised, 40 ether, "exercised");
    }

    // ──────────────────────── 带税 MEME：一个刻意的取舍 ────────────────────────

    /// @dev 池子**不核对** `0xdead` 的余额增量（取舍与理由只写在 `src/ClearingPool.sol` 的
    ///      `exercise` 上）。这条测试钉的是它的**可观察后果**：带税 MEME 下**行权照常成功**，
    ///      受益人被扣走完整的 `memeAmount`，而 `0xdead` 收到的少一截。
    ///      真实 Flap 实现上「实收恰好等于转出额」由 `test/fork/RobinhoodFlapBurn.t.sol` 复核。
    function test_exercise_succeedsEvenIfTheMemeTaxesTheBurnPath() public {
        meme.setTaxBps(300); // 3%，与 Flap 的默认买卖税同档
        uint256 seriesId = _openAndMint(alice, 100 ether);

        uint256 memeAmount = _expectedMeme(40 ether, STRIKE);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.prank(alice);
        pool.exercise(seriesId, 40 ether, alice);

        assertEq(memeBefore - meme.balanceOf(alice), memeAmount, unicode"受益人付出的是完整的 memeAmount");
        assertEq(meme.balanceOf(DEAD), memeAmount - (memeAmount * 300) / 10_000, unicode"0xdead 实收少一截");
        assertEq(meme.balanceOf(meme.TAX_SINK()), (memeAmount * 300) / 10_000, unicode"差额进了税收去处");
        assertEq(stock.balanceOf(alice), 40 ether, unicode"股票代币照常交付");
    }

    /// @dev 对称的另一半：**股票代币带税**时，池子被扣走完整的 `amount`，受益人到手的少一截。
    ///      这里同样不做任何倒推 —— 池子连「该到多少」都不该假设（`openSeries` 无许可，
    ///      抵押品是外面给的），而按到手量反算转出量会让每一次行权都变成一次搜索。
    ///
    ///      真实 GME 无税（`test/fork/RobinhoodExercise.t.sol` 上断言的是「实收恰好等于行权量」），
    ///      所以这条钉的是**万一不是**时的行为：账按 `amount` 记、抵押品按 `amount` 出池、
    ///      **偿付覆盖不破**，代价落在用户看到的数上。
    function test_exercise_withATaxedStockDebitsThePoolByTheFullAmount() public {
        stock.setTaxBps(300);
        uint256 seriesId = _openAndMint(alice, 1000 ether);

        uint256 minted = warrant.balanceOf(alice, seriesId);
        assertEq(minted, 970 ether, unicode"前置条件：存入侧按到账量铸造");

        vm.prank(alice);
        pool.exercise(seriesId, 100 ether, alice);

        assertEq(stock.balanceOf(address(pool)), minted - 100 ether, unicode"池子被扣走完整的 amount");
        assertEq(stock.balanceOf(alice), 97 ether, unicode"受益人到手的少一截 —— 税吃掉的那 3%");
        assertEq(pool.series(seriesId).exercised, 100 ether, unicode"账按 amount 记");
        assertLe(
            minted - pool.series(seriesId).exercised,
            stock.balanceOf(address(pool)),
            unicode"不变量 1：剩下的权证仍然被池内余额兜住"
        );
    }
}
