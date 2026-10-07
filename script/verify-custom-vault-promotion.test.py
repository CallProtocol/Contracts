#!/usr/bin/env python3
"""Exercise promotion gates through the verifier with an offline cast fixture."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

VERIFIER = Path(__file__).with_name("verify-deployment.sh").resolve()
CANONICAL = {
    "flapPortal": "0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0",
    "vaultPortal": "0x90497450f2a706f1951b5bdda52B4E5d16f34C06",
    "guardian": "0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b",
    "wbnb": "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
    "triggerService": "0xcf4EE25035CF883895110f367F5BA8172416a7F9",
}


class PromotionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "deployments").mkdir()
        self.manifest = {
            "chainId": 56, "factoryNonce": 5,
            "specCommit": "5949cc7eb99bcb5ac5f679cc710ae456e627f12a",
            "status": "planned", "platformV21Verified": True,
            "platformEvidence": "reviewed-platform-discovery-record",
            "feeAcceptanceVerified": False,
            "feeAcceptanceScope": "creator10+protocol10+processorCommission",
        }
        keys = ["vaultFactory", "vaultDeployer", "vaultRegistry", "clearingPool",
                "call", "merkleDistributor", "attestationRegistry", "triggerAdapter",
                "deployer", "commissionReceiver", "creationCodePart1", "creationCodePart2"]
        self.manifest.update({key: f"0x{i:040x}" for i, key in enumerate(keys, 1)})
        self.manifest.update(CANONICAL)
        self.manifest.update(protocolFeeReceiver=self.manifest["commissionReceiver"],
                             creationCodePart1Hash="0x"+"11"*32,
                             creationCodePart2Hash="0x"+"22"*32,
                             vaultCreationCodeHash="0x"+"33"*32)
        for contract, code in [("CallVault", "0x1122"), ("CallVaultFactory", "0x11")]:
            output = self.root / "out" / (contract+".sol")
            output.mkdir(parents=True)
            (output / (contract+".json")).write_text(json.dumps({"bytecode": {"object": code}}))
        self.path = self.root / "manifest.json"
        self.overrides = {}
        fake = self.root / "cast"
        fake.write_text(r'''#!/usr/bin/env python3
import json, os, sys
m=json.load(open(os.environ['FIXTURE_MANIFEST']))
a=sys.argv[1:]
with open(os.environ['FIXTURE_LOG'], 'a') as log: log.write(json.dumps(a)+'\n')
if a[0]=='chain-id': print(os.environ.get('FIXTURE_CHAIN', '56'))
elif a[0]=='block-number': print(123)
elif a[0]=='code':
    if a[1]==os.environ.get('FIXTURE_NO_CODE'): print('0x')
    elif a[1]==os.environ.get('FIXTURE_OVERSIZE'): print('0x'+'00'*24577)
    elif a[1]==m['creationCodePart1']: print(os.environ.get('FIXTURE_PART1', '0x0011'))
    elif a[1]==m['creationCodePart2']: print('0x0022')
    else: print('0x00')
elif a[0]=='keccak':
    hashes={'0x0011':m['creationCodePart1Hash'],'0x0022':m['creationCodePart2Hash'],
            '0x1122':m['vaultCreationCodeHash']}
    print(hashes.get(a[1], '0x'+'ff'*32))
elif a[0]=='compute-address': print(os.environ.get('FIXTURE_PREDICTION', m['vaultFactory']))
elif a[0]=='call':
    getter=a[2].split('(')[0]
    if getter==os.environ.get('FIXTURE_BAD_GETTER'): print('0x'+'ff'*20)
    elif getter=='factorySpecVersion': print('v2.1')
    elif getter=='isFactory': print('false')
    else:
        aliases={'factory':'vaultFactory','registry':'vaultRegistry','pool':'clearingPool',
                 'portal':'flapPortal','distributor':'merkleDistributor','attestations':'attestationRegistry'}
        print(m[aliases.get(getter,getter)])
else: sys.exit(70)
''')
        fake.chmod(0o755)

    def verify(self):
        self.path.write_text(json.dumps(self.manifest))
        env = dict(os.environ, FIXTURE_MANIFEST=str(self.path),
                   FIXTURE_LOG=str(self.root / "calls.jsonl"),
                   PATH=str(self.root) + os.pathsep + os.environ["PATH"])
        env.update(self.overrides)
        return subprocess.run([str(VERIFIER), "--manifest", str(self.path), "--promote",
                               "--source-commit", "fixture-source-commit"],
                              cwd=self.root, env=env, text=True, capture_output=True)

    def blocked(self, reason):
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(reason, result.stderr)
        self.assertFalse((self.root / "deployments/56.json").exists())

    def test_platform_evidence_cannot_replace_fee_acceptance(self):
        self.blocked("acceptance of creator 10%, Vault protocol fee 10% and processor commission")

    def test_old_fee_acceptance_scope_cannot_promote(self):
        self.manifest.update(feeAcceptanceVerified=True, feeAcceptanceEvidence="reviewed-old-fees")
        self.manifest["feeAcceptanceScope"] = "creator10+processorCommission"
        self.blocked("Vault protocol fee 10%")

    def test_fee_flag_requires_separate_evidence(self):
        self.manifest["feeAcceptanceVerified"] = True
        self.blocked("acceptance of creator 10%, Vault protocol fee 10% and processor commission")

    def test_fee_evidence_requires_boolean_confirmation(self):
        self.manifest["feeAcceptanceEvidence"] = "reviewed-fee-record"
        self.manifest["feeAcceptanceVerified"] = "false"
        self.blocked("acceptance of creator 10%, Vault protocol fee 10% and processor commission")

    def test_fee_acceptance_cannot_replace_platform_evidence(self):
        self.manifest.update(feeAcceptanceVerified=True, feeAcceptanceEvidence="reviewed-fee-record")
        self.manifest.pop("platformEvidence")
        self.blocked("discovery/schema/V6 evidence")

    def test_platform_flag_requires_boolean_confirmation(self):
        self.manifest["platformV21Verified"] = "false"
        self.blocked("discovery/schema/V6 evidence")

    def test_wrong_chain_is_rejected_before_manifest_read(self):
        self.overrides["FIXTURE_CHAIN"] = "97"
        self.blocked("Only BSC mainnet")

    def test_canonical_portal_mismatch_is_rejected(self):
        self.manifest["vaultPortal"] = self.manifest["deployer"]
        self.blocked("Dependency mismatch: vaultPortal")

    def test_missing_helper_code_is_rejected(self):
        self.overrides["FIXTURE_NO_CODE"] = self.manifest["vaultDeployer"]
        self.blocked("Missing code: vaultDeployer")

    def test_helper_size_limit_is_enforced(self):
        self.overrides["FIXTURE_OVERSIZE"] = self.manifest["vaultDeployer"]
        self.blocked("EIP170 exceeded: vaultDeployer")

    def test_factory_prediction_mismatch_is_rejected(self):
        self.overrides["FIXTURE_PREDICTION"] = self.manifest["deployer"]
        self.blocked("factory CREATE nonce")

    def test_dependency_mismatch_cannot_overwrite_promoted_manifest(self):
        promoted = self.root / "deployments/56.json"
        promoted.write_text("existing verified evidence\n")
        self.overrides["FIXTURE_BAD_GETTER"] = "registry"
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vaultFactory.registry", result.stderr)
        self.assertEqual(promoted.read_text(), "existing verified evidence\n")

    def test_data_prefix_is_enforced(self):
        self.overrides["FIXTURE_PART1"] = "0x0111"
        self.blocked("Invalid STOP-prefixed creation code data")

    def test_data_hash_mismatch_is_rejected(self):
        self.overrides["FIXTURE_PART1"] = "0x0044"
        self.blocked("creationCodePart1 content hash")

    def test_fixed_protocol_receiver_cannot_differ_from_commission_receiver(self):
        self.manifest["protocolFeeReceiver"] = self.manifest["deployer"]
        self.blocked("fixed protocol receiver")

    def test_local_creation_code_mismatch_is_rejected(self):
        artifact = self.root / "out/CallVault.sol/CallVault.json"
        artifact.write_text(json.dumps({"bytecode": {"object": "0x1123"}}))
        self.blocked("local Vault creation code")

    def test_both_independent_gates_allow_promotion(self):
        self.manifest.update(feeAcceptanceVerified=True, feeAcceptanceEvidence="reviewed-fee-record")
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        promoted = json.loads((self.root / "deployments/56.json").read_text())
        self.assertEqual(promoted["status"], "verified")
        self.assertEqual(promoted["feeAcceptanceEvidence"], "reviewed-fee-record")
        self.assertEqual(promoted["sourceCommit"], "fixture-source-commit")
        self.assertEqual(promoted["verifiedAtBlock"], 123)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(sum(args[0] == "block-number" for args in calls), 1)
        reads = [args for args in calls if args[0] in ("call", "code")]
        self.assertTrue(reads)
        for args in reads:
            self.assertEqual(args[-2:], ["--block", "123"])


if __name__ == "__main__":
    unittest.main()
