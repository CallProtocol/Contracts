// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {VaultRegistry} from "../../src/VaultRegistry.sol";

/// @notice Pool tests use the production registry and replace only its factory writer.
contract FactoryStub {
    VaultRegistry public immutable registry;

    constructor() {
        registry = new VaultRegistry(address(this));
    }

    function bind(address memeToken, address vault) external {
        registry.bind(memeToken, vault);
    }
}
