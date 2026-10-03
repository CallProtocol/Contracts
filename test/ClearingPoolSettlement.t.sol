// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {
    IssuerComplianceStub,
    IssuerPauseManagerStub,
    IssuerGatedStockToken,
    NearBudgetIssuerGatedStockToken,
    FullBudgetIssuerCompliance,
    AlwaysReadablePauseManager,
    FullBudgetIssuerGatedStockToken
} from "./helpers/IssuerGating.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {ReentrantStockToken, StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice **M1-6 到期结算 + 门控感知延期**（issue #11）。
///
/// 这张票只有一件事是难的：**观测函数的边语义**。延期的正确性完全依赖它，所以本文件的重心
/// 不在 `settleExpired` 的三行赋值上，而在下面这张表的每一格：
///
/// | 记录 \ 实时 | 门控 | 干净 | 读不通 |
/// |---|---|---|---|
/// | **门控**   | no-op | 盖章 | 盖章 |
/// | **干净**   | 置位 | 🔴 **no-op** | 盖章 |
/// | **读不通** | 置位 | 清位 | 🔴 **no-op** |
///
/// 两个 🔴 是同一条攻击的正门与后门：只要有一格会重复盖 `clearedAt`，任何人每 47 小时调一次
/// `pokeGating` 就能让 `settleExpired` 永久 revert，而他手上本该作废的系列获得**无限期免费展期**。
///
/// 🔴 第三条路径在链上而不在这张表里：**把健康的 view 用 gas 饿死**，同样能造出「干净 → 读不通」
/// 这条边。见 `test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas`。
///
/// 不变量形式（4a/4b/4c）在 `test/invariant/Invariant4SettlementAndGating.t.sol`；
/// 真实 GME 上的复核在 `test/fork/RobinhoodGating.t.sol`。
contract ClearingPoolSettlementTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    IssuerPauseManagerStub internal issuerPause;
    IssuerComplianceStub internal issuerCompliance;
    IssuerGatedStockToken internal stock;
    MemeToken internal meme;

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100 ether;

    /// @dev 🔴 **字面量，不读 `pool.GRACE_PERIOD()`。** 拿被测对象自己的常量去验它自己，
    ///      什么也证明不了 —— 同 `ClearingPoolExercise.t.sol` 里对 `0xdead` 的处理。
    uint64 internal constant GRACE = 48 hours;
    uint64 internal constant GATING_READ_GAS = 50_000;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定，见 {FactoryStub}。
        factory.bind(address(meme), address(vault));

        // 🔴 分叉测试跑在真实时间戳上，本地默认是 1。把它推到一个「48 小时早就过去了」的时刻，
        //    否则 `clearedAt + 48h` 与 `expiry` 的大小关系会被一个不真实的起点左右。
        vm.warp(1_800_000_000);
        expiry = uint64(block.timestamp + 7 days);

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 1e31);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    function _openAndMint() internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
    }

    /// @dev 发行方冻结池地址 —— §11 表格的第一行，也是门控延期真正要覆盖的场景。
    function _blockPool(bool blocked) internal {
        issuerCompliance.setBlocked(address(stock), address(pool), blocked);
    }

    function _gating(address token) internal view returns (ClearingPool.Gating memory) {
        return pool.gating(token);
    }

    // ──────────────────────── deadline：延期的全部实现 ────────────────────────

    /// @dev 没人 poke 过 ⟹ 记录全零 ⟹ deadline 就是 `expiry`。
    ///      **未被 poke 的门控不产生延期** —— 合约只信记录在案的观测（验收条款）。
    function test_deadline_isExpiryWhileNothingHasEverBeenObserved() public {
        uint256 seriesId = _openAndMint();
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"未观测 ⟹ deadline == expiry");

        // 发行方真的冻上了，但没有人 poke：deadline 一动不动。
        _blockPool(true);
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"没人 poke ⟹ 没有延期");

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, "unreadable");
        assertEq(g.clearedAt, 0, "clearedAt");
    }

    /// @dev 观测到门控 ⟹ **无截止**。这就是「发行方冻结时自动延期」，没有任何管理员参与。
    function test_deadline_isUnboundedWhileGatingIsObserved() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"门控观测中 ⟹ 无截止");
        assertTrue(_gating(address(stock)).active, "active");
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"进入门控不碰 clearedAt");
    }

    /// @dev 解除之后是 `max(expiry, clearedAt + 48h)`。两侧都要钉：
    ///      解除得晚 ⟹ 宽限把 deadline 推到 `expiry` 之后；解除得早 ⟹ deadline 还是 `expiry`。
    function test_deadline_isTheLaterOfExpiryAndClearedAtPlusGrace() public {
        uint256 seriesId = _openAndMint();

        // ① 到期之后才解除 —— 宽限说了算
        _blockPool(true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(expiry) + 10 days);
        _blockPool(false);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        assertEq(_gating(address(stock)).clearedAt, clearedAt, "clearedAt");
        assertEq(pool.exerciseDeadline(seriesId), clearedAt + GRACE, unicode"宽限把 deadline 推到解除之后 48h");

        // ② 同一只股票代币上另开一个到期更晚的系列 —— 那边 `expiry` 更大，宽限不起作用
        uint64 laterExpiry = uint64(block.timestamp + 30 days);
        uint256 later = vault.openSeries(address(meme), address(stock), laterExpiry, STRIKE);
        assertEq(pool.exerciseDeadline(later), laterExpiry, unicode"expiry 更晚时宽限不缩短窗口");
    }

    // ──────────────── 🔴 边语义：clearedAt 只在三条边上写 ────────────────

    /// @dev **本票的核心断言，正门那一半。** 对已观测为干净的股票代币反复 poke ——
    ///      无论调多少次、谁来调、跨多少个区块、离截止多近 —— `clearedAt` 必须**一动不动**。
    ///
    ///      🔴 没有这条，「无门控时结算不可阻止」是空的：能推动 `clearedAt` 的攻击者
    ///      只需让那条不变量的前提永不成立，就能永久阻止结算，而他手上本该作废的系列
    ///      获得无限期免费展期（不变量 4③ 正是为此而设）。
    function test_poke_onACleanStockNeverMovesClearedAt() public {
        uint256 seriesId = _openAndMint();

        // 先制造一个**非零**的 clearedAt：全零的记录会让「没被推动」这件事看起来像是巧合。
        _blockPool(true);
        pool.pokeGating(address(stock));
        _blockPool(false);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        assertEq(_gating(address(stock)).clearedAt, clearedAt, unicode"前置条件：clearedAt 已经被盖过一次");

        uint64 deadlineBefore = pool.exerciseDeadline(seriesId);

        // 攻击者按 47 小时一轮的节奏推，跨区块、跨调用方，一路推到宽限结束之后。
        for (uint256 round = 0; round < 6; round++) {
            vm.warp(block.timestamp + 47 hours);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(address(stock));
            vm.prank(keeper);
            pool.pokeGating(address(stock));
            pool.pokeGating(address(stock));

            assertEq(_gating(address(stock)).clearedAt, clearedAt, unicode"干净 poke 把 clearedAt 推走了");
            assertEq(pool.exerciseDeadline(seriesId), deadlineBefore, unicode"deadline 也不该动");
        }

        // 而结算照常按期发生 —— 攻击没有换来一秒钟的展期。
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"结算必须按期成功");
    }

    /// @dev `门控 → 干净` 是唯一一条真实的解除边，也是唯一一条**应该**盖章的边。
    ///      门控 → 门控则必须是 no-op：`clearedAt` 记的是「离开」的时刻，不是「看了一眼」的时刻。
    function test_poke_stampsOnlyOnTheGatedToCleanEdge() public {
        _blockPool(true);
        pool.pokeGating(address(stock));

        uint64 stampedTooEarly = _gating(address(stock)).clearedAt;
        assertEq(stampedTooEarly, 0, unicode"进入门控不盖章");

        // 门控 → 门控：多少次都不写
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 6 hours);
            pool.pokeGating(address(stock));
            assertEq(_gating(address(stock)).clearedAt, 0, unicode"门控期间的 poke 不该盖章");
            assertTrue(_gating(address(stock)).active, "active");
        }

        _blockPool(false);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, unicode"解除之后不再是门控");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"解除这一刻盖章");
    }

    /// @dev **fail-open 的后门那一半。** 门控 view 读不通时按「无门控」处理（否则一个再也读不通的
    ///      接口会把全部抵押品永远冻死），但必须**同时盖 48h 宽限** —— 否则代币真的暂停着而我们
    ///      读不到，持有人会在完全无法行权的窗口里被结算掉。
    ///
    ///      🔴 而这个盖章必须绑定在「**进入**不可读状态」这一次转变上，不是「每次读不通」：
    ///      窗口内的第二、第三次 revert **不得**重新盖章（验收条款）。
    /// 🔴 **读不通不再给宽限（deadline == expiry）** —— 2026-09-15 放宽（见 {ClearingPool-_exerciseDeadline}
    ///    与 §"无发行方门控接口的代币不吃 48h 宽限"）。`_observe` 的盖章机制**一字未动**（进入不可读
    ///    盖一次、窗口内不重复盖，防 gas-starvation 泵），本用例照旧钉它；只是 deadline 从
    ///    「clearedAt+48h」改成「expiry」。这里的 stock 是可读 bStock 被 `setViewsRevert` **临时**变读
    ///    不通 —— 正是新语义放宽的那个边缘档（bStock 冻结期间接口恰好读不通会被当干净，代价已在
    ///    合约里明示）。真实 bStock 冻结（可读 + 命中）的宽限由 §deadline 那组用例守着，未受影响。
    function test_poke_unreadableStampsOnceAndGivesNoGrace() public {
        uint256 seriesId = _openAndMint();

        vm.warp(uint256(expiry) - 1 hours);
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.unreadable, unicode"读不通 ⟹ 记为不可读（机制未变）");
        assertFalse(g.active, unicode"fail-open：不当成门控");
        assertEq(g.clearedAt, clearedAt, unicode"进入不可读时盖一次章（机制未变）");
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"读不通不再给宽限：deadline == expiry");

        // 窗口内反复读不通：一次都不许重新盖章（gas-starvation 泵防护，机制未变）。
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 9 hours);
            vm.prank(attacker);
            pool.pokeGating(address(stock));
            assertEq(_gating(address(stock)).clearedAt, clearedAt, unicode"二次 revert 重新盖了 clearedAt");
        }

        // expiry 之后照常结算 —— 不吃 48h 宽限（循环已把时钟推过 expiry）。
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev `门控 → 读不通` 按解除翻转处理（盖章 + 清掉 `active`）：读不通就不该再享受无截止的延期，
    ///      否则一个升级掉接口的发行方能让全部系列永远结算不了。
    /// 🔴 gated→unreadable 仍按解除翻转盖章（`_observe` 机制未动），但 **deadline 不再落回宽限** ——
    ///    读不通视为干净、deadline == expiry（2026-09-15 放宽，见 {ClearingPool-_exerciseDeadline}）。
    function test_poke_gatedToUnreadableStampsButGivesNoGrace() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"前置条件：无截止");

        vm.warp(uint256(expiry) + 1 days);
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, unicode"读不通之后不再是「门控中」");
        assertTrue(g.unreadable, "unreadable");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"按解除翻转盖章（机制未变）");
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"读不通 ⟹ deadline == expiry，不落回宽限");
    }

    /// @dev `读不通 → 干净` **不重新盖章**：进去那一刻已经盖过一次，出来时再盖一次，
    ///      「进 → 出 → 进」就成了一台前推 `clearedAt` 的泵。
    ///
    ///      代价照直说：若代币在整个不可读窗口里真的暂停着、直到窗口之后才恢复可读，
    ///      那 48 小时买到的时间已经用掉了（`docs/spec.zh.md` §11）。
    function test_poke_unreadableToCleanDoesNotReStamp() public {
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));
        uint64 firstStamp = _gating(address(stock)).clearedAt;

        // view 修好了、而且是干净的：无论谁调、调多少次、隔多久，都不许重新盖章
        stock.setViewsRevert(false);
        for (uint256 round = 0; round < 4; round++) {
            vm.warp(block.timestamp + 40 hours);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(address(stock));
            vm.prank(keeper);
            pool.pokeGating(address(stock));

            assertFalse(_gating(address(stock)).unreadable, unicode"恢复可读之后要清位");
            assertEq(_gating(address(stock)).clearedAt, firstStamp, unicode"读不通 → 干净不该盖章");
        }

        // 🔴 但**重新进入**不可读是一条新的边，那一次确实盖章 —— 这正是「绑定在转变上」的含义。
        //    造这条边需要 view 真的坏掉，也就是需要发行方改自己的代码；
        //    调用方能单方面造的那一条（把健康的 view 用 gas 饿死）由 `GATING_READ_GAS` 挡住，
        //    见 `test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas`。
        stock.setViewsRevert(true);
        vm.prank(attacker);
        pool.pokeGating(address(stock));
        assertGt(_gating(address(stock)).clearedAt, firstStamp, unicode"重新进入不可读是一条新的边");
    }

    /// @dev `读不通 → 门控`：view 修好了、而且说门控命中 —— 无截止的延期立刻回来。
    function test_poke_unreadableToGatedRestoresTheUnboundedDeadline() public {
        uint256 seriesId = _openAndMint();

        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).unreadable, unicode"前置条件：不可读");

        stock.setViewsRevert(false);
        stock.setTokenPaused(true);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, "active");
        assertFalse(g.unreadable, "unreadable");
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"无截止");
    }

    /// @dev 一个读不通的 view **不该**因为「贵」而被当成干净的。
    ///      顺带钉住第二件事：它烧掉的 gas 有上界，一只恶意代币不能靠一个无限循环的 view
    ///      把 poke 调用方的整笔 gas 吃光。
    function test_poke_treatsAnUnaffordablyExpensiveViewAsUnreadable() public {
        stock.setViewGasBurnRounds(50_000);

        uint256 before = gasleft();
        pool.pokeGating(address(stock));
        uint256 spent = before - gasleft();

        assertTrue(_gating(address(stock)).unreadable, unicode"读不完 ⟹ 读不通");
        assertEq(_gating(address(stock)).clearedAt, uint64(block.timestamp), unicode"照常盖宽限");
        assertLt(spent, 400_000, unicode"代币烧不掉调用方的整笔 gas");
    }

    /// @dev 🔴 **第三条造边路径，它不在状态转移表里：把健康的 view 用 gas 饿死。**
    ///
    ///      「不可读」在实现上就是「这次调用失败了」，而转发多少 gas 是**调用方**说了算的。
    ///      少了 gas 下限，任何人都能用一笔精心计量的交易把干净的 view 打成 out-of-gas，
    ///      凭空造出「干净 → 不可读」这条边，然后每 47 小时来一次 —— 攻击面从后门绕回来。
    ///
    ///      所以这里扫一整段 gas：每一档要么干净地成功、要么 revert，**绝不能落成「不可读 + 盖章」**。
    function test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas() public {
        pool.pokeGating(address(stock));
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"前置条件：干净且从未盖章");

        uint256 succeeded;
        uint256 rejected;
        for (uint256 gasLimit = 20_000; gasLimit <= 400_000; gasLimit += 2500) {
            vm.prank(attacker);
            try pool.pokeGating{gas: gasLimit}(address(stock)) {
                succeeded++;
            } catch {
                rejected++;
            }

            ClearingPool.Gating memory g = _gating(address(stock));
            assertFalse(g.unreadable, unicode"gas 饿死造出了一次「读不通」");
            assertEq(g.clearedAt, 0, unicode"gas 饿死推动了 clearedAt");
        }

        // 两个方向都得撞到，否则这条测试可能只是在一段全部失败（或全部成功）的区间上空转。
        assertGt(rejected, 0, unicode"前置条件：低 gas 那一档真的被拒了");
        assertGt(succeeded, 0, unicode"前置条件：高 gas 那一档真的成功了");
    }

    /// @dev 上一条的正向对照：gas 明确不够时报的是**这个**错，而不是一条裸 out-of-gas，
    ///      也不是「读不通」。调用方据此知道该加 gas，而不是以为发行方升级了接口。
    function test_poke_reportsTheGasFloorItSelfEnforces() public {
        uint256 floor = pool.GATING_READ_GAS();
        assertGt(floor, 0, unicode"前置条件：预算是公开的");

        // 恰好够进函数、但不够转发满预算的那一档。
        vm.expectPartialRevert(ClearingPool.NotEnoughGasToObserveGating.selector);
        this.pokeWithGas(address(stock), floor);

        assertEq(_gating(address(stock)).clearedAt, 0, unicode"什么都没写下");
    }

    /// @dev 回归 P1：旧 guard 只算 `64 / 63`，漏掉 cold `STATICCALL` 成本。调用方给 54,472 gas
    ///      时外层调用会成功，但健康 view 实际只拿到约 47k，因而被伪造成一次「不可读 + 盖章」。
    ///      修复后必须在读之前以 `NotEnoughGasToObserveGating` 整笔拒绝，状态保持全零。
    function test_poke_rejectsTheEip150ColdCallBoundaryBeforeItCanStamp() public {
        FullBudgetIssuerCompliance fullBudgetCompliance = new FullBudgetIssuerCompliance();
        AlwaysReadablePauseManager cheapPause = new AlwaysReadablePauseManager();
        FullBudgetIssuerGatedStockToken fullBudget =
            new FullBudgetIssuerGatedStockToken(address(cheapPause), address(fullBudgetCompliance));

        // 把被读到的三个地址明确冷却，钉住真实攻击所依赖的最坏路径，而不是 warm-cache 下的偶然行为。
        // 🔴 BSC 版的门控是**五个读**（管理器地址 / isTokenPaused / 合规地址 / 黑名单 / 制裁名单），
        //    比 Robinhood 版多两个，所以冷却的地址也从两个变成三个。
        vm.cool(address(fullBudget));
        vm.cool(address(cheapPause));
        vm.cool(address(fullBudgetCompliance));
        (bool success, bytes memory revertData) =
            address(pool).call{gas: 54_472}(abi.encodeCall(ClearingPool.pokeGating, (address(fullBudget))));
        assertFalse(success, unicode"修复后的 guard 必须在 cold-call 边界整笔拒绝");
        assertEq(
            bytes4(revertData),
            ClearingPool.NotEnoughGasToObserveGating.selector,
            unicode"必须是明确的 gas-floor 拒绝"
        );

        ClearingPool.Gating memory g = _gating(address(fullBudget));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, unicode"gas 饿死不得造出不可读观测");
        assertEq(g.clearedAt, 0, unicode"gas 饿死不得盖宽限章");

        // 充分 gas 时，同一只几乎吃满预算的健康代币必须仍读通。
        pool.pokeGating(address(fullBudget));
        assertFalse(_gating(address(fullBudget)).unreadable, unicode"完整预算下健康 view 必须读通");
    }

    // ───────────────── ABI 边界与读取优先级 ─────────────────

    /// @dev 返回长度不是一个 ABI word 时，`_staticWord` 必须视为不可读，而不是把短数据解码、revert，
    ///      或误判为干净。进入不可读状态只允许盖一次宽限章。
    function test_poke_shortPausedResponseIsUnreadableAndStampsOnlyOnce() public {
        // BSC 版里代币身上的第一个读是 `pauseManager()`（地址 view）。短返回照样必须记为不可读。
        vm.mockCall(address(stock), abi.encodeCall(IssuerGatedStockToken.pauseManager, ()), hex"01");

        pool.pokeGating(address(stock));
        uint64 firstStamp = _gating(address(stock)).clearedAt;
        assertFalse(_gating(address(stock)).active, "active");
        assertTrue(_gating(address(stock)).unreadable, unicode"短返回必须记为不可读");
        assertEq(firstStamp, uint64(block.timestamp), unicode"进入不可读时盖章");

        vm.warp(block.timestamp + 1 days);
        pool.pokeGating(address(stock));
        assertEq(_gating(address(stock)).clearedAt, firstStamp, unicode"同一短返回不得重复盖章");
    }

    /// @dev 发行方并不一定遵守 Solidity 的 canonical bool 编码；非零 word 仍然是肯定门控。
    ///      若用 `abi.decode(..., (bool))`，这里会 revert，把 fail-open 的读取路径变成 fail-closed。
    function test_poke_noncanonicalTruthyPausedWordIsGatedAndReadable() public {
        // 🔴 BSC 版里那个布尔读住在**管理器**上（`isTokenPaused(token)`），不在代币上。
        vm.mockCall(
            address(issuerPause),
            abi.encodeCall(IssuerPauseManagerStub.isTokenPaused, (address(stock))),
            abi.encode(uint256(2))
        );

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"非零 isTokenPaused word 仍是门控");
        assertFalse(g.unreadable, unicode"32 字节的非零 word 是可读 ABI 返回");
        assertEq(g.clearedAt, 0, unicode"进入门控不盖解除章");
    }

    /// @notice 🔴 **全局制裁名单是 BSC 版新增的第三个门控来源**（决策 53）——
    ///         Robinhood 那版只有「暂停」与「黑名单」两档。
    ///
    /// @dev 它与黑名单的区别不是形式上的：黑名单的键是 `(代币, 地址)`，制裁名单**与代币无关**。
    ///      也就是说发行方可以在不碰任何一只代币的前提下把池子拦住 —— 而池子必须看得见。
    ///      实测依据：制裁之后 `transfer` revert `UserSanctioned()`，而五个读仍然全部读得通
    ///      （`docs/research/bsc-flap-portal-probe.md` §6.4）。
    function test_poke_sanctioningThePoolIsGatingAndStaysReadable() public {
        issuerCompliance.setSanctioned(address(pool), true);

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"池子被制裁 ⟹ 门控命中");
        assertFalse(g.unreadable, unicode"制裁是一个读得通的状态，不是「读不通」");
        assertEq(g.clearedAt, 0, unicode"进入门控不盖解除章");

        // 解除之后走的是那条**唯一**真实的解除边：盖章一次。
        issuerCompliance.setSanctioned(address(pool), false);
        vm.warp(block.timestamp + 1 hours);
        pool.pokeGating(address(stock));

        g = _gating(address(stock));
        assertFalse(g.active, unicode"解除制裁后不再门控");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"解除边盖章");
    }

    /// @dev 制裁与黑名单是**两个独立的来源**：只拦一个不该让另一个失效，两个都拦也只是门控。
    ///      这条防的是把两个读写成短路 `&&` 之类的实现错误。
    function test_poke_blocklistAndSanctionsAreIndependentSources() public {
        _blockPool(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"只拉黑 ⟹ 门控");

        _blockPool(false);
        issuerCompliance.setSanctioned(address(pool), true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"只制裁 ⟹ 门控");

        _blockPool(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"两个都拦 ⟹ 仍是门控");

        _blockPool(false);
        issuerCompliance.setSanctioned(address(pool), false);
        vm.warp(block.timestamp + 1 hours);
        pool.pokeGating(address(stock));
        assertFalse(_gating(address(stock)).active, unicode"两个都解除 ⟹ 干净");
    }

    /// @dev 地址 word 的高 96 位有脏数据时绝不可截断：截断会让池子向另一个注册表地址取结论。
    function test_poke_dirtyRegistryAddressIsUnreadableAndNeverTruncated() public {
        _blockPool(true);
        uint256 dirtyRegistry = uint256(uint160(address(issuerCompliance))) | (uint256(1) << 160);
        vm.mockCall(
            address(stock),
            abi.encodeCall(IssuerGatedStockToken.compliance, ()),
            abi.encode(dirtyRegistry)
        );

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, unicode"脏地址不能截断后读出真实注册表的门控");
        assertTrue(g.unreadable, unicode"地址高位不干净就是不可读");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"不可读进入时盖宽限");
    }

    /// @dev 任何一个肯定命中优先于后续读失败；这里还用零次预期调用钉住提前返回，
    ///      防止未来重排读取顺序而把一个健康的门控命中降级成 fail-open。
    function test_poke_positivePausedReadWinsBeforeARevertingRegistryRead() public {
        bytes memory registryCall = abi.encodeCall(IssuerGatedStockToken.compliance, ());
        vm.mockCall(
            address(issuerPause),
            abi.encodeCall(IssuerPauseManagerStub.isTokenPaused, (address(stock))),
            abi.encode(true)
        );
        vm.mockCallRevert(address(stock), registryCall, "compliance must not be read after a positive paused result");
        vm.expectCall(address(stock), registryCall, 0);

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"已命中的 paused 不能被后续失败降级");
        assertFalse(g.unreadable, unicode"提前正命中仍是可读门控");
    }

    /// @dev 单独的 `paused()` 读接近 50k 预算却仍健康时，池子必须读通而不是误记为不可读。
    ///      先让池子走真实路径并钉住它转发的精确 gas，再在已 warm 的地址上复测同一 staticcall 的耗气。
    function test_poke_acceptsAHealthyPausedReadThatUsesAlmostTheFullBudget() public {
        NearBudgetIssuerGatedStockToken nearBudget = new NearBudgetIssuerGatedStockToken(issuerPause, issuerCompliance);
        uint256 budget = pool.GATING_READ_GAS();
        bytes memory pausedCall = abi.encodeCall(NearBudgetIssuerGatedStockToken.pauseManager, ());

        assertEq(budget, GATING_READ_GAS, unicode"池子必须仍转发约定的单次读预算");
        vm.expectCall(address(nearBudget), 0, GATING_READ_GAS, pausedCall);
        pool.pokeGating(address(nearBudget));

        ClearingPool.Gating memory g = _gating(address(nearBudget));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, unicode"接近预算但健康的读不能被判为不可读");

        uint256 before = gasleft();
        (bool success, bytes memory ret) = address(nearBudget).staticcall{gas: budget}(pausedCall);
        uint256 spent = before - gasleft();

        assertTrue(success, unicode"近预算 pauseManager() 仍应返回");
        // 🔴 BSC 版里这个近预算读是**地址** view（`pauseManager()`），不是 bool。
        //    断言的重点没变：仍然是规范的**一个** ABI word，而不是短返回或脏高位。
        assertEq(ret, abi.encode(address(issuerPause)), unicode"返回仍是规范的一个 address word");
        assertEq(ret.length, 32, unicode"恰好一个 word");
        assertGt(spent, budget - 12_000, unicode"单次健康读取必须确实接近预算");
        assertLt(spent, budget, unicode"健康读取必须在预算内完成");
    }

    /// @dev `expectPartialRevert` 要作用在一次**外部**调用上，所以借道 `this`。
    function pokeWithGas(address token, uint256 gasLimit) external {
        pool.pokeGating{gas: gasLimit}(token);
    }

    /// @dev 零地址挡在门外：`_gating[address(0)]` 是**未开启系列**会读到的那条记录，
    ///      让它永远是全零，比每次新增函数时重新论证一遍便宜。
    function test_poke_rejectsTheZeroAddress() public {
        vm.expectRevert(ClearingPool.ZeroToken.selector);
        pool.pokeGating(address(0));

        ClearingPool.Gating memory g = _gating(address(0));
        assertEq(g.clearedAt, 0, "clearedAt");
        assertFalse(g.unreadable, "unreadable");
    }

    /// @dev 事件在**每一次**观测上都发，包括 no-op 的那些。
    ///      链下要区分「我们看过了，是干净的」和「那笔 poke 根本没执行」，靠的就是这一条。
    function test_poke_emitsOnEveryObservationIncludingNoOps() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));

        // 第二次是彻底的 no-op —— 事件照发
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));

        _blockPool(true);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), true, true, 0);
        pool.pokeGating(address(stock));

        _blockPool(false);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, uint64(block.timestamp));
        pool.pokeGating(address(stock));

        stock.setViewsRevert(true);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, false, uint64(block.timestamp));
        pool.pokeGating(address(stock));
    }

    // ────────────────────────── settleExpired ──────────────────────────

    /// @dev 结算写下 `remainder = deposited − exercised`，此后**不可行权**（不变量 4①）。
    function test_settle_writesTheRemainderAndClosesTheSeries() public {
        uint256 seriesId = _openAndMint();

        vm.prank(alice);
        pool.exercise(seriesId, 30 ether, alice);

        vm.warp(expiry);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Settled(seriesId, uint128(DEPOSIT - 30 ether), expiry);
        vm.prank(keeper);
        pool.settleExpired(seriesId);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertTrue(s.settled, "settled");
        assertEq(s.remainder, DEPOSIT - 30 ether, unicode"remainder = deposited − exercised");
        assertEq(s.deposited, DEPOSIT, unicode"结算不改 deposited");
        assertEq(s.exercised, 30 ether, unicode"结算不改 exercised");
        assertEq(stock.balanceOf(address(pool)), DEPOSIT - 30 ether, unicode"抵押品一枚都没离开池子");

        // 不变量 4①
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 1 ether, alice);
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT - 30 ether, unicode"权证还在，只是用不了了");
    }

    /// @dev 🔴 判据必须与 `exercise` **严格互补**：差一秒就会出现一个「既不能行权、也不能结算」
    ///      的窗口，或者更糟 —— 一个两者**都能**做的窗口。
    function test_settle_exactlyComplementsTheExerciseWindow() public {
        uint256 seriesId = _openAndMint();

        // deadline 前一秒：行权开着，结算关着
        vm.warp(uint256(expiry) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.SettlementTooEarly.selector, seriesId, expiry, block.timestamp)
        );
        pool.settleExpired(seriesId);

        vm.prank(alice);
        pool.exercise(seriesId, 1 ether, alice);

        // deadline 那一秒：行权关上，结算开着
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 1 ether, alice);

        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev 门控观测中 ⟹ 结算被**结构性阻止**。行权窗口保持开放 —— 这就是自动延期的全部实现；
    ///      发行方若仍拦截股票转账，行权调用会原子回滚。
    function test_settle_isStructurallyBlockedWhileTheIssuerGates() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        vm.warp(uint256(expiry) + 365 days);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, address(stock)));
        pool.settleExpired(seriesId);

        assertFalse(pool.series(seriesId).settled, unicode"一年过去了也结算不了");
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"而系列一直是可行权的");
    }

    /// @dev 🔴 **`pokeGating` 是关窗的动作，不是开窗的动作。**
    ///
    ///      行权读的是**记录**，不做实时读取。所以记录停在「门控中」、而发行方已经悄悄解除时，
    ///      行权**立刻**可用 —— 窗口还开着（无截止），转账也放行了，**不需要任何人先 poke**。
    ///      观测到解除只做一件事：把无限的窗口收敛成 `max(expiry, clearedAt + 48h)`。
    ///
    ///      这条测试存在的理由是文档而不是代码：把它写成「解除**并被观测后**才可行权」，
    ///      前端就会去劝用户等 keeper —— 那既是错的，也把一个无许可的设计说成有运营依赖。
    ///      措辞漂了，这条会红。
    function test_exercise_worksBeforeAnyPokeOnceTheIssuerClears() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        // 过了到期很久，发行方悄悄解除 —— 而**没有任何人**再 poke 过
        vm.warp(uint256(expiry) + 30 days);
        _blockPool(false);

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"前置条件：记录仍停在「门控中」");
        assertEq(g.clearedAt, 0, unicode"前置条件：宽限的时钟从未起头");

        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(stock.balanceOf(alice), 10 ether, unicode"没有 poke，行权照样成功");

        // 而 poke 做的是**收窄**：无截止 → 解除时刻 + 48h
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"poke 之前：无截止");
        pool.pokeGating(address(stock));
        assertEq(
            pool.exerciseDeadline(seriesId), uint64(block.timestamp) + GRACE, unicode"poke 之后：窗口收敛成 48h"
        );
    }

    /// @dev 🔴 **自愈陈旧观测，最要紧的那个方向**：记录说干净、发行方其实已经冻上了。
    ///      不重读的话，结算会在持有人**根本无法行权**的时候照常推进。
    function test_settle_selfHealsARecordThatWronglySaysClean() public {
        uint256 seriesId = _openAndMint();

        pool.pokeGating(address(stock)); // 记录：干净
        vm.warp(expiry);

        // 冻结发生在最后一次 poke 之后 —— 记录是陈旧的
        _blockPool(true);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, address(stock)));
        pool.settleExpired(seriesId);

        assertFalse(pool.series(seriesId).settled, unicode"陈旧的「干净」记录没能把结算放过去");
    }

    /// @dev 另一个方向：记录说门控、实时已经解除。观测把它纠正过来并盖上宽限，于是这一笔结算太早。
    ///
    ///      ⚠️ **那次观测随这次 revert 一起回滚。** 宽限的时钟要由一次 `pokeGating` 起头 ——
    ///      运营口径因此是「先 poke，再等 48 小时，再结算」，而不是反复试探 `settleExpired`。
    ///      对活性没有影响：poke 无许可，任何人都能调。
    function test_settle_doesNotStartTheGraceClockByItself() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(expiry) + 3 days);
        _blockPool(false);

        // 试探式的 settle：被拒，且**什么也没留下**
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, uint64(block.timestamp) + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);
        assertTrue(_gating(address(stock)).active, unicode"记录仍然停在陈旧的「门控」上");
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"宽限时钟没有起头");

        // 隔多久再试都一样 —— 时钟得有人去起
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, uint64(block.timestamp) + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // 正确的做法：poke 起头，等满 48 小时，再结算。
        pool.pokeGating(address(stock));
        uint64 clearedAt = uint64(block.timestamp);

        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 1 ether, alice);

        vm.warp(uint256(clearedAt) + GRACE);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev 两道状态门：系列没开过、系列已经结算过。
    function test_settle_rejectsUnopenedAndAlreadySettledSeries() public {
        uint256 unopened = uint256(keccak256(abi.encode(address(meme), address(stock), uint64(999))));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.settleExpired(unopened);

        uint256 seriesId = _openAndMint();
        vm.warp(expiry);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.settleExpired(seriesId);
        assertEq(pool.series(seriesId).remainder, DEPOSIT, unicode"第二次没有把 remainder 重算一遍");
    }

    /// @dev 结算之后**不得再存入**：那笔抵押品既不在 `remainder` 里、也不属于任何未结算系列，
    ///      会永久卡在池子里（无 admin、无 withdraw），而对应的权证一枚也行权不了。
    function test_settle_closesTheDepositPathToo() public {
        uint256 seriesId = _openAndMint();
        vm.warp(expiry);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        vault.depositAndMint(seriesId, alice, 1 ether);

        assertEq(pool.series(seriesId).deposited, DEPOSIT, unicode"账没被动过");
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"也没有多铸出权证");
    }

    /// @dev 🔴 上一条的**再入版本**，它才是真正难挡的那个形状：存入是「先转账、后记账」，
    ///      而转账会把控制权交给股票代币。代币在回调里把这个系列结算掉，回来之后存入照常
    ///      把抵押品记进 `deposited`、把权证铸出去 —— 而 `remainder` 已经按结算那一刻的账算定了。
    ///
    ///      挡住它的是 `settleExpired` 的 `nonReentrant`（守卫是**跨函数**的）。
    function test_settle_cannotBeReenteredFromADepositCallback() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        reentrant.mint(address(vault), 1e24);
        vault.approve(reentrant, type(uint256).max);

        uint64 shortExpiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = vault.openSeries(address(meme), address(reentrant), shortExpiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 10 ether);

        // 过了 deadline，此刻 `settleExpired` 单独调用是会成功的 —— 所以内层被拒只可能是再入保护。
        vm.warp(shortExpiry);
        reentrant.armReentrancy(address(pool), abi.encodeCall(ClearingPool.settleExpired, (seriesId)));

        vault.depositAndMint(seriesId, alice, 5 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"前置条件：回调真的打进来了");
        assertFalse(reentrant.reentrySucceeded(), unicode"内层结算必须被拒");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护"
        );
        assertFalse(pool.series(seriesId).settled, unicode"系列没有在存入中途被结算掉");
        assertEq(pool.series(seriesId).deposited, 15 ether, unicode"存入照常记账");
    }

    /// @dev 结算之后 `remainder` 就是池内**属于这个系列**的全部余量，不多不少。
    function testFuzz_settle_remainderIsExactlyWhatIsLeftInThePool(uint128 deposit, uint128 exercised) public {
        deposit = uint128(bound(deposit, 1e15, 1e24));
        exercised = uint128(bound(exercised, 0, deposit));

        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, deposit);

        if (exercised != 0 && (uint256(exercised) * STRIKE) / 1e18 != 0) {
            vm.prank(alice);
            pool.exercise(seriesId, exercised, alice);
        } else {
            exercised = 0;
        }

        vm.warp(expiry);
        pool.settleExpired(seriesId);

        assertEq(pool.series(seriesId).remainder, deposit - exercised, "remainder");
        assertEq(stock.balanceOf(address(pool)), deposit - exercised, unicode"remainder 就是池内实际余量");
    }

    // ─────────────────── 只封某个持有人：不产生延期，但可辨识 ───────────────────

    /// @dev 🔴 发行方**只封某个持有人**（不是池子）。池子干净 ⟹ 观测看不到任何东西 ⟹
    ///      **不产生延期**，该持有人的权证到期即作废。这是刻意的（封一个地址不该让全系列延期），
    ///      但它是**真实且不可挽回的用户损失**（`docs/spec.zh.md` §11）。
    ///
    ///      验收条款要求这一档**可辨识**，前端才能区分它、并指出「卖掉权证」这条自救路径。
    ///      三处证据合起来足够区分：
    ///
    ///      | 证据 | 只封持有人 | 封了池子 |
    ///      |---|---|---|
    ///      | 行权的 revert 数据 | `Blocked(持有人)` | `Blocked(池子)` |
    ///      | `GatingObserved` | `gated == false` | `gated == true` |
    ///      | `exerciseDeadline` | 仍是 `expiry` | `type(uint64).max` |
    function test_blockingOneHolderProducesNoExtensionAndStaysIdentifiable() public {
        uint256 seriesId = _openAndMint();
        issuerCompliance.setBlocked(address(stock), alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuerGatedStockToken.Blocked.selector, alice));
        pool.exercise(seriesId, 1 ether, alice);

        // 观测：池子是干净的 —— 事件里写着 `gated == false`，deadline 一动不动。
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"封单个持有人不产生延期");

        // 对照：封的是池子时，同一次观测给出完全不同的三样东西。
        issuerCompliance.setBlocked(address(stock), alice, false);
        _blockPool(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuerGatedStockToken.Blocked.selector, address(pool)));
        pool.exercise(seriesId, 1 ether, alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), true, true, 0);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"封池子才有延期");

        // 被单独封住的持有人唯一的自救路径：把权证卖掉 —— 转让不触及股票代币。
        _blockPool(false);
        issuerCompliance.setBlocked(address(stock), alice, true);
        address buyer = makeAddr("buyer");
        vm.prank(alice);
        warrant.safeTransferFrom(alice, buyer, seriesId, DEPOSIT, "");
        assertEq(warrant.balanceOf(buyer, seriesId), DEPOSIT, unicode"被封的持有人仍然卖得掉权证");
    }

    // ─────────────────── 延期全路径（本地版；真实标的见分叉测试）───────────────────

    /// @dev 验收条款的那条主线，一次跑完：
    ///      pause → poke → 过 expiry 后窗口仍开（转账回滚、权证不丢） → 解除 → 48h 宽限内行权成功
    ///      → 宽限后结算成功。
    function test_fullPath_pausePokeKeepsWindowOpenThenClearGraceExerciseSettle() public {
        uint256 seriesId = _openAndMint();

        // ① 发行方暂停，任何人 poke 留下观测
        stock.setTokenPaused(true);
        vm.prank(keeper);
        pool.pokeGating(address(stock));

        // ② 过了 expiry 行权窗口仍开；只是此刻股票转账被发行方挡着，所以整笔调用回滚。
        vm.warp(uint256(expiry) + 5 days);
        vm.prank(alice);
        vm.expectRevert(IssuerGatedStockToken.IsPaused.selector);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(warrant.balanceOf(alice, seriesId), DEPOSIT, unicode"权证一枚没丢");

        // ③ 解除。宽限从这一刻开始，观测由任何人留下
        stock.setTokenPaused(false);
        vm.prank(attacker); // 谁调都一样，它无许可
        pool.pokeGating(address(stock));
        uint64 clearedAt = uint64(block.timestamp);

        // ④ 宽限**之内**行权成功 —— 这才是「延期」真正兑现的地方
        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 40 ether, alice);
        assertEq(stock.balanceOf(alice), 40 ether, unicode"宽限内照常行权");

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // ⑤ 宽限过后：行权关上，结算打开
        vm.warp(uint256(clearedAt) + GRACE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.ExerciseWindowClosed.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.exercise(seriesId, 1 ether, alice);

        pool.settleExpired(seriesId);
        assertEq(pool.series(seriesId).remainder, DEPOSIT - 40 ether, "remainder");
    }

    // ──────────────── 无发行方门控接口的代币不吃 48h 宽限（任意计价币支持）────────────────
    //
    /// 🔴 **读不通（无 `pauseManager()`/`compliance()`）现在 deadline 就是 `expiry`，不吃 48h 宽限。**
    ///    WBNB / USDT / DOGE / 各种 custom quote 都无发行方门控接口，永远读不通；旧的「读不通 →
    ///    fail-open + 48h 宽限」会把它们每周结算凭空拖 48h（真链实测 C2/C3/C5 全中 `SettlementTooEarly`）。
    ///    放宽依据（用户 2026-09-15）：能不能 launch 由 Flap Portal 把控、warrant 无条件信任它，无需
    ///    我们的门控再对任意 quote 二次把关。见 {ClearingPool-_exerciseDeadline}。
    ///    ⚠️ **`unreadable` 机制本身不动**（仍记录、仍防 gas-starvation 泵），只有 `_exerciseDeadline`
    ///    对 `g.unreadable` 这一档从「clearedAt+48h」改成「expiry」。真实 bStock 冻结（可读 clear-edge、
    ///    `g.unreadable==false`）的宽限由 §deadline 那一组用例守着，**完全保留**。
    function test_issuerlessStock_exerciseDeadlineIsExpiryNoGrace() public {
        // 无发行方门控接口的普通 ERC20（无 pauseManager/compliance）——代表 WBNB/USDT/DOGE/任意 custom。
        StockToken plain = new StockToken();
        plain.mint(address(vault), 1e30);
        vault.approve(plain, type(uint256).max);
        uint64 exp = uint64(block.timestamp + 7 days);
        uint256 seriesId = vault.openSeries(address(meme), address(plain), exp, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        // poke → 读不通 → 记录仍标 unreadable、进入不可读盖了 clearedAt（机制一字未动）。
        pool.pokeGating(address(plain));
        assertTrue(_gating(address(plain)).unreadable, unicode"无门控接口 ⟹ 读不通（unreadable 仍记录）");
        assertEq(_gating(address(plain)).clearedAt, uint64(block.timestamp), unicode"进入不可读盖了 clearedAt");

        // 🔴 但 deadline **不吃宽限** —— 读不通视为干净，deadline == expiry（而非 clearedAt+48h）。
        assertEq(pool.exerciseDeadline(seriesId), exp, unicode"读不通 ⟹ 无宽限，deadline == expiry");

        // 结算在 expiry 之后即可成功、不被拖 48h（真链上 SettlementTooEarly 的根因就此消除）。
        vm.warp(uint256(exp) + 1);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"读不通代币在 expiry 后即可结算，不拖 48h");
    }
}
