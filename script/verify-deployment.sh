#!/usr/bin/env bash
# Read-only dependency verification; promotion requires platform and fee evidence.
set -euo pipefail
python3 - "$@" <<'PY'
import argparse, json, os, subprocess, pathlib
p = argparse.ArgumentParser()
p.add_argument('--rpc-url')
p.add_argument('--manifest')
p.add_argument('--promote', action='store_true')
p.add_argument('--source-commit')
a = p.parse_args()
env = os.environ.copy()
if a.rpc_url: env['ETH_RPC_URL'] = a.rpc_url

def cast(*args):
    result = subprocess.run(['cast', *args], env=env, text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('On-chain read failed: ' + args[0])
    return result.stdout.strip().strip('"')

def equal(actual, expected, name):
    if str(actual).lower() != str(expected).lower():
        raise SystemExit('Dependency mismatch: ' + name)

chain = int(cast('chain-id'))
if chain != 56: raise SystemExit('Only BSC mainnet is validated for this deployment stack')
verified_block = int(cast('block-number'))

def read(*args):
    return cast(*args, '--block', str(verified_block))

path = pathlib.Path(a.manifest or f'deployments/{chain}.planned.json')
m = json.loads(path.read_text())
equal(chain, m['chainId'], 'chainId')
equal(m['specCommit'], '5949cc7eb99bcb5ac5f679cc710ae456e627f12a', 'spec commit')
canonical = {
    'flapPortal': '0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0',
    'vaultPortal': '0x90497450f2a706f1951b5bdda52B4E5d16f34C06',
    'guardian': '0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b',
    'wbnb': '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    'triggerService': '0xcf4EE25035CF883895110f367F5BA8172416a7F9',
}
for key, address in canonical.items(): equal(m[key], address, key)
contracts = ['vaultFactory', 'vaultDeployer', 'vaultRegistry', 'clearingPool', 'warrant',
             'merkleDistributor', 'attestationRegistry', 'triggerAdapter',
             'creationCodePart1', 'creationCodePart2', *canonical]
for key in contracts:
    code = read('code', m[key])
    if code == '0x': raise SystemExit('Missing code: ' + key)
    if key not in canonical and (len(code)-2)//2 > 24576:
        raise SystemExit('EIP170 exceeded: ' + key)

predicted = cast('compute-address', m['deployer'], '--nonce', str(m['factoryNonce']))
# cast versions may label the computed address.
equal(predicted.split()[-1], m['vaultFactory'], 'factory CREATE nonce')
links = {
    'vaultFactory': {'registry': 'vaultRegistry', 'pool': 'clearingPool',
                     'merkleDistributor': 'merkleDistributor', 'portal': 'flapPortal',
                     'vaultPortal': 'vaultPortal', 'wbnb': 'wbnb',
                     'commissionReceiver': 'commissionReceiver', 'vaultDeployer': 'vaultDeployer'},
    'vaultDeployer': {'factory': 'vaultFactory', 'pool': 'clearingPool',
                      'merkleDistributor': 'merkleDistributor', 'portal': 'flapPortal', 'wbnb': 'wbnb',
                      'protocolFeeReceiver': 'protocolFeeReceiver',
                      'creationCodePart1': 'creationCodePart1', 'creationCodePart2': 'creationCodePart2'},
    'vaultRegistry': {'factory': 'vaultFactory'},
    'clearingPool': {'warrant': 'warrant', 'distributor': 'merkleDistributor',
                     'attestations': 'attestationRegistry', 'vaultRegistry': 'vaultRegistry'},
    'warrant': {'pool': 'clearingPool'},
    'merkleDistributor': {'pool': 'clearingPool'},
    'triggerAdapter': {'factory': 'vaultFactory', 'triggerService': 'triggerService'},
}
for key, targets in links.items():
    for getter, target in targets.items():
        equal(read('call', m[key], getter+'()(address)'), m[target], key+'.'+getter)
equal(m['protocolFeeReceiver'], m['commissionReceiver'], 'fixed protocol receiver')
if int(m['protocolFeeReceiver'], 16) == 0: raise SystemExit('Zero protocol receiver')
parts = []
for key in ['creationCodePart1', 'creationCodePart2']:
    code = read('code', m[key])
    if not code.startswith('0x00') or (len(code)-2)//2 > 16001:
        raise SystemExit('Invalid STOP-prefixed creation code data: ' + key)
    equal(cast('keccak', code), m[key+'Hash'], key+' content hash')
    parts.append(code[4:])
creation = '0x' + ''.join(parts)
equal(cast('keccak', creation), m['vaultCreationCodeHash'], 'Vault creation code content')
equal(read('call', m['vaultDeployer'], 'vaultCreationCodeHash()(bytes32)'),
      m['vaultCreationCodeHash'], 'immutable Vault creation code hash')
if (len(creation)-2)//2 + 8*32 > 49152: raise SystemExit('Vault EIP3860 exceeded')
# Compare data against the pinned local build, not only a self-consistent manifest.
artifact = json.loads(pathlib.Path('out/WarrantVault.sol/WarrantVault.json').read_text())
equal(creation, artifact['bytecode']['object'], 'local Vault creation code')
factory_artifact = json.loads(pathlib.Path('out/WarrantVaultFactory.sol/WarrantVaultFactory.json').read_text())
if (len(factory_artifact['bytecode']['object'])-2)//2 + 6*32 > 49152:
    raise SystemExit('Factory EIP3860 exceeded')
equal(read('call', m['vaultFactory'], 'factorySpecVersion()(string)'), 'v2.1', 'factory version')
equal(read('call', m['vaultRegistry'], 'isFactory(address)(bool)', m['deployer']), 'false', 'single writer')
print('Verified canonical addresses, code sizes, CREATE nonce and immutable dependencies')
if a.promote:
    if m.get('platformV21Verified') is not True or not m.get('platformEvidence'):
        raise SystemExit('Promotion blocked: flap.sh v2.1 discovery/schema/V6 evidence is not recorded')
    if (m.get('feeAcceptanceVerified') is not True or not m.get('feeAcceptanceEvidence')
            or m.get('feeAcceptanceScope') != 'creator10+protocol10+processorCommission'):
        raise SystemExit('Promotion blocked: platform acceptance of creator 10%, Vault protocol fee 10% and processor commission is not recorded')
    if not a.source_commit: raise SystemExit('Promotion requires --source-commit')
    m['status'] = 'verified'
    m['sourceCommit'] = a.source_commit
    m['verifiedAtBlock'] = verified_block
    target = pathlib.Path(f'deployments/{chain}.json')
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', dir=target.parent, delete=False) as output:
        temporary = pathlib.Path(output.name)
        try:
            output.write(json.dumps(m, indent=2)+'\n')
            output.close()
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
    print('Promoted ' + str(target))
PY
