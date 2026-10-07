// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest, RequiredForkUnavailable} from "./ForkTest.sol";

/// @notice `ForkTest.selectFork` . The endpoint selects the contract.
///
/// The scaffold test of the seven tickets in the back is the whole logic of the choice, so it has to test itself.
/// Here's the assertion.**Which end is selected, which height is nailed**,Not the chain facts.
///
/// This contract is real. RPC Integrated overlay: Scrubs at nail height, list resolution and log desensitivity.
/// End of file {ForkSelectionBackendTest} Then override Three. `_backend*` Hook, lock off the line.
/// `firstReachable` Return, strict patterns and wrong chains fail immediately.
contract ForkSelectionTest is ForkTest {
    /// @dev The connection is immediately rejected and used to occupy a "unconnected" candidate.
    string internal constant UNREACHABLE = "http://127.0.0.1:1";

    function _target(string[] memory urls) internal pure returns (ForkTarget memory) {
        return ForkTarget({
            name: "Robinhood Chain",
            chainId: ForkConfig.ROBINHOOD_CHAIN_ID,
            rpcUrls: urls,
            blockNumber: ForkConfig.DEFAULT_BLOCK_ROBINHOOD,
            // CRITICAL Strictness: These tests must not be established latest Fork. Otherwise "CI "The fork steps are only nailed to the heights."
            //    That's not true -- that's the question that was caught in the last edition of this document.
            strictBlock: true,
            required: false,
            probe: ForkConfig.GME
        });
    }

    function _urls(string memory a, string memory b) internal pure returns (string[] memory urls) {
        urls = new string[](2);
        urls[0] = a;
        urls[1] = b;
    }

    /// @dev CRITICAL These tests assert that**Select Policy**,And the strategy input is the endpoint's ability at the moment -- that's the environment.
    ///      When the filing endpoint is restricted, the selector will jump legally and assert that the "archiving endpoints" will be red.
    ///      That's Ben. harness It is explicitly prohibited: environmental problems must be bypassed and cannot be turned into failures.
    ///      So every test first.**Top**Check prefix, skip if not met (`vm.skip` It only works at the top.
    ///
    ///      WARNING **But "legal skip" is also a way of losing power.** 2026-08-13 Before, the test end was written dead.
    ///      `RPC_ROBINHOOD_ARCHIVE`;After the community endpoint was reduced to non-archiving, these three tests were tested.**Quiet, all of you. skip**,
    ///      CI As usual Green - the selection strategy has never been tested by any byte. It is now changed to
    ///      {ForkConfig-pinnedCandidate}:Yes. `RPC_ROBINHOOD` or `RPC_ROBINHOOD_LIST`(CI Let's go. repo secret)Use it.
    ///      So the "archive endpoint" thing drives both the acceptance test and this document, and the two will not be separated.
    function _requirePinnedServable(string memory url) internal {
        if (!_reachable(url) || !_hasStateAt(url, ForkConfig.GME, ForkConfig.DEFAULT_BLOCK_ROBINHOOD)) {
            // CRITICAL Skip the reason `_safeUrl`  -  -  Could contain peer key,And... skip Messages will be printed.
            vm.skip(
                true,
                string.concat(
                    unicode"Preconditions not met:",
                    _safeUrl(url),
                    unicode" I can't serve the height of nails at this point."
                )
            );
        }
    }

    /// @notice CRITICAL **When the visible list is combined with two ends, the first one is not available to retreat to the second.**
    ///
    /// @dev This is a multi-end list.**All reasons**:required The single point under mode is the whole warehouse. CI Red.
    ///      And... 2026-08-13 It's been measured once. So this test is going to be**The whole way.**  -  -
    ///      Start with an original configuration string, pass {ForkConfig-parseRpcList} Parsed, and handed over to the... `selectFork`,
    ///      It was asserted that it fell on the second end.
    ///
    ///      WARNING The only jump that doesn't get covered by it is `vm.envOr` That reading. That needs to be done. `vm.setEnv`,And... `setEnv` Changed.
    ///      **Process**Environment: same `forge test` Every subsequent test in the in-country will see the modified value.
    ///      In parallel, "for the purpose of measuring a line's resolution" the endpoint of the archive is removed from the other test feet. It is neither cost-effective nor safe.
    function test_fallsBackToTheSecondConfiguredEndpoint() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        // `RPC_ROBINHOOD_LIST` shape: the priority end is in front, the bottom is behind, separated by blank.
        string[] memory urls = ForkConfig.parseRpcList(string.concat(UNREACHABLE, " ", ForkConfig.pinnedCandidate()));
        assertEq(urls.length, 2, unicode"Both ends should be resolved to two candidates.");

        selectFork(_target(urls));

        assertEq(
            forkUrl,
            _safeUrl(ForkConfig.pinnedCandidate()),
            unicode"You should have used the second one if you had the first end."
        );
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"Should be nailed to the specified height.");
        assertEq(block.number, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, "block.number");
    }

    /// @notice Two configuration syntaxes: the old single value is the same byte, and the visible list is separated by blank.
    ///
    /// @dev and {test_malformedRpcUrlIsRejectedAndGoodOnesAreNot} The same thing: The test is pure function.
    ///      So this test...**Do not touch environment variables**.
    function test_parsesExplicitWhitespaceSeparatedEndpointList() public {
        // (1) Old single value: one candidate, by by bytes,URL Also legitimate commas must not trigger splits.
        string memory commaUrl = "https://a.example/v2/key,backup?methods=a,b#fragment,c";
        string[] memory single = ForkConfig.parseConfiguredRpcs(commaUrl, "");
        assertEq(single.length, 1, unicode"The unit should be broken down to a candidate.");
        assertEq(single[0], commaUrl, unicode"The unit value with commas shall not be divided or rewritten");

        string memory trailingWhitespaceAndNewline = "https://a.example/v2/key \n";
        single = ForkConfig.parseConfiguredRpcs(trailingWhitespaceAndNewline, "");
        assertEq(
            single[0],
            trailingWhitespaceAndNewline,
            unicode"Single value after blanks and line breaks must be retained by bytes"
        );
        _assertConfiguredRejects(
            " https://a.example",
            "",
            ForkConfig.ENV_RPC_ROBINHOOD,
            unicode"Single-value leader follows old behaviour: reject"
        );

        // (2) Multiple values: must go list variables in a visible fashion; in order of writing, in spaces / Tab / LF Separate.
        string[] memory many = ForkConfig.parseRpcList(" https://a.example\t\thttps://b.example\n");
        assertEq(many.length, 2, unicode"Two.");
        assertEq(many[0], "https://a.example", unicode"First separated by blank");
        assertEq(many[1], "https://b.example", unicode"Second button. Tab Separated from line break");

        // (3) Comma is... URL content, not separator.
        many = ForkConfig.parseRpcList("https://a.example/v2/key,backup https://b.example?methods=a,b");
        assertEq(many.length, 2, unicode"Two commas. URL It should still be solved in two.");
        assertEq(many[0], "https://a.example/v2/key,backup", unicode"First one. URL Comma must be kept");
        assertEq(many[1], "https://b.example?methods=a,b", unicode"Second query It's... URL Comma must be kept");

        // 4 Empty string = Not fit; only blank visible lists cannot be disguised as unconfigured.
        assertEq(ForkConfig.parseRpcList("").length, 0, unicode"Empty string = Not configured");
        _assertListRejects("  \n ", unicode"Lists are empty only and not unconfigured");
    }

    /// @notice CRITICAL List**Any item**The wrongs must be clearly stated in the first place.
    ///
    /// @dev Just checking the first one's realization is the same thing. {test_parsesExplicitWhitespaceSeparatedEndpointList}:
    ///      Every one of those tests was legal. This one nailed it from the back.
    function test_malformedEntryAnywhereInTheListIsRejected() public {
        _assertListRejects("RPC_ROBINHOOD_LIST=https://a.example", unicode"Single item: Inline value for variable name");
        _assertListRejects("https://a.example example.com", unicode"No, not the second one. scheme");
        _assertListRejects('https://a.example "https://b.example"', unicode"Second with quotation marks.");
        _assertListRejects(" ,  ,", unicode"Comma's not. URL,The only item must be rejected.");
    }

    /// @notice The two variables cannot be set in the order of the overlays at the same time, otherwise the endpoint specified by the user is changed quietly.
    function test_rejectsSimultaneousSingleAndListConfiguration() public {
        _assertConfiguredRejects(
            "https://a.example", "https://b.example", ForkConfig.ENV_RPC_ROBINHOOD, unicode"Set the unit with the list"
        );
    }

    /// @notice Wrong chain. ID The assertion is not filed. URL path The evidence in the file.
    function test_wrongChainMessageRedactsEndpointPathCredentials() public pure {
        ForkTarget memory target = _target(_urls("", ""));
        string memory pathUrl = "https://archive.example/v2/top-secret-key";
        string memory pathMessage = _wrongChainMessage(target, pathUrl);

        assertEq(
            pathMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/... It pointed to the wrong chain.",
            unicode"Error link message should only be shown scheme and host"
        );
        assertFalse(
            _contains(pathMessage, "/v2/top-secret-key"),
            unicode"The error chain message should not be included URL path / key"
        );

        string memory queryUrl = "https://archive.example?api_key=top-secret-key";
        string memory queryMessage = _wrongChainMessage(target, queryUrl);
        assertEq(
            queryMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/... It pointed to the wrong chain.",
            unicode"query The same thing that must be hidden."
        );
        assertFalse(
            _contains(queryMessage, "api_key=top-secret-key"),
            unicode"The error chain message should not be included query key"
        );

        string memory userinfoUrl = "https://credential:top-secret@archive.example#fragment-secret";
        string memory userinfoMessage = _wrongChainMessage(target, userinfoUrl);
        assertEq(
            userinfoMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/... It pointed to the wrong chain.",
            unicode"userinfo and fragment The same thing that must be hidden."
        );
        assertFalse(
            _contains(userinfoMessage, "credential"),
            unicode"The error chain message should not be included userinfo Username"
        );
        assertFalse(
            _contains(userinfoMessage, "top-secret"),
            unicode"The error chain message should not be included userinfo Password"
        );
        assertFalse(
            _contains(userinfoMessage, "fragment-secret"),
            unicode"The error chain message should not be included fragment"
        );
    }

    /// @dev It must be. external,try/catch I'm not gonna stop it.
    function parseRpcListExternal(string memory raw) external pure returns (string[] memory) {
        return ForkConfig.parseRpcList(raw);
    }

    /// @dev It must be. external,try/catch I'm not gonna stop it.
    function parseConfiguredRpcsExternal(string memory single, string memory list)
        external
        pure
        returns (string[] memory)
    {
        return ForkConfig.parseConfiguredRpcs(single, list);
    }

    /// @dev The assertion. `raw` rejected and**Reason points to the configuration itself**  -  -  It can't be anything else that's so bad that it's green.
    function _assertListRejects(string memory raw, string memory what) private {
        try this.parseRpcListExternal(raw) {
            fail(string.concat(unicode"This value must be rejected:", what));
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, ForkConfig.ENV_RPC_ROBINHOOD_LIST),
                string.concat(unicode"You must call me when you're wrong. RPC_ROBINHOOD_LIST:", what)
            );
        }
    }

    function _assertConfiguredRejects(
        string memory single,
        string memory list,
        string memory variableName,
        string memory what
    ) private {
        try this.parseConfiguredRpcsExternal(single, list) {
            fail(string.concat(unicode"This configuration must be rejected:", what));
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, variableName),
                string.concat(unicode"Error reporting must name and configure variables:", what)
            );
        }
    }

    /// @notice The unconnected candidate is to be jumped and continue to try the next one -- not give up on it.
    function test_skipsUnreachableCandidateAndUsesTheNext() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        selectFork(_target(_urls(UNREACHABLE, ForkConfig.pinnedCandidate())));

        assertEq(forkUrl, _safeUrl(ForkConfig.pinnedCandidate()), unicode"The second candidate should be selected.");
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"Should be nailed to the specified height.");
        assertEq(block.number, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, "block.number");
    }

    /// @notice When the first endpoint is connected but cannot serve the calculator height, it is important to continue to look for the one that can serve the back.
    ///         Recoverable's priority over "getting " , which is not archived at official end points, and which are next to the filing endpoints.
    function test_prefersALaterCandidateThatCanServeThePinnedBlock() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        selectFork(_target(_urls(ForkConfig.RPC_ROBINHOOD_OFFICIAL, ForkConfig.pinnedCandidate())));

        assertEq(forkUrl, _safeUrl(ForkConfig.pinnedCandidate()), unicode"Can't stop at the first point of contact.");
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"Should be nailed to the specified height.");
    }

    /// @notice CRITICAL Chain ID It doesn't match.**Configure Error**,It must fail, not be swallowed up as "the next candidate" or skipped.
    ///
    /// WARNING The last edition of this test is...**Fake positive.**:It's broad. `vm.expectRevert()` I'll wrap it up once. external Call.
    /// And when the net is broken, `selectFork` Inside. `vm.skip` In embedded calls, you can call
    /// `skip can only be used at test level` revert  -  -  That anomaly is equally satisfying. `expectRevert()`,
    /// So the test was,**I didn't even get to the chain. ID The assertion.**The situation is green. It's been measured.
    ///
    /// Now replace: top level prefix; reuse try/catch The assertion.**The reason for failure is the chain. ID Not in line**;
    /// If you hit him, `skip` Misuse (description endpoint dropped after pre-checking) and skips at top level according to environmental problems.
    function test_wrongChainIdFailsAndIsNotSwallowed() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        string[] memory urls = new string[](1);
        urls[0] = ForkConfig.pinnedCandidate();

        try this.selectForkExpectingWrongChain(_target(urls)) {
            fail(unicode"Chain ID When not in line selectFork It has to fail, not pass.");
        } catch (bytes memory reason) {
            if (_revertMentions(reason, "skip can only be used")) {
                vm.skip(true, unicode"The endpoint fell after the pre-check.selectFork Walk to the branch.");
            }
            assertTrue(
                _revertMentions(reason, unicode"It pointed to the wrong chain."),
                unicode"The reason for failure must be the chain. ID It's not. It can't be anything else."
            );
        }
    }

    /// @notice CRITICAL **Wrong match. `RPC_ROBINHOOD` It must be made clear on the spot that it cannot be disguised as "unconnected".**
    ///
    /// @dev This test was based on a real accident:secret It's got a variable name in it, and it's got a value.
    ///      (`RPC_ROBINHOOD=https://...`).The value doesn't give "wrong".
    ///      It's been all the way down there. `vm.rpc` Failed, recorded as "no candidate has any access to the Internet." / Intercepted. /
    ///      "and three branches. CI And while Red, everyone goes to the network and... API key The limit is up.
    ///
    ///      The test is pure, so this test is a test.**Do not touch environment variables**  -  -  `vm.setEnv` It's gonna contaminate the same process.
    ///      For each subsequent test, it is not cost-effective to verify the global state of movement for a single sentence.
    ///
    ///      Both directions assert that only "bad values" are rejected, and one is always false The verdict was also passed.
    function test_malformedRpcUrlIsRejectedAndGoodOnesAreNot() public pure {
        // The shape of the real accident, and its two immediate relatives.
        assertFalse(
            ForkConfig.looksLikeRpcUrl("RPC_ROBINHOOD=https://example.com/v2/key"),
            unicode"In the value of variable names -- must be judged not to be URL"
        );
        assertFalse(ForkConfig.looksLikeRpcUrl('"https://example.com"'), unicode"With quotation marks");
        assertFalse(ForkConfig.looksLikeRpcUrl(" https://example.com"), unicode"Lead Space");
        assertFalse(ForkConfig.looksLikeRpcUrl("example.com"), unicode"No, I'm not. scheme");
        assertFalse(ForkConfig.looksLikeRpcUrl("http"), unicode"It's only half-wire. scheme");

        // In turn: The shape that is real can't be missed.
        assertTrue(ForkConfig.looksLikeRpcUrl(ForkConfig.RPC_ROBINHOOD_OFFICIAL), unicode"Official peer");
        assertTrue(ForkConfig.looksLikeRpcUrl(ForkConfig.RPC_ROBINHOOD_COMMUNITY), unicode"Community Endpoints");
        assertTrue(
            ForkConfig.looksLikeRpcUrl("https://robinhood-mainnet.g.alchemy.com/v2/deadbeef"),
            unicode"- Yeah. key Archive Endpoint"
        );
        assertTrue(ForkConfig.looksLikeRpcUrl("http://127.0.0.1:8545"), unicode"Local anvil");
        assertTrue(ForkConfig.looksLikeRpcUrl("wss://example.com/v2/key"), unicode"WebSocket");
    }

    /// @notice CI required In mode, the environment is not available and the test must fail, and it can no longer be disguised as green. skip.
    function test_requiredModeFailsWhenEveryCandidateIsUnreachable() public {
        ForkTarget memory target = ForkConfig.robinhood();
        target.rpcUrls = new string[](1);
        target.rpcUrls[0] = UNREACHABLE;
        target.required = true;

        vm.expectRevert(
            abi.encodeWithSelector(
                RequiredForkUnavailable.selector,
                "Robinhood Chain",
                unicode"All candidate ends are not connected. / Intercepted. / - No proof."
            )
        );
        this.selectForkInRequiredMode(target);
    }

    /// @dev It must be. external,try/catch I can't stop it. internal Not once. call.
    function selectForkExpectingWrongChain(ForkTarget memory target) external {
        target.chainId = 1; // The Etherport Master Network, which does not match the chain where the endpoint actually is.
        selectFork(target);
    }

    function selectForkInRequiredMode(ForkTarget memory target) external {
        selectFork(target);
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        return _revertMentions(bytes(haystack), needle);
    }
}

/// @notice Do not touch the endpoint of the network and choose to return to the net.
/// @dev Use override Implanting. fake backend;Every test is by itself. Forge Scattered quarantine.
contract ForkSelectionBackendTest is ForkTest {
    enum Scenario {
        None,
        FallbackToBLatest,
        StrictPinnedOnly,
        WrongChain
    }

    string internal constant A = "https://a.example";
    string internal constant B = "https://b.example";
    uint256 internal constant PINNED = 35_482_396;
    uint256 internal constant A_LATEST = 40_000_001;
    uint256 internal constant B_LATEST = 40_000_002;

    Scenario internal scenario;
    uint256 internal chainIdAttempts;
    uint256 internal pinnedStateAttempts;
    uint256 internal latestForkAttempts;
    uint256 internal latestStateAttempts;

    function test_firstReachableWithoutStateFallsThroughToBLatest() public {
        scenario = Scenario.FallbackToBLatest;

        string memory reason = _selectFork(_target(false));

        assertEq(reason, "", unicode"B latest Available, not return the skipping reason");
        assertEq(forkUrl, B, unicode"A It's... latest We must continue to try after the state fails. B");
        assertEq(forkHeight, 0, unicode"Selected B latest");
        assertEq(chainIdAttempts, 4, unicode"Nailed to heights and latest Both rounds should be asked. A,B");
        assertEq(pinnedStateAttempts, 2, unicode"A,B We should all be able to get to the height first.");
        assertEq(latestForkAttempts, 2, unicode"A latest We'll build it when we can't get it. B latest");
        assertEq(
            latestStateAttempts, 2, unicode"A,B Construction latest After that, we must look at the actual altitude."
        );
    }

    function test_strictModeStopsBeforeLatestAndReturnsTheSkipReason() public {
        scenario = Scenario.StrictPinnedOnly;

        string memory reason = _selectFork(_target(true));

        assertEq(reason, unicode"No endpoints to serve the height of nails, and FORK_STRICT_BLOCK=true");
        assertEq(latestForkAttempts, 0, unicode"Strict patterns are never built. latest Fork");
        assertEq(latestStateAttempts, 0, unicode"The strict pattern is never explored. latest Status");
    }

    function test_wrongChainFailsInsteadOfTryingTheNextCandidate() public {
        scenario = Scenario.WrongChain;

        // A (a) The reporting chain;B Script as success. If the wrong chain is swallowed, this call will be selected. B And return normally.
        try this.selectWrongChainTarget() {
            fail(unicode"The wrong chain must fail immediately. We can't continue to try. B");
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, unicode"It pointed to the wrong chain."),
                unicode"The reason for failure must be the chain. ID Not in line"
            );
        }
    }

    function selectWrongChainTarget() external {
        _selectFork(_target(true));
    }

    function _target(bool strictBlock) private pure returns (ForkTarget memory target) {
        target.name = "Robinhood Chain";
        target.chainId = ForkConfig.ROBINHOOD_CHAIN_ID;
        target.rpcUrls = new string[](2);
        target.rpcUrls[0] = A;
        target.rpcUrls[1] = B;
        target.blockNumber = PINNED;
        target.strictBlock = strictBlock;
        target.probe = ForkConfig.GME;
    }

    function _backendReachable(string memory url) internal override returns (bool) {
        chainIdAttempts++;
        return _is(url, A) || _is(url, B);
    }

    function _backendHasStateAt(string memory url, address, uint256 height) internal override returns (bool) {
        if (height == PINNED) {
            pinnedStateAttempts++;
            return scenario == Scenario.WrongChain;
        }

        latestStateAttempts++;
        return scenario == Scenario.FallbackToBLatest && _is(url, B) && height == B_LATEST;
    }

    function _backendCreateSelectFork(string memory url, uint256 height)
        internal
        override
        returns (bool, uint256, uint256)
    {
        if (height == 0) latestForkAttempts++;

        if (scenario == Scenario.FallbackToBLatest) {
            return (true, ForkConfig.ROBINHOOD_CHAIN_ID, _is(url, A) ? A_LATEST : B_LATEST);
        }
        if (scenario == Scenario.WrongChain) {
            return (true, _is(url, A) ? 1 : ForkConfig.ROBINHOOD_CHAIN_ID, PINNED);
        }
        return (false, 0, 0);
    }

    function _is(string memory left, string memory right) private pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
