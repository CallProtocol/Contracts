// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PriceSource} from "../../src/PriceSource.sol";

/// @notice 把 {PriceSource} 那个 `internal` 的读价函数拉到一次**真实的外部调用**后面。
///
/// @dev 存在的理由有两条，第二条才是主要的：
///      ① `internal library` 的函数在测试合约里直接调也行，但那样跑的是**测试合约自己**的上下文；
///      ② 🔴 本库的核心承诺是「一律不 revert」。从测试合约里直接调，一次 revert 会直接
///         把测试炸掉，看起来就像断言失败；隔一层外部调用，才能用 `(bool ok, ) = probe.call(…)`
///         把「它 revert 了没有」变成一个**可断言的布尔值**。
contract PriceSourceProbe {
    function spot(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        return PriceSource.spot(portal, memeToken, quoteToken, false);
    }

    /// @dev 原生计价档（`wrapsNative = true`，C2 §7.14）：曲线阶段额外接受 `f[1] == address(0)`。
    function spotNative(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        return PriceSource.spot(portal, memeToken, quoteToken, true);
    }

    /// @dev 量一次**本次调用自己**花掉的 gas，用来钉「限额 staticcall 的开销确实有上界」。
    function spotGas(address portal, address memeToken, address quoteToken)
        external
        view
        returns (uint256 gasUsed, uint8 status)
    {
        uint256 before = gasleft();
        (status,,) = PriceSource.spot(portal, memeToken, quoteToken, false);
        gasUsed = before - gasleft();
    }
}
