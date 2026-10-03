// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IVaultRegistry
/// @notice ClearingPool 依赖的**全部**身份根读接口 —— 只有一个函数。
///
/// 池子对身份根只问一件事：「这只 MEME 的合法金库是谁」。它**不问**这条绑定是什么时候写的、
/// 由哪个工厂写的、写的时候发生过什么 —— 那些是取证与前端的事。
///
/// 🔴 接口小到只剩一个 view，与 {IAttestationRegistry} 同一条理由：它是清算池的外部授权依赖，
/// 面越大，将来「顺手加一个可控开关」的空间就越大。而池子不可升级 —— 这道门装上就拆不掉了。
///
/// ⚠️ **刻意不照抄 Flap 的 `getVault(address)`**：那一个在查不到时 revert `VaultNotFound`
/// （`0xc02219d9`，实测），照抄它的签名等于白白给一条 fail-closed 的授权路径继承一条 revert
/// 路径。这里的语义是「没有」返回 `address(0)`，见 {vaultOf}。
interface IVaultRegistry {
    /// @notice 某只 MEME 的合法金库。**未绑定返回 `address(0)`，不 revert。**
    ///
    /// @dev 🔴 「不 revert」是一条被断言过的性质，不是一个观察 ——
    ///      `test/VaultRegistry.t.sol::testFuzz_vaultOf_neverReverts` 用 `staticcall` 接住结果来钉它。
    ///      池子拿它当授权门，而池子不可升级：这条路径上多一个 revert，就等于给主网上一个
    ///      永远改不了的合约加一个「永远开不出系列」的开关。
    function vaultOf(address memeToken) external view returns (address vault);
}
