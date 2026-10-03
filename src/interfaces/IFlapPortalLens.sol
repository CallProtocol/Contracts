// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IFlapPortalLens
/// @notice Flap `Portal` 的**只读**镜头面里我们用到的那一个方法。
///
/// # 为什么是 `getTokenV8Safe` 而不是 `getTokenV8`
///
/// 两者返回的字段完全一样，区别只在**枚举字段的静态类型**：`V8` 把 `status` / `tokenVersion` /
/// `lpFeeProfile` / `dexId` 声明成 Solidity 枚举，`V8Safe` 声明成 `uint8`。Flap 自己在上游注释里
/// 写明了理由 —— 解码一个超出本地枚举上限的值会**当场 revert**：
///
/// > *Safe because Solidity revert when decoding an enum value that exceeds the enum's declared
/// > maximum (e.g. a new TOKEN_TAXED_V3 value read by a contract compiled against an old
/// > TokenVersion enum).*
///
/// 也就是说，Flap 将来往 `TokenStatus` 里加一个变体，读 `getTokenV8` 的合约会**从那一刻起
/// 全部读不出价格**，而我们的金库是每小时采一次样的东西 —— 它会安静地停摆一整天，
/// 然后 `openSeries` 因为「样本不足」拒绝开系列。所以镜头一律走 `Safe` 那一支。
///
/// 🔴 **同一条理由适用于我们自己**：本仓库对外暴露的 TWAP 状态码也是 `uint256` 而不是枚举
/// （见 {WarrantVault.twap}）。这不是风格选择，是照抄 Flap 花钱买来的教训。
///
/// # 出处（逐字段实测钉死，不是照着文档抄的）
///
/// - 合约：Robinhood Chain（4663）`Portal` 代理 `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09`；
///   字段顺序最初取自 Blockscout 已验证的旧实现 `0x7Bc20c2C…fA06`（`Portal` / solc 0.8.26）；
/// - 当前实现 `0xa3b96Df56f254B926B17D5f7FB6CD858c216ff44` 尚未完成 Blockscout 源码验证，
///   但选择器 `getTokenV8Safe(address)` = `0x62fafcca` 仍在 runtime 字节码里，且 #146 在新发 GME
///   计价代币上逐字段实读复核；
/// - 返回值是 **18 个静态字**（576 字节），字段顺序与下面的 struct 一致 ——
///   `test/fork/RobinhoodTwapSource.t.sol` 每跑一次就在真实 Portal 上复核一遍。
///
/// 语义、量纲与两处坑的完整实测记录：`docs/research/flap-portal-price-semantics.md`。
interface IFlapPortalLens {
    /// @notice Flap 对一只代币的完整状态快照。**字段顺序即 ABI 顺序**，改动它会静默读错值。
    ///
    /// @dev 逐字段的中文说明只写我们真正依赖的那四个，其余保留上游英文原文，
    ///      好让「这份声明抄自哪里」这件事可被一眼核对。
    ///
    /// @param status                   `TokenStatus`：0 Invalid · 1 Tradable · 2 InDuel(废弃) ·
    ///                                 3 Killed(废弃) · 4 DEX · 5 Staged。
    ///                                 🔴 我们只接受 **1（曲线阶段）** 与 **4（已毕业）** 两态
    /// @param reserve                  The reserve amount of the quote token held by the bonding curve
    /// @param circulatingSupply        The circulating supply of the token
    /// @param price                    🔴 **1e18 raw 单位该代币值多少 raw 计价币**（见 {IFlapPortalLens} 顶部
    ///                                 与 `docs/research/flap-portal-price-semantics.md`）。
    ///                                 上游 `LibCurve.price` 的原文是 *"price (wei) of a token (1e18)"*，
    ///                                 公式 `k / (1e9 + h - s)²`（WAD 定点）。
    ///                                 **毕业之后恒为 `0`** —— 实测，不是推测
    /// @param tokenVersion             `TokenVersion`：6 = `TOKEN_TAXED_V3`
    /// @param r                        The curve parameter 'r' used for the bonding curve
    /// @param h                        The curve parameter 'h' - virtual token reserve
    /// @param k                        The curve parameter 'k' - square of virtual liquidity
    /// @param dexSupplyThresh          The circulating supply threshold for adding the token to the DEX
    /// @param quoteTokenAddress        🔴 **计价币**；`address(0)` = 原生币。
    ///                                 金库拿它与自己的 `vaultQuoteToken()` 对账 —— 对不上就说明
    ///                                 `price` 的分母不是我们的股票代币，那个读数一文不值
    /// @param nativeToQuoteSwapEnabled Whether native-to-quote swap is enabled for this token
    /// @param extensionID              The extension ID used by the token (bytes32(0) if no extension)
    /// @param buyTaxRate               The buy tax rate in basis points (0 if not a tax token)
    /// @param sellTaxRate              The sell tax rate in basis points (0 if not a tax token)
    /// @param pool                     🔴 **毕业后的 DEX 池**（未上池时为 `address(0)`）。
    ///                                 Robinhood Chain 上实测是 **Uniswap V2 形状的配对**
    ///                                 （`token0()` / `token1()` / `getReserves()` 都在，`slot0()` revert）
    /// @param progress                 The progress towards DEX listing (0 to 1e18, where 1e18 = 100%)
    /// @param lpFeeProfile             The V3 LP fee profile for the token
    /// @param dexId                    The Dex Id
    struct TokenStateV8Safe {
        uint8 status;
        uint256 reserve;
        uint256 circulatingSupply;
        uint256 price;
        uint8 tokenVersion;
        uint256 r;
        uint256 h;
        uint256 k;
        uint256 dexSupplyThresh;
        address quoteTokenAddress;
        bool nativeToQuoteSwapEnabled;
        bytes32 extensionID;
        uint256 buyTaxRate;
        uint256 sellTaxRate;
        address pool;
        uint256 progress;
        uint8 lpFeeProfile;
        uint8 dexId;
    }

    /// @notice 读一只代币的状态。
    /// @dev 🔴 **代币不存在时它 revert**，报 `TokenNotFound(address)`（`0xde6137d1`，实测）。
    ///      所以调用方必须走低层 `staticcall` 把失败变成一个**返回值**，见 {PriceSource.spot}。
    function getTokenV8Safe(address token) external view returns (TokenStateV8Safe memory state);
}

/// @title IDexPair
/// @notice 毕业之后那个池子的 Uniswap V2 形状读接口。
///
/// @dev 🔴 **「是 V2 形状」是实测结论，不是假设。** Robinhood Chain 上 `migratorType` 只有
///      `V2_MIGRATOR`（=1）走得通（`ForkConfig` 那三个常量的注释记了取别的值分别报什么错），
///      而 269 次真实毕业事件里取一个池子来问：`token0()` / `token1()` / `getReserves()` 都答得上，
///      `slot0()`（V3 的标志性入口）**revert**。复核见 `test/fork/RobinhoodTwapSource.t.sol`。
interface IDexPair {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice 读两条腿的储备与最后一次更新储备的 `uint32` 时间戳。
    /// @dev 时间戳按 V2 约定取 `uint32`；读价方必须把等于当前 `uint32(block.timestamp)` 的储备
    ///      视为同块更新，不能当作可采样的现货价。
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
