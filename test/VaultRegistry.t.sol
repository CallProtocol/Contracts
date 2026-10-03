// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

contract VaultRegistryTest is Test {
    VaultRegistry registry;
    address writer = address(123);

    function setUp() public {
        registry = new VaultRegistry(writer);
    }

    function test_singleImmutableWriter() public view {
        assertEq(registry.factory(), writer);
        assertTrue(registry.isFactory(writer));
        assertFalse(registry.isFactory(address(this)));
        address[] memory writers = registry.factories();
        assertEq(writers.length, 1);
        assertEq(writers[0], writer);
    }

    function test_zeroWriterRejected() public {
        vm.expectRevert();
        new VaultRegistry(address(0));
    }

    function test_registryHasOnlyBindingWriteSurface() public view {
        string[] memory expected = new string[](1);
        expected[0] = "bind(address,address)";
        WriteSurface.assertIsExactly("out/VaultRegistry.sol/VaultRegistry.json", expected);
    }

    function test_onlyWriterAndOnlyOneBinding() public {
        vm.expectRevert();
        registry.bind(address(1), address(2));
        vm.prank(writer);
        registry.bind(address(1), address(2));
        vm.prank(writer);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.AlreadyBound.selector, address(1), address(2)));
        registry.bind(address(1), address(3));
        assertEq(registry.vaultOf(address(1)), address(2));
    }

    function test_zeroAddressesRejected() public {
        vm.prank(writer);
        vm.expectRevert(VaultRegistry.ZeroMemeToken.selector);
        registry.bind(address(0), address(2));
        vm.prank(writer);
        vm.expectRevert(VaultRegistry.ZeroVault.selector);
        registry.bind(address(1), address(0));
    }

    function testFuzz_vaultOfNeverReverts(address token) public view {
        assertEq(registry.vaultOf(token), address(0));
    }
}
