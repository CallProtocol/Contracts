// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";

contract CallInterfaceTest is Test {
    Call private token;
    ClearingPool private pool;
    MerkleDistributor private distributor;

    function setUp() public {
        AttestationRegistry registry =
            new AttestationRegistry(address(this), keccak256("terms"), keccak256("attestation"));
        token = new Call();
        distributor = new MerkleDistributor(address(this));
        FactoryStub factory = new FactoryStub();
        pool = new ClearingPool(token, address(distributor), registry, factory.registry());
        token.setPool(address(pool));
        distributor.setPool(address(pool));
    }

    function test_poolExposesTheCallTokenThroughTheNewSelector() public view {
        (bool ok, bytes memory data) = address(pool).staticcall(abi.encodeWithSignature("call()"));
        assertTrue(ok, "Call token discovery must succeed");
        assertEq(abi.decode(data, (address)), address(token));
    }

    function test_distributorDiscoversTheSameCallToken() public view {
        (bool ok, bytes memory data) = address(distributor).staticcall(abi.encodeWithSignature("call()"));
        assertTrue(ok, "Distributor must discover the bound Call token");
        assertEq(abi.decode(data, (address)), address(token));
    }

    function test_retiredTokenDiscoverySelectorIsNotAnAlias() public view {
        (bool poolOk,) = address(pool).staticcall(abi.encodeWithSelector(bytes4(0x53e3d859)));
        (bool distributorOk,) = address(distributor).staticcall(abi.encodeWithSelector(bytes4(0x53e3d859)));
        assertFalse(poolOk, "Retired pool selector must be rejected");
        assertFalse(distributorOk, "Retired distributor selector must be rejected");
    }
}
