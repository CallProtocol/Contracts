// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";

/// @notice bStocks It's...**Pause Manager**The ones we used in the face.
///
/// @dev This is... Robinhood `Stock.paused()` Yes. BSC Counteractors on the -- but**Not on a token, in a common.
///      On the manager.**:`stock.pauseManager().isTokenPaused(stock)`.26 Only bStock Share the same.
///      Interface from runtime It's... `PUSH4` Pie release + openchain Check back, move up one by one.32 A candidate to solve 21 - Yeah.
interface IBStockPauseManager {
    function isTokenPaused(address token) external view returns (bool);
    function pausedTokens(address token) external view returns (bool);
    function allTokensPaused() external view returns (bool);
    function pauseToken(address token) external;
    function unpauseToken(address token) external;
    function pauseAllTokens() external;
}

/// @notice bStocks It's...**Compliance module**The ones we used in the face.
///
/// @dev This is... Robinhood `registry.isBlocked(pool)` Yes. BSC The counterpoint on it, but the key is a little bit more:
///      The blacklist is...**By Dial**It's... `blockedAddresses(token, who)`,There's another one.**Global**Sanctions List
///      `sanctionedAddresses(who)`.26 Only bStock Share the same module.
///
///      CRITICAL **`checkIsCompliant` Can't be used as a door hook.** It's... revert "Standed."
///      (`UserBlocked()` / `UserSanctioned()`),And... `ClearingPool._readGating` I want one.
///      **No, no. revert Number of readings**.And its real signature is... `(address token, address user)`,and
///      `msg.sender` It's not-- at first press. `(from, to)` The assumptions are wrong, and they're tested in one group.
///      Source:`docs/research/bsc-flap-portal-probe.md` 6.4.
interface IBStockCompliance {
    function blockedAddresses(address token, address who) external view returns (bool);
    function sanctionedAddresses(address who) external view returns (bool);
    function checkIsCompliant(address token, address user) external view;
    function addToBlocklist(address token, address[] calldata users) external;
    function addToSanctionsList(address[] calldata users) external;
}

/// @title ForkConfigBsc
/// @notice **BSC Only configuration source for fork test**,and {ForkConfig}(Robinhood)Parallel.
///
/// # Why a separate document, not a gift? {ForkConfig} Add a constant of suffix.
///
/// Decision-making 53 The two-chain door-control source branch management, which follows the same principle, is defined as the "separation of the source code" ("the two chains' door-control branch management").
///
/// - **Three. shell Consumer by constant name grep This file.**(`fork-node.sh` 19 Location,`preflight-mainnet.sh`
///   3 The two constants with different names on the backs. grep The government has been able to provide the necessary information to the public.
///   The "target chain" is a non-destructive sentence.
/// - Robinhood There's a lot of empirical findings in that note, "On this chain..."**Different.**
///   (See each of the following contrasts, the reading in a document must always be kept to the point of identifying which chain is said to be.
///
/// # Data source
///
/// Every constant down there comes from... 2026-09-08 It's... BSC The main web site is now in the
/// `docs/research/bsc-flap-portal-probe.md`(Revert command attached.**None of them are copied from the document.**
///
/// # CRITICAL and Robinhood Largest one difference: no free end points available
///
/// BSC The public end status window is only measured **About 120 Blocks (in thousands of dollars)55 sec)**(geth Default `TriesInMemory=128` the shape of the
/// - Yeah. Robinhood Official peer 6k-20k The block is one order of magnitude. So:
///
/// - **The pinhead must match. `RPC_BSC`(Private Archive Endpoint)**,There is no community backsliding;
/// - The public end that's built in**Only `bscLatest()` Meaningful.**,It cannot serve any historical height.
///
/// Source:9 / 9.6.2.
library ForkConfigBsc {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant BSC_CHAIN_ID = 56;

    //  Mortgages:bStocks

    /// @dev GMEB  GameStop(bStock,BeaconProxy).**Initialised**(Decision-making 54).
    ///
    ///      CRITICAL Pick it instead of Ondo It's... `GMEon`,The reason is two factual findings:Ondo Four.**Not at all.** ERC-8056
    ///      UI multiplier(This project is "By dividends." Multiplier ) and that is not available in the core mechanism of the #Renewed)
    ///      `burn(address,uint256)` It burns.**Arbitrary holder**(a) the balance of the total amount of the amount of the funds;bStocks Only self-burning - yes. GMEB I tried it one by one.
    ///      Five "Burning People" portals, all failed.6.5.
    ///
    ///       It's price-based configuration. `(1, 29, 29, 7, 0)` and Robinhood Main GME **Same in place.**  -  -
    ///      Same curve, same curve swapType.The relocation was therefore not subject to a change of standard.
    address internal constant GMEB = 0x46cEeFDa28Dd7207059ed19B0acdc026955bb15C;

    /// @dev bStock and the beacon.**26 Only bStock We share the same. beacon**  -  -
    ///      CRITICAL A single transaction by the issuer that replaces the full realization is a collateral risk disclosure (see table 2).R2)The highest one in the world.
    ///      Yeah. BSC Version version 0 Basis for the replacement of the sentence in the legal text (decision-making) 56).
    address internal constant EXPECTED_GMEB_IMPLEMENTATION = 0xCFEd6c4679297ea4889F8183bC057B4A86C64e46;
    bytes32 internal constant EXPECTED_GMEB_IMPLEMENTATION_CODEHASH =
        0x060dc28d4dd8d9bb8a381d4009bccbac129ce743a10b3d8aa0ffef5034b50544;
    address internal constant BSTOCK_BEACON = 0x156D6dce9a4f6139a3406F1f021F1A4880De93a3;
    bytes32 internal constant BSTOCK_BEACON_CODEHASH =
        0x80fbad22136c0abdce6e0f3cc46cd0572318e01b92dbd5b4d5795ef6e8808711;

    /// @dev Two portals controlled by the issuer (in the case of the26 Only bStock Common. {IBStockPauseManager} /
    ///      {IBStockCompliance} and 6.3 / 6.4.
    ///
    ///      CRITICAL **Robinhood None of those three agents exist here.**:`paused()` and
    ///      `ACCESS_CONTROLLED_REGISTRY()` Yes. bStock Topple. revert.Map relation:
    ///
    ///      | Robinhood | bStocks |
    ///      |---|---|
    ///      | `stock.paused()` | `stock.pauseManager().isTokenPaused(stock)` |
    ///      | `stock.ACCESS_CONTROLLED_REGISTRY()` | `stock.compliance()` |
    ///      | `registry.isBlocked(pool)` | `compliance.blockedAddresses(stock, who)` + `sanctionedAddresses(who)` |
    address internal constant BSTOCK_COMPLIANCE = 0x53dBa7AaBDe774787A1F57236B235567dA8e14F4;
    bytes32 internal constant BSTOCK_COMPLIANCE_CODEHASH =
        0xe53b7759da23b16be41e4faa36b85c70ec750a2a631492998f40833fab17aff8;
    address internal constant BSTOCK_PAUSE_MANAGER = 0x9fc74Be63f3589485B2423984a7a0557e0CF700a;
    bytes32 internal constant BSTOCK_PAUSE_MANAGER_CODEHASH =
        0x65c448e9ecdde44701b7a20c846fec9000d9aee6e3ddeb9362bb1980d755ff4d;

    //  Flap Portal

    /// @dev Flap Main entrance (%)ERC-1967 proxy).**Agent deployed to block 39,980,228(2024-06-27)**  -  -
    ///      subgraph It's... BSC `startBlock` That's it.
    ///
    ///      CRITICAL **What's down there? codehash Yes. BSC It's "Smartshot of a moment," no. canary The verdict.**
    ///      Portal It's been upgraded throughout history. **108 Number of times**,2026 Year 44 Once, most recently before verification.**Two days.**.
    ///      Robinhood The "cruise to the nail." codehash When? canaryIt keeps getting red on this chain -- by decision. 55,
    ///      BSC Version canary The nails are...**Behaviour**:Camera 18 Words and four fields down, arrays, drop-off after graduation V2 Pool.
    ///      Source:2.1.
    address internal constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    uint256 internal constant FLAP_PORTAL_DEPLOY_BLOCK = 39_980_228;

    /// @dev Accomplishments and modules when snapshots.**Portal It's not public. `launcher()` getter**  -  -  Here. launcher
    ///      It was taken from a real coin call tree. `delegatecall`).See 9.6.1.
    address internal constant SNAPSHOT_FLAP_PORTAL_IMPLEMENTATION = 0x16148E9F39fdD93dFeE5ff3B8cDb32C8D5643B34;
    bytes32 internal constant SNAPSHOT_FLAP_PORTAL_IMPLEMENTATION_CODEHASH =
        0x92f2e0f6f55679bf4616f6661008998c7e9a4f9f2b92a1b9ec40e07b4926a6f2;
    address internal constant SNAPSHOT_FLAP_PORTAL_LAUNCHER = 0x87354597ff986916dA83cC4895363f9bA4478f88;
    bytes32 internal constant SNAPSHOT_FLAP_PORTAL_LAUNCHER_CODEHASH =
        0xf12aeefb5407136e99a73f597c909a289885218a18f0d3d7dc4ffa07a45cd046;

    /// @dev `FlapTaxTokenV3` Achieved.**This one's steady.**  -  -  Every token is directed to it. EIP-1167 The smallest agent,
    ///      And the agent's initial code Hashili has its address, the pretty one. salt The mine is directly dependent on it. {vanityInitCodeHash}).
    address internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION = 0x024f18294970B5c76c0691b87f138A0317156422;
    bytes32 internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH =
        0xb530a7e0ff0d6ab435a5ec71f2b04092937735e23a0fb3a0746724ce9b875b4a;

    //  Build a currency matrix

    /// @notice CRITICAL **BSC The only money that can walk through. enum Group, sweep it out.**(4.5).
    ///
    /// @dev and Robinhood That watch.**Same conclusion, different codes.**  -  -  Anything that puts the wrong code in the statement. BSC Version Test
    ///      You have to write this line. You can't copy it. Robinhood That one:
    ///
    ///      | Constant | Take another value (inBSC (Inventory) | Robinhood Records |
    ///      |---|---|---|
    ///      | `tokenVersion = 6` | 0/1/3/4/5/7 -> `FeatureDisabled()`(`0xac5f6092`);**2 -> `Error("Non-tax: rates must be 0")`,That's the version in BSC It's enabled.** | 0...5,7 All of them. `FeatureDisabled()` |
    ///      | `migratorType = 1` | 0/2/**3** -> **`InvalidMigratorType()`**(`0x4fd0ffbb`) | As `FeatureDisabled()` |
    ///      | `dexThresh = 1` | 0/2/3/4/5 -> `InvalidDexThresholdType(uint8)`(`0x77146b42`) |  Same in place. |
    ///      | `dexId = 0` | 1/2 -> `0xead3ad50`(**openchain / 4byte The blogger says:vendored I'm not saying anything.**;Throw a point in launcher The first few checks of the module, see 9.6.3) | Unrecorded error code |
    ///      | `lpFeeProfile = 0` | 0/1/2 **I can do it.**;3/4 Empty revert.V2 It doesn't work if we move it. |  -  |
    ///
    ///      CRITICAL **`3`(`PCS_INFINITY_CL_MIGRATOR`)Rejected**,That's the blockage. 2 The key to overcoming: research reports are worried
    ///      BSC They'll move the tax money to the bank. Pancake Infinity CL "I'm the pool." And we...**It's not going to get through.**The migrationer.
    uint8 internal constant FLAP_TOKEN_VERSION_TAXED_V3 = 6;
    uint8 internal constant FLAP_MIGRATOR_TYPE_V2 = 1;
    uint8 internal constant FLAP_DEX_THRESH_SUPPORTED = 1;
    uint8 internal constant FLAP_DEX_ID_SUPPORTED = 0;
    uint8 internal constant FLAP_LP_FEE_PROFILE_STANDARD = 0;

    /// @notice CRITICAL **BSC Portal Force token address `7777` End**  -  -  The study did not foresee this.
    ///
    /// @dev Unsatisfactory report `VanityAddressRequirementNotMet(address)`(`0xca4c5b2d`).The token goes.
    ///      EIP-1167 Mint Agent + CREATE2,**The man who deployed it was... Portal For yourself.**,salt It's original. `uint256`,
    ///      So the initial code is predictable.`CallLauncher` It's... salt The blogger says that the government is not a party to the law.
    ///      But...**The constant of mining under the chain must be replaced by BSC This one.**.
    function vanityInitCodeHash() internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }

    //  Value

    /// @notice {GMEB} & Value & Configuration - with Robinhood Go, go, go! GME Five-dollar group**Same in place.**.
    ///
    /// @dev 2026-09-08 Actual `Portal.getQuoteTokenConfiguration(GMEB)` = `(1, 29, 29, 7, 0)`,
    ///      Configure first time in blocks 115,351,586(2026-08-11).
    ///
    ///      WARNING and Robinhood That one.**Same risk**:This is not our state, is it? Flap Five bytes in the administrator ' s storage;
    ///      The withdrawal would not affect the repayment and the ability to issue would be zero.
    ///
    ///      WARNING **`nativeToQuoteSwapType = 7` Over vendored `NativeToQuoteSwapType` Quantified limit (%2)6)**.
    ///      Take it. vendored  THE STRUCTURE GO  ABI Decode this configuration.**On the spot. revert**  -  -  So it's naked. `uint8`,
    ///      and Robinhood That's the same way.
    ///
    ///      i BSC It's been used throughout history. **39 Only**Valued currency (in US$)26 bStock + 4 Ondo + 9 Normal ERC-20),See you on the full list.
    ///      5.2.**The list is still growing.**(The most recent configuration occurred on the day of the validation) and therefore the list of assets under the chain is read from the chain.
    uint8 internal constant EXPECTED_GMEB_QUOTE_ENABLED = 1;
    /// @dev and Robinhood GME The same as 29  -  -  Same curve.
    uint8 internal constant EXPECTED_GMEB_QUOTE_DEFAULT_CURVE = 29;
    uint8 internal constant EXPECTED_GMEB_QUOTE_ALTERNATIVE_CURVE = 29;
    uint8 internal constant EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE = 7;
    uint8 internal constant EXPECTED_GMEB_QUOTE_DEX_ID = 0;

    //  Samples and DEX

    /// @notice -Punch the height.**Graduated**Sample MEME:MarsCoin,Tax rate 300/300,SPCXB Price.
    ///
    /// @dev CRITICAL **and Robinhood That part is different.**:`ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE` It's one.
    ///      **Still on the curve**(all supplied in Portal In hand, so the holder's balance is from Portal `prank` Turn out.
    ///      This one.**Graduated**,Supply in V2 The pool.
    ///
    ///      It's here to take another step:**The pool after graduation is true. V2 "The Historical Evidence of Shapes"**  -  -
    ///      `token0/token1/getReserves` Qui Quan,`slot0/liquidity/fee/tickSpacing` All revert.
    ///
    ///      WARNING **BSC There is no "curve phase" sample on it.** If you need a coin in the curve phase, you can see the price of the fork.
    ///      The current practice is to send one on site (`newTokenV6` It's a good way to get through the cross. See you. 4.5),
    ///      Not a nail to history.
    address internal constant PINNED_GRADUATED_TAX_TOKEN_V3_SAMPLE = 0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777;

    /// @dev The pool that was up there after graduation, and the factory that produced it. / Route.
    ///      The factory's identity is...**Two-way sit tight.**The:`INIT_CODE_PAIR_HASH` - Right. PancakeSwap V2,and
    ///      `factory.getPair(SPCXB, MarsCoin)` Check back the same pool address.
    ///      `TaxProcessor.initialize` The first time I was in the country, I was in the middle of a real-time construction project, and I was in the middle of a new year.
    address internal constant PINNED_GRADUATED_SAMPLE_POOL = 0x94F3ed36706c746ad59fAdCAF271b7431AB1D8F1;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    /// @dev The price of the sample above.SPCXB,One too. bStock).It's only for the review of the sample itself, not our target.
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    /// @notice USD - The price side... **Let's go. PancakeSwap V3,No, it's not. V2**(9.5.1).
    ///
    /// @dev CRITICAL **Pancake V3 It's... `Swap` Organisation Uniswap V3 Different.**(Two more. `protocolFeesToken0/1`):
    ///      topic0 Yes. `0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83`,
    ///      Not the warehouse. subgraph Templates `0xc42079f9...`.Actual:GMEB/USDT I'm not sure. 16,000 Block
    ///      576 In the log **556 The article is the former and the article is the latter.**.The template will be in the past.**I can't get a single one.**.
    ///
    ///      WARNING Rate slot**Different from asset to asset**:Mainstream is `2500`,But... SPYB and QQQB  The active pool in `100` (a) Slotting;
    ///      And the pool of four places in the same token.**They're all built.**,Just one. `liquidity() != 0`  -  -
    ///      Route generation must be selected by mobility, not by "`getPool` The blog also shows the story of the "Face of the World's Children":
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant GMEB_USDT_V3_POOL = 0x908d49048EB3a7bEdfd238972403842805EAF2bE;
    uint24 internal constant GMEB_USDT_V3_FEE = 2500;

    //  End & & Height

    /// @dev and Robinhood That set of three parallel variables.`FORK_STRICT_BLOCK` / `FORK_REQUIRED` Yes.**Cross-chain sharing**I'm sorry.
    ///      Direct {ForkConfig} The constant, not here to write another one.
    string internal constant ENV_RPC_BSC = "RPC_BSC";
    string internal constant ENV_RPC_BSC_LIST = "RPC_BSC_LIST";
    string internal constant ENV_BLOCK_BSC = "FORK_BLOCK_BSC";

    /// @dev CRITICAL **This public endpoint can't serve any pint height.**
    ///
    ///      Actual:BSC Public peer status window only about **120 Blocks (in thousands of dollars)55 sec)**,`head-127` Report.
    ///      `missing trie node`(The other two ends report "Attack Request Required" tokenAnd the flow is restricted. So it's on the list.
    ///      **Only `bscLatest()` Meaningful.**;The pinhead must match. `RPC_BSC`.
    ///
    ///       and Robinhood In a different place:BSC Public End**No, I don't.**Browser UA(Five Ends None UA All respond normally.
    string internal constant RPC_BSC_PUBLIC = "https://bsc-dataseed.bnbchain.org";

    /// @dev The test is "the end point of the archive is serviceable at this level." storage and eth_call,
    ///      and GMEB The pricer configuration is still read out. `(1,29,29,7,0)` -  -  Both have been measured.
    uint256 internal constant DEFAULT_BLOCK_BSC = 120_650_000;

    /// @notice BSC Fork target.
    function bsc() internal view returns (ForkTarget memory) {
        return ForkTarget({
            name: "BSC",
            chainId: BSC_CHAIN_ID,
            rpcUrls: _rpcUrls(),
            blockNumber: _envUint(ENV_BLOCK_BSC, DEFAULT_BLOCK_BSC),
            strictBlock: _envBool(ForkConfig.ENV_STRICT_BLOCK, false),
            required: _envBool(ForkConfig.ENV_REQUIRED, false),
            probe: GMEB
        });
    }

    /// @notice Current Achieved canary Targets;reading consistently latest.
    ///
    /// @dev CRITICAL `strictBlock` Here it is. `true`,and Robinhood That's the same thing:latest canary - I'm asking.
    ///      "What is going on up there today?"
    function bscLatest() internal view returns (ForkTarget memory target) {
        target = bsc();
        target.blockNumber = 0;
        target.strictBlock = true;
    }

    //  Internal
    //
    // WARNING And the next four are... {ForkConfig} Private function with the same name BSC Version.**Not an oversight to copy paste**  -  -
    //    Over there they are. `private`,Not available across the library; and `parseRpcList` / `looksLikeRpcUrl` Yes. `internal`,
    //    It is directly reproduced here, so there is only one definition for the decryption rule.

    function _configuredRpcs() private view returns (string[] memory) {
        string memory single = vm.envOr(ENV_RPC_BSC, string(""));
        string memory list = vm.envOr(ENV_RPC_BSC_LIST, string(""));

        bool hasSingle = bytes(single).length != 0;
        bool hasList = bytes(list).length != 0;

        require(
            !(hasSingle && hasList),
            unicode"ForkConfigBsc: RPC_BSC and RPC_BSC_LIST Not empty at the same time -- no priority guess"
        );

        if (hasList) return ForkConfig.parseRpcList(list);
        if (hasSingle) {
            require(
                ForkConfig.looksLikeRpcUrl(single),
                unicode"ForkConfigBsc: RPC_BSC It's not like it's a peer. URL  -  -  The name of the variable is in the value?"
            );
            string[] memory one = new string[](1);
            one[0] = single;
            return one;
        }
        return new string[](0);
    }

    /// @dev Only the public end when there is no visible end -- it only serves latest,The nails will be flattened and the nails will be blown.
    ///      {ForkTest} The post is part of our special coverage of the World Cup, which will be published in the next few days.**That's what we want to see failure.**,
    ///      Better than quietly returning a fake revolving baseline.
    function _rpcUrls() private view returns (string[] memory urls) {
        urls = _configuredRpcs();
        if (urls.length != 0) return urls;

        urls = new string[](1);
        urls[0] = RPC_BSC_PUBLIC;
    }

    function _envUint(string memory name, uint256 fallbackValue) private view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        return bytes(raw).length == 0 ? fallbackValue : vm.parseUint(raw);
    }

    function _envBool(string memory name, bool fallbackValue) private view returns (bool) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return fallbackValue;

        bytes32 h = keccak256(bytes(raw));
        if (h == keccak256("1") || h == keccak256("true") || h == keccak256("TRUE")) return true;
        if (h == keccak256("0") || h == keccak256("false") || h == keccak256("FALSE")) return false;
        revert(unicode"ForkConfigBsc: Bour Environment Variables Only accepted 1/0/true/false");
    }
}
