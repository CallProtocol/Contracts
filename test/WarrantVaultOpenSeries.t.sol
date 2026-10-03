// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {WarrantVault} from "../src/WarrantVault.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {WarrantVaultHarness} from "./helpers/WarrantVaultHarness.sol";

/// @notice **M2-4 开系列**（issue #36）：strike 定价、周五对齐与停发可观测。
///
/// 这份测试要钉住五件事，它们对应验收条款里的那几条 🔴：
///
/// 1. **`strike = TWAP × 0.8`，而且量纲与 `ClearingPool.exercise` 的
///    `amount * strike / 1e18` 一致** —— 后者不靠两边注释各写一遍，而是
///    {test_strike_isTheSameNumberTheClearingPoolChargesOnExercise} 一路走到真实行权，
///    拿一个**从产品口径独立算出来的** MEME 数额对账。这是本票最容易出、也最贵的错：
///    strike 差一个数量级，整周的权证要么白送要么永远无人行权。
/// 2. **到期严格落在周五 21:00 UTC，且寿命 ≥7 天** —— 期望值是**独立写死的真实日历时间戳**
///    （由 UTC 日历算出，不从被测合约读），并各有一条测试证明闰秒与夏令时改不动它。
/// 3. **样本不足就拒绝开系列** —— {twap} 的六个状态里只有 `TWAP_OK` 放行，
///    不落一个用坏数据算出来的 strike。
/// 4. **同一周重复调用不得开出第二个系列** —— 不是「大概不会」，而是把整整一周每小时调一遍。
/// 5. **未按期开出系列可被链下发现** —— {WarrantVault-openSeriesStatus} 是一个 view：
///    不必发交易、也不必等到失败之后，就答得出「本期开出来了吗、没开是因为什么」。
///
/// TWAP 本身（采样节奏、窗口、六个状态码怎么来的）在 `test/WarrantVaultTwap.t.sol`；
/// 真实 Portal 与真实 GME 上的那一份在 `test/fork/RobinhoodOpenSeries.t.sol`。
///
/// 🔴 池子、权证、分发合约、声明注册表**都是真的**（issue #5 的测试缝）：本票的核心断言跨过金库与
/// 池子的边界 —— 「金库算出来的 strike 与池子行权时收的 MEME 是同一个数」这句话，只有真池子说得出来。
contract WarrantVaultOpenSeriesTest is Test {
    /// @dev 🔴 独立写死，不读 `pool.BURN_ADDRESS()` —— 拿被测对象自己的常量去验它自己，什么也证明不了。
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ─────────────────── 🔴 到期日历：独立写死的真实周五 21:00 UTC ───────────────────
    //
    // 每一个都由 UTC 日历算出（`date -u -d "2026-08-14 21:00:00" +%s`），**不从合约推**。
    // 合约那边写的是「Unix 纪元是周四，所以周五 21:00 = 周内偏移 45 小时」；这里写的是
    // 「2026-08-14 21:00 UTC 是一个周五」。两句话没有共同来源，对上了才算证明。

    uint64 internal constant FRI_AUG_14 = 1_786_741_200; // 2026-08-14 21:00 UTC 周五
    uint64 internal constant FRI_AUG_21 = 1_787_346_000; // 2026-08-21 21:00 UTC 周五
    uint64 internal constant FRI_AUG_28 = 1_787_950_800; // 2026-08-28 21:00 UTC 周五
    uint64 internal constant FRI_SEP_04 = 1_788_555_600; // 2026-09-04 21:00 UTC 周五

    /// @dev 跨年那一档 —— 2027-01-01 恰好是周五，顺带证明对齐不看年月。
    uint64 internal constant FRI_DEC_25 = 1_798_232_400; // 2026-12-25 21:00 UTC 周五
    uint64 internal constant FRI_JAN_01 = 1_798_837_200; // 2027-01-01 21:00 UTC 周五

    /// @dev 一周的秒数与周五 21:00 的周内偏移。**独立写死**：`7 * 86400` 与 `45 * 3600`。
    uint256 internal constant WEEK_SECONDS = 604_800;
    uint256 internal constant FRIDAY_2100_OFFSET = 162_000;

    // ─────────────────────────── 🔴 定价：人能心算的一组数 ───────────────────────────
    //
    // Flap 的 `price` 是「1e18 raw MEME 值多少 raw 股票代币」，我们要的是它的倒数量纲。
    // 取 `5e14` 是为了让整条链上的数都是整的、而且一眼看得出来：
    //
    //   1e36 / 5e14 = 2e21 = 2000e18   ⟹ 1 份股票 = 2000 枚 MEME
    //   2000e18 × 0.8 = 1600e18        ⟹ strike（每 1e18 raw 股票要烧的 MEME）
    //   行权 3 份股票 ⟹ 3e18 × 1600e18 / 1e18 = 4800e18 枚 MEME
    //
    // 最后那个 4800e18 是本文件里唯一真正重要的数字，它**不由任何一个被测合约算出来**。

    uint256 internal constant FLAP_PRICE = 5e14;
    uint256 internal constant MEME_PER_STOCK = 2000e18;
    uint128 internal constant EXPECTED_STRIKE = 1600e18;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;

    WarrantVaultHarness internal vault;
    FlapPortalStub internal portal;
    MemeToken internal meme;
    StockToken internal stock;

    address internal keeper = makeAddr("trigger service");
    address internal alice = makeAddr("alice");

    uint256 internal OPEN_OK;
    uint256 internal ALREADY_OPEN;
    uint256 internal TOO_EARLY;
    uint256 internal TWAP_UNAVAILABLE;
    uint256 internal STRIKE_ROUNDS_TO_ZERO;
    uint256 internal STRIKE_TOO_LARGE;
    uint256 internal openWindow;
    uint256 internal minLifetime;

    function setUp() public {
        // 起点：周五 21:00 之前 25 小时。{_bootstrapRing} 会把这 24 小时用样本铺满，
        // 于是第一次开系列发生在**周五 20:00** —— 正是 spec §6.2 那条「周五 21:00 UTC 前」的时序。
        vm.warp(FRI_AUG_14 - 25 hours);

        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        meme = new MemeToken();
        stock = new StockToken();

        // 🔴 取价 Portal 是金库的**构造参数**（决策 39-A2），所以这里部署一个替身、把地址传进去 ——
        //    不必再 `etch` 到基类那张 chainId 表写死的地址上。
        portal = new FlapPortalStub();
        portal.setCurve(address(meme), address(stock), FLAP_PRICE);

        vault = new WarrantVaultHarness(
            pool, address(distributor), address(portal), address(meme), address(stock), makeAddr("creator"), false
        );
        factory.bind(address(meme), address(vault));

        assertEq(
            address(pool.vaultRegistry()),
            address(factory.registry()),
            unicode"池子认工厂写入的同一份身份根"
        );
        assertEq(factory.registry().vaultOf(address(meme)), address(vault), unicode"MEME 绑定到本金库");

        uint256[9] memory openConstants = vault.harnessOpenConstants();
        (OPEN_OK, ALREADY_OPEN, TOO_EARLY, TWAP_UNAVAILABLE, STRIKE_ROUNDS_TO_ZERO, STRIKE_TOO_LARGE) =
        (openConstants[0], openConstants[1], openConstants[2], openConstants[3], openConstants[4], openConstants[5]);
        (openWindow, minLifetime) = (openConstants[6], openConstants[7]);
        assertEq(openConstants[8], 8000, unicode"决策 14：k = 0.8，也就是 8000 基点");
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev 铺满一个可用的严格 24 小时窗口：25 个等间隔时间边界，环仍只保存最新 24 条。
    ///      结束时 `block.timestamp` 恰好是起点 + 24 小时。
    function _bootstrapRing() internal {
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"第一条样本");
        for (uint256 i = 0; i < 24; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap(), unicode"每小时那一条都该写进去");
        }
    }

    /// @dev 像真实 keeper 一样每小时采一次，一直走到 `target`。窗口因此始终是新鲜的 ——
    ///      这条测试里但凡出现 TWAP 失败，都该是**测试有意制造**的，而不是时间轴走过头了。
    function _keepSamplingUntil(uint256 target) internal {
        while (block.timestamp + 1 hours <= target) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            vault.sampleTwap();
        }
        if (block.timestamp < target) vm.warp(target);
    }

    /// @dev 一个铺好环、正站在周五 20:00 的金库 —— 本文件绝大多数测试的起点。
    function _readyAtFridayEvening() internal {
        _bootstrapRing();
        assertEq(block.timestamp, FRI_AUG_14 - 1 hours, unicode"起点应当是周五 20:00");
    }

    function _status() internal view returns (uint256 status, uint64 expiry, uint128 nextStrike) {
        return vault.openSeriesStatus();
    }

    // ══════════════════════════ 1. 到期：周五 21:00 UTC 对齐 ══════════════════════════

    /// @notice 🔴 **验收第 3 条**：到期落在周五 21:00 UTC，期望值是独立写死的真实日历时间戳。
    ///
    /// @dev 五个取样点覆盖一周里的不同位置。每一个的期望值都是上面那张表里的常量 ——
    ///      测试从头到尾没有算过「哪天是周五」。
    function test_expiry_landsOnTheCalendarFridayAt2100Utc() public view {
        // 周五 20:00：最近的周五只剩一小时，按 ≥7 天规则归入**下一个**周五。
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 - 1 hours), FRI_AUG_21);
        // 周六、周一、周三 —— 一周里怎么挪，落点都还是那个周五。
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 15 hours), FRI_AUG_28, unicode"周六中午");
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 3 days), FRI_AUG_28, unicode"周一");
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 5 days), FRI_AUG_28, unicode"周三");
        // 跨年：2027-01-01 也是一个周五，对齐规则不看年月。
        assertEq(vault.harnessNextExpiry(FRI_DEC_25 - 1 hours), FRI_JAN_01, unicode"跨年那一周");
    }

    /// @notice 🔴 **验收第 3 条的另一半**：`expiry − now ≥ 7 天`，且边界上取 `≥` 而不是 `>`。
    ///
    /// @dev 这是「距最近周五 <7 天时归入下一个周五」那条规则的临界点，也是它唯一会出错的地方：
    ///      早一秒是 7 天整（放行），晚一秒就必须整整推后一周，否则临近周五铸出的权证一出生就到期。
    function test_expiry_takesTheNextFridayAsSoonAsSevenDaysNoLongerFits() public view {
        assertEq(vault.harnessNextExpiry(FRI_AUG_14), FRI_AUG_21, unicode"恰好周五 21:00：寿命正好 7 天");
        assertEq(FRI_AUG_21 - FRI_AUG_14, 7 days, unicode"而 7 天整是放行的那一档（≥，不是 >）");

        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 1), FRI_AUG_28, unicode"晚一秒就得整整推后一周");
        assertEq(FRI_AUG_28 - (FRI_AUG_14 + 1), 14 days - 1, unicode"于是这一期活 14 天差一秒");
    }

    /// @notice 到期永远是一个周五 21:00 UTC，寿命永远落在 `[7 天, 14 天)`。
    /// @dev 判据用**独立写死**的 `604800` / `162000` 表达，不引用合约里的两个常量。
    function testFuzz_expiry_isAlwaysAFridayWithAtLeastSevenDaysOfLife(uint64 raw) public view {
        uint256 nowTs = bound(uint256(raw), 1, uint256(type(uint64).max) - 30 days);
        uint256 expiry = vault.harnessNextExpiry(nowTs);

        assertEq(expiry % WEEK_SECONDS, FRIDAY_2100_OFFSET, unicode"周五 21:00 UTC 的周内偏移");
        assertGe(expiry - nowTs, minLifetime, unicode"🔴 寿命不得短于 7 天");
        assertLt(expiry - nowTs, 14 days, unicode"也不该无谓地推到再下一周");
    }

    /// @notice 🔴 **闰秒改不动到期日历。**
    ///
    /// @dev 不是「大概不影响」：Unix 时间**按定义**是不计闰秒的秒计数，1972 年以来插入的每一个闰秒
    ///      都没有在这个计数里占位置。所以真正该断言的是「跨过一次真实闰秒插入，两个相邻到期
    ///      仍然精确相差 604800 秒」—— 取的正是最近一次插入（2016-12-31 23:59:60 UTC）。
    ///
    ///      反过来说：如果哪天有人把日历换成一个**会**计闰秒的实现，这条断言会立刻少一秒。
    function test_expiry_isUnaffectedByLeapSeconds() public view {
        uint64 friBeforeLeapSecond = 1_483_131_600; // 2016-12-30 21:00 UTC 周五
        uint64 friAfterLeapSecond = 1_483_736_400; // 2017-01-06 21:00 UTC 周五
        assertEq(
            friAfterLeapSecond - friBeforeLeapSecond, WEEK_SECONDS, unicode"闰秒没有在 Unix 计数里占位置"
        );

        // 闰秒插入前后各取一个时刻，落点仍然是这两个周五。
        assertEq(vault.harnessNextExpiry(friBeforeLeapSecond - 1 hours), friBeforeLeapSecond + uint64(WEEK_SECONDS));
        assertEq(vault.harnessNextExpiry(friAfterLeapSecond - 1 hours), friAfterLeapSecond + uint64(WEEK_SECONDS));
    }

    /// @notice 🔴 **夏令时改不动到期日历。**
    ///
    /// @dev 同样不是「大概不影响」：到期钉的是 **UTC**，而 UTC 按定义没有夏令时。
    ///      取 2026 年的四次真实切换（美国 3/8、欧盟 3/29、欧盟 10/25、美国 11/1）各自前后的周五，
    ///      断言相邻两期仍然精确相差 604800 秒 —— 本地时钟拨了一小时，我们的日历一秒都没动。
    function test_expiry_isUnaffectedByDaylightSaving() public view {
        uint64[4] memory fridayBeforeSwitch = [
            uint64(1_772_830_800), // 2026-03-06，美国 3/8 春季切换之前
            uint64(1_774_645_200), // 2026-03-27，欧盟 3/29 春季切换之前
            uint64(1_792_789_200), // 2026-10-23，欧盟 10/25 秋季切换之前
            uint64(1_793_394_000) // 2026-10-30，美国 11/1 秋季切换之前
        ];

        for (uint256 i = 0; i < fridayBeforeSwitch.length; i++) {
            uint64 before = fridayBeforeSwitch[i];
            assertEq(uint256(before) % WEEK_SECONDS, FRIDAY_2100_OFFSET, unicode"取样点本身得是周五 21:00 UTC");

            uint64 first = vault.harnessNextExpiry(before - 1 hours);
            uint64 second = vault.harnessNextExpiry(before - 1 hours + uint256(WEEK_SECONDS));
            assertEq(
                second - first, uint64(WEEK_SECONDS), unicode"跨过夏令时切换，两期到期仍精确相差一周"
            );
        }
    }

    // ══════════════════════════ 2. 行权价：TWAP × 0.8 ══════════════════════════

    /// @notice 🔴 **验收第 1 条**：`strike = TWAP × 0.8`。
    function test_openSeries_locksTheStrikeAtEightyPercentOfTheTwap() public {
        _readyAtFridayEvening();

        (uint256 twapStatus, uint256 price) = vault.twap();
        assertEq(twapStatus, 0, unicode"环铺满了，读数该可用");
        assertEq(price, MEME_PER_STOCK, unicode"1 份股票 = 2000 枚 MEME —— 由 Flap 的 price 倒数算出");

        vm.prank(keeper);
        (uint256 seriesId, bool opened) = vault.openSeries();

        assertTrue(opened);
        assertEq(vault.strike(), EXPECTED_STRIKE, unicode"2000 × 0.8 = 1600");
        assertEq(vault.seriesExpiry(), FRI_AUG_21);
        assertEq(pool.series(seriesId).strike, EXPECTED_STRIKE, unicode"池子里锁下的是同一个数");
    }

    /// @notice 🔴 **验收第 2 条（本票最贵的那条）**：金库算出来的 `strike`，与
    ///         `ClearingPool.exercise` 按 `amount * strike / 1e18` 收走的 MEME，是同一个量纲。
    ///
    /// # 为什么必须一路走到行权，而不是比较两个字段
    ///
    /// 「量纲一致」不是「两个 `uint128` 相等」。金库那边的口径是**每 1e18 raw 股票代币值多少 raw MEME**，
    /// 池子那边的口径是**行权 `amount` 要烧掉多少 raw MEME**；只有让真实的 MEME 余额减少一次，
    /// 两个口径才真的被对齐过。断言的数额是从产品口径**独立算出来的**：
    ///
    /// > 1 份股票 = 2000 枚 MEME，k = 0.8 ⟹ strike = 1600；行权 3 份股票 ⟹ 烧 4800 枚 MEME。
    ///
    /// `4800e18` 这个数没有任何一个被测合约参与生成 —— 它就写在下面，谁都能心算一遍。
    /// 差一个数量级会怎样：strike 大 10 倍，整周权证永远无人行权；小 10 倍，股票代币等于白送。
    function test_strike_isTheSameNumberTheClearingPoolChargesOnExercise() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        // 金库收到 10 份股票代币的税收：一成记给 creator（决策 49），九成存进池子、
        // 铸出 9 枚权证给 distributor。1:1 全额抵押说的是**已入池**的那部分 —— 权证只由它背书。
        stock.mint(address(vault), 10e18);
        vm.prank(keeper);
        assertEq(vault.processRevenue(), 8e18, unicode"1:1 全额抵押：9 份入池抵押品铸 9 枚权证");

        // 权证到 alice 手上（分发那一步不是本票的内容，这里直接从 distributor 转过去）。
        vm.prank(address(distributor));
        warrant.safeTransferFrom(address(distributor), alice, seriesId, 3e18, "");

        // 受益人侧的两步准备，正是前端要引导用户做的那两步。
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 10_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);

        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        vm.prank(alice);
        pool.exercise(seriesId, 3e18, alice);

        // 🔴 独立算出来的那个数：3 份股票 × 1600 MEME/份 = 4800 枚。
        uint256 expectedBurn = 4800e18;
        assertEq(
            memeBefore - meme.balanceOf(alice), expectedBurn, unicode"🔴 受益人被扣的 MEME 就是这个数"
        );
        assertEq(meme.balanceOf(DEAD) - deadBefore, expectedBurn, unicode"而且它真的进了销毁地址");
        assertEq(stock.balanceOf(alice), 3e18, unicode"换回 3 份股票代币");

        // 再从另一头验一遍量纲：strike 是「每 1e18 raw 股票」的价，所以 1 raw 股票只烧 1600 raw MEME。
        assertEq(uint256(vault.strike()) * 1 / 1e18, 1600, unicode"1 raw 股票 = 1600 raw MEME，量纲对得上");
    }

    /// @notice 折让是**向下取整**的，剩下的那点零头留在池子这一侧，不四舍五入到用户那边。
    function test_openSeries_roundsTheDiscountDown() public {
        // 1e36 / 3 = 333...333（向下取整），再 × 0.8 仍然向下取整。
        portal.setCurve(address(meme), address(stock), 3);
        _readyAtFridayEvening();

        (, uint256 price) = vault.twap();
        vm.prank(keeper);
        vault.openSeries();

        assertEq(vault.strike(), uint128((price * 8000) / 10_000), unicode"向下取整，不进位");
        assertLe(uint256(vault.strike()) * 10_000, price * 8000, unicode"取整只可能让 strike 偏小");
    }

    /// @notice TWAP 低到折让之后取整成 0 时**不开系列** —— 否则等于白送股票代币。
    /// @dev 池子那边有一道 `ZeroStrike`，但撞上去只能给前端一个解不开的 selector；
    ///      在金库这一侧判掉，运维拿到的是一句人话。
    function test_openSeries_refusesWhenTheDiscountRoundsTheStrikeToZero() public {
        // 1e36 / 1e36 = 1 ⟹ 1 × 8000 / 10000 = 0。
        portal.setCurve(address(meme), address(stock), 1e36);
        _readyAtFridayEvening();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, STRIKE_ROUNDS_TO_ZERO);
        assertEq(nextStrike, 0);

        vm.prank(keeper);
        vm.expectRevert(unicode"TWAP too low to price a strike / TWAP 太低，算不出非零行权价");
        vault.openSeries();
    }

    /// @notice 折让后的行权价装不进 `uint128` 时**不开系列**。
    /// @dev 走的是毕业之后的池子分支：它按储备比算价，上界（约 5.19e51）远高于曲线分支的 1e36，
    ///      所以这条分支是**真的可达**的，不是一段防御性死代码。
    function test_openSeries_refusesWhenTheStrikeWouldNotFitInUint128() public {
        DexPairStub pair = new DexPairStub(address(meme), address(stock));
        // memeReserve × 1e18 / quoteReserve = 1e48 ⟹ 折让后 8e47，远超 uint128 的 3.4e38。
        pair.setReserves(1e30, 1);
        portal.setGraduated(address(meme), address(stock), address(pair));

        _readyAtFridayEvening();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, STRIKE_TOO_LARGE);
        assertEq(nextStrike, 0);

        vm.prank(keeper);
        vm.expectRevert(unicode"Strike does not fit in uint128 / 行权价装不进 uint128");
        vault.openSeries();
    }

    // ══════════════════════ 3. 样本不足：fail-closed，一个坏 strike 都不落 ══════════════════════

    /// @notice 🔴 **验收第 4 条**：环还没填满就拒绝开系列，`strike` 一个字节都不写。
    function test_openSeries_refusesWhileTheRingIsStillFilling() public {
        vm.prank(keeper);
        vault.sampleTwap();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, TWAP_UNAVAILABLE);
        assertEq(nextStrike, 0, unicode"算都没算");

        vm.prank(keeper);
        vm.expectRevert(
            unicode"24h TWAP unavailable, call twap() for the reason / 24 小时 TWAP 不可用，原因调 twap() 读"
        );
        vault.openSeries();

        assertEq(vault.strike(), 0, unicode"🔴 没有落下一个用坏数据算出来的 strike");
        assertEq(vault.seriesExpiry(), 0);
    }

    /// @notice keeper 停了一拍，尾段超过最大缺口 —— 同样拒绝。
    /// @dev 与上一条是**两种不同的失败**（环没满 / 有缺口），但金库这一侧给的是同一句话：
    ///      具体原因的权威出处只有 `twap()` 一处，不在这里抄第二遍。
    function test_openSeries_refusesWhenTheKeeperMissedABeat() public {
        _readyAtFridayEvening();

        (uint256 ready,,) = _status();
        assertEq(ready, OPEN_OK, unicode"停拍之前是可以开的");

        // 漏掉一个完整心跳：尾段变成 1 小时 6 分，超过 65 分钟的上限。
        vm.warp(block.timestamp + 1 hours + 6 minutes);

        (uint256 status,,) = _status();
        assertEq(status, TWAP_UNAVAILABLE);

        vm.prank(keeper);
        vm.expectRevert(
            unicode"24h TWAP unavailable, call twap() for the reason / 24 小时 TWAP 不可用，原因调 twap() 读"
        );
        vault.openSeries();
    }

    /// @notice 🔴 **状态码不转发**：金库只说到「TWAP 不可用」，具体是六个原因里的哪一个由 `twap()` 交出。
    /// @dev 同一个值有两处出处，迟早有一处会漂；而漂掉的后果是链下按一张过期的对照表去查故障。
    function test_openSeriesStatus_pointsAtTwapInsteadOfCopyingItsCodes() public {
        vm.prank(keeper);
        vault.sampleTwap();

        (uint256 status,,) = _status();
        (uint256 twapStatus,) = vault.twap();

        assertEq(status, TWAP_UNAVAILABLE, unicode"金库这边恒是同一个码");
        assertEq(twapStatus, 1, unicode"而具体原因（环没填满 = 1）在 twap() 那边");
        assertTrue(status != twapStatus, unicode"两个码空间是独立的，不该被读成同一个");
    }

    // ══════════════════════ 4. 同一周重复调用：不得开出第二个系列 ══════════════════════

    /// @notice 🔴 **验收第 5 条**：重复调用是幂等的 —— 返回已开的那个系列，`opened == false`，不碰池子。
    function test_openSeries_isIdempotentWithinTheSameWeek() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 first, bool openedFirst) = vault.openSeries();
        assertTrue(openedFirst);

        uint128 mintedStrike = vault.strike();

        vm.prank(keeper);
        (uint256 second, bool openedSecond) = vault.openSeries();

        assertEq(second, first, unicode"交回来的是同一个系列");
        assertFalse(openedSecond, unicode"🔴 但它没有再开一个");
        assertEq(vault.strike(), mintedStrike, unicode"行权价一经锁死就不该被第二次调用改掉");

        (uint256 status,,) = _status();
        assertEq(status, ALREADY_OPEN, unicode"视图也这么说");
    }

    /// @notice 🔴 **验收第 5 条，用最笨也最结实的方式**：从开出系列那一刻起，每小时调一次
    ///         `openSeries()`，一直调到下一个窗口打开为止 —— 一个新系列都不该多开出来，
    ///         而且**没有任何一次调用 revert**。
    ///
    /// @dev 「不会重复开」这句话不该靠「我们只调一次」来成立：Trigger Service 会重试、会空跑、
    ///      也可能有人手动多点一下。这里把这一周的每一个小时都打一遍。
    ///
    ///      顺带钉住那条运维性质：一个**每天空跑**的 keeper 不会因此一周红六天 ——
    ///      「没事可做」走的是干净返回，不是 revert。
    function test_openSeries_neverOpensASecondSeriesHoweverOftenItIsCalled() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        uint256 calls;
        // 停在窗口打开**之前**：从那一刻起开出下一期才是正确行为，本条测试问的是它之前的那一周。
        while (block.timestamp + 1 hours < FRI_AUG_21 - openWindow) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            vault.sampleTwap();

            vm.prank(keeper);
            (uint256 id, bool opened) = vault.openSeries();
            assertEq(id, seriesId, unicode"每一次都指向同一个系列");
            assertFalse(opened, unicode"🔴 一个新系列都没多开出来");
            calls++;

            assertEq(vault.seriesExpiry(), FRI_AUG_21, unicode"当前系列一个字节都没动");
            assertEq(vault.strike(), EXPECTED_STRIKE, unicode"行权价也没动");
        }

        assertGt(calls, 140, unicode"这一周确实被逐小时打过一遍");
    }

    // ══════════════════════ 5. 开系列的时刻：24 小时窗口 ══════════════════════

    /// @notice 🔴 当前系列还早着的时候开不出下一期 —— 否则任何人都能在一周里**挑一小时**
    ///         把整周的行权价定死。完整论证见 `WarrantVault.OPEN_WINDOW`。
    function test_openSeries_refusesUntilTheOpenSeriesIsWithinADayOfExpiry() public {
        _readyAtFridayEvening();
        vm.prank(keeper);
        vault.openSeries();

        uint256 liveSeries = pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21);

        // 周六中午：距 8/21 到期还有六天多。
        _keepSamplingUntil(FRI_AUG_14 + 15 hours);
        (uint256 status, uint64 expiry,) = _status();
        assertEq(status, TOO_EARLY);
        assertEq(expiry, FRI_AUG_28, unicode"🔴 但到期日历照样答得出来 —— 它是时间的纯函数");

        // 🔴 干净返回而不是 revert：「现在本来就不该开」不是事故。交回来的是**当前**那一期。
        vm.prank(keeper);
        (uint256 id, bool openedEarly) = vault.openSeries();
        assertEq(id, liveSeries, unicode"交回当前还开着的那一期");
        assertFalse(openedEarly);

        // 窗口开启前一秒，仍然不开。
        _keepSamplingUntil(FRI_AUG_21 - openWindow - 1);
        (status,,) = _status();
        assertEq(status, TOO_EARLY, unicode"差一秒也不行");

        // 窗口一到就放行 —— 恰好是周四 21:00。
        _keepSamplingUntil(FRI_AUG_21 - openWindow);
        (status, expiry,) = _status();
        assertEq(status, OPEN_OK, unicode"到期前 24 小时整，窗口打开");

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
        assertEq(vault.seriesExpiry(), FRI_AUG_28, unicode"开出的是下一期，寿命 8 天");
    }

    /// @notice 🔴 窗口关不死活性：漏掉一整周之后，任何人都能**立刻**补开一期。
    ///
    /// @dev 这是 {WarrantVault-OPEN_WINDOW} 那笔取舍的另一半 —— 它买到的是「时刻不可挑」，
    ///      代价必须止步于「晚一点开」，不能变成「再也开不出来」。
    ///      补开的那一期按 ≥7 天寿命规则落到再下一个周五，收入也因此**立刻**又有地方去。
    function test_openSeries_recoversImmediatelyAfterAMissedWeek() public {
        _readyAtFridayEvening();
        vm.prank(keeper);
        vault.openSeries();

        // 整个窗口都没人调，系列就这么到期了。
        _keepSamplingUntil(FRI_AUG_21 + 12 hours);

        (uint256 status, uint64 expiry,) = _status();
        assertEq(status, OPEN_OK, unicode"🔴 到期之后这道门自动打开，不需要任何人来解锁");
        assertEq(expiry, FRI_SEP_04, unicode"按 ≥7 天寿命规则落到再下一个周五");

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);

        // 补开之后收入立刻又有地方去 —— 停发一周，但没有一分钱卡在金库里等两周。
        stock.mint(address(vault), 5e18);
        vm.prank(keeper);
        assertEq(vault.processRevenue(), 4e18);
    }

    /// @notice 第一次开系列不受窗口约束 —— 金库刚出生时没有「当前系列」可等。
    function test_openSeries_hasNoWindowOnTheVeryFirstSeries() public {
        // 起点是周六中午，离任何一个周五都还远。
        vm.warp(FRI_AUG_14 + 15 hours - 24 hours);
        _bootstrapRing();

        (uint256 status, uint64 expiry,) = _status();
        assertEq(status, OPEN_OK, unicode"seriesExpiry == 0，窗口门不适用");
        assertEq(expiry, FRI_AUG_28);

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
    }

    // ══════════════════════ 6. 停发可观测（issue #42 的链上抓手） ══════════════════════

    /// @notice 🔴 **验收第 7 条**：本期系列有没有开出来，链下**不必发交易**就答得出来。
    ///
    /// @dev 走一遍一只金库真实会经历的四种形态，每一种都问一次视图。这条测试要证明的是
    ///      「每一种停发形态都有一个能照着查下去的答案」，而不是「有一个视图存在」。
    function test_openSeriesStatus_answersWhetherThisWeeksSeriesIsOpen() public {
        // ① 刚部署：TWAP 还没准备好 —— 停发原因在采样链路上。
        (uint256 status, uint64 expiry, uint128 nextStrike) = _status();
        assertEq(status, TWAP_UNAVAILABLE);
        assertEq(expiry, FRI_AUG_21, unicode"到期日历任何状态下都答得出来");
        assertEq(nextStrike, 0);

        // ② 环铺满了，还没人调 —— 停发原因在 Trigger Service 那一侧。
        _readyAtFridayEvening();
        (status, expiry, nextStrike) = _status();
        assertEq(status, OPEN_OK, unicode"🔴 「本该开、能开、但没开」是最要紧的那一档");
        assertEq(expiry, FRI_AUG_21);
        assertEq(nextStrike, EXPECTED_STRIKE, unicode"连会锁下哪个行权价都先说了");

        // ③ 开出来了 —— 这一档就是「本周没问题」。
        vm.prank(keeper);
        vault.openSeries();
        (status, expiry, nextStrike) = _status();
        assertEq(status, ALREADY_OPEN);
        assertEq(expiry, FRI_AUG_21);
        assertEq(nextStrike, 0, unicode"本次不会再开，所以没有「会锁下的行权价」");

        // ④ 下一期还早 —— 这一档**不是**告警，链下据此知道现在本来就不该开。
        _keepSamplingUntil(FRI_AUG_14 + 2 days);
        (status,,) = _status();
        assertEq(status, TOO_EARLY);
    }

    /// @notice 🔴 视图与交易**不可能给出不同的答案** —— 两者共用同一个判定函数。
    /// @dev 逐个状态走一遍：视图说能开，交易就真的开得出来；视图说不能，交易就真的失败。
    ///      一个会撒谎的预检比没有预检更糟：链下会照着它把告警关掉。
    function test_openSeriesStatus_neverDisagreesWithOpenSeries() public {
        // 说不能开 → 真的开不出来
        (uint256 status,,) = _status();
        assertTrue(status != OPEN_OK && status != ALREADY_OPEN);
        vm.prank(keeper);
        vm.expectRevert();
        vault.openSeries();

        // 说能开 → 真的开得出来，而且开出来的 expiry / strike 与预告的一字不差
        _readyAtFridayEvening();
        (uint256 okStatus, uint64 predictedExpiry, uint128 predictedStrike) = _status();
        assertEq(okStatus, OPEN_OK);

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
        assertEq(vault.seriesExpiry(), predictedExpiry, unicode"预告的到期");
        assertEq(vault.strike(), predictedStrike, unicode"预告的行权价");

        // 说已经开了 → 交易干净返回，不 revert
        (status,,) = _status();
        assertEq(status, ALREADY_OPEN);
        vm.prank(keeper);
        (, bool again) = vault.openSeries();
        assertFalse(again);
    }

    /// @notice 事件把**定价的输入与输出一起**记下来，链下拿一条日志就能核对 `strike = TWAP × 0.8`。
    function test_openSeries_emitsTheTwapItPricedFrom() public {
        _readyAtFridayEvening();

        uint256 expectedId = pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21);

        vm.expectEmit(true, false, false, true, address(vault));
        emit WarrantVault.WeeklySeriesOpened(expectedId, FRI_AUG_21, EXPECTED_STRIKE, MEME_PER_STOCK);

        vm.prank(keeper);
        vault.openSeries();
    }

    // ══════════════════════ 7. 接线：seriesId、身份根与写入顺序 ══════════════════════

    /// @notice 金库开出来的 `seriesId` 与 `pool.seriesIdOf(meme, stock, expiry)` 是同一个数。
    /// @dev 期望值**独立算一份**（自己 `keccak256(abi.encode(...))`），不拿池子的 `seriesIdOf`
    ///      去验它自己 —— 同 `ClearingPoolMinting.t.sol` 的纪律。
    function test_openSeries_returnsTheSeriesIdThePoolWouldCompute() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        uint256 independent = uint256(keccak256(abi.encode(address(meme), address(stock), FRI_AUG_21)));
        assertEq(seriesId, independent, unicode"三元组的哈希，独立算一份");
        assertEq(seriesId, pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21));
        assertEq(pool.series(seriesId).vault, address(vault), unicode"本金库就是该系列的金库");
    }

    /// @notice 🔴 **写入顺序是承重的**：池子拒绝时，`strike` 与 `seriesExpiry` 一个字节都不能落下。
    ///
    /// @dev 反过来写的话（先写字段再开系列），一旦开系列失败，字段就会指向别人的系列，
    ///      而 `processRevenue` 会稳定撞上 `NotSeriesVault` —— 收入从此再也出不去金库。
    ///      陌生人现在会先被身份门拒掉，无法再抢注三元组；故这里以已登记的金库直接预开同一
    ///      三元组，专门撞后面的 `SeriesAlreadyOpen` 分支。
    function test_openSeries_writesNothingWhenThePoolRejects() public {
        _readyAtFridayEvening();

        vm.prank(address(vault));
        pool.openSeries(address(meme), address(stock), FRI_AUG_21, 1);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SeriesAlreadyOpen.selector,
                pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21),
                address(vault)
            )
        );
        vault.openSeries();

        assertEq(vault.strike(), 0, unicode"🔴 字段没有落下");
        assertEq(vault.seriesExpiry(), 0);

        // 而且金库没有因此变成一只「以为自己开过了」的金库：收入照旧走延后那条边。
        stock.mint(address(vault), 1e18);
        vm.prank(keeper);
        assertEq(vault.processRevenue(), 0, unicode"钱留在金库等下一次，不会撞 NotSeriesVault");
    }

    /// @notice 身份根已经绑定后，陌生地址不能在金库前面占走同一周的系列。
    function test_poolRejectsAnUnregisteredCallerBeforeItCanOpenTheSeries() public {
        address squatter = makeAddr("squatter");

        vm.prank(squatter);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, address(meme), squatter, address(vault))
        );
        pool.openSeries(address(meme), address(stock), FRI_AUG_21, 1);
    }

    /// @notice 入口**无入参** —— calldata 里没有一个字节能影响 strike 或 expiry。
    /// @dev 这不是一句注释就能成立的话：只要签名里有参数，「谁调都算出同一组值」就得靠调用方自觉。
    ///      顺带记一笔：池子的拒绝**原样冒泡**，不被翻译成我们自己的话（与 `_approveQuote` 同一条规矩）——
    ///      上一条测试的 `expectRevert` 等的正是 `ClearingPool.SeriesAlreadyOpen` 的选择器，
    ///      而不是一句我们自己的字面量。
    function test_openSeries_takesNoArguments() public pure {
        assertEq(WarrantVault.openSeries.selector, bytes4(keccak256("openSeries()")));
    }

    /// @notice 任取一个地址都开得出本期系列，而且开出来的是**同一组**行权价与到期。
    /// @dev 无许可不是默认值，是一处取舍（见 `WarrantVault.OPEN_WINDOW`）。它成立的前提正是这一条：
    ///      调用方换了人，两个决定性的数一个都不会变。
    function testFuzz_anyCallerCanOpenTheWeeklySeries(address caller) public {
        vm.assume(caller != address(0));
        _readyAtFridayEvening();

        vm.prank(caller);
        (uint256 seriesId, bool opened) = vault.openSeries();

        assertTrue(opened);
        assertEq(vault.strike(), EXPECTED_STRIKE, unicode"谁调都是这个行权价");
        assertEq(vault.seriesExpiry(), FRI_AUG_21, unicode"谁调都是这个到期");
        assertEq(
            pool.series(seriesId).vault, address(vault), unicode"该系列的金库仍然是金库，不是调用方"
        );
    }

    /// @notice 连着开三期：每一期都比上一期晚整整一周，`processRevenue` 一路跟着走。
    /// @dev 这是产品的正常节奏（决策 16：每周五 21:00 UTC，最短寿命 7 天），
    ///      也是「任何时刻恰好两个活跃系列」这句话在时间轴上的样子。
    function test_openSeries_walksTheWeeklyCalendarForward() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_AUG_21);

        _keepSamplingUntil(FRI_AUG_21 - 1 hours);
        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_AUG_28, unicode"第二期");

        _keepSamplingUntil(FRI_AUG_28 - 1 hours);
        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_SEP_04, unicode"第三期");

        assertEq(FRI_AUG_28 - FRI_AUG_21, 7 days);
        assertEq(FRI_SEP_04 - FRI_AUG_28, 7 days);
    }
}
