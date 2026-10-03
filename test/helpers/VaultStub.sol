// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title VaultStub
/// @notice 扮演「该系列的金库」的最小替身 —— **本里程碑唯一允许的自建 mock**（issue #9 / #5「Out of Scope」）。
///
/// 允许它存在的理由只有一条：`WarrantVault` 到 M2 才存在，而 M1-4 要交付的两个函数
/// 恰恰只对金库开放。除此之外测试一律驱动真实的四合约（issue #5「测试缝」）。
///
/// 所以这个替身刻意**什么都不做**：不算 TWAP、不定 strike、不记账，只把调用原样转给池子。
/// 它多做一件事，测试就多测一件我们不发布的东西。
///
/// @dev 🔴 金库必须是**合约**，不是 EOA。用 `vm.prank` 假装一个 EOA 金库会让一整类问题隐形 ——
///      真实金库调 `depositAndMint` 时池子会从**它**那里 `transferFrom`，而授权、余额、
///      以及「铸造回调打到谁身上」全都长在合约账户上。
contract VaultStub {
    IClearingPool public immutable pool;

    constructor(IClearingPool pool_) {
        pool = pool_;
    }

    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId)
    {
        return pool.openSeries(memeToken, stockToken, expiry, strike);
    }

    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount) external returns (uint256 minted) {
        return pool.depositAndMint(seriesId, to, expectedAmount);
    }

    /// @dev 池子用 `transferFrom` 从金库把抵押品拉走，所以授权是金库侧的事。
    function approve(IERC20 token, uint256 amount) external {
        token.approve(address(pool), amount);
    }
}
