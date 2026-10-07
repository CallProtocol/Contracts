// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {PriceSource} from "../src/PriceSource.sol";
import {CallVault} from "../src/CallVault.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {CallVaultHarness} from "./helpers/CallVaultHarness.sol";

/// @notice `CallVault` It's... TWAP Sample and Read (%1)M2-2,issue #34).
///
/// This test is to be nailed to three sentences. They correspond to one of the acceptance clauses. CRITICAL:
///
/// 1. **Repeat call and leave the second one behind within the same hour.**  -  -  The time weights are being diluted by intensive sampling by anyone else.
///    - Put it on. 24 (a) The hourly reading is traverse to the current price;
/// 2. **Strictly read points trailing 24 Hours, maximum spacing for each segment**  -  -  Disperse spot We can't be wrongly made.
///    (b) Extension of the hourly price to unobserved;
/// 3. **The reasons for the failure are clearly identified when the sample is insufficient or gaps exist**  -  -  strike Only once a week. It's decided for the week.
///    The cost of a wrong week is much higher than the cost of a stoppage.
///
/// Source of price per se (statistical, two branches, no) revert)Yes. `test/PriceSource.t.sol`;
/// Real Portal The evidence on it is... `test/fork/RobinhoodTwapSource.t.sol`.
contract CallVaultTwapTest is Test {
    /// @dev A "normal" curve price:1e18 raw MEME Value 2e18 raw Equities  1 Stock value 0.5 Grandpa. MEME.
    uint256 internal constant FLAP_PRICE = 2e18;
    uint256 internal constant MEME_PER_STOCK = 1e36 / FLAP_PRICE;

    CallVaultHarness internal vault;
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
        // Don't start with the beginning. 0:`lastSampleAt == 0` It means "never sampled" and `block.timestamp == 0`
        // The "thou" will be the same as "never" in the assertion.
        vm.warp(1_700_000_000);

        stock = new StockToken();

        // CRITICAL Prices. Portal It's the tectonic parameter of the vault. 39-A2):The government has been working on a new strategy to improve the situation of the people of the country.
        //    No more. `etch` The one in the base class. chainId The address of the death form.
        portal = new FlapPortalStub();
        portal.setCurve(meme, address(stock), FLAP_PRICE);

        // This suite never exercises the revenue route; nonzero immutables keep the production constructor shape intact.
        vault = new CallVaultHarness(
            IClearingPool(makeAddr("unused clearing pool")),
            makeAddr("unused distributor"),
            address(portal),
            meme,
            address(stock),
            makeAddr("unused creator"),
            false
        );

        uint256[12] memory constants = vault.harnessTwapConstants();
        (samples, sampleInterval, maxSampleGap, maxSampleAge, minWindow, maxWindow) =
        (constants[0], constants[1], constants[2], constants[3], constants[4], constants[5]);
        (OK, RING_NOT_FULL, STALE, WINDOW_TOO_SHORT, WINDOW_TOO_LONG, SAMPLE_GAP) =
        (constants[6], constants[7], constants[8], constants[9], constants[10], constants[11]);
    }

    //  Scaffolding.

    /// @dev Build Available Strict 24 Hour window:25 The time limit is the last time the ring is kept. 24 Article.
    function _fillRing(uint256 flapPrice) internal {
        portal.setCurve(meme, address(stock), flapPrice);
        for (uint256 i = 0; i <= samples; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap(), unicode"That one should be in there every hour.");
        }
    }

    function _twap() internal view returns (uint256 status, uint256 price) {
        return vault.twap();
    }

    //  Sample: Writing and Tungsten

    function test_sampleTwap_writesOneSampleAndReportsTheSource() public {
        assertEq(vault.lastSampleAt(), 0, unicode"Just deployed. No samples.");

        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.TwapSampled(uint64(block.timestamp), MEME_PER_STOCK, PriceSource.SOURCE_CURVE);

        vm.prank(keeper);
        assertTrue(vault.sampleTwap());
        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"Write down the sampling time");
    }

    /// @notice CRITICAL **Receiving and Inspection No. 2 Article**:Repeated calls without writing article 2 within the same hour.
    ///
    /// @dev The choice is made by a "at least an hour away"**No, it's not.**"Push the whole barrel."
    ///      - Under the barrel. `t=3599` and `t=3601` It's all written in, and that's what the attackers use to dilute the time-weighted stitches.
    function test_sampleTwap_refusesASecondSampleBeforeAFullHour() public {
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());
        uint64 firstAt = vault.lastSampleAt();

        // And then the same block is re-routed -- anyone can, and nothing should happen.
        vm.prank(attacker);
        assertFalse(vault.sampleTwap(), unicode"Same block.");
        assertEq(vault.lastSampleAt(), firstAt);

        vm.warp(block.timestamp + sampleInterval - 1);
        vm.prank(attacker);
        assertFalse(vault.sampleTwap(), unicode"Not even a second.");
        assertEq(vault.lastSampleAt(), firstAt, unicode"CRITICAL No second, no moment.");

        vm.warp(block.timestamp + 1);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"In an hour.");
        assertEq(vault.lastSampleAt(), uint64(block.timestamp));
    }

    /// @notice CRITICAL Intensive sampling does not dilute the time weight -- this is the rule.**Reasons for existence**,- One test alone.
    ///
    /// @dev The attack scene: the ring is full. 24 A normal price. The attackers raise the price and then they'll be in a few seconds.
    ///      `sampleTwap()`,You want to change the whole ring to a high price. The minimum interval makes him have to change one more item per hour.
    function test_sampleTwap_burstCannotRefillTheRing() public {
        _fillRing(FLAP_PRICE);
        (, uint256 before) = _twap();

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100); // MEME Cheap. 100 Double = Equities are expensive. 100 Double
        vm.warp(block.timestamp + sampleInterval);

        vm.startPrank(attacker);
        assertTrue(vault.sampleTwap(), unicode"The first one can be written.");
        for (uint256 i = 0; i < 200; i++) {
            vm.warp(block.timestamp + 12); // One block, one block.
            assertFalse(vault.sampleTwap(), unicode"CRITICAL I can't write one in an hour.");
        }
        vm.stopPrank();

        (uint256 status, uint256 after_) = _twap();
        assertEq(status, OK);
        // 40 Only one has been replaced in the minute. The readings will certainly move, but the "return price" will be the last one.100 Two orders of magnitude.
        assertLt(after_, before * 5, unicode"CRITICAL 200 I'm afraid I've only bought one sample.");
        console2.log(
            string.concat(
                unicode"  Intensive sampling before and after:", vm.toString(before), unicode" -> ", vm.toString(after_)
            )
        );
    }

    /// @notice When price is not available: do not write, send events, return false,And...**No, no. revert**.
    function test_sampleTwap_failureIsAnEventNotARevert() public {
        portal.setMode(FlapPortalStub.Mode.Revert);

        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.TwapSampleFailed(PriceSource.PORTAL_UNREADABLE);

        vm.prank(keeper);
        assertFalse(vault.sampleTwap());
        assertEq(vault.lastSampleAt(), 0, unicode"Nothing.");
    }

    /// @notice When the graduation pool is updated, the vault must treat it as a missing stock; the next block can be retried normally.
    function test_sampleTwap_rejectsAPoolUpdatedThisBlockAndRetriesLater() public {
        DexPairStub pair = new DexPairStub(meme, address(stock));
        pair.setReserves(1000e18, 1000e18);
        pair.setBlockTimestampLast(uint32(block.timestamp));
        portal.setGraduated(meme, address(stock), address(pair));

        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.TwapSampleFailed(PriceSource.POOL_UPDATED_THIS_BLOCK);
        vm.prank(keeper);
        assertFalse(vault.sampleTwap(), unicode"The same reserve snapshot cannot be written in the ring.");
        assertEq(vault.lastSampleAt(), 0, unicode"Failure cannot advance the latest sampling time");

        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.TwapSampled(uint64(block.timestamp), 1e18, PriceSource.SOURCE_POOL);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"The next piece reads the old stock time stamp and can be sampled.");
    }

    /// @notice CRITICAL Portal How bad is it?keeper Neither of the deals should be red -- it could sweep a lot of vaults in one piece.
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
            (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(CallVault.sampleTwap, ()));
            assertTrue(ok, string.concat(unicode"Mode ", vm.toString(i), unicode" Let the sample revert Yes."));
            assertFalse(abi.decode(ret, (bool)));
            vm.warp(block.timestamp + sampleInterval);
        }

        portal.setMode(FlapPortalStub.Mode.Honest);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"Once it's recovered, it's ready to be picked up.");
    }

    /// @notice And then, after a circle, the oldest one was thrown away... 24 The slot is... 24 Slot.
    function test_ring_wrapsAndDropsTheOldest() public {
        _fillRing(FLAP_PRICE);
        (, uint256 flat) = _twap();
        assertEq(flat, MEME_PER_STOCK);

        // And then we'll take a whole circle and double the price -- the old samples should be completely squeezed out.
        portal.setCurve(meme, address(stock), FLAP_PRICE / 2);
        for (uint256 i = 0; i <= samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);
        assertEq(price, MEME_PER_STOCK * 2, unicode"After the whole ring is changed, the reading is the new price.");
    }

    //  Read:fail-closed Five.

    /// @notice CRITICAL **Receiving and Inspection No. 4 Article**:The sample failed clearly when it was under-readable and the reasons were identifiable.
    ///
    /// @dev 24 A sample point is only crossed. 23 hour; must be an hour's end, or no. 25 A time boundary that really covers the whole day.
    function test_twap_failsClosedUntilTheRingIsFull() public {
        (uint256 status, uint256 price) = _twap();
        assertEq(status, RING_NOT_FULL, unicode"Just deployed: none of the samples");
        assertEq(price, 0, unicode"Prices are constant zero when failure");

        for (uint256 i = 0; i < samples - 1; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            vault.sampleTwap();

            (status, price) = _twap();
            assertEq(
                status,
                RING_NOT_FULL,
                string.concat(unicode"I'm sorry. ", vm.toString(i + 1), unicode" It's not enough after the article.")
            );
            assertEq(price, 0);
        }

        vm.warp(block.timestamp + sampleInterval);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"I'm sorry. 24 It's got to be written in.");

        (status, price) = _twap();
        assertEq(status, WINDOW_TOO_SHORT, unicode"CRITICAL I'm sorry. 24 Only covers the article 23 Hours");
        assertEq(price, 0);

        vm.warp(block.timestamp + sampleInterval - 1);
        (status, price) = _twap();
        assertEq(status, WINDOW_TOO_SHORT, unicode"It's not complete for a second. 24 Hours");
        assertEq(price, 0);

        vm.warp(block.timestamp + 1);
        (status, price) = _twap();
        assertEq(status, OK, unicode"CRITICAL I'm sorry. 24 Only after full hour coverage");
        assertEq(price, MEME_PER_STOCK);
    }

    /// @notice I'm sorry. 25 Before writing, left is still left ring The oldest sample is covered and must be fine-tuned.
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

        // latest Sample in t0 + 23h;End 65 The minutes are just as legitimate. The window is from t0 + 5m Start.
        vm.warp(block.timestamp + maxSampleGap);
        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);

        uint256 expected = (high * 55 minutes + MEME_PER_STOCK * (23 hours + 5 minutes)) / minWindow;
        assertEq(price, expected, unicode"CRITICAL And cut off the old ones from the old ones. 5 min");
    }

    /// @notice When the left boundary of the strict window falls in the middle of the sample segment, only the half of the window is counted.
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
        assertTrue(vault.sampleTwap(), unicode"I'm sorry. 25 Time boundary to preserve the expelled left border");

        vm.warp(block.timestamp + sampleInterval / 2);
        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);

        uint256 expected =
            (first * (sampleInterval / 2) + MEME_PER_STOCK * (23 * sampleInterval) + last * (sampleInterval / 2))
                / minWindow;
        assertEq(price, expected, unicode"CRITICAL Left 30 Minutes cannot be miscalculated as full hour.");
    }

    /// @notice I'm sorry. 25 When subsampling the ring slots, there are still boundary samples that can calculate the full scroll window.
    function test_twap_staysReadyAcrossAnHourlyRollover() public {
        _fillRing(FLAP_PRICE);
        (uint256 status, uint256 before) = _twap();
        assertEq(status, OK);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 2);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        (uint256 statusAfter, uint256 after_) = _twap();
        assertEq(statusAfter, OK, unicode"Cannot fall back after covering the old ring slot.");
        assertEq(after_, before, unicode"The sample just written weighs zero in the same instant.");
    }

    /// @notice The sampler is short-term late, first, to observe the gap; then to be completely disabled. stale.
    function test_twap_failsWhenTheNewestSampleGoesStale() public {
        _fillRing(FLAP_PRICE);

        vm.warp(block.timestamp + maxSampleGap);
        (uint256 status,) = _twap();
        assertEq(status, OK, unicode"It's just stuck to the maximum observation interval.");

        vm.warp(block.timestamp + 1);
        (status,) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"First, beyond maximum observation intervals fail-closed");

        vm.warp(uint256(vault.lastSampleAt()) + maxSampleAge + 1);
        (status,) = _twap();
        assertEq(status, STALE, unicode"CRITICAL The sampler is completely disabled. stale");
    }

    /// @notice CRITICAL **One after a long time.**:The full ring, the latest sample, is new, but the window describes the market in the past.
    ///
    /// @dev This is the "Twink of the Rings." + But the two sentences still go missing -
    ///      Yeah. {CallVault.MAX_TWAP_WINDOW} All the reasons for it.
    function test_twap_failsWhenTheWindowStretchesPastADay() public {
        _fillRing(FLAP_PRICE);

        vm.warp(block.timestamp + 3 days);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"Add a new one.");

        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"The latest sample is new.");

        (uint256 status, uint256 price) = _twap();
        assertEq(status, WINDOW_TOO_LONG, unicode"CRITICAL The ring is full, but it remembers three days ago.");
        assertEq(price, 0);
    }

    /// @notice Recovery from cutting must create a continuous, complete new phase 24 Hour history.
    function test_twap_recoversOnlyAfterAFullFreshDay() public {
        _fillRing(FLAP_PRICE);
        vm.warp(block.timestamp + 3 days);

        for (uint256 i = 0; i <= samples; i++) {
            if (i != 0) vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status,) = _twap();
        assertEq(status, OK, unicode"Continuous 25 Recovery after a full new day of time border cover");
    }

    //  Read: Weighted

    /// @notice CRITICAL **Receiving and Inspection No. 3 Article**:Allowed small shakings to remain weighted by duration and 24 Hour left border precise cropping.
    function test_twap_acceptsAValidJitterGapAndWeightsByDuration() public {
        uint256 high = MEME_PER_STOCK * 4;
        portal.setCurve(meme, address(stock), FLAP_PRICE / 4);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        // 65 The minutes are exactly the permitted single-part ceiling; then the prices return to normal.
        vm.warp(block.timestamp + maxSampleGap);
        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap());

        // Total 25 A time boundary. Last moment is... t0 + 24h + 5m,Window from t0 + 5m Other Organiser
        // The price is higher. 60 Minutes, the rest 23 Hours are normal.
        for (uint256 i = 0; i < samples - 1; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (uint256 status, uint256 price) = _twap();
        assertEq(status, OK);
        uint256 expected = (high * sampleInterval + MEME_PER_STOCK * (minWindow - sampleInterval)) / minWindow;
        assertEq(price, expected, unicode"CRITICAL Weighted only by the true duration of the window");
    }

    /// @notice High-priced snapshots, even if restored immediately, cannot continue to represent the time of no-observed observations beyond the maximum end-stage interval.
    function test_twap_rejectsAHighSnapshotAfterAnOversizedTailGap() public {
        _fillRing(FLAP_PRICE);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"The attackers can get a sample moment.");

        // - Samped. spot Not continuous price observations; withdrawal will not modify the written sample.
        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.warp(block.timestamp + maxSampleGap + 1);

        (uint256 status, uint256 price) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"The high-priced snapshot cannot be extended to the end without a limit.");
        assertEq(price, 0);
    }

    /// @notice The latest sample is new and does not mask an excessively high price snapshot inside the window.
    function test_twap_rejectsAnInteriorGapAboveMaxSampleGap() public {
        _fillRing(FLAP_PRICE);

        portal.setCurve(meme, address(stock), FLAP_PRICE / 100);
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap(), unicode"They're being sampled at a time when they're allowed.");

        portal.setCurve(meme, address(stock), FLAP_PRICE);
        vm.warp(block.timestamp + maxSampleGap + 1);
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"The later normal samples can still be written to restore");
        assertEq(vault.lastSampleAt(), uint64(block.timestamp), unicode"The latest samples are fresh.");

        (uint256 status, uint256 price) = _twap();
        assertEq(status, SAMPLE_GAP, unicode"CRITICAL Not just checking. newest-to-now It's... stale Conditions");
        assertEq(price, 0);
    }

    /// @notice The gap would be restored as the bad border rolled out, but a full, continuous new window was needed.
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

        // The current normal sample is the left boundary of the new window; then taken continuously 24 The day is covered only once.
        for (uint256 i = 0; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap());
        }

        (status,) = _twap();
        assertEq(status, OK, unicode"Only when the bad border is completely rolled out.");
    }

    /// @notice CRITICAL **End-sector weight**:Pull -> Sample -> The first time that the project was launched, the first time that the project was launched, the first time that the project was launched, the second time the project was launched, the second time the project was launched, the second time the project was launched, the second time the project was launched, the second time the project was launched, the second time the project was launched, and the second time the project was launched, the second time the project was launched, the second time the project was launched, the second time the project was launched, the second time the first time the project was launched, the second time the first time the project was launched, the second time the project was launched, the second time the first time the project was launched, the second-staged series was launched, the second-staged series was launched, and the second-time, the second-time, the second-time, the first-time, the first-time, the first-time, the first-time, the first-time, the hand had no weight.
    ///
    /// @dev The most recent sample has a weight of "from it to the writing." `block.timestamp`.It was just a moment after it was written. 0,
    ///      So the assailant had to wait for time to get his sample to matter; he could immediately recover the price, but write it in.
    ///      The snapshot of the ring will still receive weights within the permitted time frame.
    function test_twap_theFreshestSampleCarriesNoWeightUntilTimePasses() public {
        _fillRing(FLAP_PRICE);
        (, uint256 before) = _twap();

        portal.setCurve(meme, address(stock), FLAP_PRICE / 1000); // Pull 1000 Double
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap());

        portal.setCurve(meme, address(stock), FLAP_PRICE);

        (uint256 status, uint256 immediately) = _twap();
        assertEq(status, OK);
        assertEq(immediately, before, unicode"CRITICAL I read it the same instant. The sample didn't matter.");

        // It waited an hour to get an hour weight, even if the current price had recovered.
        vm.warp(block.timestamp + sampleInterval);
        (, uint256 anHourLater) = _twap();
        assertGt(anHourLater, immediately, unicode"It's not gonna start to matter until after that.");
    }

    /// @notice CRITICAL **Receiving and Inspection No. 8 Normal rhythm of bars**:Single sample of the whole point 24 The effect of hourly readings is that 1/24.
    ///
    /// @dev Here's a gift for a guy.**Quantification**The conclusion, not the "scramble" word -- the latter is not valid, and it's useless to say it:
    ///
    ///      This. fixture The sample happens to be one hour each, so any**One.**The sample is just as good. 1/24 . So put the readings
    ///      Push up. X Double. We need to push the price up at the moment of sampling. 24X The government has been able to pay two taxes and agreements for the sale of goods, and has been able to pay for the sale of goods.
    ///      The project launch parameters are: 300/300 bps).If you read the current price, the same. X The government has been able to sell the goods to the government, but the government has not yet made any payments.
    ///
    ///      This test is "The Tester"1/24This upper border is crucified: a tractor. 1000 Double. Reads are about the same. 42 Double
    ///      ((23 + 1000)/24  42.6),Not 1000 Double. Allowed. jitter The hard-on is
    ///      `MAX_SAMPLE_GAP / 24h`,It's working from above. jitter fixture Covers separately.
    function test_twap_asingleSpikeIsAttenuatedByTheNumberOfSlots() public {
        _fillRing(FLAP_PRICE);
        (, uint256 calm) = _twap();

        uint256 spikeFactor = 1000;
        portal.setCurve(meme, address(stock), FLAP_PRICE / spikeFactor);

        // The assailants got a sample and**Wait an hour.**It's the best thing he can do.
        vm.warp(block.timestamp + sampleInterval);
        vm.prank(attacker);
        assertTrue(vault.sampleTwap());
        vm.warp(block.timestamp + sampleInterval);

        (uint256 status, uint256 spiked) = _twap();
        assertEq(status, OK);

        uint256 spot = calm * spikeFactor;
        // Upper boundary:(23 + 1000) / 24  42.6 Double. Here. 1 Double the balance.
        uint256 bound = calm * (samples - 1 + spikeFactor) / samples + calm;
        assertLe(
            spiked,
            bound,
            unicode"CRITICAL The weight of a single sample at normal whole point rhythm does not exceed 1/24"
        );
        assertLt(
            spiked * 20,
            spot,
            unicode"CRITICAL It's gonna be the spot price. 1000 Double, read. TWAP Even it. 1/20 Not even a few."
        );

        console2.log(
            string.concat(
                unicode"  Current price ",
                vm.toString(spot / calm),
                unicode" Double -> 24h TWAP ",
                vm.toString(spiked / calm),
                unicode" Double"
            )
        );
    }

    /// @notice CRITICAL **Take the price of the permit and write it down.**:The attackers are in the middle of a fight. keeper Front. 24 The whole spot was taken.
    ///
    /// @dev This is... `sampleTwap()` The open one that you can't get, the front page says "write and measure."**No, it's not.**Once.
    ///      "One drive at a time, and it's done: at this point in the normal world, cadence Yes, he's going to**24 An hour apart.
    ///      Sample Time**Push the price up. You can recover the real price immediately after each sample. This is how this test is done.
    ///      Success scenario. Allowed. jitter , single-part hard-up by `MAX_SAMPLE_GAP / 24h` Limit.
    ///
    ///      The disposal of residual risk is written in `CallVault.sampleTwap` In the note: Under the chain Monitor Watch.
    ///      {CallVault.TwapSampled} The time distribution, long-term attachment. keeper One or two seconds ago was the moment of the pick.
    function test_twap_anAdversaryOwningEveryHourlySampleInstantCanReplaceTheReading() public {
        _fillRing(FLAP_PRICE);
        (, uint256 calm) = _twap();

        uint256 pumps;
        for (uint256 i = 0; i < samples; i++) {
            vm.warp(block.timestamp + sampleInterval);

            portal.setCurve(meme, address(stock), FLAP_PRICE / 10); // Pull
            vm.prank(attacker);
            assertTrue(vault.sampleTwap(), unicode"The attackers are in the middle of a fight. keeper Front");
            pumps++;

            portal.setCurve(meme, address(stock), FLAP_PRICE); // Revert it now. The real price is the same.

            // keeper This time of the hour, it was empty -- that's the price of "everyone can take."
            vm.prank(keeper);
            assertFalse(vault.sampleTwap(), unicode"keeper It's been squeezed out.");
        }

        vm.warp(block.timestamp + sampleInterval);
        (uint256 status, uint256 owned) = _twap();
        assertEq(status, OK);
        assertEq(
            pumps, samples, unicode"CRITICAL The normal whole window is to be taken down. 24 A sample time, not once."
        );
        assertApproxEqRel(owned, calm * 10, 0.05e18, unicode"When all the time, the readings were pushed up.");
    }

    //   Upgrade security: layout only adds "deleted
    //
    // CRITICAL There was one here. `test_storageLayout_m2_2FieldsAreAppendedNotInserted`:It reads the storage by slot.
    //    Stuck it. M2-2 The four new fields are indeed added to M2-1 After those four. That's the one that said it.**All reasons**It's the vault.
    //    beacon Agent deployment - insert a variable in the middle of an existing field, all stored in the World Bank is completely misplaced.
    //    And... `accountedQuote`(Reading something else is the most dangerous way to do this kind of vault.
    //
    //    Decision-making 39-A3(issue #58)After the vault.**Ungradable**:There's no proxy, and there's no "new realization old memory."
    //    This is the thing. The claim is lost -- it's only gonna redact any good-faith field for no reason.
    //    The nature of its protection is already guaranteed by the fact that there is no upgrade of the entrance itself.
    //
    //    And then there's the other thing that disappears with it. `_quoteToken` / `taxToken` Two storage fields: they're now `immutable`.

    //  description() And it's gonna change.

    /// @dev Normative requirements `description()` With the state.TWAP It's the most important state of the vault.
    ///      The front end needs to be able to ask it "to come up with a series this week."
    function test_description_reportsWhetherTheTwapIsUsable() public {
        string memory cold = vault.description();
        assertTrue(
            _hasSubstring(cold, unicode"24h TWAP unavailable"), unicode"No samples should report TWAP as unavailable"
        );

        _fillRing(FLAP_PRICE);

        string memory warm = vault.description();
        assertTrue(
            _hasSubstring(warm, unicode"24h TWAP ready"), unicode"A complete sample window should report TWAP as ready"
        );
        assertTrue(_hasSubstring(warm, vm.toString(block.timestamp)), unicode"Take the last sample.");
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
