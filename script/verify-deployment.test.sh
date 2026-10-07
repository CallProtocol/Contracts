#!/usr/bin/env bash
# Stable CI entry for the Custom Vault verifier's offline regression suite.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 script/verify-custom-vault-promotion.test.py
