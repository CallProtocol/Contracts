// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {CallVault} from "../src/CallVault.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {CallVaultHarness} from "./helpers/CallVaultHarness.sol";

/// @notice **M2-4 Open the line.**(issue #36):strike Price, Friday alignment and discontinuation are visible.
///
/// This test will nail five things. They're the ones in the acceptance clause. CRITICAL:
///
/// 1. **`strike = TWAP  0.8`,And measure the outline and `ClearingPool.exercise` It's...
///    `amount * strike / 1e18` Unanimously**  -  -  The latter is not written on both sides of the note.
///    {test_strike_isTheSameNumberTheClearingPoolChargesOnExercise} The government has been working hard to get the government to the end of the war.
///    Take one.**From the product caliber.** MEME The reconciliation of amounts. This is the easiest and most expensive mistake of a promissory note:
///    strike A full week's certificate is either a free pass or no one will ever have the right to move.
/// 2. **Due on Friday. 21:00 UTC,And life. >=7 Oh, my God.**  -  -  The expectation is...**A real calendar stamp for writing a death on its own**
///    (By UTC The calendar is calculated, not to be read from the test contract) and each test proves that the hysteria and the summer are not to be changed.
/// 3. **If you don't have enough samples, you refuse to open the series.**  -  -  {twap} In six states, there's only one. `TWAP_OK` Let go.
///    Not one of them is a bad number. strike.
/// 4. **Repeating calls in the same week is not allowed to produce a second series.**  -  -  Not "may not" but a whole week of shifts every hour.
/// 5. **Unscheduled series can be found under the chain.**  -  -  {CallVault-openSeriesStatus} It's one. view:
///    It is not necessary to make a deal, nor to wait until it fails, to say, "Did this period come out, why did it not?"
///
/// TWAP How did it come in itself? `test/CallVaultTwap.t.sol`;
/// Real Portal And the truth. GME The one on the top. `test/fork/RobinhoodOpenSeries.t.sol`.
///
/// CRITICAL Pools, certificates, distribution of contracts, registration forms for declarations**It's all true.**(issue #5 The core of the note is over the vault and over the other side of the vault.
/// The boundary of the pool -- "The vault calculated it." strike I'm taking it with Ikeko. MEME "It's the same number," said Makoto.
contract CallVaultOpenSeriesTest is Test {
    /// @dev CRITICAL Write it all alone, not read it. `pool.BURN_ADDRESS()`  -  -  It's not gonna prove anything by testing the target's own constant.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    //  CRITICAL Calendar due: Real Friday for independent writing of death 21:00 UTC
    //
    // Every one of them. UTC Calendar Count`date -u -d "2026-08-14 21:00:00" +%s`),**Not from the contract.**.
    // The contract says, "I'm not going to do it."Unix The era is Thursday, so Friday. 21:00 = Within Week Offset 45 "hours" ; here's the text.
    // 2026-08-14 21:00 UTC It's a Friday. Two words are not shared, and they're proof.

    uint64 internal constant FRI_AUG_14 = 1_786_741_200; // 2026-08-14 21:00 UTC Friday.
    uint64 internal constant FRI_AUG_21 = 1_787_346_000; // 2026-08-21 21:00 UTC Friday.
    uint64 internal constant FRI_AUG_28 = 1_787_950_800; // 2026-08-28 21:00 UTC Friday.
    uint64 internal constant FRI_SEP_04 = 1_788_555_600; // 2026-09-04 21:00 UTC Friday.

    /// @dev The one in the year-old... 2027-01-01 It happens to be Friday, and it's a chord of proof that it doesn't look like it's years.
    uint64 internal constant FRI_DEC_25 = 1_798_232_400; // 2026-12-25 21:00 UTC Friday.
    uint64 internal constant FRI_JAN_01 = 1_798_837_200; // 2027-01-01 21:00 UTC Friday.

    /// @dev Weeks of seconds and Fridays 21:00 week-by-week deviation.**Write it all on its own.**:`7 * 86400` and `45 * 3600`.
    uint256 internal constant WEEK_SECONDS = 604_800;
    uint256 internal constant FRIDAY_2100_OFFSET = 162_000;

    //  CRITICAL Pricing: a group of people who can calculate
    //
    // Flap It's... `price` It's "1e18 raw MEME What's it worth? raw "Share tokens," we want a down-to-down outline.
    // Remove `5e14` The whole chain is a whole number, and it's a simple sight:
    //
    //   1e36 / 5e14 = 2e21 = 2000e18    1 Stock shares = 2000 Quantum MEME
    //   2000e18  0.8 = 1600e18         strike(Every 1e18 raw The stock is burned. MEME)
    //   Right to exercise authority 3 Stock shares  3e18  1600e18 / 1e18 = 4800e18 Quantum MEME
    //
    // The last one. 4800e18 It's the only really important number in this paper. It's...**Not by any contract.**.

    uint256 internal constant FLAP_PRICE = 5e14;
    uint256 internal constant MEME_PER_STOCK = 2000e18;
    uint128 internal constant EXPECTED_STRIKE = 1600e18;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;

    CallVaultHarness internal vault;
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
        // Start: Friday 21:00 Before 25 Hours.{_bootstrapRing} I'll take this. 24 The time was full of samples.
        // So the first time the series started was in...**Friday. 20:00**  -  -  Exactly. spec 6.2 The Friday. 21:00 UTC "Foreign time series."
        vm.warp(FRI_AUG_14 - 25 hours);

        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        meme = new MemeToken();
        stock = new StockToken();

        // CRITICAL Prices. Portal It's from the vault.**Construct Parameters**(Decision-making 39-A2),So here's a double, send in the address.
        //    No more. `etch` The one in the base class. chainId The address of the death form.
        portal = new FlapPortalStub();
        portal.setCurve(address(meme), address(stock), FLAP_PRICE);

        vault = new CallVaultHarness(
            pool, address(distributor), address(portal), address(meme), address(stock), makeAddr("creator"), false
        );
        factory.bind(address(meme), address(vault));

        assertEq(
            address(pool.vaultRegistry()),
            address(factory.registry()),
            unicode"Ikeko's name is the same root of identity written in the factory."
        );
        assertEq(factory.registry().vaultOf(address(meme)), address(vault), unicode"MEME Tie to the principal vault.");

        uint256[9] memory openConstants = vault.harnessOpenConstants();
        (OPEN_OK, ALREADY_OPEN, TOO_EARLY, TWAP_UNAVAILABLE, STRIKE_ROUNDS_TO_ZERO, STRIKE_TOO_LARGE) =
        (openConstants[0], openConstants[1], openConstants[2], openConstants[3], openConstants[4], openConstants[5]);
        (openWindow, minLifetime) = (openConstants[6], openConstants[7]);
        assertEq(openConstants[8], 8000, unicode"Decision-making 14:k = 0.8,That's it. 8000 Basepoint");
    }

    //  Scaffolding.

    /// @dev Fill a available strict 24 Hour window:25 The time limit is the last time the ring is kept. 24 Article.
    ///      End of period `block.timestamp` It's just the beginning. + 24 Hours.
    function _bootstrapRing() internal {
        vm.prank(keeper);
        assertTrue(vault.sampleTwap(), unicode"First sample");
        for (uint256 i = 0; i < 24; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            assertTrue(vault.sampleTwap(), unicode"That one should be in there every hour.");
        }
    }

    /// @dev Like real. keeper Same thing every hour, all the way to the place. `target`.The window is always fresh...
    ///      But if anyone shows up in this test, TWAP Failure, it should be.**Tests for intentional manufacture**Not the axis of time.
    function _keepSamplingUntil(uint256 target) internal {
        while (block.timestamp + 1 hours <= target) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            vault.sampleTwap();
        }
        if (block.timestamp < target) vm.warp(target);
    }

    /// @dev One's a good ring, standing on Friday. 20:00 Other Organiser - The starting point for most of the tests in this document.
    function _readyAtFridayEvening() internal {
        _bootstrapRing();
        assertEq(block.timestamp, FRI_AUG_14 - 1 hours, unicode"The starting point should be Friday. 20:00");
    }

    function _status() internal view returns (uint256 status, uint64 expiry, uint128 nextStrike) {
        return vault.openSeriesStatus();
    }

    //  1. Due: Friday 21:00 UTC Alignment

    /// @notice CRITICAL **Receiving and Inspection No. 3 Article**:Due on Friday. 21:00 UTC,The expectation is the real calendar time stamp of death.
    ///
    /// @dev Five sampling points cover different locations in a week. Each expected value is the constant of the table above --
    ///      The test never counted "when Friday is."
    function test_expiry_landsOnTheCalendarFridayAt2100Utc() public view {
        // Friday. 20:00:There's only one hour left on Friday. Press. >=7 The rules of the day are in the order of the day.**Next.**Friday.
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 - 1 hours), FRI_AUG_21);
        // Saturday, Monday, Wednesday -- how to move in a week, where the drop is still Friday.
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 15 hours), FRI_AUG_28, unicode"Saturday, noon.");
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 3 days), FRI_AUG_28, unicode"Monday.");
        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 5 days), FRI_AUG_28, unicode"Wednesday");
        // Over the years:2027-01-01 It's also Friday, and the alignment rule doesn't look like a year.
        assertEq(vault.harnessNextExpiry(FRI_DEC_25 - 1 hours), FRI_JAN_01, unicode"The week of the New Year.");
    }

    /// @notice CRITICAL **Receiving and Inspection No. 3 The other half of the article.**:`expiry  now >= 7 Oh, my God.`,And the border is up. `>=` Not `>`.
    ///
    /// @dev It's the closest Friday. <7 The point of the rule is that it is the only one that can make a mistake:
    ///      One second early. 7 The whole sky (dismissal) must be pushed one second later by a full week, otherwise the certificate of right, which was cast near Friday, will expire at birth.
    function test_expiry_takesTheNextFridayAsSoonAsSevenDaysNoLongerFits() public view {
        assertEq(
            vault.harnessNextExpiry(FRI_AUG_14),
            FRI_AUG_21,
            unicode"It's Friday. 21:00:Life expectancy is perfect. 7 Oh, my God."
        );
        assertEq(FRI_AUG_21 - FRI_AUG_14, 7 days, unicode"And... 7 Sky is the one that lets go.>=,No, it's not. >)");

        assertEq(vault.harnessNextExpiry(FRI_AUG_14 + 1), FRI_AUG_28, unicode"One second later, a week later.");
        assertEq(FRI_AUG_28 - (FRI_AUG_14 + 1), 14 days - 1, unicode"So this time of year 14 One second.");
    }

    /// @notice It's always a Friday. 21:00 UTC,Life is forever lost. `[7 Oh, my God., 14 Oh, my God.)`.
    /// @dev Evaluation**Write it all on its own.**It's... `604800` / `162000` Express, not citing two constants in the contract.
    function testFuzz_expiry_isAlwaysAFridayWithAtLeastSevenDaysOfLife(uint64 raw) public view {
        uint256 nowTs = bound(uint256(raw), 1, uint256(type(uint64).max) - 30 days);
        uint256 expiry = vault.harnessNextExpiry(nowTs);

        assertEq(expiry % WEEK_SECONDS, FRIDAY_2100_OFFSET, unicode"Friday. 21:00 UTC Other Organiser");
        assertGe(expiry - nowTs, minLifetime, unicode"CRITICAL Life expectancy shall not be less than 7 Oh, my God.");
        assertLt(expiry - nowTs, 14 days, unicode"And it shouldn't be unnecessary to push it to another week.");
    }

    /// @notice CRITICAL **Synchronising folder failed: %s: %s**
    ///
    /// @dev The blogger says that the government is not "presumably not affecting":Unix Time**By definition**The second count is not counted,1972 Every second that has been inserted since
    ///      None of them are in this number. So the real thing to say is, "In the second, two of them are due."
    ///      Still precise difference 604800 Seconds -- the last time you took it was inserted.2016-12-31 23:59:60 UTC).
    ///
    ///      In turn: If someone changes the calendar to a calendar one day,**Yes.**The time is right, the time is right.
    function test_expiry_isUnaffectedByLeapSeconds() public view {
        uint64 friBeforeLeapSecond = 1_483_131_600; // 2016-12-30 21:00 UTC Friday.
        uint64 friAfterLeapSecond = 1_483_736_400; // 2017-01-06 21:00 UTC Friday.
        assertEq(
            friAfterLeapSecond - friBeforeLeapSecond,
            WEEK_SECONDS,
            unicode"The seconds are not here. Unix Take the place in the count."
        );

        // The point of landing remains two Fridays, one before and the other after the second.
        assertEq(vault.harnessNextExpiry(friBeforeLeapSecond - 1 hours), friBeforeLeapSecond + uint64(WEEK_SECONDS));
        assertEq(vault.harnessNextExpiry(friAfterLeapSecond - 1 hours), friAfterLeapSecond + uint64(WEEK_SECONDS));
    }

    /// @notice CRITICAL **The calendar is not changed during the summer.**
    ///
    /// @dev And it's not "likely not" either: **UTC**,And... UTC There is no summer by definition.
    ///      Remove 2026 Four real trades in the year (USA) 3/8,European Union 3/29,European Union 10/25,United States 11/1)The government is not going to be able to get the money.
    ///      The two adjacent issues are still accurate. 604800 The second -- the local clock dialed for an hour, and our calendar didn't move a second.
    function test_expiry_isUnaffectedByDaylightSaving() public view {
        uint64[4] memory fridayBeforeSwitch = [
            uint64(1_772_830_800), // 2026-03-06,United States 3/8 Before spring switch
            uint64(1_774_645_200), // 2026-03-27,European Union 3/29 Before spring switch
            uint64(1_792_789_200), // 2026-10-23,European Union 10/25 Before the fall switch
            uint64(1_793_394_000) // 2026-10-30,United States 11/1 Before the fall switch
        ];

        for (uint256 i = 0; i < fridayBeforeSwitch.length; i++) {
            uint64 before = fridayBeforeSwitch[i];
            assertEq(
                uint256(before) % WEEK_SECONDS,
                FRIDAY_2100_OFFSET,
                unicode"The sampling point itself has to be Friday. 21:00 UTC"
            );

            uint64 first = vault.harnessNextExpiry(before - 1 hours);
            uint64 second = vault.harnessNextExpiry(before - 1 hours + uint256(WEEK_SECONDS));
            assertEq(
                second - first,
                uint64(WEEK_SECONDS),
                unicode"Switches over summer, and the two dates are still one week apart."
            );
        }
    }

    //  2. Right-of-hand prices:TWAP  0.8

    /// @notice CRITICAL **Receiving and Inspection No. 1 Article**:`strike = TWAP  0.8`.
    function test_openSeries_locksTheStrikeAtEightyPercentOfTheTwap() public {
        _readyAtFridayEvening();

        (uint256 twapStatus, uint256 price) = vault.twap();
        assertEq(twapStatus, 0, unicode"The rings are full. Reads should be available.");
        assertEq(
            price, MEME_PER_STOCK, unicode"1 Stock shares = 2000 Quantum MEME  -  -  By Flap It's... price Countdown"
        );

        vm.prank(keeper);
        (uint256 seriesId, bool opened) = vault.openSeries();

        assertTrue(opened);
        assertEq(vault.strike(), EXPECTED_STRIKE, unicode"2000  0.8 = 1600");
        assertEq(vault.seriesExpiry(), FRI_AUG_21);
        assertEq(pool.series(seriesId).strike, EXPECTED_STRIKE, unicode"The same number is locked in the pool.");
    }

    /// @notice CRITICAL **Receiving and Inspection No. 2 - The most expensive one.**:The vault. `strike`,and
    ///         `ClearingPool.exercise` Press `amount * strike / 1e18` Take it away. MEME,It's the same scale.
    ///
    /// # Why must we go all the way to the right, not two fields?
    ///
    /// The same scale is not "two." `uint128` "Equity." The caliber on the vault is:**Every 1e18 raw What's the value of the shares? raw MEME**,
    /// The caliber on the pool is...**Right to exercise authority `amount` How much do I need to burn? raw MEME**;Only the real thing. MEME The balance is reduced once.
    /// It's two calibers that are actually being matched. The amount claimed is from the product caliber.**It's an independent calculation.**:
    ///
    /// > 1 Stock shares = 2000 Quantum MEME,k = 0.8  strike = 1600;Right to exercise authority 3 Stock shares  Burn 4800 Quantum MEME.
    ///
    /// `4800e18` None of this was ever measured in contract generation -- it was written down below, and anyone could count it.
    /// What happens when one order of magnitude is missing:strike Large 10 Double, the entire week is never allowed to pass; small 10 Double, shares token is the equivalent of white.
    function test_strike_isTheSameNumberTheClearingPoolChargesOnExercise() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        // Treasury, copy. 10 Tax on shares: 10% creator(Decision-making 49),90% of the people who are in the pool.
        // Cast 9 The right to a permit. distributor.1:1 The full mortgage says...** I'm in the pool **That part of the call is only endorsed by it.
        stock.mint(address(vault), 10e18);
        vm.prank(keeper);
        assertEq(vault.processRevenue(), 8e18, unicode"1:1 Full mortgage:9 A set of collateral. 9 Empirical evidence");

        // - We have the right to do that. alice It's not the content of the promissory note. distributor Turn around.
        vm.prank(address(distributor));
        call.safeTransferFrom(address(distributor), alice, seriesId, 3e18, "");

        // Two steps on the side of the beneficiary are exactly the steps that the front end is going to direct the user to.
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 10_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);

        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        vm.prank(alice);
        pool.exercise(seriesId, 3e18, alice);

        // CRITICAL The number that came out of the calculations:3 Stock shares  1600 MEME/Grandpa. = 4800 Quick.
        uint256 expectedBurn = 4800e18;
        assertEq(
            memeBefore - meme.balanceOf(alice),
            expectedBurn,
            unicode"CRITICAL The beneficiary was detained. MEME That's it."
        );
        assertEq(
            meme.balanceOf(DEAD) - deadBefore, expectedBurn, unicode"And it actually went into the destruction site."
        );
        assertEq(stock.balanceOf(alice), 3e18, unicode"Change back. 3 A share token.");

        // And then we'll take another test of the scale:strike It's "every" 1e18 raw "Securities" price, so... 1 raw The stock is burned. 1600 raw MEME.
        assertEq(uint256(vault.strike()) * 1 / 1e18, 1600, unicode"1 raw Equities = 1600 raw MEME,The scale is right.");
    }

    /// @notice The concession is...**Remove Down**The rest of the dots remain on the side of the pool, not rounded to the user side.
    function test_openSeries_roundsTheDiscountDown() public {
        // 1e36 / 3 = 333...333(- Take it down. - Again.  0.8 Still picks up the whole thing down.
        portal.setCurve(address(meme), address(stock), 3);
        _readyAtFridayEvening();

        (, uint256 price) = vault.twap();
        vm.prank(keeper);
        vault.openSeries();

        assertEq(vault.strike(), uint128((price * 8000) / 10_000), unicode"Sweep Down, No Bits");
        assertLe(uint256(vault.strike()) * 10_000, price * 8000, unicode" Take the whole thing out  strike Small");
    }

    /// @notice TWAP And then it's a little lower and then it's a little more like a little bit of a trade-off. 0 Time**No series.**  -  -  Otherwise, it would be a white coin.
    /// @dev There's one over there. `ZeroStrike`,But it's only one thing that can't be solved. selector;
    ///      On the other side of the vault, the message is a human one.
    function test_openSeries_refusesWhenTheDiscountRoundsTheStrikeToZero() public {
        // 1e36 / 1e36 = 1  1  8000 / 10000 = 0.
        portal.setCurve(address(meme), address(stock), 1e36);
        _readyAtFridayEvening();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, STRIKE_ROUNDS_TO_ZERO);
        assertEq(nextStrike, 0);

        vm.prank(keeper);
        vm.expectRevert(unicode"TWAP too low to price a strike");
        vault.openSeries();
    }

    /// @notice The concession is not loaded. `uint128` Time**No series.**.
    /// @dev The pool branch after graduation: it's up the line, in terms of reserves. 5.19e51)Much higher than the curve branch. 1e36,
    ///      So this branch is...**It's really great.**Not a defensive code.
    function test_openSeries_refusesWhenTheStrikeWouldNotFitInUint128() public {
        DexPairStub pair = new DexPairStub(address(meme), address(stock));
        // memeReserve  1e18 / quoteReserve = 1e48  After concession 8e47,Far above uint128 It's... 3.4e38.
        pair.setReserves(1e30, 1);
        portal.setGraduated(address(meme), address(stock), address(pair));

        _readyAtFridayEvening();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, STRIKE_TOO_LARGE);
        assertEq(nextStrike, 0);

        vm.prank(keeper);
        vm.expectRevert(unicode"Strike does not fit in uint128");
        vault.openSeries();
    }

    //  3. Short sample:fail-closed,A bad one. strike I'm not leaving.

    /// @notice CRITICAL **Receiving and Inspection No. 4 Article**:The ring is not filled and the series is not opened.`strike` Not a single byte.
    function test_openSeries_refusesWhileTheRingIsStillFilling() public {
        vm.prank(keeper);
        vault.sampleTwap();

        (uint256 status,, uint128 nextStrike) = _status();
        assertEq(status, TWAP_UNAVAILABLE);
        assertEq(nextStrike, 0, unicode"I didn't even count.");

        vm.prank(keeper);
        vm.expectRevert(unicode"24h TWAP unavailable, call twap() for the reason");
        vault.openSeries();

        assertEq(vault.strike(), 0, unicode"CRITICAL It didn't fall down, it was calculated with bad data. strike");
        assertEq(vault.seriesExpiry(), 0);
    }

    /// @notice keeper Stopped a beat, the end was above the maximum gap -- same rejection.
    /// @dev And the last one is...**Two different failures.**(The ring is not full. / But the same thing is given to the vault:
    ///      The authority to do so is only for the reasons. `twap()` One, not the second time here.
    function test_openSeries_refusesWhenTheKeeperMissedABeat() public {
        _readyAtFridayEvening();

        (uint256 ready,,) = _status();
        assertEq(ready, OPEN_OK, unicode"We can open it before we stop.");

        // Missing a full heartbeat: the end is now 1 Hours 6 Score, over 65 The minute limit.
        vm.warp(block.timestamp + 1 hours + 6 minutes);

        (uint256 status,,) = _status();
        assertEq(status, TWAP_UNAVAILABLE);

        vm.prank(keeper);
        vm.expectRevert(unicode"24h TWAP unavailable, call twap() for the reason");
        vault.openSeries();
    }

    /// @notice CRITICAL **Status code does not forward**:The vault just said, "Oh, yeah.TWAP "Not available." `twap()` Give it up.
    /// @dev There are two points of reference for the same value, and one will drift sooner or later; the consequence of drifting is to check the failure under the chain by an expired control sheet.
    function test_openSeriesStatus_pointsAtTwapInsteadOfCopyingItsCodes() public {
        vm.prank(keeper);
        vault.sampleTwap();

        (uint256 status,,) = _status();
        (uint256 twapStatus,) = vault.twap();

        assertEq(status, TWAP_UNAVAILABLE, unicode"The vault is the same size.");
        assertEq(twapStatus, 1, unicode"And for the exact reason (the ring is not filled) = 1)Yes. twap() Over there.");
        assertTrue(status != twapStatus, unicode"Two yards are independent and should not be read in the same way.");
    }

    //  4. Repeated calls in the same week: no second series to be published

    /// @notice CRITICAL **Receiving and Inspection No. 5 Article**:Repeat calls are like tha-- return to the already opened series,`opened == false`,Don't touch the pool.
    function test_openSeries_isIdempotentWithinTheSameWeek() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 first, bool openedFirst) = vault.openSeries();
        assertTrue(openedFirst);

        uint128 mintedStrike = vault.strike();

        vm.prank(keeper);
        (uint256 second, bool openedSecond) = vault.openSeries();

        assertEq(second, first, unicode"It's the same series that was handed over.");
        assertFalse(openedSecond, unicode"CRITICAL But it didn't open another one.");
        assertEq(
            vault.strike(),
            mintedStrike,
            unicode"Once the rights price is locked to death, they shouldn't be changed by the second call."
        );

        (uint256 status,,) = _status();
        assertEq(status, ALREADY_OPEN, unicode"That's what the view says.");
    }

    /// @notice CRITICAL **Receiving and Inspection No. 5 The most stupid and solid way.**:From the moment the series was opened, it's been transferred every hour.
    ///         `openSeries()`,The new series should not be opened more, but it should be opened more.
    ///         And...**Not once. revert**.
    ///
    /// @dev The phrase "we'll only do it once" should not be used to say:Trigger Service It'll try again, it'll run empty.
    ///      Someone might have to do more manually. Here's a roundup every hour of the week.
    ///
    ///      Stuck in the same way: one.**Every day, I run empty.**It's... keeper It won't be a week for six days in red...
    ///      "It's nothing to do." It's clean return, no. revert.
    function test_openSeries_neverOpensASecondSeriesHoweverOftenItIsCalled() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        uint256 calls;
        // Stop in the window and open**Before**:The next issue from that moment onwards is the correct act, and the test in this article is the week before it.
        while (block.timestamp + 1 hours < FRI_AUG_21 - openWindow) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(keeper);
            vault.sampleTwap();

            vm.prank(keeper);
            (uint256 id, bool opened) = vault.openSeries();
            assertEq(id, seriesId, unicode"Each time, it points to the same series.");
            assertFalse(opened, unicode"CRITICAL A new series hasn't been opened.");
            calls++;

            assertEq(vault.seriesExpiry(), FRI_AUG_21, unicode"No bytes in the current series.");
            assertEq(vault.strike(), EXPECTED_STRIKE, unicode"The right price is still the same.");
        }

        assertGt(calls, 140, unicode"It's been hit every hour this week.");
    }

    //  5. The opening of the series:24 Hour Window

    /// @notice CRITICAL The current series is not ready for the next issue in the early hours -- or anyone can be in the week.**Pick an hour.**
    ///         You'll be dead for the whole week. `CallVault.OPEN_WINDOW`.
    function test_openSeries_refusesUntilTheOpenSeriesIsWithinADayOfExpiry() public {
        _readyAtFridayEvening();
        vm.prank(keeper);
        vault.openSeries();

        uint256 liveSeries = pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21);

        // Saturday noon: Distance 8/21 The deadline is more than six days.
        _keepSamplingUntil(FRI_AUG_14 + 15 hours);
        (uint256 status, uint64 expiry,) = _status();
        assertEq(status, TOO_EARLY);
        assertEq(
            expiry,
            FRI_AUG_28,
            unicode"CRITICAL But the calendar of expirys can be answered as it is -- it's a pure function of time"
        );

        // CRITICAL  Back clean  revert:"It's not an accident.**Current**That issue.
        vm.prank(keeper);
        (uint256 id, bool openedEarly) = vault.openSeries();
        assertEq(id, liveSeries, unicode"Turn over the one that's still open.");
        assertFalse(openedEarly);

        // The window was opened one second before, and it was still open.
        _keepSamplingUntil(FRI_AUG_21 - openWindow - 1);
        (status,,) = _status();
        assertEq(status, TOO_EARLY, unicode"Not even a second.");

        // The window is released as soon as it arrives -- it happens on Thursday. 21:00.
        _keepSamplingUntil(FRI_AUG_21 - openWindow);
        (status, expiry,) = _status();
        assertEq(status, OPEN_OK, unicode"Before due 24 Hourly window open.");

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
        assertEq(vault.seriesExpiry(), FRI_AUG_28, unicode"It's the next life cycle. 8 Oh, my God.");
    }

    /// @notice CRITICAL Window is not active: after a week of leakage, anyone can**Now.**Complementing session.
    ///
    /// @dev This is... {CallVault-OPEN_WINDOW} The other half of the deal -- it buys "no time to choose" -- and it's not a choice.
    ///      The price must stop at a "later" rate and not become "never."
    ///      The one that's open to press >=7 The life rule is set for the next Friday, and so is the income.**Now.**There's room for another one.
    function test_openSeries_recoversImmediatelyAfterAMissedWeek() public {
        _readyAtFridayEvening();
        vm.prank(keeper);
        vault.openSeries();

        // The whole window was untranched, and the series just expired.
        _keepSamplingUntil(FRI_AUG_21 + 12 hours);

        (uint256 status, uint64 expiry,) = _status();
        assertEq(
            status,
            OPEN_OK,
            unicode"CRITICAL After the expiry of the term, the door opens automatically. No one is needed to unlock it."
        );
        assertEq(expiry, FRI_SEP_04, unicode"Press >=7 The life rule is set for the next Friday.");

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);

        // And immediately after the patch-up, there's a place to go -- a week off, but no cents in the vault for two weeks.
        stock.mint(address(vault), 5e18);
        vm.prank(keeper);
        assertEq(vault.processRevenue(), 4e18);
    }

    /// @notice The first series is open without windows - there was no "current series" at the time of the Treasury's birth.
    function test_openSeries_hasNoWindowOnTheVeryFirstSeries() public {
        // The starting point is Saturday noon, far from any Friday.
        vm.warp(FRI_AUG_14 + 15 hours - 24 hours);
        _bootstrapRing();

        (uint256 status, uint64 expiry,) = _status();
        assertEq(status, OPEN_OK, unicode"seriesExpiry == 0,Window Door Not Applicable");
        assertEq(expiry, FRI_AUG_28);

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
    }

    //  6. Discontinuable (suspect)issue #42  The chain grabs hands

    /// @notice CRITICAL **Receiving and Inspection No. 7 Article**:Is this series open? Under the chain?**No deal.**I can answer it.
    ///
    /// @dev Walk through the four forms that a vault actually goes through, and each one asks for a view. The test is to prove that the test is a very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very,
    ///      Every lull has an answer that can be checked, not "there is a view."
    function test_openSeriesStatus_answersWhetherThisWeeksSeriesIsOpen() public {
        // (1) Just deployed:TWAP Not ready for -- the reason for the suspension is on the sample chain.
        (uint256 status, uint64 expiry, uint128 nextStrike) = _status();
        assertEq(status, TWAP_UNAVAILABLE);
        assertEq(expiry, FRI_AUG_21, unicode"The calendar can be answered in any state");
        assertEq(nextStrike, 0);

        // (2) The rings are full, and no one's tuned them yet -- the reason for the suspension is... Trigger Service That side.
        _readyAtFridayEvening();
        (status, expiry, nextStrike) = _status();
        assertEq(status, OPEN_OK, unicode"CRITICAL \"It's the most important one.\"");
        assertEq(expiry, FRI_AUG_21);
        assertEq(nextStrike, EXPECTED_STRIKE, unicode"I'll even tell you what the right price is.");

        // (3) It's coming out -- this is "No problem this week."
        vm.prank(keeper);
        vault.openSeries();
        (status, expiry, nextStrike) = _status();
        assertEq(status, ALREADY_OPEN);
        assertEq(expiry, FRI_AUG_21);
        assertEq(nextStrike, 0, unicode"It won't open again, so there's no \"right-to-hand\" price.");

        // 4 Next issue is early -- this one.**No, it's not.**The police, by this, knew that it was never supposed to be.
        _keepSamplingUntil(FRI_AUG_14 + 2 days);
        (status,,) = _status();
        assertEq(status, TOO_EARLY);
    }

    /// @notice CRITICAL View & Transactions**There's no way to give a different answer.**  -  -  Both are subject to the same adjudicative functions.
    /// @dev Walk on a case-by-case basis: the view says it works, the deal really works; the view says it doesn't, the deal really fails.
    ///      A pre-test that lies is worse than no pre-test: the chain will close the alarm.
    function test_openSeriesStatus_neverDisagreesWithOpenSeries() public {
        // He said he couldn't open it. -> It's not gonna work.
        (uint256 status,,) = _status();
        assertTrue(status != OPEN_OK && status != ALREADY_OPEN);
        vm.prank(keeper);
        vm.expectRevert();
        vault.openSeries();

        // Say it works. -> It's really coming out. And it's coming out. expiry / strike It's not different from the word "premise."
        _readyAtFridayEvening();
        (uint256 okStatus, uint64 predictedExpiry, uint128 predictedStrike) = _status();
        assertEq(okStatus, OPEN_OK);

        vm.prank(keeper);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
        assertEq(vault.seriesExpiry(), predictedExpiry, unicode"Pre-admissible");
        assertEq(vault.strike(), predictedStrike, unicode"Advances of rights to travel");

        // Say it's open. -> The deal's clean back. No. revert
        (status,,) = _status();
        assertEq(status, ALREADY_OPEN);
        vm.prank(keeper);
        (, bool again) = vault.openSeries();
        assertFalse(again);
    }

    /// @notice The event is...**The priced input and output are together**Write it down. Take a log under the chain and check it out. `strike = TWAP  0.8`.
    function test_openSeries_emitsTheTwapItPricedFrom() public {
        _readyAtFridayEvening();

        uint256 expectedId = pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21);

        vm.expectEmit(true, false, false, true, address(vault));
        emit CallVault.WeeklySeriesOpened(expectedId, FRI_AUG_21, EXPECTED_STRIKE, MEME_PER_STOCK);

        vm.prank(keeper);
        vault.openSeries();
    }

    //  7. Connect:seriesId,Identity Roots and Writing Orders

    /// @notice It's from the vault. `seriesId` and `pool.seriesIdOf(meme, stock, expiry)` Is the same number.
    /// @dev Expectations**I'll count it myself.**(For yourself. `keccak256(abi.encode(...))`),Not the pool. `seriesIdOf`
    ///      To examine itself... same. `ClearingPoolMinting.t.sol` Discipline.
    function test_openSeries_returnsTheSeriesIdThePoolWouldCompute() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        uint256 independent = uint256(keccak256(abi.encode(address(meme), address(stock), FRI_AUG_21)));
        assertEq(seriesId, independent, unicode"Hachi of the Triples, count in one.");
        assertEq(seriesId, pool.seriesIdOf(address(meme), address(stock), FRI_AUG_21));
        assertEq(pool.series(seriesId).vault, address(vault), unicode"The vault is the vault of the series.");
    }

    /// @notice CRITICAL **The order of writing is heavy.**:The blogger says that the government is not going to let the government take the decision.`strike` and `seriesExpiry` No byte is left.
    ///
    /// @dev If you write the other way around (put a field before a series), if you fail to open the series, the field points to the other person's series.
    ///      And... `processRevenue` It'll be steady. `NotSeriesVault`  -  -  Revenue will never come out of the vault again.
    ///      Strangers will be denied identity and no more bets on the Triples; so here we open the same vault directly.
    ///      Three-dollar team. Specializing in the back. `SeriesAlreadyOpen` Branch.
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

        assertEq(vault.strike(), 0, unicode"CRITICAL Fields did not fall");
        assertEq(vault.seriesExpiry(), 0);

        // And it didn't turn into a "thinking it's been opened" vault: income is back on the side.
        stock.mint(address(vault), 1e18);
        vm.prank(keeper);
        assertEq(
            vault.processRevenue(),
            0,
            unicode"I'll leave the money in the vault next time. I won't hit it. NotSeriesVault"
        );
    }

    /// @notice Once the roots of identity have been tied, unknown addresses cannot take the same week's series in front of the vault.
    function test_poolRejectsAnUnregisteredCallerBeforeItCanOpenTheSeries() public {
        address squatter = makeAddr("squatter");

        vm.prank(squatter);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, address(meme), squatter, address(vault))
        );
        pool.openSeries(address(meme), address(stock), FRI_AUG_21, 1);
    }

    /// @notice The entrance.**No Participation**  -  -  calldata There's no byte energy effect in it. strike or expiry.
    /// @dev This is not a note that can be used: as long as the signature contains parameters, "whoever calculates the same set of values" is on the caller's self-consciousness.
    ///      And by the way, I'm saying no.**As it is.**,"and not be translated into our own words." `_approveQuote` - Same rule -
    ///      The last test. `expectRevert` That's exactly what I'm waiting for. `ClearingPool.SeriesAlreadyOpen` The choicer,
    ///      Not a word of our own.
    function test_openSeries_takesNoArguments() public pure {
        assertEq(CallVault.openSeries.selector, bytes4(keccak256("openSeries()")));
    }

    /// @notice I've got a list of addresses that I can get, and I've got a list of addresses.**Group I**Right-of-hand price with maturity.
    /// @dev Unlicensed is not a default value, it is a trade-off (see `CallVault.OPEN_WINDOW`).It was established on the basis of this article:
    ///      The caller changed the person, and neither of the two decisive numbers changed.
    function testFuzz_anyCallerCanOpenTheWeeklySeries(address caller) public {
        vm.assume(caller != address(0));
        _readyAtFridayEvening();

        vm.prank(caller);
        (uint256 seriesId, bool opened) = vault.openSeries();

        assertTrue(opened);
        assertEq(vault.strike(), EXPECTED_STRIKE, unicode"It's the right price for everyone.");
        assertEq(vault.seriesExpiry(), FRI_AUG_21, unicode"This is the last time anyone gets transferred.");
        assertEq(
            pool.series(seriesId).vault,
            address(vault),
            unicode"The vault of this series is still a vault, not a caller."
        );
    }

    /// @notice The first three issues were started: each one was a full week later than the previous one, and the next one was a week later than the previous one.`processRevenue` Follow me all the way.
    /// @dev It's the normal rhythm of the product. 16:Every Friday 21:00 UTC,Minimum life expectancy 7 I'm not going to be able to get a job.
    ///      The phrase "two active series at any given time" is also on the timeline.
    function test_openSeries_walksTheWeeklyCalendarForward() public {
        _readyAtFridayEvening();

        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_AUG_21);

        _keepSamplingUntil(FRI_AUG_21 - 1 hours);
        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_AUG_28, unicode"Second");

        _keepSamplingUntil(FRI_AUG_28 - 1 hours);
        vm.prank(keeper);
        vault.openSeries();
        assertEq(vault.seriesExpiry(), FRI_SEP_04, unicode"Third");

        assertEq(FRI_AUG_28 - FRI_AUG_21, 7 days);
        assertEq(FRI_SEP_04 - FRI_AUG_28, 7 days);
    }
}
