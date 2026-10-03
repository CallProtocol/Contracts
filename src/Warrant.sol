// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {IWarrant} from "./interfaces/IWarrant.sol";
import {PoolBound} from "./PoolBound.sol";

/// @title Warrant
/// @notice 权证（ERC-1155）。`id = seriesId`，同一系列内**完全同质**，**转让完全自由**。
///
/// 同质与自由转让不是顺手给的性质，它们是产品的前提：订单簿要有深度，就不能让同一周的权证彼此不可替换；
/// 受限辖区的用户要有一条不触及股票代币的变现路径，就不能给转让设门。合规声明那道门只出现在
/// `ClearingPool.exercise()` 上，**不出现在这里**（`docs/spec.zh.md` §5.5 / §10）。
///
/// **只有 `ClearingPool` 能铸造与销毁**，而池地址是一次性绑定的槽（见 {PoolBound}）——
/// 绑定之前 `pool == address(0)`，`onlyPool` 拒绝一切调用。
///
/// @dev 铸造与销毁的调用时机、数量口径（一律 raw `balanceOf` 单位）住在池子里：
///      开系列与存入即铸见 `ClearingPool.depositAndMint`（issue #9），
///      行权见 `ClearingPool.exercise`（issue #10），滚存见 issue #12。
contract Warrant is ERC1155, PoolBound, IWarrant {
    /// @dev `uri()` 暂为空串。系列元数据（标的、到期、strike、当前内在价值）属于前端里程碑 M6，
    ///      而 ERC-1155 的 URI 在 OpenZeppelin v5 里可由 `_setURI` 事后设置 —— 本合约不开这个口子，
    ///      因为它会是这个合约上唯一一处「有人能改点什么」的地方，而它换来的只是元数据的便利。
    constructor() ERC1155("") {}

    /// @inheritdoc IWarrant
    function mint(address to, uint256 id, uint256 amount) external onlyPool {
        _mint(to, id, amount, "");
    }

    /// @inheritdoc IWarrant
    /// @dev 🔴 这里**不检查授权**，与常见的 `burn` 实现不同 —— 因为唯一的调用方是池子，而池子只在
    ///      `exercise()` 里销毁**行权调用方自己**持有的那一份（本人，或 `MerkleDistributor` 的自有余额）。
    ///      授权由「谁发起了那次行权」表达，不由 ERC-1155 的 `isApprovedForAll` 表达。
    ///      池子侧的调用方白名单（受益人本人或 distributor）见 `ClearingPool.exercise`。
    function burn(address from, uint256 id, uint256 amount) external onlyPool {
        _burn(from, id, amount);
    }
}
