# Contracts component

## Mandatory Call naming policy

- Use Call for all project branding, contract symbols, interfaces, filenames,
  deployment keys, runtime descriptions and documentation.
- Do not reintroduce legacy brand identifiers or compatibility aliases.
- Run `python3 script/check-brand.py` before committing or publishing.

- Default branch and pull request base: `main`.
- This repository owns Solidity business logic, Foundry tests, legal originals,
  deployment scripts, ABI exports and deployment evidence.
- Keep keeper, proof, indexer and cross-component rehearsal in their component or
  Call coordination repositories.
- Preserve the validated behavior of `src/flap/`, the legal meaning of `legal/`,
  and the pinned compiler and libraries while enforcing the English-only policy.
- Run `script/ci.sh --offline` and required fixed BSC fork gates before release.
  Missing RPC is an unexecuted gate, never a passing result.
- Regenerate `interfaces/` after API or keeper policy changes and coordinate the
  consuming snapshots and root gitlinks. No secrets, runtime state or generated
  Foundry artifacts belong in commits. Do not broadcast mainnet as migration.

## Mandatory CodeGraph workflow

- If `.codegraph/` is absent, run `codegraph init .` before exploring the repository.
- Use `codegraph explore "describe the code area or symbol to inspect"` before grep, file discovery, or direct file reads when locating or understanding code.
- Use `codegraph node AGENTS.md` for focused source and dependency context, replacing `AGENTS.md` with the relevant symbol or file.
- Run `codegraph sync .` after source or documentation changes so the index remains current.
- Use `rg` or direct file reads only when CodeGraph cannot answer the query or when an exact literal or regular-expression search is specifically required.

## Mandatory English-only policy

- Write all documentation, source comments, user-facing repository text, and Git commit messages in English.
- Commit only English textual content. This applies to current, historical, archived, migration, provenance, and legal files without exception.
- Translate non-English text before committing it. Preserve protocol behavior and legal meaning during translation.
