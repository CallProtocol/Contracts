// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PoolBound
/// @notice Satellite contracts (Satellite contracts)`Call` / `MerkleDistributor`)Point `ClearingPool` It's...**One-time**Tie slot:
///         Only those who deploy can write, only once, and then lock permanently.
///
/// # Why is this tank on satellite, not on pool?
///
/// This is a tri-constructed ring after the interface freeze -- `Call -> pool`,`MerkleDistributor -> pool`,
/// `pool -> {call, distributor, attestations}`,And...**It's not gonna work out by sorting.**:CREATE2 Address by init code
/// The blogger says:init code It also contains construction parameters, so when the tectonic parameters of the pool depend on the pool ' s own address, its address cannot be predicted.
///
/// The solution is to put the "talentable" slot.**Satellite**Up: trust is concentrated in the pool, so the three addresses of the pool remain real. `immutable`,
/// There is no written path after deployment.**Where trust is concentrated, the immutable nature remains.**
/// The price is... `pool` From immutable It's a once. storage Read (100 times more call) gas) -  -  The whole thing was replaced. CREATE2 The link.
///
/// The option that has been rejected is Uniswap V3 The set (pool construction functions left empty, read back) `IDeployer(msg.sender).parameters()`):
/// Same results, more active components, still dependent CREATE2.
///
/// # Unbounded contracts are inert, not open.
///
/// Before binding `pool == address(0)`,And... `onlyPool` In this state,**Remark** -  - Not a fucking thing.
/// `msg.sender` The assumption of a chain is that it's not equal to a zero address.
/// Sentry duty. Another one that can be seen. `msg.sender` location take-up values; comparing only `msg.sender != pool` I'm not sure if I'm going to be able to do this.
/// Both identities will be collided in the same value during the unbound period. `onlyPool` * The present document was not edited before being sent to the United Nations translation services.
/// `test/PoolBound.t.sol::test_unbound_zeroSenderIsRejectedToo`.
///
/// So the window between deployment and binding, there is no caller who can cast or destroy the certificate of authority. This is a test-driven nature that does not depend on reasoning.
///
/// @dev See `docs/spec.md` / 12 and issue #8.
abstract contract PoolBound {
    /// @notice It's bound. `ClearingPool`.`address(0)` Organisation**Not bound yet**.
    /// @dev CRITICAL This contract.**No, I'm not.**Any other write path... `setPool` It's the only one, and it's the only one. `pool == address(0)` Prefix.
    address public pool;

    /// @notice The only address that has the right to be bound: the one that deployed the contract.
    /// @dev `docs/spec.md` It's in the sketches. `private`.It's done here. `public`,Because... 12 Request on-site verification of deployment.
    ///      Two bindings -- people who check should not only be traded by flipping the fabric. calldata The blogger says that the law is not a law for the people who are supposed to be bound.
    address public immutable deployer;

    /// @notice The binding is complete.
    event Bound(address indexed pool);

    error NotDeployer(address caller);
    error AlreadyBound(address pool);
    error ZeroPool();
    error PoolHasNoCode(address pool);
    error NotPool(address caller);

    /// @dev Unbound**Remark**,"and not by the way."`msg.sender` It can't be equal to `address(0)`.
    ///
    ///      CRITICAL `address(0)` I'm here to do two jobs: it's a "not tied up" sentry and it's a possible presence.
    ///      `msg.sender` value of location. Write only `msg.sender != pool` If you do, these two identities will be tied up.
    ///      **Collapse into the same value**  -  -  The caller of the zero address happened to be a judge of authority, and the caller was a lawyer.`mint(Non-zero recipients, ...)` It'll actually create a license.
    ///      (ERC-1155 Zero only.**Recipients**,It's not gonna stop.**Caller**).Other Organiser
    ///      `test/PoolBound.t.sol::test_unbound_zeroSenderIsRejectedToo` Nail.
    ///
    ///      This zero-point address is very difficult to construct on today's Ether House (without that private key, the contract cannot be deployed at zero).
    ///      But that's one thing about...**Chain**And the hypothesis, not about**This contract.**the nature of the target chain is Arbitrum Orbit L2,
    ///      The semantics of system transactions are defined by the chain and we cannot change them; the door remains intact once the satellite contract is bound.
    ///      It's cheaper to write "no without binding" into a structure than to send it to an external hypothesis -- the cost is a comparison.
    modifier onlyPool() {
        address boundPool = pool;
        if (boundPool == address(0) || msg.sender != boundPool) revert NotPool(msg.sender);
        _;
    }

    constructor() {
        deployer = msg.sender;
    }

    /// @notice Tie the clearing pool.**Only those who deploy, only once, and then forever lock to death.**
    ///
    /// @dev Four checks are one thing, and the sequence is deliberate:
    ///      (1) Non-deployers - running. Anyone can see the satellite contract is deployed but not tied, tied to their own contract.
    ///         The idea is that the government will not be able to make a decision.
    ///      (2) bound - Re-locking. This is all the reason for this function.`AlreadyBound` The current value is reported together with the current value.
    ///         The blogger says that the government is not going to let the government take the initiative to make sure that the people are not kidnapped.
    ///      (3) Zero address -- it's a sentry in the "unbound" state. Write it in means nothing, but it's gonna let
    ///         `pool != address(0)`  The verdict was false and was rejected in a blatant manner.
    ///      4 No byte code - Wrong address (EOA,The binding must take place at the pool.**After**,
    ///         So this is never gonna hit in the real process; it means the wrong address, and this is only one chance.
    ///
    ///      The rejected call is not marked, but it can be changed again -- it's locked to death.**Success**That time.
    function setPool(address p) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        if (pool != address(0)) revert AlreadyBound(pool);
        if (p == address(0)) revert ZeroPool();
        if (p.code.length == 0) revert PoolHasNoCode(p);

        pool = p;
        emit Bound(p);
    }
}
