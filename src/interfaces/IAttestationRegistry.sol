// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IAttestationRegistry
/// @notice ClearingPool 依赖的**全部**读接口 —— 只有一个函数。
///
/// 池子对合规声明只问一件事：「这个受益人声明过吗」。它**不问**声明的是哪一版、
/// 什么时候签的、内容是什么 —— 那些是前端与取证的事。链上只要求「≥1 次声明」。
///
/// 🔴 接口小到只剩一个 view，是刻意的：它是清算池唯一的外部合规依赖，
/// 面越大，将来「顺手加一个可控开关」的空间就越大。见 `spec.zh.md` §5.5。
interface IAttestationRegistry {
    /// @notice 账户已声明的版本号 **+1**；`0` 表示从未声明。
    /// @dev 存 `version + 1` 而不是 `version`，是为了让「从未声明」与「声明了 version 0」
    ///      在同一个槽里可区分 —— 否则 `versions[0]` 的声明者会和从未来过的人无法分辨。
    function attestedVersion(address account) external view returns (uint256);
}
