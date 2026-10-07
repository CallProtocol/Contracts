// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {PausedAccessRegistry} from "../../script/rehearsal/PausedAccessRegistry.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry, IRobinhoodGatedStock} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **The door control sensor settlement on the real mark.**(M1-6,issue #11).
///
/// This document answers two questions that only the real contract can answer:
///
/// CRITICAL **(1) The three choices we've been guessing are real. GME Can you read it or not?**
/// `pokeGating` Read in turn `paused()` -> `ACCESS_CONTROLLED_REGISTRY()` -> Register `isBlocked(I'm a pool.)`.
/// Any signature is wrong. The pool will.**Silence.**Incoming fail-open  -  -  No, no. revert,No mistakes, nothing but never to see again.
/// The issuer's door control, "Auto-Extension of the Freezing", has been a dead letter.
/// Because the double was based on our guess.`test_preconditions_theRealGmeIsReadable` This is the first article of this document.
/// And it's the most important one.
///
/// CRITICAL **(2) How much do you need for the three readings? gas?** `GATING_READ_GAS` It's "Handing Health." view Use gas The attack was a very serious attack on the city of Zimbabwe.
/// And the threshold is set right, only if it's measured in the real contract.
///
/// The remaining four are the path to be taken by the acceptance clause: extend the full path, settle the block attack,fail-open Lend,
/// The blogger says that the law is not binding on the holder, but that it is not a matter of the law.
///
/// | Component | With what? |
/// |---|---|
/// | Mortgages. | **Real GME**(BeaconProxy -> `Stock`) |
/// | MEME | **Real `FlapTaxTokenV3`**(EIP-1167 -> 0x7777...3333) |
/// | Door Control Status | Only mock **Two of the registration forms. view**;`Stock` And his own adornment,revert Data, execution path, everything. |
/// | Our four contracts. | Real deployment + Two bindings (in %2)issue #5  The test stitches  |
contract RobinhoodGatingForkTest is ForkTest {
    /// @dev The strangulation of the height. MEME and Flap Portal.CRITICAL **Do not write address volumes here**  -  -
    ///      They're defined as {ForkConfig},Only aliases are given here. The same sample was written in four fork tests.
    ///      So, "updating the configuration" and "updating all of it" are two things.PR #29 Review P2).
    ///      The three properties of the sample are "unreconcilable" latest canary "and the samples are exchanged." {ForkConfig} .
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev When the distribution door is in control `Stock` Throw two errors. Write here instead of empty `expectRevert()`  -  -
    ///      The latter will be considered as a "failure for other reasons".
    error Blocked(address account);
    error IsPaused();

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev CRITICAL Literally, no reading `pool.GRACE_PERIOD()`:It's not gonna prove anything by testing the target's own constant.
    uint64 internal constant GRACE = 48 hours;

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;

    AttestationRegistry internal registry;
    Call internal call;
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
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        // I.D.'s registered with the real thing. MEME The vault -- the door that opened the series, it was this binding.M2-5 / #37).
        //    True binding by `CallVaultFactory` Yes. Flap In the same transaction, see
        //    `test/fork/RobinhoodCallVaultFactory.t.sol`;Here's one.**It's been fired long ago.**The token,
        //    There was no such moment to replay, so a homogenous binding was used in the sub-plant.
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

    //  Scaffolding.

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

    /// @dev The issuer upgraded the door. view The 'Air' is a "black-sharp" "dash" that cannot be read, but the stoppage of coins is working as usual.
    function _breakTheGatingViews() internal {
        vm.mockCallRevert(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.paused, ()),
            "gating view is gone"
        );
    }

    //  CRITICAL (1) The three of the agents we guess are real. GME Can you read it?

    /// @notice **The most important item in this document.**
    ///
    /// @dev I've got three readings on the pool.**Guess.**:`Stock` It's open. `paused()`;It publishes its own registration form address;
    ///      The registration form. `isBlocked(address)`.One out of three is wrong, and the pool is in forever. fail-open  -  -
    ///      And... fail-open Yes.**Silence.**Nothing. revert It'll tell us that it's wrong.
    ///
    ///      So here's the truth. GME poke Once, and then the observation was said to be "clean and clean."**It's working.**.
    ///      `unreadable == false` This one, Bull, is the proof that all three signatures are valid.
    function test_preconditions_theRealGmeIsReadableThroughTheGatingViews() public {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There's no code on the address.");

        // Three readings each have to be set up individually -- in case this assertion is red in the future, first know which one is broken.
        assertFalse(IRobinhoodGatedStock(ForkConfig.GME).paused(), unicode"GME.paused() Can't read or be true.");
        address issuerRegistry = IRobinhoodGatedStock(ForkConfig.GME).ACCESS_CONTROLLED_REGISTRY();
        assertEq(
            issuerRegistry,
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"GME The address of the registration form that we reported on didn't match the one we wrote down."
        );
        assertFalse(
            IRobinhoodAccessRegistry(issuerRegistry).isBlocked(address(pool)), unicode"I'm not supposed to be sealed."
        );

        pool.pokeGating(ForkConfig.GME);

        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertFalse(
            g.unreadable,
            unicode"CRITICAL The pool doesn't make sense. GME The door control - one of the three choices is wrong"
        );
        assertFalse(g.active, unicode"There's no door control at the fork height.");
        assertEq(g.clearedAt, 0, unicode"Nothing happened.  No grace.");
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"deadline Yeah. expiry");
    }

    function test_rehearsalReplacementPreservesTheRegistryBeaconRole() public {
        vm.etch(ForkConfig.ROBINHOOD_ACCESS_REGISTRY, type(PausedAccessRegistry).runtimeCode);

        assertEq(
            IBeacon(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).implementation(),
            ForkConfig.EXPECTED_GME_IMPLEMENTATION,
            unicode"The double must not be destroyed. registry It's all yours. beacon Role"
        );
        assertTrue(IRobinhoodGatedStock(ForkConfig.GME).paused(), unicode"Real GME We must see a global pause.");
    }

    /// @notice CRITICAL (2) `GATING_READ_GAS` The basis of the facts is here.
    ///
    /// @dev That constant is both the maximum of forwarding and the minimum of the caller. It's too low to be healthy. view The blogger says that the government is not a party.
    ///      It's too high to let each one. poke They all ask for an unnecessary amount. gas.
    ///      This one.**The whole thing.** `pokeGating`(Including three cold accounts, events, and gas (Landline examination itself)
    ///      The cost of the actual measurements was printed out and it was confirmed that it was fit.**One.**Read the budget -- that is, the real cost of a single reading.
    ///      It's much smaller than the budget. gas Starving to health. viewThe attack cannot be hit at the threshold by normal fluctuations.
    function test_gasBudget_theRealReadsFitInsideASingleBudget() public {
        uint256 budget = pool.GATING_READ_GAS();

        uint256 before = gasleft();
        pool.pokeGating(ForkConfig.GME);
        uint256 spent = before - gasleft();

        console2.log(
            string.concat(
                unicode"  Real GME Last time. pokeGating(The cold account) ",
                vm.toString(spent),
                unicode" gas  One reading budget ",
                vm.toString(budget)
            )
        );

        assertLt(spent, budget, unicode"Whole poke The cost of the project should be included in a read budget.");
        assertFalse(pool.gating(ForkConfig.GME).unreadable, unicode"And it does read.");
    }

    /// @notice CRITICAL **The embedded in this test contract CALL Centre, Pool Execution for forwarding gas More than that. poke Actual consumption.**
    ///
    /// @dev The last measure is the cold of this test contract. `pokeGating` Time.**Consumption**.This is the same test contract.
    ///      Use low-level `CALL{gas: ...}` In `ClearingPool` How many executions were forwarded gas,Pool I'm gonna have to leave a whole piece before I read it.
    ///      Budget (%)`ceil(50,000  64 / 63) + Call Backup`).This is a...**Embedded call forwarding volume**The return test,
    ///      No, I don't. EOA or Monitor Top level deal. `gasLimit` and recommended measures or recommendations.
    ///
    ///      CRITICAL Without this, it's easy for developers to mistook the last print as a low-level consumption. CALL Forwardable gas,Result
    ///      `pokeGating` Hit it! `NotEnoughGasToObserveGating`.So here's two in a row.**Test contract** the number and put
    ///      The government has already been forced to take action to prevent the use of the Internet.
    ///
    ///      WARNING The only thing that's meant to be is**Direction**And a wide-up line, no exact numbers: that number goes with any one. `_readGating` It's...
    ///      The only thing that can be changed is a calculator that has to be manually updated every time it changes the code. The upper boundary is there to get
    ///      The budget or surplus has been increased by one order of magnitude."
    function test_gasFloor_theHarnessMustForwardMoreExecutionGasThanThePokeSpends() public {
        uint256 coldPokeGasSpent = _measureColdPoke();

        // (1) Test contract forwards the consumption to the original. Pool  -  -  It must be. gas floor Reject.
        (bool spentForwardingOk, bytes memory spentForwardingRet) = _callColdPokeWithForwardedGas(coldPokeGasSpent);
        assertFalse(
            spentForwardingOk, unicode"Test contract forwarded to consumption Pool Implementation gas It's over."
        );
        assertEq(
            bytes4(spentForwardingRet),
            ClearingPool.NotEnoughGasToObserveGating.selector,
            unicode"The grounds for refusal must be Pool It's... gas floor,Not a naked one. out-of-gas"
        );
        _assertGmeObservationIsCleanAndReadable();

        // (2) Two-part test contract. Pool Minimum successful implementation forwarded gas;The success of the upper world is first translated into reality.
        uint256 lowerForwardedPoolGas = coldPokeGasSpent; // Known Failed
        uint256 upperForwardedPoolGas = 400_000;
        (bool upperBoundOk,) = _callColdPokeWithForwardedGas(upperForwardedPoolGas);
        assertTrue(
            upperBoundOk, unicode"The upper half must be successfully transmitted from this test contract to Pool"
        );
        _assertGmeObservationIsCleanAndReadable();

        while (upperForwardedPoolGas - lowerForwardedPoolGas > 1) {
            uint256 candidateForwardedPoolGas = (upperForwardedPoolGas + lowerForwardedPoolGas) / 2;
            (bool candidateOk,) = _callColdPokeWithForwardedGas(candidateForwardedPoolGas);
            if (candidateOk) upperForwardedPoolGas = candidateForwardedPoolGas;
            else lowerForwardedPoolGas = candidateForwardedPoolGas;
        }

        // Run again with a two-point result: it must be a healthy reality if it's to succeed. GME Observation.
        (bool minimumForwardingOk,) = _callColdPokeWithForwardedGas(upperForwardedPoolGas);
        assertTrue(minimumForwardingOk, unicode"Minimum forward execution from split gas It has to work.");
        _assertGmeObservationIsCleanAndReadable();

        console2.log(
            string.concat(
                unicode"  Real GME The test contract is cold once. pokeGating:Measured consumption ",
                vm.toString(coldPokeGasSpent),
                unicode" gas  This test contract is low-level. CALL In Pool Minimum successful implementation forwarded gas ",
                vm.toString(upperForwardedPoolGas)
            )
        );

        assertGt(
            upperForwardedPoolGas,
            coldPokeGasSpent,
            unicode"This test contract Pool Minimum execution forwarded gas Must be greater than measured consumption"
        );
        assertLt(
            upperForwardedPoolGas,
            200_000,
            unicode"This test contract Pool Minimum execution forwarded gas It's going up to an unreasonable level."
        );
    }

    /// @dev Under cold reading path, this test contract is called directly. Pool  One clean one  poke How much is it? gas.
    function _measureColdPoke() private returns (uint256 spent) {
        _coolGmeGatingReadPath();
        uint256 before = gasleft();
        pool.pokeGating(ForkConfig.GME);
        spent = before - gasleft();
        _assertGmeObservationIsCleanAndReadable();
    }

    /// @dev Every one. probe From the same cold truth. GME Door access path starts and only this test contract is measured Pool .
    function _callColdPokeWithForwardedGas(uint256 forwardedPoolGas) private returns (bool ok, bytes memory ret) {
        _coolGmeGatingReadPath();
        (ok, ret) = address(pool).call{gas: forwardedPoolGas}(abi.encodeCall(ClearingPool.pokeGating, (ForkConfig.GME)));
    }

    /// @dev GME Yes. BeaconProxy:proxy,Other beacon/Registration forms and delegatecall implementation It must all get cold again.
    ///      implementation Fixed Reference ForkConfig , avoid the future routing of the call path to slip the jump.
    function _coolGmeGatingReadPath() private {
        vm.cool(ForkConfig.GME);
        vm.cool(ForkConfig.ROBINHOOD_ACCESS_REGISTRY);
        vm.cool(ForkConfig.EXPECTED_GME_IMPLEMENTATION);
    }

    function _assertGmeObservationIsCleanAndReadable() private view {
        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertFalse(g.active, unicode"The truth on the fixed fork. GME It's not supposed to be in the door.");
        assertFalse(g.unreadable, unicode"The truth on the fixed fork. GME Door control must be healthy.");
        assertEq(g.clearedAt, 0, unicode"Clean and never controlled. GME Should not start a broad clock");
    }

    //  Acceptance and acceptance: extension of full path

    /// @notice Acceptance and acceptance clauses:**pause -> poke -> Pass. expiry Back window still open (transfer roll, rights card not lost)
    ///         -> The right to move is immediately successful (no need to wait) poke)-> We've seen the window being closed. 48h,The grace of the inner line is still successful.
    ///         -> After the grace `settleExpired` Success.**
    ///
    /// @dev Press it.**Global**Pause (`PAUSER_ROLE`,A single freeze of all stock coins in the chain) -
    ///      `Stock.paused()` Back `$.paused || registry.paused()`,The most covered.
    function test_fullPath_pausePokeKeepsWindowOpenThenClearGraceExerciseSettle() public {
        // (1) Issuer paused, anyone poke Stay and observe.
        _mockGlobalPause(true);
        vm.prank(attacker);
        pool.pokeGating(ForkConfig.GME);
        assertTrue(pool.gating(ForkConfig.GME).active, unicode"We've got a door.");
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"Door control open.");

        // (2) Pass. expiry:The window is still open.
        vm.warp(uint256(expiry) + 5 days);
        vm.prank(alice);
        vm.expectRevert(IsPaused.selector);
        pool.exercise(seriesId, 10e18, alice);
        assertEq(call.balanceOf(alice, seriesId), DEPOSIT, unicode"I've lost one.");

        // The door control settlement was structurally blocked -- this is automatic extension, without any administrator involved.
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, ForkConfig.GME));
        pool.settleExpired(seriesId);

        // (3) Releaser Disable- CRITICAL **Right now, right now. There's no one else here. poke Over.**
        //    Right-reading is a record, still in the door. No deadline; transfer has been released.
        //    `pokeGating` Yes.**Close the window.**The move, not the opening of the window.
        vm.clearMockedCalls();
        assertTrue(pool.gating(ForkConfig.GME).active, unicode"Prefix: Records are still in the door control");
        assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"Prefix: the broad hour never starts");

        vm.prank(alice);
        pool.exercise(seriesId, 10e18, alice);
        assertEq(gme.balanceOf(alice), 10e18, unicode"No, I'm not. poke,The right to work is working.");

        // 4 Observed Disarm: Uncuted Harvest in Disarm Time + 48h,The grace begins at this moment.
        pool.pokeGating(ForkConfig.GME);
        uint64 clearedAt = uint64(block.timestamp);
        assertEq(pool.gating(ForkConfig.GME).clearedAt, clearedAt, unicode"Unmark this stamp.");
        assertEq(pool.exerciseDeadline(seriesId), clearedAt + GRACE, unicode"deadline = Undo + 48h");

        // 5 Lend**Inside**The right to vote is still working - where the real implementation is delayed
        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 30e18, alice);
        assertEq(gme.balanceOf(alice), 40e18, unicode"Pass. expiry Five days, two of them.");

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // 6 After grace: turn the line off, the settlement opens.
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
        assertEq(s.remainder, DEPOSIT - 40e18, unicode"remainder = deposited  exercised");
        assertEq(
            gme.balanceOf(address(pool)), DEPOSIT - 40e18, unicode"The collateral is still in the pool waiting to roll."
        );
    }

    //  Receiving and inspection: settlement blockage attack

    /// @notice CRITICAL Acceptance and acceptance clauses:**The repetition of clean markings. poke(The government has also been able to provide information on the situation in the country.
    ///         `clearedAt` I'm not going anywhere.`settleExpired` It must be done on time.**
    ///
    /// @dev It's not a variable. 4(3) The target wants to extend it for an indefinite period of free:
    ///      Every time, "clean." pokeIt's all going to push. `clearedAt`,`clearedAt + 48h` The blogger says that the government is not going to be able to make a difference.
    ///      Settlement Permanent revert,The rolling remains never happening -- and the certificate that he should have been corrupted has been valid.
    ///
    ///      The cycle deliberately crosses the real block and pushes the time, the last round.**Close**The deadline.
    function test_settlementBlockingAttack_repeatedPokesNeverMoveTheDeadline() public {
        pool.pokeGating(ForkConfig.GME);
        assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"Precondition: clean and never stamped");

        // Push from the week before maturity to the second before expiry, cross multiple blocks, switch to caller
        uint256[5] memory offsets = [uint256(6 days), 3 days, 1 days, 2 hours, 1];
        for (uint256 i = 0; i < offsets.length; i++) {
            vm.warp(uint256(expiry) - offsets[i]);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(ForkConfig.GME);
            vm.prank(makeAddr("another attacker"));
            pool.pokeGating(ForkConfig.GME);

            assertEq(pool.gating(ForkConfig.GME).clearedAt, 0, unicode"Clean. poke It's driving. clearedAt");
            assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"deadline It's been pushed away.");
        }

        // The second the line is closed, the settlement is open -- the attack is not replaced by a second extension.
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
        assertTrue(pool.series(seriesId).settled, unicode"CRITICAL The settlement must be on time.");
        assertEq(pool.series(seriesId).remainder, DEPOSIT, "remainder");
    }

    //  Acceptance and inspection:fail-open Lend

    /// @notice Acceptance and acceptance clauses:**Get the door. view revert -> 48h No internal settlement -> This must be followed by a settlement;
    ///         Second in-window revert No recapsing. `clearedAt`.**
    ///
    /// @dev fail-open The reason for this is activity: the pool cannot be upgraded.fail-closed It's gonna make an interface that can't read anymore.
    ///      All the collateral is frozen forever. The price is straight -- if the coin is in a pause and we can't read it, it's a good thing.
    ///      The holder loses its right to exercise authority in a window that is completely unauthorised.**Only the allowance. 48 Hours of manual response time.**
    function test_failOpen_stampsOnceAndSettlesOnlyAfterTheGrace() public {
        // The interface is broken when close to expiry, the width ratio is now expiry Even later,deadline I can see it's been pushed.
        vm.warp(uint256(expiry) - 1 hours);
        _breakTheGatingViews();

        pool.pokeGating(ForkConfig.GME);
        uint64 clearedAt = uint64(block.timestamp);

        ClearingPool.Gating memory g = pool.gating(ForkConfig.GME);
        assertTrue(g.unreadable, unicode"I can't read.  It's not readable.");
        assertFalse(g.active, unicode"fail-open:Not as a doorman.");
        assertEq(g.clearedAt, clearedAt, unicode"I'll seal it once when I'm in the middle of a readable.");
        assertEq(pool.exerciseDeadline(seriesId), clearedAt + GRACE, unicode"The window is open.");

        // Repeated reading in the window: no re-sequests at any time, no roll-backs on the settlement.
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 9 hours);
            vm.roll(block.number + 1);
            vm.prank(attacker);
            pool.pokeGating(ForkConfig.GME);

            assertEq(pool.gating(ForkConfig.GME).clearedAt, clearedAt, unicode"Twice. revert Recover it. clearedAt");
            vm.expectRevert(
                abi.encodeWithSelector(
                    ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
                )
            );
            pool.settleExpired(seriesId);
        }

        // After the grace period, you must be cleared... fail-open The kind of loss admitted to is of a superior nature:48 Hours
        vm.warp(uint256(clearedAt) + GRACE);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"We have to settle it after the grace.");
    }

    //  Two "no extension" borders.

    /// @notice Acceptance and acceptance clauses:**Not poke The door control does not create an extension.** The contract is only for recorded observations.
    /// @dev And this... poke Be Monitor The operational rigidity of the duty -- but it's not authorized, and any holder can do it himself.
    function test_gatingThatNobodyPokedProducesNoExtension() public {
        _mockPoolBlocked(true);

        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"Nobody. poke  No extension.");

        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 1e18, alice);

        // CRITICAL But...**Settlement**No old records were taken on this side: it observed the door control first in the house and then refused.
        //    Otherwise, the holder would be liquidated when it was simply unable to exercise its right to do so.
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, ForkConfig.GME));
        pool.settleExpired(seriesId);

        // I'll do it again. poke,The delay is immediately restored -- the price of the owner's own rescue is one. gas
        pool.pokeGating(ForkConfig.GME);
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"poke Effective after extension");
    }

    /// @notice CRITICAL Acceptance and acceptance clauses:**Only one holder (not the pool address) is enclosed without an extension and the situation is recognized.**
    ///
    /// @dev The pool is clean.  The observations don't see anything.  Without extension, the holder ' s certificate of authority expires on expiry.
    ///      It's intentional, but it's...**Real and irreversible user losses**.
    ///      The front end has to distinguish it from the other side, by three combinations:revert The address in the data is...**Holder**Not the pool.
    ///      `GatingObserved` Say it. `gated == false`,`exerciseDeadline` Still equals `expiry`.
    ///      His only way to save himself is to sell the certificate of right -- transfer without touching the stock coin, and therefore not affected by the ban.
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
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"The individual holder is not subject to extension");

        // The settlement is on schedule and the certificates are invalidated.
        vm.warp(expiry);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
        assertEq(pool.series(seriesId).remainder, DEPOSIT, unicode"The collateral rolls to other holders");

        // Self-help path: the license still sells.**Timely**Point it out.
        assertEq(call.balanceOf(alice, seriesId), DEPOSIT, unicode"He still has the call, but it's no longer useful.");
    }
}
