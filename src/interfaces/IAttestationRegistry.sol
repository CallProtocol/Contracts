// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IAttestationRegistry
/// @notice ClearingPool Dependency**All**Read interface - only one function.
///
/// Ikei asked only one question about the statement of compliance: "Did this beneficiary say it?"**No, no, no, no.**What version of the statement?
/// When did you sign it, what it was -- those were front-end and forensics. The chain only asked for ">=1 I'm not sure if I'm going to be able to do this.
///
/// CRITICAL The interface is so small that there's only one left. view,It is deliberate: it is the only external compliance dependencies of the clearing house.
/// The bigger the face, the bigger the space for "a controlled switch." `docs/spec.md`.
interface IAttestationRegistry {
    /// @notice Account declared version number **+1**;`0` It is not stated.
    /// @dev Save `version + 1` Not `version`,It's about "never making a statement" and "declaration." version 0
    ///      Distinguished in the same slot -- otherwise `versions[0]` The author of the statement cannot be distinguished from those who have lived in the future.
    function attestedVersion(address account) external view returns (uint256);
}
