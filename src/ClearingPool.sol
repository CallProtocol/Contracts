// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {IIssuerCompliance, IIssuerGatedStock, IIssuerPauseManager} from "./interfaces/IIssuerGating.sol";
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";
import {ICall} from "./interfaces/ICall.sol";

/// @title ClearingPool
/// @notice CRITICAL **Non-upgradable, one contract per chain, only one to hold a user ' s claim.**
///
/// # The entire design principle of this contract is that it is as few functions as possible and has no administrator.
///
/// We're committed to "refundability is structurally incontrovertible." That's the only thing that's going on.**There's no privileged path to move collateral in the pool.**Time
/// It was created -- so here.**None admin,None pause,None withdraw,None upgrade**,The text is written at six different points:
///
/// | Functions | Who can switch? |
/// |---|---|
/// | `openSeries` | **The MEME The vault that was registered with the identity quon.**;The same series can only be opened once (see below). |
/// | `depositAndMint` | The vaults of the series |
/// | `exercise` | the beneficiary himself, or `MerkleDistributor` |
/// | `pokeGating` | Anyone. |
/// | `settleExpired` | Anyone. |
/// | `rollExpired` | Anyone. |
///
/// "There's no seventh thing, but it's impossible to prove by listing the functions that you called -- and then adding them. `withdraw`
/// It's not gonna expire because no one called it. So it's... `test/ClearingPool.t.sol` Read and compile the product. ABI All the external entrances are in full possession.
///
/// CRITICAL **Function set to M1-7(#12)Just fill it up. No variables. 5 And that's why it's here.** It has two faces. One cannot:
/// The structural aspects were that time. ABI The first of these is the listing (there is no seventh entrance); the dynamic is the six entrances running in any order.
/// Pool balance of each stock token**Only `exercise` It's been reduced and it's just a matter of weight.**  -  -
/// "It's called "`minted > exercised` The government has been able to stop the sale of the collateral from being transferred from the contract."`rollExpired` I'm not sure I'm going to be able to get back to the pool.
/// It's a dynamically positive one. wei Don't move. I'll see you on both sides.
/// `test/invariant/Invariant5And7RollAndCustody.t.sol`.
///
/// # The four dependencies are real. `immutable`
///
/// No written path after deployment - replaceable = Could be pointed at a constant return false The contract. = The government has been able to block all the rights.
/// Or be pointed at a list of legal vaults for everyone. = The authorization is simply invalid.
/// The ring is a reliable one.**Satellite side**I'm not gonna have to do this. CREATE2,See {PoolBound},
/// {CallVaultFactory} and `docs/spec.md`.
///
/// # Who's the vault of the series? The one who's registered in the identity box.
///
/// `openSeries` Request **`msg.sender == vaultRegistry.vaultOf(memeToken)` and not zero**,
/// It's the only one who can do it after that. `depositAndMint`.The roster is our own, independent, unalterable.
/// {CallVaultFactory} is the immutable writer of {VaultRegistry}. It creates and
/// binds the vault during the official VaultPortal launch transaction.
///
/// So, "For one that already exists." MEME "Registered Treasury."**There's no entrance.**:It's not harder to win. It's not there.
/// (issue #23 The judgement 2,One vote to reject, which is to be taken in the most accurate manner).
///
/// CRITICAL **This door is... fail-closed And it's on a non-upgradable contract.**  -  -  So the "Question the Roster" thing.
/// It must be impossible to fail:{IVaultRegistry-vaultOf} Once. mapping Read, no external calls, no arithmetic, no. `require`,
/// Unbound Return `address(0)` No, I'm not. revert(The judgement 4,`test/VaultRegistry.t.sol` Nail it.
///
/// It can. fail-closed,Because...**Four are going to move the collateral without reading it.**:`depositAndMint` Yes.
/// It's from the series. `s.vault`,`exercise` / `settleExpired` / `rollExpired` The identity of the vault is not at all involved.
/// Even if the whole thing fails, the series that has been opened is kept, let's go, settled, rolled -- the worst consequence is "no new series."
/// Offline with the vault operator. This is with 5.1 The "door control" is better than "the door" fail-openNo contradiction:
/// From the issuer**External**Registration form, installed in**- The collateral.**The path,fail-closed The collateral will freeze forever.
///
/// > **History**:M1 It used to be here.**No permission** 'Cause there wasn't a single truth  Flap Process validated
/// > It's not a change of identity. The alternative is here. M1 It's unverifiable. The remaining open is the week of the bets, and it relies on it.
/// > The sorter doesn't run, doesn't review the external hypothesis -- 2026-08-13 issue #23 The blogger says that the government is not going to allow the government to take action.
/// > **That hypothesis is rejected.**,The structural door above.issue #21 And that relief is so...**Not applicable**
/// > (The new distribution activity observation is: issue #42,Normal priority, not on-line blocking).
/// > Evidence:`test/fork/RobinhoodVaultIdentity.t.sol`,`test/fork/RobinhoodCallVaultFactory.t.sol`,
/// > `test/VaultRegistry.t.sol`,`docs/research/flap-vault-identity-spike.md`,
/// > Decision-making records `docs/design.md` 10-34 / 10-36.
///
/// @dev Six Functions**All delivered**:Open series and deposit cast (M1-4,issue #9),Right to exercise (art.M1-5,issue #10),
///      Door-controlled observation and maturity settlement (Presentation)M1-6,issue #11),Pool Circulation (CyberCluster)M1-7,issue #12);
///      Open the line of identification door. M2-5(issue #37)It is loaded with the plant and the deployment connection.
contract ClearingPool is IClearingPool, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice A series of full state.
    ///
    /// @param vault       Open the vault of the series... **One**Right. `depositAndMint` The address.
    ///                    `address(0)` This is a series that has not yet been opened.
    /// @param memeToken   Demolition of tokens in power
    /// @param stockToken  Mortgages.
    /// @param expiry      Due date
    /// @param strike      Right-of-hand price: per cent **1e18 raw Units**Stock tokens need to be destroyed. MEME(raw).
    ///                    Right-of-the-hand formula `memeAmount = amount * strike / 1e18`(- Take it down. See. {exercise}.
    ///                    Write when the series is opened, and thereafter**There's no path to change it.**.
    /// @param deposited   Stock tokens deposited cumulatively (in millions of dollars)raw `balanceOf` Units, including `rollExpired` Rolling volume)
    /// @param minted      Casted certificate
    /// @param exercised   Right to be exercised (part of the destruction certificate exchanged)
    /// @param remainder   Residual amount to be rolled after settlement ({settleExpired} Writing,{rollExpired} (c) Consumption and Zero
    /// @param settled     Settlement already settled (%){settleExpired} Write it down.`settled  Non-feasible right, non-repossession`
    ///
    /// @dev Field Order By**Store Slot**Lined, not readable:`vault + expiry + settled` Just in a slot.29 bytes),
    ///      Five. `uint128` The first four two-to-two pairs.`strike + deposited`,`minted + exercised`),
    ///      `remainder` It's the sixth slot alone. It's written once in the series, once in the book, and it's real here. gas.
    struct Series {
        address vault;
        uint64 expiry;
        bool settled;
        address memeToken;
        address stockToken;
        uint128 strike;
        uint128 deposited;
        uint128 minted;
        uint128 exercised;
        uint128 remainder;
    }

    /// @dev CRITICAL Do Not Start Auto getter,Change `series()` Returns the entire structure: 10 fields in position bytes
    ///      It's too easy to read the wrong place under the test and the chain. `minted` and `exercised` Same size,
    ///      The sequence compiler is silent. This is the only place where the field name is read.
    mapping(uint256 seriesId => Series) internal _series;

    /// @notice Each stock is a single issuer door control observation record.
    ///
    /// @param active     Last observation**Hit.**The window is open during the hit.
    ///                   Actual stock delivery remains subject to the transfer door control of the issuer ' s token.
    /// @param unreadable Last observation**I can't read.**Door control. view(fail-open Status.
    /// @param clearedAt  The last time I left the gate,`0` It means that no departures have ever been observed -- there's no grace.
    ///
    /// @dev CRITICAL In the specification `Gating` Only two fields (in`active` / `clearedAt`).**The third field is heavy.**:
    ///      fail-open The grace must be bound to the "**Enter**The change is not "readable" but "improvement" at the time.
    ///      Without it, it's all about "the new situation." `clearedAt`,So every time I can't read it, I re-mark it.
    ///      5.1 That's what the "face of attack" said. Three fields. 10 Bytes, same slot, few flowers. gas.
    ///
    ///      Construct the constant `unreadable  !active`:When in unreadable `active` Clear it out.
    ///      (The government has also been able to provide a better understanding of the issue of the Internet.**Press Undo**).So three combinations of values are three states:
    ///      Clean. `(false,false)`,Door control. `(true,false)`,Unreadable `(false,true)`.
    struct Gating {
        bool active;
        bool unreadable;
        uint64 clearedAt;
    }

    /// @dev CRITICAL Do Not Start Auto getter,Change `gating()` Returns the whole structure - Reasons same `_series`:
    ///      `active` and `unreadable` Same and adjacent, position bytes, and sequence compilers without a sound.
    ///      The two Boers are meant to be the opposite (one is "Does it have a deadline" and the other is "Do we see it?").
    ///      Internal visibility has a second purpose: non-variant testing.**Counter-argument**I'm gonna have to be able to put one "every time." poke "The back door of the seal."
    ///      (See `test/invariant/Invariant4SettlementAndGating.t.sol`),And there's no hook in the production contract.
    mapping(address stockToken => Gating) internal _gating;

    /// @notice Certificate of Rights (Certificate)ERC-1155).The pool is the only casting and destroying party.
    ICall public immutable call;

    /// @notice It's a contract. `exercise` The only person on the caller's white list is the beneficiary himself.
    address public immutable distributor;

    /// @notice The statement of compliance is on file. Ikeko asked one thing: "Did this beneficiary say it?"
    IAttestationRegistry public immutable attestations;

    /// @notice CRITICAL **Treasury Identity Roots... `openSeries` The only source of the verdict on that door.**
    ///
    /// @dev True `immutable`,Same rationale as the other three: reversible = But it's pointed to a list of "everyone is a legal vault."
    ///      = The door was just off the ground. And it had no room for manoeuvre -- it was the right to issue.
    ///
    ///      The pool only sees. {IVaultRegistry}(One. view):It doesn't need to know who wrote the binding, how it was written, or how it was written.
    ///      {CallVaultFactory} creates the vault and writes the one-time binding;
    ///      {VaultRegistry} enforces the immutable writer and unique token identity.
    IVaultRegistry public immutable vaultRegistry;

    /// @notice On the exercise of power MEME The place to go.
    ///
    /// @dev CRITICAL **Yes. `0xdead`,No, it's not. `0x0`.** This is not a style selection:`FlapTaxTokenV3` It's standard. OZ It's...
    ///      `_update`,Transfer to zero. revert(`ERC20: transfer to the zero address`),And it...**No, I'm not.**
    ///      Native `burn()` / `burnFrom()`  -  -  `transferFrom(user, 0xdead, ...)` The only available destruction path.
    ///      Both are factual findings, not extrapolations:`docs/research/flap-tax-and-burn-path.md` 1.1 / 3,
    ///      And by `test/fork/RobinhoodFlapBurn.t.sol` Review of the actual contract on an ongoing basis.
    ///
    ///      The public is given an authoritative source under the chain and at the front end;WARNING It's not like it should be the other way around.
    ///      `test/ClearingPoolExercise.t.sol` Independently write dead letters.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The window of grace left to the holder ' s right of movement after the door is removed.
    ///
    /// @dev The window of the right to move during the door control is open, but the issuer may still refuse to transfer the shares; if the "discharge" is restored immediately, the time will be set for the end of the day.
    ///      A series that is released after maturity will lose the right to move at the same moment of release -- extension is nothing.
    ///      48 Hours are the time left for human reaction and the actual delivery.
    ///      The public is given an authoritative source under the chain and at the front end;WARNING It's not supposed to be the other way around.
    uint64 public constant GRACE_PERIOD = 48 hours;

    /// @notice Every time I'm in control of the door. view Read most forwards gas.
    ///
    /// @dev CRITICAL **This constant is protected against a specific attack, not defensive programming.** The observations are only written on the side of the state flip.
    ///      `clearedAt`,So if the attackers want to push it all the way, they have to repeat it.**Manufacturing**Clean. -> This side is not readable.
    ///      And "not readable" is "failed call" in terms of "no" -- just as long as the caller can decide how much to forward. gas,
    ///      He can make a whole healthy one. view Because out-of-gas And then it failed, and it was made in the following way:
    ///
    ///      ```
    ///      poke(gas Enough.) -> Clean.        poke(gas Starving.) -> Unreadable + Seal    <- Every 47 One round in the hour.
    ///      ```
    ///
    ///      `settleExpired` And it's permanent. revert  -  -  Exactly. 5.1 The "face of attack comes back from the back door."
    ///      So, before each reading, you ask for the rest of it. gas Enough. EIP-150 It's... 63/64 Rules transmitted full
    ///      `GATING_READ_GAS`,Not enough.**On the spot. revert**,The blogger says that the government is not going to read it once.
    ///      This is the threshold for every internal reading.**No, it's not.**Whole `pokeGating` Deal. gas limit.
    ///
    ///       50,000 It's based on the facts: real. GME The last three reads combined were far below it.
    ///      (`test/fork/RobinhoodGating.t.sol::test_gasBudget_theRealReadsFitInsideASingleBudget` Print the measured value
    ///      And it's said to be left in surplus.**Much greater than**Real expenses, no concessions. poke The government has been making a huge deal.
    uint256 public constant GATING_READ_GAS = 50_000;

    /// @notice Every time a door is read in {GATING_READ_GAS} It's not gonna leave. gas.
    ///
    /// @dev `gasleft()` Yes. `_staticWord` After reading it, it's still paid. `STATICCALL` Quick account access/Base cost and
    ///      A small number of instructions to press the parameters in a cage;EIP-150 It's at those costs.**After**I'm not gonna stop the transmission until I'm done. gas.
    ///      5,000 Overwrite Cancun  The cold accounts are accessible  `STATICCALL` Base cost, with remaining amounts of code to be used in immediate proximity.
    ///      This is not a budget that is forwarded to the issuer, but it is an extra budget that the caller must leave to ensure that the budget actually arrives. gas.
    ///
    ///      CRITICAL **It's public because it's with... {GATING_READ_GAS} It's the same formula in two.** The government has been making a public statement about the situation.
    ///      Even if you don't get the door under the chain, how much is it? gas  -  -  And this door is checked every time it's read.
    ///      Monitor Every single one of them. poke Hit it! `NotEnoughGasToObserveGating`.
    ///      WARNING Both constants and their derivative thresholds.**No, it's not.**The whole deal. gas limit:They only describe Pool Before each internal reading
    ///      Enforcement that must be retained gas.Top intrinsic/calldata,Call the path and any wrapper They are not in it;Monitor
    ///      It must be done by the actual call path. `eth_estimateGas` And leave a residual amount. The same name measure for the fork test is only two minutes. harness In Pool
    ///      Forwarded child-call gas,We can't push it into a deal. limit.
    uint256 public constant GATING_STATICCALL_OVERHEAD = 5000;

    /// @notice A new series has been created. Every single one of the life cycles. `seriesId` It's gonna happen at most once.
    event SeriesOpened(
        uint256 indexed seriesId,
        address indexed vault,
        address memeToken,
        address stockToken,
        uint64 expiry,
        uint128 strike
    );

    /// @notice Put in the collateral and cast the call.
    /// @dev CRITICAL `expectedAmount` and `minted` **Both.**:The difference between the two is that the stock is in this amount.
    ///      The transfer tax. One less. The chain is based on guess or go. diff The balance is the difference.
    ///      The witness. `TransferSingle` By ERC-1155 Send it yourself, here and here.
    event Deposited(
        uint256 indexed seriesId, address indexed vault, address indexed to, uint256 expectedAmount, uint256 minted
    );

    /// @notice Right to exercise: Certificates destroyed,MEME To `BURN_ADDRESS`,The shares have been in the hands of the beneficiaries.
    ///
    /// @param caller     Sponsor - the beneficiary himself, or `distributor`.Certificate from**It's...**It's destroyed there.
    /// @param amount     Right of line (in the case of rights)raw The shares are also destroyed.
    /// @param memeAmount **Transfer**It's... MEME Number, not necessarily equal to `BURN_ADDRESS` Received
    ///
    /// @dev CRITICAL `memeAmount` It's a number taken from the beneficiary's account, and the chain is "how much has it burned?" MEME Side
    ///      `Transfer`.Today, they're equal. Flap  And the way to destroy **The behavior of the outside contract now.**,
    ///      It's not a contract guarantee. `exercise` Why is there no balance reconciliation here?
    event Exercised(
        uint256 indexed seriesId,
        address indexed caller,
        address indexed beneficiary,
        uint256 amount,
        uint256 memeAmount
    );

    /// @notice A door control observation was completed.
    ///
    /// @param gated     This time, read the signal in real time.
    /// @param readable  Three. view Read all of them.`false` = fail-open Status)
    /// @param clearedAt Observations**After**The time of the de-escalation on record -- it's not the same as this.
    ///
    /// @dev CRITICAL **Each observation is sent, including those that have not been reversed.** "Only on the side."
    ///      `clearedAt` / `active` Both.**Storage**,It's not an event: the chain has to distinguish between "we have seen it, it's clean."
    ///      And "the pen." poke "It was this incident that happened in the first case."
    ///      11 The "only one" is left here -- clean pool.  `gated == false`
    ///       The user was informed by the front end that "you were sealed separately and the path to self-help was to sell the certificate of right".
    event GatingObserved(address indexed stockToken, bool gated, bool readable, uint64 clearedAt);

    /// @notice The series is closed.`remainder` Wait {rollExpired} Roll into the follow-up series.
    /// @param deadline The closing time for the right to move in effect at the time of settlement -- the door delay pushed it to the point where it could only be read below the chain.
    event Settled(uint256 indexed seriesId, uint128 remainder, uint64 deadline);

    /// @notice The remainder of the maturity has been rolled into the subsequent series.
    ///
    /// @param amount Roll stock -- also in front of the front `remainder` of the Convention, subsequent `deposited` / `minted` The incremental,
    ///               And cast. `distributor` . No variables 7 The four numbers are the same.
    ///
    /// @dev CRITICAL **There was no transfer in this case.** A collateral. wei None of them left this contract...
    ///      If you want to check under the chain, read the "the stock's currency balance is in the pool before and after the transaction."**No change.**,
    ///      Not to find one. ERC-20 It's... `Transfer`.It's right to not find it.
    event Rolled(uint256 indexed seriesId, uint256 indexed nextSeriesId, uint128 amount);

    error ZeroAddress();

    error ZeroToken();
    error ZeroStrike();
    error ExpiryNotInFuture(uint64 expiry, uint256 timestamp);
    error SeriesAlreadyOpen(uint256 seriesId, address vault);
    error SeriesNotOpen(uint256 seriesId);
    error NotSeriesVault(uint256 seriesId, address caller, address vault);

    /// @dev CRITICAL That's not the one calling it. MEME The vault registered in the identity root... `openSeries` That door.
    ///
    ///      **I want you to report the answer to the root of identity.**,Because of this. revert There are two completely different causes.
    ///      The only ones who call are the same:
    ///
    ///      | `vault` | Annotations |
    ///      |---|---|
    ///      | `address(0)` | This one. MEME **Never launched through our factory.**  -  -  It doesn't have a vault. Nobody can open its series. |
    ///      | Non-zero | There's a vault, but not you. |
    ///
    ///      The former is a business problem. / The latter is a question of competence.
    error NotRegisteredVault(address memeToken, address caller, address vault);

    /// @dev The caller is neither the beneficiary nor the beneficiary. `distributor`.
    error NotExerciseCaller(uint256 seriesId, address caller, address beneficiary);
    error SeriesSettled(uint256 seriesId);

    /// @dev `deadline` Report it alone because it**Not equal to** `expiry`:The door's been extended and it's going to be pushed back.
    ///      Just report. `expiry` "Why did I get rejected before I was due?" / The right to exercise after expiry is not explained below the chain.
    error ExerciseWindowClosed(uint256 seriesId, uint64 deadline, uint256 timestamp);
    error NotAttested(address beneficiary);

    /// @dev This one's for destruction. MEME After the whole thing is down. 0  -  -  See `exercise` Why must it be rejected.
    error ExerciseRoundsToZeroMeme(uint256 seriesId, uint256 amount, uint128 strike);

    /// @dev MEME The transfer was allegedly successful, but the actual amount withheld by the beneficiary was not calculated at the right-of-hand value.
    error MemeTransferDebitMismatch(
        uint256 seriesId, uint256 expectedDebit, uint256 balanceBefore, uint256 balanceAfter
    );

    /// @dev The stock tokens claimed that the transfer had been successful, but the actual amount withheld by the pool was not a weight.
    error StockTransferDebitMismatch(
        uint256 seriesId, uint256 expectedDebit, uint256 balanceBefore, uint256 balanceAfter
    );

    /// @dev The settlement is controlled by the door.**Structural Blocking**  -  -  This is "a automatic postponement when the issuer freezes" and it's not an error.
    ///      The line of rights window remains open; if the issuer still prevents the transfer of shares, the call will still return the atom.
    ///      Releaser release, right of movement**Now.**Available (windows open, transfer released); then the release is observed.
    ///      Window Condense As `max(expiry, clearedAt + {GRACE_PERIOD})`.
    error SettlementGatedByIssuer(uint256 seriesId, address stockToken);

    /// @dev It's not yet time to settle.`deadline` Report it individually because the door's delayed and it's pushed to the top. `expiry` After that.
    error SettlementTooEarly(uint256 seriesId, uint64 deadline, uint256 timestamp);

    /// @dev Caller for gas Not enough to keep the door open. view **Full budget read**.See {GATING_READ_GAS}:
    ///      Here. revert It's not a "implemented" attack, it's the whole line of defense.
    error NotEnoughGasToObserveGating(uint256 needed, uint256 available);

    /// @dev It's not settled yet.`remainder` It's not settled yet -- there's no way to roll. {settleExpired}.
    error SeriesNotSettled(uint256 seriesId);

    /// @dev `remainder == 0`:This series has no surplus to roll (or has already been rolled once).
    ///      This door is the only one that can be realized without double roll. {rollExpired}.
    error NothingToRoll(uint256 seriesId);

    /// @dev The sequence is not the same as the front line. (MEME, Stock tokens) Yeah.**It's a quote from the rest of the line.**,
    ///      The caller knows what the wrong dimension is when comparing it to the sequence he passed on.
    error SuccessorTokenMismatch(uint256 nextSeriesId, address memeToken, address stockToken);

    /// @dev The follow-up series has passed its own. `expiry`.The only way to get in is to create a body of valid rights.
    ///      You can restore a new series that expires in the future -- only delay, no loss.
    error SuccessorExpired(uint256 nextSeriesId, uint64 expiry, uint256 timestamp);

    /// @param call_        `Call`
    /// @param distributor_    `MerkleDistributor`
    /// @param attestations_   `AttestationRegistry`
    /// @param vaultRegistry_  `VaultRegistry`  -  -  The government has been working on the issue of the identity of the Treasury.`openSeries` The source of the door.
    ///
    /// @dev The four addresses are permanently valid, so the zero addresses are blocked here -- the error is only one pool that can be redeployed.
    ///      The "redeployment" is an option that does not exist for a contract that holds collateral.
    ///
    ///      CRITICAL **I don't want to check these four addresses for bytes.** and {PoolBound-setPool} No. No. 4 Door is different:
    ///      When you tie it up, the pool.**It must have been deployed.**,No byte code is the wrong address; this is the same root as the pool
    ///      Deployment ring (inward)`factory` -> `launcher` -> `VaultRegistry(launcher, slot)` -> `ClearingPool(..., registry)`),
    ///      Add one. `code.length` Checking only limits the legitimate deployment.
    ///      `script/DeploySystem.s.sol` The claim at the end of the article `script/verify-deployment.sh` Checkback on chain...
    ///      CRITICAL **And the opposite is "never set up" and the pool can't change.**(spike 9 The last hard-on.
    constructor(ICall call_, address distributor_, IAttestationRegistry attestations_, IVaultRegistry vaultRegistry_) {
        if (
            address(call_) == address(0) || distributor_ == address(0) || address(attestations_) == address(0)
                || address(vaultRegistry_) == address(0)
        ) {
            revert ZeroAddress();
        }
        call = call_;
        distributor = distributor_;
        attestations = attestations_;
        vaultRegistry = vaultRegistry_;
    }

    /// @notice Read all fields of a series. Unopened series returns zero (in thousands of cases)`vault == address(0)`).
    function series(uint256 seriesId) external view returns (Series memory) {
        return _series[seriesId];
    }

    /// @notice Read a door-to-door observation of a stock token. Never been. poke The last coin returned to zero -- "clean, no grace"
    /// @dev **The contract only contains documented observations.**:The door control happened, but nobody. poke,No extension will occur.
    ///      And this... poke Be Monitor It's a rigid business, but it's not licensed -- any holder can do it himself.
    function gating(address stockToken) external view returns (Gating memory) {
        return _gating[stockToken];
    }

    /// @notice A series.**Current**. The door control observation returns `type(uint64).max`(No cut-off).
    ///
    /// @dev To Front End and Monitor Read:`ExerciseWindowClosed` Only when it's rejected. deadline,
    ///      The question "how long do I have to be?" is a question to be answered before you can get to the right.
    ///      WARNING Unopened series returns here `0`,No, no. revert  -  -  It reads a zero-sum record, nothing else to say.
    function exerciseDeadline(uint256 seriesId) external view returns (uint64) {
        return _exerciseDeadline(_series[seriesId]);
    }

    /// @notice Series identifier:`keccak256(abi.encode(memeToken, stockToken, expiry))`,It's also a call. ERC-1155 id.
    ///
    /// @dev `memeToken` In there.**Required**,Not by the way it goes: the right to destroy is the same as the other projects. MEME,
    ///      It is impossible to pay different assets in the same way (i)`docs/spec.md`).Without this dimension,
    ///      The SEC shares the same project. id,The same collateral is shared.
    ///
    ///      It's open to the vault.M2)With the service under the chain.**One.**The authority source -- the same formula is copied twice,
    ///      Sooner or later, it'll float.WARNING But it should not be used to test itself:`test/ClearingPoolMinting.t.sol`
    ///      A self-determined expectation.
    function seriesIdOf(address memeToken, address stockToken, uint64 expiry) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(memeToken, stockToken, expiry)));
    }

    //  Externally available: six
    //
    // Sign and Document Live {IClearingPool}  -  -  Six functions are dispersed on four tickets, and signatures should have only one source.
    // M1-7(#12)Then all six land, and there are no more signature-only functions.
    //
    // CRITICAL Add a seventh down, equal to adding a non-upgraded hosting contract -- no variables 5 It's off the spot.

    /// @inheritdoc IClearingPool
    ///
    /// @dev Five sets of lines to block one "screw out" thing -- once the series is opened,**Unable to close, not modify**:
    ///      (1) Zero address tokens - Wrong address. First deposit `balanceOf` Yes. revert,And then the man is gone;
    ///      (2) `strike == 0`  -  -  (b) Take shares in exchange; and #12 The "sequence series" is now open.
    ///         `n.strike != 0`,The Zero Price series is not available in the eye;
    ///      (3) The one that's not in the future -- the one that's born and died: the one that's made is not in control.
    ///         (The collateral's still gonna work. {settleExpired} + #12 (a) The removable, but the holder of the certificate has lost it);
    ///      4 CRITICAL **That's not the one calling it. MEME Registered vault**  -  -  See {NotRegisteredVault} (a) The head of the contract;
    ///      5 It's open - it's "only once" and "the price of the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the right to the
    ///
    ///      CRITICAL 5 The guard is... `vault != address(0)`,No, it's not. `strike != 0`.They're here for the same price.
    ///      ((2)It's guaranteed the opening series. strike But the former said "anyone has ever driven"
    ///      It's the one that's going to judge.
    ///
    ///      4 Line up. 5 **Before**:A strange address to hit an open line, and it's time to be told, "You're not this one. MEME The government has been working on the issue.
    ///      The first time I was able to get a license, I was able to get a "serial" in the first place, not "this series has been opened" -- the latter would have reported a time-series error.
    ///      By-law:`vaultOf` Always revert,So this door is just... revert Yes.**We're alone.**It's... `if` Go on.
    ///
    ///      WARNING 4 The two conditions are written in one sentence:`bound == address(0)` The government has been able to provide a better understanding of the situation.
    ///      And the zero-point caller can't get past it. `msg.sender != bound`  -  -  But it's a zero-point deal.
    ///      This one about**Chain**And that's the assumption. {PoolBound-onlyPool} Same trade-off: Written in structure, without assumptions.
    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId)
    {
        if (memeToken == address(0) || stockToken == address(0)) revert ZeroToken();
        if (strike == 0) revert ZeroStrike();
        if (expiry <= block.timestamp) revert ExpiryNotInFuture(expiry, block.timestamp);

        address registered = vaultRegistry.vaultOf(memeToken);
        if (registered == address(0) || msg.sender != registered) {
            revert NotRegisteredVault(memeToken, msg.sender, registered);
        }

        seriesId = seriesIdOf(memeToken, stockToken, expiry);
        Series storage s = _series[seriesId];
        if (s.vault != address(0)) revert SeriesAlreadyOpen(seriesId, s.vault);

        s.vault = msg.sender;
        s.memeToken = memeToken;
        s.stockToken = stockToken;
        s.expiry = expiry;
        s.strike = strike;

        emit SeriesOpened(seriesId, msg.sender, memeToken, stockToken, expiry, strike);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev CRITICAL **Castery is based on the increase in the balance before and after transfer, and is not `expectedAmount` Yes.**
    ///      Stock tokens may carry transfer taxes, and cast the required amount directly causes over-spending -- and over-sale to the first failed user.
    ///      It's only exposed. It's not defensive programming, it's the definition of the path.
    ///
    ///      `nonReentrant` Same burden: balance balance balance booking**Natural sensitivity to re-entry.**.The money is being transferred back and forth, and the money is being transferred back and forth.
    ///      The transfer will be counted from the outer layer, and the collateral will come in. `T1 + T2`,The certificate is forged. `T1 + 2T2`.
    ///      And the pool is right.**Any**The stock is all on.`openSeries` No permission) this path can be reached.
    ///      -Punished. `test/ClearingPoolMinting.t.sol::test_depositAndMint_isNotReentrant`.
    ///      It's on the... transient The version (in the form of a copy)EIP-1153):TSTORE/TLOAD Already Robinhood Chain The project is being supported.
    ///      See `foundry.toml` Lee. `evm_version` . The comment and the restart command.
    ///
    ///      Two of them.**Do not do** Checking:
    ///      - I'm out of the way. `block.timestamp >= s.expiry`  -  -  The door's been postponed. expiry The new law is still open, and the new law is still in force.
    ///        Blocking the deposit in the extension window is also blocking. `settled`,No, it's not. `expiry`;
    ///      - I'm out of the way. `minted == 0`  -  -  100% The tax's token is the honest result.revert It was the same thing that was written about the country.
    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount)
        external
        nonReentrant
        returns (uint256 minted)
    {
        Series storage s = _series[seriesId];

        // CRITICAL Unopened and undivided from "not a vault of the series" and not merged into a single sentence `msg.sender != s.vault`.
        //    `address(0)` I'm here to do two jobs: it's a "not yet" sentry and it's a "unopened" sentry.
        //    `msg.sender` The value of the location - the two identities will be available during the unopened period after merging**Collapse into the same value**.
        //    Same {PoolBound-onlyPool} The alternative: to write it into a structure, as opposed to "zero-point-to-no contract."
        //    This one about**Chain**The assumption is much cheaper and the cost is a comparison.
        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (msg.sender != s.vault) revert NotSeriesVault(seriesId, msg.sender, s.vault);

        // CRITICAL **The settled series shall no longer be deposited.** On settlement `remainder` It's a deal, the collateral that came in.
        //    Not here. `remainder` It's not part of any of the outstanding series, and it's stuck in the pool permanently. admin,None withdraw),
        //    And the right to one of these is not a right. 4(1)).
        //    WARNING This door is just a door.**Direct**Call. The same thing comes in from the back side -- the deposit is back in the transfer.
        //    `settleExpired`  -  -  By `settleExpired` Your own. `nonReentrant` Block it, see the notes there.
        if (s.settled) revert SeriesSettled(seriesId);

        IERC20 stock = IERC20(s.stockToken);
        uint256 balanceBefore = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), expectedAmount);

        // Balance**Less**It's gonna be spilling. revert,That's what it's all about: a token for "receiving the pool and withholding the money."
        // It must stop on the spot, not keep a seemingly normal account.
        minted = stock.balanceOf(address(this)) - balanceBefore;

        // CRITICAL Naked conversion.**Quiet cut.**:Deposit 2^128 + 5 It'll be in the book. 5,The license is on. 2^128 + 5 Cast out.
        //    Real GME I can't get to that scale, but the pool is open for any stock token.
        uint128 minted128 = SafeCast.toUint128(minted);
        s.deposited += minted128;
        s.minted += minted128;

        // The accounts are maintained prior to external calls:`call.mint` We'll call back the payees. `onERC1155Received`.
        call.mint(to, seriesId, minted);

        emit Deposited(seriesId, msg.sender, to, expectedAmount, minted);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # Five doors, in order.
    ///
    ///      | # | Door. | It's blocking that. |
    ///      |---|---|---|
    ///      | (1) | Caller  {`beneficiary`, `distributor`} | Third party selection of beneficiary |
    ///      | (2) | Series is open | See? |
    ///      | (3) | Unsolved | No Variable 4(1):On settlement `remainder` It's all settled in the books. Once you're in business, you're taking it over again. |
    ///      | 4 | Not yet. deadline | Expiry expires; the line automatically moves back during door control, see {_exerciseDeadline} |
    ///      | 5 | `attestedVersion(beneficiary) != 0` | Statement of compliance |
    ///
    ///      CRITICAL **5 Check it out. `beneficiary`,No, it's not. `msg.sender`.** distributor The right path to the right of option (in the case of the#13)Here.
    ///      **For yourself.**If you call in the identity, you find the caller.distributor Once, the user passes the door."
    ///      The door will be empty, and it is the only thing we can get when we promise to "conformity is not a disguised freeze switch."
    ///
    ///      CRITICAL **(1) Not formalism.** The beneficiary gave it to Jiji. MEME The mandate says, "I'll do it for you."**Your own.**The government has been making a huge contribution to the project.
    ///      It's not "everyone can choose me." Without this restriction, third parties can choose the moment most unfavourable to the beneficiaries.
    ///      - Get him. MEME The mandatory exchange of shares -- the amount of authority is still in, and the money is spent.
    ///
    ///      (2) and {depositAndMint} It's the same trade-off, and... M1-6 And then it's already...**Not anymore.**It's the extra door:
    ///      deadline Now. `max(expiry, clearedAt + 48h)`,A series never opened (`expiry == 0`)
    ///      Read it. `_gating[address(0)]` The record -- as long as there was one on that record. `clearedAt`,
    ///      4 It's the last line of the path, which turns to "no caller happens to be there." id The rights of the people.
    ///      Write "Set to exist first" into a clear comparison, compared to every move. deadline I'm not sure I'm going to be able to do this.
    ///      ({pokeGating} There is another zero-point door on that side, which combines to keep the record permanently zero.
    ///
    ///      # Three steps, and why the books are in front of them.
    ///
    ///      ```
    ///      s.exercised += amount                                   // Recording
    ///      call.burn(msg.sender, seriesId, amount)              // 1. Destruction of the certificate of authority (holder)
    ///      meme.transferFrom(beneficiary, BURN_ADDRESS, memeAmount) // 2. Destruction of beneficiaries MEME
    ///      stock.transfer(beneficiary, amount)                     // 3. Stock tokens directly to beneficiaries
    ///      ```
    ///
    ///      I'm sorry. 3 Step failure will return two steps in the front... **That's exactly what the product promised.**:The issuer does not lose a license when the issuer freezes.
    ///      Yes. EVM It's a default act. The only thing that can break it is a sign. `try/catch`,So no variables. 3 There's only one kind of counter-argument.
    ///      Shape (see `test/invariant/Invariant3ExerciseAtomicity.t.sol`).
    ///
    ///      `docs/spec.md`  The sketches put  `s.exercised += amount` Three steps.**After**;I'm not sure if I'm going to be able to get a chance to get a chance to talk to you.
    ///      and {depositAndMint}"The same rule. Both tokens are:**Any**The contract.
    ///      Each of them can hand over control;`nonReentrant` - I'm in the way.**Cross-function**Interlaced - Jean `settleExpired`
    ///      The move to the middle of the "right to move to half" is something that needs not to be left to the future.
    ///      (The other side is equally heavy, for the reason that {settleExpired}.)
    ///
    ///      Twice. ERC-20 After the call back was successful, check it separately**Sender**Change in balance:beneficiary It has to be done right away.
    ///      `memeAmount`,The pool must be deducted. `amount`.Otherwise... return-true/no-op The money is a sign of the security.
    ///      sender-pays-extra The tokens will be used to overtly withhold the user or to pierce the remaining certificate.
    ///
    ///      # Two of them.**Do not do**Check
    ///
    ///      - **Do not check `BURN_ADDRESS` and the balance of the project.** The side-to-side increase is due to**Super-heading.**They can blow through the payoff;
    ///        The only way to check the increase is to guarantee the deflation of the "full destruction" at the cost of:MEME The way that the road is taxed is not true.
    ///        This contract will allow**All rights**Permanent revert.I'd rather have less burning than an outsider.
    ///        Change the parameters of the contract to a brick. This is a character that is being watched by the test --
    ///        `test/fork/RobinhoodFlapBurn.t.sol` The assertion that the collection is exactly the same as the transfer is made in terms of real realization.
    ///      - **I'm out of the way. `amount > s.minted - s.exercised`.** It's by ERC-1155 The balance check structural guarantees:
    ///        The license is destroyed here, only by pressing. 1:1 It's made, it can't destroy what it doesn't have. Write it twice.
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external nonReentrant {
        Series storage s = _series[seriesId];

        if (msg.sender != beneficiary && msg.sender != distributor) {
            revert NotExerciseCaller(seriesId, msg.sender, beneficiary);
        }
        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (s.settled) revert SeriesSettled(seriesId);

        uint64 deadline = _exerciseDeadline(s);
        if (block.timestamp >= deadline) revert ExerciseWindowClosed(seriesId, deadline, block.timestamp);

        if (attestations.attestedVersion(beneficiary) == 0) revert NotAttested(beneficiary);

        // CRITICAL **Wear it down and multiply it.**,The order is heavy:`amount` Yes. `uint256`,And on the books. `exercised` Yes.
        //    `uint128`,So, sooner or later, the amount that you can't fit will be rejected. Put it in a multiplication.**Front**- No, I've got two things.
        //    (1) The product structure can be loaded up -- both factors. <= 2^1281,Jack. <= (2^1281)^2 < 2^256,
        //       So there's no need for it. `Math.mulDiv`,There's no way one of them is gonna happen. Panic(0x11);
        //    (2) The excess rights are a carry-over. `SafeCastOverflowedUintDowncast`,Not a naked one. Panic,
        //       Or worse -- the numbers that come all the way to the astronomical numbers. `memeAmount`,And then I stopped. MEME The balance was insufficient.
        uint128 amount128 = SafeCast.toUint128(amount);
        uint256 memeAmount = (uint256(amount128) * s.strike) / 1e18;

        // CRITICAL Remove Clock Down `amount * strike < 1e18` the right to exercise**One. MEME No need to burn.**,Take stock tokens for nothing...
        //    That's exactly what I'm talking about. `openSeries` It's... `strike != 0` The whole version of what the door was about to block.
        //    Here the choice is to reject rather than change to a top-up: the pricing formula is written on the specifications and interfaces and changed to a product decision;
        //    And it's safer to deny a "free" vote. `amount` That's all.
        //
        //    What's left of it?**Take a discount.**:The missing part is always the cut off fraction.**Each is less strict than 1 raw Units MEME**
        //    (That's... 1e-18 - It's a quart. dust It's on the shelf.**Relative**The ratio can be large (%)strike = 1e17,amount = 19 Time
        //    Pay. 1 Not 1.9),But...**Absolutely.**The upper bounds are crucified to death with no connection to the number of calls. < 1 raw The blogger says:
        //    And every time you pay a whole line of rights. gas  -  -  There's a gap of more than a dozen orders.
        if (memeAmount == 0) revert ExerciseRoundsToZeroMeme(seriesId, amount, s.strike);

        s.exercised += amount128;

        call.burn(msg.sender, seriesId, amount);

        IERC20 memeToken = IERC20(s.memeToken);
        uint256 memeBalanceBefore = memeToken.balanceOf(beneficiary);
        memeToken.safeTransferFrom(beneficiary, BURN_ADDRESS, memeAmount);
        uint256 memeBalanceAfter = memeToken.balanceOf(beneficiary);
        if (memeBalanceAfter > memeBalanceBefore || memeBalanceBefore - memeBalanceAfter != memeAmount) {
            revert MemeTransferDebitMismatch(seriesId, memeAmount, memeBalanceBefore, memeBalanceAfter);
        }

        IERC20 stockToken = IERC20(s.stockToken);
        uint256 stockBalanceBefore = stockToken.balanceOf(address(this));
        stockToken.safeTransfer(beneficiary, amount);
        uint256 stockBalanceAfter = stockToken.balanceOf(address(this));
        if (stockBalanceAfter > stockBalanceBefore || stockBalanceBefore - stockBalanceAfter != amount) {
            revert StockTransferDebitMismatch(seriesId, amount, stockBalanceBefore, stockBalanceAfter);
        }

        emit Exercised(seriesId, msg.sender, beneficiary, amount, memeAmount);
    }

    /// @dev The cut-off time for the right-hand window - "Auto-Extension when the issuer freezes"**All**This is the expression:
    ///
    ///      ```
    ///      active
    ///      clearedAt == 0    expiry                        // Never seen a decomposition.  No grace.
    ///      Otherwise...               max(expiry, clearedAt + 48h)
    ///      ```
    ///
    ///      CRITICAL `settleExpired` Use**Same.**Function makes complementary judgement (`>= deadline` I can only settle it.
    ///      Sooner or later, it'll be a window that can't be done, or can't be settled -- or worse, both.**- Yeah.**Do the window.
    ///
    ///      WARNING `clearedAt == 0` That line is not in the specifications. `max(expiry, 0 + 48h)` The same price? On any real chain?
    ///      Yes.`expiry` It's a... 2020 The time stamp of the age.48h = 172800 It's long past. It's just that it's been written separately. `0` Here.
    ///      Yes.**Sentry.**Not the moment: it said "no relief" instead of "no relief."1970-01-01 The government has been able to do so.
    ///      By the sentry, one of the timetamps is in the 172800 The test doesn't get a blank. 48 hour's right-wing window.
    function _exerciseDeadline(Series storage s) private view returns (uint64) {
        Gating storage g = _gating[s.stockToken];
        if (g.active) return type(uint64).max;

        // CRITICAL **Current readout (no distribution door interface)-> No respite.deadline Yeah. `expiry`.**
        //
        //    History is called "No reading." -> fail-open + 48h Lend`clearedAt` It's covered at the moment of entry. It's...
        //    Yes bStock Door interface for**Temporary**You can't read it. You can't read it.
        //    **flap.sh Any kind of priced currency**,These. quote Most of them.**No issuer**Normal/Packaging Currency(s)WBNB / USDT /
        //    DOGE / Various custom),Never. `pauseManager()` / `compliance()`,It's never gonna make sense. -> Old semantics.
        //    They...**Every week, the settlement is empty. 48 Hours**(It's a real chain of things. C2 WBNB,C3 USDT,C5 DOGE All right. `SettlementTooEarly`).
        //
        //    Relax the basis (user) 2026-09-15):**Can you... launch By Flap It's... Portal Take control,call Unconditional trust on the side
        //    Flap Portal**;Portal Having been examined token,Our door is no longer free. quote Second turnoff, for no issuer
        //    The "no freeze" of the door-controlled tokens is a fact.
        //
        //    WARNING Here. `g.unreadable` **Accurate distinction**Two caps. `clearedAt` The only way to get to the front is to ease the reading:
        //      - **I can't read.**(`g.unreadable == true`,No issuing currency)-> This line goes straight back `expiry`,No grace;
        //      - **Real bStock Freezing and Unblocking**(`_observe` It's... readable clear-edge,`g.unreadable == false`)->
        //        Down there. `clearedAt + GRACE_PERIOD`,**Retention of the grace limit in its entirety**.
        //    Cost (express): One that could have been read bStock If the door is interfaced**It just happens to be out of reading during the freeze.**(Issuer contract
        //    Destroyed/It's going to be considered clean, bypassing the freeze-deficit settlement extension-- the edge scenario, "unconditional trust." Flap Portal
        //    Trial tokenis acceptable under the model.
        if (g.unreadable) return s.expiry;

        uint64 clearedAt = g.clearedAt;
        if (clearedAt == 0) return s.expiry;

        uint64 graceEnd = clearedAt + GRACE_PERIOD;
        return graceEnd > s.expiry ? graceEnd : s.expiry;
    }

    /// @dev Read the distribution door control in real time.**It's the only "failure" reading in this contract.**.
    ///
    ///      @return hit      Door control observed (currency freeze) / The whole world is out of control. / **Pool Address**(I am not going to be punished for this.)
    ///      @return readable All five read.
    ///
    ///      # Why? fail-open
    ///
    ///      Door control. view Do not use door-controlled treatment when reading.**Ungradable**,
    ///      fail-closed It will freeze the entire series of collateral forever from an interface that can't read anymore.
    ///      **Bad as hard as fail-open The kind of loss you admit.**.The price is in `docs/spec.md`:If the coins of this time are true
    ///      Time-out view If you cannot read, the holder loses the license in a window that is completely unauthorised. 48 Hours.
    ///
    ///      # Three inconvenient details.
    ///
    ///      - **It takes precedence over failure to read.** Any reading of the door control, the conclusion is the door control -- even the rest of it doesn't make sense.
    ///        This direction will only allow the holder to take more extensions, which in turn may be settled as usual when the freezing is actually taking place.
    ///      - **No, I'm fine. `abi.decode(..., (bool))`.** It's "f." 0 Not 1 "The dirty Bore will revert,And that one. revert
    ///        It's a function that should have swallowed everything.**Come on out.**  -  -  A dirty byte-back token will allow it. poke and settlement
    ///        All revert,fail-open And it was like... fail-closed.So, press. `uint256` It's true.
    ///      - **The high places of the two modules must be clean.** The top is the other address that can be broken when the byte is dirty.
    ///        It's not "read" it's "read what you can't read" it's "not read."
    ///
    ///      # CRITICAL BSC Edit Robinhood Two more editions (decision-making) 53)
    ///
    ///      Robinhood Three.`paused` / `ACCESS_CONTROLLED_REGISTRY` / `isBlocked`),
    ///      Here are five: the manager's address,`isTokenPaused`,Compliance module address, currency-by-currency blacklist, global sanctions list.
    ///      **The door was intact.**  -  -  {_staticWord} Yes.**Read it individually.**Request `gasleft()` The government has been able to provide the necessary information to the government.
    ///      One more reading, one more door to the other, instead of putting the same budget on the table. All that's changed is that `_observe` Total gas Cost.
    function _readGating(address stock) private view returns (bool hit, bool readable) {
        //  (1) Freeze:pauseManager().isTokenPaused(stock)
        //    The currency freeze and the global stoppage fell on this reading (tests:`pauseAllTokens()` After
        //    `isTokenPaused` So I don't have to ask again. `allTokensPaused()`.
        (bool okManager, uint256 managerWord) = _staticWord(stock, abi.encodeCall(IIssuerGatedStock.pauseManager, ()));
        if (managerWord >> 160 != 0) okManager = false;

        bool okPaused;
        uint256 pausedWord;
        if (okManager) {
            (okPaused, pausedWord) =
                _staticWord(address(uint160(managerWord)), abi.encodeCall(IIssuerPauseManager.isTokenPaused, (stock)));
        }
        if (okPaused && pausedWord != 0) return (true, true);

        //  (2) Compliance: blacklist by currency + Global sanctions list
        (bool okCompliance, uint256 complianceWord) =
            _staticWord(stock, abi.encodeCall(IIssuerGatedStock.compliance, ()));
        if (complianceWord >> 160 != 0) okCompliance = false;

        bool okBlocked;
        uint256 blockedWord;
        bool okSanctioned;
        uint256 sanctionedWord;
        if (okCompliance) {
            address compliance = address(uint160(complianceWord));
            (okBlocked, blockedWord) =
                _staticWord(compliance, abi.encodeCall(IIssuerCompliance.blockedAddresses, (stock, address(this))));
            (okSanctioned, sanctionedWord) =
                _staticWord(compliance, abi.encodeCall(IIssuerCompliance.sanctionedAddresses, (address(this))));
        }
        if (okBlocked && blockedWord != 0) return (true, true);
        if (okSanctioned && sanctionedWord != 0) return (true, true);

        return (false, okManager && okPaused && okCompliance && okBlocked && okSanctioned);
    }

    /// @dev One time. gas Budget `staticcall`,I returned "one." 32 The word "bytes" is not a word for reading.
    ///
    ///      CRITICAL **Request before calling gasleft() Enough to send the budget, enough to get it. revert.** See {GATING_READ_GAS}:
    ///      Without this door, anyone can measure it with a single measure. gas The deal is healthy. view I'm starving.
    ///      It's a clean one. -> "Unreadable" side, so put `clearedAt` Push the way.
    ///      EIP-150 Forward Only 63/64 And the balance is in `STATICCALL` After paying the cold account/The base cost is cut off.
    ///      So the threshold is... `ceil(Budget  64 / 63) + Call Backup`,The first half cannot be written; otherwise, one is accurate gas
    ///      limit Still makes it healthy. view Getting less than the budget. gas,The blogger says that the government is not going to be able to read the book.
    ///
    ///      WARNING On target address.**No code.**Time `staticcall` It's a success and a return to empty space - length checks are therefore not formalistic, but rather a form of censorship.
    ///      It is the only way to identify "this address is not a door-to-door token".
    function _staticWord(address target, bytes memory callData) private view returns (bool ok, uint256 word) {
        uint256 needed = (GATING_READ_GAS * 64) / 63 + 1 + GATING_STATICCALL_OVERHEAD;
        uint256 available = gasleft();
        if (available < needed) revert NotEnoughGasToObserveGating(needed, available);

        (bool success, bytes memory ret) = target.staticcall{gas: GATING_READ_GAS}(callData);
        if (!success || ret.length != 32) return (false, 0);

        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev A door control condition was observed and recorded once.**The semantics of this paragraph are at the heart of this milestone, not the details of its achievement.**
    ///
    ///      @return gated This time.**Real time**Read conclusions (in %)fail-open:I can't read.  - I'm not hit.
    ///
    ///      Three states, nine sides, only three. `clearedAt`:
    ///
    ///      | Records \ Real time | Door control. | Clean. | I can't read. |
    ///      |---|---|---|---|
    ///      | **Door control.**   | no-op | `active=false` **+ Seal** | `unreadable=true, active=false` **+ Seal** |
    ///      | **Clean.**   | `active=true` | CRITICAL **no-op** | `unreadable=true` **+ Seal** |
    ///      | **I can't read.** | `active=true, unreadable=false` | `unreadable=false` | CRITICAL **no-op** |
    ///
    ///      CRITICAL **The bottom left is the focus of the whole table.** If every time "clean" pokeWrite them all. `clearedAt`, Anyone who 47 Hours
    ///      One shift and you can push it all the way.`settleExpired` Permanent revert,The last thing that happens is the attacker should have been killed.
    ///      Series acquired**Free and indefinite extension**.No Variable 4(2) I can't catch this -- it's a premise of itself. `clearedAt` The expression,
    ///      The premise is simply being pushed away.**No Variable 4(3) That's why it's being set up.**(`test/invariant/Invariant4SettlementAndGating.t.sol`).
    ///
    ///      CRITICAL **The bottom right is the back door of the same thing.** fail-open We must put a margin on it. view I'm not sure if I can read it.
    ///      The holder will be cleared in an unauthorised window) but it must be bound to**Enter**The change is not readable, but it is not readable.
    ///      Not "no reading" . It's the only one allowed without real. `Door control. -> Clean.` . The case of a border stamp.
    ///
    ///      **I can't read. -> Clean. "No stamp.**:It's been covered once in the unreadable moment, and once more when you come out, it's like...
    ///      In. -> Out -> "Into" becomes a push-up. `clearedAt` Pumps. The price is: if the token is true in the unreadable window,
    ///      Hold it till the window is readable. 48 The hour's time for buying is already spent-- 11 It's the right loss.
    function _observe(address stock) private returns (bool gated) {
        (bool hit, bool readable) = _readGating(stock);
        Gating storage g = _gating[stock];

        if (hit) {
            // Enter / Keep the door shut.`clearedAt` It remembers the moment of "leave."
            if (!g.active) g.active = true;
            if (g.unreadable) g.unreadable = false;
            gated = true;
        } else if (!readable) {
            if (!g.unreadable) {
                g.unreadable = true;
                g.active = false; // Door control. -> Unreadable: Press Unreverseed
                g.clearedAt = uint64(block.timestamp);
            }
        } else if (g.active) {
            g.active = false; // The only real de-sidence.
            g.clearedAt = uint64(block.timestamp);
        } else if (g.unreadable) {
            g.unreadable = false; // I can't read. -> Clean: no re-seals
        }

        emit GatingObserved(stock, g.active, !g.unreadable, g.clearedAt);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev **It does only one thing: put a real-time observation on the chain.** This is the record for the extension and settlement readings.
    ///      The door control happened and nobody else. poke,No extension is possible (the contract only contains recorded observations).
    ///
    ///      CRITICAL Zero addresses are blocked here:`_gating[address(0)]` It's one.**Unopened Series**The records you read.
    ///      (`s.stockToken == address(0)`).Today `exercise` and `settleExpired` The first time I saw a series of unopened items, I was told that I was not allowed to open it.
    ///      So it's broken and nobody reads it; it's stopped outside so that "that record is always zero" doesn't have to happen every time.
    ///      reprograms when adding functions.
    ///
    ///      `nonReentrant` It's not heavy here.`_observe` Just do it. `staticcall`,The government has been able to provide the necessary information to the government.
    ///      But it leaves the whole contract with a single word:**No one in six entrances can cross the line.**.
    function pokeGating(address stockToken) external nonReentrant {
        if (stockToken == address(0)) revert ZeroToken();
        _observe(stockToken);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # The settlement during the door control was structurally blocked -- that's automatic postponement.
    ///
    ///      No administrator presses the extension switch: the settlement is just**I can't.**,So the line of rights window remained open.
    ///      The issuer will roll back the actual rights of the owner if he or she still prevents the transfer of the shares.
    ///
    ///      CRITICAL **`pokeGating` It's a window closing move, not an opening move.** The right reader is...**Records**:The record says the door is open.
    ///      So once the issuer is released, the right to move is immediately available... **No one needs to start. poke**.And the only thing that we can see is the de-activation:
    ///       To reap the infinite window  `max(expiry, clearedAt + 48h)`.
    ///      It's called "the right to move after observation" and it's gonna get the front end to talk to the users. Monitor,It was both wrong and unlicensed design.
    ///      It's called a business case. `test_exercise_worksBeforeAnyPokeOnceTheIssuerClears`.
    ///
    ///      | # | Door. | It's blocking that. |
    ///      |---|---|---|
    ///      | (1) | Series is open | Otherwise, anyone can be right about something that doesn't exist. id Write a "liquidated" record. |
    ///      | (2) | Unsolved | The settlement is one-time:`remainder` It's already done. Rerun will overwhelm. #12 Get out of here. |
    ///      | (3) | Read doorless in real time | Automatic extension itself |
    ///      | 4 | It's over. deadline | and `exercise` It's... `< deadline` Strict complementarity |
    ///
    ///      CRITICAL **(3) Before. `_observe` Once.**,This is not a good move: records may be old. The most important thing is that they are old.
    ///      The record says that the issuer is frozen -- the settlement is in the holder if it doesn't read it again.**There's no right to do it.**It's...
    ///      The time goes by. The other way around is that the observation corrects the way.
    ///
    ///      WARNING **The observation was only left in the chain when the settlement was successful.** It rolls back with the whole deal...
    ///      So the "recording of door control, real time decomposition" series is not the result of repeated retweeting. `settleExpired` Just... 48 Hours
    ///      The time limit is over: the clock is to be used once. `pokeGating` Start. The operating caliber is...**First poke,Wait, wait, wait.**,
    ///      Not "touch and test." settleExpired.This one has no effect on activity... poke No permission, no one can be transferred.
    ///
    ///      # Why? `nonReentrant` It's a heavy burden here.
    ///
    ///      CRITICAL Without it,`depositAndMint` The door "no more deposit" can be used.**Around**:The deposit is first transfers.
    ///      Re-entry, and transfer hands over control of the shares; the coins are re-directed. `settleExpired` The first time I was in the business was when I was a kid.
    ///      When you get back, you put the collateral in the book. `deposited`,And cast the certificate of authority... `remainder` I've been through the settlement.
    ///      The account is settled. The result is that it's not there. `remainder`,The government has been able to provide a comprehensive analysis of the situation and the evidence of the lack of information on the situation.
    ///      The right to a call is not a right. The guard is...**Cross-function**(Same transient So this path is blocked.
    function settleExpired(uint256 seriesId) external nonReentrant {
        Series storage s = _series[seriesId];

        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (s.settled) revert SeriesSettled(seriesId);

        if (_observe(s.stockToken)) revert SettlementGatedByIssuer(seriesId, s.stockToken);

        uint64 deadline = _exerciseDeadline(s);
        if (block.timestamp < deadline) revert SettlementTooEarly(seriesId, deadline, block.timestamp);

        // CRITICAL Subtract**Structurally.**It's not gonna spill.checked Just the last insurance:`exercised` Only `exercise` The increase in the number of people living in the country is not a problem.
        //    Each increase is accompanied by an equivalent destruction of the certificate, which is only by the 1:1 Right. `deposited` The same incremental cast.
        //    And... `exercised <= minted == deposited` It's a constant. It's gonna be a mess. Here. revert Better than writing one.
        //    The number of the back astronomical. `remainder`  -  -  That'll make... #12 Get out of the pool and get rid of the collateral it doesn't have.
        uint128 remainder = s.deposited - s.exercised;

        s.settled = true;
        s.remainder = remainder;

        emit Settled(seriesId, remainder, deadline);
    }

    /// @inheritdoc IClearingPool
    ///
    /// @dev # The collateral never leaves this contract.
    ///
    ///      Rolling in**There's no transfer.**:Front-Sequence series. `remainder` Zero. Same number in the subsequent series.
    ///      `deposited` and `minted`,Then we'll create an equal weight certificate. `distributor`.The balance of the stock in the pool is in the transaction.
    ///      Back and forth. wei Do not move (no variable) 7),So it doesn't constitute "transmit" -- no variables. 5 The wording relies on this.
    ///
    ///      CRITICAL **It's not the same design.** `claimExpired -> Treasury -> Re-invent.` It'll make things more stable. `S/f` Size
    ///      (S = The weekly tax.f = (b) Participation rates in the exercise of rights;f = 5% Time 20  I'm a week taxer **The whole pool passes once a week.
    ///      Flap Guardian Upgraded Treasury**  -  -  R4 "In transit." <=24hUnderstated one to two orders of magnitude.
    ///      After the change to pool roll, the Treasury will handle only the taxes that are newly available during the week. `docs/design.md` 10-25.
    ///
    ///      # Six doors, all self-proved by the pool -- so it's not licensed.
    ///
    ///      | # | Door. | It's blocking that. |
    ///      |---|---|---|
    ///      | (1) | Preface is open | Wrong number. id It was a "this series doesn't exist" sentence, not "it's not settled." |
    ///      | (2) | Pre-sequence settled | `remainder` It's not until the settlement. |
    ///      | (3) | `remainder != 0` | (a) Empty rolling;**And it's all about "not rolling twice."** |
    ///      | 4 | Follow-up started | It's not open to anyone. id The S.E.L.D. |
    ///      | 5 | Same MEME,With shares | See - the only one**Reimbursable**The door. |
    ///      | 6 | Subsequent unliquidated, unexpired | We'll create a list of rights that we can't have. |
    ///
    ///      (1) and (2) Overlapping (unopened series necessarily unsolved), keep (1) For the wrong face only: two fields in the same slot, more than this comparison
    ///      Not a lot of reading. Same. {depositAndMint} The decision to separate the "unopened" from "not the vault of the series" is a trade-off.
    ///
    ///      CRITICAL **5 is the heavy one.** The lack of "same currency" is a major factor in the lack of information.A Series (Symbol)GME The rest of the mortgage is recorded. B Series
    ///      (The other stock is in the currency of the other-- B The pool balance is not going to hold it. 1(2) It's broken. It's missing. MEME,
    ///      The collateral of a project will support the certificate of ownership of another project, while the right to burn is the same. MEME(`docs/spec.md`),
    ///      The holder of the certificate of authorization will never be able to pay the correct price.
    ///
    ///      4 The sentence is `n.strike != 0`,No, it's not. `n.vault != address(0)`.The two are today equal.`openSeries` It's... (2)
    ///      Guaranteed open series strike "No, it's not zero."**Specification roll caller**(`docs/spec.md`):
    ///      The zero-line rights series is not in existence in the roller eye. Roller is the only one.**The name of the card is a fake.** The path,
    ///      So the door is set to read "the forged certificate is worthless" rather than "the person who has ever opened it."
    ///
    ///      6 - Yeah. `n.expiry`,**No, it's not.** {_exerciseDeadline}.The latter will put "over" expiry,But the door was delayed.
    ///      "The right to remain viable" series is also a legal follow-up -- it's the same as allowing anyone to roll the balance into a long overdue, but not yet.
    ///      Old series of settlements: collateral won't be lost (it will continue to roll down with the settlement of that series), but it's the week. merkle root
    ///      I can't get the money, but I'm gonna make it. `distributor` There's no one in that lot. root Cover it, and it'll stay in its hands forever.
    ///      **The smaller the legitimate follow-up, the better.**,So the one that's tough; both are equal when there's no door.
    ///
    ///      `nextSeriesId == seriesId` No separate door:(2) Request for preface**Already**The settlement,6 Request for Follow-up**Not**The settlement,
    ///      Same. id It is not possible to establish both at the same time.
    ///
    ///      # Border: Clean when no subsequent series revert
    ///
    ///      The project is in a swipe, no one's opening a series this week -- the rest is in the pool. admin And it's the inevitable. Any time you open one.
    ///      The new series that expires in the future, the roll-in immediately recovers:**There was only delay, no loss.**
    ///
    ///      WARNING **Residual open: the legal successor is designated by the caller, and the pool does not identify which is the one this week.**
    ///      `openSeries` No permission, so the bet-taker can use the same pair. (MEME, Stock tokens) I'm not sure what I'm talking about.
    ///      Get in front of the normal roll and roll the rest in.**Can't steal anything.**(The license is still in place. `distributor`,The collateral is still inside the pool.
    ///      settle -> roll But he can mess up the distribution for the week. `openSeries` The three-dollar bet is...
    ///      **Same.**Roots, mitigation and conditionality are blocked on the online grid. issue #21 / #23,Not resolved in this function.
    ///
    ///      # `nonReentrant` Here.**No, it's not.**It's heavy.
    ///
    ///      The only external call is `call.mint(distributor, ...)`,And... `distributor` It's from this contract. immutable,
    ///      It's ours. `MerkleDistributor`(`ERC1155Holder`,Only returns to magic, and the account is already in line.
    ///      It's in front of it. It's added to make the whole contract reword with one word:**No one in six entrances can cross the line.**
    ///      (Same {pokeGating}).
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external nonReentrant {
        Series storage s = _series[seriesId];

        if (s.vault == address(0)) revert SeriesNotOpen(seriesId);
        if (!s.settled) revert SeriesNotSettled(seriesId);

        uint128 amount = s.remainder;
        if (amount == 0) revert NothingToRoll(seriesId);

        Series storage n = _series[nextSeriesId];

        if (n.strike == 0) revert SeriesNotOpen(nextSeriesId);
        if (n.memeToken != s.memeToken || n.stockToken != s.stockToken) {
            revert SuccessorTokenMismatch(nextSeriesId, n.memeToken, n.stockToken);
        }
        if (n.settled) revert SeriesSettled(nextSeriesId);
        if (block.timestamp >= n.expiry) revert SuccessorExpired(nextSeriesId, n.expiry, block.timestamp);

        // CRITICAL **First, clean up and then record.** Front-ordered `remainder` It's the only place that this money is on the books; both places keep it together.
        //    Even for a single external call, it is a solid double-counting exercise (no variable). 1(2) I'll see.
        //    `deposited` It's written "how much has been collected in the history of this series," but the settled series is excluded.
        //    No Variable 1(1) Outside (judgement) `test/invariant/Invariant1And2MintingPath.t.sol` It's... `CollateralCheck`).
        s.remainder = 0;

        // Both. checked:I'm gonna have to take it someday. `uint128` - It's a blast. - Here it is. revert It's better than a silent circle.
        // The pool has no claim at all. {depositAndMint} Yeah. `SafeCast` The trade.
        n.deposited += amount;
        n.minted += amount;

        // The accounts are maintained prior to external calls:`call.mint` We'll call back the payees. `onERC1155Received`.
        call.mint(distributor, nextSeriesId, amount);

        emit Rolled(seriesId, nextSeriesId, amount);
    }
}
