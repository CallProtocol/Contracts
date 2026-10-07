// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PriceSource} from "../../src/PriceSource.sol";

/// @notice - Put it on. {PriceSource} That. `internal` . The readable function is pulled once**Real External Call**Back.
///
/// @dev There are two reasons for this:
///      (1) `internal library` The function is directly transacted in the test contract, but that's how it runs.**Test the contract yourself.**(a) The context;
///      (2) CRITICAL The core commitment of the library is "No one" revert.Directly from the test contract. Once. revert It's straight.
///         Blowing up the test looks like a failure; it's only possible to use it when it's called from outside. `(bool ok, ) = probe.call(...)`
///         Put it. revert "No." "Becoming one."**Acclaimable boolean value**.
contract PriceSourceProbe {
    function spot(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        return PriceSource.spot(portal, memeToken, quoteToken, false);
    }

    /// @dev Original livelihood price (%)`wrapsNative = true`,C2 7.14):Additional acceptories for curve stages `f[1] == address(0)`.
    function spotNative(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        return PriceSource.spot(portal, memeToken, quoteToken, true);
    }

    /// @dev Take it once.**This time call yourself**It's spent. gas,It's used to pin down the limit. staticcall The cost of the project is really high."
    function spotGas(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint256 gasUsed, uint8 status)
    {
        uint256 before = gasleft();
        (status,,) = PriceSource.spot(portal, memeToken, quoteToken, false);
        gasUsed = before - gasleft();
    }
}
