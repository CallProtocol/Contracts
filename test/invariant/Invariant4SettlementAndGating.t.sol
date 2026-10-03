// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IWarrant} from "../../src/interfaces/IWarrant.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {IssuerComplianceStub, IssuerGatedStockToken, IssuerPauseManagerStub} from "../helpers/IssuerGating.sol";
import {MemeToken} from "../helpers/MemeToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {CollateralCheck} from "./Invariant1And2MintingPath.t.sol";

/// @dev 观测记录的三种状态。handler 用它同时表示「池子记着的」与「链上真实的」，
///      两者的**配对**决定了这一次观测允不允许写 `clearedAt`。
uint8 constant CLEAN = 0;
uint8 constant GATED = 1;
uint8 constant OPAQUE = 2;

/// @notice 反证要装的三个后门，各自坏掉不变量 4 的一款。
///
/// @dev 生产合约里这三个入口都不存在 —— 由 `test/ClearingPool.t.sol` 枚举编译产物的 ABI 证明
///      （「对外可写函数恰好六个」），而不是由「我们没写过」这句话证明。
///      ⚠️ `exerciseIgnoringSettlement` 重写了一遍行权的三步，理由同
///      `Invariant3ExerciseAtomicity.t.sol` 的 `NonAtomicPool`：要坏掉的那件事只能在**函数内部**发生。
contract SabotagePool is ClearingPool {
    constructor(
        IWarrant warrant_,
        address distributor_,
        IAttestationRegistry attestations_,
        IVaultRegistry vaultRegistry_
    ) ClearingPool(warrant_, distributor_, attestations_, vaultRegistry_) {}

    /// @dev 🔴 **每次 poke 都盖 `clearedAt`** —— 规格里点名的那个攻击面。
    ///      先老实观测一遍，再多写这一笔：坏的只有「只在边上写」这一条性质，其余全对。
    function pokeSloppily(address stockToken) external {
        this.pokeGating(stockToken);
        _gating[stockToken].clearedAt = uint64(block.timestamp);
    }

    /// @dev 无门控、也过了 deadline，却仍然结算不了 —— 「结算被阻止」的形状。
    function settleStubbornly(uint256 seriesId) external {
        Series storage s = _series[seriesId];
        if (block.timestamp < uint256(s.expiry) + 30 days) {
            revert SettlementTooEarly(seriesId, s.expiry, block.timestamp);
        }
        s.settled = true;
        s.remainder = s.deposited - s.exercised;
    }

    /// @dev 已结算的系列照样能行权 —— 抵押品被支取两次：一次给行权的人，一次进 `remainder`。
    function exerciseIgnoringSettlement(uint256 seriesId, uint256 amount, address beneficiary) external {
        Series storage s = _series[seriesId];
        uint256 memeAmount = (amount * s.strike) / 1e18;

        s.exercised += uint128(amount);
        warrant.burn(msg.sender, seriesId, amount);
        IERC20(s.memeToken).transferFrom(beneficiary, BURN_ADDRESS, memeAmount);
        IERC20(s.stockToken).transfer(beneficiary, amount);
    }
}

/// @notice 驱动结算与门控观测的 handler。
///
/// 🔴 **本合约的任何函数都不 revert**（同另外三个不变量文件的取舍）：不变量跑在
/// `fail_on_revert = false` 下，handler 里的 `assertEq` 失败就是一次 revert，会被 fuzzer 静静吞掉。
/// 所以违规一律**记进计数器**，由 `invariant_*` 去断言计数为零。
///
/// # 判据必须独立于被测实现
///
/// 4b 与 4c 的前提都要回答「此刻链上到底有没有门控」。handler **不去读池子的观测**来回答它 ——
/// 那等于拿被测对象的结论当自己的前提。它读的是**自己刚刚拨过的那三个开关**
/// （`tokenPaused` / `poolBlocked` / `poolSanctioned` / `viewsBroken`），这是这条链上门控状态的第一手来源。
/// deadline 同理：按公式独立算一遍，只从 `pool.gating()` 取原始字段。
contract SettlementHandler is CommonBase, StdUtils {
    enum Sabotage {
        NONE,
        SLOPPY_POKE,
        STUBBORN_SETTLE,
        IGNORE_SETTLED
    }

    uint64 internal constant GRACE = 48 hours;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    ClearingPool public immutable pool;
    Warrant public immutable warrant;
    AttestationRegistry public immutable registry;
    address public immutable distributor;
    Sabotage public immutable sabotage;

    VaultStub public immutable vault;
    IssuerPauseManagerStub public immutable issuerPause;
    IssuerComplianceStub public immutable issuerCompliance;
    IssuerGatedStockToken public immutable stock;
    MemeToken public immutable meme;

    address[3] public actors;
    uint64[2] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    // ── 门控开关的镜像：判据的第一手来源，不从池子里读回来 ──
    bool public tokenPaused;
    bool public poolBlocked;
    /// @dev BSC 版新增的第三个门控来源：全局制裁名单。
    bool public poolSanctioned;
    bool public viewsBroken;

    /// @notice 不变量 4①：一次**成功**的行权落在已结算系列上的次数。必须恒为 0。
    uint256 public postSettlementExerciseViolations;
    /// @notice 不变量 4②：前提成立（记录当前、实时无门控、已过 deadline）却结算不了的次数。必须恒为 0。
    uint256 public settlementBlockedViolations;
    /// @notice 不变量 4② 的另一半：门控命中时结算竟然成功的次数。必须恒为 0。
    uint256 public settlementWhileGatedViolations;
    /// @notice 不变量 4③：一次**不在边上**的观测改动了 `clearedAt` 的次数。必须恒为 0。
    uint256 public clearedAtDriftViolations;
    /// @notice 4③ 的反向：确实在边上、却没盖章（或 `clearedAt` 倒退）的次数。必须恒为 0。
    uint256 public missedStampViolations;
    /// @notice 结算写下的 `remainder` 不等于 `deposited − exercised` 的次数。必须恒为 0。
    uint256 public remainderViolations;

    // ── 覆盖度：六条断言全是「某个计数为 0」，一个什么都没干成的 handler 同样满足它们 ──
    uint256 public successfulDeposits;
    uint256 public successfulExercises;
    uint256 public successfulSettlements;
    uint256 public settlementsRejectedWhileGated;
    uint256 public settlementsRejectedTooEarly;
    uint256 public exercisesAttemptedOnSettledSeries;
    uint256 public observations;
    uint256 public observedEdges;

    constructor(
        ClearingPool pool_,
        Warrant warrant_,
        AttestationRegistry registry_,
        address distributor_,
        FactoryStub factory_,
        Sabotage sabotage_
    ) {
        pool = pool_;
        warrant = warrant_;
        registry = registry_;
        distributor = distributor_;
        sabotage = sabotage_;

        vault = new VaultStub(pool_);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定（M2-5 / #37）。
        factory_.bind(address(meme), address(vault));

        // 🔴 一远一近，顺序刻意：远的那个**保证整轮都活着**（否则一轮跑到一半全部系列过期，
        //    成功的行权此后一次也撞不到）；近的那个会被 `warp` 跨过去，让「结算」真的有得算。
        //    远的排在下标 0，因为 fuzzer 对 0 有强偏好。
        expiries = [uint64(block.timestamp + 400 days), uint64(block.timestamp + 10 days)];
        actors = [makeAddrLike("holder A"), makeAddrLike("holder B"), makeAddrLike("holder C")];

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        for (uint256 i = 0; i < actors.length; i++) {
            meme.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            meme.approve(address(pool_), type(uint256).max);
            if (i < 2) {
                vm.prank(actors[i]);
                registry_.attest(0, TERMS_0, ATTESTATION_0);
            }
        }
    }

    function seriesCount() external view returns (uint256) {
        return openedSeries.length;
    }

    function seriesIds() external view returns (uint256[] memory) {
        return openedSeries;
    }

    function stockAddresses() external view returns (address[] memory list) {
        list = new address[](1);
        list[0] = address(stock);
    }

    // ────────────────────────────── 动作 ──────────────────────────────

    function openSeries(uint256 expirySeed, uint128 strike) external {
        strike = uint128(bound(strike, 1e15, 1e21));

        (bool ok, bytes memory ret) = address(vault)
            .call(
                abi.encodeCall(
                    VaultStub.openSeries,
                    (address(meme), address(stock), expiries[expirySeed % expiries.length], strike)
                )
            );
        if (!ok) return;

        uint256 seriesId = abi.decode(ret, (uint256));
        if (!known[seriesId]) {
            known[seriesId] = true;
            openedSeries.push(seriesId);
        }
    }

    function depositAndMint(uint256 seriesSeed, uint256 receiverSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        amount = bound(amount, 1e15, 1e24);

        (bool ok,) =
            address(vault).call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, _actor(receiverSeed), amount)));
        if (ok) successfulDeposits++;
    }

    /// @dev 行权在本文件里主要是**布景**：它让 `exercised != 0`，`remainder` 才有内容可算。
    ///      但它同时是 4① 唯一的观察点，所以行权量夹在持有量之内（否则几乎每一笔都撞在
    ///      ERC-1155 的余额检查上，永远走不到「已结算」那一格）。
    function exercise(uint256 seriesSeed, uint256 actorSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address who = _actor(actorSeed);

        uint256 held = warrant.balanceOf(who, seriesId);
        amount = held == 0 ? bound(amount, 0, 1e24) : bound(amount, 1, held);

        bool wasSettled = pool.series(seriesId).settled;
        if (wasSettled) exercisesAttemptedOnSettledSeries++;

        vm.prank(who);
        (bool ok,) = address(pool)
            .call(
                sabotage == Sabotage.IGNORE_SETTLED
                    ? abi.encodeCall(SabotagePool.exerciseIgnoringSettlement, (seriesId, amount, who))
                    : abi.encodeCall(ClearingPool.exercise, (seriesId, amount, who))
            );
        if (!ok) return;

        successfulExercises++;
        // 不变量 4①：`settled ⟹ exercise() revert`
        if (wasSettled) postSettlementExerciseViolations++;
    }

    /// @dev 观测。**不变量 4③ 的全部观察点就在这里。**
    ///
    ///      判据：这一次观测允不允许动 `clearedAt`，由「池子记着的状态」与「链上真实的状态」
    ///      这一**对**决定 —— 只有 `门控 → 非门控` 与 `干净 → 读不通` 这三条边允许盖章。
    function poke(uint256 callerSeed) external {
        uint8 storedBefore = _storedCategory();
        uint8 live = _liveCategory();
        uint64 clearedBefore = pool.gating(address(stock)).clearedAt;

        vm.prank(_actor(callerSeed));
        (bool ok,) = address(pool)
            .call(
                sabotage == Sabotage.SLOPPY_POKE
                    ? abi.encodeCall(SabotagePool.pokeSloppily, (address(stock)))
                    : abi.encodeCall(ClearingPool.pokeGating, (address(stock)))
            );
        if (!ok) return;

        observations++;
        _checkStampRule(storedBefore, live, clearedBefore);
    }

    /// @dev 结算。**不变量 4② 的两半都在这里。**
    function settleExpired(uint256 seriesSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        ClearingPool.Series memory before = pool.series(seriesId);

        uint8 storedBefore = _storedCategory();
        uint8 live = _liveCategory();
        uint64 clearedBefore = pool.gating(address(stock)).clearedAt;

        // 🔴 前提用**观测之前**的记录算，但只在记录与链上真实状态**一致**时才要求结算必须成功。
        //    记录陈旧时 `settleExpired` 会当场自愈，而自愈本身可能盖上一个新的宽限 ——
        //    那不是「结算被阻止」，那是「刚刚才观测到解除，48 小时从现在起算」。
        bool mustSucceed = before.vault != address(0) && !before.settled && storedBefore == live && live != GATED
            && block.timestamp >= _deadlineOracle(before);

        (bool ok,) = address(pool)
            .call(
                sabotage == Sabotage.STUBBORN_SETTLE
                    ? abi.encodeCall(SabotagePool.settleStubbornly, (seriesId))
                    : abi.encodeCall(ClearingPool.settleExpired, (seriesId))
            );

        if (!ok) {
            if (mustSucceed) settlementBlockedViolations++;
            else if (live == GATED) settlementsRejectedWhileGated++;
            else if (before.vault != address(0) && !before.settled) settlementsRejectedTooEarly++;
            return;
        }

        successfulSettlements++;
        // 门控命中时结算**必须**做不到 —— 那就是「自动延期」。
        if (live == GATED) settlementWhileGatedViolations++;

        ClearingPool.Series memory afterwards = pool.series(seriesId);
        if (!afterwards.settled || afterwards.remainder != before.deposited - before.exercised) remainderViolations++;

        // 结算内部也观测了一次，同一条盖章规则照样适用。
        _checkStampRule(storedBefore, live, clearedBefore);
    }

    /// @dev 拨发行方的三个开关。**刻意偏向「什么都没发生」**：门控一多，存入与行权就几乎全被挡下，
    ///      而六条断言在「什么也没干成」时同样成立。合法档位放在 0 上（fuzzer 对 0 有强偏好）。
    ///
    ///      ⚠️ 分档是**量出来的**：`% 8`（干净 5/8）时一整轮撞不到几次门控拒绝，
    ///      改成 `% 6`（干净 3/6）之后，单轮 512 步实测 —— 17 次门控拒绝、16 次「太早」、
    ///      28 次落在已结算系列上的行权、8 条观测到的边、1 次成功结算（宇宙里只有一个会到期的系列，
    ///      所以这个数结构上就是 1）。默认档 256 轮 × 64 步合计仍是几百次。
    ///      🔴 **BSC 版多了一档 `poolSanctioned`**（决策 53）：bStocks 的合规模块除了逐代币黑名单
    ///      还有一张**全局制裁名单**，Robinhood 那版没有对应物。它必须进这个 handler ——
    ///      不变量 4c 防的是「干净 poke 把 `clearedAt` 一路前推」那台泵，而**每一个能让
    ///      `hit` 翻真的来源都各自是一条边**。漏掉一档，那一档的边就从未被扫过。
    function setIssuerGating(uint256 seed) external {
        uint256 mode = seed % 7;
        tokenPaused = mode == 3;
        poolBlocked = mode == 4;
        poolSanctioned = mode == 5;
        viewsBroken = mode == 6;

        stock.setTokenPaused(tokenPaused);
        issuerCompliance.setBlocked(address(stock), address(pool), poolBlocked);
        issuerCompliance.setSanctioned(address(pool), poolSanctioned);
        stock.setViewsRevert(viewsBroken);
        issuerPause.setViewsRevert(viewsBroken);
        issuerCompliance.setViewsRevert(viewsBroken);
    }

    /// @dev 声明门是**单调**的：没声明过的地址随时可以自己签一次。
    function attest(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        vm.prank(who);
        address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, TERMS_0, ATTESTATION_0)));
    }

    /// @dev 时间这一维。步长对着 `expiries` 调过：一轮 64 步里期望约 8 次 warp、均值 3.5 天，
    ///      于是近的那个 expiry（10 天）会在一轮里被稳稳跨过去，结算才有得算。
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    // ────────────────────────────── 判据 ──────────────────────────────

    /// @dev 三条允许盖章的边，一条都不能多，一条都不能少。
    function _checkStampRule(uint8 storedBefore, uint8 live, uint64 clearedBefore) private {
        uint64 clearedAfter = pool.gating(address(stock)).clearedAt;

        bool isEdge = (storedBefore == GATED && live != GATED) || (storedBefore == CLEAN && live == OPAQUE);
        if (isEdge) observedEdges++;

        if (!isEdge) {
            // 🔴 不变量 4③：不在边上就一个字节都不许动
            if (clearedAfter != clearedBefore) clearedAtDriftViolations++;
        } else if (clearedAfter != uint64(block.timestamp)) {
            // 反向：在边上却没盖章 —— 宽限窗根本没打开，fail-open 就退化成了裸的 fail-open
            missedStampViolations++;
        }

        if (clearedAfter < clearedBefore) missedStampViolations++;
    }

    /// @dev 池子**记着**的状态。
    function _storedCategory() private view returns (uint8) {
        ClearingPool.Gating memory g = pool.gating(address(stock));
        if (g.active) return GATED;
        if (g.unreadable) return OPAQUE;
        return CLEAN;
    }

    /// @dev 链上**真实**的状态 —— 读的是 handler 自己拨的开关，不是池子的观测。
    function _liveCategory() private view returns (uint8) {
        if (viewsBroken) return OPAQUE;
        // 🔴 三个来源缺一不可：漏掉 `poolSanctioned`，模型会在制裁档说「干净」而链上说「门控」。
        if (tokenPaused || poolBlocked || poolSanctioned) return GATED;
        return CLEAN;
    }

    /// @dev deadline 按公式**独立算一遍**：只取 `pool.gating()` 的原始字段，不调 `exerciseDeadline()`。
    ///      拿被测函数的结论当自己的前提，等于让它自己给自己打分。
    function _deadlineOracle(ClearingPool.Series memory s) private view returns (uint64) {
        ClearingPool.Gating memory g = pool.gating(s.stockToken);
        if (g.active) return type(uint64).max;
        if (g.clearedAt == 0) return s.expiry;

        uint64 graceEnd = g.clearedAt + GRACE;
        return graceEnd > s.expiry ? graceEnd : s.expiry;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **不变量 4 —— 结算后不可行权；无门控时结算不可阻止。**
///
/// | 款 | 断言 |
/// |---|---|
/// | ① | `settled ⟹ exercise() revert` |
/// | ② | 实时无门控且 `now ≥ max(expiry, clearedAt + 48h)` ⟹ `settleExpired()` 必然成功；反过来，门控命中时它必然失败 |
/// | ③ | **`clearedAt` 只随边变化** —— 对已观测为干净的股票代币再调 `pokeGating`，无论多少次、谁来调，`clearedAt` 必须不变 |
///
/// 🔴 **没有 ③，② 是空的。** ② 的前提本身以 `clearedAt` 表述；能推动 `clearedAt` 的攻击者
/// 只需让前提永不成立，就能永久阻止结算 —— 而他手上本该作废的系列因此获得**无限期免费展期**。
/// 这句话不是注释里的一个论断，它由 `test_theSloppyPokeBackdoorIsInvisibleTo4b` **当场演示**：
/// 同一个后门让 ③ 当场变红，而 ② 一声不吭。
contract Invariant4SettlementAndGatingTest is Test {
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    SettlementHandler internal handler;

    function setUp() public {
        // 分叉测试跑在真实时间戳上，本地默认是 1；推到一个「48 小时早就过去了」的起点。
        vm.warp(1_800_000_000);

        (pool, warrant, distributor, registry, factory) = _deploySystem(false);
        handler = new SettlementHandler(
            pool, warrant, registry, address(distributor), factory, SettlementHandler.Sabotage.NONE
        );

        targetContract(address(handler));
    }

    function _deploySystem(bool sabotaged)
        internal
        returns (
            ClearingPool pool_,
            Warrant warrant_,
            MerkleDistributor distributor_,
            AttestationRegistry registry_,
            FactoryStub factory_
        )
    {
        registry_ = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant_ = new Warrant();
        distributor_ = new MerkleDistributor(makeAddr("publisher"));
        factory_ = new FactoryStub();
        pool_ = sabotaged
            ? ClearingPool(address(new SabotagePool(warrant_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(warrant_, address(distributor_), registry_, factory_.registry());
        warrant_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    function _sabotagedHandler(SettlementHandler.Sabotage mode) internal returns (SettlementHandler h) {
        (ClearingPool p, Warrant w, MerkleDistributor d, AttestationRegistry r, FactoryStub f) = _deploySystem(true);
        h = new SettlementHandler(p, w, r, address(d), f, mode);
    }

    // ─────────────────────────── 不变量 4 ───────────────────────────

    function invariant_4a_settledSeriesCannotBeExercised() public view {
        assertEq(
            handler.postSettlementExerciseViolations(), 0, unicode"不变量 4①：已结算的系列被行权了"
        );
    }

    function invariant_4b_settlementCannotBeBlockedWithoutGating() public view {
        assertEq(
            handler.settlementBlockedViolations(),
            0,
            unicode"不变量 4②：无门控、已过 deadline，结算却失败了"
        );
        assertEq(
            handler.settlementWhileGatedViolations(), 0, unicode"不变量 4②：门控命中时结算竟然成功了"
        );
    }

    function invariant_4c_clearedAtOnlyMovesOnEdges() public view {
        assertEq(
            handler.clearedAtDriftViolations(),
            0,
            unicode"不变量 4③：一次不在边上的观测推动了 clearedAt"
        );
        assertEq(
            handler.missedStampViolations(),
            0,
            unicode"不变量 4③ 反向：该盖的章没盖，或 clearedAt 倒退"
        );
    }

    /// @notice 结算写下的 `remainder` 就是这个系列在池内剩下的全部债权。
    /// @dev #12 会拿着它去铸后继系列的权证 —— 多写一分就是凭空多发。
    function invariant_4_remainderIsDepositedMinusExercised() public view {
        assertEq(handler.remainderViolations(), 0, unicode"remainder ≠ deposited − exercised");
    }

    /// @notice 结算与滚存改变了不变量 1 的账面形状（`settled` 被跳过、`remainder` 加进全局那一款），
    ///         所以用**同一份** `CollateralCheck` 在这条序列上再跑一遍。
    function invariant_1_collateralisationSurvivesSettlement() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(
            perSeries, 0, unicode"不变量 1①：结算之后某个未结算系列的债权超过了它的抵押品"
        );
        assertEq(global, 0, unicode"不变量 1②：remainder 记进来之后池内余额兜不住全部债权");
    }

    // ──────────────── 覆盖度：六条断言不是在空转 ────────────────

    // handler 的种子语义写成常量。写成裸数字的话，分档一动，下面这些测试会**照常变绿**，
    // 只是不再测它们声称在测的东西。
    uint256 internal constant GATING_CLEAR = 0;
    uint256 internal constant GATING_TOKEN_PAUSED = 3;
    uint256 internal constant GATING_POOL_BLOCKED = 4;
    /// @dev BSC 版新增的第三个门控来源（决策 53）。加它把 `GATING_VIEWS_BROKEN` 顶到了 6 ——
    ///      🔴 这几个常量与 {GatingHandler-setIssuerGating} 里那个 `seed % 7` 的分支表是**同一张表**，
    ///      改一处必须改另一处；不改的后果是这个文件里的确定性覆盖用例静默选错档。
    uint256 internal constant GATING_POOL_SANCTIONED = 5;
    uint256 internal constant GATING_VIEWS_BROKEN = 6;
    uint256 internal constant HOLDER_ATTESTED = 0;
    uint256 internal constant NEAR_EXPIRY = 1;

    /// @dev 确定性地把每一条路径都走一遍：存入 → 行权 → 门控挡住结算 → 解除 → 宽限 → 结算成功
    ///      → 已结算系列上的行权被拒。六条断言各自的观察点因此都真的被撞到过。
    function test_handlerReachesSettlementAndEveryRejection() public {
        handler.openSeries(NEAR_EXPIRY, 1e18);
        handler.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler 存不进去");

        handler.exercise(0, HOLDER_ATTESTED, 10 ether);
        assertEq(handler.successfulExercises(), 1, unicode"handler 行不了权");

        // 还没到期：结算太早
        handler.settleExpired(0);
        assertEq(handler.settlementsRejectedTooEarly(), 1, unicode"「结算太早」这条路径没被撞到");

        // 发行方冻上并被观测到 —— 过期之后结算仍然被结构性阻止
        handler.setIssuerGating(GATING_POOL_BLOCKED);
        handler.poke(0);
        vm.warp(handler.expiries(NEAR_EXPIRY) + 1 days);
        handler.settleExpired(0);
        assertEq(handler.settlementsRejectedWhileGated(), 1, unicode"「门控阻止结算」这条路径没被撞到");
        assertEq(handler.settlementWhileGatedViolations(), 0, unicode"而且它确实没结算成");

        // 解除 → 观测到边 → 宽限之后结算成功
        handler.setIssuerGating(GATING_CLEAR);
        handler.poke(0);
        assertGt(handler.observedEdges(), 0, unicode"一条边都没观测到");
        vm.warp(block.timestamp + 48 hours);
        handler.settleExpired(0);
        assertEq(handler.successfulSettlements(), 1, unicode"handler 结算不了");
        assertEq(handler.remainderViolations(), 0, "remainder");

        // 已结算的系列上再行权 —— 4① 的观察点
        handler.exercise(0, HOLDER_ATTESTED, 1 ether);
        assertEq(handler.exercisesAttemptedOnSettledSeries(), 1, unicode"「已结算系列上的行权」没被撞到");
        assertEq(handler.postSettlementExerciseViolations(), 0, unicode"而且它确实没成功");

        // fail-open 那一档也走一遍：读不通 ⟹ 盖章，但只盖一次
        handler.openSeries(0, 1e18);
        handler.depositAndMint(1, HOLDER_ATTESTED, 50 ether);
        handler.setIssuerGating(GATING_VIEWS_BROKEN);
        uint256 edgesBefore = handler.observedEdges();
        handler.poke(0);
        assertEq(handler.observedEdges(), edgesBefore + 1, unicode"「干净 → 读不通」这条边没被撞到");
        handler.poke(1);
        handler.poke(2);
        assertEq(handler.clearedAtDriftViolations(), 0, unicode"窗口内的重复观测推动了 clearedAt");

        handler.setIssuerGating(GATING_TOKEN_PAUSED);
        handler.poke(0);
        assertEq(handler.missedStampViolations(), 0, "missedStamp");
    }

    // ──────────────── 反证：三个探测器真的会响 ────────────────

    /// @dev 🔴 **这条测试就是「没有 ③，② 是空的」本身。**
    ///
    ///      装上「每次 poke 都盖 `clearedAt`」这个后门，然后：
    ///      - **③ 当场变红** —— 它抓的正是这个；
    ///      - **② 一声不吭** —— 它的前提以 `clearedAt` 表述，而 `clearedAt` 被推到了未来，
    ///        于是「已过 deadline」永远为假，前提空真。
    ///
    ///      与此同时，攻击的**后果**是实打实的：结算一次都做不成。
    function test_theSloppyPokeBackdoorIsInvisibleTo4b() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.SLOPPY_POKE);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);

        // 先制造一次真实的「门控 → 干净」，让 clearedAt 有个非零起点
        h.setIssuerGating(GATING_POOL_BLOCKED);
        h.poke(0);
        h.setIssuerGating(GATING_CLEAR);
        h.poke(0);

        vm.warp(h.expiries(NEAR_EXPIRY) + 30 days);

        // 攻击者按 47 小时一轮往前推
        for (uint256 round = 0; round < 4; round++) {
            vm.warp(block.timestamp + 47 hours);
            h.poke(round);
            h.settleExpired(0);
        }

        assertGt(h.clearedAtDriftViolations(), 0, unicode"不变量 4③ 的探测器没响");
        assertEq(
            h.settlementBlockedViolations(),
            0,
            unicode"🔴 不变量 4② 竟然响了？那这条反证就没在演示「② 是空的」"
        );
        assertEq(h.successfulSettlements(), 0, unicode"而攻击的后果是实打实的：一次都结算不成");
    }

    /// @dev ② 的探测器：无门控、也过了 deadline，却结算不了。
    function test_theDetectorDetects_aSettlementThatShouldHaveSucceeded() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.STUBBORN_SETTLE);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        h.poke(0); // 记录：干净，与实时一致

        vm.warp(h.expiries(NEAR_EXPIRY) + 1 days);
        h.settleExpired(0);

        assertGt(h.settlementBlockedViolations(), 0, unicode"不变量 4② 的探测器没响");
        assertEq(h.successfulSettlements(), 0, unicode"前置条件：那一笔确实没结算成");
    }

    /// @dev ① 的探测器：已结算的系列被行权。用户的抵押品因此被支取两次 ——
    ///      一次给行权的人，一次留在 `remainder` 里等着 #12 铸成后继系列的权证。
    function test_theDetectorDetects_anExerciseAfterSettlement() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.IGNORE_SETTLED);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        h.poke(0);

        vm.warp(h.expiries(NEAR_EXPIRY) + 1 days);
        h.settleExpired(0);
        assertEq(h.successfulSettlements(), 1, unicode"前置条件：先真的结算一次");

        h.exercise(0, HOLDER_ATTESTED, 10 ether);

        assertEq(h.exercisesAttemptedOnSettledSeries(), 1, unicode"前置条件：确实打在已结算的系列上");
        assertGt(h.postSettlementExerciseViolations(), 0, unicode"不变量 4① 的探测器没响");

        // 后果说清楚：这 10 ether 已经被算进 `remainder` 了，却又被支取了一次。
        SabotagePool bad = SabotagePool(address(h.pool()));
        assertEq(bad.series(h.openedSeries(0)).remainder, 100 ether, unicode"remainder 还写着 100");
        assertEq(h.stock().balanceOf(address(bad)), 90 ether, unicode"而池子里只剩 90");
    }

    /// @dev 三个探测器的另一半：它们对**真实**的池子必须全部沉默，
    ///      否则上面三条证明的只是「它们总是响」。
    function test_theDetectorsAreSilentOnTheRealPool() public {
        test_handlerReachesSettlementAndEveryRejection();

        assertEq(handler.postSettlementExerciseViolations(), 0, "4a");
        assertEq(handler.settlementBlockedViolations(), 0, "4b");
        assertEq(handler.settlementWhileGatedViolations(), 0, "4b'");
        assertEq(handler.clearedAtDriftViolations(), 0, "4c");
        assertEq(handler.missedStampViolations(), 0, "4c'");
        assertEq(handler.remainderViolations(), 0, "remainder");
    }
}
