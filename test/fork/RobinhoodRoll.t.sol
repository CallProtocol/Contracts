// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **真实标的上的滚存全路径**（M1-7，issue #12）—— `docs/spec.zh.md` §7 的必做分叉测试之一。
///
/// 本地那份（`test/ClearingPoolRoll.t.sol`）已经把六道门和守恒断言都钉过一遍了，所以这里只做
/// **替身证明不了的那一件事**：
///
/// > 「滚存不构成转出」是关于**真实 GME 余额**的一句话，不是关于我们那只替身的。
///
/// 替身是我们自己写的 ERC-20 —— 它当然不会在滚存里动余额，因为我们没写那行代码。真实 GME 是
/// BeaconProxy → `Stock`，带着发行方的修饰器与它自己的记账；在**它**身上断言「这笔交易前后
/// `balanceOf(pool)` 一个 wei 都没动、而且没有一条 `Transfer`」，才是这句承诺的实证形式。
///
/// 顺带在真标的上跑完这条链：`deposit → exercise → settle → roll → 后继系列上行权`，
/// 于是滚过去的那 60 枚 GME 最终真的到了持有人手上。
contract RobinhoodRollForkTest is ForkTest {
    /// @dev 钉死高度上的样本 MEME 与 Flap Portal。🔴 **不在这里写地址字面量** ——
    ///      它们定义在 {ForkConfig}，这里只取别名。此前同一个样本散在四个分叉测试里各写一遍，
    ///      于是「更新了配置」与「更新了全部用到它的地方」是两件事（PR #29 复审 P2）。
    ///      样本的三条性质与「不可与 latest canary 的样本互换」见 {ForkConfig} 的注释。
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev ERC-20 `Transfer(address,address,uint256)` 的 topic0。**字面量算一遍，不从 GME 身上读** ——
    ///      要证明「这里没有转账」，就不能拿被观察对象来定义什么叫转账。
    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant EXERCISE = 40e18;
    uint128 internal constant REMAINDER = uint128(DEPOSIT - EXERCISE);

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint64 internal expiry;
    uint64 internal nextExpiry;
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
        nextExpiry = uint64(block.timestamp + 14 days);
        seriesId = vault.openSeries(address(meme), address(gme), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.prank(FLAP_PORTAL);
        meme.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev 行权一部分、到期、结算 —— 留下一个 `remainder == 60` 的前序系列。
    function _exerciseAndSettle() internal {
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);

        vm.warp(expiry);
        vm.prank(keeper);
        pool.settleExpired(seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"前置条件：余量是 60");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"前置条件：真实 GME 也确实剩 60");
    }

    function _sawGmeTransfer(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(gme)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER_TOPIC) return true;
        }
        return false;
    }

    // ─────────────────── 前置条件：跑的确实是真实合约 ───────────────────

    /// @dev 少了这一条，下面所有的绿色都可能是在一个空地址上得到的。
    function test_preconditions_theCollateralIsTheRealGme() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 地址上没有代码");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"抵押品真的进了池子");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"分叉高度上注册表不该是暂停的 —— 否则结算根本推进不了"
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"池地址不该被封"
        );
    }

    // ──────────────── 全路径：settle → roll → 后继系列上行权 ────────────────

    /// @notice 验收条款：**滚存前后真实 GME 余额不变，且不变量 1 / 7 成立。**
    ///
    /// @dev 三个面一起断言，理由见合约注释：余额（不动）、事件（没有 `Transfer`）、账（四个数相等）。
    ///      最后再把滚过去的那 60 枚真的兑给持有人 —— 否则「滚存成功」只证明了几个计数器对得上。
    function test_fullPath_settleThenRollThenExerciseTheSuccessor() public {
        _exerciseAndSettle();

        uint256 nextSeriesId = vault.openSeries(address(meme), address(gme), nextExpiry, STRIKE);
        uint256 poolBalanceBefore = gme.balanceOf(address(pool));

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Rolled(seriesId, nextSeriesId, REMAINDER);
        vm.prank(keeper); // 无许可 —— keeper 与这个系列毫无关系
        pool.rollExpired(seriesId, nextSeriesId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // ① 真实 GME 的余额一个 wei 都没动
        assertEq(gme.balanceOf(address(pool)), poolBalanceBefore, unicode"🔴 抵押品离开过池子");
        // ② 这笔交易里没有一条 GME 的 Transfer —— **找不到才是对的**
        assertFalse(_sawGmeTransfer(logs), unicode"🔴 滚存里出现了一次真实 GME 转账");
        // ③ 不变量 7 的四个数
        assertEq(pool.series(seriesId).remainder, 0, unicode"前序余量归零");
        assertEq(pool.series(nextSeriesId).deposited, REMAINDER, unicode"后继 deposited");
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, unicode"后继 minted");
        assertEq(warrant.balanceOf(address(distributor), nextSeriesId), REMAINDER, unicode"新铸权证量");

        // 不变量 1②：同一只股票代币下，未结算债权 + 待滚存余量 ≤ 池内余额。
        // 🔴 前序（已结算）**不计入**，正因如此它才成立 —— 那 60 枚已经交给后继了。
        uint256 claim = uint256(pool.series(nextSeriesId).minted - pool.series(nextSeriesId).exercised)
            + pool.series(seriesId).remainder;
        assertLe(claim, gme.balanceOf(address(pool)), unicode"不变量 1②：池内 GME 兜得住全部债权");

        // 滚过去的那 60 枚真的能兑现：distributor 以自己的身份替 alice 行权（#13 的形状）。
        vm.prank(address(distributor));
        pool.exercise(nextSeriesId, REMAINDER, alice);

        assertEq(gme.balanceOf(alice), EXERCISE + REMAINDER, unicode"🔴 持有人最终一枚不少地拿到了 100");
        assertEq(gme.balanceOf(address(pool)), 0, unicode"池子清空");

        console2.log(
            string.concat(
                unicode"  滚存 ",
                vm.toString(uint256(REMAINDER)),
                unicode" raw GME · 池内余额前后 ",
                vm.toString(poolBalanceBefore),
                unicode" → ",
                vm.toString(poolBalanceBefore)
            )
        );
    }

    /// @notice 验收条款：**无后继系列时干净 revert，开出新系列后可恢复 —— 只有延迟，没有损失。**
    ///
    /// @dev 在真标的上跑一遍的意义是：停摆期间那 60 枚 GME 既没有人能取走，也没有因为
    ///      任何外部合约的行为而变少。无 admin 的池子对「项目停摆」唯一诚实的答复就是这个。
    function test_rollRevertsCleanlyWithoutASuccessorAndRecoversLater() public {
        _exerciseAndSettle();

        uint256 unopened = pool.seriesIdOf(address(meme), address(gme), nextExpiry);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.rollExpired(seriesId, unopened);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"余量原封不动");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"真实 GME 也原封不动");

        // 停摆三周之后才有人开出新系列。
        vm.warp(block.timestamp + 21 days);
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"整段停摆期间余额都没变过");

        uint256 late = vault.openSeries(address(meme), address(gme), uint64(block.timestamp + 7 days), STRIKE);
        vm.recordLogs();
        pool.rollExpired(seriesId, late);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(pool.series(late).minted, REMAINDER, unicode"一枚不少地滚了过去");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"滚存本身仍然没动余额");
        assertFalse(_sawGmeTransfer(logs), unicode"🔴 恢复滚存里出现了一次真实 GME 转账");
    }
}
