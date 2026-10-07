#!/usr/bin/env python3
"""Compare compiled creation/runtime bytes with a frozen migration baseline."""
import hashlib
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit("Usage: script/check-bytecode-baseline.py <bytecode-baseline.json>")
for name, expected in json.loads(Path(sys.argv[1]).read_text()).items():
    artifact = json.loads((root / f"out/{name}.sol/{name}.json").read_text())
    for field, digest in expected.items():
        actual = hashlib.sha256(artifact[field]["object"].encode()).hexdigest()
        if actual != digest:
            raise SystemExit(f"Bytecode changed: {name}.{field}: {actual} != {digest}")
    print(f"{name}: creation and runtime match baseline")
