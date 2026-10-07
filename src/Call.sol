// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {ICall} from "./interfaces/ICall.sol";
import {PoolBound} from "./PoolBound.sol";

/// @title Call
/// @notice Certificate of Rights (Certificate)ERC-1155).`id = seriesId`,In the same series**Perfectly homogeneous.**,**Transfer of complete freedom**.
///
/// (a) The non-subsequent nature of homogeneity and free transfer, which are prerequisites for products: the order book cannot be replaced by the same week ' s certificate;
/// The door to transfer is not open to users in restricted jurisdictions without touching the cash path of the stock token.
/// `ClearingPool.exercise()` Go, go, go, go!**Not here.**(`docs/spec.md` / 10).
///
/// **Only `ClearingPool` It can cast and destroy.**,And the pool address is a one-time bound slot. {PoolBound}) -  -
/// Before binding. `pool == address(0)`,`onlyPool` All calls are denied.
///
/// @dev Timing and calibre of call for casting and destruction (all) raw `balanceOf` The group lives in a pool:
///      I'll be in the series and deposit. `ClearingPool.depositAndMint`(issue #9),
///      See you in the hall. `ClearingPool.exercise`(issue #10),See you on the road. issue #12.
contract Call is ERC1155, PoolBound, ICall {
    /// @dev `uri()` Other Organiserstrike,Current intrinsic value) is a front-end milestone M6,
    ///      And... ERC-1155 It's... URI Yes. OpenZeppelin v5 I can't. `_setURI` After the day, the contract was not open to comment, but to the point of the day.
    ///      Because it's the only place in the contract where someone can change something, and it's just a metadata facility.
    constructor() ERC1155("") {}

    /// @inheritdoc ICall
    function mint(address to, uint256 id, uint256 amount) external onlyPool {
        _mint(to, id, amount, "");
    }

    /// @inheritdoc ICall
    /// @dev CRITICAL Here.**Do not check authorization**,And common `burn` Make a difference -- because the only caller is the pool, and the pool is just...
    ///      `exercise()` Destroyed in the air.**The right caller himself**- The one in possession (in person, or `MerkleDistributor` the balance).
    ///      The authorization was expressed by "who initiated the right to do the business." ERC-1155 It's... `isApprovedForAll` Expression.
    ///      White list of calls to the pool side (for the beneficiary himself or herself) distributor)See `ClearingPool.exercise`.
    function burn(address from, uint256 id, uint256 amount) external onlyPool {
        _burn(from, id, amount);
    }
}
