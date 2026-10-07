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
import {MemeToken} from "../helpers/MemeToken.sol";
import {GatedStockToken, StockToken} from "../helpers/StockToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {CollateralCheck} from "./Invariant1And2MintingPath.t.sol";

interface IExerciseStockToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function frozen() external view returns (bool);
    function setFrozen(bool frozen_) external;
}

/// @notice **It's only for counter-proven detectors.**
///
/// CRITICAL Yes. EVM The atomicity is...**Default**One call is either valid or rolling back. So the "right to atom" thing.
/// There's only one shape that can be written... **Take a little bit of failure.**(`try/catch`,or ignores the returned values for lower-level transfers.
/// This is the shape of the back door: the license plate burned,MEME Burning, and the failure of the stock tokens is not a chance.
///
/// The results obtained by the users are:**Paying for it, burning the cards, not receiving anything.**.That's exactly what's not variable. 3 That's something to ban.
///
/// @dev The back door.**Another function**,Not producing. `exercise` Replace with `virtual`  -  -  issue #5 The test disciplinary ban.
///      You can't get a hook in the production code for mediocre.
///      `test/ClearingPool.t.sol::test_writeSurface_isExactlySixFunctions` Enumeration ABI Prove it.
///
///      WARNING The price is it.**rewrited it three times.**(This is usually repeated by verbal abuse in this warehouse.
///      It can't hide from it here: the failure of the child's steps is**Internal function**It's swallowed. From the outside. `try/catch` Yes.
///      The whole pen (and the destruction of the call) rolls back together, and there is no such thing as a false testimony.
///      CRITICAL The risk of repetition is therefore covered by the assertion:`test_theDetectorDetects_aSwallowedStockTransfer`
///      Directly.**Every leg.**And the balance, not just the "calculator goes off" -- the pricing line is really drifting, the test will be red.
contract NonAtomicPool is ClearingPool {
    /// @notice The last time the shares were swallowed was successful in the transfer. The only reason they were kept was to read the counter-proofs to understand what they were measuring.
    bool public lastStockTransferOk;

    constructor(ICall call_, address distributor_, IAttestationRegistry attestations_, IVaultRegistry vaultRegistry_)
        ClearingPool(call_, distributor_, attestations_, vaultRegistry_)
    {}

    function exerciseSwallowingStockFailure(uint256 seriesId, uint256 amount, address beneficiary) external {
        Series storage s = _series[seriesId];
        uint256 memeAmount = (amount * s.strike) / 1e18;

        s.exercised += uint128(amount);
        call.burn(msg.sender, seriesId, amount);
        IERC20(s.memeToken).transferFrom(beneficiary, BURN_ADDRESS, memeAmount);

        (lastStockTransferOk,) =
            s.stockToken.call(abi.encodeWithSelector(IERC20.transfer.selector, beneficiary, amount));
    }
}

/// @notice It's only for proving that the successful side detector will not be blown up by a "reverse change in balance" at a time. fuzzer It's swallowed. revert.
/// @dev When the switch was turned on, the pool was still pressed. `amount` Discharged, but the existing balance of the beneficiaries decreased. 1 wei.
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

/// @notice The one driving the right path handler.
///
/// CRITICAL **Nothing in this contract. revert**(A trade-off with two other non-variant files: the non-variant runs in
/// `fail_on_revert = false` I'm not sure if you're going to be able to do this.handler - Yes. `assertEq` Losing is one. revert,I'm gonna get it. fuzzer Swallow it.
///  -  -  The claim is written, so it's a violation.**Recording counters**,By `invariant_*` Go and say zero.
///
/// The universe is designed to be small: a stock coin, a stock coin. MEME,Three beneficiaries, two expiry.Here.
/// (1) The right to succeed is to be hit in a massive way. 0The claim is empty;
/// (2) Each type of failure - white lists, declaration doors, expired, insufficient balances, freezers - also hits.
///
/// WARNING (1) Yes.**I'm not trying to measure it.**:Each of the "legitimate" extracts below is adjusted to the counter.
/// First edition round 64 Step down. **0 Right to a successful alternative**  -  -  Three claims are green, but nothing is checked. Three reasons, one by one, are fixed.
/// In their respective notes:fuzzer Yeah. 0 The preference is to turn the "unknown caller" into a normal,`warp` The steps are so big that they're all over the wheel.
/// The weight of the line is not contained in the hold, causing almost all of it to crash. ERC-1155 - The balance check on.
/// After the transfer, every round of stability falls. 1-3 Sub-senior Right to Success (S)`--fuzz-seed 1 / 7 / 99` I've been doing this.
/// 256 The wheel is hundreds of times... CI Tranche (Class)1000 Wheel  128 (Step) Double it again.
/// CRITICAL Each successful path itself is still from below. `test_handlerReachesTheSuccessPathsAndTheRejections` I'm sure it's nailed.
/// Shit. fuzz Lucky.
contract ExerciseHandler is CommonBase, StdUtils {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    struct ExerciseSnapshot {
        uint256 callBalance;
        uint256 beneficiaryMemeBalance;
        uint256 deadMemeBalance;
        uint256 poolStockBalance;
        uint256 beneficiaryStockBalance;
        uint256 exercised;
    }

    ClearingPool public immutable pool;
    Call public immutable call;
    AttestationRegistry public immutable registry;
    address public immutable distributor;

    VaultStub public immutable vault;
    IExerciseStockToken public immutable stock;
    MemeToken public immutable meme;

    /// @dev Beneficiaries.`actors[2]` **I've been keeping my word.**,Until `attest` Move it over the door...
    ///      The two routes of "right to freedom after declaration" and "right to freedom after declaration" are therefore covered.
    address[3] public actors;
    uint64[2] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice No Variable 3(Failed side: once**Failed**The right to move changes any balance or number of accounts. 0.
    uint256 public atomicityViolations;
    /// @notice No Variable 3(Success side: Once**Success**The right to move, the three things are not together, and the number of times they change. 0.
    uint256 public consistencyViolations;

    /// @dev Overlay Count - Three claims are all "some of the counts are " 0,A man who didn't do anything. handler Same satisfaction.
    uint256 public successfulExercises;
    uint256 public rejectedExercises;
    /// @notice Of which, the issuer freezes (No. 3 The number of times you are rejected. The product commitment falls on that number.
    uint256 public rejectedWhileFrozen;
    uint256 public successfulDeposits;

    /// @dev Counter-certification connection: Yes true Time to go. {NonAtomicPool} Back door.**Real Run-A-Turn false.**
    bool public immutable sabotage;

    constructor(
        ClearingPool pool_,
        Call call_,
        AttestationRegistry registry_,
        address distributor_,
        FactoryStub factory_,
        bool sabotage_,
        bool reverseStockBalance_
    ) {
        pool = pool_;
        call = call_;
        registry = registry_;
        distributor = distributor_;
        sabotage = sabotage_;

        vault = new VaultStub(pool_);
        stock = reverseStockBalance_
            ? IExerciseStockToken(address(new ReverseBalanceStockToken()))
            : IExerciseStockToken(address(new GatedStockToken()));
        meme = new MemeToken();

        // I.D.'s registered with this one. MEME The vault -- the door that opened the series, it was this binding.M2-5 / #37).
        factory_.bind(address(meme), address(vault));

        // CRITICAL It's a long, close one, and it's a long one.**Make sure the whole wheel is alive.**(The next round is half the series expired.
        //    The road to success was never hit again, and three claims were made when nothing happened.
        //    The nearest one will be. `warp` Override, overwhelm "over" deadlineThat's a rejection.
        //    Far in line. 0,Because... fuzzer Yeah. 0 There's a strong preference - see `exercise` The note to the same thing.
        expiries = [uint64(block.timestamp + 400 days), uint64(block.timestamp + 30 days)];
        actors = [makeAddrLike("holder A"), makeAddrLike("holder B"), makeAddrLike("holder C")];

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        for (uint256 i = 0; i < actors.length; i++) {
            meme.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            meme.approve(address(pool_), type(uint256).max);
            // actors[2] Keep the no-declaration.
            if (i < 2) {
                vm.prank(actors[i]);
                registry_.attest(0, TERMS_0, ATTESTATION_0);
            }
        }
        // distributor He also holds a license (which is cast throughout the week of the real path), and**Never**Declaration  -
        // "The door-check beneficiary does not check the caller." fuzz It's alive too.
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
        // Do Not Remove Down 0:Other Organiser**View**,Its borders (zero deposits, taxes,uint128 (Excess, re-in)
        // By `Invariant1And2MintingPath.t.sol` Responsible. All we want is "the real right hand to burn."
        amount = bound(amount, 1e15, 1e24);

        (bool ok,) =
            address(vault).call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, _receiver(receiverSeed), amount)));
        if (ok) successfulDeposits++;
    }

    /// @dev The main character of this document. Callers and row weights**Diverse**The law is not to be allowed to run down a single successful line of business.
    ///      And the three claims are true when nothing happens. Both are measured, not guessed.
    ///
    /// @param clampToHeld Plug in line weight to caller**Really?**Within the amount. Almost every one of them.
    ///                    ERC-1155 (actual: round) 0 The path unit test is covered.
    function exercise(uint256 seriesSeed, uint256 callerSeed, uint256 beneficiarySeed, uint256 amount, bool clampToHeld)
        external
    {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address beneficiary = _receiver(beneficiarySeed);

        // CRITICAL **Other Organiser 0 Go on.** fuzzer Yeah. 0 There's a big preference for putting the "unknown caller" in the `% 4 == 0` Go, go, go, go!
        //    Most of the right to move in the round will stop at the first door -- as we know. 11 - I'm not gonna let you go. 5 Once it's done, and it's done. 0 - Second.
        //    distributor The one on the launch was kept: the holder on the path was not the same address as the beneficiary.
        address caller = beneficiary;
        if (callerSeed % 4 == 2) caller = distributor;
        if (callerSeed % 4 == 3) caller = makeAddrLike("stranger");

        uint256 held = call.balanceOf(caller, seriesId);
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
        // CRITICAL Three things must be**Together.**,**By Volume**Change. As with the "Burn the license without getting the goods" you can slip away.
        if (!_isConsistentExercise(before, afterwards, amount, memeAmount)) consistencyViolations++;
    }

    /// @dev Certificate**Transfer of freedom**It is a product prerequisite, so the holder and the beneficiary can be different from the same person.
    function transferCall(uint256 seriesSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address from = _receiver(fromSeed);
        amount = bound(amount, 0, call.balanceOf(from, seriesId));

        vm.prank(from);
        address(call).call(abi.encodeCall(call.safeTransferFrom, (from, _receiver(toSeed), seriesId, amount, "")));
    }

    /// @dev Issuer Freeze / Unfrozen.**I'm sorry. 3 Step failure**This path depends on it -- and that's the scene of product commitment.
    ///
    ///      WARNING Only 1/4 Call it will freeze it, and...**I didn't put it in the bag. `% 4 == 0` Go, go, go!**(fuzzer Prejudice 0):
    ///      The only way to get a half-turned is to keep the money in the whole round, so the "right to succeed" is almost impossible to hit.
    ///      And the three claims were valid when nothing happened. 0 The second successful deposit.
    ///      Freezing to stay in the cover, but it is.**Occasional events**,Not normal.
    function toggleIssuerFreeze(uint256 seed) external {
        stock.setFrozen(seed % 4 == 1);
    }

    /// @dev The declaration door is...**Undo**It is possible to sign the address without a statement once and never again.
    function attest(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        vm.prank(who);
        address(registry).call(abi.encodeCall(AttestationRegistry.attest, (0, TERMS_0, ATTESTATION_0)));
    }

    /// @dev Time is the dimension: passing through. `expiry` Then the right to move must be denied, and...**The license shouldn't have disappeared.**.
    ///
    ///      The steps are right. `expiries` Transferred: round 64 I'm hoping there's a date. 9 Number of times warp,Mean 3.5 Oh, my God.  One round to cross.
    ///      About 30 Oh, my God. It just fell on two. expiry Between. The steps are bigger, the whole wheel starts out, and the path of success is not hit at all.
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    //  Records

    function _snapshot(uint256 seriesId, address holder, address beneficiary)
        private
        view
        returns (ExerciseSnapshot memory snap)
    {
        snap.callBalance = call.balanceOf(holder, seriesId);
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
        return before.callBalance == afterwards.callBalance
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
        return _decreasedBy(before.callBalance, afterwards.callBalance, amount)
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

    /// @dev Recipients / Beneficiary range: three actor Add distributor In itself.
    function _receiver(uint256 seed) private view returns (address) {
        uint256 i = seed % 4;
        return i == 3 ? distributor : actors[i];
    }

    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **No Variable 3  -  -  Right atomity.**
///
/// | Paragraph | The assertion. |
/// |---|---|
/// | Failed side | Either substep failed  Certificates and MEME The balance remains unchanged (the same applies to accounts and collateral) |
/// | Success Side | Right to the right to succeed  the certificate of authority,MEME,Stock tokens**Together.**Volume change |
///
/// CRITICAL **One side is not necessary.** If you write about failure, "Swallow the failure of the stock token" will pass in a big swing.
/// That's when I called.**No, I'm not.**Failure, the user paid, burned the license, didn't get anything. That's exactly what this non-variant really wanted to ban.
/// That thing.`docs/spec.md`:The user does not lose the license when the issuer freezes).
///
/// Run it by the side. No variables. 1 The only thing that makes the mortgage is the right to practice.**Get out of the pool.**The path, it can't break the pay cover.
/// It's on the... `Invariant1And2MintingPath.t.sol` The same one. `CollateralCheck`  -  -  The two have written the verdicts in each and every one of them.
/// The blogger says that the government is not going to allow the government to verify the situation.
contract Invariant3ExerciseAtomicityTest is Test {
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    ExerciseHandler internal handler;

    function setUp() public {
        (pool, call, distributor, registry, factory) = _deploySystem(false);
        handler = new ExerciseHandler(pool, call, registry, address(distributor), factory, false, false);

        targetContract(address(handler));
    }

    /// @dev Deployment of real four contracts and completion of two bindings (in the case of the United States of America)issue #5 The test stitches.
    ///      `nonAtomic = true` And then you switch the pool to the one with the back door -- only counter-proof.
    function _deploySystem(bool nonAtomic)
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
        pool_ = nonAtomic
            ? ClearingPool(address(new NonAtomicPool(call_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(call_, address(distributor_), registry_, factory_.registry());
        call_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    //  No Variable 3

    /// @notice The power to fail has changed nothing.
    ///
    /// @dev WARNING To be honest, this counter is working today.**It's structurally impossible.**- It's ringing. EVM Rolling back is rolling back.
    ///      There are two reasons for keeping it: it makes "nothing changes after failure" one.**I'm gonna do it.**(a) the inspection, rather than an comment;
    ///      And when you move to a lower level and forget to check the return value, it is the first red spot.
    ///      The real counter-argument is the one that goes down.
    function invariant_3a_aFailedExerciseChangesNothing() public view {
        assertEq(
            handler.atomicityViolations(),
            0,
            unicode"No Variable 3:A failed right to move changes in balances or accounts"
        );
    }

    /// @notice The right to succeed, three things together, in volume.
    function invariant_3b_aSuccessfulExerciseMovesAllThreeLegs() public view {
        assertEq(
            handler.consistencyViolations(),
            0,
            unicode"No Variable 3:The power of power has succeeded, but the certificate of authority. / MEME / The stock tokens didn't change at volume."
        );
    }

    /// @notice The right to a mortgage is the only way out of the pool -- it can't break the pay cover.
    function invariant_1_collateralisationSurvivesExercise() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(
            perSeries, 0, unicode"No Variable 1(1):After the bill of sale, a series of claims exceeded its collateral."
        );
        assertEq(
            global,
            0,
            unicode"No Variable 1(2):The balance of the pool after the right to sell is not enough to cover the entire claim."
        );
    }

    //  Counterar: Two of the above are not empty.

    // handler . They press `% 4` The sub-segment. Changed. handler We have to change here.
    // If you write the numbers, you can split them up.**As usual, green.**,Just stop measuring what they claim to be measuring.
    uint256 internal constant CALLER_IS_BENEFICIARY = 0;
    uint256 internal constant CALLER_IS_DISTRIBUTOR = 2;
    uint256 internal constant CALLER_IS_STRANGER = 3;
    uint256 internal constant BENEFICIARY_ATTESTED = 0; // actors[0]
    uint256 internal constant BENEFICIARY_UNATTESTED = 2; // actors[2]
    uint256 internal constant FREEZE = 1;
    uint256 internal constant UNFREEZE = 0;

    /// @dev All three claims are "some of the numbers" 0,And one.**Nothing.**It's... handler Same satisfaction.
    ///      Here, it is conclusively demonstrated that the path of success and each type of rejection actually works.
    function test_handlerReachesTheSuccessPathsAndTheRejections() public {
        handler.openSeries(0, 1e18);
        handler.depositAndMint(0, 0, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler It's not gonna fit in.");

        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);
        assertEq(handler.successfulExercises(), 1, unicode"handler It's not working.");
        assertEq(handler.consistencyViolations(), 0, unicode"Three legs on the path to success.");

        // distributor On behalf of the author: the holder and the beneficiary are not the same address (the certificate is in force) actors[0] I'm gonna get this one.
        // ERC-1155 The balance check was rejected -- this is what you want.**Branch** To be taken, not to be successful
        handler.exercise(0, CALLER_IS_DISTRIBUTOR, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 1, unicode"distributor \"The branch was not taken.\"");

        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_UNATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 2, unicode"\"No statement.\" This path was not hit.");

        handler.exercise(0, CALLER_IS_STRANGER, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 3, unicode"\"The third party called.\"");

        // CRITICAL The issuer freezes - product commitments fall on this one.
        handler.toggleIssuerFreeze(FREEZE);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedWhileFrozen(), 1, unicode"The distribution freezer's path was not hit.");
        assertEq(handler.atomicityViolations(), 0, unicode"And it hasn't changed anything.");

        // Expiry - Pushed directly to `expiry` The verdict is... `block.timestamp < deadline`
        handler.toggleIssuerFreeze(UNFREEZE);
        handler.warp(1 days);
        vm.warp(handler.expiries(0));
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 1 ether, false);
        assertEq(handler.rejectedExercises(), 5, unicode"It's over. deadlineThis path didn't get hit.");
        assertEq(handler.atomicityViolations(), 0, unicode"The expired one is the same as the last one.");
    }

    /// @dev CRITICAL Detector back: Put "D" 3 The second door is loaded into a pool.
    ///      The user paid. MEME,Burning the license, taking stock in one currency - count the success side must be counted.**It was on the spot.**.
    ///
    ///      Without this,`invariant_3b` It's possible that the verdict itself is wrong.** Always for real **  -  -
    ///      That's the worst way to fail: it's still green, but it doesn't check anything.
    function test_theDetectorDetects_aSwallowedStockTransfer() public {
        (
            ClearingPool bad,
            Call badCall,
            MerkleDistributor badDistributor,
            AttestationRegistry badRegistry,
            FactoryStub badFactory
        ) = _deploySystem(true);
        ExerciseHandler h =
            new ExerciseHandler(bad, badCall, badRegistry, address(badDistributor), badFactory, true, false);

        h.openSeries(0, 1e18);
        h.depositAndMint(0, 0, 100 ether);
        h.toggleIssuerFreeze(FREEZE); // I'm sorry. 3 And it will never be possible.

        address holder = h.actors(0);
        uint256 seriesId = h.openedSeries(0);
        uint256 memeBefore = h.meme().balanceOf(holder);

        h.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(h.successfulExercises(), 1, unicode"Precondition: The back door did \"success\" once.");
        assertFalse(
            NonAtomicPool(address(bad)).lastStockTransferOk(), unicode"Prefix: The stock tokens were a real failure."
        );

        // CRITICAL Directly.**Every leg.**,Not just the counter-proofing machine. The probe caught it.
        //    The first two legs moved, the third one didn't move."**Specific**Shape - The rear door is rewritten three steps (with the price line).
        //    The counter is still green, but it proves that it is another thing.
        assertEq(h.call().balanceOf(holder, seriesId), 90 ether, unicode"I'm sorry. 1 Leg: The license was burned.");
        assertEq(
            memeBefore - h.meme().balanceOf(holder),
            10 ether,
            unicode"I'm sorry. 2 Legs:MEME They're really taking it away."
        );
        assertEq(h.stock().balanceOf(holder), 0, unicode"CRITICAL I'm sorry. 3 The leg's still on.");

        assertGt(h.consistencyViolations(), 0, unicode"The probe on the successful side didn't ring.");
    }

    /// @dev Reverse changes must be recorded as violations, not allowed. checked subtraction panic And then it was... fuzzer Swallow.
    function test_theDetectorCountsAReverseBalanceInsteadOfReverting() public {
        // CRITICAL Use**The pool.**Root of identity: new handler You'll create yourself. MEME Just register with the vault and just put it on the same roster.
        //    (One. MEME Only once you're registered, and this is just new. registry It's not going to work.
        //    The pool. authenticator Yes. `immutable`,It only recognizes the share when it is deployed.
        ExerciseHandler h = new ExerciseHandler(pool, call, registry, address(distributor), factory, false, true);
        ReverseBalanceStockToken reverseStock = ReverseBalanceStockToken(address(h.stock()));

        h.openSeries(0, 1e18);
        h.depositAndMint(0, 0, 100 ether);

        address holder = h.actors(0);
        reverseStock.mint(holder, 1 wei);
        reverseStock.setReverseTransfers(true);

        h.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(
            reverseStock.balanceOf(holder),
            0,
            unicode"Prefix: The beneficiary ' s stock balance has indeed declined in reverse"
        );
        assertEq(h.successfulExercises(), 1, unicode"Backdoor rights should be successfully returned.");
        assertGt(
            h.consistencyViolations(), 0, unicode"The reverse balance was not recorded by the successful side detector."
        );
    }

    /// @dev The other half of the probe counter-proof: the verdict must be**Real**The pool gives zero irregularities.
    ///      Otherwise, the last one proves that it's always ringing.
    function test_theDetectorIsSilentOnTheRealPool() public {
        handler.openSeries(0, 1e18);
        handler.depositAndMint(0, 0, 100 ether);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        // Same freeze. Go real. `exercise`:This time, the whole rolls back, nothing changes.
        handler.toggleIssuerFreeze(FREEZE);
        handler.exercise(0, CALLER_IS_BENEFICIARY, BENEFICIARY_ATTESTED, 10 ether, false);

        assertEq(handler.consistencyViolations(), 0, unicode"The real pool doesn't sound like a good side.");
        assertEq(handler.atomicityViolations(), 0, unicode"The real pool doesn't have to be on the wrong side.");
        assertEq(handler.rejectedWhileFrozen(), 1, unicode"Precondition: The freeze was actually rejected.");
    }
}
