// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice Compiled product ABI One of the entrances to the center.
/// @param name        function name.`receive` / `fallback` Note as a string with the same name -- they're ABI Not in there. `name` Fields
/// @param mutability  `view` / `pure` / `nonpayable` / `payable`
/// @param signature   Full Signature `name(type,type,...)`;`receive` / `fallback` Remember `receive()` / `fallback()`
struct AbiEntry {
    string name;
    string mutability;
    string signature;
}

/// @title WriteSurface
/// @notice From the compilation. ABI It's a contract.**All external entrances**,And it was said that the ones that could be written were just what they were supposed to be.
///
/// # Why read the translation, not read it in the test.
///
/// No Variable 5(Clearinghouse No Manager Export) and NonVariable 6(The statement is not to be locked.**Cannot initialise Evolution's mail component.**.
/// I'm going to go over the functions I called, and I can't prove it -- I added it. `withdraw()` It's not because
/// No test called it and it didn't work.**Just one. ABI The whole list is not circular.**
///
/// So this is not a test detail for a contract, but a common mechanism for the project to "prove that the switch does not exist" and to make a statement about the project.
/// Separated into a library, which is shared in several places:
///
/// - `AttestationRegistry`  -  -  Just two.`addVersion` / `attest`)
/// - `ClearingPool`  -  -  Just six.`docs/spec.md`)
/// - `CallVault`  -  -  Just six.`sync` / `sampleTwap` / `openSeries` / `processRevenue` / `receive`
///   / `claimCreatorFee`,Decision-making 49),
///   And...**None of them are permission functions**.It's a kind of thing.**Rationale**In decision-making 39 I changed it once.Flap Regulates compulsory privileges functions
///   And it's all awarded. GuardianThe government has been able to provide the government with the necessary financial resources to enable the government to take the necessary measures to ensure that the government will not take the money.
///   And...**The verdict hasn't changed a word.**  -  -  It's still a character to be listed.
///   (`docs/spec.md`)
///
/// @dev Yes. `out/` Read permissions, see `foundry.toml` It's... `fs_permissions`.
library WriteSurface {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev ABI It's an array.JSON The length is not taken from the inside, so the bottom mark is not taken until it is taken.
    ///      Two upper levels are simply hand-sliding to write death cycles, and normal contracts are not met.
    uint256 private constant MAX_ABI_ENTRIES = 512;
    uint256 private constant MAX_INPUTS = 32;

    /// @notice The assertion. `artifactPath` External writeable set**Just right.**Equal `expected`.
    ///
    /// @param artifactPath  Path to the compilation product, as follows: `out/ClearingPool.sol/ClearingPool.json`
    /// @param expected      Full signature, as if `settleExpired(uint256)`;`receive` / `fallback` Written
    ///                      `receive()` / `fallback()`
    ///
    /// @dev Two-way comparison, two directions are not the same thing:
    ///      - "There's no seventh entrance," as it says.**Body**;
    ///      - The missing -- someone tightens up a function. `view`/`pure`,Or change your signature. One less is the interface.
    ///        The most likely change is to slip through the illusion of "test or green."
    ///
    ///      CRITICAL `receive` / `fallback` No, it's not. `"function"`,If you miss them, you miss an entire class of entrances. They're here.
    ///      Let's go.**Same as normal functions** A path that doesn't show  `expected` The blog also provides a list of "unexpected external writing functions".
    ///      Four. M1 Contract. `expected` They're not in there, so, "These four contracts are not supposed to exist. receiveSet up as usual...
    ///      There is no more special judgment, but the same collection. The vault must be made equal. `receive()`(Flap It's... ping # Hit it there #
    ///      It's in its own. `expected` list.
    function assertIsExactly(string memory artifactPath, string[] memory expected) internal view {
        string[] memory found = writableSignatures(artifactPath);

        for (uint256 i = 0; i < found.length; i++) {
            vm.assertTrue(
                _contains(expected, found[i]), string.concat(unicode"Unexpected external writing functions:", found[i])
            );
        }
        for (uint256 i = 0; i < expected.length; i++) {
            vm.assertTrue(
                _contains(found, expected[i]),
                string.concat(
                    unicode"This external writing function is missing (deleted, signed, or tightened). view/pure):",
                    expected[i]
                )
            );
        }
        vm.assertEq(found.length, expected.length, unicode"Number of external writingable functions");
    }

    /// @notice Quantification of all external writing functions**Full Signature**.
    ///
    /// @dev CRITICAL Claiming full signature rather than a function name: one more than a name `addVersion(address,uint256)`
    ///      It's gonna be in a legitimate name.
    function writableSignatures(string memory artifactPath) internal view returns (string[] memory signatures) {
        AbiEntry[] memory all = entries(artifactPath);

        string[] memory buffer = new string[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (isReadOnly(all[i].mutability)) continue;
            buffer[n++] = all[i].signature;
        }

        signatures = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            signatures[i] = buffer[i];
        }
    }

    /// @notice Enumeration**All**The external entrance -- the written and read-only ones are in it.
    ///
    /// @dev "The vault. "`vaultUISchema()` The way you make a statement and the truth. ABI The cross-checking process is only about half the reading:
    ///      schema It's a handwritten one.ABI It's the compiler. When the two drifted,**No one reads anything but them. schema ..and the test will be red.**.
    function entries(string memory artifactPath) internal view returns (AbiEntry[] memory list) {
        string memory artifact = vm.readFile(artifactPath);

        AbiEntry[] memory buffer = new AbiEntry[](MAX_ABI_ENTRIES);
        uint256 n;
        uint256 seen;

        for (uint256 i = 0; i < MAX_ABI_ENTRIES; i++) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(artifact, string.concat(entry, ".type"))) break;
            seen++;

            bytes32 kind = keccak256(bytes(vm.parseJsonString(artifact, string.concat(entry, ".type"))));

            if (kind == keccak256("receive") || kind == keccak256("fallback")) {
                string memory name = kind == keccak256("receive") ? "receive" : "fallback";
                buffer[n++] = AbiEntry(name, _mutabilityOf(artifact, entry), string.concat(name, "()"));
                continue;
            }
            if (kind != keccak256("function")) continue;

            buffer[n++] = AbiEntry(
                vm.parseJsonString(artifact, string.concat(entry, ".name")),
                _mutabilityOf(artifact, entry),
                _signatureOf(artifact, entry)
            );
        }

        // A bottom of what you read:ABI If you read it quietly, it's a complete loop.
        // Just right. N The "one" becomes "just as zero" -- and the assertion was still green, but it meant a lie.
        vm.assertGt(seen, 0, string.concat(unicode"I didn't read it. ABI  -  -  Wrong path?", artifactPath));

        list = new AbiEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            list[i] = buffer[i];
        }
    }

    /// @notice `mutability` Is it read-only?`view` / `pure`).
    function isReadOnly(string memory mutability) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(mutability));
        return h == keccak256("view") || h == keccak256("pure");
    }

    function _mutabilityOf(string memory artifact, string memory entry) private pure returns (string memory) {
        return vm.parseJsonString(artifact, string.concat(entry, ".stateMutability"));
    }

    /// @dev From one ABI Record Spelling `name(type,type,...)`.
    function _signatureOf(string memory artifact, string memory entry) private view returns (string memory signature) {
        signature = string.concat(vm.parseJsonString(artifact, string.concat(entry, ".name")), "(");

        for (uint256 j = 0; j < MAX_INPUTS; j++) {
            string memory input = string.concat(entry, ".inputs[", vm.toString(j), "]");
            if (!vm.keyExistsJson(artifact, string.concat(input, ".type"))) break;

            string memory kind = vm.parseJsonString(artifact, string.concat(input, ".type"));
            // ABI - Put it on. struct Parameters written `tuple` Add `components`.Here's the check. ABI  The shape of the entrance
            // bytes4 selector,So, I'm keeping it. `tuple` The volume, the caller will simply include the expected verse.

            if (j != 0) signature = string.concat(signature, ",");
            signature = string.concat(signature, kind);
        }

        signature = string.concat(signature, ")");
    }

    function _contains(string[] memory haystack, string memory needle) private pure returns (bool) {
        bytes32 n = keccak256(bytes(needle));
        for (uint256 i = 0; i < haystack.length; i++) {
            if (keccak256(bytes(haystack[i])) == n) return true;
        }
        return false;
    }
}
