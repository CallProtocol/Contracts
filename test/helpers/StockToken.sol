// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReentrancyInjector} from "./ReentrancyInjector.sol";

/// @title StockToken
/// @notice 抵押品（代币化股票）的替身。**这是外部依赖的替身，不是我们自己合约的 mock**
///         —— issue #5 的测试纪律只禁止后者。
///
/// 它刻意带三样真实标的会有、而一个「老实的 ERC-20」不会有的性质：
///
/// | 性质 | 它让哪条断言变得有意义 |
/// |---|---|
/// | **转账税**（`taxBps`） | 「按实际到账增量铸造，不按请求量」—— 零税代币下这两件事看不出区别 |
/// | **`uiMultiplier()`** | 「全部数量使用 raw `balanceOf` 单位」—— 拆股改的是这个数，不是余额 |
/// | 任意 `mint` | uint128 边界：真实 GME 到不了 2^128，但池子对**任何**股票代币都开着 |
///
/// 🔴 税收模型按**接收方少收**建模（`transfer(x)` 之后收款方 `+x−fee`），这正是
/// `depositAndMint` 会踩到的那一种：按 `expectedAmount` 铸造就等于凭空多发权证。
///
/// @dev 真实 GME 的门控（`pause` / `isBlocked` / `adminBurn`）**不在这里模拟** ——
///      那些只有分叉上的真合约测得准，见 `test/fork/RobinhoodExercise.t.sol`（issue #10）
///      与门控延期全路径（issue #11）。要让「第 3 步失败」这件事在本地确定性地发生，
///      用 {GatedStockToken}，它是**失败注入器**而不是门控语义的模型。
contract StockToken is ERC20 {
    /// @notice 税收去处。真实代币多半是个 treasury；这里只要求它**不是池子**。
    address public constant TAX_SINK = address(uint160(uint256(keccak256("index-rein: tax sink"))));

    /// @notice 转账税，万分比。0 = 老实代币。
    uint16 public taxBps;

    /// @notice EIP-8056 的显示乘数。拆股改的是它，**不是 `balanceOf`**。
    /// @dev 池子从头到尾不该读这个数。它在这里存在，是为了让「读了会怎样」变成一条可断言的事实。
    uint256 public uiMultiplier = 1e18;

    constructor() ERC20("Tokenized Stock", "STOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxBps(uint16 bps) external {
        require(bps <= 10_000, "tax > 100%");
        taxBps = bps;
    }

    function setUiMultiplier(uint256 multiplier) external {
        uiMultiplier = multiplier;
    }

    /// @dev 铸造（`from == 0`）与销毁（`to == 0`）不收税 —— 收了会让测试的初始余额对不上，
    ///      而那不是任何真实代币的行为。
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

/// @title GatedStockToken
/// @notice 让行权第 3 步（股票代币转给受益人）**确定性地失败**的注入器。
///
/// 🔴 **它不是 GME 门控的模型。** 真实的门控是「注册表里 `isBlocked(池子)`」「双层 `paused()`」，
/// 语义、revert 数据、影响面都只有分叉上的真合约测得准 —— 那是
/// `test/fork/RobinhoodExercise.t.sol` 的事，它 mock 的是注册表的读，走的仍是 GME 自己的修饰器。
///
/// 这里要的只是一件事：让最后一个外部调用**失败**，好断言不变量 3（任一子步骤失败 ⟹ 权证与 MEME
/// 余额均不变）。不变量测试不能依赖网络，所以这件事必须能在本地按开关发生。
///
/// @dev 铸造与销毁不受影响 —— 否则冻结期间连测试自己的初始余额都摆不出来。
contract GatedStockToken is StockToken {
    /// @notice 冻结中。真实世界里对应「池地址被封」或「代币被暂停」。
    bool public frozen;

    error IssuerFrozen();

    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen && from != address(0) && to != address(0)) revert IssuerFrozen();
        super._update(from, to, value);
    }
}

/// @notice ERC-20 调用返回 `true`，但转账阶段可以刻意不改变任何余额。
/// @dev 先正常存入抵押品，再开启开关，才能只攻击依赖 `transferFrom` 成功返回的路径。
contract NoOpStockToken is StockToken {
    bool public noOpTransfers;

    function setNoOpTransfers(bool enabled) external {
        noOpTransfers = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (noOpTransfers && from != address(0) && to != address(0)) return;
        super._update(from, to, value);
    }
}

/// @notice ERC-20 调用返回 `true`，但只移动请求量的一个**可调比例** —— 「部分扣款」的替身。
///
/// @dev 它是 {NoOpStockToken}（一分不动）与老实代币（全额移动）之间的整个连续档。金库的分成
///      记账若按**请求量**而不是**实测扣款**入账，这只代币就能让同一批收入在重试中被
///      反复切分（审计发现 M-01）—— 与假转账替身同理：老实代币证明不了这条纪律。
///      `setHalfDebit` 保留为 50% 那一档的便捷开关；任意比例走 `setDebitBps`
///      （10000 = 全额，0 = 等价于 {NoOpStockToken}），供随机序列的上界 fuzz 用（复审 N-03）。
contract PartialDebitStockToken is StockToken {
    uint16 public debitBps = 10_000;

    function setHalfDebit(bool enabled) external {
        debitBps = enabled ? 5000 : 10_000;
    }

    function setDebitBps(uint16 bps) external {
        require(bps <= 10_000, "bps");
        debitBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (debitBps != 10_000 && from != address(0) && to != address(0)) {
            super._update(from, to, (value * debitBps) / 10_000);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice 一个 `balanceOf` 比金库 receive 的 20 万 gas 预算更慢、但在普通交易里仍可完成的标的。
/// @dev 固定工作量而不是烧光所有转发 gas：前者才能构造「封顶读失败、非封顶读成功」这个边界。
contract SlowBalanceStockToken is StockToken {
    uint256 private constant BALANCE_OF_WORK = 6000;

    function balanceOf(address account) public view override returns (uint256) {
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, BALANCE_OF_WORK) { i := add(i, 1) } { pop(keccak256(0, 0)) }
        }
        return super.balanceOf(account);
    }
}

/// @notice 模拟发行方可从任意地址销毁股票、并在升级后让余额读取失败的真实风险组合。
contract IssuerBurnableUnreadableStockToken is StockToken {
    error BalanceUnreadable();

    bool public balanceUnreadable;

    function adminBurn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setBalanceUnreadable(bool enabled) external {
        balanceUnreadable = enabled;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (balanceUnreadable) revert BalanceUnreadable();
        return super.balanceOf(account);
    }
}

/// @title GatedApprovalStockToken
/// @notice `approve` 会以**发行方自己的 custom error** 拒绝的股票代币。
///
/// 🔴 这不是臆想出来的坏代币：真实 GME 的 `approve` / `permit` 上就编译了
/// `onlyNotPaused` + `onlyNotBlocked`（`docs/research/robinhood-stock-token-permissions.md` §3），
/// 所以发行方一暂停，金库存入路径上**第一个**倒下的就是那次授权。
/// 它存在的意义只有一条：证明金库把那个原因**原样冒泡**了，而不是换成一句自己的「授权失败」——
/// 后者会把「发行方按了开关」误报成「我们的代码有问题」。
contract GatedApprovalStockToken is StockToken {
    error IssuerPaused();

    bool public approvalsBlocked;

    function setApprovalsBlocked(bool blocked) external {
        approvalsBlocked = blocked;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (approvalsBlocked) revert IssuerPaused();
        return super.approve(spender, value);
    }
}

/// @title SilentApprovalFailureStockToken
/// @notice `approve` 返回 `false` 而**不** revert —— 前 EIP-20 时代留下来的那种代币。
/// @dev 不判返回值的话，故障会推迟到池子的 `transferFrom`，报出来的原因就跟真正的病因无关了。
contract SilentApprovalFailureStockToken is StockToken {
    function approve(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @title DirtyBoolApprovalStockToken
/// @notice `approve` 返回一个既不是 0 也不是 1 的字。
///
/// 🔴 这个形状挡的是一条**报错会消失**的路：`abi.decode(ret, (bool))` 遇到脏布尔时，
/// solc 的校验器直接 `revert(0, 0)` —— 空 returndata。于是「授权失败」既冒泡不出对方的原因、
/// 也拿不到我们自己那句字面量串，前端按规范 rule 004 原样显示时什么都显示不出来，
/// 运维看到的是一次裸 revert，与 out-of-gas 无法区分。
///
/// @dev `ClearingPool._readGating` 用整段注释记下过同一件事并按 `uint256` 解；金库照抄那个做法。
///      非零即真，所以这只代币的授权**成功**——但它得走我们自己的判定，而不是把整笔炸成空 revert。
contract DirtyBoolApprovalStockToken is StockToken {
    function approve(address spender, uint256 value) public override returns (bool) {
        // 授权本身照常生效 —— 坏掉的只有**返回值的编码**，那正是要测的那一点。
        _approve(_msgSender(), spender, value);
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }
}

/// @notice 收款方拿到完整转账额，手续费作为发送方的额外扣款。
/// @dev 开关在存入完成后开启，专门构造池子扣款超过 `exercise` 行权量的路径。
contract SenderPaysFeeStockToken is StockToken {
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

/// @title ReentrantStockToken
/// @notice 在**转账过程中**回调外部的股票代币。
///
/// # 为什么这个替身必须存在
///
/// `depositAndMint` 的铸造量是「转账前后的余额差」。这个口径**天然对再入敏感**：
///
/// ```
/// 外层：before = B                      → 转入 T1 ─┐
///                                                  │ 代币在转账中回调
/// 内层：before = B + T1 → 转入 T2 → delta = T2 → 铸 T2
///                                                  │
/// 外层：after = B + T1 + T2 → delta = T1 + T2 → 再铸 T1 + T2
/// ```
///
/// 抵押品进来 `T1 + T2`，权证铸出 `T1 + 2·T2` —— **不变量 1 与 2 当场作废**。
///
/// 而池子对**任何**股票代币都开着（`openSeries` 无许可，见 `ClearingPool` 的注释），
/// 所以这条路径是可达的，不是理论。因此再入保护在这里是**承重**的，不是礼节。
///
/// 行权侧的对应物是 {ReentrantMemeToken}；回调怎么打、失败怎么记，两边共用 {ReentrancyInjector}。
contract ReentrantStockToken is StockToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _fireReentrancy(from);
    }
}

/// @title PreUpdateReentrantStockToken
/// @notice 同上，但回调打在**余额变动之前**。
///
/// 🔴 这个方向才是金库侧那条缝的形状。{ReentrantStockToken} 转完账才回调，回调看见的是**已经减少**的
/// 余额，于是任何「余额 vs 基线」的比较都天然安全 —— 它证明不了 `WarrantVault` 的记账顺序是对的。
///
/// 危险的顺序是这一个：金库正在把全部余额转出去，转账**还没生效**，回调就打回金库调 `sync()`。
/// 此刻余额仍是满的。金库若在外部调用**之前**就把 `accountedQuote` 清了零，这次 `sync()` 会看见
/// 「余额满、基线为 0」，于是把基线重新推到满额；等外层转账真的发生，基线就永久停在真实余额之上 ——
/// `balance <= accountedQuote` 从此压住一切收入识别，**金库死锁，而且一声不响**（规范 rule 010-3）。
///
/// @dev 与池子侧的用法（`ReentrantStockToken`，守的是余额差铸造被重复计数）是两条不同的缝，
///      共用同一套 {ReentrancyInjector}。
contract PreUpdateReentrantStockToken is StockToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        _fireReentrancy(from);
        super._update(from, to, value);
    }
}
