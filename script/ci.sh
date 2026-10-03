#!/usr/bin/env bash
# Contracts-only gates. Cross-component rehearsal belongs to WarrantPro.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${HOME}/.foundry/bin:${PATH}"
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"
groups=(fmt build unit deploy spec interfaces fork)
if [[ "${1:-}" == --list ]]; then printf '%s\n' "${groups[@]}"; exit 0; fi
if [[ "${1:-}" == --offline ]]; then groups=(fmt build unit deploy spec interfaces)
elif (( $# )); then groups=("$@"); fi
for group in "${groups[@]}"; do
  case "$group" in
    fmt) forge fmt --check ;;
    build) forge build --sizes ;;
    unit)
      forge test --no-match-path 'test/fork/*' -vv
      forge test --match-path 'test/fork/ForkConfigBsc.t.sol' -vv ;;
    deploy)
      bash script/verify-deployment.test.sh
      forge test --match-contract DeploySystemTest -vv ;;
    spec) bash script/flap-vault-spec-check.sh ;;
    interfaces) python3 script/export-interfaces.py --check ;;
    fork)
      : "${RPC_BSC:?RPC_BSC is required; missing archive RPC must not pass the gate}"
      FORK_STRICT_BLOCK=true FORK_REQUIRED=true forge test \
        --match-contract 'FlapCustomVault(CapabilitiesTest|ForkTest|DeploymentForkTest)' -vv ;;
    fork-robinhood)
      FORK_STRICT_BLOCK=true FORK_REQUIRED=true forge test --match-path 'test/fork/Robinhood*.t.sol' -vv
      forge test --match-path 'test/fork/ForkSelection.t.sol' -vv ;;
    *) printf 'Unknown contracts gate: %s\n' "$group" >&2; exit 2 ;;
  esac
done
