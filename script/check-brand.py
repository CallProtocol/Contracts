#!/usr/bin/env python3
"""Reject retired current branding while retaining explicit provenance boundaries."""
import argparse
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()
root = args.root
retired = [bytes.fromhex('6b65656c').decode()]
if (root / 'foundry.toml').exists():
    retired.append(bytes.fromhex('77617272616e74').decode())
historical = ('legal/', 'docs/evidence/legacy-deployments/', 'docs/archive/',
              'tests/integration/legacy-tests/', 'docs/superpowers/')
provenance = {'docs/migration/2026-10-06-' + retired[0] + '-rebrand.md'}
compatibility = {'entitlement/lib/canonical-ledger.js', 'entitlement/test/call-deployment.test.js',
                 'tests/integration/call-brand.test.mjs'}
paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
failures = []
for name in filter(None, paths):
    path = root / name
    if not path.is_file() or name.startswith(historical) or name in provenance:
        continue
    if any(brand in name.lower() for brand in retired):
        failures.append('Retired brand in path: ' + name)
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    for number, line in enumerate(text.splitlines(), 1):
        organization = bytes.fromhex('4b65656c50726f').decode()
        line = re.sub(r'https://github\.com/' + organization + r'/[^\s`\)\]"<>]+', '', line)
        if name in compatibility:
            token = retired[0]
            line = re.sub(r'deployment\.' + token + '|"' + token + '"|\x27' + token + '\x27|' + token + ':', '', line)
        if any(brand in line.lower() for brand in retired):
            failures.append(f'Retired brand in content: {name}:{number}')
if failures:
    raise SystemExit('\n'.join(failures))
print('Call naming policy verified')
