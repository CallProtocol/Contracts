// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IWarrant} from "./IWarrant.sol";

/// @title IClearingPool
/// @notice 清算池的**全部**对外可写入口 —— 恰好六个，一个不多；外加两个卫星合约要读的 view。
///
/// 这个接口就是那句「无 admin、无 pause、无 withdraw、无 upgrade」写成代码的样子：
/// 池子不可升级、每链一个、唯一托管用户债权，因此它的函数集是**冻结**的。
/// 单独成文件有三个用处：
///
/// - `MerkleDistributor` 的 `claimAndExercise` 要以本合约的身份调 `exercise`（M1-8，issue #13）；
/// - 六个签名有一处权威出处，实现分散在 M1-4…M1-7 四张票上时不会各写各的；
/// - 它是「恰好六个」这个断言的**下界**：编译器强制实现方至少有这六个函数、且签名一字不差。
///   上界（没有第七个）读编译产物的 ABI 来断言，见 `test/ClearingPool.t.sol`。两边合起来才是「恰好」。
///
/// ⚠️ {warrant} 与 {seriesIdOf} 是 **view / pure**，因此它们不在「恰好六个」的计数里 ——
/// 那句话说的是**可写**入口，而 ABI 枚举也正是按 `stateMutability` 过滤的（见 `test/helpers/WriteSurface.sol`）。
/// 两个都是同一条理由的两次应用：**一个值必须由两个合约同时说对时，它只该有一处出处。**
///
/// - {warrant}：M1-8 的 `claim` 要把权证转给 leaf 指定的 account，而权证地址的权威出处只有一个 ——
///   池子的那个 `immutable`。distributor 自己再存一份，就等于多开一条会漂的路。
/// - {seriesIdOf}：M2-3 的 `WarrantVault.processRevenue()` 要算出它今天该往哪个系列里存。
///   同一个哈希公式抄两遍，迟早有一遍会漂 —— 而漂掉的后果是金库把钱存进一个**不存在的**系列
///   （`SeriesNotOpen`，收入卡在金库里），或者更糟，存进**别人**的系列。
///
/// 🔴 **往这个接口里加可写函数，等于往一个不可升级的托管合约上加入口。** 见 `docs/spec.zh.md` §5.1。
interface IClearingPool {
    /// @notice 权证（ERC-1155）。池子是它唯一的铸造与销毁方。
    /// @dev 给 `MerkleDistributor` 用：`claim` 要以本合约持有人的身份把权证转给 account。
    function warrant() external view returns (IWarrant);

    /// @notice 系列标识符：`keccak256(abi.encode(memeToken, stockToken, expiry))`，同时是权证的 ERC-1155 id。
    /// @dev 给 `WarrantVault` 与链下服务用 —— 它是「本周该往哪个系列存」这个问题的唯一权威答案。
    ///      ⚠️ 测试里不该用它反过来验它自己：`test/ClearingPoolMinting.t.sol` 独立算一份期望值。
    function seriesIdOf(address memeToken, address stockToken, uint64 expiry) external pure returns (uint256);

    /// @notice 开启一个新系列并锁死行权价。同一个系列**只能开一次**，行权价此后不可改。
    ///
    /// @dev 🔴 **仅该 MEME 在身份根里登记的金库可调**（`msg.sender == vaultRegistry.vaultOf(memeToken)`
    ///      且非零），此后也只有它能 `depositAndMint`。名册是我们自己的不可改写的那一份；当前
    ///      唯一可用的写入方是 `WarrantLauncher`，它在普通 `Portal.newTokenV6` 返回新代币后、同一笔
    ///      发射交易里调用 `bind`。`WarrantVaultFactory` 仅由 launcher 调用来建金库，绝不写 binding，
    ///      因而「给一只已经存在的 MEME 注册金库」没有入口。
    ///      issue #23 的六条分叉判据全过，方案 A（不可变身份根）落定；实现与部署接线是 issue #37。
    ///      完整论证见 {ClearingPool} 的合约注释与 `docs/research/flap-vault-identity-spike.md`。
    ///
    /// @param memeToken   行权时销毁的代币。**同时是身份根的查询键** —— 一只 MEME 只有一个合法金库
    /// @param stockToken  抵押品
    /// @param expiry      到期时刻。产品口径是该周周五 21:00 UTC，但**池子不解释这个值**
    /// @param strike      行权价：每 **1e18 raw 单位**股票代币需销毁的 MEME（raw）。
    ///                    行权公式 `memeAmount = amount * strike / 1e18`（向下取整），见 {exercise}
    /// @return seriesId   `keccak256(abi.encode(memeToken, stockToken, expiry))`
    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId);

    /// @notice 存入抵押品并铸造等量权证。仅该系列的金库可调。
    /// @param seriesId        系列
    /// @param to              权证接收方（`MerkleDistributor`）
    /// @param expectedAmount  请求存入量
    /// @return minted         实际铸造量 = 池内该股票代币的**余额增量**（带税代币下小于请求量）
    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount) external returns (uint256 minted);

    /// @notice 行权：销毁权证 + 销毁受益人的 MEME + 股票代币转给受益人，原子执行。
    ///
    /// @dev 🔴 **仅受益人本人或 `MerkleDistributor` 可调。** MEME 授权表达的是「我愿意为自己的行权
    ///      付款」，不是「谁都可以替我择时」。
    ///      🔴 **声明门查 `beneficiary`，不查调用方** —— 否则 distributor 的代行权路径（issue #13）
    ///      会把这道门整个掏空。完整的检查顺序与三步执行见 {ClearingPool-exercise}。
    ///      MEME 必须从 beneficiary **恰好扣除**定价公式的结果，但不要求 `0xdead` 足额实收；
    ///      股票代币必须从池子**恰好扣除** `amount`，但允许 beneficiary 因接收方税而少收。
    ///
    /// @param seriesId     系列
    /// @param amount       行权量（raw 股票代币单位），同时是销毁的权证数。
    ///                     销毁的 MEME 为 `amount * strike / 1e18`（向下取整；取整到 0 的行权被拒，
    ///                     否则等于白拿股票代币）。装不进 `uint128` 的量被拒
    /// @param beneficiary  受益人 —— 声明门查他、MEME 从他那里拉取、股票代币直达他
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external;

    /// @notice 观测并记录该股票代币的发行方门控状态**翻转**。任何人可调。
    ///
    /// @dev 🔴 `clearedAt` 只在**离开**门控（或**进入**不可读状态）这条边上写入。每次「干净 poke」
    ///      都写的话，任何人每 47 小时调一次就能把它一路前推 —— `settleExpired` 永久 revert，
    ///      而攻击者手上本该作废的系列获得**无限期免费展期**。完整的三态转移表见 {ClearingPool-_observe}。
    ///      🔴 每次内部读取前都必须保留足够执行 gas：把健康的 view 饿死也是一条边。这个读取门槛
    ///      不是整笔交易的 gas limit；Monitor 应按实际 sender、calldata 与调用包装路径执行
    ///      `eth_estimateGas` 并留余量。
    function pokeGating(address stockToken) external;

    /// @notice 到期结算（惰性，任何人可调）。门控期间被结构性阻止 —— 那就是「自动延期」。
    ///
    /// @dev 内部先观测一次（自愈陈旧记录），再要求实时无门控且已过 deadline，
    ///      才置 `settled = true`、`remainder = deposited − exercised`。
    ///      ⚠️ 那次观测只在结算**成功**时才留在链上；要给宽限时钟起头，调 {pokeGating}。
    function settleExpired(uint256 seriesId) external;

    /// @notice 池内滚存：把已结算系列的余量记入后继系列并铸权证给 distributor。任何人可调。
    ///
    /// @dev 🔴 抵押品**永不离开池子** —— 这笔调用里没有任何一次转账，池内该股票代币的余额前后不变
    ///      （不变量 7）。它是池内重新归属，不构成转出，不变量 5 的措辞依赖这一点。
    ///
    ///      **无许可**，因为六道门全部可由池子自证：前序已开启、已结算、`remainder != 0`；
    ///      后继已开启（判据是 `strike != 0`）、同 (MEME, 股票代币) 对、未结算且 `now < expiry`。
    ///      完整理由与残余敞口（合法后继由调用方指定，见 issue #21 / #23）见 {ClearingPool-rollExpired}。
    ///
    ///      ⚠️ 没有可用的后继系列时干净 revert，余量停在池内 —— 开出一个到期在未来的新系列即可恢复。
    ///      **只有延迟，没有损失。**
    ///
    /// @param seriesId      已结算的前序系列
    /// @param nextSeriesId  后继系列 —— 权证铸给 `distributor`，数量等于前序的 `remainder`
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external;
}
