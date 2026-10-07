// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {ICall} from "../../src/interfaces/ICall.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {IssuerComplianceStub, IssuerGatedStockToken, IssuerPauseManagerStub} from "../helpers/IssuerGating.sol";
import {MemeToken} from "../helpers/MemeToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {CollateralCheck} from "./Invariant1And2MintingPath.t.sol";

/// @dev Three states were observed.handler The first of these is the "aqueous" and "real" of the chain, which is used to describe the "pools" and "the real ones on the chain."
///      Both.**Match**I decided this observation was not allowed. `clearedAt`.
uint8 constant CLEAN = 0;
uint8 constant GATED = 1;
uint8 constant OPAQUE = 2;

/// @notice Three back doors to back up. 4 A paragraph.
///
/// @dev None of these three entry points in the production contract are available - by `test/ClearingPool.t.sol` It's a compilation. ABI Prove it.
///      (The 'We have not written' version of the article, which is not supported by the phrase "We have not written".
///      WARNING `exerciseIgnoringSettlement` We've rewritten the three steps of the right to move.
///      `Invariant3ExerciseAtomicity.t.sol` It's... `NonAtomicPool`:The only thing to break is**Internal function**Come on.
contract SabotagePool is ClearingPool {
    constructor(ICall call_, address distributor_, IAttestationRegistry attestations_, IVaultRegistry vaultRegistry_)
        ClearingPool(call_, distributor_, attestations_, vaultRegistry_)
    {}

    /// @dev CRITICAL **Every time poke All of them. `clearedAt`**  -  -  The attack face named in the specifications.
    ///      Let's look at it first, and write it more: the only thing that's bad is the "just on the side" character, the rest right.
    function pokeSloppily(address stockToken) external {
        this.pokeGating(stockToken);
        _gating[stockToken].clearedAt = uint64(block.timestamp);
    }

    /// @dev No door control, no pass. deadline,The way the settlement is blocked, the way it is still not settled.
    function settleStubbornly(uint256 seriesId) external {
        Series storage s = _series[seriesId];
        if (block.timestamp < uint256(s.expiry) + 30 days) {
            revert SettlementTooEarly(seriesId, s.expiry, block.timestamp);
        }
        s.settled = true;
        s.remainder = s.deposited - s.exercised;
    }

    /// @dev The settled series is a right to carry on - the collateral is taken twice: one to the right, one to go. `remainder`.
    function exerciseIgnoringSettlement(uint256 seriesId, uint256 amount, address beneficiary) external {
        Series storage s = _series[seriesId];
        uint256 memeAmount = (amount * s.strike) / 1e18;

        s.exercised += uint128(amount);
        call.burn(msg.sender, seriesId, amount);
        IERC20(s.memeToken).transferFrom(beneficiary, BURN_ADDRESS, memeAmount);
        IERC20(s.stockToken).transfer(beneficiary, amount);
    }
}

/// @notice Drives the settlement and door control observations. handler.
///
/// CRITICAL **Nothing in this contract. revert**(With three other non-variant files:
/// `fail_on_revert = false` I'm not sure if you're going to be able to do this.handler - Yes. `assertEq` Losing is one. revert,I'm gonna get it. fuzzer Swallow it.
/// So, all violations are made.**Recording counters**,By `invariant_*` Go and say zero.
///
/// # The verdict must be independent of being measured.
///
/// 4b and 4c The first step is to answer "Is there a door at the moment?"handler **You're not going to read the pool.**To answer it...
/// That's the same as making the subject's conclusions his own.**The three switches I just dialed.**
/// (`tokenPaused` / `poolBlocked` / `poolSanctioned` / `viewsBroken`),This is the first-hand source of the door-control state of the chain.
/// deadline Same: a separate calculation based on formula, only from `pool.gating()` Takes the original field.
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
    Call public immutable call;
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

    //  The mirror of the door switch: the first source of the verdict, not from the pool.
    bool public tokenPaused;
    bool public poolBlocked;
    /// @dev BSC The third new source of door control: the global sanctions list.
    bool public poolSanctioned;
    bool public viewsBroken;

    /// @notice No Variable 4(1):Once.**Success**The rights of the business fall on the number of settled series. 0.
    uint256 public postSettlementExerciseViolations;
    /// @notice No Variable 4(2):Preconditions established (recording current, real time, no door, past) deadline)But I can't settle the number of times. I have to keep it up. 0.
    uint256 public settlementBlockedViolations;
    /// @notice No Variable 4(2) The other half: the number of successful settlements at the door. It has to be constant. 0.
    uint256 public settlementWhileGatedViolations;
    /// @notice No Variable 4(3):Once.**Not on the side.**The observations are changed. `clearedAt` Number of times. Must be constant 0.
    uint256 public clearedAtDriftViolations;
    /// @notice 4(3) "Inverse: it is on the side, but without a stamp (or `clearedAt` Number of times back. Must be constant. 0.
    uint256 public missedStampViolations;
    /// @notice Quite a bit of a settlement. `remainder` Not equal to `deposited  exercised` Number of times. Must be constant 0.
    uint256 public remainderViolations;

    //  Coverage: Six claims are all "some of them are counted as 0,A man who didn't do anything. handler And they're all satisfied.
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
        Call call_,
        AttestationRegistry registry_,
        address distributor_,
        FactoryStub factory_,
        Sabotage sabotage_
    ) {
        pool = pool_;
        call = call_;
        registry = registry_;
        distributor = distributor_;
        sabotage = sabotage_;

        vault = new VaultStub(pool_);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();

        // I.D.'s registered with this one. MEME The vault -- the door that opened the series, it was this binding.M2-5 / #37).
        factory_.bind(address(meme), address(vault));

        // CRITICAL It's a long way away. It's a long way away.**Make sure the whole wheel is alive.**(The next round is half the series expired.
        //    The right to succeed will not be hit once; the nearest will be killed. `warp` Over the past, the settlement is really good.
        //    Far in line. 0,Because... fuzzer Yeah. 0 There's a strong preference.
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

    //  Actions

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

    /// @dev In this document, the main thing is**View**:It makes... `exercised != 0`,`remainder` The blogger says that the government is not a party to the law.
    ///      But it's also... 4(1) The only observation point, so the weight is in the hold.
    ///      ERC-1155 The balance check never leaves the "liquidated" box.
    function exercise(uint256 seriesSeed, uint256 actorSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address who = _actor(actorSeed);

        uint256 held = call.balanceOf(who, seriesId);
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
        // No Variable 4(1):`settled  exercise() revert`
        if (wasSettled) postSettlementExerciseViolations++;
    }

    /// @dev Observation.**No Variable 4(3) The entire observation point is here.**
    ///
    ///      Release: This observation is not allowed. `clearedAt`,"The state of the pool and the state of the chain."
    ///      This one.**Yeah.**Decision - Only `Door control. -> No door control` and `Clean. -> I can't read.` These three sides allow for stamping.
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

    /// @dev Settlement.**No Variable 4(2) The two of them are here.**
    function settleExpired(uint256 seriesSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        ClearingPool.Series memory before = pool.series(seriesId);

        uint8 storedBefore = _storedCategory();
        uint8 live = _liveCategory();
        uint64 clearedBefore = pool.gating(address(stock)).clearedAt;

        // CRITICAL Preconditions.**Before we observe.**..the record is calculated, but only the true state of the record and the chain.**Unanimously**It is only now that the settlement has to be successful.
        //    When recording old `settleExpired` It's a state of health, and self-health itself may have a new grace -
        //    It's not "the settlement is blocked," it's "the only thing that's been observed to be defunct,"48 The hour is counted from now on."
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
        // Door control, hit-and-run.**I have to.**I can't -- that's "automated delay."
        if (live == GATED) settlementWhileGatedViolations++;

        ClearingPool.Series memory afterwards = pool.series(seriesId);
        if (!afterwards.settled || afterwards.remainder != before.deposited - before.exercised) remainderViolations++;

        // The same stamp rule applies.
        _checkStampRule(storedBefore, live, clearedBefore);
    }

    /// @dev Draws three switches from the issuer.**I'm thinking, "Nothing happened."**:The door is too much to keep the deposit and the right to move.
    ///      The six claims are valid when "doing nothing." 0 Top (%1)fuzzer Yeah. 0 There's a strong preference.
    ///
    ///      WARNING The sub-segment is...**I measured it.**:`% 8`(Clean. 5/8)The government has been able to control the situation and the government has been unable to respond to the situation.
    ///      Replace with `% 6`(Clean. 3/6)After that, single round 512 Step Real... 17 The second door is closed.16 "It's too early,"
    ///      28 Subordinately, the right to move over the settled series,8 The side of the bar observed,1 The only thing that will expire in the universe is a series of successful settlements.
    ///      So this is the number structure. 1).Default File 256 Wheel  64 The total number of steps remains at hundreds.
    ///      CRITICAL **BSC It's got another one. `poolSanctioned`**(Decision-making 53):bStocks The compliance module is blacklisted by currency
    ///      And one more.**Global sanctions list**,Robinhood There's no match for that. It has to go in. handler  -  -
    ///      No Variable 4c "Clean." poke - Put it on. `clearedAt` "Pushing the pump, and**Every one of them can make
    ///      `hit` The real source is one side of each.**.The one missing, the side of that one never got cleaned.
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

    /// @dev The declaration door is...**Undo**: Undeclared address can be signed by itself at any time.
    function attest(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        vm.prank(who);
        address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, TERMS_0, ATTESTATION_0)));
    }

    /// @dev Time's on the side. The steps are right. `expiries` Transferred: round 64 I'm hoping for something. 8 Number of times warp,Mean 3.5 God,
    ///      So the one close. expiry(10 It's only fair to settle when it's steady across the cycle.
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    //  The judgement

    /// @dev There are three permissible sides to the stamp, none more, none less.
    function _checkStampRule(uint8 storedBefore, uint8 live, uint64 clearedBefore) private {
        uint64 clearedAfter = pool.gating(address(stock)).clearedAt;

        bool isEdge = (storedBefore == GATED && live != GATED) || (storedBefore == CLEAN && live == OPAQUE);
        if (isEdge) observedEdges++;

        if (!isEdge) {
            // CRITICAL No Variable 4(3):Don't move a byte without it.
            if (clearedAfter != clearedBefore) clearedAtDriftViolations++;
        } else if (clearedAfter != uint64(block.timestamp)) {
            // Inverse: No stamp on the side -- no window open at all.fail-open And then it's gone naked. fail-open
            missedStampViolations++;
        }

        if (clearedAfter < clearedBefore) missedStampViolations++;
    }

    /// @dev I'm a pool.**Remember**- The state.
    function _storedCategory() private view returns (uint8) {
        ClearingPool.Gating memory g = pool.gating(address(stock));
        if (g.active) return GATED;
        if (g.unreadable) return OPAQUE;
        return CLEAN;
    }

    /// @dev The chain.**Real**State - Read handler The switch you dialed was not a pool observation.
    function _liveCategory() private view returns (uint8) {
        if (viewsBroken) return OPAQUE;
        // CRITICAL Three sources are not necessary: missing `poolSanctioned`,The model says "clean" and "door control" on the sanctions box.
        if (tokenPaused || poolBlocked || poolSanctioned) return GATED;
        return CLEAN;
    }

    /// @dev deadline By Formula**Count it on your own.**:Only `pool.gating()` original field, unmodified `exerciseDeadline()`.
    ///      Making the results of the tested function your own premise is to give itself a point.
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

/// @notice **No Variable 4  -  -  (b) The right to be closed is not feasible; settlement cannot be prevented without door control.**
///
/// | Paragraph | The assertion. |
/// |---|---|
/// | (1) | `settled  exercise() revert` |
/// | (2) | Real time no door and `now >= max(expiry, clearedAt + 48h)`  `settleExpired()` It's bound to succeed; in turn, it will fail when the door is in control. |
/// | (3) | **`clearedAt` Just keep changing.**  -  -  Re-aligning observed stock tokens to clean `pokeGating`,I don't care how many times I've been in charge of the project.`clearedAt` It has to be the same. |
///
/// CRITICAL **No, I'm not. (3),(2) It's empty.** (2)  The premise itself  `clearedAt` Presentation;enabled `clearedAt` The assailant.
/// Just let the premise never work, and it will stop the settlement forever -- and the series that he should have had was won.**Free and indefinite extension**.
/// This is not a statement in the note. It's... `test_theSloppyPokeBackdoorIsInvisibleTo4b` **On-site presentation**:
/// Same back door. (3) It's red on the spot, and... (2) Not a word.
contract Invariant4SettlementAndGatingTest is Test {
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    SettlementHandler internal handler;

    function setUp() public {
        // The fork test runs on the real time stamp, local default is 1;Push to One48 The hour is long past the beginning of the day.
        vm.warp(1_800_000_000);

        (pool, call, distributor, registry, factory) = _deploySystem(false);
        handler =
            new SettlementHandler(pool, call, registry, address(distributor), factory, SettlementHandler.Sabotage.NONE);

        targetContract(address(handler));
    }

    function _deploySystem(bool sabotaged)
        internal
        returns (
            ClearingPool pool_,
            Call call_,
            MerkleDistributor distributor_,
            AttestationRegistry registry_,
            FactoryStub factory_
        )
    {
        registry_ = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call_ = new Call();
        distributor_ = new MerkleDistributor(makeAddr("publisher"));
        factory_ = new FactoryStub();
        pool_ = sabotaged
            ? ClearingPool(address(new SabotagePool(call_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(call_, address(distributor_), registry_, factory_.registry());
        call_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    function _sabotagedHandler(SettlementHandler.Sabotage mode) internal returns (SettlementHandler h) {
        (ClearingPool p, Call w, MerkleDistributor d, AttestationRegistry r, FactoryStub f) = _deploySystem(true);
        h = new SettlementHandler(p, w, r, address(d), f, mode);
    }

    //  No Variable 4

    function invariant_4a_settledSeriesCannotBeExercised() public view {
        assertEq(
            handler.postSettlementExerciseViolations(), 0, unicode"No Variable 4(1):The settled series is being taken."
        );
    }

    function invariant_4b_settlementCannotBeBlockedWithoutGating() public view {
        assertEq(
            handler.settlementBlockedViolations(),
            0,
            unicode"No Variable 4(2):No door control, past. deadline,The settlement failed."
        );
        assertEq(
            handler.settlementWhileGatedViolations(),
            0,
            unicode"No Variable 4(2):The doorman was successful in his attack."
        );
    }

    function invariant_4c_clearedAtOnlyMovesOnEdges() public view {
        assertEq(
            handler.clearedAtDriftViolations(),
            0,
            unicode"No Variable 4(3):One observation without the edge boosted. clearedAt"
        );
        assertEq(
            handler.missedStampViolations(),
            0,
            unicode"No Variable 4(3) Reverse: the stamp is not covered, or clearedAt Backwards"
        );
    }

    /// @notice Quite a bit of a settlement. `remainder` The entire amount of the claims in this series is the rest of the pool.
    /// @dev #12 And the right to cast it in the subsequent series -- one more point is a lot of empty hair.
    function invariant_4_remainderIsDepositedMinusExercised() public view {
        assertEq(handler.remainderViolations(), 0, unicode"remainder != deposited  exercised");
    }

    /// @notice Settlement and Roll Change Non Variable 1 Book shape (in %2)`settled`  Skipped `remainder` The blogger adds:
    ///         So use it.**Same one.** `CollateralCheck` Run again on this sequence.
    function invariant_1_collateralisationSurvivesSettlement() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(
            perSeries,
            0,
            unicode"No Variable 1(1):After settlement, the claims of an open series exceed its collateral."
        );
        assertEq(
            global, 0, unicode"No Variable 1(2):remainder I can't get the balance of the pool to cover all the claims."
        );
    }

    //  Coverage: Six claims are not in the air.

    // handler The seed syntax is a constant. If you write a nudity number, you move the slots, and these tests are set below.**As usual, green.**,
    // Just stop measuring what they claim to be measuring.
    uint256 internal constant GATING_CLEAR = 0;
    uint256 internal constant GATING_TOKEN_PAUSED = 3;
    uint256 internal constant GATING_POOL_BLOCKED = 4;
    /// @dev BSC The third new portal control source (decision-making) 53).Add it. `GATING_VIEWS_BROKEN` It's on. 6  -  -
    ///      CRITICAL These constants are... {GatingHandler-setIssuerGating} The one in the house. `seed % 7` The branch chart is...**Same watch**,
    ///      The change of location must be made to another place; the consequence of the change is that certainty in the document covers the use of static slotting.
    uint256 internal constant GATING_POOL_SANCTIONED = 5;
    uint256 internal constant GATING_VIEWS_BROKEN = 6;
    uint256 internal constant HOLDER_ATTESTED = 0;
    uint256 internal constant NEAR_EXPIRY = 1;

    /// @dev I'm sure I'm going to go through every path: -> Right to exercise authority -> Door control blocking the settlement. -> Undo -> Lend -> Settlement successful
    ///      -> The right to move on the settled series was denied. Six of the sites asserted that each of the sites had been hit by the crash.
    function test_handlerReachesSettlementAndEveryRejection() public {
        handler.openSeries(NEAR_EXPIRY, 1e18);
        handler.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler It's not gonna fit in.");

        handler.exercise(0, HOLDER_ATTESTED, 10 ether);
        assertEq(handler.successfulExercises(), 1, unicode"handler It's not working.");

        // Not yet due: settlement too early
        handler.settleExpired(0);
        assertEq(handler.settlementsRejectedTooEarly(), 1, unicode"\"The settlement was too early.\"");

        // The issuer is frozen and observed - the settlement is still structurally blocked after the expiry of the term
        handler.setIssuerGating(GATING_POOL_BLOCKED);
        handler.poke(0);
        vm.warp(handler.expiries(NEAR_EXPIRY) + 1 days);
        handler.settleExpired(0);
        assertEq(handler.settlementsRejectedWhileGated(), 1, unicode"The doorman stopped the settlement.");
        assertEq(handler.settlementWhileGatedViolations(), 0, unicode"And it didn't settle.");

        // Undo -> I've seen it. -> After the grace, the settlement is successful.
        handler.setIssuerGating(GATING_CLEAR);
        handler.poke(0);
        assertGt(handler.observedEdges(), 0, unicode"I didn't see anything on either side.");
        vm.warp(block.timestamp + 48 hours);
        handler.settleExpired(0);
        assertEq(handler.successfulSettlements(), 1, unicode"handler I can't settle it.");
        assertEq(handler.remainderViolations(), 0, "remainder");

        // Re-sale of the settled series  -  4(1) ..of the observation point
        handler.exercise(0, HOLDER_ATTESTED, 1 ether);
        assertEq(
            handler.exercisesAttemptedOnSettledSeries(),
            1,
            unicode"\"The right to move in the settled series was not hit.\""
        );
        assertEq(handler.postSettlementExerciseViolations(), 0, unicode"And it didn't work out.");

        // fail-open And that one goes through it: it doesn't make sense.  Seal, but only once.
        handler.openSeries(0, 1e18);
        handler.depositAndMint(1, HOLDER_ATTESTED, 50 ether);
        handler.setIssuerGating(GATING_VIEWS_BROKEN);
        uint256 edgesBefore = handler.observedEdges();
        handler.poke(0);
        assertEq(handler.observedEdges(), edgesBefore + 1, unicode"Clean. -> \"I can't read.\" It didn't hit the side.");
        handler.poke(1);
        handler.poke(2);
        assertEq(
            handler.clearedAtDriftViolations(),
            0,
            unicode"Repeated observations in the window have facilitated clearedAt"
        );

        handler.setIssuerGating(GATING_TOKEN_PAUSED);
        handler.poke(0);
        assertEq(handler.missedStampViolations(), 0, "missedStamp");
    }

    //  Counter-argument: Three detectors really ring.

    /// @dev CRITICAL **The test is, "No." (3),(2) The blogger says that the government is not in a position to do so.**
    ///
    ///      "Each time, poke All of them. `clearedAt`This back door, and then:
    ///      - **(3) Red on the spot.**  -  -  It's the one that caught it.
    ///      - **(2) Not a word.**  -  -  It's premised on... `clearedAt` expression, and `clearedAt` The blogger says that the government is not going to be able to do this.
    ///        "and it's over. deadlineAlways fake, empty.
    ///
    ///      Meanwhile, the attacker.**Consequences**It's real: it's not gonna work out once.
    function test_theSloppyPokeBackdoorIsInvisibleTo4b() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.SLOPPY_POKE);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);

        // Make a real door control. -> Clean." Jean. clearedAt There's a non-zero point.
        h.setIssuerGating(GATING_POOL_BLOCKED);
        h.poke(0);
        h.setIssuerGating(GATING_CLEAR);
        h.poke(0);

        vm.warp(h.expiries(NEAR_EXPIRY) + 30 days);

        // The attackers press 47 Round of hour push forward.
        for (uint256 round = 0; round < 4; round++) {
            vm.warp(block.timestamp + 47 hours);
            h.poke(round);
            h.settleExpired(0);
        }

        assertGt(h.clearedAtDriftViolations(), 0, unicode"No Variable 4(3) The probe didn't ring.");
        assertEq(
            h.settlementBlockedViolations(),
            0,
            unicode"CRITICAL No Variable 4(2) That's not true. That's not a sign.\"(2) \"It's empty.\""
        );
        assertEq(h.successfulSettlements(), 0, unicode"And the consequences of the attack are real: one can't settle.");
    }

    /// @dev (2) Detector: No door, no pass. deadline,I can't settle it.
    function test_theDetectorDetects_aSettlementThatShouldHaveSucceeded() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.STUBBORN_SETTLE);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        h.poke(0); // Recording: clean, consistent with real time

        vm.warp(h.expiries(NEAR_EXPIRY) + 1 days);
        h.settleExpired(0);

        assertGt(h.settlementBlockedViolations(), 0, unicode"No Variable 4(2) The probe didn't ring.");
        assertEq(h.successfulSettlements(), 0, unicode"Prefix: The one did not go through.");
    }

    /// @dev (1) The user's collateral is thus taken twice -
    ///      One time to the right-handler, one time to stay. `remainder` Wait inside. #12 A certificate of authority to form a subsequent series.
    function test_theDetectorDetects_anExerciseAfterSettlement() public {
        SettlementHandler h = _sabotagedHandler(SettlementHandler.Sabotage.IGNORE_SETTLED);

        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);
        h.poke(0);

        vm.warp(h.expiries(NEAR_EXPIRY) + 1 days);
        h.settleExpired(0);
        assertEq(h.successfulSettlements(), 1, unicode"Precondition: a settlement is made once");

        h.exercise(0, HOLDER_ATTESTED, 10 ether);

        assertEq(h.exercisesAttemptedOnSettledSeries(), 1, unicode"Prefix: Indeed on the settled series");
        assertGt(h.postSettlementExerciseViolations(), 0, unicode"No Variable 4(1) The probe didn't ring.");

        // The consequences are clear: 10 ether It's already been calculated. `remainder` Yes, but it was taken again.
        SabotagePool bad = SabotagePool(address(h.pool()));
        assertEq(bad.series(h.openedSeries(0)).remainder, 100 ether, unicode"remainder It says, \"I'm not a man.\" 100");
        assertEq(h.stock().balanceOf(address(bad)), 90 ether, unicode"And there's only one in the pool. 90");
    }

    /// @dev Three probes, half:**Real**The pool must be completely silent.
    ///      Otherwise, all the three above prove is "they always ring."
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
