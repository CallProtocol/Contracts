// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDexPair, IFlapPortalLens} from "./interfaces/IFlapPortalLens.sol";

/// @title PriceSource
/// @notice **1e18 raw What's the value of the unit shares? raw MEME**This one reading, two price sources, one fail code set.
///
/// # CRITICAL Quantification:Flap Here you go.**Last**,Not the number we want.
///
/// This is the most prone and expensive place to error on a promissory note, so it is written in the front.
///
/// Flap It's... `Portal.getTokenV8Safe(meme).price` Original upstream
/// *"price (wei) of a token (1e18)"*  -  -  That's... **1e18 raw MEME What's it worth? raw Value**.
/// And the vault. MEME Yes.**Value in stock currency**Launched (in the case of`vaultQuoteToken()` The price of the service is equal to the price of the service.
/// See `src/flap/VaultBaseV3.sol` Information on the implementation of the Convention 2),So:
///
/// | | Who's the price? | Who's the price? |
/// |---|---|---|
/// | Flap For you. `price` | MEME | Stock tokens |
/// | We want it. `strike` Same base reading | **Stock tokens** | **MEME** |
///
/// They're in the last place. `price` Save the ring buffer, get it. strike Yes.**I can't get confused with real values.**
/// (Volume differential 1030 But that's not the source of security -- the source of security is here to clear and gauge the inverted:
///
/// ```
/// 1e18 MEME_raw  = price       Equities_raw
/// 1    Equities_raw   = 1e18/price MEME_raw
/// 1e18 Equities_raw   = 1e36/price MEME_raw   <- That's what the bank returns.
/// ```
///
/// # CRITICAL Why?**Sample**Invert, not read.
///
/// Time weighted average**No trade-off with the countdown**:The last-in-the-count average is the reconciliation, and the two vary (in the case of the two).AM-HM).
/// That means "suspend." Flap The price, average and countdown, and "Countdown and average" are:**Two different. strike**.
/// Both of them can be said to be fair, so this is an option that must be decided on the basis of two reasons:
///
/// 1. **Tablet caliber**:Ring buffer `price` "Defined as1 Units stock What's it worth? MEME,and
///    `ClearingPool.Series.strike` Equivalent Outline (Systems)issue #34 Receiving and Inspection No. 1 When you take a sample, you can replay it.
///    M2-4 Just get the reading.**No further conversions required**  -  -  (a) One less conversion and one less scalable incident;
/// 2. **Diverse**:AM >= HM,So this is what this caliber gives us. strike **No less than**Another caliber.strike High
///    = More fire in the right. MEME = To the Treasury and MEME The holder is conservative. When both calibres are reasonable, take the conservative.
///
/// Inverse accuracy loss negligible: relative cut-off error <= `price / 1e36`,And... `price` On the real curve, 1e9 Scale
/// (I've been looking at it. `docs/research/flap-portal-price-semantics.md`),That's... ~1e-27.
///
/// # Two branches and switchover conditions
///
/// | Flap `status` | Branch | How do you get the price? |
/// |---|---|---|
/// | `1` Tradable(& On the Concord | Curve | `1e36 / price` |
/// | `4` DEX(Graduated) | I'm a pool. | `memeReserve * 1e18 / quoteReserve` |
/// | `0` Invalid  `2` InDuel  `3` Killed  `5` Staged |  -  -  | I'm not going to do it.{NOT_PRICEABLE} |
///
/// CRITICAL **We didn't pick the switch. Flap I'm not gonna let you do this.**:After graduation, `price` Fields**Constant `0`**
/// (- I'm sure. See? `docs/research/flap-portal-price-semantics.md` 3).So, "Reading the curve price after graduation."
/// Not "almost"**Read to Zero**.The reverse: without graduation `pool` It's a zero address, no pool to read.
/// Each branch is defined in its own state, without an overlap zone and without a vacuum.
///
/// # No one. revert
///
/// Every failed path returns one.**Status Code**,Not throw it out. The reason is caller. {CallVault.sampleTwap}
/// The government is not going to let the failure turn into a chain of alarmable events.`docs/spec.md`:The lack of samples can affect strike),
/// Not Jean. keeper The deal is red... keeper A deal could be a lot of money, bad news about a vault.
/// I should not have sat on the rest.`Portal` When the token doesn't exist.**Really? revert** ..of the`TokenNotFound(address)`,
/// Actual `0xde6137d1`),So we have to take the lower floor. `staticcall`.
library PriceSource {
    /// @notice Reads are available.
    uint8 internal constant OK = 0;
    /// @notice Portal Can't read it:revert(Ham `TokenNotFound`),Return data insufficient or burned down gas.
    uint8 internal constant PORTAL_UNREADABLE = 1;
    /// @notice CRITICAL Flap The amount of the price is not the amount of the principal bank's income. `price` The denominator is not our stock, readings are invalidated.
    uint8 internal constant QUOTE_MISMATCH = 2;
    /// @notice The token is neither on the curve nor graduated.Invalid / InDuel / Killed / Staged).
    uint8 internal constant NOT_PRICEABLE = 3;
    /// @notice The curve phase is a price that can't be used.`0`,The blogger says that the government is not going to be able to use the Internet to use it as a tool for the dissemination of information.
    uint8 internal constant CURVE_PRICE_INVALID = 4;
    /// @notice The pool can't read it, or the reserves it answers are coming out. `uint112`  -  -  That's not one. V2 Shape pair.
    uint8 internal constant POOL_UNREADABLE = 5;
    /// @notice The two legs of the pool are not. (MEME, Stock tokens).
    uint8 internal constant POOL_MISMATCH = 6;
    /// @notice The pool has shape but no goods and the price is not defined.
    uint8 internal constant POOL_EMPTY = 7;
    /// @notice The price is not going to fit. `uint192`(The width of the convection buffer).
    uint8 internal constant PRICE_OUT_OF_RANGE = 8;
    /// @notice The pool ' s reserves have just been upgraded in the current block and cannot be captured at spot prices that can be manipulated by the same block.
    uint8 internal constant POOL_UPDATED_THIS_BLOCK = 9;

    /// @notice No price was paid, so there was no source.
    uint8 internal constant SOURCE_NONE = 0;
    /// @notice This one's from**Concord Curve**.
    uint8 internal constant SOURCE_CURVE = 1;
    /// @notice This one's from**After graduation DEX Ji.**.
    ///
    /// @dev CRITICAL The source was brought into the event because "when did this project cut from curve to pool" was a single time.**It only happened once.
    ///      And change the trust model.**: Curve price from Flap A pure function, the pool price comes from any person who can add./- Dismantling.
    ///      Match. You need to see where a sample comes from, not ask it after. Portal
    ///      (The state of affairs had changed, and the answer was not available.
    uint8 internal constant SOURCE_POOL = 2;

    /// @dev Flap `status` The two of us are taking the value. The rest are all the same. {NOT_PRICEABLE}.
    uint256 private constant STATUS_TRADABLE = 1;
    uint256 private constant STATUS_DEX = 4;

    /// @dev `TokenStateV8Safe` Yes. 18 individual**Static**Words, so return values are they flatten. 576 bytes.
    ///
    ///      CRITICAL That's all. 576 Bytes, no. `abi.decode`,Two reasons:
    ///      (1) `(bool, bytes memory) = addr.staticcall(...)` Yes.**The whole thing.** returndata I'm not sure I'm going to be able to do this.
    ///         We'll pay for that memory expansion and not limit it. gas Inside (with `CallVault._quoteBalance` (a) The same pit;
    ///      (2) `abi.decode` Break `bool` / `uint8` Fields encountered**Unnormed code**(High-level bytes) revert,
    ///         And the whole of the bank's promise is no. revert.The type taken is completely unaffected.
    ///
    ///      Subscript & & & & & & & Subscript {IFlapPortalLens.TokenStateV8Safe} The fields are sequentially linked; the error does not fail to compile, and the result is that the number of people who have been killed is not equal to the number of people who have been killed.
    ///      So... `test/PriceSource.t.sol` Press one. struct **Regular Encoding**The double cross-checks the subscripts.
    uint256 private constant STATE_BYTES = 18 * 32;
    uint256 private constant W_STATUS = 0;
    uint256 private constant W_PRICE = 3;
    uint256 private constant W_QUOTE_TOKEN = 9;
    uint256 private constant W_POOL = 14;

    /// @dev Forward to Portal Camera gas ceiling.
    ///
    ///      Portal Yes. Flap An upgraded agent. How much does it cost to read at a time? gas It's not up to us; it's like a cap.
    ///      Will the sampling take keeper The government has been able to make a decision on the implementation of the bill.50 It's far greater than the cost of measuring.
    ///      (Real Portal Actual value on `test/fork/RobinhoodTwapSource.t.sol` Print and assert that there is a surplus.
    uint256 private constant PORTAL_READ_GAS = 500_000;

    /// @dev Forward to DEX Matches. gas The limit. Three readings are pure. storage,10 More than a million dollars.
    uint256 private constant POOL_READ_GAS = 100_000;

    /// @notice Current '1e18 raw What's the value of the shares? raw MEME.
    ///
    /// @param portal      It's in the chain. Flap `Portal`(Treasury from `VaultBase._getPortal()` Take it.
    /// @param memeToken   The one in the vault. MEME
    /// @param quoteToken  Currency of income of principal treasury = Bonded stock tokens
    ///
    /// @return status       {OK} or a certain failure code; {OK} Time `memePerStock` Constant `0`
    /// @return memePerStock 1e18 raw How much is the stock exchange? raw MEME(and `ClearingPool.Series.strike` The same model)
    /// @return source       {SOURCE_CURVE} / {SOURCE_POOL};Not {OK} Time {SOURCE_NONE}
    /// @param wrapsNative Whether or not this item**Native BNB Price**(C2,Research documents 7.14).For the Real Time Curve Phase Flap
    ///                    Report `quoteTokenAddress = address(0)`,And the vault. `quoteToken` Yes. WBNB  -  -
    ///                    Both 1:1,Same 18 Bits,price The values are consistent, so it's accepted extra. `f[1] == 0`.After graduation, I'm in the bottom.
    ///                    Yes. WBNB,`f[1]` Directly equals WBNB,No special sentences.
    function spot(address portal, address memeToken, address quoteToken, bool wrapsNative)
        internal
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        (bool readable, uint256[4] memory f) = _readState(portal, memeToken);
        if (!readable) return (PORTAL_UNREADABLE, 0, SOURCE_NONE);

        // CRITICAL The price is then the price. The whole article is in the bank.**Whole Word**Up instead of breaking it up. address:
        //    When the heights have dirty bytes `address(uint160(word))` We'll just leave them alone, and we'll just stop it.
        //    Additional original release `f[1] == 0`(Curve Phase Flap Report address(0),With the vault. WBNB . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .
        if (f[1] != uint256(uint160(quoteToken)) && !(wrapsNative && f[1] == 0)) {
            return (QUOTE_MISMATCH, 0, SOURCE_NONE);
        }

        if (f[0] == STATUS_TRADABLE) return _fromCurve(f[2]);
        if (f[0] == STATUS_DEX) {
            // `pool` Yeah. ABI Medium address.I can't believe it. 96 The position is already zero: reading the lower level gets the same word, and the lower level gets the same word.
            // Cutting off will make a deformity. Portal Responding to silently leading to a real pool.
            if (f[3] > type(uint160).max) return (PORTAL_UNREADABLE, 0, SOURCE_NONE);
            return _fromPool(address(uint160(f[3])), memeToken, quoteToken);
        }
        return (NOT_PRICEABLE, 0, SOURCE_NONE);
    }

    /// @dev Curve phase: Put Flap It's... `price` Invert. See the schematics at the top of the bank.
    function _fromCurve(uint256 flapPrice) private pure returns (uint8, uint256, uint8) {
        if (flapPrice == 0) return (CURVE_PRICE_INVALID, 0, SOURCE_NONE);

        // `flapPrice` Non-zero  Business <= 1e36,Always. uint192(Upper limit 6.28e57);
        // As 0 It's just that... `flapPrice > 1e36`,That's one. MEME - Yeah. 1e18 The stock is expensive. 10^18 Double--
        // It's not even worth reading when it's real. strike,Explicitly rejected.
        uint256 memePerStock = 1e36 / flapPrice;
        if (memePerStock == 0) return (CURVE_PRICE_INVALID, 0, SOURCE_NONE);
        return (OK, memePerStock, SOURCE_CURVE);
    }

    /// @dev After graduation: Read V2 Two paired legs.
    ///
    ///      CRITICAL `token0()` and `token1()` **Both of them.**,Not read one and assume the other. There's something in the pairs we don't know.
    ///      The token is for "stop" instead of "seek it as a stock" -- the latter is calculated from a completely irrelevant reserve.
    ///      One.**It looks normal.**The price, and then it's written in a ring buffer.
    function _fromPool(address pool, address memeToken, address quoteToken)
        private
        view
        returns (uint8, uint256, uint8)
    {
        if (pool == address(0)) return (POOL_UNREADABLE, 0, SOURCE_NONE);

        (bool ok0, uint256 token0) = _readWord(pool, abi.encodeCall(IDexPair.token0, ()));
        (bool ok1, uint256 token1) = _readWord(pool, abi.encodeCall(IDexPair.token1, ()));
        if (!ok0 || !ok1) return (POOL_UNREADABLE, 0, SOURCE_NONE);

        (bool okR, uint256[3] memory reserves) = _readReserves(pool);
        if (!okR) return (POOL_UNREADABLE, 0, SOURCE_NONE);
        // `getReserves()` The first two returns values are `uint112`,The third one is... `uint32`.There's only one way to cross the border.
        // - I'm not. ABI ; the first two words spill over the next multiplication, and the third word does not allow for the same block to be updated.
        // I can't let it go. revert Or take bad data as a price.
        if (reserves[0] > type(uint112).max || reserves[1] > type(uint112).max || reserves[2] > type(uint32).max) {
            return (POOL_UNREADABLE, 0, SOURCE_NONE);
        }

        // V2 Remember the last reserve update as `uint32`.The price of the same stock that just changed is manipulated.
        // So I'd rather take it out of the sample than out of the sample; the third word was a norm, as it was verified before the comparison. `uint32`.
        if (reserves[2] == uint256(uint32(block.timestamp))) return (POOL_UPDATED_THIS_BLOCK, 0, SOURCE_NONE);

        uint256 meme = uint256(uint160(memeToken));
        uint256 quote = uint256(uint160(quoteToken));

        uint256 memeReserve;
        uint256 quoteReserve;
        if (token0 == meme && token1 == quote) {
            (memeReserve, quoteReserve) = (reserves[0], reserves[1]);
        } else if (token0 == quote && token1 == meme) {
            (memeReserve, quoteReserve) = (reserves[1], reserves[0]);
        } else {
            return (POOL_MISMATCH, 0, SOURCE_NONE);
        }

        if (memeReserve == 0 || quoteReserve == 0) return (POOL_EMPTY, 0, SOURCE_NONE);

        // It's based on target size, not "first count." MEME The price is again in the last place - less than one round, less than one spin.
        // Upper boundary:uint112 Most likely. 5.19e33,Multiply 1e18 = 5.19e51,Off uint256 It's still far.
        uint256 memePerStock = (memeReserve * 1e18) / quoteReserve;
        if (memePerStock == 0) return (POOL_EMPTY, 0, SOURCE_NONE);
        if (memePerStock > type(uint192).max) return (PRICE_OUT_OF_RANGE, 0, SOURCE_NONE);
        return (OK, memePerStock, SOURCE_POOL);
    }

    /// @dev Read it. Portal Camera, take out the four words we depend on:`[status, quoteTokenAddress, price, pool]`.
    ///      Return value to press**Use**Sort instead of press ABI Sort the bottom so that the call point is read out as a sentence.
    function _readState(address portal, address token) private view returns (bool readable, uint256[4] memory f) {
        if (portal.code.length == 0) return (false, f);

        bytes memory callData = abi.encodeCall(IFlapPortalLens.getTokenV8Safe, (token));
        bytes memory buffer = new bytes(STATE_BYTES);

        bool ok;
        uint256 returned;
        assembly ("memory-safe") {
            ok := staticcall(
                PORTAL_READ_GAS,
                portal,
                add(callData, 0x20),
                mload(callData),
                add(buffer, 0x20),
                STATE_BYTES
            )
            returned := returndatasize()
        }
        // CRITICAL **Just right.** 576 bytes, not "at least". Static struct It's... ABI The length of the code is certain.
        //    One more word indicates that the shape that we thought was not returned -- what was read at that time by pressing the mark -- is not the shape that we thought it was.
        //    Nobody knows. The extra stuff is not hypothetical:`Flood` The first one to be returned was a large zero.
        //    It's going to go "at least" under the "at least" rule, "no price bill," and the real cause of the disease is the wrong shape.
        if (!ok || returned != STATE_BYTES) return (false, f);

        assembly ("memory-safe") {
            let head := add(buffer, 0x20)
            mstore(f, mload(add(head, mul(W_STATUS, 0x20))))
            mstore(add(f, 0x20), mload(add(head, mul(W_QUOTE_TOKEN, 0x20))))
            mstore(add(f, 0x40), mload(add(head, mul(W_PRICE, 0x20))))
            mstore(add(f, 0x60), mload(add(head, mul(W_POOL, 0x20))))
        }
        readable = true;
    }

    /// @dev One time only. 32 Byte limit `staticcall`.For the collection area scratch space(0x00-0x3f),
    ///      Do not move the free memory pointer, so yes memory-safe Yeah.
    function _readWord(address target, bytes memory callData) private view returns (bool ok, uint256 word) {
        uint256 returned;
        assembly ("memory-safe") {
            ok := staticcall(POOL_READ_GAS, target, add(callData, 0x20), mload(callData), 0x00, 0x20)
            returned := returndatasize()
            word := mload(0x00)
        }
        if (!ok || returned != 32) return (false, 0);
    }

    /// @dev `getReserves()` Three words, more than that. scratch space,So one article alone.
    function _readReserves(address pool) private view returns (bool ok, uint256[3] memory reserves) {
        bytes memory callData = abi.encodeCall(IDexPair.getReserves, ());
        uint256 returned;
        bool success;
        assembly ("memory-safe") {
            success := staticcall(POOL_READ_GAS, pool, add(callData, 0x20), mload(callData), reserves, 0x60)
            returned := returndatasize()
        }
        if (!success || returned != 0x60) return (false, reserves);
        ok = true;
    }
}
