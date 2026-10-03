// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title ReentrantWarrantReceiver
/// @notice 在**收到权证的那一刻**回调池子的收款方。
///
/// # 为什么这个替身必须存在
///
/// `depositAndMint` 有两条外部调用，两条都能把控制权交出去：
///
/// | 交出去的地方 | 谁能利用 |
/// |---|---|
/// | `stock.safeTransferFrom` | 带转账钩子的股票代币，见 {ReentrantStockToken} |
/// | `warrant.mint` → `onERC1155Received` | **任意收款方** —— ERC-1155 对合约收款方强制回调 |
///
/// 第二条尤其值得单独测：本合约自己也开了一个系列，所以它是**那个系列的金库**，
/// 它的再入调用**通过**授权检查。挡住它的只剩 `nonReentrant` 一件东西。
///
/// @dev 回调失败被**吞掉并记录**，而不是冒泡 —— 这样外层存入照常完成，
///      测试才能同时断言「内层被拒」与「外层的账依然精确」。同 {ReentrantStockToken} 的取舍。
contract ReentrantWarrantReceiver {
    IClearingPool public immutable pool;

    /// @notice 本合约自己开的系列。它是这个系列的金库，因此有权对它 `depositAndMint`。
    uint256 public ownSeriesId;

    /// @notice 再入时尝试存入的数量。0 表示不再入。
    uint256 public reentryAmount;

    bool public reentrySucceeded;
    bytes public reentryError;
    uint256 public reentryAttempts;

    bool private firing;

    constructor(IClearingPool pool_) {
        pool = pool_;
    }

    function openOwnSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256)
    {
        ownSeriesId = pool.openSeries(memeToken, stockToken, expiry, strike);
        return ownSeriesId;
    }

    function approve(IERC20 token, uint256 amount) external {
        token.approve(address(pool), amount);
    }

    function armReentrancy(uint256 amount) external {
        reentryAmount = amount;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (!firing && reentryAmount != 0) {
            firing = true;
            reentryAttempts++;
            (bool ok, bytes memory ret) = address(pool)
                .call(abi.encodeCall(IClearingPool.depositAndMint, (ownSeriesId, address(this), reentryAmount)));
            firing = false;

            reentrySucceeded = ok;
            reentryError = ret;
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
}
