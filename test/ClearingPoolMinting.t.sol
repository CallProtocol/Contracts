// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {ReentrantCallReceiver} from "./helpers/ReentrantCallReceiver.sol";
import {ReentrantStockToken, StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice **M1-4 Cast Path**(issue #9):The price of the chain locks and the right to the right to the right to deposit in the shares in the currency**Actual increase in accounts payable**Casting the license.
///
/// This ticket is only two functions, but they determine the calibre of all the accounts in the back:
///
/// - `seriesId` Hash in the tri-member group - license to press**Item**Segregation (`docs/spec.md`:The right-to-fire is the right one. MEME,
///   It is impossible to pay different assets as a single asset;
/// - Casting in**Increase in balance**- Under the currency of the shares with transfer tax, the casting at the requested amount is direct overpayment;
/// - The total number is raw `balanceOf` Unit  -  EIP-8056 The change in the stock is `uiMultiplier`,
///   The first time the shares were split, the number of shares would be misplaced.
///
/// The test drives the real four contracts.`docs/spec.md` / issue #5 The government has been trying to prevent the use of the word "regime" in the media.
/// Only the "the vault of the series" has a double -- the vault itself is in the... M2 It's only there.
contract ClearingPoolMintingTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    address internal meme = makeAddr("MEME");

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        expiry = uint64(block.timestamp + 7 days);

        // CRITICAL I.D.'s registered with this one. MEME The vault... no such line,`openSeries` It can't come out at once.
        //    This is the binding line in the production. `CallVaultFactory` Yes. Flap In the same transaction, see {FactoryStub}.
        factory.bind(meme, address(vault));

        stock.mint(address(vault), 1_000_000 ether);
        vault.approve(stock, type(uint256).max);
    }

    /// @dev CRITICAL The expectation is here.**Count it on your own.**,No pool. `seriesIdOf`  -  -  Use the object's own formula
    ///      To test its own formula, nothing can prove it.
    function _expectedSeriesId(address memeToken, address stockToken, uint64 expiry_) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(memeToken, stockToken, expiry_)));
    }

    //  Open the line.

    function test_openSeries_idIsTheHashOfTheTriple_andEveryFieldIsRecorded() public {
        uint256 expected = _expectedSeriesId(meme, address(stock), expiry);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.SeriesOpened(expected, address(vault), meme, address(stock), expiry, STRIKE);
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        assertEq(seriesId, expected, "seriesId == keccak256(abi.encode(meme, stock, expiry))");
        assertEq(
            pool.seriesIdOf(meme, address(stock), expiry),
            expected,
            unicode"The same formula the pool gave to the outside world"
        );

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.vault, address(vault), unicode"The one who opened the series was the vault of the series.");
        assertEq(s.memeToken, meme, "memeToken");
        assertEq(s.stockToken, address(stock), "stockToken");
        assertEq(s.expiry, expiry, "expiry");
        assertEq(s.strike, STRIKE, "strike");
        assertEq(s.deposited, 0, "deposited");
        assertEq(s.minted, 0, "minted");
        assertEq(s.exercised, 0, "exercised");
        assertEq(s.remainder, 0, "remainder");
        assertFalse(s.settled, "settled");
    }

    /// @dev Three points are actually into Hash. One less means two different series would have hit the same one. ERC-1155 id  -  -
    ///      Hit it. `memeToken` That dimension was particularly lethal: the two projects had a single collateral shared by the CAC.
    function test_openSeries_eachComponentOfTheTripleChangesTheId() public {
        uint256 base = vault.openSeries(meme, address(stock), expiry, STRIKE);

        address otherMeme = makeAddr("another project's MEME");
        StockToken otherStock = new StockToken();
        uint64 otherExpiry = expiry + 7 days;

        // Another project. MEME You have to have your own vault first -- and here.**I'm gonna sign up for the same vault double.**:
        // The test is "three points each go to Hashi," and one more vault will only add a non-variant to this assertion.
        factory.bind(otherMeme, address(vault));

        assertTrue(base != vault.openSeries(otherMeme, address(stock), expiry, STRIKE), "memeToken");
        assertTrue(base != vault.openSeries(meme, address(otherStock), expiry, STRIKE), "stockToken");
        assertTrue(base != vault.openSeries(meme, address(stock), otherExpiry, STRIKE), "expiry");
    }

    /// @dev Acceptance and acceptance clauses:**Only one change; right-of-hand prices are not changed thereafter.**
    ///      "It's about the "inalterable"**Cannot initialise Evolution's mail component.**So it has two sources:
    ///      This test is blocking the second time. `openSeries` "No other entrance can change"
    ///      `test/ClearingPool.t.sol::test_writeSurface_isExactlySixFunctions` Enumeration ABI Prove it.
    function test_openSeries_isOnceOnly_andTheStrikeIsFrozen() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        // CRITICAL Only**The vault that was registered.**The door was opened only when the other person was blocked by the previous identity door, and the other person was not allowed to leave the door open.
        //    The path by `test_openSeries_onlyTheRegisteredVaultCanOpen` Single nails.
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesAlreadyOpen.selector, seriesId, address(vault)));
        vault.openSeries(meme, address(stock), expiry, STRIKE + 1);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.strike, STRIKE, unicode"That attempt didn't change the right price.");
        assertEq(s.vault, address(vault), unicode"And it's not gonna change the vault of the series.");
    }

    /// @notice CRITICAL **Receiving and Inspection (Accept and Inspection)issue #37 / #9 Retrospect: MEME The register can open a series of books.**
    ///
    /// @dev M1 It used to be here.**No permission**The remaining open is the week of the bets.
    ///      issue #23 After the six-part ruling was completed, the road was cut off and replaced by a structural door:
    ///      `msg.sender == vaultRegistry.vaultOf(memeToken)` And not zero.
    ///
    ///      The test separates the three "not him" because they are treated differently under the chain:
    ///
    ///      | Situation | `NotRegisteredVault` Third parameter |
    ///      |---|---|
    ///      | Strange. EOA To win. | The address of the vault that was registered -- there was a vault, but not you. |
    ///      | Another project's vault is for the bet. | Ibid. |
    ///      | This one. MEME It's not registered at all. | `address(0)`  -  -  It doesn't have a vault. Nobody can open its series. |
    ///
    ///      The last line is the most critical nature of the door:**There's no way to give a single portal to a single one that already exists. MEME Supplementary registration**
    ///      (`VaultRegistry` Only the factory. The factory only the factory. VaultPortal,And... VaultPortal The government has been able to provide the money to the government and the government.
    ///      The stakes are not so hard, they are not.
    function test_openSeries_onlyTheRegisteredVaultCanOpen() public {
        address squatter = makeAddr("squatter");
        VaultStub otherVault = new VaultStub(pool);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, squatter, address(vault))
        );
        vm.prank(squatter);
        pool.openSeries(meme, address(stock), expiry, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, address(otherVault), address(vault))
        );
        otherVault.openSeries(meme, address(stock), expiry, 1);

        // Unregistered MEME:Even its own vaults can't open -- it's not on the roster.
        address unlisted = makeAddr("a MEME that never went through our factory");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, unlisted, address(vault), address(0))
        );
        vault.openSeries(unlisted, address(stock), expiry, STRIKE);

        assertEq(
            pool.series(_expectedSeriesId(meme, address(stock), expiry)).vault,
            address(0),
            unicode"None of them came out."
        );

        // The one who registered the case could do it. Without this, the three above are green on a "no one can open" scenario.
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        assertEq(pool.series(seriesId).vault, address(vault), unicode"The vault that's registered can be opened.");
    }

    /// @dev CRITICAL **The identity door was placed before "opened".** A strange address to hit an open series, and should be told
    ///      You're not this one. MEME The vault, not the "this series has been opened" -- the latter will have misperformed the rights.
    ///      A time-series error was recorded, whereby a check under the chain would go to the calendar instead of the plant for which the launch was made.
    function test_openSeries_theIdentityGateComesBeforeTheAlreadyOpenGate() public {
        vault.openSeries(meme, address(stock), expiry, STRIKE);

        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, stranger, address(vault))
        );
        vm.prank(stranger);
        pool.openSeries(meme, address(stock), expiry, 1);
    }

    /// @dev Four lines of "open and clear" are set aside -- the series cannot be closed and modified once it is opened.
    function test_openSeries_rejectsZeroTokensZeroStrikeAndNonFutureExpiry() public {
        vm.expectRevert(ClearingPool.ZeroToken.selector);
        vault.openSeries(address(0), address(stock), expiry, STRIKE);

        vm.expectRevert(ClearingPool.ZeroToken.selector);
        vault.openSeries(meme, address(0), expiry, STRIKE);

        // strike == 0 There are two consequences: the right to take shares in exchange, and #12 The "Sequence Series" decision is now in place.
        // (`n.strike != 0`)This series will be considered non-existent.
        vm.expectRevert(ClearingPool.ZeroStrike.selector);
        vault.openSeries(meme, address(stock), expiry, 0);

        uint64 now_ = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExpiryNotInFuture.selector, now_, now_));
        vault.openSeries(meme, address(stock), now_, STRIKE);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExpiryNotInFuture.selector, now_ - 1, now_));
        vault.openSeries(meme, address(stock), now_ - 1, STRIKE);
    }

    //   And you're gonna be

    /// @dev CRITICAL **The core of the note.**:The amount of the cast is equal to the amount of the transfer tax in the stock token.**Actual amount received**,This does not equal the amount requested.
    ///      Press `expectedAmount` Casting is all about the space. 3% The certificate of authority, and the extra part of it is not matched by collateral...
    ///      No Variable 1 It's useless and it's only exposed to the first user who loses the right to move.
    function test_depositAndMint_mintsWhatArrived_notWhatWasRequested() public {
        stock.setTaxBps(300); // 3%,and Flap The default sales tax is the same.
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 requested = 1000 ether;
        uint256 arrived = 970 ether;

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Deposited(seriesId, address(vault), address(distributor), requested, arrived);
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), requested);

        assertEq(minted, arrived, unicode"Return value is the actual casting amount");
        assertEq(stock.balanceOf(address(pool)), arrived, unicode"I'm sure I've only got so much more.");
        assertEq(call.balanceOf(address(distributor), seriesId), arrived, unicode"The license is cast at the bill.");

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.deposited, arrived, "deposited");
        assertEq(s.minted, arrived, "minted");
    }

    /// @dev No Variable 2 form of certainty: volume of arbitrary request, amount of casting under arbitrary tax == Increased pool balance.
    function testFuzz_depositAndMint_mintsExactlyTheBalanceDelta(uint96 requested, uint16 taxBps) public {
        taxBps = uint16(bound(taxBps, 0, 10_000));
        stock.setTaxBps(taxBps);
        // The gold is not in the bank of money it doesn't have -- the balance is insufficient. ERC-20 It's not the claim that's going to be said.
        requested = uint96(bound(requested, 0, stock.balanceOf(address(vault))));

        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 before = stock.balanceOf(address(pool));
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), requested);
        uint256 delta = stock.balanceOf(address(pool)) - before;

        assertEq(minted, delta, unicode"No Variable 2:Casting == Increased pool balance");
        assertEq(
            call.balanceOf(address(distributor), seriesId),
            delta,
            unicode"The balance of the certificate is of the same calibre."
        );
        assertEq(pool.series(seriesId).minted, delta, "minted");
        assertLe(minted, requested, unicode"Taxes only make the books smaller, not more.");
    }

    function test_depositAndMint_accumulatesAcrossDeposits() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        vault.depositAndMint(seriesId, address(distributor), 400 ether);
        vault.depositAndMint(seriesId, address(distributor), 600 ether);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.deposited, 1000 ether, "deposited");
        assertEq(s.minted, 1000 ether, "minted");
        assertEq(
            call.balanceOf(address(distributor), seriesId), 1000 ether, unicode"The same identity. Two of them. id"
        );
    }

    /// @dev Acceptance and acceptance clauses:**Use all quantities raw `balanceOf` Unit.**
    ///      EIP-8056 The shares are changed by `uiMultiplier`,`balanceOf` Nothing - so once. 2:1 Disassembly
    ///      Ikei accounts**It should not have any impact.**.If one of the "screw" people reads the display multipliers into the books, it's not a good idea to read them.
    ///      This test will turn red on the spot.
    function test_depositAndMint_isRawAccounting_soASplitChangesNothing() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), 100 ether);

        stock.setUiMultiplier(2e18); // 2:1 Disassembly shares: double the value of the display,raw Balance remains unchanged
        vault.depositAndMint(seriesId, address(distributor), 100 ether);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.minted, 200 ether, unicode"Two books were kept in exactly the same calibre.");
        assertEq(s.minted, stock.balanceOf(address(pool)), unicode"The books are the same as the pool. raw Balance");
    }

    /// @dev Acceptance and acceptance clauses:**No one calls a vault in this series. revert.** Four types of callers come once each...
    ///      Another vault, stranger. EOA,distributor,And this test contract for the deployment of the entire system.
    function test_depositAndMint_onlyTheSeriesVault() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        VaultStub otherVault = new VaultStub(pool);
        stock.mint(address(otherVault), 1000 ether);
        otherVault.approve(stock, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(otherVault), address(vault))
        );
        otherVault.depositAndMint(seriesId, address(distributor), 1 ether);

        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, stranger, address(vault))
        );
        vm.prank(stranger);
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(distributor), address(vault))
        );
        vm.prank(address(distributor));
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(this), address(vault))
        );
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        assertEq(call.balanceOf(address(distributor), seriesId), 0, unicode"Four attempts to cast a single license.");
    }

    /// @dev CRITICAL Unopened Series**Remark**,Not really.`msg.sender` The idea of a chain is not equal to zero.
    ///
    ///      `address(0)` I'm here to do two jobs: it's a "sitting line not yet open" and it's a "sitting line."
    ///      `msg.sender` value of location. Write only `msg.sender != s.vault` If you do, these two identities will be open.
    ///      **Collapse into the same value**  -  -  The zero-point caller happened to pass the call, and then... `stockToken == address(0)`
    ///      Top `balanceOf` Yes. revert...... Which means this door is a dead end.**Another contract's accidental act.**Close.
    ///      Same `PoolBound.onlyPool` The alternative: to write "no before opening" into a structure is cheaper than to post an external hypothesis.
    function test_depositAndMint_rejectsUnopenedSeries_includingAZeroAddressCaller() public {
        uint256 unopened = _expectedSeriesId(meme, address(stock), expiry);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        vault.depositAndMint(unopened, address(distributor), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        vm.prank(address(0));
        pool.depositAndMint(unopened, address(distributor), 1 ether);
    }

    /// @dev `deposited` / `minted` Yes. `uint128`,And... ERC-20 The number is... `uint256`.
    ///      Naked conversion.**Quiet cut.**:Deposit 2^128 + 5 It'll be in the book. 5,The license is on. 2^128 + 5 Cast out.
    ///      Real GME I can't get to that scale, but the pool is right.**Any**The stock tokens are open -- the door to the series says,
    ///      MEME The identity of the vault,`stockToken` This pool is not explained, nor can it be explained.
    function test_depositAndMint_rejectsAmountsThatDoNotFitUint128() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        stock.mint(address(vault), tooBig);

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        vault.depositAndMint(seriesId, address(distributor), tooBig);

        // The other side of the border works as usual.
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), type(uint128).max);
        assertEq(minted, type(uint128).max, unicode"The one that fits.");
    }

    /// @dev CRITICAL Balance discrepancy**Natural sensitivity to re-entry.**:The transfer of the inner layer will be counted again.
    ///      The collateral comes in. `T1 + T2`,The certificate is forged. `T1 + 2T2`.See `ReentrantStockToken` .
    ///
    ///      This test is denied to the inner layer.**And the outer layers are still accurate.**  -  -  Just say, "The whole pen." revertIt's a weaker story.
    ///      It can't even say "is it the holding it?"
    function test_depositAndMint_isNotReentrant() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        VaultStub reentrantVault = new VaultStub(pool);
        reentrant.mint(address(reentrantVault), 1000 ether);
        reentrantVault.approve(reentrant, type(uint256).max);

        // If the other vault is to open a series, it has to be.**The other one. MEME** Registered: one MEME There is only one legal vault.
        address reentrantMeme = makeAddr("MEME of the reentrancy project");
        factory.bind(reentrantMeme, address(reentrantVault));

        uint256 seriesId = reentrantVault.openSeries(reentrantMeme, address(reentrant), expiry, STRIKE);
        reentrant.armReentrancy(
            address(reentrantVault),
            abi.encodeCall(VaultStub.depositAndMint, (seriesId, address(distributor), 100 ether))
        );

        uint256 minted = reentrantVault.depositAndMint(seriesId, address(distributor), 400 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"Precondition: Reconverting is actually in.");
        assertFalse(reentrant.reentrySucceeded(), unicode"The internal deposit must be denied.");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the rejection was re-entry."
        );

        assertEq(minted, 400 ether, unicode"outer casting == Actual amount received");
        assertEq(
            stock.balanceOf(address(pool)), 0, unicode"The balance of the pool in the other stock token is irrelevant."
        );
        assertEq(reentrant.balanceOf(address(pool)), 400 ether, unicode"The collateral matches the amount of the cast.");
        assertEq(call.balanceOf(address(distributor), seriesId), 400 ether, unicode"The license didn't make one more.");
    }

    /// @dev CRITICAL **Second, the path to the surrender of control.**:`call.mint` Forced recall of contract recipients `onERC1155Received`.
    ///      The last test is the stock token is re-directed in the transfer; this is the one that shows that the stock token is in the transfer.**Recipients**Revert the moment the permit was received.
    ///
    ///      The payee here has a series of his own, so it's...**The vault in that series.**  -  -  It's re-trieving.
    ///      **Pass.**Authorise inspection. Only hold it back. `nonReentrant` One thing, that's what we're gonna say.
    function test_depositAndMint_isNotReentrantThroughTheCallCallback() public {
        ReentrantCallReceiver receiver = new ReentrantCallReceiver(pool);
        stock.mint(address(receiver), 1000 ether);
        receiver.approve(stock, type(uint256).max);

        // The recipient's own series -- it has to be.**The other one. MEME** Registered: one MEME There is only one legal bank.
        // The test is for "the inner layer is itself completely legal and is still blocked by re-entry."
        address receiverMeme = makeAddr("MEME of the receiver's own project");
        factory.bind(receiverMeme, address(receiver));
        uint256 ownSeries = receiver.openOwnSeries(receiverMeme, address(stock), expiry + 1 days, STRIKE);
        receiver.armReentrancy(50 ether);

        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        uint256 minted = vault.depositAndMint(seriesId, address(receiver), 100 ether);

        assertGt(receiver.reentryAttempts(), 0, unicode"Precondition: Reconverting is actually in.");
        assertFalse(
            receiver.reentrySucceeded(),
            unicode"The internal deposit must be denied - even if the caller is a legitimate vault"
        );
        assertEq(
            receiver.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the denial was re-entry, not authorization to check."
        );

        assertEq(minted, 100 ether, unicode"outer casting == Actual amount received");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"The collateral came in once.");
        assertEq(call.balanceOf(address(receiver), seriesId), 100 ether, unicode"The license was only cast once.");

        ClearingPool.Series memory own = pool.series(ownSeries);
        assertEq(own.deposited, 0, unicode"The series in the inner layer didn't go in for a penny.");
        assertEq(own.minted, 0, "minted");
        assertEq(call.balanceOf(address(receiver), ownSeries), 0, unicode"And no call.");
    }

    /// @dev I don't read the balance of the license. I don't read the balance. `to` Who is it? - But when it's made to the recipient of the contract, ERC-1155 It's gonna force a callback.
    ///      distributor I can catch it. `ERC1155Holder`),A contract that doesn't make a return must be made revert Stop it.
    ///      Otherwise, the Council will be found somewhere that will never be taken out.
    function test_depositAndMint_mintsToWhoeverTheVaultNames() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        address holder = makeAddr("some holder");

        vault.depositAndMint(seriesId, holder, 10 ether);
        assertEq(call.balanceOf(holder, seriesId), 10 ether, unicode"EOA I can take it.");

        // Break Specific error,It's not empty. `expectRevert()`  -  -  The latter, even if it was "solded for other reasons that failed", would be accepted as a pass.
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(registry)));
        vault.depositAndMint(seriesId, address(registry), 10 ether);
    }
}
