// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WNativeMock
/// @notice canonical **WBNB / WETH** The smallest double:`deposit()` Make the original equivalent. ERC20,
///         `withdraw()` The reverse.**This is an externally dependent double, not our own contract. mock**(issue #5 It's...
///         Discipline is prohibited only for the latter).
///
/// It only brings {CallVault} Original livelihood price (%)C2,Research documents 7.14)The ones that would step on:
///
/// | Nature | It makes any claim meaningful. |
/// |---|---|
/// | **`deposit()` 1:1 Castery, no recall.** | Treasury `_wrapNative` Get the books to the original. BNB Wrap it in. Press it. ERC20 Balance balances recorded; no return is a prerequisite for " no increase in return " |
/// | Standard ERC20(transfer / approve / transferFrom) | After the bag, the rest of the world is left. WBNB Recording -> The way to the pool, it's the same word for word. |
/// | `withdraw()` | For integrity only... CRITICAL Treasury**Never tune it.**(creator fee I'll pay you for the right to trade. WBNB,Front to Yourself unwrap) |
///
/// CRITICAL and canonical WBNB Unanimously:`deposit` No return (only) credit balance).The vault is therefore not added to the original file.
///     Any re-entry. WBNB Byte code reviews this article.
contract WNativeMock is ERC20 {
    constructor() ERC20("Wrapped BNB (mock)", "WBNB") {}

    /// @notice - Put it on. `msg.value` Original currency equivalent WBNB Here. `msg.sender` Under name.**No recall.**
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @dev canonical WBNB It's... `receive` Equivalent to `deposit`.The vault doesn't go this way. `deposit()`),
    ///      I'm keeping it for direct transfer. 1:1.
    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Destruction `amount` WBNB,Refund the original equivalent.CRITICAL The vault never transfers it.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WNativeMock: native withdraw failed");
    }
}
