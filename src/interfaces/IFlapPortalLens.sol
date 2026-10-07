// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IFlapPortalLens
/// @notice Flap `Portal` It's...**Read-only**That's the way we used it in the camera.
///
/// # Why? `getTokenV8Safe` Not `getTokenV8`
///
/// The fields that return are identical, and the difference is only between**Static type of an item field**:`V8` - Put it on. `status` / `tokenVersion` /
/// `lpFeeProfile` / `dexId` As a declaration Solidity The blogger says:`V8Safe` As a declaration `uint8`.Flap I'm in the upstream note.
/// Justify - Decoding a value above the local limit of the number count**On the spot. revert**:
///
/// > *Safe because Solidity revert when decoding an enum value that exceeds the enum's declared
/// > maximum (e.g. a new TOKEN_TAXED_V3 value read by a contract compiled against an old
/// > TokenVersion enum).*
///
/// The blogger says:Flap Will be on the way. `TokenStatus` Riga, a variant. Read. `getTokenV8` The contract will**From that moment on,
/// I can't read the price.**,And our vault is taking samples every hour -- it's gonna be quiet all day, and it's gonna be a little bit more fun.
/// And then... `openSeries` The "sampling" refused to open the series. So the camera went. `Safe` That one.
///
/// CRITICAL **The same reason applies to us.**:This warehouse is exposed. TWAP And the status code. `uint256` Not an item.
/// (See {CallVault.twap}).It's not a style choice. It's a copy. Flap The lessons of paying for it.
///
/// # Source (detainable, not duly graphed)
///
/// - Contract:Robinhood Chain(4663)`Portal` Proxy `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09`;
///   Field order originally taken from Blockscout Verified old realizations `0x7Bc20c2C...fA06`(`Portal` / solc 0.8.26);
/// - Current Achieved `0xa3b96Df56f254B926B17D5f7FB6CD858c216ff44` Not yet completed Blockscout Source code verification,
///   But the Chooser `getTokenV8Safe(address)` = `0x62fafcca` Still runtime bytes in code, and #146 It's new. GME
///   (a) A field-by-field review of the currency of valuation;
/// - Return value is **18 A static word**(576 bytes), field order with the following struct Unanimously  -
///   `test/fork/RobinhoodTwapSource.t.sol` Every time I run, it's real. Portal Review it up.
///
/// The semantics, schematics and full factual records of the two pits:`docs/research/flap-portal-price-semantics.md`.
interface IFlapPortalLens {
    /// @notice Flap A complete state snapshot of a token.**Field order ABI Order**,Changes it will be silently read.
    ///
    /// @dev Only the four fields consumed by this integration are documented here.
    ///      The "where does this statement come from" is a good way to be checked.
    ///
    /// @param status                   `TokenStatus`:0 Invalid  1 Tradable  2 InDuel(Discard)
    ///                                 3 Killed(Discard)  4 DEX  5 Staged.
    ///                                 CRITICAL We only accept. **1(Curve Phase)** and **4(Graduated)** Two-state
    /// @param reserve                  The reserve amount of the quote token held by the bonding curve
    /// @param circulatingSupply        The circulating supply of the token
    /// @param price                    CRITICAL **1e18 raw What's the unit's value? raw Value**(See {IFlapPortalLens} Top
    ///                                 and `docs/research/flap-portal-price-semantics.md`).
    ///                                 Upstream `LibCurve.price`  The original is  *"price (wei) of a token (1e18)"*,
    ///                                 Formula `k / (1e9 + h - s)2`(WAD Set points.
    ///                                 **After graduation, always `0`**  -  -  It's not speculation.
    /// @param tokenVersion             `TokenVersion`:6 = `TOKEN_TAXED_V3`
    /// @param r                        The curve parameter 'r' used for the bonding curve
    /// @param h                        The curve parameter 'h' - virtual token reserve
    /// @param k                        The curve parameter 'k' - square of virtual liquidity
    /// @param dexSupplyThresh          The circulating supply threshold for adding the token to the DEX
    /// @param quoteTokenAddress        CRITICAL **Value**;`address(0)` = Original currency.
    ///                                 The vault takes it with itself. `vaultQuoteToken()` Reconciliation -- no match.
    ///                                 `price` The denominator is not our stock coin. The reading is worthless.
    /// @param nativeToQuoteSwapEnabled Whether native-to-quote swap is enabled for this token
    /// @param extensionID              The extension ID used by the token (bytes32(0) if no extension)
    /// @param buyTaxRate               The buy tax rate in basis points (0 if not a tax token)
    /// @param sellTaxRate              The sell tax rate in basis points (0 if not a tax token)
    /// @param pool                     CRITICAL **After graduation DEX Ji.**(Not on the pool `address(0)`).
    ///                                 Robinhood Chain The facts are that **Uniswap V2 Shape pairing**
    ///                                 (`token0()` / `token1()` / `getReserves()` I'm here.`slot0()` revert)
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

    /// @notice Read a token of the state.
    /// @dev CRITICAL **When the token doesn't exist. revert**,Report `TokenNotFound(address)`(`0xde6137d1`,I'm sure it's a good idea.
    ///      So the caller must go down. `staticcall` Turning failure into a**Return value**,See {PriceSource.spot}.
    function getTokenV8Safe(address token) external view returns (TokenStateV8Safe memory state);
}

/// @title IDexPair
/// @notice After graduation, the pool. Uniswap V2 Shape reading interface.
///
/// @dev CRITICAL **Yes. V2 The shape is a theory, not a hypothesis.** Robinhood Chain Go, go, go! `migratorType` Only
///      `V2_MIGRATOR`(=1)It's gonna work.`ForkConfig` The three constants note notes the difference between what they say and what they say.
///      And... 269 The real graduation event brought a pool to ask:`token0()` / `token1()` / `getReserves()` I'm not sure if I can.
///      `slot0()`(V3  The landmark entrance **revert**.See review. `test/fork/RobinhoodTwapSource.t.sol`.
interface IDexPair {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Read the two legs of the reserve and the last update of the reserve. `uint32` Time stamp.
    /// @dev Timetamp V2 Agreed `uint32`;The reading price must equal the current price `uint32(block.timestamp)` Reserves
    ///      Considers the same block as an update and cannot be considered a sampled spot price.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
