// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VaultRegistry} from "../../src/VaultRegistry.sol";

/// @title VaultFactoryProbe
/// @notice issue #23 spike It's for you.**The needle factory.**:Shape `CallVaultFactory` I'm not sure if I'm going to be able to write.
///         But only four things -- no. VaultPortal,And build a minimum vault, and write a binding,**- Put it on. Portal It's coming in.
///         Write down every parameter as it is.**.
///
/// CRITICAL **It's not. M2-5(#37)The factory to deliver.** The form of a real plant depends on the vault template (in which the real plant is a model).#33)The results of the vote are as follows:
/// Write it now, and decide for the verdict before it is decided. The probe answers only one question:
/// **Real. VaultPortal Will you call us back? The one you've got on the switch. `(memeToken, vault)` "It's not credible."** -  -
/// That's the verdict. 1.
///
/// The most important thing that's ever written down is that {Recorded-taxTokenCodeSize}:Flap The rule is the vault.**Preselect**The name of the coin is "Create."
/// `taxToken` It's one. CREATE2 No bytes at that moment.
/// (`docs/research/flap-vault-identity-spike.md` 3).If this is true,
/// "Count the token."**Atomicity of the same deal**.The probe measured it out.
/// instead of quoting the document.
contract VaultFactoryProbe {
    /// @notice Flap It's... VaultPortal,Press `block.chainid` Take Value - with Flap In the norms.
    ///         `VaultFactoryBaseV2._getVaultPortal()` **Same way to write.**(Hard code, none setter).
    ///
    /// @dev CRITICAL This is not a construction parameter, but to keep the four-step construction sequence in the first place. 1 The steps are "constructively uninvolved":
    ///      Portal No, I'm not. `Plant <-> registry <-> I'm a pool.` The ring, making it a parameter doesn't untie it.
    ///      The government has been able to provide a new service to the government, but it is likely to fill the gap with one more place where the deployment period is wrong.
    ///
    ///      WARNING Value**Actual**No, not from... BSC The table is taken from:BSC It's... VaultPortal
    ///      `0x9049...` Yes. Robinhood Chain Go, go, go!**Zero bytes**.
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    address internal constant VAULT_PORTAL_ROBINHOOD = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

    /// @notice Identity root. One-time slot - only deployer, write once, and lock permanently (and {PoolBound} The same structure.
    VaultRegistry public registry;
    address public immutable deployer;

    /// @param caller            Back to the moment. `msg.sender`.The judgement 1 It's the one.
    /// @param taxToken          Portal It's ours. MEME Address
    /// @param quoteToken        Value
    /// @param creator           Original VaultPortal The man.
    /// @param vaultData         Treasury custom data
    /// @param taxTokenCodeSize  CRITICAL Turn back that moment. `taxToken` bytes the length.**0 = No tokens yet exist.**
    /// @param vault             We built the vault.
    struct Recorded {
        address caller;
        address taxToken;
        address quoteToken;
        address creator;
        bytes vaultData;
        uint256 taxTokenCodeSize;
        address vault;
    }

    Recorded internal _last;
    uint256 public callCount;

    /// @dev Unknown Selector Call(s)Portal The detection of an optional extension occurs) and is recorded here for for cross-test printing.
    ///      The probe will answer.Portal "What did we do?"**No, I can't.**Swallowed in silence.
    bytes4[] internal _unknownSelectors;

    error OnlyVaultPortal(address caller);
    error UnsupportedChain(uint256 chainId);
    error NotDeployer(address caller);
    error RegistryAlreadySet(address registry);
    error RegistryNotSet();

    constructor() {
        deployer = msg.sender;
    }

    //  One-time slot (the first of the tectonic rings) 4 Step)

    /// @notice Tie the roots of identity.**Only those who deploy, only once, and then forever lock to death.**
    /// @dev The only written action in the four-step construction order, and it falls**Plant**On this satellite...
    ///      registry The contract with the pool is therefore maintained on a zero-written path. {VaultRegistry} The contract head.
    function setRegistry(VaultRegistry r) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        if (address(registry) != address(0)) revert RegistryAlreadySet(address(registry));
        registry = r;
    }

    //  Flap Regulation:Portal The ones that do.

    /// @notice CRITICAL **The judgement 1 and the judgement 2 The intersection.** Portal Redirect here when the coin is built.
    ///
    /// @dev Signature from a factual:`newVault(address,address,address,bytes)` = `0x15b92d7a`,
    ///      Flap Your own. `IndexVaultFactory` Yes. Robinhood Chain Up against the wrong VaultPortal Call(s)
    ///      I'll be right back. `"Only VaultPortal"`(String require,It's not a custom error.
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault)
    {
        if (msg.sender != _vaultPortal()) revert OnlyVaultPortal(msg.sender);
        if (address(registry) == address(0)) revert RegistryNotSet();

        vault = address(new VaultStubForProbe(taxToken, quoteToken));

        _last = Recorded({
            caller: msg.sender,
            taxToken: taxToken,
            quoteToken: quoteToken,
            creator: creator,
            vaultData: vaultData,
            // CRITICAL **Count before writing binding**:The absence of a token deposit determines what the "credible binding" is to be based on.
            taxTokenCodeSize: taxToken.code.length,
            vault: vault
        });
        callCount++;

        // The judgement 3 The writings happen here, and only here.
        registry.bind(taxToken, vault);
    }

    /// @dev Normative requirements.Robinhood Chain The only active value is the original. `address(0)`.
    function isQuoteTokenSupported(address) external pure returns (bool) {
        return true;
    }

    /// @dev Normative v2.2+ The first thing I can do is check the hook before launching.Portal Use `staticcall` Tunnel.
    ///      Back `(false, reason)` It'll let the launch carry it. reason revert;If you don't have this option, you'll report it.
    ///      "Factory validation hook missing".The probe is always free.
    function onBeforeLaunch(bytes calldata) external pure returns (bool success, string memory reason) {
        return (true, "");
    }

    /// @dev As a declaration v2.3  -  -  If it's lower than that, `VaultBaseV3` + ERC20 The priced road is not working.
    function factorySpecVersion() external pure returns (string memory) {
        return "v2.3";
    }

    //  Read Record

    function last() external view returns (Recorded memory) {
        return _last;
    }

    function unknownSelectors() external view returns (bytes4[] memory) {
        return _unknownSelectors;
    }

    /// @dev CRITICAL **Don't swallow the unknown call, write it down.** The probe is half worth."Portal We have to be careful.
    ///      And a quiet one. fallback They'll wipe this half off. Back to empty. `bytes` Lets the optional extended detection press
    ///      "Not achieved," which is consistent with the actual factory's behaviour when it lacks that function.
    fallback() external {
        _unknownSelectors.push(msg.sig);
    }

    function _vaultPortal() internal view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return VAULT_PORTAL_ROBINHOOD;
        revert UnsupportedChain(block.chainid);
    }
}

/// @notice The smallest vault ever built by a probe. Only achieved. Portal The ones that read in the launch process.
/// @dev The real vault is... #33 The delivery; it's enough here -- not the treasury.
contract VaultStubForProbe {
    address public immutable taxToken;
    address internal immutable _quoteToken;

    constructor(address taxToken_, address quoteToken_) {
        taxToken = taxToken_;
        _quoteToken = quoteToken_;
    }

    /// @dev `VaultPortal.getVault()` Will read it.
    function description() external pure returns (string memory) {
        return "index-rein #23 spike probe vault";
    }

    /// @dev `VaultBaseV3`:The norm requires it.**No way. revert**,The price of the money is equal to the price of the currency served.
    function vaultQuoteToken() external view returns (address) {
        return _quoteToken;
    }

    receive() external payable {}
}
