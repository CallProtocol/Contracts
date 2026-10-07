// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";

/// @title ReentrantCallReceiver
/// @notice Yes.**The moment I got the call,**Redirect the pool payees.
///
/// # Why does this double have to exist?
///
/// `depositAndMint` There are two external calls, and both can hand over control:
///
/// | Where I'm giving it away. | Who can use it? |
/// |---|---|
/// | `stock.safeTransferFrom` | - The stock token with the transfer hook. {ReentrantStockToken} |
/// | `call.mint` -> `onERC1155Received` | **Arbitrary payee**  -  -  ERC-1155 Forced recall of contract recipients |
///
/// The second article is particularly worth taking into account: the contract itself has a series, so it is.**The vault in that series.**,
/// It's re-trieving.**Pass.**Authorise inspection. Only hold it back. `nonReentrant` Something.
///
/// @dev  Backlashed by**Swallow Record**,Instead of bubbles -- so the outer layer is normally filled up,
///      The test is to say that the "rejection of the inner layer" is the same as the "outside level accounts are still accurate". {ReentrantStockToken} The trade.
contract ReentrantCallReceiver {
    IClearingPool public immutable pool;

    /// @notice This contract is a series of its own. It's a collection of the vaults, and it's entitled to it. `depositAndMint`.
    uint256 public ownSeriesId;

    /// @notice The amount that you try to deposit when re-entry.0 Means no more.
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
