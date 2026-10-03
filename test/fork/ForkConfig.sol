// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice Robinhood 中央权限注册表上，分叉测试**mock** 的那两个 view。
///
/// @dev 全部 Robinhood 股票代币共用同一套角色与黑名单，`Stock` 的每条转账路径都编译进了
///      `onlyNotPaused` 与 `onlyNotBlocked`，而它们查的就是这里
///      （`docs/research/robinhood-stock-token-permissions.md` §3）。
///      🔴 mock 只落在这两个**读**上：发行方真要冻结时改的正是它们的返回值，
///      而角色持有人无法枚举因而 prank 不了 —— mock 替代的是「谁按了那个开关」，
///      不是「按下去之后会发生什么」。
///
///      清算池自己读门控用的接口住在 `src/interfaces/IIssuerGating.sol`：那一份是**生产**代码的
///      一部分（`pokeGating` 的选择器出处），这一份只是测试用来摆布链上状态的把手。
///      两份都写着 `isBlocked(address)`，是因为它们描述的确实是同一个函数。
interface IRobinhoodAccessRegistry {
    function isBlocked(address account) external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice Robinhood `Stock` 代币上，分叉测试读的那两个 view。
///
/// @dev 🔴 **它曾经住在 `src/interfaces/IIssuerGating.sol`，现在必须在这里。**
///      那个文件描述的是「**池子**读什么」，而这条分支上池子读的是 bStocks 的形状（决策 53）；
///      这个接口描述的是「**Robinhood 链**暴露什么」。两件事在 `feature/bsc` 上第一次分开，
///      而它们本来就该分开 —— 从前重合只是因为当时只有一条链。
interface IRobinhoodGatedStock {
    function paused() external view returns (bool);
    // solhint-disable-next-line func-name-mixedcase
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
}

/// @notice 一条分叉测试需要知道的全部信息。
/// @param name         人类可读的链名，只用于日志与跳过原因
/// @param chainId      分叉选定后断言的链 ID —— 端点指错链必须**失败**，不是跳过
/// @param rpcUrls      候选端点，按优先级排列；显式配置来自单值 `RPC_ROBINHOOD` 或列表 `RPC_ROBINHOOD_LIST`
/// @param blockNumber  分叉高度；`0` 表示 latest
/// @param strictBlock  钉死的高度取不到状态时，拒绝回退（true）还是退回 latest（false）
/// @param required     环境不可用时失败（true）还是跳过（false）
/// @param probe        探测「该高度的状态是否取得到」时读取的合约地址
struct ForkTarget {
    string name;
    uint256 chainId;
    string[] rpcUrls;
    uint256 blockNumber;
    bool strictBlock;
    bool required;
    address probe;
}

/// @title ForkConfig
/// @notice 分叉测试的唯一配置来源。
///
/// 端点与高度都从环境变量读，测试文件里一个都不写死；下面的默认值是「没配任何东西时」
/// 的兜底，改这里就等于改全部分叉测试。可覆盖的变量见 `.env.example`。
///
/// v1 目标链只有 **Robinhood Chain**。BSC / BNB Chain 不属于当前实现、测试或验收范围；
/// 未来支持须作为后续大版本单独立项并重新核验。
library ForkConfig {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev GME · GameStop Robinhood Token（BeaconProxy）。首发标的，抵押品样本。
    address internal constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;

    /// @dev latest canary 上一次人工核验过的股票实现；beacon 一旦升级，先红灯、复核后再更新。
    address internal constant EXPECTED_GME_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    /// @dev 全部 Robinhood 股票代币共用的中央权限注册表（`isBlocked` / `paused` 住在这里）。
    ///
    ///      🔴 **同一个地址身兼两职**：它同时是 {GME} 这只 BeaconProxy 的 **beacon 本体**。
    ///      所以 latest canary 里那句 `IBeacon(ROBINHOOD_ACCESS_REGISTRY).implementation()`
    ///      并没有读错对象 —— 常量名只说了它的一半身份。这不是一句需要人去信的注释：
    ///      `RobinhoodCurrentCanary.t.sol` 每跑一次就从 GME 的 ERC-1967 beacon 槽里把它读出来对一遍，
    ///      将来 Robinhood 若把两个职责拆开，那条断言会先红。
    address internal constant ROBINHOOD_ACCESS_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    /// @dev Flap 主入口（ERC-1967 proxy）及 v1 当前明确支持、最近一次人工核验过的实现基线。
    ///      Portal implementation 把 launcher 固化为 immutable，launcher 又把 TaxTokenV3 implementation
    ///      固化为 immutable；latest canary 同时钉住这条链及三份 runtime codehash。Flap 新实现不会自动
    ///      进入支持范围；必须先复核并显式更新这些常量。
    ///
    ///      2026-08-30 / #146：Portal 在区块 46,501,682 升到 `0xa3b9…ff44`。新 implementation 与
    ///      launcher 当时尚未在 Blockscout 完成源码验证；下面两份 codehash 取自链上 runtime，launcher
    ///      则由 implementation 部署交易 `0x8c8ab665…436bbe` 的第一个构造字段与 runtime PUSH 交叉确认。
    ///      latest canary 还会现场发一只 GME 计价的 tokenVersion=6 代币，证明它实际落到原有
    ///      `0x7777…3333`，而不只是 launcher 字节码里碰巧出现了这个地址。
    address internal constant FLAP_PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
    address internal constant EXPECTED_FLAP_PORTAL_IMPLEMENTATION = 0xa3b96Df56f254B926B17D5f7FB6CD858c216ff44;
    bytes32 internal constant EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH =
        0xc420573f11b2c4fab419118e0e6fc167cc3902c62a3e41fd4495c5db0ea30532;
    address internal constant EXPECTED_FLAP_PORTAL_LAUNCHER = 0xCC40cfc2c1172794934aA1D908Dac77F4AF6c0A0;
    bytes32 internal constant EXPECTED_FLAP_PORTAL_LAUNCHER_CODEHASH =
        0xa0d0fcf34ff647df2c193821ada2b1237bfd0bdb40cf229b3003dc06b3edd3ed;
    address internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;
    bytes32 internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH =
        0xa73abf611d52de6364ec684feed2ef3e9aec9706a02b808523e75a6d8438b164;

    /// @notice 🔴 **VaultPortal 与 Portal 是两个合约，`newVault` 的调用方是前者。**
    ///
    /// @dev 建币带金库走的是 {FLAP_VAULT_PORTAL}（`newTokenV6WithVault`），它内部再去调
    ///      {FLAP_PORTAL}。回调进我们工厂的 `newVault` 时，`msg.sender` 是 **VaultPortal**——
    ///      实测：拿 {FLAP_PORTAL} 的地址去调 Flap 自己的 `IndexVaultFactory`，
    ///      回的是一句 `"Only VaultPortal"`。把门钉在 Portal 上等于永远开不出系列。
    ///
    ///      ⚠️ **这两个地址不能从 BSC 那张表抄。** BSC 的 VaultPortal `0x9049…` 与 Guardian
    ///      `0x9e27…` 在 Robinhood Chain 上**零字节码**；而 BSC 的 *Portal* 地址
    ///      `0xe2cE…` 在这条链上**确实有代码**（23,959 字节）却不是这条链的 Portal ——
    ///      「抄过来居然能读到东西」正是最危险的那种错法。
    ///      出处：`docs/research/flap-vault-identity-spike.md` §2，与 Flap 文档
    ///      `deployed-contract-addresses.md` 的 Robinhood 段一致。
    address internal constant FLAP_VAULT_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

    /// @dev Flap Guardian（本链）。规范要求金库/工厂的权限函数必须同时授予它且不可撤销。
    ///      身份根刻意**不**授予它任何权限 —— 它没有权限函数可授（`VaultRegistry` 的写入面只有
    ///      `bind`，且 `factory` 是 immutable）。
    address internal constant FLAP_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// @notice 🔴 **Robinhood Chain 上唯一能走通的建币 enum 组合，逐个实测出来的。**
    ///
    /// @dev Flap 文档只给枚举**名字**，不给下标；而这条链上绝大多数取值直接
    ///      `FeatureDisabled()`。下面三个常量是把矩阵跑了一遍得到的，每一个都附带
    ///      「取别的值会怎样」，因为那才是它们存在的理由：
    ///
    ///      | 常量 | 实测 |
    ///      |---|---|
    ///      | `tokenVersion = 6`（`TOKEN_TAXED_V3`） | 0…5、7 一律 `FeatureDisabled()`（`0xac5f6092`） |
    ///      | `migratorType = 1`（`V2_MIGRATOR`）    | 0 / 2 / 3 一律 `FeatureDisabled()` |
    ///      | `dexThresh = 1`                        | 0 / 2 / 3 一律 `InvalidDexThresholdType(n)`（`0x77146b42`） |
    ///
    ///      另外两个必须钉住的：`dexId = 0`、`quoteAmt = 0`（非零的 quoteAmt 在曲线建仓那步失败）。
    ///      复算见 `docs/research/flap-vault-identity-spike.md` §5。
    ///
    ///      ⚠️ **上表测的是普通 `Portal.newTokenV6`（= D0 的路）。** 那份 spike 的同名表格测的是
    ///      **`VaultPortal.newTokenV6WithVault`** 门面，两个入口各有各的拒绝点，错误码因此不同 ——
    ///      `dexThresh` 的 2 / 3 在那边报 `0x9e62f353`，在这边与 0 同报 `InvalidDexThresholdType`。
    ///      本表的四次复算（主网 / 测试网 × 原生币 / GME 计价）见
    ///      `docs/research/robinhood-testnet-flap-portal-probe.md` §7。
    ///
    ///      ⚠️ **这里曾经写着「原生币是这条链唯一启用的计价币」，那是错的**（M2-2 实测更正）：
    ///      Flap 在区块 17,391,936 一次性给五只资产开了计价币配置，**{GME} 是其中之一**
    ///      （默认曲线 `CURVE_RH_25_ASSET`），而「MEME 以股票代币计价发射」正是整个 M2 的前提。
    ///      出处：`docs/research/flap-portal-price-semantics.md` §4。
    uint8 internal constant FLAP_TOKEN_VERSION_TAXED_V3 = 6;
    uint8 internal constant FLAP_MIGRATOR_TYPE_V2 = 1;
    uint8 internal constant FLAP_DEX_THRESH_SUPPORTED = 1;

    /// @notice 🔴 **Flap 一笔普通交易就能让我们停止发币的那个开关**：{GME} 的计价币配置。
    ///
    /// @dev 下面五个数是主网 `Portal.getQuoteTokenConfiguration(GME)` 当前的读数
    ///      （2026-08-17 复核：`(1, 29, 29, 7, 0)`，自区块 17,391,936 起）。
    ///
    ///      ⚠️ **它不是我们的状态，是 Flap 管理员存储里的五个字节。**
    ///      `setQuoteTokenConfiguration(GME, {enabled: 0, …})` 一发出去，
    ///      `WarrantLauncher.launch` 就会在 `Portal.newTokenV6` 那一步撞上
    ///      `QuoteTokenNotAllowed(GME)`（`0x9a5c8a92`）当场回滚。
    ///
    ///      🔴 **边界要说准**（与 `script/watch-market-wallet.sh` 同一套措辞规矩）：
    ///
    ///      | | 撤销之后 |
    ///      |---|---|
    ///      | 已发项目的代币 / 金库 / 身份根绑定 | 不受影响 —— 都不在 Flap 手里 |
    ///      | 池内抵押品与已铸权证 | 不受影响 —— 池子不可升级、无 admin 出口 |
    ///      | 已发项目的曲线交易与税收 | 不受影响 —— 配置只在**建币**那一步被读 |
    ///      | **发新币** | 🔴 **一只都发不出来** |
    ///
    ///      也就是：**偿付不受影响，发行能力归零。** 这是 R12 那一类「平台信任」风险，
    ///      我们没有任何链上防御手段，能做的只有**看见**。
    ///
    ///      🔴 **为什么它需要一条自己的断言，而不是被 codehash 钉子覆盖**：
    ///      升级 Portal implementation 要动字节码，`EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH`
    ///      会先红；而撤销配置只改存储，**那个钉子对它一无所知**。两者是两件不同的事，
    ///      后者便宜得多。
    ///
    ///      ⏳ 这个开关**确实是活的**，不是纸面权限：
    ///      `docs/research/robinhood-testnet-flap-portal-probe.md` §5.1 在测试网分叉上
    ///      冒充管理员把它**拨开**过一次，同一笔发射一个字节没改就从 revert 变成成功。
    uint8 internal constant EXPECTED_GME_QUOTE_ENABLED = 1;
    /// @dev `CURVE_RH_25_ASSET` —— 13x 曲线、参考价约 $25、约 $10K 毕业。
    uint8 internal constant EXPECTED_GME_QUOTE_DEFAULT_CURVE = 29;
    uint8 internal constant EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE = 29;
    /// @dev 非零 = 协议侧配了原生币 → GME 的兑换路由（`SWAP_VIA_MIXED_ROUTER`）。
    uint8 internal constant EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE = 7;
    uint8 internal constant EXPECTED_GME_QUOTE_DEX_ID = 0;

    /// @notice 钉死高度上的样本 MEME：HSHITTY，税率 300/300（与历史 BSC 对照 MarsCoin 同档）。
    ///
    /// @dev 三条性质是全部分叉验收共用的前提，所以写在这里而不是各文件里各写一遍：
    ///
    ///      - **EIP-1167 最小代理**（45 字节 runtime），指向 {SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION}；
    ///      - **全部 10 亿供应仍在联合曲线（{FLAP_PORTAL}）上** —— 所以持有人的初始余额一律从 Portal
    ///        那里 `prank` 一笔转过来，**不用 `deal` 去猜它的存储布局**；
    ///      - 销毁路径零税，已实测（`RobinhoodFlapBurn.t.sol` 持续复核）。
    ///
    ///      latest canary 不复用它：latest 每次现场发新币，避免把历史证据与当前状态混在一起。
    address internal constant PINNED_FLAP_TAX_TOKEN_V3_SAMPLE = 0xf40AeC5E453cC6D2Ed29E1fcAba07653Adc47777;

    /// @dev 历史单端点变量。它必须始终原样传递，不能根据 URL 内容猜测它是不是列表。
    string internal constant ENV_RPC_ROBINHOOD = "RPC_ROBINHOOD";
    /// @dev 显式多端点变量；用 ASCII 空白分隔，避免把 URL 中合法的逗号误判为分隔符。
    string internal constant ENV_RPC_ROBINHOOD_LIST = "RPC_ROBINHOOD_LIST";
    string internal constant ENV_BLOCK_ROBINHOOD = "FORK_BLOCK_ROBINHOOD";
    string internal constant ENV_STRICT_BLOCK = "FORK_STRICT_BLOCK";
    string internal constant ENV_REQUIRED = "FORK_REQUIRED";

    /// @dev 社区端点。**曾经**是全归档，现在不是了。
    ///
    ///      🔴 2026-08-13 实测：它在 8 小时内从「能服务 300 万块之前的钉死高度」退化成
    ///      「只保留最近约 64–256 个区块的状态」（`latest-64` 可读、`latest-256` 返回
    ///      `state ... is not available`）。中途还出现过一段连自己的 latest 都给不出状态的窗口。
    ///      **它不再是可依赖的可复现基线。**
    ///
    ///      留在候选表里，是因为它免 key、而且可能恢复；但排在官方端点之后，
    ///      并且**不再假定它能服务任何历史高度**。
    string internal constant RPC_ROBINHOOD_COMMUNITY = "https://rpc.arrowrpc.com";

    /// @dev Robinhood 官方端点。权威，但**只保留约 6k–20k 个区块的状态**
    ///      （出块约 0.1 秒 ⇒ 10–30 分钟），钉死的高度在它上面必然落空。
    string internal constant RPC_ROBINHOOD_OFFICIAL = "https://rpc.mainnet.chain.robinhood.com";

    uint256 internal constant DEFAULT_BLOCK_ROBINHOOD = 31_955_417;

    function robinhood() internal view returns (ForkTarget memory) {
        return ForkTarget({
            name: "Robinhood Chain",
            chainId: ROBINHOOD_CHAIN_ID,
            rpcUrls: _rpcUrls(),
            blockNumber: _envUint(ENV_BLOCK_ROBINHOOD, DEFAULT_BLOCK_ROBINHOOD),
            strictBlock: _envBool(ENV_STRICT_BLOCK, false),
            required: _envBool(ENV_REQUIRED, false),
            probe: GME
        });
    }

    /// @notice 当前实现 canary 专用目标；始终读取 latest，不能被历史验收高度覆盖。
    ///
    /// @dev 这里曾经有一次**位置交换**（把候选表的前两项对调），用来把官方端点顶到前面 ——
    ///      它依赖的是「内置表第一项是归档端点」这个假设。归档端点退化之后，`_rpcUrls()` 已经
    ///      把官方端点排在第一位，那次交换就从「修正顺序」变成了「破坏顺序」。删掉它，
    ///      顺序只在一处定义。
    function robinhoodLatest() internal view returns (ForkTarget memory target) {
        target = robinhood();
        target.blockNumber = 0;
        target.strictBlock = true;
    }

    /// @notice 一个**有望服务钉死高度**的候选：显式配置优先，没配才退回社区端点。
    ///
    /// @dev 🔴 存在的理由是 `ForkSelection.t.sol`：那套测试要断言的是「可复现优先于连得上」这条
    ///      **选择策略**，它需要一个真的能服务钉死高度的端点当被试对象。以前那个角色由
    ///      `RPC_ROBINHOOD_COMMUNITY` 写死扮演；它退化成非归档之后，三条测试全部**静默 skip** ——
    ///      绿的，但一个字节都没在测。把角色改成「环境说了算」，配了归档端点就真的跑。
    ///
    ///      配成显式列表时取**第一项**：那是使用者自己排的优先级，第一位就是他认为最靠得住的那个。
    function pinnedCandidate() internal view returns (string memory) {
        string[] memory configured = _configuredRpcs();
        return configured.length != 0 ? configured[0] : RPC_ROBINHOOD_COMMUNITY;
    }

    /// @notice 这串文本像不像一个端点 URL。
    ///
    /// @dev 🔴 **它防的是一个已经发生过两次的手滑**：把变量名连同值一起粘进去
    ///      （`RPC_ROBINHOOD=https://…`），或者在前面多粘了空白 / 引号。
    ///
    ///      那样的值不会报「你配错了」。它会一路走到 `vm.rpc` 失败，然后被记成
    ///      **「全部候选端点都连不上（无网络 / 被拦截 / 凭据无效）」** —— 一条
    ///      把人引向网络、防火墙、API key 额度的错误信息，而问题其实只在那一行文本上。
    ///      （本地那次表现得更离奇：`cast` 把它当成 IPC socket 路径，报了一句
    ///      `local socket name length exceeds capacity of sun_path`。）
    ///
    ///      ⚠️ 判据刻意只看**开头**，不做完整 URL 解析：这里要抓的是「整段不是 URL」，
    ///      不是「URL 里某处不合法」。后者交给端点自己拒绝，判据越宽越不会误伤。
    function looksLikeRpcUrl(string memory url) internal pure returns (bool) {
        return _startsWith(url, "http://") || _startsWith(url, "https://") || _startsWith(url, "ws://")
            || _startsWith(url, "wss://");
    }

    /// @notice 把显式 `RPC_ROBINHOOD_LIST` 解析成按空白分隔的候选端点表。
    ///
    /// @dev 不能用逗号做分隔符：它在 URL 的 path、query 和 fragment 里合法。单端点变量
    ///      {ENV_RPC_ROBINHOOD} 因此始终沿用原始字节；只有明确选择了这个变量才会执行分词。
    ///      空格、Tab、LF、CR 都是分隔符，连续分隔符自然忽略。URL 中若需要这些字符，应按 URL
    ///      规则 percent-encode；这使多端点语法没有与合法 URL 字节重叠的歧义。
    function parseRpcList(string memory raw) internal pure returns (string[] memory urls) {
        bytes memory b = bytes(raw);
        if (b.length == 0) return new string[](0);

        uint256 pieces;
        bool inPiece;
        for (uint256 i = 0; i < b.length; i++) {
            if (_isSpace(b[i])) {
                inPiece = false;
            } else if (!inPiece) {
                pieces++;
                inPiece = true;
            }
        }

        if (pieces == 0) _revertEmptyRpcList();

        urls = new string[](pieces);
        uint256 found;
        uint256 start;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i != b.length && !_isSpace(b[i])) continue;
            if (start != i) {
                string memory piece = _slice(b, start, i);
                if (!looksLikeRpcUrl(piece)) _revertMalformedRpcEntry(found + 1, ENV_RPC_ROBINHOOD_LIST);
                urls[found++] = piece;
            }
            start = i + 1;
        }
    }

    /// @dev 报错只给序号，不打印原始值：端点 URL 可能包含凭据，revert 会进入 CI / 本地日志。
    function _revertMalformedRpcEntry(uint256 index, string memory variableName) private pure {
        revert(
            string.concat(
                variableName,
                unicode" 的第 ",
                vm.toString(index),
                unicode" 个端点不像一个受支持的 URL（应以 http://、https://、ws:// 或 wss:// 开头）。",
                unicode"多端点变量用空白分隔，按优先级排列。最常见的三个原因：",
                unicode"把变量名也粘了进去、值里带了引号、或者分隔符打成了别的符号。",
                unicode"值不打印出来，因为端点可能自带 key。"
            )
        );
    }

    function _revertEmptyRpcList() private pure {
        revert(string.concat(ENV_RPC_ROBINHOOD_LIST, unicode" 有值，但只包含空白，没有端点。"));
    }

    /// @notice 解析两种显式配置来源，供环境读取和无环境依赖的契约测试共用。
    ///
    /// @dev 旧变量保持单 URL 的逐字节语义；多 URL 必须显式放进 `RPC_ROBINHOOD_LIST`。
    ///      两者同时非空时拒绝，而不是悄悄决定谁覆盖谁。
    function parseConfiguredRpcs(string memory single, string memory list)
        internal
        pure
        returns (string[] memory urls)
    {
        if (bytes(single).length != 0 && bytes(list).length != 0) {
            revert(
                string.concat(
                    ENV_RPC_ROBINHOOD,
                    unicode" 与 ",
                    ENV_RPC_ROBINHOOD_LIST,
                    unicode" 不能同时设置；前者是单端点，后者是显式列表。"
                )
            );
        }
        if (bytes(list).length != 0) return parseRpcList(list);
        if (bytes(single).length == 0) return new string[](0);
        if (!looksLikeRpcUrl(single)) _revertMalformedRpcEntry(1, ENV_RPC_ROBINHOOD);

        urls = new string[](1);
        urls[0] = single;
    }

    /// @dev 读显式配置。历史单值和显式列表同时出现时拒绝，避免猜优先级造成静默换端点。
    function _configuredRpcs() private view returns (string[] memory) {
        return
            parseConfiguredRpcs(vm.envOr(ENV_RPC_ROBINHOOD, string("")), vm.envOr(ENV_RPC_ROBINHOOD_LIST, string("")));
    }

    /// @dev 空格 / 制表 / LF / CR。四个都要：CRLF 来自 Windows 的 `.env`，孤零零的 LF 来自
    ///      `echo` 与 secret 编辑框，制表符来自对齐。
    function _isSpace(bytes1 c) private pure returns (bool) {
        return c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
    }

    function _slice(bytes memory b, uint256 lo, uint256 hi) private pure returns (string memory) {
        bytes memory out = new bytes(hi - lo);
        for (uint256 i = lo; i < hi; i++) {
            out[i - lo] = b[i];
        }
        return string(out);
    }

    function _startsWith(string memory haystack, string memory prefix) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory p = bytes(prefix);
        if (h.length < p.length) return false;

        for (uint256 i = 0; i < p.length; i++) {
            if (h[i] != p[i]) return false;
        }
        return true;
    }

    /// @dev 显式配置了 `RPC_ROBINHOOD` 或 `RPC_ROBINHOOD_LIST` 就**只用**它给的那些端点 ——
    ///      别人指定了端点，我们不该偷偷换成别的，也不该在他的列表后面偷偷续上内置表
    ///      （那会把「第 2 个端点也挂了」这件事掩盖成一次悄悄降级）。
    ///
    ///      🔴 **没配的话，钉死高度现在基本没救**：官方端点只留 10–30 分钟的状态，社区端点
    ///      2026-08-13 起只留约 64–256 个区块。所以内置候选表只能兜住 latest 那一档，
    ///      而**可复现的分叉验收已经实质依赖显式 RPC 配置指向真归档端点**
    ///      （CI 走 repo secret）。顺序也据此调过：官方在前（一定连得上、权威），
    ///      社区在后（可能恢复成归档，恢复了就还能用）。
    function _rpcUrls() private view returns (string[] memory urls) {
        urls = _configuredRpcs();
        if (urls.length != 0) return urls;

        urls = new string[](2);
        urls[0] = RPC_ROBINHOOD_OFFICIAL;
        urls[1] = RPC_ROBINHOOD_COMMUNITY;
    }

    /// @dev 变量未设置**或设为空串**都当作没配 —— CI 里 `${{ secrets.X }}` 取不到时
    ///      给出的正是空串，不加这一层默认值就永远轮不上。
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
        revert(string.concat("ForkConfig: ", name, unicode" 无法解析为布尔值，收到：", raw));
    }
}
