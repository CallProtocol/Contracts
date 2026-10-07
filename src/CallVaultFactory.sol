// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CallVaultDeployer} from "./CallVaultDeployer.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultPortalTypes} from "./flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "./flap/IPortal.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";

/// @notice Non-upgradeable factory. Only the canonical VaultPortal may authorize and create projects.
contract CallVaultFactory is VaultFactoryBaseV2 {
    address public immutable portal;
    VaultRegistry public immutable registry;
    IClearingPool public immutable pool;
    address public immutable merkleDistributor;
    address public immutable wbnb;
    address public immutable commissionReceiver;
    CallVaultDeployer public immutable vaultDeployer;
    uint256 public vaultsCreated;
    mapping(address => bool) public isVault;
    bytes32 private _authorization;
    bool private _authorized;

    event VaultCreated(address indexed memeToken, address indexed vault, address indexed creator, address quoteToken);

    constructor(
        address portal_,
        VaultRegistry registry_,
        IClearingPool pool_,
        address distributor_,
        address wbnb_,
        address commissionReceiver_
    ) {
        if (portal_ == address(0)) revert(unicode"Invalid Portal");
        if (address(registry_).code.length == 0) revert(unicode"Invalid registry");
        if (address(pool_).code.length == 0) revert(unicode"Invalid pool");
        if (distributor_.code.length == 0) {
            revert(unicode"Invalid distributor");
        }
        if (wbnb_.code.length == 0) revert(unicode"Invalid WBNB");
        if (commissionReceiver_ == address(0)) revert(unicode"Invalid commission receiver");
        if (!registry_.isFactory(address(this))) revert(unicode"Invalid registry");
        portal = portal_;
        registry = registry_;
        pool = pool_;
        merkleDistributor = distributor_;
        wbnb = wbnb_;
        commissionReceiver = commissionReceiver_;
        vaultDeployer = new CallVaultDeployer(pool_, distributor_, portal_, wbnb_, commissionReceiver_);
    }

    modifier onlyVaultPortal() {
        if (msg.sender != _getVaultPortal()) revert(unicode"Only VaultPortal");
        _;
    }

    function vaultPortal() external view returns (address) {
        return _getVaultPortal();
    }

    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.1";
    }

    function isQuoteTokenSupported(address quoteToken) public view override returns (bool) {
        if (quoteToken == address(0)) return true;
        if (quoteToken.code.length == 0) return false;
        // Decode only the enabled word: deployed Portal may add enum members before
        // the pinned interface does, and irrelevant enum decoding must not reject quotes.
        bytes memory payload =
            abi.encodeWithSelector(bytes4(keccak256("getQuoteTokenConfiguration(address)")), quoteToken);
        bool ok;
        uint256 size;
        uint256 enabled;
        address target = portal;
        assembly {
            let output := mload(0x40)
            ok := staticcall(200000, target, add(payload, 32), mload(payload), output, 160)
            size := returndatasize()
            enabled := mload(output)
        }
        return ok && size == 160 && enabled == 1;
    }

    function onBeforeNewTokenV6WithVault(IVaultPortalTypes.NewTokenV6WithVaultParams calldata p)
        external
        override
        onlyVaultPortal
        returns (bool success, string memory reason)
    {
        // The protocol probes this selector with a staticcall and invalid dummy parameters.
        // Every rejection must precede writes so that probe can read a normal rejection result.
        if (p.vaultFactory != address(this)) return (false, unicode"Wrong factory");
        if (!_validData(p.vaultData)) return (false, unicode"Expected config version 1");
        if (!isQuoteTokenSupported(p.quoteToken)) {
            return (false, unicode"Quote disabled or unreadable");
        }
        if (p.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) {
            return (false, unicode"Taxed V3 required");
        }
        if (p.buyTaxRate != 300 || p.sellTaxRate != 300) {
            return (false, unicode"Buy and sell tax must be 300 bps");
        }
        if (p.taxDuration != 3_153_600_000) {
            return (false, unicode"100 year tax required");
        }
        if (
            p.mktBps != 10_000 || p.deflationBps != 0 || p.dividendBps != 0 || p.lpBps != 0
                || p.minimumShareBalance != 0
        ) return (false, unicode"All tax must fund vault");
        if (p.dividendToken != p.quoteToken) {
            return (false, unicode"Dividend token must equal quote");
        }
        if (p.commissionReceiver != commissionReceiver) {
            return (false, unicode"Wrong commission receiver");
        }
        if (
            p.dexThresh != IPortalCommonTypes.DexThreshType.FOUR_FIFTHS
                || p.migratorType != IPortalTypes.MigratorType.V2_MIGRATOR || p.dexId != IPortalTypes.DEXId.DEX0
                || p.lpFeeProfile != IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD
        ) return (false, unicode"Unsupported DEX profile");
        _authorization = keccak256(abi.encode(p.quoteToken, p.vaultData));
        _authorized = true;
        return (true, "");
    }

    function onBeforeLaunch(bytes calldata) external view override onlyVaultPortal returns (bool, string memory) {
        return (false, unicode"Full V6 validation required");
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        onlyVaultPortal
        returns (address vault)
    {
        if (!_authorized) revert(unicode"Missing creation authorization");
        if (_authorization != keccak256(abi.encode(quoteToken, vaultData))) {
            revert(unicode"Creation authorization mismatch");
        }
        // Consume before CREATE and registry calls; any downstream failure rolls it back atomically.
        delete _authorized;
        delete _authorization;
        vault = vaultDeployer.deploy(taxToken, quoteToken, creator);
        registry.bind(taxToken, vault);
        isVault[vault] = true;
        vaultsCreated++;
        emit VaultCreated(taxToken, vault, creator, quoteToken);
    }

    function _validData(bytes calldata data) private pure returns (bool) {
        if (data.length != 32) return false;
        uint256 version;
        assembly { version := calldataload(data.offset) }
        return version == 1;
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"Non-upgradeable Call vault; revenue: Pool 80%, creator 10%, fixed protocol fee 10%; processor commission is separate";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor("configVersion", "uint16", unicode"Configuration version, must be 1", 0);
    }

    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](5);
        policies[0] = FactoryPolicy("buyTaxRate", "eq", abi.encode(uint16(300)), "Buy tax 300 bps");
        policies[1] = FactoryPolicy("sellTaxRate", "eq", abi.encode(uint16(300)), "Sell tax 300 bps");
        policies[2] = FactoryPolicy("taxDuration", "eq", abi.encode(uint64(3_153_600_000)), "100 year tax duration");
        policies[3] = FactoryPolicy("mktBps", "eq", abi.encode(uint16(10_000)), "100% to vault");
        policies[4] = FactoryPolicy("tokenVersion", "eq", abi.encode(uint8(6)), "Taxed V3");
    }
}
