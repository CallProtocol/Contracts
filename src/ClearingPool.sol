// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {IIssuerCompliance, IIssuerGatedStock, IIssuerPauseManager} from "./interfaces/IIssuerGating.sol";
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";
import {IWarrant} from "./interfaces/IWarrant.sol";

/// @title ClearingPool
/// @notice 🔴 **不可升级，每链一个，唯一托管用户债权的合约。**
///
/// # 这个合约的全部设计原则是：函数尽可能少，且没有管理员
///
/// 我们对外承诺的是「偿付在结构上不可违背」。那句话只有在**池子里不存在任何可以动抵押品的特权路径**时
/// 才成立 —— 所以这里**无 admin、无 pause、无 withdraw、无 upgrade**，对外可写入口恰好六个：
///
/// | 函数 | 谁可以调 |
/// |---|---|
/// | `openSeries` | **该 MEME 在身份根里登记的那个金库**；同一个系列只能开一次（见下） |
/// | `depositAndMint` | 该系列的金库 |
/// | `exercise` | 受益人本人，或 `MerkleDistributor` |
/// | `pokeGating` | 任何人 |
/// | `settleExpired` | 任何人 |
/// | `rollExpired` | 任何人 |
///
/// 「没有第七个」这件事，自己列举一遍自己调用过的函数是证明不了的 —— 后来加进去的 `withdraw`
/// 不会因为没人调用它而失效。所以它由 `test/ClearingPool.t.sol` 读编译产物的 ABI 枚举全部对外入口来断言。
///
/// 🔴 **函数集到 M1-7（#12）才填满，不变量 5 也因此到这里才有意义。** 它有两个面，缺一不可：
/// 结构面是那次 ABI 枚举（没有第七个入口）；动态面是把六个入口按任意顺序跑遍之后，
/// 每一只股票代币的池内余额**只在 `exercise` 里减少过、且每次恰好减少行权量** ——
/// 也就是「`minted > exercised` 时抵押品无法被转出本合约」。`rollExpired` 是池内重新归属，
/// 它在动态面上表现为余额一个 wei 都不动。两面合起来见
/// `test/invariant/Invariant5And7RollAndCustody.t.sol`。
///
/// # 四个依赖地址都是真 `immutable`
///
/// 部署之后没有任何写入路径 —— 可更换 = 可被指向一个恒返回 false 的合约 = 可冻结全部行权，
/// 或者被指向一份「谁都算合法金库」的名册 = 授权门当场作废。宁可放弃「换注册表」的灵活性。
/// 构造环是靠**卫星侧**的一次性绑定槽解开的，不用 CREATE2，见 {PoolBound}、
/// {WarrantVaultFactory} 与 `docs/spec.zh.md` §12。
///
/// # 谁是「该系列的金库」：身份根里登记的那一位
///
/// `openSeries` 要求 **`msg.sender == vaultRegistry.vaultOf(memeToken)` 且非零**，
/// 此后也只有它能 `depositAndMint`。名册是我们自己的、独立的、不可改写的那一份
/// （{VaultRegistry}）：当前可用的写入方是 {WarrantLauncher}，它在同一笔 D0 发射交易里
/// 从普通 `Portal.newTokenV6` 取得新代币后才写绑定；工厂只建金库，完全不碰身份根。
///
/// 于是「给一只已经存在的 MEME 注册金库」**没有入口**：抢注不是更难，是不存在
/// （issue #23 判据 2，一票否决项，分叉实测通过）。
///
/// 🔴 **这道门是 fail-closed 的，而且装在一个不可升级的合约上** —— 所以「问名册」这个动作
/// 本身必须不可能失败：{IVaultRegistry-vaultOf} 是一次 mapping 读，无外部调用、无算术、无 `require`，
/// 未绑定返回 `address(0)` 而不 revert（判据 4，`test/VaultRegistry.t.sol` 钉住）。
///
/// 它可以 fail-closed，是因为**四条会动抵押品的路径一条都不读它**：`depositAndMint` 认的是
/// 开系列时记下的 `s.vault`，`exercise` / `settleExpired` / `rollExpired` 根本不涉及金库身份。
/// 身份根即便整个失灵，已开出的系列照常存入、行权、结算、滚存 —— 最坏后果「开不出新系列」
/// 与金库运营方掉线同级。这与 §5.1 那条「门控读取宁可 fail-open」不矛盾：那一条读的是
/// 发行方的**外部**注册表、装在**动抵押品**的路径上，fail-closed 会把抵押品永久冻死。
///
/// > **历史**：M1 这里曾是**无许可**的（谁先开谁负责），因为当时没有一个经真实 Flap 流程验证过的
/// > 不可变身份根，替代方案在 M1 内无法验证。残余敞口是抢注导致的当周停发，它依赖
/// > 「排序器不抢跑、不审查」这个外部假设 —— 2026-08-13 issue #23 的六条分叉判据全过，
/// > **这个假设被拒绝**，改用上面这道结构性的门。issue #21 的那套缓解因此**不适用**
/// > （新的发行活性观测是 issue #42，普通优先级，不是上线阻塞）。
/// > 证据：`test/fork/RobinhoodVaultIdentity.t.sol`、`test/fork/RobinhoodWarrantVaultFactory.t.sol`、
/// > `test/VaultRegistry.t.sol`、`docs/research/flap-vault-identity-spike.md`、
/// > 决策记录 `docs/design.md` §10-34 / §10-36。
///
/// @dev 六个函数**已全部交付**：开系列与存入即铸（M1-4，issue #9）、行权（M1-5，issue #10）、
///      门控观测与到期结算（M1-6，issue #11）、池内滚存（M1-7，issue #12）；
///      开系列那道身份门在 M2-5（issue #37）随工厂与部署接线一起装上。
contract ClearingPool is IClearingPool, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice 一个系列的全部状态。
    ///
    /// @param vault       开启该系列的金库 —— **唯一**有权 `depositAndMint` 的地址。
    ///                    `address(0)` 表示该系列尚未开启。
    /// @param memeToken   行权时销毁的代币
    /// @param stockToken  抵押品
    /// @param expiry      到期时刻
    /// @param strike      行权价：每 **1e18 raw 单位**股票代币需销毁的 MEME（raw）。
    ///                    行权公式 `memeAmount = amount * strike / 1e18`（向下取整），见 {exercise}。
    ///                    开系列时写入，此后**没有任何路径能改它**。
    /// @param deposited   累计存入的股票代币（raw `balanceOf` 单位，含 `rollExpired` 滚入量）
    /// @param minted      已铸权证
    /// @param exercised   已行权（销毁权证换走的那部分）
    /// @param remainder   结算后待滚存的余量（{settleExpired} 写入，{rollExpired} 消费并清零）
    /// @param settled     是否已结算（{settleExpired} 写入）。`settled ⟹ 不可行权、不可再存入`
    ///
    /// @dev 字段顺序按**存储槽**排的，不按可读性排：`vault + expiry + settled` 正好挤进一个槽（29 字节），
    ///      五个 `uint128` 里前四个两两成对（`strike + deposited`、`minted + exercised`），
    ///      `remainder` 落单占第六个槽。开系列写一次、每次存入写一次，这里省下的是真实 gas。
    struct Series {
        address vault;
        uint64 expiry;
        bool settled;
        address memeToken;
        address stockToken;
        uint128 strike;
        uint128 deposited;
        uint128 minted;
        uint128 exercised;
        uint128 remainder;
    }

    /// @dev 🔴 不开自动 getter，改用 `series()` 返回整个结构体：十个字段的位置元组
    ///      在测试与链下都太容易读错位 —— `minted` 与 `exercised` 同型同宽，
    ///      换个顺序编译器一声不吭。带字段名的读法只此一处，错不了。
    mapping(uint256 seriesId => Series) internal _series;

    /// @notice 每只股票代币一条发行方门控观测记录。
    ///
    /// @param active     最近一次观测**命中**了门控（暂停，或池地址被封）。命中期间行权窗口无截止；
    ///                   实际股票交付仍受发行方代币的转账门控约束。
    /// @param unreadable 最近一次观测**读不通**门控 view（fail-open 状态）。
    /// @param clearedAt  最近一次「离开门控」的时刻。`0` 表示从未观测到过离开 —— 那就没有宽限。
    ///
    /// @dev 🔴 规格里的 `Gating` 只有两个字段（`active` / `clearedAt`）。**第三个字段是承重的**：
    ///      fail-open 的宽限必须绑定在「**进入**不可读状态」这一次转变上，而不是「每次读不通」。
    ///      少了它，判断「这次读不通是不是新情况」就只能靠 `clearedAt`，于是每一次读不通都会重新盖章 ——
    ///      §5.1 那条「攻击面从后门绕回来」说的正是这个。三个字段共 10 字节，同一个槽，不多花 gas。
    ///
    ///      构造上恒有 `unreadable ⟹ !active`：进入不可读状态时 `active` 一并清掉
    ///      （规格：读不通时若此前为门控，**按解除翻转处理**）。所以三个取值组合就是三种状态：
    ///      干净 `(false,false)`、门控 `(true,false)`、不可读 `(false,true)`。
    struct Gating {
        bool active;
        bool unreadable;
        uint64 clearedAt;
    }

    /// @dev 🔴 不开自动 getter，改用 `gating()` 返回整个结构体 —— 理由同 `_series`：
    ///      `active` 与 `unreadable` 同型且相邻，位置元组换个顺序编译器一声不吭，
    ///      而这两个布尔的含义正好相反（一个是「有截止吗」，一个是「我们还看得见吗」）。
    ///      内部可见性还有第二个用处：不变量测试的**反证**要能装一个「每次 poke 都盖章」的后门
    ///      （见 `test/invariant/Invariant4SettlementAndGating.t.sol`），而生产合约里不留钩子。
    mapping(address stockToken => Gating) internal _gating;

    /// @notice 权证（ERC-1155）。池子是它唯一的铸造与销毁方。
    IWarrant public immutable warrant;

    /// @notice 归属与领取合约。它是 `exercise` 调用方白名单里除受益人本人之外的唯一一个。
    address public immutable distributor;

    /// @notice 合规声明存证。池子只问一件事：「这个受益人声明过吗」。
    IAttestationRegistry public immutable attestations;

    /// @notice 🔴 **金库身份根 —— `openSeries` 那道门唯一的判据来源。**
    ///
    /// @dev 真 `immutable`，与另外三个同一条理由：可更换 = 可被指向一份「谁都算合法金库」的名册
    ///      = 那道门当场作废。而它比另外三个更没有回旋余地 —— 换掉它等于把发行权交出去。
    ///
    ///      池子只看得见 {IVaultRegistry}（一个 view）：它不需要知道绑定是谁写的、怎么写的，
    ///      只需要知道结果。写入侧（当前是 {WarrantLauncher} 在一次发射中绑定、每只 MEME
    ///      只写得进一次）住在 {VaultRegistry} 与 {WarrantLauncher} 里；工厂只负责建金库。
    IVaultRegistry public immutable vaultRegistry;

    /// @notice 行权时 MEME 的去处。
    ///
    /// @dev 🔴 **是 `0xdead`，不是 `0x0`。** 这不是风格选择：`FlapTaxTokenV3` 走的是标准 OZ 的
    ///      `_update`，转给零地址会 revert（`ERC20: transfer to the zero address`），而它**没有**
    ///      原生 `burn()` / `burnFrom()` —— `transferFrom(user, 0xdead, …)` 是唯一可用的销毁路径。
    ///      两条都是实测结论，不是推断：`docs/research/flap-tax-and-burn-path.md` §1.1 / §3，
    ///      并由 `test/fork/RobinhoodFlapBurn.t.sol` 在真实合约上持续复核。
    ///
    ///      公开出来是给链下与前端一处权威出处；⚠️ 测试里不该拿它反过来验它自己，
    ///      `test/ClearingPoolExercise.t.sol` 独立写死字面量。
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice 门控解除之后留给持有人行权的宽限窗口。
    ///
    /// @dev 门控期间行权窗口无截止，但发行方仍可能拒绝股票转账；「解除」这一刻若立即恢复原截止时刻，
    ///      一个在到期后才解除的系列会在解除的同一秒失去行权资格 —— 延期就等于什么也没给。
    ///      48 小时是留给人类反应并完成实际交付的时间。
    ///      公开出来是给链下与前端一处权威出处；⚠️ 测试里不该拿它反过来验它自己。
    uint64 public constant GRACE_PERIOD = 48 hours;

    /// @notice 每一次门控 view 读取最多转发的 gas。
    ///
    /// @dev 🔴 **这个常量是防一条具体攻击的，不是防御性编程。** 观测只在状态翻转的边上写
    ///      `clearedAt`，于是攻击者若想把它一路前推，就得反复**制造**「干净 → 不可读」这条边。
    ///      而「不可读」在实现上就是「这次调用失败了」—— 只要调用方可以决定转发多少 gas，
    ///      他就能让一个完全健康的 view 因 out-of-gas 而失败，从而无中生有地造出那条边：
    ///
    ///      ```
    ///      poke(gas 充足) → 干净        poke(gas 饿死) → 不可读 + 盖章    ← 每 47 小时来一轮
    ///      ```
    ///
    ///      `settleExpired` 于是永久 revert —— 正是 §5.1 那条「攻击面从后门绕回来」。
    ///      所以每次读之前都先要求剩余执行 gas 足够按 EIP-150 的 63/64 规则转发满
    ///      `GATING_READ_GAS`，不够就**当场 revert**，绝不把它记成一次「读不通」。
    ///      这是每次内部读取的门槛，**不是**整笔 `pokeGating` 交易的 gas limit。
    ///
    ///      📏 50,000 的依据是实测：真实 GME 上三个读加起来远低于它
    ///      （`test/fork/RobinhoodGating.t.sol::test_gasBudget_theRealReadsFitInsideASingleBudget` 打印实测值
    ///      并断言留有余量）。取值只需**远大于**真实开销、又不至于让 poke 变成一笔昂贵交易。
    uint256 public constant GATING_READ_GAS = 50_000;

    /// @notice 每次门控读取在 {GATING_READ_GAS} 之外还必须留下的 gas。
    ///
    /// @dev `gasleft()` 在 `_staticWord` 读到之后，仍要支付 `STATICCALL` 的冷账户访问/基础成本和
    ///      少量把参数压栈的指令；EIP-150 是在那些成本**之后**才截断转发 gas。
    ///      5,000 覆盖 Cancun 下的冷账户访问与 `STATICCALL` 基础成本，并留下余量给紧邻调用的代码。
    ///      这不是转发给发行方的预算，而是调用方为确保那一份预算真的到达必须额外留下的 gas。
    ///
    ///      🔴 **公开出来，是因为它和 {GATING_READ_GAS} 是同一个公式的两半。** 只公开前一半，
    ///      链下就算不出这道门到底要多少 gas —— 而这道门每次读都会检查一遍，算错的后果是
    ///      Monitor 的每一笔 poke 都撞 `NotEnoughGasToObserveGating`。
    ///      ⚠️ 两个常量及其派生门槛都**不是**整笔交易的 gas limit：它们只描述 Pool 内每次读取前
    ///      必须保留的执行 gas。顶层 intrinsic/calldata、调用前路径和任何 wrapper 都不在其中；Monitor
    ///      必须按实际调用路径执行 `eth_estimateGas` 并留余量。分叉测试的同名测量仅二分 harness 向 Pool
    ///      转发的 child-call gas，不能外推成交易 limit。
    uint256 public constant GATING_STATICCALL_OVERHEAD = 5000;

    /// @notice 开出了一个新系列。全生命周期每个 `seriesId` 至多出现一次。
    event SeriesOpened(
        uint256 indexed seriesId,
        address indexed vault,
        address memeToken,
        address stockToken,
        uint64 expiry,
        uint128 strike
    );

    /// @notice 存入抵押品并铸出权证。
    /// @dev 🔴 `expectedAmount` 与 `minted` **两个都记**：两者之差就是这只股票代币在这一笔上
    ///      吃掉的转账税。少记一个，链下就只能靠猜或者去 diff 余额才知道差在哪。
    ///      权证侧的 `TransferSingle` 由 ERC-1155 自己发，这里不重复。
    event Deposited(
        uint256 indexed seriesId, address indexed vault, address indexed to, uint256 expectedAmount, uint256 minted
    );

    /// @notice 行权完成：权证已销毁、MEME 已送往 `BURN_ADDRESS`、股票代币已到受益人手上。
    ///
    /// @param caller     发起者 —— 受益人本人，或 `distributor`。权证从**它**那里销毁
    /// @param amount     行权量（raw 股票代币单位），也是销毁的权证数
    /// @param memeAmount **转出**的 MEME 数量，不一定等于 `BURN_ADDRESS` 实收
    ///
    /// @dev 🔴 `memeAmount` 记的是从受益人账上扣走的数，链下要算「真的烧了多少」得读 MEME 侧的
    ///      `Transfer`。今天两者相等（实测 Flap 的销毁路径零税），但那是**外部合约现在的行为**，
    ///      不是本合约保证的事 —— 见 `exercise` 里为什么这里不做余额差核对。
    event Exercised(
        uint256 indexed seriesId,
        address indexed caller,
        address indexed beneficiary,
        uint256 amount,
        uint256 memeAmount
    );

    /// @notice 完成了一次门控观测。
    ///
    /// @param gated     本次实时读取命中了门控
    /// @param readable  三个 view 全部读通了（`false` = fail-open 状态）
    /// @param clearedAt 观测**之后**记录在案的解除时刻 —— 没变就说明这次不是一条边
    ///
    /// @dev 🔴 **每次观测都发，包括没有发生翻转的那些。** 「只在边上写」说的是
    ///      `clearedAt` / `active` 这两处**存储**，不是事件：链下要区分「我们看过了，是干净的」
    ///      和「那笔 poke 根本没执行」，靠的正是这条事件在前一种情况下也出现。
    ///      §11 的「只封某个持有人」那一档就落在这里 —— 池子干净 ⟹ `gated == false`
    ///      ⟹ 没有延期，前端据此告诉用户「你被单独封了，自救路径是把权证卖掉」。
    event GatingObserved(address indexed stockToken, bool gated, bool readable, uint64 clearedAt);

    /// @notice 系列已结算。此后不可行权、不可再存入，`remainder` 等待 {rollExpired} 滚入后继系列。
    /// @param deadline 结算时生效的行权截止时刻 —— 门控延期把它推到了哪里，链下只能从这里读到
    event Settled(uint256 indexed seriesId, uint128 remainder, uint64 deadline);

    /// @notice 到期余量已滚入后继系列。
    ///
    /// @param amount 滚存量 —— 同时是前序 `remainder` 的减少量、后继 `deposited` / `minted` 的增量，
    ///               以及铸给 `distributor` 的权证数。不变量 7 断言的就是这四个数相等
    ///
    /// @dev 🔴 **这条事件里没有任何一笔转账。** 抵押品一个 wei 都没有离开本合约 ——
    ///      链下若想核对，读的应当是「池内该股票代币余额在这笔交易前后**不变**」，
    ///      而不是去找一条 ERC-20 的 `Transfer`。找不到才是对的。
    event Rolled(uint256 indexed seriesId, uint256 indexed nextSeriesId, uint128 amount);

    error ZeroAddress();

    error ZeroToken();
    error ZeroStrike();
    error ExpiryNotInFuture(uint64 expiry, uint256 timestamp);
    error SeriesAlreadyOpen(uint256 seriesId, address vault);
    error SeriesNotOpen(uint256 seriesId);
    error NotSeriesVault(uint256 seriesId, address caller, address vault);

    /// @dev 🔴 调用方不是这只 MEME 在身份根里登记的金库 —— `openSeries` 那道门。
    ///
    ///      **把身份根当时的答案一并报出来**，因为这条 revert 有两种完全不同的成因，
    ///      而只报调用方的话它们长得一模一样：
    ///
    ///      | `vault` | 说明 |
    ///      |---|---|
    ///      | `address(0)` | 这只 MEME **从未通过我们的工厂发射** —— 它没有金库，谁也开不了它的系列 |
    ///      | 非零 | 有金库，但不是你 |
    ///
    ///      前者是运营问题（发射用错了工厂 / 用错了链），后者是权限问题。
    error NotRegisteredVault(address memeToken, address caller, address vault);

    /// @dev 调用方既不是受益人本人、也不是 `distributor`。
    error NotExerciseCaller(uint256 seriesId, address caller, address beneficiary);
    error SeriesSettled(uint256 seriesId);

    /// @dev `deadline` 单独报出来，因为它**不等于** `expiry`：门控延期会把它往后推。
    ///      只报 `expiry` 的话，「为什么我在到期前就被拒了 / 到期后还能行权」在链下无从解释。
    error ExerciseWindowClosed(uint256 seriesId, uint64 deadline, uint256 timestamp);
    error NotAttested(address beneficiary);

    /// @dev 这一笔要销毁的 MEME 向下取整之后是 0 —— 见 `exercise` 里为什么它必须被拒。
    error ExerciseRoundsToZeroMeme(uint256 seriesId, uint256 amount, uint128 strike);

    /// @dev MEME 声称转账成功，但受益人的实际扣款量不是按行权价算出的数额。
    error MemeTransferDebitMismatch(
        uint256 seriesId, uint256 expectedDebit, uint256 balanceBefore, uint256 balanceAfter
    );

    /// @dev 股票代币声称转账成功，但池子的实际扣款量不是行权量。
    error StockTransferDebitMismatch(
        uint256 seriesId, uint256 expectedDebit, uint256 balanceBefore, uint256 balanceAfter
    );

    /// @dev 结算被门控**结构性阻止** —— 这就是「发行方冻结时自动延期」，不是错误。
    ///      系列的行权窗口保持开放；若发行方仍阻止股票转账，调用仍会原子回滚。
    ///      发行方一解除，行权**立刻**可用（窗口还开着，转账放行了）；此后再观测到解除，
    ///      窗口收敛为 `max(expiry, clearedAt + {GRACE_PERIOD})`。
    error SettlementGatedByIssuer(uint256 seriesId, address stockToken);

    /// @dev 还没到可结算的时刻。`deadline` 单独报出来，因为门控延期会把它推到 `expiry` 之后。
    error SettlementTooEarly(uint256 seriesId, uint64 deadline, uint256 timestamp);

    /// @dev 调用方给的 gas 不足以把门控 view **读满预算**。见 {GATING_READ_GAS}：
    ///      在这里 revert 而不是记成一次「读不通」，正是那条攻击的全部防线。
    error NotEnoughGasToObserveGating(uint256 needed, uint256 available);

    /// @dev 还没结算，`remainder` 就还没算定 —— 滚存无从谈起。先调 {settleExpired}。
    error SeriesNotSettled(uint256 seriesId);

    /// @dev `remainder == 0`：这个系列没有余量可滚（或者已经滚过一次了）。
    ///      这道门同时就是「不可二次滚存」的全部实现，见 {rollExpired}。
    error NothingToRoll(uint256 seriesId);

    /// @dev 后继系列与前序不是同一个 (MEME, 股票代币) 对。**报的是后继那一侧的取值**，
    ///      调用方拿它跟自己传的前序一比就知道错在哪一维。
    error SuccessorTokenMismatch(uint256 nextSeriesId, address memeToken, address stockToken);

    /// @dev 后继系列已经过了自己的 `expiry`。滚进去只会铸出一批生下来就行权不了的权证。
    ///      开一个到期在未来的新系列即可恢复 —— 只有延迟，没有损失。
    error SuccessorExpired(uint256 nextSeriesId, uint64 expiry, uint256 timestamp);

    /// @param warrant_        `Warrant`
    /// @param distributor_    `MerkleDistributor`
    /// @param attestations_   `AttestationRegistry`
    /// @param vaultRegistry_  `VaultRegistry` —— 金库身份根，`openSeries` 那道门的判据来源
    ///
    /// @dev 四个地址一经写入永久生效，所以零地址在这里挡掉 —— 传错了只能重新部署一份池子，
    ///      而「重新部署」对一个托管着抵押品的合约来说是不存在的选项。
    ///
    ///      🔴 **刻意不检查这四个地址上有没有字节码。** 与 {PoolBound-setPool} 的第 ④ 道门不同：
    ///      那边绑的时候池子**必然已经部署**，无字节码就等于地址填错；这边身份根与池子处在同一个
    ///      部署环里（`factory` → `launcher` → `VaultRegistry(launcher, slot)` → `ClearingPool(…, registry)`），
    ///      加一道 `code.length` 检查只会给合法的部署排布凭空设限。接线对不对由
    ///      `script/DeploySystem.s.sol` 末尾的断言与 `script/verify-deployment.sh` 回链上核验 ——
    ///      🔴 **接反了同样表现为「永远开不出系列」，而池子改不了**（spike §9 末的硬要求）。
    constructor(
        IWarrant warrant_,
        address distributor_,
        IAttestationRegistry attestations_,
        IVaultRegistry vaultRegistry_
    ) {
        if (
            address(warrant_) == address(0) || distributor_ == address(0) || address(attestations_) == address(0)
                || address(vaultRegistry_) == address(0)
        ) {
            revert ZeroAddress();
        }
        warrant = warrant_;
        distributor = distributor_;
        attestations = attestations_;
        vaultRegistry = vaultRegistry_;
    }

    /// @notice 读一个系列的全部字段。未开启的系列返回全零（`vault == address(0)`）。
    function series(uint256 seriesId) external view returns (Series memory) {
        return _series[seriesId];
    }

    /// @notice 读一只股票代币的门控观测记录。从未被 poke 过的代币返回全零 —— 也就是「干净、无宽限」。
    /// @dev **合约只信记录在案的观测**：门控发生了但没人 poke，就不产生延期。
    ///      这使 poke 成为 Monitor 的运营刚性职责，但它无许可 —— 任何持有人都能自己调。
    function gating(address stockToken) external view returns (Gating memory) {
        return _gating[stockToken];
    }

    /// @notice 一个系列**当前**的行权截止时刻。门控观测中返回 `type(uint64).max`（无截止）。
    ///
    /// @dev 给前端与 Monitor 的读法：`ExerciseWindowClosed` 只在被拒时才报得出 deadline，
    ///      而「我还剩多久」是行权前就要回答的问题。
    ///      ⚠️ 未开启的系列在这里返回 `0`，不 revert —— 它读的就是一份全零记录，没有别的可说。
    function exerciseDeadline(uint256 seriesId) external view returns (uint64) {
        return _exerciseDeadline(_series[seriesId]);
    }

    /// @notice 系列标识符：`keccak256(abi.encode(memeToken, stockToken, expiry))`，同时是权证的 ERC-1155 id。
    ///
    /// @dev `memeToken` 在里面是**必需的**，不是顺手加的：行权销毁的是各自项目的 MEME，
    ///      支付资产不同就不可能是同一个资产（`spec.zh.md` §2.1）。少了这一维，
    ///      两个项目的权证会共用同一个 id、也就共用同一份抵押品。
    ///
    ///      公开出来是为了让金库（M2）与链下服务有**一处**权威出处 —— 同一个公式抄两遍，
    ///      迟早有一遍会漂。⚠️ 但测试里不该用它反过来验它自己：`test/ClearingPoolMinting.t.sol`
    ///      独立算一份期望值。
    function seriesIdOf(address memeToken, address stockToken, uint64 expiry) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(memeToken, stockToken, expiry)));
    }

    // ─────────────────────────── 对外可写入口：恰好六个 ───────────────────────────
    //
    // 签名与文档住在 {IClearingPool} —— 六个函数分散在四张票上实现，签名只该有一处出处。
    // M1-7（#12）之后六个全部落地，这里再没有只有签名的函数体。
    //
    // 🔴 往下加第七个，等于往一个不可升级的托管合约上加入口 —— 不变量 5 当场作废。

    /// @inheritdoc IClearingPool
    ///
    /// @dev 五道前置各挡一件「开出来就没救了」的事 —— 系列一经开启**不可关闭、不可修改**：
    ///      ① 零地址代币 —— 打错地址。第一次存入时 `balanceOf` 才会 revert，那时人已经走了；
    ///      ② `strike == 0` —— 行权白拿股票代币；而且 #12 的「后继系列已开启」判据是
    ///         `n.strike != 0`，零行权价的系列在滚存眼里等于不存在；
    ///      ③ 到期不在未来 —— 生下来就死的系列：铸出的权证一枚都行权不了
    ///         （抵押品还能靠 {settleExpired} + #12 滚存捞回来，但权证持有人已经损失了）；
    ///      ④ 🔴 **调用方不是这只 MEME 登记在案的金库** —— 见 {NotRegisteredVault} 与合约头；
    ///      ⑤ 已开启 —— 这是「只能开一次」，也是「行权价此后不可改」的全部实现。
    ///
    ///      🔴 ⑤ 用的哨兵是 `vault != address(0)`，不是 `strike != 0`。两者在这里等价
    ///      （②保证了开启的系列 strike 必非零），但前者说的是「有没有人开过」，
    ///      正是这道门要判的那件事。
    ///
    ///      ④ 排在 ⑤ **之前**：一个陌生地址来撞一个已开系列，应当被告知「你不是这只 MEME 的金库」，
    ///      而不是「这个系列已经开过了」—— 后者会把一次权限错误报成一次时序错误。
    ///      顺带：`vaultOf` 恒不 revert，所以这道门只会 revert 在**我们自己**的 `if` 上。
    ///
    ///      ⚠️ ④ 的两个条件写成一句：`bound == address(0)` 时任何调用方都不合格，
    ///      而零地址调用方本身也过不了 `msg.sender != bound` —— 但那要靠「零地址调不动合约」
    ///      这条关于**链**的假设。与 {PoolBound-onlyPool} 同一个取舍：写成结构，不寄存在假设上。
    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId)
    {
        if (memeToken == address(0) || stockToken == address(0)) revert ZeroToken();
        if (strike == 0) revert ZeroStrike();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry, block.timestamp);

        address registered = vaultRegistry.vaultOf(memeToken);
        if (registered == address(0) || msg.sender != registered) {
            revert NotRegisteredVault(memeToken, msg.sender, registered);
        }

        seriesId = seriesIdOf(memeToken, stockToken, expiry);
        Series storage s = _series[seriesId];
        if (s.vault != address(0)) revert SeriesAlreadyOpen(seriesId, s.vault);

        s.vault = msg.sender;
        s.memeToken = memeToken;
        s.stockToken = stockToken;
        s.expiry = expiry;
        s.strike = strike;

        emit SeriesOpened(seriesId, msg.sender, memeToken, stockToken, expiry, strike);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev 🔴 **铸造量以转账前后的余额增量为准，不以 `expectedAmount` 为准。**
    ///      股票代币可能带转账税，按请求量铸造会直接造成超发 —— 而超发要到第一个行权失败的用户
    ///      身上才会暴露。这不是防御性编程，是这条路径的定义。
    ///
    ///      `nonReentrant` 同样是承重的：余额差记账**天然对再入敏感**。代币在转账里回调进来，
    ///      内层转入的那笔会被外层再数一遍，于是抵押品进来 `T1 + T2`、权证铸出 `T1 + 2·T2`。
    ///      而池子对**任何**股票代币都开着（`openSeries` 无许可），这条路径可达。
    ///      钉在 `test/ClearingPoolMinting.t.sol::test_depositAndMint_isNotReentrant`。
    ///      用的是 transient 那一版（EIP-1153）：TSTORE/TLOAD 已在 Robinhood Chain 实测支持，
    ///      见 `foundry.toml` 里 `evm_version` 的注释与复算命令。
    ///
    ///      两处刻意**不做**的检查：
    ///      - 不挡 `block.timestamp >= s.expiry` —— 门控延期下过了 expiry 的系列行权窗口仍可能开放，
    ///        挡掉等于把延期窗口里的存入也一起挡了。到期之后真正关上门的是 `settled`，不是 `expiry`；
    ///      - 不挡 `minted == 0` —— 100% 税的代币下这是诚实的结果，revert 反而丢掉了这条记录。
    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount)
        external
        nonReentrant
        returns (uint256 minted)
    {
        Series storage s = _series[seriesId];

        // 🔴 「未开启」与「不是该系列的金库」分开判，不合并成一句 `msg.sender != s.vault`。
        //    `address(0)` 在这里身兼两职：它是「尚未开启」的哨兵值，也是一个能出现在
        //    `msg.sender` 位置的取值 —— 合并之后这两个身份在未开启期间会**撞成同一个值**。
        //    同 {PoolBound-onlyPool} 的取舍：把它写成结构，比寄存在「零地址调不动合约」
        //    这条关于**链**的假设上便宜得多，代价是一次比较。
        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (msg.sender != s.vault) revert NotSeriesVault(seriesId, msg.sender, s.vault);

        // 🔴 **已结算的系列不得再存入。** 结算时 `remainder` 就按当时的账算定了；之后进来的抵押品
        //    既不在 `remainder` 里、也不属于任何未结算系列，会永久卡在池子里（无 admin、无 withdraw），
        //    而对应的权证一枚也行权不了（不变量 4①）。
        //    ⚠️ 这道门挡的只是**直接**调用。同一件事从再入那一侧过来 —— 存入的转账回调里调
        //    `settleExpired` —— 由 `settleExpired` 自己的 `nonReentrant` 挡住，见那里的注释。
        if (s.settled) revert SeriesSettled(seriesId);

        IERC20 stock = IERC20(s.stockToken);
        uint256 balanceBefore = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), expectedAmount);

        // 余额**变少**时这里会因下溢而 revert，这正是要的结果：一只「收进来反而扣池子钱」的代币
        // 必须当场停住，而不是记一笔看起来正常的账。
        minted = stock.balanceOf(address(this)) - balanceBefore;

        // 🔴 裸转换会**静默截断**：存入 2^128 + 5 会记成 5，权证却按 2^128 + 5 铸出。
        //    真实 GME 到不了这个量级，但池子对任何股票代币都开着。
        uint128 minted128 = SafeCast.toUint128(minted);
        s.deposited += minted128;
        s.minted += minted128;

        // 记账先于外部调用：`warrant.mint` 会对合约收款方回调 `onERC1155Received`。
        warrant.mint(to, seriesId, minted);

        emit Deposited(seriesId, msg.sender, to, expectedAmount, minted);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # 五道门，顺序固定
    ///
    ///      | # | 门 | 它挡住的那件事 |
    ///      |---|---|---|
    ///      | ① | 调用方 ∈ {`beneficiary`, `distributor`} | 第三方替受益人择时 |
    ///      | ② | 系列已开启 | 见下 |
    ///      | ③ | 未结算 | 不变量 4①：结算时 `remainder` 已按当时的账算定，再行权就是重复支取 |
    ///      | ④ | 未过 deadline | 到期即失效；门控期间这条线自动后移，见 {_exerciseDeadline} |
    ///      | ⑤ | `attestedVersion(beneficiary) != 0` | 合规声明 |
    ///
    ///      🔴 **⑤ 查的是 `beneficiary`，不是 `msg.sender`。** distributor 的代行权路径（#13）以
    ///      **自己**的身份调进来，查调用方就等于「distributor 签过一次，全体用户就都过门了」——
    ///      这道门会被整个掏空，而它是我们对外承诺「合规不是伪装的冻结开关」时唯一拿得出的东西。
    ///
    ///      🔴 **① 不是形式主义。** 受益人给池子的 MEME 授权表达的是「我愿意为**自己的**行权付款」，
    ///      不是「谁都可以替我择时」。少了这条限制，第三方可以挑一个对受益人最不利的时刻，
    ///      把他的 MEME 强制换成股票代币 —— 授权额度还在，钱就还能被花。
    ///
    ///      ② 与 {depositAndMint} 是同一个取舍，而 M1-6 之后它已经**不再**是多余的那道门：
    ///      deadline 现在是 `max(expiry, clearedAt + 48h)`，一个从未开启的系列（`expiry == 0`）
    ///      读的是 `_gating[address(0)]` 那条记录 —— 只要那条记录上有过一个 `clearedAt`，
    ///      ④ 反而会先放行，这条路径的最后一道防线就退化成「调用方碰巧没有那个 id 的权证」。
    ///      把「系列得先存在」写成一句显式比较，比每次动 deadline 都重新推一遍这件事便宜。
    ///      （{pokeGating} 那一侧另有一道零地址的门，两道合起来才让那条记录永远是全零。）
    ///
    ///      # 三步，以及为什么记账排在它们前面
    ///
    ///      ```
    ///      s.exercised += amount                                   // 记账
    ///      warrant.burn(msg.sender, seriesId, amount)              // 1. 销毁权证（持有方）
    ///      meme.transferFrom(beneficiary, BURN_ADDRESS, memeAmount) // 2. 销毁受益人的 MEME
    ///      stock.transfer(beneficiary, amount)                     // 3. 股票代币直达受益人
    ///      ```
    ///
    ///      第 3 步失败会回滚前两步 —— **这正是产品承诺的那件事**：发行方冻结时用户不会失去权证。
    ///      在 EVM 里这是默认行为，唯一能打破它的是显式 `try/catch`，所以不变量 3 的反证也只有那一种
    ///      形状（见 `test/invariant/Invariant3ExerciseAtomicity.t.sol`）。
    ///
    ///      `spec.zh.md` §5.1 的草图把 `s.exercised += amount` 放在三步**之后**；这里提到前面，
    ///      与 {depositAndMint}「记账先于外部调用」同一条规矩。两只代币都是**任意**合约，
    ///      它们各自都能把控制权交出去；`nonReentrant` 挡的是**跨函数**的交错 —— 让 `settleExpired`
    ///      在「行权进行到一半」的中间状态上被调进来，是一件不必留给将来去想的事。
    ///      （反过来那一侧同样承重，理由写在 {settleExpired}。）
    ///
    ///      两次 ERC-20 调用返回成功之后，还分别核对**发送方**的余额变化：beneficiary 必须恰好扣除
    ///      `memeAmount`，池子必须恰好扣除 `amount`。否则 return-true/no-op 代币能白拿抵押品，
    ///      sender-pays-extra 代币则会多扣用户或击穿剩余权证的偿付覆盖。这里只约束发送方，接收方带税仍可用。
    ///
    ///      # 两处刻意**不做**的检查
    ///
    ///      - **不核对 `BURN_ADDRESS` 的余额增量。** 存入侧按到账增量记账是因为**超发**会击穿偿付；
    ///        这里核对增量只能保证「销毁足额」这条通缩性质，而代价是：MEME 哪天真的对这条路径收税，
    ///        本合约（不可升级）会让**全部行权**永久 revert。宁可让烧掉的少一点，也不能让一个外部
    ///        合约的参数变更把用户的权证变成砖。这条性质改由测试盯着 ——
    ///        `test/fork/RobinhoodFlapBurn.t.sol` 在真实实现上断言实收恰好等于转出额。
    ///      - **不挡 `amount > s.minted - s.exercised`。** 它由 ERC-1155 的余额检查结构性保证：
    ///        权证只在这里销毁、只按 1:1 铸出，销毁不了自己没有的份额。多写一次是把同一件事说两遍。
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external nonReentrant {
        Series storage s = _series[seriesId];

        if (msg.sender != beneficiary && msg.sender != distributor) {
            revert NotExerciseCaller(seriesId, msg.sender, beneficiary);
        }
        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (s.settled) revert SeriesSettled(seriesId);

        uint64 deadline = _exerciseDeadline(s);
        if (block.timestamp >= deadline) revert ExerciseWindowClosed(seriesId, deadline, block.timestamp);

        if (attestations.attestedVersion(beneficiary) == 0) revert NotAttested(beneficiary);

        // 🔴 **先收窄再相乘**，顺序是承重的：`amount` 是 `uint256`，而账上的 `exercised` 是
        //    `uint128`，所以装不下的量迟早要被拒。放在乘法**前面**拒，收获两件事：
        //    ① 乘积结构上装得下 —— 两个因子都 ≤ 2^128−1，积 ≤ (2^128−1)^2 < 2^256，
        //       于是这里不需要 `Math.mulDiv`，也不可能出现一条 Panic(0x11)；
        //    ② 超量行权拿到的是一条带值的 `SafeCastOverflowedUintDowncast`，而不是一条裸 Panic，
        //       或者更糟 —— 一路算出天文数字的 `memeAmount`，最后停在 MEME 的余额不足上。
        uint128 amount128 = SafeCast.toUint128(amount);
        uint256 memeAmount = (uint256(amount128) * s.strike) / 1e18;

        // 🔴 向下取整让 `amount * strike < 1e18` 的行权**一枚 MEME 都不用烧**，白拿股票代币 ——
        //    这正是 `openSeries` 的 `strike != 0` 那道门要挡的事情的整数版本。
        //    这里选择拒绝而不是改成向上取整：定价公式写在规格与接口上，改它是产品决定；
        //    而拒绝一笔算下来「免费」的行权，方向上只会更安全（受益人换一个更大的 `amount` 即可）。
        //
        //    残留的是**取整折扣**：少付的永远是那个被截掉的小数部分，**每笔严格小于 1 raw 单位 MEME**
        //    （即 1e-18 枚）。在 dust 档它的**相对**比例可以很大（strike = 1e17、amount = 19 时
        //    付 1 而不是 1.9），但**绝对**上界与调用次数无关地钉死在「每次 < 1 raw 单位」上，
        //    而每次都要付一整笔行权的 gas —— 差着十几个数量级。
        if (memeAmount == 0) revert ExerciseRoundsToZeroMeme(seriesId, amount, s.strike);

        s.exercised += amount128;

        warrant.burn(msg.sender, seriesId, amount);

        IERC20 memeToken = IERC20(s.memeToken);
        uint256 memeBalanceBefore = memeToken.balanceOf(beneficiary);
        memeToken.safeTransferFrom(beneficiary, BURN_ADDRESS, memeAmount);
        uint256 memeBalanceAfter = memeToken.balanceOf(beneficiary);
        if (memeBalanceAfter > memeBalanceBefore || memeBalanceBefore - memeBalanceAfter != memeAmount) {
            revert MemeTransferDebitMismatch(seriesId, memeAmount, memeBalanceBefore, memeBalanceAfter);
        }

        IERC20 stockToken = IERC20(s.stockToken);
        uint256 stockBalanceBefore = stockToken.balanceOf(address(this));
        stockToken.safeTransfer(beneficiary, amount);
        uint256 stockBalanceAfter = stockToken.balanceOf(address(this));
        if (stockBalanceAfter > stockBalanceBefore || stockBalanceBefore - stockBalanceAfter != amount) {
            revert StockTransferDebitMismatch(seriesId, amount, stockBalanceBefore, stockBalanceAfter);
        }

        emit Exercised(seriesId, msg.sender, beneficiary, amount, memeAmount);
    }

    /// @dev 行权窗口的截止时刻 ——「发行方冻结时自动延期」的**全部**实现就是这个表达式：
    ///
    ///      ```
    ///      active           ⟹ ∞
    ///      clearedAt == 0   ⟹ expiry                        // 从没观测到过解除 ⟹ 没有宽限
    ///      否则              ⟹ max(expiry, clearedAt + 48h)
    ///      ```
    ///
    ///      🔴 `settleExpired` 用**同一个**函数做互补判断（`>= deadline` 才可结算）。两处各写一份，
    ///      迟早会漂成一个「既不能行权、也不能结算」的窗口 —— 或者更糟，一个两者**都能**做的窗口。
    ///
    ///      ⚠️ `clearedAt == 0` 那一行不是规格里的 `max(expiry, 0 + 48h)` 的等价改写吗？在任何真实链上
    ///      是的（`expiry` 是个 2020 年代的时间戳，48h = 172800 早就过去了）。分开写是因为 `0` 在这里
    ///      是**哨兵**而不是时刻：它说的是「没有发生过解除」，而不是「1970-01-01 解除的」。
    ///      按哨兵写，一条把时间戳设在 172800 以内的测试就不会拿到一个凭空 48 小时的行权窗口。
    function _exerciseDeadline(Series storage s) private view returns (uint64) {
        Gating storage g = _gating[s.stockToken];
        if (g.active) return type(uint64).max;

        // 🔴 **当前读不通（无发行方门控接口）→ 无宽限，deadline 就是 `expiry`。**
        //
        //    历史语义是「读不通 → fail-open + 48h 宽限」（`clearedAt` 在进入不可读那一刻被盖）。那是
        //    为 bStock 的门控接口**临时**读不通（发行方合约升级等）留的保守延期。但要支持
        //    **flap.sh 式任意计价币**，这些 quote 绝大多数是**无发行方**的普通/包装币（WBNB / USDT /
        //    DOGE / 各种 custom），永远没有 `pauseManager()` / `compliance()`、永远读不通 → 旧语义把
        //    它们**每周结算都凭空拖 48 小时**（真链实测 C2 WBNB、C3 USDT、C5 DOGE 全中 `SettlementTooEarly`）。
        //
        //    放宽依据（用户 2026-09-15）：**能不能 launch 由 Flap 的 Portal 把控，warrant 侧无条件信任
        //    Flap Portal**；Portal 既已审过 token，我们的门控不必再对任意 quote 二次把关，对无发行方
        //    门控的代币「没有冻结」本就是事实。
        //
        //    ⚠️ 这里用 `g.unreadable` **精确区分**两种盖 `clearedAt` 的来路，只放宽读不通这一档：
        //      - **读不通**（`g.unreadable == true`，无发行方代币）→ 本行直接返回 `expiry`，不给宽限；
        //      - **真实 bStock 冻结后解除**（`_observe` 的 readable clear-edge，`g.unreadable == false`）→
        //        走下面的 `clearedAt + GRACE_PERIOD`，**宽限完全保留**。
        //    代价（明示）：一只本来可读的 bStock 若门控接口**在冻结期间恰好变得读不通**（发行方合约
        //    被毁/坏升级）会被当成干净、绕过那次冻结的结算延期——边缘场景，在「无条件信任 Flap Portal
        //    审 token」的模型下可接受。
        if (g.unreadable) return s.expiry;

        uint64 clearedAt = g.clearedAt;
        if (clearedAt == 0) return s.expiry;

        uint64 graceEnd = clearedAt + GRACE_PERIOD;
        return graceEnd > s.expiry ? graceEnd : s.expiry;
    }

    /// @dev 实时读一遍发行方门控。**这是本合约唯一一处「失败不算失败」的读**。
    ///
    ///      @return hit      观测到门控（代币冻结 / 全局急停 / **池地址**被拉黑或被制裁）
    ///      @return readable 五个读全部读通了
    ///
    ///      # 为什么是 fail-open
    ///
    ///      门控 view 读不通（发行方升级改了接口）时按「无门控」处理。池子**不可升级**，
    ///      fail-closed 会让一个再也读不通的接口把全部系列的抵押品永远冻死 ——
    ///      **严格坏于 fail-open 承认的那种损失**。代价写在 `docs/spec.zh.md` §11：若此时代币确实
    ///      处于暂停而 view 读不通，持有人会在完全无法行权的窗口里失去权证。宽限只买 48 小时。
    ///
    ///      # 三处不能省的细节
    ///
    ///      - **命中优先于读不通。** 任何一个读说「门控」，结论就是门控 —— 哪怕其余几个读不通。
    ///        这个方向只会让持有人多拿延期，反过来则可能在真的被冻结时照常结算。
    ///      - **不用 `abi.decode(…, (bool))`。** 它对「非 0 非 1 的脏布尔」会 revert，而那条 revert
    ///        会从这个本该吞掉一切失败的函数里**冒出去** —— 一只返回脏字节的代币就能让 poke 与结算
    ///        全部 revert，fail-open 当场变成 fail-closed。所以按 `uint256` 解，非零即真。
    ///      - **两个模块地址的高位必须干净。** 高位有脏字节时截断得到的是另一个地址，
    ///        那不是「读到了」，是「读到了看不懂的东西」—— 记为读不通。
    ///
    ///      # 🔴 BSC 版比 Robinhood 版多两个读（决策 53）
    ///
    ///      Robinhood 是三个（`paused` / `ACCESS_CONTROLLED_REGISTRY` / `isBlocked`），
    ///      这里是五个：管理器地址、`isTokenPaused`、合规模块地址、逐代币黑名单、全局制裁名单。
    ///      **反饿死那道门不受影响** —— {_staticWord} 是**逐个读**要求 `gasleft()` 够转发满预算的，
    ///      多一个读就多一道独立的门，而不是把同一个预算摊薄。变的只是 `_observe` 的总 gas 成本。
    function _readGating(address stock) private view returns (bool hit, bool readable) {
        // ── ① 冻结：pauseManager().isTokenPaused(stock) ────────────────────
        //    单币冻结与全局急停都落在这一个读里（实测：`pauseAllTokens()` 之后
        //    `isTokenPaused` 一并翻真），所以不必再问一次 `allTokensPaused()`。
        (bool okManager, uint256 managerWord) =
            _staticWord(stock, abi.encodeCall(IIssuerGatedStock.pauseManager, ()));
        if (managerWord >> 160 != 0) okManager = false;

        bool okPaused;
        uint256 pausedWord;
        if (okManager) {
            (okPaused, pausedWord) =
                _staticWord(address(uint160(managerWord)), abi.encodeCall(IIssuerPauseManager.isTokenPaused, (stock)));
        }
        if (okPaused && pausedWord != 0) return (true, true);

        // ── ② 合规：逐代币黑名单 + 全局制裁名单 ───────────────────────────
        (bool okCompliance, uint256 complianceWord) =
            _staticWord(stock, abi.encodeCall(IIssuerGatedStock.compliance, ()));
        if (complianceWord >> 160 != 0) okCompliance = false;

        bool okBlocked;
        uint256 blockedWord;
        bool okSanctioned;
        uint256 sanctionedWord;
        if (okCompliance) {
            address compliance = address(uint160(complianceWord));
            (okBlocked, blockedWord) =
                _staticWord(compliance, abi.encodeCall(IIssuerCompliance.blockedAddresses, (stock, address(this))));
            (okSanctioned, sanctionedWord) =
                _staticWord(compliance, abi.encodeCall(IIssuerCompliance.sanctionedAddresses, (address(this))));
        }
        if (okBlocked && blockedWord != 0) return (true, true);
        if (okSanctioned && sanctionedWord != 0) return (true, true);

        return (false, okManager && okPaused && okCompliance && okBlocked && okSanctioned);
    }

    /// @dev 一次带 gas 预算的 `staticcall`，把「返回了一个 32 字节的字」以外的一切都判为读不通。
    ///
    ///      🔴 **调用前先要求 gasleft() 够转发满预算，不够就 revert。** 见 {GATING_READ_GAS}：
    ///      不加这道门，任何人都能用一笔精心计量 gas 的交易把健康的 view 饿死，
    ///      凭空造出一条「干净 → 不可读」的边，从而把 `clearedAt` 一路前推。
    ///      EIP-150 只转发 63/64 的余量，而且是在 `STATICCALL` 付完冷账户/基础成本之后才截断。
    ///      所以门槛是 `ceil(预算 × 64 / 63) + 调用余量`，不能只写前半段；否则一个精确 gas
    ///      limit 仍能让健康 view 拿到少于预算的 gas、伪造一次「读不通」。
    ///
    ///      ⚠️ 目标地址上**没有代码**时 `staticcall` 会成功且返回空 —— 长度检查因此不是形式主义，
    ///      它是「这个地址根本不是一只带门控的代币」唯一的识别方式。
    function _staticWord(address target, bytes memory callData) private view returns (bool ok, uint256 word) {
        uint256 needed = (GATING_READ_GAS * 64) / 63 + 1 + GATING_STATICCALL_OVERHEAD;
        uint256 available = gasleft();
        if (available < needed) revert NotEnoughGasToObserveGating(needed, available);

        (bool success, bytes memory ret) = target.staticcall{gas: GATING_READ_GAS}(callData);
        if (!success || ret.length != 32) return (false, 0);

        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev 观测并记录一次门控状态。**这段的边语义是本里程碑的核心，不是实现细节。**
    ///
    ///      @return gated 本次**实时**读取的结论（fail-open：读不通 ⟹ 未命中）
    ///
    ///      三个状态、九条边，只有三条写 `clearedAt`：
    ///
    ///      | 记录 \ 实时 | 门控 | 干净 | 读不通 |
    ///      |---|---|---|---|
    ///      | **门控**   | no-op | `active=false` **+ 盖章** | `unreadable=true, active=false` **+ 盖章** |
    ///      | **干净**   | `active=true` | 🔴 **no-op** | `unreadable=true` **+ 盖章** |
    ///      | **读不通** | `active=true, unreadable=false` | `unreadable=false` | 🔴 **no-op** |
    ///
    ///      🔴 **左下角那格是整张表的重点。** 若每次「干净 poke」都写 `clearedAt`，任何人每 47 小时
    ///      调一次即可把它一路前推，`settleExpired` 永久 revert、滚存永不发生，而攻击者手上本该作废的
    ///      系列获得**无限期免费展期**。不变量 4② 抓不到这个 —— 它的前提本身以 `clearedAt` 表述，
    ///      前提被推走就空真。**不变量 4③ 正是为此而设**（`test/invariant/Invariant4SettlementAndGating.t.sol`）。
    ///
    ///      🔴 **右下角那格是同一件事的后门。** fail-open 必须盖宽限（否则代币真的暂停而 view 读不通时，
    ///      持有人会在无法行权的窗口里被结算掉），但它必须绑定在「**进入**不可读状态」这一次转变上，
    ///      而不是「每次读不通」。这是唯一允许在没有真实 `门控 → 干净` 边时盖章的情形。
    ///
    ///      **「读不通 → 干净」不盖章**：进入不可读那一刻已经盖过一次，出来时再盖一次等于把
    ///      「进 → 出 → 进」变成一台前推 `clearedAt` 的泵。代价是：若代币在整个不可读窗口里真的
    ///      暂停着、直到窗口之后才恢复可读，那 48 小时买到的时间已经用掉了 —— §11 记的正是这条损失。
    function _observe(address stock) private returns (bool gated) {
        (bool hit, bool readable) = _readGating(stock);
        Gating storage g = _gating[stock];

        if (hit) {
            // 进入 / 保持门控。`clearedAt` 一律不碰 —— 它记的是「离开」的时刻。
            if (!g.active) g.active = true;
            if (g.unreadable) g.unreadable = false;
            gated = true;
        } else if (!readable) {
            if (!g.unreadable) {
                g.unreadable = true;
                g.active = false; // 门控 → 不可读：按解除翻转处理
                g.clearedAt = uint64(block.timestamp);
            }
        } else if (g.active) {
            g.active = false; // 唯一一条真实的解除边
            g.clearedAt = uint64(block.timestamp);
        } else if (g.unreadable) {
            g.unreadable = false; // 读不通 → 干净：不重新盖章
        }

        emit GatingObserved(stock, g.active, !g.unreadable, g.clearedAt);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev **它只做一件事：把一次实时观测记进链上。** 延期与结算读的都是这份记录 ——
    ///      门控发生了却没人 poke，就不产生延期（合约只信记录在案的观测）。
    ///
    ///      🔴 零地址在这里挡掉：`_gating[address(0)]` 是一条**未开启系列**会读到的记录
    ///      （`s.stockToken == address(0)`）。今天 `exercise` 与 `settleExpired` 都先显式拒绝未开启的系列，
    ///      所以它写坏了也没人读；把它拦在门外，是为了让「那条记录永远是全零」这件事不必每次
    ///      新增函数时都重新论证一遍。
    ///
    ///      `nonReentrant` 在这里不是承重的（`_observe` 只做 `staticcall`，被叫醒的代币写不了任何状态），
    ///      但它让整个合约的再入语义只有一句话：**六个入口里任意两个都不能交错**。
    function pokeGating(address stockToken) external nonReentrant {
        if (stockToken == address(0)) revert ZeroToken();
        _observe(stockToken);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # 门控期间结算被结构性阻止 —— 那就是「自动延期」
    ///
    ///      没有管理员按下延期开关：结算只是**做不到**，于是系列的行权窗口保持开放。
    ///      发行方若仍阻止股票转账，实际行权会整笔回滚。
    ///
    ///      🔴 **`pokeGating` 是关窗的动作，不是开窗的动作。** 行权读的是**记录**：记录说门控中就无截止，
    ///      所以发行方一解除，行权立刻可用 —— **不需要任何人先 poke**。观测到解除只做一件事：
    ///      把无限的窗口收敛成 `max(expiry, clearedAt + 48h)`。
    ///      把它说成「观测之后才能行权」会让前端劝用户等 Monitor，那既是错的、也把一个无许可的设计
    ///      说成有运营依赖。钉在 `test_exercise_worksBeforeAnyPokeOnceTheIssuerClears`。
    ///
    ///      | # | 门 | 它挡住的那件事 |
    ///      |---|---|---|
    ///      | ① | 系列已开启 | 否则任何人都能对一个不存在的 id 写出一条「已结算」记录 |
    ///      | ② | 未结算 | 结算是一次性的：`remainder` 已经算定，重算会覆盖 #12 滚走后的账 |
    ///      | ③ | 实时读取无门控 | 自动延期本身 |
    ///      | ④ | 已过 deadline | 与 `exercise` 的 `< deadline` 严格互补 |
    ///
    ///      🔴 **③ 之前先 `_observe` 一次**，这不是顺手：记录可能是陈旧的。最要紧的一种陈旧是
    ///      「记录说干净、发行方其实已经冻上了」—— 不重读的话，结算会在持有人**根本无法行权**的
    ///      时候照常推进。反过来那种（记录说门控、其实已解除）也会被这次观测纠正。
    ///
    ///      ⚠️ **这次观测只在结算成功时才留在链上。** 它跟整笔交易一起回滚 ——
    ///      所以「记录说门控、实时已解除」的系列不会因为有人反复调 `settleExpired` 就把 48 小时的
    ///      宽限走完：那个时钟要由一次 `pokeGating` 起头。运营口径因此是**先 poke，再等，再结算**，
    ///      而不是「反复试探 settleExpired」。这条对活性没有影响 —— poke 无许可，任何人都能调。
    ///
    ///      # 为什么 `nonReentrant` 在这里是承重的
    ///
    ///      🔴 少了它，`depositAndMint` 的「已结算不得再存入」那道门可以被**绕过**：存入是先转账
    ///      再记账，而转账会把控制权交给股票代币；代币在回调里调 `settleExpired` 结算掉这个系列，
    ///      回来之后存入照常把抵押品记进 `deposited`、把权证铸出去 —— 而 `remainder` 已经按结算那一刻的
    ///      账算定了。结果是一笔既不在 `remainder`、也不属于任何未结算系列的抵押品永久卡在池子里，
    ///      对应的权证一枚也行权不了。守卫是**跨函数**的（同一个 transient 槽），所以这条路径被堵死。
    function settleExpired(uint256 seriesId) external nonReentrant {
        Series storage s = _series[seriesId];

        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (s.settled) revert SeriesSettled(seriesId);

        if (_observe(s.stockToken)) revert SettlementGatedByIssuer(seriesId, s.stockToken);

        uint64 deadline = _exerciseDeadline(s);
        if (block.timestamp < deadline) revert SettlementTooEarly(seriesId, deadline, block.timestamp);

        // 🔴 减法**结构上**不会下溢，checked 只是最后一道保险：`exercised` 只在 `exercise` 里增加，
        //    每一次增加都伴随一次等量的权证销毁，而权证只按 1:1 对着 `deposited` 的同一次增量铸出。
        //    于是 `exercised ≤ minted == deposited` 恒成立。真要坏了，这里 revert 好过写出一个
        //    环绕后天文数字的 `remainder` —— 那会让 #12 从池子里滚走它根本没有的抵押品。
        uint128 remainder = s.deposited - s.exercised;

        s.settled = true;
        s.remainder = remainder;

        emit Settled(seriesId, remainder, deadline);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # 抵押品永不离开本合约
    ///
    ///      滚存里**没有一笔转账**：前序系列的 `remainder` 归零，同一个数记进后继系列的
    ///      `deposited` 与 `minted`，再铸出等量权证给 `distributor`。池内该股票代币的余额在这笔交易
    ///      前后一个 wei 都不动（不变量 7），所以它不构成「转出」—— 不变量 5 的措辞依赖这一点。
    ///
    ///      🔴 **原设计不是这样的。** `claimExpired → 金库 → 再存入` 会让稳态下约 `S/f` 规模
    ///      （S = 周税收，f = 行权参与率；f = 5% 时约 20 周税收）的**整个池子每周经过一次
    ///      Flap Guardian 可升级的金库** —— R4 的「在途 ≤24h」被低估一到两个数量级。
    ///      改成池内滚存之后，金库经手的只剩当周新到账的税收。见 `docs/design.md` §10-25。
    ///
    ///      # 六道门，全部由池子自证 —— 所以它无许可
    ///
    ///      | # | 门 | 它挡住的那件事 |
    ///      |---|---|---|
    ///      | ① | 前序已开启 | 打错 id 时给一句「这个系列不存在」，而不是「它还没结算」 |
    ///      | ② | 前序已结算 | `remainder` 要到结算那一刻才算定 |
    ///      | ③ | `remainder != 0` | 空滚存；**同时就是「不可二次滚存」的全部实现** |
    ///      | ④ | 后继已开启 | 往一个没人开过的 id 上凭空铸权证 |
    ///      | ⑤ | 同 MEME、同股票代币 | 见下 —— 唯一一道**偿付性**的门 |
    ///      | ⑥ | 后继未结算、未过期 | 铸出一批生下来就行权不了的权证 |
    ///
    ///      ① 与 ② 有重叠（没开过的系列必然未结算），留着 ① 只为错误面：两个字段同槽，多这一次比较
    ///      不多读一次存储。同 {depositAndMint} 把「未开启」与「不是该系列的金库」分开判的取舍。
    ///
    ///      🔴 **⑤ 是承重的那一道。** 少了「同股票代币」，A 系列（GME 抵押）的余量能被记成 B 系列
    ///      （另一只股票代币）的债权 —— B 的池内余额兜不住它，不变量 1② 当场断掉。少了「同 MEME」，
    ///      一个项目的抵押品会去支撑另一个项目的权证，而行权烧的是各自的 MEME（`spec.zh.md` §2.1），
    ///      那批权证的持有人永远付不出正确的价钱。
    ///
    ///      ④ 判的是 `n.strike != 0`，不是 `n.vault != address(0)`。两者今天等价（`openSeries` 的 ②
    ///      保证已开启的系列 strike 必非零），选前者是**规格点名的**（`spec.zh.md` §5.1）：
    ///      零行权价的系列在滚存眼里等于不存在。滚存是唯一一条**凭空铸出权证**的路径，
    ///      所以这道门贴着「铸出来的权证值不值钱」判，而不是贴着「有没有人开过」判。
    ///
    ///      ⑥ 比的是 `n.expiry`，**不是** {_exerciseDeadline}。后者会把「已过 expiry、但因门控延期
    ///      仍可行权」的系列也算成合法后继 —— 那等于允许任何人把余量滚进一个早就过期、只是还没人
    ///      结算的旧系列：抵押品不会丢（它会随那个系列的结算继续往下滚），但当周的 merkle root
    ///      拿不到这笔钱，而铸给 `distributor` 的那批权证没有任何 root 覆盖它，会永远留在它手上。
    ///      **合法后继的集合越小越好**，所以取严的那一个；无门控时两者本来就相等。
    ///
    ///      `nextSeriesId == seriesId` 不需要单独一道门：② 要求前序**已**结算，⑥ 要求后继**未**结算，
    ///      同一个 id 上两者不可能同时成立。
    ///
    ///      # 边界：没有后继系列时干净 revert
    ///
    ///      项目停摆、这一周没人开系列 —— 余量就停在池子里（无 admin 的必然结果）。任何时候开出一个
    ///      到期在未来的新系列，滚存立刻恢复：**只有延迟，没有损失。**
    ///
    ///      ⚠️ **残余敞口：合法后继由调用方指定，而池子分辨不出「哪一个才是这周的那一个」。**
    ///      `openSeries` 无许可，所以抢注者可以用同一对 (MEME, 股票代币) 开一个行权价离谱的系列，
    ///      抢在正常滚存前面把余量滚进去。他**偷不走东西**（权证仍然铸给 `distributor`、抵押品仍在池内、
    ///      settle → roll 会继续往下走），但他能把一周的分发搅掉。这与 `openSeries` 的三元组抢注是
    ///      **同一个**根因，缓解手段与条件化的上线阻塞记在 issue #21 / #23，不在本函数内解决。
    ///
    ///      # `nonReentrant` 在这里**不是**承重的
    ///
    ///      唯一的外部调用是 `warrant.mint(distributor, …)`，而 `distributor` 是本合约的 immutable、
    ///      是我们自己的 `MerkleDistributor`（`ERC1155Holder`，收到回调只返回魔数），且记账已经排在
    ///      它前面。加上它是为了让整个合约的再入语义只有一句话：**六个入口里任意两个都不能交错**
    ///      （同 {pokeGating}）。
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external nonReentrant {
        Series storage s = _series[seriesId];

        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (!s.settled) revert SeriesNotSettled(seriesId);

        uint128 amount = s.remainder;
        if (amount == 0) revert NothingToRoll(seriesId);

        Series storage n = _series[nextSeriesId];

        if (n.strike == 0) revert SeriesNotOpen(nextSeriesId);
        if (n.memeToken != s.memeToken || n.stockToken != s.stockToken) {
            revert SuccessorTokenMismatch(nextSeriesId, n.memeToken, n.stockToken);
        }
        if (n.settled) revert SeriesSettled(nextSeriesId);
        if (block.timestamp >= n.expiry) revert SuccessorExpired(nextSeriesId, n.expiry, block.timestamp);

        // 🔴 **先清零，再记入。** 前序的 `remainder` 是这笔钱在账上唯一的位置；两处同时记着它，
        //    哪怕只在一条外部调用的时间里，都是一次实打实的重复计账（不变量 1② 会看见）。
        //    `deposited` 不减 —— 它记的是「这个系列历史上收过多少」，而已结算的系列本就被排除在
        //    不变量 1① 之外（判据见 `test/invariant/Invariant1And2MintingPath.t.sol` 的 `CollateralCheck`）。
        s.remainder = 0;

        // 两个加法都是 checked：真要有一天把 `uint128` 加爆，在这里 revert 好过静默环绕成一个
        // 池子根本没有的债权额。同 {depositAndMint} 对 `SafeCast` 的取舍。
        n.deposited += amount;
        n.minted += amount;

        // 记账先于外部调用：`warrant.mint` 会对合约收款方回调 `onERC1155Received`。
        warrant.mint(distributor, nextSeriesId, amount);

        emit Rolled(seriesId, nextSeriesId, amount);
    }
}
