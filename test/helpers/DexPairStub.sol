// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title DexPairStub
/// @notice 毕业之后那个 Uniswap V2 形状配对的替身，可按需失败。
///
/// 🔴 `DirtyReserves` / `DirtyTimestamp` 两档不是凑数的：`getReserves()` 的三个返回字分别声明成
/// `uint112` / `uint112` / `uint32`，但 ABI 层面没有任何东西**强制**对方守规矩。放行一个越界的
/// 储备会让 `PriceSource` 里的 `memeReserve * 1e18` **溢出 revert**；截断一个越界时间戳则会破坏
/// 同块更新的判据，而那条路径的全部承诺就是不 revert。
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

    /// @notice 单独控制 V2 的最后更新时刻；默认值刻意不是创建 stub 的当前块。
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
            // 越出 uint112 的储备；时间戳仍按常规路径可控，免得它掩盖储备 ABI 的测试。
            // 走 `abi.encode` 而不是往 scratch space 里写三个字 —— 后者会踩到 0x40 的自由内存指针。
            bytes memory out = abi.encode(r0, r1, uint256(_blockTimestampLast));
            assembly {
                return(add(out, 0x20), mload(out))
            }
        }

        if (m == Mode.DirtyTimestamp) {
            // 前两字保持规范，单独伪造一个越出 uint32 的第三字。
            bytes memory out = abi.encode(uint256(uint112(r0)), uint256(uint112(r1)), uint256(type(uint32).max) + 1);
            assembly {
                return(add(out, 0x20), mload(out))
            }
        }

        return (uint112(r0), uint112(r1), _blockTimestampLast);
    }

    function _previousTimestamp() private view returns (uint32) {
        // 在 timestamp = 0 的罕见测试环境也保持「不是当前块」的默认值。
        return block.timestamp == 0 ? type(uint32).max : uint32(block.timestamp - 1);
    }
}
