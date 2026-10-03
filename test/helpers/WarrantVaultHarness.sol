// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {WarrantVault} from "../../src/WarrantVault.sol";
import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title WarrantVaultHarness
/// @notice 把生产合约里几件**故意不对外**的东西暴露给测试：任意参数开系列、把不变式打破的样子摆出来、
///         以及两组 `internal` 常量与 {WarrantVault-_nextExpiry}。
///
/// @dev 被测的仍然是**生产合约的**函数 —— 这里一行业务逻辑都没有。而「生产合约不因此多一个入口」
///      由写入面枚举保证：它读的是 `out/WarrantVault.sol/WarrantVault.json`，本文件的辅助函数
///      进不了那份产物。
///
///      📝 M2-4（issue #36）落地之后，{harnessOpenSeries} **不再是 `openSeries()` 的替身** ——
///      真实入口的完整行为在 `test/WarrantVaultOpenSeries.t.sol` 与
///      `test/fork/RobinhoodOpenSeries.t.sol` 里被直接驱动。它留下来只剩一个用处，而那个用处
///      仍然成立：给**收入路径与规范面**的测试一个便宜的「已开系列」状态，不必先把 24 条样本的
///      环填满、也不必把时间对到某个周五。两件事分开测，是为了让 `processRevenue` 的失败原因
///      永远不会是「TWAP 没准备好」。
contract WarrantVaultHarness is WarrantVault {
    constructor(
        IClearingPool pool_,
        address merkleDistributor_,
        address portal_,
        address taxToken_,
        address quoteToken_,
        address creator_,
        bool wrapsNative_
    )
        WarrantVault(pool_, merkleDistributor_, portal_, taxToken_, quoteToken_, creator_, wrapsNative_, address(0xfee))
    {}

    /// @notice 用**任意** strike 与 expiry 开一个系列 —— 生产入口两个都不让挑，所以这条路只在测试里存在。
    ///
    /// @dev 🔴 顺序与生产实现一致，而且是承重的：先在池子上开成功、再写两个字段。
    ///      `processRevenue` 依赖「`strike != 0` ⟹ 该系列由本金库开启」这条不变式；反过来写的话，
    ///      一旦开系列失败，字段就会留在一个指向别人系列的状态上，收入从此再也出不去金库。
    function harnessOpenSeries(uint128 strike_, uint64 expiry_) external returns (uint256 seriesId) {
        seriesId = pool.openSeries(taxToken, collateralToken(), expiry_, strike_);
        strike = strike_;
        seriesExpiry = expiry_;
    }

    /// @notice {WarrantVault-_nextExpiry} —— 周五 21:00 UTC 对齐 + ≥7 天寿命。
    /// @dev 暴露出来是为了让对齐规则可以被**直接**按时刻扫一遍（含跨年、跨周边界与全区间 fuzz），
    ///      而不必为每一个时刻先 `vm.warp` 再把整只金库的状态摆好。生产合约里它是 `internal`：
    ///      唯一的链上消费者就住在同一个合约里。
    function harnessNextExpiry(uint256 nowTs) external pure returns (uint64) {
        return _nextExpiry(nowTs);
    }

    /// @notice 开系列的六个状态码，顺序同 {WarrantVault-openSeriesStatus} 的文档。
    /// @dev 同 {harnessTwapConstants}：测试要按名字断言，而生产 ABI 不该为此多六个入口。
    function harnessOpenConstants() external pure returns (uint256[9] memory constants) {
        constants = [
            OPEN_OK,
            OPEN_ALREADY_OPEN,
            OPEN_TOO_EARLY,
            OPEN_TWAP_UNAVAILABLE,
            OPEN_STRIKE_ROUNDS_TO_ZERO,
            OPEN_STRIKE_TOO_LARGE,
            uint256(OPEN_WINDOW),
            uint256(MIN_SERIES_LIFETIME),
            STRIKE_BPS
        ];
    }

    /// @notice **只写字段，不碰池子** —— 把上面那条不变式被打破之后的样子摆出来。
    /// @dev 用于两件事：`description()` 的纯渲染断言（不需要池子里真有系列），
    ///      以及 `test_processRevenue_revertsWhenTheSeriesFieldsWereWrittenWithoutOpening`
    ///      —— 那条测试证明「M2-4 写反顺序」会当场炸掉，而不是静默地把钱存到别处。
    function harnessWriteSeriesFieldsWithoutOpening(uint128 strike_, uint64 expiry_) external {
        strike = strike_;
        seriesExpiry = expiry_;
    }

    /// @notice TWAP 的窗口参数与状态码。
    ///
    /// @dev 它们在生产合约里是 `internal` —— 因为唯一的链上消费者（`openSeries()`）
    ///      就住在同一个合约里，把它们做成 `public` 只会给 ABI 添九个用不上的入口，
    ///      而每一个都要在 `vaultUISchema` 的交叉核对里单独豁免一次。
    ///
    ///      `constants[0..5]` 依次是样本数、最小间隔、最大缺口、最大样本年龄、严格窗口与最大回看；
    ///      `constants[6..11]` 是六个状态码。对外的映射表在 `WarrantVault.twap` 的注释与
    ///      `docs/spec.zh.md` §5.2。
    function harnessTwapConstants() external pure returns (uint256[12] memory constants) {
        constants = [
            TWAP_SAMPLES,
            SAMPLE_INTERVAL,
            MAX_SAMPLE_GAP,
            MAX_SAMPLE_AGE,
            MIN_TWAP_WINDOW,
            MAX_TWAP_WINDOW,
            TWAP_OK,
            TWAP_RING_NOT_FULL,
            TWAP_STALE,
            TWAP_WINDOW_TOO_SHORT,
            TWAP_WINDOW_TOO_LONG,
            TWAP_SAMPLE_GAP
        ];
    }
}
