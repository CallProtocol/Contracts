// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IVaultPortal, IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../../src/flap/IPortal.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";

/// @dev Test-only probe. A successful control launch must precede conclusions about hooks.
contract V21CapabilityFactory {
    address public constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    bool public immutable enforceAuthorization;
    bool public immutable reject;
    bytes32 public authorized;
    uint256 public hookCalls;
    uint256 public vaultCalls;
    uint256 public tokenCodeSize;
    bytes32 public fullParamsHash;
    address public lastToken;
    address public lastCreator;
    address public lastVault;

    constructor(bool enforceAuthorization_, bool reject_) {
        enforceAuthorization = enforceAuthorization_;
        reject = reject_;
    }

    function factorySpecVersion() external pure returns (string memory) {
        return "v2.1";
    }

    function isQuoteTokenSupported(address) external pure returns (bool) {
        return true;
    }

    function onBeforeNewTokenV6WithVault(IVaultPortalTypes.NewTokenV6WithVaultParams calldata p)
        external
        returns (bool, string memory)
    {
        require(msg.sender == VAULT_PORTAL, "Only VaultPortal");
        if (reject || p.taxDuration != 3_153_600_000) return (false, "V21 probe rejected tax duration");
        hookCalls++;
        fullParamsHash = keccak256(abi.encode(p));
        authorized = keccak256(abi.encode(p.quoteToken, p.vaultData));
        return (true, "");
    }

    // Deliberately reject the generic path: it cannot certify taxDuration.
    function onBeforeLaunch(bytes calldata) external pure returns (bool, string memory) {
        return (false, "Full V6 hook required");
    }

    function newVault(address token, address quote, address creator, bytes calldata data)
        external
        returns (address vault)
    {
        require(msg.sender == VAULT_PORTAL, "Only VaultPortal");
        if (enforceAuthorization) {
            require(authorized == keccak256(abi.encode(quote, data)), "Missing full V6 authorization");
        }
        delete authorized;
        vaultCalls++;
        tokenCodeSize = token.code.length;
        lastToken = token;
        lastCreator = creator;
        vault = address(new V21CapabilityVault(quote));
        lastVault = vault;
    }
}

contract V21CapabilityVault {
    address public immutable vaultQuoteToken;

    constructor(address quote) {
        vaultQuoteToken = quote;
    }

    function description() external pure returns (string memory) {
        return "Call V6 capability probe";
    }

    function vaultSpecVersion() external pure returns (string memory) {
        return "v3";
    }

    receive() external payable {}
}

/// @notice Release gate, intentionally fails when the real protocol lacks the required capability.
/// @dev No latest fallback or skip: missing archive configuration is not PASS evidence.
contract FlapCustomVaultCapabilitiesTest is Test {
    address internal constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    uint256 internal constant SNAPSHOT_BLOCK = 125_316_166;
    address internal creator;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("RPC_BSC"), vm.envOr("FLAP_CAPABILITY_BLOCK", SNAPSHOT_BLOCK));
        assertEq(block.chainid, 56);
        creator = makeAddr("v21-capability-creator");
        vm.deal(creator, 1 ether);
        console2.log("BSC capability block", block.number);
        console2.log(
            "VaultPortal implementation",
            address(
                uint160(
                    uint256(vm.load(VAULT_PORTAL, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
                )
            )
        );
    }

    function test_controlV21LaunchReachesFactoryBeforeTokenDeployment() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(false, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        assertGt(token.code.length, 0);
        assertEq(factory.vaultCalls(), 1);
        assertEq(factory.tokenCodeSize(), 0);
        assertEq(factory.lastToken(), token);
        assertEq(factory.lastCreator(), creator);
        console2.log("full V6 hook calls", factory.hookCalls());
    }

    function test_gateFullHookWritesAndCallbackConsumesAuthorization() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(true, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        assertGt(token.code.length, 0);
        assertEq(factory.hookCalls(), 1, "full V6 hook must execute");
        assertEq(factory.fullParamsHash(), keccak256(abi.encode(p)), "full payload must match");
        assertEq(factory.authorized(), bytes32(0), "authorization must be consumed");
    }

    function test_gateFullHookRejectionIsRespected() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(false, true);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "V21 probe rejected tax duration"));
        IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        assertEq(factory.vaultCalls(), 0);
    }

    function test_gateWrongTaxDurationCannotBypassFullHook() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(false, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.taxDuration = 365 days;
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "V21 probe rejected tax duration"));
        IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        assertEq(factory.vaultCalls(), 0);
    }

    function test_gateV21FactorySupportsEnabledErc20Quote() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(true, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.quoteToken = ForkConfigBsc.GMEB;
        p.dividendToken = p.quoteToken;
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault(p);
        assertGt(token.code.length, 0);
        assertEq(factory.hookCalls(), 1);
        assertEq(factory.fullParamsHash(), keccak256(abi.encode(p)));
        assertEq(V21CapabilityVault(payable(factory.lastVault())).vaultQuoteToken(), p.quoteToken);
    }

    function test_gateTokenDeploymentFailureRollsBackVaultAndAuthorization() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(true, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.antiFarmerDuration = 366 days;
        address predictedVault = vm.computeCreateAddress(address(factory), 1);
        vm.prank(creator, creator);
        (bool ok,) = VAULT_PORTAL.call{value: 1 gwei}(abi.encodeCall(IVaultPortal.newTokenV6WithVault, (p)));
        assertFalse(ok, "protocol must reject excessive anti-farmer duration");
        assertEq(factory.hookCalls(), 0, "hook writes must roll back");
        assertEq(factory.vaultCalls(), 0, "callback writes must roll back");
        assertEq(factory.authorized(), bytes32(0));
        assertEq(predictedVault.code.length, 0, "CREATE must roll back");
    }

    function test_gateOtherTokenVersionCannotCreateVault() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(true, false);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.tokenVersion = IPortalTypes.TokenVersion(5);
        vm.prank(creator, creator);
        (bool ok,) = VAULT_PORTAL.call{value: 1 gwei}(abi.encodeCall(IVaultPortal.newTokenV6WithVault, (p)));
        assertFalse(ok);
        assertEq(factory.vaultCalls(), 0);
    }

    function test_gateLegacyEntryCannotCreateWithoutFullAuthorization() public {
        V21CapabilityFactory factory = new V21CapabilityFactory(true, false);
        IVaultPortalTypes.NewTaxTokenWithVaultParams memory p;
        p.name = "Legacy bypass probe";
        p.symbol = "OLD";
        p.taxRate = 300;
        p.taxDuration = 365 days;
        p.mktBps = 10_000;
        p.vaultFactory = address(factory);
        p.vaultData = abi.encode(uint16(1));
        p.dexThresh = IPortalCommonTypes.DexThreshType(ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED);
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.salt = _params(address(factory)).salt;
        vm.prank(creator, creator);
        (bool ok,) = VAULT_PORTAL.call{value: 1 gwei}(abi.encodeCall(IVaultPortal.newTaxTokenWithVault, (p)));
        assertFalse(ok, "legacy entry cannot bypass full V6 authorization");
        assertEq(factory.vaultCalls(), 0);
    }

    function _params(address factory) internal returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p) {
        p.name = "Call V21 Capability";
        p.symbol = "WV21";
        p.meta = "ipfs://call-v21-capability";
        p.dexThresh = IPortalCommonTypes.DexThreshType(ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED);
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.tokenVersion = IPortalTypes.TokenVersion(ForkConfigBsc.FLAP_TOKEN_VERSION_TAXED_V3);
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000;
        p.mktBps = 10_000;
        p.commissionReceiver = makeAddr("call-commission");
        p.vaultFactory = factory;
        p.vaultData = abi.encode(uint16(1));
        bytes32 initCodeHash = ForkConfigBsc.vanityInitCodeHash();
        address portal = ForkConfigBsc.FLAP_PORTAL;
        bytes32 salt;
        // High seed avoids the heavily occupied low salt range; check code as well as suffix.
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, portal))
            mstore(add(ptr, 0x35), initCodeHash)
            for { let i := 0x77617272616e743231 } lt(i, 0x77617272616e843231) { i := add(i, 1) } {
                mstore(add(ptr, 0x15), i)
                let predicted := and(keccak256(ptr, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(predicted, 0xffff), 0x7777) {
                    if iszero(extcodesize(predicted)) {
                        salt := i
                        break
                    }
                }
            }
        }
        require(salt != 0, "No free vanity salt found");
        p.salt = salt;
    }
}
