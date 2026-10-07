// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {CallVaultFactory} from "../src/CallVaultFactory.sol";
import {CallVault} from "../src/CallVault.sol";
import {CallVaultDeployer} from "../src/CallVaultDeployer.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {WNativeMock} from "./helpers/WNativeMock.sol";

contract QuoteConfigurationStub {
    uint8 public enabled = 1;
    bool public fails;

    function configure(uint8 value, bool fail) external {
        enabled = value;
        fails = fail;
    }

    function getQuoteTokenConfiguration(address)
        external
        view
        returns (IPortalTypes.QuoteTokenConfiguration memory config)
    {
        require(!fails);
        config.enabled = enabled;
    }
}

contract OfficialPortalTransactionStub {
    function createThenFail(CallVaultFactory factory, IVaultPortalTypes.NewTokenV6WithVaultParams calldata p) external {
        (bool success,) = factory.onBeforeNewTokenV6WithVault(p);
        require(success);
        factory.newVault(address(7777), p.quoteToken, msg.sender, p.vaultData);
        revert("Token deployment or first buy failed");
    }
}

contract CallVaultFactoryTest is Test {
    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    CallVaultFactory factory;
    VaultRegistry registry;
    QuoteConfigurationStub portal;
    address quote;
    address commission = address(123);

    function setUp() public {
        vm.chainId(56);
        portal = new QuoteConfigurationStub();
        quote = address(new WNativeMock());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new VaultRegistry(predicted);
        factory = new CallVaultFactory(
            address(portal), registry, IClearingPool(address(portal)), address(portal), quote, commission
        );
        assertEq(address(factory), predicted);
    }

    function params() internal view returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p) {
        p.vaultFactory = address(factory);
        p.vaultData = abi.encode(uint16(1));
        p.quoteToken = quote;
        p.dividendToken = quote;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000;
        p.mktBps = 10_000;
        p.commissionReceiver = commission;
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
    }

    function authorize(IVaultPortalTypes.NewTokenV6WithVaultParams memory p) internal {
        vm.prank(VAULT_PORTAL);
        (bool success, string memory reason) = factory.onBeforeNewTokenV6WithVault(p);
        assertTrue(success, reason);
    }

    function test_predictedTokenWithNoCodeBindsImmediately() public {
        authorize(params());
        address predictedVault = vm.computeCreateAddress(address(factory.vaultDeployer()), 3);
        address token = address(7777);
        assertEq(token.code.length, 0);
        vm.prank(VAULT_PORTAL);
        address vault = factory.newVault(token, quote, address(999), abi.encode(uint16(1)));
        assertEq(vault, predictedVault);
        assertEq(registry.vaultOf(token), vault);
        assertTrue(factory.isVault(vault));
        assertEq(factory.vaultsCreated(), 1);
        assertEq(CallVault(payable(vault)).creator(), address(999));
        assertEq(CallVault(payable(vault)).protocolFeeReceiver(), commission);
    }

    function test_nativeQuoteCreatesWrappedCollateral() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = params();
        p.quoteToken = address(0);
        p.dividendToken = address(0);
        authorize(p);
        vm.prank(VAULT_PORTAL);
        address vault = factory.newVault(address(7777), address(0), address(999), p.vaultData);
        assertEq(CallVault(payable(vault)).collateralToken(), quote);
        assertEq(CallVault(payable(vault)).vaultQuoteToken(), address(0));
    }

    function test_callerAndGuardianCannotCreateOrAuthorize() public {
        vm.expectRevert();
        factory.onBeforeNewTokenV6WithVault(params());
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert();
        factory.newVault(address(7), quote, address(9), abi.encode(uint16(1)));
    }

    function test_missingAuthorizationAndGenericHookReject() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Missing creation authorization"));
        factory.newVault(address(7), quote, address(9), abi.encode(uint16(1)));
        vm.prank(VAULT_PORTAL);
        (bool ok,) = factory.onBeforeLaunch("");
        assertFalse(ok);
    }

    function test_authorizationMatchesAndIsSingleUse() public {
        authorize(params());
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Creation authorization mismatch"));
        factory.newVault(address(7), address(0), address(9), abi.encode(uint16(1)));
        vm.prank(VAULT_PORTAL);
        factory.newVault(address(7), quote, address(9), abi.encode(uint16(1)));
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Missing creation authorization"));
        factory.newVault(address(8), quote, address(9), abi.encode(uint16(1)));
    }

    function test_duplicateBindingRollsBackVaultAndPreservesAuthorization() public {
        authorize(params());
        vm.prank(VAULT_PORTAL);
        address first = factory.newVault(address(7), quote, address(9), abi.encode(uint16(1)));
        authorize(params());
        uint64 nonce = vm.getNonce(address(factory.vaultDeployer()));
        vm.prank(VAULT_PORTAL);
        vm.expectRevert();
        factory.newVault(address(7), quote, address(9), abi.encode(uint16(1)));
        assertEq(vm.getNonce(address(factory.vaultDeployer())), nonce);
        assertEq(factory.vaultsCreated(), 1);
        assertEq(registry.vaultOf(address(7)), first);
        vm.prank(VAULT_PORTAL);
        factory.newVault(address(8), quote, address(9), abi.encode(uint16(1)));
    }

    function test_quoteChecksFailClosed() public {
        assertTrue(factory.isQuoteTokenSupported(quote));
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(13)));
        portal.configure(0, false);
        assertFalse(factory.isQuoteTokenSupported(quote));
        portal.configure(1, true);
        assertFalse(factory.isQuoteTokenSupported(quote));
    }

    function test_quoteConfigurationIgnoresNewEnumValuesButRejectsInvalidReturnShape() public {
        bytes memory callData = abi.encodeWithSelector(bytes4(keccak256("getQuoteTokenConfiguration(address)")), quote);
        vm.mockCall(address(portal), callData, abi.encode(uint256(1), uint256(29), uint256(29), uint256(7), uint256(0)));
        assertTrue(factory.isQuoteTokenSupported(quote));
        vm.mockCall(address(portal), callData, abi.encode(uint256(1)));
        assertFalse(factory.isQuoteTokenSupported(quote));
        vm.mockCall(
            address(portal),
            callData,
            abi.encode(uint256(1), uint256(29), uint256(29), uint256(7), uint256(0), uint256(0))
        );
        assertFalse(factory.isQuoteTokenSupported(quote));
        vm.mockCallRevert(address(portal), callData, hex"deadbeef");
        assertFalse(factory.isQuoteTokenSupported(quote));
    }

    function test_laterPortalFailureRollsBackEveryCreationEffect() public {
        vm.etch(VAULT_PORTAL, address(new OfficialPortalTransactionStub()).code);
        uint64 nonce = vm.getNonce(address(factory.vaultDeployer()));
        vm.expectRevert(bytes("Token deployment or first buy failed"));
        OfficialPortalTransactionStub(VAULT_PORTAL).createThenFail(factory, params());
        assertEq(registry.vaultOf(address(7777)), address(0));
        assertEq(factory.vaultsCreated(), 0);
        assertEq(vm.getNonce(address(factory.vaultDeployer())), nonce);
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Missing creation authorization"));
        factory.newVault(address(7777), quote, address(9), abi.encode(uint16(1)));
    }

    function test_deployerHasImmutableFactoryAndCannotBeCalledByOthers() public {
        assertEq(factory.vaultDeployer().factory(), address(factory));
        assertEq(address(factory.vaultDeployer().pool()), address(factory.pool()));
        assertEq(factory.vaultDeployer().merkleDistributor(), factory.merkleDistributor());
        assertEq(factory.vaultDeployer().portal(), factory.portal());
        assertEq(factory.vaultDeployer().wbnb(), factory.wbnb());
        address helper = address(factory.vaultDeployer());
        vm.expectRevert(bytes(unicode"Only factory"));
        CallVaultDeployer(helper).deploy(address(7777), quote, address(9));
    }

    function test_codeDataStoresExactVaultCreationCode() public view {
        CallVaultDeployer helper = factory.vaultDeployer();
        bytes memory first = helper.creationCodePart1().code;
        bytes memory second = helper.creationCodePart2().code;
        assertEq(helper.creationCodePart1(), vm.computeCreateAddress(address(helper), 1));
        assertEq(helper.creationCodePart2(), vm.computeCreateAddress(address(helper), 2));
        assertLe(first.length, 16_001);
        assertLe(second.length, 16_001);
        assertEq(uint8(first[0]), 0);
        assertEq(uint8(second[0]), 0);
        bytes memory code = new bytes(first.length + second.length - 2);
        for (uint256 i = 1; i < first.length; i++) {
            code[i - 1] = first[i];
        }
        for (uint256 i = 1; i < second.length; i++) {
            code[first.length + i - 2] = second[i];
        }
        assertEq(code, type(CallVault).creationCode);
        assertEq(helper.vaultCreationCodeHash(), keccak256(code));
        assertEq(helper.protocolFeeReceiver(), commission);
        assertLe(type(CallVaultFactory).creationCode.length + 6 * 32, 49_152);
        assertLe(code.length + 8 * 32, 49_152);
    }

    function test_zeroProtocolReceiverRejected() public {
        vm.expectRevert(bytes(unicode"Invalid protocol fee receiver"));
        new CallVaultDeployer(IClearingPool(address(portal)), address(portal), address(portal), quote, address(0));
    }

    function test_vaultCannotBeItsOwnProtocolReceiver() public {
        address predictedHelper = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address predictedVault = vm.computeCreateAddress(predictedHelper, 3);
        CallVaultDeployer helper = new CallVaultDeployer(
            IClearingPool(address(portal)), address(portal), address(portal), quote, predictedVault
        );
        vm.expectRevert(bytes(unicode"Invalid protocol receiver"));
        helper.deploy(address(7777), quote, address(9));
        assertEq(predictedVault.code.length, 0);
        assertEq(vm.getNonce(address(helper)), 3);
    }

    function test_createFailureRollsBackAuthorizationAndHelperNonce() public {
        authorize(params());
        uint64 nonce = vm.getNonce(address(factory.vaultDeployer()));
        address predictedVault = vm.computeCreateAddress(address(factory.vaultDeployer()), nonce);
        vm.prank(VAULT_PORTAL);
        vm.expectRevert();
        factory.newVault(address(0), quote, address(9), abi.encode(uint16(1)));
        assertEq(predictedVault.code.length, 0);
        assertEq(vm.getNonce(address(factory.vaultDeployer())), nonce);
        assertEq(factory.vaultsCreated(), 0);
        vm.prank(VAULT_PORTAL);
        assertEq(factory.newVault(address(7777), quote, address(9), abi.encode(uint16(1))), predictedVault);
    }

    function test_productionContractsFitEip170() public {
        assertLe(address(factory).code.length, 24_576, "Factory EIP-170");
        assertLe(address(factory.vaultDeployer()).code.length, 24_576, "Deployer EIP-170");
        authorize(params());
        vm.prank(VAULT_PORTAL);
        address vault = factory.newVault(address(7777), quote, address(9), abi.encode(uint16(1)));
        assertLe(vault.code.length, 24_576, "Vault EIP-170");
    }

    function test_vaultDataRequiresExactCanonicalEncoding() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = params();
        p.vaultData = abi.encode(uint256(65_537));
        vm.prank(VAULT_PORTAL);
        (bool ok,) = factory.onBeforeNewTokenV6WithVault(p);
        assertFalse(ok);
        p.vaultData = bytes.concat(abi.encode(uint16(1)), hex"00");
        vm.prank(VAULT_PORTAL);
        (ok,) = factory.onBeforeNewTokenV6WithVault(p);
        assertFalse(ok);
    }

    function test_staticProbeRejectsWithoutWriting() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p;
        p.vaultFactory = address(factory);
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        vm.prank(VAULT_PORTAL);
        (bool called, bytes memory result) =
            address(factory).staticcall(abi.encodeCall(factory.onBeforeNewTokenV6WithVault, (p)));
        assertTrue(called);
        (bool ok,) = abi.decode(result, (bool, string));
        assertFalse(ok);
    }

    function testFuzz_wrongTaxDurationAlwaysRejected(uint64 duration) public {
        vm.assume(duration != 3_153_600_000);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = params();
        p.taxDuration = duration;
        vm.prank(VAULT_PORTAL);
        (bool ok,) = factory.onBeforeNewTokenV6WithVault(p);
        assertFalse(ok);
    }

    function test_validationRejectsAllEconomicMutations() public {
        for (uint256 i; i < 15; i++) {
            IVaultPortalTypes.NewTokenV6WithVaultParams memory p = params();
            if (i == 0) p.buyTaxRate++;
            if (i == 1) p.sellTaxRate++;
            if (i == 2) p.mktBps--;
            if (i == 3) p.deflationBps = 1;
            if (i == 4) p.dividendBps = 1;
            if (i == 5) p.lpBps = 1;
            if (i == 6) p.minimumShareBalance = 1;
            if (i == 7) p.dividendToken = address(3);
            if (i == 8) p.commissionReceiver = address(3);
            if (i == 9) p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_V3_PERMIT;
            if (i == 10) p.vaultData = abi.encode(uint16(2));
            if (i == 11) p.dexThresh = IPortalCommonTypes.DexThreshType.TWO_THIRDS;
            if (i == 12) p.migratorType = IPortalTypes.MigratorType.V3_MIGRATOR;
            if (i == 13) p.dexId = IPortalTypes.DEXId.DEX1;
            if (i == 14) p.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_LOW;
            vm.prank(VAULT_PORTAL);
            (bool ok,) = factory.onBeforeNewTokenV6WithVault(p);
            assertFalse(ok);
        }
    }
}
