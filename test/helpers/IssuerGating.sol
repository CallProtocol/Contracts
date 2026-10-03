// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StockToken} from "./StockToken.sol";

/// @title IssuerPauseManagerStub
/// @notice bStocks **暂停管理器**的替身 —— 26 只 bStock 共用同一个（决策 53）。
///
/// @dev 只做池子会读的那一件事（`isTokenPaused(token)`），外加一个把它**读不通**的开关。
///      🔴 `*Raw` 视图供代币内部的拦截修饰器使用：`viewsRevert` 模拟的是「发行方升级改了接口」，
///      那种情况下代币的**转账拦截照常工作**，只是外面读不到状态了 —— 而那正是 fail-open
///      要买 48 小时的原因（`docs/spec.zh.md` §11：持有人会在完全无法行权的窗口里失去权证）。
///      若把内部拦截也接到会 revert 的 view 上，就再也构造不出那一档。
///
///      🔴 **单币冻结与全局急停都落在 `isTokenPaused` 这一个读里** —— 这是 BSC 主网实测：
///      冒充 `OPS_ROLE` 调 `pauseAllTokens()` 之后，`isTokenPaused(GMEB)` 一并翻成 `true`
///      （`docs/research/bsc-flap-portal-probe.md` §6.4）。所以这里也按同一个语义建模，
///      池子因此不必再问一次 `allTokensPaused()`。
contract IssuerPauseManagerStub {
    error PauseManagerViewUnreadable();

    bool public viewsRevert;
    bool private _allPaused;
    mapping(address token => bool) private _paused;

    /// @notice 全局急停（对应真实合约的 `pauseAllTokens` / `unpauseAllTokens`）。
    function setAllTokensPaused(bool paused_) external {
        _allPaused = paused_;
    }

    /// @notice 单币冻结（对应真实合约的 `pauseToken` / `unpauseToken`）。
    function setTokenPaused(address token, bool paused_) external {
        _paused[token] = paused_;
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function isTokenPaused(address token) external view returns (bool) {
        if (viewsRevert) revert PauseManagerViewUnreadable();
        return _allPaused || _paused[token];
    }

    function isTokenPausedRaw(address token) external view returns (bool) {
        return _allPaused || _paused[token];
    }
}

/// @title IssuerComplianceStub
/// @notice bStocks **合规模块**的替身 —— 逐代币黑名单 + 全局制裁名单。
///
/// @dev 🔴 **黑名单的键是 `(代币, 地址)` 两元**，比 Robinhood 那版多一维；制裁名单则与代币无关。
///      两者都是池子读的 `view`，都由 `viewsRevert` 一起断掉 —— 真实的「发行方升级改了接口」
///      不会只断掉其中一个。
contract IssuerComplianceStub {
    error ComplianceViewUnreadable();

    bool public viewsRevert;
    mapping(address token => mapping(address account => bool)) private _blocked;
    mapping(address account => bool) private _sanctioned;

    function setBlocked(address token, address account, bool blocked_) external {
        _blocked[token][account] = blocked_;
    }

    function setSanctioned(address account, bool sanctioned_) external {
        _sanctioned[account] = sanctioned_;
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function blockedAddresses(address token, address account) external view returns (bool) {
        if (viewsRevert) revert ComplianceViewUnreadable();
        return _blocked[token][account];
    }

    function sanctionedAddresses(address account) external view returns (bool) {
        if (viewsRevert) revert ComplianceViewUnreadable();
        return _sanctioned[account];
    }

    function blockedRaw(address token, address account) external view returns (bool) {
        return _blocked[token][account];
    }

    function sanctionedRaw(address account) external view returns (bool) {
        return _sanctioned[account];
    }
}

/// @title IssuerGatedStockToken
/// @notice 带**发行方门控**的股票代币替身，按 **bStock 今天的形状**建模（决策 53）。
///
/// 🔴 与 {GatedStockToken} 的分工要说清楚：那个是**失败注入器**（一个开关让转账 revert，仅此而已），
/// 它的注释里写着「不是门控的模型」—— 因为在 M1-5 那张票上，门控**语义**只有分叉上的真合约测得准。
///
/// 这张票（M1-6）不一样：`pokeGating` 读的就是门控 view 本身，而不变量 4 必须在**本地**跑
/// （不变量测试不能依赖网络）。所以这里把那个形状建出来：
///
/// | 建的 | 依据（全部为 2026-09-08 BSC 主网实测） |
/// |---|---|
/// | `pauseManager()` / `compliance()` 公开可读，地址从代币身上取 | 对 GMEB 实测读回 `0x9fc74Be6…700a` / `0x53dBa7Aa…14F4` |
/// | `isTokenPaused` 一个读覆盖单币与全局两档 | `pauseAllTokens()` 之后 `isTokenPaused(GMEB)` 一并翻真 |
/// | 黑名单查的是**合规模块**且键含代币 | `blockedAddresses(GMEB, who)`；直接对代币调会 revert |
/// | 另有一张**全局制裁名单** | `sanctionedAddresses(who)` —— Robinhood 那版没有对应物 |
/// | 每条转账路径都被拦截 | 真去 `pauseToken` / `addToBlocklist` / `addToSanctionsList` 之后 `transfer` 分别 revert `TokenPaused()` / `UserBlocked()` / `UserSanctioned()` |
///
/// ⚠️ 它仍然只是替身。真实标的上的复核见 `docs/research/bsc-flap-portal-probe.md` §6.4，
/// 以及待建的 BSC 版分叉测试。
contract IssuerGatedStockToken is StockToken {
    error IsPaused();
    error Blocked(address account);
    error Sanctioned(address account);
    error StockViewUnreadable();

    IssuerPauseManagerStub public immutable PAUSE_MANAGER;
    IssuerComplianceStub public immutable COMPLIANCE;

    /// @notice 让**池子读的那两个地址 view** 断掉（发行方升级改了接口）。转账拦截不受影响。
    bool public viewsRevert;

    /// @notice 让 `pauseManager()` 烧掉大量 gas —— 用来证明「贵到读不完的 view」被判为读不通，
    ///         而不是被判为干净，也不会把调用方的整笔 gas 吃光。
    uint256 public viewGasBurnRounds;

    constructor(IssuerPauseManagerStub pauseManager_, IssuerComplianceStub compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    /// @notice 冻结**这一只**代币（转发给管理器，与真实合约同一条路径）。
    function setTokenPaused(bool paused_) external {
        PAUSE_MANAGER.setTokenPaused(address(this), paused_);
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function setViewGasBurnRounds(uint256 rounds) external {
        viewGasBurnRounds = rounds;
    }

    function pauseManager() external view returns (address) {
        if (viewsRevert) revert StockViewUnreadable();
        for (uint256 i = 0; i < viewGasBurnRounds; i++) {
            keccak256(abi.encode(i, address(this)));
        }
        return address(PAUSE_MANAGER);
    }

    function compliance() external view returns (address) {
        if (viewsRevert) revert StockViewUnreadable();
        return address(COMPLIANCE);
    }

    /// @dev 拦截走的是 `*Raw`，因此「view 读不通、但代币真的冻结着」这一档构造得出来。
    ///      铸造与销毁不拦 —— 否则冻结期间连测试自己的初始余额都摆不出来。
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (PAUSE_MANAGER.isTokenPausedRaw(address(this))) revert IsPaused();
            if (COMPLIANCE.blockedRaw(address(this), from)) revert Blocked(from);
            if (COMPLIANCE.blockedRaw(address(this), to)) revert Blocked(to);
            if (COMPLIANCE.sanctionedRaw(from)) revert Sanctioned(from);
            if (COMPLIANCE.sanctionedRaw(to)) revert Sanctioned(to);
        }
        super._update(from, to, value);
    }
}

/// @dev A well-formed gating reader whose `pauseManager()` deliberately spends almost all of the forwarded budget.
///      It models only the two address views the pool reads; transfer semantics are irrelevant to this gas test.
contract NearBudgetIssuerGatedStockToken {
    IssuerPauseManagerStub public immutable PAUSE_MANAGER;
    IssuerComplianceStub public immutable COMPLIANCE;

    constructor(IssuerPauseManagerStub pauseManager_, IssuerComplianceStub compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    function compliance() external view returns (address) {
        return address(COMPLIANCE);
    }

    function pauseManager() external view returns (address) {
        // Leave enough gas for Solidity's ABI return path, while making a 50k-gas read genuinely near-budget.
        assembly ("memory-safe") {
            for {} gt(gas(), 7000) {} { pop(keccak256(0, 0)) }
        }
        return address(PAUSE_MANAGER);
    }
}

/// @dev A healthy compliance module whose `sanctionedAddresses` read — **the pool's fifth and last** —
///      needs virtually the whole 50k forwarding budget. Putting the threshold on the final read keeps the
///      cold-call/EIP-150 boundary observable without weakening any of the preceding four.
contract FullBudgetIssuerCompliance {
    uint256 internal constant MIN_GAS_AT_ENTRY = 49_700;

    function blockedAddresses(address, address) external pure returns (bool) {
        return false;
    }

    function sanctionedAddresses(address) external view returns (bool) {
        if (gasleft() < MIN_GAS_AT_ENTRY) revert();
        return false;
    }
}

/// @dev A pause manager that always answers cheaply — the companion for {FullBudgetIssuerCompliance}.
contract AlwaysReadablePauseManager {
    function isTokenPaused(address) external pure returns (bool) {
        return false;
    }
}

/// @dev The companion token for {FullBudgetIssuerCompliance}. A full-budget final read succeeds, while a
///      silently EIP-150-capped final read reverts.
contract FullBudgetIssuerGatedStockToken {
    address public immutable PAUSE_MANAGER;
    address public immutable COMPLIANCE;

    constructor(address pauseManager_, address compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    function pauseManager() external view returns (address) {
        return PAUSE_MANAGER;
    }

    function compliance() external view returns (address) {
        return COMPLIANCE;
    }
}
