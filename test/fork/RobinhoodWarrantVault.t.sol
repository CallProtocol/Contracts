// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {WarrantVault} from "../../src/WarrantVault.sol";
import {VaultBase} from "../../src/flap/VaultBase.sol";
import {WarrantVaultHarness} from "../helpers/WarrantVaultHarness.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {CollateralCheck} from "../invariant/Invariant1And2MintingPath.t.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev 把 {VaultBase} 里两个 internal 的地址查询暴露出来，好在**真实链上**验它们。
///      金库自己不暴露 `_getPortal()`（没有哪个用户需要它），所以这个探针只活在测试里。
contract VaultBaseProbe is VaultBase {
    function description() public pure override returns (string memory) {
        return "probe";
    }

    function portal() external view returns (address) {
        return _getPortal();
    }

    function guardian() external view returns (address) {
        return _getGuardian();
    }
}

/// @notice **真实 GME 上的金库**：骨架与协议 ping（M2-1，issue #33）+ 收入路径（M2-3，issue #35）。
///
/// 本地那份（`test/WarrantVault.t.sol`）已经把记账语义、写入面与 schema 钉过一遍了，
/// 所以这里只做**替身证明不了的那几件事**：
///
/// 1. 🔴 **「ERC20 转账不给收款方执行机会」是关于真实 `Stock` 的一句话。** 本地替身是我们自己写的
///    ERC-20，它当然不会回调我们 —— 因为我们没写那行代码。真实 GME 是 BeaconProxy → `Stock`，
///    带着发行方的修饰器与它自己的记账；在**它**身上断言「转完账金库仍然一无所知，
///    直到协议补上那记 ping」，才是余额差记账模型的实证形式。
/// 2. 🔴 **`receive()` 的 gas 是花在真实代币上的。** 规范 rule 005 的 100 万 gas 预算，
///    要拿 BeaconProxy → `Stock` 的 `balanceOf`（一次 delegatecall + 它自己的存储读）去量，
///    不是拿一个 20 行的替身去量。
/// 3. 🔴 **上游基类写死的 Portal 与 Guardian 地址，在这条链上真的是那两个地址。**
///    `src/flap/` 是逐字节副本，而副本可能抄自一份**过时**的上游（已经踩到过一次：规范自检
///    工具自带的 `references/prelude/VaultBase.sol` 至今不认识 chainId 4663，见 `src/flap/README.md`）。
///    只有在 4663 上真的调一次、并与我们一手核验的地址对一遍，才排除得掉这类错误。
/// 4. 🔴 **M1 的不变量 1 / 2 此前只在一个 `VaultStub` 下验证过。** 那个替身是我们自己写的，
///    它当然会老老实实地按请求量授权与转账。M2-3 第一次让**真金库**站在存入这一侧，
///    于是那两条不变量第一次跑在完整系统上 —— 判据复用同一份 {CollateralCheck}，
///    不另写一遍（另写一遍等于让这里去验证另一份代码）。
/// 5. 🔴 **发行方随时可以停掉这条路。** 暂停 / 封禁池地址期间存入必须**干净失败**：
///    钱一个 wei 不少地留在金库、授权不留残余、解除之后重跑一次就好。
///    这件事只有真实 `Stock` 的修饰器答得了 —— 本地替身里的「冻结」是我们自己写的注入器。
///
/// | 组件 | 用什么 |
/// |---|---|
/// | 收入币种 / 抵押品 | **真实 GME** |
/// | 服务的 MEME | 钉死高度上的**真实 `FlapTaxTokenV3`** 样本（只作为地址记录，本文件不碰它） |
/// | 金库 | 真实 `WarrantVault`，按 beacon 代理部署（与 M2-5 的工厂同形） |
/// | 池子 / 权证 / 分发 / 注册表 | 真实部署 + 两处绑定（issue #5 的测试缝） |
/// | 开系列 | {WarrantVaultHarness} 的任意参数入口 —— 本文件测的是收入路径，不该先花 24 小时铺满 TWAP 环。真实 `openSeries()` 的分叉验收在 `RobinhoodOpenSeries.t.sol` |
contract RobinhoodWarrantVaultForkTest is ForkTest {
    /// @dev 🔴 **独立写死**，不从被测合约读。出处见 `docs/research/flap-indexvault-mechanism.md`。
    address internal constant FLAP_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// @dev 模拟 keeper 的 dispatch 预算，取值与本地那份一致。
    uint256 internal constant PING_GAS = 500_000;

    /// @dev 发行方门控命中时真实 `Stock` 抛出的两个错误。写在这里而不是空 `expectRevert()` ——
    ///      后者连「因为别的原因失败」都会当成通过。与 `RobinhoodGating.t.sol` 同一份声明。
    error Blocked(address account);
    error IsPaused();

    uint128 internal constant STRIKE = 1850e18;

    IERC20 internal gme;
    WarrantVault internal vault;

    /// @dev 真实的四合约。M2-3 的存入路径要跨过金库与池子的边界，替身在这里没有立足点。
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    /// @dev 与 {vault} 同形，但多一个任意参数的 `harnessOpenSeries` —— 存入路径需要一个已开的系列。
    WarrantVaultHarness internal seriesVault;

    address internal holder = makeAddr("holder");
    address internal anyone = makeAddr("anyone");

    /// @dev 决策 49：金库的第六个构造参数 —— 发射者，分成的唯一收款人。
    address internal creator = makeAddr("creator");

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        // 🔴 决策 39-A3：金库不可升级，工厂**直接部署**它 —— 没有 beacon、没有代理、没有
        //    `initialize`。六个参数在构造那一笔里定死（决策 49 起含 creator），
        //    其中取价 Portal 是本链真实的 Flap `Portal`。
        vault = new WarrantVault(
            pool,
            address(distributor),
            ForkConfig.FLAP_PORTAL,
            ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            ForkConfig.GME,
            creator,
            false,
            address(0xfee)
        );

        seriesVault = new WarrantVaultHarness(
            pool,
            address(distributor),
            ForkConfig.FLAP_PORTAL,
            ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            ForkConfig.GME,
            creator,
            false
        );
        factory.bind(ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE, address(seriesVault));
    }

    /// @dev Flap 的唤醒调用：零值、空 calldata、限额 gas。
    function _ping() internal returns (bool ok, uint256 gasUsed) {
        uint256 before = gasleft();
        (ok,) = address(vault).call{value: 0, gas: PING_GAS}("");
        gasUsed = before - gasleft();
    }

    /// @dev 把真实 GME 送进 {seriesVault}，走的是「转账 + 协议 ping」这条真实路径，不是直接 `deal`。
    function _fundSeriesVault(uint256 amount) internal returns (uint256 delivered) {
        deal(ForkConfig.GME, holder, amount);
        vm.prank(holder);
        gme.transfer(address(seriesVault), amount);

        (bool ok,) = address(seriesVault).call{value: 0, gas: PING_GAS}("");
        assertTrue(ok, unicode"ping 应当成功");
        delivered = gme.balanceOf(address(seriesVault));
    }

    /// @dev 不变量 1①② 的判据 —— 复用 `test/invariant/` 那一份，不在这里另写。
    function _assertPoolIsCollateralised(uint256 seriesId) internal view {
        address[] memory stocks = new address[](1);
        stocks[0] = ForkConfig.GME;
        uint256[] memory ids = new uint256[](1);
        ids[0] = seriesId;

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, stocks, ids);
        assertEq(
            perSeries,
            0,
            unicode"🔴 不变量 1①：真实金库下某个未结算系列的 minted 超过了它的抵押品"
        );
        assertEq(global, 0, unicode"🔴 不变量 1②：真实金库下池内 GME 余额兜不住全部债权");
    }

    function _mockGlobalPause(bool paused) internal {
        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.paused, ()),
            abi.encode(paused)
        );
    }

    function _mockPoolBlocked(bool blocked) internal {
        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (address(pool))),
            abi.encode(blocked)
        );
    }

    // ──────── 取价 Portal 从「查表」搬到「构造参数」时，值没有变 ────────

    /// @notice 🔴 **决策 39-A2 的搬迁核对：新的那个参数，与旧的那张表在这条链上给出同一个地址。**
    ///
    /// @dev 金库从前用 `VaultBase._getPortal()` 按 `chainId` 查表拿 Portal；现在它是构造参数。
    ///      搬迁最容易出的错不是「代码写错」，而是**搬的时候抄错了那个地址** ——
    ///      而抄错的后果是采不到价、于是永远开不出系列。
    ///
    ///      所以这里在 4663 上让三方对账：上游那张表（`src/flap/VaultBase.sol`，已不再被继承，
    ///      只作存档）、我们自己一手核验的 {ForkConfig.FLAP_PORTAL}、以及**这只金库真正带着的**
    ///      那个地址。三者相等，搬迁才算没走样。
    ///
    ///      ⚠️ Guardian 那一半随决策 39-A3 一并消失：金库不再有 `guardian()`，
    ///      Flap Guardian 对它没有任何权限。存档里那张表还在，但已经没有消费者。
    function test_thePortalTheVaultCarriesEqualsWhatTheVendoredTableSays() public {
        assertEq(block.chainid, ForkConfig.ROBINHOOD_CHAIN_ID, unicode"这条测试只在 Robinhood Chain 上有意义");

        VaultBaseProbe probe = new VaultBaseProbe();

        assertEq(
            probe.portal(),
            ForkConfig.FLAP_PORTAL,
            unicode"上游基类写死的 Portal 与我们一手核验的对不上"
        );
        assertGt(ForkConfig.FLAP_PORTAL.code.length, 0, unicode"Portal 地址上没有代码");
        assertEq(vault.portal(), probe.portal(), unicode"🔴 金库带着的 Portal 就是那张表给出的那一个");

        console2.log(
            string.concat(
                "  Portal ",
                vm.toString(ForkConfig.FLAP_PORTAL),
                unicode" · code=",
                vm.toString(ForkConfig.FLAP_PORTAL.code.length),
                " bytes"
            )
        );
    }

    function test_vaultQuoteTokenIsTheRealGme() public view {
        assertEq(vault.vaultQuoteToken(), ForkConfig.GME, unicode"收入币种应当是真实 GME");
        assertEq(vault.taxToken(), ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE, unicode"服务的 MEME");
        assertEq(vault.accountedQuote(), 0, unicode"刚部署的金库没有任何已识别收入");
    }

    // ──────────────── 余额差记账：真实 GME 上的转账 → ping → 幂等 ────────────────

    /// @notice 🔴 验收条款那条：协议 ping 能唤醒金库并正确记账；重复 ping 幂等。
    function test_transferAloneIsSilent_thenPingRecognizes_andRepeatedPingsAreIdempotent() public {
        uint256 amount = 25e18;
        deal(ForkConfig.GME, holder, amount);

        vm.prank(holder);
        gme.transfer(address(vault), amount);

        uint256 delivered = gme.balanceOf(address(vault));
        assertGt(delivered, 0, unicode"真实 GME 应当到账");
        assertEq(vault.accountedQuote(), 0, unicode"🔴 转账没有给金库任何执行机会");
        assertEq(vault.lastRevenueAt(), 0, unicode"也没有留下处理时刻");

        (bool ok, uint256 gasUsed) = _ping();
        assertTrue(ok, unicode"ping 应当在限额 gas 内成功");
        assertEq(vault.accountedQuote(), delivered, unicode"按真实到账余额差记账");
        assertEq(vault.lastRevenueAt(), uint64(block.timestamp), unicode"记下处理时刻");

        // 🔴 rule 005：真实 GME 是 BeaconProxy → Stock，这一读比替身贵得多，但离预算还很远。
        //    实测约 4.8 万（含冷读账户 + 两次 SSTORE）；10 万这条线留了一倍余量，
        //    发行方换实现把 `balanceOf` 变重时会先在这里红灯。
        assertLt(gasUsed, 1_000_000, unicode"规范 rule 005 的硬上限");
        assertLt(gasUsed, 100_000, unicode"真实 GME 上的实际开销应当远小于上限");
        console2.log(string.concat(unicode"  首次 ping（含冷读 + 两次 SSTORE）gas=", vm.toString(gasUsed)));

        uint64 firstAt = vault.lastRevenueAt();
        vm.warp(block.timestamp + 1 days);

        (bool again, uint256 idempotentGas) = _ping();
        assertTrue(again);
        vm.prank(anyone);
        (bool third,) = _ping();
        assertTrue(third);

        assertEq(vault.accountedQuote(), delivered, unicode"🔴 重复 ping 幂等：零差额什么都不识别");
        assertEq(vault.lastRevenueAt(), firstAt, unicode"零差额也不动处理时刻");
        console2.log(string.concat(unicode"  幂等 ping（零差额）gas=", vm.toString(idempotentGas)));
    }

    function test_syncPicksUpRevenueThatArrivedWithoutAWake() public {
        deal(ForkConfig.GME, holder, 9e18);
        vm.prank(holder);
        gme.transfer(address(vault), 9e18);

        vm.prank(anyone); // 无许可
        vault.sync();

        assertEq(vault.accountedQuote(), gme.balanceOf(address(vault)), unicode"sync() 补记未被唤醒的到账");
    }

    /// @notice 🔴 金库不持有任何调用方可提取的债权 —— 在真实 GME 上的形式：六个无许可 ABI 入口谁都能调，
    ///         而没有一条路能把 GME 交到调用方手上，也从不授权任何人来拉它的货。
    ///
    /// @dev 📝 决策 39-A3 之后这里少了一次「第二次 initialize 必须失败」的探底 ——
    ///      那个入口整个不存在了（不可升级 ⟹ 没有代理 ⟹ 没有初始化那一拍）。
    ///      「它确实不存在」由 `test/WarrantVault.t.sol` 的写入面枚举与 ABI 探测钉住。
    ///
    /// @dev 这只金库没有开过系列，所以 `processRevenue()` 走的是**延后**那条边：
    ///      它不 revert、也不搬钱。唯一的出口通向池子这件事，由
    ///      {test_processRevenue_realGmeEndToEnd_andInvariants1And2StillHold} 正面钉住。
    function test_noEntryMovesTheRealGmeOut() public {
        deal(ForkConfig.GME, holder, 12e18);
        vm.prank(holder);
        gme.transfer(address(vault), 12e18);
        (bool ok,) = _ping();
        assertTrue(ok);

        uint256 held = gme.balanceOf(address(vault));

        vm.startPrank(anyone);
        vault.sync();
        vault.sampleTwap(); // 取价失败也只返回 false；无论哪条分支都不能搬走 GME。
        (bool pinged,) = address(vault).call{value: 0, gas: PING_GAS}("");
        assertTrue(pinged);
        assertEq(vault.processRevenue(), 0, unicode"没有已开系列 ⟹ 延后，不搬钱也不 revert");
        assertEq(vault.claimCreatorFee(), 0, unicode"零累计 ⟹ 第六个入口也是静默 no-op，不搬钱");
        vm.stopPrank();

        assertEq(gme.balanceOf(address(vault)), held, unicode"没有一个入口能让真实 GME 离开金库");
        assertEq(gme.balanceOf(anyone), 0, unicode"调用方一个 wei 都拿不到");
        assertEq(gme.allowance(address(vault), anyone), 0, unicode"金库从不授权任何人");
        assertEq(gme.allowance(address(vault), address(pool)), 0, unicode"对池子也没有常驻授权");
        assertEq(gme.allowance(address(vault), ForkConfig.FLAP_PORTAL), 0, unicode"对 Portal 也没有授权");
    }

    // ──────── 收入路径：真实 GME 上的 processRevenue → depositAndMint → 铸造 ────────

    /// @notice 🔴 **验收条款：真实 GME 上跑通 `processRevenue → depositAndMint → 铸造`，
    ///         并断言 M1 的不变量 1 / 2 在真实金库下仍然成立。**
    ///
    /// @dev 不变量 1 / 2 此前只在 `VaultStub` 下验证过 —— 那是我们自己写的替身，它当然会
    ///      老老实实地授权与转账。这里第一次让**真金库**（余额差记账、恰好授权、全额存入）
    ///      站在存入这一侧，而抵押品是真实 GME（BeaconProxy → `Stock`，带发行方修饰器）。
    ///
    ///      不变量 2 的两半在这里都要成立：`minted` 增量 == 池内 GME 余额增量，
    ///      而铸出的权证数 == `minted` 增量。判据 1①② 复用 {CollateralCheck}。
    function test_processRevenue_realGmeEndToEnd_andInvariants1And2StillHold() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);

        uint256 delivered = _fundSeriesVault(25e18);
        assertGt(delivered, 0, unicode"真实 GME 应当到账");
        assertEq(seriesVault.accountedQuote(), delivered, unicode"前置条件：ping 已经认过这笔钱");

        uint256 poolBefore = gme.balanceOf(address(pool));
        uint256 mintedBefore = pool.series(seriesId).minted;
        uint256 warrantsBefore = warrant.balanceOf(address(distributor), seriesId);

        // 🔴 时间必须往前走一格，否则「记下处理时刻」那条断言会被 `_fundSeriesVault` 里那记 ping
        //    提前满足 —— 它已经把 lastRevenueAt 写成了当前区块时刻。
        uint64 stampedByPing = seriesVault.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(anyone); // 🔴 permissionless：任何人都能把在途窗口关上
        uint256 minted = seriesVault.processRevenue();

        uint256 balanceDelta = gme.balanceOf(address(pool)) - poolBefore;
        uint256 mintedDelta = pool.series(seriesId).minted - mintedBefore;

        uint256 protocolCut = delivered / 10;
        uint256 cut = (delivered - protocolCut) / 9;
        assertEq(
            minted,
            delivered - protocolCut - cut,
            unicode"真实 GME 当前零税 ⟹ 可存量的九成就是铸造量（决策 49）"
        );
        assertEq(mintedDelta, balanceDelta, unicode"🔴 不变量 2：minted 增量 == 池内 GME 余额增量");
        assertEq(
            warrant.balanceOf(address(distributor), seriesId) - warrantsBefore,
            mintedDelta,
            unicode"🔴 不变量 2：铸出的权证数 == minted 增量"
        );
        _assertPoolIsCollateralised(seriesId);

        // 🔴 R4 的那句话在这里变成两个读数：金库里只剩 creator 浮存，「在途」归零。
        assertEq(gme.balanceOf(address(seriesVault)), cut + protocolCut, unicode"🔴 金库里只剩 creator 浮存");
        assertEq(seriesVault.creatorAccrued(), cut, unicode"分成入账 10%");
        assertEq(
            seriesVault.accountedQuote(),
            cut + protocolCut,
            unicode"🔴 基线落到真实剩余余额（规范 rule 010-3）"
        );
        assertEq(gme.allowance(address(seriesVault), address(pool)), 0, unicode"授权不留残余");
        assertEq(seriesVault.lastRevenueAt(), uint64(block.timestamp), unicode"记下处理时刻");
        assertGt(
            seriesVault.lastRevenueAt(), stampedByPing, unicode"而且这个时刻确实是被本次存入推动的"
        );

        (uint256 held, bool exact) = seriesVault.inTransit();
        assertEq(held, 0, unicode"🔴 R4 的实时读数：真实 GME 上在途也归零（浮存已净掉）");
        assertTrue(exact, unicode"真实 GME 的余额读得出来");

        // creator 在真实 GME 上也领得到 —— 任何人可触发，钱只到 creator。
        vm.prank(anyone);
        assertEq(seriesVault.claimCreatorFee(), cut, unicode"🔴 分成按实测扣款领取");
        assertEq(gme.balanceOf(creator), cut, unicode"钱只到 creator");
        assertEq(gme.balanceOf(anyone), 0, unicode"触发人一个 wei 都拿不到");
        assertEq(seriesVault.accountedQuote(), protocolCut, unicode"领取后基线同笔落到真实余额");

        // 而且金库没有因为两次支出而死锁：下一笔真实 GME 照样认得到、存得进。
        uint256 more = _fundSeriesVault(4e18);
        assertEq(seriesVault.accountedQuote(), more + protocolCut, unicode"🔴 基线没被卡住");
        assertEq(
            seriesVault.processRevenue(),
            more - more / 10 - (more - more / 10) / 9,
            unicode"🔴 第二天照样存得进去（九成）"
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @notice 🔴 **验收条款：发行方全局暂停期间调用 —— 干净失败、钱不丢、解除后可重试。**
    ///
    /// @dev 按的是**全局**暂停（`PAUSER_ROLE`，一次冻结全链所有股票代币）——
    ///      `Stock.paused()` 返回 `$.paused || registry.paused()`，覆盖面最大的那一档。
    ///      这里要证的不是「它会失败」，而是失败之后**什么都没坏**：余额、基线、授权三样全部原样，
    ///      于是解除之后重跑一次就恢复了。**只有延迟，没有损失。**
    function test_processRevenue_failsCleanlyWhilePausedThenSucceedsAfterRelease() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);
        uint256 delivered = _fundSeriesVault(18e18);

        _mockGlobalPause(true);

        vm.prank(anyone);
        vm.expectRevert(IsPaused.selector);
        seriesVault.processRevenue();

        // 🔴 干净失败：整笔回滚，三样读数一个都没动。
        assertEq(gme.balanceOf(address(seriesVault)), delivered, unicode"钱一个 wei 不少地留在金库");
        assertEq(
            seriesVault.accountedQuote(),
            delivered,
            unicode"基线没动 —— 它仍然是「已识别、尚未支出」"
        );
        assertEq(gme.allowance(address(seriesVault), address(pool)), 0, unicode"失败的那笔没留下残余授权");
        assertEq(pool.series(seriesId).minted, 0, unicode"池子那边什么都没发生");

        // 解除之后重跑一次即可 —— 不需要任何管理员动作，也不需要谁记得先做什么。
        vm.clearMockedCalls();
        vm.prank(anyone);
        assertEq(
            seriesVault.processRevenue(),
            delivered - delivered / 10 - (delivered - delivered / 10) / 9,
            unicode"解除后重试必须成功（九成入池）"
        );
        assertEq(
            seriesVault.accountedQuote(),
            delivered / 10 + (delivered - delivered / 10) / 9,
            unicode"基线落到 creator 浮存"
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @notice 🔴 **验收条款：池地址被封期间调用 —— 同样干净失败、钱不丢、解除后可重试。**
    ///
    /// @dev 与上一条是两个**不同的开关**（`PAUSER_ROLE` 的全局暂停 vs. 注册表里的单地址黑名单），
    ///      两者都编译进了 `Stock` 的每条转账路径。分开测，是因为将来只坏一个的时候，
    ///      要看得出坏的是哪一个。
    function test_processRevenue_failsCleanlyWhileThePoolIsBlockedThenSucceedsAfterRelease() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);
        uint256 delivered = _fundSeriesVault(11e18);

        _mockPoolBlocked(true);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, address(pool)));
        seriesVault.processRevenue();

        assertEq(gme.balanceOf(address(seriesVault)), delivered, unicode"钱一个 wei 不少地留在金库");
        assertEq(seriesVault.accountedQuote(), delivered, unicode"基线没动");
        assertEq(gme.allowance(address(seriesVault), address(pool)), 0, unicode"失败的那笔没留下残余授权");

        vm.clearMockedCalls();
        vm.prank(anyone);
        assertEq(
            seriesVault.processRevenue(),
            delivered - delivered / 10 - (delivered - delivered / 10) / 9,
            unicode"解封后重试必须成功（九成入池）"
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @dev `description()` 在真实数字上也渲染得出来 —— 前端把它当状态横幅轮询。
    function test_descriptionRendersOnRealNumbers() public {
        string memory before = vault.description();

        deal(ForkConfig.GME, holder, 3e18);
        vm.prank(holder);
        gme.transfer(address(vault), 3e18);
        (bool ok,) = _ping();
        assertTrue(ok);

        string memory after_ = vault.description();
        assertTrue(
            keccak256(bytes(before)) != keccak256(bytes(after_)),
            unicode"识别到收入之后，description() 应当变了"
        );
        console2.log(string.concat("  description(): ", after_));
    }
}
