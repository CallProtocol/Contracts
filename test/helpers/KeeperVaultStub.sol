// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KeeperVaultStub
/// @notice `script/trigger-keeper.sh` 反证矩阵的可编程金库替身。**只被 shell 测试用，不进生产路径。**
///
/// # 为什么是一个 Solidity 替身，而不是注入字节码
///
/// `script/watch-market-wallet.test.sh` 的替身是两段手写 runtime（`anvil_setCode` 注入），
/// 因为那个监测器只读**一个**返回值，一段「对任何 calldata 都返回同一个字」的字节码就够了。
/// keeper 不同：它要读五个不同的 view，还要按**回执里出现了哪条事件**分出五种结局。
/// 手写一个带选择器分派、又能按开关发不同事件的 runtime，等于用汇编重写这个合约 ——
/// 那份汇编自己就会成为下一个要测的东西。
///
/// # 🔴 它刻意**不**实现金库的任何判据
///
/// 替身不算 TWAP、不判到期、不记账。它只做一件事：**按测试摆好的姿势回答**，
/// 于是每一条断言测的都是 keeper 的判定，而不是「我们把金库又实现了一遍，两遍是否一致」。
/// 判据本身在 `test/WarrantVault*.t.sol` 里被 Solidity 测试钉住。
///
/// ⚠️ 唯一必须与真金库逐字节一致的是**事件签名** —— keeper 按 topic0 分辨结局。
///    这件事不靠这份注释保证：反证矩阵会从 `src/WarrantVault.sol` 里 grep 出事件声明、
///    现算 keccak，再与 keeper 脚本里钉死的常量逐个比对。
contract KeeperVaultStub {
    // ─────────────────── 与 src/WarrantVault.sol 逐字节相同的事件 ───────────────────

    event TwapSampled(uint64 ts, uint256 price, uint8 source);
    event TwapSampleFailed(uint8 reason);
    event WeeklySeriesOpened(uint256 indexed seriesId, uint64 expiry, uint128 strike, uint256 twapPrice);
    event RevenueDeferred(uint256 balance, uint64 seriesExpiry);
    event RevenueDeposited(uint256 indexed seriesId, uint256 sent, uint256 minted);
    event QuoteBalanceUnreadable(address indexed quoteToken);

    // ─────────────────────────────── 可摆姿势的读数 ───────────────────────────────

    uint64 public lastSampleAt;
    uint64 public seriesExpiry;
    uint256 public twapStatus;
    uint256 public twapPrice;
    uint256 public openStatus;
    uint64 public openExpiry;
    uint128 public openStrike;
    uint256 public inTransitAmount;
    bool public inTransitExact = true;

    // ────────────────────────────────── 结局开关 ──────────────────────────────────
    //
    // 0 = 什么事件都不发（金库的「静默 no-op」/「被别人抢先」那条边）
    // 1 = 发成功事件
    // 2 = 发失败事件（采样：TwapSampleFailed(failReason)；收入：RevenueDeferred）
    // 3 = revert
    // 4 = 只用于收入：RevenueDeposited(sent = 0)，以及 QuoteBalanceUnreadable

    uint8 public sampleOutcome = 1;
    uint8 public revenueOutcome = 1;
    uint8 public openOutcome = 1;
    uint8 public failReason = 1;

    /// @notice 打开之后复刻真金库那道 `block.timestamp < lastSampleAt + 1 小时` 的静默 no-op。
    ///
    /// @dev 🔴 默认**关闭**，理由见 {sampleTwap}：反证矩阵要能区分「keeper 盲发了、链上挡住了」
    ///      与「keeper 正确地没发」。只有 48 小时长跑（`script/trigger-keeper.soak.sh`）需要它 ——
    ///      那一场要证明的恰恰是「keeper 与那道门配合之下，样本间隔始终 ≤ 65 分钟」，
    ///      而没有门的话这句话不成立也测不出来。
    bool public enforceInterval;

    /// @notice 打开之后 {twap} 与 {inTransit} 直接 revert。
    ///
    /// @dev 🔴 真金库的这两个 view **永不 revert**（它们把失败做成了返回值）。所以链上读不到
    ///      它们只可能是**我们这一侧**的问题 —— 端点坏了、地址填错。这个开关造出来的正是那个局面，
    ///      用来钉住一条容易写反的规矩：**清除一条旧告警需要一次成功的读**。
    ///      读不到就清告警的话，一次端点抖动就能把上一轮的真告警洗掉，而那恰恰是最不该洗掉的时候。
    ///      {lastSampleAt} 仍然照常回答 —— 否则 keeper 会在更早一步就整只金库拒判，测不到这一条。
    bool public revertViews;

    /// @notice 🔴 「keeper 有没有真的广播」的判据。断言它**没有**增加，就是断言那一笔没发出去。
    uint256 public sampleCalls;
    uint256 public revenueCalls;
    uint256 public openCalls;

    // ─────────────────────────────────── 摆姿势 ───────────────────────────────────

    function setLastSampleAt(uint64 value) external {
        lastSampleAt = value;
    }

    function setSeriesExpiry(uint64 value) external {
        seriesExpiry = value;
    }

    function setTwap(uint256 status, uint256 price) external {
        twapStatus = status;
        twapPrice = price;
    }

    function setOpen(uint256 status, uint64 expiry, uint128 strike) external {
        openStatus = status;
        openExpiry = expiry;
        openStrike = strike;
    }

    function setInTransit(uint256 amount, bool exact) external {
        inTransitAmount = amount;
        inTransitExact = exact;
    }

    function setEnforceInterval(bool value) external {
        enforceInterval = value;
    }

    function setRevertViews(bool value) external {
        revertViews = value;
    }

    function setOutcomes(uint8 sample_, uint8 revenue_, uint8 open_, uint8 reason_) external {
        sampleOutcome = sample_;
        revenueOutcome = revenue_;
        openOutcome = open_;
        failReason = reason_;
    }

    // ─────────────────────────── keeper 读的五个 view ───────────────────────────

    function twap() external view returns (uint256, uint256) {
        if (revertViews) revert("stub: twap unreadable");
        return (twapStatus, twapPrice);
    }

    function openSeriesStatus() external view returns (uint256, uint64, uint128) {
        return (openStatus, openExpiry, openStrike);
    }

    function inTransit() external view returns (uint256, bool) {
        if (revertViews) revert("stub: inTransit unreadable");
        return (inTransitAmount, inTransitExact);
    }

    // ────────────────────────── keeper 广播的三个入口 ──────────────────────────

    /// @dev 真金库在这里会 `block.timestamp < last + 1 小时` 时静默返回。替身**不**复刻那道门 ——
    ///      keeper 的正确行为是自己先读 `lastSampleAt()` 并不发这一笔，而复刻了门的替身
    ///      会让「keeper 盲发了、但链上挡住了」与「keeper 正确地没发」在断言上无法区分。
    ///      `sampleCalls` 就是那条区分线。
    function sampleTwap() external returns (bool) {
        sampleCalls += 1;
        // 计数在门之前 —— 那条计数线要回答的是「keeper 发没发」，不是「链上写没写」。
        if (enforceInterval && lastSampleAt != 0 && block.timestamp < uint256(lastSampleAt) + 3600) {
            return false;
        }
        if (sampleOutcome == 3) revert("stub: sampleTwap reverted");
        if (sampleOutcome == 2) {
            emit TwapSampleFailed(failReason);
            return false;
        }
        if (sampleOutcome == 1) {
            lastSampleAt = uint64(block.timestamp);
            emit TwapSampled(uint64(block.timestamp), twapPrice, 1);
            return true;
        }
        return false;
    }

    function processRevenue() external returns (uint256) {
        revenueCalls += 1;
        if (revenueOutcome == 3) revert("stub: processRevenue reverted");
        if (revenueOutcome == 2) {
            emit RevenueDeferred(inTransitAmount, seriesExpiry);
            return 0;
        }
        if (revenueOutcome == 4) {
            emit RevenueDeposited(1, 0, 0);
            return 0;
        }
        if (revenueOutcome == 5) {
            emit QuoteBalanceUnreadable(address(this));
            return 0;
        }
        if (revenueOutcome == 1) {
            emit RevenueDeposited(1, inTransitAmount, inTransitAmount);
            inTransitAmount = 0;
            return inTransitAmount;
        }
        return 0;
    }

    function openSeries() external returns (uint256, bool) {
        openCalls += 1;
        if (openOutcome == 3) revert("stub: openSeries reverted");
        if (openOutcome == 1) {
            seriesExpiry = openExpiry;
            openStatus = 1;
            emit WeeklySeriesOpened(1, openExpiry, openStrike, twapPrice);
            return (1, true);
        }
        return (1, false);
    }
}
