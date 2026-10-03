# Vault protocol fee verification

Verified on 2026-10-03 in the existing worktree. No mainnet broadcast,
migration, commit, or deployment promotion was performed.

## Economic behavior

For 100 raw units received, recognition reserves protocol 10 immediately.
Before successful processing, creator accrued is 0 and business funds are 90.
Full processing deposits 80 into the Pool and accrues creator 10, leaving
20 raw units backing the two reserves. Claiming the protocol fee before
processing produces the same final allocation.

Protocol recipient is immutable and equals Factory commissionReceiver.
Protocol accrued, claimed, and impaired values use collateral raw units;
native projects pay WBNB. Processor commission is separately disclosed.

## Final verification

| Command | Result |
| --- | --- |
| `bash script/flap-vault-spec-check.sh` | Pinned upstream hashes, build, production size gates and 433 non-fork tests pass; zero failures or skips |
| `forge test --match-path 'test/fork/FlapCustomVault*.t.sol' -vv` | 24 tests pass; zero failures or skips at BSC block 125316166 |
| `bash script/verify-deployment.test.sh` | 17 offline manifest/dependency/promotion tests pass |
| `forge test --match-test 'test_ping_staysFarUnderTheReceiveGasBudget\|testProductionVaultCallbacksSampleOpenAndDepositWithFeeTokenWithinBudget' -vv` | Receive and real Vault/Pool callback budgets pass |
| Targeted `forge fmt --check`, `bash -n`, `git diff --check` | Pass |

The non-fork suite includes 22 protocol fee tests, two schema tests,
19 Factory tests, four deployment tests, existing Vault/TWAP/Trigger tests,
and the Pool invariants. Protocol conservation fuzz runs 256 cases.
Coverage includes cumulative division remainder, claim order, idempotence,
6/8/18 decimals, BNB and direct WBNB, recipient tax, partial/zero debit,
unreadable balances, proportional permanent impairment, Guardian withdrawals,
reentrancy, and observable callback inflow rollback.

## Production bytecode limits

| Contract | Runtime bytes / 24576 | Initcode including static constructor arguments / 49152 |
| --- | --- | --- |
| WarrantVault | 24533 | 26545 |
| WarrantVaultFactory | 6743 | 37741 |
| WarrantVaultDeployer | 1586 | 29634 |

Vault runtime has only 43 bytes of remaining EIP-170 space. The size gate
must be rerun for any source change. The test-only Vault harness is larger
than EIP-170; production gates explicitly check the deployed stack.
The two STOP-prefixed data contracts hold at most 16000 payload bytes each.
Tests reconstruct the exact Vault creation code, verify hashes and fixed
dependencies, and check CREATE rollback and helper nonce 3 for its first Vault.
The broadcaster's Factory nonce prediction remains unchanged.

## Measured gas

| Path | Gas measured around the external call | Budget |
| --- | --- | --- |
| ERC20 receive recognition, local token | 80711 | 1000000 |
| Native receive recognition, fixed BSC fork | 65272 | 1000000 |
| Live BSC Trigger sample | 74187 | 2000000 |
| Live BSC Trigger series opening | 209746 | 2000000 |
| Live BSC Trigger Pool processing | 236344 | 2000000 |
| Local fee-token Pool processing callback | 256270 | 2000000 |

Real service request/fee state is exercised on the fork; callback delivery
impersonates the service to measure the receiver path. This does not verify
the backend's eventual transaction delivery or flap.sh integration.

## Decisions And Limits

- A protocol transfer debiting more than its reserve reverts atomically.
  Generic ERC20 transfers cannot predict sender-side surcharges; these tokens
  cannot claim with such behavior enabled without risking a subsidy from
  creator or business assets.
- Protocol claims reject callback quote pings and observable net quote inflow.
  Unpinged same-token inflow masked by an outgoing debit remains
  indistinguishable from partial debit through balance reads. Supported
  collateral must not create this ambiguous flow; the integration guide
  states this assumption for all net-debit accounting paths.
- Creator retains per-processing integer rounding. Protocol rounding carries
  across income recognition; its remainder is never a claimable reserve.
- Platform v2.1 discovery/schema/transaction assembly and acceptance of
  creator 10% + Vault protocol fee 10% + processor commission remain
  UNVERIFIED and block release. Promotion additionally requires the exact
  `feeAcceptanceScope` value `creator10+protocol10+processorCommission`.
