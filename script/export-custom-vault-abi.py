#!/usr/bin/env python3
"""Export canonical interfaces and documentation ABIs for VaultPortal integration."""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "script/export-interfaces.py")], check=True)
names = ["CallVault", "CallVaultFactory", "CallVaultDeployer", "VaultRegistry",
         "CallTriggerAdapter", "ClearingPool", "Call", "MerkleDistributor", "IVaultPortal"]
target = root / "docs/abi"
target.mkdir(parents=True, exist_ok=True)
for name in names:
    artifact = json.loads((root / f"out/{name}.sol/{name}.json").read_text())
    (target / f"{name}.json").write_text(json.dumps(artifact["abi"], indent=2) + "\n")
