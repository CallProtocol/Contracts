// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";

/// @notice One for use.**Contractual accounts**Identity signed wallet.
///
/// CRITICAL Only EOA A probe can make an entire class invisible:`require(msg.sender == tx.origin)`,
/// `require(msg.sender.code.length == 0)` The door was like that. EOA The probe is all through.
/// But I'll give you every single more signature and smart wallet.**Permanent**It's not the right to do it. So there's gotta be a real contract in the probe.
contract AttestingWallet {
    AttestationRegistry private immutable registry;

    constructor(AttestationRegistry registry_) {
        registry = registry_;
    }

    /// @dev Low Layer call,Return to Caller if you want to... handler No, I can't. revert.
    function attest(uint256 v, bytes32 termsHash, bytes32 attestationHash) external returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeCall(AttestationRegistry.attest, (v, termsHash, attestationHash)));
    }
}

/// @notice Driver `AttestationRegistry` It's... handler.
///
/// CRITICAL **Nothing in this contract. revert.** The non-variant test runs on `fail_on_revert = false` I'm not sure if you're going to be able to do this.
/// And... handler - Yes. `assertEq` Losing is one. revert  -  -  I'm gonna get it. fuzzer I'm not sure if I'm gonna be able to eat it.
/// So the assertion is written, it's not written. So here it's a violation.**Recording counters**,By `invariant_*` To assert zero.
/// Calles to the registration form are always down `call`,Neither is it possible to make a difference in the record.
///
/// Can the counter itself really catch the violation? `test_theDetectorDetects_*` Those are the definitive tests against it.
contract AttestationHandler is CommonBase, StdUtils {
    AttestationRegistry public immutable registry;

    /// @dev Construct at the time `versions[0]` Two Hashs. No variables. 6(3) The assertion is...**This version.**Always be able to say.
    bytes32 public immutable terms0;
    bytes32 public immutable attestation0;

    /// @dev The account that was tracked.publisher It's inside it too -- it's in the same state of statement to itself as anyone else,
    ///      It can only be written by itself;"publisher The blogger says that the government is not going to change the rules of the law, but that it is not going to change the rules of the law.
    address[] public actors;

    /// @notice Every one. actor The biggest observation in history. `attestedVersion`.
    mapping(address account => uint256 seen) public highWater;

    /// @notice No Variable 6(1):`attestedVersion` There have been declines. It must be constant. 0.
    uint256 public decreaseViolations;
    /// @notice No Variable 6(2):The number of times a non-caller's declaration status is changed in a call. 0.
    uint256 public foreignWriteViolations;
    /// @notice No Variable 6(3):`versions[0]` The number of observations that are not consistent with the construction at that time. It must be constant. 0.
    uint256 public version0MutationViolations;
    /// @notice No Variable 6(3):Probe. `attest(0, ...)` The number of times that the threshold has not been passed since then. It must be constant. 0.
    /// @dev Three types of probes are written once: brand new. EOA,Veterans (updated version signed) and contract wallet. `_probeGate`.
    uint256 public gateClosedViolations;

    /// @dev The coverage measure.fuzz Parameters**It's legal to be deliberately biased.**(See `attest`),So these numbers are in each round.
    ///       Will be much bigger  0;`test_handlerReachesTheSuccessPaths` I'm not sure what I'm talking about.
    uint256 public successfulAttests;
    uint256 public versionsAdded;

    /// @dev Contract account probe. See you. `AttestingWallet` .
    AttestingWallet public immutable wallet;

    /// @dev Veterans probe:**The last version of the paper, which was already declared, and as far as possible, is an updated version.**That address.
    ///      It's looking at the nature of the "big instead of the strict incremental" purchase -- it's signed after the new version. version 0
    ///      Still working. The new address probe will never reach that path.
    address internal constant VETERAN = address(uint160(uint256(keccak256("index-rein: veteran gate probe"))));

    uint256 private probes;

    constructor(AttestationRegistry registry_, address[] memory actors_) {
        registry = registry_;
        actors = actors_;
        (bytes32 t, bytes32 a) = registry_.versions(0);
        terms0 = t;
        attestation0 = a;
        wallet = new AttestingWallet(registry_);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    //  Actions

    /// @dev Version and Hashedu**Legacy bias**(Each 7/8).If you take it even, you can't even make a successful statement in a round.
    ///      High enough to make the round empty: three claims are "some measure of the time." 0,They are also established by nothing.
    ///      Illegal slots are still split. 1/8,The cross-border version is not missing from the three wrong Hashi coverage.
    function attest(
        uint256 actorSeed,
        uint256 versionSeed,
        uint256 hashSeed,
        bytes32 junkTerms,
        bytes32 junkAttestation
    ) external {
        uint256 known = registry.versionCount();
        uint256 v = versionSeed % 8 == 0 ? known + (versionSeed % 3) : bound(versionSeed, 0, known - 1);

        bytes32 termsHash;
        bytes32 attestationHash;
        if (v < known) (termsHash, attestationHash) = registry.versions(v);

        if (hashSeed % 8 == 0) {
            uint256 which = (hashSeed / 8) % 3;
            if (which == 0) termsHash = junkTerms;
            else if (which == 1) attestationHash = junkAttestation;
            else (termsHash, attestationHash) = (junkTerms, junkAttestation);
        }

        bool ok = _act(_actor(actorSeed), abi.encodeCall(AttestationRegistry.attest, (v, termsHash, attestationHash)));
        if (ok) successfulAttests++;
    }

    /// @dev The same bias is legal: 3/4 By publisher(`actors[0]`)Initiated, for the reasons stated above.
    function addVersion(uint256 senderSeed, bytes32 termsHash, bytes32 attestationHash) external {
        address sender = senderSeed % 4 == 0 ? _actor(senderSeed) : actors[0];
        bool ok = _act(sender, abi.encodeCall(AttestationRegistry.addVersion, (termsHash, attestationHash)));
        if (ok) versionsAdded++;
    }

    /// @dev Get the Chooser Add `(Account, Value)` Parameters to crash into the registration form: half is pure random 4 bytes,
    ///      Half comes from the table below, "What's the name of the back door usually?"**He was followed. actor**,
    ///      So there is. `clear(address)` And if they hit the entrance, they'll be like, 6(2) The violation,
    ///      Not on an address that nobody looks at.
    ///
    ///      WARNING **It's not proof of "no back door," it's just a net.**:The half of the randomly available. 2^32 The choice of the space.
    ///      It's almost impossible to hit anything. The hit rate is on that list.
    ///      `test/AttestationRegistry.t.sol` It's... `test_writeSurface_isExactlyAddVersionAndAttest`
    ///       -  -  It's directly a compilation. ABI,Press**Full Signature**The assertion is exactly the two.
    function pokeUnknown(uint256 senderSeed, uint32 selectorSeed, uint256 targetSeed, uint256 value) external {
        bytes memory data = abi.encodePacked(_selector(selectorSeed), abi.encode(_actor(targetSeed), value));
        _act(_actor(senderSeed), data);
    }

    /// @dev Any**Time**This dimension. The door shouldn't close with time.
    ///
    ///      CRITICAL The top line is here. 500 Days, not dozens of days: "One after a year of deployment, `attest` Start revertThe time bomb.
    ///      Yes. ABI It's not clear that only when you really push the time past that line will it be exposed. 64 Step, step, step, step, step, step. 250 God,
    ///      The timescale across the "one year" is enough to exceed the most likely time frame to be written.
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 500 days));
        _observeVersion0();
        _probeGate();
    }

    //  Records

    function _act(address actor, bytes memory data) private returns (bool ok) {
        uint256 n = actors.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            before[i] = registry.attestedVersion(actors[i]);
        }

        // prank It only works on the immediate next.**Next time.**External calls, so the snapshot must be taken before it is finished.
        vm.prank(actor);
        (ok,) = address(registry).call(data);

        for (uint256 i = 0; i < n; i++) {
            address who = actors[i];
            uint256 current = registry.attestedVersion(who);

            if (current < before[i]) decreaseViolations++;
            if (who != actor && current != before[i]) foreignWriteViolations++;
            if (current > highWater[who]) highWater[who] = current;
        }

        _observeVersion0();
        _probeGate();
    }

    function _observeVersion0() private {
        (bytes32 t, bytes32 a) = registry.versions(0);
        if (t != terms0 || a != attestation0) version0MutationViolations++;
    }

    /// @dev No Variable 6(3)  The world is so full of shit **Any address at this moment.**Can you do it? `attest(0, ...)` Pass the threshold.
    ///
    ///      "Whatever" has to be covered by three categories, and one of the few is the whole kind of locking-in that is invisible:
    ///
    ///      | Probe. | It's the only way it's covered. |
    ///      |---|---|
    ///      | New EOA | General Path |
    ///      | Veterans (updated version signed) | Strictly Incremental `require`  -  -  Only "go back and sign the old version" |
    ///      | Contract wallet. | `msg.sender == tx.origin` / `code.length == 0`  -  -  Just a few more signatures and smart wallets. |
    ///
    ///      All three.**Construct at the time**I remember Hash, not now. `versions[0]`  -  -
    ///      Otherwise, "Modern version" 0 The new text can be signed, but it will be accepted.
    function _probeGate() private {
        // (1) New Address
        _probeOne(address(uint160(uint256(keccak256(abi.encode("index-rein: gate probe", probes))))));
        probes++;

        // (2) Veterans: First try to get it to the latest version and then get it back on the plate. version 0
        uint256 known = registry.versionCount();
        if (known > 1) {
            (bytes32 t, bytes32 a) = registry.versions(known - 1);
            vm.prank(VETERAN);
            address(registry).call(abi.encodeCall(AttestationRegistry.attest, (known - 1, t, a)));
        }
        _probeOne(VETERAN);

        // (3) The contract account -- it's itself initiating a call,msg.sender It's a contract.tx.origin No, it's not.
        if (!wallet.attest(0, terms0, attestation0) || registry.attestedVersion(address(wallet)) == 0) {
            gateClosedViolations++;
        }
    }

    function _probeOne(address probe) private {
        vm.prank(probe);
        (bool ok,) = address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, terms0, attestation0)));
        if (!ok || registry.attestedVersion(probe) == 0) gateClosedViolations++;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Half is purely random, half comes from this table. The form is "the name if the back door exists" --
    ///      Take it all. `(address, uint256)`,Right on. `pokeUnknown` It's a spell. calldata.
    function _selector(uint32 seed) private pure returns (bytes4) {
        if (seed % 2 == 0) return bytes4(seed);

        string[8] memory names = [
            "reset(address)",
            "clear(address)",
            "revoke(address)",
            "revokeAttestation(address)",
            "setAttestedVersion(address,uint256)",
            "attestFor(address,uint256)",
            "adminSetAttested(address,uint256)",
            "removeVersion(uint256)"
        ];
        return bytes4(keccak256(bytes(names[(seed / 2) % 8])));
    }
}

/// @notice **Only for Counter-Evidence handler The probes really will ring.** It's a non-variant. 6 Two things to ban have been made functional:
///         Quit the other person's declaration and rewriting it. `versions[0]`.Neither of them exists in the production contract.
///          -  -  That's why `test_writeSurface_isExactlyAddVersionAndAttest` Enumeration ABI Prove it.
contract BackdoorRegistry is AttestationRegistry {
    constructor(address publisher_, bytes32 termsHash, bytes32 attestationHash)
        AttestationRegistry(publisher_, termsHash, attestationHash)
    {}

    function clear(address account) external {
        attestedVersion[account] = 0;
    }

    function tamper(bytes32 termsHash, bytes32 attestationHash) external {
        versions[0] = TextVersion(termsHash, attestationHash);
    }
}

/// @notice **No Variable 6  -  -  The declaration door cannot be locked.**
///
/// | Paragraph | The assertion. |
/// |---|---|
/// | (1) | `attestedVersion[a]` For Any `a` Undumized |
/// | (2) | Only `a` You can change yourself. |
/// | (3) | `versions[0]` It exists and it's not changed.  **Any address can be used `attest(0,...)` Meet the threshold** |
///
/// No Variable 5 and 6 The only two "prove a switch" on this project.**Cannot initialise Evolution's mail component.**the means of the`docs/spec.md`).
/// They are blocked by the ability of someone to freeze the assets of all users by leaving a manager with a controlled front check on the right-to-hand path.
contract Invariant6AttestationGateTest is Test {
    AttestationRegistry internal registry;
    AttestationHandler internal handler;

    address internal publisher = makeAddr("publisher");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    function setUp() public {
        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        handler = new AttestationHandler(registry, _actors());
        targetContract(address(handler));
    }

    function _actors() private returns (address[] memory actors) {
        actors = new address[](5);
        actors[0] = publisher; // CRITICAL It must be in the row:publisher "and can't change the rules with third parties."
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
        actors[4] = address(this);
    }

    //  No Variable 6 Section 3

    /// @notice 6(1) `attestedVersion` Undumized.
    function invariant_6a_attestedVersionNeverDecreases() public view {
        assertEq(handler.decreaseViolations(), 0, unicode"No Variable 6(1):attestedVersion There's been a drop.");

        // The following paragraph is not a repetition:handler The counter only looks at**Before and after a single move**,
        // And here's the thing. fuzz Maximum number of historical actions in the sequence that cross any number of actions --
        // The next step is to get back up and down, and only this one can get it.
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address who = handler.actors(i);
            assertGe(
                registry.attestedVersion(who),
                handler.highWater(who),
                unicode"No Variable 6(1):Current value below the maximum of historical observations"
            );
        }
    }

    /// @notice 6(2) Only the account itself can change its declaration status - publisher Not with a third party.
    function invariant_6b_onlyTheAccountItselfCanWrite() public view {
        assertEq(
            handler.foreignWriteViolations(), 0, unicode"No Variable 6(2):Someone changed someone. attestedVersion"
        );
    }

    /// @notice 6(3) `versions[0]` It exists and it's not changed.  Any address can be used `attest(0,...)` Meet the threshold.
    function invariant_6c_version0IsImmutableAndAlwaysAttestable() public view {
        assertEq(handler.version0MutationViolations(), 0, unicode"No Variable 6(3):versions[0] It's been changed.");
        assertEq(
            handler.gateClosedViolations(),
            0,
            unicode"No Variable 6(3):Some kind of probe (new) EOA / Private. /  The contract wallet attest(0, ...) The threshold was not passed since then."
        );

        (bytes32 terms, bytes32 attestation) = registry.versions(0);
        assertEq(terms, TERMS_0, unicode"versions[0].termsHash");
        assertEq(attestation, ATTESTATION_0, unicode"versions[0].attestationHash");
    }

    //  Countered: Three of the above are not empty.

    /// @dev All three of the non-variables are "some of the count is 0,And one.**Nothing.**It's... handler Same satisfaction.
    ///      This is a sure proof that two successful paths do work -- fuzz The parameters are legal, so each round is hit in a large number.
    function test_handlerReachesTheSuccessPaths() public {
        // versionSeed=1  (a) A legitimate version;hashSeed=1  With real Hashi.
        handler.attest(1, 1, 1, bytes32(0), bytes32(0));
        assertEq(handler.successfulAttests(), 1, unicode"handler It's... attest I can't get to the path of success.");

        // senderSeed=1  Not 0 Moe. 4  publisher
        handler.addVersion(1, keccak256("terms"), keccak256("attestation"));
        assertEq(handler.versionsAdded(), 1, unicode"handler It's... addVersion I can't get to the path of success.");
        assertEq(registry.versionCount(), 2);
    }

    /// @dev - The probe back. (1)(2):The following is a list of the names of the people who are in the country, and the names of the people who are in the country, who are in the country, who are in the country, who are not in the country.
    ///      handler It has to be written in the act. 6(1) and 6(2) The violation.
    function test_theDetectorDetects_foreignWriteAndDecrease() public {
        (BackdoorRegistry bad, AttestationHandler h) = _handlerOverBackdoor();
        address alice = h.actors(1);

        vm.prank(alice);
        bad.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(bad.attestedVersion(alice), 1, unicode"Preconditions:alice Declared");

        // senderSeed=2  bob Launch;targetSeed=1  It's called alice;
        // selectorSeed=3  Take the name watch and get it. names[1] == "clear(address)"(3%2=1,3/2%8=1)
        h.pokeUnknown(2, 3, 1, 0);

        assertEq(bad.attestedVersion(alice), 0, unicode"Precondition: The back door is clear. alice");
        assertGt(h.foreignWriteViolations(), 0, unicode"6(2) The probe didn't ring.");
        assertGt(h.decreaseViolations(), 0, unicode"6(1) The probe didn't ring.");
    }

    /// @dev - The probe back. (3):Rewrite `versions[0]` After that, "Model 0 "As always, I can't change" and "a strange address."
    ///      Both counts must ring -- the latter proves that the probe was used by a man who had a gun.**Original**Hash, not now read.
    function test_theDetectorDetects_version0Tampering() public {
        (BackdoorRegistry bad, AttestationHandler h) = _handlerOverBackdoor();

        bad.tamper(keccak256("replaced terms"), keccak256("replaced attestation"));
        h.warp(1); // Any move will be re-observated.

        assertGt(h.version0MutationViolations(), 0, unicode"versions[0] \"The detector didn't ring.\"");
        assertGt(h.gateClosedViolations(), 0, unicode"\"The detector is not ringing.\"");
    }

    function _handlerOverBackdoor() private returns (BackdoorRegistry bad, AttestationHandler h) {
        bad = new BackdoorRegistry(publisher, TERMS_0, ATTESTATION_0);
        h = new AttestationHandler(AttestationRegistry(address(bad)), _actors());
    }
}
