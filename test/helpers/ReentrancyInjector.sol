// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ReentrancyInjector
/// @notice "In the course of the transfer, the outsider is called back."**Mechanisms**,It has nothing to do with the token on which it was loaded.
///
/// The two critical paths of the pool hand over control more than twice: the transfer and the certificate of rights to the shares at the time of deposit. `onERC1155Received`,
/// When you're in power, MEME The transfer is made in exchange for shares.**I need someone to watch every one of them.**,So the side side needs the same injection.
/// It's all on different tokens -- and it's pure mechanism, not modelling a real token.
///
/// The drawn boundary is drawn here:**Tax rates,`uiMultiplier`,The door controls the nature of which real tokens remain in their respective doubles.**
/// (They grow more each with the milestones, for example. #11 The idea of a model for the use of the Internet is to model the words of door control on the side of the stock coin.
/// The only one is "how to call back and how to forget how to fail."
///
/// @dev CRITICAL  Backlashed by**Swallow Record**,Instead of bubbles: so the outer layer can be called as usual, so the test can be said at the same time.
///      The internal section is rejected and the external section is still accurate. revert It's weaker than that...
///      It can't even say "is it the holding it?"
abstract contract ReentrancyInjector {
    address public reentryTarget;
    bytes public reentryPayload;

    /// @notice The inner circle is working. false.
    bool public reentrySucceeded;
    /// @notice The inner circle is back. revert Data (in the form of a bubble).
    bytes public reentryError;
    /// @notice The number of times that the echo actually happened - to prevent "not a single trigger" being used as "holds".
    uint256 public reentryAttempts;

    bool private firing;

    function armReentrancy(address target, bytes calldata payload) external {
        reentryTarget = target;
        reentryPayload = payload;
    }

    /// @dev In tokens. `_update` End of the line.
    /// @param from Turn out the side.`address(0)` It's foundry -- testing to set the initial balance should not trigger a backlash.
    function _fireReentrancy(address from) internal {
        if (firing || reentryTarget == address(0) || from == address(0)) return;

        firing = true;
        reentryAttempts++;
        (bool ok, bytes memory ret) = reentryTarget.call(reentryPayload);
        firing = false;

        reentrySucceeded = ok;
        reentryError = ret;
    }
}
