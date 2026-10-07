// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReentrancyInjector} from "./ReentrancyInjector.sol";

/// @title MemeToken
/// @notice Project MEME(Flap It's... `FlapTaxTokenV3`)The double.**This is an externally dependent double, not our own contract.
///         mock**  -  -  issue #5 The test discipline only forbids the latter and calls it "no variable." fuzz Use Minimum ERC-20.
///
/// Right-of-the-way path MEME Just one thing:`transferFrom(beneficiary, 0xdead, memeAmount)`.So this double...
/// The only thing that could be stepped on is the path:
///
/// | Nature | It makes any claim meaningful. |
/// |---|---|
/// | **Transfer tax**(`taxBps`) | I'm a pool.**No, no.**Check `0xdead` "The balance increases" -- the trade-off under zero tax is not different. |
/// | Any `mint` | The beneficiary balance, the amount of authority, and the two types of failure are to be constructed separately. |
///
/// CRITICAL Real Flap The token is in**There's no tax on this path.**(Actual:`0xdead` The collection is exactly the transfer. One of them is left here.
/// The tax switch is because "no tax today" is**The behavior of the outside contract now.**,And the pool is not checked and it can't be upgraded.
///  -  -  The whole reason is just in `src/ClearingPool.sol` It's... `exercise` Up, here's no repetition.
///
/// @dev Tax rates,`uiMultiplier`,The door controls the nature of the "what real token" and leaves one for each of the doubles: they follow the milestones.
///      Grow up in separate groups (in separate groups)#11 The idea of a model for a door-control semantic on the side of a stock coin is to create a model for the use of the word "supplexed" by the name of the person who is the owner of the stock.MEME Not on the side. Only pure mechanisms are shared.
///      {ReentrancyInjector}.
contract MemeToken is ERC20 {
    /// @notice Taxes go. Real tokens are... taxProcessor;It's all we're asking for here.**No, it's not.** `0xdead`,
    ///         The "taxed" and "fired" lines are not separated from the claim.
    address public constant TAX_SINK = address(uint160(uint256(keccak256("index-rein: meme tax sink"))));

    /// @notice Transfer tax, ten thousand.0 = It's true. It's true. Flap Actual values on the destruction path.
    uint16 public taxBps;

    constructor() ERC20("Project Meme", "MEME") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxBps(uint16 bps) external {
        require(bps <= 10_000, "tax > 100%");
        taxBps = bps;
    }

    /// @dev No tax on casting and destruction -- collection would not match the initial balance of the test, and that would not be any real token.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (taxBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * taxBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, TAX_SINK, fee);
    }
}

/// @notice `transferFrom` Back `true`,However, the transfer phase could be deliberately carried out without changing any balance.
contract NoOpMemeToken is MemeToken {
    bool public noOpTransfers;

    function setNoOpTransfers(bool enabled) external {
        noOpTransfers = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (noOpTransfers && from != address(0) && to != address(0)) return;
        super._update(from, to, value);
    }
}

/// @notice `0xdead` Full transfer amount received, fees as beneficiary - The extra deduction.
contract SenderPaysFeeMemeToken is MemeToken {
    uint16 public senderFeeBps;

    function setSenderFeeBps(uint16 bps) external {
        require(bps <= 10_000, "fee > 100%");
        senderFeeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (senderFeeBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        super._update(from, to, value);
        uint256 fee = (value * senderFeeBps) / 10_000;
        if (fee != 0) super._update(from, TAX_SINK, fee);
    }
}

/// @title ReentrantMemeToken
/// @notice Yes.**Transfer process**Revert outside. MEME.
///
/// Right of attorney. Give me control.**Twice.**:I'm sorry. 2 Step MEME Transfer, no. 3 The stock transfers. Both are on random contracts.
/// (`openSeries` No permission) so both articles have to be observed. 3 The step is... {ReentrantStockToken} Watch,
/// This is the first. 2 Step - It's better than the first 3 The steps are even more difficult to see:**Destroyed**,Stock tokens**It's not moving out yet.**,
/// The pool is at the worst moment of the entire path.
///
/// How to call back, how to remember how to fail, and with {ReentrantStockToken} Shared {ReentrancyInjector}  -  -  It's pure mechanism.
/// The government has not yet made a decision on the issue, but it has not yet done so.
contract ReentrantMemeToken is MemeToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _fireReentrancy(from);
    }
}
