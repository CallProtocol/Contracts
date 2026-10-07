// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CallTriggerAdapter} from "../src/CallTriggerAdapter.sol";
import {CallVault} from "../src/CallVault.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {Call} from "../src/Call.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {MemeToken} from "./helpers/MemeToken.sol";

contract TriggerFactoryStub {
    mapping(address => bool) public isVault;

    function register(address vault) external {
        isVault[vault] = true;
    }
}

/// @notice Exercise production Vault, Registry, Pool, Distributor and Call code under the service's gas budget.
/// @dev The external price Portal and quote token are test fixtures; live service/Portal gas is measured separately.
contract CallTriggerIntegrationTest is Test {
    uint256 constant FEE = 0.0002 ether;
    TriggerFactoryStub factory;
    TriggerServiceStub service;
    CallTriggerAdapter adapter;
    CallVault vault;
    ClearingPool pool;
    Call call;
    StockToken quote;
    FlapPortalStub portal;
    address meme;
    address distributor;

    function setUp() external {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1 ether);
        factory = new TriggerFactoryStub();
        service = new TriggerServiceStub();
        adapter = new CallTriggerAdapter(address(factory), address(service));
        VaultRegistry registry = new VaultRegistry(address(this));
        call = new Call();
        MerkleDistributor distribution = new MerkleDistributor(address(this));
        distributor = address(distribution);
        AttestationRegistry attestations =
            new AttestationRegistry(address(this), keccak256("terms"), keccak256("attestation"));
        pool = new ClearingPool(call, distributor, attestations, registry);
        call.setPool(address(pool));
        distribution.setPool(address(pool));
        quote = new StockToken();
        meme = address(new MemeToken());
        portal = new FlapPortalStub();
        portal.setCurve(meme, address(quote), 5e14);
        vault = new CallVault(
            pool, distributor, address(portal), meme, address(quote), address(123), false, address(0xfee)
        );
        registry.bind(meme, address(vault));
        factory.register(address(vault));
    }

    function _execute(uint16 action, string memory label) private returns (uint256 id) {
        id = adapter.schedule{value: FEE}(address(vault), action);
        vm.warp(service.due(id));
        uint256 gasBefore = gasleft();
        // Explicitly forward the official callback budget, in addition to measuring consumption.
        (bool ok,) = address(service).call{gas: 2_000_000}(abi.encodeCall(service.execute, (id)));
        uint256 used = gasBefore - gasleft();
        assertTrue(ok);
        assertLt(used, 2_000_000);
        emit log_named_uint(label, used);
    }

    function testProductionVaultCallbacksSampleOpenAndDepositWithFeeTokenWithinBudget() external {
        _execute(0, "production initial sampling callback gas");
        assertEq(vault.lastSampleAt(), block.timestamp);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            assertTrue(vault.sampleTwap());
        }
        _execute(1, "production full TWAP and Pool opening callback gas");
        assertGt(vault.strike(), 0);
        uint256 series = pool.seriesIdOf(meme, address(quote), vault.seriesExpiry());
        quote.mint(address(vault), 100 ether);
        quote.setTaxBps(100);
        _execute(2, "production fee-token Pool mint callback gas");
        assertEq(quote.balanceOf(address(pool)), 79.2 ether);
        assertEq(call.balanceOf(distributor, series), 79.2 ether);
        assertEq(vault.creatorAccrued(), 10 ether);
    }

    function testProductionBoundedOracleFailureSkipsWithinBudget() external {
        portal.setMode(FlapPortalStub.Mode.BurnGas);
        uint256 id = _execute(0, "production gas-burning oracle callback gas");
        (,,, CallTriggerAdapter.RequestStatus status) = adapter.requests(id);
        assertEq(uint256(status), uint256(CallTriggerAdapter.RequestStatus.Skipped));
        assertEq(vault.lastSampleAt(), 0);
    }

    function testProductionCollateralTransferFailureWithinBudgetPreservesRetryAndMintBacking() external {
        for (uint256 i; i <= 24; ++i) {
            if (i != 0) vm.warp(block.timestamp + 1 hours);
            assertTrue(vault.sampleTwap());
        }
        _execute(1, "production failure fixture series opening callback gas");
        uint256 series = pool.seriesIdOf(meme, address(quote), vault.seriesExpiry());
        quote.mint(address(vault), 100 ether);
        uint256 id = adapter.schedule{value: FEE}(address(vault), 2);
        // Only the external asset fails: production Vault and Pool execution remain real.
        vm.mockCallRevert(
            address(quote),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(vault), address(pool), 80 ether),
            abi.encodeWithSignature("Error(string)", "quote transfer failed")
        );
        uint256 gasBefore = gasleft();
        (bool ok,) = address(service).call{gas: 2_000_000}(abi.encodeCall(service.execute, (id)));
        uint256 used = gasBefore - gasleft();
        assertFalse(ok);
        assertLt(used, 2_000_000);
        emit log_named_uint("production asset transfer reverted callback gas", used);
        assertEq(adapter.pendingRequest(address(vault), 2), id);
        assertEq(quote.balanceOf(address(pool)), 0);
        assertEq(call.balanceOf(distributor, series), 0);
        assertEq(vault.creatorAccrued(), 0);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(quote),
            abi.encodeWithSignature("approve(address,uint256)", address(pool), 80 ether),
            new bytes(131_072)
        );
        gasBefore = gasleft();
        bytes memory failure;
        (ok, failure) = address(service).call{gas: 2_000_000}(abi.encodeCall(service.execute, (id)));
        used = gasBefore - gasleft();
        assertFalse(ok);
        assertLt(used, 2_000_000);
        assertEq(failure, abi.encodeWithSignature("Error(string)", unicode"Vault action failed"));
        emit log_named_uint("production asset returndata bomb callback gas", used);
        assertEq(adapter.pendingRequest(address(vault), 2), id);
        assertEq(quote.balanceOf(address(pool)), 0);
        vm.clearMockedCalls();
        service.execute(id);
        assertEq(call.balanceOf(distributor, series), 80 ether);
        assertEq(quote.balanceOf(address(pool)), 80 ether);
    }
}

contract TriggerVaultStub {
    uint64 public lastSampleAt;
    uint64 public seriesExpiry;
    uint128 public strike = 1;
    uint256 public openStatus;
    uint256 public revenue = 10;
    bool public exact = true;
    bool public fail;
    bool public sampleAvailable = true;
    uint8 public hostileMode;
    uint256[3] public calls;

    constructor() {
        seriesExpiry = uint64(block.timestamp + 7 days);
    }

    function configure(uint64 last, uint256 status, uint256 amount, bool readable, bool failure) external {
        lastSampleAt = last;
        openStatus = status;
        revenue = amount;
        exact = readable;
        fail = failure;
    }

    function openSeriesStatus() external view returns (uint256, uint64, uint128) {
        return (openStatus, seriesExpiry, strike);
    }

    function inTransit() external view returns (uint256, bool) {
        return (revenue, exact);
    }

    function setSampleAvailable(bool value) external {
        sampleAvailable = value;
    }

    function setHostileMode(uint8 mode) external {
        hostileMode = mode;
    }

    function _hostile() private view {
        uint8 mode = hostileMode;
        assembly {
            if eq(mode, 1) { for {} 1 {} {} }
            // A large return payload must never be copied wholesale by the adapter.
            if eq(mode, 2) {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 131072)
            }
            if eq(mode, 3) { revert(0, 131072) }
            if eq(mode, 4) {
                mstore(0, 2)
                mstore(32, 2)
                return(0, 64)
            }
            if eq(mode, 5) { return(0, 0) }
        }
    }

    function sampleTwap() external returns (bool) {
        _hostile();
        require(!fail, "execution failed");
        if (!sampleAvailable) return false;
        calls[0]++;
        lastSampleAt = uint64(block.timestamp);
        return true;
    }

    function openSeries() external returns (uint256, bool) {
        _hostile();
        require(!fail, "execution failed");
        calls[1]++;
        openStatus = 1;
        return (1, true);
    }

    function processRevenue() external returns (uint256) {
        _hostile();
        require(!fail, "execution failed");
        calls[2]++;
        revenue = 0;
        return 10;
    }
}

contract TriggerServiceStub {
    uint256 public constant FEE = 0.0002 ether;
    uint256 public count;
    mapping(uint256 => address) public receiver;
    mapping(uint256 => uint64) public due;
    bool public reenter;

    function getFee() external pure returns (uint256) {
        return FEE;
    }

    function requestTrigger(uint64 executeAfter) external payable returns (uint256 id) {
        require(msg.value == FEE);
        id = ++count;
        receiver[id] = msg.sender;
        due[id] = executeAfter;
        if (reenter) CallTriggerAdapter(msg.sender).trigger(id);
    }

    function configureReentry(bool value) external {
        reenter = value;
    }

    function execute(uint256 id) external {
        CallTriggerAdapter(receiver[id]).trigger(id);
    }
}

contract CallTriggerAdapterTest is Test {
    TriggerFactoryStub factory;
    TriggerServiceStub service;
    TriggerVaultStub vault;
    CallTriggerAdapter adapter;
    uint256 constant FEE = 0.0002 ether;

    function setUp() external {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1 ether);
        factory = new TriggerFactoryStub();
        service = new TriggerServiceStub();
        vault = new TriggerVaultStub();
        factory.register(address(vault));
        adapter = new CallTriggerAdapter(address(factory), address(service));
    }

    function schedule(uint16 action) internal returns (uint256) {
        return adapter.schedule{value: FEE}(address(vault), action);
    }

    function testSchedulingDerivesMinedTimestampWithoutCallerTimestamp() external {
        bytes memory transactionData = abi.encodeWithSignature("schedule(address,uint16)", address(vault), uint16(0));
        vm.warp(block.timestamp + 12);
        (bool ok, bytes memory result) = address(adapter).call{value: FEE}(transactionData);
        assertTrue(ok);
        uint256 id = abi.decode(result, (uint256));
        assertEq(service.due(id), block.timestamp);
    }

    function testFeeComesOnlyFromRequesterAndActionsAreBound() external {
        vm.deal(address(adapter), 1 ether);
        vm.expectRevert(bytes(unicode"Incorrect service fee"));
        adapter.schedule(address(vault), 0);
        for (uint16 action; action < 3; ++action) {
            uint256 id = schedule(action);
            service.execute(id);
            assertEq(vault.calls(action), 1);
            vm.expectRevert(bytes(unicode"Unknown or finished request"));
            service.execute(id);
        }
        assertEq(address(adapter).balance, 1 ether);
        assertEq(address(service).balance, 3 * FEE);
    }

    function testRejectsUnknownVaultAndAction() external {
        vm.expectRevert(bytes(unicode"Unknown vault"));
        adapter.schedule{value: FEE}(address(123), 0);
        vm.expectRevert(bytes(unicode"Invalid action"));
        adapter.schedule{value: FEE}(address(vault), 3);
    }

    function testSampleTimeIsDerivedAndCallbackRechecksDirectSampling() external {
        vault.configure(uint64(block.timestamp), 0, 10, true, false);
        uint64 due = uint64(block.timestamp + 1 hours);
        uint256 id = adapter.schedule{value: FEE}(address(vault), 0);
        assertEq(service.due(id), due);
        vm.expectRevert(bytes(unicode"Too early"));
        service.execute(id);
        vm.warp(due);
        vault.sampleTwap();
        service.execute(id);
        assertEq(vault.calls(0), 1);
        assertEq(adapter.pendingRequest(address(vault), 0), 0);
        (,,, CallTriggerAdapter.RequestStatus status) = adapter.requests(id);
        assertEq(uint256(status), uint256(CallTriggerAdapter.RequestStatus.Skipped));
    }

    function testAuthorizationUnknownAndDuplicatePending() external {
        uint256 id = schedule(0);
        vm.expectRevert(bytes(unicode"Pending request exists"));
        schedule(0);
        vm.expectRevert(bytes(unicode"Only TriggerService"));
        adapter.trigger(id);
        vm.prank(address(service));
        vm.expectRevert(bytes(unicode"Unknown or finished request"));
        adapter.trigger(99);
    }

    function testIneligibleActionsRejectedAndStateChangeSafelySkipped() external {
        vault.configure(0, 1, 0, false, false);
        vm.expectRevert(bytes(unicode"Action unavailable"));
        schedule(1);
        vm.expectRevert(bytes(unicode"Action unavailable"));
        schedule(2);
        vault.configure(0, 0, 10, true, false);
        uint256 open = schedule(1);
        uint256 revenue = schedule(2);
        vault.configure(0, 1, 0, true, false);
        service.execute(open);
        service.execute(revenue);
        assertEq(vault.calls(1), 0);
        assertEq(vault.calls(2), 0);
        assertEq(adapter.pendingRequest(address(vault), 1), 0);
    }

    function testExternalFailureRollsBackAndCanRetry() external {
        uint256 id = schedule(2);
        vault.configure(0, 0, 10, true, true);
        vm.expectRevert(bytes(unicode"Vault action failed"));
        service.execute(id);
        assertEq(adapter.pendingRequest(address(vault), 2), id);
        vault.configure(0, 0, 10, true, false);
        service.execute(id);
        assertEq(vault.calls(2), 1);
    }

    function testBoundedActionsHandleGasAndReturnBombsWithinServiceBudget() external {
        bytes memory expected = abi.encodeWithSignature("Error(string)", unicode"Vault action failed");
        for (uint16 action; action < 3; ++action) {
            for (uint8 mode = 1; mode <= 5; ++mode) {
                vault.configure(0, 0, 10, true, false);
                uint256 id = schedule(action);
                vault.setHostileMode(mode);
                uint256 gasBefore = gasleft();
                (bool ok, bytes memory data) =
                    address(service).call{gas: 2_000_000}(abi.encodeCall(service.execute, (id)));
                uint256 used = gasBefore - gasleft();
                emit log_named_uint("hostile callback gas", used);
                assertLt(used, 2_000_000);
                if (mode == 2 || (mode == 4 && action == 2)) {
                    assertTrue(ok);
                    assertEq(adapter.pendingRequest(address(vault), action), 0);
                } else {
                    assertFalse(ok);
                    assertEq(data, expected);
                    assertEq(adapter.pendingRequest(address(vault), action), id);
                    vault.setHostileMode(0);
                    service.execute(id);
                }
                vault.setHostileMode(0);
            }
        }
    }

    function testExpiredRequestCanBeClearedAndDoesNotReplayAcrossReplacement() external {
        uint256 id = schedule(0);
        vm.expectRevert(bytes(unicode"Too early"));
        adapter.cancelExpiredRequest(id);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(123));
        adapter.cancelExpiredRequest(id);
        uint256 replacement = schedule(0);
        vm.expectRevert(bytes(unicode"Unknown or finished request"));
        service.execute(id);
        assertEq(adapter.pendingRequest(address(vault), 0), replacement);
        service.execute(replacement);
    }

    function testSynchronousServiceCallbackCannotConsumePartiallyCreatedRequest() external {
        service.configureReentry(true);
        vm.expectRevert();
        schedule(0);
        assertEq(service.count(), 0);
        assertEq(adapter.pendingRequest(address(vault), 0), 0);
    }

    function testCallbackSuccessAndSafeFailureStayWithinTwoMillionGas() external {
        for (uint16 action; action < 3; ++action) {
            uint256 id = schedule(action);
            uint256 gasBefore = gasleft();
            service.execute(id);
            uint256 used = gasBefore - gasleft();
            emit log_named_uint("successful callback gas", used);
            assertLt(used, 2_000_000);
        }
        vault.configure(0, 0, 10, true, false);
        uint256 invalidatedId = schedule(2);
        vault.configure(0, 0, 10, false, false);
        uint256 failureGasBefore = gasleft();
        service.execute(invalidatedId);
        uint256 failureUsed = failureGasBefore - gasleft();
        emit log_named_uint("invalidated callback gas", failureUsed);
        assertLt(failureUsed, 2_000_000);
        for (uint16 action; action < 3; ++action) {
            vault.configure(0, 0, 10, true, false);
            uint256 retryId = schedule(action);
            vault.configure(0, 0, 10, true, true);
            uint256 revertGasBefore = gasleft();
            (bool ok,) = address(service).call(abi.encodeCall(service.execute, (retryId)));
            uint256 revertedUsed = revertGasBefore - gasleft();
            assertFalse(ok);
            emit log_named_uint("reverted callback gas", revertedUsed);
            assertLt(revertedUsed, 2_000_000);
            assertEq(adapter.pendingRequest(address(vault), action), retryId);
        }
    }

    function testUnavailablePriceSampleFinishesAsSkipped() external {
        uint256 id = schedule(0);
        vault.setSampleAvailable(false);
        service.execute(id);
        (,,, CallTriggerAdapter.RequestStatus status) = adapter.requests(id);
        assertEq(uint256(status), uint256(CallTriggerAdapter.RequestStatus.Skipped));
        assertEq(adapter.pendingRequest(address(vault), 0), 0);
    }
}
