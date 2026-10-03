# warrant — 设计文档

> 2026-10-03：本分支新部署遵循 [Flap Custom Vault](flap-custom-vault.zh.md) 的原子创建协议。旧 D0、Pending 激活、旧池迁移和新增 Flap 前缀合约方案已被替代；历史决策保留用于追溯。Vault 的 Guardian 全余额应急权限与永久 creator impairment 是新风险面，Pool 权限不变。
> 本分支新Vault收入以实际到账计提固定10% protocol fee，支付给不可修改的commissionReceiver；正常完整处理为Pool 80% / creator 10% / protocol 10%。claimProtocolFee无需开系列、无许可且收款人固定，原生项目支付WBNB。creator与protocol储备损失按比例永久记账，未来收入不补偿。以下历史90/10及仅creator储备叙述由[当前接入说明](flap-custom-vault.zh.md)替代；processor commission另计，发布仍须平台分别认可三项费用。

| | |
|---|---|
| **平台名** | **warrant** |
| **产品** | 股票期权化的 Meme 发射平台 + Warrant 清算所与 OTC 市场 |
| **实施路径** | 官方 VaultPortal + Warrant Custom Vault；A/B共用工厂，创建即绑定，不可升级 |
| **链** | 本阶段准备全新 BSC 栈（chainId56），不接旧池或旧抵押品；主网广播与平台发布另行执行 |
| **quote** | 原生 BNB 及 Portal 允许的有代码 ERC20；原生抵押品为 canonical WBNB |
| **技术栈** | Foundry |
| **状态** | 机制闭环。含 2026-08-08 两处架构修正（权证按项目隔离、归属改用 merkle，见 [`spec.md`](./spec.md) §2）；**含 2026-08-09 接口冻结评审四项决策 + 复审的部署绑定决策，以及 M1-8 落地时的两项**（§10-25…31）。**2026-08-13：金库身份路线的六条分叉判据全过，采用方案 A —— 不可变身份根 `VaultRegistry`**（§10-34，spike 见 [`research/flap-vault-identity-spike.md`](./research/flap-vault-identity-spike.md)）；**2026-08-14：`WarrantVaultFactory`、beacon 部署接线与 `openSeries` 身份认证落地**（§10-38 / §10-34；该 beacon 形态随后已由 #58 移除）。**2026-08-16：发射路线定案为 D0 —— 普通 `Portal` 入口 + 自建编排层，并为未来自建发射栈预留 2 槽身份根**（§10-39，spike 见 [`research/self-launch-spike.md`](./research/self-launch-spike.md)）；**2026-08-17：D0 三张实现票全部落地 —— ① registry 2 槽预留 + `PendingLauncherSlot`（#56）、② launcher 编排层 `WarrantLauncher`（#57，§10-40）、③ 金库去 Flap 化（#58），M2 至此完工**。**2026-08-17（同日，#64）：M3-W1 探针判定测试网发不出能驱动金库的币，据此定案 —— 发射栈不迁移、B 段彩排改用「改了 chainId 的主网分叉」，并补上 R16 这条此前无人盯的 Flap 开关**（§10-42）。**2026-08-18：M3 票面按决策 42 收口** —— #67 / #69 正文重写、「不找 Flap 开测试网计价币」定为不做、长跑分叉环境单列 #79（§10-42 ⑤）。**2026-08-18（同日，#66）：M3-W5 手工 merkle 通路落地 —— 构建 / 复算 / 发布 / claim 四支脚本，本仓库为「root 必须能被官方库复算出同一个值」接受了它的第一个 node 依赖**（§10-44）。**2026-08-25：M5-0 冻结 OrderbookService v1 的 D1～D10，标准 Seaport 卖单、GME 支付、部分成交、SQLite/canonical 同步和 REST interface 的完整口径见 spec §6.6.1 与 §10-47；实现尚未开始。** **M1 与 M2 已实现并通过测试，发射链路的链上部分已齐备，但尚未部署到 Robinhood Chain —— 剩余上线阻塞见 §12（其中唯一不可回滚项：version 0 声明文本，#18）；M3 正在推进；M4 #91～#96 已实现，可重置的常驻 Proof Runtime 已在 Core staging 部署，但生产 Indexer/HTTP 服务仍未部署；M5 实现与 M6 前端联合验收、M7 仍属后续** |
| **发布切面** | **2026-08-25 冻结、2026-08-26 增补 Market Preview（决策 48）**：`v1.0.0 Core` 只提供 M0～M4 真实能力，并保留不接 M5 数据或交易的静态 Market Preview；`v1.1.0 Market` 才接入 M5。Web App 已由前端工程师基于 mock 完成；专属 31337 主网分叉、静态配置、钱包/RPC、fixtures 与只读 Proof Runtime 已交付，尚待前端 Core 集成与联合验收；完整接口见 [`frontend-integration-v1.zh.md`](./frontend-integration-v1.zh.md) |
| **最后更新** | 2026-08-26 |

> **M3 当前边界（2026-08-25）**：#66 手工 Merkle 通路、#67 独立全闭环分叉彩排、#68 keeper、
> #77 外部死人开关代码与 #79 持久分叉环境已实现；未完成的是 #69 两到三周真实时钟/运营验收。

> 本文档 2026-08-07 第二次重写。第一次（同日）把产品从「单一代币 $BIDX」改为「Warrant 平台」；当日版曾把实施路径从「自建全栈」改为「Flap 第三方金库模板」。该历史路线已由 #53 / #58 取代，当前是普通 Flap `Portal` + 自有 launcher / 不可升级金库的 D0。历史可行性核验见 [`research/flap-vault-integration-feasibility.md`](./research/flap-vault-integration-feasibility.md)。
>
> **链范围（2026-08-11）**：本文中的 BSC / MarsCoin 数据只作历史对照与方法学证据，不构成 v1 的依赖或验收项。v1 的部署、持续分叉测试与上线验收全部只针对 Robinhood Chain；未来若支持 BSC，须单独立项并重新核验外部依赖。

决策 46 的交付边界已在 #91～#96 落地：bundle 内的 entry 只能是 regular file，拒绝 symlink 与嵌套目录，candidate 复制到唯一 staging 后会再做一次完整验证，然后用 hard-link 原子 claim immutable identity；竞争者可完成崩溃 owner 的 staging transaction。`FINALITY_VIOLATION`、`CHAIN_IDENTITY_MISMATCH` 或 `PUBLICATION_HISTORY_MISMATCH` 时 current/by-root 都 fail closed；只有 `CATALOG_UNAVAILABLE` 时，已知 immutable by-root 审计与 bundle download 仍可继续。#96 还交付了固定 finalized 高度、链身份与 live publication snapshot 核验的 `prepare-handoff`；它只做无钥匙 dry-run，最终 `setRoot` 仍由 publisher 人工签名。以上是库、薄 HTTP adapter 与人工操作边界，不代表常驻生产服务已部署。

---

## 1. 产品定位

**不是发射台，是"发射之后"的那一层。**

发射台已被 Flap 工业化（历史 BSC 样本约 108 个/天；v1 目标链 Robinhood Chain 累计 1,903 个金库）。但实测漏斗显示：

| 层级 | 数量 |
|---|---|
| 创建了金库 | 1,903 |
| 收到 ≥1 ETH | 49（2.6%） |
| **收到 ≥10 ETH** | **12（0.6%）** |

**产能不缺，缺的是"发出来的东西有人玩"。** 我们把已验证的飞轮（税 → 买股票 → 回馈持币者）在最后一步换成 **Warrant（看涨凭证）**，并为之建清算所与市场。

**为什么这个位置好守**：发射是一次性生意，**市场是持续生意且有网络效应**。Flap 能一夜复制一个金库模板，复制不了订单簿深度。

---

## 2. 实施路径：建在 Flap 上

| 组件 | 谁提供 |
|---|---|
| Meme 代币合约（含买/卖税） | **Flap**（`FlapTaxTokenV3`） |
| 税收采集、结算、自动兑换 | **Flap**（TaxProcessor + SwapRegistry） |
| Bonding curve、DEX 迁移 | **Flap** |
| 定时触发 | **我们自己的 Trigger Service / keeper**（`script/trigger-keeper.sh`） |
| **WarrantVaultFactory + WarrantVault** | 我们 |
| 🔴 **ClearingPool（不可升级）** | 我们 |
| **Warrant（ERC-1155）** | 我们 |
| **OTC 结算** | **复用 Robinhood Chain 上的 Seaport 1.6**（已核实部署，见 §6.4） |
| **全部前端** | 我们 |

**发射方式（2026-08-16 定案，决策 39 / #53 —— 路线 D0）**：自己的 UI 调**我们自己的 launcher 编排层合约**，它在同一笔交易里做三件事 —— 调普通 `Portal.newTokenV6()` 建币（`quoteToken = GME`、`commissionReceiver` 填我们、`beneficiary` 填本项目金库）、部署金库、把 `(token, vault)` 写进 `VaultRegistry`。**全程无需 Flap 注册或授权**（`Portal` 已验证源码里没有任何「注册 launcher / 批准工厂」入口，`newTokenV6` 只挂一道全局断路器；实测全新合约直接发币成功，集成方分成填任意未注册地址照样入账）。

> ⚠️ **被废弃的旧方式**：`VaultPortal.newTokenV6WithVault()`。那条入口在 Robinhood 主网**没有任何一档 quote 走得通** —— native 在真金库构造函数的零地址防线回滚，GME 在调用 Factory 前报 `UnsupportedQuoteToken(GME)`，且该门**写死在上游 `VaultPortalLaunch` 门面的字节码里**（无配置面、全历史零条配置事件），开门需要 Flap 升级合约而不是一笔配置交易。#45 记录了这次实测，#53 裁定改走 D0 而不是等待。

**⚠️ 但"Flap 前端曝光"不是自动的** —— 其金库选单是硬编码的策划名单，需对方上架。**分发不能押在对方身上。**

---

## 3. 核心机制

**机制：每个 meme 直接以它绑定的那只股票作为交易对货币（`quoteToken` = 该股票）。**
**2026-08-16 起这条已有可执行的发射路径**（决策 39 / 路线 D0）：普通 `Portal.newTokenV6` 接受 GME 计价，
分叉实测已把「建币 → 买穿曲线 → 毕业成 MEME/GME 池 → 收税 → 换回 GME → 无许可 `dispatch()` 到我们的金库」
整条链路跑通（`test/fork/RobinhoodSelfLaunch.t.sol`）。被前置拒绝的只是 `VaultPortal` 的**带金库入口**，
而 D0 不走那个入口。

```
用户用 GME 买卖 MEME（交易对就是 MEME / GME）
   │
   ├─ Flap TaxProcessor 收税 —— 税本身就是 GME
   │   ├─ 协议费：最高 0.3% 交易量 → Flap
   │   ├─ commission：≈0.06% → 我们（集成方，同样以 GME 计）
   │   └─ 余额 dispatch → 我们的 WarrantVault
   │
   ▼  WarrantVault —— 无需任何 swap，收到的就是股票
 收到 Y 单位 GME
   │
   ▼  存入 ClearingPool，铸造 Y 份 Warrant
 行权价 strike = 池价(每 1 GME 值多少 MEME) × k     ← 以 MEME 计
   │
   ▼  链下索引计算时间加权归属 → 每周发布 merkle root
 持有者三选一：
   ├─ 行权：销毁 strike × 数量 的 MEME → 领走 GME
   ├─ 卖出：OTC 市场转让（ERC-1155）
   └─ 放弃：到期作废 → 对应 GME 退回本项目金库，滚入下一系列
```

**这一步消掉的是金库里的第二层采购**：Flap TaxProcessor 仍会把累积的 MEME 税 swap-back 成 quote token（首发 GME）后 dispatch；`WarrantVault` 收到的已经是股票，因此不再自建路由、`minOuts` 或主动买入策略。

> 🔴 **归属计算方式已修正**（2026-08-08，详见 [`spec.md`](./spec.md) §2.2）。原设计为链上 accumulator，**不可行** —— MEME 合约属于 Flap，我们无法 hook 其 `_update`，因而无法在余额变动时维护 `userDebt`。改为**链下时间加权计算 + 每周 merkle root**，算法与复算脚本开源，任何人可用公开的 `Transfer` 事件独立验证。代价是引入本系统**唯一的中心化信任点**。

**历史对标验证**：BSC 上的 MarsCoin 用的就是这个结构（`quoteToken()` = SPCXB，实测确认）。这只证明机制已有样本，**不是 v1 的目标链依赖或验收依据**。

---

## 4. 行权价（strike）怎么定

**行权 = 销毁 `strike × 数量` 的 MEME → 领走对应数量的股票。** strike 以 **MEME** 计价。

### 为什么需要读一次价格

`quoteToken` = 股票之后，金库只观测到一个数：**收到了 Y 单位股票**。不再有"花掉多少"的成本基准，所以 `strike` 必须来自价格。

**好在交易对本身就是 `MEME / GME`** —— "1 个 GME 值多少 MEME" 就是这个池子的价格，**一次读取即可，不需要跨市场拼价**。

```
strike = 池价(每 1 GME 值多少 MEME) × k        // k = 0.8
```

**读取来源**：Flap 的 `Portal.getTokenV8Safe` 已返回 `price` 等状态（曲线阶段与 DEX 阶段统一），或 `quoteExactInput`。**不引入外部预言机。**

### 🔴 strike 必须"每系列一个"，不能"每次铸造各算各的"

税是**持续到账**的，一周内可能 dispatch 几十次。若每次按当时价格定 strike：

> 同一系列 `(本项目, GME, 本周五)` 里会出现几十种不同 strike 的 warrant。
> **它们不是同一个资产，ERC-1155 无法同 id 表示，该项目的 OTC 订单簿直接碎掉。**
>
> 有了这条规则，**每个项目在任何时刻恰好只有 2 个活跃系列**（一个累积中、一个待到期），订单簿才有深度可言。

**规则：strike 在系列开启时定一次，该系列整周所有铸造共用同一个 strike。**

**正向副作用**：strike 固定后，warrant 的价内外程度随 **MEME 相对 GME 的走势**变化 —— MEME 跌则转实值、涨则转虚值。这正是"相对强弱期权"的性质，此处是自然结果而非额外设计。

### 取价方式：系列开启前 24h TWAP

strike 从"一周几十次小额读取"变成"**一周一次、决定整周发行量**"，操纵诱因显著上升 —— **拉一次盘即可锁定一整周的行权价**。

→ 采用 **系列开启前 24 小时的时间加权均价**。既然一周只算一次，**"算得仔细"的成本被摊薄到接近零**，而收益是把攻击门槛从"拉一次盘"抬到"反复抢占受采样间隔约束的价格段"，成本差是数量级的。当前已实现的 M2-2 通过 `PriceSource` 读取曲线或毕业池的离散 spot，并作严格 trailing 24h TWAP 聚合：它要求每段不超过 65 分钟，但不连续观测价格，因此攻击者可在每次采样后恢复现价；这不是累计价预言机的保证。

> ⚠️ **已撤回的评估**：早先版本写的是"铸造时读现价 + 单批限额"，并论证"单批有界、收益被摊薄"。**那个论证只在"每次铸造各算"的前提下成立**；改为每系列定价后前提消失，故撤回。

### 铸造频率：每日一次

strike 每系列固定后，铸造频率不再影响同质性，只剩成本考量。

**由我们自己的 Trigger Service / keeper 每天调用一次 `processRevenue()`** —— `script/trigger-keeper.sh` 已实现这条调度，gas 摊薄合理，并把**新到账、尚未进池的在途资金**窗口压到 ≤24 小时（对应 §5 末尾那条运营缓解）。

> 🔴 **但它无许可**（M2-3 / issue #35 落地，§10-37）：Trigger Service 只是"通常那个调用方"，不是唯一那个。keeper 全挂时，任何持有人都能触发一次收入处理；在余额可读且实际扣款的正常路径上，它会把窗口关上。调用方也改不了钱的去向。**每日一次因此是运营节奏，不是安全依赖。** 每种节奏下在途多少钱，见 [`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md) §4.1。

### 顺带恢复的两个性质

`quoteToken` = 股票之后，strike 回到以 MEME 计价，因此：

- ✅ **行权即销毁 MEME**，无需在金库里写"回购再销毁"的逻辑
- ✅ **OTC 买方必须去买 MEME 才能行权** —— 这条天然的需求通道回来了

---

## 5. 偿付：结构性全额抵押

**Warrant 只能由"已真实买入并存入清算池的股票"铸造，1:1。** 因此任何时刻：

> `未行权 Warrant 总量 ≤ 池内股票余额`

**恒等式成立，无部分准备金，因此不存在挤兑。** 集中行权只是把池子精确清到零。

### 五条不变量

| # | 不变量 |
|---|---|
| 1 | 每个系列 `outstanding ≤ poolBalance`（**raw `balanceOf` 单位**），任何时刻 |
| 2 | 铸造量 = **实际到账的余额差**，不是"预期买入量" |
| 3 | 行权原子化：销毁 Warrant、收取 strike、转出股票同一笔，任一失败全部回滚 |
| 4 | 按 raw `balanceOf` 计量，UI 层再乘 `uiMultiplier` 显示 |
| 5 | **无任何管理员路径能在 Warrant 未到期时动池内股票** |

**不变量 2 现在极其简单**：`quoteToken` = 股票之后，金库收到的就是股票本身，**铸造量 = 本次余额增量**，没有 swap 可能失败、也没有滑点误差。

### 全额抵押解决不了的风险（首发标的 GME 已实测，见 [`research/robinhood-stock-token-permissions.md`](./research/robinhood-stock-token-permissions.md)）

**① 拆股打破 1:1（EIP-8056）**
`uiMultiplier` 变化时 `balanceOf` 不变、每枚背后的股份数变了 → **必须按 raw 单位铸造与行权**。
另注：`updateMultiplier` 支持 `effectiveAt` 预约 → **`newUIMultiplier` / `effectiveAt` 是公开可读的套利日历**，铸造与行权需在该时点前后设保护窗口。

**② 🔴 发行方可冻结**
Robinhood 的 `Stock` 把 `onlyNotBlocked` **硬编码进 `transfer` / `transferFrom` / `approve` / `permit` 每一条路径**，查的是**全链共用的中央注册表** `0xe10b6f6b…1b00`（封一次，所有股票代币同时对该地址失效）。另有**双层暂停**（单币 + 全局）。
→ **门控/暂停期间 Warrant 自动延期，而非到期作废。**

**③ 🔴🔴 `adminBurn` —— 唯一全额抵押防不住的一条**

```solidity
function adminBurn(address from, uint256 amount) public override onlyRole(ADMIN_BURNER_ROLE) {
    _burn(from, amount);            // 注意：无 onlyNotPaused、无 onlyNotBlocked
}
```

持有该角色者可**从任意地址销毁任意数量**，包括我们的 ClearingPool。

> 我们能保证 `未行权 Warrant ≤ 池内余额`，**但保证不了池内余额不被发行方直接抹掉。**
> **无技术手段可防。** 只能：① 多标的分散单点暴露 ② 事件监控与及时披露 ③ **风险条款明示，不能只讲"全额抵押"**。

**当前实测状态（2026-08-07）**：未暂停、抽查地址未被封、从持有 14,813 GME 的地址模拟转账全部通过 —— **机制已接线，但一项都没启用**。

**公平地说**：Flap 生态 1,903 个金库持有的是同一批代币，**这是整个赛道共有的暴露**，非本设计缺陷。

### 🔴 ClearingPool 独立于任何可升级体系（**两个合约现在都不可升级**）

原文：Flap 规定想要低风险徽章，金库**必须**是 beacon proxy 且**升级权归 Flap Guardian**；所有权限函数**必须**同时授予 Guardian 且不可撤销。**抵押品因此绝不能放在 WarrantVault 里** —— ClearingPool 是我们自己独立部署、不可升级、无 admin 提取路径的合约，金库只做转发。

> 🔴 **2026-08-16（决策 39-A3 / issue #58）：徽章那条路已放弃，于是这段的前提消失，结论反而更强。** 金库现在**也**不可升级（不继承 `VaultBaseV3`、不走 beacon、无 Guardian）。分层保留 —— 抵押品仍然只住在池子里 —— 但理由从「Flap 能升级金库」换成「让抵押品与它的托管规则住在同一个不可升级的地方」。

**残余风险**：**在途资金**（金库已收到、尚未存入池子的部分）→ 设计上"收到即处理"，把窗口压到最小。⚠️ 它现在暴露给的是**我们自己那份任何人都能读完、且谁也改不了的代码**，而不是一个第三方能替换的实现 —— 风险性质从「信任」降级为「审计」，量化模型不变。

> ⚠️ **该表述成立的前提是 2026-08-09 决策 ①（池内滚存）**：此前的 `claimExpired` 路径会让到期余量（稳态约 `S/f`，见 R13）每周回流金库一次——那时"在途 ≤24h"只覆盖新税收，不覆盖回流，实际暴露大一到两个数量级。改为池内滚存后，金库经手的资金才真正只剩 ≤24h 的新到账税收。
>
> 🔴 **2026-08-14（M2-3 / issue #35）起，这句话有了一个数**：稳态在途 = `S × T / 7天`，与池内规模之比 = `f × T / (0.9 × 7天)`（`S` 约掉了，**与项目大小无关**；分母的 0.9 是决策 49 之后每周只有九成收入进池子）。`f = 5%`、每日跑一次 ⟹ **0.79%**，也就是 R2b 一次 `adminBurn` 可烧规模的 1/126。模型、两个标定、三种失效场景的算例与运营要求见 [`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md)；链上读数是 `WarrantVault.inTransit()`。**尝试缩短窗口的函数无许可**——keeper 全挂时持有人自己也能调；实际关窗仍取决于余额可读且收入币种实际扣款。

---

## 6. 合约架构

### 6.1 WarrantVaultFactory + WarrantVault（**我们自己的，不可升级**）

> 🔴 **2026-08-16（决策 39-A3 / issue #58）：本节整个换了前提。** 下表原本是「Flap 规范的硬性要求」；金库去 Flap 化之后，左列里有一半失去对象，另一半我们**主动保留**下来 —— 理由换了，做法没换。逐条去向见 [`flap-vault-spec-compliance.zh.md`](./flap-vault-spec-compliance.zh.md) §0.5。

| 原规范要求 | 今天 |
|---|---|
| 继承 `VaultBaseV3` | ❌ **不继承任何 Flap 基类**。`vaultUISchema()` / `vaultSpecVersion()` / `guardian()` 一并删除 |
| beacon proxy + 升级权归 Guardian | ❌ **不可升级**：工厂每次发射**直接部署**一只金库，六个参数（决策 49 起含 creator）在构造那一笔里定死 |
| **Guardian 授权**：所有权限函数须同时授予 Guardian | ❌ 没有 Guardian。✅ **零权限面保留**（决策 33）—— 理由换成「它是『金库拿不走钱』的最短证明」 |
| `vaultQuoteToken()` | ✅ **保留**（名字也保留）：`immutable`，运营面（`series-monitor.sh`、链上核验）在读它 |
| `receive()` 遵循**余额差记账模型** | ✅ **保留**：D0 不改税收链路，ping 与余额差记账描述的是今天真实的行为 |
| `description()` 动态描述 | ✅ **保留**：它渲染 `inTransit()`，是在途窗口的实时读数 |
| — | ➕ **新增**：取价 `Portal` 是**构造参数**（决策 39-A2），不再按 `chainId` 查表 —— 「新项目用新价源、老项目用老价源」因此天然并存 |

金库逻辑本身很薄：

```
receive()          → 记账（余额差），只记账、任何路径都不 revert
sync()             → 无许可补记入口（直接转账 / 捐赠 / ping 被关掉时的恢复路径）
sampleTwap()       → 无许可：`PriceSource` 取 spot，写入严格 24h TWAP 所需样本环
                                                                       ← M2-2 已实现
openSeries()       → 每周一次：取前 24h TWAP 定下本系列 strike        ← M2-4 已实现
processRevenue()   → 每日一次、**无许可**：读实际余额 → 切 10% 记给 creator（决策 49）
                     → 其余 ClearingPool.depositAndMint() → 按池内实测增量铸造
                     → 同笔按存后实际余额更新在途基线                  ← M2-3 已实现
claimCreatorFee()  → **无许可**：把累计分成转给发射那一笔定死的 creator ——
                     调用方一个字节都改不了收款人（pull 模式，决策 49）
```

> 🔴 **金库不再经手到期余量**（2026-08-09 决策 ①）：原 `claimExpired()` 路径会让稳态下约 `S/f` 规模的全池资产**每周经过一次金库**，把在途窗口从「一天的税收」放大成「整个池子」；在 #58 前它还额外暴露给 Guardian 升级。到期结算与滚存改在 ClearingPool 内部完成（`settleExpired` / `rollExpired`，任何人可调），托管权永不出池。

> **金库无第二次采购、无 buyback** —— Flap TaxProcessor 在 dispatch 前完成 MEME 税的 swap-back；`quoteToken` = 股票让金库不必再买一次，strike 以 MEME 计价则让行权直接销毁。
>
> `processRevenue()` **不放在 `receive()` 里**，避免在转账回调中做重活影响 Flap 的 dispatch。日常由**我们自己的 Trigger Service / keeper**定时调用，函数本身仍无许可。

### 6.2 ClearingPool（我们自己，**不可升级**，平台级每链一个）

```solidity
function openSeries(address meme, address stock, uint64 expiry, uint128 strike) external returns (uint256 seriesId);
function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount) external returns (uint256 minted);
function exercise(uint256 seriesId, uint256 amount, address beneficiary) external;
    // 权证烧 msg.sender、MEME 从 beneficiary 拉取并销毁、股票发给 beneficiary；声明门查 beneficiary
    // 仅 beneficiary 本人或 MerkleDistributor 可调（决策 ③）
function pokeGating(address stockToken) external;               // 任何人：记录发行方门控状态翻转（决策 ②）
function settleExpired(uint256 seriesId) external;              // 任何人：要求已过窗口且无门控 —— 门控中被阻止 = 自动延期
function rollExpired(uint256 seriesId, uint256 nextSeriesId) external;
    // 任何人：到期余量池内直接记入后继系列并铸给 distributor —— 托管不出池（决策 ①）
```

**每个系列单一出资方**：`seriesId = keccak256(memeToken, stockToken, expiry)`，记 `(strike, 已存入, 已铸, 已行权, 是否已结算)`。

> 🔴 **此处已按 [`spec.md`](./spec.md) §2.1 修正。** 原设计让权证跨项目同质（`seriesId` 只含标的与到期日），**不可行** —— 行权销毁的是**该项目自己的 MEME**，支付资产不同就不可能是同一资产。
>
> **意外收获**：每个系列因此只有一个出资方，原本"多项目按存入比例分账"的整块账目**可以删除**，合约显著简化。

**接口只有六个，无 admin、无 pause、无 withdraw、无 upgrade。**（2026-08-09 接口冻结评审定案：原 `claimExpired` 废除，新增 `pokeGating` / `rollExpired`、`exercise` 加 beneficiary —— 完整规格与理由见 [`spec.zh.md`](./spec.zh.md) §5.1）

> **部署时如何绑定**（决策 29）：`ClearingPool` 的构造参数依赖 Warrant 与 MerkleDistributor，而两者又都要知道 pool 地址 —— **三方环，靠排序解不开**（CREATE2 地址由含构造参数的 init code 推导）。解法是把"可写一次"的槽放在两个**卫星**合约上（`setPool`，仅部署者、写后锁死），**池子本身的四个地址保持真 `immutable`，部署后无任何写入路径**。信任集中在哪里，不可变性就留在哪里。

> **"冻结时自动延期"的实现**（决策 ②）：行权的判定从"未过 expiry"改为"未结算"；`settleExpired` 要求当前实时读取无发行方门控（`paused()` / `isBlocked(pool)`，公开 view）——**门控中结算被结构性阻止，行权窗口保持开放，延期无需任何管理员**。若发行方仍阻止股票转账，`exercise` 会整笔回滚，权证与 MEME 不动；发行方一解除，行权立刻可用（**不必等 `pokeGating`**），而观测到解除会把无限的窗口收敛为 `max(expiry, clearedAt + 48h)`。view 读取失败按 fail-open 处理（避免结算/回收永久死锁），Monitor 单独告警。不变量 4 已相应改写（spec §7）。

### 6.3 Warrant（ERC-1155）

按 `(项目 meme, 标的, 到期日)` 分系列。**同一系列内完全同质、可自由转让**（无按人折扣）——这是 Seaport 撮合与部分成交的前提。

### 6.4 OTC 结算：复用 Seaport 1.6

**v1 已核实部署情况**（2026-08-07，Robinhood Chain 上 `eth_getCode` / Blockscout 实读）：

| 组件 | Robinhood Chain |
|---|---|
| Seaport 1.6 `0x0000…B395` | ✅ |
| ConduitController `0x0000…Ad63` | ✅ |

BSC 上的部署记录只保留在历史调研中；它不是 v1 的集成依赖。未来 BSC 版本须重新确认地址、字节码与接入假设。

**模式（M5-0，2026-08-25 已冻结）**：卖方链下签一张标准 `PARTIAL_OPEN` 卖单（**零 gas**）→
OrderbookService 严格接纳并投影 → 买方通过 `fulfillAdvancedOrder` 提交签名 → Seaport 验签并**原子交换**。
货始终留在卖方钱包，成交那一刻才划走。官方订单流只收 GME；不接 ETH/WETH、买单或 bundle。

**为什么适配我们**：ERC-1155 原生支持且可**部分成交**（挂 100 张、吃 30 张）；挂单与链下软下架零 gas，
适合每周换系列的高频改价；taker fee 可直接编码为订单里的一项股票代币 consideration **自动分账**。
真正撤销签名仍须 maker 发链上 `cancel`，紧急批量失效则用 `incrementCounter()`。

**我们仍需自建**：链下订单簿服务（存签名、按系列聚合精确深度、canonical/reorg 状态投影）、规范订单构造器、
挂单/吃单前端、到期系列的订单清理与 fill/cancel/approval calldata prepare。
→ **Seaport 承担"合约与资金安全"，我们承担"市场的产品与运营"** —— 后者本就是护城河所在。

**代价**：maker 须直接 `setApprovalForAll(Seaport, true)`，taker 须直接给 Seaport 精确 GME allowance；
订单结构与 reorg 生命周期字段较多，有接入成本；引入不可热更新的外部依赖。ConduitController 虽在链上有部署，
但 v1 的两个 conduit key 都是零，**它不是依赖**。完整口径见 spec §6.6.1。

**替代**：自写最小 EIP-712 结算合约（约 150 行）—— 完全可控但安全责任自负。**不推荐**：结算层直接触及用户资金，不值得自己冒险。

---

### 6.5 资金流与收入分配

一笔 100 单位交易额的去向（买 / 卖税各 3%；曲线费另计）：

```
交易额 100
  ├─ 买 / 卖税                3.00
  │   ├─ Flap 协议费          ≤0.30  → Flap
  │   ├─ 集成方 commission    0.06   → 我们（协议强制，自动累计）
  │   └─ 税收余额             2.64   → 金库 → 存入 ClearingPool → 铸造 Warrant
  └─ Bonding curve 费 1%（仅曲线阶段）  → Flap（与 3% 税分开收取，不从税收余额扣）
```

**Warrant 拿到税的约 88%**（`2.64 / 3.00`）；唯一的自动化收入是集成方 commission **0.06% 交易量**。

> 🔴 **issue #58 永久移除了 Flap 金库模板路径，也一并移除了那笔 0.06% 的金库模板方 commission。** 现在没有第二笔自动抽成；金库与清算池收到的就是扣除 Flap 协议费和集成方 commission 后的 2.64% 税收余额。

### 🔴 一条红线

**行权时绝不能从股票里抽成。** 池内 100 单位对应 100 张 warrant，每次抽成会让最后一批持有人领不到货 —— **1:1 不变量被打破，"结构性偿付"当场作废**。这是伪装成手续费的偿付漏洞，实现时极易顺手写入。

---

### 6.6 AttestationRegistry：链上签署的合规证据

**来源**：借鉴 StonkBrokers 的做法 —— 用户在链上签署 immutable 文本的哈希，前端无法篡改（[`research/stonkbrokers-playbook.md`](./research/stonkbrokers-playbook.md) §11）。完整合约设计见 [`spec.zh.md`](./spec.zh.md) §5.5。

**为什么现在做**：`ClearingPool` **不可升级**，行权函数的签名与检查逻辑部署即定终身。**合规钩子不是"以后想做再加"，是"现在不留口子就永远没有"。** 这与 R1（早期不做期权合规）不冲突 —— R1 说的是不建合规体系，不是把门焊死。

#### 门开在 `exercise()`，不开在 `claim()`

| 用户动作 | 触及代币化股票 | 需要声明 |
|---|---|---|
| 持有 MEME、累积、`claim()` | ❌ 拿到的是权证 | 否 |
| 卖出权证（Seaport） | ❌ | 否 |
| **`exercise()`** | ✅ | **是** |

StonkBrokers 的分层在**资产**层（改选 `USDG` 等非受限资产，是安慰奖）；**我们的分层落在动作层，且是平级选项** —— 权证本身可转让，受限用户可以只卖不行权，而卖出常常还是更优的经济选择。

#### 🔴 只记录，不阻断

**任何管理员可控的行权前置检查，都是一个可以冻结全体用户资产的节流阀。** 合规 admin 私钥一旦丢失或被夺，全部权证永久变砖 —— 我们对外承诺的"清算池不可升级、无 admin 提取路径"当场作废。

所以声明状态设计为：**单调不减、仅本人可写、任何人（含 publisher）无法撤销**；`versions[0]` 永久存在，**任何地址在任何时刻都能自行满足门槛**。链上只要求"≥1 次声明"，前端要求"最新版本"，文本更新不追溯失效。

> **这道门在结构上不可能被用来锁死任何人。** 该性质由 spec §7 **不变量 6** 强制，与"无管理员出口"同级。

#### 文本只写事实，不下法律结论

StonkBrokers 的 `TERMS_TEXT` 断言"这是营销服务报酬，不是分红"。**我们不照抄这类措辞**：

- **事实性自述**（"我不是美国人"）价值高 —— 只有用户自己知道的事实，谎报责任在其本人
- **法律结论性断言**（"这不是分红"）价值低 —— 认定看实质不看措辞，写了反而显得刻意

我们的两段文本全部为事实陈述（全文见 spec §5.5）。顺带一提：**我们的行权是付出对价的交换**（销毁 MEME 换股票），StonkBrokers 是白送 —— 这个区别是实质性的，不需要包装。

#### 它覆盖不到什么

只覆盖"谁能收到股票"，**不覆盖"我们发行了什么"与"我们运营了什么市场"**（见 R12）。且自我声明不可强制执行 —— 签完转到另一地址行权，链上拦不住。**它买到的是证据与善意，不是强制力。** 对外文案不得暗示更多。

---

## 7. 参数表

| 参数 | 值 | 说明 |
|---|---|---|
| **`quoteToken`** | **绑定的那只股票**（首发 **GME**） | 交易对 = MEME/GME；TaxProcessor 将 MEME 税 swap-back 成 GME 后 dispatch，金库不再执行第二次采购。GME 在普通 `Portal` 的计价配置已启用（块 17,391,936 起），**D0 走的正是这个入口**，分叉实测已跑通全链路；被拒的只是 VaultPortal 的带金库入口，D0 不走它 |
| **`k`** | **0.8** | `strike = TWAP × 0.8`，系列开启时 20% 实值 |
| **strike 计价** | **MEME**，行权即销毁 | 见 §4 |
| **strike 取价** | **系列开启前 24h TWAP，每系列一个** | 每次铸造各算会打碎系列同质性 |
| **铸造频率** | **每日一次**，由我们自己的 Trigger Service / keeper 触发 | `script/trigger-keeper.sh revenue`；在途资金窗口 ≤24h |
| **普通 Portal 的可选 quote 标的**（Robinhood） | ETH + Portal/ForkConfig 支持的 ERC-20 stock quote token | Flap 按 quote token 配置 bonding curve；产品合约保留全量支持。staging 最初以 `frontend/app-config.staging.json` 发布并验收 GME、SPY、NVDA、TSLA、AAPL、PLTR、HOODon 七项；**2026-09-03 起发布清单改为 Portal 已启用的全部 ERC-20 计价币减去 HOODon，共 24 项**（原生 ETH 因金库要求 ERC-20 而排除；HOODon 因无 `uiMultiplier()` / issuer registry 而排除）。 |
| **税率** | **买 3% / 卖 3%（暂定）** | 历史 BSC MarsCoin 样本只作为参数起点；Robinhood Chain v1 上线前须在目标链核验配置与实际行为 |
| 🔴 **`taxDuration`** | **100 年（上限）** | **官方示例写的是 365 天 —— 照抄会让项目在上线一年后无声死亡**（税停 → 无股票进池 → 无 warrant） |
| 税收分配 | `mktBps=10000`，其余为 0 | 金库路径强制：**扣除 Flap 协议费与集成方 commission 后**的税收余额全部进我们的 vault |
| 总供应 | **10 亿**（固定） | Flap 平台统一，非我们可选 |
| Indexer `minimumAverageBalanceRaw` | **10,000 MEME × 10^18 raw**（0.001%） | M4 归属政策：比较 `candidateWeight >= minimumAverageBalanceRaw × durationSeconds`，等号通过；未达者不出 leaf 且不进分母。🔴 与 Flap 的 `minimumShareBalance` 不是同一字段；launcher 因 `dividendBps == 0` 将后者固定为 0 |
| `antiFarmerDuration` | **1 天（仅开发 / 测试占位，最终值未决）** | 历史 BSC MarsCoin 样本为 30 天，但不得据此确定 Robinhood Chain 参数；须先在目标链确认语义与可用取值 |
| **到期** | **每周五 21:00 UTC** | 行权不需结算价，故夏令时漂移无经济后果 |
| **最短寿命** | **≥7 天**（新铸造归入下一个周五） | 同时活跃系列恒为 2 个 |
| **每项目标的数** | **1 只** | 绑篮子会立刻打回碎片化 |
| **持有打折 / Evolution** | **不进 POC**，仅官网叙事 | Meme 代币由 Flap 提供，我们无法加字段 |
| **OTC 撮合** | 链下订单簿 + Seaport 链上结算 | 挂单/软下架零 gas，真正取消上链；官方 v1 只收卖单并支持精确 lot 部分成交。**AMM 不适用**（期权时间衰减会磨死 LP） |
| **OTC 费率** | **`marketOpenedAt` 后前 56 天 0%，之后 50 bps**；独立股票代币（`Series.stockToken`）consideration 由 taker 在 maker 报价之上支付 | maker proceeds 不扣平台费；切换前已接纳零费订单 grandfathered（决策 47 / spec §6.6.1） |
| **行权费** | **不收** | 行权同时驱动通缩与 OTC 买盘，是最该最大化的动作 |
| **平台收入** | **集成方 commission ≈0.06% 交易量** + OTC taker fee | #58 移除了金库模板方 commission；只剩协议强制的集成方 0.06%，费率仍由 Flap 公式框死 |

---

## 8. 我们自己的 UI 承载什么

Flap 前端**没有 Warrant 的概念**，以下全部只能是我们的：

| 模块 | 内容 |
|---|---|
| **发射** | 调**我们自己的 launcher**（决策 39 / 路线 D0），选股票、名称与 vanity salt —— 税率等经济参数已固化为合约常量（决策 40-②）；它内部走普通 `Portal.newTokenV6` 并在同笔交易里建金库、写身份根。✅ D0 三张实现票已全部落地（#56 / #57 / #58，§10-39/40） |
| **项目页** | 金库累计买入、Warrant 发放量、当前两个活跃系列 |
| **我的 Warrant** | 持有量、内在价值、到期倒计时、一键行权 |
| **OTC 市场** | 挂单 / 吃单 / 深度图 |
| **到期日历** | 每周五的到期事件（天然的社区内容节奏） |

**最关键的触点是"到账通知"**，三个动作要并列摆出，对应设计里的三选一：

```
Your weekly tax just minted you 142 GME Warrants
Expiry: 7 days  ·  Strike: 1,850 $MEME per GME

[ Exercise Now ]   [ View Warrant ]   [ Sell on Market ]
```

Warrant 详情页要说清它**不是**什么：*"This is not the stock. It is the right to buy the stock token — itself the issuer's price tracker, not a share."*（2026-08-09 修订：原句 "your right to buy the stock" 会暗示行权拿到的是股票所有权，与 Robinhood Stock Token 的债权凭证性质不符）

---

## 9. 叙事层

### 9.1 两层叙事，不要混讲

我们现在是平台，不是单一代币，因此有**两个不同受众**：

| 层 | 对谁 | 一句话 |
|---|---|---|
| **平台层** | 想发币的项目方 | "在别处发币，你的持有者拿到几毛钱的股票碎片；在这里，他们拿到一张能行权、能卖、能赌的凭证。" |
| **持有者层** | 买 meme 的人 | "持有 MEME，每周领到一张 GME 看涨凭证。烧掉 MEME 就能换成代币化股票。" |

**不要把两层混在一句话里** —— 项目方关心"我的社区会不会更活跃"，持有者关心"我能拿到什么"。

### 9.2 最有力的一块砖：碎片化论证（已实证）

对历史 BSC 样本 MarsCoin（当时市值 $61.8M、23,846 持有人）做过链上拆解（`research/flap-dividend-fragmentation.md`）；以下只作产品机制对照，不是 v1 目标链数据：

| 实测 | 值 |
|---|---|
| **单次领取金额** | **$0.36 – $8.74** |
| 人均累计分红 | ≈ **$60** |

> **一个 $61.8M 的项目，把 $1.44M 切成 23,846 份发出去，单次到账几毛到几美元。**

**我们的对比不是"给得多"，而是"给的东西不一样"：**

> 同样一笔价值：
> **碎成 23,846 份** → 每人一次几毛钱，没人会因此改变行为
> **做成一张凭证** → 可以行权、可以在市场上卖、可以赌它继续涨

**这是算术，不依赖任何行为假设，因此比"我们更去中心化"这类说法难反驳得多。**

### 9.3 措辞边界

| ✅ 可以讲 | ❌ 不能讲 |
|---|---|
| **1:1 全额抵押，无部分准备金** —— 协议层不会超发 | ~~"保证兑付"~~ —— 发行方可 `adminBurn` 销毁池内资产（R2b），**必须带上这个限定** |
| **ClearingPool 不可升级、无 admin 提取路径** | ~~"资产绝对安全"~~ —— 发行方可冻结、可暂停（R2） |
| 每周五到期，节奏公开可查 | ~~承诺 Flap 会展示我们的金库~~ —— 需对方上架，非自动（R10） |
| 手续费结构完全公开 | 主动把 warrant 包装成"投资/理财/收益产品"的措辞 —— 零成本可避免的暴露 |
| **行权前须签署一次链上声明**（事实陈述 + 辖区自述） | ~~"我们已处理合规问题"~~ / ~~"已通过合规审查"~~ —— 声明只覆盖"谁能收到股票"，**不覆盖发行期权与运营市场**（R12） |
| **声明门只在行权路径，不影响持有、领取、卖出** | ~~暗示签了声明就没有法律风险~~ —— 自我声明不可强制执行 |
| **"代币化股票"= 发行方发行的追踪股价的债权凭证**；行权拿到的是代币，不是股份 | ~~"真股票" / "换成真实美股" / "right to buy the stock"~~ —— Robinhood Stock Token 不代表所有权、无投票权与股东权利（发行方公开披露），"真股票"构成实质性误述（2026-08-09，全部文档已校准） |

> **"全额抵押"这句话必须成对出现**：说它的时候同时说"但发行方保留销毁与冻结权限"。只讲前半句，一旦 R2b 真的发生，信任会一次性崩掉。
>
> **"链上声明"同理**：提它的时候必须同时说明它**不等于合规已解决**。把一个证据机制说成一张免责金牌，比不提它更危险。

### 9.4 需要注意的三处措辞变化

1. **"买入零摩擦、卖出才贡献"已作废** —— 税率改为对称 3%/3% 后这条不成立。"奖励留下来的人"现在锚在 **warrant 按持仓累积、卖出即停止累积**上。
2. **不要讲"金库永不卖出"** —— 行权就是股票流出。正确说法：**"金库不在市场抛售；股票只经行权流出"**。
3. **Evolution / 等级 / Diamond 只能讲"未来升级"** —— 本版不实现，且 MEME 合约由 Flap 提供、我们无法加字段。**禁止出现 Claim 按钮**（竞品已出现假 claim 链接钓鱼，不该提供素材）。

### 9.5 5 秒钩子（已定）

> # We don't airdrop the stock. We airdrop the call.

| 用途 | 文案 |
|---|---|
| **主 slogan** | **We don't airdrop the stock. We airdrop the call.** |
| 副标 | **Free calls. Every Friday.** |
| 定位对比句 | **Flap gives you the stock. We give you a tradable warrant.** |
| 备选 | Every trade prints calls.（税率对称后成立：买卖两边都产生 warrant） |

**为什么用期权词汇而不回避**：GME + 海外零售社区里，`calls` / `weeklies` / `0DTE` / `diamond hands` 是**母语而非术语**——2021 年那场逼空本身就是 call 期权驱动的。而我们**每周五到期**的设定与真实周期权节奏重合，是应当放大而非隐藏的巧合。

**⚠️ 早期被否掉的方向及原因**（避免重复走）：

| 候选 | 问题 |
|---|---|
| ~~Burn the meme. Take the stock.~~ | 把 meme 说成要摆脱的东西，与建设社区认同相反 |
| ~~Hold the meme. Get the option.~~ | 太软，"option" 被当术语回避，判断错误 |
| ~~Every Friday, your calls expire.~~ | 制造焦虑而非渴望，且没说清能得到什么 |
| ~~"the longer you hold, the better your strike"~~ | 🔴 **广告了我们没有的机制**，见 §9.6 |

### 9.6 🔴 禁止使用的一类文案：时间加权折扣

外部建议的整套 WSB 文案（Hero、通知、FOMO 进度条、推特草稿）几乎全部建立在 **"持有越久、行权价越便宜"** 上。

**该机制已于设计早期移除，且现在无法实现** —— MEME 合约由 Flap 提供，我们无法在其中记录持仓时长。

**照搬即构成虚假宣传。** 同时它还有两处与本设计冲突：

- **"personal strike"（每人不同行权价）会打碎系列同质性** —— strike 必须每系列唯一，否则 ERC-1155 无法同 id 表示、OTC 订单簿碎裂（§4）
- 它假设 strike 以美元计，我们的以 **MEME** 计

> **v2 的补救路径**：行权价对所有人统一（保住同质性与可交易性），长期持有者改为**行权后获得 MEME 返还** —— 折扣从"改行权价"变为"事后返现"。需链下索引 + 每周 merkle root + 返还合约，并引入"由我们计算并提交快照"的信任假设。**不进 POC。**

### 9.7 必须同步出现的风险文案

- "Warrants can expire worthless if MEME outperforms the underlying stock."
- "This is a call-like claim right, **not** a guaranteed airdrop of shares."
- "1:1 fully collateralized — **but the token issuer retains the power to freeze and to burn**."（§9.3 的成对规则）

---

## 10. 设计决策清单

| # | 决策 | 选择 |
|---|---|---|
| 6 | 产品形态 | Warrant 平台 + 清算所 + OTC 市场 |
| 7 | **实施路径** | **建在 Flap 上**（集成方 + **自建编排层** + **自有金库**），**自建 UI**。⚠️ **2026-08-16 由决策 39 修订**：仍然复用 Flap 的曲线 / 税收 / 毕业 / 索引，但**不再是 Flap 规范金库** —— 发射走普通 `Portal.newTokenV6` + 我们自己的 launcher，金库不可升级、不继承 `VaultBaseV3`。原措辞「第三方金库」指的是 Flap 规范下的第三方 vault 模板，那条路已随决策 39 关闭 |
| 8 | 链 | **v1 只支持 Robinhood Chain（chainId 4663）**；BSC / BNB Chain 留给未来大版本单独立项，不进入当前实现、测试或验收。⚠️ **2026-08-17（M3 W2 / #65）补充**：部署与核验脚本的链 allowlist 增加 Robinhood **公开测试网 46630**。这**不改变 v1 的生产链** —— 46630 承载 M3 B 段彩排里**不依赖 Flap 计价币**的那部分，上面跑的是草稿 version 0 文本（`VersionZero` 的主网闸门只认 4663）。判据不是「它是不是测试网」，而是「我们在那条链上有没有一个 Flap `Portal` 可以建币与取价」。🔴 **2026-08-17 当日更正（#64 收口）**：本条原写「Flap 在 46630 部署了**同版本** `Portal`（`eth_getCode` 非空）」，两处都要收紧 —— ①**不是同版本**：代理同地址、代理字节码逐字节相同，但实现不同、版本不同（测试网 `v5.14.16` / 主网 `v5.15.2`）；②**`eth_getCode` 非空推不出「可以建币与取价」**：那条链上 Portal 全历史**只启用过原生币一个计价币**，我们要的 GME 档不存在，因而在 46630 上**发不出任何能驱动金库的币**（原生币计价过不了 `WarrantVault` 构造函数的零地址防线，也过不了 `PriceSource` 的 quote 对账）。allowlist 该不该有 46630 这一格**不受影响**（部署、接线核验、`AttestationRegistry` 真实签名这些都不碰计价币，正需要它）；变的是**发射 / 金库 / TWAP / 开系列整条搬去 chainId 31337 的主网分叉**，见决策 42-③。落地形式是把 allowlist 与 Portal 字面量合并成 `DeploySystem.flapPortalFor` 一张表 —— 两份各自维护的名单会漂移，而漂移那天没有测试会红；测试网那一格独立写出，同地址是观测结果不是承诺 |
| 9 | 每项目标的 | 1 只股票 |
| 10 | 清算池 | 平台级统一托管；**权证按项目隔离**（`seriesId` 含 memeToken，见 spec §2.1） |
| 11 | 抵押模型 | **1:1 全额抵押** |
| 12 | **`quoteToken`** | **绑定的股票本身**（首发 GME）—— 消掉金库里的第二层采购；Flap TaxProcessor 仍先把 MEME 税 swap-back 成 GME。机制在历史 BSC MarsCoin 样本上有对照，Robinhood Chain v1 仍以目标链核验为准 |
| 13 | **行权价计价** | **MEME**，`strike = 池价 × k`，读交易对自身价格，无外部预言机（§4） |
| 14 | `k` | **0.8** |
| 15 | 通缩方式 | **行权即销毁 MEME** |
| 16 | 到期日历 | 每周五 21:00 UTC，最短寿命 7 天 |
| 17 | 分发方式 | **链下时间加权 + 每周 merkle root**（原 accumulator 方案不可行，见 spec §2.2） |
| 18 | 计价单位 | raw `balanceOf` |
| 19 | OTC 撮合 | 链下订单簿 + 链上结算，仅 taker fee |
| 20 | 可升级范围 | **ClearingPool 不可升级**；~~WarrantVault 按 Flap 规范用 beacon proxy~~ → 🔴 **2026-08-16 由决策 39 修订、issue #58 已落地：WarrantVault 同样不可升级**（拆掉 `VaultBaseV3`，不再走 beacon，工厂每次发射直接部署一只）。这是 **R4 整类消失**的前提：金库不再是任何人能换实现的合约 |
| 21 | 合规 | 早期按 meme 币处理，暂不考虑期权合规（**用户明确决定，见 R1**） |
| 22 | Evolution / 持有时长 | 不进 POC，仅官网叙事 |
| 23 | 平台代币 | **不发**，`feeRecipient` 可切换，为未来留位 |
| 24 | **合规声明存证** | **借鉴 StonkBrokers 的链上签署哈希机制**，门开在 `exercise()`、**只记录不阻断**、文本只写事实（§6.6 / spec §5.5）。**因 ClearingPool 不可升级，必须现在留钩子** |
| 25 | **到期回流路径**（2026-08-09，2026-08-13 落地） | **池内滚存 `rollExpired`**，托管权永不出池；废除 `claimExpired` 经金库的路径（否则全池每周暴露于 Guardian 升级一次，R4 被击穿）。M1-7 已实现并由不变量 5 / 7 锁死（spec §5.1 收口）。🔴 残余敞口：**合法后继由调用方指定**。M2-5（#37）之后它被压掉大半 —— 「合法后继」必须是同一只 MEME 的系列，而那只 MEME 的系列只有它登记在案的金库开得出来，抢注者没有入口造一个来接盘；剩下的是「同一个金库开出的多个后继里选错一个」，属运营问题（发行停发可观测，#42） |
| 26 | **冻结自动延期**（2026-08-09) | **门控感知结算**：行权至"已结算"为止；`settleExpired` 要求无门控 + `max(expiry, clearedAt + 48h)` 的截止已至（permissionless `pokeGating` 记录）；view 失败 fail-open 并写入 `clearedAt`，截止仍按同一 `max` 公式计算；不变量 4 改写并**补第 ③ 款**（`clearedAt` 只随边变化，spec §7-4） |
| 27 | **行权路径**（2026-08-09，2026-08-11 收紧） | `exercise` 带 **beneficiary**（声明门与 MEME 支付都落在受益人）；MEME 必须从 beneficiary 恰好扣除定价额、股票必须从池子恰好扣除行权量，但不要求接收方足额到账；`distributor.claimAndExercise` 兑现"免先领取直接行权"，仅本人可调，**且必须与 `claim` 共写同一个 claimed 位**（spec §5.4） |
| 28 | **claim**（2026-08-09，2026-08-13 落地） | **permissionless**：任何人可代提交 proof，权证只进 leaf 地址；keeper 可代付 gas 批量投递。M1-8 实现时定下的三件事：**① leaf = `keccak256(keccak256(abi.encode(seriesId, account, amount)))`**（系列钉进 leaf，同一份 root 误发两个系列也偷不到东西；哈希两次防 second preimage，与 OZ `StandardMerkleTree` 对齐）；**② 两条路径调用同一个 private `_consume`** —— 「两个入口的门一致」因此是编译器保证的，不是需要有人维护的约定；**③ `amount == 0` 两个入口都拒**，否则 `claim` 会消费掉一张 `claimAndExercise` 永远消费不掉的 leaf（spec §5.4） |
| 29 | **部署绑定**（2026-08-09 复审） | **一次性 `setPool` 绑定，不用 CREATE2**：Warrant / MerkleDistributor 各留一个"仅部署者、写一次、永久锁死"的槽；**ClearingPool 的四个地址仍是真 immutable**。三方构造环由此解开，M1 的最后一处硬阻塞消除（spec §12） |
| 30 | **归属 root 的可变性**（2026-08-13） | **该系列第一张 leaf 被消费之前可改，之后永久冻结**（`rootFrozen[seriesId]`，可读）。两个极端都不可接受：永久 write-once 让一个打错的 root 把整周分发**无法挽回**地错付（无 admin、权证已铸出）；永远可改则等于 publisher 能在分发开始后把剩余份额重新指给任何人。冻结点选在「第一个人依据这份 root 行动」的那一刻 —— 之前改动不伤害任何人，之后改动就是追溯改写 |
| 31 | **distributor 的 publisher**（2026-08-13） | **构造参数 + `immutable`，与部署者刻意分开**：部署者的权限在两笔 `setPool` 之后就用尽，而 publisher 每周签一笔 `setRoot`，必须是热钥匙。部署脚本默认两者相等，主网可用 `DISTRIBUTOR_PUBLISHER` 分开；地址进清单并由 `verify-deployment.sh` 回链上核验。🔴 它是本系统**唯一的中心化信任点**——它决定每周的权证发给谁，但它拿不走任何权证（`claim` 只往 leaf 指定的 `account` 发货） |
| 32 | **金库身份路线的裁决程序**（2026-08-13） | **不直接拍 A/B，改由分叉判据裁决。**「方案 A 分叉验证 spike」立为 **M2 的第一件事**，issue #23 的六条判据说了算：全过 → A（不可变身份根），不过 → B（无许可开系列 + #21）。spike 不开新票，交付永久化 fork 测试（钉死 block）+ `docs/research/` 核验文档 + 六个 checkbox 附证据。**timebox 3 个 agent 工作日**：到点卡在外部事实（Portal 行为与文档不符）即按「不过」裁决；卡在我方 fork 基建修完延**一次**，第二次到点无条件裁决。**判据 5**（Flap 换 Portal 后新项目断档）**可打折**——上游平台风险 B 也躲不开，条件是已绑定项目永不受影响 + 断档有明确失败信号；🔴 **判据 2**（注册面受限）**一票否决**。**若判据过**，A 的形态是：身份根放**独立的、我们自己的不可变 registry**（当时形态为工厂唯一写入；决策 40 后改为 launcher + 预留 slot），与 Flap 低风险徽章要求的 beacon + Guardian 分层，徽章决策因此可推迟而不被堵死；接线关系与决策 29 同构 —— `factory()` → `VaultRegistry(factory)` → `ClearingPool(…, registry)` → `factory.setRegistry()`（这一历史接线随决策 40 被 `launcher.setRegistry()` 取代）；一次性 `setRegistry` 槽只在工厂这个卫星上。**池子零写入路径；registry 只保留 Factory-only、每只 MEME 成功一次即锁死的 `bind`。****若判据不过**，预先接受 B + **书面化**「依赖 Robinhood / Orbit 排序器不抢跑、不审查」的信任假设并签字认残余停发风险（抢注只伤当周发行活性、不伤偿付），条件是 #21 的观测链路必须做齐；对外文案同步补边界句：**偿付 = 结构保证，发行活性 = 运营保证** |
| 33 | **金库权限面为零**（M2-6③ / issue #58；⚠️ 写入口个数与 `creator` 的角色由决策 49 修订） | `WarrantVault` 不继承 Flap 基类、不可升级，外部写入口恰好五个：`sync`、`sampleTwap`、`openSeries`、`processRevenue`、`receive`，均无角色判定。工厂在每次发射直接 `new WarrantVault(pool, distributor, portal, meme, quote)`；五个身份参数在 `CREATE` 那一笔定死，没有 `initialize`、beacon 或 Guardian 权限。`pool` / `merkleDistributor` 来自工厂仅部署者、写一次的 `setVaultTargets`，`portal` 是工厂构造参数，故发射者控制的 `vaultData` / `creator` 不能改变资金去向。⚠️ **2026-08-29（决策 49）**：写入口五个变六个（新增无许可 `claimCreatorFee`），`creator` 从「仅进事件」升为金库第 6 个构造 `immutable`。**「权限面为零」与「发射者不能改变资金去向」两条判据都没有变弱**：新入口仍无角色判定，calldata 里仍没有一个字节能影响钱的去向 —— 新增的那条去向（creator 本人）也是发射那一笔定死的，此后谁都改不了。 |
| 34 | 🔴 **金库身份路线：不可变身份根，双槽写入方**（#56；写入方形态后由决策 40 修订） | `VaultRegistry` 是独立、不可升级的身份根：`factory0` 与 `factory1` 均为构造期钉死的真 `immutable`，无 setter；`factories()` 可枚举、`isFactory()` 可核验。#56 当时第 0 槽是 `WarrantVaultFactory`，第 1 槽是 `PendingLauncherSlot`；两者共用同一张 `_vaultOf`，所以每个 MEME 仍只成功绑定一次，且对外唯一写入函数仍是 `bind`。部署时 pool 指向 registry，Factory 与 slot 分别以一次性 `setRegistry` 回接；枚举、正反 `isFactory` 与两端回接均由 manifest / verifier 核验。⚠️ **当前实现以决策 40 为准**：第 0 槽是 `WarrantLauncher`，工厂不在名单中；`launcher.setRegistry` 取代了 `factory.setRegistry`。 |

| 35 | ⚠️ **税收去向是平台信任，不是结构保证**（2026-08-13，spike 顺带查出） | Portal 的 `changeMarketWallet(token, newWallet)`（`DEFAULT_ADMIN_ROLE` / `TAX_GUARDIAN_ROLE`）能把一只代币的税收改道到别处，**代币、金库、我们的绑定全都不动**；Robinhood Chain 主网上**已经用过三次**，都由那把 2-of-3 Safe `0xa4A727E0…` 执行（它同时是 Portal 与 VaultPortal 两个代理的 ProxyAdmin owner）。**边界**：已铸权证与池内抵押品**不受影响**（池子不可升级、无 admin），可被切断的只有**此后流入金库的税收**。因此对外文案的边界句要补第三项 —— **偿付 = 结构保证，发行活性 = 运营保证，收入 = 平台信任**。与 A/B 无关（B 敞口完全相同），**不是上线阻塞**；另开普通优先级票做 `MarketWalletChanged` 监测 —— **已落地（#43）**：`script/watch-market-wallet.sh`，入口 `script/monitor.sh tax`（2026-08-17 起按需跑，无调度器），边界句已进 playbook 中英两版 §5.1 / §12（风险条目见 R15） |
| 36 | 🔴 **收入路径「收到即存入」，且 R4 从此是一个数**（2026-08-14，M2-3 / issue #35 落地） | `processRevenue()` 读**实际余额**（`balanceOf(address(this))`，不是自己那本账）→ `pool.depositAndMint(seriesId, merkleDistributor, balance)`，铸造量以池内实测增量为准（不变量 2），金库**不断言** `minted == balance`。四处拍板：**①无许可** —— 「加速资金离开一个可升级合约」不该有守门人，何况一个守门人就是本金库的第一个权限函数、会被 rule 001 一并交给 Guardian（决策 33）；调用方**改变不了钱的去向**，因为池子与分发合约是**金库的 `immutable`** 而非发射参数（决策 33 那条「工厂不得把 `vaultData` / `creator` 当作特权来源」的落地形式；🔴 **issue #58 之后它们由工厂在部署金库那一笔里填**，来源是工厂那个仅部署者、写一次、永久锁死的槽 —— 判据没有变弱，calldata 里仍然没有一个字节能影响它们，而「换一份实现把它改掉」这条路也一并没有了）。**②两条边干净返回**：零余额、没有活着的系列（后者发 `RevenueDeferred`，**钱留在金库等下一次**，不静默吞、不存进错误的系列）—— Trigger Service 每天空跑一次，revert 会污染告警；**余额读不出来则如实回滚**，不能静默跳过。**③活系列的判据是 `strike != 0 && block.timestamp < seriesExpiry`**：池子刻意不挡到期后的存入（门控延期），所以这是**金库侧的政策** —— 往行权窗口已关的系列铸权证是发废纸；该判据同时蕴含「未结算」，因此撞不上 `SeriesSettled`。代价是系列间隙里在途窗口被拉长，已量化。**④支出后以实际剩余余额更新 `accountedQuote`，而且那一步写在外部调用之后**（规范 rule 010-3）：存前记为 `balanceBefore`，清零授权后重读为 `balanceAfter`，写入 `accountedQuote = balanceAfter`，并把 `sent` 记为 `max(balanceBefore - balanceAfter, 0)`。正常全额转出时这等价于清零；若代币表面成功却没有扣款，不会虚报支出或把基线清低。提前改基线仍会开一条缝：转账回调里再调 `sync()` 会把基线推回满额，随后真实余额减少，`balance <= accountedQuote` 从此压住一切收入识别，**金库永久死锁且一声不响**；钉在 `test_processRevenue_aReentrantSyncCannotDeadlockTheVault`。🔴 **在途窗口至此是一个数**：决策 49 后为 `f × T / (0.9 × 7天)`，`f=5%`+每日一次 ⟹ **0.79% 池内规模**，见 [`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md)（⚠️ 该文档的量化模型不变，但**结论段已随 issue #58 重写** —— R4 整类消失之后这个数说的是发行与归属，不是「谁能把钱拿走」）。⚠️ **给 M2-4 的硬约束**：必须**先** `pool.openSeries` 成功、**再**写 `strike` / `seriesExpiry`；反过来写会让本函数稳定撞上 `NotSeriesVault`，收入从此出不去金库。⚠️ **2026-08-29（决策 49）**：「收到即存入」修订为「收到即**九成**存入」—— 每批可存收入先切 `CREATOR_FEE_BPS = 10%` 记入 `creatorAccrued`（只在实测扣款成功时累计），其余照旧全额存入；④ 的基线纪律不变，但「正常全额转出时这等价于清零」不再成立 —— 存后基线等于 creator 浮存，`inTransit()` 因此改为返回 `balance − creatorAccrued`，「在途」语义钉死为「本该变成权证还没变的钱」 |
| 37 | 🔴 **开系列：strike 由 24h TWAP 定，时刻由 24 小时窗口锁**（2026-08-14，M2-4 / issue #36 落地；**③那道票面没点名的门已由维护者当日确认采纳**） | `openSeries()` **无入参、无许可**：`strike = TWAP × 8000/10000`（决策 14），`expiry` = **第一个**满足「寿命 ≥7 天」的周五 21:00 UTC。四处拍板：**①周五对齐是纯算术** —— Unix 纪元是周四，故周五 21:00 UTC ⟺ `t % 7 days == 45 hours`，把 `now + 7 天` 向上取整到该边界即可；寿命因此恒落在 `[7 天, 14 天)`。闰秒与夏令时改不动它（Unix 时间不计闰秒、UTC 无夏令时），两条各有测试而不是一句注释。**②对 TWAP 六个状态全部 fail-closed** —— 只有 `0` 放行。strike 一周只定一次、决定整周发行量：**停发一周有人工兜底，定错一周没有**。折让取整成 `0` 或装不进 `uint128` 时同样拒绝，且报的是我们自己的人话而不是池子的 selector。**③🔴 新增一条票面没点名的门：`OPEN_WINDOW = 24 小时`**（实现时补上，**维护者已于 2026-08-14 确认采纳**，非遗留待议项） —— 只有当前系列剩余不到 24 小时、或已经到期，才开得出下一期。理由：无许可意味着调用方挑不了参数，**但挑得了时刻**，而 strike 一周只定一次；没有这道门，任何人都能在一周里任选一小时把整周行权价定死。这不是价格**操纵**（那一面由决策 33 / M2-2 的采样界压住），而是价格**选择**，TWAP 结构上挡不住。装上之后可选区间从「一周」压到「24 小时」，而相邻两个 24 小时窗口的 TWAP 高度重叠。代价是活性，但**到期之后门自动打开**，任何人都能立刻补开一期（按 ≥7 天规则落到再下一个周五）—— 活性没有被换掉，只是晚一点。**④两条干净返回边**：本期已开、以及还没到开下一期的时候，都返回 `(当前系列, false)` 而**不 revert** —— 与决策 36 同一条纪律：分界线是「该不该开」而不是「有没有开成」，把日常空跑做成 revert 等于让告警从第一天起淹在噪声里。**停发可观测**（issue #42 的链上抓手）交给 `openSeriesStatus()` 这个 **view**：它与 `openSeries()` 共用同一个私有判定函数，因此**不可能给出不同的答案**；它**不转发** TWAP 自己的六个码，那六个码的权威出处只有 `twap()` 一处。写入顺序遵守决策 36 的硬约束（先 `pool.openSeries` 成功、再写字段），反证测试 `test_openSeries_writesNothingWhenThePoolRejects`。⚠️ 顺带：`vaultUISchema()` 的 17 条声明被收进一个 `_method` 辅助函数 —— 展开写法每条约 750 字节，17 条就是 13KB，而合约总共只有 24,576 字节，M2-4 加进来会**超出 EIP-170**。收口后返回的字节逐字节不变，由 `test_vaultUISchema_hasNotDriftedFromTheDeclaredBytes` 的哈希钉住 |
| 38 | 🔴 **工厂的最终形态：两个一次性槽、直接部署金库**（#58；调用方与绑定职责由决策 40 修订） | `WarrantVaultFactory(flapPortal)` 的 `portal` 是取价构造参数。两个一次性槽仅部署者可写一次并永久锁死，缺任一槽时 `newVault` fail-closed；接线完成后工厂直接 `new WarrantVault(...)`，不存在 beacon、implementation、proxy 或 Guardian 升级权。⚠️ **两处已被决策 40 修订**：① 调用者门从「按 chainId 硬编码的 VaultPortal」换成 `factory.launcher()`（`setRegistry` 槽随之换成 `setLauncher`）；② 同笔 `bind` 搬去 launcher —— 工厂此后不碰身份根，也不在写入方名单上。 |
| 39 | 🔴🔴 **发射路线 D0 与未来自建栈的并存后手**（决策 39） | D0 通过普通 `Portal.newTokenV6` 与自建 launcher 创建代币、金库和绑定；未来自建栈只能与既有 Flap 项目并存、共用同一 ClearingPool，不能迁移已发 MEME。#56 已交付双槽 `VaultRegistry` 与 `PendingLauncherSlot`：slot 的 `setRegistry` / `setLauncher` 均仅部署者、写一次、永久锁死，未启用时 `bind` fail-closed，启用发 `LauncherSet`。部署为 7 次 CREATE，随后 5 次不可逆写入：两处 `setPool`、Factory / slot 各一处 `setRegistry`、Factory 的 `setVaultTargets`。#58 已交付不可升级、构造参数取价的直接部署金库；#57 launcher 编排层**已于 2026-08-17 交付**，见决策 40（部署因此变成 **8 次 CREATE + 6 次不可逆写入**，且名单第 1 格是 launcher 而不是 Factory）。预留位的诚实成本与运营义务不变：部署者权限须有保管方案，启用时公示 launcher 源码和地址，并把 `LauncherSet` / `LAUNCHER_ARMED` 的状态、事件、接线路径和精确确认记录纳入 Monitor。 |
| 40 | 🔴🔴 **D0 编排层落地：`WarrantLauncher`**（2026-08-17，#57） | 一笔交易 `launch(name, symbol, meta, salt, quoteToken, antiFarmerDuration)` 完成五步：预检 → `factory.nextVault()` 取金库预告地址 → `Portal.newTokenV6(beneficiary = 该地址)` → `factory.newVault(token, quote, msg.sender)` 并逐位核对 → `registry.bind(token, vault)`，返回 `(token, vault)`。五处拍板：**① 先算金库地址再建币** —— 发射参数的 `beneficiary` 就是 `TaxProcessor.marketAddress()`，由 Flap 在建币时写死、此后只有那把 2-of-3 Safe 改得动（决策 35），所以建币那一刻是唯一机会。预测的是**我们自己的** CREATE 地址（工厂只做那一处 `CREATE`，`nextVault()` 由 `vaultsCreated + 1` 推 RLP），核对的是那次 `CREATE` 的返回值 —— 与决策 34 里「预测别人的地址、由别人核对」形状相反。🔴 **这一条偏离了 #57 票面那句「不需要 CREATE2 预测地址」，属于实现时新增的取舍，维护者已于 2026-08-17 确认采纳**（票面同时要求 `TaxProcessor.marketAddress() == 金库`，两者只能满足一个）—— **非遗留待议项**，与决策 37 ③ 的 `OPEN_WINDOW` 同一类。**② 经济参数固化为 `constant`**（GME quote、`dividendToken == quoteToken`、买卖各 300 bps、`taxDuration = 100 年`、`mktBps = 10000`、其余 bps 全零、`TOKEN_TAXED_V3` / `V2_MIGRATOR` / `FOUR_FIFTHS` / `DEX0`），链上可读 `launchEconomics()`；`commissionReceiver` 是 `immutable` 而不是入参 —— 否则任何人都能拿我们的 launcher 发一只把分成打给自己的币。调用方只决定名称/代码/元数据、salt、计价币与 `antiFarmerDuration`（§14-2 未决，暂留参数）。**③ vanity salt 链下挖**：合约里没有挖矿循环，否则一笔发射变成不可预算的 gas 赌博；挖错了 Portal 自己会拒。**④ 判据 2 更强**：`bind` 的第一个参数只可能是 `newTokenV6` 的返回值，launcher 没有第二条通往 `registry.bind` 的路径，`launch` 的入参结构体里也没有任何一格能放一只已存在的 MEME —— 由写入面枚举 + 结构体成员枚举双重钉住。**⑤ `launch` 无许可**：从前任何陌生 EOA 都能拿我们的工厂去调 VaultPortal，这条路径本来就是公开的；加白名单只会凭空造出本系统第一把运营钥匙，却挡不住任何真正危险的事（抢注结构上不可达、抵押品按系列隔离）。配套改动：身份根名单**第 1 格从工厂换成 launcher**（工厂不再碰身份根，部署脚本与 `verify-deployment.sh` 各加一条负向核验）；工厂脱掉 `VaultFactoryBaseV2` 与五个 Flap 规范钩子（它们只为 VaultPortal 那条入口存在）；部署从七合约五处一次性写入变成**八合约六处**。 |
| 41 | **权威清单是一个区块的快照**（2026-08-17，#20） | `verify-deployment.sh` 在第一次链上读之前取一次头块高度，此后每一次 `cast code` / `cast call` 都带 `--block <该高度>`，晋级时原样写出同一个 `verifiedAtBlock`。修的不是某一行读数而是**全部**读数 —— 只钉住一条，剩下的仍是跨区块拼接，「快照」二字没有落点（票面只框了 `versionCount()`，因为只有它有明确的合法 actor：publisher 随时可 `addVersion`；维护者triage 时把范围扩到全部读）。**这里的拍板是「钉当前头块、不往回退」**：回退几块能换来时间余量，但那要求归档节点，而分叉侧已经为此付过代价（#15 / #16 / #25）。⚠️ 代价是这条保证**靠端点的实际保留窗口**，不靠「头块总是安全」—— 这条链出块约 0.1 秒（实测 1000 块 100 秒），geth 默认的 128 块状态窗口在这里只有约 **13 秒**，而一轮核验要打约 43 次串行 RPC；实际用的端点没那么薄（官方实测 6k–20k 块 ≈ 10–30 分钟）。真撞上了是 fail-closed：状态过期 → 读失败 → 不晋级，不会给出错的答案。🔴 对下游的含义：在 latest 上复核这份清单时读数**可以**合法地不同（例如 publisher 后来追加了文本版本），那不代表清单是假的 —— 要复核就带上 `--block <verifiedAtBlock>`。 |
| 42 | 🔴🔴 **发射栈不迁移；B 段彩排改用「改了 chainId 的主网分叉」**（2026-08-17，承接 #64） | M3-W1 的探针查出：**Robinhood 测试网全历史只启用过原生币一个计价币**，`QuoteTokenNotAllowed`（`0x9a5c8a92`）拦的是 Flap 的**配置**而非代币形状，因此那条链上**发不出任何能驱动我们金库的币**（原生币计价过不了 `WarrantVault` 构造函数的零地址防线，也过不了 `PriceSource` 的 quote 对账）。据此四处拍板：**① 生产路径不动。** 这件事**不影响生产** —— 主网 `getQuoteTokenConfiguration(GME) = (1, 29, 29, 7, 0)` 已启用（自区块 17,391,936），实现自 22,337,500 未变，D0 的前提「全程无需 Flap 注册或授权」原样成立；同日 `test/fork/` 全套在主网 latest 分叉上 **89 passed / 0 failed**。需要 Flap 配合的只有彩排。**② 不换发射栈** —— 评估见 [`research/robinhood-launchpad-alternatives.md`](./research/robinhood-launchpad-alternatives.md)：**自建 Portal** 接口层几乎零成本（曲线已逆向到逐位复算、`PendingLauncherSlot` 已按决策 39-D 预留、`WarrantLauncher` 只需换掉内部调的那个 Portal），但协议层是一个完整 launchpad —— 数月 + 外部审计，且**信任叙事反转**（用户的钱要先经过我们写的曲线，与「抵押品只住在不可升级的池子」方向相反）与**零流动性冷启动**（Flap Portal 363,362 笔交易 vs 从零）。它是**后手不是彩排解**：自建之后彩排对象就不再是生产环境，**彩排一个和生产不同的发射栈等于没彩排**。**pons** 则不是备选而是另一个产品：链上实测 `launchConfigCount() = 1` 且唯一那条是 **WETH** 计价、**没有转账税**（只有 1% V3 池费按 creator/protocol 分账）—— 没有股票代币流入就没有抵押品也没有权证，改造它等于推翻决策 13（strike 无外部预言机）。⚠️ 方法上一并记下：**不采信 pons 官方文档**（它称工厂里不可能有 GME，链上读数相反），全部结论用链上直读。**③ B 段搬到 `anvil --fork-url <主网归档端点> --chain-id 31337`**，评估见 [`research/fork-as-rehearsal-environment.md`](./research/fork-as-rehearsal-environment.md)：状态是主网的（真 GME、真曲线、真税收 dispatch，**GME 计价发射是默认行为**），而 `chainid ≠ 4663` 让 `VersionZero.requireDeployable` 走非主网分支 —— **#67 票面红标的「主网闸门在分叉上会启用」被一并解决，不必给部署脚本开逃生口**。✅ **不用改任何代码**：#65 那张 `DeploySystem.flapPortalFor` 表里 `31337` / `31338` 两格返回的正是 `FLAP_PORTAL_ROBINHOOD`（主网 Portal 地址）—— 而主网分叉上那个地址躺着的就是真 Portal，两边天然对上。两条纪律：**必须用归档端点**（公共端点只留 ≈6.1k 块 ≈10 分钟状态，实测把 anvil 钉在 `head−20,000` 时它**连起都起不来**），**且 chainId 用 31337 不用 46630**（后者的 `deployments/46630.json` 会进版本库被后续里程碑当真）。分叉在两处**强于**公开测试网：GME 计价发射、以及按需 `anvil_reorg`（索引器最难测的部分）；**四个坑**里终局性节奏那条是绿着骗人的 —— 真链 `latest − finalized ≈ 11,938 块（≈20 分钟）`，anvil 上只差 63 块。测试网唯一真正赢过分叉的「RPC 可靠性」可单独拿：让 keeper 只读挂在真实端点上跑。**④ 启动自建栈的判据写死为三条**：canary 的 codehash 钉子变红且复核发现语义变了、**GME 计价配置被撤销**（见 R16）、或 Flap 停止维护本链。在这三条之前启动，是拿已验证的依赖换未验证的自研。**⑤ 2026-08-18 补记（随本决策的票面收口一并定掉）：不去找 Flap 在测试网开一只 ERC20 计价币。** 彩排既已搬到分叉，这件事就没有需求方了；顺带记下它的真实成本，免得日后有人以为是「发个消息的事」—— 它是**两步不是一步**（先升级测试网 Portal、再配置计价币：主网给 GME 用的那档曲线 `CURVE_RH_25_ASSET`（29）不在测试网 v5.14.16 的 `CurveType` 里，传 29 当场空 revert），而 `DEFAULT_ADMIN_ROLE` 持有人不是我们（探针 §5.1）。**落地形态**：#67 / #69 票面已按本决策重写（原票面写于 #64 之前，正文里的三处前提已被证伪）；**那条长跑的分叉链单列 [#79](https://github.com/quiz42/index-rein/issues/79)** —— 起链、归档端点、`anvil_dumpState` 恢复与对外接入，A 段（#67）、B 段（#69）与 M4 Indexer 依赖的是同一条链，此前它不属于任何一张票。 |
| 43 | 🔴 **keeper 的采样节奏与漏拍判据 —— 两处推翻 #68 票面字面的取舍**（2026-08-17，维护者追认，采样周期由维护者于 2026-08-21 正式定为 90 秒） | **① 采样是「每 90 秒轮询、由合约自己挡」，不是票面写的「每小时一次」。** 合约钉死 `SAMPLE_INTERVAL = 3600` 与 `MAX_SAMPLE_GAP = 3900`，**两者之差 300 秒就是全部运营余量**；每小时跑一次意味着一次失败就把余量吃光，下一次机会在一小时后 —— gap 必破，而破了要重建一整套严格 24 小时窗口（约一天），撞上周五窗口则损失一个周周期。保守调度算术把 timer phase、`AccuracySec=5`、首次失败后的完整受管生命周期 `L=85` 都算入：`3600 + 2 * (90 + 5) + 85 = 3875 < 3900`。🔴 额度吃紧时**先优化 `sample` 的读取次数**（它只需要 `lastSampleAt`，现在与其它动作共用代码读了 5 个 view），**不要拉长轮询周期** —— 后者是在花我们没有的那 300 秒。🔴 `sample.timer` 的 `OnUnitActiveSec` 与 `KEEPER_SAMPLE_POLL_SECONDS` **必须相等**，`watch` 用后者算「采样器多久没跑算死了」；只改一个，停摆判据会**安静地**失灵。**② 「上次采样 > 55 分钟即告警」改为「55 分钟时去查采样器还活着吗」。** 字面版每小时误报一次 —— 样本按设计就要老到 60 分钟才允许写下一条，健康峰值本就在 60–63 分钟，而每小时误报一次的告警器会被静音，**静音掉的告警器等于没有告警器**。更根本的是**样本年龄给不出提前量**：55 分钟时健康的与坏掉的长得一模一样；唯一能提前说话的是**采样器进程还在不在跑**（心跳每 90 秒该动一次，超过 270 秒即告警）。四档：采样器停摆（271 秒内）／该写没写（63 分钟）／上限已破（65 分钟）／55–60 分钟且采样器活着（**不报**）。已确认没有漏报 —— 字面版在 3300–3600 秒那一段能报的东西，那一段里本来就没有东西可报（合约不允许写，「没写」是规则不是失效）。字面阈值保留为 opt-in：`KEEPER_MISSED_BEAT_ALERT=1`。**③ 连带**：`watch` 自己死了没有任何东西会说话（沉默与健康在输出上一模一样），补法只有外部死人开关且**必须演练过一次** —— 单独立票 **#77**，并已建立 **#69 blocked_by #77**。推导写在 `script/trigger-keeper.sh` 头部与 `docs/spec.zh.md` §9；处置见 [`trigger-keeper-runbook.zh.md`](./trigger-keeper-runbook.zh.md) |
| 44 | 🔴 **本仓库接受它的第一个 node 依赖：root 只用官方 `StandardMerkleTree` 算**（2026-08-18，#66） | 归属 root 的构建、复算与 claim 辅助落在一个 node 包 `offchain/merkle/` 上，直接依赖只有 `@openzeppelin/merkle-tree`（**精确版本 `1.0.8`，不是 `^1.0.8`**）+ `ethereum-cryptography`，传递依赖钉在 `package-lock.json`。**判据不是「哪个省事」，是「哪个更容易向第三方证明 root 是对的」** —— `docs/spec.zh.md` §9 对 Indexer 那行写死了「算法与复算脚本必须开源，**任何人可独立验证 root**」。🔴 这条承诺有一个**往返测试抓不到**的失败模式：内部节点用可交换的 sorted-pair 哈希，所以**任何**自建树都能产出一对能通过 `MerkleProof.verify` 的 (root, proof)，我们的 proof 对我们的 root 当然过；而 OZ 的 `StandardMerkleTree` 对 leaf 另有一套确定的排序与布局规则，排序差一点 ⇒ **root 就是另一个值**，两份还各自自洽 —— 第三方拿官方库照我们的公开输入复算才会发现对不上（§5.4 ① 的 2026-08-18 补记）。自己实现（纯 Solidity / forge script，零新增依赖）要连同「与官方库逐位一致」的证据一起开源，而那份证据最终还是要拿官方库来出；**murky 一类的 Solidity merkle 库不是捷径**，它们的排序规则与 `StandardMerkleTree` 不同，套上去正好踩中这一条。⚠️ **代价是真的、且落在每一台跑门禁的机器上**：本仓库 GitHub Actions 完全不用（决策见 README「门禁」），所以「CI 里装个 node 很方便」这条不成立；新增运行时前提 node ≥ 20，`script/ci.sh` 多一组 `merkle`，README 快速开始多一步 `npm ci --prefix offchain/merkle`。**接受它换来三件事**：① 第三方十有八九用的就是这个库，两边同实现；② 构建产物里带官方库的 `tree` dump，第三方**不需要本仓库的任何代码**就能复算（`StandardMerkleTree.load(产物.tree).root`）；③ M4 的 Indexer 多半也在 node 生态，这个包是它复算脚本的种子（`research/fork-as-rehearsal-environment.md` §6）。**边界**：这个依赖只许用来算 merkle，链上一侧一个字节都不碰它 —— `src/` 与 `test/` 的编译、部署、核验、巡检全部不需要 node。⚠️ `test/helpers/MerkleTree.sol` **不是**这套布局（它不排序、奇数层原样上浮），叶子数不是 2 的幂时与官方库算出不同的 root；它只驱动单元测试的 `claim`，**不可**用来构建要上链的 root，两边的一致性由 `script/ci.sh merkle` 把 `.sol` 里的 32 字节字面量抽出来与 `offchain/merkle/test/vectors/oz-standard-v1.json` 逐位比对来守 |
| 45 | 🔴 **#67 使用独立一次性 fork，不接共享 keeper / Indexer 节点**（2026-08-22，维护者确认） | 决策 42 / #79 原先把 #67、#69 与 M4 放在同一条长跑分叉上；#67 落地时发现两项操作与共享链的证据语义结构性冲突：为压缩首期到期与 48 小时宽限必须大幅 `evm_setNextBlockTimestamp`，而门控阳性还要用 `anvil_setCode` 短暂替换 Robinhood 中央权限注册表（影响**全链所有股票代币**）。这会同时破坏 keeper 的真实挂钟采样证据与 Indexer 的时间线，恢复原码也恢复不了已经前跳的时间。因此 #79 工具仍是唯一的起链/归档/身份底座，但实例拆成两类：**共享长跑实例只给 #69 keeper 与 M4 Indexer；#67 每轮使用新的空 state 目录、新端口、新 launch EOA 起独立短命实例，结束后归档证据并销毁**。#67 的阳性路径不降级：GME 只通过 impersonate 真实持有人后执行真实 ERC-20 `transfer` 供给；真实买穿曲线毕业；毕业后真实 Portal 买卖产税；`marketQuoteBalance > 0` 后真实 permissionless `dispatch()`，禁止直接注入 vault 余额代替。驾驶舱与操作边界见 [`fork-rehearsal-driver.zh.md`](./fork-rehearsal-driver.zh.md)。本决策修订决策 42 最后一段的「三者共用同一条链」，不改其余主网分叉、归档端点、chainId 与终局性结论。 |
| 46 | 🔴 **M4 归属口径冻结为每系列一次整段 TWAB**（2026-08-23，#91） | `offchain/entitlement/` 冻结 `ledger v1 + policy v1 → calculation v1 + #66 vesting input`。窗口为 `[SeriesOpened, min(next SeriesOpened for same vault, expiry))`；截止内 `Deposited.minted + Rolled.amount` 与 Warrant mint、cursor-exact Series 状态三账相等；从 MEME 创建块按 canonical cursor 重放 Transfer，以 BigInt 整数秒依次算 `grossWeight → candidateWeight → accountWeight`。资格固定为 `candidateWeight >= (10_000 × 10^18) × durationSeconds`（等号通过），协议库存须有角色/生效 cursor/链上证据，`0xdead` 普通、v1 不穿透 LP。Robinhood latest 分叉进一步证明 swap-back 前税收 MEME 在代币自身 `TAX_POT`，TaxProcessor 的 MEME 余额为 0；曲线/Portal、税池、processor 与毕业池均由 getter / lens / Transfer 证据派生，200 秒受控窗内唯一协议地址权重占 `5979/10000`，原始读数见 `protocol-inventory-robinhood-v1.json`。唯一分母是 `sum(accountWeight)`，逐户 floor，dust 留 Distributor；零库存、零合格权重、全零 amount 是三个 calculation-only 正常终态。finalized 前只许 PREVIEW，生产不从 canonical `finalized` 降级；journal 遇普通 reorg 回滚共同祖先，跨 finalized frontier 或链身份矛盾停机。链上 `RootSet` 是发布事实，sealed bundle 是公开证据，Proof API 是可重建只读投影；root replacement 保留历史 bundle。中英文权威公式与 D1–D10 见 spec §5.4.1，51 个 golden vectors 与 2 个完整 fixtures 由 `script/ci.sh entitlement` 逐位复算。🔴 这项政策与 Flap `minimumShareBalance` 无关：launcher 的该字段因 `dividendBps == 0` 继续固定为 0。 |
| 47 | 🔴 **M5 OrderbookService v1 冻结：标准 Seaport 卖单 + canonical 链下投影**（2026-08-25，M5-D1～D10） | **D1 支付**：官方流只收**该系列的股票代币**（~~固定 GME~~ → 决策 52 修订为 `Series.stockToken`，首发 GME），maker proceeds 与 fee 分项直付。**D2 fee**：标准 `PARTIAL_OPEN` consideration，不设 zone；`marketOpenedAt + 56 days` 前 0%，之后 50 bps，旧零费单 grandfathered。**D3 成交**：offer 恰好一个 Warrant series，静态数量/价格，`lotCount = gcd(warrant, proceeds[, fee])`，只用 `fulfillAdvancedOrder`，请求“最多 N lot”并允许并发自动缩量。**D4 生命周期**：链下永久 tombstone 的 Delist、链上单笔 cancel、`incrementCounter` 批量失效三分；系列窗口读 `exerciseDeadline`。**D5 接纳**：同一 pinned latest canonical block 完整验证并原子落库；稳定领域码、可恢复/终态投影、每 `(config,maker,series)` 一张可恢复单。**D6 依赖**：zero conduit，maker 直批 Seaport ERC-1155，taker 精确批 GME；生产 release 独立钉 chainId 4663、Seaport `0x0000…B395` 的 codehash/domain 与 GME `0x1b0E…153E`，计算 `deploymentConfigHash`，canary fail closed。**D7 声明**：OTC 不查 attestation，门只在 `exercise()`。**D8 状态/interface**：SQLite WAL + 单 writer + 普通 SQL migration；事实与可重建投影分离；REST `/v1` + ETag，不做 GraphQL/WebSocket/跨单 sweep。**D9 运行**：顺序 canonical block 轮询、reorg 重放、区块 timestamp 过期、周期重验；单进程，无 active-active。**D10 构造/签名**：客户端小型规范 builder，服务端严格复验；直接 EOA/EIP-1271 Seaport EIP-712，`startTime=0`、最长 7 天、随机 salt，不接 bulk/prevalidated/scheduled orders。**没有新 Solidity 结算合约**；完整字段、状态与 endpoint 见中英文 spec §6.6.1。实施总票 #103，W1～W4 为 #104～#107。 |
| 48 | 🔴 **v1 发布切面与前端 staging 接口冻结**（2026-08-25，2026-08-26 增补 Market Preview；umbrella #110；STG-0～STG-3 为 #111～#114） | **版本**：`v1.0.0 Core` 只发布 M0～M4 真实能力；允许由 `features.marketPreview` 开启静态 Market 预告，但 OTC 保持关闭，且生产不得出现 mock 订单、M5 请求、市场授权/签名或交易动作；`v1.1.0 Market` 才加入 M5。**D1 拓扑**：前端只读静态 `app-config.json`、直接连 JSON-RPC / EIP-1193 钱包，并调用只读 M4 Proof API；不新增 BFF、Core REST、GraphQL、托管钱包或代广播。**D2 环境**：公开 config hash 引用 `verified-on-chain` deployment manifest、Interface Bundle、anchor、`eventStartBlock`、法律文本与 feature flags；启动逐项核对 chainId、anchor、文件 hash 与 Pool 四处接线。专属 staging 是可重置、可预置 fixture 的 Robinhood 主网分叉，`chainId = 31337`；不使用缺少 GME 发射配置的 46630，也不复用 #69/M4 运营证据链。**D3 发现**：浏览器从 `eventStartBlock` 扫 `ProjectLaunched` / `SeriesOpened`，finalized 持久层 + latest pending 层，事件只发现 identity、getter 才给当前状态。**D4 交易**：钱包直接构造、模拟、签名、广播；官方 UI 将 claim account / exercise beneficiary 固定为 connected account，receipt 成功后仍须验事件和重读状态；Core 不请求 Warrant `setApprovalForAll`，公共 UI 不暴露 keeper/ops 按钮。**D5 Proof API**：对外 `/v1/proof/current`、`/v1/proof/by-root`、`/v1/bundles/:bundleId`、`/v1/health`；runtime 只加前缀、CORS、缓存与健康语义，不改现有 M4 handler 的 JSON/status，且永远无写路由或 publisher key。**D6 数据**：ABI/error selector/event topic 从部署 commit 的 Foundry artifacts 自动生成 `interface-bundle-v1.json`；HTTP uint 用十进制字符串，业务计算用 BigInt/raw units，未知错误 fail closed。`v1.0.0-rc` 可早于 #69 长跑完成供前端集成，但生产仍等待 #69、#87、#102、法律文本、生产参数与部署门禁。完整 schema、状态机、fixture 与验收见中英文 [`frontend-integration-v1.zh.md`](./frontend-integration-v1.zh.md) / [`frontend-integration-v1.md`](./frontend-integration-v1.md)，页面交接见 [`wireframes/market-coming-soon.zh.md`](./wireframes/market-coming-soon.zh.md)。 |
| 49 | 🔴 **creator 分成：金库每批收入的 10% 归发射者，pull 领取**（2026-08-29，修订决策 33 / 36） | **动机**：D0 经济学里 creator 没有任何持续收入 —— 税全额进金库再进池子，commission 归集成方（决策 40-②），发射行为本身零激励。**八处拍板**：**① 位置选在金库收入层，不在行权层。** 备选是行权时把用户应得股票的 10% 转给 creator，但那要动冻结的 `ClearingPool`（「恰好六个写入口」、不变量 5 结构款、行权三条腿的恰好扣除断言全部重写），且行权时 push 转账给 creator 会在发行方门控下**连坐全体行权**；金库是逐次发射新部署的，改它不触信任基，而「按交易活跃度获酬」的动机本来就该落在税收入上。两条路对用户的稀释等价（权证少铸 10% vs 行权少拿 10%），后者行权 1:1 干净。**② `CREATOR_FEE_BPS = 1000` 是平台级 `constant`**，不是发射参数 —— 自选比例必须回答上限，而 100% 分成等于抽干权证的抵押来源，是现成的 rug 向量；要改只影响此后发射的金库，存量不动（金库不可升级，与决策 33 同一条纪律）。**③ `creator` 成为金库第 6 个构造 `immutable`**（launcher 的 `msg.sender`，经工厂 `newVault` 原样透传），从「🔴 敌手可控，只进事件」升为链上权威出处；构造函数拒绝零地址（第 7 条守卫）。**④ 分成按实测扣款入账，不按请求量**：`available = balance − creatorAccrued`（饱和减），`cut = available × 10%`（向下取整，尘埃归池 —— 取整方向偏向用户）；存入后按实际净扣款反推本批可确认的分成 —— `confirmedCut = min(cut, sent × 1000 / 9000)`（实际入池 `sent` 对应批次 `sent/0.9`，其一成即 `sent/9`；满额 `cut` 封顶）。假转账（`sent == 0`）不产生分成；**部分扣款**（非标代币只走请求量的一部分）只按实际走掉的部分切一成 —— 按满额入账的话，没走掉的那部分会在重试中被反复切分，creator 能拿走接近整批的钱（审计发现 M-01）。同一批钱因此在任何路径下都不会被二次切分，累计分成的上界钉死在整批的 10%。**⑤ `claimCreatorFee()` 无许可、pull 模式**：任何人可触发，钱只会到 immutable 的 creator，calldata 一个字节都改不了收款人 —— 「没有一个是权限函数」的性质原样保住。pull 而非 push 的理由是 R2：真实 GME 每条转账路径都编译了 `onlyNotBlocked` / `onlyNotPaused`，push 会让一个被拉黑的 creator 连坐每天的 `processRevenue`。**⑥ 领取按实测扣款计量：请求 `min(creatorAccrued, 实际余额)`、转账后按实际净扣款校正债权与领取额（假转账恢复原样、部分扣款只消耗走掉的部分），并同笔更新 `accountedQuote` 基线**（规范 rule 010-3 —— 这是金库的**第二条支出路径**，`flap-vault-spec-compliance.zh.md` §3-③ 那个问题被重新回答了一次）；与 `processRevenue` 共用一把手写 transient 锁 —— 不能继承 OZ 的 guard，因为错误面必须为空、继承线性化必须只剩 `WarrantVault` 自己（spec-check 两条独立断言）。**⑦ `inTransit()` 从此返回 `balance − creatorAccrued`**：「在途」的语义钉死为「本该变成权证还没变的钱」，creator 浮存不在其中 —— keeper 的零余额跳过判据、series-monitor 的降级分支、`description()` 横幅因此语义全部不变。`RevenueDeferred` 同理改发净值。**⑧ 拉黑滞留是 creator 自担的风险**：creator 地址被发行方拉黑 → 已累计分成永久滞留金库，**不设改址口**（可转让的分成债权是新的钓鱼攻击面）**也不设回收口**（超时划回池子要加计时器和第八个入口）—— 任何逃生口都是在零权限面上开洞，而这个失效只伤 creator 本人。⚠️ **「只伤 creator」的边界**（审计 I-01）：它只对「拉黑导致领不到」成立。发行方 `adminBurn` / 负向 rebase 把金库余额烧到记账额之下时，`creatorAccrued` 作为账面债权**保留**，后续收入会先补足它再进池子 —— 即负向余额变化在经济上跨批次结转，不由 creator 单独承担；这属于 R2b 那族「无技术手段可防」的发行方权限敞口，与本机制无关也不因它变大。**代价**：写入面五个变六个（两处测试 + spec-check 名单同步改）、用户稀释 10%、`RevenueDeposited.sent` 从「全部收入」变为「净存入」（链下按 `sent / 0.9` 或 `CreatorFeeAccrued` 事件还原总量）。维护者当日拍板。 |
| 50 | 🔴 **回购金库 `BuybackVault`：每项目一只、无许可注资的规则化买方**（2026-09-04，发射日文章「接下来做什么」一节公开承诺；回应 R7 与 [`research/stonkbrokers-vs-warrant.md`](./research/stonkbrokers-vs-warrant.md) §6.3） | **动机**：R7 —— 官方订单簿冻结为只收卖单（M5-D3），早期持有者的出口只有行权或归零；此前两条备选（扩展官方接口收买单 / 外部 Seaport 流维护协议 bid）都要我们自己出资并择价。**九处拍板**：**① 定位是 R7 的第三条路**：不动池子、不动订单簿；一只不可升级、无 admin 的卫星合约，任何人存 MEME，它按规则买入价内权证并在**同一笔交易**里以自身为受益人向池子行权。深度 = 注资量，对外仍不得称「保证退出」（R7 措辞不变）。**② 🔴 共同前提**（决策 51 同用）：接受「股票可经由一个以合约身份签过声明、且强制其股票领取人签过声明的合约到达用户」。金库构造时以自身地址 `attest(0, …)`；LP 提股票必须 `attestedVersion(msg.sender) != 0`；卖方不需声明（与 §10 / M5-D7 一致）。逐人证据不丢，但保证来源从池子变为卫星代码 → R17。version 0 文本是第一人称，合约签署的法律含义待律师确认（§12-11）：**不阻塞设计与实现，阻塞该卫星的主网部署**。**③ LP 记账不读价**：份额只按 MEME 净值定价，股票经「每份额累计」累加器按行权时份额分配（MasterChef 模式）；存 / 提 MEME 零预言机依赖。**④ 取价 `min(TWAP, 现价)`**，内在价值 = p − strike，报价 = 数量 × 内在 × (1 − d)，`d` 为构造期 `immutable`（起点 10%）。TWAP 滞后一天，取低者挡单窗口内的尾盘拉抬；持续操纵由 LP 承担，与 strike 的操纵面同源。**⑤ 买入即行权，权证不过夜**：任何交易结束时金库权证余额为零；池子行权 revert（发行方门控）则整笔回滚 —— 金库只在行权可行时是买方，池子顺延窗口时它自动跟随。**⑥ 代卖入口 `sellFor(seller, …)`**：调用方须为 seller 本人或其 ERC-1155 operator，MEME 只付给 seller，触发者拿不到任何东西。这是决策 51「卖给金库」指令的落点。**⑦ 不换币**：拿到的股票不回交易对换 MEME（3% 税 + 滑点），LP 提的是 MEME + 股票的组合。**⑧ 协议费槽位**：`feeBps` 构造期 `immutable`，起点 0，与 OTC 56 天零费对齐；这条出口绕开 taker fee，对 §6.5 收入模型的影响随参数一起决定。**⑨ 部署**：launcher 不可升级，不能在发币那笔顺带部署；发币后单独一笔、任何人可部署；官方地址由前端 `app-config` 与 Interface Bundle 钉死，不设链上注册表。**代价**：多一只与池子同纪律的合约；LP 承担价格与发行方风险；R7 从二选一变三选一；R13 得到第一条结构性缓解（参与率 `f` 上升 → `S/f` 下降）。完整时序、不变量 B1～B5、失败模式与参数起点见 spec §6.7。维护者当日拍板。 |
| 51 | 🔴 **常设指令 `StandingOrder` 卫星：池子不动，择时权不给任何人**（2026-09-04，方向定案，细节待 spec §6.8 收口） | **动机**：对比文档 §2.1 / §2.2 记录的头号弱点 —— 三笔交易换几美元、一周不管就归零；对手的「零操作积累」一句话就能打穿。**六处拍板**：**① 池子的两道门原样保留**：`exercise()` 的调用方门（受益人本人或 distributor）与 `claimAndExercise()` 的 `NotAccount` 门存在的理由就是拒绝第三方择时，常设指令不是放松它们的理由。**② 做法**：卫星以自身为受益人向池子行权，再把股票转给用户。用户一次性：自签声明、`Warrant.setApprovalForAll`、`MEME.approve`、写一条规则；领取仍走无许可 `claim()`（keeper 代付）→ 用户零操作。**③ 🔴 规则硬约束**：确定性、任何人可触发、执行窗口固定（起点：到期前 6 小时内且 `vault.twap()` 价内）；触发者只付 gas；卫星行权到某用户前检查 `attestedVersion(user) != 0`。**④ 三种指令**：价内行权 / 卖给回购金库（走决策 50-⑥）/ 放过（默认，不需要卫星）。**⑤ 前提同决策 50-②**（合约身份签声明，R17）；若该前提被否决，只剩「放过 / 卖出」两种，发射日文章须改口。**⑥ 代价**：`Exercised.beneficiary` 是卫星，逐人归属退到卫星事件（M4 是否收编待定）；MEME 对卫星是常设授权 → 卫星必须不可升级、无 admin；与 Seaport 挂单冲突（卫星拉走权证使卖单成交失败）由前端提示。维护者当日拍板方向。 |
| 52 | 🔴 **M5 支付币从钉死 GME 改为按系列的 `Series.stockToken`；对外产品名 Warrant Market**（2026-09-04，修订决策 47-D1） | **动机**：首发标的按市场热度选（可能不是 GME），而 launcher 的 `quoteToken` 本来就是入参 —— 官方市场若钉死 GME，任何非 GME 项目的权证在官方流上无单可成，市场对它们等于不存在。**五处拍板**：**① consideration 币种 = `pool.series(seriesId).stockToken`**，接纳时由服务从池子读取并与已验证配置的 canonical 股票代币名单核对；不在名单的系列拒绝接纳。**② 名单进 `deploymentConfigHash`**：名单变化 = 新 hash = 新 namespace，与 D1 原有的隔离规则同构。**③ depth / fee / lot 按系列币种计价**，跨系列不可比；fee epoch 仍按 `marketOpenedAt` 全局计时。**④ 门控重验**从「GME 状态」扩为「该系列股票代币状态」；任一股票代币 pause / block 只让该系列的官方成交路径失效。**⑤ 零代码改动**：M5 尚未实现，本修订只改 spec §6.6.1 与本表。**命名**：wireframe 已用「The Warrant Market Is Next」，两篇对外文章与 playbook 统一为 **Warrant Market**。维护者当日拍板。 |
| 53 | 🔴 **BSC 门控语义：同构替换（Robinhood 三件套 → bStocks 三件套），两条链门控源码独立分支管理**（2026-09-08，依据 [`research/bsc-flap-portal-probe.md`](./research/bsc-flap-portal-probe.md) §6.3 / §6.4） | **背景**：`ClearingPool._readGating` 读的 `paused()` / `ACCESS_CONTROLLED_REGISTRY()` / `registry.isBlocked` 是 Robinhood `Stock` 的形状，bStocks 上**一个都不存在**（§6.1），照搬会让门控恒为「读不通」、每只股票首次结算被推迟 48 小时。**决定**：BSC 的池子编译自一份 `_readGating` 读 bStocks 形状的源码，**状态机、fail-open、`GRACE_PERIOD`、`max(expiry, clearedAt + 48h)` 一个字不改**。映射：`paused()` → **`stock.pauseManager().isTokenPaused(stock)`**；`ACCESS_CONTROLLED_REGISTRY()` → **`stock.compliance()`**；`registry.isBlocked(pool)` → **`compliance.blockedAddresses(stock, who)`** + **`compliance.sanctionedAddresses(who)`**。**判据（实测，非推断）**：冒充链上真实角色真去 `pauseToken` / `pauseAllTokens` / `addToBlocklist` / `addToSanctionsList` 之后，`transfer` 分别 revert `TokenPaused()` / `UserBlocked()` / `UserSanctioned()`，而**这套读法在每一种冻结状态下仍然 `readable=true`、`hit=true`** —— fail-open 不会把真实冻结误读成「没冻结」（§6.4）。`pauseAllTokens()` 的全局急停被 `isTokenPaused` 一并覆盖，不需要第四次读。**排除的两条路**：**① 可插拔适配层**——违反 `IClearingPool` 那句「可写入口恰好六个、无 admin 无升级」；**② 单源双探**（一份源码先试 Robinhood 形状、读不通再试 bStocks）——不往一个不可升级的托管合约里加分支。**签下的代价**：两条链维护两份门控源码，BSC 版必须**重跑**七条不变量与门控攻击面分析（是重跑，不是重新推导，因为状态机没动）。⚠️ **不要用 `compliance.checkIsCompliant` 当钩子**：它以 revert 表达「被拦」，而 `_readGating` 要的是一个**不 revert 的读数**；且它的真实签名是 `(address token, address user)`、与 `msg.sender` 无关（§6.4 逐种组合试出来的，起初按 `(from, to)` 的假设是错的） |
| 54 | 🔴 **BSC 目标资产：只接受 bStocks 作 `quoteToken`，Ondo 不进；首发 `GMEB`**（2026-09-08，依据 [`research/bsc-flap-portal-probe.md`](./research/bsc-flap-portal-probe.md) §5.2 / §6.5 / §9.5.1 / §9.6.5） | **背景**：BSC Portal 全历史启用过 **39 只**计价币 —— 26 只 bStock + 4 只 Ondo（Ondo Global Markets，`…on` 后缀）+ 9 只普通 ERC-20。两家发行方都被 Flap 支持，且 `GMEon` 的曲线档与 `GMEB` 同为 29，纸面上是等价替代品，所以必须实测裁决。**决定：只 bStocks，Ondo 连备胎都不留。****两条硬伤定案（§6.5）**：**① Ondo 四只全部没有 ERC-8056 UI multiplier** —— `uiMultiplier` / `newUIMultiplier` / `effectiveAt` 在其实现的派发表里根本不存在，本项目「金库沉淀股票代币、靠股息 Multiplier 复投」的核心机制在它上面**读不到**；**② Ondo 有 `burn(address,uint256)` / `burnFrom`（`BURNER_ROLE`，当前 0 人）能烧任意持有人的余额**，而 bStocks 只有自烧 —— 实测对 GMEB 逐个尝试五个「烧别人」入口（`burn(address,uint256)` / `burnFrom` / `adminBurn` / `forceTransfer` / `seize`）**全部失败**，只有 `burn(uint256)` 自烧成功。抵押品锁在不可升级的清算池里，这两档风险不是一个量级。第三条旁证：`GMEon` 的 USD 池只有 9,126 USDT，`GMEB` 是 123,333（§9.5.1）。**形制统一（§9.6.5）**：26 只 bStock **全部 18 位小数、全部有 multiplier、共用同一个 beacon / compliance / pauseManager** —— 换一只标的**不需要重做任何权限面调研**。**首发** `GMEB` `0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C`，计价币配置 `(1,29,29,7,0)`，**与 Robinhood 主网 GME 的五元组逐位相同**（曲线档、`nativeToQuoteSwapType` 全一样），经济模型算例与法务文案的改动因此最小。⚠️ **资产表必须写成「从链上现读」，不得在仓库里钉一份静态清单** —— 该名单仍在增长，最近一条配置发生在核验当天（2026-09-08，FXIon，§5.3） |
| 55 | 🔴 **BSC 毕业池沿用 PancakeSwap V2，`PriceSource` 池分支与 `WarrantLauncher` 均零改动；canary 判据从钉 codehash 改为钉行为**（2026-09-08，依据 [`research/bsc-flap-portal-probe.md`](./research/bsc-flap-portal-probe.md) §4.5 / §4.6 / §2.1） | **背景**：调研报告把「BNB 上有 `PCS_INFINITY_CL_MIGRATOR`、税代币可能迁到 Pancake Infinity CL 池」列为三条硬阻塞之一 —— 若成立，`PriceSource._fromPool` 那个只认 `token0/token1/getReserves` 的 V2 分支就得扩展。**决定：不扩展。****判据**：**① 枚举矩阵实测** `migratorType` 只有 `1`（`V2_MIGRATOR`）放行，**`3`（`PCS_INFINITY_CL_MIGRATOR`）与 0、2 一律 `InvalidMigratorType()`** —— 我们**根本传不进**那个迁移器（§4.5）；**② 分叉上真发一只 GMEB 计价的税代币并买到毕业**：`status` 1→4、`price` 归零、`pool` 出自 **PancakeSwap V2 工厂 `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73`**（`INIT_CODE_PAIR_HASH` 与 `getPair` 双向对上），`token0/token1/getReserves` 齐全而 `slot0/liquidity` 全部 revert（§4.6）。**`WarrantLauncher` 侧无需改动**：`MIGRATOR_TYPE` / `DEX_ID` / `LP_FEE_PROFILE` 是 `internal constant`，`LaunchParams` 的六个字段里没有一个能覆盖它们，调用方改不了。🔴 **canary 判据从「钉实现 codehash」改为「钉行为」** —— BSC Portal 全历史升级 **108 次**、最近一次在核验前两天（§2.1），Robinhood 那套 codehash 钉子在 BSC 上会持续变红；BSC 版 canary 应当钉：镜头 18 字与四个字段下标、枚举矩阵、毕业后确实落 V2 池。⚠️ **边界**：我们钉死的是「V2 形状 + `DEX0` 档位」，**「`V2_MIGRATOR + DEX0` 映射到哪个具体工厂」由 Portal 决定、不由我们决定** —— 这条映射也必须进 canary。**❌ 明确不做：给 launcher 补一个 `launchTopology()` 把这四个枚举暴露成链上读数**（2026-09-08 提出并当场否掉，记在这里免得再提）。`launchEconomics()` 存在的理由是「填错了不会被发现」—— `verify-deployment.sh` 对八份合约**只检查「链上有代码」**，不比对字节码，所以税率填错会**发币成功**、经济参数永久错掉且静默。**这四个枚举不属于那一类**：`migratorType` 填错当场 revert `InvalidMigratorType()`、`dexThresh` 当场 revert `InvalidDexThresholdType(uint8)`、`dexId` 当场 revert `0xead3ad50`（三者均见 §4.5 矩阵），而 `launch()` 里 `newTokenV6` 是第 ③ 步、建金库是第 ④ 步 —— **回滚发生在任何半成品出现之前**；`lpFeeProfile` 在 0/1/2 内怎么填都能发，但在 V2 迁移下**本来就不起作用**。何况其中三个已有链上读数：`dexId` / `lpFeeProfile` 就是 Portal 镜头的第 16 / 17 字段，`dexThresh` 编码在第 8 字段 `dexSupplyThresh`（`8e26` = 1e27 的 80% = `FOUR_FIFTHS`）。为一个不会静默失败的常量给身份根 `factory0` 槽里的合约加对外面、并让两条链 launcher 源码进一步分叉，不划算 |
| 56 | 🔴 **BSC 的 version 0 法务文本独立成一份；按 bStocks 实测事实改写条款与文案；`VersionZero` 主网闸门改为集合**（2026-09-08，依据 [`research/bsc-flap-portal-probe.md`](./research/bsc-flap-portal-probe.md) §6.3 / §6.4 / §9.6.5 与本次 issuer-burn 实测） | **为什么必须独立成一份**：4663 的 `AttestationRegistry.versions[0]` 已部署且**永久不可替换**（不变量 6③ 的前提），现行文本回改不了；而 `script/VersionZero.sol` 的 `TERMS_PATH` / `ATTESTATION_PATH` 是**单一硬编码路径**，没有链维度。因此 BSC 需要自己的 `legal/` 目录，`VersionZero` 需按 chainId 选路径。**要改的那一句**：现行 `terms.en.txt` 写 *「…and burn holdings from any address, including this clearing pool」* —— **这一条对 bStocks 不成立**（实测发行方烧不掉第三方余额，见决策 54）。它是照 Robinhood `Stock` 的 `adminBurn` 写的。**换成 bStocks 真实的那一条**：**26 只 bStock 共用同一个 beacon，发行方一笔交易即可替换全部实现** —— 这是比 `adminBurn` **更强**的权力（它明天就能加一个 adminBurn 进来）。**保留仍然成立的两条**：冻结转账、暂停代币 —— §6.4 实测 `pauseToken` / `pauseAllTokens` / 黑名单 / 制裁名单**全部真实可达**，且 pauseManager 的 `OPS_ROLE` 由**单个地址**持有。**其余可引用的事实**：`identifier()` 读出的是阿联酋 ISIN（GMEB = `AE000A4AVSM9`）；`ISSUER_ROLE` 可 `mint` / `burn` / `setName` / `setSymbol` / `setUIMultiplier`，且 `mintEnabled()` 与 `burnEnabled()` 当前**都是 `true`**。🔴 **同批必须改的闸门**：`VersionZero.ROBINHOOD_CHAIN_ID` 的**单值**主网判定要改成主网**集合** `{4663, 56}` —— 不改，BSC 主网部署会走「非主网、跳过定稿检查」分支，把占位文本**永久**写进 `versions[0]`。定稿前 BSC 文本带 `[DRAFT` 标记，闸门会自动拦住 |

---

> ~~**金库 implementation 的复用边界（决策 36 / 38）**~~ → 🔴 **随 issue #58 作废：没有 implementation 了。**
> 原文说的是「`pool` 与 `merkleDistributor` 是 implementation 构造时写死的 `immutable`，所以不能把一份旧
> implementation 放到一套新的 pool 上」，`DeploySystem` 因此有一个 `WARRANT_VAULT_IMPLEMENTATION`
> 复用开关与两条接线校验。金库改为**每次发射现部署一只**之后，这三样东西一起删掉了。
> 同一件事今天由工厂那个一次性槽承担：`setVaultTargets(pool, distributor)` 写一次、永久锁死，
> 部署脚本与 `verify-deployment.sh` 各核验一次它指向的是本次部署出来的那两份合约。

## 11. 风险台账

| # | 风险 | 应对 |
|---|---|---|
| **R1** | 🔴 **期权属性的合规风险** —— 对代币化证券发行看涨凭证 | **用户已明确决定早期不考虑**，记录为有意识的取舍，不再复议。**但因 ClearingPool 不可升级，已在 `exercise()` 留下声明钩子**（§6.6）——不建体系，但不焊死门 |
| **R12** | 🔴 **声明机制覆盖不到主要敞口** —— 它只管"谁能收到股票"，管不了"我们发行了期权"和"我们运营了该期权的订单簿"；且自我声明**不可强制执行**（转个地址即可绕过） | **最大的风险是产生"已经处理过合规了"的错觉。** 对外文案只可陈述"用户须签署声明"，**不得暗示合规性已解决**；真要上量前须就"发行 + 运营市场"两条单独取得法律意见 |
| **R2** | 🔴 **发行方可冻结**（GME 实测：`onlyNotBlocked` 硬编码进每条转账路径，查全链共用注册表；另有单币+全局双层暂停；beacon proxy 可整体升级） | 行权路径优雅失败；门控/暂停期间 Warrant **自动延期**；latest canary 钉住当前 beacon 与 Flap 新发币选择链（Portal → immutable launcher → immutable token implementation）及 runtime codehash，升级必须显式复核；披露池地址便于社区监控 |
| **R2b** | 🔴🔴 **`adminBurn` 可单方面销毁池内抵押品**（无暂停/黑名单检查）—— **全额抵押防不住** | **无技术手段可防**：多标的分散、事件监控、**风险条款明示**。不得只对外宣称"全额抵押" |
| **R3** | 🔴 **ClearingPool 若可被 admin 动，产品失去唯一信任基石** | 独立部署、不可升级、无提取路径 |
| **R4** | ~~**Flap Guardian 可升级我们的金库**~~ → 🔴 **2026-08-16（决策 39 / issue #58 已落地）：本条整类消失。** D0 下金库不再是 Flap 规范金库、不走 beacon、**不可升级**（不继承 `VaultBaseV3`，五个身份参数在构造那一笔里定死，`initialize` 一并消失），Guardian 对它没有任何权限；「在途资金暴露于 Guardian 升级」这个风险面不复存在。⚠️ **在途窗口本身还在**，但它的性质降级为三件事，都不是「谁能把钱拿走」：①本周收入里**还没变成权证**的那一部分（不影响不变量 1 —— 权证只由已存入池子的股票铸出，所以这笔钱既不背书权证也不构成缺口，但它会按**下一次存入那一刻**的归属发出去）；②仍在发行方权限之下、却在池子之外的一小块边角（同一个 `adminBurn` 能烧的范围因此多出约 0.7%，见 R2b）；③我们自己那份不可升级代码握着的钱 —— 金库**没有任何出口通向调用方**（写入面枚举证明；⚠️ 决策 49 的 `claimCreatorFee` 不是反例：那条出口只通向发射那一笔定死的 creator，调用方仍然一分钱都引不到自己身上），所以最坏的失效模式是**卡住**而不是**被拿走**。量化模型原样复用，结论段已按新性质重写：[`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md) | 抵押品不放金库；**到期余量池内滚存、不经金库**（决策 25）；在途资金窗口压到 ≤24h 新税收。🔴 **2026-08-14（M2-3 / #35）起这是一个数**：稳态在途 = `S × T / 7天`（`S` = **进金库**的周税收），占池内规模 `f × T / (0.9 × 7天)`（分母的 0.9 是决策 49 之后每周只有九成收入进池子，`Pool* = 0.9S/f`）—— `f=5%`、每日一次时 **0.79%**（#58 后 `S = $26,400` 的项目约 **$3,800**，峰值日保守 3× 约 $11,300），也就是池内规模的 1/126。两条会把它推到「一周税收」量级的边（开系列漏掉周五、发行方冻结）各有一条 Monitor 告警，且**都不是上界**——连着漏就是倍数。链上读数是 `WarrantVault.inTransit()`（**不是** `accountedQuote()`，后者只是已识别的基线）。📝 **随 #58 删掉的那一条缓解**：「盯 beacon `Upgraded` 事件、覆盖升级之后流入的税收」—— 没有 beacon 了，那件事不可能发生。完整模型、算例、复算与运营要求见 [`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md) |

| **R5** | **对 Flap 的依赖** —— 其可改规则、可自己做 Warrant | 护城河是订单簿深度与社区，非合约 |
| **R6** | **拆股导致 1:1 失配** | 按 raw 单位计量；监测 AAPL/SPY 除息日后 multiplier |
| **R7** | 🔴 **OTC 市场冷启动**（2026-08-09 上调）—— §2.1 修正后深度按「**项目** × 周」分片，且每个系列只活 7–14 天，**深度每周清零、无法沉淀**；空订单簿 + 到期归零 = 早期用户唯一退出是行权或损失 | 表述修正：标准化后是"每**项目** 2 个系列"，非"每股票"。⚠️ **M5-D3 已把官方 v1 冻结为只收卖单，因此旧版缓解「平台上线即在官方簿常设买单」不由 M5 交付。** 上 M7 前必须三选一并另行版本化：扩展官方 interface 支持买单、由独立外部 Seaport 流维护协议 bid，或 **回购金库**（决策 50，2026-09-04 定为首选：链上规则化买方，深度 = 注资量，不动池子与订单簿）；在正面成交证据出现前，不得对外声称「任何时刻保证退出」。护城河仍是"聚合入口 + 做市能力 + 社区"，但做市能力不是当前 v1 interface 已经证明的事实（背景见 [`research/stonkbrokers-vs-warrant.md`](./research/stonkbrokers-vs-warrant.md) §6.3） |
| **R8** | **周度到期对被动持有者不友好** | 与生态常态一致（Flap 分红同为 pull 模式） |
| **R9** | **经济学被 Flap 框死** | #58 后仅 ≈0.06% 交易量的集成方 commission 不可自定；额外收入只来自 OTC taker fee，v1 不收行权费 |
| **R10** | **Flap 曝光需对方上架，非自动** | 分发靠自有社区，不押在对方 |
| **R11** | **用户仍需付 Flap 的 1% 曲线费 + 0.3% 协议费** | 我们省的是开发，不是用户手续费 —— 定价叙事需说明 |
| **R14** | 🔴🔴 **税可能只对「已注册的交易对」生效，未注册的平行池可逃税**。历史 BSC MarsCoin 样本中，官方对收 **3.00%**、第三方 PancakeSwap V3 池收 **0**；38 分钟窗口内 **70.4% 成交量在无税池，实际捕获率 0.90%**（[`research/flap-tax-and-burn-path.md`](./research/flap-tax-and-burn-path.md)）。这不是 Robinhood Chain 验收结果；目标链收税分支阳性对照仍未取得 | 由于 Robinhood 实现与历史样本 ABI 同构，v1 在完成目标链复核前按此结构性风险保守处理：①把官方池做成**流动性最深**的场所 ②监控并公示平行池 ③**经济算例只按收税场所成交量折算**。Robinhood Chain 上线前必须补做已注册对 / 未注册池的目标链对照；合约层仍无法阻止第三方建池 |
| **R15** | ⚠️ **税收去向可被 Flap 单方面改道**（2026-08-13 立项，2026-08-14 监测落地）—— Portal 的 `changeMarketWallet(token, newWallet)`（`TAX_GUARDIAN_ROLE` / `DEFAULT_ADMIN_ROLE`）改的是税打给谁，**代币、金库、身份根里的绑定全都不动**；主网上已用过三次，均在别人的代币上。这是**收入**风险，不是偿付风险 | **合约层无从防御** —— 这是 Flap 合约上的权限。只能看见：`script/watch-market-wallet.sh` 双探针（Portal 日志 + `taxProcessor().marketAddress()`）对账，台账进版本库当已知阳性，`script/monitor.sh tax` 按需跑（🔴 2026-08-17 起没有调度器，见 README「守夜」）；分类逻辑的反证矩阵在门禁里离线跑。对外文案的边界句必须三项并列：**偿付 = 结构保证，发行活性 = 运营保证，收入 = 平台信任**（决策 35） |
| **R16** | 🔴 **Flap 可单方面关掉 GME 档的发币能力**（2026-08-17，#64 顺带查出）—— 🔴 **两个开关，两处不同的存储，任一被拨都停摆**：`setQuoteTokenConfiguration(GME, {enabled: 0, …})`（GME 不再是计价币，`Portal.newTokenV6` 撞 `QuoteTokenNotAllowed(GME)` = `0x9a5c8a92`）与 `setQuoteTokenCreationDisabled(GME, true)`（仍是计价币，但不许再用它发新币）。两条都只要**一笔普通交易**，不必升级任何合约。⚠️ 后者不在 `src/flap/IPortal.sol` 里（那份是 Flap 示例仓库的子集），取自主网实现的已验证 ABI；**只盯前者会漏掉后者** —— 实测拨第二个开关时，`getQuoteTokenConfiguration` 读出来仍是 `(1,29,29,7,0)`。**边界**：已发项目的代币 / 金库 / 身份根绑定、池内抵押品与已铸权证、以及已发项目的曲线交易、税收与开系列**全都不受影响** —— 该配置只在**建币**那一步被读；归零的只有**发新币**。因此 §5 那句边界话要读成：**偿付 = 结构保证，发行活性 = 运营保证，收入 = 平台信任，而发行能力 = 平台配置**。与 R15 是同一族（Flap 的权限，我们只能看见），但比它更彻底：R15 断的是一只币的收入，本条断的是**所有新币** | **合约层无从防御**。🔴 **它也不在 codehash 钉子的视野里** —— 撤销只改存储，字节码一个比特不变，canary 那三份 runtime codehash 会全绿。所以它有一条自己的断言：`RobinhoodCurrentCanary::test_gmeIsStillAnEnabledQuoteTokenToday`（跑 **latest**，期望值钉在 `ForkConfig.EXPECTED_GME_QUOTE_*`）。⚠️ 此前唯一的断言在 `RobinhoodTwapSource.t.sol`，而那份文件跑**钉死高度** —— 它证明的是「区块 31,955,417 上 GME 是启用的」这条历史事实，**结构上永远发现不了将来的一次撤销**；该断言保留，但不是告警。**两个开关各做了一次阴性对照**：分叉上冒充当前 `DEFAULT_ADMIN_ROLE` 持有人 `0xa4a727e0…52a4`，① 把配置改成 `(0,0,0,0,0)`、② 把 `quoteTokenCreationDisabled(GME)` 拨成 `true`，本条两次都如期变红**而三份 codehash 断言一条都没红**；②那次尤其说明问题 —— 配置本身还是 `(1,29,29,7,0)`，只加第一条断言的话发币已死而告警仍是绿的。变红后的处理流程（先划边界、再公告、再联系、最后才谈自建栈）见 [`fork-canary-runbook.zh.md`](./fork-canary-runbook.zh.md) §4.1；它同时是决策 42-④ 启动自建发射栈的三条判据之一。🔴 **2026-08-17 起 canary 没有调度器了**（本仓库不用 GitHub Actions 跑任何东西，入口改成 `script/monitor.sh canary`，见 README「守夜」）：这条断言仍然准，但它**不会自己来告诉你**。本条与 R15 的差别在这里被放大 —— R15 断的是一只币的收入，本条断的是**所有新币**，而两者现在都只在有人想起来的时候才被检查 |
| **R13** | 🔴 **低参与率使池内抵押品累积至 `S/f`**（S = 周税收，f = 行权参与率；f=5% 时约 **20 周税收**）—— 这是"保持 N=2、依赖回流浓缩"决策的**固有代价**：参与率越低（正是该策略所依赖的），池内沉淀越多，**同比放大 R2b 单次 `adminBurn` 的损失** | 非缺陷而是策略成本，须公开承认：多标的分散、Monitor 对 `adminBurn` / 门控事件告警、**风险条款明示池规模与暴露的正比关系**（推演见 [`research/expiry-window-verification.md`](./research/expiry-window-verification.md) §9.2；编号跳过 R12 因已被占用）；**回购金库（决策 50）通过拉高行权参与率 `f` 直接缩小 `S/f`，是本条第一个结构性缓解** |
| **R17** | 🔴 **股票可经由「以合约身份签声明」的卫星到达用户**（2026-09-04，决策 50 / 51 的共同前提）—— 回购金库与常设指令卫星都以自身地址通过 `exercise()` 的声明门；池子不变量 6 字面成立（受益人已声明），但「谁最终拿到股票」的逐人证据改由卫星代码强制（LP 提股 / 用户收股前查 `attestedVersion`），且 version 0 文本为第一人称，合约签署的法律含义未经律师确认 | 卫星不可升级、无 admin，声明检查写成 immutable 逻辑而非开关；对外文案仍只可说「须签署声明」（R12）；主网部署任一卫星前取得律师意见（§12-11）；若否决，常设指令只剩「放过 / 卖出」，回购金库不成立，发射日文章「接下来做什么」一节须改口 |

> `WarrantVault.inTransit()` 仅在 `exact == true` 时给出可用于金额比较的真实余额；若返回
> `(0, false)`，表示收入币种余额**不可读且金额未知**，不是「在途为零」也不是任何数学下界。Monitor
> 必须将其作为单独的高优先级故障处理。

---

## 12. 未决项

**机制与叙事的合约部分已闭环。** M1 与 M2（含 D0 三张实现票，收口于 2026-08-17）已全部实现；M3 的 #66 / #67 / #68 / #77 / #79 工具已实现，尚待 #69 真实时钟运营验收；M4 的 canonical replay、确定性计算、公开复算、sealed bundle catalog、只读 Proof API/HTTP adapter 与 publisher handoff/finality/recovery 流程已由 #91～#96 完成，可重置的常驻 Proof Runtime 已在 Core staging 部署，但 Robinhood 4663 的生产 Indexer/HTTP 服务仍未部署，`setRoot` 仍由 publisher 人工签名；M5-0 已冻结 D1～D10（决策 47 / spec §6.6.1），实现后归入 `v1.1.0 Market`。Web App 的 mock 开发已完成，决策 48 所需的后端 staging 接口产物、专属分叉、fixtures 与 runtime 已交付；当前缺口是 Web App 七条旅程、桌面/移动端、reorg/reset 与联合签字，而不是重做后端。🔴 **发射路线已于 2026-08-16 定案为 D0**（决策 39 / #53），三张实现票均已落地 —— ① `VaultRegistry` 2 槽预留 + `PendingLauncherSlot`（**必须先于池子部署**，#56）、② launcher 编排层 `WarrantLauncher`（#57，决策 40）、③ 金库去 Flap 化（#58，拆掉 `VaultBaseV3`、金库不可升级、portal 改构造参数）；**「等 Flap 升级 VaultPortal」的阻塞已解除**。下列标红生产条件仍阻塞上线：


1. **`antiFarmerDuration` 的确切语义与 Robinhood Chain 最终值** —— 开发 / 测试暂用官方示例值 1 天；历史 BSC MarsCoin 的 30 天仅作观察，不能替代目标链确认。⚠️ **2026-08-18：这次实测的落点改到 chainId 31337 的主网分叉**（#69 分叉侧任务）—— 46630 上发不出币，做不了这次实测；而分叉跑的就是主网 Portal 实现，结论可直接喂给主网参数决策（决策 42-③）
2. ~~**OTC 免费期 `N = 8 周`**~~ ✅ **2026-08-25（M5-D2）冻结**：以 `marketOpenedAt` 的 canonical
   timestamp 为起点，前 56 天 0%，之后 50 bps；切换前已接纳零费订单 grandfathered（spec §6.6.1）
3. ~~Warrant `seriesId` 的具体编码与到期归属的账目结构~~ ✅ **已定稿**（2026-08-09）：`seriesId = keccak256(meme, stock, expiry)` 不变；Series 结构含 `remainder`、门控观测表 `Gating`，见 spec §4.2
4. 🔴 **version 0 两段声明文本的最终措辞** —— 合约部署后，其**两个哈希永久存在、无法替换**；规范文本保存在 `legal/attestation-v0/`（§6.6，引用见 spec §5.5）。**这是本清单中唯一不可回滚的一项**。✅ 2026-08-26 已定稿（issue #18）：权威语言为英文，定稿依据与哈希记录见 `legal/attestation-v0/README.md`
5. ~~**OTC 侧是否要求声明**~~ ✅ **2026-08-25（M5-D7）冻结**：官方 OrderbookService 不检查
   maker/taker 的 `attestedVersion`；声明门只在 `exercise()` beneficiary 路径（spec §6.6.1）
6. **v2 候选**：时间加权折扣的**返现版**实现（§9.6）；Evolution 等级（需链下索引 + merkle root）
7. ~~`exercise()` 的 MEME 销毁路径核验~~ ✅ **已在 v1 目标链 Robinhood Chain 重跑**：固定区块 31,955,417 的套件保留可复现证据；独立 latest canary 钉住当前 GME beacon 与 Flap 新发币选择链（Portal implementation → immutable launcher → immutable 的受支持 token implementation），核对三份 Flap runtime codehash，并现场发一只 GME 计价的 V3 税代币执行 `transfer` / `transferFrom → 0xdead`。#146 已在 2026-08-30 对 Portal `0xa3b9…ff44`、launcher `0xCC40…c0A0` 与仍未漂移的 TaxTokenV3 `0x7777…3333` 重做该核验。两层都以 `FORK_REQUIRED=true` 运行 Forge —— 固定区块那层在门禁里（`script/ci.sh fork`），latest canary 那层自 issue #25 起分出去单独跑（`script/monitor.sh canary`），刻意不进门禁 —— 它监控的是第三方何时升级，与某次提交改了什么无关。真实 `FlapTaxTokenV3` 的 `transferFrom(holder, 0xdead, X)` 实收正好 X；转 `0x0` revert；不存在原生 `burn()` / `burnFrom()`。BSC / MarsCoin 的结果仅保留为历史方法学对照，不属于当前验收。✅ **目标链收税阳性对照已于 2026-08-16 取得**（#53 的 D0 spike）：自己发一只 GME 计价代币、买穿曲线毕业，实测税被扣入代币合约 → `TaxProcessor` 换回 GME → 无许可 `dispatch()` 打给发射参数指定的 beneficiary。见 [`research/self-launch-spike.md`](./research/self-launch-spike.md) §3
8. 🔴 **平行池逃税的运营对策**（2026-08-09 新增，见 R14）—— 合约层无解，需在上线前定下：官方池的初始流动性深度、平行池监控与公示方式、以及**对外经济叙事如何折算**。这条不阻塞写码，但阻塞上线
9. ~~ClearingPool 接口冻结评审~~ ✅ **四项全部定案并落实**（2026-08-09，决策记录见 §10-25…28，规格见 spec §5.1/§5.4）：① 池内 `rollExpired`；② 门控感知结算；③ `exercise` 带 beneficiary + `claimAndExercise`；④ permissionless `claim`
10. ~~Warrant / MerkleDistributor 与 ClearingPool 的构造循环依赖~~ ✅ **已解并随 M1 交付**（2026-08-09 复审，决策 29）：一次性 `setPool` 绑定，**不再需要 CREATE2**（spec §12）
11. 🔴 **卫星合约以合约身份签署 version 0 声明的法律确认**（2026-09-04 新增，决策 50 / 51 的共同前提，见 R17）—— 文本为第一人称，合约签署是否构成有效自述、是否需追加 version 1 措辞（不影响已签者，不变量 6③）待律师意见。**不阻塞设计与实现，阻塞两只卫星的主网部署。** 同条跟踪回购金库三个参数：折扣率（起点 10%）、单日买入上限（起点无）、协议费（起点 0，槽位保留），以及 MEME 钱包↔合约转账免税在主网分叉上的复核（池子行权路径已断言精确扣款，但卫星多一跳），见 spec §14-14

> **2026-08-09 复审补记**：上述四项决策落地时，规格层另有五处需要收口，均已写入 spec —— ①`claimAndExercise` 必须与 `claim` 共写 claimed 位（否则重放会从 distributor 的**共享**余额里取走其他持有人的份额）；②不变量 1 须排除已结算系列并补全局形式（否则滚存后按字面不成立）；③`clearedAt` 只能在翻转边写入，并由新增的不变量 4③ 强制（否则任何人可反复 poke 永久阻止结算）；④部署环用 `setPool` 解开（决策 29）；⑤错误处理表补"只封单个持有人"与 fail-open 的用户侧后果两行。**前三项属于"照着现有措辞实现就会出事"，不是文字问题。**

> **已关闭**：~~平台命名~~ → **warrant**；~~先上哪条链~~ → **Robinhood**；~~OTC 结算~~ → **Seaport 1.6**（§6.4）；~~quote/dividend token~~ → **quoteToken = 绑定的股票（GME）**；~~R2 按 Robinhood 重写~~ → §5 与 R2/R2b；~~税率与模板参数~~ → §7；~~strike 取价与铸造节奏~~ → §4；~~收入分配~~ → §6.5；~~叙事层~~ → §9

---

## 13. 参考

- [`research/flap-vault-integration-feasibility.md`](./research/flap-vault-integration-feasibility.md) —— **建在 Flap 上的可行性核验（本路径的依据）**
- [`research/bsc-index-clones.md`](./research/bsc-index-clones.md) —— Flap 模板生态与完整费率结构
- [`research/flap-indexvault-mechanism.md`](./research/flap-indexvault-mechanism.md) —— IndexVault v3 机制与 Robinhood 主场数据
- [`research/flap-dividend-fragmentation.md`](./research/flap-dividend-fragmentation.md) —— 即时分发的碎片化实证
- [`research/tokenized-stock-dividends-erc8056.md`](./research/tokenized-stock-dividends-erc8056.md) —— EIP-8056 / BEP-677 实测
- [`research/bstocks-contract-architecture.md`](./research/bstocks-contract-architecture.md) —— bStocks 合约实测
- [`research/the-index-teardown.md`](./research/the-index-teardown.md) —— The Index 链上逆向
- [`research/zero1-01-teardown.md`](./research/zero1-01-teardown.md) —— 赎回机制的稀释陷阱
