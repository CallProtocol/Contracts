// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";

interface IWarrantTriggerFactory {
    function isVault(address vault) external view returns (bool);
}

interface IWarrantTriggerVault {
    function lastSampleAt() external view returns (uint64);
    function seriesExpiry() external view returns (uint64);
    function strike() external view returns (uint128);
    function openSeriesStatus() external view returns (uint256, uint64, uint128);
    function inTransit() external view returns (uint256, bool);
    function sampleTwap() external returns (bool);
    function openSeries() external returns (uint256, bool);
    function processRevenue() external returns (uint256);
}

/// @notice Requester-funded automation for the three existing permissionless Vault actions.
contract WarrantTriggerAdapter is ITriggerReceiver, ReentrancyGuard {
    enum RequestStatus {
        Unknown,
        Pending,
        Executed,
        Skipped,
        Expired
    }
    enum SkipReason {
        None,
        SampleAlreadyWritten,
        SeriesUnavailable,
        RevenueUnavailable,
        SampleUnavailable
    }

    struct Request {
        address vault;
        uint16 action;
        uint64 executeAfter;
        RequestStatus status;
    }

    address public immutable factory;
    IFlapTriggerService public immutable triggerService;
    uint256 public constant SAMPLE_INTERVAL = 1 hours;
    uint256 public constant CLEANUP_DELAY = 2 hours;
    uint256 public constant ACTION_GAS_LIMIT = 1_400_000;
    mapping(uint256 => Request) public requests;
    mapping(address => mapping(uint16 => uint256)) public pendingRequest;
    mapping(address => mapping(uint16 => bool)) private _pending;

    event ActionScheduled(uint256 indexed requestId, address indexed vault, uint16 action, uint64 executeAfter);
    event ActionFinished(uint256 indexed requestId, RequestStatus status, SkipReason reason);

    constructor(address factory_, address triggerService_) {
        if (factory_.code.length == 0 || triggerService_.code.length == 0) {
            revert(unicode"Invalid dependency / 依赖地址无合约代码");
        }
        factory = factory_;
        triggerService = IFlapTriggerService(triggerService_);
    }

    /// @notice Action 0 samples TWAP, 1 opens a series, and 2 processes revenue.
    /// @dev Time is derived from Vault state; the caller cannot reserve a future arbitrary slot.
    function schedule(address vault, uint16 action) external payable nonReentrant returns (uint256 requestId) {
        if (!IWarrantTriggerFactory(factory).isVault(vault)) revert(unicode"Unknown vault / 金库不属于本工厂");
        if (action > 2) revert(unicode"Invalid action / 动作无效");
        if (_pending[vault][action]) revert(unicode"Pending request exists / 此动作已有待执行请求");
        if (msg.value != triggerService.getFee()) revert(unicode"Incorrect service fee / 服务费金额不符");
        IWarrantTriggerVault target = IWarrantTriggerVault(vault);
        uint256 expected = block.timestamp;
        if (action == 0) {
            uint64 last = target.lastSampleAt();
            if (last != 0 && uint256(last) + SAMPLE_INTERVAL > expected) expected = uint256(last) + SAMPLE_INTERVAL;
        } else if (_unavailable(target, action) != SkipReason.None) {
            revert(unicode"Action unavailable / 当前无法执行此动作");
        }
        uint64 executeAfter = uint64(expected);
        requestId = triggerService.requestTrigger{value: msg.value}(executeAfter);
        // Keep completed IDs forever so a service ID cannot be rebound to a different action.
        if (requests[requestId].status != RequestStatus.Unknown) {
            revert(unicode"Reused service request ID / 服务返回了重复请求编号");
        }
        requests[requestId] = Request(vault, action, executeAfter, RequestStatus.Pending);
        pendingRequest[vault][action] = requestId;
        _pending[vault][action] = true;
        emit ActionScheduled(requestId, vault, action, executeAfter);
    }

    function trigger(uint256 requestId) external nonReentrant {
        if (msg.sender != address(triggerService)) revert(unicode"Only TriggerService / 仅触发服务可回调");
        Request memory request = _request(requestId);
        if (block.timestamp < request.executeAfter) revert(unicode"Too early / 尚未到执行或清理时间");
        IWarrantTriggerVault vault = IWarrantTriggerVault(request.vault);
        SkipReason reason = _unavailable(vault, request.action);
        // Consume before the external action; an execution revert restores the pending request.
        _finish(requestId, request, reason == SkipReason.None ? RequestStatus.Executed : RequestStatus.Skipped);
        if (reason != SkipReason.None) {
            emit ActionFinished(requestId, RequestStatus.Skipped, reason);
            return;
        }
        (uint256 result, uint256 opened) = _executeBounded(request.vault, request.action);
        if (request.action == 0 && result == 0) {
            reason = SkipReason.SampleUnavailable;
        } else if (request.action == 1 && opened == 0) {
            reason = SkipReason.SeriesUnavailable;
        } else if (request.action == 2 && result == 0) {
            reason = SkipReason.RevenueUnavailable;
        }
        if (reason != SkipReason.None) requests[requestId].status = RequestStatus.Skipped;
        emit ActionFinished(requestId, requests[requestId].status, reason);
    }

    function _executeBounded(address target, uint16 action) private returns (uint256 result, uint256 opened) {
        bytes4 selector = action == 0
            ? IWarrantTriggerVault.sampleTwap.selector
            : (action == 1 ? IWarrantTriggerVault.openSeries.selector : IWarrantTriggerVault.processRevenue.selector);
        bool ok;
        uint256 size;
        uint256 gasLimit = ACTION_GAS_LIMIT;
        // Reserve callback gas for finishing/reverting and copy only the fixed ABI words.
        // Neither large asset revert data nor a gas-burning asset can consume that reserve.
        assembly ("memory-safe") {
            let buffer := mload(0x40)
            mstore(buffer, selector)
            ok := call(gasLimit, target, 0, buffer, 4, buffer, 64)
            size := returndatasize()
            result := mload(buffer)
            opened := mload(add(buffer, 32))
        }
        if (!ok || size < (action == 1 ? 64 : 32) || (action == 0 && result > 1) || (action == 1 && opened > 1)) {
            revert(unicode"Vault action failed / 金库动作执行失败");
        }
    }

    /// @notice Release a stalled slot two hours after its derived execution time.
    function cancelExpiredRequest(uint256 requestId) external nonReentrant {
        Request memory request = _request(requestId);
        if (block.timestamp < uint256(request.executeAfter) + CLEANUP_DELAY) {
            revert(unicode"Too early / 尚未到执行或清理时间");
        }
        _finish(requestId, request, RequestStatus.Expired);
        emit ActionFinished(requestId, RequestStatus.Expired, SkipReason.None);
    }

    function _request(uint256 requestId) private view returns (Request memory request) {
        request = requests[requestId];
        if (request.status != RequestStatus.Pending) {
            revert(unicode"Unknown or finished request / 请求未知或已结束");
        }
    }

    function _finish(uint256 id, Request memory request, RequestStatus status) private {
        requests[id].status = status;
        delete pendingRequest[request.vault][request.action];
        delete _pending[request.vault][request.action];
    }

    function _unavailable(IWarrantTriggerVault vault, uint16 action) private view returns (SkipReason) {
        if (action == 0) {
            uint64 last = vault.lastSampleAt();
            if (last != 0 && block.timestamp < uint256(last) + SAMPLE_INTERVAL) return SkipReason.SampleAlreadyWritten;
        } else if (action == 1) {
            (uint256 status,,) = vault.openSeriesStatus();
            if (status != 0) return SkipReason.SeriesUnavailable;
        } else {
            (uint256 amount, bool exact) = vault.inTransit();
            if (!exact || amount == 0 || vault.strike() == 0 || block.timestamp >= vault.seriesExpiry()) {
                return SkipReason.RevenueUnavailable;
            }
        }
        return SkipReason.None;
    }
}
