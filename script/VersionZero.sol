// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title VersionZero
/// @notice `AttestationRegistry.versions[0]` and the two paragraphs of the text: `legal/attestation-v0/` Read, read, read.
///         Hashi, and...**Main**The government has also been monitoring the use of the Internet to monitor the use of the word "finalised and approved" on the Internet.
///
/// It's a silo, not a script for deployment. M1-3(issue #8)The four contract deployment scripts need to be re-engineered with the same logic...
/// version 0 ..and only the text that you want to see.**One.**Source.
///
/// CRITICAL `versions[0]` Once the chain is in place, it cannot be deleted, and any address can be permanently accessed `attest(0, ...)` Fulfilling the right to freedom threshold
/// (No Variable 6(3)).That means...**The two paragraphs are the only guaranteed version available to all users**.There is no second chance of a mistake.
library VersionZero {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param terms            TERMS Text (byte-recognitioned, remove the only ending LF)
    /// @param attestation      ATTESTATION Text (ibid.)
    /// @param termsHash        `keccak256(bytes(terms))`
    /// @param attestationHash  `keccak256(bytes(attestation))`
    struct Texts {
        string terms;
        string attestation;
        bytes32 termsHash;
        bytes32 attestationHash;
    }

    /// @dev Main chain ID.Registration form**One in each chain.**,So "Is it the main network?"chainId On this watch or not."
    ///      CRITICAL It used to be a single value. `ROBINHOOD_CHAIN_ID`,`requireDeployable` Take it straight to the equivalent.
    ///      That shape became one at the moment the second main web appeared.**Silence.**The pit:BSC The main network will go.
    ///      Non-main network -> Skip the final check' branch, put the placeholder text marked with the draft**Permanent**Write
    ///      `versions[0]`(Unreblemable, no variables 6(3)).The chain must be added to this table. See the decision. 56.
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant BSC_CHAIN_ID = 56;

    /// @dev Robinhood Chain(4663)That one.
    string internal constant TERMS_PATH = "legal/attestation-v0/terms.en.txt";
    string internal constant ATTESTATION_PATH = "legal/attestation-v0/attestation.en.txt";

    /// @dev BSC(56)That one.**Why can't you and 4663 Share one.**,See
    ///      `legal/attestation-v0-bsc/README.md` 1:4663 It's... `versions[0]` The blogger says that the government is not a party to the law.
    ///      The two chains of collateral are issued with different titles - a text that describes both.
    ///      Either there is excessive disclosure of one chain or insufficient disclosure of another.
    string internal constant TERMS_PATH_BSC = "legal/attestation-v0-bsc/terms.en.txt";
    string internal constant ATTESTATION_PATH_BSC = "legal/attestation-v0-bsc/attestation.en.txt";

    /// @dev Draft Tag.version 0 Already 2026-08-26 Finalized (authority in English; see legal/attestation-v0/README.md).
    ///      Mark as a gate: No text re-packaged (with future drafts) will be entered into the main web site.
    ///      It is within the reach of Hashi, it is bound to change and must be re-examined in the next Hashi.
    string internal constant DRAFT_MARKER = "[DRAFT";

    /// @dev The main web site must be filled and must be equal to the current values.
    string internal constant ENV_TERMS_HASH = "ATTESTATION_V0_TERMS_HASH";
    string internal constant ENV_ATTESTATION_HASH = "ATTESTATION_V0_ATTESTATION_HASH";

    /// @notice This chain is not the main network.
    /// @dev `pure` Not read. `block.chainid`,Because... `requireDeployable` The wrong message to put
    ///      The current chain is being struck with the "master list" and the two values are being better measured separately.
    function isMainnet(uint256 chainId) internal pure returns (bool) {
        return chainId == ROBINHOOD_CHAIN_ID || chainId == BSC_CHAIN_ID;
    }

    /// @notice Which group of text files should be read in this chain.
    ///
    /// @dev CRITICAL **Press chainId Select, leave the back door to the environment variable.** "To which law is read and which chain is written."
    ///      It has to be the same fact twice; give it one. env Switches, a mistake in the night of deployment.
    ///      - Put it on. A The text of the chain is permanently written B The registration form for the chain.
    ///
    ///      WARNING **The known gap in the local fork rehearsal**:BSC The rehearsal runs. 31337 Local chains like this. ID Go, it'll fall here.
    ///      Robinhood That one -- because of the local chain. ID So far, the hard map is... Robinhood That's the one.
    ///      (`DeploySystem` It's... 31337/31338 Same thing. manifest Lee will write it down.
    ///      Robinhood Hashi. This doesn't affect the integrity of the main network. chainId (decisions, but will not be allowed) BSC Rehearsal
    ///      Can not verify this message.`requireDeployable` The online alert will be a list of the actual entries, and the online alert will be available for the public to read.
    ///      So that this thing can be done.**Visible**Not quiet. Fix it.BSC Which local chains to rehearse? IDThe case is settled.
    function legalDir() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? "legal/attestation-v0-bsc/" : "legal/attestation-v0/";
    }

    function termsPath() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? TERMS_PATH_BSC : TERMS_PATH;
    }

    function attestationPath() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? ATTESTATION_PATH_BSC : ATTESTATION_PATH;
    }

    /// @notice Read two paragraphs and calculate Hash. Which one is the reason for reading? {legalDir} Press chainId Decision.
    function load() internal view returns (Texts memory t) {
        t.terms = _readCanonical(termsPath());
        t.attestation = _readCanonical(attestationPath());
        t.termsHash = keccak256(bytes(t.terms));
        t.attestationHash = keccak256(bytes(t.attestation));
    }

    /// @notice Main web front check, nailed Hashi reading from the environment variable.
    function requireDeployable(Texts memory t) internal view {
        requireDeployable(t, vm.envOr(ENV_TERMS_HASH, bytes32(0)), vm.envOr(ENV_ATTESTATION_HASH, bytes32(0)));
    }

    /// @notice Main web pre-check: text is finalized and identical to the version by by bytes approved in the final version.
    ///
    /// @dev Non-main network (test network) / Local / The fork test) releases only one action -- the placeholder text is allowed there.
    ///
    ///      There are two ways to go on the Internet:
    ///      (1) The text should not leave draft prefixes - to prevent the most common error, "forgot to finalize" and give readable errors.
    ///      (2) The final version of the document, now counted as "Hashi must be crucified and approved", was blocked by the "document has been modified after the final version".
    ///
    ///      (2) It's covered in structure. (1)(The final version will change Hash, but (1) The wrong information.**What do you want to do?**,
    ///      And... (2) I can only tell you.**I don't know.**.These two words are not the same thing at night of deployment.
    ///
    ///      The reason why Hashi's nailed to the ground instead of reading the environment variable here is to make it measurable:
    ///      forge In the same test contract.**Parallel**Run the tests, and the environment variable is process-level -
    ///      Shit. `vm.setEnv` The test of plagiarizing it is a fight. The one above is a double-load of environment variables.
    function requireDeployable(Texts memory t, bytes32 reviewedTerms, bytes32 reviewedAttestation) internal view {
        if (!isMainnet(block.chainid)) {
            console2.log(
                string.concat(
                    unicode"[VersionZero] WARNING chainId=",
                    vm.toString(block.chainid),
                    unicode" Not Main Network (NL)",
                    vm.toString(ROBINHOOD_CHAIN_ID),
                    " / ",
                    vm.toString(BSC_CHAIN_ID),
                    unicode"),Skip \"text finalized\" check - this time the chain is occupied text. ",
                    // CRITICAL Type out the directory that you actually read: which law text is the local rehearsal?**Visible**I'm sorry.
                    //    It's not about reading. {legalDir} The source code is only known. See the rehearsal gap that's written there.
                    legalDir()
                )
            );
            return;
        }

        require(
            !_contains(t.terms, DRAFT_MARKER) && !_contains(t.attestation, DRAFT_MARKER),
            string.concat(
                unicode"VersionZero: version 0 text is still marked as a draft and cannot be deployed to mainnet. ",
                legalDir(),
                "README.md"
            )
        );

        require(
            reviewedTerms != bytes32(0) && reviewedAttestation != bytes32(0),
            string.concat(
                unicode"VersionZero: mainnet deployment requires the approved terms and attestation hashes. ",
                ENV_TERMS_HASH,
                " / ",
                ENV_ATTESTATION_HASH,
                unicode". Current text hashes: ",
                vm.toString(t.termsHash),
                " / ",
                vm.toString(t.attestationHash)
            )
        );

        require(
            reviewedTerms == t.termsHash,
            string.concat(
                unicode"VersionZero: terms.en.txt does not match the approved hash ",
                vm.toString(reviewedTerms),
                unicode"; current hash: ",
                vm.toString(t.termsHash)
            )
        );
        require(
            reviewedAttestation == t.attestationHash,
            string.concat(
                unicode"VersionZero: attestation.en.txt does not match the approved hash ",
                vm.toString(reviewedAttestation),
                unicode"; current hash: ",
                vm.toString(t.attestationHash)
            )
        );
    }

    /// @notice Whether text is still marked with a draft.
    function isDraft(Texts memory t) internal pure returns (bool) {
        return _contains(t.terms, DRAFT_MARKER) || _contains(t.attestation, DRAFT_MARKER);
    }

    function _readCanonical(string memory path) private view returns (string memory) {
        return canonicalize(bytes(vm.readFile(path)), path);
    }

    /// @notice Press `legal/attestation-v0/README.md` byte norms to remove body text:**It's just the end. LF**,
    ///         Body is not empty, does not contain any control characters, does not contain BOM / `-` / `0x` Start.
    ///         Get rid of that one. LF It's what Hash said.
    ///
    /// @dev CRITICAL **Unstandardly entered entries are rejected without "fixing".** Earlier, it was "Eat the end of any one." `\n` and `\r`,
    ///      That way. `"Text\n"` and `"Text\r\n"` It's going to be the same Hash - the file is stored by the editor after it's finalized CRLF,
    ///      The death of Hashi is a success, and his deployment is successful.**But the users took it. README The order in the house is another value.**:
    ///
    ///      ```
    ///      cast keccak -- "$(cat Documentation)"   # $( ) Strip all the lines of the end, but not the end. CR
    ///      ```
    ///
    ///      The "verified text" was then snubbed off with the "placed text" and the job was irreversible.
    ///      After the tightening, Hashi matched the byte of the document; the two sides really got on the line, and the two sides were really on the right side of the matter, and the two sides were really on the right side of it, and the two sides were really on the right side of it. CI Lee.
    ///      version 0 "Hashi can take it back."**Run this order once and for all.**To prove that, it's not the note here.
    ///
    ///      `internal` Not `private`,So that these rejection paths can be tested directly --
    ///      Go to the file system and construct them. They need to write disk privileges. `fs_permissions` and only read.
    ///      The blogger adds that the government should keep reading only.
    function canonicalize(bytes memory raw, string memory path) internal pure returns (string memory) {
        if (raw.length == 0) _reject(path, unicode"file is empty");
        if (raw[raw.length - 1] != 0x0a) {
            _reject(path, unicode"file must end with exactly one LF byte");
        }

        uint256 end = raw.length - 1; // Text length: Remove the only ending LF
        if (end == 0) _reject(path, unicode"text is empty; the file contains only the final LF byte");

        _rejectHostileOpening(raw, end, path);

        bytes memory line = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            bytes1 b = raw[i];

            // CRITICAL CR and NUL The same: the naked eye can't see, and the recalculation command can't get them.
            //    (CR By `$( )` (a) Keep but are stripped of it;NUL There's no way in. argv).
            if (b == 0x0d) {
                _reject(path, unicode"text contains CR; line endings must use LF, not CRLF");
            }
            if (b == 0x0a) {
                _reject(path, unicode"text must be a single line followed by one final LF byte");
            }
            if (b < 0x20 || b == 0x7f) {
                _reject(path, unicode"text contains a control character");
            }

            line[i] = b;
        }
        return string(line);
    }

    /// @dev The text starts with three "legitimate bytes, but will allow `cast keccak` The Quietly Calculating Other Values' Shape.
    ///      All three have been measured.foundry 1.7.1):
    ///
    ///      | Text | `cast keccak "$(cat Documentation)"` |
    ///      |---|---|
    ///      | `--json` | By clap Eat it like a switch. Return quietly. `keccak("")` |
    ///      | `0xdeadbeef` | Hexadecimal**Decoding**Then Hashi, plus `--` I can't stop it. |
    ///      | BOM Start | Both sides. BOM,Hash is in agreement -- but the body cannot tell which edition it is. |
    ///
    ///      The first two are really silent; the third is that the words "a lawyer sees" and "a byte of Hashi in the chain" may not be the same.
    ///      A body of law would never begin with these three shapes, so it would be most convenient to reject it directly.
    function _rejectHostileOpening(bytes memory raw, uint256 end, string memory path) private pure {
        if (end >= 3 && raw[0] == 0xef && raw[1] == 0xbb && raw[2] == 0xbf) {
            _reject(path, unicode"text must not begin with a UTF-8 BOM");
        }
        if (raw[0] == 0x2d) {
            _reject(path, unicode"text must not begin with '-' because cast would parse it as an option");
        }
        if (end >= 2 && raw[0] == 0x30 && (raw[1] == 0x78 || raw[1] == 0x58)) {
            _reject(path, unicode"text must not begin with 0x because cast would decode it as hexadecimal input");
        }
    }

    /// @dev Messages are only spelled on the failed path.`require` The second parameter is:**Request and call first**I'm sorry.
    ///      Write in a byte cycle that makes the function become O(n2)  -  -  The text is so big. MemoryOOG,
    ///      And the report was not a carefully written error, but a statement that was not read.
    function _reject(string memory path, string memory reason) private pure {
        revert(string.concat(unicode"VersionZero: ", path, " ", reason));
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
