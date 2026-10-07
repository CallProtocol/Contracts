// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice Smoke:Robinhood Chain(chainId 4663)The splits are connected and the readings are true. GME.
///
/// Here.**No, no.**The logic of the business -- it proves that "all the cross-tests behind the real collateral are made on a foundation that works."
/// The collateral has to be on a real contract, not on a real contract. mock The reason is clear. issue #5.
contract RobinhoodGmeForkTest is ForkTest {
    IERC20Metadata internal gme;

    function setUp() public {
        selectFork(ForkConfig.robinhood());
        gme = IERC20Metadata(ForkConfig.GME);
    }

    function test_readsRealGmeTotalSupplyAndDecimals() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There's no code on the address.");

        uint8 decimals = gme.decimals();
        uint256 totalSupply = gme.totalSupply();

        // EIP-8056 The change in the stock is uiMultiplier Not balanceOf,decimals Constant 18;
        // M1 All of you. raw balanceOf And that's exactly what that premise is.
        assertEq(decimals, 18, "GME.decimals()");
        assertGt(totalSupply, 0, "GME.totalSupply()");
        assertEq(gme.symbol(), "GME", "GME.symbol()");

        console2.log(
            string.concat(
                "  GME: ",
                gme.name(),
                unicode"  totalSupply=",
                vm.toString(totalSupply),
                unicode" raw  decimals=",
                vm.toString(uint256(decimals))
            )
        );
    }
}
