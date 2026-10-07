# Historical deployment evidence

The chain 4663 record preserves the addresses, block, source revision and legal
hashes of an earlier deployment. Its keys use current terminology as labels;
they do not imply that deployed bytecode exposes the current Keel interfaces.

This record is historical evidence, not an input for a new deployment or current
interface verification. New Keel deployments expose `keel()` on both ClearingPool
and MerkleDistributor. Previously deployed bytecode cannot acquire that selector
through a source rename. No chain upgrade or asset migration was performed.
