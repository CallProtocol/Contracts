// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";

/// @title AttestationRegistry
/// @notice 用户在行权前**一次性**签署的合规声明存证。🔴 不可升级，每链一个。
///
/// # 这个合约存在的理由，是证明某个开关**不存在**
///
/// 任何管理员可控的行权前置检查，都是一个可以冻结全体用户资产的节流阀 ——
/// 合规 admin 私钥一旦丢失或被夺，全部权证永久变砖，而我们对外承诺的是
/// 「清算池不可升级、无 admin 提取路径」。加一道可控的门，那句承诺当场作废。
///
/// 所以本合约的全部设计约束都指向同一件事：**这道门在结构上不可能锁死任何人。**
///
/// | 约束 | 实现 |
/// |---|---|
/// | `attestedVersion` 只增不减 | 无任何函数可减少或清零，**publisher 也不能** |
/// | 只有账户本人能改自己的状态 | `attest()` 只写 `msg.sender` |
/// | `versions[0]` 永久存在且不可变 | 只可追加，无删改函数 |
/// | publisher 权限仅限 append | 追加新版本**不影响**任何既有声明 |
///
/// 这三条合起来就是**不变量 6**（`spec.zh.md` §7）：`versions[0]` 存在且不可变
/// ⟹ 任意地址在任意时刻都能调 `attest(0, …)` 满足门槛。它与不变量 5（无管理员出口）
/// 是本项目仅有的两条「证明某个开关不存在」的手段，不得省略。
///
/// # 为什么哈希要作为参数传进来
///
/// `termsHash` / `attestationHash` 已经在链上了，调用时仍要求传入并校验相等 ——
/// 目的是**让文本哈希出现在交易 calldata 里**：钱包签名界面展示的是原始 calldata，
/// 用户签的是「我看过这段文本」而不是一个空调用；且前端**无法**替用户悄悄声明另一版本。
///
/// 证据落在交易本身与 `Attested` 事件里，永久可查，无需额外存储。
///
/// @dev 完整设计见 `docs/spec.zh.md` §5.5；version 0 的两段文本见 `legal/attestation-v0/`。
contract AttestationRegistry is IAttestationRegistry {
    /// @param termsHash        TERMS 文本（关于工具本身）的 keccak256
    /// @param attestationHash  ATTESTATION 文本（关于用户本人）的 keccak256
    struct TextVersion {
        bytes32 termsHash;
        bytes32 attestationHash;
    }

    /// @notice 只可追加的文本版本表。`versions[0]` 由构造函数写入，因此长度恒 ≥ 1。
    /// @dev 🔴 全合约**没有**任何写 `versions[i]` 或缩短 `versions` 的路径 ——
    ///      这是不变量 6③ 的结构性依据，不是约定。
    TextVersion[] public versions;

    /// @inheritdoc IAttestationRegistry
    /// @dev 🔴 唯一的写入点是 `attest()`，且它只写 `msg.sender`，只做「取大」。
    mapping(address account => uint256 versionPlusOne) public attestedVersion;

    /// @notice 唯一有权**追加**新版本文本的地址。它不能改、不能删、不能碰任何人的声明状态。
    address public immutable publisher;

    /// @notice 追加了一版新文本。
    event VersionAdded(uint256 indexed version, bytes32 termsHash, bytes32 attestationHash);

    /// @notice 某地址签署了某一版文本。
    /// @dev 🔴 本事件是**签署行为**的流水，不是账户状态的快照。重复签署、或在签过更高版本之后
    ///      再签一遍旧版本，都会照常 emit。链下要还原「该账户当前的声明版本」，应当读
    ///      `attestedVersion`，或对事件取 **max** 而不是取**最后一条**。
    event Attested(address indexed who, uint256 version, bytes32 termsHash, bytes32 attestationHash, uint256 at);

    error ZeroPublisher();
    error NotPublisher(address caller);
    error EmptyTextHash();
    error UnknownVersion(uint256 version, uint256 known);
    error TextMismatch(uint256 version, bytes32 termsHash, bytes32 attestationHash);

    /// @param publisher_       追加后续版本文本的地址
    /// @param termsHash        version 0 的 TERMS 哈希
    /// @param attestationHash  version 0 的 ATTESTATION 哈希
    ///
    /// @dev 🔴 **version 0 在构造函数里就写进去，不留给后续交易。**
    ///
    ///      `spec.zh.md` §5.5 的设计草图与 issue #8 原本是「先部署，再由 publisher 调
    ///      `addVersion` 追加 version 0」。那样有两个真实后果：
    ///
    ///      ① 两笔交易之间存在一段 `versions` 为空的窗口 —— 那正是这道门被焊死的样子，
    ///         `attest()` 对所有人 revert。不变量 6③ 的前提（`versions[0]` 存在）
    ///         于是变成「部署脚本跑完了第二步」这条**流程**保证，而不是结构保证；
    ///      ② publisher 必须是部署者本人，否则 `addVersion` 会被 `onlyPublisher` 拒掉 ——
    ///         publisher 想用多签就得靠人工补一笔，窗口随之拉长到人的响应时间。
    ///
    ///      放进构造函数之后，`versions.length >= 1` 从合约存在的第一个区块起恒成立，
    ///      publisher 也回到它该有的位置：**只负责追加后续版本**。
    constructor(address publisher_, bytes32 termsHash, bytes32 attestationHash) {
        if (publisher_ == address(0)) revert ZeroPublisher();
        publisher = publisher_;
        _append(termsHash, attestationHash);
    }

    /// @notice 已追加的文本版本数。
    /// @dev `versions` 的自动 getter 只按下标取单项，取不到长度；部署脚本与前端都要用它。
    function versionCount() external view returns (uint256) {
        return versions.length;
    }

    /// @notice 追加一版新文本。仅 publisher 可调，**只能追加**。
    /// @return version 新版本的下标。
    /// @dev 追加**不得**使任何既有声明失效：本函数不触碰 `attestedVersion`，也不触碰既有的
    ///      `versions[i]`。链上永远只要求「≥1 次声明」，要求最新版本是前端的事。
    function addVersion(bytes32 termsHash, bytes32 attestationHash) external returns (uint256 version) {
        if (msg.sender != publisher) revert NotPublisher(msg.sender);
        return _append(termsHash, attestationHash);
    }

    /// @dev 版本表**唯一**的写入路径。构造函数与 `addVersion` 都走它，所以「只可追加」
    ///      这件事只需要在这一处成立。
    function _append(bytes32 termsHash, bytes32 attestationHash) private returns (uint256 version) {
        // 零哈希不是一段文本。放进去会得到一版「谁都能用全零参数满足」的声明，
        // 门还开着但证据是空的 —— 这是部署时忘了填文本最可能的样子，在这里挡掉。
        if (termsHash == bytes32(0) || attestationHash == bytes32(0)) revert EmptyTextHash();

        version = versions.length;
        versions.push(TextVersion(termsHash, attestationHash));
        emit VersionAdded(version, termsHash, attestationHash);
    }

    /// @notice 签署第 `v` 版文本。只写调用者自己的状态。
    /// @param v                版本下标
    /// @param termsHash        必须与 `versions[v].termsHash` 相等
    /// @param attestationHash  必须与 `versions[v].attestationHash` 相等
    ///
    /// @dev 🔴 **对合法的 `(v, 两个哈希)` 三元组，本函数永不 revert。** 这是不变量 6③ 的落点：
    ///      `versions[0]` 由构造函数写入、此后不可变 ⟹ 任意地址在任意时刻调 `attest(0, …)` 都成功。
    ///      `UnknownVersion` 因此对 `v == 0` 是不可达的 —— 版本表长度恒 ≥ 1。
    ///
    ///      因此这里写的是**取大**而不是 `require(v + 1 > attestedVersion[msg.sender])`
    ///      ——后者见于 `spec.zh.md` §5.5 的设计草图，但它会让「已经签过 0 的地址再签一次 0」
    ///      revert，于是不变量 6③ 只能被削弱成「**尚未声明的**地址恒可 attest(0)」。
    ///      不变量 6 的全部意义就是「这道门结构上锁不死任何人」，它不该带前提条件。
    ///      取大同样满足「单调不减」（这正是不变量 6① 的措辞），且严格更强：
    ///      签署旧版本不会回退状态，也不会失败，只是留下一条签署流水。
    function attest(uint256 v, bytes32 termsHash, bytes32 attestationHash) external {
        uint256 known = versions.length;
        if (v >= known) revert UnknownVersion(v, known);

        TextVersion memory t = versions[v];
        if (termsHash != t.termsHash || attestationHash != t.attestationHash) {
            revert TextMismatch(v, termsHash, attestationHash);
        }

        uint256 next = v + 1;
        if (next > attestedVersion[msg.sender]) attestedVersion[msg.sender] = next;

        emit Attested(msg.sender, v, termsHash, attestationHash, block.timestamp);
    }
}
