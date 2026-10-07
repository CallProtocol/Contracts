// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IVaultRegistry
/// @notice ClearingPool Dependency**All**Identity Root Read Interface - Only one function.
///
/// Ikei asked me one thing about identity: "This one." MEME Who is the legal vault."**No, no, no, no.**When did you write this?
/// What happened when it was written by the factory -- those were forensics and front-end things.
///
/// CRITICAL The interface is so small that there's only one left. view,and {IAttestationRegistry} The same reason: it is dependent on external authorization of the clearing pool,
/// The bigger the face, the bigger the space for "a controlled switch." And the pool can't be upgraded -- the door is not gonna be broken.
///
/// WARNING **I'm not copying it. Flap It's... `getVault(address)`**:When that one's not gonna find out. revert `VaultNotFound`
/// (`0xc02219d9`,I'm sure it's worth a white signature. fail-closed The path of the authorization is one. revert
/// Path. The syntax here is "no" returns `address(0)`,See {vaultOf}.
interface IVaultRegistry {
    /// @notice Some of them. MEME The legal vault.**Unbound Return `address(0)`,No, no. revert.**
    ///
    /// @dev CRITICAL No, no. revertIt's a character that's been asserted, not an observation...
    ///      `test/VaultRegistry.t.sol::testFuzz_vaultOf_neverReverts` Use `staticcall` Catch the results and nail it.
    ///      The pool used it as an authorized door, and the pool could not be upgraded: one more on this path. revert,It's the same as a home network.
    ///      The contract that will never be changed and a switch that will never open the series.
    function vaultOf(address memeToken) external view returns (address vault);
}
