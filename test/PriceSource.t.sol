// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PriceSource} from "../src/PriceSource.sol";
import {IFlapPortalLens} from "../src/interfaces/IFlapPortalLens.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {PriceSourceProbe} from "./helpers/PriceSourceProbe.sol";

/// @notice {PriceSource}:The matrix, the terms of the two branches, and "No one. revert.
///
/// Real Portal The one on the top. `test/fork/RobinhoodTwapSource.t.sol`  -  -  The double can't prove it.
/// Flap It's really so coded. It's really after graduation. price "The zero." Those are about...**A contract with someone else.**The truth.
/// This is proof of our own behavior with the given input, and...**It's a word for it.**.
contract PriceSourceTest is Test {
    address internal meme = makeAddr("meme");
    address internal stock = makeAddr("stock");
    address internal stranger = makeAddr("stranger token");

    FlapPortalStub internal portal;
    PriceSourceProbe internal probe;

    function setUp() public {
        portal = new FlapPortalStub();
        probe = new PriceSourceProbe();
    }

    function _spot() internal view returns (uint8 status, uint256 price, uint8 source) {
        return probe.spot(address(portal), meme, stock);
    }

    //  Subscript: Non-revolving

    /// @notice CRITICAL **`PriceSource` The four fields that were marked by word, it was. struct The four in there.**
    ///
    /// @dev The evidence is not "tick down" again, but rather for the double. **Solidity Your own. ABI Encoder**
    ///      Press {IFlapPortalLens.TokenStateV8Safe} Return one**Each field is different.**Other Organiser
    ///      Any under-painting error would have been the value of another field, and the following one assertion would have been red.
    ///
    ///      I'm giving you a special leave. `price` and `reserve` / `circulatingSupply` Different.`quoteTokenAddress` and `pool` Different...
    ///      The adjacent field is the easiest to read strings.
    function test_wordOffsets_matchTheStructDeclaration() public {
        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 1; // Subscript 0
        state.reserve = 11;
        state.circulatingSupply = 22;
        state.price = 1e18; // Subscript 3  -  -  It happens after the reverse. 1e18
        state.tokenVersion = 6;
        state.r = 55;
        state.h = 66;
        state.k = 77;
        state.dexSupplyThresh = 88;
        state.quoteTokenAddress = stock; // Subscript 9
        state.nativeToQuoteSwapEnabled = true;
        state.extensionID = bytes32(uint256(99));
        state.buyTaxRate = 300;
        state.sellTaxRate = 300;
        state.pool = stranger; // Subscript 14
        state.progress = 1e17;
        state.lpFeeProfile = 1;
        state.dexId = 2;

        portal.setState(meme, state);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(
            status,
            PriceSource.OK,
            unicode"status Read the subscript. 0(Or what you read here is... reserve (and so on)"
        );
        assertEq(price, 1e18, unicode"price Read the subscript. 3");
        assertEq(source, PriceSource.SOURCE_CURVE, unicode"status = 1 Walk Curves");

        // `quoteTokenAddress` If read in string `pool`,This one will become QUOTE_MISMATCH.
        state.quoteTokenAddress = stranger;
        portal.setState(meme, state);
        (status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"quoteTokenAddress Read the subscript. 9");

        // `pool` If you read a string in another field, the graduating branch asks for an address that does not exist.
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(2e18, 1e18);
        state.status = 4;
        state.price = 0;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);
        (status, price, source) = _spot();
        assertEq(status, PriceSource.OK, unicode"pool Read the subscript. 14");
        assertEq(price, 2e18, unicode"2 Grandpa. MEME Tunnel 1 Stock shares");
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    //  Quantum: Rewind right?

    /// @notice CRITICAL **Flap Give it to the last count.** This one nails both directions because "forgot to reverse" is on the number.
    ///         It's just "Put it." price "Put it in the same way" -- one that can be compiled, run, figure it out. strike The mistake.
    function test_curve_invertsFlapsPrice() public {
        // 1e18 raw MEME Value 2e18 raw Equities  1e18 raw Equities 0.5e18 raw MEME.
        portal.setCurve(meme, stock, 2e18);
        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(
            price, 0.5e18, unicode"MEME The government has been making a difference.1 A share is only worth half. MEME"
        );

        // Conversely:MEME Very cheap.
        portal.setCurve(meme, stock, 1e9);
        (, price,) = _spot();
        assertEq(price, 1e27, unicode"1e36 / 1e9");
    }

    /// @notice The size on the real curve:`price  1.73e9`(- I'm sure. See? docs/research/flap-portal-price-semantics.md).
    /// @dev This nail is...**It's falling within a single person's scope of checking.**,Not a certain exact value...
    ///      Once the scale is reversed, there's 30 orders of magnitude here, as can be seen.
    function test_curve_realWorldMagnitude() public {
        portal.setCurve(meme, stock, 1_733_439_722);
        (uint8 status, uint256 price,) = _spot();

        assertEq(status, PriceSource.OK);
        // 1e36 / 1.733e9  5.77e26  -  -  1 Stock exchange 5.8 Billiones. MEME,And'10% Taxes,10 Billion supply,
        // The curve just started to agree intuitively.
        assertGt(price, 5e26, unicode"Bottom");
        assertLt(price, 6e26, unicode"Upper boundary");
    }

    /// @notice Relative cut-off error for inversion <= `flapPrice / 1e36`.
    function testFuzz_curve_inversionRoundTripsWithinOneUlp(uint256 flapPrice) public {
        flapPrice = bound(flapPrice, 1, 1e30);
        portal.setCurve(meme, stock, flapPrice);

        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(
            price,
            1e36 / flapPrice,
            unicode"It was the one time that the whole thing was cut off, and there was nothing else to do."
        );
        assertLe(price * flapPrice, 1e36, unicode"Just take it down, never zoom in.");
        assertGt((price + 1) * flapPrice, 1e36, unicode"And less than one. ulp");
    }

    //  Toggle Condition: Curve <-> I'm a pool.

    /// @notice CRITICAL **Switch condition Flap It's... `status`,There is no overlap zone between the two branches.**
    ///
    /// @dev After graduation, Flap - Put it on. `price` So, "forgot to cut the branch after graduation" is not a problem with precision, but it is a problem with the fact that the Zeros are not the only ones who are not cut.
    ///      It's reading to zero -- this claim holds the fact:`status = 4` Even when `price` Not zero, not zero.
    function test_branchSwitch_isDrivenByStatusNotByWhicheverFieldLooksUsable() public {
        DexPairStub pair = new DexPairStub(stock, meme); // The order is the other way around.
        pair.setReserves(1e18, 7e18); // stock=1e18, meme=7e18

        portal.setGraduated(meme, stock, address(pair));
        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 7e18, unicode"1 Stock exchange 7 Grandpa. MEME  -  -  It's not about the sequence of the legs.");
        assertEq(source, PriceSource.SOURCE_POOL);

        // Put the price on the curve.**Looks like it's working.**Value: After graduation it must be ignored.
        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 4;
        state.price = 3e18;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);

        (, price, source) = _spot();
        assertEq(price, 7e18, unicode"CRITICAL status = 4 I can't even see the price of the curve.");
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    /// @notice The curve is read in the curve, even if it's a curve. `pool` Fields with a real pool.
    function test_branchSwitch_curveStageIgnoresAnyPool() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(100e18, 1e18);

        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 1;
        state.price = 2e18;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 0.5e18, unicode"The curve phase is the curve price.");
        assertEq(source, PriceSource.SOURCE_CURVE);
    }

    /// @notice The other four states are all rejected -- they're either priceless or that price is meaningless.
    function test_otherStatuses_areRefused() public {
        uint8[4] memory refused = [0, 2, 3, 5]; // Invalid / InDuel / Killed / Staged

        for (uint256 i = 0; i < refused.length; i++) {
            portal.setCurve(meme, stock, 2e18);
            portal.setStatus(meme, refused[i]);

            (uint8 status, uint256 price, uint8 source) = _spot();
            assertEq(status, PriceSource.NOT_PRICEABLE, string.concat("status=", vm.toString(refused[i])));
            assertEq(price, 0);
            assertEq(source, PriceSource.SOURCE_NONE);
        }
    }

    //  Currency reconciliation

    /// @notice CRITICAL **Flap When we're not counting the shares, the denominator of the price is not our shares.**
    ///
    /// @dev This is the hardest to find in the first category: reading.**No errors, no errors, no errors.**,Just taking another asset.
    ///      It's in original currency. Flap Currency (in US$)`quoteTokenAddress == address(0)`)This is the way to be rejected.
    function test_quoteMismatch_isRefusedEvenThoughThePriceLooksFine() public {
        portal.setCurve(meme, stranger, 2e18);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"Something else. ERC20 Price");

        portal.setCurve(meme, address(0), 2e18);
        (status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"Original currency");
    }

    //  The one on the other side of the pool.

    function test_pool_refusesAPairThatIsNotOurTwoLegs() public {
        DexPairStub pair = new DexPairStub(meme, stranger);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.POOL_MISMATCH, unicode"There's no stock in the match.");
        assertEq(price, 0);
    }

    function test_pool_refusesEmptyReserves() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_EMPTY, unicode"Both legs are empty.");

        pair.setReserves(1e18, 0);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_EMPTY, unicode"The denominator is zero.");
    }

    /// @notice CRITICAL Coming out. `uint112` The reserves must be blocked before the multiplication -- otherwise the multiplication.**Spill revert**.
    function test_pool_refusesReservesThatBreakTheAbi() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(type(uint256).max, 1e18);
        pair.setMode(DexPairStub.Mode.DirtyReserves);
        portal.setGraduated(meme, stock, address(pair));

        (bool ok, bytes memory ret) =
            address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
        assertTrue(ok, unicode"CRITICAL And we can't let the price of the cross-border reserves go. revert");

        (uint8 status,,) = abi.decode(ret, (uint8, uint256, uint8));
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    /// @notice `getReserves()` The third word must be strictly the same. `uint32`,It is not possible to engage in the same judgement after silent interruption.
    function test_pool_refusesTimestampThatBreaksTheAbi() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setMode(DexPairStub.Mode.DirtyTimestamp);
        portal.setGraduated(meme, stock, address(pair));

        (bool ok, bytes memory ret) =
            address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
        assertTrue(ok, unicode"CRITICAL Cross-border time stampes don't allow for reading prices. revert");

        (uint8 status,,) = abi.decode(ret, (uint8, uint256, uint8));
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    /// @notice Portal Returned `pool` Yeah. address word;High 96 The spot is not cut silently.
    function test_poolAddressWithHighBitsIsUnreadable() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));
        portal.setMode(FlapPortalStub.Mode.DirtyPool);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.PORTAL_UNREADABLE);
        assertEq(price, 0);
        assertEq(source, PriceSource.SOURCE_NONE);
    }

    function test_pool_acceptsReservesFromAnEarlierBlock() public {
        vm.warp(1 days);
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setBlockTimestampLast(uint32(block.timestamp - 1));
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 7e18);
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    /// @notice CRITICAL The spot price of the same piece of recently converted reserve may be manipulated, rather than taking it in a sample.
    function test_pool_refusesReservesUpdatedThisBlock() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setBlockTimestampLast(uint32(block.timestamp));
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.POOL_UPDATED_THIS_BLOCK, unicode"No sample of the same updated reserve");
        assertEq(price, 0);
        assertEq(source, PriceSource.SOURCE_NONE);
    }

    function test_pool_refusesAPoolThatCannotBeRead() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        pair.setMode(DexPairStub.Mode.RevertAll);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"Three readings. revert");

        pair.setMode(DexPairStub.Mode.ShortReserves);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"getReserves Return less than three words");
    }

    /// @notice V2 static return values fixed; extra word It's not a credible thing. pair ABI Let go.
    function test_pool_refusesOverlongAbiReturns() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        pair.setMode(DexPairStub.Mode.LongToken0);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"token0 One more word must be rejected.");

        pair.setMode(DexPairStub.Mode.LongReserves);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"getReserves One more word must be rejected.");
    }

    /// @notice No pool address -- don't make zero a question.
    function test_pool_refusesTheZeroAddress() public {
        portal.setGraduated(meme, stock, address(0));
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    //  No one. revert

    /// @notice CRITICAL Portal How bad is it that the read price is just returning a failed code.
    ///
    /// @dev Real Portal When the token does not exist**It's true. revert It's...**(`TokenNotFound(address)`),
    ///      So this is not a hypothetical failure pattern, but...**Default**That one.
    function test_portal_neverRevertsWhateverItDoes() public {
        portal.setCurve(meme, stock, 2e18);

        FlapPortalStub.Mode[4] memory modes = [
            FlapPortalStub.Mode.Revert,
            FlapPortalStub.Mode.Short,
            FlapPortalStub.Mode.BurnGas,
            FlapPortalStub.Mode.Flood
        ];

        for (uint256 i = 0; i < modes.length; i++) {
            portal.setMode(modes[i]);

            (bool ok, bytes memory ret) =
                address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
            assertTrue(ok, string.concat(unicode"Mode ", vm.toString(i), unicode" Let's read the price. revert Yes."));

            (uint8 status, uint256 price,) = abi.decode(ret, (uint8, uint256, uint8));
            assertEq(status, PriceSource.PORTAL_UNREADABLE, unicode"You can't read it, you can't read it.");
            assertEq(price, 0);
        }

        // Read immediately after recovery - Failure is**Current**No after-effects.
        portal.setMode(FlapPortalStub.Mode.Honest);
        (uint8 finalStatus,,) = _spot();
        assertEq(finalStatus, PriceSource.OK);
    }

    /// @notice Portal There's no code on the address... `staticcall` Yes.**Success**The first time I saw the news, I was told that I was not a student, and I was not a student.
    function test_portal_withoutCodeIsUnreadable() public {
        (uint8 status,,) = probe.spot(makeAddr("not a portal"), meme, stock);
        assertEq(status, PriceSource.PORTAL_UNREADABLE);
    }

    /// @notice CRITICAL Copy the cost of a large piece of data back when it is returned**I shouldn't.**It's falling on our heads.
    ///
    /// @dev With Treasury `receive()` The same pit:`(bool, bytes memory) = addr.staticcall(...)`
    ///       Will take the whole  returndata Copy to caller memory, and the memory extension is not limited gas Inside.
    ///      Only the house. 576 Bytes, so the amount of this assertion is "that copy did not happen."
    function test_portal_doesNotPayForAFloodedReturnValue() public {
        portal.setCurve(meme, stock, 2e18);
        portal.setMode(FlapPortalStub.Mode.Flood);

        (uint256 gasUsed, uint8 status) = probe.spotGas(address(portal), meme, stock);

        assertEq(status, PriceSource.PORTAL_UNREADABLE);
        // Upper boundary = It's been transmitted. 50 - Man.+ We're on this side of the balance.
        // Copy 9000 I'll have to take another word. 18.5 Van, cross this line.
        assertLt(
            gasUsed,
            560_000,
            unicode"CRITICAL returndata It's copied in... the cost of the operation is out of control."
        );
    }

    //  Currency reconciliation of original livelihood price (in millions of United States dollars)A-3,7.14)

    /// @dev WBNB The address of the double. `_quoteToken`).
    address internal wbnb = makeAddr("WBNB");

    /// @notice CRITICAL **Original release**:Curve Phase Flap Report `quoteTokenAddress = address(0)`,The vault.
    ///         quote Yes. WBNB  -  -  The value of the two is equal (in value)1:1,Same 18 The blogger adds:`wrapsNative = true` Time is not the word. mismatch.
    function test_native_curveAcceptsZeroQuoteTokenAddress() public {
        portal.setCurve(meme, address(0), 2e18); // Flap Price of living at origin (%)address(0))
        (uint8 status,, uint8 source) = probe.spotNative(address(portal), meme, wbnb);
        assertEq(status, PriceSource.OK, unicode"CRITICAL Original:f[1]==0 Let go, no report. QUOTE_MISMATCH");
        assertEq(source, PriceSource.SOURCE_CURVE, unicode"Walk curve");
    }

    /// @notice CRITICAL **Examples of failures (comparability)**:Same. `f[1] == 0`,But...**It's not original.**(`wrapsNative = false`) -  -
    ///         Report still. `QUOTE_MISMATCH`.The opening was only in the original world and not all the vaults were unsealed.
    function test_native_nonNativeStillMismatchesOnZeroQuoteTokenAddress() public {
        portal.setCurve(meme, address(0), 2e18);
        (uint8 status,,) = probe.spot(address(portal), meme, wbnb); // wrapsNative=false
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"CRITICAL Non-original:f[1]==0 Still. mismatch");
    }

    /// @notice CRITICAL **Examples of failures**:Only originals. `f[1] == 0`,**No, no.**Accept any other address.Flap If you're gonna call me one,
    ///         Neither. 0,Not really. WBNB The price of the coin is not the original price of livelihood. mismatch.
    function test_native_rejectsANonZeroNonWbnbQuoteTokenAddress() public {
        portal.setCurve(meme, makeAddr("some other quote"), 2e18);
        (uint8 status,,) = probe.spotNative(address(portal), meme, wbnb);
        assertEq(
            status,
            PriceSource.QUOTE_MISMATCH,
            unicode"CRITICAL The originals only accept it. address(0),No other address."
        );
    }

    /// @notice After graduation, the legs of the pool are... WBNB(`f[1] == wbnb`):It's from the original.**Reconciliations directly matched**,Shit. `f[1]==0` That one.
    ///         Special sentence - same route as non-pretore. Only reconciliation is allowed here. `QUOTE_MISMATCH`);The pool itself.
    ///         Read or not, it is another matter (the pool here is empty, and the rest of the resumed session falls to "I can't read" , which is not a question of reconciliation).
    function test_native_graduatedReconcilesOnWbnbPoolLeg() public {
        portal.setGraduated(meme, wbnb, makeAddr("the V2 pool"));
        (uint8 status,,) = probe.spotNative(address(portal), meme, wbnb);
        assertTrue(
            status != PriceSource.QUOTE_MISMATCH,
            unicode"CRITICAL f[1]==WBNB The reconciliation is passed. It's not stuck. mismatch"
        );
    }
}
