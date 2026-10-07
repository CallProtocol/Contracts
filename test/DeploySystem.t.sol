// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeploySystem} from "../script/DeploySystem.s.sol";
import {CallVault} from "../src/CallVault.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {VersionZero} from "../script/VersionZero.sol";

contract DeploySystemTest is Test {
    DeploySystem internal deploymentScript;
    DeploySystem.Deployment internal d;
    uint64 internal initialNonce;

    function setUp() public {
        vm.chainId(56);
        VersionZero.Texts memory texts = VersionZero.load();
        vm.setEnv("ATTESTATION_V0_TERMS_HASH", vm.toString(texts.termsHash));
        vm.setEnv("ATTESTATION_V0_ATTESTATION_HASH", vm.toString(texts.attestationHash));
        vm.etch(0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0, hex"00");
        vm.etch(0x90497450f2a706f1951b5bdda52B4E5d16f34C06, hex"00");
        vm.etch(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, hex"00");
        vm.etch(0xcf4EE25035CF883895110f367F5BA8172416a7F9, hex"00");
        deploymentScript = new DeploySystem();
        initialNonce = vm.getNonce(DEFAULT_SENDER);
        d = deploymentScript.deploy(DEFAULT_SENDER);
    }

    function test_plainCreateNoncePredictionAndAllDependencies() public view {
        assertEq(d.deployer, DEFAULT_SENDER);
        assertEq(address(d.vaultRegistry), vm.computeCreateAddress(d.deployer, initialNonce));
        assertEq(address(d.registry), vm.computeCreateAddress(d.deployer, initialNonce + 1));
        assertEq(address(d.call), vm.computeCreateAddress(d.deployer, initialNonce + 2));
        assertEq(address(d.distributor), vm.computeCreateAddress(d.deployer, initialNonce + 3));
        assertEq(address(d.pool), vm.computeCreateAddress(d.deployer, initialNonce + 4));
        assertEq(address(d.factory), vm.computeCreateAddress(d.deployer, initialNonce + 5));
        assertEq(address(d.triggerAdapter), vm.computeCreateAddress(d.deployer, initialNonce + 8));
        assertTrue(d.vaultRegistry.isFactory(address(d.factory)));
        assertFalse(d.vaultRegistry.isFactory(d.deployer));
        assertEq(address(d.factory.registry()), address(d.vaultRegistry));
        assertEq(address(d.factory.pool()), address(d.pool));
        assertEq(d.factory.merkleDistributor(), address(d.distributor));
        assertEq(d.factory.portal(), d.flapPortal);
        assertEq(d.factory.wbnb(), d.wbnb);
        assertEq(d.factory.commissionReceiver(), d.commissionReceiver);
        assertEq(d.factory.vaultDeployer().protocolFeeReceiver(), d.commissionReceiver);
        address helper = address(d.factory.vaultDeployer());
        assertEq(d.factory.vaultDeployer().creationCodePart1(), vm.computeCreateAddress(helper, 1));
        assertEq(d.factory.vaultDeployer().creationCodePart2(), vm.computeCreateAddress(helper, 2));
        assertEq(address(d.pool.vaultRegistry()), address(d.vaultRegistry));
        assertEq(d.call.pool(), address(d.pool));
        assertEq(d.distributor.pool(), address(d.pool));
        assertEq(d.triggerAdapter.factory(), address(d.factory));
    }

    function test_manifestIsPlannedAndPlatformGateUnverified() public view {
        string memory manifest = vm.readFile("deployments/56.planned.json");
        assertEq(vm.parseJsonString(manifest, ".status"), "planned");
        assertEq(vm.parseJsonString(manifest, ".specCommit"), "5949cc7eb99bcb5ac5f679cc710ae456e627f12a");
        assertEq(vm.parseJsonAddress(manifest, ".vaultFactory"), address(d.factory));
        assertEq(vm.parseJsonAddress(manifest, ".vaultRegistry"), address(d.vaultRegistry));
        assertEq(vm.parseJsonUint(manifest, ".factoryNonce"), initialNonce + 5);
        assertEq(vm.parseJsonAddress(manifest, ".protocolFeeReceiver"), d.commissionReceiver);
        assertEq(vm.parseJsonAddress(manifest, ".creationCodePart1"), d.factory.vaultDeployer().creationCodePart1());
        assertEq(vm.parseJsonAddress(manifest, ".creationCodePart2"), d.factory.vaultDeployer().creationCodePart2());
        assertEq(
            vm.parseJsonBytes32(manifest, ".creationCodePart1Hash"),
            d.factory.vaultDeployer().creationCodePart1().codehash
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".creationCodePart2Hash"),
            d.factory.vaultDeployer().creationCodePart2().codehash
        );
        assertEq(vm.parseJsonBytes32(manifest, ".vaultCreationCodeHash"), keccak256(type(CallVault).creationCode));
        assertFalse(vm.parseJsonBool(manifest, ".platformV21Verified"));
        assertFalse(vm.parseJsonBool(manifest, ".feeAcceptanceVerified"));
    }

    function test_satelliteBindingsAreLocked() public {
        vm.prank(d.deployer);
        vm.expectRevert();
        d.call.setPool(address(0xbeef));
        vm.prank(d.deployer);
        vm.expectRevert();
        d.distributor.setPool(address(0xbeef));
    }

    function test_unsupportedChainRejectedBeforeDeployment() public {
        vm.chainId(1);
        vm.expectRevert();
        deploymentScript.deploy(DEFAULT_SENDER);
    }
}
