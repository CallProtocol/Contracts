// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {
    IssuerComplianceStub,
    IssuerPauseManagerStub,
    IssuerGatedStockToken,
    NearBudgetIssuerGatedStockToken,
    FullBudgetIssuerCompliance,
    AlwaysReadablePauseManager,
    FullBudgetIssuerGatedStockToken
} from "./helpers/IssuerGating.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {ReentrantStockToken, StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice **M1-6 Settlement due + Door control sensor extension.**(issue #11).
///
/// There's only one thing that's hard to get on this ticket:**Parametrics of observation functions**.The validity of the extension depends entirely on it, so the focus of this document is on the
/// No, I'm not. `settleExpired` And the three-line value is given to each of the following tables:
///
/// | Records \ Real time | Door control. | Clean. | I can't read. |
/// |---|---|---|---|
/// | **Door control.**   | no-op | Seal | Seal |
/// | **Clean.**   | Place | CRITICAL **no-op** | Seal |
/// | **I can't read.** | Place | Clear the table. | CRITICAL **no-op** |
///
/// Two. CRITICAL It's the same front and back door: if there's one, it'll be double-covered. `clearedAt`, Anyone who 47 One shift per hour.
/// `pokeGating`  Can make  `settleExpired` Permanent revert,And he's got a series he should have given away.**Free and indefinite extension**.
///
/// CRITICAL The third path is on the chain and not in this table:**Get healthy. view Use gas Starving.**,It also makes "clean." -> "I can't read."
/// This side. See you. `test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas`.
///
/// No variable form (4a/4b/4c)Yes. `test/invariant/Invariant4SettlementAndGating.t.sol`;
/// Real GME The review in question `test/fork/RobinhoodGating.t.sol`.
contract ClearingPoolSettlementTest is Test {
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

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100 ether;

    /// @dev CRITICAL **Literally, no reading `pool.GRACE_PERIOD()`.** "and test itself with its own constant,
    ///      Nothing to prove... same. `ClearingPoolExercise.t.sol` - Yeah. `0xdead` - It's a deal.
    uint64 internal constant GRACE = 48 hours;
    uint64 internal constant GATING_READ_GAS = 50_000;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

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
        meme = new MemeToken();

        // I.D.'s registered with this one. MEME The vault... the one that opened the series... that tied it up, see? {FactoryStub}.
        factory.bind(address(meme), address(vault));

        // CRITICAL The fork test runs on the real time stamp, local default is 1.Push it into one."48 The hour is long gone."
        //    Otherwise... `clearedAt + 48h` and `expiry` The size of the relationship will be shaped by an unrealistic starting point.
        vm.warp(1_800_000_000);
        expiry = uint64(block.timestamp + 7 days);

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 1e31);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
    }

    //  Scaffolding.

    function _openAndMint() internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
    }

    /// @dev Issuer Freezing Pool Address  -  11 The first line of the table is the scene that the door control extends really to cover.
    function _blockPool(bool blocked) internal {
        issuerCompliance.setBlocked(address(stock), address(pool), blocked);
    }

    function _gating(address token) internal view returns (ClearingPool.Gating memory) {
        return pool.gating(token);
    }

    //  deadline:Full realization of the extension

    /// @dev Nobody. poke Pass.  All records zero.  deadline Yeah. `expiry`.
    ///      **Not poke The door control doesn't create any delay.**  -  -  The contract is only for observations recorded (receipt and acceptance terms).
    function test_deadline_isExpiryWhileNothingHasEverBeenObserved() public {
        uint256 seriesId = _openAndMint();
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"Unobserved  deadline == expiry");

        // The issuer is really freezing, but nobody. poke:deadline Nothing moves.
        _blockPool(true);
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"Nobody. poke  No extension.");

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, "unreadable");
        assertEq(g.clearedAt, 0, "clearedAt");
    }

    /// @dev We've got a door.  **No cutout**.This is "an automatic postponement when the issuer freezes" without any manager involved.
    function test_deadline_isUnboundedWhileGatingIsObserved() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"It's in the door control.  No cutout");
        assertTrue(_gating(address(stock)).active, "active");
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"Get in the door and don't touch it. clearedAt");
    }

    /// @dev After the release, `max(expiry, clearedAt + 48h)`.Both sides are nailed:
    ///      It's late.  The broad. deadline Push `expiry` After; it's off early  deadline Or is it? `expiry`.
    function test_deadline_isTheLaterOfExpiryAndClearedAtPlusGrace() public {
        uint256 seriesId = _openAndMint();

        // (1) Undo after due - the grace is in order
        _blockPool(true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(expiry) + 10 days);
        _blockPool(false);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        assertEq(_gating(address(stock)).clearedAt, clearedAt, "clearedAt");
        assertEq(
            pool.exerciseDeadline(seriesId),
            clearedAt + GRACE,
            unicode"The broad. deadline Push it after the release. 48h"
        );

        // (2) Another series of late-expiring shares on the same stock token -- over there. `expiry` Bigger, the grace is not working.
        uint64 laterExpiry = uint64(block.timestamp + 30 days);
        uint256 later = vault.openSeries(address(meme), address(stock), laterExpiry, STRIKE);
        assertEq(
            pool.exerciseDeadline(later), laterExpiry, unicode"expiry Window without shorten in the grace limit later"
        );
    }

    //  CRITICAL Paranoid:clearedAt Only on three sides.

    /// @dev **The core assertion of the note is that the front half of the door is.** Repeatedly on the stock tokens that have been observed as clean. poke  -  -
    ///      No matter how many times you've been transferred, who's been transferred, how many blocks you've crossed, how close you've been to the deadline -- `clearedAt` I have to.**Nothing.**.
    ///
    ///      CRITICAL Without this, "no stop when there's no door" is empty: it's a push. `clearedAt` The assailant.
    ///      Just keep that non-variant premise from being valid, and he can stop the settlement forever, and he has a series that should be broken.
    ///      Free and indefinite extension (no variable) 4(3) The blogger says:
    function test_poke_onACleanStockNeverMovesClearedAt() public {
        uint256 seriesId = _openAndMint();

        // Make one first.**Non-zero**It's... clearedAt:The zero record will make the "unprovoked" matter look like a coincidence.
        _blockPool(true);
        pool.pokeGating(address(stock));
        _blockPool(false);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        assertEq(_gating(address(stock)).clearedAt, clearedAt, unicode"Preconditions:clearedAt It's been covered once.");

        uint64 deadlineBefore = pool.exerciseDeadline(seriesId);

        // The attackers press 47 Hourly round of rhythm push, cross-block, cross-caller, and push all the way to the end of the grace.
        for (uint256 round = 0; round < 6; round++) {
            vm.warp(block.timestamp + 47 hours);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(address(stock));
            vm.prank(keeper);
            pool.pokeGating(address(stock));
            pool.pokeGating(address(stock));

            assertEq(
                _gating(address(stock)).clearedAt,
                clearedAt,
                unicode"Clean. poke - Put it on. clearedAt It's pushed away."
            );
            assertEq(
                pool.exerciseDeadline(seriesId), deadlineBefore, unicode"deadline You shouldn't have moved either."
            );
        }

        // And the settlement is on schedule -- the attack did not take place for a second.
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"The settlement must be on time.");
    }

    /// @dev `Door control. -> Clean.` The only real side to the de-escalation, the only one.**I think so.**The stamp's on the side.
    ///      Door control. -> The door control must be... no-op:`clearedAt` The moment of "leave" is not the moment of "seeing."
    function test_poke_stampsOnlyOnTheGatedToCleanEdge() public {
        _blockPool(true);
        pool.pokeGating(address(stock));

        uint64 stampedTooEarly = _gating(address(stock)).clearedAt;
        assertEq(stampedTooEarly, 0, unicode"Get in the door and don't stamp.");

        // Door control. -> Door control: Not many times.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 6 hours);
            pool.pokeGating(address(stock));
            assertEq(
                _gating(address(stock)).clearedAt, 0, unicode"During the door control. poke I shouldn't have stamped."
            );
            assertTrue(_gating(address(stock)).active, "active");
        }

        _blockPool(false);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, unicode"After the release, it's no longer a door control.");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"Unmark this stamp.");
    }

    /// @dev **fail-open Back door that half.** Door control. view When you can't read, do it without door control.
    ///      The interface will freeze the whole collateral forever.**- At the same time. 48h Lend**  -  -  Otherwise, the token is really suspended and we're...
    ///      If not, the holder will be cleared in a window that is completely unauthorised.
    ///
    ///      CRITICAL And this stamp must be bound to**Enter**The change is not "perhaps read out":
    ///      Second and third times in windows revert **No way.**Re-seal (acceptance and inspection clause).
    /// CRITICAL **Read no more graces (in English)deadline == expiry)**  -  -  2026-09-15 Relax (see {ClearingPool-_exerciseDeadline}
    ///    and "No issuer door control interfaces. No tokens. 48h Lend").`_observe` and the United Nations System Chief Executives Board for Coordination**I didn't move a word.**(Enter unreadable
    ///    One cover, no repeat in the window, no. gas-starvation Pumps) ..it's the usual way to nail it; it's just... deadline From
    ///    clearedAt+48hReplace with "expiry.Here. stock It's readable. bStock By `setViewsRevert` **Temporary**Change
    ///    No -- it's the edge of the new semantic.bStock The interfaces are just as good as they are when they're frozen.
    ///    It's in the contract. It's true. bStock Freezing (readable) + The grace of the hit. deadline That group was followed by the code, and was unaffected.
    function test_poke_unreadableStampsOnceAndGivesNoGrace() public {
        uint256 seriesId = _openAndMint();

        vm.warp(uint256(expiry) - 1 hours);
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));

        uint64 clearedAt = uint64(block.timestamp);
        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.unreadable, unicode"I can't read.  Noted as unreadable (mechanism unchanged)");
        assertFalse(g.active, unicode"fail-open:Not as a doorman.");
        assertEq(g.clearedAt, clearedAt, unicode"One stamp when entering unreadable (mechanism unchanged)");
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"Read it out of the box:deadline == expiry");

        // Repeated reading in window: no re-seals at any time (see box).gas-starvation Pump protection, mechanism unchanged).
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 9 hours);
            vm.prank(attacker);
            pool.pokeGating(address(stock));
            assertEq(_gating(address(stock)).clearedAt, clearedAt, unicode"Twice. revert Recover it. clearedAt");
        }

        // expiry Then settle it as usual -- no food. 48h Wide limit (cycle has pushed the clock) expiry).
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev `Door control. -> I can't read.` Press Undoed Transverse (Stamp) + Clear it. `active`):The blogger says that the lack of reading should not be allowed to enjoy indefinite extensions.
    ///      Otherwise, an upgrade to the interface would have made the entire series never close.
    /// CRITICAL gated->unreadable The government has also been able to provide the government with a new system of training.`_observe` (Mechanisms not moving) **deadline No more back-up.**  -  -
    ///    It's not a good idea.deadline == expiry(2026-09-15 Relax, see you. {ClearingPool-_exerciseDeadline}).
    function test_poke_gatedToUnreadableStampsButGivesNoGrace() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"Precondition: no deadline");

        vm.warp(uint256(expiry) + 1 days);
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(g.active, unicode"It's not \"door control\" after reading it.");
        assertTrue(g.unreadable, "unreadable");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"Press Unreverted Seal (Mechanism unchanged)");
        assertEq(
            pool.exerciseDeadline(seriesId),
            expiry,
            unicode"I can't read.  deadline == expiry,Do not fall back the grace"
        );
    }

    /// @dev `I can't read. -> Clean.` **No re-seal**:It's been covered once in the moment, and then it's covered again.
    ///      In. -> Out -> "Enter," and it's a push. `clearedAt` The pump.
    ///
    ///      The price is: if the coin is really suspended in the unreadable window and not read again until the window is back, it will be a good thing to read the coin.
    ///      Well... 48 The hourly buy time has been spent.`docs/spec.md`).
    function test_poke_unreadableToCleanDoesNotReStamp() public {
        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));
        uint64 firstStamp = _gating(address(stock)).clearedAt;

        // view It's fixed and clean: no matter who's transferred, how many times, how long it takes, no new seals.
        stock.setViewsRevert(false);
        for (uint256 round = 0; round < 4; round++) {
            vm.warp(block.timestamp + 40 hours);
            vm.roll(block.number + 1);

            vm.prank(attacker);
            pool.pokeGating(address(stock));
            vm.prank(keeper);
            pool.pokeGating(address(stock));

            assertFalse(
                _gating(address(stock)).unreadable, unicode"You need to clear the table after you can read again."
            );
            assertEq(
                _gating(address(stock)).clearedAt, firstStamp, unicode"I can't read. -> Clean should not be stamped."
            );
        }

        // CRITICAL But...**Reenter**It was a new side, and it was a stamp -- that's what it meant to be "bound to change."
        //    Make this side. view It's really broken, which means the issuer is required to change his own code;
        //    The one that calls one way or another. view Use gas I'm starving. `GATING_READ_GAS` Stop it.
        //    See `test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas`.
        stock.setViewsRevert(true);
        vm.prank(attacker);
        pool.pokeGating(address(stock));
        assertGt(_gating(address(stock)).clearedAt, firstStamp, unicode"It's a new side to re-enter the unreadable.");
    }

    /// @dev `I can't read. -> Door control.`:view Fixed and said the door was hit -- an indefinite extension to come back right away.
    function test_poke_unreadableToGatedRestoresTheUnboundedDeadline() public {
        uint256 seriesId = _openAndMint();

        stock.setViewsRevert(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).unreadable, unicode"Precondition: not readable");

        stock.setViewsRevert(false);
        stock.setTokenPaused(true);
        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, "active");
        assertFalse(g.unreadable, "unreadable");
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"No cutout");
    }

    /// @dev A guy who can't read. view **I shouldn't.**They are also being treated as clean because of "high."
    ///      And nail it to the second thing: it burned. gas There's a high ground. A bad token cannot be cyclical. view
    ///      - Put it on. poke The whole pen of the caller gas Eat up.
    function test_poke_treatsAnUnaffordablyExpensiveViewAsUnreadable() public {
        stock.setViewGasBurnRounds(50_000);

        uint256 before = gasleft();
        pool.pokeGating(address(stock));
        uint256 spent = before - gasleft();

        assertTrue(_gating(address(stock)).unreadable, unicode"I can't read it.  I can't read.");
        assertEq(_gating(address(stock)).clearedAt, uint64(block.timestamp), unicode"As usual.");
        assertLt(spent, 400_000, unicode"The coins can't burn the whole caller pen. gas");
    }

    /// @dev CRITICAL **The third is the side path, which is not in the status table: to put healthy. view Use gas Starving to death.**
    ///
    ///      "Unreadable" is "failed call" and how much is forwarded. gas Yes.**Caller**It's up to you.
    ///      Less. gas The floor. Anyone can clean it with a carefully measured deal. view Done. out-of-gas,
    ///      "Clean" from the air. -> "Unreadable" side, and then every 47 One hour at a time -- the attack face comes back from the back door.
    ///
    ///      So here's the whole thing. gas:Each one of them either works cleanly or... revert,**It's not going to be "not readable." + Seal**.
    function test_poke_neverFabricatesAnUnreadableObservationWhenStarvedOfGas() public {
        pool.pokeGating(address(stock));
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"Precondition: clean and never stamped");

        uint256 succeeded;
        uint256 rejected;
        for (uint256 gasLimit = 20_000; gasLimit <= 400_000; gasLimit += 2500) {
            vm.prank(attacker);
            try pool.pokeGating{gas: gasLimit}(address(stock)) {
                succeeded++;
            } catch {
                rejected++;
            }

            ClearingPool.Gating memory g = _gating(address(stock));
            assertFalse(g.unreadable, unicode"gas I've been starving to death to make \"I can't read.\"");
            assertEq(g.clearedAt, 0, unicode"gas Starving to death is pushing. clearedAt");
        }

        // Both directions have to be hit, otherwise the test may be just passing over a zone where all (or all) failures have been made.
        assertGt(rejected, 0, unicode"Precondition: Low gas That one was really turned down.");
        assertGt(succeeded, 0, unicode"Precondition: High gas That one really worked.");
    }

    /// @dev Positive contrast of the previous article:gas What's not clear is that the time is not enough.**This.**Wrong, not naked. out-of-gas,
    ///      It's not "readless." The caller knows the addition. gas,The user also said that the user had not been able to use the interface.
    function test_poke_reportsTheGasFloorItSelfEnforces() public {
        uint256 floor = pool.GATING_READ_GAS();
        assertGt(floor, 0, unicode"Pre-condition: budget is public");

        // It's just enough to go into a function, but not enough to forward the full budget.
        vm.expectPartialRevert(ClearingPool.NotEnoughGasToObserveGating.selector);
        this.pokeWithGas(address(stock), floor);

        assertEq(_gating(address(stock)).clearedAt, 0, unicode"Nothing.");
    }

    /// @dev Return P1:Old guard Just... `64 / 63`,It's missing. cold `STATICCALL` cost. Caller to 54,472 gas
    ///      The outside calls will work, but they're healthy. view It's only the date. 47k,And it was falsely created as a "unreadable" + The blog is a good one.
    ///      After repair, you must read it before `NotEnoughGasToObserveGating` Whole rejection, zero.
    function test_poke_rejectsTheEip150ColdCallBoundaryBeforeItCanStamp() public {
        FullBudgetIssuerCompliance fullBudgetCompliance = new FullBudgetIssuerCompliance();
        AlwaysReadablePauseManager cheapPause = new AlwaysReadablePauseManager();
        FullBudgetIssuerGatedStockToken fullBudget =
            new FullBudgetIssuerGatedStockToken(address(cheapPause), address(fullBudgetCompliance));

        // Clearly cooled the three addresses that were read, nailing the worst path on which the real attack depended, not warm-cache The occasional act under the table.
        // CRITICAL BSC The doorman on the page is...**Five readings.**(Manager Address / isTokenPaused / Compliance address / Blacklist / The sanctions list,
        //    - Yeah. Robinhood Two more editions, so the cooling address went from two to three.
        vm.cool(address(fullBudget));
        vm.cool(address(cheapPause));
        vm.cool(address(fullBudgetCompliance));
        (bool success, bytes memory revertData) =
            address(pool).call{gas: 54_472}(abi.encodeCall(ClearingPool.pokeGating, (address(fullBudget))));
        assertFalse(success, unicode"Recovered guard It must be. cold-call Border block rejection");
        assertEq(
            bytes4(revertData),
            ClearingPool.NotEnoughGasToObserveGating.selector,
            unicode"It has to be clear. gas-floor Reject"
        );

        ClearingPool.Gating memory g = _gating(address(fullBudget));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, unicode"gas I can't make unreadable observations.");
        assertEq(g.clearedAt, 0, unicode"gas I can't go hungry without a broad stamp.");

        // Full gas At that time, the same healthy token, which is almost fully fed, must remain readable.
        pool.pokeGating(address(fullBudget));
        assertFalse(
            _gating(address(fullBudget)).unreadable, unicode"Health under the full budget view We have to read it."
        );
    }

    //  ABI Border and Reading Priority

    /// @dev Return length is not a ABI word The blog is also available.`_staticWord` It must be considered unreadable, not decoded,revert,
    ///      Or the error is clean. A person who is in a state of incomprehensible reading is allowed to have only one broad stamp.
    function test_poke_shortPausedResponseIsUnreadableAndStampsOnlyOnce() public {
        // BSC The first reading of the tokens in the edition is: `pauseManager()`(Address view).Short returns must always be recorded as unreadable.
        vm.mockCall(address(stock), abi.encodeCall(IssuerGatedStockToken.pauseManager, ()), hex"01");

        pool.pokeGating(address(stock));
        uint64 firstStamp = _gating(address(stock)).clearedAt;
        assertFalse(_gating(address(stock)).active, "active");
        assertTrue(_gating(address(stock)).unreadable, unicode"Short returns must be recorded as unreadable");
        assertEq(firstStamp, uint64(block.timestamp), unicode"Seal when entering unreadable");

        vm.warp(block.timestamp + 1 days);
        pool.pokeGating(address(stock));
        assertEq(_gating(address(stock)).clearedAt, firstStamp, unicode"The same short return cannot be repeated");
    }

    /// @dev The issuer does not always comply Solidity It's... canonical bool codes; non-zero word Still sure about the door.
    ///      If you want to use it `abi.decode(..., (bool))`,Here, I will. revert,- Put it on. fail-open The path to read becomes fail-closed.
    function test_poke_noncanonicalTruthyPausedWordIsGatedAndReadable() public {
        // CRITICAL BSC The Boolean in the edition.**Manager**Top (%1)`isTokenPaused(token)`),Not on the token.
        vm.mockCall(
            address(issuerPause),
            abi.encodeCall(IssuerPauseManagerStub.isTokenPaused, (address(stock))),
            abi.encode(uint256(2))
        );

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"Non-zero isTokenPaused word It's still a door control.");
        assertFalse(g.unreadable, unicode"32 byte non-zero word It's readable. ABI Back");
        assertEq(g.clearedAt, 0, unicode"No decorating access.");
    }

    /// @notice CRITICAL **The global sanctions list is... BSC The third new door control source**(Decision-making 53) -  -
    ///         Robinhood The only two versions of the edition are "Pause" and "Black List".
    ///
    /// @dev It's not a formal difference from the blacklist: the key to the blacklist is `(Currency, Address)`,Sanctions List**It's not about the token.**.
    ///      So the distributor can stop the pool without touching any one of the tokens -- and the pool must be visible.
    ///      Basis of fact: After sanctions `transfer` revert `UserSanctioned()`,And five readings still work.
    ///      (`docs/research/bsc-flap-portal-probe.md` 6.4).
    function test_poke_sanctioningThePoolIsGatingAndStaysReadable() public {
        issuerCompliance.setSanctioned(address(pool), true);

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"The pool is under sanction.  Door control hit.");
        assertFalse(g.unreadable, unicode"Sanctions are a readable state, not \"readable.\"");
        assertEq(g.clearedAt, 0, unicode"No decorating access.");

        // That's the one that left after the release.**One**Real demarches: once.
        issuerCompliance.setSanctioned(address(pool), false);
        vm.warp(block.timestamp + 1 hours);
        pool.pokeGating(address(stock));

        g = _gating(address(stock));
        assertFalse(g.active, unicode"No more door control after the sanctions are lifted.");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"Unmark the border");
    }

    /// @dev Sanctions and blacklists are:**Two independent sources**:One should not be allowed to fail the other, both should be just door control.
    ///      This one's about short reading. `&&` Something like a mishap.
    function test_poke_blocklistAndSanctionsAreIndependentSources() public {
        _blockPool(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"Just the black one.  Door control.");

        _blockPool(false);
        issuerCompliance.setSanctioned(address(pool), true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"Sanctions only  Door control.");

        _blockPool(true);
        pool.pokeGating(address(stock));
        assertTrue(_gating(address(stock)).active, unicode"Both of them.  It's still a door control.");

        _blockPool(false);
        issuerCompliance.setSanctioned(address(pool), false);
        vm.warp(block.timestamp + 1 hours);
        pool.pokeGating(address(stock));
        assertFalse(_gating(address(stock)).active, unicode"Both are disarmed.  Clean.");
    }

    /// @dev Address word High 96 There is no stopping a bit of dirty data: a cut will allow the pool to draw conclusions from another registration address.
    function test_poke_dirtyRegistryAddressIsUnreadableAndNeverTruncated() public {
        _blockPool(true);
        uint256 dirtyRegistry = uint256(uint160(address(issuerCompliance))) | (uint256(1) << 160);
        vm.mockCall(address(stock), abi.encodeCall(IssuerGatedStockToken.compliance, ()), abi.encode(dirtyRegistry));

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertFalse(
            g.active,
            unicode"The dirty address cannot be stopped and read the door control of the real registration form."
        );
        assertTrue(g.unreadable, unicode"If you don't have a clean address, you can't read it.");
        assertEq(g.clearedAt, uint64(block.timestamp), unicode"Unreadable Envelope");
    }

    /// @dev Any one of them has a positive priority over subsequent reading failure; there are also zero expectations of a pre-release.
    ///      To prevent future re-ordering and downgrading a healthy door control. fail-open.
    function test_poke_positivePausedReadWinsBeforeARevertingRegistryRead() public {
        bytes memory registryCall = abi.encodeCall(IssuerGatedStockToken.compliance, ());
        vm.mockCall(
            address(issuerPause),
            abi.encodeCall(IssuerPauseManagerStub.isTokenPaused, (address(stock))),
            abi.encode(true)
        );
        vm.mockCallRevert(address(stock), registryCall, "compliance must not be read after a positive paused result");
        vm.expectCall(address(stock), registryCall, 0);

        pool.pokeGating(address(stock));

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"Killed paused We can't be demoted by a subsequent failure.");
        assertFalse(g.unreadable, unicode"Early positive hits are still readable.");
    }

    /// @dev Separate `paused()` Read Close 50k When the budget is still healthy, the pool must read, not be misrecorded.
    ///      Let the pool go the real way and nail it to the exact transmission. gas,Again. warm The same address is rechecked. staticcall The gas.
    function test_poke_acceptsAHealthyPausedReadThatUsesAlmostTheFullBudget() public {
        NearBudgetIssuerGatedStockToken nearBudget = new NearBudgetIssuerGatedStockToken(issuerPause, issuerCompliance);
        uint256 budget = pool.GATING_READ_GAS();
        bytes memory pausedCall = abi.encodeCall(NearBudgetIssuerGatedStockToken.pauseManager, ());

        assertEq(budget, GATING_READ_GAS, unicode"The pool must still forward the agreed budget for one reading.");
        vm.expectCall(address(nearBudget), 0, GATING_READ_GAS, pausedCall);
        pool.pokeGating(address(nearBudget));

        ClearingPool.Gating memory g = _gating(address(nearBudget));
        assertFalse(g.active, "active");
        assertFalse(g.unreadable, unicode"Close to budget, but healthy reading cannot be ruled unreadable.");

        uint256 before = gasleft();
        (bool success, bytes memory ret) = address(nearBudget).staticcall{gas: budget}(pausedCall);
        uint256 spent = before - gasleft();

        assertTrue(success, unicode"Near budget pauseManager() Still should return");
        // CRITICAL BSC The last budget reading in the edition is:**Address** view(`pauseManager()`),No, it's not. bool.
        //    The emphasis of the assertion remains the same: it remains the norm.**One.** ABI word,The blogger says that the government is not going to return to the country, but rather to return to the top of the country.
        assertEq(ret, abi.encode(address(issuerPause)), unicode"Return remains a norm address word");
        assertEq(ret.length, 32, unicode"Just one. word");
        assertGt(spent, budget - 12_000, unicode"Single health reading must be really close to the budget.");
        assertLt(spent, budget, unicode"Health literacy must be done within budget");
    }

    /// @dev `expectPartialRevert` It's gonna work once.**External**Call it up, so I'm gonna need to get through. `this`.
    function pokeWithGas(address token, uint256 gasLimit) external {
        pool.pokeGating{gas: gasLimit}(token);
    }

    /// @dev Zero addresses blocked outside the door:`_gating[address(0)]` Yes.**Unopened Series**The record that you will read,
    ///      Make it always zero, it's cheaper to re-prove it every time it's added.
    function test_poke_rejectsTheZeroAddress() public {
        vm.expectRevert(ClearingPool.ZeroToken.selector);
        pool.pokeGating(address(0));

        ClearingPool.Gating memory g = _gating(address(0));
        assertEq(g.clearedAt, 0, "clearedAt");
        assertFalse(g.unreadable, "unreadable");
    }

    /// @dev Event in**Every time.**It's all over the view, including... no-op Those.
    ///      The chain has to distinguish between "we've seen it, it's clean" and "the pen." poke "It's not even implemented." That's what it's about.
    function test_poke_emitsOnEveryObservationIncludingNoOps() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));

        // The second time was complete. no-op  -  -  It's going to be the same.
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));

        _blockPool(true);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), true, true, 0);
        pool.pokeGating(address(stock));

        _blockPool(false);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, uint64(block.timestamp));
        pool.pokeGating(address(stock));

        stock.setViewsRevert(true);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, false, uint64(block.timestamp));
        pool.pokeGating(address(stock));
    }

    //  settleExpired

    /// @dev Write in the settlement `remainder = deposited  exercised`,After that**Right to non-feasibility**(No Variable 4(1)).
    function test_settle_writesTheRemainderAndClosesTheSeries() public {
        uint256 seriesId = _openAndMint();

        vm.prank(alice);
        pool.exercise(seriesId, 30 ether, alice);

        vm.warp(expiry);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Settled(seriesId, uint128(DEPOSIT - 30 ether), expiry);
        vm.prank(keeper);
        pool.settleExpired(seriesId);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertTrue(s.settled, "settled");
        assertEq(s.remainder, DEPOSIT - 30 ether, unicode"remainder = deposited  exercised");
        assertEq(s.deposited, DEPOSIT, unicode"The settlement is unchanged. deposited");
        assertEq(s.exercised, 30 ether, unicode"The settlement is unchanged. exercised");
        assertEq(stock.balanceOf(address(pool)), DEPOSIT - 30 ether, unicode"None of the collateral left the pool.");

        // No Variable 4(1)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 1 ether, alice);
        assertEq(
            call.balanceOf(alice, seriesId),
            DEPOSIT - 30 ether,
            unicode"The license is still in place, but it's not gonna work."
        );
    }

    /// @dev CRITICAL The verdict must be `exercise` **Strict complementarity**:One second there's a "no right, no settlement."
    ///      the window, or worse -- both.**- Yeah.**Do the window.
    function test_settle_exactlyComplementsTheExerciseWindow() public {
        uint256 seriesId = _openAndMint();

        // deadline One second: the line is open, the settlement is closed.
        vm.warp(uint256(expiry) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.SettlementTooEarly.selector, seriesId, expiry, block.timestamp)
        );
        pool.settleExpired(seriesId);

        vm.prank(alice);
        pool.exercise(seriesId, 1 ether, alice);

        // deadline One second: the line is closed, the settlement is open.
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.ExerciseWindowClosed.selector, seriesId, expiry, uint256(expiry))
        );
        pool.exercise(seriesId, 1 ether, alice);

        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev It's in the door control.  Settlement was made**Structural Blocking**.The power window remains open -- this is the full realization of automatic extensions;
    ///      If the issuer still stops the transfer of shares, the right call will return the atom.
    function test_settle_isStructurallyBlockedWhileTheIssuerGates() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        vm.warp(uint256(expiry) + 365 days);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, address(stock)));
        pool.settleExpired(seriesId);

        assertFalse(pool.series(seriesId).settled, unicode"A year passed without a settlement.");
        assertEq(
            pool.exerciseDeadline(seriesId), type(uint64).max, unicode"And the series has always been a viable right."
        );
    }

    /// @dev CRITICAL **`pokeGating` It's a window closing move, not an opening move.**
    ///
    ///      The right reader is...**Records**,The video is not read in real time. So the records are stopped in the "door control" and the issuer has quietly removed them.
    ///      Right to exercise authority**Now.**Available - window open (uncuted) and transfer is released.**No one needs to start. poke**.
    ///      And it's only one thing to see the de-activation: to reap the infinite window. `max(expiry, clearedAt + 48h)`.
    ///
    ///      The reason for this test is the document, not the code: write it "deactivate."**And it was observed.**The right to freedom of expression is a right that is only possible.
    ///      The front end will persuade the users to wait. keeper  -  -  That was wrong and described an unauthorized design as operational dependency.
    ///      Word drifts, this one will be red.
    function test_exercise_worksBeforeAnyPokeOnceTheIssuerClears() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));

        // After a long time, the issuer quietly deactivated -- and...**No one.**Again. poke Pass.
        vm.warp(uint256(expiry) + 30 days);
        _blockPool(false);

        ClearingPool.Gating memory g = _gating(address(stock));
        assertTrue(g.active, unicode"Prefix: Records remain in \"door control\"");
        assertEq(g.clearedAt, 0, unicode"Prefix: the broad hour never starts");

        vm.prank(alice);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(stock.balanceOf(alice), 10 ether, unicode"No, I'm not. poke,The right to work is working.");

        // And... poke What I did was...**Zoom In**:No cutout -> Disarm Time + 48h
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"poke Before: no deadline");
        pool.pokeGating(address(stock));
        assertEq(
            pool.exerciseDeadline(seriesId), uint64(block.timestamp) + GRACE, unicode"poke Later: Window harvest 48h"
        );
    }

    /// @dev CRITICAL **Self-rehabilitation observations, the most important direction.**:The record says that the issuer is actually frozen.
    ///      If you don't read it again, the settlement will be in the holder.**There's no right to do it.**The time has come to move forward as usual.
    function test_settle_selfHealsARecordThatWronglySaysClean() public {
        uint256 seriesId = _openAndMint();

        pool.pokeGating(address(stock)); // Record: Clean
        vm.warp(expiry);

        // The freeze took place last time poke After that - the records are old
        _blockPool(true);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SettlementGatedByIssuer.selector, seriesId, address(stock)));
        pool.settleExpired(seriesId);

        assertFalse(pool.series(seriesId).settled, unicode"Old clean records didn't put the settlement through.");
    }

    /// @dev Another direction: the record says the door is de-activated in real time. The observation corrects it and covers it, so the settlement is too early.
    ///
    ///      WARNING **That observation followed this. revert Roll back together.** The broad clock must be one. `pokeGating` Start...
    ///      The operating caliber is "first." poke,Wait a minute. 48 "hours, settlement," not over and over again. `settleExpired`.
    ///      No impact on activity:poke No permission, no one can be transferred.
    function test_settle_doesNotStartTheGraceClockByItself() public {
        uint256 seriesId = _openAndMint();

        _blockPool(true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(expiry) + 3 days);
        _blockPool(false);

        // It's a test. settle:rejected and**Nothing left.**
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, uint64(block.timestamp) + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);
        assertTrue(_gating(address(stock)).active, unicode"Records are still on the old door control.");
        assertEq(_gating(address(stock)).clearedAt, 0, unicode"The broad clock didn't start.");

        // It's the same as any other time -- the clock has to be lifted.
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, uint64(block.timestamp) + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // Correct approach:poke Turn around, wait for the full. 48 Hours, settlement.
        pool.pokeGating(address(stock));
        uint64 clearedAt = uint64(block.timestamp);

        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 1 ether, alice);

        vm.warp(uint256(clearedAt) + GRACE);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, "settled");
    }

    /// @dev Two state doors: the series was not opened and the series was closed.
    function test_settle_rejectsUnopenedAndAlreadySettledSeries() public {
        uint256 unopened = uint256(keccak256(abi.encode(address(meme), address(stock), uint64(999))));
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.settleExpired(unopened);

        uint256 seriesId = _openAndMint();
        vm.warp(expiry);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.settleExpired(seriesId);
        assertEq(pool.series(seriesId).remainder, DEPOSIT, unicode"Second time, no. remainder Recalculate.");
    }

    /// @dev After settlement**No more deposit.**:That collateral is not here. `remainder` The government has not been able to provide any information on the issue.
    ///      It'll be stuck in the pool forever. admin,None withdraw),The right to a single card is not a right.
    function test_settle_closesTheDepositPathToo() public {
        uint256 seriesId = _openAndMint();
        vm.warp(expiry);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        vault.depositAndMint(seriesId, alice, 1 ether);

        assertEq(pool.series(seriesId).deposited, DEPOSIT, unicode"It's not passive.");
        assertEq(call.balanceOf(alice, seriesId), DEPOSIT, unicode"And no more calls.");
    }

    /// @dev CRITICAL Previous**Re-version**,It's the real hard shape: "Call first, keep a check" and "Calculate later."
    ///      The transfer gives control to the shares. The coins settle the series in a return and then they deposit it back into the usual place.
    ///      Put the collateral in. `deposited`,And cast the certificate of authority... `remainder` The settlement is already settled.
    ///
    ///      What's blocking it? `settleExpired` It's... `nonReentrant`(The guards are...**Cross-function**- Yeah.
    function test_settle_cannotBeReenteredFromADepositCallback() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        reentrant.mint(address(vault), 1e24);
        vault.approve(reentrant, type(uint256).max);

        uint64 shortExpiry = uint64(block.timestamp + 1 days);
        uint256 seriesId = vault.openSeries(address(meme), address(reentrant), shortExpiry, STRIKE);
        vault.depositAndMint(seriesId, alice, 10 ether);

        // Pass. deadline,Right now. `settleExpired` So the only way to get a call alone is to get it -- so the inner layer is probably being rejected for re-protection.
        vm.warp(shortExpiry);
        reentrant.armReentrancy(address(pool), abi.encodeCall(ClearingPool.settleExpired, (seriesId)));

        vault.depositAndMint(seriesId, alice, 5 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"Precondition: Reconverting is actually in.");
        assertFalse(reentrant.reentrySucceeded(), unicode"The inner-floor settlement must be rejected.");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the rejection was re-entry."
        );
        assertFalse(pool.series(seriesId).settled, unicode"The series wasn't closed in the middle of the deposit.");
        assertEq(pool.series(seriesId).deposited, 15 ether, unicode"Keep it in the usual books.");
    }

    /// @dev After settlement `remainder` Ikechi.**It belongs to this series.**The full balance, not much.
    function testFuzz_settle_remainderIsExactlyWhatIsLeftInThePool(uint128 deposit, uint128 exercised) public {
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

        assertEq(pool.series(seriesId).remainder, deposit - exercised, "remainder");
        assertEq(stock.balanceOf(address(pool)), deposit - exercised, unicode"remainder The actual amount of the pool.");
    }

    //  Only one holder is enclosed: no extension is generated, but it is identifiable

    /// @dev CRITICAL Issuer**Only one holder**(Not the pool. The pool is clean.  The observations don't see anything.
    ///      **No extension generated**,The holder's license is revoked when it expires. It's intentional.
    ///      But it is.**Real and irreversible user losses**(`docs/spec.md`).
    ///
    ///      The acceptance clause requires this.**Visibility**,The front end can distinguish it from the other side and point out the "sell the license" as a path to self-help.
    ///      The three pieces of evidence are sufficiently distinct:
    ///
    ///      | Evidence | Only holders | Seal the pool. |
    ///      |---|---|---|
    ///      | Right-wing. revert Data | `Blocked(Holder)` | `Blocked(I'm a pool.)` |
    ///      | `GatingObserved` | `gated == false` | `gated == true` |
    ///      | `exerciseDeadline` | Still. `expiry` | `type(uint64).max` |
    function test_blockingOneHolderProducesNoExtensionAndStaysIdentifiable() public {
        uint256 seriesId = _openAndMint();
        issuerCompliance.setBlocked(address(stock), alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuerGatedStockToken.Blocked.selector, alice));
        pool.exercise(seriesId, 1 ether, alice);

        // Observation: The pool is clean -- it says in the incident: `gated == false`,deadline Nothing moves.
        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), false, true, 0);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), expiry, unicode"The individual holder is not subject to extension");

        // Contrast: When the pond is sealed, the same observation gives a completely different three things.
        issuerCompliance.setBlocked(address(stock), alice, false);
        _blockPool(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IssuerGatedStockToken.Blocked.selector, address(pool)));
        pool.exercise(seriesId, 1 ether, alice);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.GatingObserved(address(stock), true, true, 0);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(seriesId), type(uint64).max, unicode"The pool is blocked for extension.");

        // The only self-saving path for the holder that is blocked alone: sell the certificate of right - transfer without touching the stock coin.
        _blockPool(false);
        issuerCompliance.setBlocked(address(stock), alice, true);
        address buyer = makeAddr("buyer");
        vm.prank(alice);
        call.safeTransferFrom(alice, buyer, seriesId, DEPOSIT, "");
        assertEq(call.balanceOf(buyer, seriesId), DEPOSIT, unicode"The sealed holder still sells the certificate.");
    }

    //  Extension of full path (local; real mark see fork test)

    /// @dev The main line of the acceptance clause, once and for all:
    ///      pause -> poke -> Pass. expiry Back window still open (transfer roll, rights card not lost) -> Undo -> 48h Lend-in right to succeed.
    ///      -> Successful settlement after grace.
    function test_fullPath_pausePokeKeepsWindowOpenThenClearGraceExerciseSettle() public {
        uint256 seriesId = _openAndMint();

        // (1) Issuer paused, anyone poke Stay and observe.
        stock.setTokenPaused(true);
        vm.prank(keeper);
        pool.pokeGating(address(stock));

        // (2) Pass. expiry The rights window is still open; it is only at this moment that the transfer of shares is blocked by the issuer, so the whole thing is called back.
        vm.warp(uint256(expiry) + 5 days);
        vm.prank(alice);
        vm.expectRevert(IssuerGatedStockToken.IsPaused.selector);
        pool.exercise(seriesId, 10 ether, alice);
        assertEq(call.balanceOf(alice, seriesId), DEPOSIT, unicode"I've lost one.");

        // (3) Dismissed. The grace begins at this moment. The observation is left behind by anyone.
        stock.setTokenPaused(false);
        vm.prank(attacker); // It's the same thing. It's not allowed.
        pool.pokeGating(address(stock));
        uint64 clearedAt = uint64(block.timestamp);

        // 4 Lend**Inside**Right to succeed -- this is where the extension actually works.
        vm.warp(uint256(clearedAt) + GRACE - 1);
        vm.prank(alice);
        pool.exercise(seriesId, 40 ether, alice);
        assertEq(stock.balanceOf(alice), 40 ether, unicode"The right to remain within the limits of the law");

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SettlementTooEarly.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.settleExpired(seriesId);

        // 5 After grace: turn the line off, the settlement opens.
        vm.warp(uint256(clearedAt) + GRACE);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.ExerciseWindowClosed.selector, seriesId, clearedAt + GRACE, block.timestamp
            )
        );
        pool.exercise(seriesId, 1 ether, alice);

        pool.settleExpired(seriesId);
        assertEq(pool.series(seriesId).remainder, DEPOSIT - 40 ether, "remainder");
    }

    //  No issuer door control interfaces. No tokens. 48h Lend (supported by any price bill)
    //
    /// CRITICAL **Can not get message: %s %s `pauseManager()`/`compliance()`)Now. deadline Yeah. `expiry`,No, I'm not. 48h Lend.**
    ///    WBNB / USDT / DOGE / Various custom quote No distribution door interface, never read; old "not read" ->
    ///    fail-open + 48h "The graces will drag them out of the weekly settlement. 48h(It's a real chain of things. C2/C3/C5 All right. `SettlementTooEarly`).
    ///    Relax the basis (user) 2026-09-15):Can you... launch By Flap Portal Control,call Trust it unconditionally, no need.
    ///    Our door is no longer free. quote See you on the second. {ClearingPool-_exerciseDeadline}.
    ///    WARNING **`unreadable` The mechanism itself is still intact.**(Still recorded, still protected gas-starvation Pumps) `_exerciseDeadline`
    ///    Yeah. `g.unreadable` This one's fromclearedAt+48hReplace with "expiry.Real bStock Freezing (readable) clear-edge,
    ///    `g.unreadable==false`)Other Organiser deadline The group was set up by the code.**Total reservation**.
    function test_issuerlessStock_exerciseDeadlineIsExpiryNoGrace() public {
        // Normal with no distribution door control interface ERC20(None pauseManager/compliance) -  - Representative WBNB/USDT/DOGE/Any custom.
        StockToken plain = new StockToken();
        plain.mint(address(vault), 1e30);
        vault.approve(plain, type(uint256).max);
        uint64 exp = uint64(block.timestamp + 7 days);
        uint256 seriesId = vault.openSeries(address(meme), address(plain), exp, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        // poke -> I can't read. -> Record still marked unreadable,It's not readable. clearedAt(The mechanism remains unchanged.
        pool.pokeGating(address(plain));
        assertTrue(
            _gating(address(plain)).unreadable,
            unicode"No door control interface  Can not get message: %s %sunreadable (Remains recorded)"
        );
        assertEq(_gating(address(plain)).clearedAt, uint64(block.timestamp), unicode"It's not readable. clearedAt");

        // CRITICAL But... deadline **No allowance.**  -  -  The blogger says that the lack of reading is considered clean.deadline == expiry(Not clearedAt+48h).
        assertEq(pool.exerciseDeadline(seriesId), exp, unicode"I can't read.  No respite.deadline == expiry");

        // Settlement in expiry Then we can succeed and not be delayed. 48h(The real chain. SettlementTooEarly The root causes of the attack were eliminated.
        vm.warp(uint256(exp) + 1);
        pool.settleExpired(seriesId);
        assertTrue(pool.series(seriesId).settled, unicode"I can't read the tokens. expiry Then we can settle it. 48h");
    }
}
