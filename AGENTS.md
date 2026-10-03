# Contracts component

- Default branch and pull request base: `main`.
- This repository owns Solidity business logic, Foundry tests, legal originals,
  deployment scripts, ABI exports and deployment evidence.
- Keep keeper, proof, indexer and cross-component rehearsal in their component or
  WarrantPro coordination repositories.
- Preserve `src/flap/` and `legal/` bytes. Keep pinned compiler and libraries.
- Run `script/ci.sh --offline` and required fixed BSC fork gates before release.
  Missing RPC is an unexecuted gate, never a passing result.
- Regenerate `interfaces/` after API or keeper policy changes and coordinate the
  consuming snapshots and root gitlinks. No secrets, runtime state or generated
  Foundry artifacts belong in commits. Do not broadcast mainnet as migration.
