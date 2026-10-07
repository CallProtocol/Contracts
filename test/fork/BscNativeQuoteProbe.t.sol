// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {FlapNewTokenV6Params, IFlapPortalLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev and `RobinhoodSelfLaunch.t.sol` The smallest statement of the same composition -- both of which only declare the face they use.
struct ExactInputParams {
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 minOutputAmount;
    bytes permitData;
}

interface IFlapPortalSwap {
    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

interface ITaxProcessorProbeFace {
    function dispatch() external;
    function dispatchThreshold() external view returns (uint256);
    function marketAddress() external view returns (address);
    function marketQuoteBalance() external view returns (uint256);
    function quoteToken() external view returns (address);
    function dividendToken() external view returns (address);
}

interface IErc20ProbeFace {
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IDexPairProbeFace {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @dev `Portal.getQuoteTokenConfiguration` Naked. uint8 Declaration (same field) uint8,
///      Rationale and `ForkConfigBsc` Comment `nativeToQuoteSwapType = 7 Over vendored Enumeration` Same).
interface IQuoteConfigProbeFace {
    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function getQuoteTokenConfiguration(address quoteToken)
        external
        view
        returns (QuoteTokenConfiguration memory config);
}

/// @notice Recording "How much did I get when I paid my taxes?" gasThe payee of the probe.
///
/// @dev CRITICAL receive Lee.**Only one incident occurred.**(1.4k gas):If used upstream `transfer`/`send`(2300 (As a result of the accident)
///      This path also survives, notes the numbers; if you write it in, 2300 Next time. revert,
///      The test is "failure of delivery" rather than "what's the allowance" -- the probe itself cannot change what is being measured.
contract GasStipendProbe {
    event Rx(uint256 gasAtEntry, uint256 value);

    receive() external payable {
        emit Rx(gasleft(), msg.value);
    }
}

/// @title BscNativeQuoteProbeForkTest
/// @notice CRITICAL **Three solid probes in the original currency tab.**(Research documents 7.6 It's... 1/2/3/4/5 (c) The right to freedom of expression, including the right to freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of expression, freedom of religion, freedom of religion, freedom of religion, freedom of religion, freedom of expression, freedom of religion, freedom of religion, freedom of religion, freedom of religion, freedom of religion, freedom of religion, freedom of religion, freedom, freedom of religion, freedom, freedom of religion, freedom, religion, freedom, religion, religion, religion, freedom, freedom of religion, religion, freedom, freedom, freedom of religion, religion, religion, religion, religion, freedom, freedom, freedom, freedom, freedom of religion, freedom, freedom of religion, freedom, freedom, freedom, freedom, freedom, freedom, freedom, freedom, freedom, freedom, freedom, freedom,
///
/// These aren't regression tests.**Measurement**:Half of each article's value is asserted, half of it printed out.
/// All of them. `bscLatest()` Go on, ask "Today's." Portal "What behavior?" "The nail to the top will answer the question wrong."
///
/// | Probe. | Answered questions (research document number) |
/// |---|---|
/// | probe1 | 7.6-2 Original `dividendToken` What are the requirements;7.6-5 Original price schematic |
/// | probe2 | 7.6-1 Tax payments gas Allowance (%)`receive()` (a) Basis for original form;7.6-3 The legs of the graduation pool? WBNB |
/// | probe3 | 7.6-4 `enabled` Door abolished (arbitrary) ERC-20 (Accounted) |
contract BscNativeQuoteProbeForkTest is ForkTest {
    address internal constant PORTAL = ForkConfigBsc.FLAP_PORTAL;

    /// @dev canonical WBNB;Values and Research Documents 7.1 Unanimously.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @dev Cows come... 2026-09-14 Actual `getQuoteTokenConfiguration` It's... `enabled = 0`,
    ///      But it's a real, graduated tax token.QQQB The price is on the table.probe3 Use it as a pawn.
    ///      enabled=0 It's... ERC-20 The price-denominated money is a sample.
    address internal constant NIULAI = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;

    uint8 internal constant STATUS_TRADABLE = 1;
    uint8 internal constant STATUS_DEX = 4;

    uint256 private _nonce;

    //  probe0:Mining self-inspection (offline, unconnected)

    /// @notice Offline self-checking of the mine cycle: from seed=1 I must start. 1e6 I found one inside. 7777 End sign. salt,
    ///         And it's for independent use. `vm.computeCreate2Address` Recalculates the same address.
    ///
    /// @dev 2026-09-14 The first three probes were all down in "No way to dig." saltUp (statistically) 1e6 I'm hoping to hit you. ~15),
    ///      This one separates the word "mining the maths of the mine" from the word "disturbing the environment" -- it doesn't. selectFork.
    function test_probe0_offline_saltMiningSelfCheck() public view {
        bytes32 salt = _mineSalt(1);
        address predicted = vm.computeCreate2Address(salt, ForkConfigBsc.vanityInitCodeHash(), PORTAL);
        console2.log(unicode"[probe0] I'm digging it. salt =", uint256(salt));
        console2.log(unicode"[probe0] Forecast Address  =", predicted);
        require(
            uint160(predicted) & 0xffff == 0x7777,
            unicode"Recalculated address is not available 7777 End - Compilation and computeCreate2Address It's broken."
        );
    }

    //  probe1:dividendToken

    /// @notice 7.6-2:Original `newTokenV6` It's... `dividendToken` What do you want?
    ///
    /// @dev ERC-20 The hard part of the file is... `= quoteToken`(`CallLauncher.sol:341`,Leave a hole in the hole.
    ///      `DividendTokenMustEqualQuoteToken()`).It's from the original. `quoteToken = address(0)`,
    ///      Equal "means leaving zero -- but it's an inference that both values are sent over and the chain answers itself.
    function test_probe1_nativeQuote_dividendTokenRequirement() public {
        selectFork(ForkConfigBsc.bscLatest());

        _logQuoteConfig(unicode"address(0) , and then click the", address(0));
        // Feasibility reading of options (user) 2026-09-14):If the original is too costly, take it back. WBNB
        // When normal ERC-20 Valued - This configuration at the time (especially) nativeToQuoteSwapType)Decision
        // flap.sh Can you still get naked? BNB Buy.
        _logQuoteConfig(unicode"WBNB , and then click the", WBNB);

        // (1) dividendToken = address(0)(and quoteTokenThe original reading of the original version of the "Equivalent"
        (bool ok0, bytes memory err0, address token0) = _tryLaunch(address(0), address(0), vm.addr(0xd1));
        _logLaunchOutcome(unicode"(1) dividendToken = address(0)", ok0, err0, token0);

        // (2) dividendToken = WBNB(Original ERC-20 "Absortment," right?
        (bool ok1, bytes memory err1, address token1) = _tryLaunch(address(0), WBNB, vm.addr(0xd2));
        _logLaunchOutcome(unicode"(2) dividendToken = WBNB", ok1, err1, token1);

        require(
            ok0 || ok1,
            unicode"Two. dividendToken I can't even get the original living price... read the one on the page. revert Data"
        );

        // 7.6-5:Measure probe. Buy in. 1 BNB,It's from the camera. price with the amount received.
        address token = ok0 ? token0 : token1;
        address buyer = makeAddr("dimension-buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer, buyer);
        uint256 got = IFlapPortalSwap(PORTAL).swapExactInput{value: 1 ether}(
            ExactInputParams({
                inputToken: address(0), outputToken: token, inputAmount: 1 ether, minOutputAmount: 0, permitData: ""
            })
        );
        IFlapPortalLens.TokenStateV8Safe memory s = _state(token);
        console2.log(unicode"[schematic] 1 BNB I got it. raw MEME       =", got);
        console2.log(unicode"[schematic] Camera price(raw quote/1e18 MEME)=", s.price);
        console2.log(
            unicode"[schematic] price Invert 1 BNB You deserve it.      =", s.price == 0 ? 0 : uint256(1e36) / s.price
        );
        console2.log(unicode"[schematic] quoteTokenAddress          =", s.quoteTokenAddress);
        console2.log(unicode"[schematic] status                     =", uint256(s.status));
    }

    //  probe2:Delivery gas Allowances + The legs of the graduation pool.

    /// @notice 7.6-1 + 7.6-3:Original tax due to beneficiary How much is the call? gas?
    ///         After graduation DEX Is that Ji's leg? WBNB?
    ///
    /// @dev CRITICAL 7.6-1 Yes. `receive()` It's original.**All Based**:
    ///      2300 Allowances  Existing `_recognize`(SLOAD+SSTORE+event)All are beyond the limit and are ready to wrap;
    ///      Full Forward  Urgent packaging is feasible (research document) 7.8 - The hybrid form.
    ///      There's only one incident for the payee of the probe, and both are allowed to work under the allowance. `gasleft()` Write it out.
    function test_probe2_nativeQuote_taxDeliveryGasAndPoolLeg() public {
        selectFork(ForkConfigBsc.bscLatest());

        GasStipendProbe probe = new GasStipendProbe();
        (bool ok, bytes memory err, address token) = _tryLaunch(address(0), address(0), address(probe));
        if (!ok) {
            // probe1 We've answered. dividendToken Question; here it is, in exchange for a value-taking.
            (ok, err, token) = _tryLaunch(address(0), WBNB, address(probe));
        }
        require(ok, string.concat(unicode"The price of the needle has failed:", vm.toString(err)));
        console2.log(unicode"[probe2] The probe coin. =", token);

        //  Buy a curve through a raw currency (in original currency)7.6-6 (c) The cost of graduation is recorded in a series of schedules.
        address whale = makeAddr("native-whale");
        uint256 spent;
        for (uint256 i = 0; i < 200 && _state(token).status != STATUS_DEX; i++) {
            vm.deal(whale, 5 ether);
            vm.prank(whale, whale);
            IFlapPortalSwap(PORTAL).swapExactInput{value: 5 ether}(
                ExactInputParams({
                    inputToken: address(0), outputToken: token, inputAmount: 5 ether, minOutputAmount: 0, permitData: ""
                })
            );
            spent += 5 ether;
        }
        require(_state(token).status == STATUS_DEX, unicode"1000 BNB Still not graduated - take a big step and run.");
        console2.log(unicode"[probe2] Graduate expenses (%)wei,(Pretty)=", spent);

        //  7.6-3:The legs of the graduation pool.
        address pool = _state(token).pool;
        console2.log(unicode"[probe2] Graduate pool   =", pool);
        console2.log(unicode"[probe2] token0   =", IDexPairProbeFace(pool).token0());
        console2.log(unicode"[probe2] token1   =", IDexPairProbeFace(pool).token1());
        console2.log(unicode"[probe2] WBNB Contrast =", WBNB);

        //  TaxProcessor Side ID readings
        ITaxProcessorProbeFace tp = ITaxProcessorProbeFace(_taxProcessorOf(token));
        require(address(tp) != address(0), unicode"TOKEN_TAXED_V3 I think so. taxProcessor");
        console2.log(unicode"[probe2] taxProcessor        =", address(tp));
        console2.log(unicode"[probe2] tp.quoteToken       =", tp.quoteToken());
        console2.log(unicode"[probe2] tp.dividendToken    =", tp.dividendToken());
        console2.log(unicode"[probe2] tp.marketAddress    =", tp.marketAddress());
        console2.log(unicode"[probe2] tp.dispatchThreshold=", tp.dispatchThreshold());

        //  After graduation, trades are made in several rounds of taxes, and then they're visible. dispatch
        vm.recordLogs();
        for (uint256 round = 0; round < 4; round++) {
            address trader = makeAddr(string.concat("post-dex-", vm.toString(round)));
            vm.deal(trader, 3 ether);
            vm.startPrank(trader, trader);
            uint256 bought = IFlapPortalSwap(PORTAL).swapExactInput{value: 2 ether}(
                ExactInputParams({
                    inputToken: address(0), outputToken: token, inputAmount: 2 ether, minOutputAmount: 0, permitData: ""
                })
            );
            IErc20ProbeFace(token).approve(PORTAL, bought);
            IFlapPortalSwap(PORTAL)
                .swapExactInput(
                    ExactInputParams({
                    inputToken: token, outputToken: address(0), inputAmount: bought, minOutputAmount: 0, permitData: ""
                })
                );
            vm.stopPrank();
        }
        console2.log(unicode"[probe2] After the deal. marketQuoteBalance =", tp.marketQuoteBalance());
        if (tp.marketQuoteBalance() != 0) tp.dispatch();

        //  Every delivery under the probe.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rxTopic = keccak256("Rx(uint256,uint256)");
        uint256 deliveries;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(probe) || logs[i].topics[0] != rxTopic) continue;
            (uint256 gasAtEntry, uint256 value) = abi.decode(logs[i].data, (uint256, uint256));
            deliveries++;
            console2.log(unicode"[probe2] CRITICAL Delivery:receive The entrance. gasleft =", gasAtEntry);
            console2.log(unicode"[probe2]        msg.value              =", value);
        }
        console2.log(unicode"[probe2] Number of original deliveries        =", deliveries);
        console2.log(unicode"[probe2] The final original balance of the probe.    =", address(probe).balance);
        console2.log(
            unicode"[probe2] The probe ends up in the end. WBNB Balance  =",
            IErc20ProbeFace(WBNB).balanceOf(address(probe))
        );
        require(
            deliveries != 0 || address(probe).balance != 0 || IErc20ProbeFace(WBNB).balanceOf(address(probe)) != 0,
            unicode"No deliveries were observed -- no door limits? Read the one on the page. marketQuoteBalance"
        );
    }

    //  probe3:enabled Door is abolished?

    /// @notice 7.6-4:Take one. `enabled = 0` It's... ERC-20( When the price is straight  `newTokenV6`.
    ///
    /// @dev Background: Users in flap.sh The interface manual "Cows to Count" is already available, and the configuration we read on the latest block is now available.
    ///      Still. `enabled = 0`  -  -  Two observations, description `enabled` It may no longer be the door to the issue.
    ///      Here the chain itself is the answer, success and failure.
    function test_probe3_arbitraryQuote_enabledGate() public {
        selectFork(ForkConfigBsc.bscLatest());

        _logQuoteConfig(unicode"The oxen's valor configuration.", NIULAI);

        (bool ok, bytes memory err, address token) = _tryLaunch(NIULAI, NIULAI, vm.addr(0xd3));
        _logLaunchOutcome(unicode"Cowsenabled=0)Price", ok, err, token);

        if (ok) {
            IFlapPortalLens.TokenStateV8Safe memory s = _state(token);
            console2.log(unicode"[probe3] New currency quoteTokenAddress =", s.quoteTokenAddress);
            console2.log(unicode"[probe3] New currency status            =", uint256(s.status));
        }
    }

    //  Support

    /// @dev The outside is for the try/catch:- Put it on. Portal It's... revert  Turned into a**Printable Return Value**,
    ///      Instead of getting the whole test red -- the probe wants the answer, not the pass.
    function launchExternal(address quote, address dividend, address beneficiary) external returns (address token) {
        FlapNewTokenV6Params memory p;
        p.name = "Native Quote Probe";
        p.symbol = "NQPRB";
        // CRITICAL seed Remove 64 High-level Hash starting from no decimal:BSC Low on the main web salt Space has been launched.
        //    Spent (%2)2026-09-14 Actual:seed 1..1e6 Every one of them. 7777 We have code on the hit. Three probes.
        //    It's all in "No time to dig." saltGo, the real launch in the warehouse. salt  1.68e11 The blogger says:
        //    Robinhood Version FlapGmeLaunch Small seed Live because the chain is less fired -- copying it here will flip over.
        p.salt = _mineSalt(uint256(keccak256(abi.encodePacked("nq-salt", _nonce, block.number))) >> 192);
        p.quoteToken = quote;
        p.quoteAmt = 0;
        p.beneficiary = beneficiary;
        p.dexThresh = ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED;
        p.migratorType = ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2;
        p.dexId = ForkConfigBsc.FLAP_DEX_ID_SUPPORTED;
        p.lpFeeProfile = ForkConfigBsc.FLAP_LP_FEE_PROFILE_STANDARD;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000;
        p.mktBps = 10_000;
        p.dividendToken = dividend;
        p.tokenVersion = ForkConfigBsc.FLAP_TOKEN_VERSION_TAXED_V3;

        // CRITICAL Each time the sponsor:Portal Press tx.origin Limit frequency (%2)RateLimitExceeded).
        address who = vm.addr(uint256(keccak256(abi.encodePacked("nq-launcher", _nonce++))));
        vm.deal(who, 10 ether);
        vm.prank(who, who);
        token = IFlapPortalLaunch(PORTAL).newTokenV6(p);
    }

    function _tryLaunch(address quote, address dividend, address beneficiary)
        private
        returns (bool ok, bytes memory err, address token)
    {
        try this.launchExternal(quote, dividend, beneficiary) returns (address t) {
            return (true, "", t);
        } catch (bytes memory reason) {
            return (false, reason, address(0));
        }
    }

    function _logLaunchOutcome(string memory label, bool ok, bytes memory err, address token) private {
        if (ok) {
            console2.log(string.concat(unicode"[Fire!] ", label, unicode" -> Success"), token);
        } else {
            console2.log(string.concat(unicode"[Fire!] ", label, unicode" -> revert,Data:"));
            console2.logBytes(err);
        }
    }

    function _logQuoteConfig(string memory label, address quote) private {
        try IQuoteConfigProbeFace(PORTAL).getQuoteTokenConfiguration(quote) returns (
            IQuoteConfigProbeFace.QuoteTokenConfiguration memory c
        ) {
            console2.log(
                string.concat(
                    unicode"[Configure] ",
                    label,
                    " = (",
                    vm.toString(c.enabled),
                    ", ",
                    vm.toString(c.defaultCurve),
                    ", ",
                    vm.toString(c.alternativeCurve),
                    ", ",
                    vm.toString(c.nativeToQuoteSwapType),
                    ", ",
                    vm.toString(c.dexId),
                    ")"
                )
            );
        } catch {
            console2.log(string.concat(unicode"[Configure] ", label, unicode" Can not read (no reading)revert)"));
        }
    }

    /// @dev and `FlapGmeLaunch._mineVanitySaltFrom` The same paragraph is compiled, constant is replaced by BSC That one.
    ///      (`ForkConfigBsc.t.sol` Crucify: Take it. Robinhood The initial code is BSC Up the dig, one. salt Neither.
    function _mineSalt(uint256 seed) private view returns (bytes32 salt) {
        bytes32 initCodeHash = ForkConfigBsc.vanityInitCodeHash();
        address portalAddress = PORTAL;

        assembly {
            let p := mload(0x40)
            mstore8(p, 0xff)
            mstore(add(p, 0x01), shl(96, portalAddress))
            mstore(add(p, 0x35), initCodeHash)
            for { let i := seed } lt(i, add(seed, 1000000)) { i := add(i, 1) } {
                mstore(add(p, 0x15), i)
                let predicted := and(keccak256(p, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(predicted, 0xffff), 0x7777) {
                    if iszero(extcodesize(predicted)) {
                        salt := i
                        break
                    }
                }
            }
        }

        require(
            salt != 0,
            unicode"I can't dig anything. 7777 End sign. salt  -  -  The initial code or the deployment changed?"
        );
    }

    function _state(address token) private view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(PORTAL).getTokenV8Safe(token);
    }

    function _taxProcessorOf(address token) private view returns (address processor) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("taxProcessor()"));
        if (ok && ret.length == 32) processor = abi.decode(ret, (address));
    }
}
