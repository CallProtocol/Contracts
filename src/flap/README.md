# Pinned Flap interfaces and base contracts

These Solidity files are byte-for-byte copies of `src/flap/` in
`flap-sh/FlapVaultExample` commit `5949cc7eb99bcb5ac5f679cc710ae456e627f12a`.
Do not edit or format them locally. `upstream.sha256` records their hashes.
`script/flap-vault-spec-check.sh --remote` also compares against that commit.

CallVault inherits VaultBaseV3; CallVaultFactory inherits
VaultFactoryBaseV2 and explicitly selects the full V6 `v2.1` hook. Generic
`onBeforeLaunch(bytes)` is deliberately not a creation authorization.

The checker under `.agents/skills/flap-vault-spec-checker` carries an older
`references/prelude/`: its base address tables omit Robinhood and the current
fallback addresses. Its factory prelude also lacks newer validation/discovery
interfaces. Use the same commit's `src/flap/` as the implementation baseline,
and report these differences rather than mixing the copies.

The current source differs from the prior `ddae5e0` pin in the fallback Portal,
VaultPortal and Guardian tables for other chains. BSC canonical addresses
remain the same. The Call deployment script supports only BSC chain 56.

The real BSC quote configuration includes enum values outside the vendored
ABI decoder's range. CallFactory reads its five raw words with a bounded
staticcall and checks only `enabled == 1`; it does not decode unrelated enums.
This does not change these official files.

`IFlapTaxTokenV3` uses upstream's `@openzeppelin/token/` import spelling;
`remappings.txt` maps it to the existing OpenZeppelin dependency. Rule004
upstream custom errors are retained verbatim and documented in the report.
