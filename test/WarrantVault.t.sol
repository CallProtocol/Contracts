// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {WarrantVault} from "../src/WarrantVault.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {HostileQuoteToken} from "./helpers/HostileQuoteToken.sol";
import {
    DirtyBoolApprovalStockToken,
    GatedApprovalStockToken,
    GatedStockToken,
    IssuerBurnableUnreadableStockToken,
    NoOpStockToken,
    PartialDebitStockToken,
    PreUpdateReentrantStockToken,
    SenderPaysFeeStockToken,
    SilentApprovalFailureStockToken,
    SlowBalanceStockToken,
    StockToken
} from "./helpers/StockToken.sol";
import {WarrantVaultHarness} from "./helpers/WarrantVaultHarness.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";
import {WNativeMock} from "./helpers/WNativeMock.sol";

/// @notice `WarrantVault` 的对外行为：骨架（M2-1，issue #33）+ TWAP（M2-2，issue #34）+
///         收入路径（M2-3，issue #35）。
///
/// 这份测试有四个重心，它们对应三张票验收条款里的那几条 🔴：
///
/// 1. **余额差记账**：ERC20 转账不给收款方执行机会，Flap 补的那记 ping 才是唤醒；
///    重复 ping 幂等；而且 `receive()` **任何路径都不 revert** —— 后者用
///    {HostileQuoteToken} 的四种失败模式驱动，老实替身证明不了它。
/// 2. **收入路径**：读**实际余额**（不是记账值）、按池内实测增量铸造、两条干净返回边
///    （零余额 / 没有活着的系列；币种读不出来如实失败），以及 🔴 规范 rule 010-3 ——
///    支出必须同笔清掉基线，否则金库永久死锁。最后这条用 {PreUpdateReentrantStockToken}
///    从**最坏的顺序**上打一遍：转账还没生效就回调进来调 `sync()`。
/// 3. **TWAP 入口**：价格采样无许可，但严格受最小间隔和 24 小时窗口约束；具体时间序列在
///    `WarrantVaultTwap.t.sol`，这里覆盖它与其余写入口的整合。
/// 4. **写入面枚举**：对外可写入口恰好六个、没有一个是权限函数、也没有一条能把货交到**调用方**手上
///    （决策 49 的 `claimCreatorFee` 只通向构造期定死的 creator）。
///    这几句话都是「某个东西**不存在**」，只有把编译产物的 ABI 整个枚举一遍才是非循环的证法
///    （手法与不变量 5 / 6 共用，见 {WriteSurface}）。
///
/// 🔴 **M2-6③（issue #58）之后金库不可升级、不继承任何 Flap 基类**：没有 beacon、没有代理、
///    没有 `initialize` —— 六个构造参数（决策 49 起含 creator）在 `CREATE` 那一笔里全部定死。
///    所以下面每一处「建一只金库」都是一行 `new WarrantVault(..., address(0xfee))`，
///    而不再是「实现 + beacon + 代理 + initData」那四件套。
///
/// 🔴 池子、权证、分发合约、注册表**都是真的**（issue #5 的测试缝）：存入路径跨过金库与池子的
/// 边界，而「铸造量以池内实测余额增量为准」这句话只有真池子说得出来。
///
/// 真实标的上的那一份在 `test/fork/RobinhoodWarrantVault.t.sol`：本地替身是我们自己写的，
/// 它当然会老老实实地回答 `balanceOf`、也当然不会被发行方暂停。
contract WarrantVaultTest is Test {
    string internal constant ARTIFACT = "out/WarrantVault.sol/WarrantVault.json";

    /// @dev 模拟 keeper 的 dispatch 预算：协议不给 ping 封顶（EIP-150 转发调用方余量），
    ///      但它的 keeper 用一个固定预算跑完**整条** dispatch。用一个偏紧的数去 ping，
    ///      证明的是「金库不会把 keeper 饿死」。
    uint256 internal constant PING_GAS = 500_000;

    /// @dev 本周行权价的样本值：每 1e18 raw 股票代币需销毁 1850e18 raw MEME。口径同
    ///      `ClearingPool.Series.strike`，取值本身不承重。
    uint128 internal constant STRIKE = 1850e18;

    WarrantVault internal vault;
    StockToken internal stock;

    /// @dev 🔴 **真实的四合约，不是替身**（issue #5 的测试缝）：M2-3 的存入路径要跨过金库与池子的边界，
    ///      而「铸造量以池内实测余额增量为准」这句话只有真池子说得出来。
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    /// @dev 🔴 取价 Portal 现在是**构造参数**（决策 39-A2），不再是基类按 `chainId` 查出来的字面量 ——
    ///      于是本地测试直接部署一个替身、把它的地址传进去就行了，不必再 `etch` 到一个写死的地址上，
    ///      也不必再把整份测试假装成在 chainId 4663 上跑。**这就是那条改动买到的东西。**
    FlapPortalStub internal portal;

    address internal meme = makeAddr("meme");
    address internal alice = makeAddr("alice");

    /// @dev 决策 49：金库的第六个构造参数 —— 发射者，分成的唯一收款人。
    address internal creator = makeAddr("creator");

    function setUp() public {
        portal = new FlapPortalStub();

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        stock = new StockToken();
        vault = _deployVault(meme, address(stock));
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev 与工厂将要做的事同形：**一行 `new`**，六个参数在构造那一笔里全部定死
    ///      （决策 39-A3；从前是 beacon + 代理 + `initialize` 三件套）。
    ///      池子与分发合约仍是金库的 `immutable` —— 那是决策 33「工厂不得把 `vaultData` 与
    ///      `creator` 当作特权来源」的落地形式，只是它们现在由工厂在部署那一笔里填。
    ///      决策 49 起 creator 也是构造 `immutable`（分成收款人），判据不变：它仍不是特权来源。
    function _deployVault(address taxToken, address quoteToken) internal returns (WarrantVault) {
        return new WarrantVault(
            pool, address(distributor), address(portal), taxToken, quoteToken, creator, false, address(0xfee)
        );
    }

    /// @dev 一只**已经开好本周系列**的金库。这里刻意走 {WarrantVaultHarness} 的任意参数入口，
    ///      而不是真实的 `openSeries()`：本文件测的是收入路径与对外声明面，不该先花 24 小时把
    ///      TWAP 环铺满 —— 否则 `processRevenue` 的失败原因有一天会变成「TWAP 没准备好」。
    ///      真实入口的完整行为在 `test/WarrantVaultOpenSeries.t.sol`。
    function _deployHarnessWithOpenSeries(StockToken quote, uint64 expiry)
        internal
        returns (WarrantVaultHarness harness, uint256 seriesId)
    {
        harness = _deployHarness(address(quote));
        factory.bind(meme, address(harness));
        seriesId = harness.harnessOpenSeries(STRIKE, expiry);
    }

    function _deployHarness(address quoteToken) internal returns (WarrantVaultHarness) {
        return new WarrantVaultHarness(pool, address(distributor), address(portal), meme, quoteToken, creator, false);
    }

    /// @dev 原生计价档（C2，§7.14）的 harness：收入币种是 WBNB 替身、`wrapsNative = true`，
    ///      并已开好本周系列。返回 harness、WBNB 与 seriesId。
    function _deployNativeHarnessWithOpenSeries(uint64 expiry)
        internal
        returns (WarrantVaultHarness harness, WNativeMock wbnb, uint256 seriesId)
    {
        wbnb = new WNativeMock();
        harness =
            new WarrantVaultHarness(pool, address(distributor), address(portal), meme, address(wbnb), creator, true);
        factory.bind(meme, address(harness));
        seriesId = harness.harnessOpenSeries(STRIKE, expiry);
    }

    /// @dev Flap 的唤醒调用：零值、空 calldata、限额 gas。
    function _ping(WarrantVault target) internal returns (bool ok) {
        (ok,) = address(target).call{value: 0, gas: PING_GAS}("");
    }

    function _hasSubstring(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    // ──────────────────────── 身份：六个参数在构造那一笔里定死 ────────────────────────

    function test_identity_declaresTheBoundStockAndTheServedMeme() public view {
        assertEq(vault.vaultQuoteToken(), address(stock), unicode"收入币种应当是绑定的股票代币");
        assertEq(vault.taxToken(), meme, unicode"服务的 MEME");
        assertEq(address(vault.pool()), address(pool), unicode"抵押品的去处");
        assertEq(vault.merkleDistributor(), address(distributor), unicode"权证的去处");
        assertEq(vault.portal(), address(portal), unicode"取价来源是构造参数");
        assertEq(vault.creator(), creator, unicode"分成收款人是构造参数（决策 49）");
        assertEq(vault.CREATOR_FEE_BPS(), 1000, unicode"分成比例是平台级常量 10%");
        assertGt(bytes(vault.description()).length, 0, unicode"description() 不该是空串");
    }

    /// @notice 🔴 **「一只没被初始化的金库」这个状态不存在了。**
    ///
    /// @dev 从前它是一条靠工厂纪律维持的不变式（必须 `new BeaconProxy(beacon, initData)`，
    ///      不能留空），现在由编译器保证：没有 `initialize`，六个身份参数是构造参数。
    ///      这条测试从 ABI 那一侧钉住它 —— 写入面枚举里也没有它（见下面两条）。
    function test_identity_thereIsNoInitializeEntryPoint() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("initialize(address,address)", meme, address(stock)));
        assertFalse(
            ok, unicode"金库不该还有 initialize —— 不可升级就没有「先部署再初始化」那一拍"
        );
    }

    /// @dev 七道构造检查，逐个撞一遍。🔴 它们落在**构造**上的意义是：一只填错的金库在
    ///      **创建它的那一笔交易**里就死掉，而不是等到第一次 `processRevenue` 才发现；
    ///      在 D0 的编排层里，这条回滚会把整次发射一起带走，不留半条身份根绑定。
    function test_constructor_rejectsZeroAddressesAndCodelessQuote() public {
        vm.expectRevert(unicode"Clearing pool is the zero address / 清算池是零地址");
        new WarrantVault(
            ClearingPool(address(0)),
            address(distributor),
            address(portal),
            meme,
            address(stock),
            creator,
            false,
            address(0xfee)
        );

        vm.expectRevert(unicode"Distributor is the zero address / 分发合约是零地址");
        new WarrantVault(pool, address(0), address(portal), meme, address(stock), creator, false, address(0xfee));

        vm.expectRevert(unicode"Portal is the zero address / 价源 Portal 是零地址");
        new WarrantVault(pool, address(distributor), address(0), meme, address(stock), creator, false, address(0xfee));

        vm.expectRevert(unicode"Tax token is the zero address / 税收代币是零地址");
        new WarrantVault(
            pool, address(distributor), address(portal), address(0), address(stock), creator, false, address(0xfee)
        );

        vm.expectRevert(unicode"Quote token is the zero address / 收入币种是零地址");
        new WarrantVault(pool, address(distributor), address(portal), meme, address(0), creator, false, address(0xfee));

        // 🔴 EOA 上的 staticcall 返回**成功**且数据为空 —— 不挡这一下，金库会从此
        //    认不到任何收入，而且一声不响。
        vm.expectRevert(unicode"Quote token has no code / 收入币种地址上没有代码");
        new WarrantVault(pool, address(distributor), address(portal), meme, alice, creator, false, address(0xfee));

        // 🔴 零地址 creator = 分成往黑洞里记（决策 49）：钱既到不了任何人手里，也回不了池子。
        vm.expectRevert(unicode"Creator is the zero address / 发射者是零地址");
        new WarrantVault(
            pool, address(distributor), address(portal), meme, address(stock), address(0), false, address(0xfee)
        );
    }

    /// @notice 🔴 **不同的金库可以带着不同的价源共存** —— 决策 39-A2 的全部意义。
    ///
    /// @dev 从前 Portal 来自 `VaultBase._getPortal()` 那张按 `chainId` 写死的表，
    ///      于是全链每一只金库共用同一个价源，换价源就得换实现 —— 而金库现在不可升级，
    ///      那条路等于没有。改成构造参数之后，「老项目用老价源、新项目用新价源」不需要任何开关。
    function test_portal_isPerVaultSoPriceSourcesCanCoexist() public {
        FlapPortalStub nextGeneration = new FlapPortalStub();
        WarrantVault younger = new WarrantVault(
            pool, address(distributor), address(nextGeneration), meme, address(stock), creator, false, address(0xfee)
        );

        assertEq(vault.portal(), address(portal), unicode"老金库仍读老价源");
        assertEq(younger.portal(), address(nextGeneration), unicode"新金库读新价源");
        assertTrue(vault.portal() != younger.portal(), unicode"🔴 两者确实不同，测试才有内容");
    }

    // ─────────────────────────── 余额差记账与 ping ───────────────────────────

    /// @dev 规范面的核心事实：ERC20 的 `transfer` 执行的是**代币合约**的代码，不是收款方的 ——
    ///      金库拿到钱却拿不到执行。协议补的那记 ping 才是唤醒。
    function test_erc20Revenue_transferAloneIsSilent_pingRecognizes() public {
        stock.mint(alice, 25e18);

        vm.prank(alice);
        stock.transfer(address(vault), 25e18);
        assertEq(vault.accountedQuote(), 0, unicode"光是转账，金库不该识别到任何收入");
        assertEq(vault.lastRevenueAt(), 0, unicode"也不该留下处理时刻");

        assertTrue(_ping(vault), unicode"ping 应当在限额 gas 内成功");
        assertEq(vault.accountedQuote(), 25e18, unicode"ping 之后按余额差识别");
        assertEq(vault.lastRevenueAt(), uint64(block.timestamp), unicode"记下处理时刻");
    }

    /// @dev 规范 rule 2：同一次 dispatch 可能把同一个钱包 ping 多次，任何人也能随时调 `receive()`。
    ///      零差额的唤醒必须是**静默 no-op**。
    function test_ping_isIdempotent() public {
        stock.mint(address(vault), 5e18);
        assertTrue(_ping(vault));
        assertEq(vault.accountedQuote(), 5e18);

        uint64 firstAt = vault.lastRevenueAt();
        vm.warp(block.timestamp + 1 days);

        assertTrue(_ping(vault));
        assertTrue(_ping(vault));
        vm.prank(alice);
        assertTrue(_ping(vault));

        assertEq(vault.accountedQuote(), 5e18, unicode"零差额的 ping 什么都不该识别");
        assertEq(vault.lastRevenueAt(), firstAt, unicode"零差额的 ping 也不该动处理时刻");
    }

    function test_sync_picksUpRevenueThatArrivedWithoutAWake() public {
        stock.mint(address(vault), 3e18);

        vm.prank(alice); // 无许可
        vault.sync();

        assertEq(vault.accountedQuote(), 3e18, unicode"sync() 补记未被唤醒的到账");
    }

    function testFuzz_recognizesExactlyTheDelta(uint128 first, uint128 second) public {
        stock.mint(address(vault), first);
        assertTrue(_ping(vault));
        assertEq(vault.accountedQuote(), first, unicode"第一段");

        stock.mint(address(vault), second);
        assertTrue(_ping(vault));
        assertEq(
            vault.accountedQuote(), uint256(first) + second, unicode"第二段是差额累加，不是重复计数"
        );
    }

    /// @dev 🔴 `receive()` 里做的一切都必须装进 keeper 的预算。规范 rule 005 的硬上限是 100 万 gas，
    ///      而一个合规实现应当远低于它 —— 这里钉的是后者。
    function test_ping_staysFarUnderTheReceiveGasBudget() public {
        stock.mint(address(vault), 7e18);

        uint256 before = gasleft();
        (bool ok,) = address(vault).call{value: 0, gas: PING_GAS}("");
        uint256 used = before - gasleft();

        assertTrue(ok, unicode"ping 不该失败");
        emit log_named_uint("ERC20 receive recognition gas", used);
        assertLt(used, 1_000_000, unicode"规范 rule 005 的硬上限");
        assertLt(used, 100_000, unicode"本地替身上的实际开销应当远小于上限");
    }

    /// @dev 🔴 这是整份测试里赌注最大的一条：`receive()` 由 Flap 的 dispatch 触发，
    ///      它一旦 revert，受影响的是 **Flap 的税收结算**。而 `receive()` 里唯一不受我们控制的
    ///      一步就是读收入币种余额 —— 收入币种是发行方可整体升级的 BeaconProxy。
    function test_receive_neverReverts_whateverTheQuoteTokenDoes() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        WarrantVault hostileVault = _deployVault(meme, address(hostile));

        HostileQuoteToken.Mode[4] memory modes = [
            HostileQuoteToken.Mode.Revert,
            HostileQuoteToken.Mode.Empty,
            HostileQuoteToken.Mode.Short,
            HostileQuoteToken.Mode.BurnGas
        ];

        for (uint256 i = 0; i < modes.length; i++) {
            hostile.set(modes[i], 100e18);

            vm.expectEmit(true, false, false, false, address(hostileVault));
            emit WarrantVault.QuoteBalanceUnreadable(address(hostile));
            assertTrue(_ping(hostileVault), unicode"收入币种怎么坏，ping 都不该失败");

            assertEq(hostileVault.accountedQuote(), 0, unicode"读不到余额就不该记账");
            hostileVault.sync(); // 同一条路径，同样不 revert
        }

        // 🔴 读不出来只是**当次**跳过：收入按差额算，币种恢复之后一次补齐，什么都没丢。
        hostile.set(HostileQuoteToken.Mode.Honest, 100e18);
        assertTrue(_ping(hostileVault));
        assertEq(hostileVault.accountedQuote(), 100e18, unicode"恢复之后应当一次补齐");
    }

    /// @dev 🔴 第五种失败模式单列一条，因为它挡的是一笔**不在限额 gas 之内**的开销：
    ///      `(bool, bytes memory) = addr.staticcall(…)` 会把整个 returndata 复制进我们的内存，
    ///      而那份内存扩张由**调用方**付账。对方在 20 万 gas 的限额里造得出约 288KB 返回数据，
    ///      复制它要再花约 18.5 万 —— `receive()` 的开销上界就此失控。
    ///      金库只收 32 字节，所以这条断言量的是「那份复制没有发生」。
    function test_receive_doesNotPayForAFloodedReturnValue() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        WarrantVault hostileVault = _deployVault(meme, address(hostile));
        hostile.set(HostileQuoteToken.Mode.Flood, 100e18);

        uint256 before = gasleft();
        (bool ok,) = address(hostileVault).call{value: 0, gas: PING_GAS}("");
        uint256 used = before - gasleft();

        assertTrue(ok, unicode"返回一大片数据也不该让 ping 失败");
        // 上界 = 转发出去的 20 万（对方自己烧掉的）+ 我们这一侧的余量。
        // 复制那份 returndata 会再花约 18.5 万，越过这条线。
        assertLt(used, 250_000, unicode"🔴 returndata 被复制进来了 —— 开销上界失控");
    }

    /// @dev 原生币不是本金库的收入币种。收到也不记账、更不 revert —— 后者会让 Flap 的
    ///      dispatch 跟着失败。代价是这笔原生币**取不出来**，这是刻意的：一个 sweep 函数
    ///      就是一个权限函数，而 Guardian 条款会把它变成 Flap 的一把钥匙。
    function test_receive_acceptsNativeValueButNeverCountsItAsRevenue() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");

        assertTrue(ok, unicode"原生转账不该 revert");
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.accountedQuote(), 0, unicode"原生币不是收入");
    }

    // ─────────────────── 收入路径 processRevenue（M2-3，issue #35）───────────────────

    /// @notice 收到即存入的正常一天（决策 49 口径）：可存量的 90% 进池子、10% 记给 creator，
    ///         权证铸给 distributor，「在途」归零 —— 金库余额里只剩 creator 浮存。
    ///
    /// @dev 三条验收条款在这一条里同时成立：读的是**实际余额**而不是记账值（这里让一半的钱
    ///      从没被 ping 过，金库照样把它一起算进可存量）、铸造量由池子实测、以及 🔴 规范
    ///      rule 010-3 —— 支出之后基线必须落到真实剩余余额（= creator 浮存），否则金库从此死锁。
    function test_processRevenue_depositsTheWholeDepositableBalanceAndMintsToTheDistributor() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);

        // 第一笔被 ping 认过，第二笔没有 —— 金库要存的是**余额**，不是它自己那本账。
        stock.mint(address(harness), 30e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        assertEq(harness.accountedQuote(), 30e18, unicode"前置条件：只认了第一笔");
        stock.mint(address(harness), 12e18);

        // 🔴 时间必须往前走一格，否则「记下处理时刻」那条断言会被**上面那记 ping** 提前满足 ——
        //    它已经把 lastRevenueAt 写成了当前区块时刻，processRevenue 一个字节都不碰也照样绿。
        uint64 stampedByPing = harness.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);

        // 42e18 可存量 ⟹ 4.2e18 记给 creator、33.6e18 进池子。两条事件按实现顺序各钉一遍。
        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.CreatorFeeAccrued(4.2e18, 4.2e18);
        vm.expectEmit(true, false, false, true, address(harness));
        emit WarrantVault.RevenueDeposited(seriesId, 33.6e18, 33.6e18);
        uint256 minted = harness.processRevenue();

        assertEq(minted, 33.6e18, unicode"没被 ping 过的那一笔也一起算进了可存量，九成进池");
        assertEq(stock.balanceOf(address(harness)), 8.4e18, unicode"金库里只剩 creator 浮存");
        assertEq(harness.creatorAccrued(), 4.2e18, unicode"分成入账 10%");
        assertEq(stock.balanceOf(address(pool)), 33.6e18, unicode"抵押品到了池子里");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 33.6e18, unicode"权证铸给了 distributor");

        // 🔴 rule 010-3：基线必须跟着支出走到真实剩余余额。留着不减 = 金库永久死锁。
        assertEq(harness.accountedQuote(), 8.4e18, unicode"基线 = creator 浮存");
        (uint256 held, bool exact) = harness.inTransit();
        assertTrue(exact);
        assertEq(held, 0, unicode"「在途」归零 —— creator 浮存不在其中");
        assertEq(harness.lastRevenueAt(), uint64(block.timestamp), unicode"记下处理时刻");
        assertGt(harness.lastRevenueAt(), stampedByPing, unicode"而且这个时刻确实是被本次存入推动的");

        // 而且金库没有因此变成死的：下一笔收入照常认得到、存得进（九成）。
        stock.mint(address(harness), 5e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        assertEq(harness.accountedQuote(), 13.4e18, unicode"🔴 基线没被卡住，新收入仍然识别得到");
        assertEq(harness.processRevenue(), 4e18, unicode"也仍然存得进去（5e18 的九成）");
        assertEq(harness.creatorAccrued(), 4.7e18, unicode"分成继续累计");
    }

    /// @notice 🔴 验收条款：铸造量以池子实测的**余额增量**为准；金库既不自己算应铸量，
    ///         也**不断言** `minted == balance`。
    ///
    /// @dev 断言两者相等等于把「股票代币不带转账税」写死进产品。真实 GME 目前零税，
    ///      但发行方可以整体升级实现 —— 而池子对任何股票代币都开着。
    function test_processRevenue_mintsThePoolsBalanceDeltaNotTheAmountItSent() public {
        StockToken taxed = new StockToken();
        taxed.setTaxBps(300); // 3%

        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(taxed, expiry);

        taxed.mint(address(harness), 100e18);
        uint256 poolBefore = taxed.balanceOf(address(pool));

        uint256 minted = harness.processRevenue();
        uint256 delta = taxed.balanceOf(address(pool)) - poolBefore;

        assertEq(minted, delta, unicode"🔴 铸造量 == 池内实测余额增量（不变量 2）");
        assertEq(minted, 77.6e18, unicode"存入 90e18（可存量的九成），3% 的税确实被扣掉了");
        assertLt(minted, 90e18, unicode"🔴 若这条不成立，这个测试就没在测带税代币");
        assertEq(warrant.balanceOf(address(distributor), seriesId), minted, unicode"权证数 == 铸造量");
        assertEq(taxed.balanceOf(address(harness)), 20e18, unicode"金库里只剩 creator 浮存");
        assertEq(harness.creatorAccrued(), 10e18, unicode"分成按可存量的 10% 入账");
        assertEq(harness.accountedQuote(), 20e18, unicode"基线落到真实剩余余额");
    }

    /// @notice 即使池子调用成功，也只能按金库的实际后余额更新基线与 `sent` 事件字段。
    /// @dev 非标准 ERC-20 可以让 `transferFrom` 返回 true 却不移动余额；池子会诚实地铸 0，
    ///      金库不能把仍在手里的抵押品错记成已支出，否则下次唤醒会把同一笔钱再认一次。
    function test_processRevenue_keepsTheResidualWhenTransferFromReturnsTrueButMovesNothing() public {
        NoOpStockToken noOp = new NoOpStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(noOp, expiry);

        noOp.mint(address(harness), 25e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        uint64 recognisedAt = harness.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);
        noOp.setNoOpTransfers(true);

        vm.expectEmit(true, false, false, true, address(harness));
        emit WarrantVault.RevenueDeposited(seriesId, 0, 0);
        assertEq(harness.processRevenue(), 0, unicode"池子没有收到余额 ⟹ 不铸权证");

        assertEq(noOp.balanceOf(address(harness)), 25e18, unicode"假成功不能让金库余额凭空消失");
        assertEq(noOp.balanceOf(address(pool)), 0, unicode"池子实际没收到抵押品");
        assertEq(harness.accountedQuote(), 25e18, unicode"基线必须保留真实剩余余额");
        assertEq(
            harness.creatorAccrued(),
            0,
            unicode"🔴 假成功不产生分成（决策 49-④），否则重试时同批钱被二次切分"
        );
        assertEq(harness.lastRevenueAt(), recognisedAt, unicode"假成功不能伪造一次收入处理时刻");
        assertEq(noOp.allowance(address(harness), address(pool)), 0, unicode"仍不留下常驻授权");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 0, unicode"没有抵押品就没有权证");

        // 恢复正常转账后，同一笔收入可被安全地重试，不会重复识别或永久卡住。
        noOp.setNoOpTransfers(false);
        assertEq(harness.processRevenue(), 20e18, unicode"恢复后可重试实际存入（可存量的九成）");
        assertEq(
            harness.creatorAccrued(),
            2.5e18,
            unicode"分成只在实测扣款成功的这一次入账，且只入一次"
        );
        assertEq(harness.accountedQuote(), 5e18, unicode"实际清空后基线落到 creator 浮存");
        assertEq(harness.lastRevenueAt(), uint64(block.timestamp), unicode"实际扣款才推进处理时刻");
    }

    /// @notice 🔴 验收条款：余额为 0 时**干净返回，不 revert** —— Trigger Service 每天空跑一次。
    function test_processRevenue_isACleanNoOpWhenThereIsNothingToDeposit() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        vm.recordLogs();
        assertEq(harness.processRevenue(), 0, unicode"没钱可存 ⟹ 返回 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"空跑不该发任何事件");

        assertEq(harness.accountedQuote(), 0);
        assertEq(harness.lastRevenueAt(), 0, unicode"空跑不该动处理时刻");
    }

    /// @notice 🔴 验收条款：**当前无已开系列 ⟹ 拒绝并 emit，钱留在金库等下一次。**
    ///
    /// @dev 三件事必须同时成立：不得 revert（Trigger Service 的告警会被污染）、不得静默吞掉
    ///      （在途敞口正在被拉长，链下必须看得见）、不得存进错误的系列。
    ///      两种「无系列」各测一次，因为它们对应的运维动作不同：从没开过 = `openSeries()` 还没跑过第一次；
    ///      已到期 = 上一周结束了、下一周还没开。
    function test_processRevenue_defersAndEmitsWhenNoSeriesHasEverBeenOpened() public {
        stock.mint(address(vault), 7e18);

        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.RevenueDeferred(6.3e18, 0);
        assertEq(vault.processRevenue(), 0, unicode"没有系列 ⟹ 不存");

        assertEq(stock.balanceOf(address(vault)), 7e18, unicode"🔴 钱留在金库，一个 wei 不少");
        assertEq(vault.accountedQuote(), 7e18, unicode"而且它仍然是「已识别、尚未支出」");
        assertEq(warrant.balanceOf(address(distributor), 0), 0, unicode"没有往任何系列里铸过东西");
    }

    function test_processRevenue_defersOnceTheCurrentSeriesHasExpired() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 9e18);
        vm.warp(uint256(expiry)); // 到期那一秒就算过期：`block.timestamp < seriesExpiry` 是严格小于

        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.RevenueDeferred(8.1e18, expiry);
        assertEq(harness.processRevenue(), 0, unicode"系列已到期 ⟹ 不存");
        assertEq(stock.balanceOf(address(harness)), 9e18, unicode"钱留在金库等下一个系列");

        // 开出下一个系列之后，同一笔钱立刻走得掉 —— **只有延迟，没有损失**。
        uint64 next = uint64(block.timestamp + 7 days);
        uint256 nextSeries = harness.harnessOpenSeries(STRIKE, next);
        assertEq(
            harness.processRevenue(), 7.2e18, unicode"下一个系列开出来之后重跑即可（九成入池）"
        );
        assertEq(warrant.balanceOf(address(distributor), nextSeries), 7.2e18, unicode"铸进了新系列");
        assertEq(
            harness.creatorAccrued(),
            0.9e18,
            unicode"一成在存入那一刻记给 creator —— 递延期间不提前切"
        );
    }

    /// @notice 🔴 验收条款：**permissionless** —— 「加速资金离开可升级合约」不该有守门人。
    /// @dev 同时钉住第二半：调用方**改变不了**钱的去向。任取一个调用方，
    ///      抵押品仍然只进池子、权证仍然只进 distributor、他自己一个 wei 都拿不到。
    function testFuzz_processRevenue_isPermissionlessAndTheCallerGetsNothing(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool));

        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);
        // 🔴 creator 也要排除：他不是本条要测的对象 —— 分成是 pull 的，processRevenue 本身
        //    一个 wei 都不会转给他，但「caller 余额为 0」这条断言只对非 creator 的调用方是不变式。
        vm.assume(caller != address(harness) && caller != address(distributor) && caller != creator);

        stock.mint(address(harness), 20e18);

        vm.prank(caller);
        uint256 minted = harness.processRevenue();

        assertEq(minted, 16e18, unicode"任何人都调得动（可存量的九成入池）");
        assertEq(stock.balanceOf(caller), 0, unicode"🔴 调用方一个 wei 都拿不到");
        assertEq(warrant.balanceOf(caller, seriesId), 0, unicode"🔴 权证也不归他");
        assertEq(stock.balanceOf(address(pool)), 16e18, unicode"钱只可能流向池子");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 16e18, unicode"权证只可能流向 distributor");
        assertEq(
            stock.balanceOf(address(harness)),
            4e18,
            unicode"一成留在金库等 creator 领取 —— 不是调用方的"
        );
    }

    /// @notice 🔴 **两笔交易之间，金库对池子的授权恒为 0。**
    /// @dev 存入必须给池子授权（池子用 `transferFrom` 拉货），但那份授权只在存入那一笔里存在。
    ///      留一份常驻的无限授权不会立刻出事 —— 池子不可升级、也只在 `depositAndMint` 里拉货 ——
    ///      但它会把「金库此刻能被谁动多少钱」从一个结构事实降级成一句需要有人去读代码的保证。
    function test_processRevenue_leavesNoStandingAllowance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        assertEq(stock.allowance(address(harness), address(pool)), 0, unicode"存入之前是 0");

        stock.mint(address(harness), 15e18);
        harness.processRevenue();

        assertEq(stock.allowance(address(harness), address(pool)), 0, unicode"存入之后仍然是 0");
    }

    /// @notice 🔴 **规范 rule 010-3 那条缝：转账回调里再调一次 `sync()`，金库不能因此死锁。**
    ///
    /// @dev 金库把全部余额转给池子，代币在**余额变动之前**回调金库调 `sync()` ——
    ///      此刻余额还是满的。如果金库在外部调用**之前**就把 `accountedQuote` 清了零，
    ///      这次 `sync()` 会看见「余额满、基线 0」，把基线重新推回满额；转账随后生效，
    ///      基线就永久停在真实余额之上，`balance <= accountedQuote` 从此压住一切收入识别 ——
    ///      **金库死锁，而且一声不响**。
    ///
    ///      现在的顺序让那次再入天然是 no-op：`_recognize()` 已经把基线推到了满额。
    ///      所以这条测试的最后两行才是它的全部意义 —— **金库还活着**。
    function test_processRevenue_aReentrantSyncCannotDeadlockTheVault() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();

        uint64 expiry = uint64(block.timestamp + 7 days);
        WarrantVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);
        hostile.armReentrancy(address(harness), abi.encodeCall(WarrantVault.sync, ()));

        hostile.mint(address(harness), 40e18);
        assertEq(harness.processRevenue(), 32e18, unicode"存入本身应当成功（可存量的九成）");

        // 回调真的打过 —— 否则下面那两条断言什么也没验证。
        assertGt(hostile.reentryAttempts(), 0, unicode"再入一次都没触发，这条测试是空的");
        assertTrue(hostile.reentrySucceeded(), unicode"sync() 是 no-op，不该 revert");

        // 🔴 金库还活着：基线没有停在真实余额之上。决策 49 之后「真实余额」= creator 浮存，
        //    判据从「归零」变成「等于浮存」—— 高于它一个 wei 都是死锁的开端。
        assertEq(harness.accountedQuote(), 8e18, unicode"🔴 基线被再入推高了 —— 金库已死锁");
        assertEq(harness.creatorAccrued(), 4e18, unicode"浮存与基线一致");
        hostile.mint(address(harness), 6e18);
        harness.sync();
        assertEq(harness.accountedQuote(), 14e18, unicode"🔴 新收入仍然识别得到");
        assertEq(harness.processRevenue(), 4.8e18, unicode"🔴 也仍然存得出去（6e18 的九成）");
    }

    /// @notice 🔴 **余额读不出来时，金库唯一的出口必须如实失败，而 `receive()` 仍须 fail-open。**
    function test_processRevenue_revertsWhenBalanceIsUnreadableWhileReceiveFailsOpen() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        WarrantVault hostileVault = _deployVault(meme, address(hostile));

        // ① 币种彻底坏掉：如实失败，而不是静默返回 0。
        hostile.set(HostileQuoteToken.Mode.Revert, 100e18);
        vm.expectRevert(unicode"Quote balance unreadable / 收入币余额不可读");
        hostileVault.processRevenue();

        // ② `receive()` 那一侧仍然一个都不 revert —— 两条路径的取舍是相反的，而且必须相反。
        vm.expectEmit(true, false, false, false, address(hostileVault));
        emit WarrantVault.QuoteBalanceUnreadable(address(hostile));
        assertTrue(_ping(hostileVault), unicode"ping 仍然不该失败");
        assertEq(hostileVault.accountedQuote(), 0);
    }

    /// @notice 🔴 **同一只慢但健康的币：receive 的封顶读 fail-open，processRevenue 的非封顶读能存入。**
    /// @dev 这是两条路径的真实差异：固定工作量让 20 万 gas 的 `staticcall` 失败，但普通交易
    ///      里完整的 ERC-20 与真实池子路径仍可完成；无限烧 gas 的注入器不能证明这件事。
    function test_processRevenue_rejectsUnreadableBoundedBalance() public {
        SlowBalanceStockToken slow = new SlowBalanceStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(slow, expiry);

        slow.mint(address(harness), 11e18);

        bytes memory balanceCall = abi.encodeCall(IERC20.balanceOf, (address(harness)));
        (bool cappedRead,) = address(slow).staticcall{gas: 200_000}(balanceCall);
        assertFalse(cappedRead, unicode"20 万 gas 的封顶读确实读不完");
        (bool fullRead, bytes memory returned) = address(slow).staticcall{gas: 1_000_000}(balanceCall);
        assertTrue(fullRead, unicode"更高但有限的 gas 预算可以读完");
        assertEq(abi.decode(returned, (uint256)), 11e18, unicode"慢读仍返回真实余额");

        vm.expectEmit(true, false, false, false, address(harness));
        emit WarrantVault.QuoteBalanceUnreadable(address(slow));
        assertTrue(_ping(WarrantVault(payable(address(harness)))), unicode"慢读也不能让 receive 回滚");
        assertEq(harness.accountedQuote(), 0, unicode"封顶读失败 ⟹ 不猜余额");

        vm.expectRevert(unicode"Quote balance unreadable / 收入币余额不可读");
        harness.processRevenue();
        assertEq(slow.balanceOf(address(harness)), 11e18);
        assertEq(slow.balanceOf(address(pool)), 0);
        assertEq(warrant.balanceOf(address(distributor), seriesId), 0);
    }

    /// @notice 🔴 **`accountedQuote` 只是记账基线，`inTransit()` 才是 R4 的实时读数。**
    ///
    /// @dev 规范列了四种「唤醒缺席」的常态（{VaultBaseV3} rule 010-4 / rule 5、ping law 2）：
    ///      直接转账与捐赠不发 ping、ping 可以在 processor 上被关掉、ping 失败会被忽略，
    ///      以及本合约自己的 `QuoteBalanceUnreadable` 路径。拿基线当敞口读数，
    ///      恰好会在**最该报警的那种失效**下读出 0 —— 税还在进来，却没有任何东西唤醒金库。
    function test_inTransit_readsTheRealBalanceNotTheRecognisedBaseline() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        // 走完一整轮，把基线落到 creator 浮存（42e18 的一成）。
        stock.mint(address(harness), 42e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        harness.processRevenue();
        assertEq(harness.accountedQuote(), 8.4e18, unicode"前置条件：基线 = creator 浮存");
        {
            (uint256 quiet, bool quietExact) = harness.inTransit();
            assertTrue(quietExact);
            assertEq(quiet, 0, unicode"存完后「在途」为 0 —— 浮存被净掉了");
        }

        // 🔴 新收入**没有被唤醒**就到账 —— 基线读旧值，在途必须读真数（净掉浮存）。
        stock.mint(address(harness), 1000e18);
        assertEq(
            harness.accountedQuote(), 8.4e18, unicode"基线还没动，这正是它不能当敞口读数的理由"
        );

        (uint256 held, bool exact) = harness.inTransit();
        assertEq(held, 900e18, unicode"🔴 在途读的是真实余额净掉 creator 浮存");
        assertTrue(exact, unicode"老实币种上应当是精确值");
        assertTrue(
            _hasSubstring(harness.description(), unicode"在途收入 900000000000000000000 raw"),
            unicode"🔴 状态横幅不许在钱还停着的时候说「没有」"
        );
    }

    /// @dev 发行方可先从金库烧掉代币、再换成不可读实现；这时旧基线不是任何方向的边界。
    ///      `inTransit()` 必须返回未知哨兵，且 `description()` 不得把它渲染成「没有在途收入」。
    function test_inTransit_reportsUnknownWhenIssuerBurnMakesTheBaselineStaleAndBalanceUnreadable() public {
        IssuerBurnableUnreadableStockToken issuerControlled = new IssuerBurnableUnreadableStockToken();
        WarrantVault issuerVault = _deployVault(meme, address(issuerControlled));

        issuerControlled.mint(address(issuerVault), 70e18);
        assertTrue(_ping(issuerVault));
        assertEq(issuerVault.accountedQuote(), 70e18, unicode"前置条件：旧基线已记下余额");

        issuerControlled.adminBurn(address(issuerVault), 70e18);
        issuerControlled.setBalanceUnreadable(true);

        (uint256 held, bool exact) = issuerVault.inTransit();
        assertEq(held, 0, unicode"读不出来时 amount 是未知哨兵，不能泄露陈旧基线");
        assertFalse(exact, unicode"必须明确标为非精确值");
        assertEq(issuerVault.accountedQuote(), 70e18, unicode"反例成立：基线确实可能高于真实余额");
        string memory banner = issuerVault.description();
        assertTrue(
            _hasSubstring(banner, unicode"在途收入数量不可读"),
            unicode"状态横幅必须明确告知数量未知"
        );
        assertTrue(_hasSubstring(banner, "in-transit amount unreadable"), unicode"英文横幅同样明确未知");
        assertFalse(
            _hasSubstring(banner, unicode"当前没有在途收入"), unicode"未知不能被渲染为零在途"
        );
        assertFalse(_hasSubstring(banner, "nothing in transit"), unicode"英文横幅同样不能渲染为零在途");
    }

    /// @notice 🔴 **收入币种拒绝授权时，报出来的必须是它自己的原因，不是我们的一句「授权失败」。**
    ///
    /// @dev 真实 GME 的 `approve` 上编译了 `onlyNotPaused` + `onlyNotBlocked`
    ///      （`docs/research/robinhood-stock-token-permissions.md` §3），所以发行方一暂停，
    ///      金库存入路径上**第一个**倒下的就是那次授权。把 `IsPaused()` 换成一句我们自己的话，
    ///      等于把「发行方按了开关」误报成「我们的代码有问题」—— 运维会照着错误的方向查一整晚。
    ///      这也正是这里不用 `SafeERC20` 的第二条理由（第一条是它的 custom error 前端解不开）。
    function test_processRevenue_bubblesUpTheQuoteTokensOwnRejection() public {
        GatedApprovalStockToken gated = new GatedApprovalStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(gated, expiry);

        gated.mint(address(harness), 8e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        gated.setApprovalsBlocked(true);

        vm.expectRevert(GatedApprovalStockToken.IssuerPaused.selector);
        harness.processRevenue();

        // 干净失败：钱、基线、授权三样一个都没动。
        assertEq(gated.balanceOf(address(harness)), 8e18, unicode"钱一个 wei 不少地留在金库");
        assertEq(
            harness.accountedQuote(), 8e18, unicode"基线没动 —— 它仍然是「已识别、尚未支出」"
        );
        assertEq(gated.allowance(address(harness), address(pool)), 0, unicode"没留下残余授权");

        // 解除之后重跑一次即可 —— 只有延迟，没有损失。
        gated.setApprovalsBlocked(false);
        assertEq(harness.processRevenue(), 6.4e18, unicode"解除后重试必须成功（可存量的九成）");
    }

    /// @dev 另一半：对方**没有 revert 但也没同意**（返回 `false`）。这时才轮到我们那句字面量串 ——
    ///      不判返回值的话，故障会推迟到池子的 `transferFrom`，报出来的原因就跟真正的病因无关了。
    function test_processRevenue_rejectsAnApprovalThatSilentlyReturnedFalse() public {
        SilentApprovalFailureStockToken silent = new SilentApprovalFailureStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(silent, expiry);

        silent.mint(address(harness), 8e18);

        vm.expectRevert(unicode"Quote token rejected the approval / 收入币种拒绝了授权");
        harness.processRevenue();

        assertEq(silent.balanceOf(address(harness)), 8e18, unicode"钱一个 wei 不少地留在金库");
    }

    /// @notice 🔴 **返回脏布尔的 `approve` 不许把整笔炸成一次「什么都没有」的 revert。**
    ///
    /// @dev `abi.decode(ret, (bool))` 遇到既不是 0 也不是 1 的字时，solc 的校验器直接
    ///      `revert(0, 0)` —— 空 returndata。那会抢在我们的 `require` 前面，于是既冒泡不出
    ///      对方的原因、也拿不到我们的字面量串：前端按 rule 004 原样显示时什么都显示不出来，
    ///      运维看到一次裸 revert，与 out-of-gas 无法区分。
    ///      金库因此按 `uint256` 解、非零即真 —— 与 {ClearingPool} 的 `_readGating` 同一个取舍。
    ///      所以这只代币的授权应当**成功**，而不是失败得毫无线索。
    function test_processRevenue_acceptsANonCanonicalTrueInsteadOfRevertingWithNoData() public {
        DirtyBoolApprovalStockToken dirty = new DirtyBoolApprovalStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(dirty, expiry);

        dirty.mint(address(harness), 6e18);
        assertEq(harness.processRevenue(), 4.8e18, unicode"非规范的 true 也是 true（九成入池）");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 4.8e18);
    }

    /// @notice 🔴 **写入顺序的反证钉子：必须先 `pool.openSeries` 成功，再写 `strike` / `seriesExpiry`。**
    ///         正面那一半（池子拒绝时字段一个字节都不落）在
    ///         `WarrantVaultOpenSeries.t.sol::test_openSeries_writesNothingWhenThePoolRejects`。
    ///
    /// @dev 反过来写的话，字段会指向一个本金库并不拥有的系列，而本函数会稳定撞上 `NotSeriesVault`
    ///      —— 收入从此再也出不去金库，直到有人升级实现。这条测试把那个后果摆出来，
    ///      好让「顺序是承重的」这句话有一处会变红的出处。
    function test_processRevenue_revertsWhenTheSeriesFieldsWereWrittenWithoutOpening() public {
        WarrantVaultHarness harness = _deployHarness(address(stock));

        uint64 expiry = uint64(block.timestamp + 7 days);
        harness.harnessWriteSeriesFieldsWithoutOpening(STRIKE, expiry);
        stock.mint(address(harness), 3e18);

        uint256 seriesId = pool.seriesIdOf(meme, address(stock), expiry);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, seriesId));
        harness.processRevenue();

        assertEq(stock.balanceOf(address(harness)), 3e18, unicode"整笔回滚，钱一个 wei 不少");
    }

    // ───────────────────────────── 写入面（两条 🔴） ─────────────────────────────

    /// @dev 上界（没有第七个入口）读编译产物的 ABI 断言；下界由编译器保证 —— 少一个、
    ///      或者被收紧成 view，同样会红。
    ///      📝 M2-4（issue #36）把 `openSeries()` 加进来，五个变成六个；
    ///      M2-6③（issue #58）把 `initialize` 拿掉，六个又回到五个 —— 后者不是「少了一个功能」，
    ///      是**不可升级消掉了「先部署再初始化」那一拍**，两个身份参数搬到了构造函数上；
    ///      决策 49 把 `claimCreatorFee()` 加进来，五个又变成六个 —— 收款人是构造期定死的
    ///      `creator`，它仍然不是权限函数（见下一条的表）。
    function test_writeSurface_isExactlyTheDeclaredNineEntries() public view {
        string[] memory expected = new string[](9);
        expected[0] = "sync()";
        expected[1] = "sampleTwap()";
        expected[2] = "openSeries()";
        expected[3] = "processRevenue()";
        expected[4] = "receive()";
        expected[5] = "claimCreatorFee()";
        expected[6] = "emergencyWithdrawNative(address)";
        expected[7] = "emergencyWithdrawToken(address,address)";
        expected[8] = "claimProtocolFee()";

        WriteSurface.assertIsExactly(ARTIFACT, expected);
    }

    /// @notice 🔴 **零权限面：没有一把钥匙，因此没有一把钥匙可以被夺走、被泄露、被误用。**
    ///
    /// @dev 这条性质在决策 39 之前的理由是 Flap 规范的强制（权限函数必须同时授予 Guardian
    ///      且不可撤销），之后**理由换成了我们自己的选择** —— 它是「金库拿不走钱」的最短证明。
    ///      判据一个字没改：把 ABI 的可写面整个枚举一遍，再对每一个入口给出它
    ///      **为什么不是权限函数**的理由：
    ///
    ///      | 入口 | 为什么不是权限函数 |
    ///      |---|---|
    ///      | `receive()` | 协议与任何人都能调，无判定 |
    ///      | `sync()` | 无许可，余额差记账模型推荐的补记入口 |
    ///      | `processRevenue()` | 无许可，而且调用方改变不了钱的去向（去处是 `immutable`） |
    ///      | `sampleTwap()` | 🔴 无许可**是一处取舍**，不是默认值 —— 完整论证见 `WarrantVault.sampleTwap` |
    ///      | `openSeries()` | 🔴 同上，取舍写在 `WarrantVault.OPEN_WINDOW` 上：调用方一个参数都挑不了，
    ///        挑得动的只有**时刻**，而那一面由「只在当前系列到期前 24 小时内开得出下一期」压住 |
    ///      | `claimCreatorFee()` | 决策 49：收款人是构造期定死的 `creator`，calldata 改不了它 ——
    ///        抢跑触发对 creator 无害，加 `msg.sender == creator` 的门换不来任何安全收益 |
    ///
    ///      `sampleTwap()` 是这份名单上第一个**有对手方**的入口，所以它值得在这里再说一遍
    ///      为什么仍然不加权限：把它做成「只有 Trigger Service 能调」，① 后端一挂采样就停，
    ///      `openSeries()` 对 TWAP 是 fail-closed 的，环一过期就是整周停发；② 它会成为本金库的
    ///      第一把钥匙，从此需要有人保管、有人轮换、有人在丢了之后回答「怎么办」。
    ///      代价（任何人可以挑采样时刻）被最小间隔与尾段权重压住，并且是**可观测**的 ——
    ///      见 `sampleTwap` 的注释与 `test/WarrantVaultTwap.t.sol` 的对抗测试。
    function test_writeSurface_everyWritableEntryHasDeclaredPermissions() public view {
        string[] memory permissionless = new string[](9);
        permissionless[0] = "sync()";
        permissionless[1] = "sampleTwap()";
        permissionless[2] = "openSeries()";
        permissionless[3] = "processRevenue()";
        permissionless[4] = "receive()";
        permissionless[5] = "claimCreatorFee()";
        permissionless[6] = "emergencyWithdrawNative(address)";
        permissionless[7] = "emergencyWithdrawToken(address,address)";
        permissionless[8] = "claimProtocolFee()";

        string[] memory writable = WriteSurface.writableSignatures(ARTIFACT);
        for (uint256 i = 0; i < writable.length; i++) {
            bool known;
            for (uint256 j = 0; j < permissionless.length; j++) {
                if (keccak256(bytes(writable[i])) == keccak256(bytes(permissionless[j]))) known = true;
            }
            assertTrue(
                known,
                string.concat(
                    unicode"新增了一个对外可写入口，先回答它是不是权限函数 —— 零权限面是「金库拿不走钱」的最短证明：",
                    writable[i]
                )
            );
        }
    }

    /// @dev 上一条断言的是「名单上没有权限函数」，这一条断言的是**运行时也真的没有角色判定**：
    ///      任取一个地址，六个入口的表现都与调用方无关。
    ///      ⚠️ `openSeries()` 在这里只走**失败**那一侧（环还没填满），因为把 24 条样本铺满会把这条
    ///      测试的时间轴整个挪走；它成功那一侧的任意调用方由
    ///      `WarrantVaultOpenSeries.t.sol::testFuzz_anyCallerCanOpenTheWeeklySeries` 覆盖。
    function testFuzz_anyCallerCanDriveEveryWritableEntry(address caller) public {
        vm.assume(caller != address(0));

        stock.mint(address(vault), 1e18);
        vm.prank(caller);
        vault.sync();
        assertEq(vault.accountedQuote(), 1e18);

        vm.prank(caller);
        assertTrue(_ping(vault));

        portal.setCurve(meme, address(stock), 2e18);
        vm.prank(caller);
        assertTrue(vault.sampleTwap(), unicode"采样也是无许可的 —— 任取一个地址都写得进去");

        // 环里只有一条样本，所以开系列对**谁**都是同一句拒绝 —— 而这正是这条测试要问的。
        vm.prank(caller);
        vm.expectRevert(
            unicode"24h TWAP unavailable, call twap() for the reason / 24 小时 TWAP 不可用，原因调 twap() 读"
        );
        vault.openSeries();

        // 这只金库还没有系列，所以 `processRevenue` 走的是延后那条边 ——
        // 但它对任何调用方都一样走得通。
        vm.prank(caller);
        assertEq(vault.processRevenue(), 0);

        // 零累计时 `claimCreatorFee` 是静默 no-op —— 对任何调用方都一样。
        vm.prank(caller);
        assertEq(vault.claimCreatorFee(), 0, unicode"第六个入口同样无许可，零累计时干净返回");
    }

    /// @notice 🔴 **金库不持有任何调用方可提取的债权。**
    ///
    /// @dev M2-1 时这句话的证法是「三个入口一次转账都不做」。M2-3 加了唯一的支出路径，
    ///      决策 49 加了第二条 —— 于是它换成了今天的形式，而且仍然由同一份 ABI 枚举兜底：
    ///
    ///      六个入口里只有 `processRevenue()` 与 `claimCreatorFee()` 会动货，而它们的去处
    ///      全是金库的 `immutable`（池子、distributor、creator），量由金库自己的记账决定，
    ///      系列由金库自己的状态决定 —— **calldata 里没有一个字节能影响这三者**。
    ///      所以任何人、以任何顺序调它们，拿到货的都不可能是调用方本人：
    ///      货要么在金库、要么在池子、要么在发射那一笔定死的 creator 手里，
    ///      而 creator 那一份的上界是可存量的 10%。用户债权仍住在不可升级的 `ClearingPool` 里
    ///      （`docs/design.md` §10-25 的结构前提）。
    function test_writeSurface_hasNoUserClaimExit(address caller, uint96 amount) public {
        vm.assume(caller != address(0) && caller != address(vault) && caller != address(pool));
        // 🔴 caller != creator 是本条的**前提**而不是回避：断言的命题是「调用这个动作
        //    不会把货引到调用方自己手上」，而 creator 收到分成靠的是他的**身份**，不是他调用了什么 ——
        //    任何人替他调 `claimCreatorFee`，钱也只会到他那里（下一节的分成测试单独钉这件事）。
        vm.assume(caller != creator);

        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);
        vm.assume(caller != address(harness) && caller != address(distributor));

        stock.mint(address(harness), amount);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));

        portal.setCurve(meme, address(stock), 2e18);

        vm.startPrank(caller);
        harness.sync();
        harness.sampleTwap();
        (bool ok,) = address(harness).call{value: 0, gas: PING_GAS}("");
        assertTrue(ok);
        harness.processRevenue();
        harness.claimCreatorFee();
        vm.stopPrank();

        assertEq(stock.balanceOf(caller), 0, unicode"🔴 没有一个入口能把货交到调用方手上");
        assertEq(warrant.balanceOf(caller, seriesId), 0, unicode"🔴 权证也不行");
        assertEq(stock.allowance(address(harness), caller), 0, unicode"金库从不授权任何人来拉它的货");
        uint256 creatorGot = stock.balanceOf(creator);
        assertEq(
            stock.balanceOf(address(harness)) + stock.balanceOf(address(pool)) + creatorGot,
            amount,
            unicode"🔴 货要么在金库、要么在池子、要么在 creator 手里 —— 没有第四个去处"
        );
        assertLe(
            creatorGot,
            (uint256(amount) + 9) / 10,
            unicode"🔴 creator 那一份的上界是可存量的 10% —— 分成不可能吃掉抵押品"
        );
    }

    // ─────────────── creator 分成 claimCreatorFee（决策 49，第二条支出路径） ───────────────

    /// @notice 正常一轮：分成随存入入账，任何人触发领取，钱只到 creator。
    /// @dev 🔴 rule 010-3 的第二次应用也在这里钉住：领取之后基线落到真实剩余余额，
    ///      此后的新收入照常识别、照常存入 —— 这是「忘了减基线 ⟹ 金库死锁」那族错误在
    ///      第二条支出路径上的反证。
    function test_claimCreatorFee_paysTheCreatorAndKeepsTheVaultAlive() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.CreatorFeeClaimed(4e18);
        vm.prank(alice); // 🔴 不是 creator 自己 —— 触发人是谁不影响钱的去向
        uint256 claimed = harness.claimCreatorFee();

        assertEq(claimed, 4e18, unicode"按实测扣款计量");
        assertEq(stock.balanceOf(creator), 4e18, unicode"钱只到 creator");
        assertEq(stock.balanceOf(alice), 0, unicode"触发人一个 wei 都拿不到");
        assertEq(harness.creatorAccrued(), 0, unicode"债权清零");
        assertEq(stock.balanceOf(address(harness)), 4e18, "Protocol reserve remains");
        assertEq(harness.accountedQuote(), 4e18, unicode"🔴 rule 010-3：基线跟着支出落到真实余额");

        // 金库还活着：新收入照常识别、照常存入。
        stock.mint(address(harness), 10e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        assertEq(harness.accountedQuote(), 14e18, unicode"新收入识别得到");
        assertEq(harness.processRevenue(), 8e18, unicode"也存得出去");
        assertEq(harness.creatorAccrued(), 1e18, unicode"分成继续累计");
    }

    /// @notice 零累计时静默 no-op —— 与 `sync()` 的零差额、`processRevenue()` 的空跑同一条纪律。
    function test_claimCreatorFee_isASilentNoOpWhenNothingIsAccrued() public {
        vm.recordLogs();
        assertEq(vault.claimCreatorFee(), 0, unicode"没有累计 ⟹ 返回 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"空跑不该发任何事件");
    }

    /// @notice 🔴 **creator 被发行方拉黑：领取整笔如实回滚，报的是发行方自己的原因。**
    /// @dev 这正是分成做成 pull 而不是 push 的理由（决策 49-⑤）：拉黑只让 creator 自己领不到，
    ///      分成滞留金库（没有改址口，风险 creator 自担，决策 49-⑧），不连坐任何用户路径。
    ///      解除之后重领即可 —— 对 creator 而言只有延迟，没有账面损失。
    function test_claimCreatorFee_revertsWithTheIssuersOwnReasonWhenTheCreatorIsBlocked() public {
        GatedStockToken gated = new GatedStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(gated, expiry);

        gated.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        gated.setFrozen(true);
        vm.expectRevert(GatedStockToken.IssuerFrozen.selector);
        harness.claimCreatorFee();

        // 干净失败：债权、余额、基线三样一个没动。
        assertEq(harness.creatorAccrued(), 4e18, unicode"债权原样保留");
        assertEq(gated.balanceOf(address(harness)), 8e18, unicode"钱留在金库");
        assertEq(gated.balanceOf(creator), 0, unicode"creator 没收到");

        gated.setFrozen(false);
        assertEq(harness.claimCreatorFee(), 4e18, unicode"解除后重领即可");
        assertEq(gated.balanceOf(creator), 4e18);
    }

    /// @notice 表面成功却不扣款的转账**不消耗 creator 的债权**，也不伪造一条领取事件。
    /// @dev 与 `processRevenue` 的 `sent` 同一口径：一切以实测扣款为准。
    function test_claimCreatorFee_fakeTransferDoesNotConsumeTheCreatorsClaim() public {
        NoOpStockToken noOp = new NoOpStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(noOp, expiry);

        noOp.mint(address(harness), 25e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 2.5e18, unicode"前置条件：分成已入账");

        noOp.setNoOpTransfers(true);
        vm.recordLogs();
        assertEq(harness.claimCreatorFee(), 0, unicode"没扣款 ⟹ 领取量为 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"也不发 CreatorFeeClaimed");
        assertEq(harness.creatorAccrued(), 2.5e18, unicode"🔴 债权原样恢复，没有被假转账吃掉");

        noOp.setNoOpTransfers(false);
        assertEq(harness.claimCreatorFee(), 2.5e18, unicode"恢复后可重领");
        assertEq(noOp.balanceOf(creator), 2.5e18);
    }

    /// @notice 记账额高于真实余额时（发行方 `adminBurn` 掉了浮存的一部分），按 `min` 领取，
    ///         不会永久 revert 在余额不足上；余下的债权保留，等有钱时再领。
    function test_claimCreatorFee_paysMinOfAccruedAndBalanceWhenTheIssuerBurnedTheFloat() public {
        IssuerBurnableUnreadableStockToken issuerControlled = new IssuerBurnableUnreadableStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(issuerControlled, expiry);

        issuerControlled.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        issuerControlled.adminBurn(address(harness), 3e18);
        assertEq(harness.claimCreatorFee(), 2.5e18, unicode"只领得到真实存在的那一部分");
        assertEq(issuerControlled.balanceOf(creator), 2.5e18);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 1.5e18);
        assertEq(harness.accountedQuote(), 2.5e18, unicode"基线仍然落到真实余额");
    }

    /// @notice 🔴 **部分扣款不能让同一批收入被二次切分**（审计发现 M-01 的反证）。
    ///
    /// @dev 分成必须按**实测扣款**入账（`sent / 9`，满额 `cut` 封顶），不按请求量。
    ///      按请求量入账的话：请求 90 只走了 45，仍记 10 —— 剩下的 55 里下次又切一刀,
    ///      重试足够多次后 creator 能拿走接近整批的钱。这条测试跑两轮部分扣款，
    ///      逐轮钉实值，并断言累计分成始终不超过原始批次的 10%。
    function test_processRevenue_partialDebitAccruesTheFeeByMeasuredDebitNotByRequest() public {
        PartialDebitStockToken halfToken = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(halfToken, expiry);

        halfToken.mint(address(harness), 100e18);
        halfToken.setHalfDebit(true);

        // 第一轮：可存量 100，cut 上限 10，请求存入 90 —— 实际只走 45。
        // 45 对应的批次是 50，它的一成是 5：分成入账 5，不是 10。
        assertEq(harness.processRevenue(), 40e18, unicode"池子按实测增量铸造");
        assertEq(harness.creatorAccrued(), 5e18, unicode"🔴 分成按实测扣款入账（45/9），不按请求量");
        assertEq(halfToken.balanceOf(address(harness)), 60e18);
        assertEq(harness.accountedQuote(), 60e18, unicode"基线落到真实剩余余额");

        // 第二轮：可存量 55 − 5 = 50，请求 45 —— 实际走 22.5，再入账 2.5。
        assertEq(harness.processRevenue(), 20e18);
        assertEq(harness.creatorAccrued(), 7.5e18, unicode"逐轮只对实际走掉的部分切一成");

        // 🔴 上界：无论重试多少轮，累计分成 ≤ 原始批次的 10%。
        halfToken.setHalfDebit(false);
        harness.processRevenue();
        assertLe(harness.creatorAccrued(), 10e18, unicode"🔴 分成的上界钉死在整批的 10%");
        assertLe(
            harness.creatorAccrued() + halfToken.balanceOf(address(pool)),
            100e18,
            unicode"分成与入池抵押品合计不超过原始批次"
        );
        assertEq(warrant.balanceOf(address(distributor), seriesId), halfToken.balanceOf(address(pool)));
    }

    /// @notice 10% 分成的计算不能在合法的 ERC-20 最大余额上先于池子的 uint128 边界溢出。
    function test_processRevenue_feeCalculationDoesNotOverflowAtMaxBalance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);
        uint256 balance = type(uint256).max;
        uint256 cut = balance / 10;
        uint256 available = balance - cut;
        uint256 deposit = available - available / 9;
        stock.mint(address(harness), balance);

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, deposit));
        harness.processRevenue();
    }

    /// @notice 🔴 **上界不变式的随机序列版**（复审 N-03）：任意比例的部分扣款、任意穿插的领取，
    ///         累计分成（账面 + 已领）恒 ≤ 累计流入收入的 10%。
    ///
    /// @dev 固定序列的那条测试（上一条）钉的是逐轮实值；这一条钉的是**命题本身** ——
    ///      归纳论证是 `9 × confirmedCut ≤ sent` 逐轮累加得 `9F ≤ S`，
    ///      加上无凭空增发时的收入守恒 `S + F ≤ R`，得 `F ≤ R / 10`。
    ///      金额刻意含尘埃（+1 wei），扣款比例覆盖 0（假转账）到 10000（全额）。
    function testFuzz_creatorFee_totalNeverExceedsTenPercentOfInflow(uint256 seed) public {
        PartialDebitStockToken tok = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(tok, expiry);

        uint256 inflow;
        for (uint256 i = 0; i < 8; i++) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = (roll % 50e18) + 1; // 1 wei .. 50e18，含不被 9/10 整除的尘埃
            tok.mint(address(harness), amount);
            inflow += amount;
            tok.setDebitBps(uint16(roll % 10_001)); // 0 = 假转账 … 10000 = 全额
            harness.processRevenue();
            if (roll % 3 == 0) harness.claimCreatorFee(); // 领取穿插不改变 F（只在账面/已领间搬移）
        }
        // 收尾：全额扣款清空可存量，再领一次 —— 上界断言覆盖「全部处理完」的终态。
        tok.setDebitBps(10_000);
        harness.processRevenue();
        harness.claimCreatorFee();

        uint256 totalFee = harness.creatorAccrued() + tok.balanceOf(creator);
        assertLe(totalFee, inflow / 10, unicode"🔴 累计分成（账面 + 已领）不得超过累计流入的 10%");
        assertLe(
            totalFee + tok.balanceOf(address(pool)) + tok.balanceOf(address(harness)) - harness.creatorAccrued(),
            inflow,
            unicode"守恒：分成 + 入池 + 未处理余额 ≤ 总流入"
        );
    }

    /// @notice `claimCreatorFee` 的部分扣款：只消耗实际走掉的债权，四样读数一起钉。
    function test_claimCreatorFee_partialDebitConsumesOnlyTheMeasuredDebit() public {
        PartialDebitStockToken halfToken = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(halfToken, expiry);

        halfToken.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        halfToken.setHalfDebit(true);
        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.CreatorFeeClaimed(2e18);
        assertEq(harness.claimCreatorFee(), 2e18, unicode"返回值 = 实测扣款");
        assertEq(halfToken.balanceOf(creator), 2e18, unicode"creator 实收（本替身收方不再扣）");
        assertEq(harness.creatorAccrued(), 2e18, unicode"债权只消耗实际走掉的那一半");
        assertEq(harness.accountedQuote(), halfToken.balanceOf(address(harness)), unicode"基线 = 真实余额");

        halfToken.setHalfDebit(false);
        assertEq(harness.claimCreatorFee(), 2e18, unicode"余下的债权照常可领");
        assertEq(harness.creatorAccrued(), 0);
    }

    /// @notice 发送方额外手续费由真实余额基线承担，但不能伪装成 creator 收入或债权。
    function test_claimCreatorFee_senderFeeIsNotCountedAsCreatorIncome() public {
        SenderPaysFeeStockToken senderFeeToken = new SenderPaysFeeStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(senderFeeToken, expiry);

        senderFeeToken.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        senderFeeToken.mint(address(harness), 1e18);
        senderFeeToken.setSenderFeeBps(1000);
        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.CreatorFeeClaimed(4e18);
        assertEq(harness.claimCreatorFee(), 4e18, unicode"claimed 只表示实际消耗的 creator 债权");

        assertEq(senderFeeToken.balanceOf(creator), 4e18, unicode"creator 收到完整名义额");
        assertEq(
            senderFeeToken.balanceOf(senderFeeToken.TAX_SINK()), 0.4e18, unicode"额外扣款是发行方手续费"
        );
        assertEq(harness.creatorAccrued(), 0, unicode"creator 债权恰好清零，不把手续费算成分成");
        assertEq(senderFeeToken.balanceOf(address(harness)), 4.6e18, unicode"金库真实减少 4.4");
        assertEq(harness.accountedQuote(), 4.6e18, unicode"基线反映含手续费的完整余额变化");
    }

    /// @notice 🔴 已有 creator 浮存时，`RevenueDeferred` 发的是**净值** —— 链下拿它当「卡住金额」，
    ///         把浮存算进去会多报 10% 量级的假卡款。
    function test_revenueDeferred_reportsTheNetDepositableNotTheRawBalance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：浮存 4");

        vm.warp(uint256(expiry)); // 系列到期 → 下一笔走递延边
        stock.mint(address(harness), 10e18);

        vm.expectEmit(false, false, false, true, address(harness));
        emit WarrantVault.RevenueDeferred(9e18, expiry);
        assertEq(harness.processRevenue(), 0, unicode"到期递延");
        assertEq(stock.balanceOf(address(harness)), 18e18, unicode"raw 余额是 14 —— 事件刻意没发它");
    }

    /// @notice 🔴 **反向互入也被锁挡住**：`processRevenue` 的池子拉款回调里重入 `claimCreatorFee`。
    ///
    /// @dev 危险形状与正向对称：拉款还没生效（余额未减）时回调领取，会拿着「余额满、
    ///      债权在」的中间态把浮存转走，随后外层再按已经失真的余额记账。
    function test_processRevenue_reentrantClaimCreatorFeeIsLockedOut() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        WarrantVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);

        // 先攒出浮存（未布防），再布防打第二轮。
        hostile.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        hostile.armReentrancy(address(harness), abi.encodeCall(WarrantVault.claimCreatorFee, ()));
        hostile.mint(address(harness), 10e18);
        assertEq(harness.processRevenue(), 8e18, unicode"外层存入照常成功");

        assertGt(hostile.reentryAttempts(), 0, unicode"再入一次都没触发，这条测试是空的");
        assertFalse(hostile.reentrySucceeded(), unicode"🔴 内层 claimCreatorFee 必须被锁挡住");
        assertEq(
            hostile.reentryError(),
            abi.encodeWithSignature("Error(string)", unicode"Reentrant call / 重入调用"),
            unicode"拒绝的原因是锁，不是别的什么"
        );
        assertEq(hostile.balanceOf(creator), 0, unicode"浮存一分没被中间态转走");
        assertEq(harness.creatorAccrued(), 5e18, unicode"两轮分成完整入账（4 + 1）");
    }

    /// @notice 🔴 **两条支出路径互入被 transient 锁挡住** —— 决策 49-⑥ 的反证。
    ///
    /// @dev 危险的形状：`claimCreatorFee` 的转账回调（余额未减、`creatorAccrued` 已扣）里
    ///      重入 `processRevenue`，它会把 creator 那份也算进可存量存掉。
    ///      注入器只记录不冒泡，所以外层照常成功 —— 断言的是**内层确实被拒**且账目最终正确。
    function test_claimCreatorFee_reentrantProcessRevenueIsLockedOut() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        WarrantVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);

        hostile.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"前置条件：分成已入账");

        hostile.armReentrancy(address(harness), abi.encodeCall(WarrantVault.processRevenue, ()));
        assertEq(harness.claimCreatorFee(), 4e18, unicode"外层领取照常成功");

        assertGt(hostile.reentryAttempts(), 0, unicode"再入一次都没触发，这条测试是空的");
        assertFalse(hostile.reentrySucceeded(), unicode"🔴 内层 processRevenue 必须被锁挡住");
        assertEq(
            hostile.reentryError(),
            abi.encodeWithSignature("Error(string)", unicode"Reentrant call / 重入调用"),
            unicode"拒绝的原因是锁，不是别的什么"
        );
        assertEq(hostile.balanceOf(creator), 4e18, unicode"钱一分不多不少地到了 creator");
        assertEq(harness.creatorAccrued(), 0, unicode"债权清零");
    }

    // ──────────────────────────── description() ────────────────────────────

    /// @dev `description()` 曾经是 Flap 规范强制的那个动态描述；规范义务已随决策 39 消失，
    ///      而**函数与这几条断言都留下了** —— 它渲染的是 {WarrantVault.inTransit}，
    ///      也就是「此刻有多少抵押品还停在金库里」，那个问题在 D0 之后并没有变得不重要。
    ///      ⚠️ 与它同期消失的 `vaultUISchema()` 没有留下：那是 Flap UI 的自动渲染协议，
    ///      我们自建前端，没有第二个消费者 —— 连同它的两条断言一并删除（issue #58）。
    ///
    ///      要求 `description()` **随状态变化**，且至少反映系列是否已开、本周 strike、
    ///      上次收入处理时间。系列三态 ×「从未识别 / 有在途」两态 = 六种形状，这里逐一断言它们两两不同，
    ///      并且该出现的数字真的出现在串里。第三种收入态（**在途为零**，M2-3 存完之后）
    ///      由下一条单独钉住 —— 它是在途窗口的实时读数，值得自己一条。
    ///      开系列那两个字段由 `openSeries()` 写入；本文件用 {WarrantVaultHarness} 直接摆出那个状态。
    function test_description_reflectsSeriesStateAndRevenue() public {
        WarrantVaultHarness harness = _deployHarness(address(stock));

        uint128 strike = STRIKE;
        uint64 expiry = uint64(block.timestamp + 7 days);

        string[6] memory shapes;

        shapes[0] = harness.description();
        assertTrue(_hasSubstring(shapes[0], "no series open yet"), unicode"未开系列");
        assertTrue(_hasSubstring(shapes[0], unicode"尚未见到任何收入"), unicode"未见到收入");

        stock.mint(address(harness), 42e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));
        shapes[1] = harness.description();
        assertTrue(_hasSubstring(shapes[1], "37800000000000000000"), unicode"已识别收入应当出现在串里");
        assertTrue(_hasSubstring(shapes[1], vm.toString(block.timestamp)), unicode"处理时刻应当出现在串里");

        harness.harnessWriteSeriesFieldsWithoutOpening(strike, expiry);
        shapes[2] = harness.description();
        assertTrue(_hasSubstring(shapes[2], "1850000000000000000000"), unicode"strike 应当出现在串里");
        assertTrue(_hasSubstring(shapes[2], vm.toString(uint256(expiry))), unicode"到期应当出现在串里");
        assertTrue(_hasSubstring(shapes[2], unicode"本周系列已开"), unicode"已开");

        vm.warp(uint256(expiry) + 1);
        shapes[3] = harness.description();
        assertTrue(_hasSubstring(shapes[3], unicode"到期"), unicode"已到期");

        // 另外两种形状：已开 / 已到期 且尚未识别收入。
        WarrantVaultHarness fresh = _deployHarness(address(stock));
        fresh.harnessWriteSeriesFieldsWithoutOpening(strike, uint64(block.timestamp + 7 days));
        shapes[4] = fresh.description();
        vm.warp(block.timestamp + 8 days);
        shapes[5] = fresh.description();

        for (uint256 i = 0; i < shapes.length; i++) {
            assertGt(bytes(shapes[i]).length, 0);
            for (uint256 j = i + 1; j < shapes.length; j++) {
                assertTrue(
                    keccak256(bytes(shapes[i])) != keccak256(bytes(shapes[j])),
                    string.concat(
                        unicode"两种状态渲染成了同一句话：", vm.toString(i), " / ", vm.toString(j)
                    )
                );
            }
        }
    }

    /// @notice 🔴 `description()` 的第三种收入态：**在途为零** —— 在途窗口的实时读数。
    ///
    /// @dev 前端把 `description()` 当状态横幅轮询，而这句话回答的是审计者最关心的那个问题：
    ///      「此刻有多少抵押品还停在金库里、没进池子？」存入之前它是一个数，
    ///      存入之后必须变成「没有」——而不是继续渲染成「已识别收入 0」那种既别扭又容易被读反的说法。
    function test_description_reportsNothingInTransitOnceRevenueHasBeenDeposited() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 42e18);
        assertTrue(_ping(WarrantVault(payable(address(harness)))));

        string memory inTransit = harness.description();
        assertTrue(
            _hasSubstring(inTransit, unicode"在途收入 37800000000000000000 raw"), unicode"存入之前：在途 42"
        );

        harness.processRevenue();

        string memory drained = harness.description();
        assertTrue(_hasSubstring(drained, unicode"当前没有在途收入"), unicode"存入之后：在途归零");
        assertTrue(_hasSubstring(drained, "nothing in transit"), unicode"英文半句同样要变");
        assertTrue(
            keccak256(bytes(inTransit)) != keccak256(bytes(drained)),
            unicode"两种在途状态渲染成了同一句话"
        );
    }

    // ───────────────────────── 原生 BNB 计价档（C2，§7.14）─────────────────────────

    event RevenueRecognized(uint256 newRevenue, uint256 accountedTotal);

    /// @notice 🔴 **原生到账被识别为收入**：TaxProcessor dispatch 给金库的是原生 BNB，
    ///         金库在记账前把它包进 WBNB，余额差记账照常把 WBNB 增量识别成收入。
    function test_native_wrapsIncomingBnbAndRecognisesItAsRevenue() public {
        (WarrantVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        // 原生 BNB 到账（TaxProcessor.dispatch 的等价物：一笔原生转账触发 receive）。
        vm.deal(address(this), 30e18);
        (bool sent,) = address(harness).call{value: 30e18}("");
        assertTrue(sent, unicode"receive 收下原生 BNB，不 revert");
        assertEq(address(harness).balance, 30e18, unicode"懒包装：receive 里不包，原生币先躺着");
        assertEq(wbnb.balanceOf(address(harness)), 0, unicode"此刻还没有 WBNB");

        assertEq(harness.accountedNative(), 30e18);
        // Wrapping changes asset form without recognizing the same revenue twice.
        vm.recordLogs();
        harness.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != keccak256("RevenueRecognized(uint256,uint256)"), "wrapping double-counted revenue"
            );
        }

        assertEq(address(harness).balance, 0, unicode"原生币已被包装光");
        assertEq(wbnb.balanceOf(address(harness)), 30e18, unicode"🔴 30 BNB → 30 WBNB（1:1）");
        assertEq(harness.accountedQuote(), 30e18, unicode"基线推到 WBNB 收入");
    }

    /// @notice 🔴 **非原生档不 wrap**：ERC20 计价金库被强塞原生 BNB，`_wrapsNative == false`，
    ///         `_wrapNative` 是 no-op —— 原生币不被包装、不被计入收入（否则任何人强塞原生币就能
    ///         凭空给金库注入收入、多铸权证）。
    function test_native_nonNativeVaultDoesNotWrapForceSentNative() public {
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));

        vm.deal(address(harness), 30e18); // 强塞原生币（非原生档）
        harness.sync();

        assertEq(address(harness).balance, 30e18, unicode"原生币原封不动，没被包装");
        assertEq(stock.balanceOf(address(harness)), 0, unicode"计价币（stock）余额没变");
        assertEq(harness.accountedQuote(), 0, unicode"🔴 强塞的原生币没被当成收入");
    }

    /// @notice 🔴 **inTransit 计未包装原生**：懒包装下原生币到账后、sync 前躺在金库里，
    ///         `inTransit` 要把它算进去，否则两次 sync 之间前端看到的在途凭空少一块。
    function test_native_inTransitCountsUnwrappedNativeThenWbnbAfterSync() public {
        (WarrantVaultHarness harness,,) = _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        vm.deal(address(this), 12e18);
        (bool sent,) = address(harness).call{value: 12e18}("");
        assertTrue(sent);

        // sync 之前：原生币未包装，但 inTransit 必须已经算上它。
        (uint256 before, bool exactBefore) = harness.inTransit();
        assertTrue(exactBefore);
        assertEq(before, 10.8e18, unicode"🔴 未包装的原生币也算在途");

        harness.sync();

        // sync 之后：钱变成了 WBNB，inTransit 读数不变（同量纲、同一笔）。
        (uint256 afterSync, bool exactAfter) = harness.inTransit();
        assertTrue(exactAfter);
        assertEq(afterSync, 10.8e18, unicode"包装前后在途读数一致");
    }

    /// @notice **原生档端到端**：原生到账 → processRevenue 包装 → 九成 WBNB 进池、一成记 creator。
    function test_native_processRevenueWrapsThenDepositsToPool() public {
        (WarrantVaultHarness harness, WNativeMock wbnb, uint256 seriesId) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        vm.deal(address(this), 40e18);
        (bool sent,) = address(harness).call{value: 40e18}("");
        assertTrue(sent);

        vm.warp(block.timestamp + 1 hours);
        uint256 minted = harness.processRevenue();

        assertEq(address(harness).balance, 0, unicode"原生币包装光");
        assertEq(minted, 32e18, unicode"可存量的九成进池（40 → 36 WBNB）");
        assertEq(wbnb.balanceOf(address(pool)), 32e18, unicode"抵押品（WBNB）到了池子");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 32e18, unicode"权证铸给 distributor");
        assertEq(harness.creatorAccrued(), 4e18, unicode"一成记给 creator（WBNB）");
        assertEq(wbnb.balanceOf(address(harness)), 8e18, unicode"金库里只剩 creator 浮存");
    }

    function test_native_quoteDiscoverySeparatesCollateral() public {
        (WarrantVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        assertEq(harness.vaultQuoteToken(), address(0));
        assertEq(harness.collateralToken(), address(wbnb));
        assertEq(harness.vaultSpecVersion(), "v3");
    }

    function test_emergency_creatorLossIsPermanentAndFutureRevenueAccruesFresh() public {
        vm.chainId(56);
        (WarrantVaultHarness harness, uint256 id) =
            _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));
        stock.mint(address(harness), 100e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 10e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(stock), alice);
        assertEq(stock.balanceOf(alice), 20e18);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 10e18);
        assertEq(stock.balanceOf(address(pool)), 80e18);
        assertEq(warrant.balanceOf(address(distributor), id), 80e18);
        stock.mint(address(harness), 20e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 2e18);
        assertEq(harness.creatorImpaired(), 10e18);
    }

    function test_emergency_onlyGuardianAndNonzeroRecipient() public {
        vm.chainId(56);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vault.emergencyWithdrawNative(alice);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(bytes(unicode"Recipient is zero / 接收地址为零"));
        vault.emergencyWithdrawToken(address(stock), address(0));
    }

    function test_emergency_nativeWithdrawalPreservesWrappedCreatorReserve() public {
        vm.chainId(56);
        (WarrantVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.deal(address(harness), 3e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawNative(alice);
        uint256 supportedCreator = uint256(20e18) * 10e18 / 20.3e18;
        assertEq(harness.creatorAccrued(), supportedCreator);
        assertEq(harness.creatorImpaired(), 10e18 - supportedCreator);
        assertEq(wbnb.balanceOf(address(harness)), 20e18);
        assertEq(harness.accountedNative(), 0);
    }

    function test_emergency_nativeRecipientCallbackCannotReenterAndReturnedIncomeSurvives() public {
        vm.chainId(56);
        (WarrantVaultHarness harness,,) = _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        EmergencyNativeReceiver receiver = new EmergencyNativeReceiver(harness);
        vm.deal(address(harness), 10e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawNative(address(receiver));
        assertFalse(receiver.reentered());
        assertFalse(receiver.sampled());
        assertFalse(receiver.opened());
        assertEq(address(harness).balance, 5e18);
        assertEq(harness.accountedNative(), 5e18);
        (uint256 held, bool exact) = harness.inTransit();
        assertTrue(exact);
        assertEq(held, 4.5e18);
        harness.sync();
        assertEq(harness.accountedNative(), 0);
        assertEq(harness.accountedQuote(), 5e18);
    }

    function test_emergency_partialDebitRollsBackWithoutRecordingLoss() public {
        vm.chainId(56);
        PartialDebitStockToken partialToken = new PartialDebitStockToken();
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(partialToken, uint64(block.timestamp + 7 days));
        partialToken.mint(address(harness), 100e18);
        harness.processRevenue();
        partialToken.setHalfDebit(true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Incomplete quote withdrawal / 收入币全余额提款未完成");
        harness.emergencyWithdrawToken(address(partialToken), alice);
        assertEq(partialToken.balanceOf(address(harness)), 20e18);
        assertEq(partialToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.creatorClaimed(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_emergency_unrelatedTokenDoesNotImpairCollateral() public {
        vm.chainId(56);
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));
        stock.mint(address(harness), 100e18);
        harness.processRevenue();
        StockToken unrelated = new StockToken();
        unrelated.mint(address(harness), 7e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(unrelated), alice);
        assertEq(unrelated.balanceOf(alice), 7e18);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_schemaDescribesPermissionsAndRawUnits() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.methods.length, 35);
        uint256 writes;
        for (uint256 i; i < schema.methods.length; ++i) {
            if (schema.methods[i].isWriteMethod) ++writes;
            for (uint256 j; j < schema.methods[i].outputs.length; ++j) {
                assertEq(schema.methods[i].outputs[j].decimals, 0);
            }
        }
        assertEq(writes, 8);
        assertTrue(_hasSubstring(schema.methods[23].description, "Guardian only"));
        assertTrue(_hasSubstring(schema.methods[24].description, "Guardian only"));
        (uint8 decimals, bool readable) = vault.collateralDecimals();
        assertTrue(readable);
        assertEq(decimals, stock.decimals());
    }

    function test_emergency_unreadableQuoteRevertsWithoutLosingAssets() public {
        vm.chainId(56);
        IssuerBurnableUnreadableStockToken unreadable = new IssuerBurnableUnreadableStockToken();
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(unreadable, uint64(block.timestamp + 7 days));
        unreadable.mint(address(harness), 100e18);
        harness.processRevenue();
        unreadable.setBalanceUnreadable(true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Token balance unreadable / 代币余额不可读");
        harness.emergencyWithdrawToken(address(unreadable), alice);
        unreadable.setBalanceUnreadable(false);
        assertEq(unreadable.balanceOf(address(harness)), 20e18);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
    }

    function test_emergency_quoteCallbackNewDepositRollsBackInsteadOfRepayingOldLoss() public {
        vm.chainId(56);
        EmergencyCallbackStockToken callbackToken = new EmergencyCallbackStockToken();
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(callbackToken, uint64(block.timestamp + 7 days));
        callbackToken.mint(address(harness), 100e18);
        harness.processRevenue();
        callbackToken.configure(address(harness), true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Quote wake during withdrawal / 提款期间收到币种回调");
        harness.emergencyWithdrawToken(address(callbackToken), alice);
        assertEq(callbackToken.balanceOf(address(harness)), 20e18);
        assertEq(callbackToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_emergency_quoteCallbackWithoutPingRollsBackNewIncomeAndWithdrawal() public {
        vm.chainId(56);
        EmergencyCallbackStockToken callbackToken = new EmergencyCallbackStockToken();
        (WarrantVaultHarness harness,) = _deployHarnessWithOpenSeries(callbackToken, uint64(block.timestamp + 7 days));
        callbackToken.mint(address(harness), 100e18);
        harness.processRevenue();
        callbackToken.configure(address(harness), false);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Incomplete quote withdrawal / 收入币全余额提款未完成");
        harness.emergencyWithdrawToken(address(callbackToken), alice);
        assertEq(callbackToken.balanceOf(address(harness)), 20e18);
        assertEq(callbackToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
    }

    function test_emergency_nativeReturnedDuringTokenWithdrawalDoesNotRepayOldImpairment() public {
        vm.chainId(56);
        EmergencyNativeCallbackWbnb wbnb = new EmergencyNativeCallbackWbnb();
        WarrantVaultHarness harness =
            new WarrantVaultHarness(pool, address(distributor), address(portal), meme, address(wbnb), creator, true);
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        wbnb.configure(address(harness));
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(wbnb), alice);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 10e18);
        assertEq(harness.accountedNative(), 1e18);
        assertEq(address(harness).balance, 1e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 0.1e18);
        assertEq(harness.creatorImpaired(), 10e18);
    }

    function test_collateralDecimalsSixEightEighteenPreserveRawUnitEconomics() public {
        uint8[3] memory decimalsValues = [uint8(6), uint8(8), uint8(18)];
        for (uint256 i; i < decimalsValues.length; ++i) {
            DecimalStockToken token = new DecimalStockToken(decimalsValues[i]);
            address project = address(uint160(0x1000 + i));
            WarrantVaultHarness harness = new WarrantVaultHarness(
                pool, address(distributor), address(portal), project, address(token), creator, false
            );
            factory.bind(project, address(harness));
            harness.harnessOpenSeries(STRIKE, uint64(block.timestamp + 7 days));
            uint256 unit = 10 ** decimalsValues[i];
            token.mint(address(harness), 100 * unit);
            assertEq(harness.processRevenue(), 80 * unit);
            assertEq(harness.creatorAccrued(), 10 * unit);
            (uint8 decimals, bool readable) = harness.collateralDecimals();
            assertTrue(readable);
            assertEq(decimals, decimalsValues[i]);
        }
    }

    function test_emergency_nativeSelfRecipientRejectedWithoutChangingReserveOrIncome() public {
        vm.chainId(56);
        (WarrantVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.prank(address(harness));
        wbnb.withdraw(10e18);
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        vm.recordLogs();
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Invalid withdrawal recipient / 提款接收地址无效");
        harness.emergencyWithdrawNative(address(harness));
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.creatorImpaired(), 10e18 - uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.accountedNative(), 10e18);
        assertEq(address(harness).balance, 10e18);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_emergency_nativeCollateralRecipientRejectedWithoutConversionOrImpairment() public {
        vm.chainId(56);
        (WarrantVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.prank(address(harness));
        wbnb.withdraw(10e18);
        vm.recordLogs();
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Invalid withdrawal recipient / 提款接收地址无效");
        harness.emergencyWithdrawNative(address(wbnb));
        assertEq(address(harness).balance, 10e18);
        assertEq(wbnb.balanceOf(address(harness)), 10e18);
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.creatorImpaired(), 10e18 - uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.accountedNative(), 10e18);
        assertEq(vm.getRecordedLogs().length, 0);
    }
}

contract EmergencyNativeReceiver {
    WarrantVault private immutable vault;
    bool public reentered;
    bool public sampled;
    bool public opened;

    constructor(WarrantVault vault_) {
        vault = vault_;
    }

    receive() external payable {
        (reentered,) = address(vault).call(abi.encodeCall(WarrantVault.processRevenue, ()));
        (sampled,) = address(vault).call(abi.encodeCall(WarrantVault.sampleTwap, ()));
        (opened,) = address(vault).call(abi.encodeCall(WarrantVault.openSeries, ()));
        (bool returned,) = address(vault).call{value: msg.value / 2}("");
        require(returned, "refund failed");
    }
}

contract EmergencyCallbackStockToken is StockToken {
    address private target;
    bool private wake;

    function configure(address target_, bool wake_) external {
        target = target_;
        wake = wake_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == target && target != address(0)) {
            super._update(address(0), target, 5e18);
            if (wake) {
                (bool ok,) = target.call("");
                require(ok, "ping failed");
            }
        }
    }
}

contract EmergencyNativeCallbackWbnb is WNativeMock {
    address private target;

    function configure(address target_) external {
        target = target_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == target && target != address(0)) {
            target = address(0);
            (bool ok,) = from.call{value: 1e18}("");
            require(ok, "native income failed");
        }
    }
}

contract DecimalStockToken is StockToken {
    uint8 private immutable precision;

    constructor(uint8 precision_) {
        precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }
}
