// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PriceSource} from "../../src/PriceSource.sol";
import {CallVault} from "../../src/CallVault.sol";
import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";
import {IDexPair, IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {CallVaultHarness} from "../helpers/CallVaultHarness.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";
import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";

/// @dev "Take it once." X Switch Y. Original currency is at zero.
struct ExactInputParams {
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 minOutputAmount;
    bytes permitData;
}

/// @dev Use of this document Portal Noodles. The half of the reading lives in `src/interfaces/IFlapPortalLens.sol`(Production codes;
///      Only the conversion and the price allocation -- the money is shared. {FlapGmeLaunch}.
interface IFlapPortal {
    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
    function getQuoteTokenConfiguration(address quoteToken) external view returns (QuoteTokenConfiguration memory);
}

/// @title RobinhoodTwapSourceForkTest
/// @notice CRITICAL **M2-2 The "vested confirmation" acceptance.issue #34),and spec 14-6 The shut-up.**
///
/// The front. `getTokenV8Safe().price` The precision and semantics of the**Open**,"and ask for "the truth on the fork." Portal Read it once."
/// This document is the one that read it and it reads the conclusions.**Overturning a default assumption on the face**:
///
/// > Flap For you. `price` Yes.**This one. MEME What's the value of the price?**;And the ring buffer is for**What's the value of a stock? MEME**.
/// > The two are in the last place.
///
/// Just... MEME It was launched in stock currency.Flap Normative requirements `vaultQuoteToken()` The government has been able to provide the necessary information to the government.
/// This inversion is necessary. Full extrapolation and trade-off is in place. {PriceSource} In the note, the facts are recorded in the
/// `docs/research/flap-portal-price-semantics.md`.
///
/// # Four things I can't prove here.
///
/// | | Why do you have to prove it on the real chain? |
/// |---|---|
/// | Camera Return**Just right.** 18 A static word | Field order and width are Flap The truth is, it's not our deal. |
/// | `price` It's a curve.**Marginal price**(Use `r/h/k/s` Recalculate is right. | It's a mathematical form of scalding. We want it to be equal to a few. |
/// | **GME It's the price booking that's on this chain.**,And it's a real one. GME It's priced. TOKEN_TAXED_V3 | The whole product is a prerequisite. The old warehouse note says "The original currency is the only active price." |
/// | One.**Real.**The government has been able to provide the necessary information to the public.24 The hour reading is almost static. | Price shocks are given by the true curve, not by the number we set. |
///
/// The two facts of the graduation branch.`price` Zero, the pool is... V2 And here's the same thing: the real chain; the real. pair It's...
/// `blockTimestampLast` And standards cumulative getter And check the shape test. That only proves external. ABI The fact that you are a human being is a reality.
/// **No, I can't.**Make this document's curve-buying test V2 Anti-manipulation proof: not yet in the chain GME The priced graduated tokens are the most popular in the world.
/// So our own pool branch and the same block are only able to run the whole path with a double.
contract RobinhoodTwapSourceForkTest is ForkTest, FlapGmeLaunch {
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;
    address internal constant GME = ForkConfig.GME;

    /// @dev Bytes of lens returned value  -  18 A static word.**Write it all on its own.**,Never. {PriceSource} Read.
    uint256 internal constant LENS_RETURN_BYTES = 18 * 32;

    /// @notice One.**Graduated**Real. Flap The tokens, and it's the pool.
    ///
    /// @dev Three sets of criteria are required.
    ///      (1) Graduated in**Before you nailed the height.**(Blocks 30,990,499 < 31,955,417) -  -  Or you'll be able to nail the floor.
    ///      (2) The graduation is...**Inversion.** So it's in  latest It is also established with the same two heights;
    ///      (3) It's...**Original currency**- No, not at this time. GME  The priced graduated tokens
    ///         "Only to testify."Flap "What does he look like after graduation?", "not run from the pool branch of our vault.
    ///
    ///      Source:Portal It's... `LaunchedToDEX(address,address,uint256,uint256)` Log
    ///      (topic0 `0x6e4f4763...`),All history. 269 Article , this article in blocks 30,990,499.
    address internal constant GRADUATED_TOKEN = 0x7c646A41572B441527169C576ef0c0A40c667777;
    address internal constant GRADUATED_POOL = 0x0390E65412d4704A612997432E4eeA8B7688232B;

    IFlapPortal internal portal;

    function setUp() public {
        ForkTarget memory target = ForkConfig.robinhood();
        // The probe landed. Portal Up... that height has no status, to ask on contracts that are really going to be read.
        target.probe = PORTAL;
        selectFork(target);

        portal = IFlapPortal(PORTAL);
    }

    //  Pre-run: It's the real contract.

    function test_thePortalIsReal() public view {
        assertEq(
            block.chainid,
            ForkConfig.ROBINHOOD_CHAIN_ID,
            unicode"This test is only for Robinhood Chain It's interesting."
        );
        assertGt(PORTAL.code.length, 0, unicode"Portal There should be a code on the address.");
        assertGt(GME.code.length, 0, unicode"GME There should be a code.");
    }

    //  Shape of the lens: right on. 18 A static word

    /// @notice CRITICAL {PriceSource} Press**Subscript**takes value, if return is just as long.
    ///
    /// @dev The value of this assertion is that it will.**Preselect**A silent reading error to red:Flap If we change the structure of the camera, we'll be able to get a better picture.
    ///      Press the tag to get another field, and that won't be wrong -- it's just a mistake. strike.
    function test_theLensReturnsExactlyEighteenStaticWords() public {
        address token = _launchGmeQuoted();

        (bool ok, bytes memory ret) = PORTAL.staticcall(abi.encodeCall(IFlapPortalLens.getTokenV8Safe, (token)));
        assertTrue(ok, unicode"The camera should be able to read.");
        assertEq(
            ret.length,
            LENS_RETURN_BYTES,
            unicode"CRITICAL Return value is not 18 Words -- all subscripts are invalidated"
        );

        // It's a good thing it does. struct Untie the road.
        IFlapPortalLens.TokenStateV8Safe memory state = abi.decode(ret, (IFlapPortalLens.TokenStateV8Safe));
        assertEq(state.quoteTokenAddress, GME, unicode"Subscript 9 It's a price.");
        assertEq(state.tokenVersion, ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3, unicode"Subscript 4 It's a token version.");
    }

    //  Semantics:price It's the marginal price of the curve.

    /// @notice CRITICAL **`price` Semantics and precision, nailed to death with arithmetic.**
    ///
    /// @dev Flap Upstream `LibCurve`  The original is
    ///      *"price (wei) of a token (1e18) if you buy/sell infinitesimal amount at current supply"*,
    ///      Formula `k / (1e9 + h - s)2`(WAD Set. Here.**The real chain.**Recalculate it:
    ///      Take the camera and give it to yourself. `r / h / k / circulatingSupply` Calculate `price`,And the camera. `price` Place-by-place comparison.
    ///
    ///      Right, three things proved at the same time, and without relying on any document:
    ///      (1) `price` The molecular unit is...**Minimum unit of value**(Because... `reserve` Yeah, and... `reserve` ; or
    ///      (2) The denominator is... **1e18 raw The currency of the unit**;
    ///      (3) It's... **18 Place**(Formula `mulWad` / `divWad` That's the two times. 1e18).
    ///
    ///      And then,1e18 raw What's the value of the stock? raw MEME= `1e36 / price` The scale of this step is closed.
    function test_curvePriceIsTheMarginalCurvePriceInQuoteUnits() public {
        address token = _launchGmeQuoted();
        IFlapPortalLens.TokenStateV8Safe memory state = _state(token);

        assertEq(state.status, 1, unicode"The tokens just sent out are on the curve.");
        assertEq(
            state.quoteTokenAddress,
            GME,
            unicode"CRITICAL The price is... GME  -  -  And... price The molecules are... GME Minimum units"
        );

        uint256 denominator = 1_000_000_000 ether + state.h - state.circulatingSupply;
        uint256 recomputedPrice = (state.k * 1e18) / ((denominator * denominator) / 1e18);
        assertEq(state.price, recomputedPrice, unicode"CRITICAL price == k / (1e9 + h - s)2,Equal in order of place");

        // And the reserve is recalculated: two separate constant equations are created at the same time, which means that we understand that**Same Curve**.
        uint256 recomputedReserve = _divWadUp(state.k, denominator) - state.r;
        assertEq(state.reserve, recomputedReserve, unicode"reserve == k/(1e9+h-s) - r");

        console2.log(
            string.concat(
                unicode"  Real Portal:price=",
                vm.toString(state.price),
                unicode" GME-wei / 1e18 MEME    After the inversion ",
                vm.toString(uint256(1e36) / state.price),
                unicode" MEME / 1e18 GME"
            )
        );
        console2.log(
            string.concat("  r=", vm.toString(state.r), "  h=", vm.toString(state.h), "  k=", vm.toString(state.k))
        );
    }

    /// @notice CRITICAL **GME It's the price booking that's on this chain.**  -  -  The entire product architecture is premised on its establishment.
    ///
    /// @dev The warehouse's note says "The original currency is the only active value of this chain."
    ///      (`test/fork/RobinhoodVaultIdentity.t.sol` It's... `_params`).That's what it says.**Wrong.**:
    ///      Flap In the blocks. 17,391,936 One-time denominated allocation for five assets (in thousands of United States dollars)2026-08-16 Review by configuration event:
    ///      That's just the one. 5 bars, blocks 22,527,427 Again. 1 Only, current total 6 Only ERC20 + The blogger says:GME It's one of them.
    ///      Default Curve is `CURVE_RH_25_ASSET`(`r = 177.68330498`,The note says, "I'm sorry.~$25 Reference price,$10K  I'm going to be a big fan of the world
    ///      One.**Yes 25 Customization of United States dollar-denominated assets**.
    ///
    ///      If this assertion turns red, it means Flap It's off. GME Count it. It was the whole time. M2 The launch route has to be redesigned.
    ///      So it's worth standing alone.
    function test_gmeIsAnEnabledQuoteToken() public view {
        IFlapPortal.QuoteTokenConfiguration memory config = portal.getQuoteTokenConfiguration(GME);
        assertEq(config.enabled, 1, unicode"CRITICAL GME Must be a enabled value");

        console2.log(
            string.concat(
                unicode"  GME Value configuration:enabled=",
                vm.toString(uint256(config.enabled)),
                " defaultCurve=",
                vm.toString(uint256(config.defaultCurve)),
                " nativeToQuoteSwapType=",
                vm.toString(uint256(config.nativeToQuoteSwapType))
            )
        );
    }

    //  After graduation: two facts that can only be read on the chain

    /// @notice CRITICAL **After graduation, `price` Constant 0,The pool is... Uniswap V2 shape.**
    ///
    /// @dev The two are the two that make the "two branches"**Required**But not optimisation:
    ///      (1) (a) Continue to read curve prices after graduation, and read zero, not a slight debatable price;
    ///      (2) I can answer the question. `token0/token1/getReserves`,I can't answer that. `slot0()`  -  -  So it is. V2,
    ///         It's like, "There's only one in this chain." `V2_MIGRATOR` "As you can walk."{ForkConfig} Those three constants.
    function test_graduatedTokenReportsZeroCurvePriceAndAV2ShapedPool() public {
        IFlapPortalLens.TokenStateV8Safe memory state = _state(GRADUATED_TOKEN);

        assertEq(state.status, 4, unicode"This sample should have graduated.status = DEX)");
        assertEq(
            state.price,
            0,
            unicode"CRITICAL The curve after graduation is constant 0  -  -  Not \"a little bit of a distortion,\" but \"a little bit of a distortion.\""
        );
        assertEq(state.pool, GRADUATED_POOL, unicode"The pool address is the same as the graduation.");
        assertEq(state.progress, 1e18, unicode"Progress 100%");

        // V2 Shape: All three read answers.
        address token0 = IDexPair(GRADUATED_POOL).token0();
        address token1 = IDexPair(GRADUATED_POOL).token1();
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IDexPair(GRADUATED_POOL).getReserves();
        assertTrue(token0 == GRADUATED_TOKEN || token1 == GRADUATED_TOKEN, unicode"There's this token in the match.");
        assertGt(uint256(reserve0), 0, unicode"There's a cargo in the pool.");
        assertGt(uint256(reserve1), 0, unicode"There's a cargo in the pool.");
        assertGt(
            uint256(blockTimestampLast), 0, unicode"V2 getReserves The third word should be the last reserve update."
        );
        assertLe(
            uint256(blockTimestampLast),
            uint256(uint32(block.timestamp)),
            unicode"Not at present uint32 The chain is high and the last update should not be later than this block."
        );

        // Standard V2 pair And the cumulative price. getter;The production reading price is not yet taken. Here's the interface shape.
        // Misspelled as "a full cumulative predictor" or "a proven prognosis." V2 It's safe."
        (bool hasPrice0Cumulative, bytes memory price0Cumulative) =
            GRADUATED_POOL.staticcall(abi.encodeWithSignature("price0CumulativeLast()"));
        (bool hasPrice1Cumulative, bytes memory price1Cumulative) =
            GRADUATED_POOL.staticcall(abi.encodeWithSignature("price1CumulativeLast()"));
        assertTrue(hasPrice0Cumulative, unicode"V2 pair Should be exposed. price0CumulativeLast()");
        assertTrue(hasPrice1Cumulative, unicode"V2 pair Should be exposed. price1CumulativeLast()");
        assertEq(price0Cumulative.length, 32, unicode"price0CumulativeLast() Should return a static word");
        assertEq(price1Cumulative.length, 32, unicode"price1CumulativeLast() Should return a static word");

        // And... V3 The landmark entrance is not answering -- that's what it is. V2It's...**Negative.**Evidence.
        (bool isV3,) = GRADUATED_POOL.staticcall(abi.encodeWithSignature("slot0()"));
        assertFalse(isV3, unicode"CRITICAL slot0() It should not be read -- read it clearly means it's not. V2 Match");

        console2.log(string.concat("  graduated pool token0=", vm.toString(token0), " token1=", vm.toString(token1)));
        console2.log(string.concat("  V2 blockTimestampLast=", vm.toString(uint256(blockTimestampLast))));
    }

    /// @notice CRITICAL **The real value of the original coin. MEME They'll turn you down.**,The blogger says that the government is not using the term "share" to read a normal number.
    ///
    /// @dev Here's the double. {PriceSource.QUOTE_MISMATCH} The form on the chain is also the most difficult to discover:
    ///      Readers are not miscounted, and the scale is normal, but are priced with another asset.
    function test_aNativeQuotedTokenIsRefusedByAGmeVault() public {
        CallVault vault = _deployVault(ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE);

        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.TwapSampleFailed(PriceSource.QUOTE_MISMATCH);
        assertFalse(vault.sampleTwap(), unicode"It's in original currency. MEME It's not supposed to be in there.");
        assertEq(vault.lastSampleAt(), 0, unicode"Nothing.");
    }

    //  The vault is real. Portal

    /// @notice The vault is looking at the truth. Portal Take a sample, read and inverted in equal order; one time in chronology gas.
    function test_theVaultSamplesTheRealPortal() public {
        address token = _launchGmeQuoted();
        CallVault vault = _deployVault(token);

        uint256 flapPrice = _state(token).price;

        uint256 before = gasleft();
        assertTrue(vault.sampleTwap(), unicode"Real Portal It should be taken from above.");
        uint256 gasUsed = before - gasleft();

        assertEq(vault.lastSampleAt(), uint64(block.timestamp));

        // There's only one ring left, and readings are certainly not available -- but the value of that sample can be found in the description() , and then the path check is:
        // And then we'll fix it. 24 An hourly observation point, composition t0..t24 Strict 24 Overrides the hour, and the reading should be exactly equal to the inverted value.
        assertTrue(_fillTwapRing(vault, address(this)), unicode"That one should be in there every hour.");
        (uint256 status, uint256 price) = vault.twap();
        assertEq(status, 0, unicode"Available after full storage");
        assertEq(price, uint256(1e36) / flapPrice, unicode"CRITICAL Read it. 1e36 / Flap It's... price");

        // CRITICAL gas:Much less than {PriceSource}  To the camera  50 The ceiling is 10,000. The reason for the ceiling is Portal (a) Is scalable;
        //    This assertion ensures that we do not set the ceiling too close to actual expenses. Flap I'm not going to be able to get a good look at it.
        assertLt(
            gasUsed, 200_000, unicode"One sample (read with lens) + Twice. SSTORE)Should be far below gas Upper limit"
        );
        console2.log(string.concat(unicode"  Real Portal Previous sampleTwap gas=", vm.toString(gasUsed)));
    }

    /// @notice CRITICAL CRITICAL **Core acceptance of promissory notes: a real big buy-in, no change 24 hourly weighted reading.**
    ///
    /// @dev The price shocks here are not made -- it's Na-jin. GME Buy it on a real conic.
    ///
    ///      Process: Full of a ring (price remains constant throughout the process)-> A big buy and a current price. ->
    ///      The assailant immediately took one.-> Read it now.
    ///
    ///      Two claims correspond to two levels of defence:
    ///      (1) **End-sector weight**:The sample just written is long in place. 0,So read it immediately.**Nothing.**;
    ///      (2) **1/24 Normal weights**:In this test, which is strictly hourly, this one is separated after an hour. spot Just the way it is.
    ///         1/24.`twap()` Final integer division to remove the whole number, so the difference between two integer readings is by raw Unit Comparison
    ///         Allows less than one raw The unit is up and up. `MAX_SAMPLE_GAP / 24h`;It's still separated.
    ///         Samples, not continuous observations or cumulative predictors.
    function test_aSingleLargeBuyBarelyMovesTheDayLongReading() public {
        address token = _launchGmeQuoted();
        CallVault vault = _deployVault(token);

        assertTrue(_fillTwapRing(vault, address(this)), unicode"That one should be in there every hour.");
        (uint256 status, uint256 calm) = vault.twap();
        assertEq(status, 0, unicode"First, there's a quiet reading available.");

        uint256 spotBefore = uint256(1e36) / _state(token).price;

        //  A large buy-in. A curved line of graduation. 400 GME($10K @ ~$25),So this is...**The whole curve scale**One pen.
        uint256 size = 200e18;
        address whale = makeAddr("whale");
        deal(GME, whale, size);
        vm.startPrank(whale, whale);
        IERC20(GME).approve(PORTAL, size);
        uint256 bought = portal.swapExactInput(
            ExactInputParams({
                inputToken: GME, outputToken: token, inputAmount: size, minOutputAmount: 0, permitData: ""
            })
        );
        vm.stopPrank();
        assertGt(bought, 0, unicode"This should be a deal.");

        uint256 spotAfter = uint256(1e36) / _state(token).price;
        assertLt(
            spotAfter,
            spotBefore,
            unicode"CRITICAL We should have bought the stock. MEME It's getting less -- the current price has moved."
        );

        // (1) Pull -> Take a sample now. -> Read now: The end is zero and the reading text lines remain intact.
        vm.warp(block.timestamp + 1 hours);
        assertTrue(vault.sampleTwap(), unicode"The assailants took the sample for the hour.");
        (, uint256 immediately) = vault.twap();
        assertEq(
            immediately, calm, unicode"CRITICAL The sample just written is in position. 0 Seconds, nothing to read."
        );

        // (2) Wait an hour to get it complete on this strict hourly path. 1/24 Weight.
        vm.warp(block.timestamp + 1 hours);
        (uint256 latestStatus, uint256 afterAnHour) = vault.twap();
        assertEq(latestStatus, 0);

        uint256 spotDrop = spotBefore - spotAfter; // How much did the price get pushed?
        uint256 twapDrop = calm > afterAnHour ? calm - afterAnHour : 0;

        // `twap()` Take the whole weight down; so the difference between two integer readings will be the theory here 1/24 Impacts up-to-the-top.
        // Comparison ceil(spotDrop / 24),Only one of the final eliminations will be accommodated. raw Unit error.
        assertLe(
            twapDrop,
            (spotDrop + 23) / 24,
            unicode"CRITICAL Every hour, the spot price is right. 24h Reads up to 1/24(The final offset is in the final form."
        );

        console2.log(
            string.concat(
                unicode"  Single buy-in. 200 GME:Current price ",
                vm.toString(spotBefore),
                unicode" -> ",
                vm.toString(spotAfter),
                unicode"(Fall ",
                vm.toString(spotDrop * 100 / spotBefore),
                "%)"
            )
        );
        console2.log(
            string.concat(
                unicode"                 24h TWAP ",
                vm.toString(calm),
                unicode" -> ",
                vm.toString(afterAnHour),
                unicode"(Fall ",
                vm.toString(twapDrop * 100 / calm),
                "%)"
            )
        );
    }

    //  Support

    function _state(address token) internal view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(PORTAL).getTokenV8Safe(token);
    }

    /// @dev It's the same thing as what the factory is about to do:**One line. `new`**(Decision-making 39-A3).Prices. Portal is the construction parameter,
    ///      And here's the one that's real in the chain -- this is the one that's gonna tell you the real price.
    ///      This fork suite only samples prices, so nonzero immutable destinations are sufficient for deployment.
    function _deployVault(address memeToken) internal returns (CallVault vault) {
        vault = new CallVaultHarness(
            IClearingPool(makeAddr("unused clearing pool")),
            makeAddr("unused distributor"),
            PORTAL,
            memeToken,
            GME,
            makeAddr("unused creator"),
            false
        );
    }

    /// @dev Keep the name and code of this document and continue to refer directly to "Send One" GME The priced test is a test price."
    ///      `newTokenV6`,Launcher rotation and `7777` salt I'm digging all the mines. {FlapGmeLaunch} Harmonization.
    function _launchGmeQuoted() internal returns (address token) {
        return _launchGmeQuotedToken("Call TWAP Probe", "WTWAP");
    }

    /// @dev solady `FixedPointMathLib.divWadUp` ..the equivalent is only for the restart. `reserve`.
    function _divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18 + y - 1) / y;
    }
}
