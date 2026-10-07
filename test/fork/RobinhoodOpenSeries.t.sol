// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {CallVault} from "../../src/CallVault.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @title RobinhoodOpenSeriesForkTest
/// @notice CRITICAL **M2-4 The "must run on the fork" acceptance.issue #36):Real GME + Real TWAP The first time I was in the movie was in the movie.
///         `seriesId` and `pool.seriesIdOf(meme, stock, expiry)` Unanimously.**
///
/// Local.`test/CallVaultOpenSeries.t.sol`)We've got Fridays aligned, folded, tweezers, windows and...
/// We stopped the hair and we could observe it and nail it all -- we wrote it ourselves. Portal Substitutes. Only here.**The things the double can't prove.**:
///
/// 1. CRITICAL **strike It's from the real conjunction curve.**.The double. `price` We set it. We decide on the scale and the accuracy.
///    Real Portal It's... `price` Yes. `k / (1e9 + h - s)2` The marginal price of this curve,18 Place your spot. GME .
///    1e36 / priceThe scale of this step is only**It's...**I've only been tested on my body.
/// 2. CRITICAL **The real value of the money. GME**.The chain. GME The priced coin is in the M2-2 It's the first time I've run through.issue #23 The government has also been monitoring the situation.
///    And the whole thing. strike The link is built in "the currency of income." = "In the first place, the decision is to be made. 12).
///    Every time I'm here, I'm really from `Portal.newTokenV6` Send one out.
/// 3. CRITICAL **The series that came out, real. GME It's in there.**.`openSeries` and `processRevenue` It's two paragraphs of the code written by two tickets.
///    Fuck them. `strike != 0 && now < seriesExpiry` This is a constant connection; run over the real mark.
///    The idea of a new line is to get the line out of the line, but the revenue path doesn't recognize it.
///
/// | Component | With what? |
/// |---|---|
/// | Source of prices | **Real Flap Portal**(`0x26605f...`)The true conics above it |
/// | Services MEME | Every test**On the spot.**One of them. GME Price `TOKEN_TAXED_V3` |
/// | Currency of income / Mortgages. | **Real GME** |
/// | Treasury / I'm a pool. / Certificate / Distribution / Registration form | Real deployment + Two bindings (in %2)issue #5  The test stitches  |
contract RobinhoodOpenSeriesForkTest is ForkTest, FlapGmeLaunch {
    /// @dev CRITICAL **Write it all on its own.**:The number of seconds a week, and Friday. 21:00 UTC , and then click the1 Oh, my God. + 21 Hours.
    ///      The contract says... `EXPIRY_OFFSET = 45 hours`;Here's the one that says, `162000`.
    ///      The two figures are not shared and are only supported by proof of their common origin.
    uint256 internal constant WEEK_SECONDS = 604_800;
    uint256 internal constant FRIDAY_2100_OFFSET = 162_000;

    /// @dev Decision-making 14:k = 0.8.It's also a dead letter, not from the vault.
    uint256 internal constant K_NUMERATOR = 4;
    uint256 internal constant K_DENOMINATOR = 5;

    IERC20 internal gme;

    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    address internal keeper = makeAddr("trigger service");
    address internal holder = makeAddr("holder");

    function setUp() public {
        ForkTarget memory target = ForkConfig.robinhood();
        // The probe landed. Portal Up... that height has no status, to ask on contracts that are really going to be read.
        target.probe = ForkConfig.FLAP_PORTAL;
        selectFork(target);

        gme = IERC20(ForkConfig.GME);

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));
    }

    //  Scaffolding.

    /// @dev It's the same thing as what the factory is about to do:**One line. `new`**  -  -  Decision-making 39-A3 The government has been working on the issue of the government's policy of protecting the public.
    ///      Six parameters (decision-making) 49 & Inline creator)And in which they will be made to die,
    ///      Of which price Portal It's real. Flap `Portal`.
    function _deployVault(address memeToken) internal returns (CallVault vault) {
        vault = new CallVault(
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

    /// @dev A well-dressed, garbled vault that opens a series of vaults.
    function _readyVault() internal returns (CallVault vault, address memeToken) {
        memeToken = _launchGmeQuotedToken();
        vault = _deployVault(memeToken);
        factory.bind(memeToken, address(vault));
        assertEq(factory.registry().vaultOf(memeToken), address(vault), unicode"New hair. MEME Tie it to this vault.");
        assertTrue(_fillTwapRing(vault, keeper), unicode"That one should be in there every hour.");
    }

    //  Pre-run: It's the real contracts that ran.

    function test_theChainAndTheQuoteTokenAreReal() public view {
        assertEq(
            block.chainid,
            ForkConfig.ROBINHOOD_CHAIN_ID,
            unicode"This test is only for Robinhood Chain It's interesting."
        );
        assertGt(ForkConfig.FLAP_PORTAL.code.length, 0, unicode"Portal There should be a code on the address.");
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There should be a code.");
        assertEq(
            address(pool.vaultRegistry()),
            address(factory.registry()),
            unicode"I'm reading the foundation of the factory."
        );
        assertTrue(
            factory.registry().isFactory(address(factory)),
            unicode"There's a list of the root of the identity. fixture The factory."
        );
    }

    //  CRITICAL The receipt of the notes.

    /// @notice CRITICAL **Last one.**:Real GME + Real TWAP The first time I was in the movie was in the movie.
    ///         `seriesId` and `pool.seriesIdOf(meme, stock, expiry)` Unanimously.
    ///
    /// @dev Four claims are different and all expectations are all in the same direction.**Independently calculate**,Not from the contract:
    ///
    ///      | The assertion. | For what? |
    ///      |---|---|
    ///      | `seriesId` Three points. | The vault deposites the money in one.**Cannot initialise Evolution's mail component.**Series, or worse, in someone else's. |
    ///      | expiry Other Organiser | It's not due on Friday. 21:00 UTC  -  -  The whole due calendar does not match the frontend |
    ///      | expiry  now >= 7 Oh, my God. | The certificate expired at birth. |
    ///      | strike == 1e36/price  0.8 | CRITICAL The number is wrong -- the most expensive one on the ticket. |
    function test_openSeriesPricesFromTheRealCurveAndAgreesWithThePool() public {
        (CallVault vault, address memeToken) = _readyVault();

        // The marginal price on the real curve, directly from Portal Camera reading -- inversions in the test do it themselves.
        uint256 flapPrice = _tokenState(memeToken).price;
        assertGt(flapPrice, 0, unicode"The coins that have just been sent should be on the curve.price Non-zero");
        uint256 expectedTwap = uint256(1e36) / flapPrice;

        (uint256 twapStatus, uint256 twapPrice) = vault.twap();
        assertEq(twapStatus, 0, unicode"The rings are full. Reads should be available.");
        assertEq(twapPrice, expectedTwap, unicode"CRITICAL Read it. 1e36 / Flap It's... price");

        vm.prank(keeper);
        (uint256 seriesId, bool opened) = vault.openSeries();
        assertTrue(opened, unicode"It should be on the real chain.");

        uint64 expiry = vault.seriesExpiry();

        // (1) seriesId:The return value of the vault, the formula for the pool and the test for the independent calculation are equal.
        assertEq(
            seriesId,
            pool.seriesIdOf(memeToken, ForkConfig.GME, expiry),
            unicode"CRITICAL seriesId and pool.seriesIdOf(meme, stock, expiry) Unanimously"
        );
        assertEq(
            seriesId,
            uint256(keccak256(abi.encode(memeToken, ForkConfig.GME, expiry))),
            unicode"I'm counting a trifle of Hashi."
        );

        // (2) Due: Friday 21:00 UTC,And life. >=7 God.
        assertEq(uint256(expiry) % WEEK_SECONDS, FRIDAY_2100_OFFSET, unicode"CRITICAL Friday. 21:00 UTC");
        assertGe(
            uint256(expiry) - block.timestamp,
            7 days,
            unicode"CRITICAL Life expectancy shall not be less than 7 Oh, my God."
        );
        assertLt(uint256(expiry) - block.timestamp, 14 days);

        // (3) Right-of-hand prices:TWAP  0.8,Write it in isolation. 4/5 Recalculate.
        uint128 strike = vault.strike();
        assertEq(uint256(strike), (expectedTwap * K_NUMERATOR) / K_DENOMINATOR, unicode"CRITICAL strike = TWAP  0.8");
        assertEq(pool.series(seriesId).strike, strike, unicode"The same number is locked in the pool.");
        assertEq(pool.series(seriesId).vault, address(vault), unicode"The vault is the vault of the series.");
        assertEq(pool.series(seriesId).stockToken, ForkConfig.GME, unicode"The collateral is real. GME");

        console2.log(
            string.concat(
                unicode"  Real Curve price=",
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

    /// @notice CRITICAL The series that came out,**Real GME It's in there.**  -  -  Two paragraphs of the code written by the two tickets can be attached to the true label.
    ///
    /// @dev `openSeries`(M2-4)and `processRevenue`(M2-3)Shit. `strike != 0 && now < seriesExpiry`
    ///      This is a constant connection. We used the local tests to write it ourselves. ERC-20;It's real here. GME
    ///      (BeaconProxy -> `Stock`,The blogger says that the issuer's embellishment and its own account keeper, and that the issuer's cutter is not the only one who can be used to make the difference.
    ///      And it's going to be "transfer." + Agreements pingThis real awakening path is not a direct change in balance.
    function test_theSeriesJustOpenedAcceptsRealGmeRevenue() public {
        (CallVault vault,) = _readyVault();

        vm.prank(keeper);
        (uint256 seriesId,) = vault.openSeries();

        // Tax-to-account: transfer is not given to the recipient for execution, and is supplemented by the amount agreed upon ping Wake up the vault.
        deal(ForkConfig.GME, holder, 4e18);
        vm.prank(holder);
        gme.transfer(address(vault), 4e18);
        (bool pinged,) = address(vault).call{value: 0, gas: 500_000}("");
        assertTrue(pinged, unicode"ping It should be successful.");

        uint256 held = gme.balanceOf(address(vault));
        assertGt(held, 0, unicode"Real GME Here we go.");

        vm.prank(keeper);
        uint256 minted = vault.processRevenue();

        assertEq(
            minted,
            held - held / 10 - (held - held / 10) / 9,
            unicode"1:1 Full collateral: 90% of the increase in the pool is foundry. 49)"
        );
        assertEq(
            call.balanceOf(address(distributor), seriesId), minted, unicode"The certificate was made for distribution."
        );
        assertEq(gme.balanceOf(address(pool)), minted, unicode"The collateral went into the pool.");
        assertEq(
            gme.balanceOf(address(vault)),
            held / 10 + (held - held / 10) / 9,
            unicode"There's only one in the vault. creator Floating -- The \"In transit\" window closed"
        );
        (uint256 inTransitNow, bool exact) = vault.inTransit();
        assertTrue(exact);
        assertEq(inTransitNow, 0, unicode"R4 * Live reading: in the course of a journey, the floating is netted off");
    }

    /// @notice The same thing is not available on the real chain.**No, no. revert**.
    /// @dev The whole timeline of the Zen is the local one; only the real one is here. Portal And the same as the real pool, the same way it's clean back...
    ///      It decides... Trigger Service The re-test is not a police alarm.
    function test_openSeriesIsIdempotentOnTheRealChain() public {
        (CallVault vault,) = _readyVault();

        vm.prank(keeper);
        (uint256 first, bool openedFirst) = vault.openSeries();
        assertTrue(openedFirst);

        vm.prank(keeper);
        (uint256 second, bool openedSecond) = vault.openSeries();
        assertEq(second, first, unicode"Turn back the same series.");
        assertFalse(openedSecond, unicode"CRITICAL No more.");
    }

    /// @notice If the sample stops, you can't open a series... fail-closed In reality. Portal It's the same thing. One time. gas.
    ///
    /// @dev "The test was locally made with a double. Here's the ring on the real chain.**Expiry**:
    ///      The blog also shows how the government is doing this:`openSeries` It must be rejected, not taken away from the current history, which is irrelevant, to determine the distribution rate for the entire week.
    function test_openSeriesIsFailClosedWhenSamplingStopsOnTheRealChain() public {
        (CallVault vault,) = _readyVault();

        uint256 before = gasleft();
        vm.prank(keeper);
        vault.openSeries();
        uint256 gasUsed = before - gasleft();
        console2.log(string.concat(unicode"  The real chain. openSeries gas=", vm.toString(gasUsed)));

        // Goes to the next window, but the sampling has stopped for more than two hours.
        uint64 expiry = vault.seriesExpiry();
        vm.warp(uint256(expiry) - 2 hours);

        (uint256 status,,) = vault.openSeriesStatus();
        assertEq(status, 3, unicode"OPEN_TWAP_UNAVAILABLE  -  -  See you at the status code. docs/spec.md");

        vm.prank(keeper);
        vm.expectRevert(unicode"24h TWAP unavailable, call twap() for the reason");
        vault.openSeries();

        assertEq(
            vault.seriesExpiry(), expiry, unicode"CRITICAL The last issue was not broken, not a single byte. strike"
        );
    }
}
