// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Runtime-only replacement for Robinhood's access registry during the #67 gating rehearsal.
/// @dev The driver installs deployedBytecode with anvil_setCode, so constructor state cannot be used.
contract PausedAccessRegistry {
    address internal constant STOCK_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    /// @dev Robinhood uses this same address as both the access registry and the Stock beacon.
    function implementation() external pure returns (address) {
        return STOCK_IMPLEMENTATION;
    }

    function paused() external pure returns (bool) {
        return true;
    }

    function isBlocked(address) external pure returns (bool) {
        return false;
    }
}
