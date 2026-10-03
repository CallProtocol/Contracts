// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {WarrantVaultDeployer} from "./WarrantVaultDeployer.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultPortalTypes} from "./flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "./flap/IPortal.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";

/// @notice Non-upgradeable factory. Only the canonical VaultPortal may authorize and create projects.
contract WarrantVaultFactory is VaultFactoryBaseV2 {
    address public immutable portal;
    VaultRegistry public immutable registry;
    IClearingPool public immutable pool;
    address public immutable merkleDistributor;
    address public immutable wbnb;
    address public immutable commissionReceiver;
    WarrantVaultDeployer public immutable vaultDeployer;
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
        if (portal_ == address(0)) revert(unicode"Invalid Portal / Portal地址无效");
        if (address(registry_).code.length == 0) revert(unicode"Invalid registry / 身份注册表无效");
        if (address(pool_).code.length == 0) revert(unicode"Invalid pool / 清算池无效");
        if (distributor_.code.length == 0) revert(unicode"Invalid distributor / 分发合约无效");
        if (wbnb_.code.length == 0) revert(unicode"Invalid WBNB / WBNB地址无效");
        if (commissionReceiver_ == address(0)) revert(unicode"Invalid commission receiver / 佣金收款人无效");
        if (!registry_.isFactory(address(this))) revert(unicode"Invalid registry / 身份注册表无效");
        portal = portal_;
        registry = registry_;
        pool = pool_;
        merkleDistributor = distributor_;
        wbnb = wbnb_;
        commissionReceiver = commissionReceiver_;
        vaultDeployer = new WarrantVaultDeployer(pool_, distributor_, portal_, wbnb_, commissionReceiver_);
    }

    modifier onlyVaultPortal() {
        if (msg.sender != _getVaultPortal()) revert(unicode"Only VaultPortal / 仅官方VaultPortal可调用");
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
        if (p.vaultFactory != address(this)) return (false, unicode"Wrong factory / 工厂不匹配");
        if (!_validData(p.vaultData)) return (false, unicode"Expected config version 1 / 配置版本须为1");
        if (!isQuoteTokenSupported(p.quoteToken)) {
            return (false, unicode"Quote disabled or unreadable / 计价币未启用或不可读取");
        }
        if (p.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) {
            return (false, unicode"Taxed V3 required / 须使用税币V3");
        }
        if (p.buyTaxRate != 300 || p.sellTaxRate != 300) {
            return (false, unicode"Buy and sell tax must be 300 bps / 买卖税须为300基点");
        }
        if (p.taxDuration != 3_153_600_000) return (false, unicode"100 year tax required / 税期须为100年");
        if (
            p.mktBps != 10_000 || p.deflationBps != 0 || p.dividendBps != 0 || p.lpBps != 0
                || p.minimumShareBalance != 0
        ) return (false, unicode"All tax must fund vault / 税收须全部进入金库");
        if (p.dividendToken != p.quoteToken) {
            return (false, unicode"Dividend token must equal quote / 分红币须等于计价币");
        }
        if (p.commissionReceiver != commissionReceiver) {
            return (false, unicode"Wrong commission receiver / 手续费收款人不匹配");
        }
        if (
            p.dexThresh != IPortalCommonTypes.DexThreshType.FOUR_FIFTHS
                || p.migratorType != IPortalTypes.MigratorType.V2_MIGRATOR || p.dexId != IPortalTypes.DEXId.DEX0
                || p.lpFeeProfile != IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD
        ) return (false, unicode"Unsupported DEX profile / 不支持的DEX配置");
        _authorization = keccak256(abi.encode(p.quoteToken, p.vaultData));
        _authorized = true;
        return (true, "");
    }

    function onBeforeLaunch(bytes calldata) external view override onlyVaultPortal returns (bool, string memory) {
        return (false, unicode"Full V6 validation required / 须使用完整V6校验");
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        onlyVaultPortal
        returns (address vault)
    {
        if (!_authorized) revert(unicode"Missing creation authorization / 缺少创建授权");
        if (_authorization != keccak256(abi.encode(quoteToken, vaultData))) {
            revert(unicode"Creation authorization mismatch / 创建授权不匹配");
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
            unicode"Non-upgradeable Warrant vault; revenue: Pool 80%, creator 10%, fixed protocol fee 10%; processor commission is separate / 不可升级权证金库，收入分配池80%、创建者10%、固定协议费10%，处理器佣金另计";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor(
            "configVersion", "uint16", unicode"Configuration version, must be 1 / 配置版本，须为1", 0
        );
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
