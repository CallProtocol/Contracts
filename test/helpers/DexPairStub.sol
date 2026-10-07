// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title DexPairStub
/// @notice After graduation. Uniswap V2 The shape paired double, which fails as needed.
///
/// CRITICAL `DirtyReserves` / `DirtyTimestamp` Two are not a small number:`getReserves()` The three returns are declared as separate words
/// `uint112` / `uint112` / `uint32`,But... ABI There's nothing on the level.**Force**The other side follows the rules. Let a man cross the border.
/// The reserve will be released. `PriceSource` - Yes. `memeReserve * 1e18` **Spill revert**;Cutting off a cross-border time stamp will destroy it.
/// The same updated sentence, and the whole promise of that path is no. revert.
contract DexPairStub {
    enum Mode {
        Honest,
        RevertAll,
        ShortReserves,
        DirtyReserves,
        DirtyTimestamp,
        LongToken0,
        LongReserves
    }

    Mode public mode;

    address private _token0;
    address private _token1;
    uint256 private _reserve0;
    uint256 private _reserve1;
    uint32 private _blockTimestampLast;

    constructor(address token0_, address token1_) {
        _token0 = token0_;
        _token1 = token1_;
        _blockTimestampLast = _previousTimestamp();
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setTokens(address token0_, address token1_) external {
        _token0 = token0_;
        _token1 = token1_;
    }

    function setReserves(uint256 reserve0_, uint256 reserve1_) external {
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
    }

    /// @notice Controls alone V2 Last update time; default value is not meant to create stub .
    function setBlockTimestampLast(uint32 blockTimestampLast_) external {
        _blockTimestampLast = blockTimestampLast_;
    }

    function token0() external view returns (address) {
        Mode m = mode;
        if (m == Mode.RevertAll) revert(unicode"stub pair: token0 reverts");
        if (m == Mode.LongToken0) {
            bytes memory out = abi.encode(_token0, bytes32(uint256(1)));
            assembly ("memory-safe") {
                return(add(out, 0x20), mload(out))
            }
        }
        return _token0;
    }

    function token1() external view returns (address) {
        if (mode == Mode.RevertAll) revert(unicode"stub pair: token1 reverts");
        return _token1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        Mode m = mode;
        if (m == Mode.RevertAll) revert(unicode"stub pair: getReserves reverts");

        if (m == Mode.ShortReserves) {
            assembly {
                mstore(0, 1)
                return(0, 0x20)
            }
        }

        uint256 r0 = _reserve0;
        uint256 r1 = _reserve1;
        if (m == Mode.LongReserves) {
            bytes memory out = abi.encode(uint256(uint112(r0)), uint256(uint112(r1)), uint256(_blockTimestampLast), 1);
            assembly ("memory-safe") {
                return(add(out, 0x20), mload(out))
            }
        }

        if (m == Mode.DirtyReserves) {
            // Coming out. uint112 Reserves; time stamp is still controlled by normal path, so it does not cover up the stock ABI - The test.
            // Let's go. `abi.encode` Not the past. scratch space Write three words in it -- the latter will step on it. 0x40 Free memory pointer.
            bytes memory out = abi.encode(r0, r1, uint256(_blockTimestampLast));
            assembly {
                return(add(out, 0x20), mload(out))
            }
        }

        if (m == Mode.DirtyTimestamp) {
            // Keep the first two words in order, and make one more one more one more. uint32 The third word.
            bytes memory out = abi.encode(uint256(uint112(r0)), uint256(uint112(r1)), uint256(type(uint32).max) + 1);
            assembly {
                return(add(out, 0x20), mload(out))
            }
        }

        return (uint112(r0), uint112(r1), _blockTimestampLast);
    }

    function _previousTimestamp() private view returns (uint32) {
        // Yes. timestamp = 0 The rare test environment also maintains the default value "not currently block" .
        return block.timestamp == 0 ? type(uint32).max : uint32(block.timestamp - 1);
    }
}
