// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title MerkleTree
/// @notice 测试侧的 merkle 树：从一组 leaf 算 root、给任意下标出 proof。
///
/// # 为什么这份实现要独立写一遍
///
/// 生产侧只**验证** proof（`MerkleProof.verify`），从不构造树 —— 树在链下由 Indexer（M4）出。
/// 所以测试要驱动 `claim` 就必须自己有一份构造实现，而这份实现**必须与被测合约无关**：
/// 拿 `MerkleDistributor.leafOf()` 去算 leaf，再拿算出来的 proof 去验它自己，
/// 只能证明「它和它自己一致」—— 编码改了照样绿。
///
/// 因此 {leafOf} 把编码**逐字写死**在这里。两边哪天不一致，测试会红，而这正是要的：
/// 那意味着链下的 Indexer 与链上的验证也不一致了。
///
/// # 哈希口径必须与 `MerkleProof` 一致
///
/// - **内部节点**：`keccak256(排序后的两个 32 字节)` —— OpenZeppelin 的 `verify` 用的是
///   可交换哈希（`Hashes.commutativeKeccak256`），所以 proof 里不需要方向位；
/// - **leaf**：哈希**两次**。内部节点的原像恒为 64 字节，leaf 哈希两次之后原像恒为 32 字节，
///   两者永久错开 —— 这就是 second preimage（拿一个中间节点冒充 leaf）不成立的原因。
///   这是 OpenZeppelin `StandardMerkleTree` 的约定，Indexer 侧对应
///   `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`。
/// - **奇数层**：落单的那个节点**原样上浮**，不是复制自己配对。复制自己是 Bitcoin CVE-2012-2459
///   那一类伪造的入口（两棵不同的树算出同一个 root）。
library MerkleTree {
    /// @notice leaf 编码：`keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`。
    /// @dev 🔴 独立写死，不调被测合约的 `leafOf`。见库注释。
    function leafOf(uint256 seriesId, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))));
    }

    /// @notice 这组 leaf 的 root。空数组不合法（没有 root 可言）。
    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length != 0, "MerkleTree: no leaves");

        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _parents(level);
        }
        return level[0];
    }

    /// @notice `leaves[index]` 的 proof。单叶树返回空数组 —— `verify` 此时要求 `leaf == root`，正确。
    function proofFor(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        require(index < leaves.length, "MerkleTree: index out of range");

        // 32 层足够容纳 2^32 张 leaf，远超任何一周的持有人数。
        bytes32[] memory buffer = new bytes32[](32);
        uint256 n;

        bytes32[] memory level = leaves;
        uint256 i = index;
        while (level.length > 1) {
            uint256 sibling = i ^ 1;
            // 越界只可能是「本层是奇数个、而我是最后那一个」—— 我原样上浮，这一层没有 proof 元素。
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

    /// @dev 排序后再哈希 —— 与 `MerkleProof.verify` 的可交换哈希一致。
    ///      `abi.encode(bytes32,bytes32)` 恰好是 64 字节、无填充，与 OZ 汇编里那两个字一致。
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
