// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title HostileQuoteToken
/// @notice 一个只有 `balanceOf` 的收入币种替身，可以按需**用四种方式失败**。
///
/// 🔴 它证的是金库那条最硬的承诺：**`receive()` 任何路径都不 revert**。
///
/// 这条承诺的赌注不在我们这边 —— `receive()` 由 Flap 的 dispatch 触发，它一旦 revert，
/// 受影响的是 Flap 的税收结算：**我们的 bug 会变成 Flap 的事故**。而 `receive()` 里唯一
/// 不受我们控制的一步，正是读收入币种余额这次外部调用：收入币种是 BeaconProxy → `Stock`，
/// 发行方随时可以整体换掉实现。
///
/// 老实的 ERC-20 替身（{StockToken}）证明不了这件事 —— 它当然不会失败，因为我们没写那行代码。
///
/// | 模式 | 模拟的是 |
/// |---|---|
/// | `Revert` | 实现被换成会 revert 的版本（例如加了黑名单检查、或整体暂停） |
/// | `Empty` | 地址上没有代码 / 代理指向空实现 —— `staticcall` 返回**成功**且数据为空 |
/// | `Short` | 返回数据不足 32 字节，`abi.decode` 会 revert |
/// | `BurnGas` | 实现变重到烧光转发过去的限额 gas |
/// | `Flood` | 返回一大片数据 —— 复制它的账**由调用方付，且不在限额 gas 之内** |
///
/// @dev 与 {StockToken} 的分工：那一份是「真实标的会有、老实 ERC-20 不会有」的**语义**替身
///      （转账税、`uiMultiplier`）；这一份是**失败注入器**，与 {GatedStockToken} 同类。
contract HostileQuoteToken {
    enum Mode {
        Honest,
        Revert,
        Empty,
        Short,
        BurnGas,
        Flood
    }

    /// @dev 返回数据的字节数。挑的是「在 20 万 gas 的限额里造得出来」的量级：
    ///      9000 字的内存扩张约 18.5 万 gas，而复制它同样要约 18.5 万 —— 那笔账落在调用方头上。
    uint256 private constant FLOOD_BYTES = 9000 * 32;

    Mode public mode;

    /// @notice `Honest` 模式下 `balanceOf` 报出来的数。
    uint256 public reported;

    function set(Mode mode_, uint256 reported_) external {
        mode = mode_;
        reported = reported_;
    }

    function balanceOf(address) external view returns (uint256) {
        Mode m = mode;

        if (m == Mode.Revert) revert(unicode"hostile quote: balanceOf reverts");

        if (m == Mode.Empty) {
            assembly {
                return(0, 0)
            }
        }

        if (m == Mode.Short) {
            assembly {
                mstore(0, 1)
                return(0, 4)
            }
        }

        if (m == Mode.Flood) {
            uint256 size = FLOOD_BYTES;
            assembly {
                return(0, size)
            }
        }

        if (m == Mode.BurnGas) {
            // 一个跑不完的循环：把转发过来的 gas 烧光，让这次 staticcall 以 out-of-gas 收场。
            // 上界写成 `type(uint256).max` 而不是 `while (true)`，纯粹是为了函数有一条返回路径。
            uint256 x = reported;
            for (uint256 i = 0; i < type(uint256).max; i++) {
                x = uint256(keccak256(abi.encode(x, i)));
            }
            return x;
        }

        return reported;
    }
}
