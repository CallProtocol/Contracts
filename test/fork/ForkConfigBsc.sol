// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";

/// @notice bStocks 的**暂停管理器**面里我们用到的那几个。
///
/// @dev 这是 Robinhood `Stock.paused()` 在 BSC 上的对应物 —— 但**不在代币上，在一个共用的
///      管理器上**：`stock.pauseManager().isTokenPaused(stock)`。26 只 bStock 共用同一个。
///      接口取自 runtime 的 `PUSH4` 派发表 + openchain 反查，逐个链上调过（32 个候选解出 21 个）。
interface IBStockPauseManager {
    function isTokenPaused(address token) external view returns (bool);
    function pausedTokens(address token) external view returns (bool);
    function allTokensPaused() external view returns (bool);
    function pauseToken(address token) external;
    function unpauseToken(address token) external;
    function pauseAllTokens() external;
}

/// @notice bStocks 的**合规模块**面里我们用到的那几个。
///
/// @dev 这是 Robinhood `registry.isBlocked(pool)` 在 BSC 上的对应物，但键多了一维：
///      黑名单是**逐代币**的 `blockedAddresses(token, who)`，另有一张**全局**制裁名单
///      `sanctionedAddresses(who)`。26 只 bStock 共用同一个模块。
///
///      🔴 **`checkIsCompliant` 不能当门控钩子用。** 它以 revert 表达「被拦」
///      （`UserBlocked()` / `UserSanctioned()`），而 `ClearingPool._readGating` 要的是一个
///      **不 revert 的读数**。而且它的真实签名是 `(address token, address user)`、与
///      `msg.sender` 无关 —— 起初按 `(from, to)` 的假设是错的，逐种组合试出来的。
///      出处：`docs/research/bsc-flap-portal-probe.md` §6.4。
interface IBStockCompliance {
    function blockedAddresses(address token, address who) external view returns (bool);
    function sanctionedAddresses(address who) external view returns (bool);
    function checkIsCompliant(address token, address user) external view;
    function addToBlocklist(address token, address[] calldata users) external;
    function addToSanctionsList(address[] calldata users) external;
}

/// @title ForkConfigBsc
/// @notice **BSC 分叉测试的唯一配置来源**，与 {ForkConfig}（Robinhood）平行。
///
/// # 为什么是一份独立文件，而不是给 {ForkConfig} 加一组带后缀的常量
///
/// 决策 53 定的是「两条链的门控源码独立分支管理」，这份配置沿用同一个原则。另有两条更实际的理由：
///
/// - **三个 shell 消费者按常量名 grep 这个文件**（`fork-node.sh` 19 处、`preflight-mainnet.sh`
///   3 处、以及彩排驱动器）。同名不同后缀的两组常量会让那些 grep 变成前缀匹配，
///   而「按目标链选文件」是一个不会误伤的判据。
/// - Robinhood 那份的注释里有大量「这条链上……」的实测结论。两条链的结论**不同**
///   （见下面每一处对照），混在一个文件里读起来必然要不断分辨「这句说的是哪条链」。
///
/// # 数据出处
///
/// 下面每一个常量都来自 2026-09-08 的 BSC 主网实测，记录在
/// `docs/research/bsc-flap-portal-probe.md`（附复现命令）。**没有一个是从文档抄的。**
///
/// # 🔴 与 Robinhood 最大的一处不同：没有可用的免费端点
///
/// BSC 公共端点的状态窗口实测只有 **约 120 块（≈55 秒）**（geth 默认 `TriesInMemory=128` 的形状），
/// 比 Robinhood 官方端点的 ≈6k–20k 块还差一个数量级。所以：
///
/// - **钉死高度的分叉必须配 `RPC_BSC`（私有归档端点）**，没有社区兜底；
/// - 内置的那个公共端点**只对 `bscLatest()` 有意义**，它服务不了任何历史高度。
///
/// 出处：§9 / §9.6.2。
library ForkConfigBsc {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant BSC_CHAIN_ID = 56;

    // ─────────────────────────── 抵押品：bStocks ───────────────────────────

    /// @dev GMEB · GameStop（bStock，BeaconProxy）。**首发标的**（决策 54）。
    ///
    ///      🔴 选它而不是 Ondo 的 `GMEon`，理由是两条实测事实：Ondo 四只**完全没有** ERC-8056
    ///      UI multiplier（本项目「靠股息 Multiplier 复投」的核心机制读不到），且有
    ///      `burn(address,uint256)` 能烧**任意持有人**的余额；bStocks 只有自烧 —— 对 GMEB 逐个试过
    ///      五个「烧别人」入口，全部失败。出处：§6.5。
    ///
    ///      ✅ 它的计价币配置 `(1, 29, 29, 7, 0)` 与 Robinhood 主网 GME **逐位相同** ——
    ///      同一档曲线、同一个 swapType。迁移因此不必换标的。
    address internal constant GMEB = 0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C;

    /// @dev bStock 的实现与 beacon。**26 只 bStock 共用同一个 beacon** ——
    ///      🔴 发行方一笔交易可替换全部实现，这是抵押品风险披露（R2）里等级最高的一条，
    ///      也是 BSC 版 version 0 法务文本替换那半句的依据（决策 56）。
    address internal constant EXPECTED_GMEB_IMPLEMENTATION = 0xCFEd6c4679297ea4889F8183bC057B4A86C64e46;
    bytes32 internal constant EXPECTED_GMEB_IMPLEMENTATION_CODEHASH =
        0x060dc28d4dd8d9bb8a381d4009bccbac129ce743a10b3d8aa0ffef5034b50544;
    address internal constant BSTOCK_BEACON = 0x156D6dce9a4f6139a3406F1f021F1A4880De93a3;
    bytes32 internal constant BSTOCK_BEACON_CODEHASH =
        0x80fbad22136c0abdce6e0f3cc46cd0572318e01b92dbd5b4d5795ef6e8808711;

    /// @dev 发行方门控的两个入口（26 只 bStock 共用）。语义与实测见 {IBStockPauseManager} /
    ///      {IBStockCompliance} 与 §6.3 / §6.4。
    ///
    ///      🔴 **Robinhood 那三个选择器在这里一个都不存在**：`paused()` 与
    ///      `ACCESS_CONTROLLED_REGISTRY()` 在 bStock 上都 revert。映射关系：
    ///
    ///      | Robinhood | bStocks |
    ///      |---|---|
    ///      | `stock.paused()` | `stock.pauseManager().isTokenPaused(stock)` |
    ///      | `stock.ACCESS_CONTROLLED_REGISTRY()` | `stock.compliance()` |
    ///      | `registry.isBlocked(pool)` | `compliance.blockedAddresses(stock, who)` + `sanctionedAddresses(who)` |
    address internal constant BSTOCK_COMPLIANCE = 0x53dBa7AaBDe774787A1F57236B235567dA8e14F4;
    bytes32 internal constant BSTOCK_COMPLIANCE_CODEHASH =
        0xe53b7759da23b16be41e4faa36b85c70ec750a2a631492998f40833fab17aff8;
    address internal constant BSTOCK_PAUSE_MANAGER = 0x9fc74Be63f3589485B2423984a7a0557e0CF700a;
    bytes32 internal constant BSTOCK_PAUSE_MANAGER_CODEHASH =
        0x65c448e9ecdde44701b7a20c846fec9000d9aee6e3ddeb9362bb1980d755ff4d;

    // ────────────────────────────── Flap Portal ──────────────────────────────

    /// @dev Flap 主入口（ERC-1967 proxy）。**代理部署于区块 39,980,228（2024-06-27）** ——
    ///      subgraph 的 BSC `startBlock` 取的就是它。
    ///
    ///      🔴 **下面那几份 codehash 在 BSC 上是「某一时刻的快照」，不是 canary 判据。**
    ///      Portal 全历史升级过 **108 次**，2026 年内 44 次，最近一次在核验前**两天**。
    ///      Robinhood 那套「钉实现 codehash 当 canary」在这条链上会持续变红 —— 按决策 55，
    ///      BSC 版 canary 钉的是**行为**：镜头 18 字与四个字段下标、枚举矩阵、毕业后确实落 V2 池。
    ///      出处：§2.1。
    address internal constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    uint256 internal constant FLAP_PORTAL_DEPLOY_BLOCK = 39_980_228;

    /// @dev 快照时的实现与模块。**Portal 没有公开的 `launcher()` getter** —— 下面这个 launcher
    ///      是从一次真实建币的调用树里抓出来的（全是从代理发出的 `delegatecall`）。见 §9.6.1。
    address internal constant SNAPSHOT_FLAP_PORTAL_IMPLEMENTATION = 0x16148E9F39fdD93dFeE5ff3B8cDb32C8D5643B34;
    bytes32 internal constant SNAPSHOT_FLAP_PORTAL_IMPLEMENTATION_CODEHASH =
        0x92f2e0f6f55679bf4616f6661008998c7e9a4f9f2b92a1b9ec40e07b4926a6f2;
    address internal constant SNAPSHOT_FLAP_PORTAL_LAUNCHER = 0x87354597ff986916dA83cC4895363f9bA4478f88;
    bytes32 internal constant SNAPSHOT_FLAP_PORTAL_LAUNCHER_CODEHASH =
        0xf12aeefb5407136e99a73f597c909a289885218a18f0d3d7dc4ffa07a45cd046;

    /// @dev `FlapTaxTokenV3` 实现。**这一份反而是稳的** —— 每只代币都是指向它的 EIP-1167 最小代理，
    ///      而代理的初始化码哈希里含它的地址，靓号 salt 的挖矿直接依赖它（见 {vanityInitCodeHash}）。
    address internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION =
        0x024f18294970B5c76c0691b87f138A0317156422;
    bytes32 internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH =
        0xb530a7e0ff0d6ab435a5ec71f2b04092937735e23a0fb3a0746724ce9b875b4a;

    // ───────────────────────────── 建币枚举矩阵 ─────────────────────────────

    /// @notice 🔴 **BSC 上唯一能走通的建币 enum 组合，逐位扫出来的**（§4.5）。
    ///
    /// @dev 与 Robinhood 那张表**结论相同、错误码不同** —— 任何把错误码写死进断言的 BSC 版测试
    ///      都要按这一列写，不能照抄 Robinhood 那份：
    ///
    ///      | 常量 | 取别的值（BSC 实测） | Robinhood 记录 |
    ///      |---|---|---|
    ///      | `tokenVersion = 6` | 0/1/3/4/5/7 → `FeatureDisabled()`（`0xac5f6092`）；**2 → `Error("Non-tax: rates must be 0")`，即该版本在 BSC 上是启用的** | 0…5、7 一律 `FeatureDisabled()` |
    ///      | `migratorType = 1` | 0/2/**3** → **`InvalidMigratorType()`**（`0x4fd0ffbb`） | 记为 `FeatureDisabled()` |
    ///      | `dexThresh = 1` | 0/2/3/4/5 → `InvalidDexThresholdType(uint8)`（`0x77146b42`） | ✅ 逐位相同 |
    ///      | `dexId = 0` | 1/2 → `0xead3ad50`（**openchain / 4byte 均无记录，vendored 也没声明**；抛出点定位在 launcher 模块的头几条校验，见 §9.6.3） | 未记错误码 |
    ///      | `lpFeeProfile = 0` | 0/1/2 **都能发**；3/4 空 revert。V2 迁移下它不起作用 | — |
    ///
    ///      🔴 **`3`（`PCS_INFINITY_CL_MIGRATOR`）被拒**，这正是阻塞项 2 解除的关键：调研报告担心
    ///      「BSC 会把税代币迁到 Pancake Infinity CL 池」，而我们**根本传不进**那个迁移器。
    uint8 internal constant FLAP_TOKEN_VERSION_TAXED_V3 = 6;
    uint8 internal constant FLAP_MIGRATOR_TYPE_V2 = 1;
    uint8 internal constant FLAP_DEX_THRESH_SUPPORTED = 1;
    uint8 internal constant FLAP_DEX_ID_SUPPORTED = 0;
    uint8 internal constant FLAP_LP_FEE_PROFILE_STANDARD = 0;

    /// @notice 🔴 **BSC Portal 强制代币地址以 `7777` 结尾** —— 调研报告没有预见这一条。
    ///
    /// @dev 不满足报 `VanityAddressRequirementNotMet(address)`（`0xca4c5b2d`）。代币走
    ///      EIP-1167 最小代理 + CREATE2、**部署者是 Portal 自己**、salt 即原始 `uint256`，
    ///      所以初始化码完全可预测。合约侧不用改（`WarrantLauncher` 的 salt 是调用方入参），
    ///      但**链下挖矿的常量必须换成 BSC 这一份**。
    function vanityInitCodeHash() internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }

    // ───────────────────────────── 计价币配置 ─────────────────────────────

    /// @notice {GMEB} 的计价币配置 —— 与 Robinhood 上 GME 的五元组**逐位相同**。
    ///
    /// @dev 2026-09-08 实测 `Portal.getQuoteTokenConfiguration(GMEB)` = `(1, 29, 29, 7, 0)`，
    ///      首次配置于区块 115,351,586（2026-08-11）。
    ///
    ///      ⚠️ 与 Robinhood 那份**同一条风险**：这不是我们的状态，是 Flap 管理员存储里的五个字节；
    ///      撤销之后偿付不受影响、发行能力归零。
    ///
    ///      ⚠️ **`nativeToQuoteSwapType = 7` 超出 vendored `NativeToQuoteSwapType` 的枚举上限（6）**。
    ///      拿 vendored 的结构体去 ABI 解码这个配置会**当场 revert** —— 所以这里存的是裸 `uint8`，
    ///      与 Robinhood 那份同一个处理方式。
    ///
    ///      ℹ️ BSC 全历史共启用过 **39 只**计价币（26 bStock + 4 Ondo + 9 普通 ERC-20），完整名单见
    ///      §5.2。**名单仍在增长**（最近一条配置发生在核验当天），所以链下资产表要从链上现读。
    uint8 internal constant EXPECTED_GMEB_QUOTE_ENABLED = 1;
    /// @dev 与 Robinhood GME 同为 29 —— 同一档曲线。
    uint8 internal constant EXPECTED_GMEB_QUOTE_DEFAULT_CURVE = 29;
    uint8 internal constant EXPECTED_GMEB_QUOTE_ALTERNATIVE_CURVE = 29;
    uint8 internal constant EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE = 7;
    uint8 internal constant EXPECTED_GMEB_QUOTE_DEX_ID = 0;

    // ───────────────────────────── 样本与 DEX ─────────────────────────────

    /// @notice 钉死高度上的**已毕业**样本 MEME：MarsCoin，税率 300/300、SPCXB 计价。
    ///
    /// @dev 🔴 **与 Robinhood 那份的角色不同**：`ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE` 是一只
    ///      **仍在曲线上**的样本（全部供应在 Portal 手里，所以持有人余额从 Portal `prank` 转出）。
    ///      这一只**已经毕业**，供应在 V2 池里。
    ///
    ///      它在这里承担的是另一件事：**「毕业后的池子确实是 V2 形状」的历史证据** ——
    ///      `token0/token1/getReserves` 齐全、`slot0/liquidity/fee/tickSpacing` 全部 revert。
    ///
    ///      ⚠️ **BSC 上还没有钉一只「曲线阶段」的样本。** 分叉测试若需要曲线阶段的代币，
    ///      目前的做法是现场发一只（`newTokenV6` 在分叉上实测走得通，见 §4.5），
    ///      而不是钉一只历史的。
    address internal constant PINNED_GRADUATED_TAX_TOKEN_V3_SAMPLE = 0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777;

    /// @dev 上面那只样本毕业后的池子，以及产出它的工厂 / 路由。
    ///      工厂身份是**双向坐实**的：`INIT_CODE_PAIR_HASH` 对上 PancakeSwap V2，且
    ///      `factory.getPair(SPCXB, MarsCoin)` 反查回同一个池地址。路由地址取自
    ///      `TaxProcessor.initialize` 的入参（一次真实建币的调用树）。
    address internal constant PINNED_GRADUATED_SAMPLE_POOL = 0x94F3ed36706c746ad59fAdCAF271b7431AB1D8F1;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    /// @dev 上面那只样本的计价币（SPCXB，也是一只 bStock）。只用于复核样本本身，不是我们的标的。
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    /// @notice USD 定价那一侧 —— **走 PancakeSwap V3，不是 V2**（§9.5.1）。
    ///
    /// @dev 🔴 **Pancake V3 的 `Swap` 事件签名与 Uniswap V3 不同**（多两个 `protocolFeesToken0/1`）：
    ///      topic0 是 `0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83`，
    ///      而不是仓库 subgraph 模板认的 `0xc42079f9…`。实测：GMEB/USDT 池最近 16,000 块的
    ///      576 条日志里 **556 条是前者，后者零条**。原样搬模板过去会**一条事件都收不到**。
    ///
    ///      ⚠️ 费率档**逐资产不同**：主流是 `2500`，但 SPYB 与 QQQB 的活跃池在 `100` 档；
    ///      而且同一只代币四个档位的池子**都被建出来了**，只有一档 `liquidity() != 0` ——
    ///      路由生成必须按流动性挑，不能按「`getPool` 返回非零」挑。
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant GMEB_USDT_V3_POOL = 0x908d49048EB3a7bEdfd238972403842805EAF2bE;
    uint24 internal constant GMEB_USDT_V3_FEE = 2500;

    // ──────────────────────────── 端点与高度 ────────────────────────────

    /// @dev 与 Robinhood 那组平行的三个变量。`FORK_STRICT_BLOCK` / `FORK_REQUIRED` 是**跨链共用**的，
    ///      直接取 {ForkConfig} 的常量，不在这里另写一份。
    string internal constant ENV_RPC_BSC = "RPC_BSC";
    string internal constant ENV_RPC_BSC_LIST = "RPC_BSC_LIST";
    string internal constant ENV_BLOCK_BSC = "FORK_BLOCK_BSC";

    /// @dev 🔴 **这个公共端点服务不了任何钉死高度。**
    ///
    ///      实测：BSC 公共端点的状态窗口只有约 **120 块（≈55 秒）**，`head-127` 起报
    ///      `missing trie node`（另两个端点分别报「归档请求需要 token」与限流）。所以它留在候选表里
    ///      **只对 `bscLatest()` 有意义**；钉死高度的分叉必须配 `RPC_BSC`。
    ///
    ///      ✅ 与 Robinhood 不同的一处：BSC 公共端点**不需要**浏览器 UA（五个端点无 UA 均正常回话）。
    string internal constant RPC_BSC_PUBLIC = "https://bsc-dataseed.bnbchain.org";

    /// @dev 钉死的验收高度。选它的判据是「归档端点在这个高度上能同时服务 storage 与 eth_call，
    ///      且 GMEB 的计价币配置读出来仍是 `(1,29,29,7,0)`」—— 两条都实测过。
    uint256 internal constant DEFAULT_BLOCK_BSC = 120_650_000;

    /// @notice BSC 分叉目标。
    function bsc() internal view returns (ForkTarget memory) {
        return ForkTarget({
            name: "BSC",
            chainId: BSC_CHAIN_ID,
            rpcUrls: _rpcUrls(),
            blockNumber: _envUint(ENV_BLOCK_BSC, DEFAULT_BLOCK_BSC),
            strictBlock: _envBool(ForkConfig.ENV_STRICT_BLOCK, false),
            required: _envBool(ForkConfig.ENV_REQUIRED, false),
            probe: GMEB
        });
    }

    /// @notice 当前实现 canary 专用目标；始终读 latest。
    ///
    /// @dev 🔴 `strictBlock` 在这里是 `true`，与 Robinhood 那份同理：latest canary 问的是
    ///      「上游今天怎么样」，退回任何历史高度都会把问题答错。
    function bscLatest() internal view returns (ForkTarget memory target) {
        target = bsc();
        target.blockNumber = 0;
        target.strictBlock = true;
    }

    // ─────────────────────────────── 内部 ───────────────────────────────
    //
    // ⚠️ 下面四个是 {ForkConfig} 同名私有函数的 BSC 版。**不是复制粘贴的疏忽** ——
    //    那边它们是 `private`，跨库调不到；而 `parseRpcList` / `looksLikeRpcUrl` 是 `internal`，
    //    这里直接复用，解析规则因此只有一处定义。

    function _configuredRpcs() private view returns (string[] memory) {
        string memory single = vm.envOr(ENV_RPC_BSC, string(""));
        string memory list = vm.envOr(ENV_RPC_BSC_LIST, string(""));

        bool hasSingle = bytes(single).length != 0;
        bool hasList = bytes(list).length != 0;

        require(
            !(hasSingle && hasList),
            unicode"ForkConfigBsc: RPC_BSC 与 RPC_BSC_LIST 不能同时非空 —— 不猜优先级"
        );

        if (hasList) return ForkConfig.parseRpcList(list);
        if (hasSingle) {
            require(
                ForkConfig.looksLikeRpcUrl(single),
                unicode"ForkConfigBsc: RPC_BSC 的值不像一个端点 URL —— 变量名粘进值里了？"
            );
            string[] memory one = new string[](1);
            one[0] = single;
            return one;
        }
        return new string[](0);
    }

    /// @dev 没配显式端点时只给那个公共端点 —— 它只服务 latest，钉死高度会如实落空并被
    ///      {ForkTest} 记成「没有端点能服务钉死的高度」。**这正是我们要的可见失败**，
    ///      比悄悄退回一个假的可复现基线好。
    function _rpcUrls() private view returns (string[] memory urls) {
        urls = _configuredRpcs();
        if (urls.length != 0) return urls;

        urls = new string[](1);
        urls[0] = RPC_BSC_PUBLIC;
    }

    function _envUint(string memory name, uint256 fallbackValue) private view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        return bytes(raw).length == 0 ? fallbackValue : vm.parseUint(raw);
    }

    function _envBool(string memory name, bool fallbackValue) private view returns (bool) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return fallbackValue;

        bytes32 h = keccak256(bytes(raw));
        if (h == keccak256("1") || h == keccak256("true") || h == keccak256("TRUE")) return true;
        if (h == keccak256("0") || h == keccak256("false") || h == keccak256("FALSE")) return false;
        revert(unicode"ForkConfigBsc: 布尔环境变量只接受 1/0/true/false");
    }
}
