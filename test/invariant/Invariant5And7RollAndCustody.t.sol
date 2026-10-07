// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @notice Three back doors to counter-argument.**Three bad ones aren't the same thing.**,So one detector catches another,
///         It's not like I'm a little bit old for this.
///
/// | Back door. | What is it? | Who should ring? |
/// |---|---|---|
/// | `withdraw` | Textbook-style administrator exit | No Variable 5 No variables, no variables 1(2) |
/// | `rollThroughTheVault` | **The original version of the abolished version.**  -  -  The rest of the money goes back through the vault. | No Variable 5,No Variable 7 Balance, no variables 1(2) |
/// | `rollWithoutZeroingTheRemainder` | The memory is forgotten - the same balance is counted twice | No Variable 7 constant, non-variant 1(2)(Hosting count**Silence**) |
///
/// CRITICAL The second back door is worth saying alone: it's not made up, it's made up. `claimExpired -> Treasury -> Re-invent.` The smallest shape of that path.
/// (`docs/design.md` 10-25 It is the same thing that was abolished.
/// It's just one.**Almost exactly the same.**This would indeed give the trust to be given, while the four figures on the books were the same.
///
/// @dev None of these three entry points in the production contract are available - by `test/ClearingPool.t.sol` It's a compilation. ABI Prove it.
///      (The 'We have not written' version of the article, which is not supported by the phrase "We have not written".
///      The last two were meant to be.**Without any pre-check**:The one thing that's going to break is "where the money went" and "the cleanup" is not the six doors.
contract LeakyPool is ClearingPool {
    constructor(ICall call_, address distributor_, IAttestationRegistry attestations_, IVaultRegistry vaultRegistry_)
        ClearingPool(call_, distributor_, attestations_, vaultRegistry_)
    {}

    /// @dev Back door. (1):Turn the collateral out. No variables. 5 The forbidden thing, writing in code is so short.
    function withdraw(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    /// @dev Back door. (2):Accounts**All of them.**,But the collateral went to the vault.
    ///      Four digits (%)remainder Reduction / deposited Increase / minted Increase / The new cast is not bad.
    ///      The only difference between "relocation" and "transfer" is just this.
    function rollThroughTheVault(uint256 seriesId, uint256 nextSeriesId, address vault_) external {
        Series storage s = _series[seriesId];
        Series storage n = _series[nextSeriesId];

        uint128 amount = s.remainder;
        s.remainder = 0;
        n.deposited += amount;
        n.minted += amount;

        call.mint(distributor, nextSeriesId, amount);
        IERC20(s.stockToken).transfer(vault_, amount); // <- The trust has been given in this line.
    }

    /// @dev Back door. (3):Follow-up series, front row. `remainder` Forget it - the same mortgage was claimed in both places.
    ///      A collateral. wei It's still intact, so the trustee counts it.**It's blind.**;Only constant and non-variable. 1(2) I can see that.
    function rollWithoutZeroingTheRemainder(uint256 seriesId, uint256 nextSeriesId) external {
        Series storage s = _series[seriesId];
        Series storage n = _series[nextSeriesId];

        uint128 amount = s.remainder;
        n.deposited += amount;
        n.minted += amount;

        call.mint(distributor, nextSeriesId, amount);
    }
}

/// @notice Driver**All six portals.**It's... handler  -  -  No Variable 5 It makes sense only on a full external function.
///
/// CRITICAL **Nothing in this contract. revert**(With the other four non-variant files: the non-variant runs in
/// `fail_on_revert = false` I'm not sure if you're going to be able to do this.handler - Yes. `assertEq` Losing is one. revert,I'm gonna get it. fuzzer Swallow it.
/// So, all violations are made.**Recording counters**,By `invariant_*` Go and say zero.
///
/// # Trust: Press "it" for every move.**Allow**How to move the balance."
///
/// | Category | Who? | Allowed Balance Changes |
/// |---|---|---|
/// | `DEPOSIT` | `depositAndMint` | Only no loss |
/// | `EXERCISE` | `exercise` | Success  Just to reduce the weight of the line; failure  It's not moving. |
/// | `NEUTRAL` | `openSeries` / `pokeGating` / `settleExpired` / **`rollExpired`** / `drain` | **One. wei Don't move!** |
///
/// This watch is not variable. 5  The collateral only has one path out of the pool and it rolls **No, I'm not.**That path.
/// Structure section (no seventh entry) by `test/ClearingPool.t.sol` Read it. ABI The two paragraphs together are said to be the "no-man's exit".
contract RollHandler is CommonBase, StdUtils {
    enum Sabotage {
        NONE,
        WITHDRAW,
        ROLL_THROUGH_VAULT,
        ROLL_WITHOUT_ZEROING
    }

    /// @dev The level of authority for the action over the balance is shown in the contract note.
    enum Kind {
        NEUTRAL,
        DEPOSIT,
        EXERCISE
    }

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");
    bytes32 internal constant ERC20_TRANSFER = keccak256("Transfer(address,address,uint256)");

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
    uint64[3] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice No Variable 5:The collateral is in the...**I shouldn't.**Moves in the moving place, or the weight of the movement is not right. Must be constant. 0.
    uint256 public custodyViolations;
    /// @notice No Variable 7(Constant: A successful roll, four numbers not all equal. Must be constant. 0.
    uint256 public rollConservationViolations;
    /// @notice No Variable 7(Balance section: A successful roll-on changes the number of times the pool balance is changed. 0.
    uint256 public rollBalanceViolations;
    /// @notice A successful roll-off sends out stocks. ERC-20 `Transfer` Number of times. Must be constant 0.
    uint256 public rollTransferViolations;
    /// @notice Once.**Rejected**The rolling changes the amount of surplus or balance. 0.
    uint256 public rollAtomicityViolations;

    //  Coverage: Four claims are all "some of the counts are 0,A man who didn't do anything. handler And they're all satisfied.
    uint256 public successfulDeposits;
    uint256 public successfulExercises;
    uint256 public successfulSettlements;
    uint256 public successfulRolls;
    uint256 public rejectedRolls;
    /// @notice Mortgages.**Legal**Number of times that you leave the pool (right to succeed). 0 The ruling of the court of trustees has never been truly tested.
    uint256 public collateralOutflows;
    /// @notice `withdraw(address,address,uint256)` The number of times you've been denied a pool -- the number of times you've been called on a real pool.
    uint256 public drainsRejected;
    /// @notice The back door really took the money. The real pool has to be constant. 0.
    uint256 public drainsSucceeded;
    /// @notice Number of steps to "with a license to move" -- no variables 5 Preconditions for the`minted > exercised`).
    uint256 public stepsWithOutstandingCalls;

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

        // CRITICAL Three. expiry The division of labour is...**Can you get hit by a rolling stock?**Everything: the far one. 0,fuzzer Prejudice 0)
        //    The whole wheel is alive, and there's always a legal follow-up; the closest one. `warp` Just cross it, and then...
        //    Deposit -> Settlement -> The chain is really over in the round. The middle one is "the rest of you is out of date."
        //    This path of rejection also has the chance to hit.
        //
        //    WARNING The value is**I'm not trying to measure it.**.First edition to pick up 400 / 10 / 60 Days: round 64 Step down.
        //    I can't even hit a successful settlement.8 Number of times warp Mean 3.5 Oh, my God. I can't get through this. 10 The number of days is too small.
        //    So four claims were green, but they were never rolled. 400 / 2 / 12 After the day, it's a real thing.
        //    (`--fuzz-seed 1...8`,Single round: deposited 8/8,Settlement 7/8,**Successful Rolling 3/8**;
        //    CI Tranche (Class)depth 128)Single Wheel **8/8**.Default File 256 The total number of rounds is about 100.
        //
        //    The upper limit of successful roll in a single wheel is 1 Number of  -  `roll` It's... (from, to) Both sub-scripts are selected on the same probability.
        //    Circulation (Class C lose)A -> B -> C)So it's not. fuzz  The luck, by
        //    `test/ClearingPoolRoll.t.sol::test_roll_survivesAChainOfRolls` (c) The certainty coverage.
        expiries =
            [uint64(block.timestamp + 400 days), uint64(block.timestamp + 2 days), uint64(block.timestamp + 12 days)];
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

        // distributor The project is a project of the National Council of Women, which is a beneficiary: all the cards created by the roll-on are on its hands.
        // And... `exercise` Allows it to act in its own capacity on behalf of the beneficiaries (#13 It's... `claimAndExercise` shape.
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

    //  Actions

    function openSeries(uint256 expirySeed, uint128 strike) external {
        strike = uint128(bound(strike, 1e15, 1e21));

        uint256 balanceBefore = _poolBalance();
        (bool ok, bytes memory ret) = address(vault)
            .call(
                abi.encodeCall(
                    VaultStub.openSeries,
                    (address(meme), address(stock), expiries[expirySeed % expiries.length], strike)
                )
            );
        _checkCustody(Kind.NEUTRAL, balanceBefore, false, 0);
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

        uint256 balanceBefore = _poolBalance();
        (bool ok,) =
            address(vault).call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, _actor(receiverSeed), amount)));
        _checkCustody(Kind.DEPOSIT, balanceBefore, ok, 0);

        if (ok) successfulDeposits++;
    }

    /// @dev The right to own property is collateral.**One**The legal exit path - the entire test of the trustee's verdict has fallen on this move.
    function exercise(uint256 seriesSeed, uint256 actorSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address who = _actor(actorSeed);

        uint256 held = call.balanceOf(who, seriesId);
        amount = held == 0 ? bound(amount, 0, 1e24) : bound(amount, 1, held);

        uint256 balanceBefore = _poolBalance();
        vm.prank(who);
        (bool ok,) = address(pool).call(abi.encodeCall(ClearingPool.exercise, (seriesId, amount, who)));
        _checkCustody(Kind.EXERCISE, balanceBefore, ok, amount);

        if (ok) successfulExercises++;
    }

    function poke() external {
        uint256 balanceBefore = _poolBalance();
        address(pool).call(abi.encodeCall(ClearingPool.pokeGating, (address(stock))));
        _checkCustody(Kind.NEUTRAL, balanceBefore, false, 0);
    }

    function settleExpired(uint256 seriesSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];

        uint256 balanceBefore = _poolBalance();
        (bool ok,) = address(pool).call(abi.encodeCall(ClearingPool.settleExpired, (seriesId)));
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        if (ok) successfulSettlements++;
    }

    /// @dev **No Variable 7 The entire observation point is here.**
    ///
    ///      The four numbers must move together, as many as they do: the front line. `remainder` It's...**Volume reduction**,Follow `deposited` and `minted` It's...
    ///      **Incremental**,For `distributor` . The pool balance must be one wei Don't move.
    function roll(uint256 fromSeed, uint256 toSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[fromSeed % openedSeries.length];
        uint256 nextSeriesId = openedSeries[toSeed % openedSeries.length];

        uint256 balanceBefore = _poolBalance();
        uint128 remainderBefore = pool.series(seriesId).remainder;
        ClearingPool.Series memory nextBefore = pool.series(nextSeriesId);
        uint256 callsBefore = call.balanceOf(distributor, nextSeriesId);

        // The balance is equally uncapturing; the stock contract itself is not recorded. `Transfer`,
        // Let every successful roller be satisfied at the same timeBalance unchangedandProcess not transferred.
        vm.recordLogs();
        (bool ok,) = address(pool).call(_rollCalldata(seriesId, nextSeriesId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        uint128 remainderAfter = pool.series(seriesId).remainder;

        if (!ok) {
            rejectedRolls++;
            // The rejected roll must leave nothing behind.EVM It's a default, but when it happens, it's called down and forgotten.
            // Checking the return value, this is the first red spot.
            if (remainderAfter != remainderBefore || _poolBalance() != balanceBefore) rollAtomicityViolations++;
            return;
        }

        successfulRolls++;
        if (_sawStockTransfer(logs)) rollTransferViolations++;

        if (remainderAfter > remainderBefore) {
            rollConservationViolations++;
            return; // The balance is long, and the increase below is meaningless.
        }
        uint128 moved = remainderBefore - remainderAfter;

        ClearingPool.Series memory nextAfter = pool.series(nextSeriesId);
        uint256 callsAfter = call.balanceOf(distributor, nextSeriesId);

        // CRITICAL `moved == 0` It's also against the law: "success" is a rolling, or empty, remix, and "success" is a "show."
        //    Or the rest of it is written elsewhere -- neither should happen.
        if (
            moved == 0 || nextAfter.deposited - nextBefore.deposited != moved
                || nextAfter.minted - nextBefore.minted != moved || callsAfter - callsBefore != moved
        ) {
            rollConservationViolations++;
        }

        if (_poolBalance() != balanceBefore) rollBalanceViolations++;
    }

    /// @dev CRITICAL **To the pool. `withdraw(address,address,uint256)`.**
    ///
    ///      The real pool doesn't exist, it doesn't exist. fallback,So it's always... revert  -  -
    ///      This action is therefore not variable. 5 Yes. fuzz - Yes.**Live**Form: No, "We didn't write it." withdraw,
    ///      It's "no call ever made in a round." The one with the back door will work.
    ///      So the hosting count was on the spot.
    function drain(uint256 amount) external {
        amount = bound(amount, 1, 1e24);

        uint256 balanceBefore = _poolBalance();
        (bool ok,) = address(pool)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(stock), address(vault), amount));
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        if (ok) drainsSucceeded++;
        else drainsRejected++;
    }

    /// @dev Time's on the side. The steps are right. `expiries` Transferred: round 64 I'm hoping for something. 8 Number of times warp,Mean 3.5 God,
    ///      So the one close. expiry(10 It's a good way to get through the cycle, and it's a good way to get settled and roll.
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    //  The judgement

    /// @dev Trusted decision - no variable 5 and the dynamic section.
    ///
    ///      CRITICAL `NEUTRAL` The first request is...**Strictly equal**,Not "not less."
    ///      As long as it turns "go out and come back," the balance is not different, but this one is clear.
    ///       -  -  If the verdict is equal.
    function _checkCustody(Kind kind, uint256 balanceBefore, bool ok, uint256 amount) private {
        uint256 balanceAfter = _poolBalance();

        if (kind == Kind.NEUTRAL) {
            if (balanceAfter != balanceBefore) custodyViolations++;
        } else if (kind == Kind.DEPOSIT) {
            if (balanceAfter < balanceBefore) custodyViolations++;
        } else if (!ok) {
            if (balanceAfter != balanceBefore) custodyViolations++;
        } else if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) {
            custodyViolations++;
        } else if (amount != 0) {
            collateralOutflows++;
        }

        if (_hasOutstandingCalls()) stepsWithOutstandingCalls++;
    }

    /// @dev No Variable 5 "Supreme: There is an open series, it is `minted > exercised`.
    ///      This was written to prove that the claim was not being turned over an empty pool.
    function _hasOutstandingCalls() private view returns (bool) {
        for (uint256 i = 0; i < openedSeries.length; i++) {
            ClearingPool.Series memory s = pool.series(openedSeries[i]);
            if (!s.settled && s.minted > s.exercised) return true;
        }
        return false;
    }

    function _rollCalldata(uint256 seriesId, uint256 nextSeriesId) private view returns (bytes memory) {
        if (sabotage == Sabotage.ROLL_THROUGH_VAULT) {
            return abi.encodeCall(LeakyPool.rollThroughTheVault, (seriesId, nextSeriesId, address(vault)));
        }
        if (sabotage == Sabotage.ROLL_WITHOUT_ZEROING) {
            return abi.encodeCall(LeakyPool.rollWithoutZeroingTheRemainder, (seriesId, nextSeriesId));
        }
        return abi.encodeCall(ClearingPool.rollExpired, (seriesId, nextSeriesId));
    }

    /// @dev CRITICAL The judgement**I'm not going to let you down.**:It's a negative assertion. "No one's right." One more field.
    ///      There's just one more shape that can slip past. So it's just like the sender. topic0,No, it's not like that. `topics.length` and `data.length`
    ///       -  -  A hand. `Transfer` The tokens that are coded irregularly should still be caught, not sentenced to imprisonment.
    ///      and `test/ClearingPoolRoll.t.sol` It's... `_sawTransferFrom` The same sentence.
    ///      I'll see you in the right direction. `test_theTransferDetectorFiresOnARealStockTransfer`.
    function _sawStockTransfer(Vm.Log[] memory logs) private view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(stock)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER) return true;
        }
        return false;
    }

    function _poolBalance() private view returns (uint256) {
        return stock.balanceOf(address(pool));
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 i = seed % 4;
        return i == 3 ? distributor : actors[i];
    }

    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **No Variable 5(No Manager Export) and no variable 7(Rolling and standing.**
///
/// | # | No Variable | The assertion. |
/// |---|---|---|
/// | 5 | No Manager exits | No function can be used `minted > exercised` It's time to take collateral.**Transfer the contract.**;`rollExpired` It's the re-entry of the pool. It doesn't mean it's gone. |
/// | 7 | Rolling and standing | `rollExpired` The balance within the pool remains unchanged;`remainder` Volume reduction == Follow `deposited` / `minted` Incremental == New Caster |
///
/// CRITICAL **No Variable 5 There are two paragraphs, one of which cannot be left.**
///
/// - **Structure section**:Externally writeable functions are exactly six -- reading and compiling products ABI,See `test/ClearingPool.t.sol`.
///   It proves "No Seventh Entry," and that's a line about**Cannot initialise Evolution's mail component.**That's the only way to prove it.
/// - **Dynamic section**(This document: Press six portals fuzz Any sequence out of the room, collateral.**Only `exercise` Lee.
///   I've been out of the pool and every time it happens, it's the same as the weight of the line.**.It proves another thing -- none of the six of them.
///   Sneaking out the money on some path.
///
/// They can't catch each other:ABI Enumeration pair`settleExpired` I've got a line in it. transferBlind.
/// The dynamic track is "plus one that's never been called." `withdraw`It's blind.issue #12 The reason why you don't have a variable 5 Put it on the promissory note.
/// It's because the function set is here that fills it up -- it's pointless to say "no exit" in a contract that still lacks function.
contract Invariant5And7RollAndCustodyTest is Test {
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    RollHandler internal handler;

    // handler The seed syntax is a constant. If you write a nudity number, you move the slots, and these tests are set below.**As usual, green.**,
    // Just stop measuring what they claim to be measuring.
    uint256 internal constant FAR_EXPIRY = 0;
    uint256 internal constant NEAR_EXPIRY = 1;
    uint256 internal constant MID_EXPIRY = 2;
    uint256 internal constant SUCCESSOR = 0; // openedSeries[0]  -  -  The one that started.
    uint256 internal constant PREDECESSOR = 1; // openedSeries[1]  -  -  The one behind.
    uint256 internal constant HOLDER_ATTESTED = 0;

    function setUp() public {
        // The fork test runs on the real time stamp, local default is 1;Push to One48 The hour is long past the beginning of the day.
        vm.warp(1_800_000_000);

        (pool, call, distributor, registry, factory) = _deploySystem(false);
        handler = new RollHandler(pool, call, registry, address(distributor), factory, RollHandler.Sabotage.NONE);

        targetContract(address(handler));
    }

    function _deploySystem(bool leaky)
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
        pool_ = leaky
            ? ClearingPool(address(new LeakyPool(call_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(call_, address(distributor_), registry_, factory_.registry());
        call_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    function _sabotagedHandler(RollHandler.Sabotage mode) internal returns (RollHandler h) {
        (ClearingPool p, Call w, MerkleDistributor d, AttestationRegistry r, FactoryStub f) = _deploySystem(true);
        h = new RollHandler(p, w, r, address(d), f, mode);
    }

    /// @dev Cleared in the front + "The next live follow-up" is a set of four counter-argument pieces.
    function _settledPredecessorAndLiveSuccessor(RollHandler h) internal {
        h.openSeries(FAR_EXPIRY, 1e18);
        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);
        h.exercise(PREDECESSOR, HOLDER_ATTESTED, 30 ether);

        vm.warp(h.expiries(NEAR_EXPIRY) + 1);
        h.settleExpired(PREDECESSOR);
    }

    //  No Variable 5

    /// @notice The collateral is only available. `exercise` It's been out of the pool and each time it happens to be the same as the weight of the line.
    function invariant_5_collateralOnlyEverLeavesThroughExercise() public view {
        assertEq(
            handler.custodyViolations(),
            0,
            unicode"No Variable 5:The collateral moved in the wrong place or the wrong amount of movement."
        );
    }

    /// @notice `withdraw(address,address,uint256)` It didn't work out once in the whole round.
    /// @dev This is the live form of "no manager exits" -- and read it. ABI The structure is split in half.
    function invariant_5_thereIsNoWithdrawEntrypoint() public view {
        assertEq(
            handler.drainsSucceeded(), 0, unicode"No Variable 5:I can't believe one of the pools is working. withdraw"
        );
    }

    /// @notice Every successful roller should not have a stock contract issued. `Transfer`;The final balance is not sufficient to support this.
    function invariant_5_rollNeverEmitsAStockTransfer() public view {
        assertEq(
            handler.rollTransferViolations(), 0, unicode"No Variable 5:Stock currency transfers in the roll-on deal."
        );
    }

    /// @notice Full pool reimbursement coverage:`_Unsolved(minted  exercised) +  remainder <= balanceOf(pool)`.
    /// @dev It's on the... `Invariant1And2MintingPath.t.sol` - Yes.**Same one.** `CollateralCheck`  -  -
    ///      Each of these places is written over and over again, and one of them is allowed to verify the other. The whole reason for rolling is the one that exists.
    function invariant_1_collateralisationSurvivesTheRoll() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"No Variable 1(1):The claim for an unsolved series exceeds its collateral.");
        assertEq(global, 0, unicode"No Variable 1(2):I can't afford to pay all the debts after rolling.");
    }

    //  No Variable 7

    function invariant_7_rollConservesTheLedgerAndTheBalance() public view {
        assertEq(
            handler.rollConservationViolations(),
            0,
            unicode"No Variable 7:remainder Volume reduction != Follow deposited / minted Incremental != New Caster"
        );
        assertEq(handler.rollBalanceViolations(), 0, unicode"No Variable 7:Rolling memory modified pool balance");
    }

    function invariant_7_aRejectedRollLeavesNothingBehind() public view {
        assertEq(handler.rollAtomicityViolations(), 0, unicode"A rejected roll left a mark.");
    }

    //  Coverage: Four claims are not in the air.

    /// @dev I'm sure I'm going to take the whole chain over with certainty: -> Right to exercise (collaterals)**Legal**Out of the pool once)-> Settlement -> Crozen
    ///      -> Second roll is denied. -> `withdraw` They were rejected. Four of the observation points were thus actually hit.
    function test_handlerReachesTheRollAndEveryRejection() public {
        handler.openSeries(FAR_EXPIRY, 1e18);
        handler.openSeries(NEAR_EXPIRY, 1e18);
        assertEq(handler.seriesCount(), 2, unicode"handler I can't get two series.");

        handler.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler It's not gonna fit in.");
        assertGt(handler.stepsWithOutstandingCalls(), 0, unicode"No Variable 5 The premise never existed.");

        handler.exercise(PREDECESSOR, HOLDER_ATTESTED, 30 ether);
        assertEq(handler.successfulExercises(), 1, unicode"handler It's not working.");
        assertEq(handler.collateralOutflows(), 1, unicode"The collateral was legally taken out of the pool.");

        // Not yet due: Rolling in "unsolved"
        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.rejectedRolls(), 1, unicode"\"The rejection was not hit by a prior settlement.\"");

        vm.warp(handler.expiries(NEAR_EXPIRY) + 1);
        handler.settleExpired(PREDECESSOR);
        assertEq(handler.successfulSettlements(), 1, unicode"handler I can't settle it.");

        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.successfulRolls(), 1, unicode"handler It's not gonna make it.");
        assertEq(handler.rollConservationViolations(), 0, unicode"And it's constant.");
        assertEq(handler.rollBalanceViolations(), 0, unicode"The balance's still intact.");
        assertEq(handler.rollTransferViolations(), 0, unicode"Rolling trades don't have stocks. Transfer");

        // Second rolling:`remainder` It's zero.
        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(
            handler.rejectedRolls(),
            2,
            unicode"\"No, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no, no."
        );
        assertEq(handler.rollAtomicityViolations(), 0, unicode"The one that was rejected left nothing.");

        // Rolling: previous sequence settled, subsequent outstanding, same id It's not possible to establish both.
        handler.roll(SUCCESSOR, SUCCESSOR);
        assertEq(handler.rejectedRolls(), 3, unicode"\"Scram!\" \"The refusal was not hit.");

        // Manager exit: There's no such option on the real pool.
        handler.drain(1 ether);
        assertEq(handler.drainsRejected(), 1, unicode"withdraw That one didn't get hit.");
        assertEq(handler.drainsSucceeded(), 0, unicode"CRITICAL On the real pool. withdraw I can't believe it worked.");

        handler.poke();
        assertEq(handler.custodyViolations(), 0, unicode"All the above-mentioned custody charges are zero.");
    }

    /// @dev Medium term expiry - The one in the first row:**And then he was out of date.**,Rolling must be rejected.
    ///      Without this,`SuccessorExpired` The door is... fuzz Maybe not once.
    function test_handlerReachesTheExpiredSuccessorRejection() public {
        handler.openSeries(MID_EXPIRY, 1e18);
        handler.openSeries(NEAR_EXPIRY, 1e18);
        handler.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);

        vm.warp(handler.expiries(MID_EXPIRY) + 1);
        handler.settleExpired(PREDECESSOR);
        assertEq(handler.successfulSettlements(), 1, unicode"Precondition: the front line is settled.");

        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.successfulRolls(), 0, unicode"The expired successors should not be able to accept the roll.");
        assertEq(handler.rejectedRolls(), 1, unicode"\"The refusal was not hit.\"");
        assertEq(handler.rollAtomicityViolations(), 0, unicode"And it left nothing behind.");
    }

    //  Counter-argument: Three detectors really ring.

    /// @dev No Variable 5  The detection of the use of school textbooks by managers.
    ///      CRITICAL The assertion is, "This is the moment." `minted > exercised` -  -  No Variable 5 The blogger says that the government is not going to be able to do this.
    ///      Without it, this counter-proof proves that "a pool was empty."
    function test_theDetectorDetects_anAdminWithdraw() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.WITHDRAW);
        h.openSeries(FAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);

        ClearingPool.Series memory s = h.pool().series(h.openedSeries(0));
        assertGt(
            s.minted,
            s.exercised,
            unicode"Pre-condition: There is a valid certificate of right to travel outside the premises."
        );

        h.drain(40 ether);

        assertEq(h.drainsSucceeded(), 1, unicode"Prefix: The back door did take the money.");
        assertEq(h.stock().balanceOf(address(h.pool())), 60 ether, unicode"There's really no pool. 40");
        assertGt(h.custodyViolations(), 0, unicode"No Variable 5 The hosting probe didn't ring.");

        (, uint256 global) = CollateralCheck.violations(h.pool(), h.stockAddresses(), h.seriesIds());
        assertGt(global, 0, unicode"No Variable 1(2) It should be followed.");
    }

    /// @dev CRITICAL **This is a counter-proof decision. 25 In itself.**
    ///
    ///      The back door was abolished. `claimExpired -> Treasury` Minimum shape of path: 4 digits in the account**One of them.**,
    ///      The only thing that's left is the vault. So:
    ///      - No Variable 7 It's...**The constant is silent.**  -  -  It checks the books and the accounts are correct;
    ///      - No Variable 7 It's...**Balances are on the spot.**,No Variable 5 The number of hosts is also ringing.
    ///
    ///      Rolling does not constitute a transfer." The whole reason why the phrase needs to be validated rather than stated is in this test.
    function test_theDetectorDetects_aRollThatRoutesThroughTheVault() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.ROLL_THROUGH_VAULT);
        _settledPredecessorAndLiveSuccessor(h);

        uint256 poolBefore = h.stock().balanceOf(address(h.pool()));
        h.roll(PREDECESSOR, SUCCESSOR);

        assertEq(h.successfulRolls(), 1, unicode"Precondition: The back door did roll once.");
        assertEq(
            h.stock().balanceOf(address(h.pool())), poolBefore - 70 ether, unicode"The collateral is out of the pool."
        );
        assertGt(h.rollBalanceViolations(), 0, unicode"No Variable 7 The balance didn't ring.");
        assertGt(h.rollTransferViolations(), 0, unicode"Rolling stocks Transfer The probe didn't ring.");
        assertGt(h.custodyViolations(), 0, unicode"No Variable 5 The hosting probe didn't ring.");
        assertEq(
            h.rollConservationViolations(),
            0,
            unicode"CRITICAL The money is ringing? That counter-argument doesn't show \"Is the balance equal to the money?\""
        );
    }

    /// @dev No Variable 7 Constant-fixed detectors: Forget zero -- the same residual is claimed in front and back.
    ///      A collateral. wei It's not moving, so...**The trustee counts it as blind.**,The counter is therefore not redundant.
    function test_theDetectorDetects_aRollThatForgetsToZeroTheRemainder() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.ROLL_WITHOUT_ZEROING);
        _settledPredecessorAndLiveSuccessor(h);

        uint256 poolBefore = h.stock().balanceOf(address(h.pool()));
        h.roll(PREDECESSOR, SUCCESSOR);

        assertEq(h.successfulRolls(), 1, unicode"Precondition: The back door did roll once.");
        assertEq(h.stock().balanceOf(address(h.pool())), poolBefore, unicode"Precondition: Money one. wei Nothing.");
        assertGt(h.rollConservationViolations(), 0, unicode"No Variable 7 The constant has not been heard.");
        assertEq(h.custodyViolations(), 0, unicode"The trust count is blind to this evil.");
        assertEq(h.rollBalanceViolations(), 0, unicode"The balance is also blind.");

        // The consequences are clear:70 Two at once, and there's only one in the pool. 70.
        (, uint256 global) = CollateralCheck.violations(h.pool(), h.stockAddresses(), h.seriesIds());
        assertGt(global, 0, unicode"No Variable 1(2) The one who caught the double-counting.");
    }

    /// @dev Three probes, half:**Real**The pool must be completely silent.
    ///      Otherwise, all the three above prove is "they always ring."
    function test_theDetectorsAreSilentOnTheRealPool() public {
        test_handlerReachesTheRollAndEveryRejection();

        assertEq(handler.custodyViolations(), 0, "5");
        assertEq(handler.drainsSucceeded(), 0, "5'");
        assertEq(handler.rollConservationViolations(), 0, "7");
        assertEq(handler.rollBalanceViolations(), 0, "7'");
        assertEq(handler.rollTransferViolations(), 0, "5''");
        assertEq(handler.rollAtomicityViolations(), 0, "7''");

        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, "1a");
        assertEq(global, 0, "1b");
    }
}
