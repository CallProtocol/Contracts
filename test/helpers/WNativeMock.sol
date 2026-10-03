// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WNativeMock
/// @notice canonical **WBNB / WETH** 的最小替身：`deposit()` 把原生币铸成等量 ERC20，
///         `withdraw()` 反过来。**这是外部依赖的替身，不是我们自己合约的 mock**（issue #5 的
///         纪律只禁后者）。
///
/// 它只带 {WarrantVault} 原生计价档（C2，研究文档 §7.14）会踩到的那几条性质：
///
/// | 性质 | 它让哪条断言变得有意义 |
/// |---|---|
/// | **`deposit()` 1:1 铸造、无回调** | 金库 `_wrapNative` 把到账原生 BNB 包进它、按 ERC20 余额差记账；无回调是「重入面不增大」的前提 |
/// | 标准 ERC20（transfer / approve / transferFrom） | 包完之后走的就是现有 WBNB 记账 → 存池那条路，逐字不变 |
/// | `withdraw()` | 只为完整性 —— 🔴 金库**从不调它**（creator fee 与行权都付 WBNB，前端自己 unwrap） |
///
/// 🔴 与 canonical WBNB 一致：`deposit` 无回调（只 credit balance）。金库因此不因原生档新增
///     任何重入面。上线前对真 WBNB 字节码复核这一条。
contract WNativeMock is ERC20 {
    constructor() ERC20("Wrapped BNB (mock)", "WBNB") {}

    /// @notice 把 `msg.value` 原生币铸成等量 WBNB 记在 `msg.sender` 名下。**无回调。**
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @dev canonical WBNB 的 `receive` 等价于 `deposit`。金库不走这条（它显式调 `deposit()`），
    ///      留着只为让直接转原生币进来也 1:1。
    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice 销毁 `amount` WBNB，退回等量原生币。🔴 金库从不调它。
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WNativeMock: native withdraw failed");
    }
}
