#!/usr/bin/env bash
# Reproducible local checks. Platform UI compatibility is a separate release gate.
set -euo pipefail
remote=false
fork=false
for arg in "$@"; do
  case "$arg" in
    --remote) remote=true ;;
    --fork) fork=true ;;
    *) echo 'Usage: script/flap-vault-spec-check.sh [--remote] [--fork]' >&2; exit 2 ;;
  esac
done
shasum -a 256 -c src/flap/upstream.sha256
if "$remote"; then
  python3 - <<'PY'
from pathlib import Path
from urllib.request import urlopen
from concurrent.futures import ThreadPoolExecutor
pin='5949cc7eb99bcb5ac5f679cc710ae456e627f12a'
paths=list(Path('src/flap').glob('*.sol'))
def check(path):
    url=f'https://raw.githubusercontent.com/flap-sh/FlapVaultExample/{pin}/{path}'
    with urlopen(url, timeout=30) as response: data=response.read()
    if path.read_bytes()!=data: raise RuntimeError('Upstream mismatch: '+str(path))
with ThreadPoolExecutor(max_workers=4) as executor: list(executor.map(check,paths))
print('Pinned src/flap sources match upstream byte-for-byte')
PY
fi
forge build
python3 - <<'PY'
from pathlib import Path
import json
for name in ['WarrantVault','WarrantVaultFactory','WarrantVaultDeployer','WarrantTriggerAdapter','VaultRegistry','ClearingPool']:
    artifact=json.loads(Path(f'out/{name}.sol/{name}.json').read_text())
    size=(len(artifact['deployedBytecode']['object'])-2)//2
    assert size<=24576, f'{name}: EIP170 exceeded: {size}'
    print(f'{name}: runtime {size} / 24576 bytes')
    constructor=next((entry for entry in artifact['abi'] if entry['type']=='constructor'), {'inputs':[]})
    init_size=(len(artifact['bytecode']['object'])-2)//2 + 32*len(constructor['inputs'])
    assert init_size<=49152, f'{name}: EIP3860 exceeded: {init_size}'
    print(f'{name}: initcode with arguments {init_size} / 49152 bytes')
PY
forge test --no-match-path 'test/fork/**'
if "$fork"; then
  : "${RPC_BSC:?Configure RPC_BSC for the fixed-block release gate}"
  forge test --match-contract 'FlapCustomVault(CapabilitiesTest|ForkTest|DeploymentForkTest)'
fi
cat <<'REPORT'
Rule001: inheritance, Guardian access and immutable architecture tested.
Rule002: Factory v2.1 full-hook enforcement tested; fee acceptance WARNING (platform approval outstanding).
Rule003: fixed strategy and destinations tested; Guardian emergency custody authority disclosed.
Rule004: user-owned Vault/Factory/Adapter errors bilingual; upstream base/OZ errors retained WARNING.
Rule005: bounded receive recognition and hostile-balance gas tests passed.
Rule006: every exposed user method traversed against schema/ABI; critical unit flows passed.
Rule007: N/A (no AI oracle).
Rule008: sender/action/request/replay/fee/lifecycle and bounded callback gas tested.
Rule009: Guardian full withdrawals, no owner/auto-forward, and permanent impairment tested.
Rule010: raw-unit/native/ERC20 deltas, actual debit/receipt and outflow reconciliation tested.
RELEASE BLOCKER: flap.sh v2.1 discovery/schema/transaction assembly remains UNVERIFIED.
RELEASE BLOCKER: creator10% plus Vault protocol10% plus processor commission acceptance remains UNVERIFIED.
REPORT
if ! "$fork"; then
  echo 'Real BSC protocol/deployment evidence not executed in this run; use --fork. No protocol PASS inferred.'
fi
