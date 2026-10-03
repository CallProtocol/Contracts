// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {DeployAttestationRegistry} from "../script/DeployAttestationRegistry.s.sol";
import {VersionZero} from "../script/VersionZero.sol";

/// @dev `requireDeployable` 是 `internal view`，try/catch 不到。包一层才能读到 revert 原因 ——
///      「主网前置检查确实挡住了」这件事，值得断言到具体挡在哪一条上，而不是「反正 revert 了」。
contract VersionZeroHarness {
    function requireDeployable(VersionZero.Texts memory texts, bytes32 reviewedTerms, bytes32 reviewedAttestation)
        external
        view
    {
        VersionZero.requireDeployable(texts, reviewedTerms, reviewedAttestation);
    }

    function canonicalize(bytes memory raw, string memory path) external pure returns (string memory) {
        return VersionZero.canonicalize(raw, path);
    }

    /// @dev 读环境变量的那个重载。只给 `test_pinnedHashesComeFromTheEnvironment` 用 ——
    ///      forge 并行跑同一合约里的各条测试，而环境变量是进程级的，多写一条就会打架。
    function requireDeployableFromEnv(VersionZero.Texts memory texts) external view {
        VersionZero.requireDeployable(texts);
    }
}

/// @notice version 0 的文本、哈希，以及**主网部署的显式前置检查**。
///
/// 这套检查要挡的失误只有一种，但它不可逆：把还没过法律意见的占位文本写进
/// `versions[0]` 并发到主网。那条记录一经上链就永久存在、无法删改，而任意地址恒可用它
/// 通过行权门槛（不变量 6③）—— 也就是说**它是全体用户唯一保证可用的那一版文本**。
contract VersionZeroTest is Test {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant SOME_TESTNET_CHAIN_ID = 11_155_111;

    /// @dev Robinhood Chain 的公开测试网 —— **我们真的会往那里部署**（issue #65），
    ///      不像上面那个 Sepolia 只是「随便一条非主网」。见 {test_robinhoodTestnetTakesTheNonMainnetBranch}。
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;

    /// @dev 🔴 **第二条主网**（决策 56）。它走主网分支这件事由
    ///      {test_bscTakesTheMainnetBranch} 单独钉死。
    uint256 internal constant BSC_CHAIN_ID = 56;

    /// @dev 定稿哈希（2026-08-26，权威文本为英文，issue #18）。与 `.env.example` 里
    ///      `ATTESTATION_V0_*_HASH` 的值、以及 `cast keccak -- "$(cat <文件>)"` 的复算值
    ///      三处必须相同 —— 这里钉的就是链上 `versions[0]` 将指向的那两个字节串。
    bytes32 internal constant FINAL_TERMS_HASH = 0x918ec44c764a8a830c3cf13f8a67b5cca430cd5866d3bfefa7e25390129e29ab;
    bytes32 internal constant FINAL_ATTESTATION_HASH =
        0xe760c38dcca7cc6cb2e151e2c91521f89890ce053d6cbfd1f0319ff88045bd64;

    /// @dev BSC（56）那份 terms 的定稿哈希（2026-09-10 定稿）。
    ///
    ///      🔴 **只有 terms 有单独的值。** `attestation.en.txt` 两条链逐字节相同（它讲的是
    ///      用户本人，与抵押品发行方无关），所以 BSC 复用上面那个 {FINAL_ATTESTATION_HASH} ——
    ///      这一点由 {test_bscReadsItsOwnLegalDirectory} 断言。给 attestation 再钉一个同值的
    ///      常量只会让「两链是否共用」这个事实变得可疑。
    bytes32 internal constant FINAL_TERMS_HASH_BSC =
        0xe864e266e4d398abb519939899dc94ca6e80a4a8125de348e6eb0681b71b16b6;

    VersionZeroHarness internal harness;

    function setUp() public {
        harness = new VersionZeroHarness();
    }

    // ──────────────────────────── 文件与哈希 ────────────────────────────

    /// @dev 🔴 **这是一条绊线，不是普通断言。** version 0 已于 2026-08-26 定稿：权威文本为英文，
    ///      定稿依据与多语安排的记录见 `legal/attestation-v0/README.md`（issue #18）。
    ///      这条测试把「定稿」这个状态钉住：它红了只意味着有人动了定稿文本的字节，
    ///      或给它加回了草稿标记。那两个文件一个字节都不许再动 ——
    ///      链上 `versions[0]` 的哈希将永久指向这一版。
    function test_shippedTextIsFinalized() public view {
        VersionZero.Texts memory texts = VersionZero.load();

        assertFalse(VersionZero.isDraft(texts), unicode"version 0 已定稿，不得再带草稿标记");
        assertEq(
            texts.termsHash,
            FINAL_TERMS_HASH,
            unicode"terms.en.txt 的字节与定稿版不符 —— 定稿文本不可再改"
        );
        assertEq(
            texts.attestationHash,
            FINAL_ATTESTATION_HASH,
            unicode"attestation.en.txt 的字节与定稿版不符 —— 定稿文本不可再改"
        );
    }

    function test_hashes_areRealAndDistinct() public view {
        VersionZero.Texts memory texts = VersionZero.load();

        assertTrue(texts.termsHash != bytes32(0), "termsHash");
        assertTrue(texts.attestationHash != bytes32(0), "attestationHash");
        assertTrue(texts.termsHash != texts.attestationHash, unicode"两段文本不该同哈希");
        assertEq(texts.termsHash, keccak256(bytes(texts.terms)), unicode"哈希取自正文本身");
        assertEq(texts.attestationHash, keccak256(bytes(texts.attestation)));
    }

    /// @dev 一个文件一行文本，是为了让 `cast keccak -- "$(cat 文件)"` 逐字节复现链上的哈希 ——
    ///      「用户能自己复算」是这套哈希纪律的全部意义。
    ///      ⚠️ `$( )` 剥掉的是结尾**所有**换行，不是一个。所以「多于一个结尾 LF」被拒**不是**
    ///      因为复算会对不上（不会），而是为了让哈希与文件字节一一对应。
    function test_textFilesAreExactlyOneLine() public view {
        _assertCanonical(VersionZero.TERMS_PATH);
        _assertCanonical(VersionZero.ATTESTATION_PATH);
    }

    /// @dev 🔴 直接走**部署时用的那套规则**，不另写一份。
    ///      早先这里是一份独立的检查，于是两套规则在两个方向上都跑偏了：
    ///      裸 `"\n"` 能过这里却被 loader 拒，BOM 能过 loader 却被这里拒。
    ///      一套规则、一处维护，分歧就不可能存在。
    function _assertCanonical(string memory path) private view {
        bytes memory raw = bytes(vm.readFile(path));
        string memory body = harness.canonicalize(raw, path);

        assertEq(
            bytes(body).length,
            raw.length - 1,
            string.concat(path, unicode" 正文应当只比文件少那个结尾 LF")
        );
    }

    /// @dev 合规的形状只有一种：一行正文 + **恰好一个**结尾 LF。
    ///      走文件系统构造这些输入需要写盘权限，而 `fs_permissions` 是只读的、也应当保持只读，
    ///      所以直接喂字节。
    function test_canonicalize_acceptsOnlyTheCanonicalShape() public view {
        assertEq(
            harness.canonicalize(bytes(unicode"文本\n"), "t"),
            unicode"文本",
            unicode"去掉那个唯一的结尾 LF"
        );

        // ⚠️ 这条只钉住 **Solidity 那一半**：哈希 == 文件去掉结尾 LF。
        // shell 那一半（`cast keccak -- "$(cat 文件)"` 真的算出同一个值）在**这里断言不了** ——
        // foundry 的测试跑不了外部命令。那一半由 CI 的「version 0 哈希可复算」那一步负责。
        assertEq(
            keccak256(bytes(harness.canonicalize(bytes(unicode"文本\n"), "t"))),
            keccak256(bytes(unicode"文本")),
            unicode"链上哈希必须等于「文件去掉结尾 LF」的哈希"
        );
    }

    /// @dev 🔴 **不合规范一律拒绝，不做「修正」。**
    ///      归一化会让 `"文本\n"` 与 `"文本\r\n"` 落到同一个哈希：法律意见之后文件被存成 CRLF，
    ///      钉死的哈希照样能过、部署照样成功，但用户拿 README 里那条命令算出来的是**另一个值**。
    ///      审核对象与部署对象就此脱节，而这个工件不可逆。
    ///
    ///      下面每一条都对应一种**实测过的**分叉或歧义，不是防御性想象。
    function test_canonicalize_rejectsTheseNonCanonicalShapes() public {
        // ① CRLF —— 本次修复的起点
        _expectReject(
            unicode"文本\r\n",
            unicode'含 CR —— 行尾必须是 LF。CRLF 会让 cast keccak "$(cat 文件)" 复算出另一个哈希'
        );
        _expectReject(
            unicode"文\r本\n",
            unicode'含 CR —— 行尾必须是 LF。CRLF 会让 cast keccak "$(cat 文件)" 复算出另一个哈希'
        );

        // ② 其余控制字符 —— NUL 与 CR 同类：进得了链上哈希，进不了 argv。
        //    bash 会把它丢掉并只警告一句，zsh / fish 直接在那里截断，三者答案各不相同。
        _expectReject(
            unicode"ab\x00cd\n",
            unicode"正文含控制字符 —— 它进得了链上哈希，却进不了复算命令的 argv，两边必然对不上"
        );
        _expectReject(
            unicode"ab\x0bcd\n",
            unicode"正文含控制字符 —— 它进得了链上哈希，却进不了复算命令的 argv，两边必然对不上"
        );

        // ③ 以 - 开头 —— 实测 `cast keccak "$(cat 文件)"` 把 `--json` 当开关吃掉，
        //    静默返回 keccak("")，退出码 0，没有任何警告
        _expectReject(
            unicode"--json\n",
            unicode"正文以 - 开头 —— cast 会把它当成命令行开关，复算命令会静默算出别的值"
        );

        // ④ 以 0x 开头 —— cast 会把参数按十六进制**解码**再哈希；加 `--` 也拦不住
        _expectReject(
            unicode"0xdeadbeef\n",
            unicode"正文以 0x 开头 —— cast keccak 会把它按十六进制解码，复算命令会静默算出别的值"
        );

        // ⑤ BOM —— 两边哈希其实一致，但律师看到的字与链上哈希的字节可能不是一回事
        _expectReject(
            string(abi.encodePacked(hex"efbbbf", unicode"文本\n")),
            unicode"带 UTF-8 BOM —— 不可见的三个字节会一起进哈希，肉眼分不出签的是哪一版"
        );

        // ⑥ 结尾 LF 的数量。注意：`$( )` 剥掉的是**所有**结尾换行，所以「多于一个」并不会让复算对不上；
        //    拒绝它是为了让哈希与文件字节**一一对应**，两个不同的文件不该落到同一个哈希。
        _expectReject(unicode"文本", unicode"结尾必须有一个 LF —— 见同目录 README 的字节规范");
        _expectReject(
            unicode"文本\n\n",
            unicode"正文含换行 —— 一个文件必须是一行正文加恰好一个结尾 LF"
        );
        _expectReject(
            unicode"第一行\n第二行\n",
            unicode"正文含换行 —— 一个文件必须是一行正文加恰好一个结尾 LF"
        );

        // ⑦ 空
        _expectReject("\n", unicode"正文为空 —— 整个文件只有一个结尾 LF");
        _expectReject("", unicode"是空文件");
    }

    function _expectReject(string memory raw, string memory reason) private {
        vm.expectRevert(bytes(string.concat(unicode"VersionZero: t ", reason)));
        harness.canonicalize(bytes(raw), "t");
    }

    // ─────────────────────────── 主网前置检查 ───────────────────────────

    function test_testnetsAllowPlaceholderText() public {
        vm.chainId(SOME_TESTNET_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();
        harness.requireDeployable(texts, bytes32(0), bytes32(0)); // 不 revert 即可
    }

    /// @notice 🔴 **46630 走的是「非主网告警放行」那条分支**（M3 W2 / issue #65）。
    ///
    /// @dev 上面那条拿 Sepolia 证的是「非主网一律放行」这条通则；这一条单独钉 46630，因为它是
    ///      我们**真的会部署上去**的那条链 —— 而这道门的取值决定了测试网彩排的成本：
    ///
    ///      · 走非主网分支（现状）：测试网彩排不需要钉哈希，`deployments/46630.planned.json`
    ///        里 `attestationV0IsDraft` 如实记录文本状态，任何人一眼看得出那条链上签的是哪一版。
    ///      · 若哪天有人把 46630 也算进主网闸门，测试网彩排就会在 `VersionZero` 这一步整个部署不了，
    ///        而报出来的是一句「必须钉死哈希」—— 与「测试网」这三个字毫无关系的错误。
    ///
    ///      所以这里连**最糟的输入**都给足：草稿文本 + 两个哈希都没钉。它仍然必须放行。
    ///      同一件事在部署脚本那一侧的可观测结果，见 `test/DeploySystem.t.sol` 的
    ///      `DeploySystemRobinhoodTestnetTest`。
    function test_robinhoodTestnetTakesTheNonMainnetBranch() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        VersionZero.Texts memory texts = _draft();

        assertTrue(VersionZero.isDraft(texts), unicode"前提：这份合成输入确实带草稿标记");
        harness.requireDeployable(texts, bytes32(0), bytes32(0)); // 不 revert 即可
    }

    function test_mainnetRejectsDraftText() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = _draft();
        // 就算哈希钉对了也照样拦 —— 草稿是草稿
        _expectRejection(texts, texts.termsHash, texts.attestationHash, unicode"仍带草稿标记");
    }

    function test_mainnetRejectsFinalizedTextWithoutPinnedHashes() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        _expectRejection(VersionZero.load(), bytes32(0), bytes32(0), unicode"必须显式钉死定稿核准的哈希");
    }

    function test_mainnetRejectsTextThatDriftedAfterLegalReview() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();

        // 法律意见签的是别的文本 —— 也就是文件在意见之后被改过
        _expectRejection(texts, keccak256("some other terms"), texts.attestationHash, "terms.en.txt");
        _expectRejection(texts, texts.termsHash, keccak256("some other attestation"), "attestation.en.txt");
    }

    function test_mainnetAcceptsFinalizedTextWithMatchingPinnedHashes() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();
        harness.requireDeployable(texts, texts.termsHash, texts.attestationHash); // 不 revert 即可
    }

    /// @dev 钉死的哈希确实是从 `ATTESTATION_V0_*_HASH` 读进来的。
    ///      🔴 **本文件里只有这一条碰环境变量。** forge 并行跑同一合约里的各条测试，
    ///      环境变量却是进程级的 —— 再加一条就会随机互相打架（已踩过）。
    function test_pinnedHashesComeFromTheEnvironment() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory texts = VersionZero.load();

        vm.setEnv(VersionZero.ENV_TERMS_HASH, vm.toString(texts.termsHash));
        vm.setEnv(VersionZero.ENV_ATTESTATION_HASH, vm.toString(texts.attestationHash));
        harness.requireDeployableFromEnv(texts);

        vm.setEnv(VersionZero.ENV_TERMS_HASH, vm.toString(keccak256("some other terms")));
        vm.expectRevert();
        harness.requireDeployableFromEnv(texts);
    }

    // ──────────────────────────── 第二条主网：BSC ────────────────────────────

    /// @notice 🔴 **BSC 走的是主网分支。**
    ///
    /// @dev 这条测试的存在理由，是它红过的那个形状：`requireDeployable` 早先拿
    ///      `block.chainid != ROBINHOOD_CHAIN_ID` 做等值判断，于是**第二条主网出现的那一刻**，
    ///      BSC 会安静地落进「非主网 → 跳过定稿检查」那条分支，把带草稿标记的占位文本
    ///      **永久**写进 `versions[0]`（不可删改，不变量 6③）。
    ///
    ///      给足最糟的输入：草稿文本 + 两个哈希都没钉。它必须被挡下来，而且理由必须是「草稿」。
    function test_bscTakesTheMainnetBranch() public {
        vm.chainId(BSC_CHAIN_ID);
        _expectRejection(_draft(), bytes32(0), bytes32(0), unicode"仍带草稿标记");
    }

    /// @notice BSC 读的是**它自己那份**法律文本，不是 4663 的。
    ///
    /// @dev 两条链的抵押品发行方不同、权限面不同（bStocks vs Robinhood Stock），
    ///      而 4663 的 `versions[0]` 已上链且不可替换 —— 所以两份文本必须能各读各的。
    ///      见 `legal/attestation-v0-bsc/README.md` 与决策 56。
    function test_bscReadsItsOwnLegalDirectory() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        VersionZero.Texts memory rh = VersionZero.load();

        vm.chainId(BSC_CHAIN_ID);
        VersionZero.Texts memory bsc = VersionZero.load();

        assertEq(rh.termsHash, FINAL_TERMS_HASH, unicode"4663 读到的仍是定稿那一版 terms");
        assertTrue(
            bsc.termsHash != rh.termsHash,
            unicode"BSC 必须读到另一份 terms —— 否则「按 chainId 选目录」根本没生效"
        );

        // ATTESTATION 讲的是**用户本人**（不是美国居民…），与抵押品发行方无关，
        // 两条链刻意共用同一段文本 —— 所以这两个哈希**应当**相等。
        assertEq(
            bsc.attestationHash,
            rh.attestationHash,
            unicode"attestation 两链逐字节相同，哈希也应当相同"
        );
    }

    /// @notice BSC 那两个文件同样要过字节规范。
    function test_bscTextFilesAreExactlyOneLine() public view {
        _assertCanonical(VersionZero.TERMS_PATH_BSC);
        _assertCanonical(VersionZero.ATTESTATION_PATH_BSC);
    }

    /// @notice 🔴 **绊线（与 4663 那条 {test_shippedTextIsFinalized} 对称）：BSC 的文本已定稿。**
    ///
    /// @dev 这条测试此前是反向的 —— 它断言 BSC 那份**仍是草稿**，并在有人定稿的那一刻红掉、
    ///      用失败信息交代该做哪两步。2026-09-10 维护者去掉了 `[DRAFT]` 标记，那条绊线按设计
    ///      触发，于是它换成了现在这个方向：钉死定稿那一版的字节。
    ///
    ///      它红了意味着有人动了 BSC 定稿文本的字节，或给它加回了草稿标记 —— 而
    ///      `versions[0]` 一经上链**永久指向这一版**（不可删改，不变量 6③），BSC 的注册表
    ///      与 4663 的是**两个**互不相干的实例，各自只有一次机会。
    function test_bscTextIsFinalized() public {
        vm.chainId(BSC_CHAIN_ID);
        VersionZero.Texts memory bsc = VersionZero.load();

        assertFalse(VersionZero.isDraft(bsc), unicode"BSC 的 version 0 已定稿，不得再带草稿标记");
        assertEq(
            bsc.termsHash,
            FINAL_TERMS_HASH_BSC,
            unicode"attestation-v0-bsc/terms.en.txt 的字节与定稿版不符 —— 定稿文本不可再改"
        );
        assertEq(
            bsc.attestationHash,
            FINAL_ATTESTATION_HASH,
            unicode"BSC 的 attestation 与 4663 逐字节相同，哈希也应当相同"
        );
    }

    /// @notice `isMainnet` 这张表本身。
    function test_isMainnetTable() public pure {
        assertTrue(VersionZero.isMainnet(4663), "4663");
        assertTrue(VersionZero.isMainnet(56), "56");
        assertFalse(VersionZero.isMainnet(46_630), unicode"Robinhood 测试网不是主网");
        assertFalse(VersionZero.isMainnet(97), unicode"BSC 测试网不是主网");
        assertFalse(VersionZero.isMainnet(31_337), unicode"本地链不是主网");
        assertFalse(VersionZero.isMainnet(1), unicode"以太坊主网不是我们的主网");
    }

    // ───────────────────────────── 部署脚本 ─────────────────────────────

    /// @dev 部署与「追加 version 0」是同一件事的两半：只部署不追加，得到的是一个
    ///      `attest()` 对所有人都 revert 的注册表 —— 门被焊死的样子。
    function test_deployScript_leavesTheGateOpen() public {
        address publisher = makeAddr("publisher");
        AttestationRegistry registry = new DeployAttestationRegistry().deploy(publisher);

        VersionZero.Texts memory texts = VersionZero.load();

        assertEq(registry.publisher(), publisher, "publisher");
        assertEq(registry.versionCount(), 1, unicode"部署后恰好一版文本");

        (bytes32 termsHash, bytes32 attestationHash) = registry.versions(0);
        assertEq(termsHash, texts.termsHash, unicode"链上 termsHash 来自 legal/ 下的文件");
        assertEq(attestationHash, texts.attestationHash, unicode"链上 attestationHash 来自 legal/ 下的文件");

        address stranger = makeAddr("someone who has never touched this chain");
        vm.prank(stranger);
        registry.attest(0, texts.termsHash, texts.attestationHash);
        assertEq(registry.attestedVersion(stranger), 1, unicode"陌生地址必须能自行通过门槛");
    }

    // ────────────────────────────── 辅助 ──────────────────────────────

    /// @dev 一份**带草稿标记**的合成文本。仓库里已经没有草稿了（version 0 定稿于 2026-08-26），
    ///      但「草稿进不了主网」「非主网连草稿都放行」这两条路径仍要有覆盖。
    function _draft() private pure returns (VersionZero.Texts memory texts) {
        texts.terms = "[DRAFT: placeholder terms awaiting finalization.]";
        texts.attestation = "[DRAFT: placeholder attestation awaiting finalization.]";
        texts.termsHash = keccak256(bytes(texts.terms));
        texts.attestationHash = keccak256(bytes(texts.attestation));
    }

    function _expectRejection(
        VersionZero.Texts memory texts,
        bytes32 reviewedTerms,
        bytes32 reviewedAttestation,
        string memory expectedFragment
    ) private {
        try harness.requireDeployable(texts, reviewedTerms, reviewedAttestation) {
            fail(string.concat(unicode"本该被主网前置检查拦住，却放行了：", expectedFragment));
        } catch Error(string memory reason) {
            assertTrue(
                _contains(reason, expectedFragment),
                string.concat(
                    unicode"挡下来的理由不对。期望包含「",
                    expectedFragment,
                    unicode"」，实际：",
                    reason
                )
            );
        }
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
