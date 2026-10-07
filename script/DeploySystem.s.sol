// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {Call} from "../src/Call.sol";
import {CallVault} from "../src/CallVault.sol";
import {CallVaultDeployer} from "../src/CallVaultDeployer.sol";
import {CallVaultFactory} from "../src/CallVaultFactory.sol";
import {CallTriggerAdapter} from "../src/CallTriggerAdapter.sol";
import {VersionZero} from "./VersionZero.sol";

/// @notice Fresh BSC custom-vault stack. Never attaches an existing pool or collateral.
/// @dev Predict the factory with ordinary CREATE before deploying its immutable dependencies.
contract DeploySystem is Script {
    string public constant SPEC_COMMIT = "5949cc7eb99bcb5ac5f679cc710ae456e627f12a";
    address public constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;

    struct Deployment {
        AttestationRegistry registry;
        Call call;
        MerkleDistributor distributor;
        ClearingPool pool;
        CallVaultFactory factory;
        VaultRegistry vaultRegistry;
        CallTriggerAdapter triggerAdapter;
        address flapPortal;
        address vaultPortal;
        address guardian;
        address wbnb;
        address commissionReceiver;
        address deployer;
        address publisher;
        address distributorPublisher;
        uint64 startNonce;
    }

    function run() external returns (Deployment memory) {
        return deploy(vm.envOr("ATTESTATION_PUBLISHER", msg.sender));
    }

    function flapPortalFor(uint256 chainId) public pure returns (address) {
        require(chainId == 56, "Only BSC mainnet protocol validated");
        return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    }

    function wbnbFor(uint256 chainId) public pure returns (address) {
        require(chainId == 56, "Only BSC mainnet protocol validated");
        return 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    }

    function deploy(address publisher) public returns (Deployment memory d) {
        d.flapPortal = flapPortalFor(block.chainid);
        d.wbnb = wbnbFor(block.chainid);
        d.vaultPortal = block.chainid == 56
            ? 0x90497450f2a706f1951b5bdda52B4E5d16f34C06
            : 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        d.guardian = block.chainid == 56
            ? 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b
            : 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        require(d.flapPortal.code.length != 0 && d.vaultPortal.code.length != 0, "Missing protocol code");
        require(d.wbnb.code.length != 0 && TRIGGER_SERVICE.code.length != 0, "Missing asset or service code");
        require(publisher != address(0), "Zero publisher");
        d.publisher = publisher;
        d.distributorPublisher = vm.envOr("DISTRIBUTOR_PUBLISHER", publisher);
        d.commissionReceiver = vm.envOr("COMMISSION_RECEIVER", publisher);
        VersionZero.Texts memory texts = VersionZero.load();
        VersionZero.requireDeployable(texts);

        vm.startBroadcast();
        (, d.deployer,) = vm.readCallers();
        d.startNonce = vm.getNonce(d.deployer);
        address predictedFactory = vm.computeCreateAddress(d.deployer, d.startNonce + 5);
        d.vaultRegistry = new VaultRegistry(predictedFactory);
        d.registry = new AttestationRegistry(publisher, texts.termsHash, texts.attestationHash);
        d.call = new Call();
        d.distributor = new MerkleDistributor(d.distributorPublisher);
        d.pool = new ClearingPool(d.call, address(d.distributor), d.registry, d.vaultRegistry);
        d.factory = new CallVaultFactory(
            d.flapPortal, d.vaultRegistry, d.pool, address(d.distributor), d.wbnb, d.commissionReceiver
        );
        require(address(d.factory) == predictedFactory, "Factory CREATE prediction mismatch");
        d.call.setPool(address(d.pool));
        d.distributor.setPool(address(d.pool));
        d.triggerAdapter = new CallTriggerAdapter(address(d.factory), TRIGGER_SERVICE);
        vm.stopBroadcast();
        _assertDependencies(d);
        _writeManifest(d, texts);
    }

    function _assertDependencies(Deployment memory d) internal view {
        require(address(d.factory) == vm.computeCreateAddress(d.deployer, d.startNonce + 5), "Factory nonce mismatch");
        require(d.vaultRegistry.isFactory(address(d.factory)), "Registry writer mismatch");
        require(address(d.factory.registry()) == address(d.vaultRegistry), "Factory registry mismatch");
        require(address(d.pool.vaultRegistry()) == address(d.vaultRegistry), "Pool registry mismatch");
        require(address(d.factory.pool()) == address(d.pool), "Factory pool mismatch");
        require(d.factory.merkleDistributor() == address(d.distributor), "Factory distributor mismatch");
        require(d.factory.portal() == d.flapPortal, "Price portal mismatch");
        require(d.factory.wbnb() == d.wbnb, "Collateral mismatch");
        require(d.factory.commissionReceiver() == d.commissionReceiver, "Commission mismatch");
        require(d.call.pool() == address(d.pool) && d.distributor.pool() == address(d.pool), "Satellite mismatch");
        require(address(d.pool.call()) == address(d.call), "Pool call mismatch");
        require(d.pool.distributor() == address(d.distributor), "Pool distributor mismatch");
        require(address(d.pool.attestations()) == address(d.registry), "Pool attestations mismatch");
        require(d.triggerAdapter.factory() == address(d.factory), "Trigger factory mismatch");
        require(address(d.triggerAdapter.triggerService()) == TRIGGER_SERVICE, "Trigger service mismatch");
        require(d.factory.vaultDeployer().factory() == address(d.factory), "CREATE helper caller mismatch");
        require(address(d.factory.vaultDeployer().pool()) == address(d.pool), "CREATE helper pool mismatch");
        require(
            d.factory.vaultDeployer().merkleDistributor() == address(d.distributor), "CREATE helper recipient mismatch"
        );
        require(d.factory.vaultDeployer().portal() == d.flapPortal, "CREATE helper portal mismatch");
        require(d.factory.vaultDeployer().wbnb() == d.wbnb, "CREATE helper wrapper mismatch");
        CallVaultDeployer helper = d.factory.vaultDeployer();
        require(helper.protocolFeeReceiver() == d.commissionReceiver, "Protocol receiver mismatch");
        require(helper.vaultCreationCodeHash() == keccak256(type(CallVault).creationCode), "Vault code mismatch");
        bytes memory first = helper.creationCodePart1().code;
        bytes memory second = helper.creationCodePart2().code;
        require(first.length <= 16_001 && second.length <= 16_001, "Code data chunk too large");
        require(first.length != 0 && second.length != 0 && first[0] == 0 && second[0] == 0, "Code data prefix mismatch");
        bytes memory storedCode = new bytes(first.length + second.length - 2);
        address part1 = helper.creationCodePart1();
        address part2 = helper.creationCodePart2();
        assembly {
            let output := add(storedCode, 32)
            extcodecopy(part1, output, 1, sub(mload(first), 1))
            extcodecopy(part2, add(output, sub(mload(first), 1)), 1, sub(mload(second), 1))
        }
        require(keccak256(storedCode) == helper.vaultCreationCodeHash(), "Code data contents mismatch");
        require(type(CallVault).creationCode.length + 8 * 32 <= 49_152, "Vault exceeds EIP3860");
        require(type(CallVaultFactory).creationCode.length + 6 * 32 <= 49_152, "Factory exceeds EIP3860");
        require(address(helper).code.length <= 24_576, "CREATE helper exceeds EIP170");
        require(address(d.factory).code.length <= 24_576, "Factory exceeds EIP170");
    }

    function _writeManifest(Deployment memory d, VersionZero.Texts memory texts) internal {
        string memory key = "custom-vault-deployment";
        vm.serializeString(key, "status", "planned");
        vm.serializeString(key, "specCommit", SPEC_COMMIT);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "factoryNonce", d.startNonce + 5);
        vm.serializeAddress(key, "deployer", d.deployer);
        vm.serializeAddress(key, "flapPortal", d.flapPortal);
        vm.serializeAddress(key, "vaultPortal", d.vaultPortal);
        vm.serializeAddress(key, "guardian", d.guardian);
        vm.serializeAddress(key, "vaultFactory", address(d.factory));
        vm.serializeAddress(key, "vaultDeployer", address(d.factory.vaultDeployer()));
        CallVaultDeployer helper = d.factory.vaultDeployer();
        vm.serializeAddress(key, "creationCodePart1", helper.creationCodePart1());
        vm.serializeAddress(key, "creationCodePart2", helper.creationCodePart2());
        vm.serializeBytes32(key, "creationCodePart1Hash", helper.creationCodePart1().codehash);
        vm.serializeBytes32(key, "creationCodePart2Hash", helper.creationCodePart2().codehash);
        vm.serializeBytes32(key, "vaultCreationCodeHash", helper.vaultCreationCodeHash());
        vm.serializeAddress(key, "protocolFeeReceiver", helper.protocolFeeReceiver());
        vm.serializeAddress(key, "vaultRegistry", address(d.vaultRegistry));
        vm.serializeAddress(key, "clearingPool", address(d.pool));
        vm.serializeAddress(key, "call", address(d.call));
        vm.serializeAddress(key, "merkleDistributor", address(d.distributor));
        vm.serializeAddress(key, "attestationRegistry", address(d.registry));
        vm.serializeAddress(key, "wbnb", d.wbnb);
        vm.serializeAddress(key, "commissionReceiver", d.commissionReceiver);
        vm.serializeAddress(key, "triggerService", TRIGGER_SERVICE);
        vm.serializeAddress(key, "triggerAdapter", address(d.triggerAdapter));
        vm.serializeBytes32(key, "termsHash", texts.termsHash);
        vm.serializeBytes32(key, "attestationHash", texts.attestationHash);
        // A dry run cannot certify the platform UI or any transaction broadcast result.
        vm.serializeString(key, "feeAcceptanceScope", "creator10+protocol10+processorCommission");
        vm.serializeBool(key, "platformV21Verified", false);
        string memory json = vm.serializeBool(key, "feeAcceptanceVerified", false);
        vm.createDir("deployments", true);
        vm.writeFile(string.concat("deployments/", vm.toString(block.chainid), ".planned.json"), json);
    }
}
