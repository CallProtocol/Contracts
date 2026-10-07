// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {MerkleTree} from "../helpers/MerkleTree.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice **Right to receive and merge on the real object**(M1-8,issue #13) -  -  `docs/spec.md` The first of these is a cross-test.
///
/// Local.`test/MerkleDistributor.t.sol`)We've already got four directions of the sign.root Freezing, licensing level
/// It's all nailed up. So it's just done here.**The thing that the double can't prove.**:
///
/// > `claimAndExercise` It's burning.**Share balance not received by all users**,And it's moving two at once.**Real**Dinosaur.
///
/// The local ones are just our own -- they're gonna be moving in the same way as the parameters, because we don't have any other code.
/// In reality. GME(BeaconProxy -> `Stock`,The real one with the distribution-modifier. `FlapTaxTokenV3` The adjective.
///
/// - "and re-enactment will be rejected."
/// - CRITICAL Trusted balance of authorized certificates**Never below**Not received all leaf The 'Creation of the Peace'.
/// - And one last one.**Never received it.**The holder really turned her in for that...
///
/// That's the form of proof of that line.issue #13 The attack described as "the people holding it in hand." proof,The government has not yet made any progress in the area.
/// It proves exactly the opposite.
///
/// | Component | With what? |
/// |---|---|
/// | Mortgages. | **Real GME** |
/// | MEME | **Real `FlapTaxTokenV3`**(EIP-1167 -> 0x7777...3333) |
/// | Our four contracts. | Real deployment + Two bindings (in %2)issue #5  The test stitches  |
/// | Treasury | `VaultStub`  -  -  M2 It's true. |
/// | merkle Tree | Test side independent construction (`test/helpers/MerkleTree.sol`),M4 It's... Indexer That's the one under the chain. |
contract RobinhoodDistributorForkTest is ForkTest {
    /// @dev and `src/ClearingPool.sol` constant**Independence**Write to die: Take the constant of the target to test itself, and there is nothing to prove.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev The strangulation of the height. MEME and Flap Portal.CRITICAL **Do not write address volumes here**  -  -
    ///      They're defined as {ForkConfig},Only aliases are given here. The same sample was written in four fork tests.
    ///      So, "updating the configuration" and "updating all of it" are two things.PR #29 Review P2).
    ///      The three properties of the sample are "unreconcilable" latest canary "and the samples are exchanged." {ForkConfig} .
    address internal constant FLAP_MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant FLAP_PORTAL = ForkConfig.FLAP_PORTAL;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    uint128 internal constant STRIKE = 1850e18;

    /// @dev A week of casting. distributor The amount of the -- just equals three. leaf And the sum of the two. More of the casts make the trusteeship claim insensitive.
    uint256 internal constant MINTED = 100e18;

    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;

    IERC20 internal gme;
    IERC20 internal meme;

    address internal publisher = makeAddr("publisher");
    address internal keeper = makeAddr("keeper");

    /// @dev Three holders:alice Take the merge path,bob Go to the pick-up path,**carol I'm not going to take it from scratch.**  -  -
    ///      She's the one who holds it. proofMan, the last test is to get her to really shake it out.
    address[3] internal accounts;
    uint256[3] internal amounts;

    /// @dev Test the "which one" you're maintaining. leaf "It's already consumed." No contract. `claimed`  -  -  That'll make...
    ///      Balance >= The sum of the unreceipted " is defined as "unreceipt" by the client's own account.
    bool[3] internal consumed;

    uint64 internal expiry;
    uint256 internal seriesId;

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);
        meme = IERC20(FLAP_MEME);

        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        call = new Call();
        distributor = new MerkleDistributor(publisher);
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

        accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        amounts = [uint256(50e18), 30e18, 20e18];

        expiry = uint64(block.timestamp + 7 days);
        seriesId = vault.openSeries(address(meme), address(gme), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), MINTED);

        for (uint256 i = 0; i < accounts.length; i++) {
            vm.prank(FLAP_PORTAL);
            meme.transfer(accounts[i], 1_000_000e18);
            vm.prank(accounts[i]);
            meme.approve(address(pool), type(uint256).max);
        }
        // CRITICAL carol **No declaration to be signed**  -  -  The test at the gate was to use her, and her. leaf This has led to the retention of shared balances.
        _attest(accounts[0]);
        _attest(accounts[1]);

        vm.prank(publisher);
        distributor.setRoot(seriesId, MerkleTree.root(_leaves()));
    }

    //  Scaffolding.

    function _attest(address who) internal {
        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _leaves() internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            leaves[i] = MerkleTree.leafOf(seriesId, accounts[i], amounts[i]);
        }
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory) {
        return MerkleTree.proofFor(_leaves(), i);
    }

    function _memeCost(uint256 amount) internal pure returns (uint256) {
        return (amount * STRIKE) / 1e18;
    }

    function _unclaimed() internal view returns (uint256 total) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!consumed[i]) total += amounts[i];
        }
    }

    /// @dev CRITICAL **The core of the note.**,In reality. GME / Real MEME Up: the trust card will always hold.
    ///      All of them are still in the process. leaf.Every change of status is followed by a set of conditions.
    function _assertCustodyCoversUnclaimed() internal view {
        assertGe(
            call.balanceOf(address(distributor), seriesId),
            _unclaimed(),
            unicode"CRITICAL distributor Balance of certificates less than uncollected leaf And the sum of the shares that someone took from the share."
        );
    }

    //  Prefix: Both of the tokens on the fork are true.

    /// @dev Prove it before you run on the real deal.**It's a real contract to run.**.
    ///      Without this, all the green below may have been found at an empty address.
    function test_preconditions_bothTokensAreTheRealThing() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME There's no code on the address.");
        assertEq(FLAP_MEME.code.length, 45, unicode"Sample MEME I think so. EIP-1167 Mint Agent");
        assertEq(gme.balanceOf(address(pool)), MINTED, unicode"The collateral really went into the pool.");
        assertEq(
            call.balanceOf(address(distributor), seriesId),
            MINTED,
            unicode"The whole week's license is in the distributor Hands."
        );
        assertEq(_unclaimed(), MINTED, unicode"Three. leaf And the sum of the sum of the sum of the cast.");
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).paused(),
            unicode"The logs on the fork height should not be suspended -- otherwise the successful path under is not what it thinks."
        );
        assertFalse(
            IRobinhoodAccessRegistry(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).isBlocked(address(pool)),
            unicode"I'm not supposed to be sealed."
        );
    }

    //  Full path:approve + claimAndExercise,Two.

    /// @notice Acceptance and acceptance clauses:**User path is two (%1)approve + claimAndExercise)**,Run through the real mark.
    ///
    /// @dev Two "just equals" are the focus of this test, each one of which is one thing:
    ///      - `0xdead` Received == `memeAmount`  Flap The destruction path is not taxed on us;
    ///      - Beneficiaries received == `amount`  GME No transfer tax.raw The record is valid.
    ///
    ///      And one more path only:**The license never passed the beneficiary's hand.**  -  -
    ///      It's from distributor The shared balance is destroyed directly.
    function test_fullPath_claimAndExerciseOnRealTokens() public {
        address alice = accounts[0];
        uint256 amount = amounts[0];
        uint256 memeCost = _memeCost(amount);
        uint256 memeBefore = meme.balanceOf(alice);
        uint256 deadBefore = meme.balanceOf(DEAD);

        // I'm sorry. 1 The pen is in setUp Lee:alice - Put it on. MEME - Authority to**Clearinghouse**(No, it's not. distributor).
        // I'm sorry. 2 Pen:
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amount, _proof(0));
        consumed[0] = true;

        assertEq(call.balanceOf(alice, seriesId), 0, unicode"The license never passed the beneficiary's hand.");
        assertEq(call.balanceOf(address(distributor), seriesId), MINTED - amount, unicode"Destroy from shared balance");
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"Payers' money. MEME");
        assertEq(meme.balanceOf(DEAD) - deadBefore, memeCost, unicode"CRITICAL 0xdead The exact receipt is a transfer.");
        assertEq(
            gme.balanceOf(alice), amount, unicode"CRITICAL The beneficiary receives exactly the same amount of power."
        );
        assertEq(gme.balanceOf(address(pool)), MINTED - amount, unicode"I'm only so short of the pool.");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
        _assertCustodyCoversUnclaimed();

        console2.log(
            string.concat(
                unicode"  Right to merge lines ",
                vm.toString(amount),
                unicode" raw GME  Burn it. ",
                vm.toString(memeCost),
                unicode" raw MEME  0xdead Received ",
                vm.toString(meme.balanceOf(DEAD) - deadBefore)
            )
        );
    }

    //  CRITICAL Re-launch: Both directions must be rejected, while the goods of the unreceived must remain in place

    /// @notice Three articles of acceptance and acceptance, all of which are on the actual mark:
    ///         **Same. proof Second submission revert**;**`claim` After `claimAndExercise` Yes. revert,And vice versa.**;
    ///         **distributor The balance of the certificate of authority is never less than the total amount not received leaf The sum of the two.**.
    ///
    /// @dev The last few lines are the real conclusion of this test:carol I've done nothing since I was born.
    ///      And... alice and bob After trying over and over again, she's... 20 Quantum GME **A lot of them.**The land is still there.
    ///      And she can really turn it out.issue #13 The consequence of this is "Hand it in hand." proof The blogger says that the government is not in a position to exchange goods for the price of goods.
    ///      Here it is asserted to be the opposite of it.
    function test_replaysAreRejectedOnBothPathsAndTheUnclaimedHoldersGoodsSurvive() public {
        address alice = accounts[0];
        address bob = accounts[1];
        address carol = accounts[2];

        _assertCustodyCoversUnclaimed();

        // (1) alice Walk Merge Path
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));
        consumed[0] = true;
        _assertCustodyCoversUnclaimed();

        // (2) Same. proof Submit again - refused
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, alice));
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));
        _assertCustodyCoversUnclaimed();

        // (3) Another path to come -- it's also a negative.CRITICAL This is the attack: the license has been burned, and the police are not going to let me know.
        //    Again. claim The one who turned out was the other's.
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, alice));
        vm.prank(keeper);
        distributor.claim(seriesId, alice, amounts[0], _proof(0));
        _assertCustodyCoversUnclaimed();

        // 4 bob Path to recipient (inkeeper - We'll only have the right to file the certificate. bob)
        vm.prank(keeper);
        distributor.claim(seriesId, bob, amounts[1], _proof(1));
        consumed[1] = true;
        assertEq(call.balanceOf(bob, seriesId), amounts[1], unicode"The license's in. leaf Designated accounts");
        assertEq(call.balanceOf(keeper, seriesId), 0, unicode"I can't get one for the submitr.");
        _assertCustodyCoversUnclaimed();

        // 5 Rewind reverse: take the right to merge after taking it - it will be denied.
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, bob));
        vm.prank(bob);
        distributor.claimAndExercise(seriesId, bob, amounts[1], _proof(1));
        _assertCustodyCoversUnclaimed();

        // 6 CRITICAL Conclusionscarol Nothing, and her share is still there, and it is true that it is true.
        assertEq(
            call.balanceOf(address(distributor), seriesId),
            amounts[2],
            unicode"CRITICAL The balance of sharing just happens to be... carol The one."
        );

        _attest(carol);
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));
        consumed[2] = true;

        assertEq(
            gme.balanceOf(carol),
            amounts[2],
            unicode"CRITICAL The holder who never received it made a good deal of money."
        );
        assertEq(call.balanceOf(address(distributor), seriesId), 0, unicode"The whole week's license is just finished.");
        assertEq(_unclaimed(), 0, unicode"No outstanding leaf Yes.");
        assertEq(
            gme.balanceOf(address(pool)),
            amounts[1],
            unicode"The rest of the pool is just as good. bob The one with no right."
        );
    }

    //  Declares that the door is open to the beneficiary, not to the caller.

    /// @notice Acceptance and acceptance clauses:**Unsigned `account` Yes. distributor The same is true of the path.**
    ///
    /// @dev CRITICAL This is the observable consequence of the "declaration of the beneficiaries" of the right of access.distributor
    ///      And once you sign it, all users pass -- and it's when we promise to "conformity is not a disguised freeze switch"
    ///      The only thing that can be found is the door.**The structure doesn't kill anyone.**(No Variable 6(3)):carol I'll sign it myself.
    function test_theAttestationGateFollowsTheAccountThroughTheDistributorPath() public {
        address carol = accounts[2];

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, carol));
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));

        // Rolling back in the pen.  Hers. leaf I didn't get eaten by that failure.
        assertFalse(distributor.claimed(seriesId, carol), unicode"The rejected one didn't consume her. leaf");
        _assertCustodyCoversUnclaimed();

        _attest(carol);
        vm.prank(carol);
        distributor.claimAndExercise(seriesId, carol, amounts[2], _proof(2));
        consumed[2] = true;

        assertEq(gme.balanceOf(carol), amounts[2], unicode"After signing, we'll do as we please.");
        _assertCustodyCoversUnclaimed();
    }

    //  The right to merge is only personal.

    /// @notice Acceptance and acceptance clauses:**Not `account` Called by Me `claimAndExercise` Rejected.**
    ///
    /// @dev Every condition is set for "it's all in fact":alice Declared, filed MEME To the pool.proof It's true too.
    ///      The only person blocking this is the caller itself, the amount of the authorization, which means "I'm willing to pay for my rights."
    ///      I don't think it's "everyone can choose me"
    function test_onlyTheAccountMayCombineClaimAndExercise() public {
        address alice = accounts[0];
        uint256 memeBefore = meme.balanceOf(alice);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, keeper, alice));
        vm.prank(keeper);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        assertEq(meme.balanceOf(alice), memeBefore, unicode"One real. MEME She didn't get burned by anyone else.");
        assertEq(gme.balanceOf(alice), 0, unicode"And they didn't have to exchange it for stock.");
        assertFalse(distributor.claimed(seriesId, alice), unicode"leaf Not consumed");
        _assertCustodyCoversUnclaimed();

        // Presented on behalf of**Receipts**It was still allowed: it simply sent her the certificate that was hers.
        vm.prank(keeper);
        distributor.claim(seriesId, alice, amounts[0], _proof(0));
        consumed[0] = true;
        assertEq(call.balanceOf(alice, seriesId), amounts[0], unicode"Regular status of receipt submitted on behalf of");
        _assertCustodyCoversUnclaimed();
    }

    //  It's super-haired. root It stops on the spot, not steals people's share.

    /// @notice CRITICAL Attribution root It's under the chain, and the pool is made.**Actual arrival**The collateral's so much power.
    ///         It's not right.root If the sum exceeds the amount of the casting)**It's on the spot. ERC-1155 Check the balance.**,
    ///         Instead of giving away others' share first.
    ///
    /// @dev This one's not. issue #13 The acceptance clause, but it's the other side of the same line: the custody balance is not worth it. root The blog is also available.
    ///      The contract says "staggered," not "snatch-up." It also explains why the claim is written. `>=` Not `==`.
    function test_anOversizedRootStopsAtTheCustodyBoundary() public {
        uint256 fresh = vault.openSeries(address(meme), address(gme), expiry + 1 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), 10e18);

        address greedy = makeAddr("greedy");
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, greedy, 11e18); // More than you can make. 1 Quantum
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, address(distributor), 10e18, 11e18, fresh
            )
        );
        vm.prank(keeper);
        distributor.claim(fresh, greedy, 11e18, MerkleTree.proofFor(leaves, 0));

        // Three this week. leaf None of them have been passive.
        assertEq(call.balanceOf(address(distributor), seriesId), MINTED, unicode"The others are not being missed.");
        _assertCustodyCoversUnclaimed();
    }
}
