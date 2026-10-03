// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {VersionZero} from "./VersionZero.sol";

/// @title DeployAttestationRegistry
/// @notice 部署 `AttestationRegistry`，version 0 随构造函数一并写入。
///
/// 「部署」与「写入 version 0」必须是**同一笔交易**：分成两笔，中间那段窗口里
/// `attest()` 对所有人都 revert —— 也就是这道门被焊死的样子。所以 version 0 是构造参数
/// （见 `AttestationRegistry` 构造函数的注释），脚本末尾再断言「门确实是开的」，
/// 否则整个部署失败。
///
/// 四合约的完整接线（Warrant / MerkleDistributor / ClearingPool 与两处 `setPool`）在
/// [`DeploySystem.s.sol`](./DeploySystem.s.sol)（M1-3，issue #8）。那个脚本复用本文件的
/// `resolvePublisher` / `assertGateIsOpen` / `logRegistry` 与 `VersionZero` ——
/// **注册表的部署要么用本脚本，要么用那个脚本，不要两个都跑**：注册表每链一个。
///
/// ```bash
/// # 本地 / 测试网（占位文本即可）
/// forge script script/DeployAttestationRegistry.s.sol --rpc-url <url> --broadcast
///
/// # 主网：文本须已定稿，且钉死法律意见签署的哈希，见 legal/attestation-v0/README.md
/// ATTESTATION_V0_TERMS_HASH=0x… ATTESTATION_V0_ATTESTATION_HASH=0x… \
///   forge script script/DeployAttestationRegistry.s.sol --rpc-url robinhood --broadcast
/// ```
contract DeployAttestationRegistry is Script {
    /// @dev publisher 只有一项权力：**追加**后续版本文本。它改不了、删不了任何东西，
    ///      也碰不了任何人的声明状态 —— 所以它不是这套系统的信任根，多签与否是运营选择。
    ///      不填就用部署者自己；因为 version 0 走构造函数，publisher 是不是部署者都不影响部署。
    string internal constant ENV_PUBLISHER = "ATTESTATION_PUBLISHER";

    /// @dev 末尾「门是开的吗」那条断言用的探针地址。任意一个从未出现过的地址都可以 ——
    ///      这正是不变量 6③ 所断言的：**任意**地址都能自行满足门槛。
    address internal constant GATE_PROBE = address(uint160(uint256(keccak256("index-rein: attestation gate probe"))));

    function run() external returns (AttestationRegistry registry) {
        return deploy(resolvePublisher(msg.sender));
    }

    /// @notice 解析 publisher：`ATTESTATION_PUBLISHER` 优先，未设置则落回 `fallbackTo`（通常是部署者）。
    ///
    /// @dev `public` 且把「未设置时用谁」做成参数，是为了让 M1-3 的四合约部署脚本（issue #8）复用它 ——
    ///      那边若改成调 `run()`，`msg.sender` 会变成**脚本合约自己**，publisher 就会静默落在一个
    ///      没有私钥的地址上，而 publisher 是 `immutable`。
    function resolvePublisher(address fallbackTo) public view returns (address publisher) {
        address configured = vm.envOr(ENV_PUBLISHER, address(0));
        // 🔴 明说这一步取的是哪个值。`ATTESTATION_PUBLISHER` 名字打错时会**静默**落回部署者，
        //    而 publisher 是 immutable —— 发现得晚就只能重新部署一份注册表。
        console2.log(
            configured == address(0)
                ? string.concat(
                    unicode"[publisher] ", ENV_PUBLISHER, unicode" 未设置，用部署者：", vm.toString(fallbackTo)
                )
                : string.concat(unicode"[publisher] 取自 ", ENV_PUBLISHER, unicode"：", vm.toString(configured))
        );
        return configured == address(0) ? fallbackTo : configured;
    }

    function deploy(address publisher) public returns (AttestationRegistry registry) {
        VersionZero.Texts memory v0 = VersionZero.load();
        VersionZero.requireDeployable(v0);

        vm.startBroadcast();
        registry = new AttestationRegistry(publisher, v0.termsHash, v0.attestationHash);
        vm.stopBroadcast();

        assertGateIsOpen(registry, v0);
        logRegistry(registry, publisher, v0);
    }

    /// @notice 部署后立刻验证不变量 6③ 的前提在链上成立：`versions[0]` 就是刚才那两段文本，
    ///         且一个**从未出现过的地址**真的能靠 `attest(0, …)` 通过门槛。
    ///
    /// @dev 这一步是本地模拟，不在 `broadcast` 区间内，因此不会发出任何交易 ——
    ///      它跑的是刚部署的那份字节码，验的是「这份字节码上门确实开着」，
    ///      而不是「源码看起来门开着」。
    ///
    ///      `public` 是为了让 M1-3 的四合约脚本（`DeploySystem.s.sol`）复用同一份断言：
    ///      那边必须在**自己那段 broadcast 里**创建注册表（多段 broadcast 会让 forge 把 nonce 排错），
    ///      于是能复用的就只剩「怎么算文本」「怎么验门」「怎么打印」这三件有知识含量的事。
    function assertGateIsOpen(AttestationRegistry registry, VersionZero.Texts memory v0) public {
        require(registry.versionCount() == 1, unicode"部署后 versions 长度不是 1 —— version 0 没写进去");

        (bytes32 termsHash, bytes32 attestationHash) = registry.versions(0);
        require(termsHash == v0.termsHash, unicode"链上 termsHash 与文件算出来的不符");
        require(attestationHash == v0.attestationHash, unicode"链上 attestationHash 与文件算出来的不符");

        vm.prank(GATE_PROBE);
        registry.attest(0, v0.termsHash, v0.attestationHash);
        require(
            registry.attestedVersion(GATE_PROBE) == 1,
            unicode"门没开：陌生地址 attest(0, …) 之后仍未通过门槛"
        );
    }

    /// @notice 注册表那一段部署日志。
    /// @dev 🔴 CI 里「version 0 哈希可复算」那一步是**按行解析这段输出**的（`termsHash` / `attestationHash`
    ///      两行的第二列）。改格式前先看一眼 `.github/workflows/ci.yml`。
    ///      `public` 同样是给 `DeploySystem.s.sol` 复用 —— 两个脚本打印的注册表信息必须是同一份。
    function logRegistry(AttestationRegistry registry, address publisher, VersionZero.Texts memory v0) public pure {
        console2.log(
            string.concat(
                "[AttestationRegistry] ",
                vm.toString(address(registry)),
                "\n  publisher       ",
                vm.toString(publisher),
                "\n  termsHash       ",
                vm.toString(v0.termsHash),
                "\n  attestationHash ",
                vm.toString(v0.attestationHash),
                VersionZero.isDraft(v0) ? unicode"\n  ⚠️ 占位文本（草稿），仅测试网" : ""
            )
        );
    }
}
