// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WarrantVault} from "../src/WarrantVault.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "../src/flap/IVaultSchemasV1.sol";

/// @notice Traverse compiled ABI, so newly exposed methods cannot silently escape UI coverage.
contract WarrantSchemaTest is Test {
    WarrantVault internal vault;

    function setUp() public {
        StockToken collateral = new StockToken();
        vault = new WarrantVault(
            IClearingPool(address(1)),
            address(2),
            address(3),
            address(4),
            address(collateral),
            address(5),
            false,
            address(6)
        );
    }

    function test_rule006EveryExposedUserMethodMatchesSchemaAndAbi() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertGt(bytes(schema.vaultType).length, 0);
        assertGt(bytes(schema.description).length, 0);
        string memory artifact = vm.readFile("out/WarrantVault.sol/WarrantVault.json");
        uint256 checked;
        for (uint256 i; i < 100; ++i) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(artifact, string.concat(entry, ".type"))) break;
            if (keccak256(bytes(vm.parseJsonString(artifact, string.concat(entry, ".type")))) != keccak256("function")) continue;
            string memory name = vm.parseJsonString(artifact, string.concat(entry, ".name"));
            bytes32 hash = keccak256(bytes(name));
            if (
                hash == keccak256("description") || hash == keccak256("vaultUISchema")
                    || hash == keccak256("vaultSpecVersion")
            ) continue;
            uint256 index = type(uint256).max;
            for (uint256 j; j < schema.methods.length; ++j) {
                if (hash == keccak256(bytes(schema.methods[j].name))) {
                    assertEq(index, type(uint256).max, "duplicate schema method");
                    index = j;
                }
            }
            assertLt(index, schema.methods.length, string.concat("schema missing ", name));
            VaultMethodSchema memory method = schema.methods[index];
            assertGt(bytes(method.description).length, 0);
            string memory mutability = vm.parseJsonString(artifact, string.concat(entry, ".stateMutability"));
            bool readOnly =
                keccak256(bytes(mutability)) == keccak256("view") || keccak256(bytes(mutability)) == keccak256("pure");
            assertEq(method.isWriteMethod, !readOnly);
            _fields(artifact, string.concat(entry, ".inputs"), method.inputs);
            _fields(artifact, string.concat(entry, ".outputs"), method.outputs);
            assertEq(method.approvals.length, 0, "Vault users need no ERC20 approvals");
            ++checked;
        }
        assertEq(checked, schema.methods.length, "schema contains nonexistent ABI method");
        assertEq(checked, 35);
    }

    function test_protocolFeeSchemaDisclosesFixedReceiverAndRawAccounting() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        string[6] memory names = [
            "PROTOCOL_FEE_BPS",
            "protocolFeeReceiver",
            "protocolAccrued",
            "protocolClaimed",
            "protocolImpaired",
            "claimProtocolFee"
        ];
        for (uint256 i; i < names.length; ++i) {
            bool found;
            for (uint256 j; j < schema.methods.length; ++j) {
                VaultMethodSchema memory method = schema.methods[j];
                if (keccak256(bytes(method.name)) != keccak256(bytes(names[i]))) continue;
                found = true;
                assertEq(method.inputs.length, 0, "caller cannot select the fee receiver");
                assertEq(method.outputs.length, 1);
                assertEq(method.outputs[0].decimals, 0);
                assertEq(method.isWriteMethod, i == 5);
            }
            assertTrue(found, names[i]);
        }
        assertEq(vault.PROTOCOL_FEE_BPS(), 1000);
        assertEq(vault.protocolFeeReceiver(), address(6));
    }

    function _fields(string memory artifact, string memory path, FieldDescriptor[] memory fields) internal view {
        uint256 count;
        for (uint256 i; i < 10; ++i) {
            string memory entry = string.concat(path, "[", vm.toString(i), "].type");
            if (!vm.keyExistsJson(artifact, entry)) break;
            assertLt(i, fields.length);
            string memory abiType = vm.parseJsonString(artifact, entry);
            string memory normalized = keccak256(bytes(abiType)) == keccak256("uint64") ? "time" : abiType;
            if (keccak256(bytes(abiType)) == keccak256("uint8")) normalized = "uint256";
            assertEq(fields[i].fieldType, normalized);
            assertGt(bytes(fields[i].name).length, 0);
            assertGt(bytes(fields[i].description).length, 0);
            assertEq(fields[i].decimals, 0, "raw unit schema must not invent 18 decimals");
            ++count;
        }
        assertEq(count, fields.length);
    }
}
