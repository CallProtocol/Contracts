// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {WarrantVault} from "../../src/WarrantVault.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @title RobinhoodOpenSeriesForkTest
/// @notice 🔴 **M2-4 那条「必须在分叉上跑」的验收（issue #36）：真实 GME + 真实 TWAP 读数下开出系列，
///         `seriesId` 与 `pool.seriesIdOf(meme, stock, expiry)` 一致。**
///
/// 本地那份（`test/WarrantVaultOpenSeries.t.sol`）已经把周五对齐、折让取整、幂等、窗口与
/// 停发可观测逐条钉过了 —— 用的是我们自己写的 Portal 替身。这里只做**替身证明不了的那几件事**：
///
/// 1. 🔴 **strike 是从真实联合曲线上读出来的**。替身的 `price` 是我们摆的，量级与精度都由我们决定；
///    真实 Portal 的 `price` 是 `k / (1e9 + h - s)²` 这条曲线的边际价，18 位定点、以 GME 的最小单位计。
///    「1e36 / price」这一步的量纲只有在**它**身上才算被验过。
/// 2. 🔴 **计价币真的是 GME**。本链带 GME 计价的发币在 M2-2 才第一次跑通（issue #23 的补充实测），
///    而整条 strike 链路建在「收入币种 = 绑定的股票」这个前提上（决策 12）。
///    这里每一次都真的从 `Portal.newTokenV6` 发一只出来。
/// 3. 🔴 **开出来的系列，真实 GME 存得进去**。`openSeries` 与 `processRevenue` 是两张票写的两段代码，
///    它们靠 `strike != 0 && now < seriesExpiry` 这条不变式衔接；在真实标的上跑一遍，
///    才排除得掉「系列开出来了但收入路径认不出它」这类接线错误。
///
/// | 组件 | 用什么 |
/// |---|---|
/// | 价格来源 | **真实 Flap Portal**（`0x26605f…`）与它上面真实的联合曲线 |
/// | 服务的 MEME | 每条测试**当场发**的一只 GME 计价 `TOKEN_TAXED_V3` |
/// | 收入币种 / 抵押品 | **真实 GME** |
/// | 金库 / 池子 / 权证 / 分发 / 注册表 | 真实部署 + 两处绑定（issue #5 的测试缝） |
contract RobinhoodOpenSeriesForkTest is ForkTest, FlapGmeLaunch {
    /// @dev 🔴 **独立写死**：一周的秒数，以及周五 21:00 UTC 的周内偏移（1 天 + 21 小时）。
    ///      合约那边写的是 `EXPIRY_OFFSET = 45 hours`；这里写的是 `162000`。
    ///      两个数没有共同来源，对上了才算证明。
    uint256 internal constant WEEK_SECONDS = 604_800;
    uint256 internal constant FRIDAY_2100_OFFSET = 162_000;

    /// @dev 决策 14：k = 0.8。同样独立写死，不从金库读。
    uint256 internal constant K_NUMERATOR = 4;
    uint256 internal constant K_DENOMINATOR = 5;

    IERC20 internal gme;

    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    address internal keeper = makeAddr("trigger service");
    address internal holder = makeAddr("holder");

    function setUp() public {
        ForkTarget memory target = ForkConfig.robinhood();
        // 探针落在 Portal 上 —— 该高度有没有状态，要在真正会被读的合约上问。
        target.probe = ForkConfig.FLAP_PORTAL;
        selectFork(target);

        gme = IERC20(ForkConfig.GME);

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev 与工厂将要做的事同形：**一行 `new`** —— 决策 39-A3 之后金库不可升级，
    ///      六个参数（决策 49 起含 creator）在构造那一笔里定死，
    ///      其中取价 Portal 就是本链真实的 Flap `Portal`。
    function _deployVault(address memeToken) internal returns (WarrantVault vault) {
        vault = new WarrantVault(
            pool,
            address(distributor),
            ForkConfig.FLAP_PORTAL,
            memeToken,
            ForkConfig.GME,
            makeAddr("creator"),
            false,
            address(0xfee)
        );
    }

    /// @dev 一只发好、铺好环、可以开系列的金库。
    function _readyVault() internal returns (WarrantVault vault, address memeToken) {
        memeToken = _launchGmeQuotedToken();
        vault = _deployVault(memeToken);
        factory.bind(memeToken, address(vault));
        assertEq(factory.registry().vaultOf(memeToken), address(vault), unicode"新发 MEME 绑定到这只金库");
        assertTrue(_fillTwapRing(vault, keeper), unicode"每小时那一条都该写进去");
    }

    // ─────────────────── 前置：跑的确实是那几个真合约 ───────────────────

    function test_theChainAndTheQuoteTokenAreReal() public view {
        assertEq(block.chainid, ForkConfig.ROBINHOOD_CHAIN_ID, unicode"这份测试只在 Robinhood Chain 上有意义");
        assertGt(ForkConfig.FLAP_PORTAL.code.length, 0, unicode"Portal 地址上应当有代码");
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 应当有代码");
        assertEq(
            address(pool.vaultRegistry()), address(factory.registry()), unicode"池子读的是工厂写入的身份根"
        );
        assertTrue(
            factory.registry().isFactory(address(factory)), unicode"身份根的名单里有本 fixture 的工厂"
        );
    }

    // ─────────────────── 🔴 本票的分叉验收 ───────────────────

    /// @notice 🔴 **验收最后一条**：真实 GME + 真实 TWAP 读数下开出系列，
    ///         `seriesId` 与 `pool.seriesIdOf(meme, stock, expiry)` 一致。
    ///
    /// @dev 四个断言各挡一件不同的事，而且期望值全部**独立算出**，不从被测合约取：
    ///
    ///      | 断言 | 挡什么 |
    ///      |---|---|
    ///      | `seriesId` 三处一致 | 金库把钱存进一个**不存在的**系列，或者更糟，存进别人的 |
    ///      | expiry 的周内偏移 | 到期没落在周五 21:00 UTC —— 整个到期日历与前端对不上 |
    ///      | expiry − now ≥ 7 天 | 权证一出生就到期 |
    ///      | strike == 1e36/price × 0.8 | 🔴 量纲错一个数量级 —— 本票最贵的那个错 |
    function test_openSeriesPricesFromTheRealCurveAndAgreesWithThePool() public {
        (WarrantVault vault, address memeToken) = _readyVault();

        // 真实曲线上的边际价，直接从 Portal 镜头读 —— 反演在测试里自己做一遍。
        uint256 flapPrice = _tokenState(memeToken).price;
        assertGt(flapPrice, 0, unicode"刚发出来的代币应当在曲线上，price 非零");
        uint256 expectedTwap = uint256(1e36) / flapPrice;

        (uint256 twapStatus, uint256 twapPrice) = vault.twap();
        assertEq(twapStatus, 0, unicode"环铺满了，读数该可用");
        assertEq(twapPrice, expectedTwap, unicode"🔴 读数就是 1e36 / Flap 的 price");

        vm.prank(keeper);
        (uint256 seriesId, bool opened) = vault.openSeries();
        assertTrue(opened, unicode"真实链上应当开得出来");

        uint64 expiry = vault.seriesExpiry();

        // ① seriesId：金库的返回值、池子的公式、以及测试独立算的那一份，三者相等。
        assertEq(
            seriesId,
            pool.seriesIdOf(memeToken, ForkConfig.GME, expiry),
            unicode"🔴 seriesId 与 pool.seriesIdOf(meme, stock, expiry) 一致"
        );
        assertEq(
            seriesId,
            uint256(keccak256(abi.encode(memeToken, ForkConfig.GME, expiry))),
            unicode"独立算一份三元组哈希，同样对得上"
        );

        // ② 到期：周五 21:00 UTC，且寿命 ≥7 天。
        assertEq(uint256(expiry) % WEEK_SECONDS, FRIDAY_2100_OFFSET, unicode"🔴 周五 21:00 UTC");
        assertGe(uint256(expiry) - block.timestamp, 7 days, unicode"🔴 寿命不得短于 7 天");
        assertLt(uint256(expiry) - block.timestamp, 14 days);

        // ③ 行权价：TWAP × 0.8，用独立写死的 4/5 复算。
        uint128 strike = vault.strike();
        assertEq(uint256(strike), (expectedTwap * K_NUMERATOR) / K_DENOMINATOR, unicode"🔴 strike = TWAP × 0.8");
        assertEq(pool.series(seriesId).strike, strike, unicode"池子里锁下的是同一个数");
        assertEq(pool.series(seriesId).vault, address(vault), unicode"本金库就是该系列的金库");
        assertEq(pool.series(seriesId).stockToken, ForkConfig.GME, unicode"抵押品是真实 GME");

        console2.log(
            string.concat(
                unicode"  真实曲线 price=",
                vm.toString(flapPrice),
                unicode"  TWAP=",
                vm.toString(twapPrice),
                unicode"  strike=",
                vm.toString(uint256(strike))
            )
        );
        console2.log(
            string.concat(unicode"  expiry=", vm.toString(uint256(expiry)), unicode"  seriesId=", vm.toString(seriesId))
        );
    }

    /// @notice 🔴 开出来的系列，**真实 GME 存得进去** —— 两张票写的两段代码在真实标的上接得上。
    ///
    /// @dev `openSeries`（M2-4）与 `processRevenue`（M2-3）靠 `strike != 0 && now < seriesExpiry`
    ///      这条不变式衔接。本地测试用的是我们自己写的 ERC-20；这里换成真实 GME
    ///      （BeaconProxy → `Stock`，带发行方的修饰器与它自己的记账），
    ///      而且走的是「转账 + 协议 ping」这条真实唤醒路径，不是直接改余额。
    function test_theSeriesJustOpenedAcceptsRealGmeRevenue() public {
        (WarrantVault vault,) = _readyVault();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        // 税收到账：转账不给收款方执行机会，靠协议补的那记 ping 唤醒金库。
        deal(ForkConfig.GME, holder, 4e18);
        vm.prank(holder);
        gme.transfer(address(vault), 4e18);
        (bool pinged,) = address(vault).call{value: 0, gas: 500_000}("");
        assertTrue(pinged, unicode"ping 应当成功");

        uint256 held = gme.balanceOf(address(vault));
        assertGt(held, 0, unicode"真实 GME 到账了");

        vm.prank(keeper);
        uint256 minted = vault.processRevenue();

        assertEq(
            minted,
            held - held / 10 - (held - held / 10) / 9,
            unicode"1:1 全额抵押：入池的九成实测增量就是铸造量（决策 49）"
        );
        assertEq(warrant.balanceOf(address(distributor), seriesId), minted, unicode"权证铸给了分发合约");
        assertEq(gme.balanceOf(address(pool)), minted, unicode"抵押品进了池子");
        assertEq(
            gme.balanceOf(address(vault)),
            held / 10 + (held - held / 10) / 9,
            unicode"金库里只剩 creator 浮存 —— 「在途」窗口关上了"
        );
        (uint256 inTransitNow, bool exact) = vault.inTransit();
        assertTrue(exact);
        assertEq(inTransitNow, 0, unicode"R4 的实时读数：在途归零，浮存已净掉");
    }

    /// @notice 真实链上重复调用同样开不出第二个系列，而且**不 revert**。
    /// @dev 幂等的完整时间轴在本地那份；这里只确认真实 Portal 与真实池子下这条边同样是干净返回 ——
    ///      它决定的是 Trigger Service 的重试要不要当成告警。
    function test_openSeriesIsIdempotentOnTheRealChain() public {
        (WarrantVault vault,) = _readyVault();

        vm.prank(keeper);
        (uint256 first, bool openedFirst) = vault.openSeries();
        assertTrue(openedFirst);

        vm.prank(keeper);
        (uint256 second, bool openedSecond) = vault.openSeries();
        assertEq(second, first, unicode"交回同一个系列");
        assertFalse(openedSecond, unicode"🔴 没有再开一个");
    }

    /// @notice 采样停了就开不出系列 —— fail-closed 在真实 Portal 上同样成立，顺带量一次 gas。
    ///
    /// @dev 「样本不足时拒绝开系列」这条验收在本地是拿替身摆出来的。这里让真实链上的环**过期**：
    ///      停采两小时之后，`openSeries` 必须拒绝，而不是拿一段与当下无关的历史把整周发行量定死。
    function test_openSeriesIsFailClosedWhenSamplingStopsOnTheRealChain() public {
        (WarrantVault vault,) = _readyVault();

        uint256 before = gasleft();
        vm.prank(keeper);
        vault.openSeries();
        uint256 gasUsed = before - gasleft();
        console2.log(string.concat(unicode"  真实链上 openSeries gas=", vm.toString(gasUsed)));

        // 走到下一期的窗口里，但采样已经停了两个多小时。
        uint64 expiry = vault.seriesExpiry();
        vm.warp(uint256(expiry) - 2 hours);

        (uint256 status,,) = vault.openSeriesStatus();
        assertEq(status, 3, unicode"OPEN_TWAP_UNAVAILABLE —— 状态码见 docs/spec.zh.md §5.2");

        vm.prank(keeper);
        vm.expectRevert(
            unicode"24h TWAP unavailable, call twap() for the reason / 24 小时 TWAP 不可用，原因调 twap() 读"
        );
        vault.openSeries();

        assertEq(
            vault.seriesExpiry(), expiry, unicode"🔴 上一期一个字节都没动，也没落下一个坏 strike"
        );
    }
}
