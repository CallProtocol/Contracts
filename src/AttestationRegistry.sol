// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";

/// @title AttestationRegistry
/// @notice User before rights**One-time**The signed declaration of compliance is certified.CRITICAL Not an upgrade, one in each chain.
///
/// # The reason for this contract is to prove that a switch is a switch.**Cannot initialise Evolution's mail component.**
///
/// Any pre-authority check that is controlled by the administrator is a throttle that can freeze all user assets -
/// Compliance admin Once the private key is lost or taken, the full weight is permanently altered, and what we promise to do is
/// Clearinghouses are non-upgradable, no admin "The extraction path." And a controlled door, the promise is to be invalidated.
///
/// So all the design constraints of this contract point to the same thing:**This door cannot be structurally locked to death.**
///
/// | Constraints | Achieved |
/// |---|---|
/// | `attestedVersion` Only no loss | There is no function to reduce or eliminate,**publisher Not even.** |
/// | Only the account itself can change its own status. | `attest()` Write Only `msg.sender` |
/// | `versions[0]` Permanent and immutable. | Add, no debugs |
/// | publisher Permissions only append | Add new version**No impact**Any existing declaration |
///
/// These three together are...**No Variable 6**(`docs/spec.md`):`versions[0]` It exists and it's not changed.
///  Any address can be changed at any time. `attest(0, ...)` Meets the threshold. It's with no variables 5(No Manager exit)
/// The only two means of "prove that a switch does not exist" are the project, which cannot be omitted.
///
/// # Why does Hashi have to be in here as a parameter?
///
/// `termsHash` / `attestationHash` Already on the chain, still requesting to log in and verify the same call --
/// The purpose is...**Let the text Hashi appear in the transaction. calldata Lee.**:The wallet signature interface shows the original. calldata,
/// The user signed "I have seen this text" instead of an air conditioner; and the front end.**Cannot**The user is being quietly told another version.
///
/// The evidence is in itself in the transaction. `Attested` In an event, permanently searchable, no additional storage is required.
///
/// @dev See you at the full design. `docs/spec.md`;version 0 For the two paragraphs of the report, see `legal/attestation-v0/`.
contract AttestationRegistry is IAttestationRegistry {
    /// @param termsHash        TERMS Text (on the tool itself) keccak256
    /// @param attestationHash  ATTESTATION Text (for the user) keccak256
    struct TextVersion {
        bytes32 termsHash;
        bytes32 attestationHash;
    }

    /// @notice Only additional text version tables are available.`versions[0]` Written by a construction function, therefore length is constant >= 1.
    /// @dev CRITICAL Full contract.**No, I'm not.**Any writing `versions[i]` Or shorter. `versions` Path to  Other Organiser
    ///      It's not a variable. 6(3) The structural basis of this is not agreement.
    TextVersion[] public versions;

    /// @inheritdoc IAttestationRegistry
    /// @dev CRITICAL The only writing point is `attest()`,And it only writes. `msg.sender`,I'm just doing "big."
    mapping(address account => uint256 versionPlusOne) public attestedVersion;

    /// @notice The only right.**Append**The address of the new version of the text. It cannot change, delete, or touch anyone's state of declaration.
    address public immutable publisher;

    /// @notice A new version has been added.
    event VersionAdded(uint256 indexed version, bytes32 termsHash, bytes32 attestationHash);

    /// @notice A certain version of the text was signed at an address.
    /// @dev CRITICAL This event is**Signature**. Repeat or sign a higher version
    ///      Sign the old version again, and it'll be normal. emit.Under the chain, return the "current version of the account's statement" and read it.
    ///      `attestedVersion`,Or take it in case of events **max** Not take it.**Last one.**.
    event Attested(address indexed who, uint256 version, bytes32 termsHash, bytes32 attestationHash, uint256 at);

    error ZeroPublisher();
    error NotPublisher(address caller);
    error EmptyTextHash();
    error UnknownVersion(uint256 version, uint256 known);
    error TextMismatch(uint256 version, bytes32 termsHash, bytes32 attestationHash);

    /// @param publisher_       Add address for subsequent version
    /// @param termsHash        version 0 It's... TERMS Hash.
    /// @param attestationHash  version 0 It's... ATTESTATION Hash.
    ///
    /// @dev CRITICAL **version 0 Write in the construction function, not for subsequent transactions.**
    ///
    ///      `docs/spec.md` Design sketches and issue #8 It was originally called "Play first, then by" publisher Tranquility
    ///      `addVersion` Append version 0.There are two real consequences:
    ///
    ///      (1) There's a relationship between the two deals. `versions` The empty window -- that's what this door looks like, welded to death,
    ///         `attest()` To everyone. revert.No Variable 6(3) Preconditions for the`versions[0]` Existence)
    ///         So it became the "Scripts to the Second Step."**Process**(a) Assurances, not structural guarantees;
    ///      (2) publisher Must be the person who deployed it, otherwise `addVersion` I'm gonna get it. `onlyPublisher` Reject...
    ///         publisher To sign more, you have to make up for it manually, and the window increases the response time.
    ///
    ///      After putting the construction function,`versions.length >= 1` The first block of the contract is a permanent one.
    ///      publisher And back to where it belongs:**Only for the subsequent version**.
    constructor(address publisher_, bytes32 termsHash, bytes32 attestationHash) {
        if (publisher_ == address(0)) revert ZeroPublisher();
        publisher = publisher_;
        _append(termsHash, attestationHash);
    }

    /// @notice Added to the text version.
    /// @dev `versions` Auto getter Only the individual item is taken by the mark, which cannot be taken for long; it is used both in the deployed script and at the front end.
    function versionCount() external view returns (uint256) {
        return versions.length;
    }

    /// @notice Add a new version. publisher I'm not sure if I can get a hold of it.**Only add**.
    /// @return version The new version of the subscript.
    /// @dev Append**No way.**Invalid any existing declaration: This function does not touch `attestedVersion`,And don't touch what's already there.
    ///      `versions[i]`."The chain always asks only for>=1 The latest version is the front line.
    function addVersion(bytes32 termsHash, bytes32 attestationHash) external returns (uint256 version) {
        if (msg.sender != publisher) revert NotPublisher(msg.sender);
        return _append(termsHash, attestationHash);
    }

    /// @dev Version Table**One**. Construct the function to `addVersion` Take it all, so "only add."
    ///      This is just a matter of being set up here.
    function _append(bytes32 termsHash, bytes32 attestationHash) private returns (uint256 version) {
        // Zero Hashi is not a text. It is a version of the statement "Everyone can satisfy with a zero parameter" that is available to everyone.
        // The door is open, but the evidence is empty -- it's the most likely way to get out of the way when you're deployed.
        if (termsHash == bytes32(0) || attestationHash == bytes32(0)) revert EmptyTextHash();

        version = versions.length;
        versions.push(TextVersion(termsHash, attestationHash));
        emit VersionAdded(version, termsHash, attestationHash);
    }

    /// @notice Signature of the `v` . Write only the caller ' s own status.
    /// @param v                Version Subscript
    /// @param termsHash        I must. `versions[v].termsHash` Equal
    /// @param attestationHash  I must. `versions[v].attestationHash` Equal
    ///
    /// @dev CRITICAL **For the law. `(v, Two Hashs.)` Triple, this function never revert.** It's not a variable. 6(3)  The world is so full of shit
    ///      `versions[0]` Write by Constructive Functions, Non-Variable After  Any address at any time `attest(0, ...)` All successful.
    ///      `UnknownVersion` So yes. `v == 0` Unattainable - Version Table Length >= 1.
    ///
    ///      So here's the thing.**Large**Not `require(v + 1 > attestedVersion[msg.sender])`
    ///       -  - The latter is found in `docs/spec.md` The design sketch, but it'll make "was signed." 0 Sign the address again. 0
    ///      revert,So, no variables. 6(3) "and can only be reduced to "**Not yet stated**Address constant attest(0).
    ///      No Variable 6 The whole point is that "the door structure is not locked to death" and it should not be premised on preconditions.
    ///      And the same thing is enough to satisfy "one-way" (which is the non-variant). 6(1) and to be more rigorous:
    ///      Signing the old version would not be a retreat or a failure, but would leave a sign running.
    function attest(uint256 v, bytes32 termsHash, bytes32 attestationHash) external {
        uint256 known = versions.length;
        if (v >= known) revert UnknownVersion(v, known);

        TextVersion memory t = versions[v];
        if (termsHash != t.termsHash || attestationHash != t.attestationHash) {
            revert TextMismatch(v, termsHash, attestationHash);
        }

        uint256 next = v + 1;
        if (next > attestedVersion[msg.sender]) attestedVersion[msg.sender] = next;

        emit Attested(msg.sender, v, termsHash, attestationHash, block.timestamp);
    }
}
