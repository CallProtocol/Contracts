# Versioned contract interfaces

`interfaces/abi/*.json` contains complete ABI arrays for Vault, Factory, Deployer,
TriggerAdapter, Registry, Pool, Call, Distributor, AttestationRegistry and the
official IVaultPortal. Consumers keep their own copy; production execution does
not read sibling Solidity source or Foundry output.

`interfaces/contract-metadata.json` schema version 1 records compiler 0.8.30,
Cancun, ABI SHA-256 digests and `keeperPolicy.constants`, `statusCodes`, and
`eventTopics`. Constants are evaluated from the Vault's integer declarations;
status codes comprise OPEN_* and TWAP_* states (excluding OPEN_WINDOW and
TWAP_SAMPLES). Event topics use canonical signatures from the compiled Vault ABI.

`sourceSnapshotHash` is SHA-256 of compact UTF-8 JSON (`sort_keys=True`, separators
`,` and `:`) for `sourceFiles`: a path-sorted array of objects with repository
relative `path` and byte-content `sha256`, covering every `src/**/*.sol` file.
It avoids a self-referential commit identity. Call's release record separately
pins the actual component commit, gitlink and interface metadata hash.

Run `forge build` followed by `python3 script/export-interfaces.py` to update the
package. Run the exporter with `--check` to detect drift. Commit the package with
the source change, update consuming snapshots, then update coordination gitlinks.

Deployment manifests are emitted by `DeploySystem.s.sol` and validated by
`script/verify-deployment.sh`. Their schema retains chain ID, addresses, fixed
commission/protocol receiver, Vault creation-code data addresses and hashes,
creation nonce and transitive dependencies. A planned manifest is not promoted
production evidence. EIP-170 and EIP-3860 size checks, complete dependency
validation, legal approval and platform fee acceptance remain release gates.

The root migration baseline can be verified without changing compiled output:
`python3 script/check-bytecode-baseline.py /path/to/bytecode-baseline.json`.
