# BSC custom vault capability evidence

Spec commit: `5949cc7eb99bcb5ac5f679cc710ae456e627f12a`.
Fixed block: **125316166**, chainId **56**. No latest fallback and no skips.
VaultPortal: `0x90497450f2a706f1951b5bdda52B4E5d16f34C06`.
ERC1967 implementation at this block: `0x111C157a0Ed15a36797f4455e988254d1Ee93284`.
Portal: `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0`.
Guardian: `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`.

| Capability | Evidence | Result |
| --- | --- | --- |
| v2.1 full V6 hook called with unaltered complete params | Probe hashes abi.encode(params), exactly one writable hook invocation | PASS |
| Ordinary-storage authorization can be consumed by creation callback | Actual CALL writes; callback consumes quote/data hash | PASS |
| Rejections honored; wrong 100-year tax duration blocked | Exact rejection strings asserted; no callback state | PASS |
| Callback Token address is predictive and lacks code | Control checks code size0 at callback, deployed code after creation | PASS |
| Native and enabled ERC20 quote supported for v2.1 | Native and GMEB (`0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C`) launches | PASS |
| Other Token version/legacy entry bypass prevented | V5 and newTaxTokenWithVault cannot create through authorized probe | PASS for tested entries |
| Token creation failure atomicity | Excessive antiFarmerDuration fails after Vault CREATE; all callback/hook state and code roll back | PASS |
| First-buy failure atomicity | Real ERC20 insufficient allowance after production Factory callback; Registry/Vault/helper CREATE state roll back | PASS |
| Production Token/processor settings | Buy/sell300, processor market10000/others0, marketAddress=bound Vault, commission receiver | PASS |
| Real tax reaches Pool | Native0.1BNB and ERC20 10GMEB first buys, real processor.dispatch, TWAP, actual collateral mint | PASS |
| Official Trigger request fee and live receiver gas | Real service getFee/getRequest/getMaxCallbackGas; callback sender impersonated, backend delivery not tested | PASS for on-chain requester/receiver paths only |
| flap.sh factory discovery, schema rendering and V6 transaction assembly | Requires a published/staged factory and actual platform flow; not performed | UNVERIFIED / RELEASE BLOCKER |
| Platform approval of creator10% + Vault protocol fee10% + processor commission | No platform acceptance evidence | UNVERIFIED |

The Portal first probes the full hook with a STATICCALL using dummy params
(empty strings/data, zero economic fields, tokenVersion6, factory=this).
The factory must reject that probe before writing storage. The actual full
payload follows via CALL and can write ordinary storage.

The current Portal quote configuration returns five words including curve29
and swap type7 for GMEB. Decoding the vendored enum can revert locally even
when the protocol read succeeds. The Factory bounds the staticcall, requires
exactly160 bytes and validates only the enabled flag; irrelevant future enum
values do not disable supported quotes.

The actual checker prelude is older than its same-commit src/flap, notably
address tables and factory validation/discovery interfaces. Source copies
are pinned to src/flap; prelude differences are not treated as our code defects.

Reproduction (keep private endpoint out of argv and logs):

```sh
set -a
source ./.env
set +a
forge test --match-contract FlapCustomVaultCapabilitiesTest -vvvv
forge test --match-contract FlapCustomVaultForkTest -vvvv
```

Set FLAP_CAPABILITY_BLOCK to explicitly test another fixed snapshot; this
report certifies only125316166. Every release must rerun against its chosen
block and record Portal implementation changes. The complete local traces
are copied under `docs/evidence/flap-custom-vault/` with RPC credentials removed.
