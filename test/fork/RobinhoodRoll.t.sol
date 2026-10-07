// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **The whole scroll path on the real cursor**(M1-7,issue #12) -  -  `docs/spec.md` The first of these is a cross-test.
///
/// Local.`test/ClearingPoolRoll.t.sol`)Six doors and the constant assertion have been nailed.
/// **The thing that the double can't prove.**:
///
/// > "Rolling doesn't mean going out."**Real GME Balance**And the word is not about our double.
///
/// We wrote the double. ERC-20  -  -  Of course it won't move the balance in the roller-down because we didn't write the line code. It's true. GME Yes.
/// BeaconProxy -> `Stock`,with the issuer's accelerator and its own account;**It's...**"The deal is before and after."
/// `balanceOf(pool)` One. wei Nothing, and none. `Transfer`,That is the form of proof of that commitment.
///
/// Run this chain along the line on the real mark:`deposit -> exercise -> settle -> roll -> Right to follow in the series`,
/// So get over there. 60 Quantum GME And finally it really came to the holder.
contract RobinhoodRollForkTest is ForkTest {
    /// @dev The strangulation of the height. MEME and Flap Portal.CRITICAL **Do not write address volumes here**  -  -
    ///      They're defined as {ForkConfig},Only aliases are given here. The same sample was written in four fork tests.
    ///      So, "updating the configuration" and "updating all of it" are two things.PR #29 Review P2).
    ///      The three properties of the sample are "unreconcilable" latest canary "and the samples are exchanged." {ForkConfig} .
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev ERC-20 `Transfer(address,address,uint256)` It's... topic0.**- No, no, no, no. GME Read it on your body.**  -  -
    ///      To prove that there are no transfers here, you cannot define a transfer by the person you're looking at.
    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant EXERCISE = 40e18;
    uint128 internal constant REMAINDER = uint128(DEPOSIT - EXERCISE);

    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint64 internal expiry;
    uint64 internal nextExpiry;
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
        nextExpiry = uint64(block.timestamp + 14 days);
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

    /// @dev Part of the right to line, due, settlement - leave one `remainder == 60` .
    function _exerciseAndSettle() internal {
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);

        vm.warp(expiry);
        vm.prank(keeper);
        pool.settleExpired(seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"Precondition: remaining 60");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"Precondition: Real GME And it's still there. 60");
    }

    function _sawGmeTransfer(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(gme)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER_TOPIC) return true;
        }
        return false;
    }

    //  Precondition: It's a real contract to run.

    /// @dev Without this, all the green below may have been found at an empty address.
    function test_preconditions_theCollateralIsTheRealGme() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There's no code on the address.");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"The collateral really went into the pool.");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"The logs on the fork height should not be suspended -- otherwise the settlement will not advance."
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"I'm not supposed to be sealed."
        );
    }

    //  Full path:settle -> roll -> Right to follow in the series

    /// @notice Acceptance and acceptance clauses:**Real before and after the roll. GME The balance remains unchanged and is not variable 1 / 7 Establishment.**
    ///
    /// @dev Three sides of the same claim, for reasons set out in the contractual notes: balance (in motion), incident (no) `Transfer`),Account (four equals).
    ///      And then we'll roll over to the end. 60 The number is really on the holder -- otherwise the Roll Success only proves that several counters are right.
    function test_fullPath_settleThenRollThenExerciseTheSuccessor() public {
        _exerciseAndSettle();

        uint256 nextSeriesId = vault.openSeries(address(meme), address(gme), nextExpiry, STRIKE);
        uint256 poolBalanceBefore = gme.balanceOf(address(pool));

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Rolled(seriesId, nextSeriesId, REMAINDER);
        vm.prank(keeper); // No permission  -  keeper It has nothing to do with this series.
        pool.rollExpired(seriesId, nextSeriesId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // (1) Real GME I'm not sure I'm gonna be able to do this. wei Nothing.
        assertEq(gme.balanceOf(address(pool)), poolBalanceBefore, unicode"CRITICAL The collateral left the pool.");
        // (2) There's not one in this deal. GME It's... Transfer  -  -  **It's right to not find it.**
        assertFalse(_sawGmeTransfer(logs), unicode"CRITICAL There's a real thing in the roller coaster. GME Transfers");
        // (3) No Variable 7 Four numbers.
        assertEq(pool.series(seriesId).remainder, 0, unicode"Zero for the front and back");
        assertEq(pool.series(nextSeriesId).deposited, REMAINDER, unicode"Follow deposited");
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, unicode"Follow minted");
        assertEq(call.balanceOf(address(distributor), nextSeriesId), REMAINDER, unicode"New Caster");

        // No Variable 1(2):Same stock in tokens, outstanding claims + Toroll Residue <= Pool balance.
        // CRITICAL Prior (liquidated)**Not included**,That's why it's set up -- that's why it's set up. 60 The bomb was handed over to the successor.
        uint256 claim = uint256(pool.series(nextSeriesId).minted - pool.series(nextSeriesId).exercised)
            + pool.series(seriesId).remainder;
        assertLe(
            claim, gme.balanceOf(address(pool)), unicode"No Variable 1(2):Ichichi. GME I can hold on to all my claims."
        );

        // Get over there. 60 The bomb really delivers:distributor I'm a good man. alice Right to exercise (art.#13 the shape.
        vm.prank(address(distributor));
        pool.exercise(nextSeriesId, REMAINDER, alice);

        assertEq(gme.balanceOf(alice), EXERCISE + REMAINDER, unicode"CRITICAL The owner finally got a lot of it. 100");
        assertEq(gme.balanceOf(address(pool)), 0, unicode"Clear the pool.");

        console2.log(
            string.concat(
                unicode"  Crozen ",
                vm.toString(uint256(REMAINDER)),
                unicode" raw GME  Ikei balance before and after ",
                vm.toString(poolBalanceBefore),
                unicode" -> ",
                vm.toString(poolBalanceBefore)
            )
        );
    }

    /// @notice Acceptance and acceptance clauses:**Clean without a follow-up series revert,You can recover when you open a new series -- only delay, no loss.**
    ///
    /// @dev What it means to run over the real mark is, during the pause, 60 Quantum GME No one can take it away, no one can.
    ///      None of the acts of any external contract. admin The only honest answer to the project's suspension is this.
    function test_rollRevertsCleanlyWithoutASuccessorAndRecoversLater() public {
        _exerciseAndSettle();

        uint256 unopened = pool.seriesIdOf(address(meme), address(gme), nextExpiry);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.rollExpired(seriesId, unopened);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"The rest is still intact.");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"Real GME It's still there.");

        // Three weeks after the stop, a new series was launched.
        vm.warp(block.timestamp + 21 days);
        assertEq(
            gme.balanceOf(address(pool)),
            REMAINDER,
            unicode"The balance hasn't changed during the whole period of the stasis."
        );

        uint256 late = vault.openSeries(address(meme), address(gme), uint64(block.timestamp + 7 days), STRIKE);
        vm.recordLogs();
        pool.rollExpired(seriesId, late);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(pool.series(late).minted, REMAINDER, unicode"One of them rolls over.");
        assertEq(gme.balanceOf(address(pool)), REMAINDER, unicode"Rolling itself is still alive.");
        assertFalse(
            _sawGmeTransfer(logs), unicode"CRITICAL There's a real thing going on in the retrospect. GME Transfers"
        );
    }
}
