// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CallVault} from "./CallVault.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";

/// @dev STOP-prefixed immutable data: execution cannot reach the stored creation code.
contract VaultCreationCodeData {
    constructor(bytes memory data) {
        require(data.length <= 16_000, unicode"Creation code chunk too large");
        bytes memory runtime = bytes.concat(hex"00", data);
        assembly {
            return(add(runtime, 32), mload(runtime))
        }
    }
}

/// @notice Immutable CREATE helper keeps Vault initcode outside the Factory runtime.
contract CallVaultDeployer {
    address public immutable factory;
    IClearingPool public immutable pool;
    address public immutable merkleDistributor;
    address public immutable portal;
    address public immutable wbnb;
    address public immutable protocolFeeReceiver;
    address public immutable creationCodePart1;
    address public immutable creationCodePart2;
    bytes32 public immutable vaultCreationCodeHash;

    constructor(IClearingPool pool_, address distributor_, address portal_, address wbnb_, address receiver_) {
        require(receiver_ != address(0), unicode"Invalid protocol fee receiver");
        factory = msg.sender;
        pool = pool_;
        merkleDistributor = distributor_;
        portal = portal_;
        wbnb = wbnb_;
        protocolFeeReceiver = receiver_;
        bytes memory code = type(CallVault).creationCode;
        require(code.length <= 32_000, unicode"Vault creation code too large");
        vaultCreationCodeHash = keccak256(code);
        uint256 firstLength = code.length > 16_000 ? 16_000 : code.length;
        bytes memory first = new bytes(firstLength);
        bytes memory second = new bytes(code.length - firstLength);
        assembly {
            mcopy(add(first, 32), add(code, 32), firstLength)
            mcopy(add(second, 32), add(add(code, 32), firstLength), mload(second))
        }
        creationCodePart1 = address(new VaultCreationCodeData(first));
        creationCodePart2 = address(new VaultCreationCodeData(second));
    }

    function deploy(address token, address quote, address creator) external returns (address vault) {
        require(msg.sender == factory, unicode"Only factory");
        address part1 = creationCodePart1;
        address part2 = creationCodePart2;
        uint256 firstLength = part1.code.length - 1;
        uint256 secondLength = part2.code.length - 1;
        bytes memory arguments = abi.encode(
            pool,
            merkleDistributor,
            portal,
            token,
            quote == address(0) ? wbnb : quote,
            creator,
            quote == address(0),
            protocolFeeReceiver
        );
        bytes memory initcode = new bytes(firstLength + secondLength + arguments.length);
        require(initcode.length <= 49_152, unicode"Vault initcode exceeds EIP3860");
        assembly {
            let output := add(initcode, 32)
            extcodecopy(part1, output, 1, firstLength)
            extcodecopy(part2, add(output, firstLength), 1, secondLength)
            mcopy(add(add(output, firstLength), secondLength), add(arguments, 32), mload(arguments))
            vault := create(0, output, mload(initcode))
            if iszero(vault) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
