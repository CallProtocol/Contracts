# warrant — Mechanics Playbook

> For readers who want to understand exactly how this works.
>
> ⚠️ **Three classes of statement in this document. Do not conflate them:**
> - **[VERIFIED]** — on-chain facts about external dependencies (GME contracts, Flap fees, Seaport deployment), read first-hand 2026-08-08
> - **[IMPLEMENTED]** — M1 contracts and M2-0–M2-5: immutable identity root, vault skeleton, strict trailing-24-hour TWAP / PriceSource, revenue path, permissionless `openSeries`, and Factory wiring, plus all three M2-6 tickets (#56 two-slot identity root, 🔴 **#57 the D0 orchestration layer `WarrantLauncher`**, #58 vault de-Flapping). They are tested but not deployed to Robinhood Chain. **The launch route was decided on 2026-08-16 (D0, decision 39 / #53) and implemented on 2026-08-17 (decision 40 / #57)**: the generic `Portal.newTokenV6` plus our own launcher, minting the token, deploying the vault, and writing the binding in one transaction — with a pinned-height end-to-end gate in CI that includes `TaxProcessor.marketAddress() == vault`. **M2 has no implementation tickets left**; what remains before a production launch is deployment and operations, not code
> - **[IMPLEMENTED OFFCHAIN]** — M4 canonical replay, deterministic entitlement calculation, public recomputation, sealed immutable bundles, publication catalog, the read-only Proof API/HTTP adapter, and a finality/chain-identity-checked publisher handoff. A persistent, resettable Proof Runtime is deployed for Core staging acceptance; the production Indexer/HTTP service is not deployed and publication remains human-operated
> - **[PLANNED]** — production deployment of the Indexer/Proof API, the M5 order book, completion of Web App Core integration and acceptance, production scheduling, and operating parameters
>
> Competitor teardowns: [`research/`](./research/) · Product decisions and rationale: [`design.md`](./design.md) · Engineering spec: [`spec.md`](./spec.md) · Frontend contract: [`frontend-integration-v1.md`](./frontend-integration-v1.md)

- **Chain**: Robinhood Chain (chainId **4663**, Arbitrum Orbit L2, gas in ETH)
- **First underlying**: GME (GameStop · Robinhood Token)
- **Status**: **M1 and M2 contracts and tests are complete, not deployed to Robinhood Chain. The launch route D0** (decision 39 / #53, 2026-08-16) **is implemented as of #57** (decision 40, 2026-08-17): generic `Portal` entry plus our own orchestration layer `WarrantLauncher`, minting the token, deploying the vault, and writing the binding in one transaction. **M2 has no implementation tickets left; M4's code is complete through #96.** M3 tooling for #66 / #67 / #68 / #77 / #79 is implemented. The Web App is complete against mocks, and the #114 backend staging artifacts/runtime/fixtures are delivered; frontend integration and joint acceptance remain. #69's real-clock operational acceptance, M5 implementation, M7, production deployment, and production operations remain

---

## 0. In One Sentence

**Get GME → buy MEME with it → hold, and warrants accrue weekly → before Friday's expiry, pick one: burn MEME to exercise into GME, sell the warrant on the order book, or let it expire.**

---

## 1. Terminology Map

Public-facing language and on-chain entities are two different vocabularies. The two tables below
are the two halves of that vocabulary: **the half users see** (§1.1), and **the half that starts at
expiry** (§1.2) — the latter barely appears in public copy, but [`spec.md`](./spec.md), the issues
and the code comments use it constantly.

> ⏳ marks entries that are **not implemented yet**; the bracket gives the ticket or milestone.
> Cite them as such — they are not existing interfaces.

### 1.1 Assets, actions and contracts

| Public term | On-chain entity | Note |
|---|---|---|
| warrant / call | `Warrant` (ERC-1155) | keyed by `seriesId` |
| series | `seriesId = keccak256(meme, stock, expiry)` | **isolated per project**, not fungible across projects |
| open a series | `ClearingPool.openSeries()` | **only the vault registered for that MEME in the identity root** may call it; once only, and the strike is fixed from then on. 🔴 This used to be permissionless, with squatting as the exposure; after issue #23 ruled for the identity root, squatting **has no entry point** — see [`spec.md`](./spec.md) §4.2 |
| deposit-and-mint | `ClearingPool.depositAndMint()` | series vault only; mints the **actual balance delta**, not the requested amount — they differ for a taxed token |
| airdrop / claim | `MerkleDistributor.claim()` | proof-based, not pushed; **permissionless** — a keeper may submit on your behalf, and warrants only ever go to the leaf's `account` |
| exercise | `ClearingPool.exercise()` | atomic three steps, plus a step-0 attestation check |
| beneficiary | third argument of `exercise(…, beneficiary)` | 🔴 the attestation gate checks **them**, MEME is debited from them, stock goes straight to them; the caller can only be them or `MerkleDistributor` |
| claim-and-exercise | `MerkleDistributor.claimAndExercise()` | saves the "claim first, then exercise" pair of transactions; callable only by `account` itself. 🔴 Shares one `claimed` flag with `claim()` |
| attestation | `AttestationRegistry.attest()` | **one-time**, exercise path only |
| collateral | `Series.deposited` / `stockToken.balanceOf(pool)` | always **raw units**; a split changes `uiMultiplier`, not balances |
| protocol inventory | MEME balances held by chain-provable protocol roles | curve, DEX pool, Portal, token tax pot, and TaxProcessor balances are excluded from entitlement weight only with a role, effective cursor, and reproducible on-chain evidence; v1 does not look through LP tokens |
| treasury | `WarrantVault` | **one per project**, 🔴 **non-upgradeable** (decision 39-A3 / #58 shipped: no Flap base contracts, no beacon, no Guardian; the factory deploys one directly on every launch and all six arguments are fixed in that one `CREATE`). It wakes on the protocol ping and recognizes revenue by balance delta, records a strict trailing-24-hour reading from hourly discrete price samples (failing closed when insufficient), and has permissionless `processRevenue()` accrue 10% of each depositable batch to the launch creator (decision 49; counted only when the deposit actually debits) and ask the pool to pull the rest, before updating the baseline from the actual post-deposit balance. The pool, distributor, and creator are the vault's own three immutable destinations (written by the factory at deployment), and the price-source Portal is likewise a constructor argument. `claimCreatorFee()` permissionlessly transfers the accrued share to the creator — the caller cannot redirect it. `openSeries()` is likewise permissionless: it prices the strike at 24-hour TWAP × 0.8, aligns expiry to Friday 21:00 UTC with at least seven days of life, refuses to open when samples are insufficient, and bounds the caller's choice of instant to a 24-hour window. Its **external write surface is exactly six entries** — `sync`, `sampleTwap`, `openSeries`, `processRevenue`, `receive`, and `claimCreatorFee` — **none permissioned** (`initialize` went away with upgradeability). |
| identity root | `VaultRegistry` | its writers are a **two-slot list fixed at construction with no setter** (`isFactory` / `factories()`); only a listed writer can successfully bind a MEME to a vault once. The mapping is not generally mutable, but it is not itself an `immutable`: the list-only `bind` is its single write path. Both slots share one table, so "two writers" never means "two chances to bind". |
| reserved writer slot | `PendingLauncherSlot` | what fills the list's second slot today: a placeholder for the launcher of a **future in-house launch stack** (decision 39-D). Deployer-only, write-once, permanently locked `setLauncher`, emitting `LauncherSet`; until it is armed, `bind` is fail-closed to every caller. 🔴 It is an **honest cost**: code that does not exist yet enters the trust base early, in exchange for never having to replace the pool when the launch stack changes. |
| launch orchestrator | `WarrantLauncher` | 🔴 **the launch entry point** (decision 40 / #57). One transaction calls the generic `Portal.newTokenV6`, has the factory deploy a non-upgradeable vault, and writes that MEME's single identity-root binding. It occupies the identity root's first writer slot; the economics are constants in its bytecode and the caller cannot change them. Permissionless — a stranger who uses it gets the vault for *their own* MEME. |
| vault factory | `WarrantVaultFactory` | called only by `WarrantLauncher`; **deploys a non-upgradeable vault directly** and returns it — it **never touches the identity root** (that write lives in the launcher). `nextVault()` predicts the next vault address so the launcher can put it in the launch `beneficiary` field (the tax recipient). Anyone may trigger `WarrantVault.openSeries()`, but the pool admits the downstream call only when that registered vault is its caller. |
| clearing pool | `ClearingPool` | **platform-level, one per chain, immutable** |
| strike | `Series.strike` | one per series, denominated in MEME |
| expiry | `Series.expiry` | Friday 21:00 UTC. ⚠️ That is product convention; the pool does not interpret the value (§4.1) |
| market | Seaport 1.6 + our off-chain order book | we never custody; public name **Warrant Market**; takers pay in **the series' stock token** (decision 52) |
| launch | **our own launcher** (which calls `Portal.newTokenV6()`) | via Flap's generic entry point, **with no registration or authorization** (measured: a brand-new contract launches successfully). The launcher creates the token, the vault, and the identity-root binding in one transaction |
| buyback vault ⏳ | `BuybackVault` (one per project, planned, spec §6.7 / decision 50) | anyone funds it with MEME; it buys ITM warrants at `min(TWAP, spot) − strike` less a discount and exercises in the same tx; **depth = deposits, not a guaranteed exit**; LPs must be attested to withdraw stock |
| standing order ⏳ | `StandingOrder` satellite (planned, spec §6.8 / decision 51) | one-time approvals + one rule; before expiry anyone can trigger "exercise if ITM / sell to the buyback vault"; the pool's exercise gates are unchanged |

### 1.2 Expiry, gating and maintenance

Every action in this half is **permissionless** — any address may call it, holders included. There
is no dedicated role here, and no admin.

| Term | On-chain entity | Note |
|---|---|---|
| issuer | Robinhood: `Stock` + the central permission registry `0xe10b…1b00` | every Robinhood stock token shares one role set and one blocklist — block once, and that address is dead across all of them |
| gating | `ClearingPool.gating(stockToken)` → `Gating` | an **observation record** of issuer state, three-state: clean / gated / unreadable |
| observe / poke | `ClearingPool.pokeGating()` | 🔴 **writes only on a transition**. If the "cleared at" stamp can be pushed repeatedly, settlement can be blocked forever (invariant 4c, spec §7) |
| exercise deadline | `ClearingPool.exerciseDeadline()` | **not** the expiry: the window is unbounded while gating is observed (but actual exercise still reverts atomically if the issuer blocks stock delivery), and `max(expiry, cleared at + 48h)` afterwards |
| grace | `ClearingPool.GRACE_PERIOD` (48 hours) | runs from the moment the clearing is **observed**, not from the moment the issuer actually cleared |
| auto-extension | **no function corresponds to it** | it is the consequence of "settlement cannot happen while gated and the exercise window remains open", not a switch. Exercise works again the moment the issuer clears — **no poke required**; observing the clearing merely collapses the window to `max(expiry, cleared at + 48h)` — do not look for `extend()` |
| settlement | `ClearingPool.settleExpired()` | observes once first, then requires a clean live read and a passed exercise deadline |
| remainder | `Series.remainder` | `deposited − exercised`, fixed at the moment of settlement, waiting to roll |
| rollover | `ClearingPool.rollExpired()` | re-attribution inside the pool; collateral **never leaves it**; permissionless, every gate self-verifiable |
| expire worthless | **no action corresponds to it** | past the exercise deadline the warrant is unusable. It is not burned and stays with its holder; once settled, its collateral moves into `remainder` and rolls to whoever is still around |
| Monitor | off-chain service ([`spec.md`](./spec.md) §9) | three duties: watch issuer events, backstop the poke, and check daily for an **issuance stall**. **Not a trust dependency**: the contract only trusts recorded observations, and anyone can record one |
| issuance stall (停发) | "the series this period should have opened, didn't" ([`spec.md`](./spec.md) §9.1, issue #42) | orthogonal to solvency: solvency is a structural guarantee, **issuance liveness is an operational one**. The verdict comes from the on-chain `Series` record and **never assumes Friday 21:00** |
| publisher | `AttestationRegistry.publisher` | may only **append** the two hashes for a new attestation-text version; cannot touch old versions or anyone's attestation state |
| root publisher | `MerkleDistributor.publisher` | publishes the weekly entitlement root. 🔴 **The single centralized trust point in the system**: it decides who gets this week's warrants. It cannot take any warrant — `claim()` only ever delivers to the leaf's `account`. A **separate key** from the row above; the two may be different addresses |
| entitlement root | `MerkleDistributor.roots(seriesId)` / `rootFrozen(seriesId)` | one per series. Replaceable **until that series' first leaf is claimed** (typo correction), then frozen forever |

---

## 2. Three Assets

### 2.1 MEME (`FlapTaxTokenV3`) [PLANNED INTEGRATION]

Issued by Flap. **Not our contract.**

| Item | Value |
|---|---|
| Supply | **1 billion** (Flap platform standard, not our choice) |
| Buy / sell tax | **3% / 3%** |
| Tax currency | **GME itself** (the pair is MEME/GME) |
| Tax routing | `mktBps = 10000` → 100% of the net tax balance to our vault, after Flap's protocol fee and the integrator commission |
| Tax duration | **100 years** (maximum) |

> 🔴 **`taxDuration` is a trap.** Flap's official example uses 365 days. Copy it and the project **dies silently one year after launch** — tax stops, no stock enters the pool, no warrants are issued. Our template locks it to the maximum.

**We cannot modify the MEME contract.** One direct consequence: we cannot record holding duration inside it, so entitlement must be computed off-chain (§5.2).

### 2.2 GME (Robinhood Stock) [VERIFIED]

`0x1b0E319c6A659F002271B69dB8A7df2F911c153E` · 10,773 holders

**Legal form**: a **price-tracking tokenized debt security** issued by the issuer (per its public disclosure) — **no ownership of the underlying shares, no voting rights, no shareholder claims**. Every mention of "the stock / GME" in this document means this token, not the share itself. (Noted 2026-08-09)

**Architecture**: BeaconProxy → implementation `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` (contract name `Stock`, verified source). Permissions are **externalized to a chain-wide registry** at `0xe10b6f6b275de231345c20d14ab812db62151b00`.

**What the issuer retains** (each item read from source):

| Role | Capability |
|---|---|
| `BLOCKER_ROLE` | 🔴 Block any address. `onlyNotBlocked` is **hard-coded into `transfer` / `transferFrom` / `approve` / `permit`** |
| `ADMIN_BURNER_ROLE` | 🔴 **Burn from any address, with no pause check and no blocklist check** |
| `PAUSER_ROLE` / `TOKEN_PAUSER_ROLE` | Global pause / per-token pause |
| `BEACON_UPGRADER_ROLE` | Upgrade every stock token at once |
| `MULTIPLIER_UPDATER_ROLE` | Change `uiMultiplier`, with scheduled `effectiveAt` |
| `METADATA_UPDATER_ROLE` | Rename the token |

**Current measured state (2026-08-08)**: not paused, sampled addresses not blocked, and simulated transfers from a wallet holding 14,813 GME to an unknown EOA, to `0xdead`, and of a full 1.0 GME **all succeed**.

> **The machinery is wired but none of it is switched on.** That is a statement about capability, not about current behavior — and it defines the risk boundary in §12.

**EIP-8056 on Robinhood Chain**: splits and dividend reinvestment propagate through `uiMultiplier`; **`balanceOf` does not change**. All our accounting therefore uses raw units, and the frontend multiplies only for display. BEP-677 appears only in the historical BSC comparison.

### 2.3 Warrant (ERC-1155) [IMPLEMENTED, NOT DEPLOYED]

Issued by us. `id = seriesId`. **Fully fungible within a series and freely transferable** — a precondition for Seaport matching and partial fills.

Only `ClearingPool` can mint or burn.

---

## 3. The Full Loop

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  ①get GME → ②buy MEME → ③hold & accrue → ④claim → ⑤before Friday │
  │                             ↑                    ├─ exercise      │
  │                             └── selling stops ───┼─ sell          │
  │                                     accrual      └─ pass          │
  └──────────────────────────────────────────────────────────────────┘
```

### ① Get GME
Acquire GME on Robinhood Chain. **This is a precondition** — you cannot buy MEME with ETH directly.

### ② Buy MEME with GME
On the bonding curve or, after graduation, the DEX. **Buying pays 3% tax** (plus Flap's separate 1% curve fee during the curve phase; it is not deducted from the tax).

### ③ Hold — warrants accrue
Once a day, the vault deposits the GME it has received into the clearing pool and mints warrants **1:1** against it.

**Your entitlement is computed once from time-weighted holdings over the complete series window** — not a snapshot and not one allocation per day's revenue. Holding the full window earns the full share; buying a second before a claim earns nothing. An address whose full-window average is below 10,000 MEME does not participate.

### ④ Claim
A merkle root is published weekly; you claim with a proof. **Anyone may submit it for you** — warrants only ever go to the address written into the leaf, so submitting on someone's behalf takes nothing, and a keeper can pay the gas for you.

> **Claiming is only required if you want to transfer or sell.** Exercise works directly from the accrued balance — deliberately, so that "forgot to claim" never costs you the warrant.

### ⑤ Before Friday 21:00 UTC, choose

| Action | You give | You get | Attestation |
|---|---|---|---|
| **Exercise** | Burn `strike × amount` of MEME | The corresponding GME | **Yes** (one-time, §6.3) |
| **Sell** | The warrant | Premium on the order book (GME or ETH) | No |
| **Pass** | — | Nothing. The stock rolls into the next series inside the clearing pool | No |

---

## 4. The Warrant in Detail

### 4.1 Series and Expiry

| Item | Value |
|---|---|
| Expiry | **Friday 21:00 UTC** (fixed; no DST adjustment) |
| Minimum life | **≥7 days** — mints within 7 days of the coming Friday go to the following one |
| Live series | **Exactly two per project** (one accruing, one expiring) |

**Why fixed UTC rather than tracking the US close**: exercise requires **no settlement price** — it is "burn N, take one unit." The one-hour DST drift has **no economic consequence**; it is a labeling question only.

### 4.2 How the Strike Is Set

```
strike = TWAP(previous 24h, MEME/GME) × 0.8
```

- **Set once per series**, locked when the series opens, shared by every mint that week
- Denominated in **MEME**: one warrant = `strike` MEME for one unit of GME
- Opens **20% in the money**

**Why one strike per series**: tax arrives continuously — dozens of dispatches a week. Pricing each mint separately would put dozens of different strikes in one series, and **they would not be the same asset. ERC-1155 cannot represent them under one id, and the order book fragments.**

**Why TWAP rather than spot**: the strike is set once but governs a full week of issuance. Reading spot means **a single pump locks in a week's strike**. The M2-2 reader is a strict trailing-24-hour aggregate of discrete spots: an attacker must repeatedly control sampling segments (each capped at 65 minutes), but can restore the market price after each sample. It is not continuous observation or a cumulative-price oracle.

### 4.3 🔑 Moneyness Depends on MEME vs GME — Not GME's Dollar Price

The least intuitive and most misunderstood property of this design.

Say a series opens at 1 GME = 1,000 MEME, so the strike is 800 MEME.

| A week later | Worth exercising? | Where you stand |
|---|---|---|
| 1 GME = **500** MEME (your token outran it) | ❌ burn 800 for something worth 500 → worthless | but your bag doubled against the stock |
| 1 GME = 1,000 MEME (flat) | ✅ burn 800, receive 1,000 → +200 | normal |
| 1 GME = **2,000** MEME (your token lagged) | ✅ burn 800, receive 2,000 → deep ITM | **compensates you in the week your token was weak** |

> **A warrant is a relative position: long GME, short your own meme. It pays when your meme doesn't — a free weekly hedge on your own bag.**

To render it worthless your token must outrun GME by more than 20% in a week. In that case you have better things to think about.

---

## 5. How Issuance Runs

### 5.1 Daily Mint [MIXED: POOL AND M2-3 VAULT PATH IMPLEMENTED, PRODUCTION SCHEDULING UNDEPLOYED]

```
Flap TaxProcessor ──dispatch GME + ping──► WarrantVault.receive()  (accounting only)
                                                    │
        our Trigger Service ──once daily──► processRevenue()
                                                    │
                    ClearingPool.depositAndMint(seriesId, distributor, balance)
                                                    │
                        mints from the OBSERVED balance delta, not the argument
```

**Why not inside `receive()`**: `receive()` is triggered by Flap's dispatch. Doing deposits and mints there raises gas materially, and any revert would disrupt Flap's tax settlement.

**Why daily rather than per-dispatch**: with the strike fixed per series, frequency no longer affects fungibility — only cost. Daily also compresses the exposure window for **in-transit funds** (received by the vault, not yet in the pool) to ≤24 hours. `processRevenue()` fails honestly when the balance is unreadable; that failure is not evidence that the vault is empty.

> 🔴 **Where that top arrow lands is Flap's call, not ours.** The Portal exposes
> `changeMarketWallet(token, newWallet)` (`TAX_GUARDIAN_ROLE` / `DEFAULT_ADMIN_ROLE`), which changes
> **who the tax is paid to**. At launch that address is our vault; after a change, the same token's tax
> flows elsewhere while **the token, the vault, and the binding in our identity root all stay exactly
> as they were**. On Robinhood Chain mainnet this permission **has already been used three times**
> (all three on someone else's token — see [`design.md`](./design.md) decision 35).
>
> **There is no on-chain defense available to us** — this is a permission on Flap's contract. All we can
> do is see it: `script/watch-market-wallet.sh` watches for the event (entry point `script/monitor.sh tax`).
> Since 2026-08-17 it has **no scheduler** — someone has to remember to run it. See the residual risk in
> the README's monitoring section.
>
> For the boundary, see §12: it cannot touch **warrants already minted**, and it cannot touch **collateral
> in the pool**. What it changes is the tax that flows into the vault **from then on**.

### 5.2 ⚠️ Why Entitlement Must Be Computed Off-Chain

**The MEME contract belongs to Flap; we cannot hook its `_update`.** Without a transfer hook there is no way to maintain per-user accounting on-chain. And computing from current balance at claim time is trivially gamed by buying immediately beforehand.

**The solution:**

```
Indexer subscribes to MEME Transfer events
  → reconstructs each address's balance history
  → computes time-weighted holdings for the period
  → allocates the week's warrants pro-rata
  → publishes a merkle root
```

| | |
|---|---|
| ✅ | Preserves "just hold — no staking" |
| ✅ | **Anyone can recompute and verify the root from public Transfer events** (algorithm and script open-source) |
| ✅ | Time-weighted, not snapshot — defeats buy-before-claim |
| ⚠️ | **This is the single centralized trust point in the system**: we compute and publish the root |

**Why not staking**: it would turn "hold and accrue" into "stake and accrue," contradicting the core narrative.

### 5.3 Your Share

```
your warrants = floor(total allocatable warrants before the series cutoff × your eligible full-window weight ÷ total eligible full-window weight)
```

The denominator contains only holders whose full-window average is at least 10,000 MEME. Protocol inventory
that can be identified from on-chain evidence, including the curve, Portal, token-owned tax pot, TaxProcessor,
and DEX pool, is excluded; v1 does not look
through LP tokens. Each account floors independently and dust remains in the Distributor. Daily deposit timing
does not change anyone's share.

> The "total allocatable warrants" in the numerator is already **net of the 10% creator fee** — issuance mints against the 90% of each revenue batch that reaches the pool, not the gross tax (decision 49; see §8.1).

---

## 6. Exercise in Detail

### 6.1 Three Atomic Steps

```solidity
require(!settled);   // expiry takes effect at settlement; while the issuer gates transfers, settlement is blocked = auto-extension (the clearing deadline is max(expiry, cleared at + 48h))
require(attestedVersion[you] != 0);                    // 0. attestation, see §6.3
1. warrant.burn(you, seriesId, amount)                 // burn the warrant
2. MEME.transferFrom(you, 0xdead, strike × amount)     // burn the meme
3. GME.transfer(you, amount)                           // move the stock  ← can fail
```

**Any step failing reverts everything.** Step 3 is the only one that can fail for external reasons — when the issuer has blocked or paused.

> That is the behavior we want: **under an issuer freeze you do not lose the warrant.** Expiry also auto-extends while gating is active, so nothing lapses.

### 6.2 Two Direct Consequences

**Exercise is deflationary.** Every unit of stock taken out permanently destroys meme supply.

**Exercise creates buying pressure.** Anyone who buys a warrant on the order book without already holding MEME must go acquire it to exercise. **The secondary market for warrants is structurally a demand channel for the token.**

### 6.3 The One-Time Attestation Before Exercise [IMPLEMENTED; TEXTS FINALIZED IN ENGLISH]

Before first exercise you sign at least one on-chain attestation (`AttestationRegistry.attest()`). The on-chain gate
then remains satisfied permanently. Re-signing the same version, or an older version after a newer one, is allowed:
account state keeps the maximum version while events record every signing action.

**What you sign is the hash of two texts.** The canonical texts live in
[`legal/attestation-v0/`](../legal/attestation-v0/); only their hashes are stored on-chain, and the frontend must
recompute and compare them byte-for-byte before display:

| Text | Content |
|---|---|
| **TERMS** | You understand this is a **right to buy** at a price, that exercising **burns MEME as consideration**, that it may expire worthless, and that the issuer of the underlying retains freeze and burn powers |
| **ATTESTATION** | You declare you are not located in the United States or another restricted jurisdiction, and are not acting on another's behalf |

**The gate sits only on the exercise path.** Holding, accruing, claiming, and selling on the order book need **no** attestation. Users in restricted jurisdictions can run the entire "hold → accrue → claim → sell" loop; they simply don't exercise. And selling is often the better economic choice anyway — exercising forfeits the warrant's time value.

> 🔑 **This gate is structurally incapable of locking you out.** Attestation state **only increases**, **only you can write yours**, and nobody — including us — can revoke it. The initial version's two hashes exist **permanently in the contract**; the canonical texts remain independently retrievable and verifiable from the repository, so you can always sign it. The chain requires only "attested at least once"; the frontend asks for the latest. **Even if our website goes down, you can call the contract directly and exercise.**

**It does not mean compliance is handled.** It covers *who may receive the stock*. It does not cover the two larger exposures — that we issue an option, and that we operate a market in it. And self-attestation is **unenforceable**: a different address routes around it. **What it buys is evidence and good faith, not enforcement.**

---

## 7. The Market

**Settlement uses Seaport 1.6 on Robinhood Chain** [VERIFIED] (`0x0000000000000068F116a894984e2DB1123eB395`; ConduitController `0x00000000F9490004C11Cef243f5400493c00Ad63`). BSC deployment facts are historical research only; they are not a v1 dependency or acceptance criterion.

**Model**: the seller signs an order off-chain (**zero gas**) → the buyer submits it to Seaport → the contract verifies the signature and swaps atomically. **Goods stay in the seller's wallet until the moment of the fill.**

| Item | Value |
|---|---|
| Matching | off-chain order book (operated by us), settlement on-chain |
| Listing / cancelling | **zero gas** |
| Partial fills | ✅ supported (list 100, fill 30) |
| **Taker fee** | **0% for the first 8 weeks, then 0.5%** |
| **Maker fee** | **permanently 0** |

**Why not an AMM**: options decay. LPs would be ground down by theta and the pool would eventually empty.

**Why taker-only**: depth is the scarce resource. We should not charge the people supplying it.

---

## 8. The Economics [PLANNED — illustrative, not measured]

> The following is a **worked example with stated assumptions**, meant to convey magnitude. Nothing is deployed; there is no live data.

**Assume**: MEME market cap $1,000,000, daily volume $200,000 (20% turnover), tax 3%/3%.

> 🔴 **One assumption below is the shakiest, and you should know which.** The example treats **all** volume as taxed. In the historical BSC MarsCoin sample, Flap's tax applied only to transfers involving a **registered** pair: a parallel permissionless pool was untaxed, and a 38-minute sample found **70.4% of volume there, with effective capture at 0.90% against a nominal 3%** ([VERIFIED], [`research/flap-tax-and-burn-path.md`](./research/flap-tax-and-burn-path.md)). This is not Robinhood Chain acceptance evidence; v1 keeps the target-chain positive-tax and parallel-pool comparison open.
>
> **Read every figure below as "of volume that happens on the taxed venue."** We cannot fix this in our contracts — the MEME token is Flap's.
>
> 🔴 **Issue #58 permanently removed the Flap vault-template path and its 0.06% commission.** Only the 0.06% integrator commission remains. Flap's 1% bonding-curve fee is a separate curve-stage fee, not a deduction from the 3% trading tax shown below.

### 8.1 Where a Day's Money Goes

| Item | Amount | To |
|---|---|---|
| Trading tax (3%) | $6,000 | collected as GME |
| − Flap protocol fee (≤0.3% of volume) | −$600 | Flap |
| − Integrator commission (0.06%) | −$120 | us |
| = net tax balance reaching the vault (2.64% of volume) | $5,280 | vault |
| − Creator fee (10% of the depositable batch, decision 49) | −$528 | launch creator |
| **= into the pool, backing warrants (2.376% of volume)** | **$4,752** | **holders** |

**Warrants receive roughly 79% of the tax; the launch creator receives roughly 9%** (decision 49 — accrued in the vault, pulled via permissionless `claimCreatorFee`). Our only automated take is the 0.06% integrator commission = $120/day.

### 8.2 From a Holder's Seat

Someone holding 1% ($10,000):

| | |
|---|---|
| GME entering the pool per week (after the 10% creator fee) | $4,752 × 7 = **$33,264** |
| Your share (1%) | covers **$332.64** of GME |
| MEME burned to exercise | $332.64 × 0.8 = **$266.11** |
| **Net** | **$66.53 / week** (≈ **0.67%** of position) |

### 8.3 Why Farming Doesn't Pay

A sniper buys before a mint and sells after:

| | |
|---|---|
| Round-trip tax on a $10,000 position | 3% + 3% = **$600** |
| Intrinsic value of one day's accrual (pool base, after creator fee) | $4,752 × 1% × 20% ≈ **$9.50** |
| **Gap** | **63×** |

For a single day's accrual to beat a 6% round trip, **daily volume would have to exceed twelve times the market cap**, sustained.

> **The tax that funds the mechanism is also what protects it.**

### 8.4 Whales

Warrants are distributed pro-rata, so large holders receive large allocations — the same arithmetic as any dividend. **What differs is what they can do with it:**

- Exercise → they must burn **a proportionally large amount of MEME**, shrinking both their position and circulating supply
- Dump warrants → they hand smaller holders **a discounted entry into the stock**

Both paths return something to everyone else. A whale who simply receives shares and sells them elsewhere returns nothing.

---

## 9. ⚠️ Rule Traps

Ranked by the cost of getting them wrong.

1. **🔴 Unexercised warrants are void at Friday 21:00 UTC.** The stock rolls into the next series inside the clearing pool and is re-issued to whoever is still holding — **your share is not refunded to you**. Two weeks of inattention loses two weeks of accrual. (Exception: while the issuer freezes or pauses the token, the series auto-extends and cannot expire mid-gating.)

2. **🔴 The issuer can freeze, and can burn, the collateral in the pool.** Full collateralization guarantees we cannot over-issue. It does **not** guarantee the issuer stays out. `adminBurn` has no pause check and no blocklist check, and **there is no technical defense** (§12).

3. **🔴 Buying MEME requires GME first.** The pair is MEME/GME; ETH does not work directly. This is entry friction, and it is deliberate.

4. **A warrant's value tracks MEME against GME, not GME's dollar price.** Your warrants going worthless while your token moons is the design, not a bug (§4.3).

5. **Exercising reduces your MEME position.** It is a conversion, not a collection — you burn tokens to receive shares.

6. **Your first exercise needs a one-time on-chain attestation, or `exercise` reverts.** Once only, permanent thereafter — but **don't discover it at 20:55 on Friday**: your first exercise is three transactions (attest, approve, exercise), two thereafter (one, with a standing approval). Selling needs no attestation (§6.3).

7. **A round trip costs 6% in tax.** Frequent entries and exits are eaten by it.

8. **Selling MEME stops future accrual** — but **already-accrued warrants are not forfeited**; you can still claim them.

9. **Entitlement is time-weighted, not a snapshot.** Buying a second before a claim earns nothing.

10. **The merkle root is published weekly.** You cannot claim before it lands; warrants already sit in the distributor and remain claimable retroactively. **Once the first person in that series claims, the week's root freezes forever** (`rootFrozen(seriesId)`, readable on-chain) — before that the publisher can correct a mistyped root; after it, nobody can.

11. **A warrant you bought still needs your own MEME to exercise.** The warrant is the right; you supply the payment.

12. **Displayed quantities jump when `uiMultiplier` changes.** Raw on-chain accounting is unaffected, but read numbers carefully around a split.

---

## 10. Parameters at a Glance [PLANNED, EXCEPT CONTRACT CONSTANTS]

| Parameter | Value |
|---|---|
| Chain / underlying | Robinhood Chain (4663) / GME |
| MEME supply | 1 billion (Flap standard) |
| Buy / sell tax | **3% / 3%** |
| `taxDuration` | **100 years** (max; not the 365 days in Flap's example) |
| Tax split | `mktBps=10000`, all others 0; the post-protocol-fee and integrator-commission balance goes to the vault |
| Indexer `minimumAverageBalanceRaw` | **10,000 MEME × 10^18 raw**; compare full-window weights, equality passes |
| Flap `minimumShareBalance` | **0**; meaningless when `dividendBps == 0` and unrelated to entitlement eligibility |
| `antiFarmerDuration` | **1 day for development / testing only; final value unresolved** (historical BSC MarsCoin observation: 30 days; Robinhood Chain semantics and value must be confirmed) |
| **`k` (strike coefficient)** | **0.8** (20% ITM) |
| Strike pricing | **24h TWAP** before series open, one per series |
| TWAP sampling | keeper polls every 90 seconds; the contract writes about hourly into a strict 24-hour window |
| Mint frequency | **daily** (Trigger Service) |
| Expiry | **Friday 21:00 UTC** |
| Minimum life | ≥7 days |
| Live series | 2 per project |
| Collateralization | **1:1**, no fractional reserve |
| OTC taker / maker | 0% for 8 weeks → 0.5% / permanently 0 |
| Exercise fee | **none** |
| **Attestation** | **exercise path only**, one-time; state is monotonic, self-write only, irrevocable by anyone |
| **Creator fee (`CREATOR_FEE_BPS`)** | **10% (1000 bps)** of each depositable revenue batch → the immutable launch `creator`; fixed at deploy, no setter; pulled permissionlessly via `claimCreatorFee` (decision 49). The pool receives the other 90% |
| Platform revenue | **0.06% of volume** (integrator commission only after #58) + taker fees. The 10% creator fee is **not** platform revenue — it goes to the launcher, not to us |

---

## 11. Contract Addresses

### External dependencies [VERIFIED]

| Role | Address |
|---|---|
| GME (BeaconProxy) | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` |
| GME implementation (`Stock`, verified) | `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` |
| **Chain-wide access registry** | `0xe10b6f6b275de231345c20d14ab812db62151b00` |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |
| ConduitController | `0x00000000F9490004C11Cef243f5400493c00Ad63` |
| Flap VaultPortal / Portal | see Flap docs, Deployed Contract Addresses |

### Ours

**Not deployed to Robinhood Chain.** The eight-contract deployment script (including the vault identity
root, the D0 launcher, the factory and the reserved second writer slot) has been broadcast, verified and
tested on local Anvil. Production order is in [`spec.md`](./spec.md) §12 and uses **no CREATE2 at all**:
**WarrantVaultFactory(flapPortal)** → **WarrantLauncher(flapPortal, factory, commissionReceiver)** →
**PendingLauncherSlot** → VaultRegistry (launcher and reserved slot as the two writers) → AttestationRegistry →
Warrant → MerkleDistributor → ClearingPool → the two `setPool` calls + `launcher.setRegistry` +
`slot.setRegistry` + `factory.setVaultTargets(pool, distributor)` + `factory.setLauncher(launcher)`.
🔴 The reserved slot must exist before the pool: the registry's writer list is fixed at construction and the pool's
`vaultRegistry` is immutable, so once the pool ships no slot can ever be added (decisions 39-C / 39-D). **The final
target-wiring step deploys no vault** (#58): vaults are non-upgradeable and the factory deploys one per launch.

The complete `DeploySystem` and verifier accept Robinhood mainnet **4663**, the public testnet **46630**
(issue #65), and local **31337 / 31338**; every other chain ID fails closed before broadcast or manifest
promotion. 🔴 **46630 carries only the part of stage B that does not depend on a Flap quote token** —
deployment and wiring verification, real version-0 signatures, the keeper's real-clock cadence.
**Launch / vault / TWAP / open-series cannot run there at all**, because that chain's Flap `Portal` has only
ever enabled one quote token — the native asset (#64). That whole chain moves to a mainnet fork running under
chainId **31337**; see [`design.md`](./design.md) decision 42.

🔴 That allowlist *is* `DeploySystem.flapPortalFor`, the chainId → Flap `Portal` table: **allowing a chain means
there is a Flap `Portal` contract on it**, and on a chain without one the system deploys into a pile of contracts
that can never open a series. ⚠️ The criterion stops there — "there is a Portal" does not imply "we can mint and
read prices there", and 46630 is exactly that counterexample (a Portal, but no ERC20 quote token enabled). The
testnet entry is written out separately even though it currently holds the same address as mainnet (and *not* the
same implementation: `v5.14.16` there against `v5.15.2` on mainnet), and `verify-deployment.sh` additionally checks
that the address really has code on chain before it will `--promote`.

> ⚠️ This line previously read "Warrant (CREATE2 precompute) … MerkleDistributor last". That was the order **before** decision 29 of 2026-08-09 and is void: the three-way construction cycle is now broken by the one-time binding slot on the satellites, CREATE2 is not needed anywhere, and both satellites must be deployed *before* the pool.

---

## 12. Risks

| Risk | Note |
|---|---|
| 🔴 **`adminBurn` can erase pool collateral** | No pause or blocklist check; burns from any address. **Full collateralization does not cover this.** Mitigation is limited to multi-underlying diversification, event monitoring, and explicit disclosure |
| 🔴 **Issuer can freeze or pause** | `onlyNotBlocked` is hard-coded into every transfer path and reads a chain-wide registry; plus per-token and global pause. Mitigation: exercise reverts cleanly, expiry auto-extends |
| 🔴 **The merkle publisher is a centralized trust point** | We compute and submit the root. Mitigation: algorithm and recomputation script are open-source and independently verifiable |
| 🔴 **Tax may be escapable via a parallel pool** | Historical BSC MarsCoin evidence found **70.4% of volume** in an untaxed pool and 0.90% effective capture vs 3% nominal. Robinhood Chain still lacks the positive-tax / parallel-pool comparison, so v1 treats this as a conservative structural risk until target-chain verification. Third-party pools remain **not fixable in our contracts** |
| 🔴 **Attestation ≠ compliance handled** | It covers *who may receive the stock*. It does **not** cover that we issue an option or that we operate an order book for one; and self-attestation is unenforceable (a second address routes around it). **The real risk is treating it as a shield** |
| 🟡 **Dependence on Flap** | Token, tax settlement, curve, and the Portal price source sit on their rails. The Trigger Service is our own operations component; Flap can still change platform terms and build warrants themselves |
| ~~🟡 **Flap Guardian can upgrade our vault**~~ | ✅ **Eliminated** (decision 39-A3 / #58): the vault is non-upgradeable and the Guardian has no authority over it. The **in-transit window** (≤24h) still exists, but it is now just "the part of this week's revenue that has not become warrants yet" plus a small edge of the issuer-permission exposure (~0.79% of pool size; `Pool* = 0.9S/f` as of decision 49) — no longer "exposed to a third party who can swap the implementation". Quantified in [`r4-in-transit-window.zh.md`](./r4-in-transit-window.zh.md) |
| 🟡 **Order-book cold start** | An empty book is a dead market. Zero taker fees for 8 weeks and permanently free maker are the bootstrap |
| 🟡 **Weekly expiry is unkind to passive holders** | Two weeks of inattention forfeits the accrual. Consistent with the ecosystem norm (Flap dividends are likewise pull-based) |
| 🟡 **Splits: an unexploded issue** | `uiMultiplier` is currently 1.0 almost everywhere. Raw-unit accounting avoids the failure, but `effectiveAt` must be monitored |
| 🟡 **Flap can unilaterally redirect the tax** | The Portal's `changeMarketWallet` is callable by `TAX_GUARDIAN_ROLE` / `DEFAULT_ADMIN_ROLE` and changes who the tax is paid to; it **has already been used three times** on mainnet (all on someone else's token). **Warrants already minted and collateral in the pool are unaffected** — what is affected is revenue reaching the vault from then on. No contract-level defense exists; monitoring only (`script/watch-market-wallet.sh`) |
| 🟡 **A blocked creator's accrued fee is stranded** | The 10% creator fee accrues to the immutable `creator` address; `claimCreatorFee` is gated by `onlyNotBlocked`. If the stock issuer blocks that address, the accrual can never be pulled — there is no setter and no recovery path (decision 49-⑧). This harms **only that creator**; warrants, pool collateral, and every holder's share are untouched. It is the creator's own key/eligibility risk, priced in by design |

### 🔴 Four Guarantees, Four Different Strengths — Say All Four

| Layer | Rests on | Who can move it |
|---|---|---|
| **Solvency** | **Structural guarantee** — collateral sits in a separate, non-upgradeable ClearingPool with no admin withdrawal path | Only the stock issuer (`adminBurn` / freeze, first two rows above). **Flap cannot reach it** |
| **Issuance liveness** | **Operational guarantee** — someone has to open each series on time and deposit the tax on time | Our own keeper and monitoring; Flap price-source or tax-routing changes remain external dependencies |
| **Revenue** | **Platform trust** — who the tax is paid to depends on a permission Flap holds | Flap's `changeMarketWallet` |
| **Launch capability** | **Our own implementation + two of the platform's config slots** — as of decision 39 we use the generic `Portal.newTokenV6`, which takes **no registration and no authorization** and accepts GME quoting in practice; ✅ the `WarrantLauncher` orchestration layer shipped in #57 (#56 and #58 shipped too), so nothing on the contract side blocks a launch. ⚠️ But the platform holds after-the-fact kill switches, and the **two cheapest** each take one ordinary transaction and no contract upgrade: `setQuoteTokenConfiguration(GME, {enabled: 0, …})` (GME stops being a quote token) and `setQuoteTokenCreationDisabled(GME, true)` (still a quote token, but no new tokens may be launched against it). 🔴 **These are two distinct storage slots, and either one alone stops new launches** — measured: flipping the second leaves the first reading its original value. There are also `halt` / `setBitFlags` and the Portal proxy upgrade. **All of them only gate whether *new* tokens can be launched — they cannot touch already-launched tokens, warrants already minted, or pool collateral**; we watch both switches (`RobinhoodCurrentCanary::test_gmeIsStillAnEnabledQuoteTokenToday`, run against latest; risk ledger R16) | **Us + Flap** — *being able to* launch rests on our own implementation, *the launch succeeding* rests on those two Flap config slots (decision 39 turned this row from "wait upstream" into "do it ourselves", but it cannot turn those two slots) |

**These four weaken from top to bottom, and must not be blurred together.** "Solvency is a structural
guarantee" is true on its own — but **stopping after that sentence** leaves the impression that revenue is
structurally protected too. It is not. A redirect strips no one's warrant of its collateral; it stops the tax
from reaching our vault **from that point forward**. The fourth layer differs in kind from the first three:
it protects no existing holder — it decides whether there is a **next project at all**. Today it is **open**,
and **whether it closes depends only on those two Flap config slots** (fourth row above).

> 🔴 **Correction, 2026-08-17**: this sentence used to read "and today it is closed". That was the state at
> #45 — back then the only known launch entry, `VaultPortal.newTokenV6WithVault`, was blocked. After
> decision 39 / #53 moved to the generic `Portal` and #57 shipped the orchestration layer, nothing on the
> contract side blocks a launch: mainnet reads `getQuoteTokenConfiguration(GME) = (1, 29, 29, 7, 0)` and
> `quoteTokenCreationDisabled(GME) = false` (re-checked 2026-08-17).

> The same discipline already applies once, to "fully collateralized", in [`design.md`](./design.md) §9.3:
> **that sentence must always appear in pairs.** This is the third instance of the same rule.

---

## Appendix: What This Document Does **Not** Verify

Stated plainly to avoid misleading anyone:

- **M1 contract behavior on mainnet** — implemented and tested, but not deployed to Robinhood Chain; [IMPLEMENTED] is not a mainnet measurement
- **Remaining production behavior** — the M4 replay/calculation/Proof API/publisher-handoff modules exist, and a persistent, resettable Proof Runtime is deployed for Core staging acceptance; no production Indexer or HTTP service is deployed, and `setRoot` still requires a human publisher signature. M3's #66 / #67 / #68 / #77 / #79 tooling exists, while #69's real-clock rehearsal and production configuration/drills remain. The #114 backend staging artifacts/runtime/fixtures are delivered, but Web App journeys, desktop/mobile, reorg/reset, and joint sign-off remain; the M5 order book and other operational controls remain planned. M2-0 through M2-6 and M4 through #96 are implemented and tested
- **No production project can launch on this chain today** — but the reason has changed: it is not waiting on Flap, code, or #18's version-0 legal text (counsel review and finalization are complete). What remains is deployment and operations. All three D0 tickets (#56 / #57 / #58) **have shipped**. The abandoned VaultPortal-with-vault entry point genuinely has no usable quote (#45, block 31,955,417 plus a 2026-08-16 mainnet re-check); the generic `Portal` entry point that D0 uses has been exercised end to end. [IMPLEMENTED] speaks to contracts and tests, **not** "ready to launch"
- **Every number in §8** — a worked example with assumptions, not real data
- **The exact semantics and final Robinhood Chain value of `antiFarmerDuration`** — 1 day is only a development / test placeholder; the 30-day value is a historical BSC MarsCoin observation and does not settle v1
- ~~Precision and semantics of `getTokenV8Safe().price` during the curve phase~~ — ✅ measured (2026-08-14; see [`research/flap-portal-price-semantics.md`](./research/flap-portal-price-semantics.md) and spec §14-6); what remains unverified is the post-graduation pool branch's target-chain positive control
- **Production reliability and cost of our Trigger Service / keeper** — scripts and offline/systemd regressions exist, but it is neither production-deployed nor production load-tested
- **Who holds the roles in Robinhood's access registry** — the registry does **not** implement `AccessControlEnumerable`, so roles cannot be enumerated; only `hasRole` against known addresses is possible
