// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

interface ICurrentFlapTaxTokenV3 {
    function buyTaxRate() external view returns (uint256);
    function sellTaxRate() external view returns (uint256);
}

interface ICurrentFlapPortal {
    struct TokenStateV9Safe {
        uint8 status;
        uint256 reserve;
        uint256 circulatingSupply;
        uint256 price;
        uint8 tokenVersion;
        uint256 r;
        uint256 h;
        uint256 k;
        uint256 dexSupplyThresh;
        address quoteTokenAddress;
        bool nativeToQuoteSwapEnabled;
        bytes32 extensionID;
        uint256 buyTaxRate;
        uint256 sellTaxRate;
        address pool;
        uint256 progress;
        uint8 lpFeeProfile;
        uint8 dexId;
        uint16 bondingCurveFeeRate;
    }

    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function getTokenV9Safe(address token) external view returns (TokenStateV9Safe memory);

    /// @dev Read all fields `uint8`  -  -  and `IFlapPortalLens` Let's go. `V8Safe` It's the same reason:
    ///      Flap Go on. `CurveType` Riga's variant, declared as an acoustic caller.**From that moment on, the code was decoded. revert**.
    ///      And this one... canary It's the moment when the meaning of existence is given.**Readable**Red, not a decoding error.
    ///      (`CurveType` It's long: the test net is only there. 27,The main network is here. >=34.)
    function getQuoteTokenConfiguration(address quoteToken) external view returns (QuoteTokenConfiguration memory);

    /// @dev CRITICAL **The second switch is for the cut.**,And the one up there is...**Two different storages.**:
    ///      `setQuoteTokenConfiguration(quote, {enabled: 0, ...})` The "this is no longer a value for money" is what I call "the money."
    ///      `setQuoteTokenCreationDisabled(quote, true)` "It's still a price-denominated currency, but no new coins will be issued."
    ///      Both of them are just a normal deal. `CallLauncher.launch` Stop.
    ///      And...**Just one of them will miss the other.**.
    ///
    ///      WARNING It's not here. `src/flap/IPortal.sol` - That's... Flap Example repository**Subset**.
    ///      This function initially takes the old autonomous network Portal Achieved `0x7Bc20c2C...fA06` Authenticated ABI(92 function;
    ///      #146 It's new. `0xa3b9...ff44` Read it out to confirm the need for selector The semantics of return are still in place.
    function quoteTokenCreationDisabled(address quoteToken) external view returns (bool);
}

/// @notice Independent of a fixed history. latest canary:The external upgrade must be followed by a visible re-acceptance here.
contract RobinhoodCurrentCanaryTest is ForkTest, FlapGmeLaunch {
    uint256 internal constant AMOUNT = 1 ether;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint8 internal constant FLAP_TAX_TOKEN_V3 = 6;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function setUp() public {
        selectFork(ForkConfig.robinhoodLatest());
    }

    function test_canaryRunsAgainstLatestState() public view {
        assertEq(forkHeight, 0, unicode"current canary No re-use fixed historical blocks");
    }

    /// @dev WARNING Read it below. beacon It's on the... `ROBINHOOD_ACCESS_REGISTRY`,Looks like the wrong object was read -- it didn't.
    ///      **He's got two jobs at the same address.**:`isBlocked` / `paused` and `implementation()` I'm not sure if I'm going to be able to live in the same contract.
    ///      It's both a system of permission registrations that is shared across the chain and a system of licensing. GME This one. BeaconProxy It's... beacon The body.
    ///
    ///      CRITICAL So let's get this thing started.**Prove it.**Read it over and over again, or else you'll be able to... Robinhood The blogger says that the government is not responsible for the war.
    ///      It's a strange contract, a strange address, and then it's, "Oh, my God.GME beacon "Scaled" to name red --
    ///      A warning pointing people in the wrong direction.
    function test_currentGmeImplementationKeepsExactTransferSemantics() public {
        assertEq(
            address(uint160(uint256(vm.load(ForkConfig.GME, ERC1967_BEACON_SLOT)))),
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"GME It's... ERC-1967 beacon The slot no longer points to the right registration form - two duties were removed, and the right to enter the registry was not allowed to be used.canary Which contract to read?"
        );

        address implementation = IBeacon(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).implementation();
        assertEq(
            implementation,
            ForkConfig.EXPECTED_GME_IMPLEMENTATION,
            unicode"GME beacon upgraded; must be re-checked and updated canary"
        );
        assertGt(implementation.code.length, 0, unicode"GME implementation No code.");

        IERC20Metadata gme = IERC20Metadata(ForkConfig.GME);
        assertEq(gme.decimals(), 18, "GME.decimals()");
        assertEq(gme.symbol(), "GME", "GME.symbol()");

        address holder = makeAddr("current GME holder");
        address recipient = makeAddr("current GME recipient");
        deal(ForkConfig.GME, holder, AMOUNT);

        uint256 holderBefore = gme.balanceOf(holder);
        uint256 recipientBefore = gme.balanceOf(recipient);
        vm.prank(holder);
        assertTrue(gme.transfer(recipient, AMOUNT), unicode"GME transfer Should return true");

        assertEq(
            holderBefore - gme.balanceOf(holder),
            AMOUNT,
            unicode"GME The sender must be able to deduct the nominal amount."
        );
        assertEq(
            gme.balanceOf(recipient) - recipientBefore,
            AMOUNT,
            unicode"GME The recipient must have received the nominal amount in due course."
        );
    }

    /// @dev You can't just stare at one old man. clone:Portal The path selected for the new currency is:
    ///      proxy -> Portal implementation It's... immutable launcher -> launcher It's... immutable TaxTokenV3 implementation.
    ///      Three. codehash And two. PUSH The command quotes the choice chain; any exchange will be made first canary Red.
    function test_currentPortalLaunchPathPinsTheSupportedTaxTokenImplementation() public view {
        address portalImplementation = _portalImplementation();
        assertEq(
            portalImplementation,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION,
            unicode"Flap Portal Upgraded; new currency to be re-checked to achieve selection chain"
        );
        assertEq(
            portalImplementation.codehash,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH,
            unicode"Flap Portal implementation runtime Changed; had to be rechecked launcher"
        );
        assertTrue(
            _runtimePushesAddress(portalImplementation, ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER),
            unicode"Current Portal implementation No longer solidified expectations launcher"
        );

        address launcher = ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER;
        assertEq(
            launcher.codehash,
            ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER_CODEHASH,
            unicode"Flap Portal launcher runtime Changed; new issuances must be re-checked"
        );
        assertTrue(
            _runtimePushesAddress(launcher, ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION),
            unicode"Current launcher No more solidization v1 Supported FlapTaxTokenV3 implementation"
        );
        assertEq(
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION.codehash,
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH,
            unicode"v1 Supported FlapTaxTokenV3 runtime Changed"
        );
    }

    /// @notice CRITICAL **GME Is it still a value for money?**  -  -  "The only thing that can keep an eye on."Flap The government has been making a statement that the ordinary deal is not going to make us pay the money."
    ///
    /// @dev **Why can't he stay? `RobinhoodTwapSource.t.sol` Lee.** There's one of them.
    ///      `test_gmeIsAnEnabledQuoteToken`,But that file ran away `ForkConfig.robinhood()`  -  -
    ///      **Crucify height.**.It says "block." 31,955,417 Go, go, go! GME It's enabled." One.**Historical facts**:
    ///      That's the right conclusion, but it's...**It's never structurally possible to find a future withdrawal.**.The blogger says that the government is not a party to the law.
    ///      The assertion is that you have to live in a running place. `robinhoodLatest()` In the document. The original one.**Reservations**:
    ///      It is anchored in the premise upon which the receiving and inspection is based, not the same thing.
    ///
    ///      **Why can't it be the one above? codehash Nail overwhelm.** Upgrade implementation To move byte code,
    ///      `EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH` It's gonna be red first; and...
    ///      `setQuoteTokenConfiguration(GME, {enabled: 0, ...})` Change only**Storage**,
    ///      The byte code is the same as the bits -- the nail knows nothing about it, and it's much cheaper.
    ///
    ///      **Two-step claims, deliberately separated.**:
    ///
    ///      | Trail | The judgement | Meaning |
    ///      |---|---|---|
    ///      | (1) | `enabled == 1` **and** `quoteTokenCreationDisabled(GME) == false` | CRITICAL **Zero distribution capacity**.The red is "no new coins will come out today."CRITICAL **Both switches are two different stores, and they have to be read.**  -  -  Just one of them will miss the other. |
    ///      | (2) | The remaining four == `ForkConfig` The nails. | WARNING Flap Changed. GME  the curves or the exchange routes   Don't stop **The economic parameters have changed.**,The constant will be updated after manual review |
    ///
    ///      Neither of them is.**Projects issued**:The configuration is only read at the moment when the coin is built.
    ///      The contents of the pool are gone. Flap In hand. `ForkConfig` In the five constant notes.
    ///
    ///      WARNING and `script/watch-market-wallet.sh` The same rule:**The only way to do this is to state the facts and consequences of the issue.
    ///      No conclusion to be made on motive.** We have no chain defence against this switch, and all we can do is see.
    ///
    ///       **Negative check-ups have been made.** Before you play on the main web fork. `DEFAULT_ADMIN_ROLE` The holder changed the configuration to
    ///      `(0,0,0,0,0)`,This article is red as scheduled  -  **And three in the same round. codehash None of the claims are red.**.
    ///      Those two. `[PASS]` This is proof that the claim must exist independently.
    ///      `docs/research/robinhood-launchpad-alternatives.md` 5.1.
    function test_gmeIsStillAnEnabledQuoteTokenToday() public view {
        ICurrentFlapPortal.QuoteTokenConfiguration memory config =
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).getQuoteTokenConfiguration(ForkConfig.GME);

        // (1) The scrambling -- both switches read, one reads, one is missing.
        assertEq(
            config.enabled,
            ForkConfig.EXPECTED_GME_QUOTE_ENABLED,
            unicode"CRITICAL GME No longer a enabled value  -  CallLauncher No new currency issued since then (no project issued affected)"
        );
        assertFalse(
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).quoteTokenCreationDisabled(ForkConfig.GME),
            unicode"CRITICAL GME The builder switch was turned off -- it's still a price, but no new coins are issued."
        );

        // (2) Changed: Uninterrupted, but economic parameters have changed and the constant must be manually reviewed before being updated.
        assertEq(
            config.defaultCurve,
            ForkConfig.EXPECTED_GME_QUOTE_DEFAULT_CURVE,
            unicode"Flap Changed. GME default curve; the curve parameters of the new currency change with the graduation line and must be reviewed spec 6.1"
        );
        assertEq(
            config.alternativeCurve,
            ForkConfig.EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE,
            unicode"Flap Changed. GME . The backup curve"
        );
        assertEq(
            config.nativeToQuoteSwapType,
            ForkConfig.EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            unicode"Flap Changed the original coin.->GME ; tax returns GME That part has to be re-checked."
        );
        assertEq(
            config.dexId, ForkConfig.EXPECTED_GME_QUOTE_DEX_ID, unicode"Flap Changed. GME - The file. DEX Subscript"
        );
    }

    function test_supportedFlapImplementationKeepsExactDeadTransferSemantics() public {
        address portalImplementation = _portalImplementation();
        assertEq(
            portalImplementation,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION,
            unicode"Flap Portal Upgraded; re-checking for post-release currency update canary"
        );
        assertGt(portalImplementation.code.length, 0, unicode"Flap Portal implementation No code.");

        // One at a time. GME It's priced. V3 Tax token: this is verified at the same time launcher The actual selection branch,
        // A long-term sample does not produce a warning that is not related to the chain of realization.
        address token = _launchGmeQuotedToken("Implementation Canary", "ICANARY");
        ICurrentFlapPortal.TokenStateV9Safe memory state =
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).getTokenV9Safe(token);
        assertTrue(state.status != 0, unicode"New hair. Flap token Not Portal Identification");
        assertEq(state.quoteTokenAddress, ForkConfig.GME, unicode"New hair. Flap token I must. GME Price");
        assertEq(state.tokenVersion, FLAP_TAX_TOKEN_V3, unicode"New hair. Flap token Not anymore. V3 Tax tokens");

        address tokenImplementation = _minimalProxyImplementation(token);
        assertEq(
            tokenImplementation,
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
            unicode"Supported FlapTaxTokenV3 Achieving change; destruction paths must be re-checked"
        );
        assertGt(tokenImplementation.code.length, 0, unicode"FlapTaxTokenV3 implementation No code.");

        ICurrentFlapTaxTokenV3 taxToken = ICurrentFlapTaxTokenV3(token);
        assertLe(taxToken.buyTaxRate(), 10_000, "buyTaxRate()");
        assertLe(taxToken.sellTaxRate(), 10_000, "sellTaxRate()");

        IERC20 meme = IERC20(token);
        uint256 portalBefore = meme.balanceOf(ForkConfig.FLAP_PORTAL);
        uint256 deadBefore = meme.balanceOf(BURN_ADDRESS);
        assertGe(
            portalBefore,
            AMOUNT * 2,
            unicode"New hair. Flap token It's... Portal There are less than two transfers in stock"
        );

        vm.prank(ForkConfig.FLAP_PORTAL);
        assertTrue(meme.transfer(BURN_ADDRESS, AMOUNT), unicode"MEME transfer Should return true");
        assertEq(
            portalBefore - meme.balanceOf(ForkConfig.FLAP_PORTAL),
            AMOUNT,
            unicode"transfer The sender must be properly docked."
        );
        assertEq(
            meme.balanceOf(BURN_ADDRESS) - deadBefore,
            AMOUNT,
            unicode"transfer It's... 0xdead You have to get the nominal right."
        );

        portalBefore = meme.balanceOf(ForkConfig.FLAP_PORTAL);
        deadBefore = meme.balanceOf(BURN_ADDRESS);

        vm.prank(ForkConfig.FLAP_PORTAL);
        assertTrue(meme.approve(address(this), AMOUNT), unicode"MEME approve Should return true");
        assertTrue(
            meme.transferFrom(ForkConfig.FLAP_PORTAL, BURN_ADDRESS, AMOUNT),
            unicode"MEME transferFrom Should return true"
        );

        assertEq(
            portalBefore - meme.balanceOf(ForkConfig.FLAP_PORTAL),
            AMOUNT,
            unicode"transferFrom The sender must be properly docked."
        );
        assertEq(
            meme.balanceOf(BURN_ADDRESS) - deadBefore,
            AMOUNT,
            unicode"transferFrom It's... 0xdead You have to get the nominal right."
        );
    }

    function _minimalProxyImplementation(address token) private view returns (address implementation) {
        bytes memory runtimeCode = token.code;
        assertEq(runtimeCode.length, 45, unicode"Current Flap The sample is no longer. EIP-1167 minimal proxy");
        assembly ("memory-safe") {
            implementation := shr(96, mload(add(runtimeCode, 0x2a)))
        }
    }

    function _portalImplementation() private view returns (address) {
        return address(uint160(uint256(vm.load(ForkConfig.FLAP_PORTAL, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _runtimePushesAddress(address account, address expected) private view returns (bool) {
        bytes memory runtimeCode = account.code;
        uint256 i;
        while (i < runtimeCode.length) {
            uint8 opcode = uint8(runtimeCode[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                uint256 width = opcode - 0x5f;
                if (i + width >= runtimeCode.length) return false;

                bytes32 operand;
                assembly ("memory-safe") {
                    operand := mload(add(add(runtimeCode, 0x21), i))
                }
                if (width == 20 && address(uint160(uint256(operand) >> 96)) == expected) return true;
                if (width == 32 && operand == bytes32(uint256(uint160(expected)))) return true;

                i += width + 1;
            } else {
                i++;
            }
        }
        return false;
    }
}
