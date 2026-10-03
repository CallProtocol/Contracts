# warrant — Product & Engineering Specification

| | |
|---|---|
| **Audience** | Contract, frontend, and backend engineers |
| **Prerequisites** | [`design.md`](./design.md) (product decisions and rationale) · [`research/`](./research/) (first-hand on-chain verification) |
| **Status** | **M1 implemented and tested**: AttestationRegistry, Warrant, MerkleDistributor, ClearingPool, deployment wiring, and all seven invariants are shipped. **M2-0 through M2-5 are implemented and tested**: immutable identity root, vault skeleton, strict 24-hour TWAP / PriceSource, revenue path, series opening, and Factory wiring. **M2-6③ (#58) is shipped: the vault is de-Flapped** — it no longer inherits `VaultBaseV3`, is not upgradeable, and takes its price-source Portal as a constructor argument. 🔴 **M2-6② (#57) is shipped: the D0 orchestration layer `WarrantLauncher`** — one transaction mints the token, deploys the vault, and writes the identity-root binding, via ordinary `Portal.newTokenV6`; the deprecated VaultPortal-with-vault entry point is no longer part of the system (§6.1). **M2 has no implementation tickets left**. **M4's canonical replay, deterministic calculation, public recomputation, sealed bundle catalog, read-only Proof API/HTTP adapter, and publisher handoff/finality/recovery flow are implemented and tested (#91–#96). A persistent, resettable Proof Runtime is deployed for Core staging acceptance; no production Indexer or HTTP service is deployed, and `setRoot` remains human-signed. Frontend integration STG-0-D1 through D6 is frozen in [`frontend-integration-v1.md`](./frontend-integration-v1.md): `v1.0.0 Core` releases only M0 through M4, and M5 joins in `v1.1.0 Market`. M5-0 has frozen the OrderbookService v1 decisions (§6.6.1); implementation has not started.** M3 remains in progress: the manual Merkle path (#66), isolated full-loop fork rehearsal (#67), keeper (#68), external dead-man hook (#77), and persistent fork environment (#79) are implemented; #69's two-to-three-week real-clock/operational acceptance is not complete. M5 implementation remains planned. The frontend engineer has completed the Web App against mocks; the backend staging artifacts/runtime/fixtures are delivered, while Web App journeys, desktop/mobile, reorg/reset, and joint sign-off remain (§10 / §13). Includes the two `design.md` corrections (§2), interface-freeze decisions, and implementation hardening |
| **Chains** | **v1: Robinhood Chain only** (chainId 4663). BSC / BNB Chain is outside the current implementation, test, and acceptance scope; any support requires a separately scoped future release and fresh on-chain validation |
| **Last updated** | 2026-08-26 |

---

## 1. System Overview

### 1.1 In One Sentence

Users hold a meme token → receive weekly **warrants** → burn meme to exercise into tokenized equity, or sell the warrant on an order book.

### 1.2 Components and Ownership

```
┌──────────────── External dependencies (we do not build) ────────────────┐
│                                                                         │
│  Flap Portal                 ── D0 launch entry, bonding curve, DEX migration│
│  FlapTaxTokenV3 (MEME)       ── token itself + buy/sell tax              │
│  Flap TaxProcessor           ── tax collection, settlement, dispatch     │
│  ⛔ Flap Trigger Service     ── not our dependency since decision 39 (§9)│
│  Robinhood Stock (GME)       ── underlying; beacon proxy + central registry│
│  Seaport 1.6                 ── order matching and atomic settlement     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
┌──────────────── We build ─────────┼─────────────────────────────────────┐
│                                   ▼                                     │
│  ① WarrantLauncher       D0: mint token → build vault → bind identity   │
│  ② WarrantVaultFactory   one vault per project (ours, non-upgradeable)  │
│  ③ WarrantVault          receive/sync → processRevenue → mint (thin)   │
│  ④ VaultRegistry         immutable two-slot memeToken → vault root      │
│  ⑤ PendingLauncherSlot   fail-closed future writer slot                 │
│  ⑥ ClearingPool  🔴      custody, mint/exercise/expiry (immutable)      │
│  ⑦ Warrant (ERC-1155)    the warrant token                              │
│  ⑧ MerkleDistributor     holder entitlement proofs (see §2.2)           │
│  ⑨ AttestationRegistry   on-chain attestation record (see §5.5)         │
│                                                                         │
│  ⑩ Indexer               off-chain: Transfer events → balance history   │
│  ⑪ OrderbookService      off-chain: Seaport signed orders               │
│  ⑫ Web App               all frontend                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Relationships

| From | To | Relationship |
|---|---|---|
| Flap TaxProcessor | WarrantVault | dispatches stock + `receive()` ping |
| Trigger Service (**our own**, `script/trigger-keeper.sh`, issue #68) | WarrantVault | triggers the permissionless `sampleTwap()` (🔴 polled every **90 seconds**, the contract itself gates the hourly write — a strict hourly cron would inevitably breach the 65-minute cap, derivation in §9), `openSeries()` (asks `openSeriesStatus()` every 15 minutes; the window answers for itself) and `processRevenue()` (daily) |
| WarrantVault | ClearingPool | `depositAndMint()` |
| ClearingPool | Warrant | mints / burns ERC-1155 |
| Indexer | MerkleDistributor | publishes weekly entitlement root |
| User | AttestationRegistry | `attest()`, **one-time**, prerequisite for exercise (§5.5) |
| ClearingPool | AttestationRegistry | **read-only** `attestedVersion`; address immutable |
| User | ClearingPool | `exercise(…, beneficiary = self)` |
| MerkleDistributor | ClearingPool | `claimAndExercise` → `exercise(…, beneficiary = account)` (claim-free path) |
| Anyone | ClearingPool | `pokeGating` / `settleExpired` / `rollExpired` (permissionless maintenance) |
| User | Seaport | list / fill orders |

---

## 2. 🔴 Two Corrections to `design.md`

Writing this specification surfaced two errors not previously visible. **Both change implementation and must be confirmed before any code is written.**

### 2.1 Warrants Cannot Be Fungible Across Projects

**Original design.** `seriesId = (stock, expiry)`; warrants on the same stock from different projects were to be the same asset, aggregating order-book depth.

**Why it's wrong.** Exercise burns **that project's own MEME**. Project A's warrant burns A's token; project B's burns B's. **Different payment assets cannot be the same instrument.**

**Correction:**

```
seriesId = keccak256(abi.encode(memeToken, stockToken, expiry))
```

Warrants are isolated per project. ClearingPool remains platform-level (unified custody, one audit, single integration point for the market) but **no longer provides cross-project fungibility**.

**Consequences:**
- "One deep market per stock" becomes "**two live series per project per week**"
- ✅ **Applied 2026-08-08** to `design.md` §3 / §4 / §6.2 and to all four public-facing documents
- No impact on the first launch (single project); it affects long-tail aggregation, and the long tail was thin regardless

### 2.2 Accrual Cannot Use an On-Chain Accumulator

**Original design.** MasterChef-style `accWarrantPerToken` + `userDebt` — O(1), no snapshot, no keeper.

**Why it's wrong.** An accumulator requires **updating user accounting on every balance change**. The MEME contract belongs to Flap; **we cannot hook its `_update`**. Without a transfer hook there is no way to maintain `userDebt`.

Computing entitlement from current balance at claim time is trivially gamed: buy immediately before claiming.

**Correction: off-chain computation + weekly merkle root.**

```
Indexer subscribes to MEME Transfer events
  → reconstructs each address's balance history
  → computes time-weighted holdings over the complete series window
  → allocates all warrants in that window once, using the full-window weights
  → publishes a merkle root to MerkleDistributor
Users claim with a proof
```

**Properties:**
- ✅ Preserves "just hold, no staking required"
- ✅ **Anyone can independently recompute the root from public Transfer events**
- ⚠️ **Introduces a new trust assumption**: we compute and publish the root. The algorithm and a recomputation script must be open-sourced
- ⚠️ Time-weighted rather than snapshot, which defeats buy-before-claim

**Alternative (more trustless, changes the product):** require users to **stake** MEME into our contract, making accounting fully on-chain. **Not recommended** — it turns "hold and accrue" into "stake and accrue," contradicting the core narrative.

---

## 3. External Dependencies

| Dependency | Address / identifier | Purpose | Risk |
|---|---|---|---|
| Robinhood Chain | chainId **4663**, RPC `rpc.mainnet.chain.robinhood.com` (browser UA required) | Primary chain | — |
| **GME** | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` | Underlying and target quoteToken | beacon proxy; the deprecated VaultPortal-with-vault route rejects it, while D0 uses ordinary Portal |
| GME implementation | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` (`Stock`, verified) | — | upgradeable in bulk |
| **Access registry** | `0xe10b6f6b275de231345c20d14ab812db62151b00` | blocklist / pause / roles | 🔴 chain-wide |
| **Seaport 1.6** | `0x0000000000000068F116a894984e2DB1123eB395` | OTC settlement | immutable |
| ConduitController | `0x00000000F9490004C11Cef243f5400493c00Ad63` | approvals | immutable |
| Flap VaultPortal | `0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B` | deprecated historical launch-with-vault entry | not part of D0 |
| **Flap Portal** | `0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09` (implementation `0xa3b96Df5…ff44` since block 46,501,682; revalidated in #146) | launch / curve trading / **price lens** | 🔴 upgradeable by Flap |
| ⛔ Flap Trigger Service | `0xD3421B1b616a72bB88993A0cf75709BB8D532cc1` | scheduled callbacks | 🔴 **not our dependency since decision 39**: the vault is not a Flap canonical vault, so this backend will never knock on our door. The three cadences are run by `script/trigger-keeper.sh` ourselves (issue #68); the address stays here as historical record only |

> 🔴 **Correction, 2026-08-14 (M2-2, issue #34): GME is an enabled quote token on this chain.**
> `Portal.getQuoteTokenConfiguration(GME).enabled == 1`, default curve `CURVE_RH_25_ASSET`
> (`r = 177.68330498`; Flap's own comment reads "~$25 ref price, $10K graduation"), in force since block
> 17,391,936; a GME-quoted `TOKEN_TAXED_V3` has been launched for real on a fork. The earlier repo comment
> saying "the native token is the only enabled quote currency on this chain" was wrong. This proves only the
> **generic Portal** quote-token configuration and a GME-quoted launch. It does **not** enable
> `VaultPortal.newTokenV6WithVault`: that deprecated entry still rejects GME with `UnsupportedQuoteToken(GME)` before
> a factory is called. D0 does not use that entry: its launcher uses ordinary `Portal.newTokenV6`, so the stock-quoted
> MEME remains the executable product target.
> Measurements:
> [`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md) §4.

**Issuer permission surface** (from verified `Stock` source, each item tested): `onlyNotBlocked` is **hard-coded into `transfer` / `transferFrom` / `approve` / `permit`**; two-tier pause (per-token and global); 🔴 **`adminBurn` has no pause or blocklist check and can burn from any address**. See [`research/robinhood-stock-token-permissions.md`](./research/robinhood-stock-token-permissions.md).

---

## 4. Data Model

### 4.1 Identifiers

```solidity
seriesId = keccak256(abi.encode(memeToken, stockToken, expiry))   // uint256, used as ERC-1155 id
```

`expiry` = Unix timestamp of that week's Friday 21:00 UTC.

> 🔴 **That is a product convention, not an on-chain constraint.** The pool treats `expiry` as an opaque `uint64`: it
> neither validates nor interprets it. The frontend, the Indexer and the expiry calendar must therefore read
> `Series.expiry` from chain and **never assume Friday 21:00**. The "≥7 days of life" rule in §6.2 still holds.

### 4.2 ClearingPool Storage

```solidity
struct Series {
    address vault;          // the vault that opened this series — the only address allowed to depositAndMint
                            // (added 2026-08-11, see below)
    address memeToken;      // burned on exercise
    address stockToken;     // collateral
    uint64  expiry;
    uint128 strike;         // MEME (raw) required per 1e18 raw units of stock
    uint128 deposited;      // cumulative stock deposited (raw balanceOf units, incl. rolled amounts)
    uint128 minted;
    uint128 exercised;
    uint128 remainder;      // post-settlement leftover awaiting roll (2026-08-09 decision ①: never returns to the vault)
    bool    settled;        // settled ⟹ no further exercise
}
mapping(uint256 seriesId => Series) internal _series;   // read via series(seriesId), which returns the whole struct
```

> 📝 **2026-08-14 — do not decode against the field order above.** The actual declaration order in
> `src/ClearingPool.sol` is ordered **by storage slot** (`vault + expiry + settled` pack into one):
>
> ```
> vault, expiry, settled, memeToken, stockToken, strike, deposited, minted, exercised, remainder
> ```
>
> The listing above is ordered for readability; the two disagree, and `src/` wins.
>
> 🔴 This one is load-bearing off-chain: `cast` decodes according to the return types **you** type, not
> the real ABI. Getting a position wrong raises no error and exits zero — it just yields a plausible-looking
> set of values. Decode `settled` as some other field and a settled series counts as live coverage.
> `script/series-monitor.sh` uses the `src/` order, pinned by the "Series tuple decodes in declaration
> order" case in `.github/workflows/test/series-monitor.sh`.

```solidity
/// One issuer-gating observation record per stock (2026-08-09 decision ②, see §5.1)
/// 🔴 The implementation is **three-state**: it adds `unreadable`, and reads go through
///    gating(stockToken), which returns the whole struct. See tightenings ① / ⑦ in §5.1.
///    src/ClearingPool.sol is authoritative.
struct Gating { bool active; bool unreadable; uint64 clearedAt; }
mapping(address stockToken => Gating) internal _gating;
```

**Single-depositor simplification.** Because warrants are per-project (§2.1), each series has exactly one contributing vault. **The original "split pro-rata across contributing projects" accounting can be deleted entirely.**

> 📝 **Who `Series.vault` is: the vault registered for that MEME in the identity root** (M1-4 shipped
> "whoever opens it owns it"; M2-5 / issue #37 replaced that with this). [`src/ClearingPool.sol`](../src/ClearingPool.sol)
> is authoritative:
>
> `openSeries` requires **`msg.sender == vaultRegistry.vaultOf(memeToken)`, non-zero**, and only that address may
> `depositAndMint` afterwards. The roster is our own, separate, non-rewritable
> [`VaultRegistry`](../src/VaultRegistry.sol); its writers are a **two-slot list fixed at construction with no
> setter** (M2-6① / issue #56, decision 39-D). Slot 1 is
> [`WarrantLauncher`](../src/WarrantLauncher.sol), which writes only after ordinary `Portal.newTokenV6` returns the
> newly created token in the same D0 launch transaction; [`WarrantVaultFactory`](../src/WarrantVaultFactory.sol) only
> builds that vault and never touches the identity root. Slot 2 is
> [`PendingLauncherSlot`](../src/PendingLauncherSlot.sol), reserved for a future in-house launch stack and **unarmed
> today**; while unarmed it is fail-closed to every caller of `bind`.
> So "register a vault for a MEME that already exists" **has no entry point**: squatting is not harder, it is absent.
> Both slots share one `memeToken → vault` table, so widening the roster gives no MEME a second chance to bind.
>
> 🔴 This gate is **fail-closed**, and it can afford to be, because **none of the four collateral-moving paths read it**:
> `depositAndMint` authenticates against the `s.vault` recorded at open time, and `exercise` / `settleExpired` /
> `rollExpired` never touch vault identity. Even a totally broken identity root leaves open series depositable,
> exercisable, settleable and rollable — the worst case is "no new series", the same severity as the vault operator
> going offline. This does not contradict §5.1's "gating reads prefer fail-open": that one reads an **external**
> registry on a **collateral-moving** path, where fail-closed would freeze collateral permanently.
>
> **History**: M1-4 (2026-08-11) shipped a **permissionless** `openSeries`, because the pool could not tell on-chain
> which address was a MEME's legitimate vault and the alternative could not be validated inside M1 (the factory and the
> Flap integration both land in M2). The residual exposure was squatting-induced weekly stalls, which rested on an
> external "the sequencer does not front-run or censor" assumption: atomic in-transaction retry blocks interleaving but
> not a builder/sequencer placing a batch of squats before the vault transaction (`blockhash` and timestamp are public to
> a preceding transaction in the same block). On 2026-08-13 all six fork criteria in issue **#23** passed, that
> assumption was rejected, and the structural gate above replaced it; issue **#21**'s mitigations are **not applicable**
> (issuance-liveness observability is now issue #42, normal priority, not a release blocker).
> Decisions and evidence: `design.md` §10-34 / §10-38,
> [`research/flap-vault-identity-spike.md`](./research/flap-vault-identity-spike.md),
> `test/fork/RobinhoodVaultIdentity.t.sol`, `test/fork/RobinhoodWarrantVaultFactory.t.sol`.
>
> **② Reads go through `series(seriesId)`, which returns the whole struct; no auto-getter.** A ten-field positional
> tuple is far too easy to misread off-chain and in tests — `minted` and `exercised` are the same type and width, so
> swapping them compiles silently. Also added `seriesIdOf(meme, stock, expiry)` (`pure`) so the vault (M2) and off-chain
> services have **one** authoritative formula instead of each copying it.
>
> **③ Two hardenings on the quantity path**: every `uint128` narrowing goes through SafeCast — a bare cast **truncates
> silently**, recording a `2^128 + 5` deposit as 5 while minting `2^128 + 5` warrants; and `depositAndMint` is
> `nonReentrant` — balance-delta accounting is **inherently reentrancy-sensitive**: if the token calls back mid-transfer,
> the inner deposit is counted again by the outer one, so `T1 + T2` of collateral mints `T1 + 2·T2` warrants. The pool
> accepts **any** stock token (the open gate authenticates the MEME's vault; the pool does not interpret
> `stockToken`), so that path is reachable.

### 4.3 Units

**All quantities use raw `balanceOf` units.** The frontend multiplies by `uiMultiplier()` for display.

> Rationale: under EIP-8056 a split changes `uiMultiplier`, not `balanceOf`. Accounting in "shares" would desynchronize obligations from pool holdings on the first 2:1 split. See [`research/tokenized-stock-dividends-erc8056.md`](./research/tokenized-stock-dividends-erc8056.md).

---

## 5. Contract Design

### 5.1 ClearingPool (🔴 immutable, one per chain)

**The only contract holding user claims.** Design principle: **as few functions as possible, no admin, no upgrade.**

```solidity
interface IClearingPool {
    /// 🔴 Only the vault registered for that MEME in the identity root may call this
    ///    (`msg.sender == vaultRegistry.vaultOf(memeToken)`, non-zero). Once only; see §4.2.
    function openSeries(
        address memeToken, address stockToken, uint64 expiry, uint128 strike
    ) external returns (uint256 seriesId);

    function depositAndMint(
        uint256 seriesId, address to, uint256 expectedAmount
    ) external returns (uint256 minted);

    /// Exercise: burn warrants (msg.sender) + burn beneficiary's MEME + send stock to beneficiary, atomically.
    /// The attestation gate and the MEME payment both apply to the beneficiary (2026-08-09 decision ③).
    /// Callable only by the beneficiary or the MerkleDistributor (prevents forced third-party exercise).
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external;

    /// Observe and record issuer-gating state transitions for a stock (anyone; Monitor as backstop)
    function pokeGating(address stockToken) external;

    /// Lazy settlement (anyone): requires the exercise window to be over and no live gating
    function settleExpired(uint256 seriesId) external;

    /// Pool-internal rollover (anyone): credit a settled series' remainder to its successor and
    /// mint warrants to the distributor — custody never leaves the pool (2026-08-09 decision ①)
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external;
}
```

**`depositAndMint` — mint from the observed delta, never the argument:**

```solidity
uint256 before = IERC20(s.stockToken).balanceOf(address(this));
IERC20(s.stockToken).safeTransferFrom(msg.sender, address(this), expectedAmount);
uint256 delta = IERC20(s.stockToken).balanceOf(address(this)) - before;
warrant.mint(to, seriesId, delta);
s.deposited += SafeCast.toUint128(delta);
s.minted    += SafeCast.toUint128(delta);
```

> 📝 **2026-08-11 (M1-4, issue #9)** — `openSeries` has four preconditions, each blocking something that cannot be
> undone once the series exists (a series can never be closed or edited): zero-address tokens, `strike == 0`, an
> `expiry` that is not in the future, and already-open. **`strike != 0` is load-bearing**: the rollover below uses
> `n.strike != 0` as its "successor exists" predicate, so a zero-strike series is invisible to it — and exercising
> against it would hand out the stock token for free.
>
> ✅ **M1-6 added the settlement gate**: `depositAndMint` checks `s.settled` before any transfer, so a settled series
> cannot receive another deposit. Without it, collateral arriving after `remainder` was fixed would be stuck forever in
> a pool with no admin or withdrawal path.

**`exercise` must be atomic:**

```solidity
require(msg.sender == beneficiary || msg.sender == distributor, "not authorized");
require(!s.settled, "settled");
require(block.timestamp < _exerciseDeadline(s), "expired");   // gating can extend — see below
require(attestations.attestedVersion(beneficiary) != 0, "not attested");  // 0. gate checks the BENEFICIARY, see §5.5
uint256 memeAmount = amount * s.strike / 1e18;
s.exercised += SafeCast.toUint128(amount);                            // book first; any failure rolls everything back
warrant.burn(msg.sender, seriesId, amount);                          // 1. burn warrants (holder: self or distributor)
IERC20(s.memeToken).safeTransferFrom(beneficiary, BURN_ADDRESS, memeAmount);  // 2. burn the beneficiary's MEME
IERC20(s.stockToken).safeTransfer(beneficiary, amount);              // 3. send stock — may fail under issuer gating
```

A failure in step 3 reverts everything — which is the desired behavior: **under an issuer freeze the user does not lose the warrant.**

Step 0 is the **only** precondition, and it is **structurally incapable of locking anyone out** — `attestedVersion` is monotonic, writable only by the account itself, and `versions[0]` is permanently available (§5.5). **It appears only on `exercise()`, never on `claim()` or any transfer path** — only exercise touches tokenized equity. 🔴 **The gate checks `beneficiary`, not `msg.sender`** — otherwise the distributor path (§5.4) would hollow it out.

🔴 **The caller restriction is defensive**: a MEME approval expresses "willing to pay for my own exercise," not "anyone may time it for me." Without the restriction, a third party could force-swap a beneficiary's MEME into stock at a moment chosen against their interest.

> 📝 **Six tightenings made while implementing this** (2026-08-11, M1-5, issue #10). The block above is
> the design sketch; [`src/ClearingPool.sol`](../src/ClearingPool.sol) is authoritative:
>
> **① One more gate — "the series is open"** — placed after the caller whitelist and before `!settled`.
> An unopened series has `expiry == 0`, so the deadline check *does* stop it **today** — but that is a
> coincidence, not structure: once the deadline becomes `max(expiry, clearedAt + 48h)` (#11), an unopened
> series picks up the `gating[address(0)]` record and the deadline check lets it through first, leaving
> "the caller happens to hold no warrants of that id" as the last line of defence. Same trade-off as
> §4.2 tightening ① made for `depositAndMint`: write it as an explicit comparison.
>
> **② An exercise whose MEME cost rounds to zero is explicitly rejected** (`ExerciseRoundsToZeroMeme`).
> `memeAmount` rounds down, so the `amount × strike < 1e18` band would take stock **without burning a
> single MEME** — the integer version of exactly what `openSeries`'s `strike != 0` gate exists to stop.
> 🔴 The pricing formula was **not** switched to rounding up: it is stated in this section and on the
> interface, so changing it is a product decision; refusing an exercise that computes to "free" only ever
> errs safe, and the beneficiary can simply pass a larger `amount`. What remains is a rounding *discount* —
> what goes unpaid is always the truncated fraction, i.e. **strictly less than 1 raw MEME unit (1e-18)
> per exercise**. In the dust band its *relative* size can be large (at `strike = 1e17`, exercising 19 raw
> pays 1 instead of 1.9), but the *absolute* bound is pinned at "< 1 raw unit per call" independently of
> how many calls are made — and every call costs a full exercise's gas, orders of magnitude more.
> The `uint128` narrowing of `amount` happens **before** the multiplication: with both factors ≤ 2^128−1
> the product structurally fits in 256 bits (no `Math.mulDiv` needed, and no Panic(0x11) possible), and an
> oversized exercise gets a `SafeCastOverflowedUintDowncast` carrying the value rather than a misleading
> "insufficient MEME balance".
>
> **③ Bookkeeping moved ahead of the three steps** (checks-effects-interactions), plus `nonReentrant`.
> The sketch puts `s.exercised += amount` last; exercise hands control away **twice** (the MEME transfer
> and the stock transfer) and both tokens are arbitrary contracts. The guard is about **cross-function**
> interleaving: #11 / #12 are not written yet, and letting them be called into the middle of a
> half-completed exercise is a problem there is no reason to leave for later.
>
> **④ The pool does not check the balance delta at `BURN_ADDRESS`.** On the deposit side, delta-based
> accounting exists because over-minting breaks solvency. Here, checking the delta would only enforce the
> deflation property — at the price that if MEME ever taxes `transferFrom(user, 0xdead, …)`, the immutable
> pool would revert **every** exercise forever. Better to burn slightly less than to let an external
> contract's parameter change brick users' warrants. A pinned acceptance suite retains reproducible evidence,
> while a separate latest-state canary watches the current `FlapTaxTokenV3` / Portal state. It pins the
> new-launch selection chain itself — Portal implementation → immutable launcher → immutable supported
> TaxTokenV3 implementation — plus all three runtime codehashes and both dead-transfer paths on a freshly launched
> GME-quoted V3 token. Both layers must actually
> execute in CI-required mode rather than silently skip.
> ⚠️ That file's header records a gap that is still open: Robinhood Chain has no Flap token with an active
> tax branch yet, so the **positive control on the target chain has not been obtained** (issue #5's
> residual gap).
>
> **⑤ Both ERC-20 calls verify the sender's actual debit.** MEME must debit the beneficiary by exactly
> `memeAmount`, preventing return-true/no-op free exercises and sender-pays-extra overcharges. Stock must debit
> the pool by exactly `amount`, preventing no-op delivery failures and extra debits that undercollateralise the
> remaining warrants. This deliberately does **not** require exact recipient credits: recipient-side taxes at
> `0xdead` or the stock beneficiary remain compatible with tightening ④.
>
> **⑥ `_exerciseDeadline` is `s.expiry` for now**; it is a separate function purely as the landing site
> for #11. 🔴 The test is `block.timestamp < deadline`, while `settleExpired` uses `>= deadline` — the two
> must be strictly complementary, or a one-second window opens in which a series can be neither exercised
> nor settled. Pinned by
> `test/ClearingPoolExercise.t.sol::test_exercise_rejectsAtAndAfterTheDeadline`.
>
> Both halves of invariant 3 (failure side: "nothing moved"; success side: "all three legs move together,
> by the same amount") live in
> [`test/invariant/Invariant3ExerciseAtomicity.t.sol`](../test/invariant/Invariant3ExerciseAtomicity.t.sol).
> 🔴 Atomicity is the EVM's default, and **the only shape that breaks it is explicitly swallowing a step's
> failure** — which makes the success side the load-bearing half: with only the failure side, "swallow
> step 3" sails straight through, and that is precisely the case where the user paid, burned the warrant,
> and received nothing.

#### Exercise window and gating extension (2026-08-09 decision ②)

R2 promises that warrants "auto-extend rather than expire" while the issuer gates transfers. The pool is immutable, so the extension must be a **structural, admin-free behavior**:

```
_exerciseDeadline(s) = gating[s.stockToken].active
                        ? ∞                                        // gating observed: no deadline
                        : max(s.expiry, gating[s.stockToken].clearedAt + GRACE)   // GRACE = 48h
```

- **`pokeGating(stock)`** reads the issuer's live state (`Stock.paused()`, global pause, registry `isBlocked(address(this))` — all public views) and records **transitions only**. Anyone may call; the Monitor (§9) is the operational backstop.

  🔴 **`clearedAt` must be written only on the `active: true → false` edge.** Writing it on every clean poke is a **permanent settlement-griefing vector**: anyone could call `pokeGating` every 47 hours, keep pushing `clearedAt` forward, and hold `clearedAt + GRACE` permanently in the future — `settleExpired` would revert forever, `remainder` would never roll, and the attacker would hold an indefinitely extended free option on a series that should have died. Invariant 4(b) does **not** catch this (its premise is stated in terms of `clearedAt`, so a moving `clearedAt` makes the premise vacuous) — invariant 4(c) exists for exactly this.

  ```solidity
  function _observe(address stock) internal {
      bool hit = _readGating(stock);              // fail-open, see below
      Gating storage g = gating[stock];
      if (hit && !g.active)       { g.active = true; }
      else if (!hit && g.active)  { g.active = false; g.clearedAt = uint64(block.timestamp); }
      // clean → clean and gated → gated are both no-ops: clearedAt is NEVER touched
  }
  ```

- **`settleExpired(seriesId)`** first re-runs `_observe` (self-healing stale observations), then requires `block.timestamp ≥ _exerciseDeadline(s)` and a clean live read before setting `settled = true` and `remainder = deposited − exercised`. **While gated, settlement is structurally blocked and the exercise window remains open — that IS the auto-extension.** If the issuer still blocks stock transfers, `exercise` atomically reverts and leaves the warrant and MEME untouched. 🔴 **`pokeGating` closes the window; it does not open it.** Exercise reads the *record*, and a record that says "gated" means no deadline — so **the moment the issuer clears, exercise works again, with no poke required**. Observing the clearing does exactly one thing: it collapses the unbounded window into `max(expiry, clearedAt + 48h)`. After that deadline, anyone may settle.
- **Fail-open**: if the gating views revert (the issuer upgraded the interface), treat as not gated. Interface changes are far more likely than malicious freezes, and fail-closed would deadlock settlement and rollover **permanently** — the pool is immutable, so an interface that never becomes readable again would freeze every series' collateral forever. That is strictly worse than the failure fail-open admits.

  **But fail-open must also open the grace window.** A view revert is treated as a clear transition (`active = false, clearedAt = now`) if the previous state was gated, and — when the previous state was already clean — the *first* revert observed for that stock likewise stamps `clearedAt = now`. Rationale: if the token is genuinely paused while the views are unreadable, exercise fails but settlement would otherwise proceed on schedule and **holders lose warrants they had no way to exercise**. The 48h stamp costs nothing and buys human assessment time. The Monitor alerts separately on view failure.

  > Implementation note: this is the one case where `clearedAt` may be written without a true `true → false` edge. Bound it to "the transition into unreadable state," not "every unreadable read," or the griefing vector returns through the back door.

- **Unpoked gating produces no extension** — the contract only trusts recorded observations. Poking is therefore a hard operational duty of the Monitor, but any holder can poke; there is no permissioned dependency.
- **Per-address blocks do not extend anything.** `pokeGating` reads `isBlocked(address(this))` — the *pool*. If the issuer blocks an individual holder while the pool stays clean, settlement proceeds on schedule and that holder's warrants die. This is deliberate (one blocked address must not extend the series for everyone) but it is a real, unrecoverable user loss — see §11.

> 📝 **Ten tightenings made during implementation, 2026-08-12** (M1-6, issue #11). [`src/ClearingPool.sol`](../src/ClearingPool.sol) is authoritative; the sketch above remains a sketch.
> ⚠️ **Issue #11's acceptance criteria were amended on the same date**: "exercise still succeeds past expiry" is
> unachievable — the stock cannot leave the pool while the issuer is paused, so `exercise` reverts atomically.
> The extension grants a **window**, not **delivery**; and once the issuer clears, exercise works *immediately* —
> `pokeGating` closes the window, it does not open it (same precedent as issue #9).
>
> **① `Gating` is three-state, not two** — it gains an `unreadable` field. The rule stated above ("bind it to the transition *into* the unreadable state") is only expressible with it: with two fields, "is this outage new?" can only be answered from `clearedAt` itself, so **every** unreadable read would re-stamp — precisely the back door this section names. Three fields are 10 bytes in one slot, so it costs no gas. By construction `unreadable ⟹ !active`, giving exactly three states: clean / gated / unreadable. The full 3×3 transition table lives in the `_observe` comment.
>
> **② 🔴 One attack is not in that table: starving a healthy view of gas.** "Unreadable" is implemented as "this call failed", and how much gas is forwarded is up to the *caller*. Without a floor, anyone can craft a gas-metered transaction that drives a perfectly healthy view out of gas, fabricating the `clean → unreadable` edge, and repeat every 47 hours — the griefing vector returns through the back door with the edge semantics written perfectly. So each read first requires `gasleft()` to cover a full `GATING_READ_GAS` forward under EIP-150's 63/64 rule, and **reverts on the spot** rather than recording an "unreadable" observation. 🔴 The threshold is `ceil(budget × 64 / 63) + GATING_STATICCALL_OVERHEAD`, and **both terms are required**: the 63/64 truncation happens *after* `STATICCALL` has paid cold-account access and base cost, so the first term alone still lets a precisely metered gas limit hand a healthy view less than the budget and fabricate an "unreadable + stamp". Both constants are public — two halves of one formula, and publishing only one leaves off-chain callers unable to compute the floor. 📏 The budget is **50,000**: one whole `pokeGating` against real GME (three cold-account reads + event + the floor checks) measures roughly **32k** gas, printed and asserted with margin by `test/fork/RobinhoodGating.t.sol`.
>
> ⚠️ **Operational note: do not turn either measurement into a transaction `gasLimit`.** The fork measurement invokes `address(pool).call{gas: ...}(...)`: its binary search measures only the execution gas explicitly forwarded by that Solidity test contract to the Pool's child call. It is **not** an EOA or Monitor top-level transaction `gasLimit`; top-level intrinsic and calldata costs, and any Monitor calling wrapper, change the result. For every production `pokeGating`, the Monitor must run `eth_estimateGas` on the actual target chain with the actual sender, calldata, and complete calling/wrapping path, then leave an appropriate safety margin. Do not hardcode an absolute top-level number or size from the roughly 32k gas-spent measurement.
>
> **③ The three reads and where they come from.** `stock.paused()` covers both the per-token and the global pause in a single read (`Stock.paused()` returns `$.paused || registry.paused()`); the registry address is **read from the token itself** (`ACCESS_CONTROLLED_REGISTRY()`, measured against GME on 2026-08-12: `0xe10b…1b00`) and never hardcoded — the pool is immutable, and hardcoding would assume this chain will only ever have one issuer permission system. Signatures live in [`src/interfaces/IIssuerGating.sol`](../src/interfaces/IIssuerGating.sol). 🔴 Return values are decoded as `uint256` (non-zero = true), **not** `abi.decode(…, (bool))`: the latter reverts on a dirty bool, and that revert would escape a function whose whole job is to swallow failures — a token returning dirty bytes could make every poke and settlement revert, turning **fail-open into fail-closed**. Return data that is not exactly 32 bytes, or a registry address with dirty high bits, counts as unreadable.
>
> **④ `unreadable → clean` does not re-stamp.** Entering the unreadable state already stamped once; stamping on the way out turns "in → out → in" into a pump that pushes `clearedAt` forward. The cost, stated plainly: if the token really was paused for the whole unreadable window and only became readable afterwards, those 48 hours are already spent — that is the loss §11 records.
>
> **⑤ The observation inside `settleExpired` only persists when the settlement succeeds.** It rolls back with the transaction. So a series whose record says "gated" while the live read is clean cannot have its grace burned down by repeatedly probing `settleExpired` — that clock is started by a `pokeGating`. The operational rule is therefore **poke, wait until `max(expiry, clearedAt + 48h)`, settle**, not "keep retrying settleExpired"; liveness is unaffected because poking is permissionless. 🔴 This also sharpens **invariant 4(b)**'s premise: the clean live read and `clearedAt` must come from the **same** observation. When the record is stale, settlement self-heals on the spot, and that self-healing may stamp a fresh grace — which is not "settlement blocked", it is "the clearing was only just observed, so the deadline is recomputed as `max(expiry, clearedAt + 48h)`".
>
> **⑥ `nonReentrant` on `settleExpired` is load-bearing, not ceremony.** Without it, `depositAndMint`'s "no deposit after settlement" gate can be bypassed: deposits transfer first and account second, and the transfer hands control to the stock token; the token settles the series from its callback, and on return the deposit records the collateral into `deposited` and mints warrants — while `remainder` was already fixed at settlement time. That collateral would be stuck in the pool forever and its warrants would be unexercisable. The guard is **cross-function** (one transient slot), so the path is closed.
>
> **⑦ `gating` and `exerciseDeadline` are explicit views; no auto-getter.** Same reason as `series()`: `active` and `unreadable` are adjacent same-typed booleans whose meanings are opposites, and a positional tuple can be misread silently. Internal visibility has a second use: the invariant counter-proof needs to install a "stamp on every poke" backdoor, and production code leaves no hooks.
>
> **⑧ `depositAndMint` gained its `settled` gate** — the one flagged in §4.2's tightenings; this ticket delivers it.
>
> **⑨ `clearedAt == 0` is a sentinel and does not enter the `max`.** On any real chain `max(expiry, 0 + 48h)` equals `expiry`, but `0` means "no clearing has ever happened", not "cleared on 1970-01-01". Writing it as a sentinel keeps a test whose timestamp is below 172800 from receiving a 48-hour exercise window out of nowhere.
>
> **⑩ `pokeGating` rejects the zero address.** `_gating[address(0)]` is the record an **unopened series** would read; keeping it permanently zero is cheaper than re-deriving "who could read it" every time a function is added.

#### Pool-internal rollover (2026-08-09 decision ①)

The original `claimExpired()` returned expired remainders to the vault, which redeposited them. **That path is abolished**: at steady state the pool holds ≈ `S/f` (R13), and the entire amount would pass through the vault once per week, blowing the in-transit window up from "one day of tax" to "the entire pool" and defeating the "in-transit ≤24h" claim. (📝 The original reason read "the Guardian-upgradeable vault" — that risk is gone as of issue #58, but the trade-off is not.)

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
    warrant.mint(distributor, nextSeriesId, amt);   // internal reassignment; the stock never leaves this contract
}
```

- Every check is self-verifiable by the pool (same meme/stock, successor open and live), so the call is **permissionless**, matching `settleExpired`'s lazy style
- **The vault now only ever handles freshly dispatched tax** (≤24h), restoring R4's claim
- Edge case: if a project halts and no successor series exists, the remainder stays in the pool (the inevitable consequence of no admin) — the Trigger Service, or anyone else, can reopen a series via permissionless `vault.openSeries()` and resume rollover at any time. **No loss, only delay**

> 📝 **Eight tightenings applied while implementing (2026-08-13, M1-7, issue #12).** [`src/ClearingPool.sol`](../src/ClearingPool.sol) is authoritative; the block above remains a design sketch.
>
> **① Six gates, each with its own error.** The sketch folds "settled" and "remainder non-zero" into one `require`; the implementation splits them into predecessor **open** / **settled** / `remainder != 0`. The first overlaps the second (an unopened series is never settled) and is kept only for the error surface: a caller who mistyped an id gets "this series does not exist" rather than "it is not settled yet". 🔴 The third gate **is** the entire implementation of "cannot roll twice" — the remainder is zeroed, so the second attempt hits it. No separate "already rolled" flag.
>
> **② 🔴 The successor's liveness is compared against `n.expiry`, not `exerciseDeadline(n)`.** Gating extension keeps an already-expired series exercisable; using the deadline as the predicate would let anyone roll a remainder into an old series that expired long ago and merely has not been settled. The collateral is not lost (it rolls onward when that series settles), but **the current week's merkle root never receives it**, and the warrants minted to `distributor` are covered by no root and stay there forever. **The smaller the set of legal successors, the better** — so the strict comparison wins. With no gating the two are identical anyway.
>
> **③ `nextSeriesId == seriesId` needs no separate gate.** The predecessor must be settled and the successor must not be; the same id cannot satisfy both.
>
> **④ The predecessor's `deposited` is not written back.** It records what that series ever received; the roll only clears `remainder`. So after a roll the predecessor's ledger still shows `minted − exercised > 0` while its collateral now belongs to the successor — which is exactly why **invariant 1(a) must be scoped to unsettled series** (§7). What makes that harmless is not the wording of the predicate but `settled ⟹ exercise reverts` (invariant 4(a)); solvency across the roll is invariant 1(b)'s job. 🔴 issue #5 names this: **1(a) must not be weakened into something that passes** — what is removed is an inapplicable premise, not the predicate.
>
> **⑤ `nonReentrant` is not load-bearing here.** The only external call is `warrant.mint(distributor, …)`, whose recipient is our own `MerkleDistributor` (an `ERC1155Holder` that only returns the magic value), and the bookkeeping precedes it. It is present so the contract's reentrancy semantics stay one sentence: **no two of the six entrypoints may interleave**.
>
> **⑥ Residual exposure: the caller names the successor, and the pool cannot tell which one is "this week's".** `rollExpired` itself is permissionless — every check is self-verifiable by the pool (same (MEME, stock) pair, successor open and live) — so anyone can roll the remainder into **any legitimate successor**. 🔴 **M2-5 (issue #37) removed most of this exposure**: a "legitimate successor" must now be a series on the same MEME, and only that MEME's registered vault can open one (§4.2). Every candidate successor therefore comes from our own vault; a squatter has no entry point for creating an absurd-strike series to catch the remainder. What remains is "the wrong one of several successors opened by the same vault", which is an operational concern (issuance-liveness observability, issue #42), not an authorization one.
>
> **⑦ Invariant 5 has two halves, and neither is sufficient alone.** The structural half is "exactly six external write functions" (read off the compiled ABI, `test/ClearingPool.t.sol`). The dynamic half is "after driving all six entrypoints in any order, collateral has only ever left the pool inside `exercise`, and each time by exactly the exercised amount" (`test/invariant/Invariant5And7RollAndCustody.t.sol`). Neither catches the other: ABI enumeration is blind to a `transfer` hidden inside `settleExpired`; the dynamic half is blind to a `withdraw` nobody ever called. **The function set is only complete as of this ticket, which is why invariant 5 only becomes meaningful here.**
>
> **⑧ "A rollover is not an exit" is verified, not asserted.** The falsification backdoor is the minimal shape of the abolished design: all four ledger numbers (`remainder` down / successor `deposited` up / `minted` up / warrants minted) match **exactly**, and only the collateral takes a detour through the vault — invariant 7's conservation clause stays **silent**; only its balance clause and the custody counter see it. So every success path asserts two things at once: the pool balance is unchanged **and** the transaction contains no `Transfer` from that stock token. The latter is re-checked against real GME in `test/fork/RobinhoodRoll.t.sol`. The event is `Rolled(seriesId, nextSeriesId, amount)`, where `amount` is all four numbers.

**No admin, no pause, no withdraw, no upgrade.** The six functions above are the entire external write surface.

```solidity
address public immutable attestations;   // fixed at construction, not replaceable
```

> ⚠️ Non-replaceability is deliberate: a replaceable registry could be pointed at a contract that always returns false, freezing every exercise. We give up the flexibility rather than keep that switch.

### 5.2 WarrantVault (per project, **ours, non-upgradeable**)

> 🔴 **2026-08-16 (decision 39-A3 / issue #58): the vault is de-Flapped.** It no longer inherits
> `VaultBaseV3`, is not a beacon proxy, has no Guardian, and exposes no `vaultUISchema()` /
> `vaultSpecVersion()` / `initialize()`. The factory **deploys one directly** on every launch; all six
> arguments (pool / distributor / price-source Portal / MEME / quote token / creator — the sixth added by
> decision 49) are fixed in that one
> `CREATE`. **R4 disappears as a risk class** (`design.md` R4). Item-by-item disposition:
> [`flap-vault-spec-compliance.zh.md`](./flap-vault-spec-compliance.zh.md) §0.5.

> 📌 **Vaults are created by [`WarrantVaultFactory`](../src/WarrantVaultFactory.sol); the binding is written by
> [`WarrantLauncher`](../src/WarrantLauncher.sol)** (M2-5 / #37 → M2-6② / #57): in one transaction the launcher mints
> the token, has the factory **directly deploy a non-upgradeable vault**, and writes that MEME's single identity-root
> binding. The vault therefore carries **no** "route around squatted triples" responsibility — it is the only address
> that can open that MEME's series (§4.2).
> ⚠️ The `newVault` gate accepts **only our own launcher** (not Flap's VaultPortal — that entry point went away with
> #57). The factory's constructor `Portal` is the **price source**: the same address the launcher mints through, in a
> different role.

> 🔴 **The factory is no longer a Flap-spec factory either** (M2-6② / issue #57). It used to inherit
> `VaultFactoryBaseV2` and implement `factorySpecVersion()` / `onBeforeLaunch(bytes)` / `isQuoteTokenSupported()` /
> `vaultDataSchema()` / `resolveDividendToken(...)`. Those hooks existed **only for the VaultPortal entry point**,
> which is deprecated; all five were deleted along with the base-class inheritance, and
> `script/flap-vault-spec-check.sh` now asserts the *absence* of each. The factory's external write surface is
> **exactly three**: `newVault(address,address,address)` (launcher only), `setLauncher(address)`, and
> `setVaultTargets(pool, distributor)`. It gained one **read**: `nextVault()`, which predicts the CREATE address of the
> next vault so the launcher can put it in the launch `beneficiary` field (the tax recipient) and verify it afterwards
> (§6.1). The former note read: the second one-shot slot is
> `setVaultTargets(pool, distributor)` (🔴 **replacing `setBeacon` as of issue #58**: it no longer locks "who may swap
> the vault's implementation" but "where the money and the warrants go for every vault this factory builds"; both
> targets are code-checked, hollow addresses fail closed). The price-source `Portal` is a factory constructor argument
> (decision 39-A2). **Historical, pre-#58:** the one-shot `setBeacon` wiring also read `owner()` and accepted only a
> beacon already owned by the fixed Flap Guardian; missing or malformed owner reads failed closed.

**The vault's external surface** (🔴 formerly "Flap requirements, all mandatory"; after issue #58 half of the
left column has no object left and the other half is our own choice):

| Original requirement | Today |
|---|---|
| Inherit `VaultBaseV3` | ❌ removed; `vaultUISchema()` / `vaultSpecVersion()` / `guardian()` go with it |
| beacon proxy + Guardian upgrade authority | ❌ removed — **non-upgradeable**: the bytecode is fixed in that one `CREATE` |
| `initialize(address,address)` | ❌ removed — no proxy means no "deploy then initialize" beat; both identity arguments moved into the constructor |
| `vaultQuoteToken()` | ✅ kept (`immutable`) — the ops surface reads it (`series-monitor.sh`, on-chain verification) |
| `receive()` + balance-delta accounting | ✅ kept — D0 does not change the tax path, so the ping contract still describes reality |
| `description()` | ✅ kept — it renders `inTransit()`, the live read of the in-transit window |
| **Zero permissioned surface** | ✅ kept — the reason changed from "the spec grants every permissioned function to the Guardian" to **our own**: it is the shortest proof that the vault cannot take the money. ⚠️ As of decision 49 the precise reading is "cannot hand the **caller** the money": `claimCreatorFee` is a permissionless, fixed exit worth at most 10% of revenue whose payee is pinned at launch — no calldata byte can redirect it |
| price-source `Portal` | ➕ new **constructor argument** — no more `chainId` table, so old and new price sources coexist by construction (decision 39-A2) |

```solidity
contract WarrantVault {
    // issue #58: arguments fixed in one CREATE; nothing can write them afterwards.
    // Decision 49: creator_ is the sixth — the launcher's msg.sender, sole payee of the creator fee
    constructor(IClearingPool pool_, address merkleDistributor_, address portal_,
                address taxToken_, address quoteToken_, address creator_);

    function sampleTwap() external;       // M2-2: permissionless, normally once per hour
    // M2-4 shipped: read the 24h TWAP → strike = TWAP × 0.8 → open this week's series on the pool
    function openSeries() external returns (uint256 seriesId, bool opened);
    // M2-4 shipped: view preflight — "is this week open, and if not, why?"
    function openSeriesStatus() external view returns (uint256 status, uint64 expiry, uint128 nextStrike);
    function processRevenue() external;   // M2-3 shipped: deposit received stock, mint warrants
                                          // Decision 49: 10% of each depositable batch goes to the
                                          // creator — accrued from the measured debit after the deposit
                                          // (confirmedCut = min(cut, sent/9)); neither a fake transfer
                                          // nor a partial debit can skim the undelivered part
    // Decision 49: transfer the accrued fee to the creator. Permissionless — anyone may trigger it,
    // the payee is a constructor-pinned immutable no calldata byte can change; requests
    // min(creatorAccrued, actual balance) and settles by the measured debit; a zero accrual is a silent no-op
    function claimCreatorFee() external returns (uint256 claimed);

    // ⚠️ No sweepExpired — expiry settlement and rollover live on the ClearingPool side
    // (settleExpired / rollExpired, permissionless). The vault never handles expired
    // remainders (2026-08-09 decision ①): routing the whole pool through it weekly
    // would blow the in-transit window up from "one day of tax" to "the entire pool".
    // (The original reason read "it is a Guardian-upgradeable beacon proxy, defeating R4";
    //  R4 is gone as of issue #58, but this trade-off never depended on it.)
}
```

**`processRevenue()` must not live in `receive()`.** `receive()` is triggered by Flap's dispatch; running deposits and mints there raises gas materially and any revert disrupts Flap's tax settlement. **Keep `receive()` to accounting only.**

> 📝 **2026-08-13 tightening (M2-1 shipped, issue #33), updated 2026-08-14 for M2-2 / #34, M2-3 / #35 and
> M2-4 / #36.** The implementation lives in [`src/WarrantVault.sol`](../src/WarrantVault.sol):
> `sampleTwap()`, `openSeries()` and `processRevenue()` are all shipped. M2-0 through M2-4 are implemented and tested.
>
> Combined implementation hardening — `src/` wins:
>
> 1. **The external write surface is exactly six entries** (🔴 **as of issue #58**: `initialize` went away with
>    upgradeability, six became five; 🔴 **as of decision 49**: `claimCreatorFee()` joined, five became six) —
>    `sync()` / `sampleTwap()` / `openSeries()` / `processRevenue()` / `receive()` / `claimCreatorFee()`
>    — and **none is permissioned**, proven by enumerating the compiled ABI. The *reason* for that property is now
>    ours (a zero permissioned surface is the shortest proof the vault cannot hand the caller the money); the *test* is
>    unchanged. `sampleTwap()` keeps an explicit liveness-versus-timing trade-off for its external price
>    source; the caller of `processRevenue()` cannot alter the immutable `pool` / `merkleDistributor` destination;
>    the caller of `openSeries()` picks no argument at all — only the *instant*, which §6.2's 24-hour window bounds;
>    the caller of `claimCreatorFee()` (decision 49) cannot alter the payee — funds only ever reach the
>    constructor-pinned `creator`.
>    Rule-by-rule mapping:
>    [`flap-vault-spec-compliance.zh.md`](./flap-vault-spec-compliance.zh.md).
> 2. **`receive()` never reverts on any path.** The quote balance is read through a **gas-capped `staticcall`**
>    (200k); an unreadable balance emits `QuoteBalanceUnreadable` and returns silently. Recognition is
>    delta-based, so the next wake or `sync()` picks it up in full. Measured on real GME: ~48k gas for the
>    first ping against a 1M spec budget.
> 3. **`sync()`** — the spec-recommended permissionless recovery entry (direct transfers, donations, or pings
>    switched off) — was not in this section before.
> 4. **The upstream files are vendored byte-for-byte** into [`src/flap/`](../src/flap/) and pinned
>    by a sha256 manifest. ⚠️ As of issue #58 the `VaultBase*` trio is **no longer inherited**, and as of issue #57
>    `VaultFactoryBaseV2` is no longer a Factory base either; those old bases are kept only as an archive of the ping
>    contract / balance-delta model and of the old `chainId` address table. `IPortal` is different: the launcher still
>    imports its types in production, so its vendored definition remains a live interface rather than an archive.
>    Re-writing that interface by hand would let entity-level details drift silently.

> 📝 **2026-08-14 M2-3 hardening (issue #35).** `processRevenue()` completes the six-entry surface listed above.
> Its additional six points — `src/` wins (decision [`design.md`](./design.md) §10-36):
>
> 1. **Two addresses are `immutable` on every vault.** `pool` and `merkleDistributor` are constructor
>    arguments — **not** `initialize` parameters and not launch parameters. This is decision 33's hard
>    constraint: the Factory's deployer-only, one-shot `setVaultTargets` supplies both destinations. The current
>    `newVault(taxToken, quoteToken, creator)` receives the token returned by the launcher, a code-checked
>    user-selected quote token, and the creator; none can become a source of privilege.
>    ⚠️ **Decision 49 revises the creator's half of that sentence**: it is no longer "used only in the event" —
>    it is forwarded into the vault constructor as the sixth `immutable` (the fee's sole payee). "No source of
>    privilege" holds unchanged: the creator gains no call authority, only a fixed payout path anyone can
>    trigger on their behalf; the launcher still cannot redirect tax, deposits, or minting anywhere.
> 2. **The signature returns a value**: `function processRevenue() external returns (uint256 minted)`.
> 3. **Two edges return cleanly; everything else fails honestly.** Zero balance, and no live series (emits
>    `RevenueDeferred` — **the money stays in the vault and waits**): the Trigger Service runs this daily
>    against an empty vault and a revert would pollute alerting. Issuer pause, a blocked pool address, and
>    **an unreadable balance** all revert the whole transaction.
>    🔴 **An unreadable balance must be loud, not skipped.** The 200k gas cap exists only for `receive()`'s
>    never-revert promise, while `pool.depositAndMint` reads `balanceOf` **uncapped**. Reusing the cap would let
>    a quote token whose `balanceOf` merely got *more expensive* (one issuer implementation swap away) turn the
>    vault into a permanent, silent refusal to ship — which is the R4 exposure itself. So `processRevenue`
>    reads the balance uncapped. **Delay only, never loss.**
> 4. **"Live series" means `strike != 0 && block.timestamp < seriesExpiry`.** The pool deliberately does *not*
>    block deposits past expiry (gating can keep the exercise window open), so this is a **vault-side policy**:
>    minting warrants into a series whose exercise window has closed hands people waste paper. The same test
>    also implies "not settled", so `SeriesSettled` is unreachable from here.
> 5. **No `SafeERC20` for the approval**, and an approval failure **bubbles up the quote token's own revert
>    data unchanged**; the return value is decoded as `uint256` and treated as true when non-zero
>    (`abi.decode(…, (bool))` does `revert(0,0)` on a dirty bool, erasing the error entirely — the same
>    trade-off as `ClearingPool._readGating`) — real GME's `approve` carries `onlyNotPaused` + `onlyNotBlocked`, and replacing its
>    `IsPaused()` with a message of ours would misreport "the issuer flipped a switch" as "our code is broken".
>    The allowance is exactly this deposit's amount and is zeroed straight after, so **between transactions the
>    vault's allowance to the pool is always 0**.
>
> 6. **A new view `inTransit()`** returning `(amount, exact)`: how much collateral is sitting in the vault
>    right now, waiting to be deposited. 🔴 **That — not `accountedQuote()` — is the R4 exposure gauge.**
>    The baseline only counts *recognized* revenue, so it reads zero in exactly the failure that most deserves
>    an alarm: tax still arriving while nothing is waking the vault. If `exact == false`, the return is
>    `(0, false)`: the balance is unreadable and the amount is **unknown**, not zero and not a lower bound.
>    `description()` renders this as an unreadable amount rather than a healthy zero.
>    🔴 **As of decision 49 it returns `balance − creatorAccrued` (saturating)**, not the raw balance —
>    "in transit" is pinned to mean "money that should have become warrants and has not yet", and the
>    creator's unclaimed fee is not part of it. That one definition keeps four consumers correct at once:
>    the keeper's zero-balance skip, the `REVENUE_SENT_ZERO` alert, series-monitor's wound-down downgrade
>    branch, and `description()`'s "nothing in transit" banner — a raw-balance reading would jam all four
>    on a float that never clears.
>
> 🔴 **The hard constraint M2-4 obeys**: `openSeries()` calls `pool.openSeries` **first** and writes
> `strike` / `seriesExpiry` **second**. The other order leaves the fields pointing at somebody else's series
> whenever opening fails, and `processRevenue` then reverts with `NotSeriesVault` forever — revenue can never
> leave the vault again. Counter-test: `test_openSeries_writesNothingWhenThePoolRejects`.

> 🔴 **`accountedQuote` is the balance-delta baseline, and `processRevenue()` must decrement it by every
> amount it spends, in the same transaction.** Forget that and the baseline stays permanently above the real
> balance, `balance <= accountedQuote` suppresses all future revenue recognition, and the vault deadlocks — with
> no error anywhere. It is the single most dangerous mistake a V3 vault can make (spec rule 010).
>
> 📝 What M2-3 does (amounts revised by decision 49; the discipline is unchanged): it asks the pool to pull the
> **observed depositable** amount (`available = balance − creatorAccrued`, saturating, minus this batch's 10%
> `cut`), then, after clearing the allowance, re-reads the vault balance and writes
> `accountedQuote = balanceAfter`. `sent` is `max(balanceBefore - balanceAfter, 0)`. The baseline no longer
> returns to zero after a deposit — it equals the creator float plus dust; a token that reports success without
> deducting the vault cannot falsely clear it, inflate `sent`, **or accrue a fee** — the fee is derived from
> the measured debit (`confirmedCut = min(cut, sent × 1000/9000)`), so neither a fake transfer nor a partial
> debit can skim the undelivered part of a batch twice (audit finding M-01). The write still sits
> **after** the external call: changing the baseline first opens a crack where a `sync()` re-entered from the
> transfer callback pushes it back to full and the eventual balance decrease deadlocks the vault. The counter-proof
> test `test_processRevenue_aReentrantSyncCannotDeadlockTheVault` drives exactly that ordering with a token that
> calls back **before** the balance moves — after decision 49 the suppression predicate is
> `balance <= accountedQuote` measured against `available`; the re-entrancy argument lives in the `src/` comments.
>
> 🔴 **`claimCreatorFee()` is the vault's second spending path, and the same rule 010-3 applies verbatim**:
> `_recognize()` first, effects before interaction (`creatorAccrued` is decremented **before** the transfer),
> and `accountedQuote = balanceAfter` in the same transaction after it. It shares one hand-rolled transient
> lock with `processRevenue()` — two spending paths re-entering each other's external call would compute the
> depositable amount from a "balance not yet debited, books already changed" intermediate state. The OZ
> `ReentrancyGuardTransient` cannot be inherited: the vault's error surface must stay empty (rule 004) and its
> inheritance linearization must remain exactly `[WarrantVault]` (spec-check assertion).

**TWAP** (shipped in M2-2, issue #34; [`src/WarrantVault.sol`](../src/WarrantVault.sol) and
[`src/PriceSource.sol`](../src/PriceSource.sol) are authoritative):

```solidity
struct Sample { uint64 ts; uint192 price; }   // price = raw MEME per 1e18 raw units of stock
Sample[24] private _ring;
Sample private _twapBoundary;                 // overwritten left boundary after the ring wraps

function sampleTwap() external returns (bool written);         // permissionless, writes only if >= 1h since the last
function twap() public view returns (uint256 status, uint256 price);  // never reverts; failures return a code
```

> **Integration boundary (wired by M2-4 / #36).** `twap()`'s reading is consumed by `openSeries()`, which fails
> closed on **every** non-zero status — only `0` proceeds. `openSeriesStatus()` reports that as a single code
> (`3 = OPEN_TWAP_UNAVAILABLE`) and deliberately does **not** forward TWAP's own six codes: `twap()` is their one
> authoritative source.

> **Why TWAP is mandatory for M2-4.** The strike is set once per week and governs a full week of issuance. Reading spot means a single pump locks in a week's strike.

**Price source and the 🔴 dimension inversion.** The curve phase reads
`Portal.getTokenV8Safe(meme).price`; after graduation, the DEX pool. 🔴 **Flap gives the reciprocal**: its
`price` is "raw quote per 1e18 raw MEME", while we need "raw MEME per 1e18 raw stock", so sampling computes
`1e36 / price`. The inversion happens **at sample time, not at read time**, because time-weighting does not
commute with reciprocals (the reciprocal of an arithmetic mean is a harmonic mean) — the two conventions
produce different strikes. The arithmetic convention wins because (a) it matches `ClearingPool.strike`'s
dimension so M2-4 converts nothing, and (b) AM ≥ HM, so the resulting strike is the more conservative of the
two. After graduation the curve `price` is **identically 0** (measured), so the branch condition is Flap's
`status` (`1` = curve, `4` = graduated) and the two branches do not overlap. The quote token is also
cross-checked against `vaultQuoteToken()` — a mismatch refuses the sample, because then the price's
denominator is not our stock. Full derivation and measurements:
[`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md) (closes §14-6).

**Graduated V2 source: a narrow same-block guard, not a cumulative oracle.** The pool branch currently reads a
single `getReserves()` snapshot. Its third ABI word is strictly validated as a `uint32` `blockTimestampLast`; if it
equals `uint32(block.timestamp)`, `PriceSource` returns `POOL_UPDATED_THIS_BLOCK` (`9`) and `sampleTwap()` emits
`TwapSampleFailed(9)` without writing. This rejects the direct same-block "update reserves → sample spot" path.
It does **not** read `price0CumulativeLast` / `price1CumulativeLast`, does not make the spot a continuous
observation, and does not protect against manipulation that persists into another block, liquidity attacks, or any
other V2-oracle threat. The real-pair fork test checks the V2 ABI shape, including the timestamp and standard
cumulative getters; that is not evidence that this implementation uses a full cumulative-price oracle or that V2
pricing is generally manipulation-safe.

**Sampling rules.** `sampleTwap()` is **permissionless** and writes only if **at least one hour** has passed
since the previous sample (not "one per clock hour" — bucketing would let `t=3599` and `t=3601` both land,
which is exactly how an attacker squeezes 24 samples into a few minutes). Each successful write is an
**instantaneous spot snapshot**, not a statement that the price was continuously observed between timestamps.
The target cadence is one hour and `MAX_SAMPLE_GAP = 1h + 5m`: every adjacent left-endpoint segment and the newest
tail must be no longer than 65 minutes, or reads fail closed rather than pretending an old snapshot described an
unobserved interval. A delayed call may resume sampling, but it cannot make an invalid window usable until fresh
bounded coverage has been rebuilt. When no price is available it emits `TwapSampleFailed(reason)` and returns
silently; **no path reverts** (a keeper may sweep many vaults in one transaction).

**Reading.** `twap()` integrates the strict trailing interval `[now - 24h, now]`, not merely the elapsed time
between the oldest and newest occupied slot. The 24-slot ring retains price points; once it wraps,
`_twapBoundary` retains the overwritten left boundary so the next exact 24-hour interval remains reconstructible.
The first 24 hourly observations (`t0` through `t23`) span only 23 hours and are deliberately too short; the
normal next hour establishes full coverage (the recovery harness uses 25 consecutive observations `t0` through
`t24`). Each snapshot supplies a **left-endpoint** price only for its bounded segment; the newest one is weighted
only up to `block.timestamp`, so a "pump → sample → open the series immediately" sequence gives that
sample ~zero weight. Fail-closed status codes (`openSeries()` refuses on every non-zero status):

| `status` | Meaning |
|---|---|
| `0` | Usable |
| `1` | Ring not full (fewer than 24 occupied price slots) |
| `2` | Newest sample older than 2 hours |
| `3` | Strict trailing coverage shorter than 24 hours |
| `4` | Required history lies more than 30 hours back (a long outage cannot be repaired by topping up one sample) |
| `5` | An adjacent segment or newest tail exceeds `MAX_SAMPLE_GAP` (65 minutes) |

> 🔴 **The guarantee is a quantified bound, not "cannot be moved".** Under the normal strict hourly cadence, the
> 24 complete price segments each carry exactly `1/24` of the trailing window. Across every accepted window the
> hard per-segment upper bound is `MAX_SAMPLE_GAP / 24h = 65 minutes / 24 hours` (about 4.51%), not `1/24`.
> The value is still a weighted aggregate of discrete spots, not a continuously observed market price. Replacing the
> whole reading requires repeatedly controlling valid sampling segments; the permissionless cost is that anyone can
> front-run the keeper and choose those instants (not the price itself). That buys liveness when the backend dies and
> avoids giving this vault its first key. A Monitor should watch both `TwapSampled` timing and gap/failure
> events. The 200 GME fork experiment is on the **curve** branch: it demonstrates the strict-hourly aggregator against
> a real curve trade, not V2-pool manipulation resistance.

### 5.3 Warrant (ERC-1155)

```solidity
contract Warrant is ERC1155 {
    address public pool;                        // one-time binding, see §12 — NOT immutable
    address private immutable deployer;
    modifier onlyPool() { require(msg.sender == pool); _; }

    function setPool(address p) external { require(msg.sender == deployer && pool == address(0)); pool = p; }

    function mint(address to, uint256 id, uint256 amount) external onlyPool;
    function burn(address from, uint256 id, uint256 amount) external onlyPool;
}
```

> `pool` is a one-time, deployer-only, permanently locked slot rather than an `immutable` — this is what breaks the three-way constructor cycle without CREATE2 (§12). **`onlyPool` with `pool == address(0)` denies everything**, so an unbound Warrant is inert rather than open.

**Only ClearingPool may mint or burn.** Transfers are unrestricted — a precondition for Seaport trading.

> The current `uri(id)` returns an empty string and there is no metadata administrator. Read series data from
> `ClearingPool.series(id)` and compose the underlying, expiry, strike, and status in the client; do not depend on an
> ERC-1155 metadata URI.

### 5.4 MerkleDistributor

```solidity
constructor(address publisher_);        // 🔴 publisher is immutable (see ③ below)

function setRoot(uint256 seriesId, bytes32 root) external onlyPublisher;

/// Permissionless (2026-08-09 decision ④): anyone may submit a proof; warrants only go to the leaf's account
function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external;

/// Combined path (2026-08-09 decision ③): claim then immediately exercise with account as beneficiary.
/// Callable only by the account itself. MUST set the same claimed flag as claim() — see below.
function claimAndExercise(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external;

/// The authoritative leaf encoding, for the off-chain Indexer and the frontend — see ① below
function leafOf(uint256 seriesId, address account, uint256 amount) external pure returns (bytes32);

mapping(uint256 seriesId => bytes32 root)   public roots;
mapping(uint256 seriesId => bool)           public rootFrozen;   // frozen on first consumption, see ② below
mapping(uint256 seriesId => mapping(address => bool)) public claimed;   // 🔴 written by BOTH paths
```

ClearingPool mints the week's warrants to this contract; users claim with a proof.

- **`claim` is permissionless**: a keeper (or we) can pay gas and batch-deliver; users accrue with zero action. Compatible with the rollover mechanism — delivering cannot exercise, and rollover is driven by "unexercised," not "unclaimed" ([`research/expiry-window-verification.md`](./research/expiry-window-verification.md) §9.4).
- **`claimAndExercise` honors the public copy** ("exercise straight from your accrued balance"): this contract, as warrant holder, calls `pool.exercise(seriesId, amount, beneficiary = account)` — warrants burn from this contract, MEME pulls from the account (must have approved the ClearingPool), the attestation gate checks the account, and the stock goes straight to the account. The user path shrinks from three transactions (claim + approve + exercise) to two (approve + claimAndExercise). **`require(msg.sender == account)`**: exercise spends the account's MEME and must not be timeable by third parties.

  🔴 **`claimAndExercise` MUST set `claimed[seriesId][account]` exactly as `claim` does, and MUST reject an already-claimed leaf.** This is a *second consumption entry point* on the same merkle leaf, and omitting the flag is not "double-claiming your own entitlement" — it is **theft from the shared pool**:

  ```
  claimAndExercise(seriesId, account, amount, proof)     // replayed N times
    └─ pool.exercise(…, beneficiary = account)
          └─ warrant.burn(msg.sender = distributor, seriesId, amount)
                 ↑ this contract holds the warrants of EVERY unclaimed holder in the series
  ```

  Each replay burns `amount` from that shared balance. The caller pays their own MEME each time, but what they receive is **stock backing warrants belonging to holders who have not yet claimed** — who are then left with a valid proof and nothing to deliver against. The two entry points must share one flag; both must check it before doing anything else.
- **Unclaimed warrants** die at settlement (`settled ⟹ exercise reverts`); their collateral joins `remainder` and is rolled by `rollExpired`. **Nothing returns to the vault.**

> 📝 **Four things pinned down during implementation, 2026-08-13** (M1-8, issue #13). The first two are questions this sketch does not answer but which must be answered the moment it becomes code.
>
> **① Leaf encoding: `keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`.**
> Both details are load-bearing. **`seriesId` is inside the leaf** — the flag is already per-series, so it looks
> redundant, but it blocks a different route: if the publisher accidentally sets one root on two series, the same
> leaf can be consumed once in each, and the second consumption draws on a *different* set of unclaimed holders'
> shared balance. Pinning the series into the leaf makes that structurally impossible rather than a thing the
> publisher must not get wrong. **Hashing twice** is the OpenZeppelin `StandardMerkleTree` convention: internal
> node preimages are always 64 bytes, so a singly-hashed leaf whose preimage happens to be 64 bytes could double
> as an internal node's preimage (second preimage). Off-chain this is
> `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`.
>
> 🔴 **Added 2026-08-18 (issue #66): matching the encoding is not enough — the root must be reproducible
> by the official library, bit for bit.** Internal nodes use a commutative sorted-pair hash, so *any*
> home-grown tree can produce a (root, proof) pair that passes `MerkleProof.verify`. But OZ's
> `StandardMerkleTree` also imposes a specific leaf ordering and layout: a different ordering yields a
> **different root**, and both are internally consistent. The consequence is that §9's promise — "the
> algorithm and recomputation script must be open source, **anyone can independently verify the root**" —
> fails silently: **a round-trip test cannot catch this** (our proofs match our root, of course they pass);
> only a third party recomputing from our published input with the official library discovers the mismatch.
> ⇒ The root builder's acceptance criteria must include a **bit-for-bit comparison against the official
> library's output** (fixed vectors or a direct call). This is independent of the language chosen.
>
> **② A root may be replaced until that series' first leaf is consumed, then it freezes forever**
> (`rootFrozen[seriesId]`). Neither extreme is acceptable: permanent write-once means one typo misallocates a
> whole week **irrecoverably** (no admin, and the warrants are already minted); freely mutable means the publisher
> can re-point the remaining shares at anyone *after* distribution has begun. The freeze point is the moment the
> first person acts on the root — before that, a change harms nobody; after it, a change is a retroactive rewrite.
> The guarantee is **readable**: `rootFrozen[id] == true ⟹ that series' entitlement is final`.
>
> **③ `publisher` is a constructor argument and `immutable`, deliberately separate from the deployer.** The
> deployer's authority is spent after the two `setPool` calls, whereas the publisher signs a `setRoot` every week —
> it has to be a hot key. The deploy script defaults them to the same address; mainnet can split them with
> `DISTRIBUTOR_PUBLISHER`. The address goes into the manifest and is read back on-chain by `verify-deployment.sh` (§12).
>
> **④ A zero-`amount` leaf is rejected on both entry points.** This blocks no attack; it removes an **asymmetry
> between the two entry points**: zero is necessarily rejected on the `claimAndExercise` side by the pool
> (`memeAmount` rounds to 0 ⟹ `ExerciseRoundsToZeroMeme`), while `claim` would consume it happily. One leaf, two
> answers to "is this consumable" — exactly the class of divergence this section exists to eliminate.
>
> Two more things settled in code: both paths call the **same** private `_consume` (one implementation of
> "check → verify → set", so the two gates agreeing is compiler-enforced rather than a convention someone must
> maintain); and both entry points carry `nonReentrant`, at the cost that a contract wallet cannot claim a second
> leaf from inside the ERC-1155 receive callback (two transactions instead).

#### 5.4.1 Authoritative M4 Entitlement Calculation (2026-08-23, #91)

This section is the sole algorithm definition for
`canonical series ledger → entitlement calculation → §5.4 vesting input`. The versioned interface, bit-for-bit
input/output vectors, and rerunnable check live in [`offchain/entitlement/`](../offchain/entitlement/):

```bash
script/ci.sh entitlement
```

1. **D1 — one full-window TWAB per series.** All allocatable warrants before the series cutoff form one pool;
   revenue arrival and `processRevenue()` timing never segment holder weights. If two holders each hold half the
   window and have equal full-window weight, a 90/10 revenue arrival pattern still pays 50/50. The sole formula is
   `amount = floor(allocatable × accountWeight / totalAccountWeight)`.
2. **D2 — window.** `[ClearingPool.SeriesOpened, min(next ClearingPool.SeriesOpened for the same vault, expiry))`.
   An early successor cuts the old window at that event's cursor. Expiry has `endCursor = null` and records the
   first canonical block crossing `endTimestamp`. A missed opening creates a gap that is never backfilled; issuer
   gating does not extend accrual.
3. **D3 — allocatable inventory.** Every in-cutoff `Deposited.minted` / `Rolled.amount` must pair uniquely with a
   Pool-originated Warrant `TransferSingle` mint in the same transaction, with equal amounts. Their total must also
   equal cursor-exact replay of `Series.deposited == Series.minted`. A post-cutoff roll cannot change a sealed result,
   and excess Distributor balance cannot increase `allocatable`.
4. **D4 — eligibility and protocol inventory.** The fixed policy is
   `minimumAverageBalanceRaw = 10_000 × 10^18`; it never follows `totalSupply()`. Do not divide first: compare
   `candidateWeight >= minimumAverageBalanceRaw × durationSeconds`, with equality passing. An ineligible account has
   `accountWeight = 0`, no leaf, and no denominator weight. Curve, DEX pool, Portal, the token's own tax pot
   (`TAX_POT`), and TaxProcessor balances are excluded only with publicly reproducible role, effective-cursor, and
   on-chain evidence. A real fork shows that before swap-back the MEME sits on the token contract while the
   TaxProcessor's MEME balance is zero; those are distinct addresses. `0xdead` is an ordinary balance address; v1
   neither excludes an address merely for having code nor looks through LP tokens. This is unrelated to Flap's
   launch field `minimumShareBalance = 0`.
5. **D5 — weights.** Replay every canonical `Transfer` from MEME creation in
   `(blockNumber, transactionIndex, logIndex)` order. Integrate cursor-exact, piecewise-constant raw balances using
   integer seconds and BigInt. Same-timestamp events update state in cursor order but contribute zero duration;
   taxed transfer legs remain separate; the zero address alone means a real mint/burn. The sequence is fixed:
   `grossWeight → candidateWeight → accountWeight`. Any failure of `sumBalances == replayedSupply`,
   `sum(grossWeight) == integral(replayedSupply)`, or a full-block state anchor fails closed.
6. **D6 — denominator and normal no-root results.** The only denominator is `sum(accountWeight)`.
   `allocatable == 0` and positive inventory with a zero denominator produce `NO_ALLOCATABLE_INVENTORY` and
   `NO_ELIGIBLE_HOLDERS`. Keep a calculation record; do not invent an empty root, divert to treasury, or alter the
   threshold. Only untrusted canonicality, conservation, or chain-identity evidence is `BLOCKED`.
7. **D7 — rounding.** Floor each account independently with BigInt and record its `numerator` and
   `fractionRemainder`. A zero amount remains in the calculation but never enters vesting.
   `dust = allocatable - sum(non-zero amount)`, `dust < positiveWeightCount`, and dust stays in the Distributor.
   If every amount is zero, return `NO_NONZERO_ENTITLEMENTS`. Never use largest remainder, rounding-to-nearest, or a
   treasury fallback.
8. **D8 — finality and publication mode.** Each series has one final calculation. Before finality, only a plainly
   marked `PREVIEW` may exist; it cannot be sealed, published, or served as proof. A usable canonical `finalized` tag
   that has not reached the boundary yields `WAITING_FINALITY`; an unavailable/degraded tag or ancestry/hash conflict
   fails closed, never falling back to `latest - N`. Once finalized, an unsettled series observed before its actual
   `exerciseDeadline` is `TIME_WINDOW_OPEN`; otherwise it is `CLAIM_ONLY`. The latter may still be published and
   claimed but cannot use `claimAndExercise`.
9. **D9 — reorgs.** Block headers plus the raw-log canonical journal are the source of truth; checkpoints only
   accelerate it. Verify parent/tip hashes on new blocks and startup. A coherent alternate chain rolls back to the
   nearest common ancestor and replays atomically, producing the exact full-replay result. Temporarily unavailable
   evidence preserves prior state and reports `CANONICALITY_UNAVAILABLE`. Crossing the finalized frontier or changing
   deployment/chain identity reports `FINALITY_VIOLATION` / `CHAIN_IDENTITY_MISMATCH`, stops, and never replaces a
   root automatically.
10. **D10 — evidence and lookup.** On-chain `RootSet` is publication fact, a sealed bundle is public evidence, and
    the Proof API is a rebuildable read-only projection. Non-zero entitlement seals calculation / vesting / built /
    manifest / bundle; the three normal no-root outcomes seal calculation / manifest / bundle only. Files use exact-byte SHA-256;
    `bundleId` is SHA-256 of path-sorted `path + NUL + fileHash + LF` bytes and contains no wall-clock identity.
    Immutable lookup is `(chainId, distributor, seriesId, root, account)`; current lookup resolves only through the
    reorg-aware `RootSet` catalog. Root replacement moves the current pointer without deleting historical bundles.
    `FINALITY_VIOLATION`, `CHAIN_IDENTITY_MISMATCH`, and `PUBLICATION_HISTORY_MISMATCH` fail closed for current and
    by-root queries. Only `CATALOG_UNAVAILABLE` permits a known immutable by-root audit and static bundle download to
    continue. The API does not calculate, sign, or decide claimability.

### 5.5 AttestationRegistry (🔴 immutable, one per chain)

**Purpose.** Leave user-signed, on-chain evidence on the exercise path. Adapted from StonkBrokers ([`research/stonkbrokers-playbook.md`](./research/stonkbrokers-playbook.md) §11), with three deliberate departures — see below.

```solidity
contract AttestationRegistry {
    struct TextVersion { bytes32 termsHash; bytes32 attestationHash; }

    TextVersion[] public versions;                       // 🔴 append-only; no edit or delete
    mapping(address => uint256) public attestedVersion;  // 0 = never; stores version+1
    address public immutable publisher;                  // may only append

    event Attested(address indexed who, uint256 version,
                   bytes32 termsHash, bytes32 attestationHash, uint256 at);

    // 🔴 version 0 is written in the constructor — not in a follow-up tx; see below
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
        // 🔴 take the max, not require(v + 1 > attestedVersion[msg.sender]); see below
        if (v + 1 > attestedVersion[msg.sender]) attestedVersion[msg.sender] = v + 1;
        emit Attested(msg.sender, v, termsHash, attestationHash, block.timestamp);
    }
}
```

> 📝 **Two tightenings made during implementation, 2026-08-10** (M1-2, issue #7). Both exist so that
> invariant 6 carries **no preconditions** — the whole point of that invariant is "this gate is
> structurally incapable of locking anyone out," and any added condition weakens exactly that.
>
> **① `attest` takes the max rather than `require(… > …)`.** Strict increase would make
> "an address that already attested version 0 attests it again" revert, so 6③ could only be stated as
> "any address **that has not yet attested** can always `attest(0,…)`." The max satisfies 6①'s own
> wording (**monotonically non-decreasing**, not strictly increasing) and is strictly stronger:
> re-signing an older version neither fails nor rolls the state back. The cost is that `Attested`
> becomes a **log of signing events**, not a snapshot of account state — off-chain readers must take
> the `max`, or simply read `attestedVersion`.
>
> **② Version 0 is written in the constructor**, not by a post-deploy `addVersion` call. The latter
> has two real consequences: between the two transactions there is a window where `versions` is empty
> and `attest()` reverts for everyone, which demotes 6③'s premise from a **structural** guarantee to a
> **procedural** one; and the publisher would have to be the deployer, since `addVersion` is
> publisher-only — making the publisher a multisig would stretch that window to human response time.
> In the constructor, `versions.length ≥ 1` holds from the very first block.
> ⚠️ **This supersedes issue #8's acceptance item "the deploy script calls `addVersion(version 0)`
> immediately after deployment"** — version 0's two hashes are constructor arguments instead.
>
> The block above remains **illustrative**, not the literal implementation. The shipped contract also
> carries a few semantics-preserving additions: custom errors instead of require strings,
> `versionCount()`, a `VersionAdded` event, `addVersion` returning the new index, and two
> construction-time guards (publisher must be non-zero; text hashes must be non-zero).
> [`src/AttestationRegistry.sol`](../src/AttestationRegistry.sol) is authoritative.

**ClearingPool checks exactly one thing** (§5.1):

```solidity
require(attestations.attestedVersion(beneficiary) != 0, "not attested");
```

> 📝 **Corrected 2026-08-10**: this previously read `msg.sender`, contradicting the exercise check
> order in §5.1. 🔴 **It must query `beneficiary`** — otherwise the distributor's `claimAndExercise`
> path (§5.4) hollows the gate out entirely.

#### 🔴 Why it must record, not block

**Any admin-controlled precondition on exercise is a valve that can freeze every user's assets.** If a compliance admin key is lost or seized, every warrant is permanently bricked — and our public claim is that the clearing pool is immutable with no administrative withdrawal path. A controllable gate voids that claim outright.

Hence the design constraints:

| Constraint | Implementation |
|---|---|
| `attestedVersion` **only increases** | no function decreases or clears it — **not even the publisher** |
| Only the **account itself** can change its state | `attest()` writes `msg.sender` only |
| `versions[0]` **exists forever, immutably** | no edit or delete; anyone can call `attest(0, …)` at any time to satisfy the gate |
| Publisher power is **append-only** | adding a version **never invalidates** an existing attestation |

> **Consequence: this gate is structurally incapable of locking anyone out.** The chain requires "at least one attestation"; the frontend requires the latest version. Text updates are a frontend concern; the chain never invalidates retroactively. **The compliance goal and the immutability promise both survive.**

#### Why the hashes are passed as arguments

The hashes already live on-chain, yet callers must pass them and the contract checks equality. The point is to **put the text hash in the transaction calldata**:

- Wallets display raw calldata at signing time, so the user signs "I have seen this text," not an empty call
- **A frontend cannot silently attest a different version on the user's behalf** — the same hash discipline StonkBrokers uses

**The evidence is the transaction itself plus the `Attested` event — permanent and queryable, with no extra storage.**

#### Three departures from StonkBrokers

| | StonkBrokers | Ours | Reason |
|---|---|---|---|
| **Where the gate sits** | `elect()`, at stock selection | **`exercise()`** | our `claim()` produces a transferable warrant and never touches the stock |
| **Fallback for restricted users** | elect `USDG` etc. — a consolation prize | **sell the warrant** — a peer option, often the better one | the warrant is transferable, so it can be monetized without touching the underlying |
| **Text content** | includes legal conclusions ("this is marketing services compensation, not a dividend") | **facts only** | see below |

#### Text: state facts, do not assert legal conclusions

| Type | Example | Value |
|---|---|---|
| **Factual self-representation** | "I am not a US person / not in a restricted jurisdiction" | **High** — a fact only the user knows; misrepresentation is on them; demonstrates good-faith screening |
| **Legal conclusion** | "this is not a dividend / not a security" | **Low** — characterization follows substance, not wording; asserting it can read worse than silence |

Version 0 therefore carries two texts, **both purely factual**:

**TERMS (about the instrument)**
> I understand that what I receive is the **right to purchase** tokenized stock at an agreed price, not an entitlement to any distribution; that exercising this right requires me to **burn MEME tokens as consideration**; that this right may expire worthless; that the tokenized stock is itself a **debt claim issued by a regulated third party, tracking the price of the underlying stock while representing no ownership of the underlying stock and carrying no voting rights or any other shareholder rights**; and that the issuer of the tokenized stock reserves the ability to freeze transfers, pause the token, and burn holdings from any address, **including this clearing pool**.

> 📝 **Revised 2026-08-09**: added the debt-instrument statement — Robinhood Stock Tokens are legally tokenized debt securities (issuer's public disclosure); the earlier draft could lead a signer to believe they receive share ownership. ✅ Finalized 2026-08-26 (issue #18); English is the authoritative language.

**ATTESTATION (about the person)**
> I declare that I am not an individual or entity located in, incorporated in, or resident of the **United States of America** or any jurisdiction that restricts the receipt or exercise of instruments relating to tokenized stocks, and that I am not acting on behalf of any such individual or entity.

> ⚠️ **Version 0's two hashes are permanent once deployed. The texts were finalized on 2026-08-26 (issue #18); English is the authoritative language** (§14-8 ✅).
>
> 📌 The two paragraphs above are a **readable quotation, not the canonical bytes** — they carry Markdown
> emphasis. There is exactly one authoritative source: [`legal/attestation-v0/*.en.txt`](../legal/attestation-v0/);
> the hashes are computed from those files. The finalization record lives in that directory's README.

#### What this mechanism does **not** cover

| Exposure | Covered |
|---|---|
| Distributing tokenized equity to restricted persons | ✅ Partially — good-faith screening, burden shifted |
| **That we issue a derivative of a security (an option)** | ❌ **Not at all** |
| **That we operate an order book for that derivative** | ❌ **Not at all** |

And self-attestation is **unenforceable**: nothing on-chain stops someone from attesting and then exercising from a different address (the same is true of StonkBrokers). **What it buys is evidence and good faith, not enforcement.** Public copy must not imply more — see R12.

---

## 6. Sequences

### 6.1 Project Launch (D0, shipped in M2-6② / issue #57)

🔴 **The launch entry point is our own contract, `WarrantLauncher` — not Flap's `VaultPortal`.**
Both quote options on `VaultPortal.newTokenV6WithVault` are dead on this chain (native reaches the vault's
zero-address quote guard and reverts; GME is rejected with `UnsupportedQuoteToken(GME)` before the factory is
called), and that gate is hard-coded in unverified facade bytecode — we can neither change it nor wait for it
(issues #45 / #53). Ordinary `Portal.newTokenV6` was never subject to that gate, and D0 goes through it
(decisions 39 / 40; measurements in [`research/self-launch-spike.md`](./research/self-launch-spike.md)).

```
Creator fills the form in our Web App → a vanity salt ending the token address in 7777 is mined off-chain
  → one transaction: WarrantLauncher.launch({name, symbol, meta, salt, quoteToken, antiFarmerDuration})
        ① preflight: is the identity root wired? is the quote token an address **with code**?
        ② expectedVault = factory.nextVault()          ← the vault address is needed *before* minting; see below
        ③ token = Portal.newTokenV6(… beneficiary = expectedVault …)   ← **returns the real address synchronously**
        ④ vault = factory.newVault(token, quoteToken, msg.sender)
           require(vault == expectedVault)             ← byte-for-byte check; a mismatch reverts everything
        ⑤ registry.bind(token, vault)                  ← the only identity-root write, and it comes last
     returns (token, vault)
  → backend registers the project; Indexer begins subscribing to Transfer
```

🔴 **Why `beneficiary` must be computed first.** That launch field *is* `TaxProcessor.marketAddress()` — the
recipient of **every future tax payment** for this token (measured byte-for-byte in spike §3.4). Flap writes it at
mint time, and afterwards only Portal's `changeMarketWallet` (held by the 2-of-3 Safe) can change it — meaning
**mint time is our only chance** (decision 35 / R15). The ordering follows from that fact: ask the factory where its
next vault will land, put that address in `beneficiary`, then verify the factory really produced it.

> ⚠️ This is the **opposite** shape from the predicted address in decision 34: there we predicted *someone else's*
> token address and *they* did the checking; here we predict *our own* vault address and *we* do the checking, and
> the thing being checked is the return value of a `CREATE`.
>
> 🔴 Issue #57 says "no CREATE2 address prediction is needed". That holds for the **token** side but not for the
> **vault** side — the same ticket also requires `TaxProcessor.marketAddress() == vault`. **The maintainer accepted
> this trade-off on 2026-08-17**; see item ① of `design.md` §10-40.

**Launch parameters (constants in the launcher's bytecode — the caller cannot change them):** GME quote,
`dividendToken == quoteToken`, 300 bps buy/sell tax, `taxDuration` of 100 years (not Flap's 365-day example),
`mktBps = 10000`, zero deflation / dividend / LP bps, `minimumShareBalance = 0`
(`dividendBps == 0`; unrelated to the M4 threshold), `quoteAmt = 0`, `tokenVersion = TOKEN_TAXED_V3`,
`migratorType = V2_MIGRATOR`, `dexThresh = FOUR_FIFTHS`, `dexId = DEX0`, and `commissionReceiver` as an
`immutable` (our address). Readable on-chain via `launcher.launchEconomics()`.

**The caller decides only five things:** `name` / `symbol` / `meta`, `salt`, `quoteToken`, and
`antiFarmerDuration` (§14 item 2 is still open; it stays a parameter until it is settled).

🔴 **The vanity salt is mined off-chain.** Portal requires the token address to end in `7777`; mining a compliant
salt averages hundreds of thousands of keccaks, and putting that loop on-chain would turn a launch into an
unbudgetable gas gamble. Derivation: `predicted = CREATE2(Portal, salt, keccak(EIP-1167(TaxTokenV3Impl)))` —
reference implementation in `test/fork/FlapGmeLaunch.sol::_mineVanitySaltFrom`. A bad salt is not silent: Portal
rejects it.

**Criterion 2 is stronger under this construction.** The first argument to `bind` can only be the return value of
step ③ — the launcher has **no second path to `registry.bind`, and no entry point that accepts a caller-supplied
token address** (the `launch` parameter struct has no such field). Registering a vault for an *already existing*
MEME is therefore not merely harder; there is no function to call. Pinned twice: the write-surface enumeration in
`test/WarrantLauncher.t.sol` and the struct-member enumeration in `script/flap-vault-spec-check.sh`.

**Any failure reverts everything.** Step ⑤ comes last, so it is unreachable if any earlier step reverts; if ⑤ itself
reverts (say, this MEME is already bound), the whole transaction goes with it — **there is no state in which the
token exists but the binding was never written.** Preflight ① could be deferred to the vault constructor, which
enforces the same predicate; it runs first because **a token, once minted, cannot be un-minted.**

**`launch` is permissionless.** A stranger who uses it gets the vault for *their own* MEME and cannot alter a single
byte of any existing project (squatting is structurally unreachable, and each series' collateral is isolated inside
`ClearingPool`). Adding an allowlist would only conjure this system's first operational key.

**Acceptance:** the pinned-height end-to-end run is `test/fork/RobinhoodLauncher.t.sol` (CI required, including
`TaxProcessor.marketAddress() == vault`); the latest-block probe is `test/fork/RobinhoodSelfLaunch.t.sol`
(`script/monitor.sh canary`, deliberately outside the gate) — the split follows the discipline in issue #25. 🔴 **Since 2026-08-17 this repo does not use GitHub Actions**: these checks run on demand (`script/monitor.sh`) with no scheduler — "did anyone remember to run it" is the new silent-failure point; see the README's monitoring section.

### 6.2 Weekly Series Open (M2-4 shipped, issue #36)

```
Before Friday 21:00 UTC ── anyone (normally the Trigger Service) → vault.openSeries()
   ├─ expiry = the first Friday 21:00 UTC with "expiry − now ≥ 7 days"
   ├─ two clean return edges, no revert:
   │     ├─ this week is already open (expiry == seriesExpiry) → return (current series, false)
   │     └─ the open series still has more than 24 hours left  → same
   ├─ compute the 24h TWAP — 🔴 only status 0 proceeds; every other code reverts
   ├─ strike = TWAP × 8000 / 10000 (decision 14, k = 0.8, floored)
   │     └─ floors to 0, or does not fit uint128 → revert; no bad strike is ever stored
   ├─ pool.openSeries(meme, stock, expiry, strike)   ← 🔴 must succeed first; the pool admits only the
   │   identity-root-registered vault for this MEME, which is exactly this vault after Factory creation
   └─ then write strike / seriesExpiry, emit WeeklySeriesOpened(seriesId, expiry, strike, twapPrice)
```

**Friday alignment.** `expiry` is the **first** Friday 21:00 UTC satisfying `expiry − now ≥ 7 days`, so a series'
life always falls in `[7 days, 14 days)`. The implementation is pure arithmetic: the Unix epoch was a **Thursday**,
so Friday 21:00 UTC ⟺ `t % 7 days == 45 hours`; round `now + 7 days` up to that boundary. Leap seconds and daylight
saving cannot move it (Unix time does not count leap seconds; UTC has no DST) — each has its own test.

🔴 **The instant of the call is bounded by a 24-hour window** (not named in the ticket; added during
implementation). The next series can only be opened once the current one has less than 24 hours left, or has
already expired. `openSeries()` is **permissionless** and the caller picks no argument — but it does pick the
*instant*, and the strike is set once per week. Without this gate anyone could choose any hour of the week and fix
the whole week's strike. That is not price *manipulation* (§5.2's sampling bound covers that face) but price
*selection*, which a TWAP cannot prevent because every sample is genuine. With the gate the selectable range
collapses from a week to 24 hours, and adjacent 24-hour TWAP windows overlap heavily. The cost is liveness, but
that path is not closed: **the gate opens automatically once the series expires**, so anyone can reopen
immediately — the recovery series simply lands on the Friday after next under the ≥7-day rule. Full argument:
`OPEN_WINDOW` in `src/WarrantVault.sol`.

**Issuance-stall observability** (the on-chain handle for issue #42). `openSeriesStatus()` is a **view**: it
answers "is this week open, and if not, why?" without sending a transaction. It shares one private decision
function with `openSeries()`, so the two **cannot** disagree.

| `status` | Meaning | Where to look next |
|---|---|---|
| `0` | Calling now would open a series | 🔴 "should be open, could be open, is not" — check the Trigger Service |
| `1` | This week's series is already open | Healthy |
| `2` | The open series has more than 24 hours left | Healthy; it is not supposed to open yet |
| `3` | The 24-hour TWAP is unavailable | **Call `twap()`** for its six codes — this table deliberately does not forward them |
| `4` | TWAP too low; the discount floors the strike to 0 | Price source / curve state |
| `5` | The discounted strike does not fit `uint128` | Price source / pool reserves |

⚠️ A pool-side `SeriesAlreadyOpen` still bubbles up as the pool's own revert if **this vault** tries to open the
same triple twice. A stranger cannot preempt it: after M2-5 the pool admits only the identity-root-registered vault
for that MEME, so the former third-party squatting path is structurally unreachable.

### 6.3 Daily Mint (M2-3 shipped, issue #35)

```
Anyone (normally the Trigger Service, once a day) → vault.processRevenue()
   ├─ _recognize() first: delta-based recognition (spec rule 010-5, recognize before you act)
   ├─ read the **actual** balance (🔴 **uncapped** — unlike receive(), an unreadable balance fails honestly)
   │     └─ if the capped first read was merely too slow, recognize this known balance before depositing
   ├─ available = balance − creatorAccrued (saturating)        ← 🔴 decision 49: the creator float is not depositable
   ├─ two edges return cleanly instead of reverting:
   │     ├─ zero available           → return 0
   │     └─ no live series           → emit RevenueDeferred(available); the money waits in the vault
   ├─ cut = available × CREATOR_FEE_BPS / 10000                ← decision 49: floored, dust goes to the pool
   ├─ approve(pool, available − cut)                           ← exactly this deposit's amount
   ├─ pool.depositAndMint(seriesId, merkleDistributor, available − cut)
   │     └─ mints the pool's **measured balance delta** (invariant 2; the vault never
   │        asserts minted == the deposit — a taxed stock token makes them differ by design)
   ├─ approve(pool, 0)                                        ← allowance is 0 between transactions
   ├─ re-read the actual vault balance, uncapped
   ├─ accountedQuote = balanceAfter                            ← 🔴 rule 010-3, same transaction
   ├─ sent = max(balanceBefore - balanceAfter, 0)              ← actual net vault deduction
   ├─ confirmedCut = min(cut, sent × 1000 / 9000)              ← 🔴 fee accrues by measured debit,
   │   creatorAccrued += confirmedCut                             capped at cut: neither a fake
   │                                                             transfer (sent=0) nor a partial
   │                                                             debit can skim one batch twice (M-01)
   └─ emit RevenueDeposited(seriesId, sent, minted) (+ CreatorFeeAccrued(confirmedCut, total))

Anyone (normally the creator) → vault.claimCreatorFee()
   ├─ _recognize() first (rule 010-5); a zero accrual is a silent no-op returning 0
   ├─ requested = min(creatorAccrued, actual balance); creatorAccrued is decremented by it up front
   ├─ stock token → creator (a constructor-pinned immutable; 🔴 an issuer-blocked creator reverts the
   │   whole call honestly — it hurts only the creator, never processRevenue, and there is no re-address hatch)
   ├─ debited = max(balanceBefore − balanceAfter, 0)           ← 🔴 same yardstick as processRevenue: measured debit
   ├─ claimed = min(debited, original creatorAccrued); the claim is corrected to claimed
   │   (a fake transfer restores the claim untouched, no event; a partial debit consumes only what moved)
   │   (a sender fee may make debited > claimed; it is not creator income, while accountedQuote records the full debit)
   ├─ accountedQuote = balanceAfter                            ← second spending path, same rule 010-3
   └─ if claimed != 0: emit CreatorFeeClaimed(claimed)

Indexer computes one full-window TWAB after the series cutoff; the final series root is published after finality
```

> ✅ **2026-08-24 (#91–#96): M4's canonical replay, deterministic calculation, public recomputation, sealed
> bundle catalog, and read-only Proof API/HTTP adapter are implemented and tested.** Publishing remains an explicit
> publisher-signed step. The manual tools remain available: `node offchain/merkle/build-root.js` (list → root + a proof for every leaf),
> `script/publish-root.sh` (the publisher signs `setRoot`), and `script/claim-warrant.sh` (assemble the
> `claim` / `claimAndExercise` calldata for one holder). Usage and the full weekly walkthrough are in
> [`offchain/merkle/README.md`](../offchain/merkle/README.md).
> Issue #96's `node offchain/entitlement/prepare-handoff.js` now combines replay/recompute/sealing at a finalized
> height with chain identity, series reconciliation, Distributor balance, publisher, current-root, and
> `rootFrozen` checks into a `READY_FOR_HUMAN` handoff. It removes the private-key environment variable before
> invoking the publisher dry-run; the actual broadcast remains a separate human action. Recovery, A-to-B
> replacement, synchronization, and independent recomputation are specified in
> [`publisher-handoff-runbook.zh.md`](./publisher-handoff-runbook.zh.md).
> 🔴 **The moment before publishing is the only moment a mistake can still be corrected** — the root freezes
> forever once that series' first leaf is consumed (§5.4 ②). So `publish-root.sh` refuses to broadcast until it
> has recomputed everything from the input list, confirmed which chain it is talking to, confirmed the signing
> key really is the on-chain `publisher`, and read `rootFrozen` — and it puts "is this a first publication or an
> overwrite" in front of whoever is signing.

`seriesId = pool.seriesIdOf(taxToken, quoteToken, seriesExpiry)` — the formula has exactly one home (the pool's).

🔴 **Permissionless.** "Speed funds out of an upgradeable contract" should not have a gatekeeper, and the
caller **cannot change where the money goes**: `pool` and `merkleDistributor` are `immutable` on the
implementation. The in-transit window is quantified in
[`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md).

### 6.4 Exercise

```
Frontend shows claimable + held warrants
   ├─ if attestedVersion == 0 or behind the latest version
   │     → display both texts in full → registry.attest(v, termsHash, attestationHash)
   │        (one-time; chain requires ≥1, frontend requires latest)
   ├─ approve MEME to ClearingPool (one-time / per amount)
   ├─ straight from accrued balance (claim-free, decision ③):
   │     distributor.claimAndExercise(seriesId, account=user, amount, proof)   ← account only
   │        └─ internally: pool.exercise(seriesId, amount, beneficiary=user)
   ├─ already-held warrants: pool.exercise(seriesId, amount, beneficiary=msg.sender)
   └─ inside exercise:
         ├─ check caller ∈ {beneficiary, distributor}
         ├─ check not settled and before _exerciseDeadline (gating extends it, §5.1)
         ├─ check attestedVersion(beneficiary) != 0     ← see §5.5
         ├─ burn warrants (from the holder)
         ├─ burn the beneficiary's MEME (transfer to 0xdead)
         └─ send stock to beneficiary   ← fails under issuer gating → whole tx reverts
```

> **The sell path has no such gate.** Listing and filling go through Seaport and never touch the stock, so restricted users can still run the full "hold → accrue → claim → sell" loop.

### 6.5 Expiry Settlement

```
After the exercise window ends (deadline = max(expiry, gating-cleared + 48h);
no deadline while gating is observed) — lazy, permissionless:

   pool.settleExpired(seriesId)
      ├─ first refreshes the gating observation (same logic as pokeGating, self-healing)
      ├─ gating hit → revert (exercise window remains open; a still-blocked stock transfer makes `exercise` revert atomically — the auto-extension, §5.1)
      └─ clean → settled = true; remainder = deposited − exercised

   pool.rollExpired(seriesId, nextSeriesId)
      └─ remainder credited to the successor series, warrants minted to the distributor
         — custody never leaves the pool; the vault is not involved (decision ①)

(Monitor / anyone may call pool.pokeGating(stock) at any time to record observations)
```

### 6.6 OTC Trade

```
Seller: sign a Seaport order in the frontend
        (offer: Warrant ERC-1155; consideration: GME + optional taker fee)
        → POST to OrderbookService (off-chain, zero gas)
Buyer:  fetch order → Seaport.fulfillAdvancedOrder()
        → atomic swap, fee split automatically
```

#### 6.6.1 Frozen M5 v1 policy (2026-08-25, M5-D1 through D10)

> 🔴 **Amended (2026-09-04, decision 52):** the payment token changes from "fixed GME" to **the series' stock token `Series.stockToken`**. The first stock is picked by market heat and the launcher already takes `quoteToken` as a parameter, so pinning GME would leave every non-GME project with no fillable official orders. On acceptance the service reads `pool.series(seriesId).stockToken` and checks it against the canonical stock-token list in verified config; the list is part of `deploymentConfigHash`; depth, fee, and lots are denominated per series and are not comparable across series; gating revalidation widens from "GME state" to "the series' stock-token state". M5 is not implemented yet, so this amendment changes no code. The `GME` wording below has been replaced accordingly; the first project is still GME. The public product name is **Warrant Market**.

This section is authoritative for the OrderbookService v1 interface and state model. M5 adds **no settlement
contract**: standard Seaport open orders, the existing ERC-1155 Warrant, and stock-token allowances cover settlement.
Users may bypass the service and create other valid Seaport orders; these constraints define the **official order
flow**, not a chain-wide transfer rule.

**Deployment and payment.** Production is Robinhood Chain `chainId = 4663`, with Seaport fixed at
`0x0000000000000068F116a894984e2DB1123eB395` and the payment token fixed to **the series' stock token** `Series.stockToken` (GME
`0x1b0E319c6A659F002271B69dB8A7df2F911c153E` for the first project; decision 52). Native ETH, WETH, other ERC-20s, and mixed payment are rejected.
Maker proceeds go directly to the maker and fees directly to the epoch's fixed recipient. Both
`order.conduitKey` and `fulfillerConduitKey` are zero: makers call `Warrant.setApprovalForAll(Seaport, true)` and
takers call `stockToken.approve(Seaport, requiredAllowance)` directly. v1 does not depend on ConduitController or Permit2
and does not generate unlimited approvals by default. A stock-token pause or block may disable the official fill path; this
is an explicitly accepted external-dependency risk.

Addresses are supplied by the environment, but each production release independently pins the allowed chainId,
Seaport runtime codehash / EIP-712 domain, the canonical stock-token list, and system wiring. The expected codehash cannot be
overridden by that environment and config cannot hot-reload. Canonical config produces `deploymentConfigHash`;
orders, SQLite state, and cursors from different hashes occupy separate namespaces. Startup or periodic canary
failure makes transaction interfaces fail closed.

**Only accepted order shape.** The official service accepts asks only: seller = maker and buyer = taker.

```text
offerer       = maker
zone          = address(0)
orderType     = PARTIAL_OPEN
startTime     = 0
zoneHash      = bytes32(0)
salt          = cryptographically random, non-zero uint256 from the client
conduitKey    = bytes32(0)
counter       = maker's current Seaport counter when signing

offer.length  = 1
offer[0]      = ERC1155(canonical Warrant, seriesId, warrantAmount)
                with startAmount == endAmount > 0

consideration[0] = ERC20(series.stockToken, makerProceeds, recipient = maker)
                    with startAmount == endAmount > 0
consideration[1] = present only in a fee-bearing epoch:
                    ERC20(series.stockToken, feeAmount, recipient = feeRecipient)
```

ERC-20 `identifierOrCriteria` is zero and `totalOriginalConsiderationItems` equals the actual count. v1 rejects
criteria items, multi-series bundles, dynamic amounts, additional recipients, tips, scheduled orders, bulk-order
signatures, empty signatures, and orders relying on prior on-chain Seaport `validate()`. EOAs may use direct 64/65
byte EIP-712 signatures accepted by the pinned Seaport; contract wallets may use EIP-1271. The typed-data domain's
chainId, verifying contract, name, and version must exactly match the canary-verified Seaport domain.

The client builder accepts only `{maker, seriesId, warrantAmount, makerProceeds, expiresAt}`. Verified config supplies
chainId, Seaport, Warrant, the series' stock token, fee epoch, fee recipient, and conduit, and callers cannot override them. After signing
native Seaport typed data, the client submits `schemaVersion = 1`, `deploymentConfigHash`, `OrderParameters`, the
counter used for signing, and the signature to `POST /v1/orders`. The service never holds keys, signs, or requests an
additional platform authorization, and it exposes no `/orders/prepare` session. It canonicalizes independently,
recomputes the order hash, and performs every on-chain check.

**Lifetime and fee epoch.** The canonical acceptance block timestamp must satisfy:

```text
acceptedBlock.timestamp < endTime <= acceptedBlock.timestamp + 7 days
if exerciseDeadline(seriesId) is finite: endTime <= exerciseDeadline(seriesId)
```

The UI suggests 24 hours by default. Neither server wall time nor maker `startTime` determines fees.
`marketOpenedAt` is fixed before launch and `feeActivatesAt = marketOpenedAt + 56 days`: 0% before it, 50 bps after.

```text
feeAmount = floor(makerProceeds * 50 / 10000)
```

A fee-epoch order whose computed fee is zero is rejected. Zero-fee orders accepted before the switch are
grandfathered until their own expiry. The recipient is fixed per epoch and replacement affects only new orders; in
production it should be an operations Safe. Submitting a stale pre-switch shape after the boundary returns
`FEE_EPOCH_MISMATCH` and requires a new salt and signature. This fee covers only the official flow and is not a
global transfer tax.

**Exact lots and partial fill.** All official fills call `fulfillAdvancedOrder()`:

```text
zero fee: lotCount = gcd(warrantAmount, makerProceeds)
with fee: lotCount = gcd(warrantAmount, makerProceeds, feeAmount)
```

`lotCount <= uint120.max`. Official fill calldata uses integer lots with `denominator = lotCount`; a buyer asks for
"up to N lots." A one-lot order can only fill in full. The taker pays the stock token and receives the Warrant, with no recipient
override. The service reserves nothing off-chain. Seaport may shrink a concurrent request to the remaining fraction;
a fully filled or cancelled order reverts. The receipt's `OrderFulfilled`, not the prepare response, is authoritative
for the actual amount. The default stock-token approval is exact for the requested maximum N lots.

**Delisting, cancellation, and series windows.** These are three distinct actions:

- `Delist`: the maker signs EIP-712 `Delist(chainId,seaport,orderHash)`; after EOA / EIP-1271 verification the service
  records a permanent tombstone. It costs no gas and affects only official interfaces. The hash cannot return, relist
  requires a new salt, and any Seaport signature already distributed remains valid.
- `Cancel`: the maker sends an on-chain Seaport cancellation for the specific order; the service only prepares calldata.
- `Cancel all`: the maker calls `incrementCounter()`, invalidating external-market orders too; the UI must warn strongly.

Acceptance and revalidation require an open series, `settled == false`, and
`now < exerciseDeadline(seriesId)`; a finite deadline also requires `order.endTime <= deadline`. Active gating makes
the deadline `uint64.max`; after clearing it converges to `max(expiry, clearedAt + 48h)`. `SERIES_WINDOW_CLOSED` may
recover as gating changes, while `SERIES_SETTLED` is terminal. The former "listing/cancellation is gasless" wording is
invalid: listing and soft delisting are gasless; true cancellation is an on-chain transaction.

**Acceptance, projection, and stable status codes.** `POST /v1/orders` performs every RPC read and simulation at one
pinned latest canonical block hash and atomically accepts a passing order; there is no async pending queue. RPC or
chain-identity inconsistency fails closed, while ordinary reorgs roll back and recompute. Same hash and content returns
`IDEMPOTENT_REPLAY`; same hash with different content returns `ORDER_HASH_CONFLICT`. At most one recoverable,
non-terminal official order may occupy `(deploymentConfigHash, maker, seriesId)`. Recoverable states are:

```text
SUSPENDED_MAKER_BALANCE
SUSPENDED_MAKER_APPROVAL
SUSPENDED_MAKER_SIGNATURE
SUSPENDED_PAYMENT_TOKEN
SUSPENDED_PAYMENT_RECIPIENT
SERIES_WINDOW_CLOSED
```

Terminal states are:

```text
DELISTED_OFFCHAIN
CANCELLED_ONCHAIN
COUNTER_INVALIDATED
ORDER_EXPIRED
FILLED
SERIES_SETTLED
```

An acceptance-block reorg crossing the fee boundary produces `FEE_EPOCH_INVALIDATED`. A submitted signing counter
different from the maker's counter at the pinned block returns `COUNTER_MISMATCH`. Domain responses use a versioned
envelope containing stable `code`, `retryable`, `orderHash`, `observedAtBlock`, and structured `details`. Clients never
parse HTTP prose, RPC strings, or Solidity revert text.

**Attestation policy.** OrderbookService does not read, cache, expose, or gate maker/taker `attestedVersion`, and has
no hidden `REQUIRE_ATTESTATION` switch. Unattested users may trade and hold Warrant. ClearingPool alone enforces the
attestation on the `exercise()` beneficiary; M6 explains and guides attest before exercise. `FILL_READY` does not mean
exercisable. A future legal requirement must version this decision again.

**Persistence and query interface.** v1 uses SQLite WAL with `synchronous = FULL` and one active writer per
`deploymentConfigHash`. It uses ordinary SQL migrations plus `user_version`, not an ORM. uint256 values are decimal
strings or 32-byte big-endian and all arithmetic uses BigInt, never floating point. Facts include `orders`,
`delist_tombstones`, `chain_occurrences`, and `service_cursor`; `order_projection`, `slot_claims`, the active index, and
depth are rebuildable projections. The minimal REST `/v1` interface is:

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

Queries use ETag / conditional polling, not GraphQL, SSE, WebSocket, or cross-order matching. Opaque cursors bind to
`projectionRevision`; a revision change returns `CURSOR_STALE`. Depth includes ACTIVE asks only and sorts by the exact
reduced rational `(makerProceeds + feeAmount) / warrantAmount`; fills name exactly one orderHash. Success is returned
only after the SQLite transaction durably commits. Backups use SQLite online backup / consistent snapshots, never a
lone `.db` copy that ignores WAL. A missing production DB returns `STATE_MISSING`, corruption returns `STATE_CORRUPT`,
and both fail closed rather than creating an empty market.

**Chain synchronization and process model.** One process hosts HTTP, sequential canonical-block polling, expiry, and
periodic revalidation, serializing mutations through one SQLite writer. A file lock rejects a second writer; v1 has no
active-active, leader election, message queue, or WebSocket authority. From `service_cursor + 1`, the synchronizer
processes blocks and `(transactionIndex, logIndex)` order, committing block header, occurrence, projection, and cursor
in one transaction. It tracks Seaport fill/cancel/counter events, Warrant Transfer/ApprovalForAll, and pool events that
change series windows. Startup and periodic full non-terminal revalidation cover EIP-1271, stock-token state, and other
changes without reliable events.

Expiry is driven only by processed canonical block timestamps: `endTime <= block.timestamp` projects
`ORDER_EXPIRED` and removes the order from active depth. Wall time and a separate cron are not authoritative. If the
cursor hash leaves the canonical chain, the service finds a common ancestor, marks fork occurrences orphaned, and
replays. If it cannot prove an ancestor it replays from the configured start and keeps transaction interfaces closed.
Startup is config/DB/canary → reconcile cursor → catch up → full revalidation → rebuild depth → ready; shutdown removes
readiness before finishing the current transaction. `/v1/health` separates live/ready and exposes observed block,
canonical head, lag, and last successful RPC. During lag or recovery, reads may return a prior projection with
`stale: true`, but transaction and calldata-prepare interfaces do not proceed.

---

### 6.7 `BuybackVault` (⏳ planned, decision 50, `v1.2` candidate)

**What it is.** The on-chain answer to R7's cold start: one non-upgradeable, admin-less satellite per project. Anyone
funds it with MEME; it buys in-the-money warrants by rule and exercises them against the pool in the same transaction.
It is not a market maker, not a guaranteed exit, never swaps, never holds warrants across a transaction. **Depth = deposits.**

**Constructor (all `immutable`).** `vault` (the project's `WarrantVault`: TWAP / spot, `taxToken`, `quoteToken`), `pool`,
`warrant`, `attestations`, `discountBps` (start 1000), `feeBps` (start 0), `feeRecipient`. The constructor calls
`attestations.attest(0, termsHash, attestationHash)` from its own address: the pool checks the beneficiary, and the
beneficiary is the vault itself (premise: `design.md` decision 50-② / R17).

**LP accounting: shares in MEME, stock as a dividend.** This is the one choice that lets LPs enter and exit without any price.

- Deposit: `shares = amount × totalShares / memeBalance`, 1:1 when empty. Shares are priced on MEME NAV only.
- Stock: every exercise credits a `stockPerShare` accumulator; each LP carries a `stockDebt` baseline (MasterChef pattern).
- Withdraw MEME: pro rata, any time.
- Withdraw stock: `shares × stockPerShare − stockDebt`, **requires `attestations.attestedVersion(msg.sender) != 0`**.
  Unattested LPs can always take their MEME; their stock stays in the vault. The LP UI says so up front.

**Sell path (one transaction).** The seller has done `Warrant.setApprovalForAll(buybackVault, true)`.

1. Check `pool.series(seriesId)`: `memeToken` / `stockToken` match this vault; `settled == false`;
   `block.timestamp < exerciseDeadline(seriesId)`.
2. Price: `vault.twap()` must be `TWAP_OK`; read spot; `p = min(twap, spot)` (MEME raw per 1e18 raw stock, same unit as `strike`).
3. Intrinsic `iv = p − strike`; reject if `iv <= 0`.
4. `quote = amount × iv / 1e18 × (10000 − discountBps) / 10000`; reject if `quote < minMemeOut`.
5. `need = quote + amount × strike / 1e18`; if short, partial-fill the largest affordable `amount`; reject if `filled < minFill`.
   The pool's rounding rule (`amount × strike >= 1e18`) is pre-checked here.
6. `warrant.safeTransferFrom(seller, this, seriesId, filled)`.
7. `meme.approve(pool, filled × strike / 1e18)`; `pool.exercise(seriesId, filled, address(this))`: the pool burns the
   warrants from the vault, burns MEME pulled from the vault, sends stock to the vault. Any revert reverts the whole call.
8. `meme.transfer(seller, quote − fee)`; `fee` to `feeRecipient`.
9. `stockPerShare += filled × 1e18 / totalShares`.

**Sell on behalf.** `sellFor(seller, seriesId, amount, minMemeOut, minFill)`: `msg.sender == seller` or
`warrant.isApprovedForAll(seller, msg.sender)`; MEME always goes to `seller`. Standing orders (§6.8) and gas-paying
keepers use this one entry.

**Invariants.**

| # | Statement |
|---|---|
| B1 | After any transaction `warrant.balanceOf(this, id) == 0` for every `id` |
| B2 | Per call, `quote + burned MEME ≤ pre-call MEME balance` |
| B3 | `Σ unclaimed stock == stock.balanceOf(this)` |
| B4 | Stock leaves only to addresses with `attestedVersion != 0` |
| B5 | No admin, no pause, no withdrawal path; no `selfdestruct`, no proxy |

**Failure modes.**

| Case | Behaviour | Wording |
|---|---|---|
| Issuer gating (freeze / pause) | `exercise` reverts → `sell` reverts; the pool extends the exercise window, the vault follows | "the bid is there whenever exercise works", never "always" |
| TWAP not OK | reject | no bid during a sampling gap |
| Late MEME pump makes TWAP look ITM | `min(twap, spot)` blocks a single-window pump; manipulation sustained beyond 24h is borne by LPs | LP risk, same surface as strike manipulation (comparison doc §2.8) |
| Issuer freezes the vault address | stock stuck; MEME still withdrawable | R2 family |
| Issuer `adminBurn`s vault stock | B3 recomputed on actual balance; LPs share the loss pro rata | R2b |
| MEME taxes wallet↔contract transfers | **the whole design fails**; mainnet-fork check is a deployment precondition (§14-14) | — |

**Starting parameters.** `discountBps = 1000`; price `min(twap, spot)`; `feeBps = 0` (slot kept, aligned with the 56-day
zero-fee OTC epoch); no daily buy cap. Final values tracked in §14-14.

**Economics.** A series opens 20% ITM; at a 10% discount the vault bids ≈ `0.18p` for a fresh warrant and pays the `0.8p`
strike, `0.98p` for one share, 2% under TWAP; deeper ITM, larger absolute discount. LPs are structurally **long stock /
short MEME**, the same direction as the warrant hedge. Natural LPs: MEME holders who want stock at a discount, the project, us.

**Deployment and discovery.** The launcher is non-upgradeable, so the vault cannot ride the launch transaction; it is a
separate, permissionless deployment after launch. The official address is pinned in the frontend `app-config` and
published in the Interface Bundle; no on-chain registry.

**Relation to M5.** The vault is an off-book floor; official sell orders should price above it. This exit bypasses the
taker fee (§6.6.1); the revenue-model impact is recorded in `design.md` decision 50-⑧. **R13:** the vault raises exercise
participation `f` and shrinks the `S/f` pool residue directly.

### 6.8 `StandingOrder` satellite (⏳ planned, decision 51, details pending)

**The pool does not change.** The caller gate on `exercise()` (beneficiary or distributor) and the `NotAccount` gate on
`claimAndExercise()` stay exactly as they are; they exist to deny third-party timing, and standing orders are not a
reason to relax them.

**How.** The satellite exercises with itself as beneficiary and forwards the stock to the user. One-time user setup:
self-attest, `Warrant.setApprovalForAll(standingOrder, true)`, `MEME.approve(standingOrder, …)`, one rule. Claiming
still goes through permissionless `claim()` (keeper pays gas).

**Rule constraints (🔴 hard).** Deterministic, anyone may trigger, fixed execution window (start: within 6 hours of
expiry and `vault.twap()` ITM); the trigger only pays gas and receives nothing; the satellite checks
`attestedVersion(user) != 0` before exercising for that user.

**Three instructions.** ① exercise if ITM (pull warrants + MEME → `pool.exercise(id, amt, this)` → stock to user);
② sell to the buyback vault (§6.7 `sellFor`, MEME to the user); ③ let it ride: the default, no satellite needed.

**Costs and open points.** `Exercised.beneficiary` is the satellite, so per-user attribution moves to satellite events
(whether M4 ingests them is open); MEME is a standing approval, so the satellite must be non-upgradeable and admin-less;
a Seaport listing conflicts with the satellite pulling the warrants (the fill fails), which the UI must flag. Premise as
§6.7 (decision 50-② / R17).

## 7. Invariants and Testing

**All seven are shipped as Foundry invariant or invariant-style tests with M1.**

| # | Invariant | Assertion |
|---|---|---|
| 1 | Collateral sufficiency (**restated 2026-08-09**) | (a) `∀ **unsettled** series: minted − exercised ≤ pool holdings attributable to that series`; (b) globally: `Σ_unsettled (minted − exercised) + Σ remainder ≤ stock.balanceOf(pool)` |
| 2 | Mint conservation | after every `depositAndMint`, Δ`minted` == Δ(pool stock balance) |
| 3 | Exercise atomicity | any sub-step reverting ⟹ warrant and MEME balances unchanged; success ⟹ warrant / MEME / stock legs all move by their specified amounts, with beneficiary MEME debit == `memeAmount` and pool stock debit == `amount` |
| 4 | **No exercise after settlement; settlement unstoppable absent gating** (rewritten 2026-08-09; was "no exercise after expiry") | (a) `settled ⟹ exercise() reverts`; (b) clean live read and `now ≥ max(expiry, clearedAt + 48h)` ⟹ `settleExpired()` must succeed (🔴 both must come from the **same** observation: a stale record self-heals on the spot and restarts the grace — see tightening ⑤ in §5.1); (c) **`clearedAt` is monotone-by-edge** — calling `pokeGating` on a stock already observed clean must leave `clearedAt` unchanged, for any number of calls by any caller. **(b) alone is vacuous without (c)**: an adversary who can move `clearedAt` forward simply falsifies (b)'s premise and blocks settlement forever |
| 5 | No admin exit | no ClearingPool function can move collateral **out of the contract** while `minted > exercised`; `rollExpired` is internal reassignment, not an exit |
| 6 | **Attestation gate cannot lock out** | (a) `attestedVersion[a]` is **monotonically non-decreasing** for all `a`; (b) only `a` itself can change `attestedVersion[a]`; (c) `versions[0]` exists and is immutable ⟹ **any address can always satisfy the gate via `attest(0, …)`** |
| 7 | **Rollover conservation** (added 2026-08-09) | pool stock balance is unchanged across `rollExpired`; the decrease in `remainder` == the successor's `deposited` / `minted` increase == warrants newly minted |

> Invariant 6 is the **only** thing proving the new compliance gate cannot become an asset-freeze switch. It ranks with invariant 5 and **must not be skipped.**

**Required fork tests** (Robinhood mainnet fork):
- Full deposit → mint → exercise path against the real GME contract
- **Simulate issuer `pause()`: exercise must revert cleanly and the user must retain the warrant**
- **Burn path**: on the real `FlapTaxTokenV3`, `transferFrom(user, 0xdead, X)` must deliver **exactly X**.
  🔴 Nothing in the contracts guards this — the pool deliberately does not check the balance delta at
  `0xdead` (§5.1 tightening ④), so any regression would be **silent**
- **Two-layer external-dependency guard**: the pinned suite preserves reproducible evidence; a separate latest-state canary checks the current GME beacon, the Flap new-launch selection chain (Portal implementation → immutable launcher → immutable supported token implementation), all three runtime codehashes, and `transfer` / `transferFrom → 0xdead` on a freshly launched GME-quoted V3 token. Both run Forge with `FORK_REQUIRED=true`, so unavailable RPC or required historical state must fail rather than produce a green `vm.skip`; only the pinned suite is part of the gate (`script/ci.sh fork`)
- **Full gating-extension path**: pause → `pokeGating` → the exercise window remains open past expiry (a still-blocked transfer makes `exercise` revert atomically, preserving warrant / MEME) → exercise succeeds the moment the issuer unpauses (**no poke required**) → observing the clearing collapses the window to `max(expiry, clearedAt + 48h)`, and exercise still succeeds before that deadline → `settleExpired` succeeds after it; also test that unpoked gating yields no extension, and that `settleExpired` self-heals stale observations
- 🔴 **Settlement-griefing**: an adversary calls `pokeGating` repeatedly on a clean stock (including right before the deadline, and in a loop across many blocks) — `clearedAt` must not move and `settleExpired` must still succeed on schedule (invariant 4c)
- 🔴 **Fail-open grace**: make the gating views revert → settlement must not proceed for 48h → then must proceed; a second revert observed during that window must not re-stamp `clearedAt`
- **Full `rollExpired` path**: settle → roll → invariants 1 / 7 hold for both series; roll reverts cleanly with no successor and resumes once a new series opens; **invariant 1(a) must hold for the settled predecessor precisely because it is excluded** — assert the global form 1(b) across the roll
- **`claimAndExercise` path**: two transactions total; a non-`account` caller is rejected; **an unattested `account` is rejected on the distributor path too** (the gate checks the beneficiary)
- 🔴 **`claimAndExercise` replay**: the same proof submitted twice must revert on the second call, and a `claim` after a `claimAndExercise` (and vice versa) must also revert — **assert the distributor's warrant balance never drops below the sum of unclaimed leaves**
- Simulate a `uiMultiplier` change: accounting must remain consistent
- Full Flap dispatch → `receive()` ping → `processRevenue()` path. **M2-3 delivered the second half**
  (`test/fork/RobinhoodWarrantVault.t.sol`): `processRevenue → depositAndMint → mint` runs against real GME,
  and M1's invariants 1 / 2 are re-checked **under a real vault** (they had only ever been verified against
  `VaultStub`), reusing the same `CollateralCheck` from `test/invariant/`. Two further tests assert that a
  deposit fails cleanly while the issuer has **globally paused** or **blocked the pool address** — balance,
  baseline and allowance all untouched — and succeeds on retry once released.
  The historical M2-5 fork path preserves the real VaultPortal -> Factory callback / binding evidence that led to
  rejecting that route. It is **not** the production launch path: native reaches the real-vault constructor and
  reverts, while GME is rejected by VaultPortal before a Factory is invoked. Production D0 instead has
  `WarrantLauncher` call ordinary Portal, build the vault through the Factory, and write the binding atomically.
- **After the publisher appends a new text version, holders attested to an older version must still exercise normally** (appending must never invalidate retroactively)

---

## 8. Permission Matrix

| Function | Caller | Note |
|---|---|---|
| `pool.openSeries` | **only the vault registered for that MEME in the identity root** (`vaultRegistry.vaultOf(memeToken)`, non-zero; M2-5 / issue #37, see §4.2) | once only; strike immutable thereafter; the roster is written by the identity root's **two-slot writer list** (today slot 1, `WarrantLauncher`, is the only active writer; slot 2 is the unarmed `PendingLauncherSlot`; M2-6① / issue #56). The Factory only builds vaults and is not on that list. |
| `pool.depositAndMint` | that series' vault | — |
| `pool.exercise` | **the beneficiary, or the distributor** (`claimAndExercise` path) | MEME pulls from the beneficiary; the attestation gate checks the beneficiary; caller restriction prevents forced third-party timing |
| `pool.pokeGating` | **anyone** | Monitor as backstop; recorded observations drive the gating extension |
| `pool.settleExpired` | **anyone** | lazy; structurally blocked while gated (= the auto-extension) |
| `pool.rollExpired` | **anyone** | pool-internal rollover; checks are self-verifiable |
| `distributor.claim` | **anyone** (proof submission) | warrants only go to the leaf's `account`; keepers may pay gas |
| `distributor.claimAndExercise` | **the `account` itself only** | spends the account's MEME; not timeable by third parties |
| `vault.sampleTwap` | **Anyone** (M2-2 shipped) | Trigger Service is only the normal scheduler. No role or Guardian key is introduced; its explicit liveness-versus-timing trade-off is the bounded, strict 24-hour discrete TWAP. |
| `vault.processRevenue` | **Anyone** (M2-3 shipped, see §6.3) | 🔴 Permissionless on purpose: a gatekeeper would be this vault's first permissioned function, and a zero permissioned surface is the shortest proof the vault cannot take the money (design §10-33 / §10-36). The caller cannot change where the money goes — `pool` / `merkleDistributor` / `creator` are `immutable` on the vault (as of decision 49 the fee destination is pinned at construction too). |
| `vault.claimCreatorFee` | **Anyone** (decision 49) | Permissionless for the same reason as the other five entries: the payee is the constructor-pinned `creator` and no calldata byte can change it — front-running the trigger cannot harm the creator (it is still their money), while a `msg.sender == creator` gate would buy no security and break "none is permissioned". A zero accrual is a silent no-op. |
| `vault.openSeries` | **Anyone** (M2-4 shipped) | No arguments: the strike comes from the ring buffer and the expiry from the calendar, so the caller picks nothing. It does pick the *instant*, which §6.2's 24-hour window bounds. If it were ever moved onto the Trigger Service's `trigger(uint256)` callback (rule 008 requires it to check the caller), that would become this vault's first permissioned function — the zero permissioned surface would end there, and `design.md` §10 must record it. |
| `distributor.setRoot` | `MerkleDistributor.publisher` (our publisher key; **may differ** from the registry's) | 🔴 the single centralized trust point. Once that series' first leaf is consumed the root freezes forever — not even it can change one |
| `registry.attest` | **anyone, but only for themselves** | monotonically **non-decreasing** (take-max, not strictly increasing — see §5.5); **no one can revoke another's attestation, not even the publisher** |
| `registry.addVersion` | our publisher key | **append-only**; never affects an existing attestation and **cannot be used to block exercise** |
| `vaultRegistry.bind` | **only the two-slot writer list fixed at construction** (`isFactory`; M2-6① / issue #56) | the list has no setter and no admin; both slots share one `memeToken → vault` table, so each MEME is still bindable exactly once, ever |
| `pendingLauncherSlot.bind` | **only the armed launcher** (nobody at all while unarmed) | pure forwarding; fail-closed to every caller until armed — the same shape as an unbound satellite |
| `pendingLauncherSlot.setRegistry` / `setLauncher` | the deployer | each **once only, then permanently locked** (same shape as decision 29's `setPool` / `setRegistry` / `setBeacon`). 🔴 `setLauncher` is the moment a new binding path enters the trust base: the new launcher's source and address must be published, and the `LauncherSet` event is watched by the monitor (`LAUNCHER_ARMED`, §9) |

---

## 9. Off-Chain Services

> 📝 **2026-08-17 (issue #68): "Trigger Service" changed subject in the table below.**
> This section originally meant **Flap's** Trigger Service (`0xD3421B…`) — a centralized backend
> we do not control, which this table treated as existing infrastructure. Since decision 39
> (issue #58) the vault no longer inherits any Flap base class and is not a Flap canonical
> vault, so that backend **will never knock on our door**.
>
> These three cadences therefore stopped being "something someone else does while we watch" and
> became **our own operational duty**. The implementation is
> [`script/trigger-keeper.sh`](../script/trigger-keeper.sh), hosted on a VPS with systemd timers
> (issue #69, maintainer decision ①). The "Requirement" columns of the **Series Opener** and
> **TWAP Sampler** rows below are **unchanged, word for word** — the criteria were always
> on-chain reads and hold no matter who triggers.
>
> 🔴 Only one statement needs correcting: the TWAP Sampler row's "every hour" is the **wrong
> shape**. The margin between `SAMPLE_INTERVAL` (1 hour) and `MAX_SAMPLE_GAP` (65 minutes) is
> only 5 minutes, so a strict hourly cron means one failure inevitably breaches the cap. The
> right shape is **poll every 90 seconds and let the contract itself gate the write** —
> the conservative bound is `3600 + 2 * (90 + AccuracySec 5) + 85 = 3875 < 3900` seconds;
> derivation is in the header of `script/trigger-keeper.sh` and README's "why 90 seconds".

| Service | Responsibility | Requirement |
|---|---|---|
| **Indexer / entitlement pipeline** | Replay the verified canonical journal, reconstruct MEME balances and protocol roles, calculate the one-time full-window TWAB entitlement, and project published proofs | ✅ **Implemented and tested in #91–#96** under `offchain/entitlement/`: canonical replay, strict calculation v1, deterministic recomputation, sealed immutable bundles, a reorg-aware publication catalog, a read-only Proof API/HTTP adapter, and a publisher handoff that checks finality, chain identity, and a live publication snapshot. `offchain/merkle/` remains the public root/proof implementation. A third party can still compare `cast call <distributor> 'roots(uint256)(bytes32)' <seriesId>` with `node offchain/merkle/verify-root.js --input <list> --root <root>`, or audit a sealed by-root bundle. `offchain/entitlement/proof-runtime.js` exposes the frozen `/v1` read routes and is deployed for resettable Core staging acceptance. A persistent production Indexer and HTTP server are not deployed, and `setRoot` is never auto-broadcast |
| **OrderbookService** | Admit canonical Seaport asks, aggregate exact per-series depth, track fills/cancels/reorgs, prepare fill/cancel/approval calldata | M5-0 policy is §6.6.1; orders are signatures only, **no custody**, and M5 adds no settlement contract |
| **Series Opener** | Our Trigger Service polls `openSeriesStatus()` every 15 minutes and calls `openSeries()` when it returns `0` | 🔴 **The criterion is on-chain**: returning `1` means this week is open — not "our service believes it opened it". `0` is the loudest case (should be open, could be open, is not); `3` means read `twap()` next to locate the sampling failure. The function is **permissionless** and its routine no-ops do not revert, so retries and 15-minute polling are safe (§6.2, issue #42). |
| **TWAP Sampler** | Our Trigger Service polls `sampleTwap()` every 90 seconds; the contract writes only after one hour has elapsed | Maintain the 65-minute maximum gap, not just the one-hour minimum write interval. Alert on `TwapSampleFailed(reason)`, `lastSampleAt()` and gap status; recovery needs a fresh strict 24-hour window (normally 25 consecutive observation points). The function is **permissionless**, so anyone can stand in when the backend dies — and equally, anyone can choose the sampling instants, so the Monitor should watch the timestamp distribution of `TwapSampled` (§5.2). |
| **Monitor** | ① Watch the issuer registry for `isBlocked` / `paused` / `adminBurn`; ② **backstop-trigger** `pool.pokeGating` for the stock token of every open series (the contract only trusts observations on record — §5.1 / §8); ③ check daily that every project still has a series **opened on schedule** (issuance stall, issue #42) | 🔴 ① any hit triggers immediate public disclosure (§11); ② an operational hard duty, but permissionless — any holder can poke; ③ see §9.1 |
| **Monitor (tax routing)** | Watch `MarketWalletChanged` on the Flap Portal. **Record every token; alert only on ours** — someone else's token being redirected is a leading indicator that this permission is in active use, worth recording but not our alert | Implemented as `script/watch-market-wallet.sh`, entry point `script/monitor.sh tax`. 🔴 **Since 2026-08-17 this repo does not use GitHub Actions**, so it runs on demand with no scheduler — see the residual risk in the README's monitoring section. 🔴 **Both probes must be read and reconciled**: the log side (the Portal's event) gives history, the state side (`token.taxProcessor().marketAddress()`) gives the present moment. Logs alone miss any path that changes state without emitting; state alone cannot see other people's tokens. Their disagreement is itself a first-order alert. The ledger `monitoring/market-wallet-<chainId>.jsonl` is committed as a known positive — otherwise "found nothing" and "the monitor is broken" are indistinguishable. Complete classification also needs an independently, manually reviewed `monitoring/vault-bound-<chainId>.jsonl` baseline for `VaultBound`, reconciled bidirectionally with chain. Until the identity root and that baseline are committed, the workflow uses `--record-only`: a new event exits `2` (inconclusive), never `0` as someone else's token |
| **Monitor (reserved writer slot)** | Reconcile the second writer slot's `launcher()` state with its one-shot `LauncherSet` history (M2-6① / issue #56, decision 39-D) | `script/series-monitor.sh` fixes both slot reads and the event query to one observed head block `H`. With `pendingLauncherSlotFromBlock` it scans `[fromBlock, H]`: zero state requires zero events; a non-zero state requires exactly one event with the same launcher. It also verifies `factories()[1]` and that the slot's `registry()` points back to the verified pool `vaultRegistry()`. Missing history, unreadable RPC, or either mismatch is an alert, not a healthy result. A non-zero match remains `LAUNCHER_ARMED:<slot>` until the roster's exact four-field `pendingLauncherSlotAcknowledgement` re-verifies it; only then does the producer emit `resolves:true` for `deliver-findings.sh` to close the prior issue. See `monitoring/README.md` and `docs/series-monitor-runbook.zh.md`; do **not** manually close an unacknowledged one-shot-event issue. |

### 9.1 Issuance-Stall Monitoring (issue #42)

Until now, "this week's series never opened" could **only** be discovered by someone noticing there
were no warrants — reasoning backwards from the consequence, and only after a user speaks up. A vault
operator going offline, the Trigger Service not firing, insufficient TWAP samples, a miswired identity
root, an upstream price-source/pool-state change, our own deployment order being wrong: not one of those six surfaces
on its own.

② and ③ are **two duties of the same off-chain service** — both are about things that failed to
happen on schedule — so they are documented together.

Implementation: [`script/series-monitor.sh`](../script/series-monitor.sh) (the verdict) +
[`.github/workflows/scripts/deliver-findings.sh`](../.github/workflows/scripts/deliver-findings.sh)
(delivery) + [`monitoring/series-roster.json`](../monitoring/series-roster.json) (the project roster).
Runbook: [`series-monitor-runbook.zh.md`](./series-monitor-runbook.zh.md).

| Constraint | Detail |
|---|---|
| 🔴 The verdict comes from the on-chain `Series` record | `pool.seriesIdOf(meme, stock, expiry)` → `pool.series(id)`, and it counts only if `vault` / `memeToken` / `stockToken` all match, `strike != 0`, and `settled == false`. **Not** "our service thinks it called `openSeries`". `SeriesOpened` logs are used only to discover candidate expiries, never to conclude |
| 🔴 **Friday 21:00 UTC is never assumed** | The pool treats `expiry` as an opaque `uint64` and neither validates nor interprets it (§4.1). So the check reads the on-chain `Series.expiry`, and the roster supplies only a **duration** (`periodSeconds`). Were the roster to predict an exact second, the vault's ≥7-day lifetime rule rolling an expiry to the following Friday would change `seriesId = keccak(meme, stock, expiry)` entirely — marking every healthy week as a stall |
| Two predicates | **Cadence**: has it been longer than `periodSeconds + graceSeconds` since the last successful open (answers "did this period's series open?"). **Coverage**: is there still an unsettled, unexpired series right now (answers "is money stranded in the vault?"). The latter sets severity |
| 🔴 A far-future expiry must not suppress the verdict | An expiry beyond the roster's `maxSeriesSeconds` (how long a series may *live* — a different quantity from how often one is *opened*) is **excluded from coverage** and is itself an alert. ⚠️ The gate only bites on series **our own vault** opened: `openSeries` writes `s.vault = msg.sender`, so a third party's far-dated series never enters the coverage calculation at all. What it catches is us miscomputing an expiry |
| 🔴 Severity is not keyed on money | "No new series opened this period" is an **alert in its own right** — that is this section's whole question. `inTransit()` only ever *escalates*. The single downgrade is "cadence is not yet due, coverage merely ran out, and in-transit is a confirmed exact zero", which is most likely a wound-down project |
| 🔴 "Recovered" needs positive evidence | The cadence predicate is **unknown** when logs are unreadable, or when the provider withholds `blockTimestamp` (measured: always `0x0` on Robinhood Chain, and the `cast block` fallback may also fail). In that state the check reports neither healthy nor recovered — otherwise one flaky `eth_getLogs` would comment "recovered" on a project that has been stalled for three months |
| Alerts must say where to look next | A simulation that succeeds only says it can run **now**; it proves neither that someone did nor did not call it historically. A reverted simulation carries the **raw revert data** and a local known-selector decode, but without a call trace its source is **undetermined** and must not be attributed to the pool. `RevenueDeferred` proves that someone called permissionless `processRevenue()` and that call deferred; it does not identify the caller. The verifiable identity-root lead remains `vaultOf` disagreeing with the vault. The current vault signature is `openSeries()(uint256,bool)`; a `null` `triggerSignature` is valid only for an undeployed/inactive placeholder and leaves simulation **undetermined** |
| The TWAP cause is **readable on chain** | Since M2-2 (#34), `vault.twap()` hands failure back as a return value instead of reverting, so "ring buffer under-sampled, strike cannot be computed" needs no digging through keeper logs — the check translates the status into plain language in the alert (`keeper stopped` / `keeper missed a heartbeat` / `ring not full` …) and states outright that **an uncomputable strike means opening a series is guaranteed to be rejected** |
| 🔴 "Identity root not wired" ≠ "identity-root fault" | The current `ClearingPool` constructor pins four dependencies, including `vaultRegistry`, and `openSeries` authenticates `msg.sender` against `vaultRegistry.vaultOf(memeToken)` (#36 / #37 shipped). The monitor reads the real `pool.vaultRegistry()` ABI; a missing, unreadable, or roster-mismatched value raises run-level `MISWIRED` (§12: a miswiring also presents as "series can never be opened") |
| Alerts must carry `inTransit()` | R4's residual exposure is denominated in that number (`design.md` R4). `(0, false)` means **unreadable**, not "no money" — handled as its own high-priority finding |
| Heartbeat | 🔴 An alerter that never alerts is indistinguishable from no alerter. The heartbeat receipt is a **permanently open issue** rewritten every run through **exactly the same `gh` path** the alerts use: if `gh` breaks, the run goes red instead of quietly green. Each run first reads the previous `lastRunAt` and alerts separately past `maxSilenceSeconds`. ⚠️ This cannot catch "never triggered again" — a dead cron job will not rewrite the receipt; set `HEARTBEAT_URL` for an independent external dead-man's switch, and make a configured POST failure fail the run; the external service must still actually detect a missing check-in |
| Fail-closed | chain-id mismatch, pool without code, head timestamp skew, head block regression, roster missing a field / count mismatch / duplicate entry — all **abort the whole round** with an alert, never a green. A green must prove it **actually read the chain** (`readsSucceeded` goes into the receipt) |
| Out of scope | Auto-remediation (auto-reopening a series). **Make it visible first, automate later.** The check only ever `cast call`s; it never broadcasts |

📝 **2026-08-14**: section added. The old §9 Monitor row listed only issuer events, while the
`pokeGating` backstop duty was scattered across §5.1 / §6.5 / §8 / §11; both are consolidated here —
they are the same service watching for things that failed to happen, over one alert channel.
Issue **#35** (revenue path) reuses the same deliverer: write another producer emitting different
`kind`s into the same `findings.json`, and the delivery side needs no change.

---

## 10. Frontend Modules

[`frontend-integration-v1.md`](./frontend-integration-v1.md) is the authoritative frontend contract for
`v1.0.0 Core`. Core covers M0 through M4 only: the frontend directly consumes a hash-verified `app-config.json`,
deployment manifest, Interface Bundle, JSON-RPC/wallet, and the read-only M4 Proof API. It adds no BFF, Core REST API,
or project Indexer API. Dedicated staging is a resettable, fixture-seeded Robinhood mainnet fork exposed as
`chainId == 31337`; it does not reuse the #69/M4 production evidence chain.

OTC must be disabled in `v1.0.0`, and production must show no mock order. The M5 OrderbookService and Seaport UI join
in `v1.1.0 Market`. A `v1.0.0-rc` environment may open early for frontend integration, but production `v1.0.0` still
waits for #69, #87, #102, legal text, production parameters, and deployment gates.

| Module | Content |
|---|---|
| **Launch** | Parameter form → **mine a vanity salt off-chain** → `WarrantLauncher.launch(...)`; fixed economics are not in the form (they are constants in the launcher's bytecode, §6.1), while the still-unsettled `antiFarmerDuration` remains a form parameter (§14 item 2) |
| **Project page** | Cumulative stock acquired, warrants issued, two live series, expiry countdown |
| **My Warrants** | Claimable / held, intrinsic value, one-click exercise; **attestation step inserted before first exercise** |
| **Attestation** | Both TERMS and ATTESTATION shown **in full** (not collapsed, not pre-checked), then written to the registry. **Appears only on the exercise path** |
| **Market** | **Disabled in `v1.0.0 Core`**; list / fill / depth arrive in `v1.1.0 Market` and, under the frozen M5 policy, have **no attestation gate** |
| **Expiry calendar** | Weekly Friday events (community content cadence) |

**Hard requirements for the attestation screen:** the text must be **fully readable** (no collapsing, no link-only); the hash must match on-chain `versions[v]` and **be displayed for the user to verify**; the frontend requires the latest version but must state that **the chain only requires ≥1**, so a user may exercise on an older attestation.

The critical touchpoint is the issuance notification; the three actions must be presented together:

```
Your weekly tax just minted you 142 GME Warrants
Expiry: 7 days · Strike: 1,850 $MEME per GME

[ Exercise Now ]  [ View Warrant ]  [ Sell on Market ]
```

The warrant detail page must state what it is not: *"This is not the stock. It is the right to buy the stock token — itself the issuer's price tracker, not a share."*

**All displayed quantities multiply by `uiMultiplier()`**; internals stay raw.

---

## 11. Failure Modes and Degradation

| Scenario | Symptom | Handling |
|---|---|---|
| Issuer **blocks** the pool address | transfer step of `exercise` reverts | whole tx reverts, warrant and MEME retained; **auto-extension = gating-aware settlement** (§5.1): Monitor / anyone `pokeGating`s → settlement blocked while gated and the exercise window remains open (while the issuer can still reject delivery) → exercise works again the moment the issuer clears (no poke needed), and observing the clearing sets the deadline to `max(expiry, clearedAt + 48h)`; frontend states the cause; public disclosure |
| Issuer **pauses** the token | same | same |
| Gating occurs but **nobody pokes** | no extension takes effect; the series can be settled on schedule | the contract only trusts recorded observations — poking is a hard Monitor duty, triggered on any event hit; any holder can also poke |
| Issuer upgrade **changes the gating view interface** | reads inside `pokeGating` revert | **fail-open** (treated as not gated, avoiding a permanent settlement/rollover deadlock) plus a `clearedAt` stamp whose deadline is `max(expiry, clearedAt + 48h)` (§5.1). 🔴 **User-facing consequence, stated plainly**: if the token is genuinely paused while the views are unreadable, exercise fails and settlement proceeds after that deadline — **holders lose warrants they had no way to exercise.** The grace exists to give humans up to 48h to react; there is no on-chain remedy beyond it |
| 🔴 Issuer **blocks an individual holder** (not the pool) | that holder's `exercise` reverts at step 3; `pokeGating` sees a clean pool, so **no extension** | **Deliberate** — one blocked address must not extend the series for everyone. But the loss is real and unrecoverable: at settlement those warrants die and their collateral rolls to *other* holders. Frontend must detect `isBlocked(user)` and say so explicitly rather than showing a bare revert; the only mitigation available to the holder is **selling the warrant** (Seaport transfers of the ERC-1155 are unaffected by a stock-token block) — the frontend must surface that path |
| 🔴 Issuer **`adminBurn`s** pool holdings | collateral reduced; invariant 1 broken by external force | **no technical defense**; Monitor triggers disclosure; risk disclosed in advance |
| ~~A series triple is squatted~~ ✅ **structurally eliminated** (M2-5 / issue #37) | a stranger calling `pool.openSeries` receives `NotRegisteredVault(memeToken, caller, vault)`; only the identity-root-registered vault can open that MEME's series (§4.2) | The active writer, `WarrantLauncher`, can bind only the token returned by its own ordinary `Portal.newTokenV6` call in the same transaction, so an existing MEME has **no** retrofit-registration path. Remaining failure modes are our vault missing its opening window (an operational stall), or a MEME launched outside our launcher (`vault == address(0)`). The frontend and Indexer must still read `expiry` from chain and **never assume Friday 21:00** |
| TWAP sample gap / stale or too-short window | `twap()` returns non-zero ⟹ `openSeries()` **fails closed**: the week stalls rather than mispricing | Alert and resume permissionless sampling; do not treat old discrete spots as continuous history. The stall itself surfaces as `openSeriesStatus() == 3` (§6.2, issue #42). |
| V2 pool updates in the sampling block | `sampleTwap()` emits `TwapSampleFailed(POOL_UPDATED_THIS_BLOCK)` and writes nothing | Retry in a later block. This only removes the direct same-block reserve-snapshot path; it is **not** a cumulative oracle or a general V2 manipulation defense. |
| `uiMultiplier` change | displayed values jump; raw accounting unchanged | frontend warns around `effectiveAt`; protective window on mint and exercise |
| Trigger Service down | no mint that day | funds remain in the vault and roll forward; anyone can trigger manually |
| Merkle root not published | users temporarily cannot claim | warrants already minted to distributor; retroactively claimable once published |
| Seaport order stale or projection behind | prepare fails closed, or a broadcast reverts after concurrent state changes | revalidate at a pinned canonical block, return stable codes plus `observedAtBlock`, and trust only receipt `OrderFulfilled` for actual fill (§6.6.1) |
| **User has not attested** | `exercise` reverts at step 0 | frontend pre-checks `attestedVersion` and prompts (one-time); **the sell path is unaffected** |
| **Our frontend goes offline** | users cannot attest from the UI | both texts and their hashes must remain permanently retrievable from `research/` and contract events so **users can call `attest()` directly** — this is the backstop behind "the gate cannot lock out" |

---

## 12. Deployment Order

**Circular dependencies are resolved by one-time binding, not by CREATE2** (decided 2026-08-09, closing §14-7;
extended to a second ring of the same shape on 2026-08-13, when the vault identity root landed).

Neither ring can be broken **by ordering alone**: a CREATE2 address is derived from the init code, which *includes the
constructor arguments*, so when A's arguments depend on B and B's on A, neither address can be precomputed.

- **Satellite ring** (decision 29): `Warrant → pool`, `MerkleDistributor → pool`, `pool → {warrant, distributor, attestations, vaultRegistry}`
- **Identity-root wiring** (decisions 34 / 38 / 39-D): `registry → writer list (2 slots)`, `pool → registry`, `both writers → registry`; this is a one-shot configuration relationship, not a pair of mutually dependent constructors

```
 1. WarrantVaultFactory(flapPortal) ── the price-source Flap Portal is a constructor arg (decision 39-A2),
                              outside the ring
 2. WarrantLauncher(flapPortal, factory, commissionReceiver)
                           ── 🔴 the D0 orchestration layer (decision 40 / issue #57). It is the identity root's
                              **first** writer slot; the factory must exist first (it is an immutable ctor arg).
                              The same `flapPortal` is the **mint entry** here and the **price source** in step 1
 3. PendingLauncherSlot()  ── no constructor args; placeholder for the identity root's second writer slot (39-D)
 4. VaultRegistry(launcher, slot) ── both slots are real immutables with no setter; exactly one external writer (bind)
 5. AttestationRegistry    ── no dependencies; version 0's two hashes are CONSTRUCTOR ARGS (see the §5.5 note)
 6. Warrant (ERC-1155)     ── no constructor args
 7. MerkleDistributor      ── constructor(publisher) — the address that publishes entitlement roots, immutable (§5.4 ③)
 8. ClearingPool           ── immutable; one shot
                              constructor(warrant, distributor, attestations, vaultRegistry)
                              — all four are REAL immutables
 9. Warrant.setPool(pool)           ── one-time, deployer-only, then permanently locked
    MerkleDistributor.setPool(pool) ── same
    launcher.setRegistry(vaultRegistry) ── same; closes the identity-root ring
    slot.setRegistry(vaultRegistry)     ── same; the second slot's end of it
10. factory.setVaultTargets(pool, distributor) ── same; one of the factory's two one-shot slots:
    ── **where the money and the warrants go for every vault it builds from now on**.
       Both targets are code-checked; hollow addresses fail closed
11. factory.setLauncher(launcher)  ── same; the last wire. The factory accepts only this caller from now on,
    ── and is **inert** before it (`LauncherNotSet()`)
12. Launch a test MEME on Flap via `launcher.launch(...)` and run the full path
    ── 🔴 This step is chain-qualified (decision 42-③ / #64): on testnet 46630 it cannot work
       by design — that chain has never enabled a single ERC20 quote token, so `launcher.launch`
       hits `QuoteTokenNotAllowed` at the Portal. In rehearsals this step runs on the mainnet
       fork (chainId 31337, #69 / #79); the full 1–13 sequence completes on mainnet 4663 or on
       the mainnet fork. 46630 carries only the deployment-and-wiring-verification part of
       steps 1–11 and 13 (see the §13 M3 row and the `DeploySystem.flapPortalFor` table notes)
13. Verify: all six one-shot writes are locked; identity ring closed (writer list compared slot by slot);
    **the factory is NOT on that list**; the launch ring is closed (launcher → factory, factory → launcher);
    the reserved slot still unarmed; pool has no admin exit; fork tests green
```

🔴 **1–4 must precede 8**: the pool's authenticator is an `immutable`.
🔴 **Step 3 cannot be deferred**: the registry's writer list is fixed at construction and the pool's `vaultRegistry`
is immutable, so once the pool ships no slot can ever be added. Swapping the writer would then mean a new registry and
a new pool, stranding every warrant and all collateral in the old one (decision 39-C). **The reserved slot is not
optional — it is the one thing only the pre-deployment moment can buy.**
🔴 **The first writer slot holds the launcher, not the factory** (issue #57): the binding follows the fact "this token
was just created", and in D0 that fact lives next to the return value of `Portal.newTokenV6`. The factory only deploys
vaults; it **never touches the identity root**, and both the deploy script's closing assertions and
`verify-deployment.sh` carry a negative check for exactly that.
🔴 The vault is **non-upgradeable**: this system has no vault implementation, beacon, or address with the power to
replace a vault's logic. The factory **deploys a fresh vault on every launch**. ⚠️ A factory with either required slot
unwired is **inert** — `newVault` reverts the whole launch (`LauncherNotSet()` / `VaultTargetsNotSet()`) rather than
producing a broken vault, because a binding pointing at a broken vault is **irrevocable**.

**Why the one-time slot sits on Warrant / MerkleDistributor and not on ClearingPool.** The pool is where the trust concentrates, so its four addresses stay genuine `immutable`s with no post-deployment write path at all. The two satellites each carry a single `initialized` slot:

```solidity
address public pool;
function setPool(address p) external {
    require(msg.sender == deployer && pool == address(0), "bound");
    pool = p;
}
```

- **Front-running**: gated on `deployer`, so only we can bind; and it is verifiable on-chain immediately afterwards
- **Trade-off**: `pool` becomes a storage read instead of an immutable — a few hundred gas per call, against removing CREATE2 from the deployment entirely
- **Alternative considered**: the Uniswap V3 pattern (empty pool constructor, arguments read back from `IDeployer(msg.sender).parameters()`) keeps everything immutable but requires an extra deployer contract and still depends on CREATE2. Rejected as the more moving parts for the same result

> **Step 13 must verify all six one-shot deployment writes are locked before anything else touches the system.** An unbound satellite, writer slot, Factory target slot, or Factory launcher slot is the one window in which the design's guarantees do not yet hold.

**Deployment checklist:** `launcher.launchEconomics()` read back on chain matches §6.1 (`taxDuration` at maximum, `mktBps == 10000`) — read it from the chain, not the source · ClearingPool confirmed to have no admin function · **all six one-shot deployment writes locked** (`Warrant.setPool`, `MerkleDistributor.setPool`, `launcher.setRegistry`, `slot.setRegistry`, `factory.setVaultTargets`, `factory.setLauncher`) · **`launcher.commissionReceiver()` is the address you actually intend to collect integrator commission with** (immutable) · **`MerkleDistributor.publisher` is the key you actually intend to sign `setRoot` with every week** (immutable, and the single centralized trust point in the system) · **that key signs through `script/publish-root.sh` every week** (it recomputes the root, checks the chain and the signer, and reads `rootFrozen` before broadcasting — see the §6.3 addendum) · **version 0 canonical texts legally reviewed, with byte-for-byte hashes matching the deployment arguments and frontend** (the hashes are permanent after deployment).

**Vault binding:** `pool` and `merkleDistributor` are constructor-set `immutable`s **on the vault**, not launch
parameters. 🔴 As of issue #58 they come from the factory's one-shot `setVaultTargets(pool, distributor)` slot
(deployer-only, write-once, permanently locked), and the price-source `Portal` from the factory's constructor.
The deploy script and `verify-deployment.sh` each check that `factory.pool()` / `factory.merkleDistributor()` /
`factory.portal()` point at this deployment's contracts; the manifest's `flapPortal` field exists for that check
(it replaced `warrantVaultBeacon` / `warrantVaultGuardian` / `warrantVaultImplementation` — with nobody able to
upgrade a vault, those three have no object). `flapPortal` is the price source in every vault and the ordinary mint
entry in the launcher; there is no separate per-chain `vaultPortal()` gate on `newVault`.

🔴 **The identity ring has its own checklist** (the pool's authenticator is physically immutable after deployment):

- `ClearingPool.vaultRegistry()` points at the registry from step 4, `VaultRegistry.factories()` equals the two
  addresses from steps 2 and 3 **slot by slot**, and both writers' `registry()` point back at the same registry.
  Missing any of the four hops presents identically to **"no series can ever be opened"**, and neither the pool nor
  the registry can be changed. 🔴 **Read the enumeration, do not merely ask `isFactory(launcher)`**: that is equally
  true of a registry whose *both* slots hold the launcher — which silently costs you the reserved slot, with no way
  back. `test/DeploySystem.t.sol` asserts the ring end to end; `script/verify-deployment.sh` reads it back from chain
  and prints the current `PendingLauncherSlot.launcher()` state.
- **The reserved slot (decision 39-D)**: `PendingLauncherSlot` ships **unarmed** — `launcher == 0`, and in that state
  it is fail-closed to every caller of `bind`. Arming it is a single deployer-only, write-once, permanently-locked
  `setLauncher` that emits `LauncherSet`. 🔴 **The operational requirements are part of the design, not an extra**
  (see the "honest cost" paragraph in `design.md` §10-39, 39-D): the deployer key needs an explicit custody plan; the
  new launcher's **source and address must be published** when it is armed; and the operator must follow
  `docs/series-monitor-runbook.zh.md` to record the slot deployment block, reconcile the state/event/path evidence,
  and add an exact roster acknowledgement. `LAUNCHER_ARMED` closes only after that machine-rechecked acknowledgement;
  manually closing an issue is not approval and will not suppress the next round.
- 🔴 **The factory no longer carries a VaultPortal gate** (issue #57): `newVault` accepts only `factory.launcher()`.
  What must be checked instead is the **launch ring**: `launcher.factory() == factory`,
  `factory.launcher() == launcher`, and `launcher.portal() == factory.portal() == 0x26605f…` (Flap's `Portal` — one
  address in two roles: the launcher mints through it, the factory writes it into every vault as the price source).
  🔴 **Not** BSC's `0x9049…` (zero code on this chain), and **not** the deprecated VaultPortal `0xe9F7…`. The
  verification script reads each of these on chain.
- A freshly deployed identity root must be **empty**, and no stranger — including the deployer — can write to it.
- 🔴 **Vault upgradeability: there is none** (decision 39-A3 / issue #58). The vault is non-upgradeable, has no
  Guardian, no beacon and no implementation, so Flap's "every permissioned vault function must also be granted to
  the Guardian" obligation **loses its object entirely**; the vault's own permissioned surface is still zero
  (proven by ABI enumeration). `launcher.setRegistry`, `factory.setVaultTargets`, and `factory.setLauncher` are
  one-shot deployment wiring, not vault business methods. 📝 The manifest's former `warrantVaultBeacon` /
  `warrantVaultGuardian` / `warrantVaultImplementation` fields are deleted and replaced by `flapPortal`, and
  `verify-deployment.sh` checks the factory's three vault-facing addresses instead of a beacon owner
  (decisions 34 / 38 / 39).

> ✅ **The vault-identity route is decided (2026-08-13): all six fork criteria passed, so route A — the immutable
> identity root — is adopted.** The adjudication procedure is `design.md` §10-32; the verdict and its evidence are
> §10-34 / §10-38 and [`research/flap-vault-identity-spike.md`](./research/flap-vault-identity-spike.md).
> Route B (permissionless `openSeries`) and issue #21 are **not applicable**. The implementation and deployment wiring
> are issue #37 (M2-5).

---

## 13. Milestones

| Stage | Content | Output |
|---|---|---|
| **M1** | **All four on-chain contracts** — AttestationRegistry + Warrant + **MerkleDistributor** + ClearingPool — plus the **seven** invariant tests | contracts + test suite |
| **M2** | WarrantVault + Factory + Launcher + structural self-check | **identity root + D0 launcher + factory + deployment wiring shipped** (issues #37 / #57); **the vault and factory are de-Flapped** (issues #58 / #57) — the structural check now proves the absence of the former Flap bases and hooks |
| **M3** | End-to-end integration on a complete-system deployment chain | Code-side tooling is present: #66 manual Merkle path, #67 isolated stage-A full-loop driver, #68 keeper, #77 external dead-man hook, and #79 persistent mainnet-fork environment. The deployment and verification allowlist covers 4663 / 46630 / 31337 / 31338 (issue #65). ⚠️ Testnet **46630** carries only the operations part of stage B (deployment/wiring verification, real version-0 signing, keeper on the real block cadence, explorer/front-end reads, and monitoring hookup); launching, vaults, TWAP, and series opening stay on a mainnet fork. #69's two-to-three-week real-clock rehearsal/operational acceptance remains open |
| **M4** | ✅ Canonical replay + deterministic calculation + MerkleDistributor + open-source recomputation + sealed proof read model + publisher handoff/finality/recovery (#91–#96); a persistent Proof Runtime is deployed for Core staging, while production services remain undeployed | independently verifiable modules and artifacts; `setRoot` remains human-signed |
| **M5** | OrderbookService + Seaport integration; ✅ M5-0 froze D1–D10 (§6.6.1); umbrella #103, implementation #104–#107 | canonical asks / partial fill / soft delist and on-chain cancel / canonical state projection |
| **M6** | Web App is complete against mocks outside this repository; the #114 backend staging artifacts/runtime/fixtures are delivered, while frontend integration and joint acceptance remain under umbrella #110 | `v1.0.0` enables launch / project / warrant / claim / attest / exercise / calendar and disables OTC |
| **M7** | Mainnet + first GME project | — |
| **M8** | ⏳ Buyback vault + standing-order satellite (§6.7 / §6.8, decisions 50 / 51) | `v1.2` candidate; mainnet preconditions: R17 counsel opinion + tax-free contract-transfer check (§14-14) |

Current progress: **M1 is complete; M2-0 through M2-6 are implemented and tested** — identity-root slots, D0
launcher, Factory wiring, strict TWAP, revenue, `openSeries`, and **the de-Flapped, non-upgradeable vault (#58)**
are all present. **M4's canonical replay, deterministic calculation, public recomputation, sealed bundle catalog,
read-only Proof API/HTTP adapter, and publisher handoff/finality/recovery flow are implemented and tested (#91–#96).
A persistent, resettable Proof Runtime is deployed for Core staging acceptance; no production Indexer or HTTP service
is deployed, and `setRoot` remains human-signed.** M3 tooling for #66 / #67 / #68 / #77 / #79 is implemented; #69's real-clock operational acceptance remains. The #114 backend staging artifacts/runtime/fixtures are delivered, while Web App journeys, desktop/mobile, reorg/reset, and joint sign-off remain. M5 implementation and M7 remain planned. The `v1.0.0 Core` / `v1.1.0 Market` boundary and STG-0-D1 through D6 are frozen in [`frontend-integration-v1.md`](./frontend-integration-v1.md). Local
`deployments/31337*.json` files only demonstrate the deployment script against Anvil and do not represent a
Robinhood Chain deployment.

---

## 14. Open Technical Items

1. ~~Confirm the two corrections in §2~~ ✅ **Confirmed and propagated to design, implementation, and public copy**
2. **Exact semantics and final Robinhood Chain value of `antiFarmerDuration`** — **still unconfirmed**. The 30-day measurement is from the historical BSC MarsCoin sample and cannot set v1; 1 day remains a development / test placeholder until target-chain verification
3. ~~**TWAP sample frequency**~~ ✅ **Implemented for M2-2**: a strict trailing 24-hour window, normally sampled
   hourly, with `MAX_SAMPLE_GAP = 65 minutes`. This is a discrete-spot design; M2-4 has integrated the strike
   calculation, while service monitoring remains required.
4. ~~**Merkle publication cadence and latency**~~ ✅ **Frozen 2026-08-23 (#91)**: one full-window TWAB per
   series, never segmented by daily revenue; seal and publish only after the boundary block is in canonical
   `finalized` ancestry.
5. ~~**Seaport taker-fee encoding**~~ ✅ **Frozen 2026-08-25 (M5-D2)**: standard `PARTIAL_OPEN` order with no
   zone; fee is a separate GME consideration above maker proceeds, 0% for 56 days and 50 bps afterward (§6.6.1).
6. ~~**Curve-phase price read** — precision and semantics of `getTokenV8Safe().price` need testing~~ ✅ **Measured and confirmed 2026-08-14** (M2-2, issue #34). `price` = **raw quote units per 1e18 raw units of the token**, 18-decimal fixed point, formula `k/(1e9+h-s)²`; recomputed on the real chain from the lens's own `r/h/k/s` and equal to the reported `price` bit for bit (the `reserve` identity checks out too). 🔴 **It is the reciprocal of what the vault needs**, so sampling inverts it (`1e36/price`); 🔴 **it is identically `0` after graduation**, which makes the dual branch mandatory rather than an optimization, with `status` as the switch. Also confirmed along the way: **GME is an enabled quote token on this chain** (see the §3 correction), the post-graduation pool is **Uniswap V2-shaped**, and the lens **reverts** for unknown tokens (`TokenNotFound`). The current V2 branch rejects a reserve update stamped in the sampling block, but this is only a narrow same-block guard: it neither reads cumulative prices nor proves a complete V2 oracle/manipulation defense. ⚠️ Residual: `price` is normalized to 18 decimals rather than the quote token's raw units — GME happens to be 18 decimals so the two coincide, but **this must be re-derived before onboarding a stock token with different decimals**. Full record in [`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md)
7. ~~CREATE2 precomputation — Warrant / MerkleDistributor ↔ ClearingPool circular dependency~~ ✅ **Resolved 2026-08-09**: one-time deployer-only `setPool` binding on the two satellites; the pool keeps genuine immutables and **CREATE2 is no longer needed at all** (§12). This was M1's last hard blocker
8. 🔴 **Final wording of the two version-0 texts** — after deployment, their **two hashes are permanent and cannot be replaced**; the canonical texts themselves live in [`legal/attestation-v0/`](../legal/attestation-v0/). **This is the only irreversible item on this list.** ✅ **Finalized 2026-08-26 (issue #18)**: English is the authoritative language; the submitted texts are the versions reviewed and revised by external counsel, and their finalized hashes are pinned in `.env.example` and the `test_shippedTextIsFinalized` tripwire. The review scope and multi-language arrangement are permanently recorded in [`legal/attestation-v0/README.md`](../legal/attestation-v0/README.md). The mainnet gate is already enforced in `script/VersionZero.sol`
9. ~~**Attestation policy on the OTC side**~~ ✅ **Frozen 2026-08-25 (M5-D7)**: OrderbookService does not gate
   maker or taker attestation; only the `exercise()` beneficiary path enforces it (§6.6.1).
10. ~~Verify `FlapTaxTokenV3.transferFrom → 0xdead` behavior~~ ✅ **Verified on the v1 target, Robinhood Chain.** The pinned block 31,955,417 suite preserves reproducible evidence; a separate latest-state canary pins the current GME beacon and the Flap new-launch selection chain (Portal implementation → immutable launcher → immutable supported token implementation), checks all three Flap runtime codehashes, and exercises a real transfer. Both layers run Forge with `FORK_REQUIRED=true`: the pinned-block layer is part of the gate (`script/ci.sh fork`), while the latest-state canary was split out as of issue #25 and runs separately (`script/monitor.sh canary`), deliberately outside the gate, because what it watches (when a third party upgrades) has nothing to do with what any given commit changed. Against a real `FlapTaxTokenV3` proxy, **`transferFrom(holder, 0xdead, X)` delivers exactly X**; `0x0` reverts; and no native `burn()` / `burnFrom()` exists, so the `0xdead` path is required. The earlier BSC / MarsCoin probe remains historical methodology evidence only, not a v1 requirement. ✅ **The target-chain positive tax control was obtained on 2026-08-16** (the D0 spike for #53): not by *finding* a token with an active tax branch, but by *launching one ourselves* and buying it through the curve to graduation — a GME-quoted token whose 300 bps buy/sell tax is measurably withheld into the token contract, swapped back to GME by the `TaxProcessor`, and paid out by a permissionless `dispatch()` to the beneficiary named at launch. Anchor: `test/fork/RobinhoodSelfLaunch.t.sol`; write-up in [`research/self-launch-spike.md`](./research/self-launch-spike.md) §3
11. 🔴 **Target-chain check still open: tax may be scoped to registered pairs, allowing an unregistered parallel pool to escape it.** Historical BSC MarsCoin evidence measured **3.00%** into the registered pair, **0** into a third-party PancakeSwap V3 pool, and **70.4% of volume** on the untaxed pool during a 38-minute window. This does not constitute Robinhood Chain acceptance evidence. Because the target implementation is ABI-isomorphic but no active-tax positive sample has been found there, v1 treats the mechanism as a conservative structural risk and must repeat the registered-pair / parallel-pool comparison on Robinhood Chain before launch. Third-party pools remain **not fixable in our contracts**; see `design.md` R14
12. ~~ClearingPool interface-freeze review~~ ✅ **Decided and applied** (2026-08-09): ① pool-internal `rollExpired`; ② gating-aware settlement (fail-open + 48h grace); ③ `exercise` with beneficiary + `claimAndExercise`; ④ permissionless `claim`. §4–§8, §11, §12 of this file rewritten; decision records in `design.md` §10-25…28

13. 🔴 **The launch route is decided: D0** (2026-08-16, #53 / `design.md` §10-39). This item now tracks its
    implementation.

    **Settled fact (unchanged)**: the `VaultPortal.newTokenV6WithVault` entry point has **no quote that can create a
    real `WarrantVault`**. Native `quoteToken = address(0)` reaches the `WarrantVault` **constructor**, whose zero-address
    guard reverts the whole launch before the subsequent code-length guard can run; GME is rejected with
    `UnsupportedQuoteToken(GME)` **before** our Factory is called. Both failures are loud and leave no permanent bad
    registry binding. Anchors:
    `test/fork/RobinhoodWarrantVaultFactory.t.sol::test_withTheRealVaultTemplate_aNativeQuotedLaunchFailsLoudly`
    and `::test_withTheRealVaultTemplate_aGmeQuotedLaunchFailsUntilVaultPortalEnablesGme`. A mainnet re-check
    confirmed the gate is **hardcoded upstream** (a pure constant check in the `VaultPortalLaunch` facade; VaultPortal
    exposes no quote-configuration surface and has zero configuration events in its entire history), so opening it
    would require a Flap contract upgrade, not a configuration transaction.

    **Decision: do not wait for upstream — take D0** — the generic `Portal.newTokenV6` plus our own launcher
    orchestrator (create token → create vault → `bind`, all in one transaction). Fork tests have driven the whole
    chain end to end and are merged to `dev` (`test/fork/RobinhoodSelfLaunch.t.sol`, seven tests; spike write-up in
    [`research/self-launch-spike.md`](./research/self-launch-spike.md)): a contract may be the `msg.sender` of
    `newTokenV6` and that call **returns the real token address synchronously**; a GME-quoted launch buys through the
    curve and graduates into a **MEME/GME** pool; tax is withheld as MEME inside the token contract, and once past
    `dispatchThreshold` the `TaxProcessor` swaps it back to GME and a **permissionless `dispatch()`** pays
    `marketAddress` — which equals the `beneficiary` supplied at launch (our vault in production). The whole path
    requires **no registration and no authorization** from Flap.
    `Portal.getQuoteTokenConfiguration(GME).enabled == 1` describes exactly the entry point D0 uses.

    ⚠️ **One intermediate state that invites a wrong reading**: the swapped-back GME first sits in the
    `TaxProcessor`, split across five purpose buckets (market / dividend / lp / fee / commission), and does **not**
    appear at the recipient address on its own — watching only the recipient's balance reads as "the tax never
    arrived". Pinned by
    `test/fork/RobinhoodSelfLaunch.t.sol::test_theTaxPotIsSwappedBackIntoTheQuoteTokenByTheProcessor`.

    ✅ **The launcher orchestrator shipped on 2026-08-17 (issue #57 / decision 40)**:
    [`src/WarrantLauncher.sol`](../src/WarrantLauncher.sol); sequence and parameters in §6.1; pinned-height
    end-to-end acceptance in `test/fork/RobinhoodLauncher.t.sol` (CI required), latest-block probe in
    `test/fork/RobinhoodSelfLaunch.t.sol` (`script/monitor.sh canary`). The `VaultRegistry` 2-slot writer roster plus
    `PendingLauncherSlot` shipped as #56 and must precede `ClearingPool` deployment because the pool's
    `vaultRegistry` is immutable, so slots cannot be added afterwards. Vault de-Flapping shipped as #58:
    `VaultBaseV3` is gone, each vault is non-upgradeable, and the price-source portal is a constructor parameter.
    §14-7's target-chain positive tax control is **closed affirmatively** by this spike.

    🔴 **What this item still tracks:**
    - the production value of `antiFarmerDuration` is still open (§14 item 2). Today it is a `launch` parameter,
      not a constant; settling it should fold it into a launcher `constant`, which means redeploying the launcher;
    - `commissionReceiver` is a launcher `immutable`. Changing it means redeploying the launcher **and** the
      identity root and the pool (the writer roster is fixed at construction) — so it must be settled before
      mainnet deployment; see the §12 checklist;
    - "who buys through the curve" is an operational question, not a contract one (spike §6-2).

14. 🔴 **Deployment preconditions for the buyback vault / standing orders** (added 2026-09-04, §6.7 / §6.8): ① counsel confirmation that a contract signing version 0 is a valid attestation (R17; whether a version 1 text is needed); ② mainnet-fork check that MEME wallet↔contract transfers are untaxed (the pool's exercise path already asserts an exact debit; the satellites add one hop, `transferFrom(user → satellite)`); ③ final values for `discountBps` (start 1000), daily buy cap (start none), `feeBps` (start 0); ④ whether M4 ingests the satellites' per-user exercise events. ① and ② block mainnet deployment; ③ and ④ do not block implementation.
