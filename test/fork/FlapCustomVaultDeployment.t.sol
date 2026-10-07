// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {DeploySystem} from "../../script/DeploySystem.s.sol";
import {VersionZero} from "../../script/VersionZero.sol";

contract FlapCustomVaultDeploymentForkTest is Test {
    function test_realBscFixedBlockDeploymentSimulationUsesOnlyFreshDependencies() public {
        vm.createSelectFork(vm.envString("RPC_BSC"), vm.envOr("FLAP_CAPABILITY_BLOCK", uint256(125_316_166)));
        assertEq(block.chainid, 56);
        VersionZero.Texts memory texts = VersionZero.load();
        vm.setEnv("ATTESTATION_V0_TERMS_HASH", vm.toString(texts.termsHash));
        vm.setEnv("ATTESTATION_V0_ATTESTATION_HASH", vm.toString(texts.attestationHash));
        DeploySystem deployment = new DeploySystem();
        vm.deal(DEFAULT_SENDER, 100 ether);
        uint64 startNonce = vm.getNonce(DEFAULT_SENDER);
        DeploySystem.Deployment memory d = deployment.deploy(DEFAULT_SENDER);
        assertEq(address(d.factory), vm.computeCreateAddress(DEFAULT_SENDER, startNonce + 5));
        assertEq(address(d.triggerAdapter), vm.computeCreateAddress(DEFAULT_SENDER, startNonce + 8));
        assertEq(d.factory.vaultsCreated(), 0);
        assertTrue(d.vaultRegistry.isFactory(address(d.factory)));
        assertEq(d.factory.vaultDeployer().factory(), address(d.factory));
        assertEq(address(d.factory.pool()), address(d.pool));
        assertEq(d.factory.merkleDistributor(), address(d.distributor));
        assertEq(d.call.pool(), address(d.pool));
        assertEq(d.distributor.pool(), address(d.pool));
        assertEq(d.factory.vaultDeployer().protocolFeeReceiver(), d.commissionReceiver);
        assertLe(d.factory.vaultDeployer().creationCodePart1().code.length, 16_001);
        assertLe(d.factory.vaultDeployer().creationCodePart2().code.length, 16_001);
        assertLe(address(d.factory.vaultDeployer()).code.length, 24_576);
        string memory manifest = vm.readFile("deployments/56.planned.json");
        assertEq(vm.parseJsonAddress(manifest, ".vaultDeployer"), address(d.factory.vaultDeployer()));
        assertFalse(vm.parseJsonBool(manifest, ".platformV21Verified"));
    }
}
