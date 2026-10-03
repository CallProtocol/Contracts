// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice 编译产物 ABI 里的一条对外入口。
/// @param name        函数名。`receive` / `fallback` 记成同名字符串 —— 它们在 ABI 里没有 `name` 字段
/// @param mutability  `view` / `pure` / `nonpayable` / `payable`
/// @param signature   完整签名 `name(type,type,…)`；`receive` / `fallback` 记成 `receive()` / `fallback()`
struct AbiEntry {
    string name;
    string mutability;
    string signature;
}

/// @title WriteSurface
/// @notice 从编译产物的 ABI 里枚举一个合约的**全部对外入口**，并断言可写的那些恰好是预期的那几个。
///
/// # 为什么要读编译产物，而不是在测试里挨个调一遍
///
/// 不变量 5（清算池无管理员出口）与不变量 6（声明门不可锁死）要证明的都是「某个开关**不存在**」。
/// 自己列举一遍自己调用过的函数，证明不了这件事 —— 后来加进去的 `withdraw()` 不会因为
/// 没有哪条测试调用它而失效。**只有把 ABI 整个枚举一遍，才是非循环的做法。**
///
/// 因此这套断言不是某个合约的测试细节，而是本项目「证明开关不存在」的手段共用的机制，
/// 单独成库，几处共用一份实现：
///
/// - `AttestationRegistry` —— 恰好两个（`addVersion` / `attest`）
/// - `ClearingPool` —— 恰好六个（`docs/spec.zh.md` §5.1）
/// - `WarrantVault` —— 恰好六个（`sync` / `sampleTwap` / `openSeries` / `processRevenue` / `receive`
///   / `claimCreatorFee`，决策 49），
///   而且**没有一个是权限函数**。这条性质的**理由**在决策 39 换过一次（从「Flap 规范强制权限函数
///   同时授予 Guardian」换成「我们自己的选择：零权限面是『金库拿不走钱』的最短证明」），
///   而**判据一个字没改** —— 它仍然是一条要被枚举证明的性质
///   （`docs/flap-vault-spec-compliance.zh.md`）
///
/// @dev 需要 `out/` 的读权限，见 `foundry.toml` 的 `fs_permissions`。
library WriteSurface {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev ABI 是个数组，JSON 里取不到长度，所以按下标走到取不到为止。
    ///      两个上界纯粹是防手滑写出死循环，正常合约碰不到。
    uint256 private constant MAX_ABI_ENTRIES = 512;
    uint256 private constant MAX_INPUTS = 32;

    /// @notice 断言 `artifactPath` 的对外可写函数集**恰好**等于 `expected`。
    ///
    /// @param artifactPath  编译产物路径，形如 `out/ClearingPool.sol/ClearingPool.json`
    /// @param expected      完整签名，形如 `settleExpired(uint256)`；`receive` / `fallback` 写成
    ///                      `receive()` / `fallback()`
    ///
    /// @dev 双向比对，两个方向挡的不是同一件事：
    ///      - 多出来的 —— 「没有第七个入口」，这是断言的**本体**；
    ///      - 少掉的 —— 有人把某个函数收紧成了 `view`/`pure`、或改了签名。少一个同样是接口变了，
    ///        而这类改动最容易在「测试还是绿的」的错觉里溜过去。
    ///
    ///      🔴 `receive` / `fallback` 不是 `"function"`，漏掉它们就等于漏掉一整类入口。它们在这里
    ///      走**与普通函数完全相同**的一条路：不出现在 `expected` 里就报「意料之外的对外可写函数」。
    ///      四个 M1 合约的 `expected` 里都没有它们，所以「这四个合约不该有 receive」照旧成立 ——
    ///      只是不再靠一条特判，而是靠同一条集合相等。金库必须有 `receive()`（Flap 的 ping 打在那里），
    ///      它在自己的 `expected` 里显式列出。
    function assertIsExactly(string memory artifactPath, string[] memory expected) internal view {
        string[] memory found = writableSignatures(artifactPath);

        for (uint256 i = 0; i < found.length; i++) {
            vm.assertTrue(
                _contains(expected, found[i]), string.concat(unicode"意料之外的对外可写函数：", found[i])
            );
        }
        for (uint256 i = 0; i < expected.length; i++) {
            vm.assertTrue(
                _contains(found, expected[i]),
                string.concat(
                    unicode"这个对外可写函数不见了（被删、被改签名，或被收紧成 view/pure）：",
                    expected[i]
                )
            );
        }
        vm.assertEq(found.length, expected.length, unicode"对外可写函数的个数");
    }

    /// @notice 枚举全部对外可写函数的**完整签名**。
    ///
    /// @dev 🔴 断言完整签名而不是函数名：只比名字的话，一个 `addVersion(address,uint256)`
    ///      会顶着合法的名字混进去。
    function writableSignatures(string memory artifactPath) internal view returns (string[] memory signatures) {
        AbiEntry[] memory all = entries(artifactPath);

        string[] memory buffer = new string[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (isReadOnly(all[i].mutability)) continue;
            buffer[n++] = all[i].signature;
        }

        signatures = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            signatures[i] = buffer[i];
        }
    }

    /// @notice 枚举**全部**对外入口 —— 可写的与只读的都在里面。
    ///
    /// @dev 金库那条「`vaultUISchema()` 声明的方法与真实 ABI 对得上」的交叉核对要用到只读那一半：
    ///      schema 是手写的，ABI 是编译器生成的，两者漂开时**没有任何一条只读 schema 的测试会红**。
    function entries(string memory artifactPath) internal view returns (AbiEntry[] memory list) {
        string memory artifact = vm.readFile(artifactPath);

        AbiEntry[] memory buffer = new AbiEntry[](MAX_ABI_ENTRIES);
        uint256 n;
        uint256 seen;

        for (uint256 i = 0; i < MAX_ABI_ENTRIES; i++) {
            string memory entry = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(artifact, string.concat(entry, ".type"))) break;
            seen++;

            bytes32 kind = keccak256(bytes(vm.parseJsonString(artifact, string.concat(entry, ".type"))));

            if (kind == keccak256("receive") || kind == keccak256("fallback")) {
                string memory name = kind == keccak256("receive") ? "receive" : "fallback";
                buffer[n++] = AbiEntry(name, _mutabilityOf(artifact, entry), string.concat(name, "()"));
                continue;
            }
            if (kind != keccak256("function")) continue;

            buffer[n++] = AbiEntry(
                vm.parseJsonString(artifact, string.concat(entry, ".name")),
                _mutabilityOf(artifact, entry),
                _signatureOf(artifact, entry)
            );
        }

        // 一条读到东西的保底：ABI 要是悄悄读成了空数组，上面的循环一次都不进，
        // 「恰好 N 个」就变成「恰好零个」—— 那时断言仍然可能是绿的，但它的意思已经是一句假话。
        vm.assertGt(seen, 0, string.concat(unicode"没读到 ABI —— 产物路径写错了？", artifactPath));

        list = new AbiEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            list[i] = buffer[i];
        }
    }

    /// @notice `mutability` 是不是只读（`view` / `pure`）。
    function isReadOnly(string memory mutability) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(mutability));
        return h == keccak256("view") || h == keccak256("pure");
    }

    function _mutabilityOf(string memory artifact, string memory entry) private pure returns (string memory) {
        return vm.parseJsonString(artifact, string.concat(entry, ".stateMutability"));
    }

    /// @dev 从一条 ABI 记录拼出 `name(type,type,…)`。
    function _signatureOf(string memory artifact, string memory entry) private view returns (string memory signature) {
        signature = string.concat(vm.parseJsonString(artifact, string.concat(entry, ".name")), "(");

        for (uint256 j = 0; j < MAX_INPUTS; j++) {
            string memory input = string.concat(entry, ".inputs[", vm.toString(j), "]");
            if (!vm.keyExistsJson(artifact, string.concat(input, ".type"))) break;

            string memory kind = vm.parseJsonString(artifact, string.concat(input, ".type"));
            // ABI 把 struct 参数写成 `tuple` 加 `components`。这里核对的是 ABI 的入口形状而不是
            // bytes4 selector，所以保留 `tuple` 字面量，调用方把它显式列入预期即可。

            if (j != 0) signature = string.concat(signature, ",");
            signature = string.concat(signature, kind);
        }

        signature = string.concat(signature, ")");
    }

    function _contains(string[] memory haystack, string memory needle) private pure returns (bool) {
        bytes32 n = keccak256(bytes(needle));
        for (uint256 i = 0; i < haystack.length; i++) {
            if (keccak256(bytes(haystack[i])) == n) return true;
        }
        return false;
    }
}
