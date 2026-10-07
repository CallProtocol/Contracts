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
import {StockToken} from "../helpers/StockToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";

/// @notice No Variable 1 The two paragraphs are written in one place for nonvariable testing and sharing the same test as the "detector counter-proofing".
///
/// CRITICAL The two tests are written down, and they're going to have to prove the other code -- the other one is exactly what the counter-testing is about.**This one.**It's gonna ring.
library CollateralCheck {
    /// @param ids All Open Seriess
    /// @return perSeries Violations 1(1) Number of series
    /// @return global    Violations 1(2) Number of shares in currency
    ///
    /// @dev 1(1) "attribution to the series "and part of this project is `deposited  exercised`:
    ///      Certificates are segregated by project (%)`docs/spec.md`),And so...**Each series has only one financier**,
    ///      No prorated account (%)4.2The design of a single vault." 1(1) Simplify `minted <= deposited`
    ///       -  -  A series can never claim to be more than it has.
    ///
    ///      1(2) The one that crosses the line: the pool balance of the same stock token is**Shared**I'm sorry.
    ///      The outstanding rights of the entire unliquidated series, together with the remaining amount of the total amount to be rolled, must therefore be covered by the balance.
    function violations(ClearingPool pool, address[] memory stocks, uint256[] memory ids)
        internal
        view
        returns (uint256 perSeries, uint256 global)
    {
        for (uint256 i = 0; i < ids.length; i++) {
            ClearingPool.Series memory s = pool.series(ids[i]);

            // CRITICAL **Limit to the open range, which is no variable 1(1) The original is not meant to be.**
            //    If the certificate of rights in the settled series were not viable, it would not have required collateral; rather, it would have been rolled (see table 2).#12)The rest of the time is recorded in the series.
            //    Front-Sequence series. `deposited` And the number of the numbers that have been re-assigned -- it continues to be said to be full of lines.
            //    The one that's on the roll is the one that's got the balance that's already on the books. 1(2) The global form of responsibility.
            //    issue #5:**Don't put it in the car. 1(1) It's a way to get through.**  -  -  It is the rule that weakens, and it is the precondition of non-application that is deleted here.
            if (s.settled) continue;

            // `exercised > minted` It is itself the image of a broken account (more weight than cast).
            // One violation, not a reduction. revert  -  -  view Lee. revert The blogger says that the "no variable is broken" is being wiped out.
            if (s.exercised > s.minted || s.exercised > s.deposited) perSeries++;
            else if (s.minted - s.exercised > s.deposited - s.exercised) perSeries++;
        }

        for (uint256 t = 0; t < stocks.length; t++) {
            uint256 claim;
            for (uint256 i = 0; i < ids.length; i++) {
                ClearingPool.Series memory s = pool.series(ids[i]);
                if (s.stockToken != stocks[t]) continue;
                if (!s.settled && s.minted >= s.exercised) claim += s.minted - s.exercised;
                claim += s.remainder;
            }
            if (claim > IERC20(stocks[t]).balanceOf(address(pool))) global++;
        }
    }
}

/// @notice **It's only for counter-proven detectors.** It's a non-variant. 1 and 2 The two things that you want to ban are done in one function.
///
/// The two back doors are deliberately separated because they're not the same thing -- one detector catches the other, which means one is redundant:
///
/// | Back door. | Who should ring? | Who should be silent? |
/// |---|---|---|
/// | `overmint` The billings were sprung with the cards, but no collateral. | No Variable 1(1)(2),No Variable 2 Constant Count | Validity count (accounts and cards remain the same) |
/// | `mintPhantomCalls` Only the cards, no bills. | Validation | No Variable 1(It reads books, it's not passive. |
///
/// Neither of these two entry points in the production contract exists - by `test/ClearingPool.t.sol` It's a compilation. ABI Prove it.
/// (The 'We have not written' version of the article, which is not supported by the phrase "We have not written".
contract OvermintingPool is ClearingPool {
    constructor(ICall call_, address distributor_, IAttestationRegistry attestations_, IVaultRegistry vaultRegistry_)
        ClearingPool(call_, distributor_, attestations_, vaultRegistry_)
    {}

    /// @dev If you don't put the collateral on it, you'll put it in the bag. `minted` Raise it up and cast the corresponding cards.
    function overmint(uint256 seriesId, address to, uint128 amount) external {
        _series[seriesId].minted += amount;
        call.mint(to, seriesId, amount);
    }

    /// @dev Only the cast, the accounts remain intact -- the pool's account thus undervalued its own debt.
    function mintPhantomCalls(uint256 seriesId, address to, uint256 amount) external {
        call.mint(to, seriesId, amount);
    }
}

/// @notice Drives the casting path. handler.
///
/// CRITICAL **Nothing in this contract. revert**(Same `Invariant6AttestationGate.t.sol` :
/// No variable running in `fail_on_revert = false` I'm not sure if you're going to be able to do this.handler - Yes. `assertEq` Losing is one. revert,
/// I'm gonna get it. fuzzer Swallow it in silence -- the assertion is written as if it was not written. So the violation is always done.**Recording counters**,
/// By `invariant_*` Go and say zero; call the pool all low. `call`.
///
/// Can the counter itself catch the violation? `test_theDetectorDetects_*` Counterargument.
contract MintingHandler is CommonBase, StdUtils {
    ClearingPool public immutable pool;
    Call public immutable call;

    /// @dev CRITICAL Three vault doubles, two stock coins, two. MEME,Four. expiry  -  -
    ///      The universe is deliberately small: the maximum number of series 224 = 16,And...
    ///      (1) The non-variant function is still cheap to run through the whole series (it runs after every step);
    ///      (2) The same triad is hit repeatedly, and the path "only once" is covered.
    ///      (3) The vaults are three and one.  About 2/3  The deposit in the**Not the vault of the series.**is the caller.
    ///
    ///      CRITICAL **- Oh, my God. MEME One more, it's deliberate.**(M2-5 / #37):Only the identity is registered.
    ///      `memes[i] -> vaults[i]`(i < 2),And... `vaults[2]` **Never one. MEME Legal Treasury**  -  -
    ///      The identity door in the series is covered in every round, not by the... fuzzer It happened to hit.
    VaultStub[3] public vaults;
    StockToken[2] public stocks;
    address[2] public memes;
    address[3] public receivers;
    uint64[4] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice No Variable 2:Before and after a certain move `minted` Incremental != The number of times the stock is increased by its currency balance. 0.
    uint256 public conservationViolations;
    /// @notice The same thing on the side of the certificate: the number of cards cast != `minted` Number of increments. Must be constant 0.
    uint256 public callViolations;
    /// @notice The stock balance in the pool**Reduction**Number of times. No turning out of the casting path, which must be permanent. 0.
    uint256 public outflowViolations;

    /// @dev Override Count: All three non-variables are "some of them are counted " 0,And one of them didn't do anything. handler Same satisfaction.
    uint256 public successfulOpens;
    uint256 public successfulDeposits;
    uint256 public rejectedOpens;
    uint256 public rejectedDeposits;

    /// @dev Detector counter-probable connection:**Both of them are in real operation. 0**.Not 0 The first time I saw the first time I saw the first time I saw it, I saw it in the paper.
    ///      It's to prove that the counters up there aren't asleep. See you. `test_theDetectorDetects_*`.
    uint128 public immutable sabotagePerDeposit;
    uint128 public immutable phantomCallsPerDeposit;

    constructor(
        ClearingPool pool_,
        Call call_,
        address distributor_,
        FactoryStub factory_,
        uint128 sabotagePerDeposit_,
        uint128 phantomCallsPerDeposit_
    ) {
        pool = pool_;
        call = call_;
        sabotagePerDeposit = sabotagePerDeposit_;
        phantomCallsPerDeposit = phantomCallsPerDeposit_;

        memes = [makeAddrLike("MEME A"), makeAddrLike("MEME B")];
        receivers = [distributor_, makeAddrLike("holder 1"), makeAddrLike("holder 2")];
        expiries = [
            uint64(block.timestamp + 30 days),
            uint64(block.timestamp + 60 days),
            uint64(block.timestamp + 90 days),
            uint64(block.timestamp + 365 days)
        ];

        for (uint256 i = 0; i < stocks.length; i++) {
            stocks[i] = new StockToken();
        }
        stocks[1].setTaxBps(300); // A belt. 3% Transfer tax: "Branch by account" does not make any difference under zero tax.

        for (uint256 i = 0; i < vaults.length; i++) {
            VaultStub v = new VaultStub(pool_);
            vaults[i] = v;
            // Front `memes.length` One for each vault. MEME;The extra one.**Intentional failure to register**,See the field note.
            if (i < memes.length) factory_.bind(memes[i], address(v));
            for (uint256 t = 0; t < stocks.length; t++) {
                stocks[t].mint(address(v), 1e30);
                v.approve(stocks[t], type(uint256).max);
            }
        }
    }

    function seriesCount() external view returns (uint256) {
        return openedSeries.length;
    }

    function stockAddresses() external view returns (address[] memory list) {
        list = new address[](stocks.length);
        for (uint256 i = 0; i < stocks.length; i++) {
            list[i] = address(stocks[i]);
        }
    }

    function seriesIds() external view returns (uint256[] memory) {
        return openedSeries;
    }

    //  Actions

    function openSeries(uint256 vaultSeed, uint256 memeSeed, uint256 stockSeed, uint256 expirySeed, uint128 strike)
        external
    {
        // strike == 0 The government is not going to accept the contract.`ZeroStrike`),The unit tests are covered; the series is as accessible as possible here.
        // Otherwise, a whole cycle of the series may not be open and the deposits behind it will be empty.
        strike = uint128(bound(strike, 1, type(uint128).max));

        (bool ok, bytes memory ret) = address(vaults[vaultSeed % vaults.length])
            .call(
                abi.encodeCall(
                    VaultStub.openSeries,
                    (
                        memes[memeSeed % memes.length],
                        address(stocks[stockSeed % stocks.length]),
                        expiries[expirySeed % expiries.length],
                        strike
                    )
                )
            );

        if (!ok) {
            rejectedOpens++;
            return;
        }
        successfulOpens++;

        uint256 seriesId = abi.decode(ret, (uint256));
        if (!known[seriesId]) {
            known[seriesId] = true;
            openedSeries.push(seriesId);
        }
    }

    function depositAndMint(uint256 vaultSeed, uint256 seriesSeed, uint256 receiverSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address to = receivers[receiverSeed % receivers.length];
        amount = bound(amount, 0, 1e24);

        IERC20 stock = IERC20(pool.series(seriesId).stockToken);
        uint256 balanceBefore = stock.balanceOf(address(pool));
        uint256 mintedBefore = pool.series(seriesId).minted;
        uint256 callBefore = call.balanceOf(to, seriesId);

        (bool ok,) = address(vaults[vaultSeed % vaults.length])
            .call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, to, amount)));
        if (ok) {
            successfulDeposits++;
            if (sabotagePerDeposit != 0) {
                OvermintingPool(address(pool)).overmint(seriesId, to, sabotagePerDeposit);
            }
            if (phantomCallsPerDeposit != 0) {
                OvermintingPool(address(pool)).mintPhantomCalls(seriesId, to, phantomCallsPerDeposit);
            }
        } else {
            rejectedDeposits++;
        }

        uint256 balanceAfter = stock.balanceOf(address(pool));
        if (balanceAfter < balanceBefore) {
            outflowViolations++;
            return; // After the balance is reversed, the increase below is meaningless.
        }

        uint256 mintedDelta = pool.series(seriesId).minted - mintedBefore;
        if (mintedDelta != balanceAfter - balanceBefore) conservationViolations++;
        if (call.balanceOf(to, seriesId) - callBefore != mintedDelta) callViolations++;
    }

    /// @dev Time is the dimension: deposit can take place long after the series has been opened, or it can take place `expiry` **After**
    ///      (The door's been extended. That's legal. See? issue #11) -  -  The casting strength is not about time, this action nails it.
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 2 days));
    }

    /// @dev `makeAddr` Yes. forge-std It's... `Test` Go, go, go, go!handler The heir is... `CommonBase`.
    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **No Variable 1((In unsolved form) and non-variable 2  -  -  Castery can never run to the collateral.**
///
/// | # | No Variable | The assertion. |
/// |---|---|---|
/// | 1(1) | Sufficient collateral (series by series) |  Unsolved series:`minted  exercised <= It belongs to him. series Part of the` |
/// | 1(2) | Sufficient collateral (global) |  Stock tokens:`_Unsolved(minted  exercised) +  remainder <= balanceOf(pool)` |
/// | 2 | Casting is constant. | Every time `depositAndMint` Back `minted` Incremental == Increased currency balance of the stock in the pool |
///
/// **for the present document handler Drive casting path only**,So here. `exercised` / `remainder` / `settled` Constantly at the beginning.
/// But the assertion is...**In final form**:`exercised` . The writing path is followed M1-5(#10)Landing,`Invariant3ExerciseAtomicity.t.sol`
/// Use**Same one.** `CollateralCheck` Run again on the real rights sequence. 1(1)(2);`remainder` / `settled` Wait. #11 / #12.
/// The sentence itself should not be modified - especially 1(1) The "unresolved" limit is not clear.issue #5 Call it.**We must not be weakened into a pass.**.
contract Invariant1And2MintingPathTest is Test {
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;
    MintingHandler internal handler;

    function setUp() public {
        (pool, call, distributor, factory) = _deploySystem(false);
        handler = new MintingHandler(pool, call, address(distributor), factory, 0, 0);

        targetContract(address(handler));
    }

    /// @dev The deployment is...**Real Four.**And two bindings are completed (issue #5 Test stitches: the external of the post-deployment contract collection ABI),
    ///      Plus a real root of identity -- the fourth of the pool. `immutable`(M2-5 / #37).
    ///      `overminting = true` And then you switch the pool to the one with the back door -- only counter-proof.
    function _deploySystem(bool overminting)
        internal
        returns (ClearingPool pool_, Call call_, MerkleDistributor distributor_, FactoryStub factory_)
    {
        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call_ = new Call();
        distributor_ = new MerkleDistributor(makeAddr("publisher"));
        factory_ = new FactoryStub();
        pool_ = overminting
            ? ClearingPool(address(new OvermintingPool(call_, address(distributor_), registry, factory_.registry())))
            : new ClearingPool(call_, address(distributor_), registry, factory_.registry());
        call_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    //  No Variable 1 and 2

    /// @notice 1(1) The unused weights of each of the outstanding series were covered by collateral that it had itself deposited in.
    function invariant_1a_everyUnsettledSeriesIsCollateralised() public view {
        (uint256 perSeries,) = CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(
            perSeries,
            0,
            unicode"No Variable 1(1):Some sort of unsolved series. minted It's beyond the collateral it's depositing."
        );
    }

    /// @notice 1(2) Unsigned rights in all outstanding series under the same stock tokens + All to roll balance <= Pool balance.
    function invariant_1b_theWholePoolIsCollateralised() public view {
        (, uint256 global) = CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(global, 0, unicode"No Variable 1(2):The balance of a stock in the pool can't cover all the claims.");
    }

    /// @notice 2 Every time `depositAndMint` The blogger adds:`minted` Incremental == The pool is an increase in the currency balance of the stock.
    function invariant_2_mintedTracksTheBalanceDelta() public view {
        assertEq(
            handler.conservationViolations(), 0, unicode"No Variable 2:minted Incremental != Increased pool balance"
        );
        assertEq(handler.callViolations(), 0, unicode"No Variable 2:Number of certificates cast != minted Incremental");
        assertEq(
            handler.outflowViolations(),
            0,
            unicode"There's no way to get any collateral out of the pool on the casting path."
        );
    }

    //  Countered: Three of the above are not empty.

    /// @dev All three of the non-variables are "some of the count is 0/Some of the two <= "and one**Nothing.**It's... handler
    ///      It's also satisfying. Here, it is conclusively proven that the path to success is working and that the path to rejection is actually hit.
    function test_handlerReachesTheSuccessPathsAndTheRejections() public {
        handler.openSeries(0, 0, 0, 0, 1e18);
        assertEq(handler.successfulOpens(), 1, unicode"handler I can't open a series.");
        assertEq(handler.seriesCount(), 1, unicode"The series is not taken down.");

        // The same vault, the same triad, the second time.  Rejected (`SeriesAlreadyOpen`);No increase in series
        handler.openSeries(0, 0, 0, 0, 1e18);
        assertEq(handler.rejectedOpens(), 1, unicode"\"Only once.\" This path was not hit.");
        assertEq(handler.seriesCount(), 1, unicode"The rejected series should not have produced a new series.");

        // CRITICAL Another vault to open the same one. MEME  - I'm not allowed to do it.`NotRegisteredVault`,M2-5 / #37).
        //    Another one that hasn't been opened yet. expiry,The government has been able to get the door open and the door is not "opened."
        handler.openSeries(1, 0, 0, 1, 1e18);
        assertEq(handler.rejectedOpens(), 2, unicode"The path to the identity door in the series was not hit.");
        assertEq(handler.seriesCount(), 1, unicode"It's not. MEME,I can't open a series.");

        // vaultSeed 0 == The vault that opened the series.  Success
        handler.depositAndMint(0, 0, 0, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler It's not gonna fit in.");
        assertGt(call.balanceOf(address(distributor), handler.openedSeries(0)), 0, unicode"The license is real.");

        // vaultSeed 1 != The vaults of the series  Rejected
        handler.depositAndMint(1, 0, 0, 100 ether);
        assertEq(handler.rejectedDeposits(), 1, unicode"The path of the non-serial vault was not hit.");

        assertEq(handler.conservationViolations(), 0, unicode"There's no constant violation of the law.");
    }

    /// @dev The probe countered: "The back door of "No collateral can be cast" and "No record of only casting" is loaded into the pool.
    ///      No Variable 1 , no variables 2 The constant and weight count must be**It's all on the spot.**.
    ///
    ///      CRITICAL That's all I need. Those three claims could be written wrong at any time.** Always for real **
    ///       -  -  That's the worst way to fail: it's still green, but it doesn't check anything.
    ///
    ///      CRITICAL Two vantage points.**It's not equal.**(1 wei / 2 wei).If you take the same, the bill will be blown up. 1,The cards are not up. 1,
    ///      Number of certificates == minted The incremental is re-established -- two back doors are set off, the call detector is dead together.
    function test_theDetectorDetects_overmintingAndPhantomCalls() public {
        (ClearingPool bad, Call badCall, MerkleDistributor badDistributor, FactoryStub badFactory) = _deploySystem(true);
        MintingHandler h = new MintingHandler(bad, badCall, address(badDistributor), badFactory, 1 wei, 2 wei);

        h.openSeries(0, 0, 0, 0, 1e18);
        h.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(bad, h.stockAddresses(), h.seriesIds());
        assertGt(perSeries, 0, unicode"No Variable 1(1) The probe didn't ring.");
        assertGt(global, 0, unicode"No Variable 1(2) The probe didn't ring.");
        assertGt(h.conservationViolations(), 0, unicode"No Variable 2 The probe didn't ring.");
        assertGt(h.callViolations(), 0, unicode"The probe on the side of the call didn't ring.");
    }

    /// @dev Validation**Unique.**The stitches covered: only the casting cards, the accounts, remained intact.
    ///      No Variable 1 It's a book, it's not passive -- it's blind about this bad thing, so the counter is not redundant.
    function test_theCallDetectorCatchesWhatTheLedgerCheckCannot() public {
        (ClearingPool bad, Call badCall, MerkleDistributor badDistributor, FactoryStub badFactory) = _deploySystem(true);
        MintingHandler h = new MintingHandler(bad, badCall, address(badDistributor), badFactory, 0, 1 wei);

        h.openSeries(0, 0, 0, 0, 1e18);
        h.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(bad, h.stockAddresses(), h.seriesIds());
        assertEq(perSeries, 0, unicode"No Variable 1(1) It's blind to \"the cast.\"");
        assertEq(global, 0, unicode"No Variable 1(2) It's blind to \"the cast.\"");
        assertEq(h.conservationViolations(), 0, unicode"The constant count is blind to the \"show.\"");
        assertGt(h.callViolations(), 0, unicode"This stitch is only visible on the count of the right.");
    }

    /// @dev The other half of the probe counter-proof: the verdict must be**Real**The pool gives zero irregularities.
    ///      The last test proves that it's always ringing.
    function test_theDetectorIsSilentOnTheRealPool() public {
        handler.openSeries(0, 0, 0, 0, 1e18);
        handler.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"On the real pool. 1(1) It shouldn't ring.");
        assertEq(global, 0, unicode"On the real pool. 1(2) It shouldn't ring.");
    }
}
