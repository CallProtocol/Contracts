// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";

/// @notice 一个用**合约账户**身份签署的钱包。
///
/// 🔴 只用 EOA 做探针，会让一整类锁死方式隐形：`require(msg.sender == tx.origin)`、
/// `require(msg.sender.code.length == 0)` 之类的门在 EOA 探针下全部通过，
/// 却会把每一个多签与智能钱包**永久**挡在行权之外。所以探针里必须有一个真的合约。
contract AttestingWallet {
    AttestationRegistry private immutable registry;

    constructor(AttestationRegistry registry_) {
        registry = registry_;
    }

    /// @dev 低层 call，成不成都返回给调用方 —— handler 不能 revert。
    function attest(uint256 v, bytes32 termsHash, bytes32 attestationHash) external returns (bool ok) {
        (ok,) = address(registry).call(abi.encodeCall(AttestationRegistry.attest, (v, termsHash, attestationHash)));
    }
}

/// @notice 驱动 `AttestationRegistry` 的 handler。
///
/// 🔴 **本合约的任何函数都不 revert。** 不变量测试跑在 `fail_on_revert = false` 下，
/// 而 handler 里的 `assertEq` 失败就是一次 revert —— 会被 fuzzer 静静吞掉，
/// 于是断言写了等于没写。所以这里把违规**记进计数器**，由 `invariant_*` 去断言计数为零；
/// 对注册表的调用一律走低层 `call`，成不成都不影响记录。
///
/// 计数器本身能不能真的抓到违规，由 `test_theDetectorDetects_*` 那几条确定性测试反证。
contract AttestationHandler is CommonBase, StdUtils {
    AttestationRegistry public immutable registry;

    /// @dev 构造当时 `versions[0]` 的两个哈希。不变量 6③ 断言的是**这一版**永远可声明。
    bytes32 public immutable terms0;
    bytes32 public immutable attestation0;

    /// @dev 被跟踪的账户。publisher 也在里面 —— 它对自己的声明状态和别人一样，
    ///      只能自己写；「publisher 也改不了别人」因此落在同一条规则下。
    address[] public actors;

    /// @notice 每个 actor 历史上观测到的最大 `attestedVersion`。
    mapping(address account => uint256 seen) public highWater;

    /// @notice 不变量 6①：`attestedVersion` 出现过下降的次数。必须恒为 0。
    uint256 public decreaseViolations;
    /// @notice 不变量 6②：某次调用里，非调用者的声明状态被改动的次数。必须恒为 0。
    uint256 public foreignWriteViolations;
    /// @notice 不变量 6③：`versions[0]` 与构造当时不一致的观测次数。必须恒为 0。
    uint256 public version0MutationViolations;
    /// @notice 不变量 6③：探针 `attest(0, …)` 之后仍未通过门槛的次数。必须恒为 0。
    /// @dev 三类探针各记一次：全新 EOA、老兵（已签过更新版本）、合约钱包。见 `_probeGate`。
    uint256 public gateClosedViolations;

    /// @dev 覆盖度计数。fuzz 参数**刻意偏向合法**（见 `attest`），所以这两个数在每一轮里
    ///      都会远大于 0；`test_handlerReachesTheSuccessPaths` 把这件事钉死成确定性断言。
    uint256 public successfulAttests;
    uint256 public versionsAdded;

    /// @dev 合约账户探针。见 `AttestingWallet` 的注释。
    AttestingWallet public immutable wallet;

    /// @dev 老兵探针：**已经声明过、而且尽量声明的是更新版本**的那个地址。
    ///      它盯的是「取大而不是严格递增」买来的那条性质 —— 签过新版本之后再签 version 0
    ///      仍然成功。全新地址的探针永远碰不到这条路径。
    address internal constant VETERAN = address(uint160(uint256(keccak256("index-rein: veteran gate probe"))));

    uint256 private probes;

    constructor(AttestationRegistry registry_, address[] memory actors_) {
        registry = registry_;
        actors = actors_;
        (bytes32 t, bytes32 a) = registry_.versions(0);
        terms0 = t;
        attestation0 = a;
        wallet = new AttestingWallet(registry_);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ────────────────────────────── 动作 ──────────────────────────────

    /// @dev 版本与哈希都**偏向合法**（各 7/8）。均匀取的话一整轮里连一次成功声明都没有的概率
    ///      高到会让这轮不变量变成空转：三条断言全是「某个计数为 0」，什么都没干过时它们同样成立。
    ///      非法档位仍各占 1/8，越界版本与三种错哈希的覆盖不缺。
    function attest(
        uint256 actorSeed,
        uint256 versionSeed,
        uint256 hashSeed,
        bytes32 junkTerms,
        bytes32 junkAttestation
    ) external {
        uint256 known = registry.versionCount();
        uint256 v = versionSeed % 8 == 0 ? known + (versionSeed % 3) : bound(versionSeed, 0, known - 1);

        bytes32 termsHash;
        bytes32 attestationHash;
        if (v < known) (termsHash, attestationHash) = registry.versions(v);

        if (hashSeed % 8 == 0) {
            uint256 which = (hashSeed / 8) % 3;
            if (which == 0) termsHash = junkTerms;
            else if (which == 1) attestationHash = junkAttestation;
            else (termsHash, attestationHash) = (junkTerms, junkAttestation);
        }

        bool ok = _act(_actor(actorSeed), abi.encodeCall(AttestationRegistry.attest, (v, termsHash, attestationHash)));
        if (ok) successfulAttests++;
    }

    /// @dev 同样偏向合法：约 3/4 由 publisher（`actors[0]`）发起，理由同上。
    function addVersion(uint256 senderSeed, bytes32 termsHash, bytes32 attestationHash) external {
        address sender = senderSeed % 4 == 0 ? _actor(senderSeed) : actors[0];
        bool ok = _act(sender, abi.encodeCall(AttestationRegistry.addVersion, (termsHash, attestationHash)));
        if (ok) versionsAdded++;
    }

    /// @dev 拿选择器加 `(账户, 数值)` 参数去撞注册表：一半是纯随机的 4 字节，
    ///      一半来自下面那张「后门通常长什么名字」的表。参数里放的是**被跟踪的 actor**，
    ///      所以真有 `clear(address)` 之类的入口被撞上，会立刻表现为 6② 的违规，
    ///      而不是打在一个没人看的地址上。
    ///
    ///      ⚠️ **这不是「没有后门」的证明，只是一张撒开的网**：纯随机那一半在 2^32 的选择器空间里
    ///      基本撞不到东西，命中率全靠那张名字表。结构性的证明在
    ///      `test/AttestationRegistry.t.sol` 的 `test_writeSurface_isExactlyAddVersionAndAttest`
    ///      —— 它直接枚举编译产物的 ABI，按**完整签名**断言可写入口恰好是那两个。
    function pokeUnknown(uint256 senderSeed, uint32 selectorSeed, uint256 targetSeed, uint256 value) external {
        bytes memory data = abi.encodePacked(_selector(selectorSeed), abi.encode(_actor(targetSeed), value));
        _act(_actor(senderSeed), data);
    }

    /// @dev 「任意**时刻**」这一维。门不该随时间关上。
    ///
    ///      🔴 上界给到 500 天，不是几十天：一颗「部署满一年后 `attest` 开始 revert」的定时炸弹
    ///      在 ABI 上完全看不出来，只有把时间真的推过那条线才会暴露。一轮 64 步、每步期望约 250 天，
    ///      横跨的时间尺度足够越过「一年」这一档最可能被写出来的期限。
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 500 days));
        _observeVersion0();
        _probeGate();
    }

    // ────────────────────────────── 记录 ──────────────────────────────

    function _act(address actor, bytes memory data) private returns (bool ok) {
        uint256 n = actors.length;
        uint256[] memory before = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            before[i] = registry.attestedVersion(actors[i]);
        }

        // prank 只作用于紧接着的**下一次**外部调用，所以快照必须在它之前取完。
        vm.prank(actor);
        (ok,) = address(registry).call(data);

        for (uint256 i = 0; i < n; i++) {
            address who = actors[i];
            uint256 current = registry.attestedVersion(who);

            if (current < before[i]) decreaseViolations++;
            if (who != actor && current != before[i]) foreignWriteViolations++;
            if (current > highWater[who]) highWater[who] = current;
        }

        _observeVersion0();
        _probeGate();
    }

    function _observeVersion0() private {
        (bytes32 t, bytes32 a) = registry.versions(0);
        if (t != terms0 || a != attestation0) version0MutationViolations++;
    }

    /// @dev 不变量 6③ 的落点：**此时此刻，任意地址**能不能靠 `attest(0, …)` 通过门槛。
    ///
    ///      「任意」得真的覆盖到三类，少一类就有一整类锁死方式隐形：
    ///
    ///      | 探针 | 它独家覆盖的锁死方式 |
    ///      |---|---|
    ///      | 全新 EOA | 常规路径 |
    ///      | 老兵（已签过更新版本） | 严格递增式的 `require` —— 只挡「回头签旧版本」的人 |
    ///      | 合约钱包 | `msg.sender == tx.origin` / `code.length == 0` —— 只挡多签与智能钱包 |
    ///
    ///      三个都用**构造当时**记下的哈希，而不是现读 `versions[0]` ——
    ///      否则「版本 0 被换掉了，但新文本也能签」会被当成通过。
    function _probeGate() private {
        // ① 全新地址
        _probeOne(address(uint160(uint256(keccak256(abi.encode("index-rein: gate probe", probes))))));
        probes++;

        // ② 老兵：先尽量把它推到最新版本，再让它回头签 version 0
        uint256 known = registry.versionCount();
        if (known > 1) {
            (bytes32 t, bytes32 a) = registry.versions(known - 1);
            vm.prank(VETERAN);
            address(registry).call(abi.encodeCall(AttestationRegistry.attest, (known - 1, t, a)));
        }
        _probeOne(VETERAN);

        // ③ 合约账户 —— 它自己发起调用，msg.sender 是合约，tx.origin 不是
        if (!wallet.attest(0, terms0, attestation0) || registry.attestedVersion(address(wallet)) == 0) {
            gateClosedViolations++;
        }
    }

    function _probeOne(address probe) private {
        vm.prank(probe);
        (bool ok,) = address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, terms0, attestation0)));
        if (!ok || registry.attestedVersion(probe) == 0) gateClosedViolations++;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev 一半纯随机，一半来自这张表。表里是「后门如果存在，多半叫这个名字」的形状 ——
    ///      全部收 `(address, uint256)`，正好对上 `pokeUnknown` 拼出来的 calldata。
    function _selector(uint32 seed) private pure returns (bytes4) {
        if (seed % 2 == 0) return bytes4(seed);

        string[8] memory names = [
            "reset(address)",
            "clear(address)",
            "revoke(address)",
            "revokeAttestation(address)",
            "setAttestedVersion(address,uint256)",
            "attestFor(address,uint256)",
            "adminSetAttested(address,uint256)",
            "removeVersion(uint256)"
        ];
        return bytes4(keccak256(bytes(names[(seed / 2) % 8])));
    }
}

/// @notice **只用于反证 handler 的探测器真的会响。** 它把不变量 6 要禁止的两件事做成了函数：
///         清零别人的声明状态，以及改写 `versions[0]`。生产合约里两者都不存在
///         —— 这一点由 `test_writeSurface_isExactlyAddVersionAndAttest` 枚举 ABI 证明。
contract BackdoorRegistry is AttestationRegistry {
    constructor(address publisher_, bytes32 termsHash, bytes32 attestationHash)
        AttestationRegistry(publisher_, termsHash, attestationHash)
    {}

    function clear(address account) external {
        attestedVersion[account] = 0;
    }

    function tamper(bytes32 termsHash, bytes32 attestationHash) external {
        versions[0] = TextVersion(termsHash, attestationHash);
    }
}

/// @notice **不变量 6 —— 声明门不可锁死。**
///
/// | 款 | 断言 |
/// |---|---|
/// | ① | `attestedVersion[a]` 对任意 `a` 单调不减 |
/// | ② | 仅 `a` 自身可改 |
/// | ③ | `versions[0]` 存在且不可变 ⟹ **任意地址恒可通过 `attest(0,…)` 满足门槛** |
///
/// 不变量 5 与 6 是本项目仅有的两条「证明某个开关**不存在**」的手段（`spec.zh.md` §7）。
/// 它们要挡的是：有人在行权路径上留一个管理员可控的前置检查，从而获得冻结全体用户资产的能力。
contract Invariant6AttestationGateTest is Test {
    AttestationRegistry internal registry;
    AttestationHandler internal handler;

    address internal publisher = makeAddr("publisher");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    function setUp() public {
        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        handler = new AttestationHandler(registry, _actors());
        targetContract(address(handler));
    }

    function _actors() private returns (address[] memory actors) {
        actors = new address[](5);
        actors[0] = publisher; // 🔴 必须在列：「publisher 也不能改别人」与第三方同规则
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
        actors[4] = address(this);
    }

    // ─────────────────────────── 不变量 6 三款 ───────────────────────────

    /// @notice 6① `attestedVersion` 单调不减。
    function invariant_6a_attestedVersionNeverDecreases() public view {
        assertEq(handler.decreaseViolations(), 0, unicode"不变量 6①：attestedVersion 出现过下降");

        // 下面这段不是重复：handler 的计数器只看**单次动作前后**，
        // 而这里比的是 fuzz 序列里跨越任意多次动作的历史最大值 ——
        // 「悄悄降一点、下一步再涨回来」只有这一层抓得到。
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address who = handler.actors(i);
            assertGe(
                registry.attestedVersion(who),
                handler.highWater(who),
                unicode"不变量 6①：当前值低于历史观测最大值"
            );
        }
    }

    /// @notice 6② 只有账户本人能改自己的声明状态 —— publisher 与第三方都不能。
    function invariant_6b_onlyTheAccountItselfCanWrite() public view {
        assertEq(
            handler.foreignWriteViolations(), 0, unicode"不变量 6②：有人改动了别人的 attestedVersion"
        );
    }

    /// @notice 6③ `versions[0]` 存在且不可变 ⟹ 任意地址恒可通过 `attest(0,…)` 满足门槛。
    function invariant_6c_version0IsImmutableAndAlwaysAttestable() public view {
        assertEq(handler.version0MutationViolations(), 0, unicode"不变量 6③：versions[0] 被改动过");
        assertEq(
            handler.gateClosedViolations(),
            0,
            unicode"不变量 6③：某类探针（全新 EOA / 老兵 / 合约钱包）attest(0, …) 之后仍未通过门槛"
        );

        (bytes32 terms, bytes32 attestation) = registry.versions(0);
        assertEq(terms, TERMS_0, unicode"versions[0].termsHash");
        assertEq(attestation, ATTESTATION_0, unicode"versions[0].attestationHash");
    }

    // ──────────────────── 反证：上面三条不是空转 ────────────────────

    /// @dev 三条不变量全是「某个计数为 0」，而一个**什么都没干成**的 handler 同样满足它们。
    ///      这里确定性地证明两条成功路径确实走得通 —— fuzz 参数偏向合法，所以每一轮都会大量命中。
    function test_handlerReachesTheSuccessPaths() public {
        // versionSeed=1 ⇒ 合法版本；hashSeed=1 ⇒ 用真哈希
        handler.attest(1, 1, 1, bytes32(0), bytes32(0));
        assertEq(handler.successfulAttests(), 1, unicode"handler 的 attest 走不到成功路径");

        // senderSeed=1 ⇒ 非 0 模 4 ⇒ publisher
        handler.addVersion(1, keccak256("terms"), keccak256("attestation"));
        assertEq(handler.versionsAdded(), 1, unicode"handler 的 addVersion 走不到成功路径");
        assertEq(registry.versionCount(), 2);
    }

    /// @dev 探测器反证 ①②：把一个「能清零别人状态」的后门装进注册表，
    ///      handler 必须当场把它记成 6① 与 6② 的违规。
    function test_theDetectorDetects_foreignWriteAndDecrease() public {
        (BackdoorRegistry bad, AttestationHandler h) = _handlerOverBackdoor();
        address alice = h.actors(1);

        vm.prank(alice);
        bad.attest(0, TERMS_0, ATTESTATION_0);
        assertEq(bad.attestedVersion(alice), 1, unicode"前置条件：alice 已声明");

        // senderSeed=2 ⇒ bob 发起；targetSeed=1 ⇒ 打的是 alice；
        // selectorSeed=3 ⇒ 走名字表且取到 names[1] == "clear(address)"（3%2=1、3/2%8=1）
        h.pokeUnknown(2, 3, 1, 0);

        assertEq(bad.attestedVersion(alice), 0, unicode"前置条件：后门确实清零了 alice");
        assertGt(h.foreignWriteViolations(), 0, unicode"6② 的探测器没响");
        assertGt(h.decreaseViolations(), 0, unicode"6① 的探测器没响");
    }

    /// @dev 探测器反证 ③：改写 `versions[0]` 之后，「版本 0 不可变」与「陌生地址恒可声明」
    ///      两个计数都必须响 —— 后者证明探针用的是**原始**哈希，而不是现读的哈希。
    function test_theDetectorDetects_version0Tampering() public {
        (BackdoorRegistry bad, AttestationHandler h) = _handlerOverBackdoor();

        bad.tamper(keccak256("replaced terms"), keccak256("replaced attestation"));
        h.warp(1); // 任意一次动作都会重新观测

        assertGt(h.version0MutationViolations(), 0, unicode"「versions[0] 不可变」的探测器没响");
        assertGt(h.gateClosedViolations(), 0, unicode"「任意地址恒可声明」的探测器没响");
    }

    function _handlerOverBackdoor() private returns (BackdoorRegistry bad, AttestationHandler h) {
        bad = new BackdoorRegistry(publisher, TERMS_0, ATTESTATION_0);
        h = new AttestationHandler(AttestationRegistry(address(bad)), _actors());
    }
}
