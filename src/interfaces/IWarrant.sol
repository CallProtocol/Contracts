// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IWarrant
/// @notice `ClearingPool` 依赖的**全部**权证接口 —— 只有铸造与销毁两个写入口。
///
/// 池子不读权证余额：它自己的账（`minted` / `exercised`）就是那本账，多读一份只会多一处可能对不上的地方。
/// 转让、授权、余额查询都是 ERC-1155 的事，与池子无关 —— 权证**转让完全自由**是 Seaport 撮合的前提。
///
/// 🔴 接口只留两个函数是刻意的，同 `IAttestationRegistry`：面越大，将来「顺手加一个可控开关」的空间就越大。
interface IWarrant {
    /// @notice 铸造 `amount` 份 `id` 系列的权证给 `to`。仅池子可调。
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice 从 `from` 销毁 `amount` 份 `id` 系列的权证。仅池子可调。
    function burn(address from, uint256 id, uint256 amount) external;
}
