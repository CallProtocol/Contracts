// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FlapCustomVaultCapabilitiesTest} from "./FlapCustomVaultCapabilities.t.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";
import {IVaultPortal, IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {VaultRegistry} from "../../src/VaultRegistry.sol";
import {Call} from "../../src/Call.sol";
import {CallVault} from "../../src/CallVault.sol";
import {CallVaultFactory} from "../../src/CallVaultFactory.sol";
import {IFlapTaxTokenV3} from "../../src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor, PackedFeeConfigV2} from "../../src/flap/ITaxProcessor.sol";
import {CallTriggerAdapter} from "../../src/CallTriggerAdapter.sol";
import {IFlapTriggerService} from "../../src/flap/IFlapTriggerService.sol";
import {console2} from "forge-std/Test.sol";

contract FlapCustomVaultForkTest is FlapCustomVaultCapabilitiesTest {
    VaultRegistry internal registry;
    CallVaultFactory internal factory;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function setUp() public override {
        super.setUp();
        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 5);
        registry = new VaultRegistry(predictedFactory);
        AttestationRegistry attestations =
            new AttestationRegistry(address(this), keccak256("terms"), keccak256("attestation"));
        call = new Call();
        distributor = new MerkleDistributor(address(this));
        pool = new ClearingPool(call, address(distributor), attestations, registry);
        factory = new CallVaultFactory(
            ForkConfigBsc.FLAP_PORTAL, registry, pool, address(distributor), WBNB, makeAddr("call-commission")
        );
        assertEq(address(factory), predictedFactory);
        call.setPool(address(pool));
        distributor.setPool(address(pool));
    }

    function test_e2eNativeCreationBindingAndActualCollateralMint() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        CallVault vault = CallVault(payable(registry.vaultOf(token)));
        _identity(token, vault, address(0), WBNB);
        _open(vault);
        vm.deal(address(this), 1 ether);
        uint256 gasBeforeReceive = gasleft();
        (bool sent,) = address(vault).call{value: 1 ether, gas: 1_000_000}("");
        uint256 receiveGas = gasBeforeReceive - gasleft();
        assertLt(receiveGas, 1_000_000);
        console2.log("Native receive recognition gas", receiveGas);
        assertTrue(sent);
        assertEq(address(vault).balance, 1 ether, "receive must not wrap");
        uint256 minted = vault.processRevenue();
        assertGt(minted, 0);
        assertEq(IERC20(WBNB).balanceOf(address(pool)), 0.8 ether);
        assertEq(vault.creatorAccrued(), 0.1 ether);
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0.2 ether);
        uint256 id = pool.seriesIdOf(token, WBNB, vault.seriesExpiry());
        assertEq(call.balanceOf(address(distributor), id), minted);
    }

    function test_e2eEnabledErc20CreationBindingAndActualCollateralMint() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.quoteToken = ForkConfigBsc.GMEB;
        p.dividendToken = p.quoteToken;
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault(p);
        CallVault vault = CallVault(payable(registry.vaultOf(token)));
        _identity(token, vault, p.quoteToken, p.quoteToken);
        _open(vault);
        deal(p.quoteToken, address(this), 10 ether);
        IERC20(p.quoteToken).transfer(address(vault), 10 ether);
        (bool ping,) = address(vault).call("");
        assertTrue(ping);
        assertEq(vault.accountedQuote(), 10 ether);
        uint256 minted = vault.processRevenue();
        assertGt(minted, 0);
        assertEq(IERC20(p.quoteToken).balanceOf(address(pool)), 8 ether);
        assertEq(vault.creatorAccrued(), 1 ether);
    }

    function test_e2eProtocolFailureRollsBackRegistryFactoryAndVault() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.antiFarmerDuration = 366 days;
        address predictedToken = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), ForkConfigBsc.FLAP_PORTAL, p.salt, ForkConfigBsc.vanityInitCodeHash()
                        )
                    )
                )
            )
        );
        address predictedVault = vm.computeCreateAddress(address(factory.vaultDeployer()), 3);
        vm.prank(creator, creator);
        (bool ok,) = VAULT_PORTAL.call{value: 1 gwei}(abi.encodeCall(IVaultPortal.newTokenV6WithVault, (p)));
        assertFalse(ok);
        assertEq(registry.vaultOf(predictedToken), address(0));
        assertEq(predictedVault.code.length, 0);
        assertEq(factory.vaultsCreated(), 0);
    }

    function test_e2eFirstBuyFailureLeavesNoVaultOrBinding() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.quoteToken = ForkConfigBsc.GMEB;
        p.dividendToken = p.quoteToken;
        p.quoteAmt = 1 ether;
        // No allowance: the real quote transfer for the first buy must fail atomically.
        deal(p.quoteToken, creator, 1 ether);
        vm.prank(creator, creator);
        (bool ok,) = VAULT_PORTAL.call(abi.encodeCall(IVaultPortal.newTokenV6WithVault, (p)));
        assertFalse(ok);
        address predictedToken = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), ForkConfigBsc.FLAP_PORTAL, p.salt, ForkConfigBsc.vanityInitCodeHash()
                        )
                    )
                )
            )
        );
        assertEq(registry.vaultOf(predictedToken), address(0));
        assertEq(predictedToken.code.length, 0);
        assertEq(factory.vaultsCreated(), 0);
        assertEq(vm.computeCreateAddress(address(factory.vaultDeployer()), 3).code.length, 0);
    }

    function test_e2eNativeRealFirstBuyTaxDispatchEntersPool() public {
        _firstBuyTax(false);
    }

    function test_e2eErc20RealFirstBuyTaxDispatchEntersPool() public {
        _firstBuyTax(true);
    }

    function test_realServiceRequestFeeAndLiveVaultCallbackBudget() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: 1 gwei}(p);
        CallVault vault = CallVault(payable(registry.vaultOf(token)));
        IFlapTriggerService service = IFlapTriggerService(0xcf4EE25035CF883895110f367F5BA8172416a7F9);
        CallTriggerAdapter adapter = new CallTriggerAdapter(address(factory), address(service));
        assertEq(service.getMaxCallbackGas(), 2_000_000);
        uint256 fee = service.getFee();
        vm.deal(address(this), 10 ether);
        uint256 id = adapter.schedule{value: fee}(address(vault), 0);
        IFlapTriggerService.TriggerRequest memory request = service.getRequest(id);
        assertEq(request.requester, address(adapter));
        assertEq(request.feePaid, fee);
        assertEq(request.executeAfter, block.timestamp);
        _callback(adapter, service, id);
        assertEq(vault.lastSampleAt(), block.timestamp);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= 24; ++i) {
            vm.warp(start + i * 1 hours);
            assertTrue(vault.sampleTwap());
        }
        id = adapter.schedule{value: fee}(address(vault), 1);
        _callback(adapter, service, id);
        assertGt(vault.strike(), 0);
        uint256 gasBeforeReceive = gasleft();
        (bool sent,) = address(vault).call{value: 1 ether, gas: 1_000_000}("");
        uint256 receiveGas = gasBeforeReceive - gasleft();
        assertLt(receiveGas, 1_000_000);
        console2.log("Native receive recognition gas", receiveGas);
        assertTrue(sent);
        id = adapter.schedule{value: fee}(address(vault), 2);
        _callback(adapter, service, id);
        assertEq(IERC20(WBNB).balanceOf(address(pool)), 0.8 ether);
        assertEq(address(adapter).balance, 0);
    }

    function _callback(CallTriggerAdapter adapter, IFlapTriggerService service, uint256 id) internal {
        // Service requester/fee state is real. Impersonation isolates the receiver's live gas path
        // from the backend role; this is not evidence of an off-chain backend delivery.
        vm.prank(address(service));
        uint256 beforeGas = gasleft();
        (bool ok,) = address(adapter).call{gas: 2_000_000}(abi.encodeCall(adapter.trigger, (id)));
        uint256 used = beforeGas - gasleft();
        assertTrue(ok);
        assertLe(used, 2_000_000);
        console2.log("Live Vault Trigger callback gas", used);
    }

    function _firstBuyTax(bool erc20) internal {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p = _params(address(factory));
        p.quoteAmt = erc20 ? 10 ether : 0.1 ether;
        if (erc20) {
            p.quoteToken = ForkConfigBsc.GMEB;
            p.dividendToken = p.quoteToken;
            deal(p.quoteToken, creator, p.quoteAmt);
            vm.prank(creator, creator);
            IERC20(p.quoteToken).approve(VAULT_PORTAL, p.quoteAmt);
        }
        vm.prank(creator, creator);
        address token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: erc20 ? 0 : p.quoteAmt}(p);
        CallVault vault = CallVault(payable(registry.vaultOf(token)));
        assertGt(IERC20(token).balanceOf(creator), 0, "first buy must execute");
        ITaxProcessor processor = ITaxProcessor(IFlapTaxTokenV3(token).taxProcessor());
        processor.dispatch();
        (uint256 available, bool exact) = vault.inTransit();
        assertTrue(exact);
        assertGt(available, 0, "real first buy tax must reach vault");
        _open(vault);
        uint256 minted = vault.processRevenue();
        assertGt(minted, 0);
        assertGt(IERC20(vault.collateralToken()).balanceOf(address(pool)), 0);
        assertGt(vault.creatorAccrued(), 0);
    }

    function _identity(address token, CallVault vault, address quote, address collateral) internal view {
        assertGt(token.code.length, 0);
        assertGt(address(vault).code.length, 0);
        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.vaultsCreated(), 1);
        assertEq(vault.taxToken(), token);
        assertEq(vault.creator(), creator);
        assertEq(vault.protocolFeeReceiver(), factory.commissionReceiver());
        assertEq(vault.vaultQuoteToken(), quote);
        assertEq(vault.collateralToken(), collateral);
        assertEq(address(vault.pool()), address(pool));
        assertEq(vault.merkleDistributor(), address(distributor));
        assertLe(address(vault).code.length, 24_576, "Vault must fit EIP170");
        assertLe(address(factory).code.length, 24_576, "Factory must fit EIP170");
        assertLe(address(factory.vaultDeployer()).code.length, 24_576, "CREATE helper must fit EIP170");
        IFlapTaxTokenV3 tax = IFlapTaxTokenV3(token);
        assertEq(tax.buyTaxRate(), 300);
        assertEq(tax.sellTaxRate(), 300);
        ITaxProcessor processor = ITaxProcessor(tax.taxProcessor());
        assertEq(processor.marketAddress(), address(vault));
        assertEq(processor.getQuoteToken(), collateral);
        assertEq(processor.commissionReceiver(), factory.commissionReceiver());
        PackedFeeConfigV2 memory config = processor.feeConfigV2();
        assertEq(config.marketBps, 10_000);
        assertEq(config.deflationBps, 0);
        assertEq(config.dividendBps, 0);
        assertEq(config.lpBps, 0);
    }

    function _open(CallVault vault) internal {
        uint256 start = block.timestamp;
        for (uint256 i; i <= 24; ++i) {
            vm.warp(start + i * 1 hours);
            assertTrue(vault.sampleTwap());
        }
        (uint256 status, uint256 price) = vault.twap();
        assertEq(status, 0);
        (, bool opened) = vault.openSeries();
        assertTrue(opened);
        assertEq(vault.strike(), price * 8 / 10);
        assertGe(vault.seriesExpiry(), block.timestamp + 7 days);
        assertEq(vault.seriesExpiry() % 7 days, 45 hours);
    }
}
