// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title Bytecode
/// @notice Yes.**deployed runtime Byte Code**The above assertion that a certain code does not appear.
///
/// # Why? ABI There's not enough enumeration.
///
/// `test/helpers/WriteSurface.sol` It proves "No. " N+1 Externally writeable function." That one won't stop.
/// **Proxy**:beacon proxy It's... ABI Neither did it. `upgradeTo`  -  -  It's a realization address.**From beacon It's from the book.**,
/// In exchange for doing so, you do not have to expose any function to yourself.
///
/// CRITICAL And that's exactly what it is. issue #23 The judgement 3 "In-Hin" Flap GuardianThe one that's gonna stop:Guardian Powers
/// From beacon Upgrade, not from calling a function. Prove it. 'Guardian The law is not a legal instrument, but it is a legal instrument that is not a legal instrument.
/// It has to be proven.**They're not gonna do code anywhere else.**  -  -  That's it. runtime Not in there. `DELEGATECALL`.
///
/// # Two scans. The first one, the first one.
///
/// | All over. | The judgement | Strength |
/// |---|---|---|
/// | PARK Soo-soo. | The whole byte**One.** `0xf4` Not even. | Unconditional, without any decomposition assumptions. |
/// | PUSH Sensory | Skip `PUSH1..PUSH32` The immediate number of the number of the number of the persons who did not appear. | We need a "linear layout" scenario. |
///
/// It's over when Park's gone through it -- it can't have fake negatives. Only one of them. `0xf4` It's falling in a few miles.
/// It's the second time you've been able to put a constant in your report. PUSH The blogger says that the government is not going to allow the government to take a decision.
/// Because its conclusions are indeed low in intensity.
///
/// @dev Only**Small contract.**With this. In the big deal. `0xf4` It's almost inevitable to be in constant, and the first one is bound to fail.
///      And the conclusion is downsized -- that's where we should use another argument, not the assumption here.
library Bytecode {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 internal constant DELEGATECALL = 0xf4;
    uint8 internal constant CALLCODE = 0xf2;
    uint8 internal constant SELFDESTRUCT = 0xff;

    /// @notice The assertion. `target` It's... runtime No byte code exists `opcode`.What scan did you use to return?
    ///
    /// @param target  Contracts deployed
    /// @param opcode  Disabled Operator Code
    /// @param name    Human readable names, only in the description of error and return.
    ///
    /// @return note Description text, as follows: `DELEGATECALL:The whole paragraph. 1234 One byte 0xf4 Not even.`.
    ///              Test it. `console2.log` Come out - conclusions**Strength**The government has to stay in evidence.
    ///              The "green" cannot be the same thing when two scans are made.
    function assertNoOpcode(address target, uint8 opcode, string memory name)
        internal
        view
        returns (string memory note)
    {
        bytes memory code = target.code;
        vm.assertGt(code.length, 0, string.concat(unicode"No byte code to scan:", vm.toString(target)));

        if (!_containsByte(code, opcode)) {
            return string.concat(
                name,
                unicode":The whole paragraph. ",
                vm.toString(code.length),
                unicode" One byte 0x",
                _hex(opcode),
                unicode" Not even."
            );
        }

        // It's here to say somewhere.**Bytes**There it is. Walk it through the article by article, and eliminate the immediate count.
        uint256 i;
        while (i < code.length) {
            uint8 b = uint8(code[i]);

            if (b >= 0x60 && b <= 0x7f) {
                i += 1 + (uint256(b) - 0x5f); // PUSH1..PUSH32:Skip the count immediately
                continue;
            }

            vm.assertTrue(
                b != opcode,
                string.concat(
                    unicode"Bytes Number ",
                    vm.toString(i),
                    unicode" Yes. ",
                    name,
                    unicode"  -  -  It can execute code elsewhere."
                )
            );
            i++;
        }

        return string.concat(
            name,
            unicode":It's been in bytes. 0x",
            _hex(opcode),
            unicode",But it all fell. PUSH Immediate (conclusion dependent on linear layout assumptions, low intensity)"
        );
    }

    function _containsByte(bytes memory code, uint8 b) private pure returns (bool) {
        for (uint256 i = 0; i < code.length; i++) {
            if (uint8(code[i]) == b) return true;
        }
        return false;
    }

    function _hex(uint8 b) private pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory out = new bytes(2);
        out[0] = alphabet[b >> 4];
        out[1] = alphabet[b & 0x0f];
        return string(out);
    }
}
