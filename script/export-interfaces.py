#!/usr/bin/env python3
"""Publish reproducible ABI and keeper policy snapshots without sibling repos."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = ["CallVault", "CallVaultFactory", "CallVaultDeployer", "VaultRegistry",
         "CallTriggerAdapter", "ClearingPool", "Call", "MerkleDistributor",
         "IVaultPortal", "AttestationRegistry"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def render(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def snapshots():
    source_files = [{"path": str(p.relative_to(ROOT)), "sha256": sha(p.read_bytes())}
                    for p in sorted((ROOT / "src").rglob("*.sol"))]
    source_hash = sha(json.dumps(source_files, separators=(",", ":"), sort_keys=True).encode())
    source = (ROOT / "src/CallVault.sol").read_text()
    constants = {}
    # Resolve Solidity integer constants in declaration order, including time units.
    for name, expression in re.findall(r"uint(?:256|64)\s+(?:internal|public|private)\s+constant\s+(\w+)\s*=\s*([^;]+);", source):
        expression = expression.replace("_", "") if re.fullmatch(r"[\d_]+", expression) else expression
        for unit, seconds in [("minutes", 60), ("hours", 3600), ("days", 86400)]:
            expression = re.sub(rf"(\d+)\s+{unit}\b", lambda m: str(int(m[1]) * seconds), expression)
        for symbol, value in constants.items():
            expression = re.sub(rf"\b{symbol}\b", str(value), expression)
        if not re.fullmatch(r"[\d\s+*()/-]+", expression):
            raise ValueError(f"Cannot resolve integer constant {name}: {expression}")
        constants[name] = int(eval(expression, {"__builtins__": {}}, {}))
    result, abi_hashes, topics = {}, {}, {}
    for name in NAMES:
        artifact = json.loads((ROOT / f"out/{name}.sol/{name}.json").read_text())
        data = render(artifact["abi"])
        filename = f"abi/{name}.json"
        result[filename] = data
        abi_hashes[filename] = sha(data)
        if name == "CallVault":
            for event in artifact["abi"]:
                if event["type"] == "event":
                    signature = event["name"] + "(" + ",".join(i["type"] for i in event["inputs"]) + ")"
                    topics[event["name"]] = subprocess.check_output(["cast", "keccak", signature], text=True).strip()
    metadata = {"schemaVersion": 1, "sourceSnapshotHash": source_hash,
                "sourceFiles": source_files, "compiler": "0.8.30", "evmVersion": "cancun",
                "abiSha256": abi_hashes,
                "keeperPolicy": {"constants": {k: v for k, v in constants.items() if not (k.startswith(("OPEN_", "TWAP_")) and k not in ("TWAP_SAMPLES", "OPEN_WINDOW"))},
                                 "statusCodes": {k: v for k, v in constants.items() if k.startswith(("OPEN_", "TWAP_")) and k not in ("TWAP_SAMPLES", "OPEN_WINDOW")},
                                 "eventTopics": topics}}
    result["contract-metadata.json"] = render(metadata)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if exported snapshots drift")
    args = parser.parse_args()
    for filename, data in snapshots().items():
        target = ROOT / "interfaces" / filename
        if args.check:
            if not target.exists() or target.read_bytes() != data:
                raise SystemExit(f"Interface snapshot differs: {filename}; run script/export-interfaces.py")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    print("Interface snapshots verified" if args.check else "Interface snapshots exported")


if __name__ == "__main__":
    main()
