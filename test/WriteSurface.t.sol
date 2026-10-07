// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AbiEntry, WriteSurface} from "./helpers/WriteSurface.sol";

/// @dev Samples that exist for an item: one `receive`,One. `fallback`,One normal writing function, one view.
contract SurfaceSample {
    uint256 public counter;

    receive() external payable {
        counter++;
    }

    fallback() external {
        counter++;
    }

    function poke(uint256 by) external {
        counter += by;
    }
}

/// @dev Put the claim once. external The call is back to make "it should fail" a certain fact.
///      `vm.assert*` When it fails, it is. revert,It's only possible to cross the call border.
contract SurfaceProbe {
    function assertIsExactly(string memory artifactPath, string[] memory expected) external view {
        WriteSurface.assertIsExactly(artifactPath, expected);
    }
}

/// @notice {WriteSurface} Your own contract.
///
/// CRITICAL Why do you write a test aid library: the claim that this project "proves that a switch does not exist" is all passed through it?
/// No Variable 5(Clearinghouses without managers, no variables 6(The door is not locked, and the two vaults.
/// No permission function "No user extracts" (see also http://www.un.org/sc/sc/sc/sc/sc/sc/sc/sc/sc/sc/sc)`docs/spec.md`).
/// If it's missing one of its own, every one of them will.**Keep turning green.**,Just don't check the old thing anymore.
///
/// This is the type that's the easiest to miss:`receive` / `fallback` Yes. ABI Not Lee. `"function"`,
/// Yeah.**No, I'm not. `name` Fields**,Read empty on the spot as the normal function is analysed in the path.
contract WriteSurfaceTest is Test {
    string internal constant SAMPLE = "out/WriteSurface.t.sol/SurfaceSample.json";

    function test_enumeratesReceiveAndFallbackAlongsideOrdinaryFunctions() public view {
        string[] memory expected = new string[](3);
        expected[0] = "receive()";
        expected[1] = "fallback()";
        expected[2] = "poke(uint256)";

        WriteSurface.assertIsExactly(SAMPLE, expected);
    }

    /// @dev Counter-argument one: Leaked `receive()` It must be red. This is the most important piece of the system--
    ///      There's no contract. receiveAnd before that, by a special judgment, now by the same sum.
    function test_undeclaredReceiveIsRejected() public {
        SurfaceProbe probe = new SurfaceProbe();

        string[] memory missingReceive = new string[](2);
        missingReceive[0] = "fallback()";
        missingReceive[1] = "poke(uint256)";

        vm.expectRevert();
        probe.assertIsExactly(SAMPLE, missingReceive);
    }

    /// @dev Counter-argument II: Write an additional non-existent entry must also be red (the missing direction).
    function test_vanishedEntryIsRejected() public {
        SurfaceProbe probe = new SurfaceProbe();

        string[] memory extra = new string[](4);
        extra[0] = "receive()";
        extra[1] = "fallback()";
        extra[2] = "poke(uint256)";
        extra[3] = "withdraw()";

        vm.expectRevert();
        probe.assertIsExactly(SAMPLE, extra);
    }

    /// @dev In full measure. view Also, and read-written properties are clearly identified -- the vault. schema Cross-check this.
    function test_entriesCarryMutabilityForReadsAndWrites() public view {
        AbiEntry[] memory entries = WriteSurface.entries(SAMPLE);
        assertEq(entries.length, 4, unicode"receive + fallback + poke + counter");

        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 name = keccak256(bytes(entries[i].name));
            bool readOnly = WriteSurface.isReadOnly(entries[i].mutability);

            if (name == keccak256("counter")) {
                assertTrue(readOnly, unicode"public Variables getter Yes. view");
            } else {
                assertFalse(readOnly, string.concat(unicode"It should be written:", entries[i].signature));
            }
        }
    }
}
