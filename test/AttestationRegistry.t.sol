// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {IAttestationRegistry} from "../src/interfaces/IAttestationRegistry.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice `AttestationRegistry` 的对外行为。
///
/// 全部测试只通过 external 函数驱动，不测 internal，不为可测性在生产代码里留钩子。
/// 断言写在**状态与事件**上。
///
/// 不变量 6 的三款（单调不减 / 仅本人可写 / `versions[0]` 恒可声明）在
/// `test/invariant/Invariant6AttestationGate.t.sol` 里以 fuzz 序列驱动；这里写的是
/// 那三条性质的**具名边界情形**，以及验收条款里点名的几条路径。
contract AttestationRegistryTest is Test {
    AttestationRegistry internal registry;

    address internal publisher = makeAddr("publisher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");
    bytes32 internal constant TERMS_1 = keccak256("TERMS v1");
    bytes32 internal constant ATTESTATION_1 = keccak256("ATTESTATION v1");

    function setUp() public {
        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
    }

    // ─────────────────────────── 构造与版本表 ───────────────────────────

    function test_constructor_rejectsZeroPublisher() public {
        vm.expectRevert(AttestationRegistry.ZeroPublisher.selector);
        new AttestationRegistry(address(0), TERMS_0, ATTESTATION_0);
    }

    /// @dev 🔴 version 0 走构造函数，不走「部署完再由 publisher 追加」——
    ///      后者中间有一段 `versions` 为空的窗口，那时 `attest()` 对所有人 revert，
    ///      不变量 6③ 的前提就从结构保证退化成流程保证。见构造函数注释。
    function test_constructor_writesVersion0_soTheGateIsOpenFromBlockOne() public {
        AttestationRegistry fresh = new AttestationRegistry(publisher, TERMS_1, ATTESTATION_1);

        assertEq(fresh.versionCount(), 1, unicode"构造完就该有一版文本");
        (bytes32 terms, bytes32 attestation) = fresh.versions(0);
        assertEq(terms, TERMS_1);
        assertEq(attestation, ATTESTATION_1);

        // publisher 与部署者无关也照样能开门 —— 构造函数不经过 onlyPublisher
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        fresh.attest(0, TERMS_1, ATTESTATION_1);
        assertEq(fresh.attestedVersion(stranger), 1);
    }

    function test_constructor_rejectsEmptyTextHash() public {
        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        new AttestationRegistry(publisher, bytes32(0), ATTESTATION_0);

        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        new AttestationRegistry(publisher, TERMS_0, bytes32(0));
    }

    function test_addVersion_appendsWithoutTouchingEarlierEntries() public {
        vm.prank(publisher);
        uint256 version = registry.addVersion(TERMS_1, ATTESTATION_1);

        assertEq(version, 1, unicode"新版本的下标");
        assertEq(registry.versionCount(), 2, unicode"版本数");

        (bytes32 terms0, bytes32 attestation0) = registry.versions(0);
        assertEq(terms0, TERMS_0, unicode"追加不得改动 versions[0].termsHash");
        assertEq(attestation0, ATTESTATION_0, unicode"追加不得改动 versions[0].attestationHash");

        (bytes32 terms1, bytes32 attestation1) = registry.versions(1);
        assertEq(terms1, TERMS_1, "versions[1].termsHash");
        assertEq(attestation1, ATTESTATION_1, "versions[1].attestationHash");
    }

    function test_addVersion_onlyPublisher() public {
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.NotPublisher.selector, alice));
        vm.prank(alice);
        registry.addVersion(TERMS_1, ATTESTATION_1);

        assertEq(registry.versionCount(), 1, unicode"被拒的追加不得留下痕迹");
    }

    /// @dev 全零哈希不是一段文本 —— 它会得到一版「谁都能用全零参数满足」的声明：门还开着，
    ///      证据是空的。这是部署脚本忘了填文本时最可能的样子。
    function test_addVersion_rejectsEmptyTextHash() public {
        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        vm.prank(publisher);
        registry.addVersion(bytes32(0), ATTESTATION_1);

        vm.expectRevert(AttestationRegistry.EmptyTextHash.selector);
        vm.prank(publisher);
        registry.addVersion(TERMS_1, bytes32(0));
    }

    // ─────────────────────────────── attest ───────────────────────────────

    function test_attest_recordsVersionPlusOneAndEmits() public {
        assertEq(registry.attestedVersion(alice), 0, unicode"声明前");

        vm.expectEmit(true, false, false, true, address(registry));
        emit AttestationRegistry.Attested(alice, 0, TERMS_0, ATTESTATION_0, block.timestamp);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertEq(registry.attestedVersion(alice), 1, unicode"存的是 version + 1");
    }

    /// @dev 哈希作为参数传入并校验，是为了让文本哈希进入 calldata（钱包可见）、
    ///      且前端无法替用户悄悄声明另一版本。校验失败就必须拒。
    function test_attest_rejectsMismatchedText() public {
        bytes32 wrong = keccak256("some other text");

        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, wrong, ATTESTATION_0));
        vm.prank(alice);
        registry.attest(0, wrong, ATTESTATION_0);

        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, TERMS_0, wrong));
        vm.prank(alice);
        registry.attest(0, TERMS_0, wrong);

        // 两段文本调换 —— 参数顺序写反是最容易发生的一种「哈希对，但对不上号」
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.TextMismatch.selector, 0, ATTESTATION_0, TERMS_0));
        vm.prank(alice);
        registry.attest(0, ATTESTATION_0, TERMS_0);

        assertEq(registry.attestedVersion(alice), 0, unicode"失败的声明不得留下痕迹");
    }

    function test_attest_rejectsUnknownVersion() public {
        vm.expectRevert(abi.encodeWithSelector(AttestationRegistry.UnknownVersion.selector, 1, 1));
        vm.prank(alice);
        registry.attest(1, TERMS_0, ATTESTATION_0);
    }

    /// @dev 「单调不减」不是「严格递增」：签署旧版本既不回退状态，也不失败。
    ///      见 `AttestationRegistry.attest` 的注释 —— 这是与 `spec.zh.md` §5.5 设计草图
    ///      唯一的语义偏差，为的是让不变量 6③ 不带前提条件。
    function test_attest_isMonotonicNonDecreasing_notStrictlyIncreasing() public {
        vm.prank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);

        vm.prank(alice);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        assertEq(registry.attestedVersion(alice), 2, unicode"签了 version 1");

        // 回头再签一遍 version 0：不 revert，也不把状态推回去，但**照常 emit** ——
        // `Attested` 是签署行为的流水，不是账户状态的快照。链下取 max，不能取最后一条。
        vm.expectEmit(true, false, false, true, address(registry));
        emit AttestationRegistry.Attested(alice, 0, TERMS_0, ATTESTATION_0, block.timestamp);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(registry.attestedVersion(alice), 2, unicode"签旧版本不得让状态倒退");

        // 重复签署同一版本同样不 revert
        vm.prank(alice);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        assertEq(registry.attestedVersion(alice), 2, unicode"重复签署是幂等的");
    }

    /// @dev 验收条款：**任意地址在任意时刻**调 `attest(0, …)` 均成功。
    ///      「任意时刻」这里覆盖两个维度：时间推进，以及 publisher 已经追加了任意多版新文本。
    function testFuzz_attest0_alwaysSucceeds(address who, uint32 timeJump, uint8 extraVersions) public {
        vm.warp(block.timestamp + timeJump);

        for (uint256 i = 0; i < uint256(extraVersions) % 8; i++) {
            vm.prank(publisher);
            registry.addVersion(keccak256(abi.encode("terms", i)), keccak256(abi.encode("attestation", i)));
        }

        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertGe(registry.attestedVersion(who), 1, unicode"attest(0, …) 之后必须通过门槛");
    }

    // ──────────────────── 追加不得追溯失效 / 别人写不了我的状态 ────────────────────

    /// @dev 验收条款：publisher 追加新版本后，**旧版本声明者的状态不变**。
    function test_addingVersion_doesNotInvalidateEarlierAttesters() public {
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        uint256 before = registry.attestedVersion(alice);

        vm.startPrank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);
        registry.addVersion(keccak256("TERMS v2"), keccak256("ATTESTATION v2"));
        vm.stopPrank();

        assertEq(registry.attestedVersion(alice), before, unicode"追加不得改动既有声明");
        assertGt(registry.attestedVersion(alice), 0, unicode"旧版本声明者仍然通过门槛");
    }

    /// @dev 验收条款：第三方无法改他人的 `attestedVersion`；publisher 也不能。
    ///
    ///      「不能」的**结构性**证明是 `test_writeSurface_isExactlyAddVersionAndAttest`
    ///      （对外可写函数只有两个）与不变量 6②。这里补的是几个具名的尝试。
    function test_nobodyElseCanWriteAnothersAttestedVersion() public {
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(registry.attestedVersion(alice), 1);

        // publisher 追加新版本、并为自己签署 —— 都碰不到 alice
        vm.startPrank(publisher);
        registry.addVersion(TERMS_1, ATTESTATION_1);
        registry.attest(1, TERMS_1, ATTESTATION_1);
        vm.stopPrank();
        assertEq(registry.attestedVersion(alice), 1, unicode"publisher 改不了 alice");

        // 第三方为自己签署 —— 同样碰不到 alice
        vm.prank(bob);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(registry.attestedVersion(alice), 1, unicode"第三方改不了 alice");

        // 几个「如果真有后门，多半长这样」的选择器。
        // 这里是**具名的旁证**，不是证明——「没有别的写入口」由下面那条枚举 ABI 完整签名的测试给出。
        // `Invariant6AttestationGate.t.sol` 的 `_selector` 另有一张同类的表，喂给 fuzzer 用；
        // 两张表不需要保持一致，它们各自服务的机制不同。
        string[6] memory backdoors = [
            "reset(address)",
            "clear(address)",
            "revoke(address)",
            "setAttestedVersion(address,uint256)",
            "attestFor(address,uint256)",
            "removeVersion(uint256)"
        ];
        for (uint256 i = 0; i < backdoors.length; i++) {
            vm.prank(publisher);
            (bool ok,) = address(registry).call(abi.encodeWithSignature(backdoors[i], alice, uint256(0)));
            assertFalse(ok, string.concat(unicode"意料之外地存在：", backdoors[i]));
        }

        assertEq(registry.attestedVersion(alice), 1, unicode"alice 的状态自始至终没被别人动过");
    }

    // ─────────────────────── 对外可写函数集（结构性证明）───────────────────────

    /// @dev 不变量 6 要证明的是「某个开关**不存在**」。自己列举一遍自己调用过的函数，
    ///      证明不了这件事 —— 后来加进去的 `clear(address)` 不会因为没人调用它而失效。
    ///      所以这里读编译产物的 ABI，把**全部**对外入口枚举一遍（含 `receive` / `fallback`）。
    ///
    ///      枚举本身住在 {WriteSurface}：不变量 5（清算池无管理员出口）用的是同一套机制，
    ///      而这是本项目仅有的两条「证明开关不存在」的手段，不该有两份会各自漂移的实现。
    function test_writeSurface_isExactlyAddVersionAndAttest() public view {
        string[] memory expected = new string[](2);
        expected[0] = "addVersion(bytes32,bytes32)";
        expected[1] = "attest(uint256,bytes32,bytes32)";

        WriteSurface.assertIsExactly("out/AttestationRegistry.sol/AttestationRegistry.json", expected);
    }

    // ─────────────────────── 清算池将要用的那一次读取 ───────────────────────

    /// @dev 钉住 ClearingPool（M1-5，issue #10）唯一会做的那次查询：
    ///      `attestations.attestedVersion(beneficiary) != 0`。
    function test_theQueryClearingPoolWillMake() public {
        IAttestationRegistry gate = IAttestationRegistry(address(registry));

        assertEq(gate.attestedVersion(alice), 0, unicode"没声明过就是 0");

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);

        assertTrue(gate.attestedVersion(alice) != 0, unicode"声明过就非 0");
    }
}
