// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";

/// @title FlapPortalStub
/// @notice Flap `Portal` 镜头面的替身：**每个字段都能摆**，而且能按需返回几种畸形响应。
///
/// # 🔴 它同时是「下标读对了没有」的非循环证据
///
/// `PriceSource` 不用 `abi.decode`，而是按**字下标**从 576 字节里取那四个字段（理由见那里）。
/// 下标写错不会编译失败，也不会在任何只读 `PriceSource` 自己的测试里露馅。
///
/// 所以这个替身的 `Honest` 分支刻意走 **Solidity 自己的 ABI 编码器**返回
/// {IFlapPortalLens.TokenStateV8Safe}：编码顺序由编译器按 struct 声明生成，
/// 与 `PriceSource` 那四个常量**没有任何共同来源**。两边对上了，下标才算被证明。
///
/// | 模式 | 模拟的是 |
/// |---|---|
/// | `Honest` | 正常读 |
/// | `Revert` | 代币不存在 —— 真实 Portal 报 `TokenNotFound(address)`（实测 `0xde6137d1`） |
/// | `Short` | 返回数据不足 576 字节（Flap 换了更窄的镜头，或代理指错了实现） |
/// | `BurnGas` | 镜头变重到烧光转发过去的限额 gas |
/// | `Flood` | 返回一大片数据 —— 复制它的账**由调用方付，且不在限额 gas 之内** |
/// | `DirtyPool` | 维持 576 字节形状，但将 `pool` 的 address word 高 96 位写脏 |
contract FlapPortalStub {
    enum Mode {
        Honest,
        Revert,
        Short,
        BurnGas,
        Flood,
        DirtyPool
    }

    /// @dev 与 {HostileQuoteToken} 同一个量级：在 50 万 gas 的限额里造得出来的返回数据。
    uint256 private constant FLOOD_BYTES = 9000 * 32;

    Mode public mode;

    mapping(address token => IFlapPortalLens.TokenStateV8Safe state) private _states;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setState(address token, IFlapPortalLens.TokenStateV8Safe calldata state) external {
        _states[token] = state;
    }

    /// @dev 曲线阶段（`status = 1`）的常用摆法。
    function setCurve(address token, address quoteToken, uint256 price) external {
        IFlapPortalLens.TokenStateV8Safe storage s = _states[token];
        s.status = 1;
        s.quoteTokenAddress = quoteToken;
        s.price = price;
        s.pool = address(0);
        s.tokenVersion = 6;
    }

    /// @dev 毕业之后（`status = 4`）的常用摆法：曲线价归零、池子地址就位 —— 与实测一致。
    function setGraduated(address token, address quoteToken, address pool) external {
        IFlapPortalLens.TokenStateV8Safe storage s = _states[token];
        s.status = 4;
        s.quoteTokenAddress = quoteToken;
        s.price = 0;
        s.pool = pool;
        s.tokenVersion = 6;
    }

    function setStatus(address token, uint8 status) external {
        _states[token].status = status;
    }

    function getTokenV8Safe(address token) external view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        Mode m = mode;

        if (m == Mode.Revert) {
            // 真实 Portal 的错误形状：`TokenNotFound(address)`。
            revert(unicode"stub portal: TokenNotFound");
        }

        if (m == Mode.Short) {
            assembly {
                mstore(0, 1)
                return(0, 0x40)
            }
        }

        if (m == Mode.Flood) {
            uint256 size = FLOOD_BYTES;
            assembly {
                return(0, size)
            }
        }

        if (m == Mode.DirtyPool) {
            bytes memory out = abi.encode(_states[token]);
            assembly ("memory-safe") {
                // `pool` 是 18 字段 struct 中的第 14 个 0-based ABI word。
                let poolWord := add(add(out, 0x20), mul(14, 0x20))
                mstore(poolWord, or(mload(poolWord), shl(160, 1)))
                return(add(out, 0x20), mload(out))
            }
        }

        if (m == Mode.BurnGas) {
            // 跑不完的循环。`x` 必须真的被用掉，否则优化器会把整段当死代码删掉，
            // 于是这一档就会安静地退化成 `Honest`（与 {HostileQuoteToken} 同一处坑）。
            uint256 x = uint256(uint160(token));
            for (uint256 i = 0; i < type(uint256).max; i++) {
                x = uint256(keccak256(abi.encode(x, i)));
            }
            IFlapPortalLens.TokenStateV8Safe memory burned;
            burned.price = x;
            return burned;
        }

        return _states[token];
    }
}
