// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VaultRegistry} from "../../src/VaultRegistry.sol";

/// @title VaultFactoryProbe
/// @notice issue #23 spike 用的**探针工厂**：形状照 `WarrantVaultFactory` 该有的样子写，
///         但只做四件事 —— 拒绝非 VaultPortal、建一个最小金库、写一条绑定、**把 Portal 传进来的
///         每一个参数原样记下来**。
///
/// 🔴 **这不是 M2-5（#37）要交付的那个工厂。** 真工厂的形态取决于金库模板（#33）与本票的裁决结果，
/// 现在写它就是在裁决之前替裁决做决定。探针只回答一个问题：
/// **「真实的 VaultPortal 到底会不会回调我们，回调时手上那份 `(memeToken, vault)` 可不可信」**——
/// 也就是判据 1。
///
/// 记录下来的东西里最要紧的是 {Recorded-taxTokenCodeSize}：Flap 的规范说金库**先于**代币创建，
/// `taxToken` 是一个 CREATE2 预测地址、那一刻还没有字节码
/// （`docs/research/flap-vault-identity-spike.md` §3）。这条如果为真，
/// 「绑定可信」就不能靠「去问问那个代币」，只能靠**同笔交易的原子性**。探针把它量出来，
/// 而不是引用文档。
contract VaultFactoryProbe {
    /// @notice Flap 的 VaultPortal，按 `block.chainid` 取值 —— 与 Flap 规范里
    ///         `VaultFactoryBaseV2._getVaultPortal()` **同一套写法**（硬编码、无 setter）。
    ///
    /// @dev 🔴 这么写而不是做成构造参数，是为了保住四步构造顺序里第 1 步的「构造无参」：
    ///      Portal 不在 `工厂 ↔ registry ↔ 池子` 那个环里，把它做成参数不会解开环，
    ///      却会凭空多一个部署期可填错的地方。
    ///
    ///      ⚠️ 值是**实测**的，不是从 BSC 那张表抄的：BSC 的 VaultPortal
    ///      `0x9049…` 在 Robinhood Chain 上**零字节码**。
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant VAULT_PORTAL_ROBINHOOD = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

    /// @notice 身份根。一次性槽 —— 仅部署者、写一次、写后永久锁死（与 {PoolBound} 同构）。
    VaultRegistry public registry;
    address public immutable deployer;

    /// @param caller            回调那一刻的 `msg.sender`。判据 1 要认的就是它。
    /// @param taxToken          Portal 交给我们的 MEME 地址
    /// @param quoteToken        计价币
    /// @param creator           最初调 VaultPortal 的那个人
    /// @param vaultData         金库自定义数据
    /// @param taxTokenCodeSize  🔴 回调那一刻 `taxToken` 的字节码长度。**0 = 代币还不存在。**
    /// @param vault             我们建出来的金库
    struct Recorded {
        address caller;
        address taxToken;
        address quoteToken;
        address creator;
        bytes vaultData;
        uint256 taxTokenCodeSize;
        address vault;
    }

    Recorded internal _last;
    uint256 public callCount;

    /// @dev 未知选择器的调用（Portal 探测可选扩展时会发生）记在这里，供分叉测试打印。
    ///      探针要回答「Portal 到底调了我们什么」，所以这些**不能**被静默吞掉。
    bytes4[] internal _unknownSelectors;

    error OnlyVaultPortal(address caller);
    error UnsupportedChain(uint256 chainId);
    error NotDeployer(address caller);
    error RegistryAlreadySet(address registry);
    error RegistryNotSet();

    constructor() {
        deployer = msg.sender;
    }

    // ───────────────────────── 一次性槽（构造环的第 4 步）─────────────────────────

    /// @notice 绑定身份根。**仅部署者、仅一次、写后永久锁死。**
    /// @dev 四步构造顺序里唯一的写入动作，且它落在**工厂**这个卫星上 ——
    ///      registry 与池子两个承重合约因此保持零写入路径。见 {VaultRegistry} 的合约头。
    function setRegistry(VaultRegistry r) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        if (address(registry) != address(0)) revert RegistryAlreadySet(address(registry));
        registry = r;
    }

    // ───────────────────────── Flap 规范：Portal 会调的那几个 ─────────────────────────

    /// @notice 🔴 **判据 1 与判据 2 的交汇点。** Portal 建币时回调这里。
    ///
    /// @dev 签名来自实测：`newVault(address,address,address,bytes)` = `0x15b92d7a`，
    ///      Flap 自己的 `IndexVaultFactory` 在 Robinhood Chain 上对非 VaultPortal 的调用
    ///      回一句 `"Only VaultPortal"`（字符串 require，不是自定义错误）。
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault)
    {
        if (msg.sender != _vaultPortal()) revert OnlyVaultPortal(msg.sender);
        if (address(registry) == address(0)) revert RegistryNotSet();

        vault = address(new VaultStubForProbe(taxToken, quoteToken));

        _last = Recorded({
            caller: msg.sender,
            taxToken: taxToken,
            quoteToken: quoteToken,
            creator: creator,
            vaultData: vaultData,
            // 🔴 **在写绑定之前量**：这一刻代币存不存在，决定了「绑定可信」能靠什么论证。
            taxTokenCodeSize: taxToken.code.length,
            vault: vault
        });
        callCount++;

        // 判据 3 的写入就发生在这里，且只发生在这里。
        registry.bind(taxToken, vault);
    }

    /// @dev 规范要求。Robinhood Chain 上唯一启用的计价币是原生币 `address(0)`。
    function isQuoteTokenSupported(address) external pure returns (bool) {
        return true;
    }

    /// @dev 规范 v2.2+ 的发射前校验钩子，Portal 用 `staticcall` 调。
    ///      返回 `(false, reason)` 会让发射带着 reason revert；缺这个选择器则报
    ///      "Factory validation hook missing"。探针一律放行。
    function onBeforeLaunch(bytes calldata) external pure returns (bool success, string memory reason) {
        return (true, "");
    }

    /// @dev 声明成 v2.3 —— 低于它的话 `VaultBaseV3` + ERC20 计价币那条路走不通。
    function factorySpecVersion() external pure returns (string memory) {
        return "v2.3";
    }

    // ───────────────────────────── 读取记录 ─────────────────────────────

    function last() external view returns (Recorded memory) {
        return _last;
    }

    function unknownSelectors() external view returns (bytes4[] memory) {
        return _unknownSelectors;
    }

    /// @dev 🔴 **不吞掉未知调用，记下来。** 探针的价值一半在「Portal 调了我们什么」，
    ///      而一个静默的 fallback 会把这半边抹掉。返回空 `bytes` 让可选扩展的探测按
    ///      「没实现」处理，与真工厂缺那个函数时的行为一致。
    fallback() external {
        _unknownSelectors.push(msg.sig);
    }

    function _vaultPortal() internal view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return VAULT_PORTAL_ROBINHOOD;
        revert UnsupportedChain(block.chainid);
    }
}

/// @notice 探针建出来的最小金库。只实现 Portal 在发射流程里会读的那几个。
/// @dev 真金库是 #33 的交付物；这里够用就行 —— 本票要证的不是金库长什么样。
contract VaultStubForProbe {
    address public immutable taxToken;
    address internal immutable _quoteToken;

    constructor(address taxToken_, address quoteToken_) {
        taxToken = taxToken_;
        _quoteToken = quoteToken_;
    }

    /// @dev `VaultPortal.getVault()` 会读它。
    function description() external pure returns (string memory) {
        return "index-rein #23 spike probe vault";
    }

    /// @dev `VaultBaseV3`：规范要求它**不得 revert**，且等于所服务代币的计价币。
    function vaultQuoteToken() external view returns (address) {
        return _quoteToken;
    }

    receive() external payable {}
}
