// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";

/// @notice Immutable identity root with one factory writer and one binding per token.
contract VaultRegistry is IVaultRegistry {
    address public immutable factory;
    mapping(address => address) private _vaultOf;
    event VaultBound(address indexed memeToken, address indexed vault);
    error NotFactory(address caller);
    error AlreadyBound(address memeToken, address vault);
    error ZeroMemeToken();
    error ZeroVault();
    error ZeroFactory(uint256 slot);

    // The factory is predicted using CREATE and deployed after its dependencies.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroFactory(0);
        factory = factory_;
    }

    function bind(address memeToken, address vault) external {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        if (memeToken == address(0)) revert ZeroMemeToken();
        if (vault == address(0)) revert ZeroVault();
        address bound = _vaultOf[memeToken];
        if (bound != address(0)) revert AlreadyBound(memeToken, bound);
        _vaultOf[memeToken] = vault;
        emit VaultBound(memeToken, vault);
    }

    function isFactory(address candidate) public view returns (bool) {
        return candidate == factory;
    }

    function factories() external view returns (address[] memory list) {
        list = new address[](1);
        list[0] = factory;
    }

    function vaultOf(address memeToken) external view returns (address) {
        return _vaultOf[memeToken];
    }
}
