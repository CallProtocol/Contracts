# AttestationRegistry version 0 texts for BSC (chain ID 56)

> **Status:** Finalized on 2026-09-10 when the maintainer removed the `[DRAFT]` marker. English is authoritative.

| File | keccak256 of the body without its single trailing LF |
|---|---|
| `terms.en.txt` | `0xe864e266e4d398abb519939899dc94ca6e80a4a8125de348e6eb0681b71b16b6` |
| `attestation.en.txt` | `0xe760c38dcca7cc6cb2e151e2c91521f89890ce053d6cbfd1f0319ff88045bd64` (identical to chain ID 4663) |

Recompute the BSC terms hash with:

```bash
cast keccak -- "$(cat legal/attestation-v0-bsc/terms.en.txt)"
```

These byte strings are immutable. `test_bscTextIsFinalized` pins them, and the BSC `versions[0]` record permanently identifies this version after deployment. The BSC and chain ID 4663 registries are independent instances and each has only one opportunity to establish version 0.

The byte rules, hash algorithm, and `VersionZero` rejection behavior are identical to those documented in [`../attestation-v0/README.md`](../attestation-v0/README.md). This file explains why BSC needs a separate terms text and identifies the substantive difference.

## Why BSC cannot reuse `legal/attestation-v0/`

Two independent reasons apply:

1. The chain ID 4663 hashes are already immutable. Its deployed `AttestationRegistry.versions[0]` cannot be updated.
2. The collateral issuers and retained powers differ. Chain ID 4663 uses Robinhood Stock, while BSC uses bStocks. A single text would either overstate one issuer's powers or understate the other's.

`script/VersionZero.sol` selects `legalDir()`, `termsPath()`, and `attestationPath()` by chain ID. `isMainnet()` recognizes both 4663 and 56.

## Differences from the chain ID 4663 version

### `attestation.en.txt`

The attestation is byte-for-byte identical. It describes the user rather than the collateral issuer, so both chains use the same text while storing the hash in separate registries.

### `terms.en.txt`

Only the final clause differs. The chain ID 4663 text says that the issuer may freeze transfers, pause the token, and burn holdings from any address, including the clearing pool.

The burn-from-any-address statement is not supported for bStocks. Probes performed on 2026-09-08 with a GMEB `ISSUER_ROLE` holder found that `burn(address,uint256)`, `burnFrom(address,uint256)`, `adminBurn(address,uint256)`, `forceTransfer`, and `seize` all failed against a third-party balance. Only self-burning through `burn(uint256)` succeeded.

This result is asset-specific. Ondo Global Markets tokens on BSC expose `burn(address,uint256)` and `burnFrom` behind `BURNER_ROLE`; those assets are outside the current target set. Their inclusion would require another legal and technical review.

The BSC terms instead disclose that the issuer may freeze transfers for any address, pause the token, and replace the implementation used by every token it issues in a single transaction, potentially introducing powers it does not hold today.

This wording reflects the shared beacon at `0x156d6dce9a4f6139a3406f1f021f1a4880de93a3`, which serves 26 bStocks. Replacing that beacon implementation can change all those tokens at once.

### Verified retained powers

| Disclosure | Observed behavior |
|---|---|
| Freeze transfers for any address | `compliance.addToBlocklist(GMEB, [addr])` makes transfers revert with `UserBlocked()`; `addToSanctionsList` makes them revert with `UserSanctioned()`. Both incoming and outgoing transfers are blocked. |
| Pause the token | `pauseManager.pauseToken(GMEB)` makes transfers revert with `TokenPaused()`. `pauseAllTokens()` provides a global emergency stop controlled by the pause manager's `OPS_ROLE`. |

## Additional verified facts

| Fact | Evidence summary |
|---|---|
| `identifier()` returns UAE ISIN values, including GMEB `AE000A4AVSM9` and SPCXB `AE000A4AVAW6`. | Probe performed 2026-09-08. |
| `ISSUER_ROLE` can call `mint(uint256)`, `burn(uint256)`, `setName`, `setSymbol`, and `setUIMultiplier`; GMEB had three role holders. | Role enumeration and call probes. |
| `mintEnabled()` and `burnEnabled()` were both `true`. | On-chain reads. |
| The compliance module `0x53dBa7Aa...14F4` and pause manager `0x9fc74Be6...700a` are shared by 26 bStocks and expose enumerable roles. | Cross-token configuration reads. |
| All four gating views remained readable under every tested freeze state. | Gating probe with `readable = true`. |

## Finalization checklist

- [x] `script/VersionZero.sol` selects the legal directory by chain ID.
- [x] Mainnet recognition includes both chain IDs 4663 and 56.
- [x] Both chains intentionally share the same `attestation.en.txt` bytes.
- [x] The draft marker was removed and both hashes were pinned on 2026-09-10.
- [x] `foundry.toml` grants read access to the full `./legal` directory.
- [ ] Counsel review of the replacement-implementation disclosure is tracked outside this repository; the maintainer finalized the repository text on 2026-09-10.

## BSC preflight remains separate

`script/preflight-mainnet.sh` is intentionally specific to Robinhood Chain (chain ID 4663). It derives the expected chain ID, pinned block, Portal address, endpoint, and `RPC_ROBINHOOD` configuration from Robinhood-specific constants, and it references `legal/attestation-v0/` directly.

Do not run that preflight for BSC. A BSC deployment requires a dedicated preflight port; that work is separate from finalizing these texts and must be completed before a BSC mainnet deployment.
