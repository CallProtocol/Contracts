// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CallVault} from "../../src/CallVault.sol";
import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title CallVaultHarness
/// @notice How many of the production contracts?**I'm not going anywhere.**And it's exposed to tests: any parameter opens up, the unchanging breakup is shown,
///         And two groups. `internal` Constants and {CallVault-_nextExpiry}.
///
/// @dev The test is still...**Production contract.**Function -- There's no business logic in this line. And "Property contracts don't add one entry."
///      By writing face count: it reads `out/CallVault.sol/CallVault.json`,Auxiliary functions for this document
///      I can't get in that piece.
///
///       M2-4(issue #36)After landing,{harnessOpenSeries} **Not anymore. `openSeries()` The double.**  -  -
///      The whole thing is in the real entrance. `test/CallVaultOpenSeries.t.sol` and
///      `test/fork/RobinhoodOpenSeries.t.sol` It's driven directly. It's left with only one thing, and that's it.
///      Still in place: to**Income path and normative aspects**The test is a cheap "serialized" state, so you don't have to put it first. 24 A sample.
///      Fill the rings, and don't have to run the time until a Friday. Two things are measured separately, so that you can get a better time. `processRevenue`  The reason for failure
///      "and never will be."TWAP Not ready."
contract CallVaultHarness is CallVault {
    constructor(
        IClearingPool pool_,
        address merkleDistributor_,
        address portal_,
        address taxToken_,
        address quoteToken_,
        address creator_,
        bool wrapsNative_
    ) CallVault(pool_, merkleDistributor_, portal_, taxToken_, quoteToken_, creator_, wrapsNative_, address(0xfee)) {}

    /// @notice Use**Any** strike and expiry Open a series of -- no one in the production portal is allowed to pick, so this path only exists in the test.
    ///
    /// @dev CRITICAL The sequence is consistent with production and is heavy: first, the pool is opened successfully and then two fields are written.
    ///      `processRevenue` Dependency`strike != 0`  The series is opened by the vault."
    ///      Once the series fails, the field remains in a state of direction to others, and the revenue will never be released from the vault again.
    function harnessOpenSeries(uint128 strike_, uint64 expiry_) external returns (uint256 seriesId) {
        seriesId = pool.openSeries(taxToken, collateralToken(), expiry_, strike_);
        strike = strike_;
        seriesExpiry = expiry_;
    }

    /// @notice {CallVault-_nextExpiry}  -  -  Friday. 21:00 UTC Alignment + >=7 Day life.
    /// @dev It's exposed to the alignment rule.**Direct**Sweep it all the time (including the multi-year, cross-border and sector-wide) fuzz),
    ///      And not for every moment. `vm.warp` And set the whole vault up. The production contract is. `internal`:
    ///      The only consumers in the chain live in the same contract.
    function harnessNextExpiry(uint256 nowTs) external pure returns (uint64) {
        return _nextExpiry(nowTs);
    }

    /// @notice Six-state code in the series. {CallVault-openSeriesStatus} .
    /// @dev Same {harnessTwapConstants}:The test is based on a name, and it's produced. ABI There should be no more six entrances for this.
    function harnessOpenConstants() external pure returns (uint256[9] memory constants) {
        constants = [
            OPEN_OK,
            OPEN_ALREADY_OPEN,
            OPEN_TOO_EARLY,
            OPEN_TWAP_UNAVAILABLE,
            OPEN_STRIKE_ROUNDS_TO_ZERO,
            OPEN_STRIKE_TOO_LARGE,
            uint256(OPEN_WINDOW),
            uint256(MIN_SERIES_LIFETIME),
            STRIKE_BPS
        ];
    }

    /// @notice **Write fields, not pools.**  -  -  Put the same thing on top after it's broken.
    /// @dev It's for two things:`description()` The idea of a new system of social media is to create a new environment for the people of the world.
    ///      and `test_processRevenue_revertsWhenTheSeriesFieldsWereWrittenWithoutOpening`
    ///       -  -  The test certificate."M2-4 The "Turn Up" will blow up on the spot, instead of placing the money quietly elsewhere.
    function harnessWriteSeriesFieldsWithoutOpening(uint128 strike_, uint64 expiry_) external {
        strike = strike_;
        seriesExpiry = expiry_;
    }

    /// @notice TWAP . The window parameter and the status code.
    ///
    /// @dev They're in the production contract. `internal`  -  -  Because the only consumers in the chain.`openSeries()`)
    ///      Lives in the same contract, makes them. `public` It's just for the... ABI The government has also been able to provide access to the Internet.
    ///      And each one of them is in `vaultUISchema` One exemption in the cross-check.
    ///
    ///      `constants[0..5]` (a) Sample numbers, minimum spacing, maximum gap, maximum sample age, strict window and maximum perspective, in order;
    ///      `constants[6..11]` It's six state codes. The external map is in `CallVault.twap` * The present document was not edited before being sent to the United Nations translation services.
    ///      `docs/spec.md`.
    function harnessTwapConstants() external pure returns (uint256[12] memory constants) {
        constants = [
            TWAP_SAMPLES,
            SAMPLE_INTERVAL,
            MAX_SAMPLE_GAP,
            MAX_SAMPLE_AGE,
            MIN_TWAP_WINDOW,
            MAX_TWAP_WINDOW,
            TWAP_OK,
            TWAP_RING_NOT_FULL,
            TWAP_STALE,
            TWAP_WINDOW_TOO_SHORT,
            TWAP_WINDOW_TOO_LONG,
            TWAP_SAMPLE_GAP
        ];
    }
}
