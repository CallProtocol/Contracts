# AttestationRegistry version 0 texts

The two `.txt` files in this directory are deployment inputs and the canonical off-chain legal texts. The deployment script hashes each body with keccak256 and stores both hashes in `AttestationRegistry.versions[0]`; the contract does not store the text itself.

Once deployed, the hashes are permanent and cannot be replaced. This immutability is the basis of invariant 6(3). Changing any byte changes the pending deployment hash and therefore changes the legal text users are expected to read and verify.

| File | Registry field | Subject |
|---|---|---|
| `terms.en.txt` | `versions[0].termsHash` | The exercise-right token instrument |
| `attestation.en.txt` | `versions[0].attestationHash` | The signing user |

## Byte specification

Each file must contain exactly one line of UTF-8 text followed by exactly one LF. The text is plain text, not Markdown.

The registry hash is calculated from the body after removing that single trailing LF:

```text
hash = keccak256(bytes(file contents without the single trailing LF))
```

Recompute the hashes with:

```bash
cast keccak -- "$(cat legal/attestation-v0/terms.en.txt)"
cast keccak -- "$(cat legal/attestation-v0/attestation.en.txt)"
```

These commands must produce the same values used by the deployment. CI executes this calculation and compares it with the values produced by the Foundry-side checks. A Solidity assertion alone cannot validate the external command because FFI is intentionally disabled.

### Inputs rejected by `script/VersionZero.sol`

Nonconforming input is rejected rather than normalized. Deployment fails immediately and never changes the supplied text silently.

| Rejected input | Reason |
|---|---|
| No trailing LF or more than one trailing LF | The hash must map one-to-one to the file bytes. Command substitution removes all trailing newlines, so this rule is not merely for command-line recomputation. |
| A `\r` in the body | A CRLF file would recompute differently from the on-chain value. |
| Any control character below `0x20`, or `0x7f`, in the body | Such bytes can enter a hash but cannot be passed reliably through shells. NUL is particularly unsafe because shells drop or truncate it differently. |
| A UTF-8 BOM | Invisible BOM bytes would enter the hash even though reviewers see the same apparent text. |
| A body beginning with `-` | `cast keccak` can interpret values such as `--json` as options and silently hash an empty value. |
| A body beginning with `0x` | `cast keccak` decodes a hexadecimal argument before hashing it; `--` does not prevent this behavior. |
| An empty body | Version 0 must contain an explicit legal text. |

Rejecting invalid input is deliberate. Earlier normalization removed arbitrary trailing `\n` and `\r` bytes, which could make LF and CRLF files resolve to the same pinned hash while the documented recomputation command produced a different value. That would disconnect the reviewed text from the deployed artifact at an irreversible step.

### End-of-line defenses

| Defense | Protects against | Does not protect against |
|---|---|---|
| `.gitattributes` with `-text` | Git checkout-time line-ending conversion | Someone committing a file saved directly with CRLF |
| `test_textFilesAreExactlyOneLine` | Incorrect files already present in the repository | A dirty deployment worktree |
| Deployment-time validation | All cases listed above | None |

The first two defenses can be bypassed. The deployment script therefore enforces every byte rule in `canonicalize` at the irreversible boundary.

## Finalized status

Version 0 was finalized on 2026-08-26 under issue #18. The files no longer contain the draft marker. `test_shippedTextIsFinalized` pins the hashes below, so changing either file makes the test fail. Wording changes require a new version; version 0 remains immutable.

| File | Final hash |
|---|---|
| `terms.en.txt` | `0x918ec44c764a8a830c3cf13f8a67b5cca430cd5866d3bfefa7e25390129e29ab` |
| `attestation.en.txt` | `0xe760c38dcca7cc6cb2e151e2c91521f89890ce053d6cbfd1f0319ff88045bd64` |

For a chain ID 4663 deployment, set `ATTESTATION_V0_TERMS_HASH` and `ATTESTATION_V0_ATTESTATION_HASH` to these values. The deployment script recomputes and compares them byte-for-byte. Any future draft must include `[DRAFT` (`VersionZero.DRAFT_MARKER`); the mainnet gate rejects text containing that marker.

## Finalization record

1. **Authoritative language:** Version 0 is English only. Translations in other languages would be non-binding references and must not enter these hashes. Multilingual binding text requires a new registry version.
2. **Review basis:** External counsel reviewed the English texts, and the project team confirmed and submitted their exact bytes on 2026-08-26. This records review of version 0 wording and scope; it does not imply that every other project legal risk has been resolved.
3. **Scope:** The terms disclose the nature of the rights, the MEME exercise consideration, possible expiry at zero, the claim-like nature of the instrument, the absence of ownership, voting, and shareholder rights, and the issuer's retained freeze, pause, and burn powers. The attestation covers restricted-jurisdiction eligibility and non-agency statements.
4. **Post-deployment verification:** Confirm that `versions(0)` matches both hashes. The deployment script performs this assertion, and `verify-deployment.sh` can verify it again from the chain.
