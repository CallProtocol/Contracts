// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title VaultStub
/// @notice The smallest double to play "the vault of the series"  -  **The only self-building allowed for this milestone mock**(issue #9 / #5Out of Scope).
///
/// There is only one ground for allowing it to exist:`CallVault` Present. M2 It's only there, and... M1-4 Two Functions to Deliver
/// It's just open to the vault. And all the tests drive the real four contracts.issue #5The test stitches."
///
/// So this double meant it.**Nothing.**:Not really. TWAP,Uncertainty strike,No accounts are kept and only the call is transferred to the pool.
/// It does one more thing, and the test is a test of something we don't publish.
///
/// @dev CRITICAL The vault must be...**Contract**,No, it's not. EOA.Use `vm.prank` Pretending to be one. EOA The vault will make an entire set of problems invisible...
///      Real Treasury Tranquilling `depositAndMint`  And the pool will be from **It's...**There. `transferFrom`,And the authority, the balance,
///      The government has been working on the issue of the "whomever found in the cast" and "who is called back to the cast" and has been working on the contract account.
contract VaultStub {
    IClearingPool public immutable pool;

    constructor(IClearingPool pool_) {
        pool = pool_;
    }

    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId)
    {
        return pool.openSeries(memeToken, stockToken, expiry, strike);
    }

    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount) external returns (uint256 minted) {
        return pool.depositAndMint(seriesId, to, expectedAmount);
    }

    /// @dev The pool. `transferFrom` Pull the collateral from the vault, so the authorization is on the side of the vault.
    function approve(IERC20 token, uint256 amount) external {
        token.approve(address(pool), amount);
    }
}
