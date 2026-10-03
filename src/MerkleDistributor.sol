// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {PoolBound} from "./PoolBound.sol";

/// @title MerkleDistributor
/// @notice 权证的归属与领取。清算池把整周的权证一次性铸给本合约，持有者凭 merkle proof 领走 ——
///         或者一步到位，直接从这份累积余额里行权。
///
/// # 🔴 本合约持有的是**别人的**权证
///
/// 这句话决定了下面每一行代码的形状。`ClearingPool.depositAndMint` 与 `rollExpired` 把整个系列的权证
/// 铸给本合约，它们在被领走之前是**全体未领取用户的共享余额**。因此这里的每一个消费入口都不是
/// 「花自己的钱」，而是「从共享盘子里取走某个人的那一份」。
///
/// 同一张 merkle leaf 有**两个**消费入口（{claim} 与 {claimAndExercise}），于是：
///
/// ```
/// claimAndExercise(seriesId, account, amount, proof)     // 重放 N 次
///   └─ pool.exercise(…, beneficiary = account)
///         └─ warrant.burn(msg.sender = distributor, seriesId, amount)
///                ↑ 烧的是本合约持有的【所有未领取用户】的权证
/// ```
///
/// 漏掉标志位不是「重复领自己的份额」，而是**从共享余额里偷别人的**：调用者每次都付自己的 MEME，
/// 拿走的却是尚未领取的其他持有人对应的股票代币 —— 那些人握着有效 proof，却已无货可兑。
///
/// 所以两条路径共写同一位 {claimed}，而且**这不是靠两处各写一遍来保证的**：
/// 它们调用的是同一个 private 的 {_consume}，一条 leaf 的「查 → 验 → 置位」只有一份实现。
/// 把它写成两份，才需要有人记得让它们保持一致。
///
/// # 三条访问约束，各挡一件不同的事
///
/// | 入口 | 谁可以调 | 为什么是这个答案 |
/// |---|---|---|
/// | {setRoot} | `publisher` | 🔴 本系统**唯一的中心化信任点**（`docs/spec.zh.md` §11） |
/// | {claim} | **任何人** | keeper 可代付 gas 批量投递；权证只进 leaf 指定的 `account`，代提交拿不走东西 |
/// | {claimAndExercise} | **仅 `account` 本人** | 行权花的是 account 的 MEME，不可由第三方代为择时 |
///
/// 🔴 {claim} 与 {claimAndExercise} 的许可级别不同，是因为**它们的后果不同**：前者只是把一份
/// 本来就属于 account 的权证送到他手上（他可以不理会）；后者会**花掉他的 MEME**。授权给池子的
/// MEME 额度表达的是「我愿意为自己的行权付款」，不是「谁都可以替我择时」。
///
/// @dev 领取路径的 leaf 编码见 {leafOf}；声明门（`attestations.attestedVersion(account) != 0`）
///      不在本合约里 —— 它长在 `ClearingPool.exercise` 上，且查的是**受益人**。
///      本合约代行权时受益人就是 `account`，因此未声明的 `account` 在这条路径下同样被拒。
///      完整设计见 `docs/spec.zh.md` §5.4 与 issue #13。
///
///      🔴 继承 `ERC1155Holder` 不是可有可无的礼节：ERC-1155 的 `_mint` 对合约收款方强制调用
///      `onERC1155Received` 并校验返回值 —— 少了它，铸造会直接 revert，整条铸造路径无从跑起。
///      接线里这一环看不见，所以它由 `test/DeploySystem.t.sol` 在真实四合约上铸一次来证明。
///      两个 `onERC1155*Received` 是非 view 的（ERC-1155 规范如此），因此会出现在本合约的对外可写
///      函数集里。这不构成入口：两者除了返回魔数之外什么都不做。
contract MerkleDistributor is PoolBound, ERC1155Holder, ReentrancyGuardTransient {
    /// @notice 每周发布归属 root 的地址。🔴 **本系统唯一的中心化信任点。**
    ///
    /// @dev 它是 `immutable`，同 `AttestationRegistry.publisher` —— 可更换的 publisher 等于
    ///      多一条「谁能改这条链上的分发权」的路径，而本合约无 admin、无升级。
    ///      它能做的事只有一件：给**尚未开始领取**的系列写 root（见 {setRoot}）。
    ///      它拿不走任何权证：`claim` 只往 leaf 指定的 `account` 发货。
    address public immutable publisher;

    /// @notice 每个系列的归属 root。`bytes32(0)` = 尚未发布。
    /// @dev 未发布前无法领取，已铸的权证留在本合约里；root 补发之后可追溯领取。
    mapping(uint256 seriesId => bytes32 root) public roots;

    /// @notice 该系列的 root 是否已冻结 —— 第一张 leaf 被消费的那一刻置位，此后永久不可改。
    ///
    /// @dev 🔴 **这一位是 {setRoot} 的可替换性与「已发布的归属不可被追溯改写」之间的分界线。**
    ///      两个极端各有一条真实的失败模式：
    ///
    ///      - **root 永久 write-once**：publisher 打错一个字，这一周的分发全数错付且**无法挽回**
    ///        （本合约无 admin，权证已经铸出来了）；
    ///      - **root 永远可改**：分发已经开始之后，publisher 仍能把剩下的份额重新指给任何人 ——
    ///        那正是本合约最不该有的那种权力。
    ///
    ///      冻结点选在「第一张 leaf 被消费」上，因为那是**第一个人依据这份 root 行动**的时刻：
    ///      在那之前改动不伤害任何人（没有人据此做过任何事），在那之后改动就是追溯改写。
    ///      而且这条保证是**可读的**：`rootFrozen[seriesId] == true` ⟹ 这个系列的归属已定死。
    mapping(uint256 seriesId => bool frozen) public rootFrozen;

    /// @notice 🔴 **两条消费路径共写的那一位。** `true` = 这张 leaf 已经被消费掉了。
    /// @dev 一个 (系列, 账户) 只有一位，因此同一个 account 在同一个系列里只能有**一张**可消费的 leaf。
    ///      归属计算（M4 的 Indexer）必须为每个账户每周只出一条记录 —— 出两条的话，
    ///      第二条永远消费不掉。
    mapping(uint256 seriesId => mapping(address account => bool)) public claimed;

    /// @notice 发布了一个系列的归属 root。
    /// @param previousRoot 被覆盖掉的那一个（`bytes32(0)` = 这是首次发布）。
    ///                     🔴 记下来是为了让「这个系列的 root 被改过几次、从什么改成什么」
    ///                     在链上完整可查 —— 冻结只保证「开始领取之后不再变」，不保证「从未变过」。
    event RootSet(uint256 indexed seriesId, bytes32 root, bytes32 previousRoot);

    /// @notice 一张 leaf 被消费了。
    ///
    /// @param exercised `false` = 权证已转给 `account`（{claim}）；
    ///                  `true`  = 已直接行权，权证从本合约销毁、股票代币直达 `account`
    ///                            （{claimAndExercise}，行权本身另有 `ClearingPool.Exercised`）
    ///
    /// @dev 🔴 **两条路径发同一条事件，只用一个布尔区分。** 理由与它们共写同一位标志位是同一条：
    ///      「这张 leaf 被消费了」在链上只该有一处出处。发两种事件的话，链下要回答
    ///      「这张 leaf 还能不能领」就得记得把两种都订上 —— 漏一种就会重算出一份并不存在的余额。
    event Claimed(uint256 indexed seriesId, address indexed account, uint256 amount, bool exercised);

    error ZeroPublisher();
    error NotPublisher(address caller);

    /// @dev 零 root 是「尚未发布」的哨兵值。写进去等于什么都没做，却会让
    ///      「`roots[id] != 0` ⟹ 已发布」这个判据失真 —— 同 {PoolBound-setPool} 对零地址的取舍。
    error ZeroRoot(uint256 seriesId);

    /// @dev 这个系列已经有人领过了，root 就此定死。见 {rootFrozen}。
    error RootAlreadyFrozen(uint256 seriesId, bytes32 root);

    /// @dev 这个系列还没有 root。权证可能已经铸给本合约了 —— 等 publisher 发布即可，没有损失。
    error NoRoot(uint256 seriesId);

    /// @dev 🔴 这条错误是本合约存在的全部理由。见合约头部的重放示意图。
    error AlreadyClaimed(uint256 seriesId, address account);

    /// @dev proof 与本系列的 root 对不上。`amount` 一并报出来：最常见的原因是数量抄错了一位，
    ///      而不是 proof 本身有问题。
    error InvalidProof(uint256 seriesId, address account, uint256 amount);

    /// @dev {claimAndExercise} 只有 `account` 本人可调 —— 行权花的是他的 MEME。
    error NotAccount(uint256 seriesId, address caller, address account);

    /// @dev 见 {_consume}：零份额的 leaf 在两个入口上的可消费性不一致，因此在共用的那道门里挡掉。
    error ZeroAmount(uint256 seriesId, address account);

    /// @dev 还没绑定清算池（{PoolBound}）。绑定之前本合约收不到任何权证，因此这条在真实流程里不可达；
    ///      显式挡掉是为了让失败停在一句说得清的话上，而不是停在一次对零地址的调用上。
    error PoolNotBound();

    /// @param publisher_ 每周发布归属 root 的地址
    ///
    /// @dev 🔴 publisher 与**部署者**（{PoolBound-deployer}）刻意分开，尽管部署脚本默认让它们相等。
    ///      两把钥匙的使用节奏差着一个数量级：部署者只在部署那一天用一次（两笔 `setPool` 之后
    ///      它的权限就用尽了），而 publisher 每周都要签一笔 `setRoot` —— 它必须是一把热钥匙。
    ///      把周用的热钥匙焊死成「当初部署的那一个」，等于要求部署密钥永远保持在线。
    constructor(address publisher_) {
        if (publisher_ == address(0)) revert ZeroPublisher();
        publisher = publisher_;
    }

    /// @notice leaf 的编码：`keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`。
    ///
    /// @dev 公开出来是为了给 Indexer（M4）与前端**一处**权威出处 —— 同一个编码抄两遍，迟早有一遍会漂，
    ///      而漂掉的后果是整周的 proof 全部验不过。
    ///      ⚠️ 但测试里不该用它反过来验它自己：`test/MerkleDistributor.t.sol` 独立算一份
    ///      （同 `ClearingPool.seriesIdOf` 的取舍）。
    ///
    ///      两处细节都是承重的：
    ///
    ///      🔴 **`seriesId` 在 leaf 里面。** 标志位已经是按系列分开的（`claimed[seriesId][account]`），
    ///      所以看起来是多余的 —— 但它挡的是**另一条路**：publisher 若把同一个 root 误发给两个系列，
    ///      同一张 leaf 就能在两个系列上各消费一次，第二次动的是另一批未领取用户的共享余额。
    ///      把系列钉进 leaf，这件事在结构上不可能发生，而不是靠 publisher 不犯错。
    ///
    ///      🔴 **哈希两次。** 这是 OpenZeppelin `StandardMerkleTree` 的约定：内部节点是
    ///      64 字节两个哈希的 keccak，leaf 若只哈希一次，一段**恰好 64 字节**的 leaf 原像
    ///      就可能同时是一个内部节点的原像 —— 于是「中间节点」能被当成 leaf 提交（second preimage）。
    ///      多哈希一次让两者的原像长度永久错开。
    ///      Indexer 侧对应 `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`。
    function leafOf(uint256 seriesId, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))));
    }

    /// @notice 权证合约。读的是**池子的那个 `immutable`**，本合约不另存一份。
    /// @dev 多存一份就多一处可能与池子指向不同的地方，而两者指向不同时 `claim` 会把一个
    ///      毫不相干的 ERC-1155 转给用户。绑定之前这里 revert（{PoolNotBound}）。
    function warrant() public view returns (IERC1155) {
        return IERC1155(address(_boundPool().warrant()));
    }

    /// @notice 发布某个系列的归属 root。仅 `publisher`。
    ///
    /// @dev 三道门：
    ///
    ///      | # | 门 | 它挡住的那件事 |
    ///      |---|---|---|
    ///      | ① | 调用方是 publisher | 任何人都能改写整周的分发 |
    ///      | ② | root 非零 | 零是「尚未发布」的哨兵值 |
    ///      | ③ | 该系列尚未有人领取 | 🔴 **追溯改写已经开始的分发** —— 见 {rootFrozen} |
    ///
    ///      ③ 在**第一张 leaf 被消费**之前允许改写，是刻意留的一条纠错路径：root 打错时，
    ///      本合约没有任何别的办法把权证送到对的人手上（无 admin、权证已经铸出来了）。
    ///      纠错窗口关得很早 —— 第一个人依据这份 root 行动之后就关上。
    function setRoot(uint256 seriesId, bytes32 root) external {
        if (msg.sender != publisher) revert NotPublisher(msg.sender);
        if (root == bytes32(0)) revert ZeroRoot(seriesId);

        bytes32 previousRoot = roots[seriesId];
        if (rootFrozen[seriesId]) revert RootAlreadyFrozen(seriesId, previousRoot);

        roots[seriesId] = root;
        emit RootSet(seriesId, root, previousRoot);
    }

    /// @notice 领取权证。**无许可** —— 任何人都可以代 `account` 提交 proof。
    ///
    /// @dev 代提交拿不走东西：收货地址不是 `msg.sender`，而是 **leaf 里写死的那个 `account`**。
    ///      于是 keeper（或我们）可以代付 gas 批量投递，持有者零操作也能收到权证。
    ///
    ///      ⚠️ 这条路径**不碰**声明门，也不碰 MEME：它只是把一份本来就属于 `account` 的权证
    ///      送到他手上。受限辖区的用户因此可以完整参与「持有 → 累积 → 领取 → 卖出」（§10）。
    ///
    ///      已结算系列的权证照常可领 —— 领到的是一份行权不了的权证（不变量 4①）。这里不加门：
    ///      加了只会让「我的那一份到底在哪」多一种说不清的状态，而权证本身仍是 `account` 的资产。
    function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _consume(seriesId, account, amount, proof);

        // 记账（`claimed` 置位）已经发生在外部调用之前 —— 收款方若是合约，ERC-1155 会回调它。
        warrant().safeTransferFrom(address(this), account, seriesId, amount, "");

        emit Claimed(seriesId, account, amount, false);
    }

    /// @notice 领取并当场行权，**两笔完成**（approve + 本函数）。仅 `account` 本人可调。
    ///
    /// @dev 权证**不经过** `account` 的手：本合约以持有人的身份调
    ///      `pool.exercise(seriesId, amount, beneficiary = account)`，于是
    ///
    ///      - 权证从**本合约**销毁（`warrant.burn(msg.sender = distributor, …)`）；
    ///      - MEME 从 **`account`** 拉取 —— 他必须先 `approve` 给 **`ClearingPool`**（不是本合约）；
    ///      - 声明门查 **`account`**（池子那一侧的规矩，见 `ClearingPool.exercise` 的第 ⑤ 道门）；
    ///      - 股票代币**直达 `account`**。
    ///
    ///      用户路径因此从三笔（claim + approve + exercise）压到两笔。
    ///
    ///      🔴 **`msg.sender == account` 这道门必须在这里，不能只靠池子。** 池子的调用方白名单是
    ///      「受益人本人**或** distributor」—— 本合约正好在白名单里，所以池子那一侧看到的是一次
    ///      合法的代行权，它分辨不出这次代行权是不是 `account` 自己要的。少了这道门，
    ///      任何人都能挑一个对 `account` 最不利的时刻，把他授权给池子的 MEME 换成股票代币。
    function claimAndExercise(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        // 🔴 顺序说明：这道门在标志位**之前**，但它不写任何状态 ——「在做任何事之前先检查标志位」
        //    这条规矩管的是**副作用**，不是比较。放在前面只为让第三方拿到的是
        //    「你不是这张 leaf 的主人」，而不是一句关于别人领没领过的话。
        if (msg.sender != account) revert NotAccount(seriesId, msg.sender, account);

        _consume(seriesId, account, amount, proof);

        _boundPool().exercise(seriesId, amount, account);

        emit Claimed(seriesId, account, amount, true);
    }

    /// @dev 🔴 **一张 leaf 的「查 → 验 → 置位」只有这一份实现**，{claim} 与 {claimAndExercise} 都走它。
    ///
    ///      写成两份也能对，但那时「两个入口的门完全一致」就变成一条需要有人记得维护的约定；
    ///      写成一份，它是编译器保证的。这是本票交付的东西里最重要的一行结构。
    ///
    ///      顺序是固定的，**标志位排在最前面**：
    ///
    ///      | # | 门 | 它挡住的那件事 |
    ///      |---|---|---|
    ///      | ① | 未领取 | 🔴 重放 —— 从共享余额里偷别人的（见合约头部） |
    ///      | ② | `amount != 0` | 见下 |
    ///      | ③ | 已发布 root | 对着一个空 root 验 proof |
    ///      | ④ | proof 有效 | 自造 leaf |
    ///
    ///      ② 挡的不是攻击，是**两个入口的不对称**：`amount == 0` 的 leaf 在
    ///      {claimAndExercise} 那一侧必然被池子拒掉（`memeAmount` 取整到 0 ⟹
    ///      `ExerciseRoundsToZeroMeme`），而 {claim} 会照常把它消费掉、转 0 份权证。
    ///      于是同一张 leaf 「能不能消费」有两个答案 —— 正是本票要消灭的那类不对称。
    ///
    ///      置位与冻结都写在返回之前，**外部调用一律排在本函数之后**（checks-effects-interactions）：
    ///      权证转账会回调收款方，行权会把控制权交给两只任意的 ERC-20。
    function _consume(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) private {
        if (claimed[seriesId][account]) revert AlreadyClaimed(seriesId, account);
        if (amount == 0) revert ZeroAmount(seriesId, account);

        bytes32 root = roots[seriesId];
        if (root == bytes32(0)) revert NoRoot(seriesId);
        if (!MerkleProof.verify(proof, root, leafOf(seriesId, account, amount))) {
            revert InvalidProof(seriesId, account, amount);
        }

        claimed[seriesId][account] = true;

        // 第一张 leaf 一旦被消费，这个系列的归属就定死了。见 {rootFrozen}。
        if (!rootFrozen[seriesId]) rootFrozen[seriesId] = true;
    }

    /// @dev 已绑定的清算池。绑定之前 `pool == address(0)`，此时对它发起调用只会得到一次
    ///      「向无代码地址的 staticcall 成功且返回空」，再在 ABI 解码上失败 —— 那条 revert
    ///      说不清任何事情。见 {PoolBound} 里同一个取舍。
    function _boundPool() private view returns (IClearingPool) {
        address boundPool = pool;
        if (boundPool == address(0)) revert PoolNotBound();
        return IClearingPool(boundPool);
    }
}
