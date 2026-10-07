// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {DeployAttestationRegistry} from "../script/DeployAttestationRegistry.s.sol";
import {VersionZero} from "../script/VersionZero.sol";

/// @dev `requireDeployable` Yes. `internal view`,try/catch Not yet. You can read it on one level. revert Reason  -
///      The main web pre-screening did block it. revert I'm not going anywhere.
contract VersionZeroHarness {
    function requireDeployable(VersionZero.Texts memory texts, bytes32 reviewedTerms, bytes32 reviewedAttestation)
        external
        view
    {
        VersionZero.requireDeployable(texts, reviewedTerms, reviewedAttestation);
    }

    function canonicalize(bytes memory raw, string memory path) external pure returns (string memory) {
        return VersionZero.canonicalize(raw, path);
    }

    /// @dev The reload that reads the environment variable. Only for `test_pinnedHashesComeFromTheEnvironment` Use...
    ///      forge Runs the tests in parallel with the same contract, and environmental variables are process-level, and one more is a fight.
    function requireDeployableFromEnv(VersionZero.Texts memory texts) external view {
        VersionZero.requireDeployable(texts);
    }
}

/// @notice version 0 and the text of Hash, and**Visible pre-checks deployed on the main network**.
///
/// There's only one mistake to be covered by this check, but it's irreversible: to write in the pre-legal text.
/// `versions[0]` And it's sent to the main web. The record is permanently in the chain, it can't be deleted, and it's always available at any address.
/// Passing the right-of-hand threshold (no variable) 6(3)) -  -  That means...**It's the only version of the text that all users can guarantee.**.
contract VersionZeroTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant SOME_TESTNET_CHAIN_ID = 11_155_111;

    /// @dev Robinhood Chain Open Test Network  -  **We're really gonna be there.**(issue #65),
    ///      Not like the one up there. Sepolia It's just "a non-mainstream network." {test_robinhoodTestnetTakesTheNonMainnetBranch}.
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;

    /// @dev CRITICAL **Second Main Network**(Decision-making 56).It's a part of the main network.
    ///      {test_bscTakesTheMainnetBranch} Scrubbed alone.
    uint256 internal constant BSC_CHAIN_ID = 56;

    /// @dev Finalising Hash2026-08-26,The authoritative text is in English.issue #18).and `.env.example` Lee.
    ///      `ATTESTATION_V0_*_HASH` value, and `cast keccak -- "$(cat <Documentation>)"` Repetitive value
    ///      The three must be the same -- the chain is the nail here. `versions[0]` The two bytes that will be pointed at.
    bytes32 internal constant FINAL_TERMS_HASH = 0x918ec44c764a8a830c3cf13f8a67b5cca430cd5866d3bfefa7e25390129e29ab;
    bytes32 internal constant FINAL_ATTESTATION_HASH =
        0xe760c38dcca7cc6cb2e151e2c91521f89890ce053d6cbfd1f0319ff88045bd64;

    /// @dev BSC(56)That one. terms * The final version of the article is as follows:2026-09-10 Finalised).
    ///
    ///      CRITICAL **Only terms There are separate values.** `attestation.en.txt` The two chains are the same bytes.
    ///      The user himself, not the issuer of the collateral) BSC Re-use the one on top. {FINAL_ATTESTATION_HASH}  -  -
    ///      That's why {test_bscReadsItsOwnLegalDirectory} The assertion. Here. attestation One more for the same.
    ///      The constant only makes the fact that the two chains are shared suspicious.
    bytes32 internal constant FINAL_TERMS_HASH_BSC = 0xe864e266e4d398abb519939899dc94ca6e80a4a8125de348e6eb0681b71b16b6;

    VersionZeroHarness internal harness;

    function setUp() public {
        harness = new VersionZeroHarness();
    }

    //  Documents and Hash

    /// @dev CRITICAL **It is a trip, not a mere assertion.** version 0 Already 2026-08-26 Finalized: Authorised in English,
    ///      The final version is based on the records of the multilingual arrangements. `legal/attestation-v0/README.md`(issue #18).
    ///      The test nailed the "final" state: it reded the byte that meant that someone moved the final text, and it was a "final" text that was written in the last place.
    ///      Or add a draft tag to it. No more bytes to the files --
    ///      The chain. `versions[0]` The Hashi will be permanently pointed to this version.
    function test_shippedTextIsFinalized() public view {
        VersionZero.Texts memory texts = VersionZero.load();

        assertFalse(VersionZero.isDraft(texts), unicode"version 0 Finalized, no more draft tags");
        assertEq(
            texts.termsHash,
            FINAL_TERMS_HASH,
            unicode"terms.en.txt The bytes do not match the final version - the final text cannot be changed"
        );
        assertEq(
            texts.attestationHash,
            FINAL_ATTESTATION_HASH,
            unicode"attestation.en.txt The bytes do not match the final version - the final text cannot be changed"
        );
    }

    function test_hashes_areRealAndDistinct() public view {
        VersionZero.Texts memory texts = VersionZero.load();

        assertTrue(texts.termsHash != bytes32(0), "termsHash");
        assertTrue(texts.attestationHash != bytes32(0), "attestationHash");
        assertTrue(texts.termsHash != texts.attestationHash, unicode"Two paragraphs should not be the same as Hash.");
        assertEq(texts.termsHash, keccak256(bytes(texts.terms)), unicode"Hash is from the text itself.");
        assertEq(texts.attestationHash, keccak256(bytes(texts.attestation)));
    }

    /// @dev A file is a line of text to get `cast keccak -- "$(cat Documentation)"` Hash on the Byte Recovering Chain...
    ///      The user can recalculate himself" is the full meaning of this Hashi discipline.
    ///      WARNING `$( )` It's the end.**All**Line change, not one. So, "More than one ending." LFRejected**No, it's not.**
    ///      Because the recalculation would not be (never) but rather to match Hashi with the byte of the document.
    function test_textFilesAreExactlyOneLine() public view {
        _assertCanonical(VersionZero.TERMS_PATH);
        _assertCanonical(VersionZero.ATTESTATION_PATH);
    }

    /// @dev CRITICAL Go straight ahead.**The rules used in deployment.**,No other one.
    ///      Earlier, an independent inspection was conducted, so both sets of rules were missed in both directions:
    ///      Naked `"\n"`  Can get through here and be  loader I'm sorry.BOM Yes. loader The government has been unable to provide any information on the situation.
    ///      A set of rules, one at a time, cannot exist.
    function _assertCanonical(string memory path) private view {
        bytes memory raw = bytes(vm.readFile(path));
        string memory body = harness.canonicalize(raw, path);

        assertEq(
            bytes(body).length,
            raw.length - 1,
            string.concat(path, unicode" The text should be less than the document. LF")
        );
    }

    /// @dev There's only one shape for compliance: a single line of text. + **Just one.**End LF.
    ///      The following is the first time that you have written permissions to go through the file system to construct these inputs, and `fs_permissions` It is only read, and it should be kept.
    ///      So feed it directly to the byte.
    function test_canonicalize_acceptsOnlyTheCanonicalShape() public view {
        assertEq(harness.canonicalize(bytes(unicode"Text\n"), "t"), unicode"Text", unicode"Get rid of that one end. LF");

        // WARNING This one's nailed. **Solidity That's half.**:Hash. == File off the ending LF.
        // shell That's half.`cast keccak -- "$(cat Documentation)"` The same value is actually calculated.**There's no way to say it.**  -  -
        // foundry The test won't run out of the outside. The half is... CI "'version 0 The government is responsible for the event.
        assertEq(
            keccak256(bytes(harness.canonicalize(bytes(unicode"Text\n"), "t"))),
            keccak256(bytes(unicode"Text")),
            unicode"The chain must be the same as \"the file's off.\" LFHash."
        );
    }

    /// @dev CRITICAL **The law is not to be amended.**
    ///      It's a merger. `"Text\n"` and `"Text\r\n"` The file was deposited after the same Hash: legal opinion CRLF,
    ///      Hathy nailed it, and he deployed it, but the users took it. README The order came out of the one in the house.**Another value**.
    ///      The audit was not linked to the subject of the deployment, and the work was irreversible.
    ///
    ///      Each one of them is one.**I've measured it.**Split or divide, not defensive imagination.
    function test_canonicalize_rejectsTheseNonCanonicalShapes() public {
        // (1) CRLF  -  -  The beginning of this restoration
        _expectReject(unicode"Text\r\n", unicode"text contains CR; line endings must use LF, not CRLF");
        _expectReject(unicode"Man\rBen.\n", unicode"text contains CR; line endings must use LF, not CRLF");

        // (2) The remaining control character... NUL and CR Same: I can get into the chain, I can't get in. argv.
        //    bash It will be thrown away and warned only for one word.zsh / fish The answer to that is different.
        _expectReject(unicode"ab\x00cd\n", unicode"text contains a control character");
        _expectReject(unicode"ab\x0bcd\n", unicode"text contains a control character");

        // (3) Here. - Start - Real `cast keccak "$(cat Documentation)"` - Put it on. `--json` When the switch ate,
        //    Quietly return keccak(""),Exit Code 0,No warning.
        _expectReject(unicode"--json\n", unicode"text must not begin with '-' because cast would parse it as an option");

        // 4 Here. 0x First  -  cast It's a hexadecimal.**Decoding**And Hashi; and `--` I can't stop it.
        _expectReject(
            unicode"0xdeadbeef\n",
            unicode"text must not begin with 0x because cast would decode it as hexadecimal input"
        );

        // 5 BOM  -  -  Ha-hi is the same on both sides, but the word that counsel saw in the chain might not be the same byte as Hashi.
        _expectReject(
            string(abi.encodePacked(hex"efbbbf", unicode"Text\n")), unicode"text must not begin with a UTF-8 BOM"
        );

        // 6 End LF Number. Note:`$( )` The one that was stripped off was...**All**The end line is changed so "more than one" does not make the double-counting unmatched;
        //    It was rejected to get Hashi to the byte of the file.**- One-on-one.**,Two different documents should not be found in the same Hashi.
        _expectReject(unicode"Text", unicode"file must end with exactly one LF byte");
        _expectReject(unicode"Text\n\n", unicode"text must be a single line followed by one final LF byte");
        _expectReject(
            unicode"First line\nSecond line\n", unicode"text must be a single line followed by one final LF byte"
        );

        // 7 Empty
        _expectReject("\n", unicode"text is empty; the file contains only the final LF byte");
        _expectReject("", unicode"file is empty");
    }

    function _expectReject(string memory raw, string memory reason) private {
        vm.expectRevert(bytes(string.concat(unicode"VersionZero: t ", reason)));
        harness.canonicalize(bytes(raw), "t");
    }

    //  Main web precheck

    function test_testnetsAllowPlaceholderText() public {
        vm.chainId(SOME_TESTNET_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();
        harness.requireDeployable(texts, bytes32(0), bytes32(0)); // No, no. revert Yeah.
    }

    /// @notice CRITICAL **46630 The branch called "not the main web"**(M3 W2 / issue #65).
    ///
    /// @dev The one up there. Sepolia This is the general rule of "no-one-in-the-mode", which is a separate nail. 46630,Because it is.
    ///      We...**It's gonna be deployed.**And the chain -- and the value of the door determines the cost of testing the network rehearsal:
    ///
    ///       The main part of the network is not the main network (status quo): testing the network rehearsal does not require a nail to Hashi, but it is the first time that the network is being run.`deployments/46630.planned.json`
    ///        Lee. `attestationV0IsDraft` The status of the text is recorded as it is, and anyone can see at first sight which version of the chain is signed.
    ///       If someone had to... 46630 And the main gate. The test rehearsal will be here. `VersionZero` This step is not going to be deployed.
    ///        The report says that the word "Hashi must be nailed" - is a mistake that has nothing to do with the word "test net".
    ///
    ///      So here's a link.**Worst Inputs**Other Organiser + Both Hash didn't nail it. It still has to go.
    ///      See the observations on the other side of the script. `test/DeploySystem.t.sol` It's...
    ///      `DeploySystemRobinhoodTestnetTest`.
    function test_robinhoodTestnetTakesTheNonMainnetBranch() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        VersionZero.Texts memory texts = _draft();

        assertTrue(VersionZero.isDraft(texts), unicode"Presupposition: This synthesis input does carry a draft tag");
        harness.requireDeployable(texts, bytes32(0), bytes32(0)); // No, no. revert Yeah.
    }

    function test_mainnetRejectsDraftText() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = _draft();
        // Even if the Hathsi nails are right -- the draft is a draft.
        _expectRejection(texts, texts.termsHash, texts.attestationHash, unicode"still marked as a draft");
    }

    function test_mainnetRejectsFinalizedTextWithoutPinnedHashes() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        _expectRejection(
            VersionZero.load(), bytes32(0), bytes32(0), unicode"requires the approved terms and attestation hashes"
        );
    }

    function test_mainnetRejectsTextThatDriftedAfterLegalReview() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();

        // The legal opinion was signed in another text -- that is, the document was modified after the opinion.
        _expectRejection(texts, keccak256("some other terms"), texts.attestationHash, "terms.en.txt");
        _expectRejection(texts, texts.termsHash, keccak256("some other attestation"), "attestation.en.txt");
    }

    function test_mainnetAcceptsFinalizedTextWithMatchingPinnedHashes() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();
        harness.requireDeployable(texts, texts.termsHash, texts.attestationHash); // No, no. revert Yeah.
    }

    /// @dev Hathy was nailed to death. `ATTESTATION_V0_*_HASH` Read it in.
    ///      CRITICAL **This is the only one in this document that touches on the environment variable.** forge The government has been working on the issue of the "Standing of the Tests" in the same contract.
    ///      Environmental variables are process-level -- one more is randomly fighting each other.
    function test_pinnedHashesComeFromTheEnvironment() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();

        vm.setEnv(VersionZero.ENV_TERMS_HASH, vm.toString(texts.termsHash));
        vm.setEnv(VersionZero.ENV_ATTESTATION_HASH, vm.toString(texts.attestationHash));
        harness.requireDeployableFromEnv(texts);

        vm.setEnv(VersionZero.ENV_TERMS_HASH, vm.toString(keccak256("some other terms")));
        vm.expectRevert();
        harness.requireDeployableFromEnv(texts);
    }

    //  Main Web 2BSC

    /// @notice CRITICAL **BSC The main network is going.**
    ///
    /// @dev The reason for this test is the shape it's red:`requireDeployable` Earlier.
    ///      `block.chainid != ROBINHOOD_CHAIN_ID` And then it was the same.**The second moment that the second main web came up.**,
    ///      BSC  Will fall quietly into the non-mainline  -> Skip the final check' branch, put the placeholder text marked with the draft
    ///      **Permanent**Write `versions[0]`(Unreblemable, no variables 6(3)).
    ///
    ///      Gives the worst input: the draft text + Both Hash had no nails. It had to be blocked, and the reason must be a "draft".
    function test_bscTakesTheMainnetBranch() public {
        vm.chainId(BSC_CHAIN_ID);
        _expectRejection(_draft(), bytes32(0), bytes32(0), unicode"still marked as a draft");
    }

    /// @notice BSC Read it.**It's his own share.**- Legal texts, no. 4663 Yeah.
    ///
    /// @dev The collateral is issued in two chains with different degrees of authority (see table 2).bStocks vs Robinhood Stock),
    ///      And... 4663 It's... `versions[0]` Already chained and irreplaceable -- so both texts must be read separately.
    ///      See `legal/attestation-v0-bsc/README.md` and decision-making 56.
    function test_bscReadsItsOwnLegalDirectory() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory rh = VersionZero.load();

        vm.chainId(BSC_CHAIN_ID);
        VersionZero.Texts memory bsc = VersionZero.load();

        assertEq(rh.termsHash, FINAL_TERMS_HASH, unicode"4663 The final version was still read. terms");
        assertTrue(
            bsc.termsHash != rh.termsHash,
            unicode"BSC We have to read another one. terms  -  -  Or you'll press. chainId The selection directory is not working."
        );

        // ATTESTATION It's about...**Users themselves**(Not American residents, not the issuer.
        // The two chains are deliberately sharing the same text -- so the two Hashs...**Should**Equal.
        assertEq(
            bsc.attestationHash,
            rh.attestationHash,
            unicode"attestation The two chains are the same bytes. Hash should be the same."
        );
    }

    /// @notice BSC The two documents are also subject to byte regulation.
    function test_bscTextFilesAreExactlyOneLine() public view {
        _assertCanonical(VersionZero.TERMS_PATH_BSC);
        _assertCanonical(VersionZero.ATTESTATION_PATH_BSC);
    }

    /// @notice CRITICAL **Treadlines (with 4663 That one. {test_shippedTextIsFinalized} Symmetrical:BSC The text has been finalized.**
    ///
    /// @dev This test was reverse -- it's a statement. BSC That one.**Still draft**,And the moment someone finally finished,
    ///      We'll use the information of failure to explain which steps to do.2026-09-10 The maintainer's gone. `[DRAFT]` Mark. The trip wire is designed.
    ///      And then it was the way it was: nailing the byte version of the final version.
    ///
    ///      It's red. It means someone's moving. BSC Bytes of the final text, or the draft tags are returned -- and
    ///      `versions[0]` Once you're in the chain,**Permanently points to this version**(Unreblemable, no variables 6(3)),BSC of the Republic of Korea
    ///      and 4663 Yes.**Two.**There are isolated examples of each having only one chance.
    function test_bscTextIsFinalized() public {
        vm.chainId(BSC_CHAIN_ID);
        VersionZero.Texts memory bsc = VersionZero.load();

        assertFalse(VersionZero.isDraft(bsc), unicode"BSC It's... version 0 Finalized, no more draft tags");
        assertEq(
            bsc.termsHash,
            FINAL_TERMS_HASH_BSC,
            unicode"attestation-v0-bsc/terms.en.txt The bytes do not match the final version - the final text cannot be changed"
        );
        assertEq(
            bsc.attestationHash,
            FINAL_ATTESTATION_HASH,
            unicode"BSC It's... attestation and 4663 The byte is the same. Hash should be the same."
        );
    }

    /// @notice `isMainnet` This table itself.
    function test_isMainnetTable() public pure {
        assertTrue(VersionZero.isMainnet(4663), "4663");
        assertTrue(VersionZero.isMainnet(56), "56");
        assertFalse(VersionZero.isMainnet(46_630), unicode"Robinhood The test net is not the main network.");
        assertFalse(VersionZero.isMainnet(97), unicode"BSC The test net is not the main network.");
        assertFalse(VersionZero.isMainnet(31_337), unicode"Local chains are not the main network.");
        assertFalse(VersionZero.isMainnet(1), unicode"Ethercom is not our main network.");
    }

    //  Deployment scripts

    /// @dev Deployment and "Additional" version 0It's the same thing: deployment without extra, one of them.
    ///      `attest()` To everyone. revert The registration form... the door was welded to death.
    function test_deployScript_leavesTheGateOpen() public {
        address publisher = makeAddr("publisher");
        AttestationRegistry registry = new DeployAttestationRegistry().deploy(publisher);

        VersionZero.Texts memory texts = VersionZero.load();

        assertEq(registry.publisher(), publisher, "publisher");
        assertEq(registry.versionCount(), 1, unicode"Just as it was deployed.");

        (bytes32 termsHash, bytes32 attestationHash) = registry.versions(0);
        assertEq(termsHash, texts.termsHash, unicode"The chain. termsHash From legal/ File Below");
        assertEq(attestationHash, texts.attestationHash, unicode"The chain. attestationHash From legal/ File Below");

        address stranger = makeAddr("someone who has never touched this chain");
        vm.prank(stranger);
        registry.attest(0, texts.termsHash, texts.attestationHash);
        assertEq(registry.attestedVersion(stranger), 1, unicode"Strange addresses must be able to cross the threshold.");
    }

    //  Support

    /// @dev One.**Bring Draft Tags**. There is no draft in the warehouse.version 0 Finally on 2026-08-26),
    ///      But the two routes of "no drafts" "non-mainline drafts" should be covered.
    function _draft() private pure returns (VersionZero.Texts memory texts) {
        texts.terms = "[DRAFT: placeholder terms awaiting finalization.]";
        texts.attestation = "[DRAFT: placeholder attestation awaiting finalization.]";
        texts.termsHash = keccak256(bytes(texts.terms));
        texts.attestationHash = keccak256(bytes(texts.attestation));
    }

    function _expectRejection(
        VersionZero.Texts memory texts,
        bytes32 reviewedTerms,
        bytes32 reviewedAttestation,
        string memory expectedFragment
    ) private {
        try harness.requireDeployable(texts, reviewedTerms, reviewedAttestation) {
            fail(
                string.concat(
                    unicode"Should have been stopped by a front-end inspection of the main network, but it was released:",
                    expectedFragment
                )
            );
        } catch Error(string memory reason) {
            assertTrue(
                _contains(reason, expectedFragment),
                string.concat(
                    unicode"The reason for this is wrong. Expectations include \"",
                    expectedFragment,
                    unicode",Actual:",
                    reason
                )
            );
        }
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;

        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
