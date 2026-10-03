> 本分支创建/身份绑定/应急会计按 [Flap Custom Vault](flap-custom-vault.zh.md) 实施，替代旧 Launcher 与 Pending 激活叙述；原有 TWAP、系列、行权与分发经济模型保留。
> 本分支新Vault收入以实际到账计提固定10% protocol fee，支付给不可修改的commissionReceiver；正常完整处理为Pool 80% / creator 10% / protocol 10%。claimProtocolFee无需开系列、无许可且收款人固定，原生项目支付WBNB。creator与protocol储备损失按比例永久记账，未来收入不补偿。以下历史90/10及仅creator储备叙述由[当前接入说明](flap-custom-vault.zh.md)替代；processor commission另计，发布仍须平台分别认可三项费用。

# warrant — 产品与工程设计文档

| | |
|---|---|
| **读者** | 合约、前端、后端工程师 |
| **前置** | [`design.md`](./design.md)（产品决策与理由）· [`research/`](./research/)（一手核验数据） |
| **状态** | **M1 已实现并通过测试**：AttestationRegistry、Warrant、MerkleDistributor、ClearingPool、部署接线与七条不变量均已落地。**M2-0～M2-5 已实现并通过测试**：不可升级身份根、金库骨架、严格 24 小时 TWAP / PriceSource、收入路径、开系列，以及 Factory 接线。**M2-6③（#58）已落地：金库去 Flap 化 —— 不继承 `VaultBaseV3`、不可升级、portal 改构造参数**。🔴 **M2-6②（#57）已落地：D0 编排层 `WarrantLauncher`** —— 一笔交易完成建币 + 建金库 + 身份根绑定，走的是普通 `Portal.newTokenV6`，与已废弃的 VaultPortal-with-vault 入口再无关系（§6.1）。**M2 的实现票至此清空**。**M4 的 canonical replay、确定性计算、公开复算、sealed bundle catalog、只读 Proof API/HTTP adapter 与 publisher handoff/finality/recovery 流程已由 #91～#96 实现并通过测试。可重置的常驻 Proof Runtime 已在 Core staging 部署；Robinhood 4663 的生产 Indexer/HTTP 服务仍未部署，`setRoot` 仍由 publisher 人工签名。前端集成接口 STG-0-D1～D6 已冻结为 [`frontend-integration-v1.zh.md`](./frontend-integration-v1.zh.md)：`v1.0.0 Core` 只发布 M0～M4，M5 在 `v1.1.0 Market` 接入。M5-0 的 OrderbookService v1 决策已冻结（§6.6.1），实现尚未开始。** M3 仍在推进：手工 Merkle 通路（#66）、独立全闭环分叉彩排（#67）、keeper（#68）、外部死人开关代码（#77）与持久分叉环境（#79）已落地；#69 的两到三周真实时钟/运营验收尚未完成。M5 实现仍属规划；Web App 已由前端工程师基于 mock 完成，后端 staging 接口产物、专属分叉、fixtures 与 runtime 已交付，尚待 Web App 七条旅程、桌面/移动端、reorg/reset 与联合签字（§10 / §13）。含两处对 `design.md` 的修正（§2）、接口冻结决策与实现收口 |
| **链** | **v1 只支持 Robinhood Chain**（chainId 4663）。BSC / BNB Chain 不属于当前实现、测试或验收范围；未来支持须另行立项并重新做链上核验 |
| **最后更新** | 2026-08-26 |

---

## 1. 系统全景

### 1.1 一句话

用户持有 meme → 每周获得一批**认购权证** → 销毁 meme 行权换取真实代币化股票，或在订单簿上转让。

### 1.2 组件与归属

```
┌─────────────────────── 外部依赖（不由我们实现）───────────────────────┐
│                                                                     │
│  Flap Portal                 ── D0 发币入口、bonding curve、DEX 迁移   │
│  FlapTaxTokenV3 (MEME)       ── 代币本体 + 买卖税                     │
│  Flap TaxProcessor           ── 收税、结算、dispatch 到金库            │
│  ⛔ Flap Trigger Service     ── 决策 39 之后不再是我们的依赖（见 §9）  │
│  Robinhood Stock (GME)       ── 标的资产，beacon proxy + 中央权限注册表 │
│  Seaport 1.6                 ── 订单撮合与原子结算                     │
└─────────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────── 我们实现 ──┼──────────────────────────────────┐
│                                   ▼                                  │
│  ① WarrantLauncher       D0：建币 → 建金库 → 写身份根                  │
│  ② WarrantVaultFactory   每项目部署一个金库（我们自己的，不可升级）      │
│  ③ WarrantVault          receive/sync → processRevenue → 存池/铸造     │
│  ④ VaultRegistry         不可变双槽 memeToken → vault 身份根           │
│  ⑤ PendingLauncherSlot   fail-closed 的未来写入方槽                    │
│  ⑥ ClearingPool  🔴      托管抵押品、铸造/行权/到期（不可升级，每链一个）│
│  ⑦ Warrant (ERC-1155)    权证代币                                     │
│  ⑧ MerkleDistributor     持仓归属证明（见 §2.2）                       │
│  ⑨ AttestationRegistry   合规声明存证（见 §5.5）                       │
│                                                                      │
│  ⑩ Indexer               链下：Transfer 事件 → 持仓时间序列            │
│  ⑪ OrderbookService      链下：Seaport 签名订单存储与撮合展示           │
│  ⑫ Web App               全部前端                                     │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.3 组件关系

| 从 | 到 | 关系 |
|---|---|---|
| Flap TaxProcessor | WarrantVault | dispatch 股票 + `receive()` ping |
| Trigger Service（**我们自己的**，`script/trigger-keeper.sh`，issue #68） | WarrantVault | 定时触发无许可的 `sampleTwap()`（🔴 每 **90 秒**轮询、够一小时才写 —— 每小时跑一次会必破 65 分钟上限，推导见 §9）、`openSeries()`（每 15 分钟问 `openSeriesStatus()`，窗口由它自己回答）与 `processRevenue()`（每日） |
| WarrantVault | ClearingPool | `depositAndMint()` 存抵押品并按实际到账量铸权证 |
| ClearingPool | Warrant | 铸造 / 销毁 ERC-1155 |
| Indexer | MerkleDistributor | 每周发布持仓归属 root |
| 用户 | AttestationRegistry | `attest()`，**一次性**，行权前置（§5.5） |
| ClearingPool | AttestationRegistry | **只读** `attestedVersion`，地址 immutable |
| 用户 | ClearingPool | `exercise(…, beneficiary=本人)` |
| MerkleDistributor | ClearingPool | `claimAndExercise` → `exercise(…, beneficiary=account)`（免先领取路径） |
| 任何人 | ClearingPool | `pokeGating` / `settleExpired` / `rollExpired`（permissionless 维护） |
| 用户 | Seaport | 挂单 / 吃单 |

---

## 2. 🔴 对 `design.md` 的两处架构修正

编写本文档时推演出两个此前未暴露的错误。**两者都改变实现，必须在写第一行代码前确认。**

### 2.1 权证**不能**跨项目同质

**原设计**：`seriesId = (标的股票, 到期日)`，同一只股票、不同项目发出的权证是同一资产，以此汇聚 OTC 深度。

**错误**：行权是**销毁该项目自己的 MEME**。项目 A 的权证要烧 A 的币，项目 B 的要烧 B 的币 —— **支付资产不同，就不可能是同一个资产。**

**修正**：

```
seriesId = keccak256(abi.encode(memeToken, stockToken, expiry))
```

权证按**项目**隔离。ClearingPool 仍是平台级（统一托管、统一审计、单一 OTC 接入点），但**不再提供跨项目同质性**。

**连带影响**：
- "每只股票一个深市场" → 实际是"**每个项目每周 2 个系列**"
- ✅ **已于 2026-08-08 同步**至 `design.md` §3 / §4 / §6.2 及全部四份对外文案
- 对首发（单一项目）无实际影响；影响的是长尾聚合，而长尾本来就薄

### 2.2 累积**不能**用链上 accumulator

**原设计**：MasterChef 式 `accWarrantPerToken` + `userDebt`，O(1)、无快照、无 keeper。

**错误**：accumulator 要求**在每次余额变动时更新用户记账**。而 **MEME 合约是 Flap 的，我们无法 hook 它的 `_update`**。没有转账钩子，就无法维护 `userDebt`。

若改为"claim 时按当前余额计算"，则可被"领取前一刻买入"直接套利。

**修正：链下计算 + 每周 merkle root。**

```
Indexer 订阅 MEME 的 Transfer 事件
  → 重建每个地址的持仓时间序列
  → 计算系列完整归属窗口内的时间加权持仓
  → 将该系列窗口内的全部可分配权证按一次整段权重分配
  → 发布 merkle root 到 MerkleDistributor
用户凭 proof 领取
```

**性质**：
- ✅ 保留"只需持有、无需质押"的产品承诺
- ✅ **任何人都能用公开的 Transfer 事件独立复算并验证 root**
- ⚠️ **引入新的信任假设**：root 由我们计算并提交。必须公开算法与复算脚本
- ⚠️ 时间加权而非余额快照，可防"领取前买入"

**备选（更去信任，但改变产品）**：要求用户**质押** MEME 到我们的合约，则可完全链上记账。**不推荐** —— 它把"持有即累积"变成"质押才累积"，与核心叙事冲突。

---

## 3. 外部依赖清单

| 依赖 | 地址 / 标识 | 用途 | 风险 |
|---|---|---|---|
| Robinhood Chain | chainId **4663**，RPC `rpc.mainnet.chain.robinhood.com`（需浏览器 UA） | 主链 | — |
| **GME** | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | 标的与目标 quoteToken | beacon proxy；已废弃的 VaultPortal-with-vault 会拒绝它，D0 走普通 Portal |
| GME 实现 | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`（`Stock`，已验证） | — | 可被整体升级 |
| **权限注册表** | `0xe10b6f6b275de231345c20d14ab812db62151b00` | 黑名单 / 暂停 / 角色 | 🔴 全链共用 |
| **Seaport 1.6** | `0x0000000000000068F116a894984e2DB1123eB395` | OTC 结算 | 不可变 |
| ConduitController | `0x00000000F9490004C11Cef243f5400493c00Ad63` | 授权管道 | 不可变 |
| Flap VaultPortal | `0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B` | 已废弃的历史带金库发币入口 | 不属于 D0 |
| **Flap Portal** | `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09`（实现自区块 46,501,682 起为 `0xa3b96Df5…ff44`；#146 已复核） | 发币 / 曲线交易 / **价格镜头** | 🔴 Flap 可升级 |
| ⛔ Flap Trigger Service | `0xD3421B1b616a72bB88993A0cf75709BB8D532cc1` | 定时回调 | 🔴 **决策 39 之后不再是我们的依赖**：金库不是 Flap 规范金库，这个后端不会来敲我们的门。三下节拍改由 `script/trigger-keeper.sh` 自己跑（issue #68），地址留在这里只作历史记录 |

> 🔴 **2026-08-14 更正（M2-2，issue #34）：GME 是本链上启用的计价币。**
> `Portal.getQuoteTokenConfiguration(GME).enabled == 1`，默认曲线 `CURVE_RH_25_ASSET`
> （`r = 177.68330498`，Flap 注释写着「参考价约 $25、$10K 毕业」），自区块 17,391,936 起有效；
> 分叉上已真发出一只 GME 计价的 `TOKEN_TAXED_V3`。此前仓库注释写的「原生币是本链唯一启用的计价币」
> 是错的。但这只证明**普通 Portal** 的计价配置与 GME 发射，不能启用
> `VaultPortal.newTokenV6WithVault`：已废弃的该入口仍会在调用 Factory 前以 `UnsupportedQuoteToken(GME)` 拒绝。
> D0 不走它，而是由 launcher 调普通 `Portal.newTokenV6`，因此「MEME 以股票代币计价」是当前可执行的产品路径。实测记录：
> [`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md) §4。

**发行方权限面**（`Stock` 已验证源码，逐条实测）：`onlyNotBlocked` **硬编码在 `transfer`/`transferFrom`/`approve`/`permit` 每条路径**；双层暂停（单币 + 全局）；🔴 **`adminBurn` 无暂停/黑名单检查，可从任意地址销毁**。详见 [`research/robinhood-stock-token-permissions.md`](./research/robinhood-stock-token-permissions.md)。

---

## 4. 数据模型

### 4.1 标识符

```solidity
seriesId = keccak256(abi.encode(memeToken, stockToken, expiry))   // uint256 作为 ERC-1155 id
```

`expiry` = 该周周五 21:00 UTC 的 Unix 时间戳。

> 🔴 **这是产品口径，不是链上约束。** 池子把 `expiry` 当成一个不透明的 `uint64`，既不校验也不解释它。
> 因此**前端、Indexer、到期日历一律以链上 `Series.expiry` 为准，不得假定它必然落在周五 21:00**。
> §6.2 的「≥7 天寿命」规则仍然成立。

### 4.2 ClearingPool 存储

```solidity
struct Series {
    address vault;          // 开启该系列的金库——唯一有权 depositAndMint 的地址（2026-08-11 新增，见下）
    address memeToken;      // 行权时销毁的代币
    address stockToken;     // 抵押品
    uint64  expiry;
    uint128 strike;         // 每 1e18 raw 单位股票需销毁的 MEME（raw）
    uint128 deposited;      // 累计存入的股票（raw balanceOf 单位，含 rollExpired 滚入量）
    uint128 minted;         // 已铸权证
    uint128 exercised;      // 已行权
    uint128 remainder;      // settle 后待滚存的余量（2026-08-09 决策 ①：不再退回金库）
    bool    settled;        // 是否已结算（settled ⟹ 不可行权）
}
mapping(uint256 seriesId => Series) internal _series;   // 读取走 series(seriesId)，返回整个结构体，见下
```

> 📝 **2026-08-14 —— 上面这个字段顺序不能拿来解码。** `src/ClearingPool.sol` 里的实际声明顺序是
> **按存储槽排的**（`vault + expiry + settled` 正好挤进一个槽），即：
>
> ```
> vault, expiry, settled, memeToken, stockToken, strike, deposited, minted, exercised, remainder
> ```
>
> 上面那段是**按可读性排的**，两者不一致。合约以 `src/` 为准。
>
> 🔴 这条对链下是**承重**的：`cast` 按你写的返回类型解码，**不看真实 ABI**。位置写错了不会报错、
> 不会非零退出，只会给出一组看起来很合理的值 —— 把 `settled` 解成别的字段，一条已结算的系列就会
> 被当成有效覆盖。`script/series-monitor.sh` 用的是 `src/` 的顺序，并由
> `.github/workflows/test/series-monitor.sh` 的「Series 元组按声明顺序解码」一例钉死。

```solidity
/// 每只股票一条发行方门控观测记录（2026-08-09 决策 ②，见 §5.1）
/// 🔴 实现是**三态**：多一个 unreadable，且读取走 gating(stockToken) 返回整个结构体，
///    理由见 §5.1 的实现收口 ① / ⑦。以 src/ClearingPool.sol 为准。
struct Gating { bool active; bool unreadable; uint64 clearedAt; }
mapping(address stockToken => Gating) internal _gating;
```

**单一金库设计**：因权证按项目隔离（§2.1），每个 series 只有一个出资方，**无需按项目分账**。这比原设计简单得多 —— 原来的"多项目按存入比例分账"整块可以删除。

> 📝 **`Series.vault` 是谁：该 MEME 在身份根里登记的那个金库**（M1-4 落地时是「谁先开谁负责」，
> M2-5 / issue #37 改成了这一条）。以 [`src/ClearingPool.sol`](../src/ClearingPool.sol) 为准：
>
> `openSeries` 要求 **`msg.sender == vaultRegistry.vaultOf(memeToken)` 且非零**，此后也只有它能
> `depositAndMint`。名册是我们自己的、独立的、不可改写的 [`VaultRegistry`](../src/VaultRegistry.sol)，
> 写入方是一张**构造期钉死、无 setter 的 2 格名单**（M2-6① / issue #56，决策 39-D）：第 1 格是
> [`WarrantLauncher`](../src/WarrantLauncher.sol)，它只在同一笔 D0 发射交易里从普通
> `Portal.newTokenV6` 拿到新代币后写绑定；[`WarrantVaultFactory`](../src/WarrantVaultFactory.sol) 只建
> 金库，完全不碰身份根。第 2 格是
> [`PendingLauncherSlot`](../src/PendingLauncherSlot.sol)，为未来自建发射栈预留，**今天未启用**，
> 未启用时它对任何调用者的 `bind` 都 fail-closed。
> 于是「给一只已经存在的 MEME 注册金库」**没有入口**：抢注不是更难，是不存在。
> 两格共用同一张 `memeToken → vault`，所以放宽名单**没有**给任何一只 MEME 第二次绑定机会。
>
> 🔴 这道门是 **fail-closed** 的，而它可以 fail-closed，是因为**四条会动抵押品的路径一条都不读它**：
> `depositAndMint` 认的是开系列时记下的 `s.vault`，`exercise` / `settleExpired` / `rollExpired`
> 根本不涉及金库身份。身份根即便整个失灵，已开出的系列照常存入、行权、结算、滚存 ——
> 最坏后果「开不出新系列」与金库运营方掉线同级。这与 §5.1 那条「门控读取宁可 fail-open」不矛盾：
> 那一条读的是**外部**注册表、装在**动抵押品**的路径上，fail-closed 会把抵押品永久冻死。
>
> **历史**：M1-4（2026-08-11）落地的是**无许可** `openSeries` —— 当时池子无法在链上认出谁是合法金库，
> 而替代方案在 M1 内无法验证（工厂在 M2、Flap 集成在 M2）。残余敞口是抢注导致的当周停发，它依赖
> 「排序器不抢跑、不审查」这个外部假设：同交易原子重试挡得住交易内插入，挡不住 builder / sequencer
> 把一笔批量占位交易排在金库交易前面（`blockhash` / 时间戳是同区块前置交易也读得到的公共量）。
> 2026-08-13 issue **#23** 的六条分叉判据**全过**，这个假设被拒绝，改用上面那道结构性的门；
> issue **#21** 的那套缓解**不适用**（新的发行活性观测是 issue #42，普通优先级，不是上线阻塞）。
> 决策与证据：`design.md` §10-34 / §10-36、[`research/flap-vault-identity-spike.md`](./research/flap-vault-identity-spike.md)、
> `test/fork/RobinhoodVaultIdentity.t.sol`、`test/fork/RobinhoodWarrantVaultFactory.t.sol`。
>
> **② 读取走 `series(seriesId)` 返回整个结构体，不开自动 getter。** 十个字段的位置元组在测试与链下都太容易读错位
> —— `minted` 与 `exercised` 同型同宽，换个顺序编译器一声不吭。另加 `seriesIdOf(meme, stock, expiry)`（`pure`），
> 让金库（M2）与链下服务有**一处**权威公式，而不是各抄一遍。
>
> **③ 数量口径的两处硬化**：`uint128` 一律走 SafeCast —— 裸转换会**静默截断**，存入 `2^128 + 5` 记成 5，
> 权证却按 `2^128 + 5` 铸出；`depositAndMint` 带 `nonReentrant` —— 余额差记账**天然对再入敏感**，
> 代币在转账里回调进来，内层转入会被外层再数一遍，抵押品进来 `T1 + T2`、权证铸出 `T1 + 2·T2`。
> 池子对**任何**股票代币都开着（开系列那道门认的是 MEME 的金库身份，`stockToken` 这一维池子不解释），
> 所以这条路径可达。

### 4.3 单位约定

**所有数量一律使用 raw `balanceOf` 单位。** 显示时前端乘 `uiMultiplier()`。

> 依据：EIP-8056 下拆股改变的是 `uiMultiplier` 而非 `balanceOf`。若按"股数"记账，一次 2:1 拆股会让承兑量与池内余额错位。见 [`research/tokenized-stock-dividends-erc8056.md`](./research/tokenized-stock-dividends-erc8056.md)。

---

## 5. 合约详细设计

### 5.1 ClearingPool（🔴 不可升级，每链一个）

**这是唯一托管用户债权的合约。** 设计原则：**函数尽可能少、无管理员、无升级**。

```solidity
interface IClearingPool {
    /// 由 WarrantVault 调用：存入抵押品并铸造等量权证
    /// @return minted 实际铸造量 = 本次余额增量
    function depositAndMint(
        uint256 seriesId,
        address to,          // 权证接收方（MerkleDistributor）
        uint256 expectedAmount
    ) external returns (uint256 minted);

    /// 开启一个新系列并锁定 strike
    /// 🔴 仅该 MEME 在身份根里登记的金库可调（`msg.sender == vaultRegistry.vaultOf(memeToken)` 且非零）；
    ///    同一系列只能开一次，见 §4.2
    function openSeries(
        address memeToken, address stockToken, uint64 expiry, uint128 strike
    ) external returns (uint256 seriesId);

    /// 行权：销毁权证（msg.sender）+ 销毁 beneficiary 的 MEME + 股票转给 beneficiary，原子执行
    /// 声明门与 MEME 支付都落在 beneficiary（2026-08-09 决策 ③）
    /// 仅 beneficiary 本人或 MerkleDistributor 可调（防止第三方用他人 MEME 强制行权）
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external;

    /// 观测并记录该股票的发行方门控状态翻转（任何人可调；Monitor 负责保底触发）
    function pokeGating(address stockToken) external;

    /// 到期结算（惰性，任何人可调）：要求已过可行权窗口且当前实时读取无门控
    function settleExpired(uint256 seriesId) external;

    /// 池内滚存（任何人可调）：把已结算系列的余量直接记入后继系列并铸权证给 distributor
    /// 托管权不出池（2026-08-09 决策 ①）
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external;
}
```

**`depositAndMint` 的关键实现约束**：

```solidity
uint256 before = IERC20(s.stockToken).balanceOf(address(this));
IERC20(s.stockToken).safeTransferFrom(msg.sender, address(this), expectedAmount);
uint256 delta = IERC20(s.stockToken).balanceOf(address(this)) - before;
// 以 delta 为准，不是 expectedAmount
warrant.mint(to, seriesId, delta);
s.deposited += SafeCast.toUint128(delta);
s.minted   += SafeCast.toUint128(delta);
```

> 📝 **2026-08-11（M1-4，issue #9）** —— `openSeries` 的四道前置，各挡一件「开出来就没救了」的事
> （系列一经开启不可关闭、不可修改）：零地址代币、`strike == 0`、`expiry` 不在未来、以及已开启。
> 其中 **`strike != 0` 是承重的**：本节的滚存拿 `n.strike != 0` 当「后继系列已开启」的判据，
> 零行权价的系列在滚存眼里等于不存在，且行权时可以白拿股票代币。
>
> ✅ **M1-6 已补上结算门**：`depositAndMint` 在任何转账之前检查 `s.settled`，已结算系列不能再存入。
> 结算时 `remainder` 已按当时的账算定；缺少这道门会让后续抵押品永久卡在无 admin / withdraw 的池子里。

**`exercise` 必须原子**：

```solidity
require(msg.sender == beneficiary || msg.sender == distributor, "not authorized");
require(!s.settled, "settled");
require(block.timestamp < _exerciseDeadline(s), "expired");   // 门控可自动延长，见下
require(attestations.attestedVersion(beneficiary) != 0, "not attested");  // 0. 合规声明查【受益人】，见 §5.5
uint256 memeAmount = amount * s.strike / 1e18;
s.exercised += SafeCast.toUint128(amount);                // 先记账；任一步失败都会整体回滚
warrant.burn(msg.sender, seriesId, amount);              // 1. 销毁权证（持有方：本人或 distributor）
IERC20(s.memeToken).safeTransferFrom(beneficiary, BURN_ADDRESS, memeAmount);  // 2. 销毁 beneficiary 的 MEME
IERC20(s.stockToken).safeTransfer(beneficiary, amount);  // 3. 股票转给 beneficiary —— 可能因发行方门控失败
```

第 3 步失败会回滚全部 —— 这正是我们要的：**发行方冻结时，用户不会失去权证**。

第 0 步是**唯一**的前置门，且**结构上不可能锁死任何人** —— `attestedVersion` 只增不减、只有本人可写、`versions[0]` 永久可用（§5.5）。**它只出现在 `exercise()`，不出现在 `claim()` 或转让路径上** —— 因为只有行权才触及代币化股票。🔴 **声明门查的是 `beneficiary` 而非 `msg.sender`** —— 否则 distributor 代路径（§5.4）会把这道门架空。

🔴 **调用方限定是防御性的**：`beneficiary` 的 MEME approve 只表达"愿意为自己行权付费"，不表达"任何人可替我择时"。若不加限定，第三方可在对 `beneficiary` 不利的时点用其 MEME 强制换仓。

> 📝 **2026-08-11 实现时的六处收口**（M1-5，issue #10）。以 [`src/ClearingPool.sol`](../src/ClearingPool.sol) 为准，
> 上面那段仍是设计草图：
>
> **① 多一道「系列已开启」的门**，排在调用方白名单之后、`!settled` 之前。
> 未开启的系列 `expiry == 0`，deadline 那道检查**今天**确实会挡下它 —— 但那是巧合不是结构：
> 本节下面把 deadline 改成 `max(expiry, clearedAt + 48h)` 之后（#11），一个从未开启的系列会拿到
> `gating[address(0)]` 的那份记录，deadline 反而先放行，最后一道防线退化成「调用方碰巧没有那个 id 的权证」。
> 同 §4.2 收口 ① 对 `depositAndMint` 的取舍：把它写成一句显式比较。
>
> **② 取整到 0 的行权被显式拒绝**（`ExerciseRoundsToZeroMeme`）。`memeAmount` 向下取整，
> 于是 `amount × strike < 1e18` 的那一档**一枚 MEME 都不用烧**就能换走股票代币 ——
> 那正是 `openSeries` 的 `strike != 0` 要挡的事情的整数版本。
> 🔴 定价公式**没有改成向上取整**：公式写在本节与接口上，改它是产品决定；而拒绝一笔算下来「免费」的
> 行权只会更安全，受益人换一个更大的 `amount` 即可。残留的是取整**折扣** —— 少付的永远是被截掉的
> 小数部分，**每笔严格小于 1 raw 单位 MEME**（1e-18 枚）。dust 档它的*相对*比例可以很大
> （strike = 1e17、amount = 19 时付 1 而不是 1.9），但*绝对*上界与调用次数无关地钉在「每次 < 1 raw 单位」，
> 而每次都要付一整笔行权的 gas，差着十几个数量级。
> `amount` 的 `uint128` 收窄放在**乘法之前**：两个因子都 ≤ 2^128−1 之后，乘积结构上装得进 256 位
> （不需要 `Math.mulDiv`，也不会出现 Panic(0x11)），而超量行权拿到的是一条带值的
> `SafeCastOverflowedUintDowncast`，不是「你 MEME 不够」这种答非所问的报错。
>
> **③ 记账提到三步之前**（CEI），并加 `nonReentrant`。上面的草图把 `s.exercised += amount` 放在最后；
> 行权会把控制权交出去**两次**（MEME 转账、股票代币转账），两只代币都是任意合约。
> 再入保护挡的是**跨函数**交错 —— #11 / #12 尚未写，让它们在「行权进行到一半」的中间状态上被调进来，
> 是一件现在就不必留给将来去想的事。
>
> **④ 池子不核对 `BURN_ADDRESS` 的余额增量。** 存入侧按到账增量记账是因为超发会击穿偿付；
> 这一侧核对增量只能保证「销毁足额」这条通缩性质，而代价是：MEME 哪天真的对 `transferFrom(user, 0xdead, …)`
> 收税，不可升级的池子会让**全部行权**永久 revert。宁可烧掉的少一点，也不能让一个外部合约的参数变更
> 把用户的权证变成砖。这条性质改由钉死高度的验收套件保留可复现证据，再由 latest canary 对当前
> `FlapTaxTokenV3` / Portal 状态持续复核。canary 会钉住新发币选择链本身 —— Portal implementation →
> immutable launcher → immutable 的受支持 TaxTokenV3 implementation —— 以及三份 runtime codehash；
> canary 还会现场发一只 GME 计价 V3 代币，实测两条 dead transfer。两层在 CI required 模式下都必须
> 实际执行，不能静默跳过。
> ⚠️ 该文件头部记着一条仍然敞着的口子：Robinhood Chain 上还找不到收税分支处于激活状态的 Flap 代币，
> 因此**目标链上的阳性对照仍未取得**（issue #5 的 residual gap）。
>
> **⑤ 两次 ERC-20 调用都核对发送方的实际扣款量。** MEME 必须从 beneficiary 恰好扣除
> `memeAmount`，避免 return-true/no-op 白拿股票或 sender-pays-extra 多扣用户；股票必须从池子恰好扣除
> `amount`，避免 no-op 让用户烧钱却收不到货，或额外扣款击穿剩余权证的抵押覆盖。该检查**不要求接收方
> 足额到账**：`0xdead` 与股票 beneficiary 的接收方税仍被允许，保持收口 ④ 的活性取舍。
>
> **⑥ `_exerciseDeadline` 现在就是 `s.expiry`**，单独成函数是给 #11 留的落点。
> 🔴 判据是 `block.timestamp < deadline`，而 `settleExpired` 是 `>= deadline` —— 两者必须严格互补，
> 差一秒就会出现一个「既不能行权、也不能结算」的窗口。这条边界钉在
> `test/ClearingPoolExercise.t.sol::test_exercise_rejectsAtAndAfterTheDeadline`。
>
> 不变量 3 的两侧（失败侧「什么都没变」、成功侧「三条腿一起按量动」）见
> [`test/invariant/Invariant3ExerciseAtomicity.t.sol`](../test/invariant/Invariant3ExerciseAtomicity.t.sol)：
> 🔴 在 EVM 里原子性是默认的，**打破它只有「显式吞掉某一步的失败」这一种形状**，所以成功侧那一款才是
> 承重的那一半 —— 只写失败侧的话，「吞掉第 3 步」会大摇大摆通过，而那时用户付了钱、烧了权证、什么也没收到。

#### 行权窗口与门控延期（2026-08-09 决策 ②）

R2 承诺"发行方门控/暂停期间权证自动延期"。ClearingPool 不可升级，延期必须是**无管理员的结构性行为**：

```
_exerciseDeadline(s) = gating[s.stockToken].active
                        ? ∞                                        // 门控观测中：无截止
                        : max(s.expiry, gating[s.stockToken].clearedAt + GRACE)   // GRACE = 48h
```

- **`pokeGating(stock)`**：实时读发行方状态（`Stock.paused()`、全局暂停、注册表 `isBlocked(address(this))` —— 均为公开 view），**只写翻转**。任何人可调，Monitor（§9）在事件命中时保底触发。

  🔴 **`clearedAt` 只能在 `active: true → false` 这条边上写入。** 若每次"干净 poke"都写，就是一个**永久阻止结算的攻击面**：任何人每 47 小时调一次 `pokeGating`，把 `clearedAt` 一路往前推，`clearedAt + GRACE` 永远落在未来 —— `settleExpired` 永久 revert、`remainder` 永不滚存，而攻击者手上本该作废的系列获得**无限期免费展期**。不变量 4(b) **抓不到这个**（它的前提本身以 `clearedAt` 表述，`clearedAt` 被推走则前提空真）—— 不变量 4(c) 正是为此而设。

  ```solidity
  function _observe(address stock) internal {
      bool hit = _readGating(stock);              // fail-open，见下
      Gating storage g = gating[stock];
      if (hit && !g.active)       { g.active = true; }
      else if (!hit && g.active)  { g.active = false; g.clearedAt = uint64(block.timestamp); }
      // 干净→干净、门控→门控 均为 no-op：clearedAt 绝不触碰
  }
  ```

- **`settleExpired(seriesId)`**：内部先执行一次 `_observe`（自愈陈旧观测），然后要求 `block.timestamp ≥ _exerciseDeadline(s)` 且实时读取无门控，才置 `settled = true`、`remainder = deposited − exercised`。**门控期间结算被结构性阻止，行权窗口保持开放 → "自动延期"由此成立**；但若发行方仍阻止股票转账，`exercise` 会整笔回滚，权证与 MEME 不动。🔴 **`pokeGating` 是关窗的动作，不是开窗的动作**：行权读的是记录，记录说门控中就无截止，所以发行方**一解除，行权立刻可用，不需要任何人先 poke**；观测到解除只做一件事 —— 把无限的窗口收敛成 `max(expiry, clearedAt + 48h)`。该截止后任何人可结算。
- **fail-open**：门控 view 调用 revert（发行方升级改了接口）时按"无门控"处理。理由：接口变更远比恶意冻结常见，而 fail-closed 会把结算与回收**永久死锁** —— 池子不可升级，一个再也读不通的接口会让全部系列的抵押品永远冻死，**严格坏于 fail-open 承认的那种损失**。

  **但 fail-open 必须同时打开宽限窗。** view revert 时：若此前状态为门控，按解除翻转处理（`active = false, clearedAt = now`）；若此前已是干净状态，则**该股票首次观测到 revert** 同样盖上 `clearedAt = now`。理由：若此时代币确实处于暂停而 view 读不通，行权失败、结算却照常推进，**持有人会在完全无法行权的窗口里失去权证**。盖这个时间戳零成本，换来 48 小时的人工评估时间。Monitor 对 view 失败单独告警。

  > 实现注意：这是唯一允许在没有真实 `true → false` 边时写 `clearedAt` 的情形。**必须绑定在"进入不可读状态"这一次转变上，而不是"每次读不通"**，否则攻击面从后门绕回来。

- **未被 poke 的门控不产生延期** —— 合约只信记录在案的观测。这使 poke 成为 Monitor 的运营刚性职责，但任何持有人都能自行 poke，无许可依赖。
- **封单个地址不产生任何延期**：`pokeGating` 读的是 `isBlocked(address(this))` —— **池子**。发行方若只封某个持有人而池子干净，结算照常推进，该持有人的权证直接作废。这是刻意的（一个地址被封不该让全系列延期），但**这是真实且不可挽回的用户损失**，见 §11。

> 📝 **2026-08-12 实现时的十处收口**（M1-6，issue #11）。以 [`src/ClearingPool.sol`](../src/ClearingPool.sol) 为准，
> 上面那段仍是设计草图。
> ⚠️ **issue #11 的验收条款也于 2026-08-12 一并修订**：原文「过 expiry 后行权仍成功」做不到 ——
> 暂停期间股票转不出去，`exercise` 必然整笔回滚。延期给的是**窗口**不是**交付**；
> 而解除之后行权**立刻**可用，`pokeGating` 是关窗的动作，不是开窗的动作（同 issue #9 的先例）。
>
> **① `Gating` 是三态，不是两态** —— 多一个 `unreadable` 字段。上面那条「必须绑定在**进入**不可读状态这一次转变上」
> 只有它才实现得出来：两个字段时，判断「这次读不通是不是新情况」只能靠 `clearedAt` 本身，
> 于是**每一次**读不通都会重新盖章 —— 正是这一节点名要防的那个后门。
> 三个字段共 10 字节、同一个槽，不多花 gas。构造上恒有 `unreadable ⟹ !active`，所以状态恰好三种：
> 干净 / 门控 / 不可读。完整的三态转移表写在 `_observe` 的注释里。
>
> **② 🔴 还有一条攻击不在那张表里：把健康的 view 用 gas 饿死。**
> 「不可读」在实现上就是「这次调用失败了」，而转发多少 gas 是**调用方**说了算的。只要没有下限，
> 任何人都能用一笔精心计量的交易把干净的 view 打成 out-of-gas，凭空造出「干净 → 不可读」这条边，
> 然后每 47 小时来一次 —— 攻击面从后门绕回来，而边语义本身一个字都没写错。
> 因此每次读之前先要求 `gasleft()` 足够按 EIP-150 的 63/64 规则转发满 `GATING_READ_GAS`，
> 不够就**当场 revert**，绝不把它记成一次「读不通」。
> 🔴 门槛是 `ceil(预算 × 64 / 63) + GATING_STATICCALL_OVERHEAD`，**两项缺一不可**：63/64 的截断发生在
> `STATICCALL` 付完冷账户访问与基础成本**之后**，只算前一项的话，一个精确 gas limit 仍能让健康的 view
> 拿到少于预算的 gas、伪造出一次「读不通 + 盖章」。两个常量都是 public —— 它们是同一个公式的两半，
> 只公开一半，链下就算不出这道门要多少 gas。
> 📏 预算取 **50,000**：真实 GME 上一整次 `pokeGating`（三次冷账户读取 + 事件 + 门槛检查）实测消耗
> 约 **3.2 万** gas，由 `test/fork/RobinhoodGating.t.sol` 打印并断言留有余量。
>
> ⚠️ **运营口径：不要把任一实测数当成交易 `gasLimit`。** 分叉测量通过
> `address(pool).call{gas: ...}(...)` 让 Solidity 测试合约向 Pool 的子调用显式转发 gas；它二分得到的只是
> 这一层转发给 Pool 的执行 gas，**不是** EOA 或 Monitor 顶层交易的 `gasLimit`。顶层交易的 intrinsic / calldata
> 成本，以及 Monitor 所经的调用包装路径都会改变结果。生产中每次 `pokeGating`，Monitor 都必须在实际目标链上，
> 使用实际 sender、calldata 与完整调用/包装路径运行 `eth_estimateGas`，再留合理余量；不得硬编码任何固定的顶层
> 数字，也不能按约 3.2 万的实测消耗设值。
>
> **③ 三个读的形状与出处。** `stock.paused()` 一个读同时覆盖单币暂停与全局暂停（`Stock.paused()` 返回
> `$.paused || registry.paused()`）；注册表地址**从代币自己身上读**（`ACCESS_CONTROLLED_REGISTRY()`，
> 2026-08-12 对 GME 实测读回 `0xe10b…1b00`），不写死在池子里 —— 池子不可升级，写死等于假定这条链上
> 永远只有一套发行方权限体系。签名住在 [`src/interfaces/IIssuerGating.sol`](../src/interfaces/IIssuerGating.sol)。
> 🔴 返回值按 `uint256` 解、非零即真，**不用 `abi.decode(…, (bool))`**：后者对「非 0 非 1 的脏布尔」会 revert，
> 而那条 revert 会从这个本该吞掉一切失败的函数里冒出去 —— 一只返回脏字节的代币就能让 poke 与结算全部 revert，
> **fail-open 当场变成 fail-closed**。返回数据长度不是 32 字节、注册表地址高位不干净，一律记为读不通。
>
> **④ 「读不通 → 干净」不重新盖章。** 进入不可读那一刻已经盖过一次；出来时再盖一次，
> 「进 → 出 → 进」就成了一台前推 `clearedAt` 的泵。代价照直说：若代币在整个不可读窗口里真的暂停着、
> 直到窗口之后才恢复可读，那 48 小时买到的时间已经用掉了 —— §11 记的正是这条损失。
>
> **⑤ `settleExpired` 内部那次观测，只在结算成功时才留在链上。** 它跟整笔交易一起回滚。
> 于是「记录说门控、实时已解除」的系列不会因为有人反复调 `settleExpired` 就把宽限走完 ——
> 那个时钟要由一次 `pokeGating` 起头。运营口径因此是**先 poke，等到 `max(expiry, clearedAt + 48h)`，再结算**，
> 而不是反复试探 `settleExpired`；对活性没有影响，poke 无许可。
> 🔴 这也精确化了**不变量 4②** 的前提：「实时无门控」与 `clearedAt` 必须取**同一次**观测。
> 记录陈旧时结算会当场自愈，而自愈本身可能盖上一个新的宽限 —— 那不是「结算被阻止」，
> 是「刚刚才观测到解除，截止重新按 `max(expiry, clearedAt + 48h)` 计算」。
>
> **⑥ `settleExpired` 的 `nonReentrant` 是承重的，不是礼节。** 少了它，`depositAndMint` 的
> 「已结算不得再存入」那道门可以被绕过：存入先转账后记账，而转账把控制权交给股票代币；
> 代币在回调里结算掉这个系列，回来之后存入照常把抵押品记进 `deposited`、把权证铸出去，
> 而 `remainder` 已经按结算那一刻的账算定了 —— 那笔抵押品会永久卡在池子里，对应的权证一枚也行权不了。
> 守卫是**跨函数**的（同一个 transient 槽），所以这条路径被堵死。
>
> **⑦ `gating` 与 `exerciseDeadline` 都是显式 view，不开自动 getter。** 理由同 `series()`：
> `active` 与 `unreadable` 同型且相邻，位置元组换个顺序编译器一声不吭，而这两个布尔的含义正好相反。
> 内部可见性还有第二个用处：不变量测试的反证要能装一个「每次 poke 都盖章」的后门，而生产合约里不留钩子。
>
> **⑧ `depositAndMint` 补上了 `settled` 那道门** —— §4.2 收口里预告的那一条，本票兑现。
>
> **⑨ `clearedAt == 0` 当哨兵用，不参与 `max`。** 在任何真实链上 `max(expiry, 0 + 48h)` 与 `expiry` 等价，
> 但 `0` 说的是「没有发生过解除」，不是「1970-01-01 解除的」。按哨兵写，一条把时间戳设在 172800 以内的
> 测试就不会拿到一个凭空 48 小时的行权窗口。
>
> **⑩ `pokeGating` 拒绝零地址。** `_gating[address(0)]` 是**未开启系列**会读到的那条记录；
> 让它永远是全零，比每次新增函数时重新论证一遍「谁会读到它」便宜。

#### 池内滚存（2026-08-09 决策 ①）

原设计 `claimExpired()` 把到期余量退回金库、再由金库存入下一系列。**该路径已废除**：稳态下池规模 ≈ `S/f`（R13），全池每周要经过一次金库，把在途窗口从「一天的税收」放大成「整个池子」，击穿"在途 ≤24h"的承诺。（📝 原文的理由是「金库是 Flap Guardian 可升级的」—— 那条随 issue #58 消失，而这个取舍本身与它无关，照旧成立。）

```solidity
function rollExpired(uint256 seriesId, uint256 nextSeriesId) external {
    Series storage s = series[seriesId];
    Series storage n = series[nextSeriesId];
    require(s.settled && s.remainder > 0, "nothing to roll");
    require(n.memeToken == s.memeToken && n.stockToken == s.stockToken, "wrong successor");
    require(n.strike != 0 && !n.settled && block.timestamp < n.expiry, "successor not live");
    uint128 amt = s.remainder;
    s.remainder = 0;
    n.deposited += amt;
    n.minted    += amt;
    warrant.mint(distributor, nextSeriesId, amt);   // 池内重新归属，股票从未离开本合约
}
```

- 校验全部可由池子自证（同 meme/stock、后继已开启且在世），故 **permissionless**，与 `settleExpired` 的惰性风格一致
- **金库经手的资金从此只剩新到账税收**（≤24h），R4 的表述恢复成立
- 边界情况：项目停摆、无后继系列时，余量停留池中（无 admin 的必然结果）——任何时候由 Trigger Service（或任何人）触发 `vault.openSeries()` 开出新系列即可恢复滚存，**无资金损失，只有延迟**

> 📝 **2026-08-13 实现时的八处收口**（M1-7，issue #12）。以 [`src/ClearingPool.sol`](../src/ClearingPool.sol) 为准，
> 上面那段仍是设计草图。
>
> **① 六道门，各报各的错。** 草图把「已结算」与「余量非零」合成一句 `require`；实现拆成
> 前序**已开启** / **已结算** / `remainder != 0` 三句。第一句与第二句有重叠（没开过的系列必然未结算），
> 留着它只为错误面：打错 id 的调用方拿到的是「这个系列不存在」，而不是「它还没结算」。
> 🔴 第三句同时就是**「不可二次滚存」的全部实现** —— 滚完归零，第二次撞的就是它，
> 不需要另一个「已滚过」的标志位。
>
> **② 🔴 后继「未过期」比的是 `n.expiry`，不是 `exerciseDeadline(n)`。** 门控延期会把一个已过 expiry
> 的系列的行权窗口撑开；若拿 deadline 当判据，任何人都能把余量滚进一个早就过期、只是还没人结算的
> 旧系列。抵押品不会丢（它会随那个系列的结算继续往下滚），但**当周的 merkle root 拿不到这笔钱**，
> 而铸给 `distributor` 的那批权证没有任何 root 覆盖它，会永远留在它手上。
> **合法后继的集合越小越好**，所以取严的那一个；无门控时两者本来就相等。
>
> **③ `nextSeriesId == seriesId` 不需要单独一道门。** 前序**已**结算、后继**未**结算，
> 同一个 id 上两者不可能同时成立。
>
> **④ 前序的 `deposited` 不回冲。** 它记的是「这个系列历史上收过多少」，滚存只清 `remainder`。
> 于是滚存之后前序账上仍写着 `minted − exercised > 0`，而属于它的抵押品已经交给后继了 ——
> 这正是**不变量 1① 必须限定在未结算范围**的原因（§7）：让它无害的不是判据的措辞，
> 是 `settled ⟹ exercise revert`（不变量 4①）。跨滚存的偿付覆盖由全局的 1② 负责。
> 🔴 issue #5 点名：**不得把 1① 削弱成能通过的样子** —— 删掉的是不适用的前提，不是判据。
>
> **⑤ `nonReentrant` 在这里不是承重的。** 唯一的外部调用是 `warrant.mint(distributor, …)`，
> 收款方是我们自己的 `MerkleDistributor`（`ERC1155Holder`，收到回调只返回魔数），且记账排在它前面。
> 加上它是为了让整个合约的再入语义只有一句话：**六个入口里任意两个都不能交错**。
>
> **⑥ 残余敞口：合法后继由调用方指定，池子分辨不出「哪一个才是这周那一个」。**
> `rollExpired` 本身无许可（它的全部校验池子都能自证：同一对 (MEME, 股票代币)、后继已开启且在世），
> 所以任何人都能把余量滚进**任意一个合法后继**。
> 🔴 **M2-5（issue #37）之后这条敞口被压掉了大半**：「合法后继」现在必须是同一只 MEME 的系列，
> 而那只 MEME 的系列**只有它登记在案的金库开得出来**（§4.2）—— 也就是说，可选的后继全部出自
> 我们自己的金库，抢注者没有入口造一个行权价离谱的系列来接盘。
> 剩下的是「同一个金库开出的多个后继之间选错一个」，那是运营问题（发行停发可观测，issue #42），
> 不是授权问题。
>
> **⑦ 不变量 5 有两款，缺一不可。** 结构款是「对外可写函数恰好六个」（读编译产物的 ABI，
> `test/ClearingPool.t.sol`）；动态款是「把六个入口按任意顺序跑遍之后，抵押品只在 `exercise` 里
> 离开过池子、且每次恰好等于行权量」（`test/invariant/Invariant5And7RollAndCustody.t.sol`）。
> 两款互相抓不到对方：ABI 枚举对「`settleExpired` 里藏了一行 transfer」是瞎的，
> 动态款对「加了个从没被调用过的 `withdraw`」也是瞎的。**函数集到本票才填满，不变量 5 也因此到这里才成立。**
>
> **⑧ 「滚存不构成转出」是被验证的，不是被声明的。** 反证装的后门就是被废除的那版原设计的最小形状：
> 账上四个数（`remainder` 减少 / 后继 `deposited` 增 / `minted` 增 / 新铸权证）**一个不差**，
> 唯独抵押品经金库走了一趟 —— 不变量 7 的守恒款对它**一声不吭**，只有余额款与托管计数看得见。
> 所以每条成功路径都同时断言两件事：池内余额前后相等，**且这笔交易里没有一条该股票代币的 `Transfer`**。
> 后者在真实 GME 上也复核了一遍（`test/fork/RobinhoodRoll.t.sol`）。
> 事件是 `Rolled(seriesId, nextSeriesId, amount)`，`amount` 同时是上述四个数。

**无 admin、无 pause、无 withdraw、无 upgrade。** 唯一的外部可写入口是上述六个函数。

```solidity
address public immutable attestations;   // 构造时写死，不可更换
```

> ⚠️ 该地址**不可更换**是刻意的：可更换 = 可被指向一个恒返回 false 的合约 = 可冻结全部行权。宁可放弃"换注册表"的灵活性。

### 5.2 WarrantVault（每项目一个，**我们自己的，不可升级**）

> 🔴 **2026-08-16（决策 39-A3 / issue #58）：金库去 Flap 化已落地。** 它不再继承 `VaultBaseV3`、
> 不走 beacon proxy、没有 Guardian、没有 `vaultUISchema()` / `vaultSpecVersion()` / `initialize()`。
> 工厂在每次发射时**直接部署一只**，六个参数（池子 / 分发合约 / 取价 Portal / MEME / 收入币种 /
> creator —— 第六个由决策 49 加入）在构造那一笔里定死。**R4 因此整类消失**（`design.md` R4）。
> 逐条去向见 [`flap-vault-spec-compliance.zh.md`](./flap-vault-spec-compliance.zh.md) §0.5。

> 📌 **金库由 [`WarrantVaultFactory`](../src/WarrantVaultFactory.sol) 创建，绑定由
> [`WarrantLauncher`](../src/WarrantLauncher.sol) 写**（M2-5 / #37 → M2-6② / #57）：
> launcher 在同一笔交易里建币、让工厂**直接部署**一只金库、再往身份根写下这只 MEME 的唯一一条绑定。
> 金库因此**不需要**任何「绕开被抢注的三元组」的职责 —— 它是那只 MEME 唯一开得出系列的地址（§4.2）。
> ⚠️ `newVault` 的调用者门是**我们自己的 launcher**（不是 Flap 的 VaultPortal，那条入口随 #57 一并弃用）；
> 工厂构造参数里的 `Portal` 是**取价来源**，与 launcher 拿来建币的是同一个地址、两种身份。

> 🔴 **Factory 也不再是 Flap 规范工厂**（M2-6② / issue #57）。它从前继承 `VaultFactoryBaseV2` 并实现
> `factorySpecVersion()` / `onBeforeLaunch(bytes)` / `isQuoteTokenSupported()` / `vaultDataSchema()` /
> `resolveDividendToken(...)` 那一整套 —— 那些钩子**只为 VaultPortal 那条入口存在**，而那条入口已弃用。
> 五个钩子连同 `VaultFactoryBaseV2` 继承一起删除；`script/flap-vault-spec-check.sh` 反过来断言它们确实不在。
> 工厂今天的对外可写面**恰好三个**：`newVault(address,address,address)`（只认 launcher）、
> `setLauncher(address)`、`setVaultTargets(pool, distributor)`。
> 另有一个新的**只读**面 `nextVault()` —— 它预告下一只金库的 CREATE 地址，launcher 拿它填
> 发射参数的 `beneficiary`（= 税收收款人），建完再逐位核对（§6.1）。
> 从前那句「第二个一次性槽是 `setVaultTargets(pool, distributor)`」
> （🔴 **issue #58 起取代 `setBeacon`**：它锁死的不再是「谁能换金库的实现」，而是
> 「本工厂此后建出的每一只金库，钱流向哪个池子、货发给哪个分发合约」；两个目标都查代码，
> 空壳一律 fail-closed）。取价 `Portal` 则是工厂的**构造参数**（决策 39-A2）。

**金库的对外面**（🔴 原为「Flap 规范硬性要求」，issue #58 之后一半失去对象、一半是我们自己的选择）：

| 项 | 今天 | 为什么 |
|---|---|---|
| 继承 `VaultBaseV3` | ❌ 删除 | 不是规范金库了；`vaultUISchema()` / `vaultSpecVersion()` / `guardian()` 一并删除 |
| beacon proxy + Guardian 升级权 | ❌ 删除 | **不可升级**：字节码在 `CREATE` 那一笔里定死 |
| `initialize(address,address)` | ❌ 删除 | 没有代理就没有「先部署再初始化」那一拍；两个身份参数搬到构造函数 |
| `vaultQuoteToken()` | ✅ 保留（`immutable`） | 运营面在读它（`series-monitor.sh`、链上核验） |
| `receive()` + 余额差记账 | ✅ 保留 | D0 不改税收链路，ping 与余额差记账描述的是今天真实的行为 |
| `description()` | ✅ 保留 | 它渲染 `inTransit()` —— 在途窗口的实时读数 |
| **零权限面** | ✅ 保留 | 理由从「规范强制权限函数同授 Guardian」换成**我们自己的选择**：它是「金库拿不走钱」的最短证明。⚠️ 决策 49 之后这句话的精确读法是「**调用方**拿不走钱」——`claimCreatorFee` 是一条无许可、只通向发射时定死的 creator 的固定出口（上限 = 收入的 10%），calldata 改不了收款人 |
| 取价 `Portal` | ➕ 新增为**构造参数** | 不再按 `chainId` 查表 —— 「新项目用新价源、老项目用老价源」天然并存（决策 39-A2） |

```solidity
contract WarrantVault {
    // issue #58：参数在构造那一笔里定死，此后没有任何写入路径能改它们
    // 决策 49：creator_ 是第六个 —— 发射者本人（launcher 的 msg.sender），分成的唯一收款人
    constructor(IClearingPool pool_, address merkleDistributor_, address portal_,
                address taxToken_, address quoteToken_, address creator_);

    // M2-2 已落地：通常每小时一次，但任何人可调用
    function sampleTwap() external;

    // M2-4 已落地：读 24h TWAP → strike = TWAP × 0.8 → 在 ClearingPool 开出本周系列
    function openSeries() external returns (uint256 seriesId, bool opened);

    // M2-4 已落地：openSeries() 的 view 预检 —— 「本期开出来了吗、没开是因为什么」
    function openSeriesStatus() external view returns (uint256 status, uint64 expiry, uint128 nextStrike);

    // M2-3 已落地：把已到账的股票存入池子并铸造权证
    // 决策 49：本批可存量的 10%（CREATOR_FEE_BPS）归 creator —— 存入后按实测扣款反推入账
    // （confirmedCut = min(cut, sent/9)），假转账与部分扣款都切不到没走掉的部分
    function processRevenue() external;

    // 决策 49：把累计分成转给 creator。无许可 —— 任何人可触发，收款人是构造时定死的 immutable，
    // calldata 一个字节都改不了它；请求 min(creatorAccrued, 实际余额)，按实测扣款计量与校正债权，
    // 零累计时静默 no-op
    function claimCreatorFee() external returns (uint256 claimed);

    // ⚠️ 无 sweepExpired —— 到期结算与滚存在 ClearingPool 侧（settleExpired / rollExpired，
    // 任何人可调），金库不再经手到期余量（2026-08-09 决策 ①）。
    // 原因：全池每周过一次金库会把在途窗口从「一天的税收」放大成「整个池子」。
    // （原文写的是「金库是 Guardian 可升级的 beacon proxy，会击穿 R4」——
    //  R4 已随 issue #58 消失，而这条设计取舍本身与它无关，照旧成立。）
}
```

**为什么 `processRevenue()` 不能放在 `receive()` 里**：`receive()` 由 Flap 的 dispatch 触发。在其中执行存款与铸造会显著抬高 gas，且任何 revert 都会影响 Flap 的税收结算。**保持 `receive()` 只记账。**

> 📝 **2026-08-13 收紧（M2-1 已落地，issue #33）· 2026-08-14 更新（M2-2 / #34、M2-3 / #35 与
> M2-4 / #36 已落地）**：实现在 [`src/WarrantVault.sol`](../src/WarrantVault.sol)；
> `sampleTwap()` / `openSeries()` / `processRevenue()` 均已交付。M2-0～M2-4 已实现并通过测试。
>
> 合并后的实现收口如下，以 `src/` 为准：
>
> 1. **对外可写入口恰好六个**（🔴 **issue #58 起**：`initialize` 随不可升级一并消失，六个变五个；
>    🔴 **决策 49 起**：`claimCreatorFee()` 加入，五个变六个）：
>    `sync()` / `sampleTwap()` / `openSeries()` / `processRevenue()` / `receive()` / `claimCreatorFee()`，
>    而且**没有一个是权限函数** —— 由枚举编译产物 ABI 证明。这条性质的**理由**已换成我们自己的
>    （零权限面 = 「金库拿不走**调用方引向自己的**钱」的最短证明），**判据一个字没改**。`sampleTwap()`（M2-2）把外部价格源
>    的活性与任意人可挑采样时刻的取舍写明；`processRevenue()`（M2-3）的调用方改不了 `pool` /
>    `merkleDistributor` 这两个 immutable 目的地；`openSeries()`（M2-4）的调用方一个参数都挑不了，
>    挑得动的只有**时刻**，那一面由 §6.2 的 24 小时窗口压住；`claimCreatorFee()`（决策 49）的调用方
>    改不了收款人 —— 钱只会到构造时定死的 `creator`。四者无许可都不是默认值。
>    逐条归属见 [`flap-vault-spec-compliance.zh.md`](./flap-vault-spec-compliance.zh.md)。
> 2. **`receive()` 任何路径都不 revert**：读收入币种余额走**限 gas 的 `staticcall`**（20 万），
>    读不到就发 `QuoteBalanceUnreadable` 并静默返回。收入按差额算，下一次唤醒或 `sync()` 一次补齐。
>    真实 GME 上实测首次 ping 约 4.8 万 gas，规范上限是 100 万。
> 3. **`sync()`**：规范推荐的无许可补记入口（直接转账 / 捐赠 / ping 被关掉时的恢复路径），
>    本节此前没提。
> 4. **上游文件逐字节照抄进 [`src/flap/`](../src/flap/)**，由 sha256 清单钉住 ——
>    ⚠️ issue #58 之后 `VaultBase*` 三个文件**不再被继承**，issue #57 之后
>    `VaultFactoryBaseV2` 也不再是 Factory 的基类；这些旧基类转为「余额差记账 / ping 契约原文」与
>    「旧 `chainId` 地址表」的存档。`IPortal` 不同：launcher 仍在生产代码中导入其类型，故它的 vendored
>    定义仍是活接口、不是存档；自己重写会让实体细节静默漂掉。

> 📝 **2026-08-14 M2-3 收口（issue #35）**：`processRevenue()` 补齐了上面列出的六个入口。
> 其余六处收口以 `src/` 为准（决策 [`design.md`](./design.md) §10-36）：
>
> 1. **两个地址是金库的 `immutable`**：`pool` 与 `merkleDistributor` 由构造参数写死，
>    **不是**初始化参数，也不是发射参数。理由是决策 33 那条硬约束 —— 两个目的地只来自 Factory
>    那个仅部署者、写一次、永久锁死的 `setVaultTargets` 槽。当前
>    `newVault(taxToken, quoteToken, creator)` 拿到的是 launcher 从 Portal 返回的代币、经代码检查后由
>    调用方选择的计价币，以及 `creator`；三者都不能成为特权来源。
>    ⚠️ **决策 49 修订了 `creator` 的后半句**：它不再「仅进入事件」，而是被透传进金库构造函数存为
>    第 6 个 `immutable`（分成的唯一收款人）。「不能成为特权来源」原样成立 —— creator 拿到的不是
>    任何函数的调用权，而是一条**别人也能替他触发**的固定收款路径；发射者仍然改不了税收、存入
>    与铸造的任何去向。
> 2. **签名带返回值**：`function processRevenue() external returns (uint256 minted)`。
> 3. **两条边干净返回、其余一律如实失败**：零余额、以及没有还活着的系列
>    （发 `RevenueDeferred`，**钱留在金库等下一次**）——Trigger Service 每天空跑一次，revert 会污染告警。
>    发行方暂停、池地址被封、**余额读不出来**都整笔回滚。
>    🔴 **余额读不出来必须响，不能静默跳过**：`receive()` 那个 20 万 gas 的封顶只为它的不 revert 承诺
>    而存在，而 `pool.depositAndMint` 读 `balanceOf` 是**不封顶**的 —— 沿用封顶读，会让一只
>    `balanceOf` 只是变贵了的收入币种（发行方换一次实现就够）把金库变成**永久、静默**拒绝出货 ——
>    也就是把在途窗口拉到无限长，而且一声不响。所以 `processRevenue` 读余额不封顶。**只有延迟，没有损失**。
> 4. **「还活着的系列」的判据是 `strike != 0 && block.timestamp < seriesExpiry`**。
>    池子刻意不挡到期后的存入（门控延期），所以这是**金库侧的政策**：往行权窗口已关的系列铸权证
>    是发废纸。该判据同时蕴含「未结算」，因此撞不上 `SeriesSettled`。
> 5. **不用 `SafeERC20` 授权**，而且授权失败时**原样冒泡收入币种自己的 revert 数据**；
>    返回值按 `uint256` 解、非零即真（`abi.decode(…, (bool))` 遇到脏布尔会 `revert(0,0)`，
>    把报错整个抹掉——同 `ClearingPool._readGating` 的取舍）——
>    真实 GME 的 `approve` 带 `onlyNotPaused` + `onlyNotBlocked`，把它的 `IsPaused()` 换成一句
>    我们自己的话，会把「发行方按了开关」误报成「我们的代码有问题」。授权额恰好是本次存入量，
>    存完清零，**两笔交易之间对池子的授权恒为 0**。
>
> 6. **新增 view `inTransit()`**，返回 `(amount, exact)`：此刻停在金库里、还没进池子的抵押品。
>    🔴 **R4 的敞口读数是它，不是 `accountedQuote()`** —— 后者只是已识别的基线，
>    没有唤醒就到账的钱不在里面，于是恰好会在「税还在进来、却没有任何东西唤醒金库」
>    这种最该报警的复合失效下读出 0。若 `exact == false`，返回值为 `(0, false)`：余额**不可读且
>    金额未知**，不是零、更不是下界；`description()` 会渲染「数量不可读」，而不是健康的零余额。
>    🔴 **决策 49 起它返回 `balance − creatorAccrued`（饱和减）**，不再是 raw 余额 ——
>    「在途」的语义钉死为「**本该变成权证还没变**的钱」，creator 未领的分成不在其中。
>    这一个定义同时救活四处消费者：keeper 的零余额跳过判据、`REVENUE_SENT_ZERO` 告警、
>    series-monitor 的收摊降级分支、`description()` 的「当前没有在途收入」横幅 ——
>    发 raw 余额的话，四处都会被一笔永不清零的 creator 浮存卡成永久异常。
>
> 🔴 **M2-4 遵守的硬约束**：`openSeries()` **先** `pool.openSeries` 成功、**再**写
> `strike` / `seriesExpiry`。反过来写的话，开系列一失败字段就会指向别人的系列，
> 而 `processRevenue` 会稳定撞上 `NotSeriesVault` —— 收入从此再也出不去金库。
> 反证测试：`test_openSeries_writesNothingWhenThePoolRejects`。

> 🔴 **`accountedQuote` 是余额差记账的基线，`processRevenue()` 每支出一笔都必须在同一笔交易里
> 等额减少它。** 忘记减，基线就永远高于真实余额，`balance <= accountedQuote` 会从此压住一切收入识别 ——
> 金库死锁，而且没有任何报错。这是 V3 金库能犯的最危险的一个错误（规范 rule 010）。
>
> 📝 M2-3 的做法（决策 49 修订量，纪律不变）：请求池子拉走**存前观测到的可存量**
> （`available = balance − creatorAccrued`，再扣掉本批 10% 的 `cut`），清零授权后重读金库余额并写
> `accountedQuote = balanceAfter`；`sent = max(balanceBefore - balanceAfter, 0)`。存后基线不再归零 ——
> 它等于 creator 浮存加尘埃；若代币表面成功却没有从金库扣款，不会虚报支出或把基线清低，
> **也不会累计分成** —— 分成按实测扣款反推（`confirmedCut = min(cut, sent × 1000/9000)`），
> 假转账与部分扣款都切不到没走掉的那部分，同一批钱在任何路径下不会被二次切分（审计 M-01）。
> 这个写入仍刻意排在外部调用**之后**：提前改基线会开一条缝，转账回调里再调 `sync()` 会把基线推回满额，
> 随后真实余额减少，金库当场死锁。反证测试 `test_processRevenue_aReentrantSyncCannotDeadlockTheVault`
> 用一只**在余额变动之前**回调的替身从最坏的顺序上打过一遍 —— 决策 49 之后这条判据的形式是
> `balance <= accountedQuote` 对 `available` 的压制，重入窗口的论证以 `src/` 注释为准。
>
> 🔴 **`claimCreatorFee()` 是金库的第二条支出路径，同一条 rule 010-3 原样适用**：先 `_recognize()`、
> 效果先行（`creatorAccrued` 在转账**前**扣减）、转账后同笔 `accountedQuote = balanceAfter`。
> 它与 `processRevenue()` 共用一把手写 transient 锁 —— 两条支出路径若在彼此的外部调用里重入，
> 会拿着「余额还没减、记账已经改了」的中间态算错可存量。不继承 OZ `ReentrancyGuardTransient`，
> 因为金库的错误面必须为空（rule 004）、继承线性化必须只剩 `WarrantVault` 自己（spec-check 断言）。

**TWAP 实现**（M2-2 已落地，issue #34；以 [`src/WarrantVault.sol`](../src/WarrantVault.sol) 与
[`src/PriceSource.sol`](../src/PriceSource.sol) 为准）：

```solidity
struct Sample { uint64 ts; uint192 price; }   // price = 1e18 raw 股票代币值多少 raw MEME
Sample[24] private _ring;
Sample private _twapBoundary;                 // 环轮转后保留被覆盖的左边界

function sampleTwap() external returns (bool written);         // 无许可，距上一条 ≥ 1 小时才写
function twap() public view returns (uint256 status, uint256 price);  // 不 revert，失败给码
```

> **接线边界（M2-4 / #36 已接上）**：`twap()` 的读数由 `openSeries()` 消费，且对**所有非零状态
> fail-closed** —— 六个码里只有 `0` 放行。`openSeriesStatus()` 把这件事翻译成一个码
> （`3 = OPEN_TWAP_UNAVAILABLE`）并**不转发** TWAP 自己的六个码：那六个码的权威出处只有 `twap()` 一处。

> **为什么 M2-4 必须用 TWAP**：strike 一周只定一次、决定整周发行量。读现价意味着"拉一次盘锁定一整周行权价"。

**价格来源与 🔴 量纲反演**：曲线阶段读 `Portal.getTokenV8Safe(meme).price`，毕业后读 DEX 池。
🔴 **Flap 给的是倒数**：它的 `price` 是「1e18 raw MEME 值多少 raw 计价币」，而我们要的是
「1e18 raw 股票值多少 raw MEME」，所以采样时做 `1e36 / price`。**在采样时反演而不是读数时**，
因为时间加权与取倒数不可交换（算术平均的倒数是调和平均），两种口径给出不同的 strike；
选算术口径的理由是 ① 与 `ClearingPool.strike` 同量纲、M2-4 无需换算，② AM ≥ HM，strike 偏高更保守。
毕业之后曲线 `price` **恒为 0**（实测），所以切换条件是 Flap 的 `status`（`1` 曲线 / `4` 已毕业），
两个分支没有重叠区。计价币还要与 `vaultQuoteToken()` 对账 —— 对不上就拒采，因为那个价的分母不是我们的股票。
完整推导与实测：[`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md)（关闭 §14-6）。

**毕业后 V2 来源：窄化的同块拦截，不是累计预言机。** 池子分支当前只读一次 `getReserves()` 现货快照。
第三个 ABI 字会被严格校验为 `uint32` 的 `blockTimestampLast`；若它等于 `uint32(block.timestamp)`，
`PriceSource` 返回 `POOL_UPDATED_THIS_BLOCK`（`9`），`sampleTwap()` 发出 `TwapSampleFailed(9)` 且不写样本。
这只挡「同一块更新储备 → 采现货」这条直接路径。它**没有**读 `price0CumulativeLast` /
`price1CumulativeLast`，没有把现货变成连续观测，也挡不住跨块持续操纵、流动性攻击或其他 V2 预言机风险。
分叉的真实 pair 测试会核对 V2 ABI 形状（含该时间戳与标准 cumulative getter）；那**不是**「已使用完整累计价预言机」
或「已证明 V2 定价安全」的证据。

**采样规则**：`sampleTwap()` **无许可**，距上一条**至少 1 小时**才写（不是「按整点分桶」——
分桶下 `t=3599` 与 `t=3601` 会都写进去，攻击者据此把 24 条挤进几分钟）。
每次成功写入都是一个**瞬时 spot 快照**，不是声称两个时间戳之间一直连续观测到该价格。目标节奏是每小时一次，
`MAX_SAMPLE_GAP = 1h + 5m`：每个相邻的左端点价格段以及最新尾段都不得超过 65 分钟，否则读数 fail-closed，
而不是把旧快照说成覆盖了无人观测的时间。延迟调用可以恢复写样，但在重新积出新鲜、有界的覆盖前不能让读数可用。
取不到价时发 `TwapSampleFailed(reason)` 并静默返回，**任何路径都不 revert**（keeper 一笔交易可能扫多个金库）。

**读数**：`twap()` 积分的是严格 trailing 的 `[now - 24h, now]`，不是只看最旧与最新已占槽之间的经过时间。
24 槽环保存价格点；环轮转后 `_twapBoundary` 保留刚被覆盖的左边界，因此后续也能重建精确 24 小时区间。
最初每小时的 24 个观测点（`t0` 至 `t23`）只跨 23 小时，故意仍然太短；正常的下一小时补足完整覆盖
（恢复脚手架使用连续 25 个观测点 `t0` 至 `t24`）。每个快照只作为它那段有界区间的**左端点价格**；
最新一条只算到 `block.timestamp`，于是「拉盘 → 采样 → 立刻开系列」时该条权重约等于 0。
fail-closed 的原因码（`openSeries()` 拿到非零一律拒绝开系列）：

| `status` | 含义 |
|---|---|
| `0` | 可用 |
| `1` | 环没填满（不足 24 个价格槽） |
| `2` | 最新样本 > 2 小时旧 |
| `3` | 严格 trailing 覆盖不足 24 小时 |
| `4` | 所需历史已回看超过 30 小时（长时间断采不能靠补一条样本修好） |
| `5` | 相邻价格段或最新尾段超过 `MAX_SAMPLE_GAP`（65 分钟） |

> 🔴 **保证是一条定量的界，不是「移不动」**：正常严格每小时时，24 个完整价格段各恰为 `1/24` 权重；
> 所有可接受窗口中的硬上界则是 `MAX_SAMPLE_GAP / 24h = 65 分钟 / 24 小时`（约 4.51%），不是任何情形都
> 恰为 `1/24`。该值仍是离散 spot 的加权聚合，不是连续观测的市场价。要整个替换读数，需要反复控制有效的
> 采样段；无许可的代价是任何人都可抢在 keeper 前面挑时刻（不能直接挑价格）。换来的是后端挂了仍有活性，
> 且不给本金库配上第一把钥匙。Monitor 应同时盯 `TwapSampled` 的时刻与 gap / failure 事件。
> 200 GME 的分叉实验运行在**曲线**分支：它展示真实曲线交易下严格每小时聚合器的行为，不能拿来证明 V2 池
> 抗操纵。

### 5.3 Warrant（ERC-1155）

```solidity
contract Warrant is ERC1155 {
    address public pool;                        // 一次性绑定，见 §12 —— 不是 immutable
    address private immutable deployer;
    modifier onlyPool() { require(msg.sender == pool); _; }

    function setPool(address p) external { require(msg.sender == deployer && pool == address(0)); pool = p; }

    function mint(address to, uint256 id, uint256 amount) external onlyPool;
    function burn(address from, uint256 id, uint256 amount) external onlyPool;
}
```

**仅 ClearingPool 可铸造与销毁。** 转让完全自由（Seaport 交易的前提）。

> 当前 `uri(id)` 返回空字符串，且合约没有元数据管理员。系列详情应从 `ClearingPool.series(id)` 读取，
> 展示层自行组合标的、到期、strike 与状态；不要依赖 ERC-1155 metadata URI。

> `pool` 做成"一次性、仅部署者、写后永久锁死"的槽而非 `immutable` —— 这正是**不用 CREATE2 就打开三方构造环**的办法（§12）。**未绑定时 `pool == address(0)`，`onlyPool` 拒绝一切调用**，所以未绑定的 Warrant 是惰性的，不是敞开的。

### 5.4 MerkleDistributor

```solidity
constructor(address publisher_);        // 🔴 publisher 是 immutable（见下 ③）

function setRoot(uint256 seriesId, bytes32 root) external onlyPublisher;  // 每周一次

/// permissionless（2026-08-09 决策 ④）：任何人可代提交 proof，权证只进 leaf 指定的 account
function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external;

/// 组合路径（2026-08-09 决策 ③）：领取后立即以 account 为受益人行权，仅 account 本人可调
/// 必须写入与 claim() 相同的 claimed 标志位 —— 见下
function claimAndExercise(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external;

/// leaf 编码的权威出处（链下 Indexer 与前端都读它）—— 见下 ①
function leafOf(uint256 seriesId, address account, uint256 amount) external pure returns (bytes32);

mapping(uint256 seriesId => bytes32 root)   public roots;
mapping(uint256 seriesId => bool)           public rootFrozen;   // 首次消费后 root 定死，见下 ②
mapping(uint256 seriesId => mapping(address => bool)) public claimed;   // 🔴 两条路径共写同一位
```

权证由 ClearingPool 铸给本合约，用户凭 proof 领走。

- **`claim` 是 permissionless 的**：keeper（或我们）可代付 gas 批量投递，用户零操作也能收到权证。与回流机制兼容——代领无法代行权，回流由"未行权"驱动（[`research/expiry-window-verification.md`](./research/expiry-window-verification.md) §9.4）。
- **`claimAndExercise` 兑现文案承诺**（"行权可直接从累积余额执行"）：本合约作为权证持有方调 `pool.exercise(seriesId, amount, beneficiary = account)`——权证从本合约销毁、MEME 从 account 拉取（须已 approve 给 ClearingPool）、声明门查 account、股票直达 account。用户路径从三笔（claim + approve + exercise）压到两笔（approve + claimAndExercise）。**`require(msg.sender == account)`**：行权花的是 account 的 MEME，不可由第三方代为择时。

  🔴 **`claimAndExercise` 必须像 `claim` 一样置 `claimed[seriesId][account]`，并在入口先拒绝已领取的 leaf。** 这是同一张 merkle leaf 上的**第二个消费入口**，漏掉标志位不是"重复领自己的份额"，而是**从共享余额里偷别人的**：

  ```
  claimAndExercise(seriesId, account, amount, proof)     // 重放 N 次
    └─ pool.exercise(…, beneficiary = account)
          └─ warrant.burn(msg.sender = distributor, seriesId, amount)
                 ↑ 本合约持有的是该系列【所有未领取用户】的权证
  ```

  每次重放都从这个共享余额里烧掉 `amount`。调用者每次都付自己的 MEME，但拿走的是**尚未领取的其他持有人所对应的股票**——那些人手里握着有效 proof，却已无货可兑。**两个入口必须共用一个标志位，且都要在做任何事之前先检查它。**
- **未领取的权证**：系列结算后作废（`settled ⟹ exercise revert`），对应抵押品计入 `remainder` 由 `rollExpired` 池内滚存，**不再回流金库**。

> 📝 **2026-08-13 实现时的四处收口**（M1-8，issue #13）。前两处是本节草图没写、但一落地就必须回答的问题。
>
> **① leaf 编码：`keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`。**
> 两个细节都是承重的。**`seriesId` 在 leaf 里面**——标志位已经按系列分开了，看似多余，但它挡的是另一条路：
> publisher 若把同一个 root 误发给两个系列，同一张 leaf 就能在两个系列上各消费一次，第二次动的是
> 另一批未领取用户的共享余额。把系列钉进 leaf，这件事在结构上不可能发生，而不是靠 publisher 不犯错。
> **哈希两次**是 OpenZeppelin `StandardMerkleTree` 的约定：内部节点原像恒为 64 字节，leaf 只哈希一次时
> 一段恰好 64 字节的 leaf 原像可能同时是某个内部节点的原像（second preimage）。链下对应
> `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`。
>
> 🔴 **2026-08-18 补记（issue #66）：不只是编码要一致，root 必须能被官方库复算出同一个值。**
> 内部节点用的是可交换的 sorted-pair 哈希，所以**任何**自建树都能产出一对能通过 `MerkleProof.verify`
> 的 (root, proof)；但 OZ 的 `StandardMerkleTree` 对 leaf 另有一套确定的排序与布局规则，排序不同
> ⇒ **root 就是另一个值**，两份还各自自洽。后果是 §9 那条「算法与复算脚本必须开源，**任何人可独立
> 验证 root**」会在无人察觉的情况下落空：**往返测试抓不到它**（我们的 proof 对我们的 root，当然过），
> 第三方拿官方库照我们的公开输入复算才会发现对不上。⇒ root 构建脚本的验收里必须有一条
> **与官方库输出逐位比对**（固定向量或直接调库），它与语言选型无关。
>
> **② root 在该系列的第一张 leaf 被消费之前可改，之后永久冻结**（`rootFrozen[seriesId]`）。
> 两个极端都不可接受：永久 write-once 让一个打错的 root 把整周分发全数错付且**无法挽回**
> （本合约无 admin，权证已经铸出去了）；永远可改则意味着分发已经开始之后，publisher 仍能把剩下的
> 份额重新指给任何人。冻结点选在「第一个人依据这份 root 行动」的那一刻——在那之前改动不伤害任何人，
> 在那之后改动就是追溯改写。这条保证是**可读的**：`rootFrozen[id] == true ⟹ 该系列的归属已定死`。
>
> **③ publisher 是构造参数且 `immutable`，与部署者刻意分开。** 部署者的权限在两笔 `setPool` 之后就用尽了，
> 而 publisher 每周都要签一笔 `setRoot`——它必须是一把热钥匙。部署脚本默认让两者相等，
> 主网可用 `DISTRIBUTOR_PUBLISHER` 分开；地址进清单并由 `verify-deployment.sh` 回链上核验（§12）。
>
> **④ `amount == 0` 的 leaf 在两个入口上都被拒。** 它挡的不是攻击，是**两个入口的不对称**：
> 零份额在 `claimAndExercise` 那一侧必然被池子拒掉（`memeAmount` 取整到 0 ⟹ `ExerciseRoundsToZeroMeme`），
> 而 `claim` 会照常消费掉它。同一张 leaf「能不能消费」有两个答案，正是本节要消灭的那类不对称。
>
> 另外两件落地时确定的事：两条路径调用的是**同一个** private `_consume`（「查 → 验 → 置位」只有一份实现，
> 两个入口的门一致因此是编译器保证的，不是需要有人记得维护的约定）；两个入口都带 `nonReentrant`，
> 代价是合约钱包不能在 ERC-1155 回调里顺手领第二张 leaf（分两笔即可）。

#### 5.4.1 M4 归属计算的权威口径（2026-08-23，#91）

本节是 `canonical series ledger → entitlement calculation → §5.4 vesting input` 的唯一算法定义。
版本化接口、逐位固定的输入输出和复跑入口位于 [`offchain/entitlement/`](../offchain/entitlement/)：

```bash
script/ci.sh entitlement
```

1. **D1——每系列一次整段 TWAB。** 将该系列截止前全部可分配权证组成一个池，周内收入与
   `processRevenue()` 时点不切分持仓权重。两人各持半窗且整窗权重相等时，即使收入按 90/10 到账，
   仍各得 50%。唯一公式是
   `amount = floor(allocatable × accountWeight / totalAccountWeight)`。
2. **D2——窗口。** `[ClearingPool.SeriesOpened, min(next ClearingPool.SeriesOpened for the same vault, expiry))`。
   提前换期开出时由下一条事件的 cursor 截断；到期截止时 `endCursor = null`，并记录第一块越过
   `endTimestamp` 的 canonical block。漏开产生不倒填的停发缺口，issuer gating 不延长归属窗口。
3. **D3——可分配库存。** 截止内每条 `Deposited.minted` / `Rolled.amount` 必须与同交易中 Pool 发出的
   Warrant `TransferSingle` mint 唯一配对，且两笔金额相等；总和还必须等于 cutoff cursor 重放出的
   `Series.deposited == Series.minted`。截止后 roll 不改变已封存结果，额外 Distributor 余额也不扩大
   `allocatable`。
4. **D4——资格与协议库存。** 固定政策
   `minimumAverageBalanceRaw = 10_000 × 10^18`，不随 `totalSupply()` 变化；禁止先除法，直接比较
   `candidateWeight >= minimumAverageBalanceRaw × durationSeconds`，等号通过。未达者 `accountWeight = 0`、
   不出 leaf、不进分母。曲线、DEX 池、Portal、代币自身税池（`TAX_POT`）与 TaxProcessor 等只有在角色、
   生效 cursor 与链上证据可公开复算时才排除；真实分叉表明 swap-back 前 MEME 在代币合约自身，
   TaxProcessor 的 MEME 余额为 0，两者不得混为同一地址。`0xdead` 是普通余额地址，v1 不按“地址有代码”
   排除，也不向 LP 持有人穿透。
   这与 Flap 发射字段 `minimumShareBalance = 0` 完全无关。
5. **D5——权重。** 从 MEME 创建块开始按 `(blockNumber, transactionIndex, logIndex)` 完整重放 canonical
   `Transfer`，以 cursor-exact 起始余额、整数秒和 BigInt 对分段常数余额积分。同 timestamp 事件按 cursor
   改状态但持续时间为 0；带税转账的每条 leg 分开处理；零地址只表示真 mint/burn。计算顺序固定为
   `grossWeight → candidateWeight → accountWeight`。`sumBalances == replayedSupply`、
   `sum(grossWeight) == integral(replayedSupply)` 与完整块状态锚点任一不成立即 fail closed。
6. **D6——分母与正常无 root 结果。** 唯一分母为 `sum(accountWeight)`。`allocatable == 0`、正库存但
   分母为 0 分别得到 `NO_ALLOCATABLE_INVENTORY`、`NO_ELIGIBLE_HOLDERS`；保留 calculation record，
   不造空 root、不把钱给 treasury、不临时改门槛。只有 canonicality、守恒或链身份等输入证据不可信
   才是 `BLOCKED`。
7. **D7——取整。** 每户独立 BigInt floor，记录 `numerator` 与 `fractionRemainder`。零 amount 留在
   calculation 但不进 vesting；`dust = allocatable - sum(non-zero amount)`，且
   `dust < positiveWeightCount`，留在 Distributor。若所有 amount 都为 0，结果为
   `NO_NONZERO_ENTITLEMENTS`；不用最大余数法、四舍五入或 treasury 兜底。
8. **D8——finality 与发布模式。** 每系列只有一个最终计算。finality 前只能产生不可 seal、不可发布、
   不可服务 proof 的 `PREVIEW`；canonical `finalized` tag 尚未追上时是 `WAITING_FINALITY`，tag 不可用、
   降级或 ancestry/hash 矛盾时 fail closed，禁止退化为 `latest - N`。finalized 后，尚未 settled 且观察时刻
   早于实际 `exerciseDeadline` 标为 `TIME_WINDOW_OPEN`，否则为 `CLAIM_ONLY`；后者仍可发布和 `claim`，
   但不能 `claimAndExercise`。
9. **D9——reorg。** block header + raw log canonical journal 是事实源，checkpoint 只加速。新块与恢复启动
   都核对 parent/tip hash；coherent alternate chain 回滚到最近共同祖先并原子重放，结果必须与空库全量
   重放逐位一致。证据暂不可得时保持原状态并报 `CANONICALITY_UNAVAILABLE`；跨 finalized frontier 或
   部署/链身份改变时分别报 `FINALITY_VIOLATION` / `CHAIN_IDENTITY_MISMATCH`，停止且不自动替换 root。
10. **D10——证据与查询。** 链上 `RootSet` 是发布事实，sealed bundle 是公开证据，Proof API 只是可重建的
    只读投影。有非零 entitlement 时封存 calculation / vesting / built / manifest / bundle；三个正常无-root 结果
    只封存 calculation / manifest / bundle。文件按 exact bytes 做 SHA-256；`bundleId` 是按路径排序的
    `path + NUL + fileHash + LF` 字节串的 SHA-256，不含 wall clock。不可变查询键为
    `(chainId, distributor, seriesId, root, account)`；current 查询只由 reorg-aware `RootSet` catalog 解析。
    root replacement 只移动 current 指针，历史 bundle 永久保留。`FINALITY_VIOLATION`、
    `CHAIN_IDENTITY_MISMATCH` 与 `PUBLICATION_HISTORY_MISMATCH` 会让 current/by-root 查询全部
    fail closed；只有 `CATALOG_UNAVAILABLE` 时，已知 immutable by-root 审计与静态 bundle download
    可继续。API 不计算、不签名、不判断 claimable。

### 5.5 AttestationRegistry（🔴 不可升级，每链一个）

**用途**：在行权路径上留下用户签署的链上证据。借鉴 StonkBrokers 的做法（[`research/stonkbrokers-playbook.md`](./research/stonkbrokers-playbook.md) §11），但有三处刻意的差异，见下。

```solidity
contract AttestationRegistry {
    struct TextVersion { bytes32 termsHash; bytes32 attestationHash; }

    TextVersion[] public versions;                       // 🔴 只能 append，无删改函数
    mapping(address => uint256) public attestedVersion;  // 0 = 从未声明；存的是 version+1
    address public immutable publisher;                  // 仅能 append 新版本

    event Attested(address indexed who, uint256 version,
                   bytes32 termsHash, bytes32 attestationHash, uint256 at);

    // 🔴 version 0 在构造函数里写入 —— 不是部署后再补一笔，理由见下
    constructor(address publisher_, bytes32 termsHash, bytes32 attestationHash) {
        publisher = publisher_;
        versions.push(TextVersion(termsHash, attestationHash));
    }

    function addVersion(bytes32 termsHash, bytes32 attestationHash) external {
        require(msg.sender == publisher);
        versions.push(TextVersion(termsHash, attestationHash));
    }

    function attest(uint256 v, bytes32 termsHash, bytes32 attestationHash) external {
        TextVersion memory t = versions[v];
        require(termsHash == t.termsHash && attestationHash == t.attestationHash, "text mismatch");
        // 🔴 取大，不是 require(v + 1 > attestedVersion[msg.sender])，理由见下
        if (v + 1 > attestedVersion[msg.sender]) attestedVersion[msg.sender] = v + 1;
        emit Attested(msg.sender, v, termsHash, attestationHash, block.timestamp);
    }
}
```

> 📝 **2026-08-10 实现时的两处收口**（M1-2，issue #7）。两处都是为了让不变量 6 **不带前提条件** ——
> 这条不变量的全部意义就是「这道门结构上锁不死任何人」，任何附加条件都在削弱它。
>
> **① `attest` 用取大，不用 `require(… > …)`。** 严格递增会让「已经签过 version 0 的地址再签一次 0」
> revert，于是 6③ 只能被削弱成「**尚未声明的**地址恒可 `attest(0,…)`」。取大同样满足 6① 的
> 措辞（**单调不减**，不是严格递增），且严格更强：签署旧版本既不失败也不回退状态。
> 代价是 `Attested` 变成**签署行为的流水**而非账户状态的快照 —— 链下还原当前版本要取 `max`，
> 或者直接读 `attestedVersion`。
>
> **② version 0 走构造函数，不走「部署完再由 publisher 调 `addVersion`」。** 后者有两个真实后果：
> 两笔交易之间存在一段 `versions` 为空的窗口，那时 `attest()` 对所有人 revert，
> 6③ 的前提于是从**结构**保证退化成**流程**保证；且 publisher 必须是部署者本人，
> 否则 `addVersion` 会被 `onlyPublisher` 拒掉 —— publisher 想用多签就得靠人工补一笔，
> 窗口随之拉长到人的响应时间。放进构造函数后 `versions.length ≥ 1` 从第一个区块起恒成立。
> ⚠️ **issue #8 的验收条款「部署脚本在部署后立即 `addVersion(version 0)`」随之作废**，
> 换成「构造参数里带上 version 0 的两个哈希」。
>
> 上面这个代码块仍是**示意**，不是逐字的实现。实现另外带了几处不改变语义的加固：
> 自定义 error 取代 require 字符串、`versionCount()`、`VersionAdded` 事件、
> `addVersion` 返回新版本下标，以及两条构造期防呆（publisher 不得为 0、文本哈希不得为全零）。
> 以 [`src/AttestationRegistry.sol`](../src/AttestationRegistry.sol) 为准。

**ClearingPool 侧只查一件事**（见 §5.1）：

```solidity
require(attestations.attestedVersion(beneficiary) != 0, "not attested");
```

> 📝 **2026-08-10 更正**：此处原写 `msg.sender`，与 §5.1 的行权检查顺序不符。🔴 **查的必须是
> `beneficiary`** —— 否则 distributor 的 `claimAndExercise` 路径（§5.4）会把这道门整个掏空。

#### 🔴 为什么必须"只记录，不阻断"

**任何管理员可控的行权前置检查，都是一个可以冻结全体用户资产的节流阀。** 合规 admin 私钥一旦丢失或被夺，全部权证永久变砖 —— 而我们对外承诺的是"清算池不可升级、无 admin 提取路径"。加一道可控的门，这句话当场作废。

因此本合约的设计约束是：

| 约束 | 实现 |
|---|---|
| `attestedVersion` **只增不减** | 无任何函数可减少或清零，**publisher 也不能** |
| 只有账户**本人**能改自己的状态 | `attest()` 只写 `msg.sender` |
| `versions[0]` **永久存在且不可变** | 无删改函数；任何人在任何时刻都能调 `attest(0, …)` 满足门槛 |
| publisher 权限**仅限 append** | 追加新版本**不影响**任何既有声明 |

> **结论：这道门在结构上不可能被用来锁死任何人。** 链上只要求"≥1 次声明"，前端要求"最新版本"。文本更新时前端跟进，链上永不追溯失效。**合规目标与不可升级承诺同时成立。**

#### 为什么参数里要传哈希

`termsHash` / `attestationHash` 已存在链上，调用时仍要求传入并校验相等 —— 目的是**让文本哈希出现在交易 calldata 里**：

- 钱包签名界面会展示原始 calldata，用户签的是"我看过这段文本"而非一个空调用
- **前端无法替用户悄悄声明另一版本的文本** —— 与 StonkBrokers 同一套哈希纪律

**证据落在交易本身与 `Attested` 事件里，永久可查，无需额外存储。**

#### 与 StonkBrokers 的三处差异

| | StonkBrokers | 我们 | 原因 |
|---|---|---|---|
| **门开在哪** | `elect()` 选股时 | **`exercise()` 行权时** | 我们的 `claim()` 只产出可转让权证，不触及股票 |
| **受限用户的替代路径** | 改选 `USDG` 等非受限资产（安慰奖） | **卖出权证**（平级选项，常常更优） | 权证本身可转让，无需触及标的即可变现 |
| **文本内容** | 含法律结论性断言（"这是营销服务报酬，不是分红"） | **只写事实** | 见下 |

#### 文本内容：只写事实，不下法律结论

| 类型 | 例子 | 价值 |
|---|---|---|
| **事实性自述** | "我不是美国人 / 不位于受限辖区" | **高** —— 只有用户自己知道的事实，谎报责任在其本人，且证明了善意筛查 |
| **法律结论性断言** | "这不是分红 / 不是证券" | **低** —— 认定看实质不看措辞；写了反而显得刻意 |

因此 version 0 采用两段文本，**均为事实陈述**：

**TERMS（关于工具本身）**
> 我理解我获得的是**按约定价格购买**代币化股票的**权利**，不是获得分配的资格；行权需要我**销毁 MEME 作为对价**；它可能到期归零；代币化股票本身是由受监管第三方发行的**追踪股价的债权型凭证，不代表标的股票的所有权，不附带投票权或任何股东权利**；该发行方保留冻结转账、暂停代币、以及从任意地址销毁持仓（**包括本清算池**）的能力。

> 📝 **2026-08-09 修订**：新增债权型凭证性质的陈述——Robinhood Stock Token 的法律形态是 tokenized debt security（发行方公开披露），此前草稿的表述会让签署者以为拿到的是股票所有权。✅ 已定稿（2026-08-26，issue #18；权威文本为英文）。

**ATTESTATION（关于用户本人）**
> 我声明我不是位于、注册于或居住于**美利坚合众国**、或任何限制接收/行权代币化股票相关工具的司法辖区的个人或实体，且我并非代表任何此类个人或实体行事。

> ⚠️ **version 0 的两个哈希一经部署即永久存在。两段文本已于 2026-08-26 定稿（issue #18），权威语言为英文**（§14-8 ✅）。
>
> 📌 以上中文两段是**非约束性参考译文，不是权威文本** —— 权威定稿文本为英文，字节只有一处：
> [`legal/attestation-v0/*.en.txt`](../legal/attestation-v0/)，哈希从那两个文件现算；
> 权威语言与定稿依据的永久记录见同目录 README。

#### 这个机制**不**覆盖什么

| 敞口 | 覆盖 |
|---|---|
| 向受限地区人士分发代币化股票 | ✅ 部分 —— 善意筛查 + 举证责任转移 |
| **我们发行的是证券的衍生品（期权）** | ❌ **完全不覆盖** |
| **我们运营该衍生品的订单簿** | ❌ **完全不覆盖** |

且自我声明**不可强制执行**：签署后转到另一地址行权，链上拦不住（StonkBrokers 亦然）。**它买到的是证据与善意，不是强制力。** 对外文案不得暗示更多，见 R12。

---

## 6. 核心时序

### 6.1 项目发射（D0，M2-6② / issue #57 已落地）

🔴 **发射入口是我们自己的合约 `WarrantLauncher`，不是 Flap 的 `VaultPortal`。**
`VaultPortal.newTokenV6WithVault` 那条路在本链上两档 quote 都是死的（native 撞金库的零地址计价币
防线，GME 被 `UnsupportedQuoteToken(GME)` 前置拒绝），而那道门写死在未验证的门面字节码里 ——
我们改不了、也等不起（issue #45 / #53）。普通 `Portal.newTokenV6` 从来没有被那道门约束过，
D0 走的就是它（决策 39 / 40，实测见 [`research/self-launch-spike.md`](./research/self-launch-spike.md)）。

```
项目方在我们的 Web App 填参数 → 链下挖一个使代币地址以 7777 结尾的 vanity salt
  → 一笔交易：WarrantLauncher.launch({name, symbol, meta, salt, quoteToken, antiFarmerDuration})
        ① 预检：身份根接了没有、计价币是不是一个**有代码**的地址
        ② expectedVault = factory.nextVault()          ← 建币前就得知道金库地址，见下
        ③ token = Portal.newTokenV6(… beneficiary = expectedVault …)   ← **同步返回真地址**
        ④ vault = factory.newVault(token, quoteToken, msg.sender)
           require(vault == expectedVault)             ← 逐位核对，不等就整笔回滚
        ⑤ registry.bind(token, vault)                  ← 唯一写身份根的地方，排在最后
     返回 (token, vault)
  → 后端登记项目，Indexer 开始订阅 Transfer
```

🔴 **为什么 `beneficiary` 必须先算出来。** 发射参数里那一格就是 `TaxProcessor.marketAddress()` ——
这只代币此后**全部税收的收款人**（spike §3.4 实测逐位相等）。它由 Flap 在建币时写死，此后只有
Portal 的 `changeMarketWallet`（那把 2-of-3 Safe 的权限）改得动，也就是说**我们只有建币那一刻这
一次机会**（决策 35 / R15）。所以顺序被这条事实钉死：先问工厂「下一只金库落在哪」，把那个地址填进
`beneficiary`，建完币再核对工厂真建出来的是不是同一个。

> ⚠️ 这与决策 34 里那个「预测地址」形状**相反**：那边预测的是别人的代币地址、核对的人是别人；
> 这边预测的是我们自己的金库地址、核对的人是我们自己，而被核对的对象是一次 `CREATE` 的返回值。
>
> 🔴 #57 票面原话是「不需要 CREATE2 预测地址」。那句话对**代币**那一侧成立，对**金库**那一侧
> 不成立（同一张票又要求 `TaxProcessor.marketAddress() == 金库`）。**维护者已于 2026-08-17
> 确认采纳这条取舍**，见 `design.md` §10-40 的第 ① 项。

**发射参数（固化在 launcher 的字节码里，调用方改不了）**：GME quote、`dividendToken == quoteToken`、
买卖各 300 bps、`taxDuration = 100 年`（不是 Flap 示例的 365 天）、`mktBps = 10000`、
deflation / dividend / LP bps 均为 0、`minimumShareBalance = 0`（`dividendBps == 0`，与 M4 门槛无关）、
`quoteAmt = 0`、`tokenVersion = TOKEN_TAXED_V3`、
`migratorType = V2_MIGRATOR`、`dexThresh = FOUR_FIFTHS`、`dexId = DEX0`、
`commissionReceiver` = launcher 的 `immutable`（我们的地址）。链上可读：`launcher.launchEconomics()`。

**调用方能决定的只有五样**：`name` / `symbol` / `meta`、`salt`、`quoteToken`，以及
`antiFarmerDuration`（§14-2 的未决项，定值之前留成参数）。

🔴 **vanity salt 在链下挖。** Portal 要求代币地址以 `7777` 结尾；挖一个合规 salt 平均要几十万次
keccak，放进合约就是把一笔发射变成一次不可预算的 gas 赌博。推导：
`predicted = CREATE2(Portal, salt, keccak(EIP-1167(TaxTokenV3Impl)))` ——
参考实现见 `test/fork/FlapGmeLaunch.sol::_mineVanitySaltFrom`。挖错了不会静默：Portal 自己会拒绝。

**判据 2 在这个构造下更强。** `bind` 的第一个参数只可能是 ③ 那一行的返回值 —— launcher **没有第二条
通往 `registry.bind` 的路径，也没有任何入口接受一个调用方给定的代币地址**（`launch` 的入参结构体里
根本没有那一格）。「给一只已经存在的 MEME 补登记金库」因此不是更难，是没有函数可调；由
`test/WarrantLauncher.t.sol` 的写入面枚举 + `script/flap-vault-spec-check.sh` 的结构体成员枚举双重钉住。

**失败即整笔回滚。** ⑤ 排在最后，前四步任何一步 revert 它根本执行不到；⑤ 自己 revert（例如这只 MEME
已经绑过）则整笔一起回滚 —— **不存在「代币建出来了但绑定没写上」的中间态**。
①②那两道预检可以放到后面去撞（金库构造函数拦同样的计价币），提前是因为**代币一旦建出来就撤不回**。

**`launch` 无许可。** 陌生人用它发的项目得到的是他自己那只 MEME 的金库；他改变不了任何已有项目的
一个字节（抢注在结构上不可达，且每个系列的抵押品在 `ClearingPool` 里彼此隔离）。加一道白名单只会
凭空造出本系统的第一把运营钥匙。

**验收**：钉死高度的端到端在 `test/fork/RobinhoodLauncher.t.sol`（CI required，含
`TaxProcessor.marketAddress() == 金库`）；latest 探针在 `test/fork/RobinhoodSelfLaunch.t.sol`
（`script/monitor.sh canary`，刻意不进门禁）—— 分工纪律见 issue #25。

### 6.2 每周开系列（M2-4 已落地，issue #36）

```
周五 21:00 UTC 前 ── 任何人（通常是 Trigger Service）→ vault.openSeries()
   ├─ expiry = 第一个满足「expiry − now ≥ 7 天」的周五 21:00 UTC
   ├─ 两条干净返回边，不 revert：
   │     ├─ 本期已开（expiry == seriesExpiry）        → 返回 (当前系列, false)
   │     └─ 当前系列还剩超过 24 小时才到期            → 同上
   ├─ 读 ring buffer 计算 24h TWAP —— 🔴 六个状态里只有 0 放行，其余一律 revert
   ├─ strike = TWAP × 8000 / 10000（决策 14，k = 0.8，向下取整）
   │     └─ 取整成 0、或装不进 uint128 → revert，不落一个坏 strike
   ├─ pool.openSeries(meme, stock, expiry, strike)   ← 🔴 先成功；池子只接受身份根为该 MEME
   │   登记的金库，而 Factory 创建后这里恰好就是本 vault
   └─ 再写 strike / seriesExpiry，发 WeeklySeriesOpened(seriesId, expiry, strike, twapPrice)
```

**周五对齐**：`expiry` 取**第一个**满足 `expiry − now ≥ 7 天` 的周五 21:00 UTC，所以寿命恒落在
`[7 天, 14 天)`。实现是纯算术：Unix 纪元是**周四**，因此周五 21:00 UTC ⟺ `t % 7 days == 45 hours`；
把 `now + 7 天` 向上取整到该边界即可。闰秒与夏令时都影响不到它（Unix 时间不计闰秒，UTC 没有夏令时），
两条各有测试。

🔴 **开系列的时刻受 24 小时窗口约束**（票面未点名，实现时补上）：只有当前系列剩余不到 24 小时、
或已经到期时才开得出下一期。`openSeries()` **无许可**，调用方挑不了任何参数，但挑得了**时刻** ——
而 strike 一周只定一次。没有这道门，任何人都可以在一周里任选一小时把整周的行权价定死；
这不是价格**操纵**（那一面由 §5.2 的采样界压住），而是价格**选择**，TWAP 挡不住它。
装上之后可选区间从「一周」压到「24 小时」，而相邻两个 24 小时窗口的 TWAP 高度重叠。
代价是活性，但那条路没堵死：**到期之后门自动打开**，任何人都能立刻补开一期，只是按 ≥7 天寿命规则
落到再下一个周五。完整论证见 `src/WarrantVault.sol` 的 `OPEN_WINDOW`。

**停发可观测**（issue #42 的链上抓手）：`openSeriesStatus()` 是一个 **view**，不必发交易就答得出
「本期开出来了吗、没开是因为什么」。它与 `openSeries()` 共用同一个私有判定函数，因此**不可能给出
不同的答案**。

| `status` | 含义 | 下一步该看哪里 |
|---|---|---|
| `0` | 现在调就会开出一期 | 🔴 「本该开、能开、却没开」—— 查 Trigger Service |
| `1` | 本期已经开出来了 | 正常 |
| `2` | 当前系列还剩超过 24 小时 | 正常，现在本来就不该开 |
| `3` | 24 小时 TWAP 不可用 | **调 `twap()` 读那六个码**——本表刻意不转发它们 |
| `4` | TWAP 太低，折让后取整成 0 | 价格来源 / 曲线状态 |
| `5` | 折让后的 strike 装不进 `uint128` | 价格来源 / 池子储备 |

⚠️ 池子侧 `SeriesAlreadyOpen` 仍会原样冒泡：若**本 vault 自己**重复开同一三元组就会遇到它。
但陌生地址不能抢先开走：issue #37 接上身份根后，池子只放行该 MEME 已登记的 vault，第三方抢注路径
在结构上不再可达。

### 6.3 每日铸造（M2-3 已落地，issue #35）

```
任何人（通常是 Trigger Service，每日一次） → vault.processRevenue()
   ├─ 先 _recognize()：按余额差认收入（规范 rule 010-5，先识别再行动）
   ├─ 读**实际余额**（🔴 **不封顶** —— 与 receive() 相反，读不出来就如实失败）
   │     └─ 若前一次封顶读只是太慢，则先按这次真数补发收入识别，再存入
   ├─ available = balance − creatorAccrued（饱和减）           ← 🔴 决策 49：creator 浮存不可存
   ├─ 两条边干净返回，不 revert：
   │     ├─ available 为 0                  → 返回 0
   │     └─ 没有还活着的系列               → emit RevenueDeferred(available)，钱留在金库等下一次
   ├─ cut = available × CREATOR_FEE_BPS / 10000                ← 决策 49：向下取整，尘埃归池
   ├─ approve(pool, available − cut)                           ← 恰好这一次的量
   ├─ pool.depositAndMint(seriesId, merkleDistributor, available − cut)
   │     └─ 以池内**实际余额增量**为准铸造（不变量 2；金库不断言 minted == 存入量）
   ├─ approve(pool, 0)                                        ← 两笔交易之间授权恒为 0
   ├─ 再次不封顶读取金库实际余额
   ├─ accountedQuote = balanceAfter                            ← 🔴 规范 rule 010-3，同笔更新基线
   ├─ sent = max(balanceBefore - balanceAfter, 0)              ← 实际净从金库扣除量
   ├─ confirmedCut = min(cut, sent × 1000 / 9000)              ← 🔴 分成按实测扣款反推、满额封顶：
   │   creatorAccrued += confirmedCut                             假转账（sent=0）与部分扣款都不会
   │                                                             让同一批钱被二次切分（审计 M-01）
   └─ emit RevenueDeposited(seriesId, sent, minted)（+ CreatorFeeAccrued(confirmedCut, 累计)）

任何人（通常是 creator 自己） → vault.claimCreatorFee()
   ├─ 先 _recognize()（rule 010-5），零累计时静默 no-op 返回 0
   ├─ requested = min(creatorAccrued, 实际余额)；creatorAccrued 先按请求额扣减（效果先行）
   ├─ 股票代币 → creator（构造时定死的 immutable；🔴 发行方拉黑 creator 时整笔如实回滚，
   │   只影响他自己 —— 不连坐 processRevenue，也没有改址口）
   ├─ debited = max(余额前 − 余额后, 0)                         ← 🔴 与 processRevenue 同口径：实测扣款
   ├─ claimed = min(debited, 原 creatorAccrued)；债权按 claimed 校正
   │   （假转账 → 债权原样恢复、不发事件；部分扣款 → 只消耗实际走掉的那部分）
   │   （发送方额外手续费可使 debited > claimed；手续费不是 creator 收入，完整余额变化见 accountedQuote）
   ├─ accountedQuote = balanceAfter                            ← 第二条支出路径，同一条 rule 010-3
   └─ 若 claimed != 0：emit CreatorFeeClaimed(claimed)

后端 Indexer 在系列窗口截止后计算一次整段 TWAB → finalized 后发布该系列最终 merkle root
```

> ✅ **2026-08-24（#91～#96）：M4 的 canonical replay、确定性计算、公开复算、sealed bundle
> catalog 与只读 Proof API/HTTP adapter 已实现并通过测试。** 发布仍是需 publisher 显式签名的步骤。
> 手工工具仍保留：`node offchain/merkle/build-root.js`（清单 → root + 每张 leaf 的 proof）、
> `script/publish-root.sh`（publisher 签 `setRoot`）、`script/claim-warrant.sh`（为某个持有人拼
> `claim` / `claimAndExercise` 的 calldata）。用法与一周的完整流程见
> [`offchain/merkle/README.md`](../offchain/merkle/README.md)。
> #96 的 `node offchain/entitlement/prepare-handoff.js` 已把 finalized 高度上的 replay / recompute / seal、
> 链身份、系列双账、Distributor 余额、publisher、当前 root 与 `rootFrozen` 快照接成一个
> `READY_FOR_HUMAN` handoff，并在**移除私钥环境变量**后调用发布脚本 dry-run。真正广播仍是独立的人工
> 步骤；完整恢复、A→B 替换、同步与独立复算流程见
> [`publisher-handoff-runbook.zh.md`](./publisher-handoff-runbook.zh.md)。
> 🔴 **发布之前那一刻是唯一能纠错的时刻** —— root 在该系列第一张 leaf 被消费之后永久冻结（§5.4 ②），
> 所以 `publish-root.sh` 在广播之前会强制从输入清单完整复算一遍、核对链是哪条、核对签名的钥匙
> 是不是链上那个 `publisher`、读一次 `rootFrozen`，并把「这是覆盖还是首发」摆到签名的人眼前。

`seriesId = pool.seriesIdOf(taxToken, quoteToken, seriesExpiry)` —— 公式只有一处出处（池子那一份）。

🔴 **无许可。** 「加速资金离开一个可升级合约」不该有守门人；而且调用方**改变不了钱的去向** ——
`pool` 与 `merkleDistributor` 是实现合约的 `immutable`。在途窗口的量化算例见
[`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md)。

### 6.4 用户行权

```
前端：查询用户可领取 + 已持有权证
   ├─ 若 attestedVersion == 0 或落后于最新版本
   │     → 展示两段文本全文 → registry.attest(v, termsHash, attestationHash)
   │        （一次性；链上只要求 ≥1 次，前端要求最新版本）
   ├─ approve MEME 给 ClearingPool（一次性/按量）
   ├─ 累积余额直接行权（免先领取，决策 ③）：
   │     distributor.claimAndExercise(seriesId, account=用户, amount, proof)   ← 仅本人可调
   │        └─ 内部：pool.exercise(seriesId, amount, beneficiary=用户)
   ├─ 已持有的权证：pool.exercise(seriesId, amount, beneficiary=msg.sender)
   └─ exercise 内部：
         ├─ 校验调用方 ∈ {beneficiary, distributor}
         ├─ 校验未结算、未过 _exerciseDeadline（门控可延长，见 §5.1）
         ├─ 校验 attestedVersion(beneficiary) != 0      ← 见 §5.5
         ├─ 销毁权证（从持有方）
         ├─ 销毁 beneficiary 的 MEME（转入 0xdead）
         └─ 股票转给 beneficiary   ← 发行方门控时此步失败 → 全部回滚
```

> **卖出路径不设此门。** 挂单/吃单走 Seaport，不触及股票，因此受限用户仍可完整参与"持有 → 累积 → 领取 → 卖出"。

### 6.5 到期结算

```
可行权窗口结束后（deadline = max(expiry, 门控解除 + 48h)；门控观测中无截止）
惰性，任何人可触发：

   pool.settleExpired(seriesId)
      ├─ 内部先刷新门控观测（同 pokeGating，自愈陈旧状态）
      ├─ 门控命中 → revert（行权窗口保持开放；若发行方仍禁转，`exercise` 整笔回滚——"自动延期"的实现，见 §5.1）
      └─ 通过 → settled = true；remainder = deposited − exercised

   pool.rollExpired(seriesId, nextSeriesId)
      └─ remainder 直接记入后继系列并铸权证给 distributor
         —— 托管权不出池，金库不经手（决策 ①）

（Monitor / 任何人可随时调 pool.pokeGating(stock) 留下门控观测记录）
```

### 6.6 OTC 成交

```
卖方：前端签 Seaport 订单（offer: Warrant ERC-1155，consideration: GME + 可选 taker fee）
      → 提交到 OrderbookService（链下，零 gas）
买方：前端取订单 → Seaport.fulfillAdvancedOrder()
      → 原子交换 + 手续费自动分账
```

#### 6.6.1 M5 v1 冻结口径（2026-08-25，M5-D1～D10）

> 🔴 **修订（2026-09-04，决策 52）**：支付币从「固定 GME」改为**该系列的股票代币 `Series.stockToken`**。首发项目按市场热度选股，launcher 的 `quoteToken` 本来就是入参，钉死 GME 会让任何非 GME 项目在官方市场上无单可成。服务接纳订单时从 `pool.series(seriesId).stockToken` 读取币种并与已验证配置里的 canonical 股票代币名单核对；名单进入 `deploymentConfigHash`；depth、fee、lot 全部按该系列币种计价，跨系列不可比；门控重验从「GME 状态」扩为「该系列股票代币状态」。M5 尚未实现，本修订零代码改动。下文原有的 `GME` 字样已按此替换，首发项目仍为 GME。对外产品名统一为 **Warrant Market**。

本节是 OrderbookService v1 的权威接口与状态口径。M5 **不新增结算合约**：标准 Seaport open order、
现有 ERC-1155 Warrant 与股票代币 allowance 已覆盖结算路径。外部用户仍可绕过本服务创建其他合法的
Seaport 订单；下列限制只定义**官方订单流**，不是链上全局转让规则。

**部署与支付。** 生产链固定为 Robinhood Chain `chainId = 4663`，Seaport 固定为
`0x0000000000000068F116a894984e2DB1123eB395`，支付币固定为**该系列的股票代币** `Series.stockToken`（首发项目为 GME
`0x1b0E319c6A659F002271B69dB8A7df2F911c153E`；决策 52）。不接受原生 ETH、WETH、其他 ERC-20 或混合支付。
maker 收入直接付 maker，手续费直接付该 epoch 固定的 recipient。`order.conduitKey` 与
`fulfillerConduitKey` 均为零：maker 直接 `Warrant.setApprovalForAll(Seaport, true)`，taker 直接
`stockToken.approve(Seaport, requiredAllowance)`；v1 不依赖 ConduitController、不接 Permit2，也不默认生成无限授权。
股票代币的 pause / block 会让官方成交路径失败，这是明确接受的外部依赖风险。

地址从环境注入，但 production release 独立固定允许的 chainId、Seaport runtime codehash / EIP-712 domain、
canonical 股票代币名单与系统接线规则；expected codehash 不可由同一环境变量覆盖，也不支持热更新。配置归一化后计算
`deploymentConfigHash`，不同 hash 的订单、SQLite 状态与 cursor 必须 namespace 隔离。启动及周期 canary
任一失败，交易接口 fail closed。

**唯一接纳的订单形状。** 官方服务只接卖单：seller = maker、buyer = taker。订单必须满足：

```text
offerer       = maker
zone          = address(0)
orderType     = PARTIAL_OPEN
startTime     = 0
zoneHash      = bytes32(0)
salt          = 客户端密码学随机、非零 uint256
conduitKey    = bytes32(0)
counter       = 签名时 maker 的当前 Seaport counter

offer.length  = 1
offer[0]      = ERC1155(canonical Warrant, seriesId, warrantAmount)
                且 startAmount == endAmount > 0

consideration[0] = ERC20(series.stockToken, makerProceeds, recipient = maker)
                    且 startAmount == endAmount > 0
consideration[1] = 仅收费 epoch 存在：
                    ERC20(series.stockToken, feeAmount, recipient = feeRecipient)
```

ERC-20 的 `identifierOrCriteria` 必须为零，`totalOriginalConsiderationItems` 必须等于实际项数。v1 不接
criteria item、多 series bundle、动态价格、额外 recipient、tip、scheduled order、bulk-order 签名、空签名或
依赖 Seaport 预先 `validate()` 的订单。EOA 可使用 pinned Seaport 接受的直接 64/65-byte EIP-712 签名；
合约钱包可使用 EIP-1271。typed-data domain 的 chainId、verifying contract、name/version 必须与经 canary
核验的 Seaport 完全一致。

客户端构造模块只接收 `{maker, seriesId, warrantAmount, makerProceeds, expiresAt}` 这一窄意图；chainId、
Seaport、Warrant、该系列的股票代币、fee epoch、fee recipient 和 conduit 均来自已验证配置，不允许调用者覆盖。客户端签
原生 Seaport typed data 后，将 `schemaVersion = 1`、`deploymentConfigHash`、`OrderParameters`、签名所用
counter 与 signature 提交到 `POST /v1/orders`。服务端不托管私钥、不代签、不增加一层平台授权，也不提供
`/orders/prepare` 会话；它必须独立规范解码、重算 order hash 并完成全部链上验证。

**有效期与手续费 epoch。** 接纳块的 canonical timestamp 必须满足：

```text
acceptedBlock.timestamp < endTime <= acceptedBlock.timestamp + 7 days
若 exerciseDeadline(seriesId) 有限：endTime <= exerciseDeadline(seriesId)
```

UI 默认建议 24 小时。服务端本地时间与 maker 的 `startTime` 均不得参与 fee 判定。`marketOpenedAt` 在开放前
固定，`feeActivatesAt = marketOpenedAt + 56 days`：此前为 0%，之后为 50 bps。收费时：

```text
feeAmount = floor(makerProceeds * 50 / 10000)
```

收费 epoch 算出零手续费的订单拒绝接纳；切换前已经接纳的零费订单 grandfathered，到自身失效为止。
fee recipient 按 epoch 固定，更换只影响新订单；生产 recipient 应为运营 Safe。客户端跨 fee 边界提交旧形状时
返回 `FEE_EPOCH_MISMATCH`，重新构造、换 salt、重新签名。官方 fee 只覆盖官方订单流，不是全局转让税。

**精确 lot 与部分成交。** 所有官方订单统一用 `fulfillAdvancedOrder()`。定义：

```text
零费：lotCount = gcd(warrantAmount, makerProceeds)
收费：lotCount = gcd(warrantAmount, makerProceeds, feeAmount)
```

要求 `lotCount <= uint120.max`。官方 fill 只生成整数 lot，`denominator = lotCount`，买方请求“最多 N lot”；
`lotCount == 1` 时只能全量成交。taker 自己付股票代币、自己收 Warrant，不允许 recipient override。服务不做链下
预留；并发导致剩余不足时允许 Seaport 自动缩量，已填满或已取消则回滚。实际成交量的唯一权威是 receipt 中的
`OrderFulfilled`，不是 prepare 响应。股票代币 allowance 默认只生成本次最多 N lot 的精确所需额。

**下架、取消与系列窗口。** 三个动作必须明确区分：

- `Delist`：maker 签 EIP-712 `Delist(chainId,seaport,orderHash)`，服务验证 EOA / EIP-1271 后写永久 tombstone；
  零 gas、只影响官方接口，同一 hash 不可恢复，重新挂单必须换 salt，且不会撤销已流出的 Seaport 签名。
- `Cancel`：maker 链上调用 Seaport 取消指定订单；服务只生成 calldata。
- `Cancel all`：maker 链上 `incrementCounter()`；会连同外部市场订单一起失效，界面必须强警告。

接纳和重验均要求系列已开启、`settled == false`、`now < exerciseDeadline(seriesId)`；deadline 有限时还要求
`order.endTime <= deadline`。active gating 时 deadline 为 `uint64.max`；解除后按
`max(expiry, clearedAt + 48h)` 收敛。`SERIES_WINDOW_CLOSED` 可随门控变化重新开放，`SERIES_SETTLED` 为终态。
“挂单/撤单零 gas”的旧说法至此作废：准确表述是“挂单/软下架零 gas；真正取消需要链上交易”。

**接纳、投影与稳定状态码。** `POST /v1/orders` 在一个 pinned latest canonical block hash 上完成全部 RPC 读取
与模拟，通过后原子接纳，不建异步 pending 队列。RPC / 链身份不一致时 fail closed；普通 reorg 回滚并重算。
同 hash 同内容返回 `IDEMPOTENT_REPLAY`，同 hash 不同内容返回 `ORDER_HASH_CONFLICT`。每个
`(deploymentConfigHash, maker, seriesId)` 最多一张可恢复、非终态官方订单。可恢复状态为：

```text
SUSPENDED_MAKER_BALANCE
SUSPENDED_MAKER_APPROVAL
SUSPENDED_MAKER_SIGNATURE
SUSPENDED_PAYMENT_TOKEN
SUSPENDED_PAYMENT_RECIPIENT
SERIES_WINDOW_CLOSED
```

终态为：

```text
DELISTED_OFFCHAIN
CANCELLED_ONCHAIN
COUNTER_INVALIDATED
ORDER_EXPIRED
FILLED
SERIES_SETTLED
```

接纳块被 reorg 且跨 fee 边界时进入 `FEE_EPOCH_INVALIDATED`。签名 counter 与 pinned block 的 maker 当前 counter
不同则返回 `COUNTER_MISMATCH`。领域响应固定为版本化 envelope，至少包含稳定 `code`、`retryable`、
`orderHash`、`observedAtBlock` 与结构化 `details`；客户端不得解析 HTTP 文本、RPC 错误字符串或 Solidity
revert 文本。

**声明策略。** OrderbookService 不读取、缓存、返回或检查 maker / taker 的 `attestedVersion`，也没有隐藏的
`REQUIRE_ATTESTATION` 开关。未声明用户仍可买卖和持有 Warrant；声明只在 `exercise()` beneficiary 路径由
ClearingPool 强制，M6 在行权前解释并引导 attest。`FILL_READY` 不代表可行权。未来法律意见若要求 OTC 设门，
必须重新版本化本决策。

**持久化与查询接口。** v1 使用 SQLite WAL、`synchronous = FULL`，每个 `deploymentConfigHash` 只有一个
active writer；不用 ORM，以普通 SQL migration + `user_version` 管 schema。uint256 存十进制字符串或 32-byte
big-endian，计算只用 BigInt，不用浮点。事实表至少包含 `orders`、`delist_tombstones`、`chain_occurrences`、
`service_cursor`；`order_projection`、`slot_claims`、active index 与 depth 都是可重建投影。最小 REST `/v1`
interface 为：

```text
GET  /v1/config
GET  /v1/health
POST /v1/orders
GET  /v1/orders/:orderHash
GET  /v1/series/:seriesId/orders
GET  /v1/series/:seriesId/depth
POST /v1/orders/:orderHash/delist
POST /v1/fills/prepare
POST /v1/cancels/prepare
POST /v1/counters/prepare
POST /v1/approvals/prepare
```

查询使用 ETag / 条件轮询，不做 GraphQL、SSE、WebSocket 或跨订单撮合。cursor 不透明并绑定
`projectionRevision`，revision 变化返回 `CURSOR_STALE`。depth 只聚合 ACTIVE 卖单，按精确约分有理数
`(makerProceeds + feeAmount) / warrantAmount` 从低到高排序；fill 必须指定一张 orderHash。成功响应必须在
SQLite 事务持久提交后返回。备份必须用 SQLite online backup / 一致性 snapshot，不能只复制 `.db` 而忽略 WAL。
生产 DB 缺失返回 `STATE_MISSING`，损坏返回 `STATE_CORRUPT`，均 fail closed，绝不自动创建空市场。

**链同步与进程模型。** 一个进程承载 HTTP、顺序 canonical block 轮询、过期处理和周期重验，全部写入经单一
SQLite writer 串行提交；文件锁阻止第二个 active writer，v1 不做 active-active、leader election 或消息队列。
同步器从 `service_cursor + 1` 逐块处理，以 `(transactionIndex, logIndex)` 排序并在同一事务提交 block header、
occurrence、投影和 cursor。它跟踪 Seaport 成交/取消/counter、Warrant Transfer/ApprovalForAll 以及会改变系列
窗口的池事件；启动和运行期间还完整重验非终态订单，以覆盖 EIP-1271、股票代币状态等无可靠事件的变化。

过期只由已处理 canonical block timestamp 驱动，`endTime <= block.timestamp` 即投影为 `ORDER_EXPIRED` 并退出
active depth；本地时钟和独立 cron 都不是权威。发现 cursor hash 不在 canonical chain 时，向前找共同祖先、
把分叉 occurrence 标为 orphaned、重放并重建投影；无法证明共同祖先时从配置起点完整重放，在恢复完成前交易
interface fail closed。启动顺序固定为配置/DB/canary → cursor 对链 → 追平 → 全量重验 → 重建 depth → ready；
关闭时先撤 readiness，再完成当前事务。`/v1/health` 区分 live/ready，并公开 `observedAtBlock`、canonical head、
lag 与最近成功 RPC。落后或恢复期间查询可返回带 `stale: true` 的旧投影，交易与 calldata prepare 接口不得放行。

---

### 6.7 回购金库 `BuybackVault`（⏳ 规划，决策 50，`v1.2` 候选）

**定位。** R7 冷启动的链上答案：每项目一只、不可升级、无 admin 的卫星，任何人存 MEME，它按规则买入价内权证并在
同一笔交易里向池子行权。它不是做市商、不保证退出、不换币、不持有权证过夜。**深度 = 注资量。**

**构造参数（全部 `immutable`）。** `vault`（该项目的 `WarrantVault`：TWAP / 现价、`taxToken`、`quoteToken`）、
`pool`、`warrant`、`attestations`、`discountBps`（起点 1000）、`feeBps`（起点 0）、`feeRecipient`。
构造函数以自身地址调用 `attestations.attest(0, termsHash, attestationHash)` —— 池子的声明门查的是受益人，
受益人是金库自己（前提见 `design.md` 决策 50-② / R17）。

**LP 记账：MEME 计份额，股票当分红。** 这是整个设计里最关键的选择，它让 LP 进出不需要任何价格。

- 存入：`shares = amount × totalShares / memeBalance`，空池 1:1。份额只按 MEME 净值定价。
- 股票：每次行权到账的股票按当时份额比例记入 `stockPerShare` 累加器；LP 各自持有 `stockDebt` 基线（MasterChef 模式）。
- 提 MEME：按份额比例，随时。
- 提股票：领取 `shares × stockPerShare − stockDebt`，**要求 `attestations.attestedVersion(msg.sender) != 0`**。
  未声明者 MEME 随时可走，股票留在金库。前端在 LP 入口明示。

**卖出时序（一笔交易）。** 卖方事先 `Warrant.setApprovalForAll(buybackVault, true)`。

1. 校验：`pool.series(seriesId)` 的 `memeToken` / `stockToken` 与本金库一致；`settled == false`；
   `block.timestamp < exerciseDeadline(seriesId)`。
2. 取价：`vault.twap()` 状态非 `TWAP_OK` 则拒；同时读现价；`p = min(twap, spot)`
   （单位：每 1e18 raw 股票的 MEME raw，与 `strike` 同单位）。
3. 内在价值 `iv = p − strike`；`iv <= 0` 则拒。
4. 报价 `quote = amount × iv / 1e18 × (10000 − discountBps) / 10000`；`quote < minMemeOut` 则拒。
5. 需求 `need = quote + amount × strike / 1e18`；余额不足则按可负担的最大 `amount` 部分成交，`filled < minFill` 则拒。
   池子的取整规则（`amount × strike >= 1e18`）由金库先行校验。
6. `warrant.safeTransferFrom(seller, this, seriesId, filled)`。
7. `meme.approve(pool, filled × strike / 1e18)`；`pool.exercise(seriesId, filled, address(this))` ——
   池子从金库销毁权证、从金库扣 MEME 烧毁、股票到金库。任何 revert 整笔回滚。
8. `meme.transfer(seller, quote − fee)`；`fee` 付 `feeRecipient`。
9. `stockPerShare += filled × 1e18 / totalShares`。

**代卖入口。** `sellFor(seller, seriesId, amount, minMemeOut, minFill)`：`msg.sender == seller` 或
`warrant.isApprovedForAll(seller, msg.sender)`；MEME 永远付给 `seller`。常设指令（§6.8）与 keeper 代付 gas 走这一个口。

**不变量。**

| # | 陈述 |
|---|---|
| B1 | 任何交易结束时 `warrant.balanceOf(this, id) == 0`，对所有 `id` |
| B2 | 单笔 `quote + 烧毁 MEME ≤ 交易前 MEME 余额` |
| B3 | `Σ 未领取股票 == stock.balanceOf(this)` |
| B4 | 股票只转给 `attestedVersion != 0` 的地址 |
| B5 | 无 admin、无暂停、无提款路径；无 `selfdestruct`、无代理 |

**失败模式。**

| 情形 | 行为 | 对外表述 |
|---|---|---|
| 发行方门控（冻结 / 暂停） | `exercise` revert → `sell` revert；池子顺延行权窗口，金库自动跟随 | 「行权可行时买单在」，不是「随时」 |
| TWAP 状态非 OK | 拒 | 采样断档期间无买单 |
| 尾盘拉 MEME 使 TWAP 假价内 | `min(twap, spot)` 挡掉单窗口内的拉抬；持续超过 24h 的操纵由 LP 承担 | LP 风险，与 strike 操纵面同源（对比文档 §2.8） |
| 发行方冻结金库地址 | 股票卡在金库；MEME 仍可提 | 与 R2 同族 |
| 发行方 `adminBurn` 金库持股 | B3 按实际余额重算，LP 按比例承担 | R2b |
| MEME 对钱包↔合约转账抽税 | **整套设计不成立**；主网分叉复核为部署前置（§14-14） | — |

**参数起点。** `discountBps = 1000`；取价 `min(twap, spot)`；`feeBps = 0`（槽位保留，与 OTC 56 天零费对齐）；
无单日买入上限。定值见 §14-14。

**经济直觉。** 系列开启价内 20%，折扣 10%：金库对一张新权证出价 ≈ `0.18p`，加行权价 `0.8p` 共付 `0.98p` 换一股，
比 TWAP 低 2%；越深价内折扣绝对值越大。LP 的结构性头寸是**多股票 / 空 MEME**，与权证对冲方向一致 ——
天然 LP：想折价换股的 MEME 持有者、项目方、我们自己。

**部署与发现。** launcher 不可升级，不能在发币那笔顺带部署；发币后单独一笔，任何人可部署。官方地址由前端
`app-config` 钉死并在 Interface Bundle 里发布；不设链上注册表。

**与 M5 的关系。** 金库是簿外的地板价；官方订单簿的卖单价格应高于它。这条出口不经过 taker fee（§6.6.1），
收入模型的影响记入 `design.md` 决策 50-⑧。**对 R13**：金库拉高行权参与率 `f`，直接缩小 `S/f` 的池内沉淀。

### 6.8 常设指令 `StandingOrder` 卫星（⏳ 规划，决策 51，细节待收口）

**池子不变。** `exercise()` 的调用方门（受益人本人或 distributor）与 `claimAndExercise()` 的 `NotAccount` 门
原样保留 —— 它们挡的是第三方择时，常设指令不能成为放松它们的理由。

**做法。** 卫星以自身为受益人向池子行权，再把股票转给用户。用户一次性：自签声明、
`Warrant.setApprovalForAll(standingOrder, true)`、`MEME.approve(standingOrder, …)`、写一条规则。
领取仍走无许可 `claim()`（keeper 代付）。

**规则约束（🔴 硬性）。** 确定性、任何人可触发、执行窗口固定（起点：到期前 6 小时内且 `vault.twap()` 价内）；
触发者只付 gas，拿不到任何东西；卫星行权到某用户前检查 `attestedVersion(user) != 0`。

**三种指令。** ① 价内行权（卫星 pull 权证 + MEME → `pool.exercise(id, amt, this)` → 股票转用户）；
② 卖给回购金库（走 §6.7 `sellFor`，MEME 付给用户）；③ 放过 —— 默认，不需要卫星。

**代价与待定。** `Exercised.beneficiary` 为卫星，逐人归属退到卫星事件（M4 是否收编待定）；MEME 对卫星是常设授权，
卫星必须不可升级、无 admin；与 Seaport 挂单冲突（卫星拉走权证使卖单成交失败）由前端提示。
前提同 §6.7（决策 50-② / R17）。

## 7. 不变量与测试

**七条均已写成 Foundry invariant / invariant-style 测试并随 M1 交付。**

| # | 不变量 | 断言 |
|---|---|---|
| 1 | 抵押充足（**2026-08-09 重述**） | ①`∀ **未结算** series：minted − exercised ≤ stock.balanceOf(pool) 中归属该 series 的部分`；②全局：`Σ_未结算(minted − exercised) + Σ remainder ≤ stock.balanceOf(pool)` |
| 2 | 铸造量守恒 | 每次 `depositAndMint` 后 `minted` 增量 == 池内该股票余额增量 |
| 3 | 行权原子性 | 任一子步骤 revert ⟹ 权证与 MEME 余额均不变；成功 ⟹ 权证 / MEME / 股票三条腿一起按量变动，且 beneficiary 的 MEME 与池子的股票实际扣款分别恰好等于 `memeAmount` / `amount` |
| 4 | **结算后不可行权；无门控时结算不可阻止**（2026-08-09 改写，原文"到期后不可行权"） | ① `settled ⟹ exercise() revert`；② 实时无门控且 `now ≥ max(expiry, clearedAt + 48h)` ⟹ `settleExpired()` 必然成功（🔴 两者须取**同一次**观测：记录陈旧时结算会当场自愈并重新起算宽限，见 §5.1 实现收口 ⑤）；③ **`clearedAt` 只随边变化** —— 对已观测为干净的股票再调 `pokeGating`，无论调多少次、谁来调，`clearedAt` 必须不变。**没有 ③，② 是空的**：能推动 `clearedAt` 的攻击者只需让 ② 的前提永不成立，即可永久阻止结算 |
| 5 | 无管理员出口 | ClearingPool 无任何函数可在 `minted > exercised` 时把抵押品**转出本合约**；`rollExpired` 是池内重新归属，不构成转出 |
| 6 | **声明门不可锁死** | ①`attestedVersion[a]` 对任意 `a` **单调不减**；②仅 `a` 自身可改 `attestedVersion[a]`；③`versions[0]` 存在且不可变 ⟹ **任意地址恒可通过 `attest(0,…)` 满足行权门槛** |
| 7 | **滚存守恒**（2026-08-09 新增） | `rollExpired` 前后池内股票余额不变；`remainder` 减少量 == 后继系列 `deposited` / `minted` 增量 == 新铸权证量 |

> 不变量 6 是本项目**唯一**用于证明"新增的合规门不会变成资产冻结开关"的手段，与不变量 5 同级重要，**不得省略**。

**必做的 fork 测试**（Robinhood 主网分叉）：
- 真实 GME 合约下的完整 deposit → mint → exercise 路径
- **模拟发行方 `pause()` 后行权应干净 revert，且用户权证不丢失**
- **销毁路径**：真实 `FlapTaxTokenV3` 上 `transferFrom(user, 0xdead, X)` 实收必须**恰好等于 X**。
  🔴 这条没有合约层的守卫 —— 池子刻意不核对 `0xdead` 的余额增量（§5.1 收口 ④），所以退化会是**无声**的
- **两层外部依赖守卫**：固定区块套件保存可复现证据；独立 latest canary 核对当前 GME beacon、Flap 新发币选择链（Portal implementation → immutable launcher → immutable 的受支持 token implementation）、三份 runtime codehash，并在现场新发的 GME 计价 V3 代币上实测 `transfer` / `transferFrom → 0xdead`。两层都以 `FORK_REQUIRED=true` 运行 Forge，RPC 或所需历史状态不可用必须失败，不得以 `vm.skip` 产出绿勾；只有固定区块套件是 required PR 门禁
- **门控延期全路径**：pause → `pokeGating` → 过 expiry 后行权窗口仍开（若发行方仍禁转，`exercise` 整笔回滚且权证 / MEME 不动）→ 解除后行权立刻成功（**不需要先 poke**）→ 观测到解除把窗口收敛为 `max(expiry, clearedAt + 48h)`，该截止前行权仍成功 → 该截止后 `settleExpired` 成功；另测未 poke 时无延期、`settleExpired` 自愈陈旧观测
- 🔴 **结算阻断攻击**：攻击者对干净股票反复调 `pokeGating`（含临近截止时刻、跨多个区块循环）—— `clearedAt` 必须不动，`settleExpired` 必须按期成功（不变量 4③）
- 🔴 **fail-open 宽限**：令门控 view revert → 48h 内不得结算 → 之后必须可结算；窗口内再次观测到 revert **不得重新盖 `clearedAt`**
- **`rollExpired` 全路径**：settle → roll → 不变量 1 / 7 成立；无后继系列时 roll 干净 revert、开出新系列后可恢复；**已结算的前序系列正因被排除在 1① 之外才成立** —— 跨滚存须断言全局形式 1②
- **`claimAndExercise` 路径**：两笔完成；非 `account` 本人调用被拒；**未声明的 `account` 在 distributor 路径下同样被拒**（声明门查受益人）
- 🔴 **`claimAndExercise` 重放**：同一份 proof 第二次提交必须 revert；`claimAndExercise` 后再 `claim`（及反向）同样必须 revert —— **断言 distributor 的权证余额永不低于全部未领取 leaf 之和**
- 模拟 `uiMultiplier` 变更后账目仍然自洽
- Flap dispatch → `receive()` ping → `processRevenue()` 全链路。**M2-3 已交付后半段**
  （`test/fork/RobinhoodWarrantVault.t.sol`）：真实 GME 上 `processRevenue → depositAndMint → 铸造` 跑通，
  并在**真实金库**下重跑 M1 的不变量 1 / 2（此前它们只在 `VaultStub` 下验证过），
  判据复用 `test/invariant/` 的同一份 `CollateralCheck`；另有两条断言发行方**全局暂停**与
  **封禁池地址**期间存入干净失败（钱、基线、授权三样一个不动）、解除后重跑即恢复。
  历史上的 M2-5 Factory fork 路径保留真实 VaultPortal -> Factory 回调 / 绑定形状的证据，说明为何该路径被
  放弃；它**不是**生产发射路径。真实模板下 native 会在金库**构造函数**里回滚，GME 则在调用 Factory **之前**
  被 VaultPortal 拒绝。生产 D0 则由 `WarrantLauncher` 调普通 Portal、经 Factory 建金库，并在同一笔交易写绑定。
- **publisher 追加新版本文本后，旧版本声明者仍可正常行权**（追加不得追溯失效）

---

## 8. 权限矩阵

| 函数 | 调用者 | 说明 |
|---|---|---|
| `pool.openSeries` | **仅该 MEME 在身份根里登记的金库**（`vaultRegistry.vaultOf(memeToken)`，非零；M2-5 / issue #37，见 §4.2） | 一次性，strike 之后不可改；名册由身份根那张 **2 格写入方名单**写下（今天第 1 格 `WarrantLauncher` 是唯一启用的写入方，第 2 格是未启用的 `PendingLauncherSlot`；M2-6① / issue #56）。Factory 只建金库，不在名单中 |
| `pool.depositAndMint` | 该系列的 vault | — |
| `pool.exercise` | **beneficiary 本人，或 distributor**（`claimAndExercise` 代路径） | MEME 从 beneficiary 拉取、声明门查 beneficiary；限定调用方防第三方强制择时 |
| `pool.pokeGating` | **任何人** | Monitor 保底触发；观测记录驱动门控延期 |
| `pool.settleExpired` | **任何人** | 惰性；门控命中时被结构性阻止（= 自动延期） |
| `pool.rollExpired` | **任何人** | 池内滚存，校验自证合法 |
| `distributor.claim` | **任何人**（代提交 proof） | 权证只进 leaf 指定的 `account`；keeper 可代付 gas |
| `distributor.claimAndExercise` | **仅 `account` 本人** | 行权花的是 account 的 MEME，不可代为择时 |
| `vault.sampleTwap` | **任何人**（M2-2 已落地） | Trigger Service 只是通常的调度者，未引入角色或 Guardian 钥匙；其无许可的显式取舍是有界、严格 24 小时的离散 TWAP。 |
| `vault.processRevenue` | **任何人**（M2-3 已落地，见 §6.3） | 🔴 无许可是刻意的：一个守门人就是本金库的第一个权限函数，而零权限面是「金库拿不走钱」的最短证明（design §10-33 / §10-36）。调用方改不了钱的去向 —— `pool` / `merkleDistributor` / `creator` 都是金库的 `immutable`（决策 49 起分成去向同样构造期定死）。 |
| `vault.claimCreatorFee` | **任何人**（决策 49） | 无许可与其余五个入口同一条理由：收款人是构造时定死的 `creator`，calldata 一个字节都改不了它 —— 抢跑触发对 creator 无害（钱还是他的），加一道 `msg.sender == creator` 的门换不来任何安全收益，却会打破「没有一个是权限函数」。零累计时静默 no-op。 |
| `vault.openSeries` | **任何人**（M2-4 已落地） | 无入参：strike 由环形缓冲决定、expiry 由日历决定，调用方挑不了任何参数。挑得动的只有**时刻**，由 §6.2 的 24 小时窗口压住。若将来改接 Trigger Service 的 `trigger(uint256)` 回调（rule 008 要求校验调用方），那将是本金库的第一个权限函数 —— 零权限面就此作废，须在 `design.md` §10 记一笔。 |
| `distributor.setRoot` | `MerkleDistributor.publisher`（我们的 publisher key，与注册表那把**可以不同**） | 🔴 唯一的中心化信任点。该系列第一张 leaf 被消费之后 root 永久冻结，此后连它也改不了 |
| `registry.attest` | **任何人，但只能写自己** | 单调**不减**（取大，不是严格递增 —— 见 §5.5）；**无人可撤销他人声明，publisher 也不能** |
| `registry.addVersion` | 我们的 publisher key | **只能 append**；不影响任何既有声明，**无法用于阻断行权** |
| `vaultRegistry.bind` | **仅构造期钉死的 2 格写入方名单**（`isFactory`；M2-6① / issue #56） | 名单无 setter、无 admin；两格共用同一张 `memeToken → vault`，每只 MEME 全生命周期仍只写得进一次 |
| `pendingLauncherSlot.bind` | **仅已启用的那个 launcher**（未启用时**没有人**） | 纯转发；未启用之前对任何调用者 fail-closed —— 与未绑定的卫星合约同一条形状 |
| `pendingLauncherSlot.setRegistry` / `setLauncher` | 部署者 | 各自**仅一次、写后永久锁死**（与决策 29 的三处 `setPool` / `setRegistry` / `setBeacon` 同构）。🔴 `setLauncher` 是把一条新的绑定路径接进信任基的那一刻：必须公示新 launcher 的源码与地址，`LauncherSet` 事件由巡检盯着（`LAUNCHER_ARMED`，见 §9） |

---

## 9. 链下服务

> 📝 **2026-08-17（issue #68）：「Trigger Service」在下表里换了主语。**
> 本节原先写的是 **Flap 的** Trigger Service（`0xD3421B…`）—— 那是一个我们不控制的
> 中心化后端，本表把它当成既有基建。决策 39（issue #58）之后金库不再继承任何 Flap 基类、
> 不再是 Flap 规范金库，那个后端**不会来敲我们的门**。
>
> 于是这三下节拍从一件「别人替我们做、我们盯着」的事，变成了**我们自己的运营责任**。
> 实现是 [`script/trigger-keeper.sh`](../script/trigger-keeper.sh)，宿主 VPS + systemd timer
> （issue #69 决策 ①）。下表 **Series Opener** 与 **TWAP Sampler** 两行的「关键要求」
> **一个字都没改** —— 判据本来就写的是链上读数，换了谁来触发都成立。
>
> 🔴 只有一处的说法要更正：TWAP Sampler 那行的「每小时触发」是**错的形状**。
> `SAMPLE_INTERVAL`（1 小时）与 `MAX_SAMPLE_GAP`（65 分钟）之差只有 5 分钟余量，
> 每小时跑一次意味着一次失败就必破上限。正确的形状是**每 90 秒轮询、由合约自己挡**；
> 保守上界为 `3600 + 2 * (90 + AccuracySec 5) + 85 = 3875 < 3900` 秒，
> 推导见 `script/trigger-keeper.sh` 头部与 README「为什么 90 秒」。

| 服务 | 职责 | 关键要求 |
|---|---|---|
| **Indexer / entitlement pipeline** | 从已验证的 canonical journal 重放，重建 MEME 余额与协议角色，计算每系列一次的整段 TWAB 归属，并投影已发布 proof | ✅ **#91～#96 已在 `offchain/entitlement/` 实现并测试**：canonical replay、严格 calculation v1、确定性复算、sealed immutable bundle、reorg-aware publication catalog、只读 Proof API/HTTP adapter，以及带 finality / 链身份 / live publication snapshot 核验的 publisher handoff。`offchain/merkle/` 仍是公开的 root/proof 实现。第三方仍可将 `cast call <distributor> 'roots(uint256)(bytes32)' <seriesId>` 与 `node offchain/merkle/verify-root.js --input <list> --root <root>` 对照，或审计 sealed by-root bundle。`offchain/entitlement/proof-runtime.js` 提供冻结的 `/v1` 只读路由，并已部署用于可重置的 Core staging 验收。常驻生产 Indexer 与 HTTP server 仍未部署；`setRoot` 不自动广播 |
| **OrderbookService** | 接纳规范 Seaport 卖单、按系列聚合精确深度、跟踪成交/取消/reorg、准备 fill/cancel/approval calldata | M5-0 口径见 §6.6.1；订单仅为签名，**不托管资产**，M5 不新增结算合约 |
| **Series Opener** | 我们的 Trigger Service 每 15 分钟查询 `openSeriesStatus()`，为 `0` 时触发 `openSeries()` | 🔴 **判据读链上**：返回 `1` 才算本期开出来了，不是「我们的服务以为自己开过了」。返回 `0` 是最要紧的一档（本该开、能开、却没开）；`3` 要接着读 `twap()` 定位采样链路故障。该函数**无许可**且日常空跑不 revert，所以重试与 15 分钟轮询都安全（§6.2、issue #42） |
| **TWAP Sampler** | 我们的 Trigger Service 每 90 秒轮询 `sampleTwap()`；合约距上次样本满一小时才真正写入 | 不能只满足一小时最小写入间隔，还须维持 65 分钟最大 gap。对 `TwapSampleFailed(reason)`、`lastSampleAt()` 与 gap 状态告警；恢复需重建新鲜的严格 24 小时窗口（通常为连续 25 个观测点）。🔴 该函数**无许可**，后端挂了任何人可顶上，但也意味着任何人可挑采样时刻 —— Monitor 应同时盯 `TwapSampled` 的时刻分布（§5.2） |
| **Monitor** | ① 监控发行方注册表的 `isBlocked` / `paused` / `adminBurn` 事件；② 对已开系列的股票代币**保底触发** `pool.pokeGating`（合约只信记录在案的观测，见 §5.1 / §8）；③ 每日核对每个项目**是否仍有系列按期开出**（发行停发，issue #42） | 🔴 ①命中即公告，见 §11；②是运营刚性职责，但无许可，任何持有人都能自己调；③见 §9.1 |
| **Monitor（税收去向）** | 监听 Flap Portal 的 `MarketWalletChanged`。**记录全部代币，只对我们的告警** —— 别人的代币被改道是这条风险变活跃的前兆，值得记，但不是我们的告警 | 实现 `script/watch-market-wallet.sh`，入口 `script/monitor.sh tax`（🔴 **2026-08-17 起本仓库不用 GitHub Actions**：这些巡检改为按需跑（`script/monitor.sh`），没有调度器 —— 「有没有人想起来跑」成了新的静默失效点，见 README「守夜」一节。）。🔴 **两个探针都要读，并且要对一遍**：日志面（Portal 的事件）给出历史，状态面（`token.taxProcessor().marketAddress()`）给出此刻；只读日志会漏掉「改了状态却不发事件」的路径，只读状态看不见别人的代币。两面对不上本身就是头等告警。台账 `monitoring/market-wallet-<chainId>.jsonl` 进版本库当已知阳性 —— 否则「扫不出东西」与「监测器坏了」无法区分。完整判定还必须有经独立、人工复核的 `monitoring/vault-bound-<chainId>.jsonl` 作为 `VaultBound` 基线，并与链上日志双向对账。身份根和该基线提交前，工作流只能用 `--record-only`：有新事件时退出 `2`（无结论），绝不把它当作别人的代币后给 `0` |
| **Monitor（预留写入位）** | 对账身份根第 2 格的 `launcher()` 当前状态与一次性 `LauncherSet` 历史（M2-6① / issue #56，决策 39-D） | `script/series-monitor.sh` 把 slot 的两个读取和事件查询固定在同一观测链头 `H`。清单填写 `pendingLauncherSlotFromBlock` 后扫描 `[fromBlock, H]`：零状态必须对应零事件；非零状态必须对应唯一一条、且 launcher 相同的事件；并核对 `factories()[1]` 与 slot 的 `registry()` 都接回已验证的 pool `vaultRegistry()`。缺历史起点、RPC 不可读或任一不一致都是告警，不是健康。非零匹配仍以 `LAUNCHER_ARMED:<slot>` 告警，直到 roster 中四字段 `pendingLauncherSlotAcknowledgement` 与链上证据逐项重验一致，才输出 `resolves:true` 让 `deliver-findings.sh` 关旧单。字段与操作见 `monitoring/README.md`、`docs/series-monitor-runbook.zh.md`；一次性事件未确认前**不要手动关 issue**。|

### 9.1 发行停发监测（issue #42）

「这周的系列没开出来」在此之前**只能靠有人注意到本周没有权证**发现 —— 从后果反推原因，
而且要等用户开口。金库运营方掉线、Trigger Service 没触发、TWAP 采样不足、身份根接线错、
上游价源 / 池状态漂移、部署顺序出错，六种原因没有一种会自己浮出来。

② 与 ③ 是**同一个链下服务的两项职责**，都由「按期没发生的事」构成，所以写在一起。

实现：[`script/series-monitor.sh`](../script/series-monitor.sh)（判定）＋
[`.github/workflows/scripts/deliver-findings.sh`](../.github/workflows/scripts/deliver-findings.sh)（交付）
＋ [`monitoring/series-roster.json`](../monitoring/series-roster.json)（项目清单）。
处置见 [`series-monitor-runbook.zh.md`](./series-monitor-runbook.zh.md)。

| 约束 | 说明 |
|---|---|
| 🔴 判据取**链上 `Series` 记录** | `pool.seriesIdOf(meme, stock, expiry)` → `pool.series(id)`，核对 `vault` / `memeToken` / `stockToken` / `strike ≠ 0` / `settled == false` 全部相符才算数。**不是**「我们的服务以为自己开过了」；`SeriesOpened` 日志只用来发现候选到期日，不用来下结论 |
| 🔴 **不假定周五 21:00** | 池子把 `expiry` 当成不透明的 `uint64`，既不校验也不解释它（§4.1）。所以巡检读链上 `Series.expiry`，项目清单只提供一个**时长** `periodSeconds`。清单若去预测具体秒数，一旦金库的 ≥7 天寿命规则把到期推到下一个周五，`seriesId = keccak(meme, stock, expiry)` 差一秒就是另一个系列 —— 每个健康的周都会被判成停发 |
| 两个判据 | **周期**：距最近一次成功开系列是否超过 `periodSeconds + graceSeconds`（回答「本周期开出来了吗」）；**覆盖**：此刻是否还有未结算、未过期的系列（回答「钱会不会正卡在金库里」）。后者决定严重级 |
| 🔴 远期到期不得压住判定 | 到期超过项目清单 `maxSeriesSeconds`（一个系列**最长能活多久**，与「多久开一次」是两个量）的**不计入覆盖**，且本身就是一条告警。⚠️ 这道闸门只对**我们自己金库开出的**系列生效 —— `openSeries` 写的是 `s.vault = msg.sender`，别人开的远期系列根本进不了覆盖计算。它挡的是我们自己把到期算错 |
| 🔴 严重级不挂在「有没有钱」上 | 「本周期没开出新系列」**本身就是 alert** —— 那正是本节的原问题。`inTransit()` 只用来**升级**。唯一的降级是「周期没到点、只是覆盖用完、且确认在途为精确的 0」，那多半是一个已经收摊的项目 |
| 🔴 「已恢复」要有正面证据 | 周期判据在日志读不到、或提供方不给 `blockTimestamp`（Robinhood Chain 实测**恒为 `0x0`**，回头 `cast block` 也问不到）时是**未知**的。此时既不报健康，也不发「已恢复」去关单 —— 否则一次 `eth_getLogs` 抖动就能给一个停了三个月的项目留言「已恢复」 |
| 告警要带**下一步该看哪里** | 当前模拟能跑通只说明**现在**可跑，不能证明历史上有人或没人调用；模拟回滚要附**原始 revert 数据**和已知选择器的本地解读，但没有调用 trace 时来源仍是**未定**，不得归因给池子。`RevenueDeferred` 只证明有人调用过无权限的 `processRevenue()` 且该调用被延期，不能识别调用者。身份根的可验证线索仍是 `vaultOf` 与金库不符。当前金库签名是 `openSeries()(uint256,bool)`；`triggerSignature: null` 只适用于未部署/未启用占位项，且会使触发模拟报为**未能判定** |
| TWAP 那一条成因是**链上可读**的 | M2-2（#34）之后 `vault.twap()` 把失败当返回值交出来而不 revert，所以「环形缓冲采样不足、strike 算不出来」这条成因不必靠人去翻 keeper 日志 —— 巡检直接把 status 翻译成人话贴进告警（`keeper 停了` / `keeper 漏了心跳` / `环没填满` …），并点明 **strike 算不出来时开系列必然被拒** |
| 🔴 身份根未接线 ≠ 身份根故障 | 当前 `ClearingPool` 构造函数钉死包含 `vaultRegistry` 在内的四个依赖，`openSeries` 会用 `vaultRegistry.vaultOf(memeToken)` 校验 `msg.sender`（#36 / #37 已落地）。巡检读真实 ABI `pool.vaultRegistry()`；该值缺失、不可读或与清单不符，都是运行级告警 `MISWIRED`（§12：接线错了同样表现为「永远开不出系列」） |
| 告警必须带 `inTransit()` | R4 的残余敞口以这个数计量（`design.md` R4）。`(0, false)` 是**读不出来**，不是没有钱 —— 单独按高优先级处理 |
| 心跳 | 🔴 一个永远不告警的告警器与没有告警器无法区分。心跳收据是一张**常开 issue**，每轮都用**和告警完全同一条 `gh` 路径**重写：`gh` 一坏整轮就红，不会安静报绿。巡检带着上一轮收据跑时会先读 `lastRunAt`，超过 `maxSilenceSeconds` 单独告警。🔴 **但 `script/monitor.sh` 刻意不传 `--prev-receipt`**：按需跑的间隔本来就不规律，留着它只会每次报假告警 —— 代价是「巡检自己不跑了」这件事现在没有任何东西会告诉你。🔴 **2026-08-17 起本仓库不用 GitHub Actions**：这些巡检改为按需跑（`script/monitor.sh`），没有调度器 —— 「有没有人想起来跑」成了新的静默失效点，见 README「守夜」一节。 |
| fail-closed | chain id 对不上、清算池无代码、链头时间戳跑偏、链头回退、清单缺字段 / 条数对不上 / 有重复 —— 一律**拒判整轮**并告警，绝不报绿。绿灯必须证明自己**真的读过链**（`readsSucceeded` 进收据） |
| 不在范围内 | 自动补救（自动重开系列）。**先做看得见，再谈自动做。** 巡检只 `cast call`，永不广播 |

📝 **2026-08-14**：本节新增。§9 原先的 Monitor 一行只写了发行方事件，`pokeGating` 的保底触发职责
散在 §5.1 / §6.5 / §8 / §11，这里一并收进来 —— 两者都是「按期没发生的事」，同一个服务、同一条告警链路。
issue **#35**（收入路径）的告警复用同一个交付端：新写一个 producer 往同一份 `findings.json` 里塞
`kind` 不同的记录即可，交付端一行不改。

---

## 10. 前端模块

[`frontend-integration-v1.zh.md`](./frontend-integration-v1.zh.md) 是 `v1.0.0 Core` 的权威前端接口规格。
Core 只包含 M0～M4：前端直接使用经 hash 核验的 `app-config.json`、deployment manifest、Interface Bundle、
JSON-RPC / 钱包与只读 M4 Proof API；不新增 BFF、Core REST API 或项目 Indexer API。专属 staging 是
`chainId == 31337` 的 Robinhood 主网分叉，可重置、可预置 fixture，且不复用 #69/M4 生产证据链。

OTC 在 `v1.0.0` 必须关闭，生产不得显示 mock 订单；M5 OrderbookService 与 Seaport UI 在
`v1.1.0 Market` 才启用。`v1.0.0-rc` 可先供前端集成，但生产 `v1.0.0` 仍等待 #69、#87、#102、
法律文本、生产参数与部署门禁。

| 模块 | 内容 |
|---|---|
| **发射** | 参数表单 → **链下挖 vanity salt** → `WarrantLauncher.launch(...)`；固定经济参数不在表单里（它们固化在 launcher 的字节码里，见 §6.1），但尚未定值的 `antiFarmerDuration` 仍是表单参数（§14-2） |
| **项目页** | 金库累计买入、权证发放量、当前 2 个活跃系列、到期倒计时 |
| **我的权证** | 可领取 / 已持有、内在价值、一键行权；**首次行权前插入声明步骤** |
| **合规声明** | 展示 TERMS + ATTESTATION **两段全文**（非折叠、非默认勾选），签署后写入 registry。**仅在行权路径出现** |
| **OTC 市场** | **`v1.0.0 Core` 关闭**；`v1.1.0 Market` 才提供挂单 / 吃单 / 深度图，且按 M5 冻结口径**不设声明门** |
| **到期日历** | 每周五事件（社区内容节奏） |

**声明界面的硬性要求**：文本必须**完整可读**（不得折叠或仅给链接）；哈希必须与链上 `versions[v]` 一致并**显示给用户核对**；前端要求最新版本，但须说明**链上只要求 ≥1 次**，用户可自行用旧版本行权。

**核心触点是到账通知**，三个动作必须并列：

```
Your weekly tax just minted you 142 GME Warrants
Expiry: 7 days · Strike: 1,850 $MEME per GME

[ Exercise Now ]  [ View Warrant ]  [ Sell on Market ]
```

权证详情页必须写明它**不是**什么：*"This is not the stock. It is the right to buy the stock token — itself the issuer's price tracker, not a share."*

**所有数量显示乘 `uiMultiplier()`**，内部一律 raw。

---

## 11. 错误处理与降级

| 场景 | 表现 | 处理 |
|---|---|---|
| 发行方**冻结**池地址 | `exercise` 的转出步骤 revert | 全笔回滚，权证与 MEME 保留；**自动延期 = 门控感知结算**（§5.1）：Monitor / 任何人 `pokeGating` 留观测 → 门控中 `settleExpired` 被阻止、行权窗口保持开放（但转账仍会被发行方拒绝）→ 解除后行权立刻恢复（不必等 poke），观测到解除后截止为 `max(expiry, clearedAt + 48h)`；前端明示原因并公告 |
| 发行方**暂停**代币 | 同上 | 同上 |
| 门控发生但**无人 poke** | 延期未生效，届时可被正常结算 | 合约只信记录在案的观测——Monitor 的 poke 是运营刚性职责，命中事件即调；任何持有人亦可自行 poke |
| 发行方升级**改掉门控 view 接口** | `pokeGating` 内部读取 revert | **fail-open**（按无门控处理，避免结算/回收永久死锁）并写入 `clearedAt`，截止按 `max(expiry, clearedAt + 48h)` 计算（§5.1）。🔴 **用户侧后果须直说**：若此时代币确实处于暂停而 view 读不通，行权失败、该截止后结算照常推进 —— **持有人会失去自己根本无从行权的权证**。宽限最多只买 48 小时的人工反应时间，除此之外链上无补救 |
| 🔴 发行方**只封某个持有人**（非池地址） | 该用户 `exercise` 在第 3 步 revert；`pokeGating` 看到池子干净，**不触发延期** | **刻意如此** —— 一个地址被封不该让全系列延期。但损失真实且不可挽回：结算时这些权证作废，对应抵押品滚给**其他**持有人。前端须检测 `isBlocked(user)` 并明确告知原因，而不是抛一个裸 revert；该用户唯一的自救路径是**把权证卖掉**（ERC-1155 的 Seaport 转让不受股票代币封禁影响），前端必须把这条路指出来 |
| 🔴 发行方 **`adminBurn`** 池内持仓 | 抵押品直接减少，不变量 1 被外力打破 | **无技术手段可防**。Monitor 命中即公告；风险条款须提前明示 |
| ~~系列三元组**被抢注**~~ ✅ **结构上已消除**（M2-5 / issue #37） | 陌生地址调 `pool.openSeries` 收到 `NotRegisteredVault(memeToken, caller, vault)`；那只 MEME 的系列只有身份根登记在案的金库开得出来（§4.2） | 唯一启用的写入方 `WarrantLauncher` 只能把自己那次普通 `Portal.newTokenV6` 返回的代币在同一笔交易里绑定，对已存在的 MEME **没有补登记入口**。剩下的失败形态只有：**我们自己**没按期开系列（运营停发），或该 MEME 根本不是通过 launcher 发射（`vault == address(0)`）。前端与 Indexer 仍一律读链上 `expiry`，**不得假定周五 21:00** |
| TWAP 样本 gap / stale / 窗口过短 | `twap()` 返回非零 ⟹ `openSeries()` **fail-closed**，当周停发而不是定错价 | 告警并恢复无许可采样；不可把旧的离散 spot 当连续历史。停发本身由 `openSeriesStatus()` 返回 `3` 交给链下（§6.2、issue #42）。 |
| V2 池子在采样块内更新 | `sampleTwap()` 发 `TwapSampleFailed(POOL_UPDATED_THIS_BLOCK)`，不写样本 | 下一块重试。这只移除了直接的同块储备快照路径，**不是**累计预言机或一般性的 V2 抗操纵防御。 |
| `uiMultiplier` 变更 | 显示值跳变，raw 账目不变 | 前端在 `effectiveAt` 前后加提示；铸造与行权设保护窗口 |
| Trigger Service 失效 | 当日未铸造 | 资金留在金库滚入下一轮；任何人可手动触发 |
| Merkle root 未发布 | 用户暂时无法领取 | 权证已铸在 distributor，root 补发后可追溯领取 |
| Seaport 订单失效或投影落后 | prepare fail closed，或广播后因并发状态变化而 revert | 服务按 pinned canonical block 重验；响应带稳定状态码与 `observedAtBlock`，最终成交量只认 receipt 的 `OrderFulfilled`（§6.6.1） |
| **用户未签署声明** | `exercise` 在第 0 步 revert | 前端预检 `attestedVersion` 并引导签署（一次性）；**卖出路径不受影响** |
| **我们的前端下线** | 用户无法从 UI 签署 | 两段文本与哈希须在 `research/` 与合约事件中永久可查，**用户可直接调 `attest()`**；这是"门不可锁死"的兜底 |

---

## 12. 部署顺序

**循环依赖用一次性绑定解开，不用 CREATE2**（2026-08-09 定案，关闭 §14-7；2026-08-13 金库身份根落定后扩成两个环，形状同构）。

两个构造环都**单靠排序解不开**：CREATE2 地址由 init code 推导，**而 init code 包含构造参数**，所以当 A 的构造参数依赖 B、B 的又依赖 A 时，谁的地址都无法预计算。

- **卫星环**（决策 29）：`Warrant → pool`、`MerkleDistributor → pool`、`pool → {warrant, distributor, attestations, vaultRegistry}`
- **身份根接线**（决策 34 / 38 / 39-D）：`registry → 写入方名单（2 格）`、`pool → registry`、`两个写入方 → registry`；这是一次性配置关系，不是双方构造函数互相依赖

```
1. WarrantVaultFactory(flapPortal) ── 取价用的 Flap Portal 是构造参数（决策 39-A2），它不在环里
2. WarrantLauncher(flapPortal, factory, commissionReceiver)
                                ── 🔴 D0 的编排层（决策 40 / issue #57）。它是身份根名单的**第 1 格**；
                                   工厂必须先于它存在（工厂是它的 immutable 构造参数）。
                                   同一个 `flapPortal` 在这里是**建币入口**，在第 1 步是**取价来源**
3. PendingLauncherSlot()     ── 构造无参；身份根名单第 2 格的占位人（决策 39-D）
4. VaultRegistry(launcher, slot) ── 名单两格都是真 immutable、无 setter；对外可写函数恰好一个（bind）
5. AttestationRegistry       ── 无依赖；version 0 的两个哈希是**构造参数**（见 §5.5 的修订说明）
6. Warrant (ERC-1155)        ── 构造函数无参
7. MerkleDistributor         ── constructor(publisher) —— 发布归属 root 的地址，immutable（见 §5.4 ③）
8. ClearingPool              ── 不可升级，一次部署定终身
                                constructor(warrant, distributor, attestations, vaultRegistry)
                                —— 四个都是真 immutable
9. Warrant.setPool(pool)            ── 一次性、仅部署者、写后永久锁死
   MerkleDistributor.setPool(pool)  ── 同上
   launcher.setRegistry(vaultRegistry) ── 同上，身份根环的最后一步
   slot.setRegistry(vaultRegistry)     ── 同上，第 2 格那一头
10. factory.setVaultTargets(pool, distributor) ── 同上，工厂的一次性槽之一：
    ── **此后每一只新金库的钱与货去哪**。两个目标都查代码，空壳一律 fail-closed
11. factory.setLauncher(launcher)  ── 同上，最后一根线：工厂此后只认这一个调用方。
    ── 接它之前工厂是**惰性**的（`LauncherNotSet()`）
12. 在 Flap 上用测试参数发一个 MEME（`launcher.launch(...)`），跑通全链路
    ── 🔴 本步有链限定（决策 42-③ / #64）：测试网 46630 上按设计走不通 —— 那条链一个 ERC20
       计价币都没启用，`launcher.launch` 会在 Portal 撞 `QuoteTokenNotAllowed`。彩排语境下
       本步在主网分叉（chainId 31337，#69 / #79）上执行；完整 1–13 步在主网 4663 或主网分叉
       上走完。46630 只承担 1–11 与第 13 步的部署与接线核验那部分（见 §13 M3 行与
       `DeploySystem.flapPortalFor` 的表注）
13. 验证：六处一次性写入均已锁死、身份根环闭合（含名单两格逐格核对）、**工厂不在名单上**、
    编排环闭合（launcher → 工厂、工厂 → launcher）、预留位仍未启用、pool 无管理员出口、fork 测试全绿
```

🔴 **1–4 必须排在 8 前面**：池子的 authenticator 是 `immutable`。
🔴 **第 3 步不能推迟**：`VaultRegistry` 的名单是构造期钉死的，而池子的 `vaultRegistry` 又是 immutable ——
池子一旦部署，槽位就再也加不进去。那时要换写入方就得换 registry、换池子，而老池子里的权证与抵押品
会全部搁浅（决策 39-C）。**预留位不是可选项，是只有部署前那一刻才能做的事。**
🔴 **名单第 1 格是 launcher，不是工厂**（issue #57）：绑定跟着「代币刚刚被创建出来」这个事实走，
而那个事实在 D0 里住在 `Portal.newTokenV6` 的返回值旁边。工厂只部署金库，它**不碰身份根**，
末尾那组断言与 `verify-deployment.sh` 各有一条负向核验专门盯这件事。
🔴 金库已经**不可升级**：系统里没有金库 implementation、beacon 或能替换金库逻辑的地址；工厂在**每次发射时
现部署一只**。⚠️ 工厂缺任一必需槽时是**惰性**的 —— `newVault` 整笔 revert
（`LauncherNotSet()` / `VaultTargetsNotSet()`），不会建出坏金库（一条指向坏金库的绑定**不可撤销**）。

**为什么把"可写一次"的槽放在 Warrant / MerkleDistributor 上，而不是 ClearingPool 上。** 信任集中在池子，所以池子的四个地址保持真正的 `immutable`，部署后不存在任何写入路径。两个卫星合约各带一个 `initialized` 槽：

```solidity
address public pool;
function setPool(address p) external {
    require(msg.sender == deployer && pool == address(0), "bound");
    pool = p;
}
```

- **抢跑**：限定 `deployer`，只有我们能绑；且绑完即可立刻链上核验
- **代价**：`pool` 从 immutable 变成 storage 读，每次调用多几百 gas —— 换掉整个 CREATE2 环节
- **备选（已否决）**：Uniswap V3 那套（pool 构造函数留空，回读 `IDeployer(msg.sender).parameters()`）能保住全部 immutable，但要多一个 deployer 合约、且仍依赖 CREATE2。同样的结果，更多活动部件

> **第 13 步必须在任何其他动作之前确认六处一次性部署写入均已锁死。** 未绑定的卫星、写入方槽、Factory target 槽或 Factory launcher 槽，是本设计的保证唯一尚未成立的窗口。

**部署检查清单**：`launcher.launchEconomics()` 读回的 `taxDuration` / `mktBps` 是否是 §6.1 那一组（链上读，不是读源码）、ClearingPool 是否确无 admin 函数、**六处一次性部署写入是否均已锁死**（`Warrant.setPool`、`MerkleDistributor.setPool`、`launcher.setRegistry`、`slot.setRegistry`、`factory.setVaultTargets`、`factory.setLauncher`）、**`launcher.commissionReceiver()` 是否是那把我们打算收集成方分成的地址**（immutable）、**`MerkleDistributor.publisher` 是否是那把打算每周签 `setRoot` 的钥匙**（immutable，且它是本系统唯一的中心化信任点）、**那把钥匙每周走的是 `script/publish-root.sh`**（它在广播前重算 root、核对链与签名者、读 `rootFrozen`，见 §6.3 的补记）、**version 0 两段规范文本是否已过法律意见且逐字节复算出的哈希与部署参数及前端一致**（合约部署后哈希永久存在）。

**金库接线**：`pool` 与 `merkleDistributor` 是**金库的 `immutable`**，不是发射参数。
🔴 issue #58 之后它们的来源是**工厂的一次性槽** `setVaultTargets(pool, distributor)`（仅部署者、
写一次、永久锁死），取价 `Portal` 则是工厂的构造参数。部署脚本与 `verify-deployment.sh` 各核验一次
`factory.pool()` / `factory.merkleDistributor()` / `factory.portal()` 指向的是本次部署出来的那几个；
清单里的 `flapPortal` 字段就是为此存在（它取代了从前的 `warrantVaultBeacon` / `warrantVaultGuardian` /
`warrantVaultImplementation` 三项 —— 没有人能升级金库，那三项不再有对象）。`flapPortal` 只表示取价
来源，也是 launcher 调普通 `newTokenV6` 的建币入口；`newVault` 已没有另一个按 chainId 硬编码的
`vaultPortal()` 门。

🔴 **身份根那一环还要逐条核对**（池子的 authenticator 在部署之后物理上不可变）：

- `ClearingPool.vaultRegistry()` 指向的确实是第 4 步那份 registry、`VaultRegistry.factories()` **逐格**等于
  第 2、3 步那两个地址、两个写入方的 `registry()` 又各自指回同一份 registry —— 四跳缺任何一跳都
  **同样表现为「永远开不出系列」**，而池子与身份根都改不了。
  🔴 **必须读枚举而不是只问 `isFactory(launcher)`**：后者在一份两格都填成 launcher 的 registry 上照样为真，
  而那样预留位就没了，且此后无法补救。`test/DeploySystem.t.sol` 端到端断言这个环，
  `script/verify-deployment.sh` 回链上再读一遍（并打印 `PendingLauncherSlot.launcher()` 的当前设定状态）；
- **预留位（决策 39-D）**：`PendingLauncherSlot` 部署时是**未启用**的 —— `launcher == 0`，此时它对任何
  调用者 `bind` 都 fail-closed。启用是一次「仅部署者、写一次、永久锁死」的 `setLauncher`，发
  `LauncherSet` 事件。🔴 **配套运营要求**（缺一不可，见 design.md §10-39 的 39-D「诚实成本」）：
  部署者私钥须有明确保管方案；启用时必须公示新 launcher 的**源码与地址**；操作方还须按
  `docs/series-monitor-runbook.zh.md` 记录 slot 部署块、核对状态/事件/接线路径，并写入精确 roster
  确认记录。`LAUNCHER_ARMED` 只会在该确认被机器重新核对通过后自动关闭；人工关 issue 不是审批，也不能
  阻止下一轮重新报出未确认的一次性事件；
- 🔴 **工厂里已经没有 VaultPortal 那道门了**（issue #57）：`newVault` 只认 `factory.launcher()`。
  取而代之要核的是**编排环**：`launcher.factory() == 工厂`、`factory.launcher() == launcher`、
  `launcher.portal() == factory.portal() == 0x26605f…`（Flap 的 `Portal`，一个地址两种身份：
  launcher 拿它建币，工厂把它写进每一只金库当价源）。🔴 **不是 BSC 的 `0x9049…`**（本链零字节码），
  也不是已弃用的 VaultPortal `0xe9F7…`。核验脚本在链上逐条读；
- 崭新的身份根必须是**空**的，且陌生地址（含部署者本人）写不进去；
- 🔴 **金库的可升级性：没有了**（决策 39-A3 / issue #58）。金库**不可升级**、没有 Guardian、
  没有 beacon、没有 implementation，因此「所有金库权限函数须同时授予 Guardian 且不可撤销」这条
  Flap 规范义务**连同它的对象一起消失**；金库自身的权限面仍然是零（写入面枚举证明）。
  `launcher.setRegistry`、工厂的 `setVaultTargets` / `setLauncher` 是仅部署者可用的一次性接线，
  不是金库业务方法。
  📝 manifest 里原本的 `warrantVaultBeacon` / `warrantVaultGuardian` / `warrantVaultImplementation`
  三项已删除，取而代之的是 `flapPortal`（金库的取价来源，决策 39-A2 之后它是工厂的构造参数）；
  `verify-deployment.sh` 改为核验 `factory.pool()` / `factory.merkleDistributor()` / `factory.portal()`。

> ✅ **金库身份路线已裁决（2026-08-13）：六条分叉判据全过，采用方案 A —— 不可变身份根。**
> 裁决程序见 `design.md` §10-32，结论与证据见 §10-34 / §10-38 与
> [`research/flap-vault-identity-spike.md`](./research/flap-vault-identity-spike.md)。
> 方案 B（无许可开系列）与 issue #21 **就此不适用**。实现与部署接线是 issue #37（M2-5）。

---

## 13. 里程碑

| 阶段 | 内容 | 产出 |
|---|---|---|
| **M1** | **链上四件套** —— AttestationRegistry + Warrant + **MerkleDistributor** + ClearingPool —— 加**七条**不变量测试 | 合约 + 测试套件 |
| **M2** | WarrantVault + Factory + Launcher + 结构自检 | **身份根 + D0 launcher + 工厂 + 部署接线已落地**（issues #37 / #57）；**金库与工厂均已去 Flap 化**（issues #58 / #57）—— 结构自检改为证明旧 Flap 基类与钩子确实不存在 |
| **M3** | 完整系统可部署链上的端到端联调 | 代码侧工具已有：#66 手工 Merkle 通路、#67 独立 A 段全闭环驱动器、#68 keeper、#77 外部死人开关代码、#79 持久主网分叉环境。部署与核验链 allowlist 已扩到 4663 / 46630 / 31337 / 31338（#65）。⚠️ 测试网 **46630** 只承担 B 段运营侧；发射 / 金库 / TWAP / 开系列留在主网分叉。#69 的两到三周真实时钟彩排/运营验收仍未完成 |
| **M4** | ✅ canonical replay + 确定性计算 + MerkleDistributor + 开源复算 + sealed proof read model + publisher handoff/finality/recovery（#91～#96）；常驻 Proof Runtime 已在 Core staging 部署，生产服务尚未部署 | 模块与产物可独立验证；`setRoot` 仍人工签名 |
| **M5** | OrderbookService + Seaport 集成；✅ M5-0 已冻结 D1～D10（§6.6.1）；总票 #103，实现票 #104～#107 | 规范卖单 / 部分成交 / 软下架与链上取消 / canonical 状态投影 |
| **M6** | Web App 已由前端工程师基于 mock 完成；#114 的后端 staging 接口产物、专属分叉、fixtures 与 runtime 已交付，前端集成与联合验收仍在 umbrella #110 下推进 | `v1.0.0` 启用发射 / 项目 / 权证 / claim / attest / exercise / 日历，OTC 关闭 |
| **M7** | 主网 + 首个 GME 项目 | — |
| **M8** | ⏳ 回购金库 + 常设指令卫星（§6.7 / §6.8，决策 50 / 51） | `v1.2` 候选；主网部署前置：R17 律师意见 + 合约转账免税复核（§14-14） |

当前进度：**M1 已完成；M2-0～M2-6 已实现并通过测试** —— 身份根双槽、D0 launcher、Factory 接线、
严格 TWAP、收入路径、开系列，以及**金库去 Flap 化（不可升级 + portal 改构造参数）**均已落地。
**M4 的 canonical replay、确定性计算、公开复算、sealed bundle catalog、只读 Proof API/HTTP adapter 与
publisher handoff/finality/recovery 流程已由 #91～#96 实现并通过测试。可重置的常驻 Proof Runtime 已在
Core staging 部署；Robinhood 4663 的生产 Indexer/HTTP 服务仍未部署，`setRoot` 仍由 publisher 人工签名。**
M3 的 #66 / #67 / #68 / #77 / #79 工具已实现，尚待 #69 真实时钟运营验收；#114 的后端 staging 接口产物、
专属分叉、fixtures 与 runtime 已交付，尚待 Web App 七条旅程、桌面/移动端、reorg/reset 与联合签字；M5 实现与 M7
仍属后续规划。`v1.0.0 Core` / `v1.1.0 Market` 的发布分界及 STG-0-D1～D6 见
[`frontend-integration-v1.zh.md`](./frontend-integration-v1.zh.md)。仓库中的本地 `deployments/31337*.json` 只证明部署脚本在
Anvil 上通过，不代表 Robinhood Chain 已部署。

---

## 14. 未决技术项

1. ~~§2.1 / §2.2 两处修正需确认~~ ✅ **已确认并同步到设计、实现与对外文案**
2. **`antiFarmerDuration` 的确切语义与 Robinhood Chain 最终值** —— **仍未确认**。30 天来自历史 BSC MarsCoin 样本，不能据此确定 v1；在目标链完成核验前，1 天只作开发 / 测试占位
3. ~~**TWAP 样本频率**~~ ✅ **M2-2 已落实**：严格 trailing 24 小时窗口，通常每小时采样，
   `MAX_SAMPLE_GAP = 65 分钟`。这是离散 spot 设计；strike 已由 M2-4 接入（对非零状态 fail-closed），服务监控仍是必需工作。
4. ~~**Merkle 发布周期与延迟**~~ ✅ **2026-08-23（#91）已冻结**：每系列一次整段 TWAB，
   不按每日收入分段；窗口截止且 boundary block 进入 canonical `finalized` ancestry 后才可 seal / 发布。
5. ~~**Seaport 订单的 taker fee 编码方式**~~ ✅ **2026-08-25（M5-D2）已冻结**：标准
   `PARTIAL_OPEN` order，不设 zone；fee 是 maker 报价之上的独立 GME consideration，前 56 天 0%，之后 50 bps，见 §6.6.1。
6. ~~**曲线阶段的价格读取** —— `getTokenV8Safe().price` 的精度与语义需实测确认~~ ✅ **2026-08-14 已实测确认**（M2-2，issue #34）。`price` = **1e18 raw 单位该代币值多少 raw 计价币**，18 位定点，公式 `k/(1e9+h-s)²`；在真链上用镜头自己给的 `r/h/k/s` 复算，与它给的 `price` 逐位相等（`reserve` 的恒等式同样对上）。🔴 **它是金库要的那个数的倒数**，反演在采样时做（`1e36/price`）；🔴 **毕业后恒为 `0`**，因此双分支是必需而非优化，切换条件是 `status`。顺带确认 **GME 是本链启用的计价币**（§3 的更正）、毕业后的池子是 **Uniswap V2 形状**、代币不存在时镜头 **revert**（`TokenNotFound`）。当前 V2 分支会拒绝采样块内更新过储备的现货，但这只是窄化的同块拦截：既不读取累计价，也不能证明完整的 V2 预言机 / 抗操纵安全。⚠️ 残余：`price` 归一到 18 位而非计价币 raw，GME 恰好 18 位所以重合，**接入非 18 位小数的股票代币时须重推**。全部记录见 [`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md)
7. ~~CREATE2 地址预计算 —— Warrant / MerkleDistributor 与 ClearingPool 的循环依赖~~ ✅ **2026-08-09 已解**：两个卫星合约用"仅部署者、一次性、写后锁死"的 `setPool` 绑定；池子保持真 immutable，**CREATE2 整个不再需要**（§12）。这是 M1 的最后一处硬阻塞
8. 🔴 **version 0 两段文本的最终措辞** —— 合约部署后，其**两个哈希永久存在、无法替换**；规范文本本身保存在 [`legal/attestation-v0/`](../legal/attestation-v0/)。**这是本清单中唯一不可回滚的一项**。✅ **2026-08-26 已定稿（issue #18）**：权威语言为英文；提交文本为外部律师审阅并修改后的版本，定稿哈希已钉进 `.env.example` 与 `test_shippedTextIsFinalized` 绊线。审阅范围与多语安排的永久记录见 [`legal/attestation-v0/README.md`](../legal/attestation-v0/README.md)。主网闸门已在 `script/VersionZero.sol` 里生效
9. ~~**OTC 侧的声明策略**~~ ✅ **2026-08-25（M5-D7）已冻结**：OrderbookService 不检查 maker/taker
   声明；声明只在 `exercise()` beneficiary 路径由合约强制，见 §6.6.1。
10. ~~`FlapTaxTokenV3.transferFrom → 0xdead` 行为核验~~ ✅ **已在 v1 目标链 Robinhood Chain 完成**。固定区块 31,955,417 的套件保留可复现证据；独立 latest canary 钉住当前 GME beacon 与 Flap 新发币选择链（Portal implementation → immutable launcher → immutable 的受支持 token implementation），核对三份 Flap runtime codehash，并执行真实转账；两层都以 `FORK_REQUIRED=true` 运行 Forge —— 固定区块那层在门禁里（`script/ci.sh fork`），latest canary 那层自 issue #25 起分出去单独跑（`script/monitor.sh canary`），刻意不进门禁：它监控的是第三方何时升级，与某次提交改了什么无关。真实 `FlapTaxTokenV3` 代理上，**`transferFrom(holder, 0xdead, X)` 实收正好 X**；转 `0x0` 会 revert；且不存在原生 `burn()` / `burnFrom()`，因此必须使用 `0xdead` 路径。此前 BSC / MarsCoin 的探针只保留为历史方法学证据，不属于 v1 验收。✅ **目标链收税阳性对照已于 2026-08-16 取得**（#53 的 D0 spike）：不是「找到」一只已激活的代币，而是**自己发一只**并把它买穿曲线毕业 —— GME 计价档，买卖各 300 bps 的税实测扣进代币合约，`TaxProcessor` 换回 GME，无许可 `dispatch()` 打给发射参数指定的 beneficiary。锚点 `test/fork/RobinhoodSelfLaunch.t.sol`，记录见 [`research/self-launch-spike.md`](./research/self-launch-spike.md) §3
11. 🔴 **目标链核验仍未完成：税可能只对「已注册的交易对」生效，未注册的平行池可逃税。** 历史 BSC MarsCoin 证据测得：转入已注册官方对收 **3.00%**，转入第三方 PancakeSwap V3 池收 **0**，38 分钟窗口内 **70.4% 成交量**在无税池。该结果不构成 Robinhood Chain 验收证据。目标链实现虽与历史样本 ABI 同构，但尚未找到收税分支已激活的阳性样本；因此 v1 在上线前须于 Robinhood Chain 重做已注册对 / 平行池对照，并在此前按保守结构性风险处理。第三方建池仍然**无法由我们的合约修复**，见 `design.md` R14
12. ~~ClearingPool 接口冻结评审~~ ✅ **已定案并落实**（2026-08-09）：① 池内滚存 `rollExpired`；② 门控感知结算（fail-open + `max(expiry, clearedAt + 48h)` 截止）；③ `exercise` 带 beneficiary + `claimAndExercise`；④ permissionless `claim`。本文件 §4–§8、§11、§12 已改写，决策记录见 `design.md` §10-25…28

13. ✅ **发射路线 D0 已定案（2026-08-16，#53 / `design.md` §10-39）并已实现（2026-08-17，#57 / 决策 40）。**
    本条转为历史记录 + 残余项。

    **既成事实（不变）**：`VaultPortal.newTokenV6WithVault` 这个入口**没有任何一档 quote 能创建真 `WarrantVault`**。
    native `quoteToken = address(0)` 会进入 `WarrantVault` 的**构造函数**，先被收入币种零地址防线整笔回滚，
    后续「地址须有代码」检查不会执行；GME 则在调用本 Factory **之前**被 `UnsupportedQuoteToken(GME)` 拒绝。
    两种失败都响亮回滚，不留下永久的错误 registry 绑定。锚点：
    `test/fork/RobinhoodWarrantVaultFactory.t.sol::test_withTheRealVaultTemplate_aNativeQuotedLaunchFailsLoudly`
    与 `::test_withTheRealVaultTemplate_aGmeQuotedLaunchFailsUntilVaultPortalEnablesGme`。
    主网复核确认这道门**写死在上游代码里**（`VaultPortalLaunch` 门面的纯常量检查，VaultPortal 无计价配置面、
    全历史零条配置事件），开门需要 Flap 升级合约而不是一笔配置交易。

    **裁决**：**不等上游，改走 D0** —— 普通 `Portal.newTokenV6` + 我们自己的 launcher 编排层
    （建币 → 建金库 → `bind`，同一笔交易）。**实现是 [`src/WarrantLauncher.sol`](../src/WarrantLauncher.sol)**，
    时序与参数见 §6.1；钉死高度的端到端验收在 `test/fork/RobinhoodLauncher.t.sol`（CI required），
    latest 探针在 `test/fork/RobinhoodSelfLaunch.t.sol`（`script/monitor.sh canary`）。
    路线判据当初的分叉实测（spike 见
    [`research/self-launch-spike.md`](./research/self-launch-spike.md)）：合约可以当 `newTokenV6` 的
    `msg.sender` 且它同步返回真地址；GME 计价档买穿曲线后毕业成 **MEME/GME** 池；税以 MEME 扣进代币合约，
    越过 `dispatchThreshold` 后 `TaxProcessor` 卖回 GME，**无许可 `dispatch()`** 打给 `marketAddress`
    （`== 发射参数里的 beneficiary`，生产里那格填我们的金库）；全程零注册、零授权。
    `Portal.getQuoteTokenConfiguration(GME).enabled == 1` 描述的正是 D0 走的这个入口。

    ⚠️ **一处会误判的中间态**：换回的 GME 先停在 `TaxProcessor` 里按用途分账
    （market / dividend / lp / fee / commission 五格），**不会自动出现在收款地址上** ——
    只盯收款地址余额会误判成「税没收到」。由
    `test/fork/RobinhoodSelfLaunch.t.sol::test_theTaxPotIsSwappedBackIntoTheQuoteTokenByTheProcessor` 钉住。

    🔴 **残余项（本条继续跟踪的全部内容）**：
    - `antiFarmerDuration` 的生产取值仍未定（§14-2）。它今天是 `launch` 的入参，不是常量 ——
      定值之后应当收进 launcher 的 `constant`，那是一次需要重新部署 launcher 的改动；
    - `commissionReceiver` 是 launcher 的 `immutable`。换它要重新部署 launcher **并且**重新部署
      身份根与池子（名单构造期钉死）—— 所以它在主网部署前必须定死，见 §12 的部署检查清单；
    - 「谁来买穿曲线」是运营问题，不是合约问题（spike §6-2）。

    **launcher 编排层已由 #57 交付。** `VaultRegistry` 2 槽写入方名单 +
    `PendingLauncherSlot` 已由 **issue #56 交付**，并且必须先于 `ClearingPool` 部署，因为池子的
    `vaultRegistry` 是 immutable，事后加不了槽。金库去 Flap 化也已由 #58 交付：`VaultBaseV3` 已拆、
    每只金库不可升级、取价 portal 已改构造参数。
    §14-7 的目标链收税阳性对照已由本次 spike **正面关闭**。

14. 🔴 **回购金库 / 常设指令的部署前置**（2026-09-04 新增，§6.7 / §6.8）：① 卫星以合约身份签 version 0 的法律确认（R17，是否追加 version 1 措辞）；② MEME 钱包↔合约转账免税在主网分叉复核（池子行权路径已断言精确扣款，卫星多一跳 `transferFrom(user → satellite)`）；③ 三个参数定值：`discountBps`（起点 1000）、单日买入上限（起点无）、`feeBps`（起点 0）；④ M4 是否收编卫星的逐人行权事件。①② 阻塞主网部署，③④ 不阻塞实现。
