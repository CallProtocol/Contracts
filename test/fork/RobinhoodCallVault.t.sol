// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Call} from "../../src/Call.sol";
import {CallVault} from "../../src/CallVault.sol";
import {VaultBase} from "../../src/flap/VaultBase.sol";
import {CallVaultHarness} from "../helpers/CallVaultHarness.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {CollateralCheck} from "../invariant/Invariant1And2MintingPath.t.sol";
import {ForkConfig, IRobinhoodAccessRegistry} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev - Put it on. {VaultBase} Two of them. internal The address check was revealed.**The real chain.**Check them.
///      The vault doesn't reveal itself. `_getPortal()`(No user needs it, so the probe is only in the test.
contract VaultBaseProbe is VaultBase {
    function description() public pure override returns (string memory) {
        return "probe";
    }

    function portal() external view returns (address) {
        return _getPortal();
    }

    function guardian() external view returns (address) {
        return _getGuardian();
    }
}

/// @notice **Real GME Up the vault.**:Bones and protocols. ping(M2-1,issue #33)+ Income path (in millions of dollars)M2-3,issue #35).
///
/// Local.`test/CallVault.t.sol`)The word for the account has been used, written on the schema I've been through it.
/// So here's what we do.**The things the double can't prove.**:
///
/// 1. CRITICAL **ERC20 "The transfer is not giving the recipient an execution." `Stock` A sentence.** We wrote the local double.
///    ERC-20,Of course it won't call us back -- because we didn't write the code. It's true. GME Yes. BeaconProxy -> `Stock`,
///    with the issuer's accelerator and its own account;**It's...**The blogger says that the bank account is still unknown, and that the bank account is still empty.
///    Until the agreement is made to fill that note. ping,It is the empirical form of the balance reconciliation model that is being documented.
/// 2. CRITICAL **`receive()` It's... gas It's spent on real tokens.** Normative rule 005 It's... 100 Thousand gas budget,
///    - Yes, sir. BeaconProxy -> `Stock` It's... `balanceOf`(Once. delegatecall + It's its own memory reading) to go to quantity,
///    Not one. 20 All right, doubles go.
/// 3. CRITICAL **Upstream base type. Portal and Guardian Addresses, which are really the two addresses on this chain.**
///    `src/flap/` It's a byte copy, and a copy may be taken from a copy.**Outdated**Upstream (tried once: regular self-censorship)
///    The tools are self-contained. `references/prelude/VaultBase.sol` I haven't known him yet. chainId 4663,See `src/flap/README.md`).
///    Only 4663 It was only once, and then once, that we checked the address that ruled out such errors.
/// 4. CRITICAL **M1 Non-variant 1 / 2 It was just one before. `VaultStub` Checked down.** We wrote that double ourselves.
///    It will certainly be honest about the amount of authorization and transfer requested.M2-3 First time.**The real vault.**Stand on this side of the box,
///    So for the first time, the two non-variables ran on the whole system -- the same copy was used. {CollateralCheck},
///    Do not write it again (remark it again, it's the same as letting this check the other code).
/// 5. CRITICAL **The issuer can stop this road any time.** Pause / The contents of the restricted pool are deposited during the time of the deposit.**Clean failure.**:
///    Money. wei It is a lot of money left in the vault, no residuals left behind, and once again after being released.
///    It's only true. `Stock` The emulator answers -- the "freeze" in the local double is the injection we wrote ourselves.
///
/// | Component | With what? |
/// |---|---|
/// | Currency of income / Mortgages. | **Real GME** |
/// | Services MEME | -Punch the height.**Real `FlapTaxTokenV3`** Sample (to record only as address, this document does not touch it) |
/// | Treasury | Real `CallVault`,Press beacon Agent deployment (with M2-5 (Infragrance of plants) |
/// | I'm a pool. / Certificate / Distribution / Registration form | Real deployment + Two bindings (in %2)issue #5  The test stitches  |
/// | Open the line. | {CallVaultHarness} Any argument entry - this document looks at the income path, not the first one to be spent 24 Hours covered TWAP Ring. Real. `openSeries()`  The cross-checking acceptance  `RobinhoodOpenSeries.t.sol` |
contract RobinhoodCallVaultForkTest is ForkTest {
    /// @dev CRITICAL **Write it all on its own.**,Not read from the contract. See you at the source. `docs/research/flap-indexvault-mechanism.md`.
    address internal constant FLAP_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// @dev Simulation keeper It's... dispatch Budget, value-taking is consistent with the locals.
    uint256 internal constant PING_GAS = 500_000;

    /// @dev The issuer's door was real when it hit the target. `Stock` Throw two errors. Write here instead of empty `expectRevert()`  -  -
    ///      The latter will be considered as a "failure for other reasons" and the same. `RobinhoodGating.t.sol` The same statement.
    error Blocked(address account);
    error IsPaused();

    uint128 internal constant STRIKE = 1850e18;

    IERC20 internal gme;
    CallVault internal vault;

    /// @dev Real Four.M2-3 The deposit path crosses the boundary between the vault and the pool, where the double has no foothold.
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    /// @dev and {vault} Same, but one more of the parameters. `harnessOpenSeries`  -  -  The attachment path requires an open series.
    CallVaultHarness internal seriesVault;

    address internal holder = makeAddr("holder");
    address internal anyone = makeAddr("anyone");

    /// @dev Decision-making 49:The sixth construct parameter of the vault -- the launcher, the only recipient of the split.
    address internal creator = makeAddr("creator");

    function setUp() public {
        selectFork(ForkConfig.robinhood());

        gme = IERC20(ForkConfig.GME);

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        // CRITICAL Decision-making 39-A3:The vault can't be upgraded, the factory.**Direct deployment**It's... no. beacon,No representation, no representation.
        //    `initialize`.Six parameters are fixed in the construction of that one. 49 & Inline creator),
        //    Of which price Portal It's real. Flap `Portal`.
        vault = new CallVault(
            pool,
            address(distributor),
            ForkConfig.FLAP_PORTAL,
            ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            ForkConfig.GME,
            creator,
            false,
            address(0xfee)
        );

        seriesVault = new CallVaultHarness(
            pool,
            address(distributor),
            ForkConfig.FLAP_PORTAL,
            ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            ForkConfig.GME,
            creator,
            false
        );
        factory.bind(ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE, address(seriesVault));
    }

    /// @dev Flap . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . calldata,Limits gas.
    function _ping() internal returns (bool ok, uint256 gasUsed) {
        uint256 before = gasleft();
        (ok,) = address(vault).call{value: 0, gas: PING_GAS}("");
        gasUsed = before - gasleft();
    }

    /// @dev Put reality on the table. GME Send it in. {seriesVault},The one that goes is "transfer." + Agreements pingThis is a real path, not a direct one. `deal`.
    function _fundSeriesVault(uint256 amount) internal returns (uint256 delivered) {
        deal(ForkConfig.GME, holder, amount);
        vm.prank(holder);
        gme.transfer(address(seriesVault), amount);

        (bool ok,) = address(seriesVault).call{value: 0, gas: PING_GAS}("");
        assertTrue(ok, unicode"ping It should be successful.");
        delivered = gme.balanceOf(address(seriesVault));
    }

    /// @dev No Variable 1(1)(2) The sentence - reuse `test/invariant/` That one, not here.
    function _assertPoolIsCollateralised(uint256 seriesId) internal view {
        address[] memory stocks = new address[](1);
        stocks[0] = ForkConfig.GME;
        uint256[] memory ids = new uint256[](1);
        ids[0] = seriesId;

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, stocks, ids);
        assertEq(
            perSeries,
            0,
            unicode"CRITICAL No Variable 1(1):Some sort of unsolved series under the real vault. minted It's beyond its collateral."
        );
        assertEq(
            global,
            0,
            unicode"CRITICAL No Variable 1(2):The real vault is down in the pool. GME I can't afford to pay the balance."
        );
    }

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

    //  Prices. Portal Values remain unchanged when moving from Checklist to Construct Parameters

    /// @notice CRITICAL **Decision-making 39-A2 The new parameter, the same address as the old table, is given on this chain.**
    ///
    /// @dev The vault used to be used. `VaultBase._getPortal()` Press `chainId` Check the forms. Portal;Now it's construction parameters.
    ///      The easiest mistake to make is not "microcode" but...**I took the wrong address when I moved it.**  -  -
    ///      The result of the error is that the price is not available and the series is never available.
    ///
    ///      So here's the... 4663 Three-way reconciliation: the upstream table (in the form)`src/flap/VaultBase.sol`,The government has not been able to take over the country.
    ///      We're only gonna file it. We're gonna check it ourselves. {ForkConfig.FLAP_PORTAL},and**This vault is really carrying it.**
    ///      That address. The three are the same. The move is still going on.
    ///
    ///      WARNING Guardian That's the half of the decision. 39-A3 Gone together: the vault no longer exists `guardian()`,
    ///      Flap Guardian There's no authority over it. The watch is still on file, but there's no consumer.
    function test_thePortalTheVaultCarriesEqualsWhatTheVendoredTableSays() public {
        assertEq(
            block.chainid,
            ForkConfig.ROBINHOOD_CHAIN_ID,
            unicode"This test is only for Robinhood Chain It's interesting."
        );

        VaultBaseProbe probe = new VaultBaseProbe();

        assertEq(
            probe.portal(), ForkConfig.FLAP_PORTAL, unicode"Upstream base type. Portal It's not the same as our test."
        );
        assertGt(ForkConfig.FLAP_PORTAL.code.length, 0, unicode"Portal There's no code on the address.");
        assertEq(
            vault.portal(), probe.portal(), unicode"CRITICAL The vault. Portal That's the one that the watch gave you."
        );

        console2.log(
            string.concat(
                "  Portal ",
                vm.toString(ForkConfig.FLAP_PORTAL),
                unicode"  code=",
                vm.toString(ForkConfig.FLAP_PORTAL.code.length),
                " bytes"
            )
        );
    }

    function test_vaultQuoteTokenIsTheRealGme() public view {
        assertEq(vault.vaultQuoteToken(), ForkConfig.GME, unicode"The currency of income should be real. GME");
        assertEq(vault.taxToken(), ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE, unicode"Services MEME");
        assertEq(vault.accountedQuote(), 0, unicode"The vault just deployed has no identified revenue.");
    }

    //  Balance discrepancy: real GME Transfer on -> ping -> Wait.

    /// @notice CRITICAL The acceptance clause: the agreement. ping To wake up the vault and keep the books correctly; repeat ping Wait.
    function test_transferAloneIsSilent_thenPingRecognizes_andRepeatedPingsAreIdempotent() public {
        uint256 amount = 25e18;
        deal(ForkConfig.GME, holder, amount);

        vm.prank(holder);
        gme.transfer(address(vault), amount);

        uint256 delivered = gme.balanceOf(address(vault));
        assertGt(delivered, 0, unicode"Real GME I should have paid.");
        assertEq(
            vault.accountedQuote(), 0, unicode"CRITICAL The transfer did not give the vault any chance of execution."
        );
        assertEq(vault.lastRevenueAt(), 0, unicode"And I didn't leave a moment for that.");

        (bool ok, uint256 gasUsed) = _ping();
        assertTrue(ok, unicode"ping Should be limited gas Internal Success");
        assertEq(
            vault.accountedQuote(), delivered, unicode"Make the difference between the real and the account balance."
        );
        assertEq(vault.lastRevenueAt(), uint64(block.timestamp), unicode"Write down the processing time.");

        // CRITICAL rule 005:Real GME Yes. BeaconProxy -> Stock,This reading is far more expensive than the double, but it is far from the budget.
        //    The situation is as it should be. 4.8 10,000 (including cold reading accounts) + Twice. SSTORE);10 The line is more than double that.
        //    Releaser for implementation `balanceOf` Weights change first here in red light.
        assertLt(gasUsed, 1_000_000, unicode"Normative rule 005 Hard ceiling");
        assertLt(
            gasUsed, 100_000, unicode"Real GME Actual expenses on the project should be much smaller than the ceiling"
        );
        console2.log(
            string.concat(unicode"  First time ping(It's cold reading. + Twice. SSTORE)gas=", vm.toString(gasUsed))
        );

        uint64 firstAt = vault.lastRevenueAt();
        vm.warp(block.timestamp + 1 days);

        (bool again, uint256 idempotentGas) = _ping();
        assertTrue(again);
        vm.prank(anyone);
        (bool third,) = _ping();
        assertTrue(third);

        assertEq(vault.accountedQuote(), delivered, unicode"CRITICAL Repeat ping Zero margin: nothing is identified.");
        assertEq(vault.lastRevenueAt(), firstAt, unicode"Zero margin is still at the processing point.");
        console2.log(string.concat(unicode"  Wait. ping((Zero difference)gas=", vm.toString(idempotentGas)));
    }

    function test_syncPicksUpRevenueThatArrivedWithoutAWake() public {
        deal(ForkConfig.GME, holder, 9e18);
        vm.prank(holder);
        gme.transfer(address(vault), 9e18);

        vm.prank(anyone); // No permission
        vault.sync();

        assertEq(
            vault.accountedQuote(),
            gme.balanceOf(address(vault)),
            unicode"sync() The unawaken receipt of the duplicates"
        );
    }

    /// @notice CRITICAL The vault does not hold any claims that could be called to make -- in real terms GME Form above: six without permission ABI The entrance is open to anyone.
    ///         And there's no way to get it. GME And no one is authorized to pull its cargo.
    ///
    /// @dev  Decision-making 39-A3 And then there was one less time here. initialize "The bottom of the search that must fail"  -
    ///      The entrance is completely non-existent.  No representation.  No initialization of that shot.
    ///      It does not exist." `test/CallVault.t.sol` Write face count and ABI - I'm gonna find a nail.
    ///
    /// @dev This vault has no series, so... `processRevenue()` It's the one who's gone.**Delay**That side:
    ///      It doesn't. revert,And I don't move the money. The only way out is to get to the pool.
    ///      {test_processRevenue_realGmeEndToEnd_andInvariants1And2StillHold} Heads up.
    function test_noEntryMovesTheRealGmeOut() public {
        deal(ForkConfig.GME, holder, 12e18);
        vm.prank(holder);
        gme.transfer(address(vault), 12e18);
        (bool ok,) = _ping();
        assertTrue(ok);

        uint256 held = gme.balanceOf(address(vault));

        vm.startPrank(anyone);
        vault.sync();
        vault.sampleTwap(); // And only return if the price fails. false;No branch can be moved. GME.
        (bool pinged,) = address(vault).call{value: 0, gas: PING_GAS}("");
        assertTrue(pinged);
        assertEq(vault.processRevenue(), 0, unicode"No series opened  You're late, you're not moving money. revert");
        assertEq(vault.claimCreatorFee(), 0, unicode"Zero cumulative  The sixth entrance is silent. no-op,No money.");
        vm.stopPrank();

        assertEq(
            gme.balanceOf(address(vault)),
            held,
            unicode"There's no portal that makes it real. GME Get out of the vault."
        );
        assertEq(gme.balanceOf(anyone), 0, unicode"Caller One wei I can't get it.");
        assertEq(gme.allowance(address(vault), anyone), 0, unicode"The vault never authorizes anyone.");
        assertEq(
            gme.allowance(address(vault), address(pool)), 0, unicode"I don't have a resident authorization for Ikeko."
        );
        assertEq(gme.allowance(address(vault), ForkConfig.FLAP_PORTAL), 0, unicode"Yeah. Portal No authorization.");
    }

    //  Income path: real GME Top processRevenue -> depositAndMint -> Cast

    /// @notice CRITICAL **Acceptance and acceptance clause: real GME Up and running. `processRevenue -> depositAndMint -> Cast`,
    ///         And it's said, M1 Non-variant 1 / 2 It's still in existence under the real treasury.**
    ///
    /// @dev No Variable 1 / 2 It was just... `VaultStub` We did it -- that's our own double.
    ///      Just go ahead and authorize and transfer. This is the first time that you've ever given a name to a woman.**The real vault.**(Balance balances are recorded, authorized, fully deposited)
    ///      On this side of the deposit, and the collateral is real. GME(BeaconProxy -> `Stock`,with a distribution-side fixer.
    ///
    ///      No Variable 2 The two-half are set up here:`minted` Incremental == Ichichi. GME Increased balance,
    ///      And the number of cards cast == `minted` Incremental. 1(1)(2) Reuse {CollateralCheck}.
    function test_processRevenue_realGmeEndToEnd_andInvariants1And2StillHold() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);

        uint256 delivered = _fundSeriesVault(25e18);
        assertGt(delivered, 0, unicode"Real GME I should have paid.");
        assertEq(
            seriesVault.accountedQuote(), delivered, unicode"Preconditions:ping I've already recognized the money."
        );

        uint256 poolBefore = gme.balanceOf(address(pool));
        uint256 mintedBefore = pool.series(seriesId).minted;
        uint256 callsBefore = call.balanceOf(address(distributor), seriesId);

        // CRITICAL Time must go one step forward, or the claim of "recording the moment of processing" will be taken. `_fundSeriesVault` The one in the box. ping
        //     Meet early   It's already put  lastRevenueAt The current block time is written.
        uint64 stampedByPing = seriesVault.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(anyone); // CRITICAL permissionless:Anyone can close the window.
        uint256 minted = seriesVault.processRevenue();

        uint256 balanceDelta = gme.balanceOf(address(pool)) - poolBefore;
        uint256 mintedDelta = pool.series(seriesId).minted - mintedBefore;

        uint256 protocolCut = delivered / 10;
        uint256 cut = (delivered - protocolCut) / 9;
        assertEq(
            minted,
            delivered - protocolCut - cut,
            unicode"Real GME Current zero tax  The nine achievable achievements in stock are foundry (decision-making) 49)"
        );
        assertEq(
            mintedDelta,
            balanceDelta,
            unicode"CRITICAL No Variable 2:minted Incremental == Ichichi. GME Increase in balance"
        );
        assertEq(
            call.balanceOf(address(distributor), seriesId) - callsBefore,
            mintedDelta,
            unicode"CRITICAL No Variable 2:Number of certificates cast == minted Incremental"
        );
        _assertPoolIsCollateralised(seriesId);

        // CRITICAL R4 And that phrase became two readings here: there's only one in the vault. creator Floating, "in transit" to zero.
        assertEq(
            gme.balanceOf(address(seriesVault)),
            cut + protocolCut,
            unicode"CRITICAL There's only one in the vault. creator Floating"
        );
        assertEq(seriesVault.creatorAccrued(), cut, unicode"Divisiond into accounts 10%");
        assertEq(
            seriesVault.accountedQuote(),
            cut + protocolCut,
            unicode"CRITICAL Baseline to real surplus (norm) rule 010-3)"
        );
        assertEq(gme.allowance(address(seriesVault), address(pool)), 0, unicode"No residuals left behind.");
        assertEq(seriesVault.lastRevenueAt(), uint64(block.timestamp), unicode"Write down the processing time.");
        assertGt(seriesVault.lastRevenueAt(), stampedByPing, unicode"And this moment was really pushed by this.");

        (uint256 held, bool exact) = seriesVault.inTransit();
        assertEq(held, 0, unicode"CRITICAL R4 : Real GME And the way it was going is zero.");
        assertTrue(exact, unicode"Real GME I can read the balance.");

        // creator In reality. GME I can get it, too -- anyone can trigger it, the money comes. creator.
        vm.prank(anyone);
        assertEq(
            seriesVault.claimCreatorFee(),
            cut,
            unicode"CRITICAL Deductions received in accordance with the established monitoring"
        );
        assertEq(gme.balanceOf(creator), cut, unicode"The money's all there is. creator");
        assertEq(gme.balanceOf(anyone), 0, unicode"Trigger one. wei I can't get it.");
        assertEq(
            seriesVault.accountedQuote(),
            protocolCut,
            unicode"The receipt baseline is the same as the pen to the real balance"
        );

        // And the vault was not locked for two expenses: the next one was real. GME I'm sure it's a good idea.
        uint256 more = _fundSeriesVault(4e18);
        assertEq(seriesVault.accountedQuote(), more + protocolCut, unicode"CRITICAL The baseline is not stuck.");
        assertEq(
            seriesVault.processRevenue(),
            more - more / 10 - (more - more / 10) / 9,
            unicode"CRITICAL It'll be in the next day."
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @notice CRITICAL **Receiving and Inspection Clause: Call during the global suspension of the issuer - clean failure, no money lost, retry after release.**
    ///
    /// @dev Press it.**Global**Pause (`PAUSER_ROLE`,A single freeze of all stock coins in the chain) -
    ///      `Stock.paused()` Back `$.paused || registry.paused()`,The most covered.
    ///      It's not about "it will fail" but about "it will fail."**Nothing bad.**:The balance, baseline, authorization, all of the same.
    ///      So, once after the break, it recovered.**There was only delay, no loss.**
    function test_processRevenue_failsCleanlyWhilePausedThenSucceedsAfterRelease() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);
        uint256 delivered = _fundSeriesVault(18e18);

        _mockGlobalPause(true);

        vm.prank(anyone);
        vm.expectRevert(IsPaused.selector);
        seriesVault.processRevenue();

        // CRITICAL Clean failure: rollbacks, three readings, none.
        assertEq(gme.balanceOf(address(seriesVault)), delivered, unicode"Money. wei A lot of it in the vault.");
        assertEq(
            seriesVault.accountedQuote(),
            delivered,
            unicode"The baseline is still intact -- it's still \"identified, not spent\""
        );
        assertEq(
            gme.allowance(address(seriesVault), address(pool)),
            0,
            unicode"The failed one left no residual authorization."
        );
        assertEq(pool.series(seriesId).minted, 0, unicode"Nothing happened at the pool.");

        // Just run again after you've been relieved -- no manager moves, no one remembers what to do first.
        vm.clearMockedCalls();
        vm.prank(anyone);
        assertEq(
            seriesVault.processRevenue(),
            delivered - delivered / 10 - (delivered - delivered / 10) / 9,
            unicode"After being discharged, retrying must be successful (90% enter the pool)"
        );
        assertEq(
            seriesVault.accountedQuote(),
            delivered / 10 + (delivered - delivered / 10) / 9,
            unicode"Baseline to creator Floating"
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @notice CRITICAL **Receiving and Inspection Clause: Called during the time the pool address was sealed - also clean failed, money was not lost, and could be retried after being removed.**
    ///
    /// @dev Two with the last one.**Different switches**(`PAUSER_ROLE` Other Organiser vs. The list of names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the names of the persons whose names are listed in the list.
    ///      Both are compiled. `Stock` Every transfer path. Separated because there's only one bad future.
    ///      Depends which one is bad.
    function test_processRevenue_failsCleanlyWhileThePoolIsBlockedThenSucceedsAfterRelease() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 seriesId = seriesVault.harnessOpenSeries(STRIKE, expiry);
        uint256 delivered = _fundSeriesVault(11e18);

        _mockPoolBlocked(true);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Blocked.selector, address(pool)));
        seriesVault.processRevenue();

        assertEq(gme.balanceOf(address(seriesVault)), delivered, unicode"Money. wei A lot of it in the vault.");
        assertEq(seriesVault.accountedQuote(), delivered, unicode"The baseline is still intact.");
        assertEq(
            gme.allowance(address(seriesVault), address(pool)),
            0,
            unicode"The failed one left no residual authorization."
        );

        vm.clearMockedCalls();
        vm.prank(anyone);
        assertEq(
            seriesVault.processRevenue(),
            delivered - delivered / 10 - (delivered - delivered / 10) / 9,
            unicode"Re-testing after unsealing must be successful (90% enter pool)"
        );
        _assertPoolIsCollateralised(seriesId);
    }

    /// @dev `description()` It's also replayed on the real numbers -- the front end uses it as a state-wide liner.
    function test_descriptionRendersOnRealNumbers() public {
        string memory before = vault.description();

        deal(ForkConfig.GME, holder, 3e18);
        vm.prank(holder);
        gme.transfer(address(vault), 3e18);
        (bool ok,) = _ping();
        assertTrue(ok);

        string memory after_ = vault.description();
        assertTrue(
            keccak256(bytes(before)) != keccak256(bytes(after_)),
            unicode"The government has been able to provide the necessary information to the public.description() It should have changed."
        );
        console2.log(string.concat("  description(): ", after_));
    }
}
