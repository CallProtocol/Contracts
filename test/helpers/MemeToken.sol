// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReentrancyInjector} from "./ReentrancyInjector.sol";

/// @title MemeToken
/// @notice 项目方 MEME（Flap 的 `FlapTaxTokenV3`）的替身。**这是外部依赖的替身，不是我们自己合约的
///         mock** —— issue #5 的测试纪律只禁止后者，并且点名「不变量 fuzz 用最小 ERC-20」。
///
/// 行权路径上 MEME 只承担一件事：`transferFrom(beneficiary, 0xdead, memeAmount)`。所以这个替身
/// 也只带那条路径上会被踩到的性质：
///
/// | 性质 | 它让哪条断言变得有意义 |
/// |---|---|
/// | **转账税**（`taxBps`） | 「池子**不**核对 `0xdead` 的余额增量」—— 零税代币下这个取舍看不出区别 |
/// | 任意 `mint` | 受益人余额、授权额度这两类失败要能被单独构造出来 |
///
/// 🔴 真实 Flap 代币在**这条路径上不收税**（实测：`0xdead` 实收恰好等于转出额）。这里之所以还留一个
/// 税开关，是因为「今天不收税」是**外部合约现在的行为**，而池子刻意不核对到账、且不可升级
/// —— 完整的理由只写在 `src/ClearingPool.sol` 的 `exercise` 上，这里不复述。
///
/// @dev 税率、`uiMultiplier`、门控这些「像哪只真实代币」的性质，各自的替身各留一份：它们会随里程碑
///      分头长大（#11 要在股票代币侧模拟门控语义，MEME 侧不会）。共用的只有纯机制的
///      {ReentrancyInjector}。
contract MemeToken is ERC20 {
    /// @notice 税收去处。真实代币是 taxProcessor；这里只要求它**不是** `0xdead`，
    ///         否则「被税吃掉的那一截」和「真的烧掉的那一截」在断言里分不开。
    address public constant TAX_SINK = address(uint160(uint256(keccak256("index-rein: meme tax sink"))));

    /// @notice 转账税，万分比。0 = 老实代币，也是真实 Flap 在销毁路径上的实测值。
    uint16 public taxBps;

    constructor() ERC20("Project Meme", "MEME") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxBps(uint16 bps) external {
        require(bps <= 10_000, "tax > 100%");
        taxBps = bps;
    }

    /// @dev 铸造与销毁不收税 —— 收了会让测试的初始余额对不上，而那不是任何真实代币的行为。
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

/// @notice `transferFrom` 返回 `true`，但转账阶段可以刻意不改变任何余额。
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

/// @notice `0xdead` 收到完整转账额，手续费作为 beneficiary 的额外扣款。
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
/// @notice 在**转账过程中**回调外部的 MEME。
///
/// 行权把控制权交出去**两次**：第 2 步的 MEME 转账、第 3 步的股票代币转账。两只代币都是任意合约
/// （`openSeries` 无许可），所以两条都得有人守。第 3 步那条由 {ReentrantStockToken} 守，
/// 这一份守的是第 2 步 —— 它比第 3 步更难看出来：此刻权证**已经销毁**、股票代币**还没转出**，
/// 池子正处在整条路径上账最不平的那一瞬间。
///
/// 回调怎么打、失败怎么记，与 {ReentrantStockToken} 共用 {ReentrancyInjector} —— 那是纯机制，
/// 与「像哪只真实代币」无关。
contract ReentrantMemeToken is MemeToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _fireReentrancy(from);
    }
}
