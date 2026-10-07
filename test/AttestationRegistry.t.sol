// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {IAttestationRegistry} from "../src/interfaces/IAttestationRegistry.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice `AttestationRegistry` External behavior.
///
/// All tests passed only external Function Driven, Unspecified internal,No hooks in the production code for detectability.
/// The claim is written here.**Status and events**Go on.
///
/// No Variable 6 3 paragraphs (single-twice) / I can write only in person. / `versions[0]`  I'm always gonna say
/// `test/invariant/Invariant6AttestationGate.t.sol` Lee. fuzz Sequence Drive; Here's the text:
/// Those three.**Name border situation**,The project is based on the following:
contract AttestationRegistryTest is Test {
    AttestationRegistry internal registry;

    address internal publisher = makeAddr("publisher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");
    bytes32 internal constant TERMS_1 = keccak256("TERMS v1");
    bytes32 internal constant ATTESTATION_1 = keccak256("ATTESTATION v1");

    function setUp() public {
        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
    }

    //  Construct and Version Table

    function test_constructor_rejectsZeroPublisher() public {
        vm.expectRevert(AttestationRegistry.ZeroPublisher.selector);
        new AttestationRegistry(address(0), TERMS_0, ATTESTATION_0);
    }

    /// @dev CRITICAL version 0 Quick-Turn-Turn-In-Step-In-Step publisher "Send"--
    ///      There's a part of the latter. `versions` It was empty, then. `attest()` To everyone. revert,
    ///      No Variable 6(3) . See the tectonic function comment.
    function test_constructor_writesVersion0_soTheGateIsOpenFromBlockOne() public {
        AttestationRegistry fresh = new AttestationRegistry(publisher, TERMS_1, ATTESTATION_1);

        assertEq(fresh.versionCount(), 1, unicode"There should be a copy of the text after the construction.");
        (bytes32 terms, bytes32 attestation) = fresh.versions(0);
        assertEq(terms, TERMS_1);
        assertEq(attestation, ATTESTATION_1);

        // publisher Open the door without concern to the deployer - no construction function onlyPublisher
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        fresh.attest(0, TERMS_1, ATTESTATION_1);
        assertEq(fresh.attestedVersion(stranger), 1);
    }

    function test_constructor_rejectsEmptyTextHash() public {
        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        new AttestationRegistry(publisher, bytes32(0), ATTESTATION_0);

        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        new AttestationRegistry(publisher, TERMS_0, bytes32(0));
    }

    function test_addVersion_appendsWithoutTouchingEarlierEntries() public {
        vm.prank(publisher);
        uint256 version = registry.addVersion(TERMS_1, ATTESTATION_1);

        assertEq(version, 1, unicode"Subscript for new version");
        assertEq(registry.versionCount(), 2, unicode"Versions");

        (bytes32 terms0, bytes32 attestation0) = registry.versions(0);
        assertEq(terms0, TERMS_0, unicode"No change in the additions versions[0].termsHash");
        assertEq(attestation0, ATTESTATION_0, unicode"No change in the additions versions[0].attestationHash");

        (bytes32 terms1, bytes32 attestation1) = registry.versions(1);
        assertEq(terms1, TERMS_1, "versions[1].termsHash");
        assertEq(attestation1, ATTESTATION_1, "versions[1].attestationHash");
    }

    function test_addVersion_onlyPublisher() public {
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.NotPublisher.selector, alice));
        vm.prank(alice);
        registry.addVersion(TERMS_1, ATTESTATION_1);

        assertEq(registry.versionCount(), 1, unicode"No trace of the rejected addition.");
    }

    /// @dev The whole Zero Hashi is not a text -- it gets a version of the statement "Everyone can satisfy with a full zero parameter": the door is open and the door is open.
    ///      The evidence is empty. This is the most likely way to deploy scripts when they are not filled out.
    function test_addVersion_rejectsEmptyTextHash() public {
        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        vm.prank(publisher);
        registry.addVersion(bytes32(0), ATTESTATION_1);

        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        vm.prank(publisher);
        registry.addVersion(TERMS_1, bytes32(0));
    }

    //  attest

    function test_attest_recordsVersionPlusOneAndEmits() public {
        assertEq(registry.attestedVersion(alice), 0, unicode"Before declaration");

        vm.expectEmit(true, false, false, true, address(registry));
        emit AttestationRegistry.Attested(alice, 0, TERMS_0, ATTESTATION_0, block.timestamp);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertEq(registry.attestedVersion(alice), 1, unicode"What's left of it? version + 1");
    }

    /// @dev Hash is entered and verified as a parameter to get text into calldata(The wallet is visible.
    ///      The user can't be told another version by the front end.
    function test_attest_rejectsMismatchedText() public {
        bytes32 wrong = keccak256("some other text");

        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, wrong, ATTESTATION_0));
        vm.prank(alice);
        registry.attest(0, wrong, ATTESTATION_0);

        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, TERMS_0, wrong));
        vm.prank(alice);
        registry.attest(0, TERMS_0, wrong);

        // Two paragraphs to replace -- the argument sequence is the most likely type of "Hashi yes, but not the number"
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, ATTESTATION_0, TERMS_0));
        vm.prank(alice);
        registry.attest(0, ATTESTATION_0, TERMS_0);

        assertEq(registry.attestedVersion(alice), 0, unicode"No sign of a failed statement.");
    }

    function test_attest_rejectsUnknownVersion() public {
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.UnknownVersion.selector, 1, 1));
        vm.prank(alice);
        registry.attest(1, TERMS_0, ATTESTATION_0);
    }

    /// @dev The "one-way" is not "a strict increase": signing the old version is neither retreating nor failing.
    ///      See `AttestationRegistry.attest` Other Organiser `docs/spec.md` Design sketches
    ///      The only semantic deviation is to make no variables 6(3) No preconditions.
    function test_attest_isMonotonicNonDecreasing_notStrictlyIncreasing() public {
        vm.prank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);

        vm.prank(alice);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        assertEq(registry.attestedVersion(alice), 2, unicode"I signed it. version 1");

        // I'll sign it again. version 0:No, no. revert,And don't push it back, but...**As usual. emit**  -  -
        // `Attested` It's a sign of behavior, not a snapshot of the account status. Take it under the chain. max,Can't take the last one.
        vm.expectEmit(true, false, false, true, address(registry));
        emit AttestationRegistry.Attested(alice, 0, TERMS_0, ATTESTATION_0, block.timestamp);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(
            registry.attestedVersion(alice), 2, unicode"Signing old versions is not allowed to reverse the status quo"
        );

        // I'm not signing the same version again. revert
        vm.prank(alice);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        assertEq(registry.attestedVersion(alice), 2, unicode"Repeated signatures are for the rest of the day.");
    }

    /// @dev Acceptance and acceptance clauses:**Any address at any time**Tranquility `attest(0, ...)` All successful.
    ///      Any moment here covers two dimensions: time advance, and publisher Any new versions have been added.
    function testFuzz_attest0_alwaysSucceeds(address who, uint32 timeJump, uint8 extraVersions) public {
        vm.warp(block.timestamp + timeJump);

        for (uint256 i = 0; i < uint256(extraVersions) % 8; i++) {
            vm.prank(publisher);
            registry.addVersion(keccak256(abi.encode("terms", i)), keccak256(abi.encode("attestation", i)));
        }

        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertGe(registry.attestedVersion(who), 1, unicode"attest(0, ...) Then the threshold must be passed.");
    }

    //  Non-retroactive additions / I can't write my status.

    /// @dev Acceptance and acceptance clauses:publisher The new version is being added to the text.**The status of the old version of the declarant remains unchanged**.
    function test_addingVersion_doesNotInvalidateEarlierAttesters() public {
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        uint256 before = registry.attestedVersion(alice);

        vm.startPrank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);
        registry.addVersion(keccak256("TERMS v2"), keccak256("ATTESTATION v2"));
        vm.stopPrank();

        assertEq(registry.attestedVersion(alice), before, unicode"No additional changes to the existing declaration");
        assertGt(
            registry.attestedVersion(alice),
            0,
            unicode"The old version of the declarant still goes through the threshold."
        );
    }

    /// @dev Acceptance clause: No third party can change `attestedVersion`;publisher Not even.
    ///
    ///      "No, I can't."**Structure**Prove it. `test_writeSurface_isExactlyAddVersionAndAttest`
    ///      (Only two external writing functions) and no variables 6(2).Here are some famous attempts.
    function test_nobodyElseCanWriteAnothersAttestedVersion() public {
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(registry.attestedVersion(alice), 1);

        // publisher Add a new version and sign for yourself - none of it will be touched alice
        vm.startPrank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        vm.stopPrank();
        assertEq(registry.attestedVersion(alice), 1, unicode"publisher I can't change that. alice");

        // Third party signing for itself -- no one's ever touched it. alice
        vm.prank(bob);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(registry.attestedVersion(alice), 1, unicode"Third party can't change. alice");

        // A few of the "regarding the back door, if it does exist" choices.
        // Here it is.**It's a famous witness.**,Not proof. "No other writing" is from the one below. ABI The full signature test is given.
        // `Invariant6AttestationGate.t.sol` It's... `_selector` And another one of the same forms. Feed it. fuzzer Use it;
        // The tables do not need to be consistent and they serve different mechanisms.
        string[6] memory backdoors = [
            "reset(address)",
            "clear(address)",
            "revoke(address)",
            "setAttestedVersion(address,uint256)",
            "attestFor(address,uint256)",
            "removeVersion(uint256)"
        ];
        for (uint256 i = 0; i < backdoors.length; i++) {
            vm.prank(publisher);
            (bool ok,) = address(registry).call(abi.encodeWithSignature(backdoors[i], alice, uint256(0)));
            assertFalse(ok, string.concat(unicode"Unexpectedly:", backdoors[i]));
        }

        assertEq(registry.attestedVersion(alice), 1, unicode"alice I've never been touched.");
    }

    //  Externally Writeable Function Set (Structural Certificate)

    /// @dev No Variable 6 It's proof of "some switch."**Cannot initialise Evolution's mail component.**.The first time I was able to get a job, I was able to get a job.
    ///      It didn't prove it -- it was added. `clear(address)` It's not gonna go off because no one calls it.
    ///      So here's the translation. ABI,- Put it on.**All**Take the outside entrance count. `receive` / `fallback`).
    ///
    ///      The bomb itself lives. {WriteSurface}:No Variable 5(The government has been using the same mechanism to clear the pool without any manager.
    ///      And this is the only two means of proving that the switch does not exist, and that neither should be achieved by drifting.
    function test_writeSurface_isExactlyAddVersionAndAttest() public view {
        string[] memory expected = new string[](2);
        expected[0] = "addVersion(bytes32,bytes32)";
        expected[1] = "attest(uint256,bytes32,bytes32)";

        WriteSurface.assertIsExactly("out/AttestationRegistry.sol/AttestationRegistry.json", expected);
    }

    //  The one the clearing pool will be reading.

    /// @dev Stuck it. ClearingPool(M1-5,issue #10)The only one that would do:
    ///      `attestations.attestedVersion(beneficiary) != 0`.
    function test_theQueryClearingPoolWillMake() public {
        IAttestationRegistry gate = IAttestationRegistry(address(registry));

        assertEq(gate.attestedVersion(alice), 0, unicode"I've never said it. 0");

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertTrue(gate.attestedVersion(alice) != 0, unicode"I'm not gonna say it. 0");
    }
}
