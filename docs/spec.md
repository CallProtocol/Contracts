# Current contract business specification

The current stack creates projects through official VaultPortal v2.1 and
CallVaultFactory. The immutable Factory writes VaultRegistry identity; the
retired launch wrapper is not part of this stack.

The Vault reserves 10% of actual recognized income for its immutable protocol
receiver, with cross-receipt rounding carry. Creator accrual occurs only when
business income is successfully processed. Full processing allocates 80% to Pool,
10% to creator, and 10% to protocol. Protocol claiming is permissionless and pays
only the fixed receiver, in WBNB for native projects or ERC20 collateral otherwise.
Actual Vault debit determines claim accounting; transfer tax is not subsidized by
Pool or creator. Both reserves permanently share asset impairment proportionally;
new income does not repay historical loss. Trigger availability excludes reserves.

The Pool accepts only registered project Vaults and mints against actual received
collateral. Existing collateral in Pool remains separate from Vault reserves and
Guardian emergency withdrawal. Deployment is immutable and retains exact-size,
creation-code data hash, nonce prediction and dependency verification gates.

The [interface package](interfaces.md) documents current integration interfaces
and their provenance. Tests in test/ and test/fork/ provide executable business
invariants and edge cases. Original legal text remains under legal/attestation-v0/.

Historical Launcher, deployment and operator instructions must not be used for
the current stack. Platform v2.1 assembly verification and creator 10% plus protocol
10% plus processor commission acceptance remain release blockers.
