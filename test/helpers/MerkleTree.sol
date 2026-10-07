// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MerkleTree
/// @notice Test side. merkle Tree: From a group leaf Fine. root,Mark Any proof.
///
/// # Why write this one on its own?
///
/// Production side only**Authentication** proof(`MerkleProof.verify`),Never construct tree - tree under chain by Indexer(M4)Out.
/// So the test is driven. `claim` You have to have one of your own, and this one is.**It has to be unrelated to the contract.**:
/// Take it. `MerkleDistributor.leafOf()` I'll figure it out. leaf,I'll figure it out. proof Go check it out.
/// It's just proof that it's the same as it is, and the code has changed to green.
///
/// And so... {leafOf} Encoding**Death by word.**Here. The test is red, and that's what it is:
/// That means under the chain. Indexer It's not consistent with the chain certification.
///
/// # Hash had to... `MerkleProof` Unanimously
///
/// - **Internal Nodes**:`keccak256(Sorted two 32 Bytes)`  -  -  OpenZeppelin It's... `verify` It's on the...
///   Swaps Hashi`Hashes.commutativeKeccak256`),So... proof No directional position is required;
/// - **leaf**:Hash.**Twice.**.The original image of the internal node is constant 64 bytes,leaf Hashi's two times later, he's been like a... 32 bytes,
///   The two are permanently staggered -- that's it. second preimage(Take an intermediate node and pretend to be leaf)Reason for not being established.
///   This is... OpenZeppelin `StandardMerkleTree` The agreement,Indexer Side-to-side
///   `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`.
/// - **Odd Layer**:The single node.**Floating up as it is.**,Not copy yourself. Copy yourself. Bitcoin CVE-2012-2459
///   The kind of fake entrance. root).
library MerkleTree {
    /// @notice leaf Encoding:`keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`.
    /// @dev CRITICAL I'm gonna write this myself. I don't know what to do with my contract. `leafOf`.See the library note.
    function leafOf(uint256 seriesId, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))));
    }

    /// @notice This group. leaf It's... root.Empty array is invalid (no) root I'm not sure.
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length != 0, "MerkleTree: no leaves");

        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _parents(level);
        }
        return level[0];
    }

    /// @notice `leaves[index]` It's... proof.Single tree returns empty arrays... `verify` Request at this time `leaf == root`,Correct.
    function proofFor(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        require(index < leaves.length, "MerkleTree: index out of range");

        // 32 There's enough floors to hold. 2^32 Chang! leaf,Far above the number of people held in any week.
        bytes32[] memory buffer = new bytes32[](32);
        uint256 n;

        bytes32[] memory level = leaves;
        uint256 i = index;
        while (level.length > 1) {
            uint256 sibling = i ^ 1;
            // The only thing that crosses the border is "the odd layer, and I'm the last one" -- I floated up, and there's no floor. proof Elements.
            if (sibling < level.length) buffer[n++] = level[sibling];
            level = _parents(level);
            i /= 2;
        }

        proof = new bytes32[](n);
        for (uint256 j = 0; j < n; j++) {
            proof[j] = buffer[j];
        }
    }

    function _parents(bytes32[] memory level) private pure returns (bytes32[] memory up) {
        up = new bytes32[]((level.length + 1) / 2);
        for (uint256 i = 0; i < up.length; i++) {
            uint256 left = 2 * i;
            up[i] = left + 1 < level.length ? _hashPair(level[left], level[left + 1]) : level[left];
        }
    }

    /// @dev Sort after Hash -- with `MerkleProof.verify` The trade-off for the Hashy-unanimous.
    ///      `abi.encode(bytes32,bytes32)` Exactly. 64 bytes, unfilled, with OZ The two words in the compilation are identical.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
