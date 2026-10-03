// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice The ERC-20 reads and approval the v1 frontend is allowed to use.
/// @dev This interface exists so the published ABI is generated with the Core
///      artifacts, rather than copied into a JavaScript package.
interface IERC20Ui {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Robinhood Stock reads used for display and issuer-gating status.
/// @dev `uiMultiplier` changes only presentation. Amounts sent to Core stay in
///      raw units, and a pending multiplier is shown before its effective time.
interface IRobinhoodStockUi is IERC20Ui {
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint64);
    function paused() external view returns (bool);
}
