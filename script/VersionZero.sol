// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title VersionZero
/// @notice `AttestationRegistry.versions[0]` 的两段文本：从 `legal/attestation-v0/` 读入、
///         算哈希、并在**主网**上强制「已定稿并核准」这道前置检查。
///
/// 单独成库而不是塞进部署脚本，是因为 M1-3（issue #8）的四合约部署脚本要复用同一套逻辑 ——
/// version 0 的文本只该有**一个**来源。
///
/// 🔴 `versions[0]` 一经上链永久存在、无法删改，而任意地址恒可通过 `attest(0, …)` 满足行权门槛
/// （不变量 6③）。也就是说**这两段文本是全体用户唯一保证可用的那一版**。写错没有第二次机会。
library VersionZero {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param terms            TERMS 正文（已过字节规范校验，去掉那个唯一的结尾 LF）
    /// @param attestation      ATTESTATION 正文（同上）
    /// @param termsHash        `keccak256(bytes(terms))`
    /// @param attestationHash  `keccak256(bytes(attestation))`
    struct Texts {
        string terms;
        string attestation;
        bytes32 termsHash;
        bytes32 attestationHash;
    }

    /// @dev 主网链 ID。注册表**每链一个**，所以「是不是主网」就等于「chainId 在不在这张表上」。
    ///      🔴 曾经这里是单值 `ROBINHOOD_CHAIN_ID`，`requireDeployable` 直接拿它做等值判断。
    ///      那个形状在第二条主网出现的那一刻就变成了一个**静默**的坑：BSC 主网会走
    ///      「非主网 → 跳过定稿检查」那条分支，把带草稿标记的占位文本**永久**写进
    ///      `versions[0]`（不可删改，不变量 6③）。加链必须同时加进这张表。见决策 56。
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant BSC_CHAIN_ID = 56;

    /// @dev Robinhood Chain（4663）的那一份。
    string internal constant TERMS_PATH = "legal/attestation-v0/terms.en.txt";
    string internal constant ATTESTATION_PATH = "legal/attestation-v0/attestation.en.txt";

    /// @dev BSC（56）的那一份。**为什么不能与 4663 共用一份**，见
    ///      `legal/attestation-v0-bsc/README.md` §1：4663 的 `versions[0]` 已上链且不可替换，
    ///      而两条链的抵押品发行方不同、权限面不同 —— 一段同时描述两者的文本，
    ///      要么对一条链过度披露，要么对另一条披露不足。
    string internal constant TERMS_PATH_BSC = "legal/attestation-v0-bsc/terms.en.txt";
    string internal constant ATTESTATION_PATH_BSC = "legal/attestation-v0-bsc/attestation.en.txt";

    /// @dev 草稿标记。version 0 已于 2026-08-26 定稿（权威文本为英文，见 legal/attestation-v0/README.md）。
    ///      标记留作闸门：任何重新带上它的文本（含未来版本的草稿）都进不了主网 ——
    ///      它在哈希覆盖范围之内，动它哈希必变，必须重新过一遍下面的哈希钉死检查。
    string internal constant DRAFT_MARKER = "[DRAFT";

    /// @dev 定稿核准时对应的哈希，由部署者显式填入。主网上必填且必须与现算值相等。
    string internal constant ENV_TERMS_HASH = "ATTESTATION_V0_TERMS_HASH";
    string internal constant ENV_ATTESTATION_HASH = "ATTESTATION_V0_ATTESTATION_HASH";

    /// @notice 这条链算不算主网。
    /// @dev `pure` 而不是读 `block.chainid`，因为 `requireDeployable` 的错误信息要能把
    ///      「当前链」与「主网名单」一起打出来，两个值分开传更好测。
    function isMainnet(uint256 chainId) internal pure returns (bool) {
        return chainId == ROBINHOOD_CHAIN_ID || chainId == BSC_CHAIN_ID;
    }

    /// @notice 本链该读哪一组文本文件。
    ///
    /// @dev 🔴 **按 chainId 选，不留环境变量后门。** 「读哪份法律文本」与「往哪条链上写」
    ///      必须是同一个事实的两次表述；给它开一个 env 开关，等于让部署夜的一个手误
    ///      把 A 链的文本永久写进 B 链的注册表。
    ///
    ///      ⚠️ **本地分叉彩排的已知缺口**：BSC 彩排若跑在 31337 这类本地链 ID 上，这里会落到
    ///      Robinhood 那一份 —— 因为本地链 ID 目前硬映射的就是 Robinhood 那一套
    ///      （`DeploySystem` 的 31337/31338 同样如此）。彩排产出的 manifest 里因此会记下
    ///      Robinhood 的哈希。这不影响主网正确性（主网完全由 chainId 决定），但会让 BSC 彩排
    ///      验不到自己的文本。`requireDeployable` 的非主网告警会把实际读到的目录打出来，
    ///      好让这件事**可见**而不是静默。彻底修好要等「BSC 彩排用哪对本地链 ID」定案。
    function legalDir() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? "legal/attestation-v0-bsc/" : "legal/attestation-v0/";
    }

    function termsPath() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? TERMS_PATH_BSC : TERMS_PATH;
    }

    function attestationPath() internal view returns (string memory) {
        return block.chainid == BSC_CHAIN_ID ? ATTESTATION_PATH_BSC : ATTESTATION_PATH;
    }

    /// @notice 读入两段文本并算出哈希。读哪一份由 {legalDir} 按 chainId 决定。
    function load() internal view returns (Texts memory t) {
        t.terms = _readCanonical(termsPath());
        t.attestation = _readCanonical(attestationPath());
        t.termsHash = keccak256(bytes(t.terms));
        t.attestationHash = keccak256(bytes(t.attestation));
    }

    /// @notice 主网前置检查，钉死的哈希从环境变量读。
    function requireDeployable(Texts memory t) internal view {
        requireDeployable(t, vm.envOr(ENV_TERMS_HASH, bytes32(0)), vm.envOr(ENV_ATTESTATION_HASH, bytes32(0)));
    }

    /// @notice 主网前置检查：文本已定稿，且与定稿核准的那一版逐字节相同。
    ///
    /// @dev 非主网（测试网 / 本地 / 分叉测试）只打一行告警就放行 —— 占位文本在那里是允许的。
    ///
    ///      主网上要过两道：
    ///      ① 文本里不得残留草稿前缀 —— 挡「忘了定稿」这个最常见的失误，并给出可读的错误；
    ///      ② 现算哈希必须等于钉死的、定稿核准时的哈希 —— 挡「定稿之后文件又被改过」。
    ///
    ///      ② 在结构上已经覆盖 ①（定稿会改变哈希），但 ① 的错误信息告诉你**该去做什么**，
    ///      而 ② 只能告诉你**对不上**。这两句话在部署夜里不是一回事。
    ///
    ///      把「钉死的哈希」做成参数而不是在这里读环境变量，是为了让它可测：
    ///      forge 在同一个测试合约里**并行**跑各条测试，而环境变量是进程级的 ——
    ///      靠 `vm.setEnv` 摆弄它的测试会互相打架。上面那个一参重载负责读环境变量。
    function requireDeployable(Texts memory t, bytes32 reviewedTerms, bytes32 reviewedAttestation) internal view {
        if (!isMainnet(block.chainid)) {
            console2.log(
                string.concat(
                    unicode"[VersionZero] ⚠️ chainId=",
                    vm.toString(block.chainid),
                    unicode" 不是主网（",
                    vm.toString(ROBINHOOD_CHAIN_ID),
                    " / ",
                    vm.toString(BSC_CHAIN_ID),
                    unicode"），跳过「文本已定稿」检查 —— 本次上链的是占位文本。读的是 ",
                    // 🔴 把实际读到的目录打出来：本地彩排落到哪一份法律文本是**可见**的，
                    //    不是要靠读 {legalDir} 的源码才知道。见那里记的彩排缺口。
                    legalDir()
                )
            );
            return;
        }

        require(
            !_contains(t.terms, DRAFT_MARKER) && !_contains(t.attestation, DRAFT_MARKER),
            string.concat(
                unicode"VersionZero: version 0 文本仍带草稿标记，不得部署至主网。定稿清单见 ",
                legalDir(),
                "README.md"
            )
        );

        require(
            reviewedTerms != bytes32(0) && reviewedAttestation != bytes32(0),
            string.concat(
                unicode"VersionZero: 主网部署必须显式钉死定稿核准的哈希。请设置 ",
                ENV_TERMS_HASH,
                " / ",
                ENV_ATTESTATION_HASH,
                unicode"。当前文本算出来的是 ",
                vm.toString(t.termsHash),
                " / ",
                vm.toString(t.attestationHash)
            )
        );

        require(
            reviewedTerms == t.termsHash,
            string.concat(
                unicode"VersionZero: terms.en.txt 与定稿核准的版本不符 —— 钉死的是 ",
                vm.toString(reviewedTerms),
                unicode"，现算是 ",
                vm.toString(t.termsHash)
            )
        );
        require(
            reviewedAttestation == t.attestationHash,
            string.concat(
                unicode"VersionZero: attestation.en.txt 与定稿核准的版本不符 —— 钉死的是 ",
                vm.toString(reviewedAttestation),
                unicode"，现算是 ",
                vm.toString(t.attestationHash)
            )
        );
    }

    /// @notice 文本是否仍带草稿标记。
    function isDraft(Texts memory t) internal pure returns (bool) {
        return _contains(t.terms, DRAFT_MARKER) || _contains(t.attestation, DRAFT_MARKER);
    }

    function _readCanonical(string memory path) private view returns (string memory) {
        return canonicalize(bytes(vm.readFile(path)), path);
    }

    /// @notice 按 `legal/attestation-v0/README.md` 的字节规范取出正文：**恰好一个结尾 LF**，
    ///         正文非空、不含任何控制字符、不以 BOM / `-` / `0x` 开头。
    ///         去掉那个唯一的 LF 就是要哈希的内容。
    ///
    /// @dev 🔴 **不合规范的输入一律拒绝，不做「修正」。** 早先这里是「剥掉结尾任意多个 `\n` 与 `\r`」，
    ///      那样 `"文本\n"` 与 `"文本\r\n"` 会归一到同一个哈希 —— 定稿之后文件被编辑器存成 CRLF，
    ///      钉死的哈希照样能过，部署照样成功，**但用户拿 README 里那条命令算出来的是另一个值**：
    ///
    ///      ```
    ///      cast keccak -- "$(cat 文件)"   # $( ) 剥掉结尾所有换行，但不剥 CR
    ///      ```
    ///
    ///      于是「审核过的那份文本」与「部署上去的那份文本」悄悄脱节，而这个工件不可逆。
    ///      收紧之后哈希与文件字节一一对应；两边真的对得上这件事，由 CI 里
    ///      「version 0 哈希可复算」那一步**实际跑一遍这条命令**来证明，不靠这里的注释。
    ///
    ///      `internal` 而不是 `private`，是为了让这几条拒绝路径能被测试直接驱动 ——
    ///      走文件系统去构造它们需要写盘权限，而这个仓库的 `fs_permissions` 是只读的，
    ///      且应当保持只读。
    function canonicalize(bytes memory raw, string memory path) internal pure returns (string memory) {
        if (raw.length == 0) _reject(path, unicode"是空文件");
        if (raw[raw.length - 1] != 0x0a) {
            _reject(path, unicode"结尾必须有一个 LF —— 见同目录 README 的字节规范");
        }

        uint256 end = raw.length - 1; // 正文长度：去掉那个唯一的结尾 LF
        if (end == 0) _reject(path, unicode"正文为空 —— 整个文件只有一个结尾 LF");

        _rejectHostileOpening(raw, end, path);

        bytes memory line = new bytes(end);
        for (uint256 i = 0; i < end; i++) {
            bytes1 b = raw[i];

            // 🔴 CR 与 NUL 是同一类：肉眼看不见，而复算命令拿不到它们
            //    （CR 被 `$( )` 保留但被这里剥掉过；NUL 根本进不了 argv）。
            if (b == 0x0d) {
                _reject(
                    path,
                    unicode'含 CR —— 行尾必须是 LF。CRLF 会让 cast keccak "$(cat 文件)" 复算出另一个哈希'
                );
            }
            if (b == 0x0a) {
                _reject(path, unicode"正文含换行 —— 一个文件必须是一行正文加恰好一个结尾 LF");
            }
            if (b < 0x20 || b == 0x7f) {
                _reject(
                    path,
                    unicode"正文含控制字符 —— 它进得了链上哈希，却进不了复算命令的 argv，两边必然对不上"
                );
            }

            line[i] = b;
        }
        return string(line);
    }

    /// @dev 正文开头的三种「合法字节，但会让 `cast keccak` 静默算出别的值」的形状。
    ///      三条都实测过（foundry 1.7.1）：
    ///
    ///      | 正文 | `cast keccak "$(cat 文件)"` |
    ///      |---|---|
    ///      | `--json` | 被 clap 当成开关吃掉，静默返回 `keccak("")` |
    ///      | `0xdeadbeef` | 按十六进制**解码**后再哈希，加 `--` 也拦不住 |
    ///      | BOM 开头 | 两边都含 BOM，哈希其实一致 —— 但肉眼分不出签的是哪一版 |
    ///
    ///      前两条是真正的静默分叉；第三条是「律师看到的字」与「链上哈希的字节」可能不是一回事。
    ///      一段法律正文永远不会以这三种形状开头，所以直接拒绝最省事。
    function _rejectHostileOpening(bytes memory raw, uint256 end, string memory path) private pure {
        if (end >= 3 && raw[0] == 0xef && raw[1] == 0xbb && raw[2] == 0xbf) {
            _reject(
                path,
                unicode"带 UTF-8 BOM —— 不可见的三个字节会一起进哈希，肉眼分不出签的是哪一版"
            );
        }
        if (raw[0] == 0x2d) {
            _reject(
                path,
                unicode"正文以 - 开头 —— cast 会把它当成命令行开关，复算命令会静默算出别的值"
            );
        }
        if (end >= 2 && raw[0] == 0x30 && (raw[1] == 0x78 || raw[1] == 0x58)) {
            _reject(
                path,
                unicode"正文以 0x 开头 —— cast keccak 会把它按十六进制解码，复算命令会静默算出别的值"
            );
        }
    }

    /// @dev 消息只在失败那条路径上拼。`require` 的第二个参数是**先求值再调用**的，
    ///      写在逐字节的循环里会让整个函数变成 O(n²) —— 正文一大就先撞 MemoryOOG，
    ///      而那时报出来的是一句看不懂的话，不是这里精心写的错误。
    function _reject(string memory path, string memory reason) private pure {
        revert(string.concat(unicode"VersionZero: ", path, " ", reason));
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;

        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
