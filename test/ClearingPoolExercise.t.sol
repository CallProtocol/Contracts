// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken, NoOpMemeToken, ReentrantMemeToken, SenderPaysFeeMemeToken} from "./helpers/MemeToken.sol";
import {
    GatedStockToken,
    NoOpStockToken,
    ReentrantStockToken,
    SenderPaysFeeStockToken,
    StockToken
} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice One.**Contractual status**The right-holder. Both calls to the right give control to it.
///         So the beneficiary of the retest must be a contract, not a contract. EOA.
///
/// @dev It inherits. `ERC1155Holder` Hard demand: when a certificate of authority is cast to the recipient of the contract ERC-1155 Force Retrieval
///      `onERC1155Received` . Check the return value.`exercise` As it is. revert,
///      The reason for the failure is written down in the pendulum of the penthouse -- if you swallow it, "what is the reason for the rejection?"
contract ExerciseWallet is ERC1155Holder {
    function exercise(ClearingPool pool, uint256 seriesId, uint256 amount) external {
        pool.exercise(seriesId, amount, address(this));
    }
}

/// @notice **M1-5 Right path**(issue #10):Destruction MEME Swap stock coins, atoms complete.
///
/// This path is the way the product is delivered, and it's the only collateral.**Get out of the pool.**Place. Three things determine its shape:
///
/// - **Five doors, in order.**  -  -  Caller White List -> Series is open -> Unsolved -> Not yet. deadline -> (a) Declaration door;
///   CRITICAL The statement of the doorman is **`beneficiary`**,Not the caller, otherwise. distributor The alternative path will empty it out.
/// - **Three-step atoms.**  -  -  Destruction of the certificate of authority -> Destruction of beneficiaries MEME(To `0xdead`)-> (a) Stock tokens directly to beneficiaries;
///   The government has been unable to take any steps to get back to the city.**The user will not lose the license when the issuer freezes**;
/// - **The address of the destruction is `0xdead` No, it's not. `0x0`**  -  -  The latter is real. `FlapTaxTokenV3` I'm sure it's a good idea. revert.
///
/// The test drives the real four contracts.issue #5 The double is only on the outer-dependent level:
/// Treasury (%)M2 It's only there. It's stock coins.MEME.The real mark is in the right place. `test/fork/`.
contract ClearingPoolExerciseTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev CRITICAL **The word is in the test, not read. `pool.BURN_ADDRESS()`.** "and test itself with its own constant,
    ///      Nothing to prove... same. `ClearingPoolMinting.t.sol` Rey's a self-independent man. `seriesId` Justification.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        meme = new MemeToken();
        expiry = uint64(block.timestamp + 7 days);

        // I.D.'s registered with this one. MEME The vault... the one that opened the series... that tied it up, see? {FactoryStub}.
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        // Two things to prepare for the beneficiaries. 6.4 The steps the front end is going to lead the user to do.
        _attest(alice);
        _approveMeme(alice);
        meme.mint(alice, 1e31);
    }

    //  Scaffolding.

    function _attest(address who) internal {
        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);
    }

    function _approveMeme(address who) internal {
        vm.prank(who);
        meme.approve(address(pool), type(uint256).max);
    }

    /// @dev Open a series and cast the certificate. `to`.The vault double is the only self-building allowed for this milestone. mock(issue #5).
    function _openAndMint(address to, uint256 amount) internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, to, amount);
    }

    /// @dev Expectations MEME Amount destroyed,**Count it on your own.**:No contract transfer, no copying. `Math.mulDiv`.
    function _expectedMeme(uint256 amount, uint256 strike) internal pure returns (uint256) {
        return (amount * strike) / 1e18;
    }

    //  Successful Path

    /// @dev CRITICAL **The core of the note.**:Three things change at once and**Only three.**.
    ///      The certificate is missing from the holder,MEME From beneficiary's account to `0xdead`,Stock coins range from pool to beneficiary.
    function test_exercise_burnsCallBurnsMemeAndDeliversStock() public {
        uint256 amount = 100 ether;
        uint256 seriesId = _openAndMint(alice, amount);

        uint256 exerciseAmount = 40 ether;
        uint256 memeAmount = _expectedMeme(exerciseAmount, STRIKE);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Exercised(seriesId, alice, alice, exerciseAmount, memeAmount);
        vm.prank(alice);
        pool.exercise(seriesId, exerciseAmount, alice);

        assertEq(
            call.balanceOf(alice, seriesId), amount - exerciseAmount, unicode"Certificates destroyed by weight of right"
        );
        assertEq(meme.balanceOf(alice), memeBefore - memeAmount, unicode"Payers' money. MEME");
        assertEq(meme.balanceOf(DEAD), memeAmount, unicode"MEME Here we are. 0xdead");
        assertEq(stock.balanceOf(alice), exerciseAmount, unicode"Stock tokens directly to beneficiaries");
        assertEq(stock.balanceOf(address(pool)), amount - exerciseAmount, unicode"I'm only so short of the pool.");

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.exercised, exerciseAmount, "exercised");
        assertEq(s.minted, amount, unicode"minted It doesn't change by the right to do business.");
        assertEq(s.deposited, amount, unicode"deposited It doesn't change by the right to do business.");
    }

    /// @dev Acceptance and acceptance clauses:**The address of the destruction is `0xdead`,No, it's not. `0x0`.** We've got a real one. `0x0` In reality.
    ///      `FlapTaxTokenV3` Go, go, go! revert(`ERC20: transfer to the zero address`),
    ///      And it's not original. `burn()`  -  -  Transfer `0xdead` The only available destruction path.
    ///
    ///      And this is the same constant that's going to be exposed to the public: the bottom of the chain with the M2 Read it.
    function test_exercise_burnsToDeadAndNeverToTheZeroAddress() public {
        uint256 seriesId = _openAndMint(alice, 10 ether);

        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(meme.balanceOf(DEAD), _expectedMeme(10 ether, STRIKE), unicode"0xdead Copy that. MEME");
        assertEq(meme.balanceOf(address(0)), 0, unicode"There's no address.");
        assertEq(pool.BURN_ADDRESS(), DEAD, unicode"The public constant is... 0xdead");
    }

    /// @dev Some of these rights can be done many times, and the accounts are added up; the remaining weights remain homogeneous.
    function test_exercise_accumulatesAcrossPartialExercises() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.startPrank(alice);
        pool.exercise(seriesId, 30 ether, alice);
        pool.exercise(seriesId, 20 ether, alice);
        vm.stopPrank();

        assertEq(pool.series(seriesId).exercised, 50 ether, "exercised");
        assertEq(call.balanceOf(alice, seriesId), 50 ether, unicode"Balance of certificates");
        assertEq(stock.balanceOf(alice), 50 ether, unicode"Two shares of the coin.");
        assertEq(meme.balanceOf(DEAD), _expectedMeme(50 ether, STRIKE), unicode"It burned twice. MEME");
    }

    /// @dev Pricing formulae:`memeAmount = amount * strike / 1e18`,**Remove Down**.
    ///      Other Organiser 0 The one that must be rejected -- otherwise it's the same as taking shares in cash, see the next test.
    function testFuzz_exercise_memeCostIsAmountTimesStrikeOver1e18(uint128 amount, uint128 strike) public {
        amount = uint128(bound(amount, 1, 1e24));
        strike = uint128(bound(strike, 1, 1e24));

        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, strike);
        vault.depositAndMint(seriesId, alice, amount);

        uint256 expected = _expectedMeme(amount, strike);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.prank(alice);
        if (expected == 0) {
            vm.expectRevert(
                abi.encodeWithSelector(ClearingPool.ExerciseRoundsToZeroMeme.selector, seriesId, amount, strike)
            );
            pool.exercise(seriesId, amount, alice);
            assertEq(stock.balanceOf(alice), 0, unicode"Other Organiser 0 I can't take a single stock coin.");
            return;
        }

        pool.exercise(seriesId, amount, alice);
        assertEq(memeBefore - meme.balanceOf(alice), expected, unicode"Paying. MEME");
        assertEq(meme.balanceOf(DEAD), expected, unicode"Burned it. MEME");
        assertEq(stock.balanceOf(alice), amount, unicode"Share tokens received");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
    }

    /// @dev CRITICAL Remove Clock Down `amount * strike < 1e18` the right to exercise**One. MEME No need to burn.**.
    ///      That's exactly what I'm talking about. `openSeries` Lee. `strike != 0` The whole version of the thing to block, so the slot must be rejected.
    ///      The price of rejection is just "one bigger." `amount` -  - The next two lines also lock the back road.
    function test_exercise_rejectsDustThatRoundsToZeroMeme() public {
        uint128 strike = 1e17; // Every 1e18 raw Stock burning 0.1 MEME  Less than 10 raw The unit is in order. 0
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, strike);
        vault.depositAndMint(seriesId, alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExerciseRoundsToZeroMeme.selector, seriesId, 9, strike));
        pool.exercise(seriesId, 9, alice);

        // Worked as usual on the other side of the border: burning 1 wei MEME,Switch 10 wei Stock tokens.
        vm.prank(alice);
        pool.exercise(seriesId, 10, alice);
        assertEq(meme.balanceOf(DEAD), 1, unicode"The one that burns.");
        assertEq(stock.balanceOf(alice), 10, unicode"Share tokens received");
    }

    /// @dev Certificate**Transfer of complete freedom**(`Call` The design premise) does not require that the person exercising the right be the person who received the certificate of right initially.
    ///      Those who have obtained the certificate of authority**For yourself.**Right to work for the beneficiaries: declaration and MEME All on his head.
    function test_exercise_worksForWhoeverHoldsTheCall() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.prank(alice);
        call.safeTransferFrom(alice, bob, seriesId, 60 ether, "");

        _attest(bob);
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(bob);
        pool.exercise(seriesId, 60 ether, bob);

        assertEq(stock.balanceOf(bob), 60 ether, unicode"The transferee received the shares in tokens");
        assertEq(call.balanceOf(bob, seriesId), 0, unicode"His license is burned.");
        assertEq(call.balanceOf(alice, seriesId), 40 ether, unicode"The rest of the seller's share is not passive.");
        assertEq(pool.series(seriesId).exercised, 60 ether, "exercised");
    }

    //  Called white list: myself, or distributor

    /// @dev Acceptance and acceptance clauses:**Third party takes another person as its own beneficiary Call denied.**
    ///
    ///      CRITICAL This restriction is defensive, not formalist: the beneficiary gave it to the pool. MEME The mandate says:
    ///      I'd like to do it for you.**Your own.**"Everyone can choose me." So here's the plan.
    ///      The project is based on the following criteria:
    ///      The only thing blocking this is the caller itself.
    function test_exercise_rejectsThirdPartyCallers() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);
        _attest(carol); // The caller himself has declared it - not yet.

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotExerciseCaller.selector, seriesId, carol, alice));
        pool.exercise(seriesId, 10 ether, alice);

        // Not even the vault: it's paid for, but it's not the beneficiary himself, nor is it. distributor.
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotExerciseCaller.selector, seriesId, address(vault), alice)
        );
        vm.prank(address(vault));
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"Two attempts to get a single card.");
        assertEq(meme.balanceOf(DEAD), 0, unicode"And it didn't burn anything. MEME");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }

    /// @dev The other half of the white list:`distributor` In the name of the beneficiary. This is the right. `claimAndExercise`(issue #13)
    ///      On this side of the pool - the license from **distributor His own balance**The fire is burning.MEME From**Beneficiaries**The bank is pulled.
    ///      Stock tokens**Direct to beneficiaries**.
    ///
    ///      distributor The contract itself. #13 It's the only way to call the pool. That's why we use it here. `vm.prank` With its identity...
    ///      The pool cannot be divided between the two, and the test is to be nailed to the verdict on the side of the pool.
    function test_exercise_distributorMayExerciseForTheBeneficiary() public {
        uint256 amount = 100 ether;
        uint256 seriesId = _openAndMint(address(distributor), amount);
        uint256 memeAmount = _expectedMeme(30 ether, STRIKE);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Exercised(seriesId, address(distributor), alice, 30 ether, memeAmount);
        vm.prank(address(distributor));
        pool.exercise(seriesId, 30 ether, alice);

        assertEq(call.balanceOf(address(distributor), seriesId), 70 ether, unicode"Certificate from distributor Burn");
        assertEq(call.balanceOf(alice, seriesId), 0, unicode"The beneficiary never got a permit.");
        assertEq(meme.balanceOf(DEAD), memeAmount, unicode"MEME Burn it from the beneficiary's account.");
        assertEq(stock.balanceOf(alice), 30 ether, unicode"Stock tokens directly to beneficiaries");
    }

    //  Statement of the beneficiaries of the door check

    /// @dev Acceptance and acceptance clauses:**Unsigned beneficiary Rejected.**
    function test_exercise_requiresTheBeneficiaryToHaveAttested() public {
        uint256 seriesId = _openAndMint(bob, 100 ether);
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, bob));
        pool.exercise(seriesId, 10 ether, bob);

        // Door.**The structure doesn't kill anyone.**(No Variable 6(3)):It's over once, and no one's permission is required.
        _attest(bob);
        vm.prank(bob);
        pool.exercise(seriesId, 10 ether, bob);
        assertEq(stock.balanceOf(bob), 10 ether, unicode"After signing, just as you wish.");
    }

    /// @dev CRITICAL **This door check is `beneficiary`,No, it's not. `msg.sender`.** I'm not sure if I can get a chance to get a better picture.
    ///      The "who" thing is only half proven:
    ///
    ///      | Caller | Beneficiaries | Expectations |
    ///      |---|---|---|
    ///      | distributor((declared)) | Undeclared | **Reject**  -  -  Otherwise, the alternative will empty the door. |
    ///      | distributor((not declared) | Declared | **Pass.**  -  -  The door should not fall on the submitr. |
    function test_exercise_theAttestationGateFollowsTheBeneficiaryNotTheCaller() public {
        uint256 seriesId = _openAndMint(address(distributor), 100 ether);

        // (1) Caller signed, beneficiary not signed - must refuse
        _attest(address(distributor));
        _approveMeme(bob);
        meme.mint(bob, 1e30);

        vm.prank(address(distributor));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, bob));
        pool.exercise(seriesId, 10 ether, bob);

        // (2) Signed by the beneficiary (in thousands of United States dollars)distributor It doesn't matter if you sign or not.
        vm.prank(address(distributor));
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(
            stock.balanceOf(alice),
            10 ether,
            unicode"Beneficiaries have declared  The path of the generation is the same."
        );
    }

    //  Unsolved / Not yet. deadline

    /// @dev Third door in the acceptance clause. **`deadline` Yeah. `expiry`**
    ///      (How do you see the doorway moving it back? `ClearingPoolSettlement.t.sol`),
    ///      And the verdict is, `block.timestamp < deadline`  -  -  The second it's due.**Not anymore.**Right to exercise.
    ///
    ///      CRITICAL This border is not a matter of style:`settleExpired` The verdict is... `>= deadline`,
    ///      The two must be strictly complementary. A window "no rights, no settlements" will emerge in a second.
    function test_exercise_rejectsAtAndAfterTheDeadline() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        // One second before due: as usual
        vm.warp(expiry - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(stock.balanceOf(alice), 10 ether, unicode"Right to remain viable one second before expiry");

        // Other Organiser
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 10 ether, alice);

        // After: still rejected
        vm.warp(uint256(expiry) + 30 days);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry) + 30 days
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(
            call.balanceOf(alice, seriesId),
            90 ether,
            unicode"Expiry not to destroy the license, but it's not gonna work."
        );
    }

    /// @dev No Variable 4(1):**`settled  exercise() revert`**.
    ///
    ///      M1-6 There was a belt used here. `forceSettle` Subcategory of back door; now go**Real.**Clear path.
    ///      `stock` The two without the issuer's door. view,So the observations are down. fail-open The first one: `pokeGating`
    ///      I'm not sure if I'm going to be able to get a job.48 It's not over until the hour. `ClearingPoolSettlement.t.sol`).
    function test_exercise_rejectsSettledSeries() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"Precondition: Really settled.");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"One of the cards is still intact.");
        assertEq(meme.balanceOf(DEAD), 0, unicode"MEME One of them didn't burn.");
    }

    /// @dev CRITICAL Unopened Series**Remark**.`expiry == 0` That way. deadline The check will also block it...
    ///      But it's a coincidence, not a structure:deadline Now. `max(expiry, clearedAt + 48h)`,
    ///      The unopened series reads: `gating[address(0)]` That record, once it's on it, `clearedAt`,
    ///      deadline The inspection was first released.
    ///
    ///      The zero caller is measured together for the same reason. `depositAndMint`:`address(0)` The blogger says that the government is not a good source of information for the government.
    ///      And it's the one that can be seen. `msg.sender` location.
    function test_exercise_rejectsUnopenedSeries_includingAZeroAddressCaller() public {
        uint256 unopened = uint256(keccak256(abi.encode(address(meme), address(stock), expiry)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.exercise(unopened, 1 ether, alice);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.exercise(unopened, 1 ether, address(0));
    }

    /// @dev `amount` Yes. `uint256`,And on the books. `exercised` Yes. `uint128`  -  -  The amount that cannot be filled must be rejected.
    ///      And...**Before Multiplication**The blogger says that the government is not going to let the government take a stand.`amount  strike` It's the structure that's going to fit in. 256 Bit.
    ///
    ///      CRITICAL This one's nailed.**Grounds for refusal**.If you put it behind the multiplication, one. `2^128` I'll figure out one first.
    ///      Astrometric numbers. `memeAmount`,And then stop in MEME The balance is not enough - it's also... revert,
    ///      But the wrong one is "you." MEME The reason for this is that "this amount is not even recorded."
    function test_exercise_rejectsAmountsThatDoNotFitUint128() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        pool.exercise(seriesId, tooBig, alice);

        assertEq(pool.series(seriesId).exercised, 0, unicode"The accounts are not passive.");
        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"The license hasn't been passive.");
    }

    /// @dev The government has not been able to destroy the rights it does not have -- that is, the full realization of "the weight of the power of the trade cannot exceed the amount of the right not to do so."
    ///      I'm not going to repeat this. `exercise` And so here's the assertion that it really is. ERC-1155 Take a ride.
    function test_exercise_cannotBurnMoreCallsThanHeld() public {
        uint256 seriesId = _openAndMint(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 100 ether, 101 ether, seriesId
            )
        );
        pool.exercise(seriesId, 101 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, unicode"The accounts haven't been changed.");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"The collateral didn't go out.");
    }

    //  No Variable 3:Either substep failed  Certificates and MEME No change.

    /// @dev CRITICAL **Acceptance clause: All rolls are returned when the issuer freezes and the certificate is not lost.** It's the core commitment of the product to the user.
    ///      (issue #5 It's... User Story 2),And it's not a variable. 3 and the form of certainty.
    ///
    ///      Not to lose it, not just "not burned down" -- the license that was released was really working. The last three lines were about the latter.
    ///      Real GME (Registration form) `isBlocked` / Double `paused`)Yes.
    ///      `test/fork/RobinhoodExercise.t.sol` And so, here's the local failure injector.
    function test_exercise_isAtomicWhenTheIssuerFreezesTheStock() public {
        GatedStockToken gated = new GatedStockToken();
        gated.mint(address(vault), 1e24);
        vault.approve(gated, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(gated), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);

        uint256 memeBefore = meme.balanceOf(alice);
        gated.setFrozen(true);

        vm.prank(alice);
        vm.expectRevert(GatedStockToken.IssuerFrozen.selector);
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"I've lost one.");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME One of them didn't burn.");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead Nothing.");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(gated.balanceOf(address(pool)), 100 ether, unicode"The collateral's still in the pool.");

        // After the freeze, the certificate was really useful -- that's the whole meaning of "no loss."
        gated.setFrozen(false);
        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(gated.balanceOf(alice), 10 ether, unicode"After unfrozen, just as usual.");
    }

    /// @dev I'm sorry. 2 Two real manifestations of the failure: the lack of authorization of the beneficiaries and the insufficient balance of the beneficiaries.
    ///      Both.**Nothing happened.**  -  -  Especially the certificate of authority: it's in the first place. 1 The government has been able to destroy the entire country.
    ///      It's all roll back and bring it back.
    function test_exercise_isAtomicWhenTheMemePaymentFails() public {
        uint256 seriesId = _openAndMint(bob, 100 ether);
        _attest(bob);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);

        // (1) No authorization.
        meme.mint(bob, 1e30);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, memeAmount)
        );
        pool.exercise(seriesId, 10 ether, bob);
        assertEq(call.balanceOf(bob, seriesId), 100 ether, unicode"I'm not losing my license.");

        // (2) I've authorized it, but I don't have enough balance.
        _approveMeme(bob);
        // CRITICAL The balance is read to local variables:`vm.prank` It only works on the immediate next.**Next time.**The blogger says:
        //    Written `meme.transfer(carol, meme.balanceOf(bob))` If it were to be, `balanceOf` Eat.
        uint256 bobsMeme = meme.balanceOf(bob);
        vm.prank(bob);
        meme.transfer(carol, bobsMeme);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, memeAmount));
        pool.exercise(seriesId, 10 ether, bob);

        assertEq(call.balanceOf(bob, seriesId), 100 ether, unicode"The license is still in place.");
        assertEq(stock.balanceOf(bob), 0, unicode"And I didn't get the stock tokens in advance.");
        assertEq(pool.series(seriesId).exercised, 0, "exercised");
    }

    /// @dev ERC-20 It's... `true` Just to say no. revert,Doesn't mean the collateral really left the pool.
    ///      The test took place at the last step, so it was also necessary to prove the previous account, the destruction of the certificate and the destruction of the certificate. MEME The transfer is all rolling back.
    function test_exercise_revertsAtomicallyWhenStockReturnsTrueWithoutDebitingPool() public {
        NoOpStockToken noOpStock = new NoOpStockToken();
        noOpStock.mint(address(vault), 100 ether);
        vault.approve(noOpStock, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(noOpStock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = meme.balanceOf(alice);
        noOpStock.setNoOpTransfers(true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.StockTransferDebitMismatch.selector, seriesId, 10 ether, 100 ether, 100 ether
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"I've lost one.");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME One of them didn't burn.");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead Nothing.");
        assertEq(noOpStock.balanceOf(address(pool)), 100 ether, unicode"The Qin collateral is still intact.");
        assertEq(noOpStock.balanceOf(alice), 0, unicode"The beneficiary did not receive the stock in a vacuum.");
    }

    /// @dev Authentication onlyThe balance has changed.Still not enough: if the sender pays extra, the pool will be on the books. `exercised` Multiple collateral losses.
    function test_exercise_revertsAtomicallyWhenStockDebitsThePoolByMoreThanTheAmount() public {
        SenderPaysFeeStockToken senderPaysFeeStock = new SenderPaysFeeStockToken();
        senderPaysFeeStock.mint(address(vault), 100 ether);
        vault.approve(senderPaysFeeStock, type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(senderPaysFeeStock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = meme.balanceOf(alice);
        senderPaysFeeStock.setSenderFeeBps(1000);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.StockTransferDebitMismatch.selector, seriesId, 10 ether, 100 ether, 89 ether
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"I've lost one.");
        assertEq(meme.balanceOf(alice), memeBefore, unicode"MEME One of them didn't burn.");
        assertEq(meme.balanceOf(DEAD), 0, unicode"0xdead Nothing.");
        assertEq(senderPaysFeeStock.balanceOf(address(pool)), 100 ether, unicode"All over-deposited rolls back.");
        assertEq(senderPaysFeeStock.balanceOf(alice), 0, unicode"Stock deliveries are rolled back.");
        assertEq(senderPaysFeeStock.balanceOf(senderPaysFeeStock.TAX_SINK()), 0, unicode"Additional fees rolled back");
    }

    /// @dev `transferFrom` Back `true` It may also not be possible to withhold payments from beneficiaries; this cannot result in a zero cost to the user for the stock.
    function test_exercise_revertsAtomicallyWhenMemeReturnsTrueWithoutDebitingBeneficiary() public {
        NoOpMemeToken noOpMeme = new NoOpMemeToken();
        factory.bind(address(noOpMeme), address(vault));
        noOpMeme.mint(alice, 1e31);
        vm.prank(alice);
        noOpMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(noOpMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = noOpMeme.balanceOf(alice);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);
        noOpMeme.setNoOpTransfers(true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.MemeTransferDebitMismatch.selector, seriesId, memeAmount, memeBefore, memeBefore
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"I've lost one.");
        assertEq(noOpMeme.balanceOf(alice), memeBefore, unicode"Beneficiaries ' MEME Nothing.");
        assertEq(noOpMeme.balanceOf(DEAD), 0, unicode"0xdead Nothing.");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"The collateral is still in the pool.");
        assertEq(stock.balanceOf(alice), 0, unicode"The beneficiary took the stock without any cost.");
    }

    /// @dev beneficiary The result of the pricing formula must be paid; unlimited authorization cannot be a licence to double-deductible coins.
    function test_exercise_revertsAtomicallyWhenMemeDebitsBeneficiaryByMoreThanThePrice() public {
        SenderPaysFeeMemeToken senderPaysFeeMeme = new SenderPaysFeeMemeToken();
        factory.bind(address(senderPaysFeeMeme), address(vault));
        senderPaysFeeMeme.mint(alice, 1e31);
        vm.prank(alice);
        senderPaysFeeMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(senderPaysFeeMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 100 ether);
        uint256 memeBefore = senderPaysFeeMeme.balanceOf(alice);
        uint256 memeAmount = _expectedMeme(10 ether, STRIKE);
        uint256 senderFee = memeAmount / 10;
        senderPaysFeeMeme.setSenderFeeBps(1000);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.MemeTransferDebitMismatch.selector,
                seriesId,
                memeAmount,
                memeBefore,
                memeBefore - memeAmount - senderFee
            )
        );
        pool.exercise(seriesId, 10 ether, alice);

        assertEq(pool.series(seriesId).exercised, 0, "exercised");
        assertEq(call.balanceOf(alice, seriesId), 100 ether, unicode"I've lost one.");
        assertEq(
            senderPaysFeeMeme.balanceOf(alice), memeBefore, unicode"Over. MEME All the deductions are rolled back."
        );
        assertEq(senderPaysFeeMeme.balanceOf(DEAD), 0, unicode"0xdead Nothing.");
        assertEq(senderPaysFeeMeme.balanceOf(senderPaysFeeMeme.TAX_SINK()), 0, unicode"Additional fees rolled back");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"The collateral is still in the pool.");
        assertEq(stock.balanceOf(alice), 0, unicode"Stock deliveries are rolled back.");
    }

    //  Re-in.

    /// @dev CRITICAL Right of attorney. Give me control.**Twice.**,This is the first test. 3 The one time that step (stock tokens transferred to the beneficiary).
    ///      The beneficiary is a contract and it is.**Legitimate Caller**(So the internal calls go through the white list,
    ///      Through the declaration door, through all five doors. It's all that's left to block. `nonReentrant`,That is the assertion.
    function test_exercise_isNotReentrantThroughTheStockTransfer() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        ExerciseWallet wallet = new ExerciseWallet();

        reentrant.mint(address(vault), 1e24);
        vault.approve(reentrant, type(uint256).max);
        _attest(address(wallet));
        meme.mint(address(wallet), 1e30);
        vm.prank(address(wallet));
        meme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(meme), address(reentrant), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(wallet), 100 ether);

        // The deposit is not loaded until the call is returned: the deposit itself will pass. `_update`,That was not the test of this article.
        reentrant.armReentrancy(address(wallet), abi.encodeCall(ExerciseWallet.exercise, (pool, seriesId, 10 ether)));

        wallet.exercise(pool, seriesId, 40 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"Precondition: Reconverting is actually in.");
        assertFalse(reentrant.reentrySucceeded(), unicode"The inner circle must be denied.");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the refusal was re-entry, not white lists or declarations."
        );

        assertEq(call.balanceOf(address(wallet), seriesId), 60 ether, unicode"Only one time on the outside.");
        assertEq(reentrant.balanceOf(address(wallet)), 40 ether, unicode"The stock tokens only go out once.");
        assertEq(meme.balanceOf(DEAD), _expectedMeme(40 ether, STRIKE), unicode"MEME Only one burn.");
        assertEq(pool.series(seriesId).exercised, 40 ether, "exercised");
    }

    /// @dev I'm sorry. 2 Step (Destroyed beneficiaries ' MEME)That's the one. It's worse than the last one: the proof of right now.**Destroyed**,
    ///      Stock tokens**It's not moving out yet.**,The pool is at the worst moment of the entire path.
    function test_exercise_isNotReentrantThroughTheMemeTransfer() public {
        ReentrantMemeToken reentrantMeme = new ReentrantMemeToken();
        factory.bind(address(reentrantMeme), address(vault));
        ExerciseWallet wallet = new ExerciseWallet();

        reentrantMeme.mint(address(wallet), 1e30);
        _attest(address(wallet));
        vm.prank(address(wallet));
        reentrantMeme.approve(address(pool), type(uint256).max);

        uint256 seriesId = vault.openSeries(address(reentrantMeme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(wallet), 100 ether);

        reentrantMeme.armReentrancy(
            address(wallet), abi.encodeCall(ExerciseWallet.exercise, (pool, seriesId, 10 ether))
        );

        wallet.exercise(pool, seriesId, 40 ether);

        assertGt(reentrantMeme.reentryAttempts(), 0, unicode"Precondition: Reconverting is actually in.");
        assertFalse(reentrantMeme.reentrySucceeded(), unicode"The inner circle must be denied.");
        assertEq(
            reentrantMeme.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the rejection was re-entry."
        );

        assertEq(call.balanceOf(address(wallet), seriesId), 60 ether, unicode"Only one time on the outside.");
        assertEq(stock.balanceOf(address(wallet)), 40 ether, unicode"The stock tokens only go out once.");
        assertEq(reentrantMeme.balanceOf(DEAD), _expectedMeme(40 ether, STRIKE), unicode"MEME Only one burn.");
        assertEq(pool.series(seriesId).exercised, 40 ether, "exercised");
    }

    //  Taxes MEME:A deliberate trade-off.

    /// @dev I'm a pool.**Do not check** `0xdead` Increased balance (opposed and justified only in `src/ClearingPool.sol` It's...
    ///      `exercise` Go. This test nails it.**Observable consequences**:Taxes MEME Down**We're doing the same thing.**,
    ///      The beneficiary was taken in full. `memeAmount`,And... `0xdead` One less receipt.
    ///      Real Flap "The collection is exactly the transfer" by `test/fork/RobinhoodFlapBurn.t.sol` Review.
    function test_exercise_succeedsEvenIfTheMemeTaxesTheBurnPath() public {
        meme.setTaxBps(300); // 3%,and Flap The default sales tax is the same.
        uint256 seriesId = _openAndMint(alice, 100 ether);

        uint256 memeAmount = _expectedMeme(40 ether, STRIKE);
        uint256 memeBefore = meme.balanceOf(alice);

        vm.prank(alice);
        pool.exercise(seriesId, 40 ether, alice);

        assertEq(
            memeBefore - meme.balanceOf(alice),
            memeAmount,
            unicode"The beneficiary pays for the whole thing. memeAmount"
        );
        assertEq(meme.balanceOf(DEAD), memeAmount - (memeAmount * 300) / 10_000, unicode"0xdead We're missing a few.");
        assertEq(meme.balanceOf(meme.TAX_SINK()), (memeAmount * 300) / 10_000, unicode"The difference is in the tax.");
        assertEq(stock.balanceOf(alice), 40 ether, unicode"Stock tokens are delivered as usual");
    }

    /// @dev The other half of the symmetry:**Stock currency tax**And then the pool was taken away. `amount`,The beneficiaries are less likely to arrive.
    ///      And here, too, there's no push-over -- the pool doesn't even have to assume how much it should be.`openSeries` No permission.
    ///      The collateral is given outside, and hand-to-hand inverse turnover makes every right a search.
    ///
    ///      Real GME No tax (%)`test/fork/RobinhoodExercise.t.sol` The government has been able to provide the necessary information to the government and the government.
    ///      So this nail is...**If it wasn't,**"The behaviour of the child: by `amount` Note, collateral press `amount` Out of the pool.
    ///      **The compensation coverage is intact**,The cost falls on the number that the user sees.
    function test_exercise_withATaxedStockDebitsThePoolByTheFullAmount() public {
        stock.setTaxBps(300);
        uint256 seriesId = _openAndMint(alice, 1000 ether);

        uint256 minted = call.balanceOf(alice, seriesId);
        assertEq(minted, 970 ether, unicode"Prefix: Deposit side by account to cast");

        vm.prank(alice);
        pool.exercise(seriesId, 100 ether, alice);

        assertEq(stock.balanceOf(address(pool)), minted - 100 ether, unicode"The pool was taken completely. amount");
        assertEq(
            stock.balanceOf(alice),
            97 ether,
            unicode"The beneficiary's missing a bit of the money... the tax-eating one. 3%"
        );
        assertEq(pool.series(seriesId).exercised, 100 ether, unicode"Press amount Remember");
        assertLe(
            minted - pool.series(seriesId).exercised,
            stock.balanceOf(address(pool)),
            unicode"No Variable 1:The rest of the permits are still being held up by the pool balance."
        );
    }
}
