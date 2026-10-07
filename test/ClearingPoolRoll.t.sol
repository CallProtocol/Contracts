// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {IssuerComplianceStub, IssuerGatedStockToken, IssuerPauseManagerStub} from "./helpers/IssuerGating.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";
import {CollateralCheck} from "./invariant/Invariant1And2MintingPath.t.sol";

/// @notice **M1-7 Pool Circulation**(issue #12).
///
/// There is only one thing that is difficult to get on this ticket, and it is not in those lines:**The phrase "Crozen" is not a transfer."
/// Not a word.** So each successful path in this document asserts three sides of the same thing:
///
/// | Noodles. | The assertion. |
/// |---|---|
/// | Balance | The balance of the stock coin in the pool is before and after the roll.**One. wei Don't move.** |
/// | Events | In this deal,**No, I'm not.**The stock is in tokens. `Transfer`  -  -  It's right to not find it. |
/// | Accounts | `remainder` Reductions in the == Follow `deposited` / `minted` Incremental == New casting weight (no variable) 7) |
///
/// The second side is singled out because the first two were wrong.**It happened.**There's only one shape:
/// One day someone added a "go out and come back." The balance is not visible, the events are visible.
///
/// CRITICAL The other main line is...**No Variable 1 Cross-Crossing Forms**:Pre-sequenced series after scrolling `deposited` And the pen is already in there.
/// Numbers of re-assigned, so they're line by line. 1(1) Only**Unsolved**It's a meaningful range. The cross-rolling must be global. 1(2).
/// issue #5 Name call:**Don't put it in the car. 1(1) It's a way to get through.**.The difference between these two things is...
/// `test_roll_theSettledPredecessorIsSoundOnlyBecause1aExcludesIt` On-site demonstration.
///
/// No Variable 5 / 7 It's... fuzz Form `test/invariant/Invariant5And7RollAndCustody.t.sol`;
/// Real GME The review in question `test/fork/RobinhoodRoll.t.sol`.
contract ClearingPoolRollTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    IssuerPauseManagerStub internal issuerPause;
    IssuerComplianceStub internal issuerCompliance;
    IssuerGatedStockToken internal stock;
    MemeToken internal meme;

    /// @dev The second pair of tokens serves only one thing: "Same." MEME,"The two dimensions of the door.**Separate**Measure.
    ///      In the case of a single pair, one of the two assertions is actually the other.
    IssuerGatedStockToken internal otherStock;
    MemeToken internal otherMeme;

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant EXERCISED = 30 ether;
    uint128 internal constant REMAINDER = uint128(DEPOSIT - EXERCISED);

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev ERC-20 `Transfer(address,address,uint256)` It's... topic0.**It's not from the token.**  -  -
    ///      To prove that there are no transfers here, you cannot define a transfer by the person you're looking at.
    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    uint64 internal expiry;
    uint64 internal nextExpiry;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        otherStock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();
        otherMeme = new MemeToken();

        // Two. MEME Register each one - here**I'm gonna sign up for the same vault double.**:The key to rolling is that "the rest must be the same pair."
        // (MEME, Stock tokens),One more vault will only add a non-variant to that assertion.
        factory.bind(address(meme), address(vault));
        factory.bind(address(otherMeme), address(vault));

        // Same `ClearingPoolSettlement.t.sol`:Local Default Timetamp is 1,And... `clearedAt + 48h` and `expiry`
        // The size of the relationship should not be left to an unrealistic starting point.
        vm.warp(1_800_000_000);
        expiry = uint64(block.timestamp + 7 days);
        nextExpiry = uint64(block.timestamp + 14 days);

        stock.mint(address(vault), 1e30);
        otherStock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);
        vault.approve(otherStock, type(uint256).max);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 1e31);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
    }

    //  Scaffolding.

    /// @dev One.**Cleared, surplus 70** The pre-sequence series. Three articles are repeated in one place:
    ///      Deposit 100,Right to exercise authority 30,Settlement due  `remainder == 70`,And the pool is still in there. 70.
    function _settledPredecessor() internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.prank(alice);
        pool.exercise(seriesId, EXERCISED, alice);

        vm.warp(expiry);
        pool.settleExpired(seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"Precondition: remaining 70");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"Precondition: The pool is still in place. 70");
    }

    function _openSuccessor() internal returns (uint256) {
        return vault.openSeries(address(meme), address(stock), nextExpiry, STRIKE);
    }

    function _stocks() internal view returns (address[] memory list) {
        list = new address[](2);
        list[0] = address(stock);
        list[1] = address(otherStock);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    /// @dev Did you get any of this in the log? `token` Send ERC-20 `Transfer`.
    function _sawTransferFrom(Vm.Log[] memory logs, address token) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != token) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER_TOPIC) return true;
        }
        return false;
    }

    /// @dev Each successful roll must look at its own log and cannot be inferred from the final balance alone that it has not been transferred or returned.
    function _rollAndAssertNoStockTransfer(uint256 seriesId, uint256 nextSeriesId) internal {
        _rollAndAssertNoStockTransferAs(address(0), seriesId, nextSeriesId);
    }

    /// @dev `address(0)` Keeps the test contract as a caller; the rest of the address is used to pin the unauthorized path.
    function _rollAndAssertNoStockTransferAs(address caller, uint256 seriesId, uint256 nextSeriesId) internal {
        vm.recordLogs();
        if (caller != address(0)) vm.prank(caller);
        pool.rollExpired(seriesId, nextSeriesId);

        assertFalse(
            _sawTransferFrom(vm.getRecordedLogs(), address(stock)),
            unicode"CRITICAL There was a stock transfer in the roll."
        );
    }

    //  The test is self-censored: This detector is not asleep.

    /// @dev CRITICAL `_sawTransferFrom` It's nine common judgments in this document, and they're...**It's all negative.**It's...
    ///      (The negative assertion is that there is a unique and bad way to do it: when the trial itself fails, it is the same thing that happens when the trial itself is not working.
    ///      Nine claims will.**Together.**Silence becomes empty -- green, but nothing is checked.
    ///
    ///      The same thing in the non-variant file is caused by `ROLL_THROUGH_VAULT` Backdoor counter-proof.**It must ring.**);
    ///      There's no back door in this document, so it's cross-referenced here: right to move does give the stock tokens. `Transfer`,
    ///      The verdict must be visible.
    ///
    ///      **Both directions.** If you only prove that it will ring, a constant true verdict will pass equally.
    ///      The second assertion is that it must remain silent by asking for a token that has not been moved throughout the course of the proceedings.
    function test_theTransferDetectorFiresOnARealStockTransfer() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.recordLogs();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISED, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _sawTransferFrom(logs, address(stock)),
            unicode"The right to trade has actually transferred the stock tokens, but the verdicts have not been seen -- the nine \"no.\" TransferIt's all empty."
        );
        assertFalse(
            _sawTransferFrom(logs, address(otherStock)),
            unicode"The verdicts have been ringing a token that hasn't been moved all the way."
        );
    }

    //  No Variable 7:And the collateral is not in the pool.

    /// @notice Core of the promissory note:**Four equals, one in the pool. wei Don't move.**
    ///
    /// @dev No permission to pin it: The caller is a strange address that has nothing to do with this series.
    ///      Anyone can't modulate it. It's not a word on the interface. It's a live guarantee -- the operator should not be stuck when it disappears.user story 19).
    function test_roll_reattributesInsideThePoolWithoutMovingAWei() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        uint256 poolBalanceBefore = stock.balanceOf(address(pool));
        uint256 distributorCallsBefore = call.balanceOf(address(distributor), nextSeriesId);
        ClearingPool.Series memory nextBefore = pool.series(nextSeriesId);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Rolled(seriesId, nextSeriesId, REMAINDER);
        _rollAndAssertNoStockTransferAs(stranger, seriesId, nextSeriesId);

        // (1) Balance: one wei Don't move.
        assertEq(stock.balanceOf(address(pool)), poolBalanceBefore, unicode"CRITICAL The collateral left the pool.");

        // (2) Event: Sharing helper We have been told that the deal has no shares. Transfer

        // (3) Account: 4 equals
        ClearingPool.Series memory prior = pool.series(seriesId);
        ClearingPool.Series memory next = pool.series(nextSeriesId);
        assertEq(prior.remainder, 0, unicode"Zero for the front and back");
        assertEq(next.deposited - nextBefore.deposited, REMAINDER, unicode"Follow deposited Incremental");
        assertEq(next.minted - nextBefore.minted, REMAINDER, unicode"Follow minted Incremental");
        assertEq(
            call.balanceOf(address(distributor), nextSeriesId) - distributorCallsBefore, REMAINDER, unicode"New Caster"
        );

        // The front book.**Do Not Rewrite**:`deposited` / `minted` / `exercised` It remembers its own history.
        assertEq(prior.deposited, DEPOSIT, unicode"Foreword deposited Don't move.");
        assertEq(prior.minted, DEPOSIT, unicode"Foreword minted Don't move.");
        assertEq(prior.exercised, EXERCISED, unicode"Foreword exercised Don't move.");
        assertTrue(prior.settled, "settled");
    }

    /// @dev Get out of the way.**It really works.**:By `distributor` Subaru alice Right to exercise (art.#13 It's... `claimAndExercise` shape)
    ///      The collateral is the first time that we've left the pool -- and it's exactly the same as the weight of the line.
    ///
    ///      Without this, the Rolling Success only proves that several counters are right and that the user has not been able to get something.
    function test_roll_theRolledCallsAreExercisableInTheSuccessor() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        uint256 memeBefore = meme.balanceOf(alice);

        // distributor Here.**For yourself.**The identity profile. The beneficiary is... alice  -  -  The statement of the doorman is alice(See `exercise`).
        vm.prank(address(distributor));
        pool.exercise(nextSeriesId, REMAINDER, alice);

        assertEq(stock.balanceOf(alice), EXERCISED + REMAINDER, unicode"The part that came up to me was paid as usual.");
        assertEq(stock.balanceOf(address(pool)), 0, unicode"The pool was empty -- every one was turned to the holder.");
        assertEq(
            call.balanceOf(address(distributor), nextSeriesId),
            0,
            unicode"Validation certificates destroyed in quantities"
        );
        assertEq(
            memeBefore - meme.balanceOf(alice),
            (uint256(REMAINDER) * STRIKE) / 1e18,
            unicode"MEME Less at the right to trade price of the subsequent series"
        );
    }

    /// @dev Rolling is not a distribution door, and it's not a token, so...**The issuer can't stop it.**.
    ///      The settlement was structurally prevented by door control (which was a postponement), but once the settlement had taken place, the pool would no longer be subject to external contracts.
    function test_roll_worksWhileTheIssuerGatesThePool() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        issuerCompliance.setBlocked(address(stock), address(pool), true);
        pool.pokeGating(address(stock));
        assertEq(
            pool.exerciseDeadline(nextSeriesId),
            type(uint64).max,
            unicode"Precondition: The door control has been observed"
        );

        _rollAndAssertNoStockTransferAs(keeper, seriesId, nextSeriesId);

        assertEq(pool.series(seriesId).remainder, 0, unicode"Rolling as usual during door control");
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, "minted");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"And the collateral is still one. wei Nothing.");
    }

    /// @dev Keep it to the right side. / There's a power set up, not just a power set. 100 / 30 That group.
    function testFuzz_roll_conservesEveryWei(uint128 deposit, uint128 exercised) public {
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

        uint128 remainder = deposit - exercised;
        uint256 nextSeriesId = _openSuccessor();
        uint256 poolBalanceBefore = stock.balanceOf(address(pool));

        if (remainder == 0) {
            vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
            pool.rollExpired(seriesId, nextSeriesId);
            return;
        }

        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        assertEq(
            stock.balanceOf(address(pool)),
            poolBalanceBefore,
            unicode"The pool balance must be equal before and after the roller."
        );
        assertEq(pool.series(seriesId).remainder, 0, "remainder");
        assertEq(pool.series(nextSeriesId).deposited, remainder, "deposited");
        assertEq(pool.series(nextSeriesId).minted, remainder, "minted");
        assertEq(call.balanceOf(address(distributor), nextSeriesId), remainder, unicode"New Caster");
    }

    //  No Variable 1 Transcurve: only the global section is still in place

    /// @notice CRITICAL **Acceptance and inspection clause: the settlement of a prior series is being excluded 1(1) It's not like it's a place to be.**
    ///
    /// @dev It's on the front line after the roll. `minted  exercised == 70`,It's collateral.**It's already been handed over to the successor.**.
    ///      If you're gonna... 1(1) The request and scope of the project was broadened to the full series (or worse - to change the sentence to something else to make it pass).
    ///      The same mortgage will be repeated twice: the first paragraph is about the wrong answer. 140 > Pool balance 70.
    ///
    ///      Let this happen.**It's harmless.**It's not the wording of the verdict. It's... `settled  exercise revert`(No Variable 4(1)):
    ///      - In front of the front. 70 The encumbrance is no longer a claim from the moment it is settled. So there's only one way to read it correctly.
    ///      The one by series.**Unsolved**Meaningful range, cross-rolling payments covered by global 1(2) Responsible.
    function test_roll_theSettledPredecessorIsSoundOnlyBecause1aExcludesIt() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        ClearingPool.Series memory prior = pool.series(seriesId);
        ClearingPool.Series memory next = pool.series(nextSeriesId);

        // (1) And the number of settled series together -- the number that a pool can't afford.
        uint256 naiveClaim = (prior.minted - prior.exercised) + (next.minted - next.exercised);
        assertEq(
            naiveClaim,
            2 * uint256(REMAINDER),
            unicode"Precondition: naivety and true count of the same collateral twice"
        );
        assertGt(naiveClaim, stock.balanceOf(address(pool)), unicode"I can't afford to keep that amount.");

        // (2) It's harmless.**One**Reason: The pre-compensation certificate is no longer a claim.
        assertGt(
            prior.minted - prior.exercised,
            0,
            unicode"Pre-condition: There is indeed an unauthorised certificate in the front line."
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 1, alice);

        // (3) Correct sentence - in non-variant files**Same one.** `CollateralCheck`,Not here to write another one.
        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, _stocks(), _ids(seriesId, nextSeriesId));
        assertEq(perSeries, 0, unicode"No Variable 1(1)((unsolved range)");
        assertEq(global, 0, unicode"No Variable 1(2)(Global format)");
    }

    /// @dev Two rolls:A -> B -> C.The whole form must be set up after each step --
    ///      The same thing is not true for "rolling up" and "rolling up the chain."
    function test_roll_survivesAChainOfRolls() public {
        uint256 a = _settledPredecessor();
        uint256 b = _openSuccessor();
        _rollAndAssertNoStockTransfer(a, b);

        // B Due, no one's allowed  Roll the rest again.
        vm.warp(nextExpiry);
        pool.settleExpired(b);
        assertEq(pool.series(b).remainder, REMAINDER, unicode"B The rest is the one that rolls in.");

        uint64 thirdExpiry = uint64(block.timestamp + 7 days);
        uint256 c = vault.openSeries(address(meme), address(stock), thirdExpiry, STRIKE);
        _rollAndAssertNoStockTransfer(b, c);

        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"The balance after the two rolls is still there. 70");
        assertEq(pool.series(c).minted, REMAINDER, "C.minted");
        assertEq(call.balanceOf(address(distributor), c), REMAINDER, unicode"That's all the papers. 70");

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, _stocks(), ids);
        assertEq(perSeries, 0, unicode"No Variable 1(1)");
        assertEq(global, 0, unicode"No Variable 1(2):I can still afford to run the balance after two rolls.");
    }

    //  Six doors, one door.

    /// @dev (1):Wrong number. id The "serial series doesn't exist" instead of "it's not settled."
    function test_roll_rejectsAnUnopenedPredecessor() public {
        uint256 nextSeriesId = _openSuccessor();
        uint256 ghost = uint256(keccak256("nobody opened this"));

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, ghost));
        pool.rollExpired(ghost, nextSeriesId);
    }

    /// @dev (2):`remainder` It's not until the moment of settlement -- it was before. 0,There's no way to get out of here.
    function test_roll_rejectsAnUnsettledPredecessor() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
        uint256 nextSeriesId = _openSuccessor();

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotSettled.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // The same call after the settlement -- the reason for the rejection is really "unsolved" and not anything else.
        vm.warp(expiry);
        pool.settleExpired(seriesId);
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);
        assertEq(pool.series(nextSeriesId).minted, DEPOSIT, unicode"Roll as usual after settlement");
    }

    /// @dev (3):**This door is the full realization of the "not to roll twice".** Get out of here. `remainder` Zero.
    ///      So the second time, wherever you go -- no need for another "rolled" sign.
    function test_roll_cannotHappenTwice() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // The same thing happens in the next place -- otherwise "twice" becomes a copy of a claim.
        uint256 third = vault.openSeries(address(meme), address(stock), nextExpiry + 7 days, STRIKE);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, third);

        assertEq(call.balanceOf(address(distributor), third), 0, unicode"No second subsequent license.");
        assertEq(
            stock.balanceOf(address(pool)), REMAINDER, unicode"The pool balance was not copied for the second time."
        );
    }

    /// @dev (3) The other half: the balance of the total rights lost is 0,There's nothing to do.
    function test_roll_rejectsAFullyExercisedPredecessor() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
        vm.prank(alice);
        pool.exercise(seriesId, DEPOSIT, alice);

        vm.warp(expiry);
        pool.settleExpired(seriesId);
        uint256 nextSeriesId = _openSuccessor();

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);
    }

    /// @notice 4 And the acceptance clause "no follow-up sequence clean" revert;The new series will be restored after it is launched."
    ///
    /// @dev CRITICAL **There's only delay, no loss.**  -  -  It's nothing. admin And the only honest thing it said was:
    ///      The rest of the project was parked in the pool, and no one could remove it, nor would anyone need to.
    function test_roll_revertsCleanlyWithoutASuccessorAndRecoversOnceOneOpens() public {
        uint256 seriesId = _settledPredecessor();
        uint256 unopened = pool.seriesIdOf(address(meme), address(stock), nextExpiry);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.rollExpired(seriesId, unopened);

        // Nothing changed: the balance was still on the books and the collateral was still in the pool.
        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"The rest is still intact.");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"The collateral is intact.");

        // Three weeks later, someone came up with a new series -- and then the roll-in immediately recovered.
        vm.warp(block.timestamp + 21 days);
        uint256 late = vault.openSeries(address(meme), address(stock), uint64(block.timestamp + 7 days), STRIKE);
        _rollAndAssertNoStockTransfer(seriesId, late);

        assertEq(pool.series(late).minted, REMAINDER, unicode"One of them rolls over.");
        assertEq(
            stock.balanceOf(address(pool)),
            REMAINDER,
            unicode"The balance hasn't been moved during the whole period of the stasis."
        );
    }

    /// @dev 5 The first dimension,**The weighty dimension.**:If you change a stock token, it's the same as Jean. A The collateral to support B - The claim.
    ///      The other token in the pool is the balance of the other coin. 0,Get in there and shoot through the field. 1(2).
    function test_roll_rejectsAMismatchedStockToken() public {
        uint256 seriesId = _settledPredecessor();
        uint256 wrong = vault.openSeries(address(meme), address(otherStock), nextExpiry, STRIKE);

        assertEq(otherStock.balanceOf(address(pool)), 0, unicode"Prefix: none of the other stock pools.");

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorTokenMismatch.selector, wrong, address(meme), address(otherStock)
            )
        );
        pool.rollExpired(seriesId, wrong);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"The rest was not moved.");
        assertEq(call.balanceOf(address(distributor), wrong), 0, unicode"And no one forged the license.");
    }

    /// @dev 5 Second dimension: change one. MEME.The collateral is right, but the right to burn is...**Individual items** MEME
    ///      (`docs/spec.md`),So the holder of the certificate never paid the right price.
    function test_roll_rejectsAMismatchedMemeToken() public {
        uint256 seriesId = _settledPredecessor();
        uint256 wrong = vault.openSeries(address(otherMeme), address(stock), nextExpiry, STRIKE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorTokenMismatch.selector, wrong, address(otherMeme), address(stock)
            )
        );
        pool.rollExpired(seriesId, wrong);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"The rest was not moved.");
    }

    /// @dev 6 Half: The rest is settled -- one card to roll in is not a valid one. 4(1)).
    ///      Stuck in the middle. `nextSeriesId == seriesId`:Foreword**Already**Settlement, follow-up**Not**The settlement,
    ///      Same. id It is not possible to establish both, so a single door is not required for rolling.
    function test_roll_rejectsASettledSuccessorIncludingItself() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        vm.warp(nextExpiry);
        pool.settleExpired(nextSeriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, nextSeriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // Rolling to yourself: The same door hit.
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.rollExpired(seriesId, seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"I haven't even checked my bill twice.");
    }

    /// @dev 6 The second half,**The border was nailed to the second.**:`expiry` One second before you can roll,`expiry` Not that second.
    ///      Evidence and `exercise` It's... `block.timestamp >= deadline` Same direction -- the time-out series is dead.
    function test_roll_rejectsAnExpiredSuccessorExactlyAtItsExpiry() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        vm.warp(uint256(nextExpiry) - 1);
        uint256 snapshotId = vm.snapshotState();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, unicode"I can still roll in one second before I'm due.");

        vm.revertToState(snapshotId);
        vm.warp(nextExpiry);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorExpired.selector, nextSeriesId, nextExpiry, uint256(nextExpiry)
            )
        );
        pool.rollExpired(seriesId, nextSeriesId);
        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"The rest is still there after they're rejected.");
    }

    /// @dev 6 It's on the... `n.expiry`,**No, it's not.** deadline.The extension of the doorway has opened the subsequent power window, and the door is open.
    ///      But it's still not a legitimate rolling target -- the smaller the legitimate follow-on, for the reason. {ClearingPool-rollExpired}.
    ///
    ///      This test is...**The anchor to trade.**:When will someone replace the verdict? `_exerciseDeadline(n)`,It'll be red.
    function test_roll_refusesAnExpiredSuccessorEvenWhileGatingKeepsItExercisable() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        issuerCompliance.setBlocked(address(stock), address(pool), true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(nextExpiry) + 30 days);

        assertEq(
            pool.exerciseDeadline(nextSeriesId),
            type(uint64).max,
            unicode"Pre-condition: Right to remain viable at this point in time"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.SuccessorExpired.selector, nextSeriesId, nextExpiry, block.timestamp)
        );
        pool.rollExpired(seriesId, nextSeriesId);
    }
}
