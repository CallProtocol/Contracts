// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {WarrantVault} from "../src/WarrantVault.sol";
import {WarrantVaultHarness} from "./helpers/WarrantVaultHarness.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {Warrant} from "../src/Warrant.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {WNativeMock} from "./helpers/WNativeMock.sol";
import {
    StockToken,
    PartialDebitStockToken,
    GatedStockToken,
    SenderPaysFeeStockToken,
    IssuerBurnableUnreadableStockToken,
    PreUpdateReentrantStockToken
} from "./helpers/StockToken.sol";

contract ProtocolDecimalToken is StockToken {
    uint8 immutable _precision;

    constructor(uint8 precision) {
        _precision = precision;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }
}

contract ProtocolCallbackDepositToken is StockToken {
    uint256 public returnedAmount;
    bool public ping;

    function configure(uint256 amount, bool shouldPing) external {
        returnedAmount = amount;
        ping = shouldPing;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == address(0) || to != address(0xfee)) return;
        _mint(from, returnedAmount);
        if (ping) {
            (bool ok,) = from.call("");
            require(ok, "ping failed");
        }
    }
}

contract WarrantProtocolFeeTest is Test {
    address constant RECEIVER = address(0xfee);
    address constant CREATOR = address(0xcafe);
    address constant MEME = address(0x123);
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    ClearingPool pool;
    MerkleDistributor distributor;
    FactoryStub factory;
    FlapPortalStub portal;
    StockToken quote;
    WarrantVaultHarness vault;

    function setUp() public {
        vm.chainId(56);
        Warrant warrant = new Warrant();
        distributor = new MerkleDistributor(address(this));
        factory = new FactoryStub();
        AttestationRegistry registry =
            new AttestationRegistry(address(this), keccak256("terms"), keccak256("attestation"));
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));
        portal = new FlapPortalStub();
        quote = new StockToken();
        vault = _deploy(address(quote), false);
    }

    function _deploy(address token, bool native) private returns (WarrantVaultHarness target) {
        target = new WarrantVaultHarness(pool, address(distributor), address(portal), token, token, CREATOR, native);
        factory.bind(token, address(target));
    }

    function _open(WarrantVaultHarness target) private {
        target.harnessOpenSeries(1e18, uint64(block.timestamp + 8 days));
    }

    function test_unsyncedRevenueReservesFeeInTransit() public {
        quote.mint(address(vault), 100);
        (uint256 available, bool exact) = vault.inTransit();
        assertTrue(exact);
        assertEq(available, 90);
        assertEq(vault.protocolAccrued(), 0);
        vault.sync();
        assertEq(vault.protocolAccrued(), 10);
        vault.sync();
        assertEq(vault.protocolAccrued(), 10);
    }

    function test_claimBeforeSeriesAndProcessingLeaves801010() public {
        quote.mint(address(vault), 100);
        vm.prank(address(0xbeef));
        assertEq(vault.claimProtocolFee(), 10);
        assertEq(quote.balanceOf(RECEIVER), 10);
        assertEq(quote.balanceOf(address(0xbeef)), 0);
        _open(vault);
        assertEq(vault.processRevenue(), 80);
        assertEq(vault.creatorAccrued(), 10);
        assertEq(vault.protocolClaimed(), 10);
        assertEq(vault.claimProtocolFee(), 0);
        vault.sync();
        assertEq(vault.protocolAccrued(), 0);
    }

    function test_processThenClaimBothReserves() public {
        _open(vault);
        quote.mint(address(vault), 100);
        assertEq(vault.processRevenue(), 80);
        assertEq(vault.creatorAccrued(), 10);
        assertEq(vault.protocolAccrued(), 10);
        assertEq(vault.claimCreatorFee(), 10);
        assertEq(vault.claimProtocolFee(), 10);
        assertEq(quote.balanceOf(address(pool)), 80);
        assertEq(quote.balanceOf(address(vault)), 0);
    }

    function test_tinyDepositsCarryRemainderAcrossClaims() public {
        for (uint256 i; i < 9; ++i) {
            quote.mint(address(vault), 1);
            vault.sync();
            assertEq(vault.claimProtocolFee(), 0);
        }
        quote.mint(address(vault), 1);
        (uint256 available,) = vault.inTransit();
        assertEq(available, 9);
        assertEq(vault.claimProtocolFee(), 1);
        quote.mint(address(vault), 10);
        assertEq(vault.claimProtocolFee(), 1);
        assertEq(vault.protocolClaimed(), 2);
    }

    function test_nativeReceiveReservesWithoutWrappingAndNoDoubleCharge() public {
        WNativeMock wrapped = new WNativeMock();
        WarrantVaultHarness native = _deploy(address(wrapped), true);
        vm.deal(address(this), 110);
        (bool ok,) = address(native).call{value: 100, gas: 1_000_000}("");
        assertTrue(ok);
        assertEq(native.protocolAccrued(), 10);
        assertEq(wrapped.balanceOf(address(native)), 0);
        wrapped.deposit{value: 10}();
        wrapped.transfer(address(native), 10);
        (uint256 available,) = native.inTransit();
        assertEq(available, 99);
        assertEq(native.claimProtocolFee(), 11);
        native.sync();
        assertEq(native.protocolAccrued(), 0);
        assertEq(wrapped.balanceOf(RECEIVER), 11);
        assertEq(native.accountedNative(), 0);
    }

    function test_partialDebitKeepsUnpaidReserve() public {
        PartialDebitStockToken token = new PartialDebitStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        token.setHalfDebit(true);
        assertEq(target.claimProtocolFee(), 5);
        assertEq(target.protocolAccrued(), 5);
        assertEq(target.protocolClaimed(), 5);
        token.setHalfDebit(false);
        assertEq(target.claimProtocolFee(), 5);
        assertEq(target.protocolClaimed(), 10);
    }

    function test_zeroDebitLeavesReserveAndBaselineIntact() public {
        PartialDebitStockToken token = new PartialDebitStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        token.setDebitBps(0);
        assertEq(target.claimProtocolFee(), 0);
        assertEq(target.protocolAccrued(), 10);
        assertEq(target.protocolClaimed(), 0);
        target.sync();
        assertEq(target.protocolAccrued(), 10);
    }

    function test_partialProcessingAccruesCreatorOnlyByActualDebit() public {
        PartialDebitStockToken token = new PartialDebitStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        _open(target);
        token.mint(address(target), 100);
        token.setHalfDebit(true);
        assertEq(target.processRevenue(), 40);
        assertEq(target.creatorAccrued(), 5);
        assertEq(target.protocolAccrued(), 10);
        (uint256 available,) = target.inTransit();
        assertEq(available, 45);
        assertEq(available + target.creatorAccrued() + target.protocolAccrued(), token.balanceOf(address(target)));
    }

    function test_protocolClaimBlocksCrossEntryReentrancyBeforeTokenDebit() public {
        bytes4[3] memory entries = [
            WarrantVault.claimCreatorFee.selector,
            WarrantVault.claimProtocolFee.selector,
            WarrantVault.processRevenue.selector
        ];
        for (uint256 i; i < entries.length; ++i) {
            PreUpdateReentrantStockToken token = new PreUpdateReentrantStockToken();
            WarrantVaultHarness target = _deploy(address(token), false);
            token.mint(address(target), 100);
            token.armReentrancy(address(target), abi.encodeWithSelector(entries[i]));
            assertEq(target.claimProtocolFee(), 10);
            assertEq(token.reentryAttempts(), 1);
            assertFalse(token.reentrySucceeded());
            assertEq(
                token.reentryError(), abi.encodeWithSignature("Error(string)", unicode"Reentrant call / 重入调用")
            );
            assertEq(target.protocolClaimed(), 10);
            assertEq(target.protocolAccrued(), 0);
        }
    }

    function test_claimCallbackSyncCannotRecognizeFeesTwice() public {
        PreUpdateReentrantStockToken token = new PreUpdateReentrantStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        token.armReentrancy(address(target), abi.encodeCall(WarrantVault.sync, ()));
        assertEq(target.claimProtocolFee(), 10);
        assertTrue(token.reentrySucceeded());
        target.sync();
        assertEq(target.protocolAccrued(), 0);
        assertEq(target.accountedQuote(), 90);
    }

    function test_claimRejectsObservableCallbackInflowAtomically() public {
        ProtocolCallbackDepositToken token = new ProtocolCallbackDepositToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        target.sync();
        token.configure(20, false);
        vm.expectRevert(unicode"Quote inflow during claim / 领取期间收入回流");
        target.claimProtocolFee();
        assertEq(token.balanceOf(address(target)), 100);
        assertEq(token.balanceOf(RECEIVER), 0);
        assertEq(target.protocolAccrued(), 10);
        assertEq(target.protocolClaimed(), 0);
        assertEq(target.accountedQuote(), 100);
    }

    function test_claimRejectsAmbiguousCallbackDepositWithQuoteWake() public {
        ProtocolCallbackDepositToken token = new ProtocolCallbackDepositToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        target.sync();
        token.configure(1, true);
        vm.expectRevert(unicode"Quote wake during withdrawal / 提款期间收到币种回调");
        target.claimProtocolFee();
        assertEq(token.balanceOf(address(target)), 100);
        assertEq(token.balanceOf(RECEIVER), 0);
        assertEq(target.protocolAccrued(), 10);
        assertEq(target.protocolClaimed(), 0);
        token.configure(0, false);
        assertEq(target.claimProtocolFee(), 10);
    }

    function test_sixEightAndEighteenDecimalsUseRawUnits() public {
        uint8[3] memory precisions = [uint8(6), uint8(8), uint8(18)];
        for (uint256 i; i < precisions.length; ++i) {
            ProtocolDecimalToken token = new ProtocolDecimalToken(precisions[i]);
            WarrantVaultHarness target = _deploy(address(token), false);
            _open(target);
            uint256 unit = 10 ** precisions[i];
            token.mint(address(target), 100 * unit);
            assertEq(target.processRevenue(), 80 * unit);
            assertEq(target.protocolAccrued(), 10 * unit);
            assertEq(target.creatorAccrued(), 10 * unit);
            assertEq(target.claimProtocolFee(), 10 * unit);
        }
    }

    function test_recipientTransferTaxConsumesOnlyProtocolReserve() public {
        quote.mint(address(vault), 100);
        quote.setTaxBps(2000);
        assertEq(vault.claimProtocolFee(), 10);
        assertEq(quote.balanceOf(RECEIVER), 8);
        assertEq(vault.protocolClaimed(), 10);
        assertEq(quote.balanceOf(address(vault)), 90);
    }

    function test_senderExtraChargeRevertsRatherThanSubsidizingProtocol() public {
        SenderPaysFeeStockToken token = new SenderPaysFeeStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        target.sync();
        token.setSenderFeeBps(1000);
        vm.expectRevert(unicode"Protocol debit exceeds reserve / 协议扣款超过储备");
        target.claimProtocolFee();
        assertEq(target.protocolAccrued(), 10);
        assertEq(target.protocolClaimed(), 0);
        assertEq(token.balanceOf(address(target)), 100);
        assertEq(token.balanceOf(RECEIVER), 0);
    }

    function test_failedClaimRollsBackIncomeRecognitionAndReserve() public {
        GatedStockToken token = new GatedStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        token.setFrozen(true);
        vm.expectRevert(GatedStockToken.IssuerFrozen.selector);
        target.claimProtocolFee();
        assertEq(target.protocolAccrued(), 0);
        assertEq(target.accountedQuote(), 0);
        token.setFrozen(false);
        assertEq(target.claimProtocolFee(), 10);
    }

    function test_businessAbsorbsLossThenReservesAreImpairedProportionally() public {
        IssuerBurnableUnreadableStockToken token = new IssuerBurnableUnreadableStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        _open(target);
        token.mint(address(target), 100);
        target.processRevenue();
        token.mint(address(target), 10);
        target.sync();
        token.adminBurn(address(target), 9);
        target.sync();
        assertEq(target.creatorImpaired(), 0);
        assertEq(target.protocolImpaired(), 0);
        token.adminBurn(address(target), 11);
        target.sync();
        assertEq(target.creatorAccrued(), 4);
        assertEq(target.protocolAccrued(), 6);
        assertEq(target.creatorImpaired(), 6);
        assertEq(target.protocolImpaired(), 5);
        token.mint(address(target), 100);
        target.sync();
        assertEq(target.protocolAccrued(), 16);
        assertEq(target.creatorAccrued(), 4);
        assertEq(target.creatorImpaired(), 6);
        assertEq(target.protocolImpaired(), 5);
    }

    function test_guardianFullTokenWithdrawalPermanentlyImpairsBothReserves() public {
        _open(vault);
        quote.mint(address(vault), 100);
        vault.processRevenue();
        vm.prank(GUARDIAN);
        vault.emergencyWithdrawToken(address(quote), address(0xbabe));
        assertEq(vault.creatorImpaired(), 10);
        assertEq(vault.protocolImpaired(), 10);
        assertEq(vault.protocolAccrued(), 0);
        assertEq(vault.creatorAccrued(), 0);
        assertEq(quote.balanceOf(address(pool)), 80);
        quote.mint(address(vault), 100);
        vault.sync();
        assertEq(vault.protocolAccrued(), 10);
    }

    function test_guardianNativeWithdrawalImpairmentAndFreshRevenue() public {
        WNativeMock wrapped = new WNativeMock();
        WarrantVaultHarness native = _deploy(address(wrapped), true);
        vm.deal(address(this), 200);
        (bool ok,) = address(native).call{value: 100}("");
        assertTrue(ok);
        vm.prank(GUARDIAN);
        native.emergencyWithdrawNative(address(0xbabe));
        assertEq(native.protocolImpaired(), 10);
        assertEq(native.protocolAccrued(), 0);
        (ok,) = address(native).call{value: 100}("");
        assertTrue(ok);
        assertEq(native.protocolAccrued(), 10);
        assertEq(native.protocolImpaired(), 10);
    }

    function test_unreadableBalanceCannotClaimOrChangeReserve() public {
        IssuerBurnableUnreadableStockToken token = new IssuerBurnableUnreadableStockToken();
        WarrantVaultHarness target = _deploy(address(token), false);
        token.mint(address(target), 100);
        target.sync();
        token.setBalanceUnreadable(true);
        vm.expectRevert(unicode"Quote balance unreadable / 收入币余额不可读");
        target.claimProtocolFee();
        assertEq(target.protocolAccrued(), 10);
        (, bool exact) = target.inTransit();
        assertFalse(exact);
    }

    function test_constructorRejectsZeroAndSelfReceiver() public {
        vm.expectRevert(unicode"Invalid protocol receiver / 协议收款地址无效");
        new WarrantVault(pool, address(distributor), address(portal), MEME, address(quote), CREATOR, false, address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(unicode"Invalid protocol receiver / 协议收款地址无效");
        new WarrantVault(pool, address(distributor), address(portal), MEME, address(quote), CREATOR, false, predicted);
    }

    function testFuzz_reserveAndPoolConservation(uint96 amount) public {
        _open(vault);
        quote.mint(address(vault), amount);
        uint256 minted = vault.processRevenue();
        (uint256 available, bool exact) = vault.inTransit();
        assertTrue(exact);
        assertEq(vault.protocolAccrued(), uint256(amount) / 10);
        assertEq(minted + quote.balanceOf(address(vault)), amount);
        assertEq(available + vault.creatorAccrued() + vault.protocolAccrued(), quote.balanceOf(address(vault)));
        assertEq(vault.claimProtocolFee(), uint256(amount) / 10);
        vault.sync();
        assertEq(vault.protocolAccrued(), 0);
    }
}
