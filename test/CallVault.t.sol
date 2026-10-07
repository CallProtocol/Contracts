// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {CallVault} from "../src/CallVault.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {HostileQuoteToken} from "./helpers/HostileQuoteToken.sol";
import {
    DirtyBoolApprovalStockToken,
    GatedApprovalStockToken,
    GatedStockToken,
    IssuerBurnableUnreadableStockToken,
    NoOpStockToken,
    PartialDebitStockToken,
    PreUpdateReentrantStockToken,
    SenderPaysFeeStockToken,
    SilentApprovalFailureStockToken,
    SlowBalanceStockToken,
    StockToken
} from "./helpers/StockToken.sol";
import {CallVaultHarness} from "./helpers/CallVaultHarness.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";
import {WNativeMock} from "./helpers/WNativeMock.sol";

/// @notice `CallVault` External behaviour: skeleton (bone skeletal)M2-1,issue #33)+ TWAP(M2-2,issue #34)+
///         Income path (in millions of dollars)M2-3,issue #35).
///
/// This test has four main points. They're the ones that are supposed to be in three ticket acceptances. CRITICAL:
///
/// 1. **Balance discrepancy**:ERC20 The transfer does not give the recipient the opportunity to execute it.Flap The rest. ping It's the wake-up call.
///    Repeat ping - And so on; `receive()` **No path. revert**  -  -  The latter.
///    {HostileQuoteToken} Four models of failure drive, and the double doesn't prove it.
/// 2. **Income path**:Read it.**Actual balance**(Not a book value, cast by the volume of the pool, two clean returns.
///    (Zero balance / There is no living series; the currency fails to read it. CRITICAL Normative rule 010-3  -  -
///    The expenditure must be cleared from the same line of money, or the vault will be locked forever. {PreUpdateReentrantStockToken}
///    From**Worst order**Call it up. Call it back before the transfer takes effect. `sync()`.
/// 3. **TWAP The entrance.**:Price sampling is not permitted, but is strictly minimally spaced and 24 hour window constraints; specific time series in
///    `CallVaultTwap.t.sol`,This covers the integration of it with the rest of the writing.
/// 4. **Writing Noodles**:It's six externals, none of which is a power function, and none of which can deliver the goods.**Caller**Hands.
///    (Decision-making 49 It's... `claimCreatorFee` Only death is scheduled to occur to the construction period. creator).
///    These words are "something."**Cannot initialise Evolution's mail component.**,Only the compilers. ABI The whole list is a non-revolving evidence.
///    (Methodologies and Nonvariables 5 / 6 Share, see you. {WriteSurface}).
///
/// CRITICAL **M2-6(3)(issue #58)Then the vault will not be upgraded, and it will not inherit anything. Flap Base Category**:No, I'm not. beacon,No representation.
///    No, I'm not. `initialize`  -  -  Six tectonic parameters (decision-making) 49 & Inline creator)Yes. `CREATE` That's all I'm gonna get.
///    So every place down there is a line of building a vault. `new CallVault(..., address(0xfee))`,
///    And no longer "realized." + beacon + Proxy + initDataThose four sets.
///
/// CRITICAL Ike, license, distribution of contracts, registration form**It's all true.**(issue #5 : The deposit path crosses the vault and the pool.
/// The boundary, and the phrase "the amount of casting is based on the increase in the balance measured in the pool" is only said by the real pool.
///
/// The one on the real mark is in `test/fork/RobinhoodCallVault.t.sol`:We wrote the local double ourselves.
/// Of course he'll answer honestly. `balanceOf`,The issuer will certainly not be suspended.
contract CallVaultTest is Test {
    string internal constant ARTIFACT = "out/CallVault.sol/CallVault.json";

    /// @dev Simulation keeper It's... dispatch Budget: No agreement ping Top (Photo)EIP-150 The government has also been making efforts to improve the quality of the media.
    ///      But it's... keeper Run with a fixed budget.**The whole article** dispatch.Use a tight number. ping,
    ///      It proves that "the vault won't put keeper I'm starving."
    uint256 internal constant PING_GAS = 500_000;

    /// @dev Sample value of current weekly right-of-the-line prices: per 1e18 raw Stock tokens need to be destroyed. 1850e18 raw MEME.Same caliber
    ///      `ClearingPool.Series.strike`,The value itself is not heavy.
    uint128 internal constant STRIKE = 1850e18;

    CallVault internal vault;
    StockToken internal stock;

    /// @dev CRITICAL **Real Four, not doubles.**(issue #5 :M2-3 The way of deposit is to cross the boundaries of the vault and the pool.
    ///      The phrase "the amount of casting is based on the increase in the balance measured in the pool" is only said by the real pool.
    ClearingPool internal pool;
    Call internal call;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;

    /// @dev CRITICAL Prices. Portal Now.**Construct Parameters**(Decision-making 39-A2),No longer base type by `chainId` Recovered Literary Quantities...
    ///      So the local test directly deploys a double and sends his address in. `etch` To a dead address.
    ///      And no need to pretend the whole test is in. chainId 4663 Run up.**This is what the change bought.**
    FlapPortalStub internal portal;

    address internal meme = makeAddr("meme");
    address internal alice = makeAddr("alice");

    /// @dev Decision-making 49:The sixth construct parameter of the vault -- the launcher, the only recipient of the split.
    address internal creator = makeAddr("creator");

    function setUp() public {
        portal = new FlapPortalStub();

        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        stock = new StockToken();
        vault = _deployVault(meme, address(stock));
    }

    //  Scaffolding.

    /// @dev It's the same thing as what the factory is about to do:**One line. `new`**,Six parameters are all dead in the construction of that one.
    ///      (Decision-making 39-A3;I used to be. beacon + Proxy + `initialize` Three sets.
    ///      The pool and distribution contract are still in the vault. `immutable`  -  -  That's decision-making. 33The factory must not. `vaultData` and
    ///      `creator` The form of landing as a source of privilege is only that they are now filled in by the plant in the amount of the deployment.
    ///      Decision-making 49 Rise creator It's also a construction. `immutable`((b) Discrepancies of the award: it is still not a source of privilege.
    function _deployVault(address taxToken, address quoteToken) internal returns (CallVault) {
        return new CallVault(
            pool, address(distributor), address(portal), taxToken, quoteToken, creator, false, address(0xfee)
        );
    }

    /// @dev One.**This week's series has been set up.**The vault. Here we go. {CallVaultHarness} The entry of any parameters,
    ///      Not real. `openSeries()`:This paper looks at income paths and public statements, and should not be spent first. 24 Hours.
    ///      TWAP The rings are full -- otherwise `processRevenue` The reason for the failure is one day,TWAP Not ready."
    ///      The whole thing is in the real entrance. `test/CallVaultOpenSeries.t.sol`.
    function _deployHarnessWithOpenSeries(StockToken quote, uint64 expiry)
        internal
        returns (CallVaultHarness harness, uint256 seriesId)
    {
        harness = _deployHarness(address(quote));
        factory.bind(meme, address(harness));
        seriesId = harness.harnessOpenSeries(STRIKE, expiry);
    }

    function _deployHarness(address quoteToken) internal returns (CallVaultHarness) {
        return new CallVaultHarness(pool, address(distributor), address(portal), meme, quoteToken, creator, false);
    }

    /// @dev Original livelihood price (%)C2,7.14)It's... harness:The currency of the income is WBNB Double, double, double, double.`wrapsNative = true`,
    ///      And have set up the week series. harness,WBNB and seriesId.
    function _deployNativeHarnessWithOpenSeries(uint64 expiry)
        internal
        returns (CallVaultHarness harness, WNativeMock wbnb, uint256 seriesId)
    {
        wbnb = new WNativeMock();
        harness = new CallVaultHarness(pool, address(distributor), address(portal), meme, address(wbnb), creator, true);
        factory.bind(meme, address(harness));
        seriesId = harness.harnessOpenSeries(STRIKE, expiry);
    }

    /// @dev Flap . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . calldata,Limits gas.
    function _ping(CallVault target) internal returns (bool ok) {
        (ok,) = address(target).call{value: 0, gas: PING_GAS}("");
    }

    function _hasSubstring(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    //  Identity: Six parameters are fixed in the construction of the one.

    function test_identity_declaresTheBoundStockAndTheServedMeme() public view {
        assertEq(vault.vaultQuoteToken(), address(stock), unicode"The currency of income should be a bonding stock.");
        assertEq(vault.taxToken(), meme, unicode"Services MEME");
        assertEq(address(vault.pool()), address(pool), unicode"Where the collateral goes.");
        assertEq(vault.merkleDistributor(), address(distributor), unicode"The license.");
        assertEq(vault.portal(), address(portal), unicode"The price is the construction parameter.");
        assertEq(vault.creator(), creator, unicode"tectonic parameters for split recipients (decision-making) 49)");
        assertEq(vault.CREATOR_FEE_BPS(), 1000, unicode"Proportional is the platform level constant 10%");
        assertGt(bytes(vault.description()).length, 0, unicode"description() It's not supposed to be empty.");
    }

    /// @notice CRITICAL **A vault that was not initialized is no longer in existence.**
    ///
    /// @dev It was once a constant, maintained by plant discipline (must) `new BeaconProxy(beacon, initData)`,
    ///      Not left blank) `initialize`,Six identity parameters are constructed.
    ///      This test is from ABI The side nailed it -- it was not in the face count either.
    function test_identity_thereIsNoInitializeEntryPoint() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("initialize(address,address)", meme, address(stock)));
        assertFalse(
            ok,
            unicode"There's no way there's a vault. initialize  -  -  There's no \"deployment before initialization\" shot without an upgrade."
        );
    }

    /// @dev Seven-track structural checks, one by one.CRITICAL They're falling.**Construct**What it means is that a wrong vault is...
    ///      **The deal that created it.**Lee died instead of waiting for the first time. `processRevenue` I'm not sure if I'm going to find out.
    ///      Yes. D0 In the layout, this rollback takes the whole launch together, without half of the identity tied.
    function test_constructor_rejectsZeroAddressesAndCodelessQuote() public {
        vm.expectRevert(unicode"Clearing pool is the zero address");
        new CallVault(
            ClearingPool(address(0)),
            address(distributor),
            address(portal),
            meme,
            address(stock),
            creator,
            false,
            address(0xfee)
        );

        vm.expectRevert(unicode"Distributor is the zero address");
        new CallVault(pool, address(0), address(portal), meme, address(stock), creator, false, address(0xfee));

        vm.expectRevert(unicode"Portal is the zero address");
        new CallVault(pool, address(distributor), address(0), meme, address(stock), creator, false, address(0xfee));

        vm.expectRevert(unicode"Tax token is the zero address");
        new CallVault(
            pool, address(distributor), address(portal), address(0), address(stock), creator, false, address(0xfee)
        );

        vm.expectRevert(unicode"Quote token is the zero address");
        new CallVault(pool, address(distributor), address(portal), meme, address(0), creator, false, address(0xfee));

        // CRITICAL EOA Top staticcall Back**Success**And the data is empty -- without this, the vault will never be able to get back.
        //    No income, and no sound.
        vm.expectRevert(unicode"Quote token has no code");
        new CallVault(pool, address(distributor), address(portal), meme, alice, creator, false, address(0xfee));

        // CRITICAL Zero addresses creator = Split into black holes. 49):Money can't reach anyone, nor can it go back to the pool.
        vm.expectRevert(unicode"Creator is the zero address");
        new CallVault(
            pool, address(distributor), address(portal), meme, address(stock), address(0), false, address(0xfee)
        );
    }

    /// @notice CRITICAL **Different vaults can coexist with different prices.**  -  -  Decision-making 39-A2 The whole point.
    ///
    /// @dev Once upon a time, Portal From `VaultBase._getPortal()` That one. `chainId` The death watch.
    ///      So each vault in the chain shares the same source of price, and the exchange of price will have to be realized -- and the vault is not upgraded now.
    ///      The road is equal to none. When the parameters are changed to construction, no switch is required for "old and new " items.
    function test_portal_isPerVaultSoPriceSourcesCanCoexist() public {
        FlapPortalStub nextGeneration = new FlapPortalStub();
        CallVault younger = new CallVault(
            pool, address(distributor), address(nextGeneration), meme, address(stock), creator, false, address(0xfee)
        );

        assertEq(vault.portal(), address(portal), unicode"The old vault still reads the old price.");
        assertEq(younger.portal(), address(nextGeneration), unicode"New Treasury Read New Price");
        assertTrue(vault.portal() != younger.portal(), unicode"CRITICAL The test is the only thing that's relevant.");
    }

    //  Balance difference between ping

    /// @dev Core normative facts:ERC20 It's... `transfer` And the execution is**Currency contract**The code, not the recipient's...
    ///      The vault gets the money, but it doesn't get the money. The protocol. ping It's the wake-up call.
    function test_erc20Revenue_transferAloneIsSilent_pingRecognizes() public {
        stock.mint(alice, 25e18);

        vm.prank(alice);
        stock.transfer(address(vault), 25e18);
        assertEq(
            vault.accountedQuote(), 0, unicode"The vault should not recognize any income just for money transfers."
        );
        assertEq(vault.lastRevenueAt(), 0, unicode"I shouldn't have left the moment for the treatment.");

        assertTrue(_ping(vault), unicode"ping Should be limited gas Internal Success");
        assertEq(vault.accountedQuote(), 25e18, unicode"ping Then I'll identify it as a balance difference.");
        assertEq(vault.lastRevenueAt(), uint64(block.timestamp), unicode"Write down the processing time.");
    }

    /// @dev Normative rule 2:Same time. dispatch Maybe it's the same wallet. ping Many times, anyone can be transferred. `receive()`.
    ///      The difference must be awakened.**Silence. no-op**.
    function test_ping_isIdempotent() public {
        stock.mint(address(vault), 5e18);
        assertTrue(_ping(vault));
        assertEq(vault.accountedQuote(), 5e18);

        uint64 firstAt = vault.lastRevenueAt();
        vm.warp(block.timestamp + 1 days);

        assertTrue(_ping(vault));
        assertTrue(_ping(vault));
        vm.prank(alice);
        assertTrue(_ping(vault));

        assertEq(vault.accountedQuote(), 5e18, unicode"Zero difference. ping Nothing should be identified.");
        assertEq(vault.lastRevenueAt(), firstAt, unicode"Zero difference. ping I shouldn't have moved on.");
    }

    function test_sync_picksUpRevenueThatArrivedWithoutAWake() public {
        stock.mint(address(vault), 3e18);

        vm.prank(alice); // No permission
        vault.sync();

        assertEq(vault.accountedQuote(), 3e18, unicode"sync() The unawaken receipt of the duplicates");
    }

    function testFuzz_recognizesExactlyTheDelta(uint128 first, uint128 second) public {
        stock.mint(address(vault), first);
        assertTrue(_ping(vault));
        assertEq(vault.accountedQuote(), first, unicode"First paragraph");

        stock.mint(address(vault), second);
        assertTrue(_ping(vault));
        assertEq(
            vault.accountedQuote(),
            uint256(first) + second,
            unicode"The second is the sum of the differences, not the double counting."
        );
    }

    /// @dev CRITICAL `receive()` Everything in it must be loaded. keeper Budget. rule 005 The hard limit is... 100 Thousand gas,
    ///      And a compliance should be far lower than it -- here's the latter.
    function test_ping_staysFarUnderTheReceiveGasBudget() public {
        stock.mint(address(vault), 7e18);

        uint256 before = gasleft();
        (bool ok,) = address(vault).call{value: 0, gas: PING_GAS}("");
        uint256 used = before - gasleft();

        assertTrue(ok, unicode"ping It's not a failure.");
        emit log_named_uint("ERC20 receive recognition gas", used);
        assertLt(used, 1_000_000, unicode"Normative rule 005 Hard ceiling");
        assertLt(used, 100_000, unicode"The actual cost of local replacements should be much smaller than the ceiling.");
    }

    /// @dev CRITICAL This is the biggest bet in the whole test:`receive()` By Flap It's... dispatch Trigger.
    ///       It once  revert,What's affected is... **Flap Tax settlement**.And... `receive()` The only thing in there is beyond our control.
    ///      One step is to read the balance of the income currency -- the currency of the income is issued to upgrade the whole. BeaconProxy.
    function test_receive_neverReverts_whateverTheQuoteTokenDoes() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        CallVault hostileVault = _deployVault(meme, address(hostile));

        HostileQuoteToken.Mode[4] memory modes = [
            HostileQuoteToken.Mode.Revert,
            HostileQuoteToken.Mode.Empty,
            HostileQuoteToken.Mode.Short,
            HostileQuoteToken.Mode.BurnGas
        ];

        for (uint256 i = 0; i < modes.length; i++) {
            hostile.set(modes[i], 100e18);

            vm.expectEmit(true, false, false, false, address(hostileVault));
            emit CallVault.QuoteBalanceUnreadable(address(hostile));
            assertTrue(_ping(hostileVault), unicode"The money is bad.ping You should never fail.");

            assertEq(
                hostileVault.accountedQuote(), 0, unicode"If you can't read the balance, you shouldn't keep a book."
            );
            hostileVault.sync(); // Same path, same path. revert
        }

        // CRITICAL I can't read it.**Current**Skip: Income is calculated as the difference, and the currency is restored and replaced once and for all.
        hostile.set(HostileQuoteToken.Mode.Honest, 100e18);
        assertTrue(_ping(hostileVault));
        assertEq(
            hostileVault.accountedQuote(), 100e18, unicode"After recovery, it should be completed once and for all."
        );
    }

    /// @dev CRITICAL The fifth failure pattern is a separate article, because it's a block.**Not within limit gas Inside**Cost:
    ///      `(bool, bytes memory) = addr.staticcall(...)`  Will take the whole  returndata I'm not sure I'm going to be able to do this.
    ///      And that memory expansion was...**Caller**Pay the bill. The other one's in the... 20 Thousand gas The limit of the contract. 288KB Return data,
    ///      Copy it, and then you'll have to meet again. 18.5 10,000-- `receive()` The cost of the operation went out of control.
    ///      Only the vault. 32 Bytes, so the amount of this assertion is "that copy did not happen."
    function test_receive_doesNotPayForAFloodedReturnValue() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        CallVault hostileVault = _deployVault(meme, address(hostile));
        hostile.set(HostileQuoteToken.Mode.Flood, 100e18);

        uint256 before = gasleft();
        (bool ok,) = address(hostileVault).call{value: 0, gas: PING_GAS}("");
        uint256 used = before - gasleft();

        assertTrue(ok, unicode"Returning a large piece of data should not be allowed. ping Failed");
        // Upper boundary = It's been transmitted. 20 - Man.+ We're on this side of the balance.
        // Copy that. returndata We'll meet again. 18.5 Van, cross this line.
        assertLt(
            used, 250_000, unicode"CRITICAL returndata It's copied in... the cost of the operation is out of control."
        );
    }

    /// @dev Original currency is not the principal bank's income currency. revert  -  -  The latter will let Flap It's...
    ///      dispatch And then it's a failure. The price is the original coin.**I can't get it out.**,It's deliberate: one. sweep Functions
    ///      It's just a power function, and... Guardian The terms will make it... Flap A key.
    function test_receive_acceptsNativeValueButNeverCountsItAsRevenue() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");

        assertTrue(ok, unicode"No, no, no, no, no, no. revert");
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.accountedQuote(), 0, unicode"Original currency is not income.");
    }

    //  Income path processRevenue(M2-3,issue #35)

    /// @notice Regular day on receipt (decision-making) 49 Caliber: Available 90% Into the pool.10% Here. creator,
    ///         The certificate is made for distributor,"In the middle of the journey" to zero -- the only remaining balance in the vault is creator Floating.
    ///
    /// @dev Three acceptance clauses are also established in this article:**Actual balance**Not a bookkeeping value.
    ///      Never. ping Over, the vault counts it together, the amount of casting is measured by the pool, and CRITICAL Normative
    ///      rule 010-3  -  -  The baseline after expenditure must be reached to the real remaining balance (in thousands of United States dollars)= creator If not, the vault will never be locked.
    function test_processRevenue_depositsTheWholeDepositableBalanceAndMintsToTheDistributor() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);

        // First one. ping Yes, the second one, no... the vault is stored.**Balance**,Not his own account.
        stock.mint(address(harness), 30e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        assertEq(harness.accountedQuote(), 30e18, unicode"Precondition: First only recognized");
        stock.mint(address(harness), 12e18);

        // CRITICAL Time must go one step forward, or the claim of "recording the moment of processing" will be taken.**The one on top. ping** Pre-met  -
        //    It's already put lastRevenueAt The blog is a blog that has been published on the blog of the blog.processRevenue And even if it doesn't touch a byte, it's green.
        uint64 stampedByPing = harness.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);

        // 42e18 Available stock  4.2e18 Here. creator,33.6e18 Get in the pool. The two events are nailed in the order of their realization.
        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.CreatorFeeAccrued(4.2e18, 4.2e18);
        vm.expectEmit(true, false, false, true, address(harness));
        emit CallVault.RevenueDeposited(seriesId, 33.6e18, 33.6e18);
        uint256 minted = harness.processRevenue();

        assertEq(
            minted,
            33.6e18,
            unicode"No, I'm not. ping The one that passed was also counted as a stock, 90% of which was in the pool."
        );
        assertEq(stock.balanceOf(address(harness)), 8.4e18, unicode"There's only one in the vault. creator Floating");
        assertEq(harness.creatorAccrued(), 4.2e18, unicode"Divisiond into accounts 10%");
        assertEq(stock.balanceOf(address(pool)), 33.6e18, unicode"The collateral went into the pool.");
        assertEq(
            call.balanceOf(address(distributor), seriesId), 33.6e18, unicode"The certificate was made. distributor"
        );

        // CRITICAL rule 010-3:The baseline must follow the expenditure to the real balance. = The vault is permanently locked.
        assertEq(harness.accountedQuote(), 8.4e18, unicode"Baseline = creator Floating");
        (uint256 held, bool exact) = harness.inTransit();
        assertTrue(exact);
        assertEq(held, 0, unicode" On the way to zero  creator Floating is not in it.");
        assertEq(harness.lastRevenueAt(), uint64(block.timestamp), unicode"Write down the processing time.");
        assertGt(harness.lastRevenueAt(), stampedByPing, unicode"And this moment was really pushed by this.");

        // Moreover, the vault did not die as a result: the next income was recognized and kept in the way it was (90%).
        stock.mint(address(harness), 5e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        assertEq(
            harness.accountedQuote(),
            13.4e18,
            unicode"CRITICAL The baseline is not stuck, new revenue is still recognized"
        );
        assertEq(harness.processRevenue(), 4e18, unicode"It's still in there.5e18 90% of the total)");
        assertEq(harness.creatorAccrued(), 4.7e18, unicode"Division continues to accumulate");
    }

    /// @notice CRITICAL Acceptance clause: foundry measured in pool**Increase in balance**Whichever is so; the vault does not calculate its own amount.
    ///         Yeah.**No, I don't.** `minted == balance`.
    ///
    /// @dev The two are said to be equal to the death of the "stock token without transfer tax" in the product. GME The current zero tax is not a tax.
    ///      But the issuer can upgrade it as a whole -- and the pool is open for any stock coin.
    function test_processRevenue_mintsThePoolsBalanceDeltaNotTheAmountItSent() public {
        StockToken taxed = new StockToken();
        taxed.setTaxBps(300); // 3%

        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(taxed, expiry);

        taxed.mint(address(harness), 100e18);
        uint256 poolBefore = taxed.balanceOf(address(pool));

        uint256 minted = harness.processRevenue();
        uint256 delta = taxed.balanceOf(address(pool)) - poolBefore;

        assertEq(minted, delta, unicode"CRITICAL Casting == Measured increase in pool balance (no variable) 2)");
        assertEq(
            minted,
            77.6e18,
            unicode"Deposit 90e18(The government has been able to provide a better understanding of the problem.3% The taxes were actually withheld."
        );
        assertLt(minted, 90e18, unicode"CRITICAL If this doesn't work, the test is not measuring the tax token.");
        assertEq(call.balanceOf(address(distributor), seriesId), minted, unicode"Number of certificates == Casting");
        assertEq(taxed.balanceOf(address(harness)), 20e18, unicode"There's only one in the vault. creator Floating");
        assertEq(harness.creatorAccrued(), 10e18, unicode"Share of available 10% Recording");
        assertEq(harness.accountedQuote(), 20e18, unicode"Baseline to real surplus");
    }

    /// @notice Even if the pool is successfully called, it will be possible to update the baseline against the actual balance of the vault. `sent` Event field.
    /// @dev Non-standard ERC-20 You can. `transferFrom` Back true But they don't move the balance; the pool is made honestly. 0,
    ///      The vault cannot misdirect the collateral still in hand, otherwise the same money will be recognized again next time.
    function test_processRevenue_keepsTheResidualWhenTransferFromReturnsTrueButMovesNothing() public {
        NoOpStockToken noOp = new NoOpStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(noOp, expiry);

        noOp.mint(address(harness), 25e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        uint64 recognisedAt = harness.lastRevenueAt();
        vm.warp(block.timestamp + 1 hours);
        noOp.setNoOpTransfers(true);

        vm.expectEmit(true, false, false, true, address(harness));
        emit CallVault.RevenueDeposited(seriesId, 0, 0);
        assertEq(harness.processRevenue(), 0, unicode"I've got no balance.  No casting certificate");

        assertEq(
            noOp.balanceOf(address(harness)), 25e18, unicode"If you succeed, you can't make the balance disappear."
        );
        assertEq(noOp.balanceOf(address(pool)), 0, unicode"The pool actually got taken away from the collateral.");
        assertEq(harness.accountedQuote(), 25e18, unicode"Baseline must retain real surplus");
        assertEq(
            harness.creatorAccrued(),
            0,
            unicode"CRITICAL No share of false success (decision-making) 49-4),Otherwise, the same money is divided in doubles when retrying."
        );
        assertEq(harness.lastRevenueAt(), recognisedAt, unicode"You can't fake a time of income processing.");
        assertEq(noOp.allowance(address(harness), address(pool)), 0, unicode"Still no permanent authorization.");
        assertEq(call.balanceOf(address(distributor), seriesId), 0, unicode"No collateral, no call.");

        // Once the transfer has resumed, the same income can be safely retested and not identified or permanently contained.
        noOp.setNoOpTransfers(false);
        assertEq(
            harness.processRevenue(), 20e18, unicode"Retryable actual deposit after recovery (90% of available stock)"
        );
        assertEq(
            harness.creatorAccrued(),
            2.5e18,
            unicode"The split was only recorded once, and only once, on the successful basis of the actual monitoring of the deduction"
        );
        assertEq(
            harness.accountedQuote(), 5e18, unicode"The baseline actually fell after it was cleared creator Floating"
        );
        assertEq(
            harness.lastRevenueAt(),
            uint64(block.timestamp),
            unicode"The actual deductions are the advance of the processing moment."
        );
    }

    /// @notice CRITICAL Acceptance clause: balance 0 Time**Get back clean. No. revert**  -  -  Trigger Service Run empty once a day.
    function test_processRevenue_isACleanNoOpWhenThereIsNothingToDeposit() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        vm.recordLogs();
        assertEq(harness.processRevenue(), 0, unicode"There's no money left.  Back 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"There should be no incident when you run.");

        assertEq(harness.accountedQuote(), 0);
        assertEq(harness.lastRevenueAt(), 0, unicode"It's not time to move.");
    }

    /// @notice CRITICAL Acceptance and acceptance clauses:**No current open series  Reject and emit,The money stays in the vault and so on.**
    ///
    /// @dev Three things must be established simultaneously: no. revert(Trigger Service The alarm will be contaminated. It will not be swallowed.
    ///      (The road openings are being stretched, and must be visible under the chain, and must not be stored in the wrong series.
    ///      The two "no series" are measured separately because they have different movements: never opened. = `openSeries()` I haven't run for the first time.
    ///      Due = Last week was over and the next week was not open.
    function test_processRevenue_defersAndEmitsWhenNoSeriesHasEverBeenOpened() public {
        stock.mint(address(vault), 7e18);

        vm.expectEmit(false, false, false, true, address(vault));
        emit CallVault.RevenueDeferred(6.3e18, 0);
        assertEq(vault.processRevenue(), 0, unicode"No series  Not available");

        assertEq(stock.balanceOf(address(vault)), 7e18, unicode"CRITICAL The money's in the vault. One. wei A lot.");
        assertEq(vault.accountedQuote(), 7e18, unicode"And it's still \"identified, undisbursed.\"");
        assertEq(call.balanceOf(address(distributor), 0), 0, unicode"No one's ever made anything in any series.");
    }

    function test_processRevenue_defersOnceTheCurrentSeriesHasExpired() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 9e18);
        vm.warp(uint256(expiry)); // The second it expires, it expires:`block.timestamp < seriesExpiry` It's strict less than

        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.RevenueDeferred(8.1e18, expiry);
        assertEq(harness.processRevenue(), 0, unicode"Series expired  Not available");
        assertEq(
            stock.balanceOf(address(harness)), 9e18, unicode"The money's in the vault, waiting for the next series."
        );

        // When the next series is opened, the same money will be gone. **There's only delay, no loss.**.
        uint64 next = uint64(block.timestamp + 7 days);
        uint256 nextSeries = harness.harnessOpenSeries(STRIKE, next);
        assertEq(harness.processRevenue(), 7.2e18, unicode"The next series will be back and run again.");
        assertEq(call.balanceOf(address(distributor), nextSeries), 7.2e18, unicode"I've got a new series.");
        assertEq(
            harness.creatorAccrued(),
            0.9e18,
            unicode"10% of the time it was deposited, creator  -  -  No advance notice for deferred periods"
        );
    }

    /// @notice CRITICAL Acceptance and acceptance clauses:**permissionless**  -  -  The government has already been able to provide financial support to the government, but the government has not yet made a decision to expedite the release of funds from the upgraded contract.
    /// @dev And nail it to the second half: caller.**It doesn't change.**Money's going. Take a caller.
    ///      The collateral is still in the pool, the license is still in the pool. distributor,He's alone. wei I can't get it.
    function testFuzz_processRevenue_isPermissionlessAndTheCallerGetsNothing(address caller) public {
        vm.assume(caller != address(0) && caller != address(pool));

        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);
        // CRITICAL creator And you have to exclude that he is not the object of this article - divided by pull I'm sorry.processRevenue In itself
        //    One. wei I'm not going to give it to him, but."caller Balance 0This claim is only true. creator . The caller is unchanged.
        vm.assume(caller != address(harness) && caller != address(distributor) && caller != creator);

        stock.mint(address(harness), 20e18);

        vm.prank(caller);
        uint256 minted = harness.processRevenue();

        assertEq(minted, 16e18, unicode"Anyone can make it.");
        assertEq(stock.balanceOf(caller), 0, unicode"CRITICAL Caller One wei I can't get it.");
        assertEq(call.balanceOf(caller, seriesId), 0, unicode"CRITICAL He's not getting the call.");
        assertEq(stock.balanceOf(address(pool)), 16e18, unicode"Money only flows to the pool.");
        assertEq(
            call.balanceOf(address(distributor), seriesId), 16e18, unicode"The license is only possible. distributor"
        );
        assertEq(
            stock.balanceOf(address(harness)),
            4e18,
            unicode"Ten percent of them stay in the vault and so on. creator Retrieving - not caller"
        );
    }

    /// @notice CRITICAL **Between the two deals, the vault's authorization to pool is constant. 0.**
    /// @dev The deposit must be authorized for the pool. `transferFrom` (Put it in the box) but that authorization only exists in the amount deposited.
    ///      A permanent, unlimited authorization will not happen immediately -- the pool will not be upgraded, and only the pool will be able to be upgraded. `depositAndMint` Li La...
    ///      But it would downgrade the "how much money can the vault be moved at this moment" from a structural fact to a guarantee that someone will read the code.
    function test_processRevenue_leavesNoStandingAllowance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        assertEq(stock.allowance(address(harness), address(pool)), 0, unicode"Before you put it in. 0");

        stock.mint(address(harness), 15e18);
        harness.processRevenue();

        assertEq(stock.allowance(address(harness), address(pool)), 0, unicode"It's still after the deposit. 0");
    }

    /// @notice CRITICAL **Normative rule 010-3 The stitch: transfer back and re-route. `sync()`,The vault can't be locked.**
    ///
    /// @dev The vault transfers the balance to the pool. The coin is in.**Before the change in balance**Redirect the vault. `sync()`  -  -
    ///      The balance is still full. If the vault calls outside,**Before**Just... `accountedQuote` Zero.
    ///      This time. `sync()` You see, "The balance is full, the baseline is full." 0,Full roll back of the baseline; transfer is then effective,
    ///      The baseline is permanently above the real balance.`balance <= accountedQuote` From this point, press all revenue recognitions...
    ///      **The vault is locked and it's not ringing.**.
    ///
    ///      The order of things now makes it natural that... no-op:`_recognize()` The baseline has been fully rolled.
    ///      So the last two lines of this test are the whole point of it. **The vault is alive.**.
    function test_processRevenue_aReentrantSyncCannotDeadlockTheVault() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();

        uint64 expiry = uint64(block.timestamp + 7 days);
        CallVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);
        hostile.armReentrancy(address(harness), abi.encodeCall(CallVault.sync, ()));

        hostile.mint(address(harness), 40e18);
        assertEq(
            harness.processRevenue(),
            32e18,
            unicode"The deposit itself should be successful (90% of the available stock)"
        );

        // The echo really did -- otherwise the two claims down there didn't prove anything.
        assertGt(hostile.reentryAttempts(), 0, unicode"Once more, it didn't trigger. This test was empty.");
        assertTrue(hostile.reentrySucceeded(), unicode"sync() Yes. no-op,I shouldn't. revert");

        // CRITICAL The vault is still alive: the baseline is not on the real balance. 49 Then "real balance."= creator floating,
        //    The sentence went from zero to "equivalent to floating" -- higher than it was. wei It's the beginning of the lock.
        assertEq(
            harness.accountedQuote(), 8e18, unicode"CRITICAL The baseline is pushed back up -- the vault is locked."
        );
        assertEq(harness.creatorAccrued(), 4e18, unicode"Floating in line with baseline");
        hostile.mint(address(harness), 6e18);
        harness.sync();
        assertEq(harness.accountedQuote(), 14e18, unicode"CRITICAL New revenue still recognized");
        assertEq(harness.processRevenue(), 4.8e18, unicode"CRITICAL And it's still there.6e18 90% of the total)");
    }

    /// @notice CRITICAL **When the balance cannot be read, the only exit from the vault must be the same as the one that failed. `receive()` Still need fail-open.**
    function test_processRevenue_revertsWhenBalanceIsUnreadableWhileReceiveFailsOpen() public {
        HostileQuoteToken hostile = new HostileQuoteToken();
        CallVault hostileVault = _deployVault(meme, address(hostile));

        // (1) The currency is completely broken: failure, not quiet return 0.
        hostile.set(HostileQuoteToken.Mode.Revert, 100e18);
        vm.expectRevert(unicode"Quote balance unreadable");
        hostileVault.processRevenue();

        // (2) `receive()` There's still no one on that side. revert  -  -  The choice between the two paths is the opposite and must be the opposite.
        vm.expectEmit(true, false, false, false, address(hostileVault));
        emit CallVault.QuoteBalanceUnreadable(address(hostile));
        assertTrue(_ping(hostileVault), unicode"ping I still shouldn't have failed.");
        assertEq(hostileVault.accountedQuote(), 0);
    }

    /// @notice CRITICAL **The same slow but healthy currency:receive Seattop reading fail-open,processRevenue . The non-cap reading can be deposited.**
    /// @dev This is the real difference between the two paths: fixed workloads 20 Thousand gas It's... `staticcall` Failed, but ordinary transaction
    ///      Full of the inside. ERC-20 The path to the real pool is still complete; infinite burning gas The injection cannot prove it.
    function test_processRevenue_rejectsUnreadableBoundedBalance() public {
        SlowBalanceStockToken slow = new SlowBalanceStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(slow, expiry);

        slow.mint(address(harness), 11e18);

        bytes memory balanceCall = abi.encodeCall(IERC20.balanceOf, (address(harness)));
        (bool cappedRead,) = address(slow).staticcall{gas: 200_000}(balanceCall);
        assertFalse(cappedRead, unicode"20 Thousand gas I can't read the top of the page.");
        (bool fullRead, bytes memory returned) = address(slow).staticcall{gas: 1_000_000}(balanceCall);
        assertTrue(fullRead, unicode"Higher but limited gas The budget can be read.");
        assertEq(abi.decode(returned, (uint256)), 11e18, unicode"Slow reading still returns real balance");

        vm.expectEmit(true, false, false, false, address(harness));
        emit CallVault.QuoteBalanceUnreadable(address(slow));
        assertTrue(_ping(CallVault(payable(address(harness)))), unicode"You can't slow down. receive Roll back");
        assertEq(harness.accountedQuote(), 0, unicode"Caption reading failed  No guess of the balance.");

        vm.expectRevert(unicode"Quote balance unreadable");
        harness.processRevenue();
        assertEq(slow.balanceOf(address(harness)), 11e18);
        assertEq(slow.balanceOf(address(pool)), 0);
        assertEq(call.balanceOf(address(distributor), seriesId), 0);
    }

    /// @notice CRITICAL **`accountedQuote` It's just a baseline of accounts.`inTransit()` Yes. R4 .**
    ///
    /// @dev The norm lists four "awakening" normal patterns.{VaultBaseV3} rule 010-4 / rule 5,ping law 2):
    ///      Direct transfers and donations are not issued ping,ping Yes. processor The top's off.ping The failure will be ignored.
    ///      And the contract itself. `QuoteBalanceUnreadable` Path. Take the baseline as open reading,
    ///      It happens to be.**The kind that should call the police is not working.**Bottom Read 0  -  -  Taxes are still coming in, but nothing wakes up the vault.
    function test_inTransit_readsTheRealBalanceNotTheRecognisedBaseline() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        // After a full round, you'll have to set the baseline. creator Floating (in %2)42e18 Ten percent.
        stock.mint(address(harness), 42e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        harness.processRevenue();
        assertEq(harness.accountedQuote(), 8.4e18, unicode"Precondition: baseline = creator Floating");
        {
            (uint256 quiet, bool quietExact) = harness.inTransit();
            assertTrue(quietExact);
            assertEq(quiet, 0, unicode"\"On the way\" after the end of the deposit 0  -  -  The floats are cleared.");
        }

        // CRITICAL New income**He didn't wake up.**On arrival - the baseline reads the old values and the true number must be read (net float).
        stock.mint(address(harness), 1000e18);
        assertEq(
            harness.accountedQuote(), 8.4e18, unicode"The baseline's still intact. That's why it can't be open reading."
        );

        (uint256 held, bool exact) = harness.inTransit();
        assertEq(held, 900e18, unicode"CRITICAL The real balance is netting off. creator Floating");
        assertTrue(exact, unicode"The honest coin should be the exact value.");
        assertTrue(
            _hasSubstring(harness.description(), unicode"Income in transit 900000000000000000000 raw"),
            unicode"CRITICAL The state banners don't say \"no\" while the money's still on."
        );
    }

    /// @dev The issuer must burn the token from the vault and replace it with a non-readable; the old baseline is not the boundary in any direction at this time.
    ///      `inTransit()` Must return to the unknown sentry, and `description()` The blogger says that the government is not going to make it look like it's not getting any money in the way.
    function test_inTransit_reportsUnknownWhenIssuerBurnMakesTheBaselineStaleAndBalanceUnreadable() public {
        IssuerBurnableUnreadableStockToken issuerControlled = new IssuerBurnableUnreadableStockToken();
        CallVault issuerVault = _deployVault(meme, address(issuerControlled));

        issuerControlled.mint(address(issuerVault), 70e18);
        assertTrue(_ping(issuerVault));
        assertEq(issuerVault.accountedQuote(), 70e18, unicode"Pre-condition: balance recorded from old baseline");

        issuerControlled.adminBurn(address(issuerVault), 70e18);
        issuerControlled.setBalanceUnreadable(true);

        (uint256 held, bool exact) = issuerVault.inTransit();
        assertEq(held, 0, unicode"When I can't read it. amount It's an unknown sentry. We can't leak old baselines.");
        assertFalse(exact, unicode"Must be clearly marked as non-accuracy");
        assertEq(
            issuerVault.accountedQuote(),
            70e18,
            unicode"A contrario: the baseline may indeed be higher than the real balance"
        );
        string memory banner = issuerVault.description();
        assertTrue(
            _hasSubstring(banner, unicode"in-transit amount unreadable"),
            unicode"The status banner must report an unreadable in-transit amount"
        );
        assertFalse(_hasSubstring(banner, "nothing in transit"), unicode"The English banners can't be rendered zero.");
    }

    /// @notice CRITICAL **When income currencies refuse to authorize, they must be reported for their own reasons, not for our "failure of authorization".**
    ///
    /// @dev Real GME It's... `approve` It's compiled. `onlyNotPaused` + `onlyNotBlocked`
    ///      (`docs/research/robinhood-stock-token-permissions.md` 3),So the issuer is suspended.
    ///      Gold inventory on the path**First**That's the authorization that fell. `IsPaused()` In other words, we're talking about ourselves.
    ///      The result is that the issuer has been misinforming the "we have a code problem" - the traffic will be looking in the wrong direction all night.
    ///      That's exactly what I'm not using. `SafeERC20` The second reason for this is that it's the first one. custom error The front end is not unsolved.
    function test_processRevenue_bubblesUpTheQuoteTokensOwnRejection() public {
        GatedApprovalStockToken gated = new GatedApprovalStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(gated, expiry);

        gated.mint(address(harness), 8e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        gated.setApprovalsBlocked(true);

        vm.expectRevert(GatedApprovalStockToken.IssuerPaused.selector);
        harness.processRevenue();

        // Clean failure: money, baseline, authorization, none.
        assertEq(gated.balanceOf(address(harness)), 8e18, unicode"Money. wei A lot of it in the vault.");
        assertEq(
            harness.accountedQuote(),
            8e18,
            unicode"The baseline is still intact -- it's still \"identified, not spent\""
        );
        assertEq(gated.allowance(address(harness), address(pool)), 0, unicode"No residual authorization left.");

        // Just run again after you're released -- only delay, no loss.
        gated.setApprovalsBlocked(false);
        assertEq(
            harness.processRevenue(),
            6.4e18,
            unicode"After being discharged, retrying must be successful (90% of available stock)"
        );
    }

    /// @dev The other half: the other side.**No, I'm not. revert But I didn't agree.**(Back `false`).It's our turn to measure the string.
    ///      If we don't return the value, the failure will be delayed until the pool. `transferFrom`,The reason for reporting is not related to the real cause.
    function test_processRevenue_rejectsAnApprovalThatSilentlyReturnedFalse() public {
        SilentApprovalFailureStockToken silent = new SilentApprovalFailureStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(silent, expiry);

        silent.mint(address(harness), 8e18);

        vm.expectRevert(unicode"Quote token rejected the approval");
        harness.processRevenue();

        assertEq(silent.balanceOf(address(harness)), 8e18, unicode"Money. wei A lot of it in the vault.");
    }

    /// @notice CRITICAL **Back to dirty Boolean `approve` Don't blow the whole pen up like "Nothing" once. revert.**
    ///
    /// @dev `abi.decode(ret, (bool))` It's not like it's a hit. 0 Not really. 1 The words are not the same as the words used in the article.solc . Checker direct
    ///      `revert(0, 0)`  -  -  Empty returndata.That'll be ours. `require` In front, so you can't even get a hold of yourself.
    ///      The reason for the other is not even our word string: front-end press rule 004 The blogger says that the government is not going to be able to show anything when it shows up.
    ///      The luck of seeing naked once. revert,and out-of-gas I can't tell.
    ///      The vault is therefore pressed. `uint256` Deactivate, or not zero is real - with {ClearingPool} It's... `_readGating` Same trade.
    ///      So the authorization for the token should be**Success**,But it is not a failure that has no clue.
    function test_processRevenue_acceptsANonCanonicalTrueInsteadOfRevertingWithNoData() public {
        DirtyBoolApprovalStockToken dirty = new DirtyBoolApprovalStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(dirty, expiry);

        dirty.mint(address(harness), 6e18);
        assertEq(harness.processRevenue(), 4.8e18, unicode"Unnormish true Yeah. true(90% of the pool.");
        assertEq(call.balanceOf(address(distributor), seriesId), 4.8e18);
    }

    /// @notice CRITICAL **Counter-arguments for writing order: must first `pool.openSeries` It's working. Write again. `strike` / `seriesExpiry`.**
    ///         The half of the front.
    ///         `CallVaultOpenSeries.t.sol::test_openSeries_writesNothingWhenThePoolRejects`.
    ///
    /// @dev If you write the other way around, the field will point to a series that the principal vault does not own, and this function will be stable. `NotSeriesVault`
    ///       -  -  The income will never go out of the vault until someone upgrades it. This test puts out the consequences.
    ///      The "sequence is heavy" phrase has a red-reded source.
    function test_processRevenue_revertsWhenTheSeriesFieldsWereWrittenWithoutOpening() public {
        CallVaultHarness harness = _deployHarness(address(stock));

        uint64 expiry = uint64(block.timestamp + 7 days);
        harness.harnessWriteSeriesFieldsWithoutOpening(STRIKE, expiry);
        stock.mint(address(harness), 3e18);

        uint256 seriesId = pool.seriesIdOf(meme, address(stock), expiry);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, seriesId));
        harness.processRevenue();

        assertEq(stock.balanceOf(address(harness)), 3e18, unicode"Roll it all back. Money one. wei A lot.");
    }

    //  Writing face (two entries) CRITICAL)

    /// @dev High-level (no seventh entry) reading and compilation products ABI Acclaim; lower bounds guaranteed by compilers - one less,
    ///      Or be tightened. view,Same red.
    ///       M2-4(issue #36)- Put it on. `openSeries()` Added, five become six;
    ///      M2-6(3)(issue #58)- Put it on. `initialize` The last one, the one that was taken off, and the six went back to five -- the other one was not "a missing function."
    ///      Yes.**We can't upgrade the "Set up first" shot.**,Two identity parameters were moved to the construction function;
    ///      Decision-making 49 - Put it on. `claimCreatorFee()` Five of them are six -- the payee is tectonic.
    ///      `creator`,It is still not a power function (see table in the next article).
    function test_writeSurface_isExactlyTheDeclaredNineEntries() public view {
        string[] memory expected = new string[](9);
        expected[0] = "sync()";
        expected[1] = "sampleTwap()";
        expected[2] = "openSeries()";
        expected[3] = "processRevenue()";
        expected[4] = "receive()";
        expected[5] = "claimCreatorFee()";
        expected[6] = "emergencyWithdrawNative(address)";
        expected[7] = "emergencyWithdrawToken(address,address)";
        expected[8] = "claimProtocolFee()";

        WriteSurface.assertIsExactly(ARTIFACT, expected);
    }

    /// @notice CRITICAL **Zero-face: There is no key, so there is no key that can be taken, leaked, misused.**
    ///
    /// @dev This is a nature of decision-making. 39 The reason for this is... Flap Regulate mandatory (the function of authority must be granted simultaneously) Guardian
    ///      (and irrevocably)**The reason is our choice.**  -  -  It is the shortest proof that the vault can't take away the money.
    ///      The verdict is unchanged: ABI The whole address is full, and it's given to every entrance.
    ///      **Why not a power function?**Reason:
    ///
    ///      | The entrance. | Why not a power function? |
    ///      |---|---|
    ///      | `receive()` | The agreement is compatible with anyone. No decision. |
    ///      | `sync()` | Unlicensed, crediting entry recommended by the balance reconciliation model |
    ///      | `processRevenue()` | No permission, and the caller can't change the money's whereabouts. `immutable`) |
    ///      | `sampleTwap()` | CRITICAL No permission**It's a trade-off.**,Not Default - Full Paradigm `CallVault.sampleTwap` |
    ///      | `openSeries()` | CRITICAL I'm just saying. `CallVault.OPEN_WINDOW` Top: No one can pick a single parameter for the caller.
    ///        Only one thing that can be picked is**Time**,And that side was "just before the current series expired." 24 "Stretch it in the next issue within the hour." |
    ///      | `claimCreatorFee()` | Decision-making 49:The payee is a tectonic death. `creator`,calldata It's not gonna change...
    ///        The raid triggers right. creator No harm, plus. `msg.sender == creator` The door won't bring any security gains. |
    ///
    ///      `sampleTwap()` It's the first on this list.**There's an opponent.**The entrance, so it's worth repeating here.
    ///      Why not? Trigger Service I can't believe it.(1) The last time I saw the photo, I saw it.
    ///      `openSeries()` Yeah. TWAP Yes. fail-closed - When the ring expires, it stops all week long.(2) It'll be the capital bank.
    ///      The first key, which will henceforth require safekeeping, rotation, and the answer "what will we do" after it is lost.
    ///      The price (anyone can pick the time) is pressed by the minimum spacing and end weight and is**Observable**- I'm sorry.
    ///      See `sampleTwap` * The present document was not edited before being sent to the United Nations translation services. `test/CallVaultTwap.t.sol` The counter-test.
    function test_writeSurface_everyWritableEntryHasDeclaredPermissions() public view {
        string[] memory permissionless = new string[](9);
        permissionless[0] = "sync()";
        permissionless[1] = "sampleTwap()";
        permissionless[2] = "openSeries()";
        permissionless[3] = "processRevenue()";
        permissionless[4] = "receive()";
        permissionless[5] = "claimCreatorFee()";
        permissionless[6] = "emergencyWithdrawNative(address)";
        permissionless[7] = "emergencyWithdrawToken(address,address)";
        permissionless[8] = "claimProtocolFee()";

        string[] memory writable = WriteSurface.writableSignatures(ARTIFACT);
        for (uint256 i = 0; i < writable.length; i++) {
            bool known;
            for (uint256 j = 0; j < permissionless.length; j++) {
                if (keccak256(bytes(writable[i])) == keccak256(bytes(permissionless[j]))) known = true;
            }
            assertTrue(
                known,
                string.concat(
                    unicode"Add a new external writeable entry, and answer whether it is a power function -- zero is the minimum proof that the vault can't take money:",
                    writable[i]
                )
            );
        }
    }

    /// @dev The previous assertion is that there is no function on the list, and the one that says that there is no function on the list is that there is no function on the list.**There was really no character judgement when running.**:
    ///      An address is available and the performance of the six entry points is irrelevant to the caller.
    ///      WARNING `openSeries()` Just go here.**Failed**That side. 24 A sample will fill this one.
    ///      The entire time axis of the test is removed; it succeeds in any caller on that side by
    ///      `CallVaultOpenSeries.t.sol::testFuzz_anyCallerCanOpenTheWeeklySeries` Overwrite.
    function testFuzz_anyCallerCanDriveEveryWritableEntry(address caller) public {
        vm.assume(caller != address(0));

        stock.mint(address(vault), 1e18);
        vm.prank(caller);
        vault.sync();
        assertEq(vault.accountedQuote(), 1e18);

        vm.prank(caller);
        assertTrue(_ping(vault));

        portal.setCurve(meme, address(stock), 2e18);
        vm.prank(caller);
        assertTrue(vault.sampleTwap(), unicode"And the sampling is not allowed -- it's all written in the address.");

        // There's only one sample in the ring, so it's a series.**Who?**And that's the same thing that's been rejected -- and that's what this test is about.
        vm.prank(caller);
        vm.expectRevert(unicode"24h TWAP unavailable, call twap() for the reason");
        vault.openSeries();

        // This vault doesn't have a series, so... `processRevenue` The way is to delay the side...
        // But it's as good as any caller.
        vm.prank(caller);
        assertEq(vault.processRevenue(), 0);

        // Zero-cumulative `claimCreatorFee` It's quiet. no-op  -  -  It's the same for any caller.
        vm.prank(caller);
        assertEq(vault.claimCreatorFee(), 0, unicode"The sixth entrance is also unlicensed and returns clean at zero.");
    }

    /// @notice CRITICAL **The Treasury does not hold any claims that could be called upon.**
    ///
    /// @dev M2-1 The law of the hour is that "three entry points are closed for one transfer."M2-3 The only way to spend money is to add the only way.
    ///      Decision-making 49 And then you add the second -- so it's in the form of today, and it's still the same. ABI Element:
    ///
    ///      There's only six entrances. `processRevenue()` and `claimCreatorFee()` They move the goods, and they go where they go.
    ///      It's all in the vault. `immutable`(I'm a pool.distributor,creator),The amount is determined by the Treasury's own accounts.
    ///      The series is determined by the Treasury's own status - **calldata None of them has a byte energy impact on these three.**.
    ///      So no one, no matter how many times, can get the goods:
    ///      The cargo is either in the vault, in the pool, or in the firing of the one that's gonna die. creator In your hand,
    ///      And... creator The top of that one is worth a fortune. 10%.User claims still live in non-upgradable situations. `ClearingPool` Lee.
    ///      (`docs/design.md` 10-25 The structure of the project is based on the following structural premises:
    function test_writeSurface_hasNoUserClaimExit(address caller, uint96 amount) public {
        vm.assume(caller != address(0) && caller != address(vault) && caller != address(pool));
        // CRITICAL caller != creator It's this one.**Preconditions**Not to avoid: the proposition is "call this move."
        //    "I'm not gonna get the goods into the hands of the caller." creator He's the one who got the split.**Identity**,It's not what he called...
        //    Anyone who can do it for him. `claimCreatorFee`,The money will only go to him (the next section is divided into tests and this is a separate thing).
        vm.assume(caller != creator);

        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(stock, expiry);
        vm.assume(caller != address(harness) && caller != address(distributor));

        stock.mint(address(harness), amount);
        assertTrue(_ping(CallVault(payable(address(harness)))));

        portal.setCurve(meme, address(stock), 2e18);

        vm.startPrank(caller);
        harness.sync();
        harness.sampleTwap();
        (bool ok,) = address(harness).call{value: 0, gas: PING_GAS}("");
        assertTrue(ok);
        harness.processRevenue();
        harness.claimCreatorFee();
        vm.stopPrank();

        assertEq(
            stock.balanceOf(caller), 0, unicode"CRITICAL There's no portal that can deliver the goods to the caller."
        );
        assertEq(call.balanceOf(caller, seriesId), 0, unicode"CRITICAL Not even the license.");
        assertEq(
            stock.allowance(address(harness), caller), 0, unicode"The vault never authorizes anyone to take his goods."
        );
        uint256 creatorGot = stock.balanceOf(creator);
        assertEq(
            stock.balanceOf(address(harness)) + stock.balanceOf(address(pool)) + creatorGot,
            amount,
            unicode"CRITICAL It's either in the vault, in the pool, or in the pool. creator In your hand -- there's no fourth place."
        );
        assertLe(
            creatorGot,
            (uint256(amount) + 9) / 10,
            unicode"CRITICAL creator The top of that one is worth a fortune. 10%  -  -  It's impossible to eat collateral."
        );
    }

    //  creator Split claimCreatorFee(Decision-making 49,Second expenditure path)

    /// @notice Normal round: share with the entry, any person triggers the receipt, the money only arrives creator.
    /// @dev CRITICAL rule 010-3 The second application is also nailed here: the baseline is actually left after the receipt, and the remaining balance is still available.
    ///      And then the new income was recognized and deposited -- it was "forgot to cut the baseline."  "The vault is dead."
    ///      Counterfeiting on second expenditure path.
    function test_claimCreatorFee_paysTheCreatorAndKeepsTheVaultAlive() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.CreatorFeeClaimed(4e18);
        vm.prank(alice); // CRITICAL No, it's not. creator The person who triggers the money doesn't affect the movement.
        uint256 claimed = harness.claimCreatorFee();

        assertEq(claimed, 4e18, unicode"Measured by actual deductions");
        assertEq(stock.balanceOf(creator), 4e18, unicode"The money's all there is. creator");
        assertEq(stock.balanceOf(alice), 0, unicode"Trigger one. wei I can't get it.");
        assertEq(harness.creatorAccrued(), 0, unicode"Zero claims");
        assertEq(stock.balanceOf(address(harness)), 4e18, "Protocol reserve remains");
        assertEq(
            harness.accountedQuote(), 4e18, unicode"CRITICAL rule 010-3:Baseline follows expenditure to real balance"
        );

        // The vault is still alive: new income is recognized and deposited as usual.
        stock.mint(address(harness), 10e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        assertEq(harness.accountedQuote(), 14e18, unicode"New income recognition");
        assertEq(harness.processRevenue(), 8e18, unicode"I can save it.");
        assertEq(harness.creatorAccrued(), 1e18, unicode"Division continues to accumulate");
    }

    /// @notice Zero-cumulative silence no-op  -  -  and `sync()` Zero difference,`processRevenue()` The empty run is the same discipline.
    function test_claimCreatorFee_isASilentNoOpWhenNothingIsAccrued() public {
        vm.recordLogs();
        assertEq(vault.claimCreatorFee(), 0, unicode"No accumulation  Back 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"There should be no incident when you run.");
    }

    /// @notice CRITICAL **creator Issued Lai each: collect the whole volume and return it for the reasons of the issuer.**
    /// @dev That's exactly what we're talking about. pull Not push Reasons for the decision 49-5):Lai-ha-ha-ha-ha-ha-ha-ha-ha-ha. creator I can't get it.
    ///      Partition of the detention pool (no relocation, risk) creator Self-responsibility, decision-making 49-8),Do not even sit on any user path.
    ///      Rearjoinder after Undo -- Yes creator There were only delays and no book losses.
    function test_claimCreatorFee_revertsWithTheIssuersOwnReasonWhenTheCreatorIsBlocked() public {
        GatedStockToken gated = new GatedStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(gated, expiry);

        gated.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        gated.setFrozen(true);
        vm.expectRevert(GatedStockToken.IssuerFrozen.selector);
        harness.claimCreatorFee();

        // Clean failure: one claim, balance, baseline, one.
        assertEq(harness.creatorAccrued(), 4e18, unicode"Retention of claim as it is");
        assertEq(gated.balanceOf(address(harness)), 8e18, unicode"The money's in the vault.");
        assertEq(gated.balanceOf(creator), 0, unicode"creator No, I didn't.");

        gated.setFrozen(false);
        assertEq(harness.claimCreatorFee(), 4e18, unicode"You can retake it after you're released.");
        assertEq(gated.balanceOf(creator), 4e18);
    }

    /// @notice Transfer of a prima facie success without deduction**No consumption creator Claims**,Nor is there any false receipt incident.
    /// @dev and `processRevenue` It's... `sent` Same calibre: all payments are based on the actual deduction.
    function test_claimCreatorFee_fakeTransferDoesNotConsumeTheCreatorsClaim() public {
        NoOpStockToken noOp = new NoOpStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(noOp, expiry);

        noOp.mint(address(harness), 25e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 2.5e18, unicode"Pre-condition: splitting recorded");

        noOp.setNoOpTransfers(true);
        vm.recordLogs();
        assertEq(harness.claimCreatorFee(), 0, unicode"No deduction.  Amount of receipt is 0");
        assertEq(vm.getRecordedLogs().length, 0, unicode"Not even. CreatorFeeClaimed");
        assertEq(
            harness.creatorAccrued(),
            2.5e18,
            unicode"CRITICAL Claims resumed as they were, not eaten by false transfers"
        );

        noOp.setNoOpTransfers(false);
        assertEq(harness.claimCreatorFee(), 2.5e18, unicode"Recoverable after recovery");
        assertEq(noOp.balanceOf(creator), 2.5e18);
    }

    /// @notice When the amount of the account is higher than the real balance (issuer) `adminBurn`  I'm not gonna get away with it  `min` (a) To receive,
    ///         It won't last forever. revert There is insufficient balance; the remaining claims are retained and received when there is money.
    function test_claimCreatorFee_paysMinOfAccruedAndBalanceWhenTheIssuerBurnedTheFloat() public {
        IssuerBurnableUnreadableStockToken issuerControlled = new IssuerBurnableUnreadableStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(issuerControlled, expiry);

        issuerControlled.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        issuerControlled.adminBurn(address(harness), 3e18);
        assertEq(harness.claimCreatorFee(), 2.5e18, unicode"Only the part that really exists.");
        assertEq(issuerControlled.balanceOf(creator), 2.5e18);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 1.5e18);
        assertEq(harness.accountedQuote(), 2.5e18, unicode"The baseline remains real.");
    }

    /// @notice CRITICAL **Part of the deduction does not allow for double-dipping of the same income.**(Audit findings M-01 The counter-argument.
    ///
    /// @dev The split must be by**Deductions measured**Recording (in United States dollars)`sent / 9`,Full `cut` (Packing), not as requested.
    ///      If recorded by request: request 90 Just left. 45,Still remember 10  -  -  The rest. 55 Next time, Lee cut again.,
    ///      After trying again enough times creator It's a close-to-the-full payment. This test runs two rounds of partial deductions.
    ///      The true value is pegged roundly and the cumulative division is asserted to never exceed the original batch 10%.
    function test_processRevenue_partialDebitAccruesTheFeeByMeasuredDebitNotByRequest() public {
        PartialDebitStockToken halfToken = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness, uint256 seriesId) = _deployHarnessWithOpenSeries(halfToken, expiry);

        halfToken.mint(address(harness), 100e18);
        halfToken.setHalfDebit(true);

        // First round: available stocks 100,cut Upper limit 10,Request for deposit 90  -  -  Just go. 45.
        // 45 The corresponding batch is 50,It's a part of it. 5:Divisiond into accounts 5,No, it's not. 10.
        assertEq(harness.processRevenue(), 40e18, unicode"The pool is made of a real increment.");
        assertEq(
            harness.creatorAccrued(),
            5e18,
            unicode"CRITICAL Sub-total to accounts based on actual deductions (in millions of United States dollars)45/9),Not as requested"
        );
        assertEq(halfToken.balanceOf(address(harness)), 60e18);
        assertEq(harness.accountedQuote(), 60e18, unicode"Baseline to real surplus");

        // Second round: available stocks 55  5 = 50,Request 45  -  -  - Get out of here. 22.5,Re-entry 2.5.
        assertEq(harness.processRevenue(), 20e18);
        assertEq(harness.creatorAccrued(), 7.5e18, unicode"Round by round, only 10% of the actual part that's gone.");

        // CRITICAL Upper world: cumulative division regardless of the number of rounds to be retried <= Original batch 10%.
        halfToken.setHalfDebit(false);
        harness.processRevenue();
        assertLe(harness.creatorAccrued(), 10e18, unicode"CRITICAL The top of the line is nailed to the top. 10%");
        assertLe(
            harness.creatorAccrued() + halfToken.balanceOf(address(pool)),
            100e18,
            unicode"The sum of the collateral divided into the pool does not exceed the original batch"
        );
        assertEq(call.balanceOf(address(distributor), seriesId), halfToken.balanceOf(address(pool)));
    }

    /// @notice 10% The split is not legal. ERC-20 The maximum balance ahead of the pool. uint128 Border spills.
    function test_processRevenue_feeCalculationDoesNotOverflowAtMaxBalance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);
        uint256 balance = type(uint256).max;
        uint256 cut = balance / 10;
        uint256 available = balance - cut;
        uint256 deposit = available - available / 9;
        stock.mint(address(harness), balance);

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, deposit));
        harness.processRevenue();
    }

    /// @notice CRITICAL **Random sequenced topline unchanged**(Review N-03):Partial deductions of any proportion, arbitrary penetration,
    ///         Cumulative share (books) + I've been through this. <= of cumulative inflows of income 10%.
    ///
    /// @dev The test for the fixed sequence is the real value by round; the nail is the true value.**The proposition itself**  -  -
    ///      And the conclusion is, `9  confirmedCut <= sent` Round by round `9F <= S`,
    ///      Plus constant income when there is no increase in the amount of money. `S + F <= R`,Okay. `F <= R / 10`.
    ///      Amounts are deliberately dusted (+1 wei),Deduction rate covered 0(Fake transfers to 10000(Full.
    function testFuzz_creatorFee_totalNeverExceedsTenPercentOfInflow(uint256 seed) public {
        PartialDebitStockToken tok = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(tok, expiry);

        uint256 inflow;
        for (uint256 i = 0; i < 8; i++) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = (roll % 50e18) + 1; // 1 wei .. 50e18,Enemble 9/10 Dust.
            tok.mint(address(harness), amount);
            inflow += amount;
            tok.setDebitBps(uint16(roll % 10_001)); // 0 = Fake transfers... 10000 = Full
            harness.processRevenue();
            if (roll % 3 == 0) harness.claimCreatorFee(); // The receipt of the plug will remain unchanged. F(Only on the books./The lead is moved.
        }
        // End of story: Full deduction clears the stock and takes it again - the upper-level assertion that it covers the "all-processed" finality.
        tok.setDebitBps(10_000);
        harness.processRevenue();
        harness.claimCreatorFee();

        uint256 totalFee = harness.creatorAccrued() + tok.balanceOf(creator);
        assertLe(
            totalFee,
            inflow / 10,
            unicode"CRITICAL Cumulative share (books) + (Accounted) should not exceed cumulative inflows 10%"
        );
        assertLe(
            totalFee + tok.balanceOf(address(pool)) + tok.balanceOf(address(harness)) - harness.creatorAccrued(),
            inflow,
            unicode"Persistence: division + Into the pool. + Unprocessed balance <= Total inflows"
        );
    }

    /// @notice `claimCreatorFee` Part of deduction: only the actual claim is consumed, and the four readings are nailed together.
    function test_claimCreatorFee_partialDebitConsumesOnlyTheMeasuredDebit() public {
        PartialDebitStockToken halfToken = new PartialDebitStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(halfToken, expiry);

        halfToken.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        halfToken.setHalfDebit(true);
        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.CreatorFeeClaimed(2e18);
        assertEq(harness.claimCreatorFee(), 2e18, unicode"Return value = Deductions measured");
        assertEq(halfToken.balanceOf(creator), 2e18, unicode"creator Collections (no more doubles)");
        assertEq(harness.creatorAccrued(), 2e18, unicode"The debt only consumes the half of what actually went down.");
        assertEq(harness.accountedQuote(), halfToken.balanceOf(address(harness)), unicode"Baseline = Real balance");

        halfToken.setHalfDebit(false);
        assertEq(harness.claimCreatorFee(), 2e18, unicode"The rest of the claims are on the same footing.");
        assertEq(harness.creatorAccrued(), 0);
    }

    /// @notice The additional vendor handling costs are covered by the real balance baseline, but cannot be disguised as creator (c) Income or claims.
    function test_claimCreatorFee_senderFeeIsNotCountedAsCreatorIncome() public {
        SenderPaysFeeStockToken senderFeeToken = new SenderPaysFeeStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(senderFeeToken, expiry);

        senderFeeToken.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        senderFeeToken.mint(address(harness), 1e18);
        senderFeeToken.setSenderFeeBps(1000);
        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.CreatorFeeClaimed(4e18);
        assertEq(harness.claimCreatorFee(), 4e18, unicode"claimed Only for actual consumption creator Claims");

        assertEq(senderFeeToken.balanceOf(creator), 4e18, unicode"creator Received full nominal amount");
        assertEq(
            senderFeeToken.balanceOf(senderFeeToken.TAX_SINK()),
            0.4e18,
            unicode"The extra deduction is the issuer's fee."
        );
        assertEq(
            harness.creatorAccrued(),
            0,
            unicode"creator The claim is just as clean as it is, and the fees are not included."
        );
        assertEq(senderFeeToken.balanceOf(address(harness)), 4.6e18, unicode"Real decrease in the vault. 4.4");
        assertEq(
            harness.accountedQuote(), 4.6e18, unicode"Baseline reflects full balance changes including handling fees"
        );
    }

    /// @notice CRITICAL Existing creator The government is not going to be able to afford to use the Internet.`RevenueDeferred` And the one that's going to be**Net value**  -  -  The government has been able to take it as "carried money" under the chain.
    ///         It'll be overstated if you count the floats. 10% I'm not gonna be able to get a full-time, but I'm gonna get a full-time, big-time, fake card.
    function test_revenueDeferred_reportsTheNetDepositableNotTheRawBalance() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Precondition: Floating 4");

        vm.warp(uint256(expiry)); // Series due -> Next move is deferred.
        stock.mint(address(harness), 10e18);

        vm.expectEmit(false, false, false, true, address(harness));
        emit CallVault.RevenueDeferred(9e18, expiry);
        assertEq(harness.processRevenue(), 0, unicode"Deferred due");
        assertEq(
            stock.balanceOf(address(harness)),
            18e18,
            unicode"raw The balance is... 14  -  -  The incident didn't send it."
        );
    }

    /// @notice CRITICAL **The reverse interlocking is blocked.**:`processRevenue`  The pool pulls back in  `claimCreatorFee`.
    ///
    /// @dev Hazard shape and positive symmetry: Recall when withdrawal is not effective (balance unreduced) and will be carried with " full balance,
    ///      The claim is in the middle of the bank, which is then accounted for on the outside, as the balance is already debatable.
    function test_processRevenue_reentrantClaimCreatorFeeIsLockedOut() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        CallVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);

        // Flows are saved (unprotected) and then placed on the second round.
        hostile.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        hostile.armReentrancy(address(harness), abi.encodeCall(CallVault.claimCreatorFee, ()));
        hostile.mint(address(harness), 10e18);
        assertEq(harness.processRevenue(), 8e18, unicode"The outer layer is working as usual.");

        assertGt(hostile.reentryAttempts(), 0, unicode"Once more, it didn't trigger. This test was empty.");
        assertFalse(hostile.reentrySucceeded(), unicode"CRITICAL Inner layer claimCreatorFee It has to be locked in.");
        assertEq(
            hostile.reentryError(),
            abi.encodeWithSignature("Error(string)", unicode"Reentrant call"),
            unicode"The reason for the rejection is lock, not anything else."
        );
        assertEq(hostile.balanceOf(creator), 0, unicode"A single point of the float was not diverted by the middle.");
        assertEq(
            harness.creatorAccrued(),
            5e18,
            unicode"Two rounds of full accounting (in thousands of United States dollars)4 + 1)"
        );
    }

    /// @notice CRITICAL **Two expenditure paths are interoperable transient Lock it up.**  -  -  Decision-making 49-6 Counterarguments.
    ///
    /// @dev Dangerous shape:`claimCreatorFee` Redirected transfers (balance unreduced,`creatorAccrued` It's in.
    ///      Retry `processRevenue`,It'll take creator It's also in stock.
    ///      The injection is only recorded as non-frozen, and the outer layer is as successful as usual -- the assertion is that the**The inner layer is actually rejected.**And the accounts are ultimately correct.
    function test_claimCreatorFee_reentrantProcessRevenueIsLockedOut() public {
        PreUpdateReentrantStockToken hostile = new PreUpdateReentrantStockToken();
        uint64 expiry = uint64(block.timestamp + 7 days);
        CallVaultHarness harness = _deployHarness(address(hostile));
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, expiry);

        hostile.mint(address(harness), 40e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 4e18, unicode"Pre-condition: splitting recorded");

        hostile.armReentrancy(address(harness), abi.encodeCall(CallVault.processRevenue, ()));
        assertEq(harness.claimCreatorFee(), 4e18, unicode"The outside collections are successful.");

        assertGt(hostile.reentryAttempts(), 0, unicode"Once more, it didn't trigger. This test was empty.");
        assertFalse(hostile.reentrySucceeded(), unicode"CRITICAL Inner layer processRevenue It has to be locked in.");
        assertEq(
            hostile.reentryError(),
            abi.encodeWithSignature("Error(string)", unicode"Reentrant call"),
            unicode"The reason for the rejection is lock, not anything else."
        );
        assertEq(hostile.balanceOf(creator), 4e18, unicode"Money is not much, it's not much. creator");
        assertEq(harness.creatorAccrued(), 0, unicode"Zero claims");
    }

    //  description()

    /// @dev `description()` I was. Flap The dynamic description of the peremptory norm; the normative obligation is in the decision-making process 39 # Gone, gone, gone #
    ///      And...**The function and these claims are all left.**  -  -  It repletes with... {CallVault.inTransit},
    ///      That's the question: "How many collaterals are still in the vault at this point?" D0 It didn't get any less important.
    ///      WARNING It disappeared in the same period as it. `vaultUISchema()` Not left: That's... Flap UI The auto-rendering protocol,
    ///      We built our own front end, and there was no second consumer -- with its two assertions deleted.issue #58).
    ///
    ///      Request `description()` **With state**,And at least reflect whether the series is open and this week strike,
    ///      Last time you received the income. Series three. Never. / There's a "in the middle of it" attitude. = Six shapes, one by one, and they're different.
    ///      And the number that should appear really appears in the string. The third income pattern.**Zero on the way.**,M2-3 After saving)
    ///      It's a real-time reading of the window, worth one of itself.
    ///      Open the two fields of the series by `openSeries()` writing;using this document {CallVaultHarness} Just show that state.
    function test_description_reflectsSeriesStateAndRevenue() public {
        CallVaultHarness harness = _deployHarness(address(stock));

        uint128 strike = STRIKE;
        uint64 expiry = uint64(block.timestamp + 7 days);

        string[6] memory shapes;

        shapes[0] = harness.description();
        assertTrue(_hasSubstring(shapes[0], "no series open yet"), unicode"Unopened series");
        assertTrue(_hasSubstring(shapes[0], unicode"no revenue seen yet"), unicode"No revenue should be reported yet");

        stock.mint(address(harness), 42e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));
        shapes[1] = harness.description();
        assertTrue(
            _hasSubstring(shapes[1], "37800000000000000000"), unicode"Identified revenue should be in the string."
        );
        assertTrue(
            _hasSubstring(shapes[1], vm.toString(block.timestamp)),
            unicode"The moment of the process should be in the chain."
        );

        harness.harnessWriteSeriesFieldsWithoutOpening(strike, expiry);
        shapes[2] = harness.description();
        assertTrue(_hasSubstring(shapes[2], "1850000000000000000000"), unicode"strike It should be in the string.");
        assertTrue(
            _hasSubstring(shapes[2], vm.toString(uint256(expiry))), unicode"Due date should appear in the string"
        );
        assertTrue(_hasSubstring(shapes[2], unicode"series open"), unicode"The series should be reported as open");

        vm.warp(uint256(expiry) + 1);
        shapes[3] = harness.description();
        assertTrue(_hasSubstring(shapes[3], unicode"series expired"), unicode"The series should be reported as expired");

        // Two other shapes: open / Could not close temporary folder: %s
        CallVaultHarness fresh = _deployHarness(address(stock));
        fresh.harnessWriteSeriesFieldsWithoutOpening(strike, uint64(block.timestamp + 7 days));
        shapes[4] = fresh.description();
        vm.warp(block.timestamp + 8 days);
        shapes[5] = fresh.description();

        for (uint256 i = 0; i < shapes.length; i++) {
            assertGt(bytes(shapes[i]).length, 0);
            for (uint256 j = i + 1; j < shapes.length; j++) {
                assertTrue(
                    keccak256(bytes(shapes[i])) != keccak256(bytes(shapes[j])),
                    string.concat(
                        unicode"The two states are reproducing the same sentence:",
                        vm.toString(i),
                        " / ",
                        vm.toString(j)
                    )
                );
            }
        }
    }

    /// @notice CRITICAL `description()` Third income pattern:**Zero on the way.**  -  -  is the real time reading of the window in transit.
    ///
    /// @dev Front handles `description()` When the state of affairs is in a broad line of inquiry, the sentence answers the question of the auditer's greatest concern:
    ///      How many collaterals are in the vault at this point, and not in the pool?"
    ///      It must become "no" after deposit, not continue to be rendered as "identified revenue." 0The kind of thing that's both awkward and counterproductive.
    function test_description_reportsNothingInTransitOnceRevenueHasBeenDeposited() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, expiry);

        stock.mint(address(harness), 42e18);
        assertTrue(_ping(CallVault(payable(address(harness)))));

        string memory inTransit = harness.description();
        assertTrue(
            _hasSubstring(inTransit, unicode"Income in transit 37800000000000000000 raw"),
            unicode"Before deposit: In transit 42"
        );

        harness.processRevenue();

        string memory drained = harness.description();
        assertTrue(
            _hasSubstring(drained, "nothing in transit"), unicode"Deposited revenue should no longer be in transit"
        );
        assertTrue(keccak256(bytes(inTransit)) != keccak256(bytes(drained)), unicode"The two are in the same sentence.");
    }

    //  Native BNB Scaling (%)C2,7.14)

    event RevenueRecognized(uint256 newRevenue, uint256 accountedTotal);

    /// @notice CRITICAL **Original entry recognized as income**:TaxProcessor dispatch The vault is for the original. BNB,
    ///         The vault will be packed before it's written in. WBNB,The balance is recorded as usual. WBNB Incremental recognition as income.
    function test_native_wrapsIncomingBnbAndRecognisesItAsRevenue() public {
        (CallVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        // Native BNB Presented (in)TaxProcessor.dispatch Equivalent: a primary transfer triggered receive).
        vm.deal(address(this), 30e18);
        (bool sent,) = address(harness).call{value: 30e18}("");
        assertTrue(sent, unicode"receive Take the natives. BNB,No, no. revert");
        assertEq(
            address(harness).balance,
            30e18,
            unicode"Lazy wrapping:receive No, it's not. The original coin is lying down."
        );
        assertEq(wbnb.balanceOf(address(harness)), 0, unicode"Not yet. WBNB");

        assertEq(harness.accountedNative(), 30e18);
        // Wrapping changes asset form without recognizing the same revenue twice.
        vm.recordLogs();
        harness.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != keccak256("RevenueRecognized(uint256,uint256)"), "wrapping double-counted revenue"
            );
        }

        assertEq(address(harness).balance, 0, unicode"The original coin has been packed out.");
        assertEq(wbnb.balanceOf(address(harness)), 30e18, unicode"CRITICAL 30 BNB -> 30 WBNB(1:1)");
        assertEq(harness.accountedQuote(), 30e18, unicode"Baseline pushed to WBNB Income");
    }

    /// @notice CRITICAL **It's not original. wrap**:ERC20 The price-added vault was forced into the original. BNB,`_wrapsNative == false`,
    ///         `_wrapNative` Yes. no-op  -  -  No original currency is packaged, no income is included.
    ///         The government has also been able to provide income and multi-casting certificates to the Treasury.
    function test_native_nonNativeVaultDoesNotWrapForceSentNative() public {
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));

        vm.deal(address(harness), 30e18); // Zhang Cai (non-original)
        harness.sync();

        assertEq(address(harness).balance, 30e18, unicode"The original currency is intact, not packed.");
        assertEq(
            stock.balanceOf(address(harness)), 0, unicode"Valued currency (in US$)stock)The balance hasn't changed."
        );
        assertEq(
            harness.accountedQuote(), 0, unicode"CRITICAL The original coin of the jagged is not considered income."
        );
    }

    /// @notice CRITICAL **inTransit Unpackaged raw**:When the original coin arrives,sync The government is not going to let them go.
    ///         `inTransit` You're gonna count it in, or twice. sync The road between the front end was missing a piece.
    function test_native_inTransitCountsUnwrappedNativeThenWbnbAfterSync() public {
        (CallVaultHarness harness,,) = _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        vm.deal(address(this), 12e18);
        (bool sent,) = address(harness).call{value: 12e18}("");
        assertTrue(sent);

        // sync Before: Original currency unpackaged, but inTransit Must have counted it.
        (uint256 before, bool exactBefore) = harness.inTransit();
        assertTrue(exactBefore);
        assertEq(before, 10.8e18, unicode"CRITICAL Unpacked original currency is in transit.");

        harness.sync();

        // sync And then: the money became WBNB,inTransit The readings remain unchanged (same outline, same item).
        (uint256 afterSync, bool exactAfter) = harness.inTransit();
        assertTrue(exactAfter);
        assertEq(afterSync, 10.8e18, unicode"The package is the same number of readings in the distance.");
    }

    /// @notice **Original to End**:Originals paid. -> processRevenue Packaging -> Ninety percent. WBNB Into the pool, 10% of it. creator.
    function test_native_processRevenueWrapsThenDepositsToPool() public {
        (CallVaultHarness harness, WNativeMock wbnb, uint256 seriesId) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));

        vm.deal(address(this), 40e18);
        (bool sent,) = address(harness).call{value: 40e18}("");
        assertTrue(sent);

        vm.warp(block.timestamp + 1 hours);
        uint256 minted = harness.processRevenue();

        assertEq(address(harness).balance, 0, unicode"Packing light in raw currency");
        assertEq(
            minted, 32e18, unicode"90% of available stocks entering the pool (in United States dollars)40 -> 36 WBNB)"
        );
        assertEq(wbnb.balanceOf(address(pool)), 32e18, unicode"Mortgages (in United States dollars)WBNB)To the pool.");
        assertEq(
            call.balanceOf(address(distributor), seriesId), 32e18, unicode"The certificate is made for distributor"
        );
        assertEq(harness.creatorAccrued(), 4e18, unicode"I'll take 10% of it. creator(WBNB)");
        assertEq(wbnb.balanceOf(address(harness)), 8e18, unicode"There's only one in the vault. creator Floating");
    }

    function test_native_quoteDiscoverySeparatesCollateral() public {
        (CallVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        assertEq(harness.vaultQuoteToken(), address(0));
        assertEq(harness.collateralToken(), address(wbnb));
        assertEq(harness.vaultSpecVersion(), "v3");
    }

    function test_emergency_creatorLossIsPermanentAndFutureRevenueAccruesFresh() public {
        vm.chainId(56);
        (CallVaultHarness harness, uint256 id) = _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));
        stock.mint(address(harness), 100e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 10e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(stock), alice);
        assertEq(stock.balanceOf(alice), 20e18);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 10e18);
        assertEq(stock.balanceOf(address(pool)), 80e18);
        assertEq(call.balanceOf(address(distributor), id), 80e18);
        stock.mint(address(harness), 20e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 2e18);
        assertEq(harness.creatorImpaired(), 10e18);
    }

    function test_emergency_onlyGuardianAndNonzeroRecipient() public {
        vm.chainId(56);
        vm.expectRevert(bytes(unicode"Only Guardian"));
        vault.emergencyWithdrawNative(alice);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(bytes(unicode"Recipient is zero"));
        vault.emergencyWithdrawToken(address(stock), address(0));
    }

    function test_emergency_nativeWithdrawalPreservesWrappedCreatorReserve() public {
        vm.chainId(56);
        (CallVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.deal(address(harness), 3e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawNative(alice);
        uint256 supportedCreator = uint256(20e18) * 10e18 / 20.3e18;
        assertEq(harness.creatorAccrued(), supportedCreator);
        assertEq(harness.creatorImpaired(), 10e18 - supportedCreator);
        assertEq(wbnb.balanceOf(address(harness)), 20e18);
        assertEq(harness.accountedNative(), 0);
    }

    function test_emergency_nativeRecipientCallbackCannotReenterAndReturnedIncomeSurvives() public {
        vm.chainId(56);
        (CallVaultHarness harness,,) = _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        EmergencyNativeReceiver receiver = new EmergencyNativeReceiver(harness);
        vm.deal(address(harness), 10e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawNative(address(receiver));
        assertFalse(receiver.reentered());
        assertFalse(receiver.sampled());
        assertFalse(receiver.opened());
        assertEq(address(harness).balance, 5e18);
        assertEq(harness.accountedNative(), 5e18);
        (uint256 held, bool exact) = harness.inTransit();
        assertTrue(exact);
        assertEq(held, 4.5e18);
        harness.sync();
        assertEq(harness.accountedNative(), 0);
        assertEq(harness.accountedQuote(), 5e18);
    }

    function test_emergency_partialDebitRollsBackWithoutRecordingLoss() public {
        vm.chainId(56);
        PartialDebitStockToken partialToken = new PartialDebitStockToken();
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(partialToken, uint64(block.timestamp + 7 days));
        partialToken.mint(address(harness), 100e18);
        harness.processRevenue();
        partialToken.setHalfDebit(true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Incomplete quote withdrawal");
        harness.emergencyWithdrawToken(address(partialToken), alice);
        assertEq(partialToken.balanceOf(address(harness)), 20e18);
        assertEq(partialToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.creatorClaimed(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_emergency_unrelatedTokenDoesNotImpairCollateral() public {
        vm.chainId(56);
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(stock, uint64(block.timestamp + 7 days));
        stock.mint(address(harness), 100e18);
        harness.processRevenue();
        StockToken unrelated = new StockToken();
        unrelated.mint(address(harness), 7e18);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(unrelated), alice);
        assertEq(unrelated.balanceOf(alice), 7e18);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_schemaDescribesPermissionsAndRawUnits() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.methods.length, 35);
        uint256 writes;
        for (uint256 i; i < schema.methods.length; ++i) {
            if (schema.methods[i].isWriteMethod) ++writes;
            for (uint256 j; j < schema.methods[i].outputs.length; ++j) {
                assertEq(schema.methods[i].outputs[j].decimals, 0);
            }
        }
        assertEq(writes, 8);
        assertTrue(_hasSubstring(schema.methods[23].description, "Guardian only"));
        assertTrue(_hasSubstring(schema.methods[24].description, "Guardian only"));
        (uint8 decimals, bool readable) = vault.collateralDecimals();
        assertTrue(readable);
        assertEq(decimals, stock.decimals());
    }

    function test_emergency_unreadableQuoteRevertsWithoutLosingAssets() public {
        vm.chainId(56);
        IssuerBurnableUnreadableStockToken unreadable = new IssuerBurnableUnreadableStockToken();
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(unreadable, uint64(block.timestamp + 7 days));
        unreadable.mint(address(harness), 100e18);
        harness.processRevenue();
        unreadable.setBalanceUnreadable(true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Token balance unreadable");
        harness.emergencyWithdrawToken(address(unreadable), alice);
        unreadable.setBalanceUnreadable(false);
        assertEq(unreadable.balanceOf(address(harness)), 20e18);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
    }

    function test_emergency_quoteCallbackNewDepositRollsBackInsteadOfRepayingOldLoss() public {
        vm.chainId(56);
        EmergencyCallbackStockToken callbackToken = new EmergencyCallbackStockToken();
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(callbackToken, uint64(block.timestamp + 7 days));
        callbackToken.mint(address(harness), 100e18);
        harness.processRevenue();
        callbackToken.configure(address(harness), true);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Quote wake during withdrawal");
        harness.emergencyWithdrawToken(address(callbackToken), alice);
        assertEq(callbackToken.balanceOf(address(harness)), 20e18);
        assertEq(callbackToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
        assertEq(harness.accountedQuote(), 20e18);
    }

    function test_emergency_quoteCallbackWithoutPingRollsBackNewIncomeAndWithdrawal() public {
        vm.chainId(56);
        EmergencyCallbackStockToken callbackToken = new EmergencyCallbackStockToken();
        (CallVaultHarness harness,) = _deployHarnessWithOpenSeries(callbackToken, uint64(block.timestamp + 7 days));
        callbackToken.mint(address(harness), 100e18);
        harness.processRevenue();
        callbackToken.configure(address(harness), false);
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Incomplete quote withdrawal");
        harness.emergencyWithdrawToken(address(callbackToken), alice);
        assertEq(callbackToken.balanceOf(address(harness)), 20e18);
        assertEq(callbackToken.balanceOf(alice), 0);
        assertEq(harness.creatorAccrued(), 10e18);
        assertEq(harness.creatorImpaired(), 0);
    }

    function test_emergency_nativeReturnedDuringTokenWithdrawalDoesNotRepayOldImpairment() public {
        vm.chainId(56);
        EmergencyNativeCallbackWbnb wbnb = new EmergencyNativeCallbackWbnb();
        CallVaultHarness harness =
            new CallVaultHarness(pool, address(distributor), address(portal), meme, address(wbnb), creator, true);
        factory.bind(meme, address(harness));
        harness.harnessOpenSeries(STRIKE, uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        wbnb.configure(address(harness));
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        harness.emergencyWithdrawToken(address(wbnb), alice);
        assertEq(harness.creatorAccrued(), 0);
        assertEq(harness.creatorImpaired(), 10e18);
        assertEq(harness.accountedNative(), 1e18);
        assertEq(address(harness).balance, 1e18);
        harness.processRevenue();
        assertEq(harness.creatorAccrued(), 0.1e18);
        assertEq(harness.creatorImpaired(), 10e18);
    }

    function test_collateralDecimalsSixEightEighteenPreserveRawUnitEconomics() public {
        uint8[3] memory decimalsValues = [uint8(6), uint8(8), uint8(18)];
        for (uint256 i; i < decimalsValues.length; ++i) {
            DecimalStockToken token = new DecimalStockToken(decimalsValues[i]);
            address project = address(uint160(0x1000 + i));
            CallVaultHarness harness = new CallVaultHarness(
                pool, address(distributor), address(portal), project, address(token), creator, false
            );
            factory.bind(project, address(harness));
            harness.harnessOpenSeries(STRIKE, uint64(block.timestamp + 7 days));
            uint256 unit = 10 ** decimalsValues[i];
            token.mint(address(harness), 100 * unit);
            assertEq(harness.processRevenue(), 80 * unit);
            assertEq(harness.creatorAccrued(), 10 * unit);
            (uint8 decimals, bool readable) = harness.collateralDecimals();
            assertTrue(readable);
            assertEq(decimals, decimalsValues[i]);
        }
    }

    function test_emergency_nativeSelfRecipientRejectedWithoutChangingReserveOrIncome() public {
        vm.chainId(56);
        (CallVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.prank(address(harness));
        wbnb.withdraw(10e18);
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        vm.recordLogs();
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Invalid withdrawal recipient");
        harness.emergencyWithdrawNative(address(harness));
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.creatorImpaired(), 10e18 - uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.accountedNative(), 10e18);
        assertEq(address(harness).balance, 10e18);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_emergency_nativeCollateralRecipientRejectedWithoutConversionOrImpairment() public {
        vm.chainId(56);
        (CallVaultHarness harness, WNativeMock wbnb,) =
            _deployNativeHarnessWithOpenSeries(uint64(block.timestamp + 7 days));
        vm.deal(address(harness), 100e18);
        harness.processRevenue();
        vm.prank(address(harness));
        wbnb.withdraw(10e18);
        vm.recordLogs();
        vm.prank(0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b);
        vm.expectRevert(unicode"Invalid withdrawal recipient");
        harness.emergencyWithdrawNative(address(wbnb));
        assertEq(address(harness).balance, 10e18);
        assertEq(wbnb.balanceOf(address(harness)), 10e18);
        assertEq(harness.creatorAccrued(), uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.creatorImpaired(), 10e18 - uint256(20e18) * 10e18 / 21e18);
        assertEq(harness.accountedNative(), 10e18);
        assertEq(vm.getRecordedLogs().length, 0);
    }
}

contract EmergencyNativeReceiver {
    CallVault private immutable vault;
    bool public reentered;
    bool public sampled;
    bool public opened;

    constructor(CallVault vault_) {
        vault = vault_;
    }

    receive() external payable {
        (reentered,) = address(vault).call(abi.encodeCall(CallVault.processRevenue, ()));
        (sampled,) = address(vault).call(abi.encodeCall(CallVault.sampleTwap, ()));
        (opened,) = address(vault).call(abi.encodeCall(CallVault.openSeries, ()));
        (bool returned,) = address(vault).call{value: msg.value / 2}("");
        require(returned, "refund failed");
    }
}

contract EmergencyCallbackStockToken is StockToken {
    address private target;
    bool private wake;

    function configure(address target_, bool wake_) external {
        target = target_;
        wake = wake_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == target && target != address(0)) {
            super._update(address(0), target, 5e18);
            if (wake) {
                (bool ok,) = target.call("");
                require(ok, "ping failed");
            }
        }
    }
}

contract EmergencyNativeCallbackWbnb is WNativeMock {
    address private target;

    function configure(address target_) external {
        target = target_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == target && target != address(0)) {
            target = address(0);
            (bool ok,) = from.call{value: 1e18}("");
            require(ok, "native income failed");
        }
    }
}

contract DecimalStockToken is StockToken {
    uint8 private immutable precision;

    constructor(uint8 precision_) {
        precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }
}
