// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ICall
/// @notice `ClearingPool` Dependency**All**The certificate interface -- only two writings -- foundry and destruction.
///
/// The pool does not read the balance of the certificate: it owns the account (in the case of the bank account)`minted` / `exercised`)It's the one that's going to read it, and it's just one more place that might not be there.
/// Transfer, authorization, balance queries ERC-1155 The thing is not about the pool - the license.**Transfer of complete freedom**Yes. Seaport  Tie the premise.
///
/// CRITICAL Only two functions are left on the interface. Same. `IAttestationRegistry`:The bigger the face, the bigger the space for "a controlled switch."
interface ICall {
    /// @notice Cast `amount` Grandpa. `id` The right to the series. `to`.Only the pool can be tuned.
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice From `from` Destruction `amount` Grandpa. `id` Series of rights cards. Only pool can be moved.
    function burn(address from, uint256 id, uint256 amount) external;
}
