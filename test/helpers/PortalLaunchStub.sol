// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPortalTypes} from "../../src/flap/IPortal.sol";
import {MemeToken} from "./MemeToken.sol";

/// @title PortalLaunchStub
/// @notice Flap `Portal.newTokenV6` 的最小替身。**这是外部依赖的替身，不是我们自己合约的 mock**
///         —— issue #5 的测试纪律只禁止后者。
///
/// 它只带 {WarrantLauncher} 会踩到的那几条性质：
///
/// | 性质 | 它让哪条断言变得有意义 |
/// |---|---|
/// | **同步返回一个已经有字节码的地址** | 这是 D0 相对 with-vault 路径的全部结构性优势（spike §2） |
/// | **原样留存收到的那份发射参数** | 固定经济参数由字节码决定、而项目字段与未决的 `antiFarmerDuration` 原样透传，都要靠比对真实 calldata 来证 |
/// | 可以被要求**返回零地址 / 返回一个没有字节码的地址** | launcher 的 {WarrantLauncher-LaunchReturnedNoToken} 那道门在真链上撞不到 |
/// | 可以被要求**返回同一只代币两次** | 「同一只 MEME 绑不了第二次」在真链上撞不到（地址唯一） |
///
/// 🔴 它**不**模拟真实 Portal 的任何一条业务规则（vanity salt、频率限制、计价币配置、
/// 枚举取值），因为那几条没有一条是我们的代码 —— 它们由钉死高度的分叉验收
/// （`test/fork/RobinhoodLauncher.t.sol`）在真 Portal 上证。
contract PortalLaunchStub {
    /// @notice 上一次收到的完整发射参数。
    /// @dev 不做成 `public`：自动 getter 会把 `string` / `bytes` 成员整个省掉，
    ///      而「`meta` 有没有原样透传」正是要断言的东西之一。走 {last} 返回整个 struct。
    IPortalTypes.NewTokenV6Params private _last;

    /// @notice 一共被调了几次。
    uint256 public calls;

    /// @notice 上一次返回的代币地址。
    address public lastToken;

    /// @notice 上一次收到的 `msg.value`。
    /// @dev BSC 上 ERC20 计价的税代币建币要一笔建币费（实测 1 gwei）；launcher 把它原样透传，
    ///      本字段让「确实透传了」成为可断言的事实。真 Portal 的收费规则不在这里模拟。
    uint256 public lastValue;

    /// @dev 非零时，建币后把这么多 wei 退回调用方（launcher）——用来构造「Portal 退回多付的
    ///      建币费」这一形状，好让 launcher 的零残留守卫（{WarrantLauncher-LauncherRetainedValue}）
    ///      有一个失败用例。真 Portal 退不退、退多少不在我们的代码里。
    uint256 public refundToCaller;

    function setRefundToCaller(uint256 amount) external {
        refundToCaller = amount;
    }

    /// @dev 非零时**不建新代币**，直接返回它。用来构造「Portal 返回了一个我们已经绑过的地址」
    ///      与「返回一个没有字节码的地址」这两种真链上撞不到的形状。
    address public forcedToken;

    /// @dev 为真时返回零地址。
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

    /// @notice 建一只代币并返回它的地址 —— 与真 Portal 一样**同步**返回，且那一刻它已有字节码。
    function newTokenV6(IPortalTypes.NewTokenV6Params calldata params) external payable returns (address token) {
        _last = params;
        lastValue = msg.value;
        calls += 1;

        // 可选：把一笔 ETH **强塞**给调用方（launcher），制造「合约名下凭空多出 ETH」形状。
        // 🔴 用 `selfdestruct` 而不是普通转账：launcher 没有 `receive()`，普通 `.call` 会被它
        //    拒掉（这本身是对的——它不该用常规转账收 ETH）。零残留守卫真正要拦的正是绕过
        //    `receive()` 的强塞，所以失败用例必须走这条路。
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

/// @notice 把构造时收到的 ETH 立刻 `selfdestruct` 强塞给 `target`。
/// @dev 用来在单测里模拟「绕过 `receive()` 的强制转账」——零残留守卫的唯一真实触发路径。
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
