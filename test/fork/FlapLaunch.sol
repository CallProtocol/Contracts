// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev Flap It's... VaultPortal Enter the currency. The field order is**Actual**Crucified: Take this. 27 Spell a field as tuple Signature,
///      Calculating Selector `0x1b806220`  In the chain  VaultPortal Achieved runtime Byte code in.
struct NewTokenV6WithVaultParams {
    string name;
    string symbol;
    string meta;
    uint8 dexThresh;
    bytes32 salt;
    uint8 migratorType;
    address quoteToken;
    uint256 quoteAmt;
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
    address vaultFactory;
    bytes vaultData;
}

interface IFlapVaultPortal {
    struct VaultInfo {
        address vault;
        address vaultFactory;
        string description;
        bool isOfficial;
        uint8 riskLevel;
    }

    function newTokenV6WithVault(NewTokenV6WithVaultParams calldata params) external payable returns (address token);
    function getVault(address taxToken) external view returns (VaultInfo memory info);
    function tryGetVault(address taxToken) external view returns (bool found, VaultInfo memory info);
    function vaultFactories(address factory)
        external
        view
        returns (bool enabled, bool official, uint8 riskLevel, bytes29 reserved);
    /// @dev `AUDITOR_ROLE` Exclusive:**Redo**Some kind of token. `token -> vault` Tie.
    function refreshTokenVault(address taxToken) external;
}

/// @title FlapLaunchTest
/// @notice Yes. Robinhood Chain Split it up.**Really, a guy with a vault. MEME** All the machines that are needed.
///
/// Every value taken is a real nail.`docs/research/flap-vault-identity-spike.md` 4 / 5 Remember the recalculation process.
/// The base class is drawn because it has two users, and the parameters should only have**One.**Source:
///
/// - `RobinhoodVaultIdentity.t.sol`(issue #23 Six judgments, needle factory)
/// - `RobinhoodCallVaultFactory.t.sol`(issue #37 The acceptance,**Real factory.**)
///
/// The two sides are each copy of the text.Flap One day, the red party is one, and the other will continue to run quietly.
/// No path has been established.
abstract contract FlapLaunchTest is ForkTest {
    address internal constant VAULT_PORTAL = ForkConfig.FLAP_VAULT_PORTAL;
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;
    address internal constant TAX_TOKEN_V3_IMPL = ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION;

    IFlapVaultPortal internal vaultPortal = IFlapVaultPortal(VAULT_PORTAL);

    uint256 internal _launchNonce;

    /// @dev CRITICAL **Every launch is a change of sponsors.** VaultPortal There are limits on the frequency of construction of the same address
    ///      (`RateLimitExceeded(user, lastCreationTime)` = `0xa7382e9b`,I've been hit.
    ///      The same sponsor sent it twice. The second time will be because**It's not about the evidence.**Reasons for red.
    function _launch(NewTokenV6WithVaultParams memory p) internal returns (address token) {
        address who = _freshLauncher();
        vm.prank(who, who);
        return vaultPortal.newTokenV6WithVault(p);
    }

    /// @dev CRITICAL **for two parameters `vm.prank`**:The frequency limit is... `tx.origin`,No, it's not. `msg.sender`.
    ///      Single Parameter Version Change only `msg.sender`,`tx.origin` Or is it? forge , and then**Second**
    ///      Fire will hit. `RateLimitExceeded(0x1804c8Ab..., ...)`  -  -  A thing that is not a witness,
    ///      The address is not a red light for any of the characters. It's been measured.
    function _freshLauncher() internal returns (address who) {
        who = makeAddr(string.concat("launcher-", vm.toString(_launchNonce++)));
        vm.deal(who, 10 ether);
    }

    /// @dev Robinhood Chain The only coin that's ever made it, five of which are measured dead by the actual tweak. {ForkConfig}
    ///      The three constant notes (where all errors are recorded by the other values).
    ///      Tax rates,`mktBps` and `taxDuration` Photo `docs/spec.md` the filling of launch parameters,
    ///      The road is akin to the real launch, not "just a set of parameters that can be used."
    function _params(address vaultFactory, bytes32 salt) internal pure returns (NewTokenV6WithVaultParams memory p) {
        p.name = "Spike Call Token";
        p.symbol = "SPIKE";
        p.salt = salt;
        // Original currency is not the only active currency; this is measured here VaultPortal Rewinding times, selecting it without the need to authorize or prepare for the originator.
        p.quoteToken = address(0);
        p.quoteAmt = 0;
        p.dexThresh = ForkConfig.FLAP_DEX_THRESH_SUPPORTED;
        p.migratorType = ForkConfig.FLAP_MIGRATOR_TYPE_V2;
        p.dexId = 0;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000; // 100 - Yeah, I'll see you. 6.1(WARNING No official example. 365  God
        p.mktBps = 10_000;
        p.tokenVersion = ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3;
        p.vaultFactory = vaultFactory;
    }

    function _mineVanitySalt() internal view returns (bytes32) {
        return _mineVanitySaltFrom(1);
    }

    /// @notice Dig one that will make you**It's a prediction.**Currency address `7777` End of line. salt.
    ///
    /// @dev CRITICAL **It's a theory, not a copy.**:
    ///      `predicted = CREATE2(Portal, salt, keccak(EIP-1167(TaxTokenV3Impl)))`  -  -
    ///      Attention to the deployment. **Portal**(No, it's not. VaultPortal),and salt Directly, no more Hashi.
    ///      Anti-description: two sets `(salt, Forecast Address)` Sample (in %2)`InvalidVanity(address)` They'll put the forecast address.
    ///      The candidates for deployment are on the same page.  Candidates salt Change to compare to the nearest one. Samples and recalculations
    ///      `docs/research/flap-vault-identity-spike.md` 4.
    ///
    ///      I'm not writing about one. salt:Initialize Hashi from**Current on Chain**The address of the realization is released.Flap I'm gonna change it.
    ///      This one's gonna change itself; it's gonna die. salt It'll be a sentence on that day. `InvalidVanity`,And the red light.
    ///      "And it pointed to thesalt "Expired." No, "No."Flap "The next floor, the next floor, the next round.
    ///
    ///      Expectations 2^16 It's a bit. It's a piece of a fixed one. scratch Description:`abi.encodePacked` Every round.
    ///      One memory, hundreds of thousands of rounds later. `MemoryOOG`(It was a real problem.
    ///
    ///      CRITICAL **I'm gonna dig up and see if that address's empty.** Low salt It's been used long ago. `salt = 0x2d76`
    ///      Corresponding `0x4ddc...7777` A token already lives on this chain. The launch will hit.
    ///      `TokenAlreadyStaged(address)`(`0x524b4af7`).So, the verdict adds one. `extcodesize == 0`:
    ///      Without it, these files will be kept low as others take over. salt And it rots slowly.
    ///      And the red light would say "encumbered" and not related to what they were asked to testify about.
    function _mineVanitySaltFrom(uint256 seed) internal view returns (bytes32 salt) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", TAX_TOKEN_V3_IMPL, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        address portal = PORTAL;

        assembly {
            let p := mload(0x40)
            mstore8(p, 0xff)
            mstore(add(p, 0x01), shl(96, portal))
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
}
