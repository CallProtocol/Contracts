// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **The right-to-all path on the real object**(M1-5,issue #10).
///
/// The document exists for one reason:`docs/spec.md` The three lines of "The issuer freezes" in the Ri  "All rolls, the cards are reserved."
/// It's the product's core commitment to users, and it's...**Only on a real contract.**  -  -  Interception logic is compiled. `Stock` Every transfer path
/// A trim, not a thing that can be used. mock Regraved modules.
///
/// So here:
///
/// | Component | With what? |
/// |---|---|
/// | Mortgages. | **Real GME**(BeaconProxy -> `Stock`) |
/// | MEME | **Real `FlapTaxTokenV3`**(EIP-1167 -> 0x7777...3333),See you at the destruction path. {RobinhoodFlapBurnForkTest} |
/// | Door Control Status | Only mock **Two of the registration forms. view**;`Stock` And his own adornment,revert Data, execution path, everything. |
/// | Our four contracts. | Real deployment + Two bindings (in %2)issue #5  The test stitches  |
/// | Treasury | `VaultStub`  -  -  M2 It's true. |
///
/// CRITICAL mock Just landed.**Read the registration form**Up. The issuer will really freeze and change the return value of these two readings.
/// (`BLOCKER_ROLE` / `PAUSER_ROLE`,See `research/robinhood-stock-token-permissions.md` 5),
/// The character holder cannot be listed so that prank No, in other words,mock The replacement here is "who pressed the switch" and the government is not the only one who has been able to use the switch.
/// Not "what happens when you press it."
contract RobinhoodExerciseForkTest is ForkTest {
    /// @dev and `src/ClearingPool.sol` constant**Independence**Write to die: Take the constant of the target to test itself, and there is nothing to prove.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev The strangulation of the height. MEME and Flap Portal.CRITICAL **Do not write address volumes here**  -  -
    ///      They're defined as {ForkConfig},Only aliases are given here. The same sample was written in four fork tests.
    ///      So, "updating the configuration" and "updating all of it" are two things.PR #29 Review P2).
    ///      The three properties of the sample are "unreconcilable" latest canary "and the samples are exchanged." {ForkConfig} .
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev When the distribution door is in control `Stock` Throw two errors. Write here instead of empty `expectRevert()`  -  -
    ///      The latter will be accepted as a failure for other reasons, and the whole point of this test is a failure.**Reason**.
    error Blocked(address account);
    error IsPaused();

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100e18;
    uint256 internal constant EXERCISE = 40e18;

    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal alice = makeAddr("alice");
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

        // Beneficiaries:MEME Balance (transmitted from the conic), authorization, one-time declaration.
        vm.prank(FLAP_PORTAL);
        meme.transfer(alice, 1_000_000e18);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _memeCost(uint256 amount) internal pure returns (uint256) {
        return (amount * STRIKE) / 1e18;
    }

    //  Prefix: Both of the tokens on the fork are true.

    /// @dev Prove it before you run on the real deal.**It's a real contract to run.**.
    ///      Without this, all the green below may have been found at an empty address.
    function test_preconditions_bothTokensAreTheRealThing() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There's no code on the address.");
        assertEq(FLAP_MEME.code.length, 45, unicode"Sample MEME I think so. EIP-1167 Mint Agent");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"The collateral really went into the pool.");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"The logs on the fork height should not be suspended -- otherwise the successful path under is not what it thinks."
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"I'm not supposed to be sealed."
        );
    }

    //  Full path:deposit -> mint -> exercise

    /// @notice Acceptance and acceptance clauses:**Real GME Complete Down `deposit -> mint -> exercise`.**
    ///
    /// @dev Two "just equals" are the focus of this test, each one of which is one thing:
    ///      - `0xdead` Received == `memeAmount`  Flap The destruction path is not taxed (if one day we are paid, we are paid)
    ///        The users paid for it but did not burn it enough and the deflation promises were silently degraded;
    ///      - Beneficiaries received == `amount`  GME No transfer tax.raw The record is valid.
    function test_fullPath_depositMintExerciseOnRealTokens() public {
        assertEq(
            call.balanceOf(alice, seriesId), DEPOSIT, unicode"The license is cast at the actual amount of the account."
        );

        uint256 memeCost = _memeCost(EXERCISE);
        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);

        assertEq(
            call.balanceOf(alice, seriesId), DEPOSIT - EXERCISE, unicode"Certificates destroyed by weight of right"
        );
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"Payers' money. MEME");
        assertEq(meme.balanceOf(DEAD) - deadBefore, memeCost, unicode"CRITICAL 0xdead The exact receipt is a transfer.");
        assertEq(
            gme.balanceOf(alice), EXERCISE, unicode"CRITICAL The beneficiary receives exactly the same amount of power."
        );
        assertEq(gme.balanceOf(address(pool)), DEPOSIT - EXERCISE, unicode"I'm only so short of the pool.");
        assertEq(pool.series(seriesId).exercised, EXERCISE, "exercised");

        console2.log(
            string.concat(
                unicode"  Right to exercise authority ",
                vm.toString(EXERCISE),
                unicode" raw GME  Burn it. ",
                vm.toString(memeCost),
                unicode" raw MEME  0xdead Received ",
                vm.toString(meme.balanceOf(DEAD) - deadBefore)
            )
        );
    }

    //  Issuer freeze: Clean revert,And the license is still in place.

    /// @notice Acceptance and acceptance clauses:**Simulates the issuer `pause()`,Clean up the business. revert The user's license is not lost.**
    ///
    /// @dev Here's the button.**Global**Pause (`PAUSER_ROLE`,A single freeze of all stock coins in the chain) -
    ///      `Stock.paused()` Back `$.paused || registry.paused()`,So it's the one with the most coverage.
    ///
    ///      Not to lose it, not to burn it: the certificate after the release is really working. The last two lines say it's the latter.
    ///      That's exactly what I'm talking about. R2The automatic postponement of the commitment during the freeze" (the extension itself is #11).
    function test_exerciseRevertsCleanlyWhenTheIssuerPausesGlobally() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY, abi.encodeCall(IRobinhoodAccessRegistry.paused, ()), abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(IsPaused.selector);
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        // And after that, the certificate of authority will be of good use.
        vm.clearMockedCalls();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);
        assertEq(gme.balanceOf(alice), EXERCISE, unicode"Right to act as usual after the suspension is lifted");
    }

    /// @notice The other one: the issuer**Only the pool address**(`BLOCKER_ROLE`).
    ///
    /// @dev The pool is neither collected nor paid for -- the power is suspended. 3 Step. It's... 11 The first line of Coulgry,
    ///      Yeah. #11 The door control is extended to cover the real scene:`pokeGating` It's just that. `isBlocked(address(this))`.
    function test_exerciseRevertsCleanlyWhenTheIssuerBlocksThePool() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (address(pool))),
            abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, address(pool)));
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        vm.clearMockedCalls();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISE, alice);
        assertEq(gme.balanceOf(alice), EXERCISE, unicode"Unsealed and as usual");
    }

    /// @notice CRITICAL Issuer**Only one holder**(Not the pool.
    ///
    /// @dev `docs/spec.md` List this file because it's two of the top.**Different.**:The pool is clean.
    ///      So... #11 The door control observation doesn't see anything.**There will be no extension.**,The holder's certificate of rights expires on expiry.
    ///      It's intentional, but it's...**Real and irreversible user losses**.
    ///
    ///      The only promise on the contract floor that can stand is:**The license is still his and still sells it.**  -  -
    ///      ERC-1155 The transfer does not touch the stock coin, and therefore is not affected by the ban. The last three lines of the deal are the path of self-help.
    ///      The front end must point it out.11 / 10 The front end requirement.
    function test_blockingOneHolderStopsHisExerciseButNotHisCall() public {
        uint256 memeBefore = meme.balanceOf(alice);

        vm.mockCall(
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            abi.encodeCall(IRobinhoodAccessRegistry.isBlocked, (alice)),
            abi.encode(true)
        );

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, alice));
        pool.exercise(seriesId, EXERCISE, alice);

        _assertNothingMoved(memeBefore);

        // Self-help path: the certificate of rights is transferred as usual -- it does not touch the stock tokens and is therefore not subject to the ban.
        address buyer = makeAddr("buyer");
        vm.prank(alice);
        call.safeTransferFrom(alice, buyer, seriesId, DEPOSIT, "");
        assertEq(call.balanceOf(buyer, seriesId), DEPOSIT, unicode"The sealed holder still sells the certificate.");
        assertEq(call.balanceOf(alice, seriesId), 0, unicode"The license is actually transferred.");
    }

    /// @dev Three common assertions of the freeze test:**Nothing happened.**
    ///      the certificate of authority,MEME,Mortgages, accounts -- nothing moves.
    function _assertNothingMoved(uint256 memeBefore) private view {
        assertEq(call.balanceOf(alice, seriesId), DEPOSIT, unicode"I've lost one.");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME One of them didn't burn.");
        assertEq(gme.balanceOf(alice), 0, unicode"And I didn't get the stock tokens in advance.");
        assertEq(gme.balanceOf(address(pool)), DEPOSIT, unicode"The collateral's still in the pool.");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }
}
