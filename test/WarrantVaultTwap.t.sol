// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {PriceSource} from "../src/PriceSource.sol";
import {WarrantVault} from "../src/WarrantVault.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {WarrantVaultHarness} from "./helpers/WarrantVaultHarness.sol";

/// @notice `WarrantVault` 的 TWAP 采样与读数（M2-2，issue #34）。
///
/// 这份测试要钉住的是三句话，它们各自对应验收条款里的一条 🔴：
///
/// 1. **同一小时内重复调用不写第二条** —— 否则任何人都能用密集采样冲淡时间加权，
///    把 24 小时读数拉回近似现价；
/// 2. **读数严格积分 trailing 24 小时，且每段受最大间隔限制** —— 离散 spot 不能被错误地
///    延长成无人观测的数小时价格；
/// 3. **样本不足或有缺口时明确失败、且失败原因可辨识** —— strike 一周只定一次、决定整周
///    发行量，错一周的代价远高于停发一周。
///
/// 价格来源本身（量纲、两个分支、不 revert）在 `test/PriceSource.t.sol`；
/// 真实 Portal 上的实证在 `test/fork/RobinhoodTwapSource.t.sol`。
contract WarrantVaultTwapTest is Test {
    /// @dev 一条「正常」的曲线价：1e18 raw MEME 值 2e18 raw 股票 ⟹ 1 份股票值 0.5 份 MEME。
    uint256 internal constant FLAP_PRICE = 2e18;
    uint256 internal constant MEME_PER_STOCK = 1e36 / FLAP_PRICE;

    WarrantVaultHarness internal vault;
    FlapPortalStub internal portal;
    StockToken internal stock;

    address internal meme = makeAddr("meme");
    address internal keeper = makeAddr("trigger service");
    address internal attacker = makeAddr("attacker");

    uint256 internal samples;
    uint256 internal sampleInterval;
    uint256 internal maxSampleGap;
    uint256 internal maxSampleAge;
    uint256 internal minWindow;
    uint256 internal maxWindow;
    uint256 internal OK;
    uint256 internal RING_NOT_FULL;
    uint256 internal STALE;
    uint256 internal WINDOW_TOO_SHORT;
    uint256 internal WINDOW_TOO_LONG;
    uint256 internal SAMPLE_GAP;

    function setUp() public {
        // 起点不要落在 0：`lastSampleAt == 0` 表示「从未采样」，而 `block.timestamp == 0`
        // 会让「采过一次」与「从未采过」在断言里长得一样。
        vm.warp(1_700_000_000);

        stock = new StockToken();

        // 🔴 取价 Portal 是金库的构造参数（决策 39-A2）：部署一个替身、把地址传进去，
        //    不必再 `etch` 到基类那张 chainId 表写死的地址上。
        portal = new FlapPortalStub();
        portal.setCurve(meme, address(stock), FLAP_PRICE);

        // This suite never exercises the revenue route; nonzero immutables keep the production constructor shape intact.
        vault = new WarrantVaultHarness(
            IClearingPool(makeAddr("unused clearing pool")),
            makeAddr("unused distributor"),
            address(portal),
            meme,
            address(stock),
            makeAddr("unused creator")
        , false);

        uint256[12] memory constants = vault.harnessTwapConstants();
        (samples, sampleInterval, maxSampleGap, maxSampleAge, minWindow, maxWindow) =
        (constants[0], constants[1], constants[2], constants[3], constants[4], constants[5]);
        (OK, RING_NOT_FULL, STALE, WINDOW_TOO_SHORT, WINDOW_TOO_LONG, SAMPLE_GAP) =
        (constants[6], constants[7], constants[8], constants[9], constants[10], constants[11]);
    }

    // ──────────────────────────── 脚手架 ────────────────────────────

    /// @dev 建成可用的严格 24 小时窗口：25 个等间隔时间边界，环仍只保存最新 24 条。
    function _fillRing(uint256 flapPrice) internal {
        portal.setCurve(meme, address(stock), flapPrice);
        for (uint256 i = 0; i <= samples; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap(), unicode"每小时那一条都该写进去");
        }
    }

    function _twap() internal view returns (uint256 status, uint256 price) {
        return vault.twap();
    }

    // ──────────────────────── 采样：写入与幂等 ────────────────────────

    function test_sampleTwap_writesOneSampleAndReportsTheSource() public {
        assertEq(vault.lastSampleAt(), 0, unicode"刚部署，没有样本");

        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.TwapSampled(uint64(block.timestamp), MEME_PER_STOCK, PriceSource.SOURCE_CURVE);

        vm.prank(keeper);
        assertTrue(vault.sampleTwap());
        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"记下采样时刻");
    }

    /// @notice 🔴 **验收第 2 条**：同一小时内重复调用不写第二条。
    ///
    /// @dev 顺带钉住实现选的是「距上一条至少一小时」而**不是**「按整点分桶」：
    ///      分桶下 `t=3599` 与 `t=3601` 会都写进去，而那正是攻击者用来冲淡时间加权的缝。
    function test_sampleTwap_refusesASecondSampleBeforeAFullHour() public {
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());
        uint64 firstAt = vault.lastSampleAt();

        // 同一个区块里再调 —— 任何人都可以，什么都不该发生。
        vm.prank(attacker);
        assertFalse(vault.sampleTwap(), unicode"同一区块");
        assertEq(vault.lastSampleAt(), firstAt);

        vm.warp(block.timestamp + sampleInterval - 1);
        vm.prank(attacker);
        assertFalse(vault.sampleTwap(), unicode"差一秒也不行");
        assertEq(vault.lastSampleAt(), firstAt, unicode"🔴 没写第二条，时刻也没动");

        vm.warp(block.timestamp + 1);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"整整一小时之后可以");
        assertEq(vault.lastSampleAt(), uint64(block.timestamp));
    }

    /// @notice 🔴 密集采样冲淡不了时间加权 —— 这是上一条规则**存在的理由**，单独测一次。
    ///
    /// @dev 攻击场景：环已经攒满 24 条正常价，攻击者把价格拉高，然后在几秒内狂调
    ///      `sampleTwap()`，想把整环换成高价。最小间隔让他每小时只能换掉一条。
    function test_sampleTwap_burstCannotRefillTheRing() public {
        _fillRing(FLAP_PRICE);
        (, uint256 before) = _twap();

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100); // MEME 便宜 100 倍 = 股票贵 100 倍
        vm.warp(block.timestamp + sampleInterval);

        vm.startPrank(attacker);
        assertTrue(vault.sampleTwap(), unicode"第一条写得进去");
        for (uint256 i = 0; i < 200; i++) {
            vm.warp(block.timestamp + 12); // 一个区块一个区块地试
            assertFalse(vault.sampleTwap(), unicode"🔴 一小时之内一条都写不进去");
        }
        vm.stopPrank();

        (uint256 status, uint256 after_) = _twap();
        assertEq(status, OK);
        // 40 分钟里只换掉了一条。读数当然会动，但离「拉回现价」（100 倍）差着两个数量级。
        assertLt(after_, before * 5, unicode"🔴 200 次密集采样也只买到一条样本的份量");
        console2.log(
            string.concat(unicode"  密集采样前后：", vm.toString(before), unicode" → ", vm.toString(after_))
        );
    }

    /// @notice 取不到价时：不写、发事件、返回 false，而且**不 revert**。
    function test_sampleTwap_failureIsAnEventNotARevert() public {
        portal.setMode(FlapPortalStub.Mode.Revert);

        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.TwapSampleFailed(PriceSource.PORTAL_UNREADABLE);

        vm.prank(keeper);
        assertFalse(vault.sampleTwap());
        assertEq(vault.lastSampleAt(), 0, unicode"什么都没写");
    }

    /// @notice 毕业池本块刚更新过储备时，金库必须把它当成缺样；下一块可正常重试。
    function test_sampleTwap_rejectsAPoolUpdatedThisBlockAndRetriesLater() public {
        DexPairStub pair = new DexPairStub(meme, address(stock));
        pair.setReserves(1000e18, 1000e18);
        pair.setBlockTimestampLast(uint32(block.timestamp));
        portal.setGraduated(meme, address(stock), address(pair));

        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.TwapSampleFailed(PriceSource.POOL_UPDATED_THIS_BLOCK);
        vm.prank(keeper);
        assertFalse(vault.sampleTwap(), unicode"同块储备快照不能写进环");
        assertEq(vault.lastSampleAt(), 0, unicode"失败不能推进最近采样时间");

        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.TwapSampled(uint64(block.timestamp), 1e18, PriceSource.SOURCE_POOL);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"下一块读取旧储备时间戳可以采样");
    }

    /// @notice 🔴 Portal 怎么坏，keeper 的交易都不该红 —— 它一笔里可能扫很多金库。
    function test_sampleTwap_neverRevertsWhateverThePortalDoes() public {
        FlapPortalStub.Mode[4] memory modes = [
            FlapPortalStub.Mode.Revert,
            FlapPortalStub.Mode.Short,
            FlapPortalStub.Mode.BurnGas,
            FlapPortalStub.Mode.Flood
        ];

        for (uint256 i = 0; i < modes.length; i++) {
            portal.setMode(modes[i]);
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(WarrantVault.sampleTwap, ()));
            assertTrue(ok, string.concat(unicode"模式 ", vm.toString(i), unicode" 让采样 revert 了"));
            assertFalse(abi.decode(ret, (bool)));
            vm.warp(block.timestamp + sampleInterval);
        }

        portal.setMode(FlapPortalStub.Mode.Honest);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"恢复之后立刻又能采");
    }

    /// @notice 环转满一圈之后，最旧的那条被丢掉 —— 24 槽就是 24 槽。
    function test_ring_wrapsAndDropsTheOldest() public {
        _fillRing(FLAP_PRICE);
        (, uint256 flat) = _twap();
        assertEq(flat, MEME_PER_STOCK);

        // 再采满一整圈，价格翻倍 —— 老样本应当被彻底挤出去。
        portal.setCurve(meme, address(stock), FLAP_PRICE / 2);
        for (uint256 i = 0; i <= samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);
        assertEq(price, MEME_PER_STOCK * 2, unicode"整环换新之后，读数就是新价");
    }

    // ──────────────────────── 读数：fail-closed 的五种 ────────────────────────

    /// @notice 🔴 **验收第 4 条**：样本不足时读数明确失败，且原因可辨识。
    ///
    /// @dev 24 个样本点只跨 23 个小时；必须还有一小时尾段，或第 25 个时间边界，才真正覆盖完整一天。
    function test_twap_failsClosedUntilTheRingIsFull() public {
        (uint256 status, uint256 price) = _twap();
        assertEq(status, RING_NOT_FULL, unicode"刚部署：一条样本都没有");
        assertEq(price, 0, unicode"失败时价格恒为零");

        for (uint256 i = 0; i < samples - 1; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            vault.sampleTwap();

            (status, price) = _twap();
            assertEq(
                status, RING_NOT_FULL, string.concat(unicode"第 ", vm.toString(i + 1), unicode" 条之后仍然不够")
            );
            assertEq(price, 0);
        }

        vm.warp(block.timestamp + sampleInterval);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"第 24 条写得进去");

        (status, price) = _twap();
        assertEq(status, WINDOW_TOO_SHORT, unicode"🔴 第 24 条只覆盖 23 小时");
        assertEq(price, 0);

        vm.warp(block.timestamp + sampleInterval - 1);
        (status, price) = _twap();
        assertEq(status, WINDOW_TOO_SHORT, unicode"差一秒也不是完整 24 小时");
        assertEq(price, 0);

        vm.warp(block.timestamp + 1);
        (status, price) = _twap();
        assertEq(status, OK, unicode"🔴 第 24 小时完整覆盖后才可用");
        assertEq(price, MEME_PER_STOCK);
    }

    /// @notice 第 25 条写入前，左端仍由 ring 内的最旧样本覆盖，且同样必须精确裁剪。
    function test_twap_clipsTheFirstIntervalBeforeTheRingRollsOver() public {
        uint256 high = MEME_PER_STOCK * 4;
        portal.setCurve(meme, address(stock), FLAP_PRICE / 4);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        portal.setCurve(meme, address(stock), FLAP_PRICE);
        for (uint256 i = 1; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        // latest 样本位于 t0 + 23h；尾段 65 分钟刚好合法，窗口从 t0 + 5m 开始。
        vm.warp(block.timestamp + maxSampleGap);
        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);

        uint256 expected = (high * 55 minutes + MEME_PER_STOCK * (23 hours + 5 minutes)) / minWindow;
        assertEq(price, expected, unicode"🔴 未轮转时也要裁掉最旧高价窗口外的 5 分钟");
    }

    /// @notice 严格窗口左边界落在样本段中间时，只计入窗口里的那一半。
    function test_twap_clipsTheOldestIntervalAtTheTwentyFourHourCutoff() public {
        uint256 first = MEME_PER_STOCK * 2;
        uint256 last = MEME_PER_STOCK * 4;

        portal.setCurve(meme, address(stock), FLAP_PRICE / 2);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        portal.setCurve(meme, address(stock), FLAP_PRICE);
        for (uint256 i = 1; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        portal.setCurve(meme, address(stock), FLAP_PRICE / 4);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"第 25 个时间边界保存被逐出的左边界");

        vm.warp(block.timestamp + sampleInterval / 2);
        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);

        uint256 expected =
            (first * (sampleInterval / 2) + MEME_PER_STOCK * (23 * sampleInterval) + last * (sampleInterval / 2))
                / minWindow;
        assertEq(price, expected, unicode"🔴 左侧 30 分钟不能被错误地算成完整一小时");
    }

    /// @notice 第 25 次采样覆盖环槽时，仍有边界样本可计算完整的滚动窗口。
    function test_twap_staysReadyAcrossAnHourlyRollover() public {
        _fillRing(FLAP_PRICE);
        (uint256 status, uint256 before) = _twap();
        assertEq(status, OK);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 2);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        (uint256 statusAfter, uint256 after_) = _twap();
        assertEq(statusAfter, OK, unicode"覆盖最旧环槽后不能重新掉回不可用");
        assertEq(after_, before, unicode"刚写入的样本在同一瞬间权重为零");
    }

    /// @notice 采样器短暂迟到先是观测缺口；彻底停摆才是 stale。
    function test_twap_failsWhenTheNewestSampleGoesStale() public {
        _fillRing(FLAP_PRICE);

        vm.warp(block.timestamp + maxSampleGap);
        (uint256 status,) = _twap();
        assertEq(status, OK, unicode"刚好卡在最大观测间隔上还算数");

        vm.warp(block.timestamp + 1);
        (status,) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"超过最大观测间隔先 fail-closed");

        vm.warp(uint256(vault.lastSampleAt()) + maxSampleAge + 1);
        (status,) = _twap();
        assertEq(status, STALE, unicode"🔴 采样器彻底停摆才报告 stale");
    }

    /// @notice 🔴 **断采很久之后补一条**：环是满的、最新样本也很新，但窗口描述的是过去的市场。
    ///
    /// @dev 这条挡的是「环满 + 不过期」两个判据合起来仍然漏掉的那种情况 ——
    ///      也是 {WarrantVault.MAX_TWAP_WINDOW} 存在的全部理由。
    function test_twap_failsWhenTheWindowStretchesPastADay() public {
        _fillRing(FLAP_PRICE);

        vm.warp(block.timestamp + 3 days);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"补上一条新的");

        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"最新样本很新");

        (uint256 status, uint256 price) = _twap();
        assertEq(status, WINDOW_TOO_LONG, unicode"🔴 环是满的，但它记的是三天前");
        assertEq(price, 0);
    }

    /// @notice 从断采中恢复必须建立一段连续、完整的新 24 小时历史。
    function test_twap_recoversOnlyAfterAFullFreshDay() public {
        _fillRing(FLAP_PRICE);
        vm.warp(block.timestamp + 3 days);

        for (uint256 i = 0; i <= samples; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status,) = _twap();
        assertEq(status, OK, unicode"连续 25 个时间边界覆盖完整新一天后恢复");
    }

    // ──────────────────────── 读数：加权方式 ────────────────────────

    /// @notice 🔴 **验收第 3 条**：允许的小抖动仍按持续时间加权，并在 24 小时左边界精确裁剪。
    function test_twap_acceptsAValidJitterGapAndWeightsByDuration() public {
        uint256 high = MEME_PER_STOCK * 4;
        portal.setCurve(meme, address(stock), FLAP_PRICE / 4);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        // 65 分钟正好是允许的单段上限；之后恢复正常价。
        vm.warp(block.timestamp + maxSampleGap);
        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        // 共 25 个时间边界。最后时刻是 t0 + 24h + 5m，窗口从 t0 + 5m 开始：
        // 高价只贡献 60 分钟，其余 23 小时都是正常价。
        for (uint256 i = 0; i < samples - 1; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);
        uint256 expected = (high * sampleInterval + MEME_PER_STOCK * (minWindow - sampleInterval)) / minWindow;
        assertEq(price, expected, unicode"🔴 只按窗口内的真实持续时间加权");
    }

    /// @notice 高价快照即使立刻恢复，超过最大尾段间隔后也不能继续代表无人观测的时间。
    function test_twap_rejectsAHighSnapshotAfterAnOversizedTailGap() public {
        _fillRing(FLAP_PRICE);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"攻击者能抢到一个采样时刻");

        // 被采样的 spot 不是连续价格观测；撤回不会改掉已写样本。
        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.warp(block.timestamp + maxSampleGap + 1);

        (uint256 status, uint256 price) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"高价快照不能无界地延长到尾段");
        assertEq(price, 0);
    }

    /// @notice 最新样本很新也不能掩盖窗口内部一个过长的高价快照段。
    function test_twap_rejectsAnInteriorGapAboveMaxSampleGap() public {
        _fillRing(FLAP_PRICE);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"高价在一个允许时刻被采样");

        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.warp(block.timestamp + maxSampleGap + 1);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"较晚的正常样本仍可写入以便恢复");
        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"最新样本确实新鲜");

        (uint256 status, uint256 price) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"🔴 不是只检查 newest-to-now 的 stale 条件");
        assertEq(price, 0);
    }

    /// @notice 缺口会随着坏边界滚出而恢复，但需要一段完整、连续的新窗口。
    function test_twap_recoversFromAGapOnlyAfterAFullFreshDay() public {
        _fillRing(FLAP_PRICE);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap());

        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.warp(block.timestamp + maxSampleGap + 1);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());
        (uint256 status,) = _twap();
        assertEq(status, SAMPLE_GAP);

        // 当前这条正常样本作为新窗口的左边界；再连续采 24 次才覆盖完整的一天。
        for (uint256 i = 0; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (status,) = _twap();
        assertEq(status, OK, unicode"只有坏边界完全滚出后才恢复");
    }

    /// @notice 🔴 **尾段权重**：「拉盘 → 采样 → 立刻开系列」这一手在同一瞬间没有权重。
    ///
    /// @dev 最新那条样本的权重是「从它写入到 `block.timestamp`」。刚写完那一瞬间它是 0，
    ///      所以攻击者想让自己那条样本有份量，就必须等待时间流逝；他可以立刻恢复现价，但写进
    ///      环的快照仍会在允许的时间段内获得权重。
    function test_twap_theFreshestSampleCarriesNoWeightUntilTimePasses() public {
        _fillRing(FLAP_PRICE);
        (, uint256 before) = _twap();

        portal.setCurve(meme, address(stock), FLAP_PRICE / 1000); // 拉盘 1000 倍
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap());

        portal.setCurve(meme, address(stock), FLAP_PRICE);

        (uint256 status, uint256 immediately) = _twap();
        assertEq(status, OK);
        assertEq(immediately, before, unicode"🔴 同一瞬间读，那条样本一点份量都没有");

        // 等上一小时，它才拿到一小时的权重，即使现价已经恢复。
        vm.warp(block.timestamp + sampleInterval);
        (, uint256 anHourLater) = _twap();
        assertGt(anHourLater, immediately, unicode"等过之后才开始有份量");
    }

    /// @notice 🔴 **验收第 8 条的正常节奏版**：整点单次采样对 24 小时读数的影响是 1/24。
    ///
    /// @dev 这里给的是一个**定量**结论，而不是「移不动」这句话 —— 后者不成立，说出来也没用：
    ///
    ///      这个 fixture 的样本恰好每小时一条，所以任何**一条**样本恰好占 1/24 的权重。所以把读数
    ///      推高 X 倍，需要在采样那一刻把现价推高约 24X 倍（还得付买卖两道税与协议费，
    ///      本项目发射参数是 300/300 bps）。读现价的话，同样的 X 倍只要一笔交易、且卖得回去。
    ///
    ///      这条测试把「1/24」这个上界钉死：拉盘 1000 倍，读数最多变成约 42 倍
    ///      （(23 + 1000)/24 ≈ 42.6），而不是 1000 倍。允许 jitter 时的硬上界是
    ///      `MAX_SAMPLE_GAP / 24h`，由上面的有效 jitter fixture 单独覆盖。
    function test_twap_asingleSpikeIsAttenuatedByTheNumberOfSlots() public {
        _fillRing(FLAP_PRICE);
        (, uint256 calm) = _twap();

        uint256 spikeFactor = 1000;
        portal.setCurve(meme, address(stock), FLAP_PRICE / spikeFactor);

        // 攻击者拿到一条样本，并且**等满一小时**让它拿到完整权重（这是他能做到的最好情况）。
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap());
        vm.warp(block.timestamp + sampleInterval);

        (uint256 status, uint256 spiked) = _twap();
        assertEq(status, OK);

        uint256 spot = calm * spikeFactor;
        // 上界：(23 + 1000) / 24 ≈ 42.6 倍。给 1 倍的取整余量。
        uint256 bound = calm * (samples - 1 + spikeFactor) / samples + calm;
        assertLe(spiked, bound, unicode"🔴 正常整点节奏下单条样本的权重不超过 1/24");
        assertLt(spiked * 20, spot, unicode"🔴 读现价会是 1000 倍，读 TWAP 连它的 1/20 都不到");

        console2.log(
            string.concat(
                unicode"  现价 ",
                vm.toString(spot / calm),
                unicode" 倍 → 24h TWAP ",
                vm.toString(spiked / calm),
                unicode" 倍"
            )
        );
    }

    /// @notice 🔴 **无许可的代价，量出来写下来**：攻击者抢在 keeper 前面把 24 个整点采样时刻全挑走。
    ///
    /// @dev 这是 `sampleTwap()` 无许可换来的那条敞口，票面要求「写清并测」。它**不是**一次
    ///      「拉一次盘」就能完成的事：在这个正常整点 cadence 中，他要在**24 个相隔一小时的
    ///      采样时刻**分别把价格推上去。每次采样后都可以立刻恢复真实价；本测试正是这样演示完整
    ///      成功的情形。允许 jitter 时，单段硬上界由 `MAX_SAMPLE_GAP / 24h` 限制。
    ///
    ///      残余风险的处置写在 `WarrantVault.sampleTwap` 的注释里：链下 Monitor 盯
    ///      {WarrantVault.TwapSampled} 的时刻分布，长期贴着 keeper 之前一两秒就是有人在挑时刻。
    function test_twap_anAdversaryOwningEveryHourlySampleInstantCanReplaceTheReading() public {
        _fillRing(FLAP_PRICE);
        (, uint256 calm) = _twap();

        uint256 pumps;
        for (uint256 i = 0; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);

            portal.setCurve(meme, address(stock), FLAP_PRICE / 10); // 拉盘
            vm.prank(attacker);
            assertTrue(vault.sampleTwap(), unicode"攻击者抢在 keeper 前面");
            pumps++;

            portal.setCurve(meme, address(stock), FLAP_PRICE); // 立刻撤回，真实价照旧

            // keeper 这一小时的那一次就此打空 —— 这正是「谁都能采」的代价。
            vm.prank(keeper);
            assertFalse(vault.sampleTwap(), unicode"keeper 被挤掉了");
        }

        vm.warp(block.timestamp + sampleInterval);
        (uint256 status, uint256 owned) = _twap();
        assertEq(status, OK);
        assertEq(pumps, samples, unicode"🔴 正常整点窗口要拿下 24 个采样时刻，不是一次");
        assertApproxEqRel(owned, calm * 10, 0.05e18, unicode"全部时刻都被挑走时，读数确实被推上去了");
    }

    // ──────────────────────── 📝 「升级安全：布局只许追加」已删除 ────────────────────────
    //
    // 🔴 这里曾经有一条 `test_storageLayout_m2_2FieldsAreAppendedNotInserted`：它逐槽读存储，
    //    钉住 M2-2 的四个新字段确实追加在 M2-1 那四个之后。那条断言的**全部理由**是金库按
    //    beacon 代理部署 —— 往既有字段中间插一个变量，全部在世金库的存储会整体错位，
    //    而 `accountedQuote`（记账基线）读到别的东西是这类金库最危险的一种坏法。
    //
    //    决策 39-A3（issue #58）之后金库**不可升级**：没有代理，也就没有「新实现读旧存储」
    //    这件事。那条断言因此失去了对象 —— 留着它只会让任何一次善意的字段重排无理由地变红，
    //    而它保护的性质已经由「没有升级入口」这件事本身保证。
    //
    //    与它一起消失的还有 `_quoteToken` / `taxToken` 两个存储字段：它们现在是 `immutable`。

    // ──────────────────────── description() 也得跟着变 ────────────────────────

    /// @dev 规范面要求 `description()` 随状态变化。TWAP 是金库最重要的一个状态，
    ///      前端要能靠轮询它知道「这周开不开得出系列」。
    function test_description_reportsWhetherTheTwapIsUsable() public {
        string memory cold = vault.description();
        assertTrue(_hasSubstring(cold, unicode"24 小时 TWAP 不可用"), unicode"没样本时说不可用");

        _fillRing(FLAP_PRICE);

        string memory warm = vault.description();
        assertTrue(_hasSubstring(warm, unicode"24 小时 TWAP 可用"), unicode"攒满之后说可用");
        assertTrue(_hasSubstring(warm, vm.toString(block.timestamp)), unicode"带上最近一次采样时刻");
        console2.log(string.concat("  description(): ", warm));
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
}
