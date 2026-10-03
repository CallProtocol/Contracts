// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IIssuerGating
/// @notice 池子**读**发行方门控时用到的三个外部形状 —— **BSC / bStocks 版**（决策 53）。
///
/// 这里不是「我们要求股票代币实现的接口」—— 池子对任何股票代币都开着（`openSeries` 无许可），
/// 而这三个签名描述的是 **bStocks 今天的样子**（已在链上逐个读回来核对，见下）。
/// 读不通的代币按「读不通」处理（fail-open + 48h 宽限），不是按「不合规」拒绝 ——
/// 完整语义见 {ClearingPool-pokeGating} 与 `docs/spec.zh.md` §5.1。
///
/// 🔴 **不要把它写成 `ClearingPool` 的 `import` 之外的任何东西。** 池子调用它们走的是
/// 低层 `staticcall`（必须能吞掉 revert），这里存在的意义只有一个：让选择器有**一处**
/// 出处，而不是在合约里散着几个手写的 `bytes4` 字面量。
///
/// # 🔴 与 Robinhood 那一版的对照（这个文件在 `feature/bsc` 分支上被整体替换）
///
/// Robinhood `Stock` 的三个入口在 bStock 上**一个都不存在** —— `paused()` 与
/// `ACCESS_CONTROLLED_REGISTRY()` 直接 revert。但 BSC 上**有**一套结构逐条对得上的门控面，
/// 只是名字全不同：
///
/// | 语义 | Robinhood `Stock` | **bStocks（本文件）** |
/// |---|---|---|
/// | 代币被冻结了吗 | `stock.paused()` | `stock.pauseManager().isTokenPaused(stock)` |
/// | 中央权限入口在哪 | `stock.ACCESS_CONTROLLED_REGISTRY()` | `stock.compliance()` |
/// | 某个地址被拦了吗 | `registry.isBlocked(pool)` | `compliance.blockedAddresses(stock, pool)` **+** `compliance.sanctionedAddresses(pool)` |
///
/// 两处形状差异值得单独记：
///
/// - **黑名单多一维。** Robinhood 的键是地址；bStocks 是 `(代币, 地址)` 两元，另有一张**全局**
///   制裁名单。所以池子这边从三个读变成**五个**读。
/// - **全局急停不在同一个读里。** Robinhood 的 `paused()` 自己就返回
///   `本币暂停 || 注册表全局暂停`；bStocks 的 `pauseAllTokens()` 实测**会让
///   `isTokenPaused(stock)` 一并翻成 true**，所以仍然一个读覆盖两档 —— 这是实测结论，不是推断。
///
/// @dev 2026-09-08 在 BSC 主网上对 GMEB `0x46cE…b15C` 实测读回：
///      `pauseManager() = 0x9fc74Be6…700a`、`isTokenPaused(GMEB) = false`、
///      `compliance() = 0x53dBa7Aa…14F4`、`blockedAddresses(GMEB, 任意) = false`、
///      `sanctionedAddresses(任意) = false`。26 只 bStock **共用**同一个 compliance 与 pauseManager。
///
///      🔴 **行为面也验过，不只是接口面**：冒充链上真实角色真去 `pauseToken` /
///      `pauseAllTokens` / `addToBlocklist` / `addToSanctionsList` 之后，`transfer` 分别 revert
///      `TokenPaused()` / `UserBlocked()` / `UserSanctioned()`，而**这五个读在每一种冻结状态下
///      仍然全部读得通**（`readable = true`、`hit = true`）—— fail-open 不会把真实冻结误读成
///      「没冻结」。这正是决策 53 能选「同构替换」而不是「接受现状」的全部依据。
///      出处：`docs/research/bsc-flap-portal-probe.md` §6.3 / §6.4。
interface IIssuerGatedStock {
    /// @notice 该代币的暂停管理器。
    ///
    /// @dev 🔴 **地址从代币自己身上读，不写死在池子里。** 池子不可升级，写死一个管理器地址
    ///      等于假定这条链上永远只有一套发行方权限体系 —— 而那个假设一旦过期就再也改不了。
    ///      （与 Robinhood 版 `ACCESS_CONTROLLED_REGISTRY()` 同一条理由。）
    function pauseManager() external view returns (address);

    /// @notice 该代币的合规模块（逐代币黑名单与全局制裁名单住在那里）。
    /// @dev 同上：地址从代币身上读。
    function compliance() external view returns (address);
}

/// @notice 发行方的暂停管理器上，池子读的那一个函数。
///
/// @dev 单币冻结（`pauseToken`）与全局急停（`pauseAllTokens`）**都反映在这一个读里** ——
///      实测：`pauseAllTokens()` 之后 `isTokenPaused(GMEB)` 一并翻成 `true`。
///      所以池子不必再问一次 `allTokensPaused()`；多一个读只会多一次可失败的外部调用。
interface IIssuerPauseManager {
    function isTokenPaused(address token) external view returns (bool);
}

/// @notice 发行方的合规模块上，池子读的那两个函数。
///
/// @dev 🔴 池子问的是 **池子自己**（`address(this)`），不是受益人。发行方只封某个持有人时
///      池子仍然干净，因此**不产生任何延期**：一个地址被封不该让全系列延期。
///      这是刻意的取舍，但它是真实且不可挽回的用户损失，见 `docs/spec.zh.md` §11。
///
///      ⚠️ **不要用 `checkIsCompliant` 当门控钩子。** 它以 revert 表达「被拦」
///      （`UserBlocked()` / `UserSanctioned()`），而这里要的是**不 revert 的读数**；
///      而且它的真实签名是 `(address token, address user)`、与 `msg.sender` 无关 ——
///      起初按 `(from, to)` 的假设被读数否掉了（§6.4 逐种组合试出来的）。
interface IIssuerCompliance {
    /// @notice 逐代币黑名单。键是 `(代币, 地址)` 两元 —— 比 Robinhood 那版多一维。
    function blockedAddresses(address token, address account) external view returns (bool);

    /// @notice 全局制裁名单，与代币无关。
    function sanctionedAddresses(address account) external view returns (bool);
}
