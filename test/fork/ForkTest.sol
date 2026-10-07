// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ForkTarget} from "./ForkConfig.sol";

error RequiredForkUnavailable(string name, string reason);

/// @title ForkTest
/// @notice Fork test base category.
///
/// Single duties:**The government has also been able to provide a clear picture of the situation in the country.**
/// No web, no proof, no endpoint to historical status - Local default `vm.skip`,CI required (a) The clear failure of the model;
/// Endpoints point to the wrong chain, the fact on the chain is not consistent with the assertion - all fail.
///
/// Usage: in `setUp()` - The middle. `selectFork(...)`,Skipping will work on all tests of the contract.
abstract contract ForkTest is Test {
    /// @notice The security display of the actually selected endpoint is empty. No endpoint is selected.
    ///         For testing, it says, "Who's chosen? host,And even if it fails, it doesn't leak. path / query - In the evidence.
    string internal forkUrl;

    /// @notice The actual forklift to the height.`0` It means it's back. latest  -  -  That is, this operation cannot be repeated.
    uint256 internal forkHeight;

    /// @notice Create & & Select `target` delineated fork; press when environment is not available target Configure Skipping or Failed.
    ///
    /// The blogger says:**Every round finishes the list.**:
    ///   1. (a) Find an endpoint that can serve the height of the nailing - replicability has priority over linkage;
    ///   2. When you can't do it, you can't do it in a strict mode. latest .
    ///
    /// CRITICAL Both rounds must go through.**All**Candidate. Early versions will only remember "first responder" eth_chainId Other Organiser
    /// And take it to the first. 2 Wheel, then "first point report." chainId,The situation is limited, but the request is not allowed to flow.
    /// There's no point behind it that can be used -- the whole smoke cover of the fork is being thrown away silently.
    ///
    /// WARNING **Only `setUp()` or the test function calls directly.** This function is to be moved when the environment is not available `vm.skip`,
    /// And... `vm.skip` Only test level Effective - From Embedded external Call it in. Skipping it will become a piece.
    /// `skip can only be used at test level` It's... revert.It's really gonna drive it in a nested call.
    /// Use try/catch The caller must first check the top level before the condition is set.
    function selectFork(ForkTarget memory target) internal {
        string memory unavailableReason = _selectFork(target);
        if (bytes(unavailableReason).length != 0) _skip(target, unavailableReason);
    }

    /// @dev Selective strategies only; return reasons when environment is unavailable, not at this level `vm.skip`.
    ///      The test will inject. fake backend,The location of the call sequence and the cessation of the strict pattern is asserted.
    function _selectFork(ForkTarget memory target) internal returns (string memory) {
        if (target.rpcUrls.length == 0) {
            return unicode"Not configured RPC Peer";
        }

        bool anyReachable;

        //  I'm sorry. 1 Round: Crucified height
        if (target.blockNumber != 0) {
            for (uint256 i = 0; i < target.rpcUrls.length; i++) {
                string memory url = target.rpcUrls[i];
                if (!_reachable(url)) continue;
                anyReachable = true;
                if (!_hasStateAt(url, target.probe, target.blockNumber)) continue;
                if (_tryFork(target, url, target.blockNumber)) return "";
            }

            if (!anyReachable) {
                return unicode"All candidate ends are not connected. / Intercepted. / - No proof.";
            }
            if (target.strictBlock) {
                return unicode"No endpoints to serve the height of nails, and FORK_STRICT_BLOCK=true";
            }
            console2.log(
                string.concat(
                    unicode"[fork:",
                    target.name,
                    unicode"] WARNING No peer to serve height ",
                    vm.toString(target.blockNumber),
                    unicode",Back up. latest  -  -  This operation cannot be repeated"
                )
            );
        }

        //  I'm sorry. 2 Round:latest,And we'll finish the candidate as a matter of priority.
        for (uint256 i = 0; i < target.rpcUrls.length; i++) {
            string memory url = target.rpcUrls[i];
            if (!_reachable(url)) continue;
            anyReachable = true;
            if (_tryFork(target, url, 0)) return "";
        }

        return anyReachable
            ? unicode"Candidates can give a header but not a status (non-archiving nodes) / Status request restricted)"
            : unicode"All candidate ends are not connected. / Intercepted. / - No proof.";
    }

    /// @dev Try it. `url` Yes. `height`(`0` Organisation latest)Create a fork on it.
    ///      **Environmental causes**Return when Failed `false` Let the caller try next candidate;
    ///      CRITICAL Chain ID It doesn't match.**Configure Error**,It's a direct assertion of failure, and it's never going to be "to take the next."
    function _tryFork(ForkTarget memory target, string memory url, uint256 height) private returns (bool) {
        (bool created, uint256 chainId, uint256 actualHeight) = _backendCreateSelectFork(url, height);
        if (!created) return false;

        // forge Always nailing the split.**Specific**Altitude (even if it's passed on) latest).If the end is just a block
        // Without that altitude, the failure will be delayed until the first time in the middle of the test. storage Read it and blow it -- it was in the form of a...
        // Failure, not skip. Here it is converted to "for next candidate."
        if (!_hasStateAt(url, target.probe, actualHeight)) return false;

        assertEq(chainId, target.chainId, _wrongChainMessage(target, url));

        forkUrl = _safeUrl(url);
        forkHeight = height;

        console2.log(
            string.concat(
                "[fork:",
                target.name,
                "] chainId=",
                vm.toString(chainId),
                " block=",
                vm.toString(actualHeight),
                // The report is...**Actual**The mode to be taken, not the one in the configuration -- back latest After
                // Print as well "pinned" It's a replica of non-recurring operations.
                height == 0 ? unicode" (latest  -  -  Unrecoverable)" : " (pinned)",
                " via ",
                _safeUrl(url)
            )
        );
        return true;
    }

    function _skip(ForkTarget memory target, string memory reason) private {
        if (target.required) revert RequiredForkUnavailable(target.name, reason);
        vm.skip(true, string.concat("[fork:", target.name, "] ", reason));
    }

    /// @dev Chain ID When you're wrong, the word of this claim will be heard. forge Logging; never taking out URL path Medium key.
    function _wrongChainMessage(ForkTarget memory target, string memory url) internal pure returns (string memory) {
        return string.concat("[fork:", target.name, "] ", _safeUrl(url), unicode" It pointed to the wrong chain.");
    }

    /// @notice Secure end writing in log: Leave only scheme + host,Path,query,fragment Collapse All `/...`.
    ///
    /// @dev CRITICAL **- Yeah. key Once the endpoint is entered in the log as it is, the evidence is written in the log every time a fork is run.**
    ///      Archive endpoints must now be physically self-contained key(`https://.../v2/<KEY>` This shape, see. {ForkConfig}),
    ///      And this line log every time `selectFork` You can fight if you succeed.GitHub Actions I'll sign it up. secret Hit the number.
    ///      **But not locally.**  -  -  The most common leak route is "Apostille a log help".
    ///
    ///      No, I'm fine. key , so this is not a log change.
    ///      `forkUrl` Saves only the return value of this function, avoiding writing in the log when the test assertion fails.
    function _safeUrl(string memory url) internal pure returns (string memory) {
        bytes memory b = bytes(url);
        uint256 authorityStart;

        // URLs accepted by ForkConfig have `://`; find the first byte of their authority.
        for (uint256 i = 0; i + 2 < b.length; i++) {
            if (b[i] == 0x3a && b[i + 1] == 0x2f && b[i + 2] == 0x2f) {
                authorityStart = i + 3;
                break;
            }
        }

        if (authorityStart == 0) return url;

        uint256 authorityEnd = b.length;
        uint256 hostStart = authorityStart;
        for (uint256 i = authorityStart; i < b.length; i++) {
            if (b[i] == 0x40) hostStart = i + 1; // Drop URL userinfo too: it may be credentials.
            if (b[i] == 0x2f || b[i] == 0x3f || b[i] == 0x23) {
                authorityEnd = i;
                break;
            }
        }

        // No sensitive suffix or userinfo: preserve the historic display exactly.
        if (authorityEnd == b.length && hostStart == authorityStart) return url;

        bytes memory safe = new bytes(authorityStart + authorityEnd - hostStart);
        for (uint256 i = 0; i < authorityStart; i++) {
            safe[i] = b[i];
        }
        for (uint256 i = hostStart; i < authorityEnd; i++) {
            safe[authorityStart + i - hostStart] = b[i];
        }
        return string(abi.encodePacked(safe, unicode"/..."));
    }

    /// @dev is the peer reached. See only whether the call is not made, and do not resolve the return value.
    ///      Subcategory uses it as a precondition (jumping when the environment is not satisfactory, rather than giving the assertion a red light).
    function _reachable(string memory url) internal returns (bool) {
        return _backendReachable(url);
    }

    function _backendReachable(string memory url) internal virtual returns (bool) {
        try vm.rpc(url, "eth_chainId", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev End service `height` High**Status**.
    ///
    /// Read at the end of the fork. storage And you read accounts, and public ends are often restricted by method.
    /// (I've seen it at the same altitude. `eth_call`,But I did. `eth_getBalance` The blog is a blog that has been published by the Ministry of Information and Communications.
    /// So both of them find that either failure is deemed to be unavailable.
    function _hasStateAt(string memory url, address probe, uint256 height) internal returns (bool) {
        return _backendHasStateAt(url, probe, height);
    }

    function _backendHasStateAt(string memory url, address probe, uint256 height) internal virtual returns (bool) {
        string memory addr = vm.toString(probe);
        string memory blockTag = _hexQuantity(height);

        try vm.rpc(url, "eth_getStorageAt", string.concat('["', addr, '","0x0","', blockTag, '"]')) returns (
            bytes memory
        ) {}
        catch {
            return false;
        }

        try vm.rpc(url, "eth_getBalance", string.concat('["', addr, '","', blockTag, '"]')) returns (bytes memory) {}
        catch {
            return false;
        }

        return true;
    }

    /// @dev Default backend Use Foundry (b) Fork-building;fake Just... override These three. `_backend*` The hook.
    function _backendCreateSelectFork(string memory url, uint256 height)
        internal
        virtual
        returns (bool created, uint256 chainId, uint256 actualHeight)
    {
        if (height == 0) {
            try vm.createSelectFork(url) returns (uint256) {}
            catch {
                return (false, 0, 0);
            }
        } else {
            try vm.createSelectFork(url, height) returns (uint256) {}
            catch {
                return (false, 0, 0);
            }
        }
        return (true, block.chainid, block.number);
    }

    /// @dev revert Did it ever appear in the data? `needle`.Foundry The claim to use the belt selector The blogger says that the government is not a party to the law.
    ///      So choose the strategy test in the whole section. ABI Find out what's in the code, don't take anything. revert Consider it a success.
    function _revertMentions(bytes memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        if (n.length == 0 || haystack.length < n.length) return false;
        for (uint256 i = 0; i <= haystack.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (haystack[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /// @dev JSON-RPC It's... QUANTITY Encoding:`0x` The zeroing is partially rejected.
    function _hexQuantity(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0x0";

        bytes16 alphabet = "0123456789abcdef";
        bytes memory digits = new bytes(64);
        uint256 start = 64;
        while (value != 0) {
            start--;
            digits[start] = alphabet[value & 0xf];
            value >>= 4;
        }

        bytes memory out = new bytes(66 - start);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = start; i < 64; i++) {
            out[2 + i - start] = digits[i];
        }
        return string(out);
    }
}
