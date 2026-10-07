# Call Contracts

Immutable Call protocol contracts and their chain business rules. The Call
coordination repository pins this component alongside Offchain and Indexer; keeper,
proof services and subgraph code live in those independent repositories.

## Reproduce

Install Foundry, Python 3 and Git, then initialize the pinned dependencies:

```sh
git submodule update --init --recursive
forge build src --sizes
script/ci.sh --offline
RPC_BSC='<archive endpoint>' script/ci.sh fork
```

Frozen migration sources have existing `forge fmt --check` differences, including
`src/ClearingPool.sol` and `test/fork/ForkConfigBsc.sol`. Default and offline gates
continue reporting those failures. Standalone CI verifies behavior and interfaces
while retaining the frozen source bytes.

Solidity is fixed to 0.8.30, Cancun, optimizer 200 runs, and no metadata bytecode
hash. Do not upgrade compiler or dependencies as part of repository migration.
`script/ci.sh --list` lists the component gates. The optional `fork-robinhood`
gate retains the historical fixed-chain regression suite. Missing RPC dependencies
fail fork gates; offline success does not claim real chain compatibility.

## Interfaces and deployment

`python3 script/export-interfaces.py` exports the compiled ABI package and keeper
policy; `--check` verifies the committed package without writing files. Consumers
copy `interfaces/` into their own repository and pin its source snapshot hash.
See [interface contract](docs/interfaces.md) for exact provenance and update rules.
Deployment scripts and read-only validation remain under `script/` and manifests
under `deployments/`. Running a build or test never authorizes a mainnet broadcast.

Protocol income reserves a fixed 10% fee payable to the immutable protocol fee
receiver. After complete processing, every 100 raw collateral units allocate 10
to protocol, 10 to creator and 80 to Pool. Claiming is permissionless and cannot
change the destination. The [business specification](docs/spec.md) describes
rounding, loss impairment, raw-unit accounting and deployment gates.

Platform v2.1 compatibility and acceptance of creator 10% plus protocol 10% plus
processor commission remain independent release blockers. Migration does not
satisfy or relax either gate. Legal source bytes in `legal/` and official Flap
source bytes in `src/flap/` must remain unchanged.

All component pull requests target `main`. Coordinate a new component revision
with an explicit gitlink update in Call after independent validation.
