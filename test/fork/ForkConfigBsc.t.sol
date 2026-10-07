// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";

/// @notice BSC Fork Configuration**Offline**Returning to the web - no one's asking for a network.
///
/// The fork test itself. RPC It was the wrong configuration, and there was no end in the situation.
/// (CI Most of them. job,And anything that doesn't. `RPC_BSC` No one's looking at it. This file adds the half:
/// Anything.**You don't need a chain to get a false one.**Nature, all nailed in here.
contract ForkConfigBscTest is Test {
    //  Objective structure

    function test_theForkTargetIsShapedForBsc() public view {
        ForkTarget memory t = ForkConfigBsc.bsc();

        assertEq(t.chainId, 56, unicode"chainId It must be. BSC Main");
        assertEq(
            t.probe,
            ForkConfigBsc.GMEB,
            unicode"The status probe should be on the contract that's really going to be read."
        );
        assertEq(t.blockNumber, ForkConfigBsc.DEFAULT_BLOCK_BSC, unicode"Default pin height");
        assertGt(t.rpcUrls.length, 0, unicode"Can't be empty for the endpoint.");
    }

    /// @notice latest canary Target: No height, and**Refuse to retreat.**.
    ///
    /// @dev `strictBlock = true` It's the whole meaning of this:canary The question is "How's it going up there today?"
    ///      Returning to any historical height would be an erroneous answer, and it would seem like a yes.
    function test_theLatestTargetRefusesToFallBack() public view {
        ForkTarget memory t = ForkConfigBsc.bscLatest();

        assertEq(t.blockNumber, 0, unicode"latest Target is not pinned to height.");
        assertTrue(t.strictBlock, unicode"latest canary We must refuse to retreat to historical heights.");
        assertEq(t.chainId, 56, "chainId");
    }

    //  CRITICAL and Robinhood Contrast

    /// @notice CRITICAL **Decision-making 54 The core facts are written in the final form.**:GMEB The five dollar dollar denominated sum of the Robinhood GME Same in place.
    ///
    /// @dev It's "relocation." BSC The entire basis of the phrase "assets without changing the label" - the same curve (in which the value of the table is not specified)29),
    ///      Same. `nativeToQuoteSwapType`(7).This red means two chains of curves are slit.
    ///      The economic model calculations, the legal writings, the front end display multipliers are then re-examining.
    function test_gmebQuoteConfigMatchesRobinhoodGmeByteForByte() public pure {
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_ENABLED, ForkConfig.EXPECTED_GME_QUOTE_ENABLED, "enabled");
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEFAULT_CURVE,
            ForkConfig.EXPECTED_GME_QUOTE_DEFAULT_CURVE,
            unicode"defaultCurve  -  -  Both chains together. 29(CURVE_RH_25_ASSET)"
        );
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_ALTERNATIVE_CURVE,
            ForkConfig.EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE,
            "alternativeCurve"
        );
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            ForkConfig.EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            "nativeToQuoteSwapType"
        );
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEX_ID, ForkConfig.EXPECTED_GME_QUOTE_DEX_ID, "dexId");

        // The absolute value of the nailing -- the five above only prove that "one side is the same" and that the same change will still be green.
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEFAULT_CURVE, 29, unicode"The curve is... 29");
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE, 7, "swapType 7");
    }

    /// @notice  The price of the coin is equal to the amount of the coin. Robinhood Align - the constant is `CallLauncher` It's burning.
    ///         The same one with the same chain. launcher Source code, so they...**I have to.**Unanimously.
    function test_theLaunchEnumsAreTheSameOnBothChains() public pure {
        assertEq(ForkConfigBsc.FLAP_TOKEN_VERSION_TAXED_V3, ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3, "tokenVersion");
        assertEq(ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2, ForkConfig.FLAP_MIGRATOR_TYPE_V2, "migratorType");
        assertEq(ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED, ForkConfig.FLAP_DEX_THRESH_SUPPORTED, "dexThresh");
        assertEq(
            ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2,
            1,
            unicode"V2_MIGRATOR  -  -  3(Infinity CL)Yes. BSC - The top is rejected."
        );
    }

    /// @notice CRITICAL **"The most dangerous way to read is to copy it."**
    ///
    /// @dev `ForkConfig` The same thing is written in the note in the opposite direction:BSC It's... Portal Address in Robinhood Chain Go, go, go!
    ///      **Yes, I do. 23,959 Byte Code**But it's not that chain. Portal.This test is in the right direction...
    ///      BSC In this configuration, all the addresses "two chains must be different" are really different.
    ///      Once they're equal, the fork test will read one with a code and a answer. getter,But the semantics are completely wrong.
    function test_theAddressesThatMustDifferReallyDo() public pure {
        assertTrue(ForkConfigBsc.FLAP_PORTAL != ForkConfig.FLAP_PORTAL, unicode"Two chains. Portal Different address");
        assertTrue(ForkConfigBsc.GMEB != ForkConfig.GME, unicode"GMEB and GME It's two different tokens.");
        assertTrue(
            ForkConfigBsc.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION
                != ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
            unicode"Two chains. FlapTaxTokenV3 The initialization of the beautiful mine depends on it."
        );
        assertTrue(
            ForkConfigBsc.PINNED_GRADUATED_TAX_TOKEN_V3_SAMPLE != ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            unicode"The sample is different."
        );
        assertTrue(
            ForkConfigBsc.BSTOCK_COMPLIANCE != ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"Compliance module and Robinhood The Central Registration Form is at different locations"
        );
    }

    //  The beautiful mine.

    /// @notice CRITICAL **The original hussy must be included. BSC That one. TaxTokenV3 Realization, no. Robinhood That one.**
    ///
    /// @dev This is the one the study did not foresee.`VanityAddressRequirementNotMet`,`0xca4c5b2d`):
    ///      BSC Portal Force token address `7777` And the end, and the initialization code for mining is the actual address.
    ///      Take it. Robinhood That one's gone and dug. salt Yes. BSC Go, go, go!**None of them are right.**,
    ///      Every launch will be there. `Portal.newTokenV6` On the spot. revert.
    ///
    ///      And here, independently, recalculate, without the test function itself -- otherwise, both sides are green.
    function test_theVanityInitCodeHashEmbedsTheBscImplementation() public pure {
        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                bytes20(0x024f18294970B5c76c0691b87f138A0317156422),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertEq(ForkConfigBsc.vanityInitCodeHash(), expected, unicode"Initialize Hashi");

        bytes32 robinhoodFlavoured = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                bytes20(ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertTrue(
            ForkConfigBsc.vanityInitCodeHash() != robinhoodFlavoured,
            unicode"CRITICAL The mine constant must be replaced by the mine constant. BSC The one-- copy. Robinhood It'll get every launch. revert"
        );
    }

    /// @notice I'm gonna dig it up with the real one. salt Recalculate:CREATE2 The man who deployed it was... **Portal For yourself.**,And the address is actually... 7777 End of line.
    ///
    /// @dev salt `0x272fd24bb0` Address with token `0x2f3a5Ac3...7777` From**Same time.**Real successful fork launch.
    ///      (`.context/bsc-probe`,2026-09-08):The one calling in the tree. `newTokenV6`  And the reference to the salt,
    ///      And... `TaxProcessor.initialize` The entry of the calculated token address -- cross-checking of both ends.
    ///      This one is pinned down to three things: initialization of the Hashi pair,**The man who deployed it was... Portal Not launcher**,And the rule of the beauty is the end. 2 bytes.
    ///
    ///      WARNING Write this test and run it twice. salt One time with the address, it caught him in the spot...
    ///      This is where "independent recosting" is worth more than "in a line in a log" .
    function test_aRealMinedSaltReproducesTheTokenAddress() public pure {
        bytes32 salt = bytes32(uint256(0x272fd24bb0));
        address predicted =
            vm.computeCreate2Address(salt, ForkConfigBsc.vanityInitCodeHash(), ForkConfigBsc.FLAP_PORTAL);

        assertEq(
            predicted,
            0x2f3a5Ac3e01748104445bF27894296Ed72397777,
            unicode"The real launch's token address -- the initial code or the deployment changed."
        );
        assertEq(
            uint256(uint160(predicted)) & 0xffff, 0x7777, unicode"The \"Sweet\" rule: the last two bytes must be 0x7777"
        );
    }

    //  Peer Table

    /// @notice It's not worth it. `RPC_BSC` The public end of the list**Just one. latest Peer**.
    ///
    /// @dev The network is a "unrecoverable basis for the clandestine use of a non-archiving endpoint":
    ///      There's only one item in the table, and... {ForkTest} The first round of the series is bound to fall on it.
    ///      It's like, "No end points can serve the height of nails."**Visible Failures**,Exactly what we want.
    function test_theFallbackTableHasExactlyOnePublicEndpoint() public view {
        if (bytes(vm.envOr(ForkConfigBsc.ENV_RPC_BSC, string(""))).length != 0) return; // We'll skip the machine.
        if (bytes(vm.envOr(ForkConfigBsc.ENV_RPC_BSC_LIST, string(""))).length != 0) return;

        ForkTarget memory t = ForkConfigBsc.bsc();
        assertEq(
            t.rpcUrls.length,
            1,
            unicode"There's no community backsliding... BSC There are no free ends that serve historical heights"
        );
        assertEq(t.rpcUrls[0], ForkConfigBsc.RPC_BSC_PUBLIC, unicode"The bottom line is the public end.");
        assertTrue(ForkConfig.looksLikeRpcUrl(t.rpcUrls[0]), unicode"It has to be like... URL");
    }
}
