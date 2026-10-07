// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @notice Robinhood Central rights registration form, fork test**mock** The two. view.
///
/// @dev All Robinhood The same set of roles and blacklists are shared in shares.`Stock` Every transfer path has been compiled.
///      `onlyNotPaused` and `onlyNotBlocked`,And they're looking for this place.
///      (`docs/research/robinhood-stock-token-permissions.md` 3).
///      CRITICAL mock It's only two.**Read it.**The issuer is really trying to freeze the value of the return, but the issuer is not interested in the return value.
///      And the character-holder can't list it. prank No, no, no. mock The alternative is "who pressed the switch" and the other one is "who pressed the switch" and "who pushed the switch" and "who pushed the switch" and "who pushed the switch" and "who pushed the switch."
///      Not "what happens when you press it."
///
///      The clearing house itself is the interface for door control. `src/interfaces/IIssuerGating.sol`:And that one is...**Production**Code
///      Part (%)`pokeGating` The selection source) is the only handle that is tested for the state of the chain.
///      Both of them. `isBlocked(address)`,Because they really describe the same function.
interface IRobinhoodAccessRegistry {
    function isBlocked(address account) external view returns (bool);
    function paused() external view returns (bool);
}

/// @notice Robinhood `Stock` The two that read the fork test. view.
///
/// @dev CRITICAL **It used to live in... `src/interfaces/IIssuerGating.sol`,Now must be here.**
///      The document says, "I'm not sure.**I'm a pool.**"What is it?" And the part that reads on the pool is, bStocks shape (decision-making) 53);
///      This interface describes it as "the most powerful of all."**Robinhood Chain**"Explosion of what." Two things. `feature/bsc` The first time I was separated,
///      And they should have been separated -- they were only re-coup because there was only one chain.
interface IRobinhoodGatedStock {
    function paused() external view returns (bool);
    // solhint-disable-next-line func-name-mixedcase
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
}

/// @notice A fork test requires all the information you need to know.
/// @param name         Human readable chain names, only for logs and skipping reasons
/// @param chainId      The chain of claims after the split fork has been selected ID  -  -  End finger must be wrong**Failed**,Not skipping.
/// @param rpcUrls      Candidate peer, in order of priority; visible configuration from single value `RPC_ROBINHOOD` or list `RPC_ROBINHOOD_LIST`
/// @param blockNumber  (b) The height of the fork;`0` Organisation latest
/// @param strictBlock  Refuses to retreat when the calculator's height is not available (in the case of a state of emergency).true)Or back up? latest(false)
/// @param required     Failed when environment is not available (true)Or skip.false)
/// @param probe        The contractual address read when you detect whether the altitude is reached
struct ForkTarget {
    string name;
    uint256 chainId;
    string[] rpcUrls;
    uint256 blockNumber;
    bool strictBlock;
    bool required;
    address probe;
}

/// @title ForkConfig
/// @notice The only configuration source for the fork test.
///
/// End and height are read from environment variables, and none of the test files is written dead; the default value below is "when there is nothing to match"
/// . The variable that you can cover is shown in the table below. `.env.example`.
///
/// v1 The target chain is only **Robinhood Chain**.BSC / BNB Chain (a) is not currently within the scope of achievement, testing or acceptance;
/// Future support must be a separate and re-checked item as a follow-up large version.
library ForkConfig {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    /// @dev GME  GameStop Robinhood Token(BeaconProxy).Initial offer, a sample of collateral.
    address internal constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;

    /// @dev latest canary (a) The last manual verification of stocks was achieved;beacon Once upgraded, red light, review and update.
    address internal constant EXPECTED_GME_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;

    /// @dev All Robinhood Central rights registration form for shares (in US$)`isBlocked` / `paused` Stay here.
    ///
    ///      CRITICAL **He's got two jobs at the same address.**:It's both. {GME} This one. BeaconProxy It's... **beacon Body**.
    ///      So... latest canary The one in there. `IBeacon(ROBINHOOD_ACCESS_REGISTRY).implementation()`
    ///      There is no error in reading objects -- constant names only say half of their identity. This is not a comment that needs to be sent:
    ///      `RobinhoodCurrentCanary.t.sol` Every time I run, I run from GME It's... ERC-1967 beacon Read it right in the sink.
    ///      In the future Robinhood If the two functions are removed, the assertion will be red.
    address internal constant ROBINHOOD_ACCESS_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    /// @dev Flap Main entrance (%)ERC-1967 proxy)and v1 Currently clearly supported and most recently manually validated to achieve the baseline.
    ///      Portal implementation - Put it on. launcher Solid as immutable,launcher Again. TaxTokenV3 implementation
    ///      Solid as immutable;latest canary And nailed this chain and three. runtime codehash.Flap New realizations don't automatically
    ///      Access to support; these constants must be reviewed and significantly updated.
    ///
    ///      2026-08-30 / #146:Portal In the blocks. 46,501,682 Raise `0xa3b9...ff44`.New implementation and
    ///      launcher It wasn't there yet. Blockscout Complete source code validation; two below codehash From the chain. runtime,launcher
    ///      by implementation Deployment trading `0x8c8ab665...436bbe` , and the first construction field with runtime PUSH Cross-check.
    ///      latest canary And one at the scene. GME It's priced. tokenVersion=6 It's a token, proof it actually came to its original form.
    ///      `0x7777...3333`,And not just... launcher This address happened to be in the byte code.
    address internal constant FLAP_PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
    address internal constant EXPECTED_FLAP_PORTAL_IMPLEMENTATION = 0xa3b96Df56f254B926B17D5f7FB6CD858c216ff44;
    bytes32 internal constant EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH =
        0xc420573f11b2c4fab419118e0e6fc167cc3902c62a3e41fd4495c5db0ea30532;
    address internal constant EXPECTED_FLAP_PORTAL_LAUNCHER = 0xCC40cfc2c1172794934aA1D908Dac77F4AF6c0A0;
    bytes32 internal constant EXPECTED_FLAP_PORTAL_LAUNCHER_CODEHASH =
        0xa0d0fcf34ff647df2c193821ada2b1237bfd0bdb40cf229b3003dc06b3edd3ed;
    address internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;
    bytes32 internal constant SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH =
        0xa73abf611d52de6364ec684feed2ef3e9aec9706a02b808523e75a6d8438b164;

    /// @notice CRITICAL **VaultPortal and Portal It's two contracts.`newVault` The caller is the former.**
    ///
    /// @dev The money and the vault are gone. {FLAP_VAULT_PORTAL}(`newTokenV6WithVault`),It's going to be in the inside.
    ///      {FLAP_PORTAL}.Back to our factory. `newVault` The blog is also available.`msg.sender` Yes. **VaultPortal** -  -
    ///      Actual: Take {FLAP_PORTAL} I'll get the address. Flap Your own. `IndexVaultFactory`,
    ///      I'm going back to the line. `"Only VaultPortal"`.Lock the door. Portal It's like never going to open a series.
    ///
    ///      WARNING **These two addresses can't be taken from BSC That's a copy.** BSC It's... VaultPortal `0x9049...` and Guardian
    ///      `0x9e27...` Yes. Robinhood Chain Go, go, go!**Zero bytes**;And... BSC It's... *Portal* Address
    ///      `0xe2cE...` On this chain.**There's a code.**(23,959 It's not this chain. Portal  -  -
    ///      The most dangerous way to read is to copy something.
    ///      Source:`docs/research/flap-vault-identity-spike.md` 2,and Flap Document
    ///      `deployed-contract-addresses.md` It's... Robinhood Paragraph is consistent.
    address internal constant FLAP_VAULT_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

    /// @dev Flap Guardian(This is the chain. The norm requires the vault./The plant ' s competence functions must be granted and irrevocable at the same time.
    ///      I'm a person.**No, no.**Grants it any privileges - it has no privileges to assign (`VaultRegistry` Only written face
    ///      `bind`,and `factory` Yes. immutable).
    address internal constant FLAP_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// @notice CRITICAL **Robinhood Chain The only money that can walk through. enum Group, one by one.**
    ///
    /// @dev Flap Document is only given as an item**Name**,No subscripts; and most values are taken directly from this chain
    ///      `FeatureDisabled()`.The next three constants run through the matrix, each with it.
    ///      "What would be the other value?" because that's why they exist:
    ///
    ///      | Constant | Actual |
    ///      |---|---|
    ///      | `tokenVersion = 6`(`TOKEN_TAXED_V3`) | 0...5,7 All of them. `FeatureDisabled()`(`0xac5f6092`) |
    ///      | `migratorType = 1`(`V2_MIGRATOR`)    | 0 / 2 / 3 All of them. `FeatureDisabled()` |
    ///      | `dexThresh = 1`                        | 0 / 2 / 3 All of them. `InvalidDexThresholdType(n)`(`0x77146b42`) |
    ///
    ///      The other two must be nailed:`dexId = 0`,`quoteAmt = 0`(Non-zero quoteAmt The one who lost the curved silo.
    ///      I'll see you around. `docs/research/flap-vault-identity-spike.md` 5.
    ///
    ///      WARNING **It's normal. `Portal.newTokenV6`(= D0 The way.** That one. spike The same name form is measured as
    ///      **`VaultPortal.newTokenV6WithVault`** The front door, the two entrances have different points of rejection, so the wrong code is different--
    ///      `dexThresh` It's... 2 / 3 - It's over there. `0x9e62f353`, Over here with  0 Concurrent `InvalidDexThresholdType`.
    ///      Four recalculations of this table (Mainnet) / Test Network  Original currency / GME See you at the price.
    ///      `docs/research/robinhood-testnet-flap-portal-probe.md` 7.
    ///
    ///      WARNING **It used to say, "The original is the only active value of this chain." That's wrong.**(M2-2 Actual corrections:
    ///      Flap In the blocks. 17,391,936 The first time that the government has set up a single account for five assets, the second time the government has made a bid for the assets.**{GME} It's one of them.**
    ///      (Default Curve `CURVE_RH_25_ASSET`),And...MEME "Speeched in stock currency." M2 The premise.
    ///      Source:`docs/research/flap-portal-price-semantics.md` 4.
    uint8 internal constant FLAP_TOKEN_VERSION_TAXED_V3 = 6;
    uint8 internal constant FLAP_MIGRATOR_TYPE_V2 = 1;
    uint8 internal constant FLAP_DEX_THRESH_SUPPORTED = 1;

    /// @notice CRITICAL **Flap A normal deal would stop the switch we're dealing with.**:{GME} .
    ///
    /// @dev The five numbers below are the main network. `Portal.getQuoteTokenConfiguration(GME)` Current Read
    ///      (2026-08-17 Review:`(1, 29, 29, 7, 0)`,From Blocks 17,391,936 - Get up.
    ///
    ///      WARNING **It's not our state, is it? Flap Five bytes in administrator 's storage.**
    ///      `setQuoteTokenConfiguration(GME, {enabled: 0, ...})` - Send it out.
    ///      `CallLauncher.launch` It'll be there. `Portal.newTokenV6` That one hit.
    ///      `QuoteTokenNotAllowed(GME)`(`0x9a5c8a92`)Roll back in the field.
    ///
    ///      CRITICAL **The border must be right.**(and `script/watch-market-wallet.sh` The same set of rules for the wording:
    ///
    ///      | | After the withdrawal |
    ///      |---|---|
    ///      | Currency of the project issued / Treasury / Identity tied. | Not affected - not anywhere. Flap In your hand. |
    ///      | I'm taking the Quantico mortgage and the cast. | No impact - no upgrade of pool, no impact admin Exports |
    ///      | Curved transactions and taxes on the items issued | Not affected - Configuration only**The coin.**That step was read. |
    ///      | **New currency** | CRITICAL **I can't send one.** |
    ///
    ///      That is:**The reimbursement is not affected and the ability to issue is zero.** This is... R12 The risk of "platform trust" is not a problem.
    ///      We don't have any defenses on the chain. All we can do is...**Yeah.**.
    ///
    ///      CRITICAL **Why does it need a claim of its own, not a claim by a man? codehash Nail Overwhelm**:
    ///      Upgrade Portal implementation To move byte code,`EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH`
    ///      It's red first; it's only stored when the configuration is removed.**That nail knows nothing about it.**.The two are different things.
    ///      The latter is much cheaper.
    ///
    ///       This switch.**It's alive.**,Not a paper permission:
    ///      `docs/research/robinhood-testnet-flap-portal-probe.md` 5.1 On the test web fork.
    ///      I'm gonna pretend to be the administrator.**Pull it.**Once, the same launch was never changed. revert Turned into success.
    uint8 internal constant EXPECTED_GME_QUOTE_ENABLED = 1;
    /// @dev `CURVE_RH_25_ASSET`  -  -  13x Curves, reference price $25,About $10K Graduated.
    uint8 internal constant EXPECTED_GME_QUOTE_DEFAULT_CURVE = 29;
    uint8 internal constant EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE = 29;
    /// @dev Non-zero = The protocol side is matched with the original coin. -> GME . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .`SWAP_VIA_MIXED_ROUTER`).
    uint8 internal constant EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE = 7;
    uint8 internal constant EXPECTED_GME_QUOTE_DEX_ID = 0;

    /// @notice The strangulation of the height. MEME:HSHITTY,Tax rate 300/300(And history BSC Contrast MarsCoin The same.
    ///
    /// @dev Three articles are of a general nature, which is a prerequisite for the full acceptance and acceptance, and are therefore written here rather than in individual documents:
    ///
    ///      - **EIP-1167 Mint Agent**(45 Bytes runtime),Point {SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION};
    ///      - **All 10 Billions of supplies are still on the conic (in the case of the fusion curve){FLAP_PORTAL})Go, go, go!**  -  -  So the holder's initial balance is always from Portal
    ///        There. `prank` I'm not sure if I'm going to be able to get a job.**No, I'm fine. `deal` Go figure out how it's stored.**;
    ///      - Zero tax on the destruction of routes, as measured (in thousands of US dollars)`RobinhoodFlapBurn.t.sol` Ongoing review).
    ///
    ///      latest canary Do not reuse it:latest Each time a new currency is issued on the spot, it avoids mixing historical evidence with the current state.
    address internal constant PINNED_FLAP_TAX_TOKEN_V3_SAMPLE = 0xf40AeC5E453cC6D2Ed29E1fcAba07653Adc47777;

    /// @dev History single endpoint variable. It must always be transmitted as it is, not based on URL The contents guess it's not a list.
    string internal constant ENV_RPC_ROBINHOOD = "RPC_ROBINHOOD";
    /// @dev visible multi-end variable;using ASCII Blank separation, avoid placing URL valid comma miscalculated as separator.
    string internal constant ENV_RPC_ROBINHOOD_LIST = "RPC_ROBINHOOD_LIST";
    string internal constant ENV_BLOCK_ROBINHOOD = "FORK_BLOCK_ROBINHOOD";
    string internal constant ENV_STRICT_BLOCK = "FORK_STRICT_BLOCK";
    string internal constant ENV_REQUIRED = "FORK_REQUIRED";

    /// @dev Community endpoints.**Once.**It's all filed, not anymore.
    ///
    ///      CRITICAL 2026-08-13 - It's in the middle of a month. 8 "Supplied within the hour." 300 "The calculus height of 10,000 dollars ago has deteriorated to
    ///      Only the most recent one. 64-256 Status of individual blocks" (in thousands of US dollars)`latest-64` Readable,`latest-256` Back
    ///      `state ... is not available`).There was a part of it that was even more of itself. latest Can not get message: %s %s
    ///      **It is no longer a revolving baseline on which to rely.**
    ///
    ///      It's because it's not necessary. key,And it could be restored; but after the official end, it is not possible to get the information out of the public.
    ///      And...**No longer assume it serves any historical height.**.
    string internal constant RPC_ROBINHOOD_COMMUNITY = "https://rpc.arrowrpc.com";

    /// @dev Robinhood Official endpoint. Authority, but...**Keep the treaty only 6k-20k Status of individual blocks**
    ///      (Make a deal. 0.1 sec  10-30 The calculus is bound to fall above it.
    string internal constant RPC_ROBINHOOD_OFFICIAL = "https://rpc.mainnet.chain.robinhood.com";

    uint256 internal constant DEFAULT_BLOCK_ROBINHOOD = 31_955_417;

    function robinhood() internal view returns (ForkTarget memory) {
        return ForkTarget({
            name: "Robinhood Chain",
            chainId: ROBINHOOD_CHAIN_ID,
            rpcUrls: _rpcUrls(),
            blockNumber: _envUint(ENV_BLOCK_ROBINHOOD, DEFAULT_BLOCK_ROBINHOOD),
            strictBlock: _envBool(ENV_STRICT_BLOCK, false),
            required: _envBool(ENV_REQUIRED, false),
            probe: GME
        });
    }

    /// @notice Current Achieved canary dedicated target; always reading latest,It cannot be highly covered by historical acceptances.
    ///
    /// @dev There was once here.**Position Exchange**(Put the first two alignments on the list, and then top the official endpoints to the front --
    ///      It relies on the assumption that the first of the internalised tables is the filing endpoint.`_rpcUrls()` Already
    ///      The exchange went from "revision order" to "destruct order."
    ///      The order is defined in only one place.
    function robinhoodLatest() internal view returns (ForkTarget memory target) {
        target = robinhood();
        target.blockNumber = 0;
        target.strictBlock = true;
    }

    /// @notice One.**I hope the service is nailed to the height.**Candidates: The visible configuration is preferred and not worthy of community endpoints.
    ///
    /// @dev CRITICAL The reason for it is. `ForkSelection.t.sol`:The test is about "replicable priority".
    ///      **Select Policy**,It needs a point that really serves the height of the nail as the subject. The role used to be by
    ///      `RPC_ROBINHOOD_COMMUNITY` Write dead play; after it's degraded to non-archive, all three tests**Silence. skip**  -  -
    ///      Green, but not a single byte. Turn the role into "environmentally good" and then run with the filing endpoint.
    ///
    ///      Take when matching a visible list**First**:That's the priority of the user's own ranking, and the first is the one he thinks is the most reliable.
    function pinnedCandidate() internal view returns (string memory) {
        string[] memory configured = _configuredRpcs();
        return configured.length != 0 ? configured[0] : RPC_ROBINHOOD_COMMUNITY;
    }

    /// @notice This string of text doesn't look like a peer. URL.
    ///
    /// @dev CRITICAL **It's a smoother hand that's happened twice.**:Stick the variable name in with the value.
    ///      (`RPC_ROBINHOOD=https://...`),Or a little bit of a blank in the front. / Quotes.
    ///
    ///      That's not what you say. It's going to go all the way. `vm.rpc` Failure, and then it's written down.
    ///      **All candidate ends are not connected. / Intercepted. / "I'm not sure if it's valid."**  -  -  One.
    ///      Bring people to the network, firewalls,API key The amount of the error message, and the problem is actually only in that line of text.
    ///      (The locals were more remarkable:`cast` Think of it as IPC socket Path, report.
    ///      `local socket name length exceeds capacity of sun_path`.)
    ///
    ///      WARNING The verdict is meant to be only for reading.**Start**,Do Not Complete URL Parsing: The catch here is "The whole part is not" URL,
    ///      No, it's not.URL The latter hand over the end of the case to the end point, and the more lenient the sentence, the less the injury.
    function looksLikeRpcUrl(string memory url) internal pure returns (bool) {
        return _startsWith(url, "http://") || _startsWith(url, "https://") || _startsWith(url, "ws://")
            || _startsWith(url, "wss://");
    }

    /// @notice Put the visible `RPC_ROBINHOOD_LIST` Resolves the candidate endpoint list separated by blanks.
    ///
    /// @dev No comma separator: it's in URL It's... path,query and fragment . Single-end variable
    ///      {ENV_RPC_ROBINHOOD} The original bytes are therefore always followed; the semiwords will only be executed if the variable is clearly selected.
    ///      Space,Tab,LF,CR All separator, continuous separator automatically ignores.URL . If you need these characters, you should press URL
    ///      Rule percent-encode;This makes multi-end syntax irrelevant. URL Byte overlaps.
    function parseRpcList(string memory raw) internal pure returns (string[] memory urls) {
        bytes memory b = bytes(raw);
        if (b.length == 0) return new string[](0);

        uint256 pieces;
        bool inPiece;
        for (uint256 i = 0; i < b.length; i++) {
            if (_isSpace(b[i])) {
                inPiece = false;
            } else if (!inPiece) {
                pieces++;
                inPiece = true;
            }
        }

        if (pieces == 0) _revertEmptyRpcList();

        urls = new string[](pieces);
        uint256 found;
        uint256 start;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i != b.length && !_isSpace(b[i])) continue;
            if (start != i) {
                string memory piece = _slice(b, start, i);
                if (!looksLikeRpcUrl(piece)) _revertMalformedRpcEntry(found + 1, ENV_RPC_ROBINHOOD_LIST);
                urls[found++] = piece;
            }
            start = i + 1;
        }
    }

    /// @dev Error reporting only to serial number, not printing original value: end URL It may contain evidence.revert I'll get in. CI / Local log.
    function _revertMalformedRpcEntry(uint256 index, string memory variableName) private pure {
        revert(
            string.concat(
                variableName,
                unicode" No. No. ",
                vm.toString(index),
                unicode" It's not like a supported end. URL(The paragraph should read http://,https://,ws:// or wss:// (a) The beginning.",
                unicode"Multi-end variables are separated by blanks and prioritized. The most common three reasons are:",
                unicode"The variable name is also glued to the reference, the value is quoted or the separator is marked with another symbol.",
                unicode"Value not printed because peer may bring itself key."
            )
        );
    }

    function _revertEmptyRpcList() private pure {
        revert(string.concat(ENV_RPC_ROBINHOOD_LIST, unicode" There is value, but only blanks, no endpoints."));
    }

    /// @notice Two visible configuration sources are analysed for environmental readability and environmentally undependent contractual testing.
    ///
    /// @dev Keep old variable single URL bytes of the text; URL It has to be visible. `RPC_ROBINHOOD_LIST`.
    ///      Both are not being rejected in time, not quietly deciding who will cover.
    function parseConfiguredRpcs(string memory single, string memory list)
        internal
        pure
        returns (string[] memory urls)
    {
        if (bytes(single).length != 0 && bytes(list).length != 0) {
            revert(
                string.concat(
                    ENV_RPC_ROBINHOOD,
                    unicode" and ",
                    ENV_RPC_ROBINHOOD_LIST,
                    unicode" It cannot be set at the same time; the former is a single endpoint, the latter is a visible list."
                )
            );
        }
        if (bytes(list).length != 0) return parseRpcList(list);
        if (bytes(single).length == 0) return new string[](0);
        if (!looksLikeRpcUrl(single)) _revertMalformedRpcEntry(1, ENV_RPC_ROBINHOOD);

        urls = new string[](1);
        urls[0] = single;
    }

    /// @dev Reads the visible configuration. History single values and visible lists are rejected when they appear at the same time, avoiding guessing priorities that result in silent alternation of the endpoints.
    function _configuredRpcs() private view returns (string[] memory) {
        return
            parseConfiguredRpcs(vm.envOr(ENV_RPC_ROBINHOOD, string("")), vm.envOr(ENV_RPC_ROBINHOOD_LIST, string("")));
    }

    /// @dev Space / Tab / LF / CR.All four:CRLF From Windows It's... `.env`,Alone. LF From
    ///      `echo` and secret Edit box, tab from alignment.
    function _isSpace(bytes1 c) private pure returns (bool) {
        return c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;
    }

    function _slice(bytes memory b, uint256 lo, uint256 hi) private pure returns (string memory) {
        bytes memory out = new bytes(hi - lo);
        for (uint256 i = lo; i < hi; i++) {
            out[i - lo] = b[i];
        }
        return string(out);
    }

    function _startsWith(string memory haystack, string memory prefix) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory p = bytes(prefix);
        if (h.length < p.length) return false;

        for (uint256 i = 0; i < p.length; i++) {
            if (h[i] != p[i]) return false;
        }
        return true;
    }

    /// @dev - It's a visual configuration. `RPC_ROBINHOOD` or `RPC_ROBINHOOD_LIST` Just...**Only**It gives those ends...
    ///      We should not have changed to something else, or simply left the inside of his list.
    ///      (That'll put "D" in. 2 The incident was covered up in a quiet drop in the ranks.
    ///
    ///      CRITICAL **If it's not worth it, the nailing is almost hopeless.**:Official peer only 10-30 Minute status, community endpoint
    ///      2026-08-13 Only the appointment. 64-256 A block. So the internal candidate can only hold. latest The one in the first,
    ///      And...**Recoverable fork acceptance has been substantially dependent on a visible approach. RPC Configure the pointer to the real archive endpoint**
    ///      (CI Let's go. repo secret).The order is also being changed: the official front (must be connected, authoritative) and the official line is being changed.
    ///      The community is then (possibly back to archiving, and then back to use).
    function _rpcUrls() private view returns (string[] memory urls) {
        urls = _configuredRpcs();
        if (urls.length != 0) return urls;

        urls = new string[](2);
        urls[0] = RPC_ROBINHOOD_OFFICIAL;
        urls[1] = RPC_ROBINHOOD_COMMUNITY;
    }

    /// @dev Variables Not Set**Or set empty strings**It's not worth it. CI Lee. `${{ secrets.X }}`  When I can't get
    ///      It's just an empty string that is given, and it's never gonna be available without this level of default.
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
        revert(string.concat("ForkConfig: ", name, unicode" Could not close temporary folder: %s", raw));
    }
}
