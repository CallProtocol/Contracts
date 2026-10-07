// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPortalTypes} from "../../src/flap/IPortal.sol";
import {MemeToken} from "./MemeToken.sol";

/// @title PortalLaunchStub
/// @notice Flap `Portal.newTokenV6` The smallest double.**This is an externally dependent double, not our own contract. mock**
///          -  -  issue #5 The latter is only prohibited by the test discipline.
///
/// It only brings {CallLauncher} The ones that would step on:
///
/// | Nature | It makes any claim meaningful. |
/// |---|---|
/// | **Synchronize returns an address with a byte code** | This is... D0 Relative with-vault Total structural advantages of the path (spike 2) |
/// | **Retain the launch parameters received.** | Fixed economic parameters are determined by by bytes, while project fields are left open `antiFarmerDuration` It's all over the world. It's all true. calldata I'm gonna testify. |
/// | You can be asked.**Return zero address / Return an address without byte code** | launcher It's... {CallLauncher-LaunchReturnedNoToken} The door won't hit the real chain. |
/// | You can be asked.**Returning the same token twice** | The same one. MEME "I can't tie it twice." |
///
/// CRITICAL It's...**No, no.**Simulate Real Portal Any of the rules of operation (the rules of procedure)vanity salt,Frequency limits, valor configuration,
/// The number of pieces of the table is not one of our codes -- they're accepted by a cross at nail height.
/// (`test/fork/RobinhoodLauncher.t.sol`)In true Portal Check.
contract PortalLaunchStub {
    /// @notice Complete launch parameters received last time.
    /// @dev I'm not gonna do it. `public`:Automatic getter Yes. `string` / `bytes` The whole group is saved.
    ///      And...`meta` "There's no such thing as "that's one thing to say." {last} Return to Whole struct.
    IPortalTypes.NewTokenV6Params private _last;

    /// @notice A couple of times.
    uint256 public calls;

    /// @notice Last return token address.
    address public lastToken;

    /// @notice Last received `msg.value`.
    /// @dev BSC Go, go, go! ERC20 A tax is a fee for the construction of a currency. 1 gwei);launcher I'm not sure if I'm going to be able to get a hold of it.
    ///      This field makes "real truth" a certain fact. Portal The charge rules are not simulated here.
    uint256 public lastValue;

    /// @dev Not zero, that's all the money you'll get. wei Return to Caller (launcher) -  - To construct 'Portal I'll return the overpaid.
    ///      "The shape of the money, so that's good. launcher Zero residual guards (in the case of the{CallLauncher-LauncherRetainedValue})
    ///      There's a failure example. Portal It's not our code.
    uint256 public refundToCaller;

    function setRefundToCaller(uint256 amount) external {
        refundToCaller = amount;
    }

    /// @dev Non-zero hours**Do not build a new token**,returns it directly. Use it to construct it.Portal "Returned an address we've already tied."
    ///      The two forms of "return to an address without bytes" are unbreakable.
    address public forcedToken;

    /// @dev Returns zero address for real.
    bool public returnsZero;

    function setForcedToken(address token) external {
        forcedToken = token;
    }

    function setReturnsZero(bool value) external {
        returnsZero = value;
    }

    function last() external view returns (IPortalTypes.NewTokenV6Params memory) {
        return _last;
    }

    /// @notice Build a token and return its address - with truth Portal Same thing.**Sync**Back, and at that moment it had byte code.
    function newTokenV6(IPortalTypes.NewTokenV6Params calldata params) external payable returns (address token) {
        _last = params;
        lastValue = msg.value;
        calls += 1;

        // Optional: one sum ETH **Johnston.**To Caller (launcher),"The contract is more than a single one." ETHshape.
        // CRITICAL Use `selfdestruct` The first one is a new one.launcher No, I'm not. `receive()`,Normal `.call` It'll get you.
        //    Refuse. It's right in itself. It shouldn't be collected with regular transfers. ETH).The only thing that's gonna stop the Zero is the way around.
        //    `receive()` The force, so failure must follow this path.
        if (refundToCaller != 0) {
            new ForceSender{value: refundToCaller}(payable(msg.sender));
        }

        if (returnsZero) {
            lastToken = address(0);
            return address(0);
        }
        token = forcedToken != address(0) ? forcedToken : address(new MemeToken());
        lastToken = token;
    }
}

/// @notice  When you're building  ETH Now. `selfdestruct` - I'll put it in. `target`.
/// @dev It's a simulation of "Back" in a single test. `receive()` The only real trigger route for the zero-removed guards.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
