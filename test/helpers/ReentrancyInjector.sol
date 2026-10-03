// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ReentrancyInjector
/// @notice 「在转账过程中回调外部」这件事的**机制**，与它被装在哪只代币上无关。
///
/// 池子的两条关键路径各自把控制权交出去两次以上：存入时是股票代币的转账与权证的 `onERC1155Received`，
/// 行权时是 MEME 的转账与股票代币的转账。**每一处都得有人守**，于是替身侧需要同一套注入器
/// 装在不同的代币上 —— 而那是纯机制，不是对某只真实代币的建模。
///
/// 抽出来的边界正画在这里：**税率、`uiMultiplier`、门控这些「像哪只真实代币」的性质留在各自的替身里**
/// （它们会随里程碑各自长出更多东西，比如 #11 要在股票代币侧模拟门控语义），
/// 而「回调怎么打、失败怎么记」只此一份。
///
/// @dev 🔴 回调失败被**吞掉并记录**，而不是冒泡：这样外层调用照常完成，测试才能同时断言
///      「内层被拒」与「外层的账依然精确」。只断言整笔 revert 是更弱的说法 ——
///      它连「守住的是不是这件事」都说不清。
abstract contract ReentrancyInjector {
    address public reentryTarget;
    bytes public reentryPayload;

    /// @notice 内层回调成功了吗。必须为 false。
    bool public reentrySucceeded;
    /// @notice 内层回调的 revert 数据（原样冒泡上来的）。
    bytes public reentryError;
    /// @notice 回调实际发生过的次数 —— 防止「一次都没触发」被当成「守住了」。
    uint256 public reentryAttempts;

    bool private firing;

    function armReentrancy(address target, bytes calldata payload) external {
        reentryTarget = target;
        reentryPayload = payload;
    }

    /// @dev 在代币的 `_update` 末尾调一次。
    /// @param from 转出方。`address(0)` 是铸造 —— 测试自己摆初始余额时不该触发回调。
    function _fireReentrancy(address from) internal {
        if (firing || reentryTarget == address(0) || from == address(0)) return;

        firing = true;
        reentryAttempts++;
        (bool ok, bytes memory ret) = reentryTarget.call(reentryPayload);
        firing = false;

        reentrySucceeded = ok;
        reentryError = ret;
    }
}
