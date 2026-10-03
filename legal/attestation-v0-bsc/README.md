# AttestationRegistry · version 0 的两段文本 —— **BSC（chainId 56）版**

> **当前状态：已定稿（2026-09-10，维护者去掉 `[DRAFT]` 标记）。** 权威文本为英文。
>
> | 文件 | keccak256（正文，去掉那个唯一的结尾 LF） |
> |---|---|
> | `terms.en.txt` | `0xe864e266e4d398abb519939899dc94ca6e80a4a8125de348e6eb0681b71b16b6` |
> | `attestation.en.txt` | `0xe760c38dcca7cc6cb2e151e2c91521f89890ce053d6cbfd1f0319ff88045bd64` —— **与 4663 相同**（见 §2） |
>
> 复算（与 `../attestation-v0/README.md` 的命令一字不差）：
>
> ```bash
> cast keccak -- "$(cat legal/attestation-v0-bsc/terms.en.txt)"
> ```
>
> 🔴 **这两个字节串从此不许再动。** `test_bscTextIsFinalized` 钉死了它们；BSC 的
> `versions[0]` 一经上链永久指向这一版，且与 4663 的注册表是**两个**互不相干的实例 ——
> 各自只有一次机会（不变量 6③）。

字节规范、哈希算法、`VersionZero` 拒绝什么 —— **全部与 [`../attestation-v0/README.md`](../attestation-v0/README.md) 一致，不在这里复述**。这份 README 只回答两个问题：为什么要另起一份，以及改了哪一句。

---

## 1. 为什么 BSC 不能沿用 `legal/attestation-v0/`

两条各自独立、都足以成立的理由：

1. **4663 的那份改不了。** Robinhood 主网的 `AttestationRegistry.versions[0]` 已经部署，两个哈希**永久存在、不可替换** —— 这正是不变量 6③ 成立的前提。所以「把 terms 里那句话改对」这个动作，对已上线的 4663 来说是不存在的选项。
2. **两条链的抵押品发行方不是同一家，权限面也不同。** 4663 的抵押品是 Robinhood Stock，BSC 的是 bStocks。一段同时描述两者的文本，要么对其中一条链**过度披露**，要么对另一条**披露不足**。

✅ **落地前提已完成**：`script/VersionZero.sol` 的 `legalDir()` / `termsPath()` / `attestationPath()` 已按 `chainId` 选路径，`isMainnet()` 已从单值 `4663` 改成集合 `{4663, 56}`。见决策 56。

---

## 2. 与 4663 版的差异

### `attestation.en.txt` —— **逐字节相同**

它讲的是**用户本人**（不是美国居民、不代表受限司法辖区的实体），与抵押品发行方无关。两条链共用同一段文本，只是各自算各自的哈希、写进各自的注册表。

### `terms.en.txt` —— **只改最后一个从句**

4663 版的结尾是：

> …and that the issuer of the tokenized stock reserves the ability to freeze transfers, pause the token, **and burn holdings from any address, including this clearing pool**.

**加粗那半句对 bStocks 不成立。** 实测（`docs/research/bsc-flap-portal-probe.md`，2026-09-08）：以 GMEB 的 `ISSUER_ROLE` 持有人身份，逐个尝试 `burn(address,uint256)` / `burnFrom(address,uint256)` / `adminBurn(address,uint256)` / `forceTransfer` / `seize` 五个入口去烧一个第三方地址的余额，**五个全部失败**；只有 `burn(uint256)`（自烧）成功。那半句是照 Robinhood `Stock` 的 `adminBurn` 写的。

> ⚠️ **反面的例子在同一条链上**：Ondo Global Markets 的代币**确实**有 `burn(address,uint256)` / `burnFrom`（由 `BURNER_ROLE` 管，当前 0 人）。这也是决策 54 把 Ondo 排除在目标资产之外的两条理由之一。若将来把 Ondo 纳入，这一句要**加回来**。

BSC 版换成 bStocks 真实成立的那一条：

> …and that the issuer of the tokenized stock reserves the ability to freeze transfers of any address, to pause the token, **and to replace the token's implementation for every token it issues in a single transaction, which may introduce powers it does not hold today**.

**为什么这样写**：26 只 bStock 共用同一个 beacon（`0x156d6dce9a4f6139a3406f1f021f1a4880de93a3`），发行方一笔交易就能把**全部**实现换掉 —— 这比 `adminBurn` 更强，因为它**明天就能加一个 `adminBurn` 进来**。文本因此不去枚举「今天有哪些权力」，而是披露那个能生出新权力的开关本身。

### 保留下来、且**已逐条实测**的两条

| 文本里的话 | 实测（§6.4） |
|---|---|
| freeze transfers of any address | `compliance.addToBlocklist(GMEB, [addr])` → `transfer` revert `UserBlocked()`；`addToSanctionsList` → revert `UserSanctioned()`。**转出与转入两个方向都拦** |
| pause the token | `pauseManager.pauseToken(GMEB)` → revert `TokenPaused()`；另有 `pauseAllTokens()` 全局急停，由 pauseManager 的 `OPS_ROLE` **单个地址**持有 |

---

## 3. 其余可供律师引用的事实

全部出自 `docs/research/bsc-flap-portal-probe.md`（2026-09-08 实测，附复现命令）：

| 事实 | 出处 |
|---|---|
| bStocks 的 `identifier()` 返回阿联酋 ISIN —— GMEB = `AE000A4AVSM9`，SPCXB = `AE000A4AVAW6` | §6.3 |
| `ISSUER_ROLE` 可 `mint(uint256)` / `burn(uint256)` / `setName` / `setSymbol` / `setUIMultiplier`；GMEB 的该角色由 **3 个地址**持有 | §6.3 |
| `mintEnabled()` 与 `burnEnabled()` **当前都是 `true`** | §6.3 |
| compliance 模块 `0x53dBa7Aa…14F4` 与 pauseManager `0x9fc74Be6…700a` 由 **26 只 bStock 共用**；两者都是 `AccessControlEnumerable`，角色持有人可枚举 | §6.3 |
| 门控四个入口在**任何**冻结状态下仍然读得通（`readable = true`） | §6.4 |

---

## 4. 定稿清单

- [x] `script/VersionZero.sol` 按 chainId 选路径（决策 56）
- [x] `VersionZero` 的主网判定从单值 `4663` 改成集合 `{4663, 56}`（决策 56）—— 不改就会把草稿永久写进 BSC 的 `versions[0]`
- [x] 决定 `attestation.en.txt` 两链共用 —— **是**，由 `test_bscReadsItsOwnLegalDirectory` 断言两个哈希相等
- [x] 去掉 `[DRAFT]` 标记，重算哈希（2026-09-10）；`test_bscTextIsFinalized` 已钉死，`.env.example` 已按链列出两个 TERMS 值
- [x] `foundry.toml` 的 `fs_permissions` 已对 `./legal` 整个目录放行，无需另加
- [ ] 律师复核上面那句替换，特别是「replace the token's implementation」这个表述在目标司法辖区是否够清楚 —— **本仓库无此项的证据**；定稿由维护者于 2026-09-10 签字，律师复核状态在仓库之外

### 🔴 部署 BSC 主网之前还差一件事：preflight

`script/preflight-mainnet.sh` **按构造只服务 4663** —— 抬头就写着「主网（Robinhood Chain 4663）」，`WANT_CHAIN_ID` / 钉死高度 / Portal 地址 / 官方端点全部从 `test/fork/ForkConfig.sol` 里的 `ROBINHOOD_*` 常量 grep 出来，读的 env 也是 `RPC_ROBINHOOD`；第 135 行那句 `file="legal/attestation-v0/${f}.en.txt"` 同样写死。

所以它不是「在 BSC 上会核对错目录」，而是**在 BSC 上根本不该跑**。BSC 主网的 preflight 是一件独立的移植工作，不属于本次定稿的范围 —— 记在这里是为了别让它在部署夜才被想起来。
