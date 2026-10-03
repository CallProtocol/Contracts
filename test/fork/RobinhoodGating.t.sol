// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {PausedAccessRegistry} from "../../script/rehearsal/PausedAccessRegistry.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry, IRobinhoodGatedStock} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **真实标的上的门控感知结算**（M1-6，issue #11）。
///
/// 这个文件回答两个只有真合约能回答的问题：
///
/// 🔴 **① 我们猜的那三个选择器，在真实 GME 上到底读不读得通？**
/// `pokeGating` 依次读 `paused()` → `ACCESS_CONTROLLED_REGISTRY()` → 注册表的 `isBlocked(池子)`。
/// 任何一个签名猜错，池子都会**静默**落进 fail-open —— 不 revert、不报错，只是从此再也看不见
/// 发行方的门控，「冻结时自动延期」这条产品承诺当场变成一句空话。本地替身证明不了这件事，
/// 因为替身是照着我们的猜测写的。`test_preconditions_theRealGmeIsReadable` 是本文件的第一条，
/// 也是最重要的一条。
///
/// 🔴 **② 那三个读要花多少 gas？** `GATING_READ_GAS` 是防「把健康的 view 用 gas 饿死」那条攻击的门槛，
/// 而门槛定得对不对，只有在真合约上量过才知道。
///
/// 其余四条是验收条款点名要在分叉上跑的路径：延期全路径、结算阻断攻击、fail-open 宽限、
/// 以及「只封某个持有人不产生延期」。
///
/// | 组件 | 用什么 |
/// |---|---|
/// | 抵押品 | **真实 GME**（BeaconProxy → `Stock`） |
/// | MEME | **真实 `FlapTaxTokenV3`**（EIP-1167 → 0x7777…3333） |
/// | 门控状态 | 只 mock **注册表的两个 view**；`Stock` 自己的修饰器、revert 数据、执行路径全是真的 |
/// | 我们的四个合约 | 真实部署 + 两处绑定（issue #5 的测试缝） |
contract RobinhoodGatingForkTest is ForkTest {
    /// @dev 钉死高度上的样本 MEME 与 Flap Portal。🔴 **不在这里写地址字面量** ——
    ///      它们定义在 {ForkConfig}，这里只取别名。此前同一个样本散在四个分叉测试里各写一遍，
    ///      于是「更新了配置」与「更新了全部用到它的地方」是两件事（PR #29 复审 P2）。
    ///      样本的三条性质与「不可与 latest canary 的样本互换」见 {ForkConfig} 的注释。
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev 发行方门控命中时 `Stock` 抛出的两个错误。写在这里而不是空 `expectRevert()` ——
    ///      后者连「因为别的原因失败」都会当成通过。
    error Blocked(address account);
    error IsPaused();

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev 🔴 字面量，不读 `pool.GRACE_PERIOD()`：拿被测对象自己的常量去验它自己，什么也证明不了。
    uint64 internal constant GRACE = 48 hours;

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
    uint64 internal expiry;
    uint256 internal seriesId;

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);
        meme = IERC20(FLAP_MEME);

        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        // 身份根里登记这只真实 MEME 的金库 —— 开系列那道门认的就是这条绑定（M2-5 / #37）。
        //    真实绑定由 `WarrantVaultFactory` 在 Flap 建币的同一笔交易里写下，见
        //    `test/fork/RobinhoodWarrantVaultFactory.t.sol`；这里的标的是一只**早就发射过**的代币，
        //    没有那一刻可回放，所以用替身工厂补一条同形的绑定。
        factory.bind(address(meme), address(vault));

        deal(address(gme), address(vault), 1000e18);
        vault.approve(gme, type(uint256).max);

        expiry = uint64(block.timestamp + 7 days);
        seriesId = vault.openSeries(address(meme), address(gme), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.prank(FLAP_PORTAL);
        meme.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    function _mockGlobalPause(bool paused) internal {
        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.paused, ()),
            abi.encode(paused)
        );
    }

    function _mockPoolBlocked(bool blocked) internal {
        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (address(pool))),
            abi.encode(blocked)
        );
    }

    /// @dev 「发行方升级改掉了门控 view 的接口」——池子读不通，但代币的拦截照常工作。
    function _breakTheGatingViews() internal {
        vm.mockCallRevert(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.paused, ()),
            "gating view is gone"
        );
    }

    // ────────────── 🔴 ① 我们猜的那三个选择器在真实 GME 上读得通吗 ──────────────

    /// @notice **本文件最重要的一条。**
    ///
    /// @dev 池子的门控读是三个**猜测**：`Stock` 有公开的 `paused()`；它公开自己的注册表地址；
    ///      注册表有 `isBlocked(address)`。三个里错一个，池子就永久落进 fail-open ——
    ///      而 fail-open 是**静默**的，没有任何 revert 会告诉我们猜错了。
    ///
    ///      所以这里对真实 GME poke 一次，然后断言观测结果是「干净且**读得通**」。
    ///      `unreadable == false` 这一个布尔，就是那三个签名全部成立的证明。
    function test_preconditions_theRealGmeIsReadableThroughTheGatingViews() public {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 地址上没有代码");

        // 三个读各自单独也要成立 —— 万一将来这条断言红了，先知道是哪一个坏了。
        assertFalse(IRobinhoodGatedStock(ForkConfig.GME).paused(), unicode"GME.paused() 读不通或为真");
        address issuerRegistry = IRobinhoodGatedStock(ForkConfig.GME).ACCESS_CONTROLLED_REGISTRY();
        assertEq(
            issuerRegistry,
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"GME 自己报的注册表地址与我们记的那个不一致"
        );
        assertFalse(IRobinhoodAccessRegistry(issuerRegistry).isBlocked(address(pool)), unicode"池地址不该被封");

        pool.pokeGating(ForkConfig.GME);

        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertFalse(
            g.unreadable, unicode"🔴 池子读不通真实 GME 的门控 —— 三个选择器里有一个不对"
        );
        assertFalse(g.active, unicode"分叉高度上不该有门控");
        assertEq(g.clearedAt, 0, unicode"什么都没发生过 ⟹ 没有宽限");
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"deadline 就是 expiry");
    }

    function test_rehearsalReplacementPreservesTheRegistryBeaconRole() public {
        vm.etch(ForkConfig.ROBINHOOD_ACCESS_REGISTRY, type(PausedAccessRegistry).runtimeCode);

        assertEq(
            IBeacon(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).implementation(),
            ForkConfig.EXPECTED_GME_IMPLEMENTATION,
            unicode"替身不得破坏 registry 同时承担的 beacon 角色"
        );
        assertTrue(IRobinhoodGatedStock(ForkConfig.GME).paused(), unicode"真实 GME 必须看到全局暂停");
    }

    /// @notice 🔴 ② `GATING_READ_GAS` 的实测依据就在这里。
    ///
    /// @dev 那个常量既是转发上限、也是调用方必须备足的下限。定得太低会把健康的 view 判成读不通，
    ///      定得太高会让每一次 poke 都要求一笔不必要的大额 gas。
    ///      这条把**整个** `pokeGating`（含三次冷账户读取、事件、以及 gas 门槛检查本身）
    ///      的实测开销打印出来，并断言它整个装得进**一份**读预算里 —— 也就是说单次读的真实开销
    ///      远小于预算，那条「用 gas 饿死健康 view」的攻击不可能靠正常波动撞上门槛。
    function test_gasBudget_theRealReadsFitInsideASingleBudget() public {
        uint256 budget = pool.GATING_READ_GAS();

        uint256 before = gasleft();
        pool.pokeGating(ForkConfig.GME);
        uint256 spent = before - gasleft();

        console2.log(
            string.concat(
                unicode"  真实 GME 上一次 pokeGating（冷账户）实测 ",
                vm.toString(spent),
                unicode" gas · 单次读预算 ",
                vm.toString(budget)
            )
        );

        assertLt(spent, budget, unicode"整次 poke 的开销应当装得进一份读预算");
        assertFalse(pool.gating(ForkConfig.GME).unreadable, unicode"而且它确实读通了");
    }

    /// @notice 🔴 **在本测试合约的嵌套 CALL 中，向 Pool 转发的执行 gas 会远多于 poke 实际消耗。**
    ///
    /// @dev 上一条量的是本测试合约执行一次冷 `pokeGating` 时的**消耗**。这里量的是同一个测试合约
    ///      用低级 `CALL{gas: ...}` 向 `ClearingPool` 转发多少执行 gas，Pool 才能在每次读之前留下一整份
    ///      预算（`ceil(50,000 × 64 / 63) + 调用余量`）。这是一个**嵌套调用转发量**的回归测试，
    ///      不是、也不提供 EOA 或 Monitor 顶层交易 `gasLimit` 的测量或建议。
    ///
    ///      🔴 少了这一条，开发者很容易把上一条打印的「消耗」误作这个低级 CALL 可转发的 gas，导致
    ///      `pokeGating` 撞 `NotEnoughGasToObserveGating`。所以这里并排量两个**测试合约内**的数，并把
    ///      「按消耗转发必被拒」钉死。
    ///
    ///      ⚠️ 断言刻意只有**方向**和一个宽上界，不钉具体数字：那个数随任何一次 `_readGating` 的
    ///      改动而漂，钉死只会得到一条每次改代码都要手工更新的测试。上界在那里是为了让
    ///      「有人把预算或余量调大了一个数量级」当场变红。
    function test_gasFloor_theHarnessMustForwardMoreExecutionGasThanThePokeSpends() public {
        uint256 coldPokeGasSpent = _measureColdPoke();

        // ① 测试合约把「消耗」原样转发给 Pool —— 必须被 gas floor 拒绝。
        (bool spentForwardingOk, bytes memory spentForwardingRet) = _callColdPokeWithForwardedGas(coldPokeGasSpent);
        assertFalse(spentForwardingOk, unicode"测试合约按消耗转发给 Pool 的执行 gas 竟然过了");
        assertEq(
            bytes4(spentForwardingRet),
            ClearingPool.NotEnoughGasToObserveGating.selector,
            unicode"拒绝的理由必须是 Pool 的 gas floor，不是一条裸 out-of-gas"
        );
        _assertGmeObservationIsCleanAndReadable();

        // ② 二分本测试合约向 Pool 转发的最低成功执行 gas；先把上界的成功变成事实。
        uint256 lowerForwardedPoolGas = coldPokeGasSpent; // 已知失败
        uint256 upperForwardedPoolGas = 400_000;
        (bool upperBoundOk,) = _callColdPokeWithForwardedGas(upperForwardedPoolGas);
        assertTrue(upperBoundOk, unicode"二分上界必须能由本测试合约成功转发给 Pool");
        _assertGmeObservationIsCleanAndReadable();

        while (upperForwardedPoolGas - lowerForwardedPoolGas > 1) {
            uint256 candidateForwardedPoolGas = (upperForwardedPoolGas + lowerForwardedPoolGas) / 2;
            (bool candidateOk,) = _callColdPokeWithForwardedGas(candidateForwardedPoolGas);
            if (candidateOk) upperForwardedPoolGas = candidateForwardedPoolGas;
            else lowerForwardedPoolGas = candidateForwardedPoolGas;
        }

        // 用二分结果重新跑一次：它既要成功，也必须仍是一次健康的真实 GME 观测。
        (bool minimumForwardingOk,) = _callColdPokeWithForwardedGas(upperForwardedPoolGas);
        assertTrue(minimumForwardingOk, unicode"二分出的最低转发执行 gas 必须成功");
        _assertGmeObservationIsCleanAndReadable();

        console2.log(
            string.concat(
                unicode"  真实 GME 上测试合约一次冷 pokeGating：实测消耗 ",
                vm.toString(coldPokeGasSpent),
                unicode" gas · 本测试合约以低级 CALL 向 Pool 转发的最低成功执行 gas ",
                vm.toString(upperForwardedPoolGas)
            )
        );

        assertGt(
            upperForwardedPoolGas,
            coldPokeGasSpent,
            unicode"本测试合约向 Pool 转发的最低执行 gas 必须大于实测消耗"
        );
        assertLt(
            upperForwardedPoolGas,
            200_000,
            unicode"本测试合约向 Pool 转发的最低执行 gas 涨到了不合理的量级"
        );
    }

    /// @dev 冷读路径下，本测试合约直接调用 Pool 的一次干净 poke 消耗多少 gas。
    function _measureColdPoke() private returns (uint256 spent) {
        _coolGmeGatingReadPath();
        uint256 before = gasleft();
        pool.pokeGating(ForkConfig.GME);
        spent = before - gasleft();
        _assertGmeObservationIsCleanAndReadable();
    }

    /// @dev 每个 probe 都从同一条冷的真实 GME 门控读取路径开始，并只量本测试合约向 Pool 的转发量。
    function _callColdPokeWithForwardedGas(uint256 forwardedPoolGas) private returns (bool ok, bytes memory ret) {
        _coolGmeGatingReadPath();
        (ok, ret) = address(pool).call{gas: forwardedPoolGas}(abi.encodeCall(ClearingPool.pokeGating, (ForkConfig.GME)));
    }

    /// @dev GME 是 BeaconProxy：proxy、其 beacon/门控注册表和 delegatecall implementation 都必须重新变冷。
    ///      implementation 固定引用 ForkConfig 的预期值，避免未来调用路径重构悄悄漏掉这一跳。
    function _coolGmeGatingReadPath() private {
        vm.cool(ForkConfig.GME);
        vm.cool(ForkConfig.ROBINHOOD_ACCESS_REGISTRY);
        vm.cool(ForkConfig.EXPECTED_GME_IMPLEMENTATION);
    }

    function _assertGmeObservationIsCleanAndReadable() private view {
        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertFalse(g.active, unicode"固定分叉上的真实 GME 不该处于门控中");
        assertFalse(g.unreadable, unicode"固定分叉上的真实 GME 门控读取必须健康");
        assertEq(g.clearedAt, 0, unicode"干净且从未门控的真实 GME 不该启动宽限时钟");
    }

    // ──────────────────────── 验收：延期全路径 ────────────────────────

    /// @notice 验收条款：**pause → poke → 过 expiry 后窗口仍开（转账回滚、权证不丢）
    ///         → 解除后行权立刻成功（不必等 poke）→ 观测到解除把窗口收敛为 48h、宽限内行权仍成功
    ///         → 宽限后 `settleExpired` 成功。**
    ///
    /// @dev 按的是**全局**暂停（`PAUSER_ROLE`，一次冻结全链所有股票代币）——
    ///      `Stock.paused()` 返回 `$.paused || registry.paused()`，覆盖面最大的那一档。
    function test_fullPath_pausePokeKeepsWindowOpenThenClearGraceExerciseSettle() public {
        // ① 发行方暂停，任何人 poke 留下观测
        _mockGlobalPause(true);
        vm.prank(attacker);
        pool.pokeGating(ForkConfig.GME);
        assertTrue(pool.gating(ForkConfig.GME).active, unicode"观测到门控");
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"门控中无截止");

        // ② 过了 expiry：窗口仍然开着（此刻转账被发行方挡住，权证一枚不丢）
        vm.warp(uint256(expiry) + 5 days);
        vm.prank(alice);
        vm.expectRevert(IsPaused.selector);
        pool.exercise(seriesId, 10e18, alice);
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"权证一枚没丢");

        // 门控中结算被结构性阻止 —— 这就是「自动延期」，没有任何管理员参与
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, ForkConfig.GME));
        pool.settleExpired(seriesId);

        // ③ 发行方解除 —— 🔴 **行权立刻可用，此刻还没有任何人 poke 过。**
        //    行权读的是记录，记录仍停在「门控中」⟹ 无截止；而转账已经放行。
        //    `pokeGating` 是**关窗**的动作，不是开窗的动作。
        vm.clearMockedCalls();
        assertTrue(pool.gating(ForkConfig.GME).active, unicode"前置条件：记录仍停在门控中");
        assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"前置条件：宽限时钟从未起头");

        vm.prank(alice);
        pool.exercise(seriesId, 10e18, alice);
        assertEq(gme.balanceOf(alice), 10e18, unicode"没有 poke，行权照样成功");

        // ④ 观测到解除：无截止收敛成「解除时刻 + 48h」，宽限从这一刻开始
        pool.pokeGating(ForkConfig.GME);
        uint64 clearedAt = uint64(block.timestamp);
        assertEq(pool.gating(ForkConfig.GME).clearedAt, clearedAt, unicode"解除这一刻盖章");
        assertEq(pool.exerciseDeadline(seriesId), clearedAt + GRACE, unicode"deadline = 解除 + 48h");

        // ⑤ 宽限**之内**行权仍然成功 —— 延期真正兑现的地方
        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 30e18, alice);
        assertEq(gme.balanceOf(alice), 40e18, unicode"过了 expiry 五天，两笔都领到了货");

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // ⑥ 宽限过后：行权关上，结算打开
        vm.warp(uint256(clearedAt) + GRACE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.ExerciseWindowClosed.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.exercise(seriesId, 1e18, alice);

        pool.settleExpired(seriesId);
        ClearingPool.Series memory s = pool.series(seriesId);
        assertTrue(s.settled, "settled");
        assertEq(s.remainder, DEPOSIT - 40e18, unicode"remainder = deposited − exercised");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT - 40e18, unicode"抵押品仍在池子里等着滚存");
    }

    // ──────────────────────── 验收：结算阻断攻击 ────────────────────────

    /// @notice 🔴 验收条款：**对干净标的反复 poke（含临近截止时刻、跨多区块循环），
    ///         `clearedAt` 必须不动，`settleExpired` 必须按期成功。**
    ///
    /// @dev 这是不变量 4③ 在真实标的上的确定性版本。攻击者想要的是无限期免费展期：
    ///      只要每次「干净 poke」都能推动 `clearedAt`，`clearedAt + 48h` 就永远落在未来，
    ///      结算永久 revert、滚存永不发生 —— 而他手上本该作废的权证一直有效。
    ///
    ///      循环刻意跨真实区块并推进时间，最后一轮**紧贴**截止时刻。
    function test_settlementBlockingAttack_repeatedPokesNeverMoveTheDeadline() public {
        pool.pokeGating(ForkConfig.GME);
        assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"前置条件：干净且从未盖章");

        // 从到期前一周一路推到到期前一秒，跨多个区块、换调用方
        uint256[5] memory offsets = [uint256(6 days), 3 days, 1 days, 2 hours, 1];
        for (uint256 i = 0; i < offsets.length; i++) {
            vm.warp(uint256(expiry) - offsets[i]);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(ForkConfig.GME);
            vm.prank(makeAddr("another attacker"));
            pool.pokeGating(ForkConfig.GME);

            assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"干净 poke 推动了 clearedAt");
            assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"deadline 被推走了");
        }

        // 到期那一秒：行权关上、结算开着 —— 攻击没有换来一秒钟的展期
        vm.warp(expiry);
        vm.prank(attacker);
        pool.pokeGating(ForkConfig.GME);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 1e18, alice);

        vm.prank(attacker);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"🔴 结算必须按期成功");
        assertEq(pool.series(seriesId).remainder, DEPOSIT, "remainder");
    }

    // ──────────────────────── 验收：fail-open 宽限 ────────────────────────

    /// @notice 验收条款：**令门控 view revert → 48h 内不得结算 → 之后必须可结算；
    ///         窗口内二次 revert 不得重新盖 `clearedAt`。**
    ///
    /// @dev fail-open 的理由是活性：池子不可升级，fail-closed 会让一个再也读不通的接口把
    ///      全部抵押品永远冻死。代价照直说 —— 若此时代币确实处于暂停而我们读不到，
    ///      持有人会在完全无法行权的窗口里失去权证。**宽限只买 48 小时的人工反应时间。**
    function test_failOpen_stampsOnceAndSettlesOnlyAfterTheGrace() public {
        // 贴近到期时接口坏掉，此刻宽限比 expiry 更晚，deadline 才看得出被推动过
        vm.warp(uint256(expiry) - 1 hours);
        _breakTheGatingViews();

        pool.pokeGating(ForkConfig.GME);
        uint64 clearedAt = uint64(block.timestamp);

        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertTrue(g.unreadable, unicode"读不通 ⟹ 记为不可读");
        assertFalse(g.active, unicode"fail-open：不当成门控");
        assertEq(g.clearedAt, clearedAt, unicode"进入不可读时盖一次章");
        assertEq(pool.exerciseDeadline(seriesId), clearedAt + GRACE, unicode"宽限窗打开了");

        // 窗口内反复读不通：一次都不许重新盖章，也不许把结算往后推
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 9 hours);
            vm.roll(block.number + 1);
            vm.prank(attacker);
            pool.pokeGating(ForkConfig.GME);

            assertEq(pool.gating(ForkConfig.GME).clearedAt, clearedAt, unicode"二次 revert 重新盖了 clearedAt");
            vm.expectRevert(
                abi.encodeWithSelector(
                    ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
                )
            );
            pool.settleExpired(seriesId);
        }

        // 宽限过后必须可结算 —— fail-open 承认的那种损失有上界：48 小时
        vm.warp(uint256(clearedAt) + GRACE);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"宽限过后必须结算得掉");
    }

    // ──────────────────── 两条「不产生延期」的边界 ────────────────────

    /// @notice 验收条款：**未被 poke 的门控不产生延期。** 合约只信记录在案的观测。
    /// @dev 这使 poke 成为 Monitor 的运营刚性职责 —— 但它无许可，任何持有人都能自己调。
    function test_gatingThatNobodyPokedProducesNoExtension() public {
        _mockPoolBlocked(true);

        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"没人 poke ⟹ 没有延期");

        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 1e18, alice);

        // 🔴 但**结算**这一侧不吃陈旧记录：它内部先观测一次，于是当场发现门控并拒绝。
        //    否则持有人会在根本无法行权的时候被结算掉。
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, ForkConfig.GME));
        pool.settleExpired(seriesId);

        // 补一次 poke，延期立刻恢复 —— 持有人自救的代价就是一笔 gas
        pool.pokeGating(ForkConfig.GME);
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"poke 之后延期生效");
    }

    /// @notice 🔴 验收条款：**只封某个持有人（非池地址）不产生延期，且该情形可辨识。**
    ///
    /// @dev 池子干净 ⟹ 观测看不到任何东西 ⟹ 不延期，该持有人的权证到期即作废。
    ///      这是刻意的（封一个地址不该让全系列延期），但它是**真实且不可挽回的用户损失**。
    ///      前端要区分它，靠的是三样合起来：revert 数据里的地址是**持有人**而不是池子、
    ///      `GatingObserved` 说 `gated == false`、`exerciseDeadline` 仍然等于 `expiry`。
    ///      他唯一的自救路径是把权证卖掉 —— 转让不触及股票代币，因此不受封禁影响。
    function test_blockingOneHolderProducesNoExtensionAndStaysIdentifiable() public {
        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (alice)),
            abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, alice));
        pool.exercise(seriesId, 10e18, alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(ForkConfig.GME, false, true, 0);
        pool.pokeGating(ForkConfig.GME);
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"封单个持有人不产生延期");

        // 结算照常按期发生，这些权证就此作废
        vm.warp(expiry);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
        assertEq(pool.series(seriesId).remainder, DEPOSIT, unicode"抵押品滚给其他持有人");

        // 自救路径：权证仍然卖得掉（这一步得在结算之前做才有意义 —— 所以前端必须**及时**指出来）
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"权证还在他手上，只是已经没用了");
    }
}
