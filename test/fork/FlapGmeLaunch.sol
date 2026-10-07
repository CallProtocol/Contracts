// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {CallVault} from "../../src/CallVault.sol";
import {ForkConfig} from "./ForkConfig.sol";

/// @dev Flap `Portal` The entry of the coin (without the vault). Blockscout Go, go, go!**Authenticated**It's...
///      `Portal` Realistic `NewTokenV6Params`(`src/interfaces/IPortal.sol`).
///      Enumerated fields are written in all fields `uint8`  -  -  We just need the code right, not the type.
struct FlapNewTokenV6Params {
    string name;
    string symbol;
    string meta;
    uint8 dexThresh;
    bytes32 salt;
    uint8 migratorType;
    address quoteToken;
    uint256 quoteAmt;
    address beneficiary;
    bytes permitData;
    bytes32 extensionID;
    bytes extensionData;
    uint8 dexId;
    uint8 lpFeeProfile;
    uint16 buyTaxRate;
    uint16 sellTaxRate;
    uint64 taxDuration;
    uint64 antiFarmerDuration;
    uint16 mktBps;
    uint16 deflationBps;
    uint16 dividendBps;
    uint16 lpBps;
    uint256 minimumShareBalance;
    address dividendToken;
    address commissionReceiver;
    uint8 tokenVersion;
}

interface IFlapPortalLaunch {
    function newTokenV6(FlapNewTokenV6Params calldata params) external payable returns (address token);
}

/// @title FlapGmeLaunch
/// @notice Yes.**Real** Flap `Portal` One up. **GME Price** It's... `TOKEN_TAXED_V3`.
///
/// Everything in the fork test is "real." TWAP "Reading" is for one. GME It's priced. MEME:Nail the one on the height.
/// `PINNED_FLAP_TAX_TOKEN_V3_SAMPLE` Yes.**Original currency**We'll press the vault.
/// {PriceSource.QUOTE_MISMATCH} - Refuse it.`RobinhoodTwapSource.t.sol` There's a test to nail this thing.
///
/// @dev By `RobinhoodOpenSeries.t.sol` and `RobinhoodTwapSource.t.sol` Share. Besides real coins, both
///      And we share strict. 24 Hours TWAP ring ; only `RobinhoodVaultIdentity.t.sol` He's gone with the vault.
///      `newTokenV6WithVault`,Not the same entry point as this document.
abstract contract FlapGmeLaunch {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant FLAP_PORTAL_ADDRESS = ForkConfig.FLAP_PORTAL;
    address internal constant GME_ADDRESS = ForkConfig.GME;

    /// @dev Launch parameters. `docs/spec.md`(Trade in each other. 300 bps,Tax period 100 The government has a long history of taxing the government's tax revenues.
    uint16 internal constant LAUNCH_BUY_TAX_BPS = 300;
    uint16 internal constant LAUNCH_SELL_TAX_BPS = 300;
    uint64 internal constant LAUNCH_TAX_DURATION = 3_153_600_000;
    uint256 private constant LAUNCH_SALT_SEED_STRIDE = 7919;

    uint256 private _launchNonce;

    /// @notice One. GME It's priced. `TOKEN_TAXED_V3`,returns the token address.
    ///
    /// @dev CRITICAL **Every time we change the sponsors,**:Portal Right on the same one. `tx.origin` There is a limit on the frequency of construction money
    ///      (`RateLimitExceeded`),The same address was sent twice and the second was redacted for reasons unrelated to the content of the test.
    ///      for two parameters `vm.prank` It's necessary -- the limit is... `tx.origin`,No, it's not. `msg.sender`.
    function _launchGmeQuotedToken() internal returns (address token) {
        return _launchGmeQuotedToken("Call Series Probe", "WSERIES");
    }

    /// @dev Names and codes are customised to readability for testing; real Portal Path,salt Mining and the rotation of sponsors will be here.
    function _launchGmeQuotedToken(string memory name, string memory symbol) internal returns (address token) {
        FlapNewTokenV6Params memory params;
        params.name = name;
        params.symbol = symbol;
        params.salt = _mineVanitySaltFrom(1 + _launchNonce * LAUNCH_SALT_SEED_STRIDE);
        params.quoteToken = GME_ADDRESS; // CRITICAL The whole article TWAP The premise of the chain is in this line of business.
        params.quoteAmt = 0;
        params.beneficiary = vm.addr(uint256(keccak256(abi.encodePacked("beneficiary", _launchNonce))));
        params.dexThresh = ForkConfig.FLAP_DEX_THRESH_SUPPORTED;
        params.migratorType = ForkConfig.FLAP_MIGRATOR_TYPE_V2;
        params.dexId = 0;
        params.buyTaxRate = LAUNCH_BUY_TAX_BPS;
        params.sellTaxRate = LAUNCH_SELL_TAX_BPS;
        params.taxDuration = LAUNCH_TAX_DURATION;
        params.mktBps = 10_000;
        // When a currency is not original, the cents of the currency must be given in a visible form (in the case of a non-original currency).`DividendTokenMustEqualQuoteToken()`).
        params.dividendToken = GME_ADDRESS;
        params.tokenVersion = ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3;

        address who = vm.addr(uint256(keccak256(abi.encodePacked("gme launcher", _launchNonce++))));
        vm.deal(who, 10 ether);
        vm.prank(who, who);
        token = IFlapPortalLaunch(FLAP_PORTAL_ADDRESS).newTokenV6(params);
    }

    /// @dev Portal Requesting a token address `7777` The end, so we'll have to dig one first. salt.The token is the smallest agent left.
    ///      (EIP-1167)+ CREATE2,The initialization code is thus fully predictable.
    function _mineVanitySaltFrom(uint256 seed) internal view returns (bytes32 salt) {
        address implementation = ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION;
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        address portalAddress = FLAP_PORTAL_ADDRESS;

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

    /// @dev Portal The moment the token is in the camera.
    function _tokenState(address token) internal view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(FLAP_PORTAL_ADDRESS).getTokenV8Safe(token);
    }

    /// @dev Generate Strict trailing 24h Overwrite: Empty Encyclopedia t0..t24 Total 25 bars; only fill in initial samples when available 24 Article.
    ///      Time stamp reading in turn is necessary to maintain the hourly sampling discipline achieved by production.
    function _fillTwapRing(CallVault vault, address sampler) internal returns (bool) {
        uint256 writes = vault.lastSampleAt() == 0 ? 25 : 24;
        for (uint256 i = 0; i < writes; i++) {
            if (vault.lastSampleAt() != 0) vm.warp(block.timestamp + 1 hours);
            vm.prank(sampler);
            if (!vault.sampleTwap()) return false;
        }
        return true;
    }
}
