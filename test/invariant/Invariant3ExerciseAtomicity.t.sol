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
import {MemeToken} from "../helpers/MemeToken.sol";
import {GatedStockToken, StockToken} from "../helpers/StockToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {CollateralCheck} from "./Invariant1And2MintingPath.t.sol";

interface IExerciseStockToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function frozen() external view returns (bool);
    function setFrozen(bool frozen_) external;
}

/// @notice **只用于反证探测器真的会响。**
///
/// 🔴 在 EVM 里原子性是**默认**的：一次调用要么整个生效，要么整个回滚。所以「行权不原子」这件事
/// 只有一种写得出来的形状 —— **把某个子步骤的失败显式吞掉**（`try/catch`，或忽略低层调用的返回值）。
/// 下面这个后门就是那个形状：权证照烧、MEME 照烧，而股票代币那一步失败了也当没发生。
///
/// 用户拿到的结果是：**付了钱、烧了权证、什么都没收到**。这正是不变量 3 要禁止的那件事。
///
/// @dev 后门写成**另一个函数**，不把生产的 `exercise` 改成 `virtual` —— issue #5 的测试纪律禁止
///      「为了可测性在生产代码里留钩子」。生产合约里没有这个入口，由
///      `test/ClearingPool.t.sol::test_writeSurface_isExactlySixFunctions` 枚举 ABI 证明。
///
///      ⚠️ 代价是它**重写了一遍三步**（含定价那一行），这在本仓库通常是要挨骂的重复。
///      它在这里躲不掉：子步骤的失败只能在**函数内部**被吞掉，从外面包一层 `try/catch` 会把
///      整笔（含权证销毁）一起回滚，也就复现不出要证伪的那种坏法。
///      🔴 因此重复的风险改由断言兜住：`test_theDetectorDetects_aSwallowedStockTransfer`
///      直接断言**每一条腿**的余额，而不只是「计数器响了」—— 定价那行真漂了，那条测试会红。
contract NonAtomicPool is ClearingPool {
    /// @notice 上一次吞掉的那个股票代币转账成功了吗。留着是为了让反证读得懂自己在测什么。
    bool public lastStockTransferOk;

    constructor(
        IWarrant warrant_,
        address distributor_,
        IAttestationRegistry attestations_,
        IVaultRegistry vaultRegistry_
    ) ClearingPool(warrant_, distributor_, attestations_, vaultRegistry_) {}

    function exerciseSwallowingStockFailure(uint256 seriesId, uint256 amount, address beneficiary) external {
        Series storage s = _series[seriesId];
        uint256 memeAmount = (amount * s.strike) / 1e18;

        s.exercised += uint128(amount);
        warrant.burn(msg.sender, seriesId, amount);
        IERC20(s.memeToken).transferFrom(beneficiary, BURN_ADDRESS, memeAmount);

        (lastStockTransferOk,) =
            s.stockToken.call(abi.encodeWithSelector(IERC20.transfer.selector, beneficiary, amount));
    }
}

/// @notice 只用于证明成功侧探测器不会被「余额逆向变化」炸成一次被 fuzzer 吞掉的 revert。
/// @dev 开关打开后，池子仍按 `amount` 被扣款，但受益人的既有余额反而减少 1 wei。
contract ReverseBalanceStockToken is StockToken {
    bool public frozen;
    bool public reverseTransfers;

    error IssuerFrozen();

    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    function setReverseTransfers(bool enabled) external {
        reverseTransfers = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen && from != address(0) && to != address(0)) revert IssuerFrozen();
        if (reverseTransfers && from != address(0) && to != address(0)) {
            super._update(from, address(0), value);
            super._update(to, address(0), 1 wei);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice 驱动行权路径的 handler。
///
/// 🔴 **本合约的任何函数都不 revert**（同另外两个不变量文件的取舍）：不变量跑在
/// `fail_on_revert = false` 下，handler 里的 `assertEq` 失败就是一次 revert，会被 fuzzer 静静吞掉
/// —— 断言写了等于没写。所以违规一律**记进计数器**，由 `invariant_*` 去断言计数为零。
///
/// 宇宙刻意做小：一只股票代币、一只 MEME、三个受益人、两个 expiry。这样
/// ① 成功的行权会被大量撞到（否则三条「计数为 0」的断言全是空转）；
/// ② 每一类失败 —— 白名单、声明门、过期、余额不足、发行方冻结 —— 也都撞得到。
///
/// ⚠️ ① 是**量出来的，不是希望出来的**：下面每一处「偏向合法」的取值都对着计数器调过。
/// 第一版一轮 64 步下来 **0 次成功行权** —— 三条断言全绿，但什么也没检查。三个原因，逐条修在
/// 各自的注释里：fuzzer 对 0 的偏好把「陌生调用方」撞成了常态、`warp` 的步子大到整轮全过期、
/// 行权量不夹在持有量之内导致几乎全部撞在 ERC-1155 的余额检查上。
/// 调完之后每轮稳定落在 1–3 次成功行权（`--fuzz-seed 1 / 7 / 99` 各测过），
/// 256 轮合计数百次 —— CI 档（1000 轮 × 128 步）再翻一倍。
/// 🔴 每条成功路径本身仍由下面的 `test_handlerReachesTheSuccessPathsAndTheRejections` 确定性地钉住，
/// 不靠 fuzz 的运气。
contract ExerciseHandler is CommonBase, StdUtils {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    struct ExerciseSnapshot {
        uint256 warrantBalance;
        uint256 beneficiaryMemeBalance;
        uint256 deadMemeBalance;
        uint256 poolStockBalance;
        uint256 beneficiaryStockBalance;
        uint256 exercised;
    }

    ClearingPool public immutable pool;
    Warrant public immutable warrant;
    AttestationRegistry public immutable registry;
    address public immutable distributor;

    VaultStub public immutable vault;
    IExerciseStockToken public immutable stock;
    MemeToken public immutable meme;

    /// @dev 受益人。`actors[2]` **刻意一直不声明**，直到 `attest` 动作把它推过门 ——
    ///      「未声明被拒」与「声明之后就能行权」两条路径因此都在覆盖里。
    address[3] public actors;
    uint64[2] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice 不变量 3（失败侧）：一次**失败**的行权改动了任何余额或账目的次数。必须恒为 0。
    uint256 public atomicityViolations;
    /// @notice 不变量 3（成功侧）：一次**成功**的行权，三样东西没有一起、按量变动的次数。必须恒为 0。
    uint256 public consistencyViolations;

    /// @dev 覆盖度计数 —— 三条断言全是「某个计数为 0」，一个什么都没干成的 handler 同样满足它们。
    uint256 public successfulExercises;
    uint256 public rejectedExercises;
    /// @notice 其中，发行方冻结着（第 3 步必然失败）时被拒的次数。产品承诺就落在这个数上。
    uint256 public rejectedWhileFrozen;
    uint256 public successfulDeposits;

    /// @dev 反证接线：为 true 时走 {NonAtomicPool} 的后门。**真实运行里恒为 false。**
    bool public immutable sabotage;

    constructor(
        ClearingPool pool_,
        Warrant warrant_,
        AttestationRegistry registry_,
        address distributor_,
        FactoryStub factory_,
        bool sabotage_,
        bool reverseStockBalance_
    ) {
        pool = pool_;
        warrant = warrant_;
        registry = registry_;
        distributor = distributor_;
        sabotage = sabotage_;

        vault = new VaultStub(pool_);
        stock = reverseStockBalance_
            ? IExerciseStockToken(address(new ReverseBalanceStockToken()))
            : IExerciseStockToken(address(new GatedStockToken()));
        meme = new MemeToken();

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定（M2-5 / #37）。
        factory_.bind(address(meme), address(vault));

        // 🔴 一远一近，顺序也是刻意的：远的那个**保证整轮都活着**（否则一轮跑到一半全部系列过期，
        //    成功路径此后一次也撞不到，而三条断言在「什么都没发生」时同样成立），
        //    近的那个会被 `warp` 跨过去，覆盖「已过 deadline」那条拒绝。
        //    远的排在下标 0，因为 fuzzer 对 0 有强偏好 —— 见 `exercise` 里对同一件事的注释。
        expiries = [uint64(block.timestamp + 400 days), uint64(block.timestamp + 30 days)];
        actors = [makeAddrLike("holder A"), makeAddrLike("holder B"), makeAddrLike("holder C")];

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        for (uint256 i = 0; i < actors.length; i++) {
            meme.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            meme.approve(address(pool_), type(uint256).max);
            // actors[2] 留着不声明
            if (i < 2) {
                vm.prank(actors[i]);
                registry_.attest(0, TERMS_0, ATTESTATION_0);
            }
        }
        // distributor 自己也持有权证（真实路径里整周的权证都铸给它），并且**从不**声明 ——
        // 「门查受益人不查调用方」因此在 fuzz 里也是活的。
        meme.mint(distributor_, 1e30);
        vm.prank(distributor_);
        meme.approve(address(pool_), type(uint256).max);
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
        // 下界不取 0：存入在本文件里是**布景**，它的边界（零存入、带税、uint128 溢出、再入）
        // 由 `Invariant1And2MintingPath.t.sol` 负责。这里要的只是「手上真的有权证可以烧」。
        amount = bound(amount, 1e15, 1e24);

        (bool ok,) =
            address(vault).call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, _receiver(receiverSeed), amount)));
        if (ok) successfulDeposits++;
    }

    /// @dev 本文件的主角。调用方与行权量都**偏向**合法，否则一整轮下来一次成功的行权都撞不到，
    ///      而三条断言在「什么都没发生」时同样成立。两处偏向都是实测调出来的，不是猜的。
    ///
    /// @param clampToHeld 把行权量夹到调用方**真的持有**的量之内。不夹的话几乎每一笔都撞在
    ///                    ERC-1155 的余额检查上（实测：一轮 0 次成功），而那条路径单元测试已经覆盖。
    function exercise(uint256 seriesSeed, uint256 callerSeed, uint256 beneficiarySeed, uint256 amount, bool clampToHeld)
        external
    {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address beneficiary = _receiver(beneficiarySeed);

        // 🔴 **合法取值放在 0 上。** fuzzer 对 0 有强偏好，把「陌生调用方」放在 `% 4 == 0` 上，
        //    一轮里大半的行权都会停在第一道门 —— 实测 11 次拒绝里 5 次是它，而成功 0 次。
        //    distributor 代发起那一档留着：那条路径上持有方与受益人不是同一个地址。
        address caller = beneficiary;
        if (callerSeed % 4 == 2) caller = distributor;
        if (callerSeed % 4 == 3) caller = makeAddrLike("stranger");

        uint256 held = warrant.balanceOf(caller, seriesId);
        amount = clampToHeld && held != 0 ? bound(amount, 1, held) : bound(amount, 0, 1e24);

        ClearingPool.Series memory s = pool.series(seriesId);
        uint256 memeAmount = (amount * s.strike) / 1e18;

        ExerciseSnapshot memory before = _snapshot(seriesId, caller, beneficiary);

        vm.prank(caller);
        (bool ok,) = address(pool)
            .call(
                sabotage
                    ? abi.encodeCall(NonAtomicPool.exerciseSwallowingStockFailure, (seriesId, amount, beneficiary))
                    : abi.encodeCall(ClearingPool.exercise, (seriesId, amount, beneficiary))
            );

        ExerciseSnapshot memory afterwards = _snapshot(seriesId, caller, beneficiary);

        if (!ok) {
            rejectedExercises++;
            if (stock.frozen()) rejectedWhileFrozen++;
            if (!_sameSnapshot(before, afterwards)) atomicityViolations++;
            return;
        }

        successfulExercises++;
        // 🔴 三样东西必须**一起**、**按量**变动。少查一样，「烧了权证却没拿到货」就能溜过去。
        if (!_isConsistentExercise(before, afterwards, amount, memeAmount)) consistencyViolations++;
    }

    /// @dev 权证**转让自由**是产品前提，所以持有方与受益人可以不是同一个人。
    function transferWarrant(uint256 seriesSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address from = _receiver(fromSeed);
        amount = bound(amount, 0, warrant.balanceOf(from, seriesId));

        vm.prank(from);
        address(warrant).call(abi.encodeCall(warrant.safeTransferFrom, (from, _receiver(toSeed), seriesId, amount, "")));
    }

    /// @dev 发行方冻结 / 解冻。**第 3 步失败**这条路径全靠它 —— 而那正是产品承诺的场景。
    ///
    ///      ⚠️ 只有 1/4 的调用会把它冻上，而且**刻意不放在 `% 4 == 0` 上**（fuzzer 偏爱 0）：
    ///      对半开的话一整轮里连存入都进不去几次，于是「成功的行权」几乎撞不到，
    ///      而三条断言在什么都没发生时同样成立（实测过，对半开时一轮下来 0 次成功存入）。
    ///      冻结要留在覆盖里，但它是**偶发事件**，不是常态。
    function toggleIssuerFreeze(uint256 seed) external {
        stock.setFrozen(seed % 4 == 1);
    }

    /// @dev 声明门是**单调**的：没声明过的地址随时可以自己签一次，签过就再也回不去。
    function attest(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        vm.prank(who);
        address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, TERMS_0, ATTESTATION_0)));
    }

    /// @dev 时间这一维：跨过 `expiry` 之后行权必须被拒，而**权证不该因此消失**。
    ///
    ///      步长对着 `expiries` 调过：一轮 64 步里期望有约 9 次 warp，均值 3.5 天 ⟹ 一轮跨掉
    ///      约 30 天，正好落在两个 expiry 之间。步子迈大了，整轮开头就全过期，成功路径一次也撞不到。
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    // ────────────────────────────── 记录 ──────────────────────────────

    function _snapshot(uint256 seriesId, address holder, address beneficiary)
        private
        view
        returns (ExerciseSnapshot memory snap)
    {
        snap.warrantBalance = warrant.balanceOf(holder, seriesId);
        snap.beneficiaryMemeBalance = meme.balanceOf(beneficiary);
        snap.deadMemeBalance = meme.balanceOf(DEAD);
        snap.poolStockBalance = stock.balanceOf(address(pool));
        snap.beneficiaryStockBalance = stock.balanceOf(beneficiary);
        snap.exercised = pool.series(seriesId).exercised;
    }

    function _sameSnapshot(ExerciseSnapshot memory before, ExerciseSnapshot memory afterwards)
        private
        pure
        returns (bool)
    {
        return before.warrantBalance == afterwards.warrantBalance
            && before.beneficiaryMemeBalance == afterwards.beneficiaryMemeBalance
            && before.deadMemeBalance == afterwards.deadMemeBalance
            && before.poolStockBalance == afterwards.poolStockBalance
            && before.beneficiaryStockBalance == afterwards.beneficiaryStockBalance
            && before.exercised == afterwards.exercised;
    }

    function _isConsistentExercise(
        ExerciseSnapshot memory before,
        ExerciseSnapshot memory afterwards,
        uint256 amount,
        uint256 memeAmount
    ) private pure returns (bool) {
        return _decreasedBy(before.warrantBalance, afterwards.warrantBalance, amount)
            && _decreasedBy(before.beneficiaryMemeBalance, afterwards.beneficiaryMemeBalance, memeAmount)
            && _increasedBy(before.deadMemeBalance, afterwards.deadMemeBalance, memeAmount)
            && _decreasedBy(before.poolStockBalance, afterwards.poolStockBalance, amount)
            && _increasedBy(before.beneficiaryStockBalance, afterwards.beneficiaryStockBalance, amount)
            && _increasedBy(before.exercised, afterwards.exercised, amount);
    }

    function _decreasedBy(uint256 beforeValue, uint256 afterValue, uint256 expected) private pure returns (bool) {
        return beforeValue >= afterValue && beforeValue - afterValue == expected;
    }

    function _increasedBy(uint256 beforeValue, uint256 afterValue, uint256 expected) private pure returns (bool) {
        return afterValue >= beforeValue && afterValue - beforeValue == expected;
    }

    /// @dev 收款方 / 受益人的取值域：三个 actor 加上 distributor 本身。
    function _receiver(uint256 seed) private view returns (address) {
        uint256 i = seed % 4;
        return i == 3 ? distributor : actors[i];
    }

    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **不变量 3 —— 行权原子性。**
///
/// | 款 | 断言 |
/// |---|---|
/// | 失败侧 | 任一子步骤失败 ⟹ 权证与 MEME 余额均不变（账目与抵押品亦然） |
/// | 成功侧 | 行权成功 ⟹ 权证、MEME、股票代币**一起**按量变动 |
///
/// 🔴 **两侧缺一不可。** 只写失败侧的话，「把股票代币那一步的失败吞掉」会大摇大摆地通过 ——
/// 那时调用**没有**失败，用户只是付了钱、烧了权证、什么也没收到。而那恰恰是这条不变量真正要禁止的
/// 那件事（`spec.zh.md` §11：发行方冻结时，用户不会失去权证）。
///
/// 附带跑一遍不变量 1 的判据：行权是唯一让抵押品**离开池子**的路径，它不能把偿付覆盖打破。
/// 用的是 `Invariant1And2MintingPath.t.sol` 里的同一份 `CollateralCheck` —— 两处各写一遍判据，
/// 等于让其中一份去验证另一份。
contract Invariant3ExerciseAtomicityTest is Test {
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    ExerciseHandler internal handler;

    function setUp() public {
        (pool, warrant, distributor, registry, factory) = _deploySystem(false);
        handler = new ExerciseHandler(pool, warrant, registry, address(distributor), factory, false, false);

        targetContract(address(handler));
    }

    /// @dev 部署真实的四合约并完成两处绑定（issue #5 的测试缝）。
    ///      `nonAtomic = true` 时把池子换成带后门的那一份 —— 只有反证用。
    function _deploySystem(bool nonAtomic)
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
        pool_ = nonAtomic
            ? ClearingPool(address(new NonAtomicPool(warrant_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(warrant_, address(distributor_), registry_, factory_.registry());
        warrant_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    // ─────────────────────────── 不变量 3 ───────────────────────────

    /// @notice 失败的行权什么也没改。
    ///
    /// @dev ⚠️ 老实说：这个计数器在今天的实现下**结构上不可能**响 —— EVM 里回滚就是回滚。
    ///      留着它有两个理由：它让「失败之后什么都没变」成为一条**会执行**的检查而不是一句注释；
    ///      并且实现哪天改用低层调用而忘了检查返回值时，它是第一道会红的地方。
    ///      真正承重的反证是下面那条成功侧的。
    function invariant_3a_aFailedExerciseChangesNothing() public view {
        assertEq(handler.atomicityViolations(), 0, unicode"不变量 3：一次失败的行权改动了余额或账目");
    }

    /// @notice 成功的行权，三样东西一起按量变动。
    function invariant_3b_aSuccessfulExerciseMovesAllThreeLegs() public view {
        assertEq(
            handler.consistencyViolations(),
            0,
            unicode"不变量 3：行权成功了，但权证 / MEME / 股票代币没有一起按量变动"
        );
    }

    /// @notice 行权是抵押品唯一的出池路径 —— 它不能把偿付覆盖打破。
    function invariant_1_collateralisationSurvivesExercise() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"不变量 1①：行权之后某个系列的债权超过了它的抵押品");
        assertEq(global, 0, unicode"不变量 1②：行权之后池内余额兜不住全部债权");
    }

    // ──────────────────── 反证：上面两条不是空转 ────────────────────

    // handler 的种子语义写成常量。它们按 `% 4` 分档，改了 handler 就得改这里 ——
    // 写成裸数字的话，分档一动，下面这些测试会**照常变绿**，只是不再测它们声称在测的东西。
    uint256 internal constant CALLER_IS_BENEFICIARY = 0;
    uint256 internal constant CALLER_IS_DISTRIBUTOR = 2;
    uint256 internal constant CALLER_IS_STRANGER = 3;
    uint256 internal constant BENEFICIARY_ATTESTED = 0; // actors[0]
    uint256 internal constant BENEFICIARY_UNATTESTED = 2; // actors[2]
    uint256 internal constant FREEZE = 1;
    uint256 internal constant UNFREEZE = 0;

    /// @dev 三条断言全是「某个计数为 0」，而一个**什么都没干成**的 handler 同样满足它们。
    ///      这里确定性地证明成功路径与每一类拒绝路径都真的走得通。
    function test_handlerReachesTheSuccessPathsAndTheRejections() public {
        handler.openSeries(0, 1e18);
        handler.depositAndMint(0, 0, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler 存不进去");

        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);
        assertEq(handler.successfulExercises(), 1, unicode"handler 行不了权");
        assertEq(handler.consistencyViolations(), 0, unicode"成功路径上三条腿是齐的");

        // distributor 代发起：持有方与受益人不是同一个地址（权证在 actors[0] 手上，所以这一笔会被
        // ERC-1155 的余额检查拒掉 —— 要的是这条**分支**被走到，不是它成功）
        handler.exercise(0, CALLER_IS_DISTRIBUTOR, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 1, unicode"「distributor 代发起」这条分支没被走到");

        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_UNATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 2, unicode"「未声明」这条路径没被撞到");

        handler.exercise(0, CALLER_IS_STRANGER, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 3, unicode"「第三方调用」这条路径没被撞到");

        // 🔴 发行方冻结 —— 产品承诺就落在这条上
        handler.toggleIssuerFreeze(FREEZE);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedWhileFrozen(), 1, unicode"「发行方冻结」这条路径没被撞到");
        assertEq(handler.atomicityViolations(), 0, unicode"而且它什么都没改");

        // 过期 —— 直接推到 `expiry` 那一秒，判据是 `block.timestamp < deadline`
        handler.toggleIssuerFreeze(UNFREEZE);
        handler.warp(1 days);
        vm.warp(handler.expiries(0));
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 5, unicode"「已过 deadline」这条路径没被撞到");
        assertEq(handler.atomicityViolations(), 0, unicode"过期那一笔同样什么都没改");
    }

    /// @dev 🔴 探测器反证：把「第 3 步失败就当没发生」这个后门装进池子。
    ///      用户付了 MEME、烧了权证、股票代币一枚没收到 —— 成功侧的计数必须**当场响**。
    ///
    ///      少了这条，`invariant_3b` 随时可能因为判据本身写错而**永远为真** ——
    ///      那正是一条不变量最坏的失效方式：它还在，还是绿的，但已经不检查任何东西。
    function test_theDetectorDetects_aSwallowedStockTransfer() public {
        (
            ClearingPool bad,
            Warrant badWarrant,
            MerkleDistributor badDistributor,
            AttestationRegistry badRegistry,
            FactoryStub badFactory
        ) = _deploySystem(true);
        ExerciseHandler h =
            new ExerciseHandler(bad, badWarrant, badRegistry, address(badDistributor), badFactory, true, false);

        h.openSeries(0, 1e18);
        h.depositAndMint(0, 0, 100 ether);
        h.toggleIssuerFreeze(FREEZE); // 第 3 步从此必然失败

        address holder = h.actors(0);
        uint256 seriesId = h.openedSeries(0);
        uint256 memeBefore = h.meme().balanceOf(holder);

        h.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(h.successfulExercises(), 1, unicode"前置条件：后门确实「成功」了一次");
        assertFalse(
            NonAtomicPool(address(bad)).lastStockTransferOk(),
            unicode"前置条件：股票代币那一步真的失败了"
        );

        // 🔴 直接断言**每一条腿**，不只是「计数器响了」。这条反证要证明的是探测器抓到了
        //    「前两条腿动了、第三条没动」这个**具体**形状 —— 而后门重写了一遍三步（含定价那一行）。
        //    只看计数器的话，定价哪天写漂了，计数器照样响，反证仍然是绿的，但它证明的已经是另一件事。
        assertEq(h.warrant().balanceOf(holder, seriesId), 90 ether, unicode"第 1 条腿：权证真的被烧掉了");
        assertEq(memeBefore - h.meme().balanceOf(holder), 10 ether, unicode"第 2 条腿：MEME 真的被扣走了");
        assertEq(h.stock().balanceOf(holder), 0, unicode"🔴 第 3 条腿没动 —— 用户什么都没收到");

        assertGt(h.consistencyViolations(), 0, unicode"成功侧的探测器没响");
    }

    /// @dev 逆向变化也必须记为违规，不能让 checked subtraction panic 后被 fuzzer 吞掉。
    function test_theDetectorCountsAReverseBalanceInsteadOfReverting() public {
        // 🔴 用**池子那一份**身份根：新 handler 会新建自己的 MEME 与金库，登记进同一份名册即可
        //    （一只 MEME 只登记得进一次，而这只是新的）。换一份 registry 反而会静默失效 ——
        //    池子的 authenticator 是 `immutable`，它只认部署时那一份。
        ExerciseHandler h = new ExerciseHandler(pool, warrant, registry, address(distributor), factory, false, true);
        ReverseBalanceStockToken reverseStock = ReverseBalanceStockToken(address(h.stock()));

        h.openSeries(0, 1e18);
        h.depositAndMint(0, 0, 100 ether);

        address holder = h.actors(0);
        reverseStock.mint(holder, 1 wei);
        reverseStock.setReverseTransfers(true);

        h.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(reverseStock.balanceOf(holder), 0, unicode"前置条件：受益人的股票余额确实逆向减少");
        assertEq(h.successfulExercises(), 1, unicode"后门行权应当成功返回");
        assertGt(h.consistencyViolations(), 0, unicode"逆向余额变化没被成功侧探测器记下");
    }

    /// @dev 探测器反证的另一半：判据必须对**真实**的池子给出零违规，
    ///      否则上一条证明的只是「它总是响」。
    function test_theDetectorIsSilentOnTheRealPool() public {
        handler.openSeries(0, 1e18);
        handler.depositAndMint(0, 0, 100 ether);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        // 同样的冻结，走真实的 `exercise`：这一次整笔回滚，什么都没变。
        handler.toggleIssuerFreeze(FREEZE);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(handler.consistencyViolations(), 0, unicode"真实池子上成功侧不该响");
        assertEq(handler.atomicityViolations(), 0, unicode"真实池子上失败侧也不该响");
        assertEq(handler.rejectedWhileFrozen(), 1, unicode"前置条件：冻结那一笔确实被拒了");
    }
}
