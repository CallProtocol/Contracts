// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StockToken} from "./StockToken.sol";

/// @title IssuerPauseManagerStub
/// @notice bStocks **Pause Manager**The double... 26 Only bStock Common (decision-making) 53).
///
/// @dev Just the one thing the pool would read.`isTokenPaused(token)`),And one of them put it in.**I can't read.**The switch.
///      CRITICAL `*Raw` View for intercept modifiers inside the token:`viewsRevert` The simulation is "the issuer has upgraded the interface" and the issuer has been able to use the interface to create a new interface.
///      In that case, in token.**Transfer intercepts are working as usual.**,It's just that it's not reading out there -- and that's exactly what it is. fail-open
///      I'll buy it. 48 Reason for hour (%)`docs/spec.md`:The holder loses its right to exercise it in a window that is completely unauthorised).
///      If you intercept the inside, you'll be notified. revert It's... view Up, there's no way to build that one.
///
///      CRITICAL **The currency freeze and the global stoppage are falling. `isTokenPaused` This one is in the book.**  -  -  This is... BSC Main web site measurements:
///      Counterfeit `OPS_ROLE` Tranquility `pauseAllTokens()` The blogger says:`isTokenPaused(GMEB)` And then we'll all turn it together. `true`
///      (`docs/research/bsc-flap-portal-probe.md` 6.4).So here, too, is a model in the same language.
///      Ike didn't have to ask again. `allTokensPaused()`.
contract IssuerPauseManagerStub {
    error PauseManagerViewUnreadable();

    bool public viewsRevert;
    bool private _allPaused;
    mapping(address token => bool) private _paused;

    /// @notice The whole world is out of control. `pauseAllTokens` / `unpauseAllTokens`).
    function setAllTokensPaused(bool paused_) external {
        _allPaused = paused_;
    }

    /// @notice Single currency freeze (relative to real contract) `pauseToken` / `unpauseToken`).
    function setTokenPaused(address token, bool paused_) external {
        _paused[token] = paused_;
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function isTokenPaused(address token) external view returns (bool) {
        if (viewsRevert) revert PauseManagerViewUnreadable();
        return _allPaused || _paused[token];
    }

    function isTokenPausedRaw(address token) external view returns (bool) {
        return _allPaused || _paused[token];
    }
}

/// @title IssuerComplianceStub
/// @notice bStocks **Compliance module**Substitutes - Blacklist by Currency + Global sanctions list.
///
/// @dev CRITICAL **The key to the blacklist is... `(Currency, Address)` Two dollars.**,- Yeah. Robinhood That version is a little more than a dimension; the sanctions list is not related to tokens.
///      Both of them were read by the pool. `view`, By `viewsRevert` Break together -- real "sender upgrades to interfaces"
///      Not just one of them.
contract IssuerComplianceStub {
    error ComplianceViewUnreadable();

    bool public viewsRevert;
    mapping(address token => mapping(address account => bool)) private _blocked;
    mapping(address account => bool) private _sanctioned;

    function setBlocked(address token, address account, bool blocked_) external {
        _blocked[token][account] = blocked_;
    }

    function setSanctioned(address account, bool sanctioned_) external {
        _sanctioned[account] = sanctioned_;
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function blockedAddresses(address token, address account) external view returns (bool) {
        if (viewsRevert) revert ComplianceViewUnreadable();
        return _blocked[token][account];
    }

    function sanctionedAddresses(address account) external view returns (bool) {
        if (viewsRevert) revert ComplianceViewUnreadable();
        return _sanctioned[account];
    }

    function blockedRaw(address token, address account) external view returns (bool) {
        return _blocked[token][account];
    }

    function sanctionedRaw(address account) external view returns (bool) {
        return _sanctioned[account];
    }
}

/// @title IssuerGatedStockToken
/// @notice - Yeah.**Issuer Gate Control**The stock token double. Press. **bStock Today's shape**Modelling (decision-making) 53).
///
/// CRITICAL and {GatedStockToken} And the division of labour is clear:**Failed Injection**(A switch to transfer. revert,The blogger adds:
/// It says in its note, "not a model of door control," because... M1-5 The ticket. The door.**Semantics**Only the real contract on the fork can be measured.
///
/// This ticket.M1-6)Different:`pokeGating` It's a door control. view By itself, not by variable 4 It must be.**Local**Run!
/// (No variable test can rely on the network. So here's the shape:
///
/// | Built | Base (all 2026-09-08 BSC Main web site (based) |
/// |---|---|
/// | `pauseManager()` / `compliance()` Open readable. Address taken from tokens. | Yeah. GMEB Readback `0x9fc74Be6...700a` / `0x53dBa7Aa...14F4` |
/// | `isTokenPaused` A read-over single currency and a global set | `pauseAllTokens()` After `isTokenPaused(GMEB)` And I'll turn it over. |
/// | The blacklist is...**Compliance module**And key contains tokens | `blockedAddresses(GMEB, who)`;Directly to the tokens. revert |
/// | There's another one.**Global sanctions list** | `sanctionedAddresses(who)`  -  -  Robinhood There's no match on that page. |
/// | Every transfer route is blocked. | Really? `pauseToken` / `addToBlocklist` / `addToSanctionsList` After `transfer` Separate revert `TokenPaused()` / `UserBlocked()` / `UserSanctioned()` |
///
/// WARNING It's still just a double. See the real mark on the review. `docs/research/bsc-flap-portal-probe.md` 6.4,
/// And what's to be built. BSC Edit fork test.
contract IssuerGatedStockToken is StockToken {
    error IsPaused();
    error Blocked(address account);
    error Sanctioned(address account);
    error StockViewUnreadable();

    IssuerPauseManagerStub public immutable PAUSE_MANAGER;
    IssuerComplianceStub public immutable COMPLIANCE;

    /// @notice Jean.**The two addresses I read about. view** Disconnected (issuer upgrades to interface). Transfer interception is not affected.
    bool public viewsRevert;

    /// @notice Jean. `pauseManager()` Burn a lot. gas  -  -  It's a proof that "it's expensive to read." viewThe blogger says that the government is not going to be able to read the book.
    ///         Not being cleared, and not the whole pen of the caller. gas Eat up.
    uint256 public viewGasBurnRounds;

    constructor(IssuerPauseManagerStub pauseManager_, IssuerComplianceStub compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    /// @notice Freeze**This one.**(b) Currency (referred to manager, with the same path as the real contract).
    function setTokenPaused(bool paused_) external {
        PAUSE_MANAGER.setTokenPaused(address(this), paused_);
    }

    function setViewsRevert(bool enabled) external {
        viewsRevert = enabled;
    }

    function setViewGasBurnRounds(uint256 rounds) external {
        viewGasBurnRounds = rounds;
    }

    function pauseManager() external view returns (address) {
        if (viewsRevert) revert StockViewUnreadable();
        for (uint256 i = 0; i < viewGasBurnRounds; i++) {
            keccak256(abi.encode(i, address(this)));
        }
        return address(PAUSE_MANAGER);
    }

    function compliance() external view returns (address) {
        if (viewsRevert) revert StockViewUnreadable();
        return address(COMPLIANCE);
    }

    /// @dev The interceptor is... `*Raw`,"So, "view The price of the money is not working, but the currency is frozen."
    ///      Casting and destruction are not stopped -- otherwise the initial balance of testing itself cannot be put out during the freeze.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (PAUSE_MANAGER.isTokenPausedRaw(address(this))) revert IsPaused();
            if (COMPLIANCE.blockedRaw(address(this), from)) revert Blocked(from);
            if (COMPLIANCE.blockedRaw(address(this), to)) revert Blocked(to);
            if (COMPLIANCE.sanctionedRaw(from)) revert Sanctioned(from);
            if (COMPLIANCE.sanctionedRaw(to)) revert Sanctioned(to);
        }
        super._update(from, to, value);
    }
}

/// @dev A well-formed gating reader whose `pauseManager()` deliberately spends almost all of the forwarded budget.
///      It models only the two address views the pool reads; transfer semantics are irrelevant to this gas test.
contract NearBudgetIssuerGatedStockToken {
    IssuerPauseManagerStub public immutable PAUSE_MANAGER;
    IssuerComplianceStub public immutable COMPLIANCE;

    constructor(IssuerPauseManagerStub pauseManager_, IssuerComplianceStub compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    function compliance() external view returns (address) {
        return address(COMPLIANCE);
    }

    function pauseManager() external view returns (address) {
        // Leave enough gas for Solidity's ABI return path, while making a 50k-gas read genuinely near-budget.
        assembly ("memory-safe") {
            for {} gt(gas(), 7000) {} { pop(keccak256(0, 0)) }
        }
        return address(PAUSE_MANAGER);
    }
}

/// @dev A healthy compliance module whose `sanctionedAddresses` read  -  **the pool's fifth and last**  -
///      needs virtually the whole 50k forwarding budget. Putting the threshold on the final read keeps the
///      cold-call/EIP-150 boundary observable without weakening any of the preceding four.
contract FullBudgetIssuerCompliance {
    uint256 internal constant MIN_GAS_AT_ENTRY = 49_700;

    function blockedAddresses(address, address) external pure returns (bool) {
        return false;
    }

    function sanctionedAddresses(address) external view returns (bool) {
        if (gasleft() < MIN_GAS_AT_ENTRY) revert();
        return false;
    }
}

/// @dev A pause manager that always answers cheaply  -  the companion for {FullBudgetIssuerCompliance}.
contract AlwaysReadablePauseManager {
    function isTokenPaused(address) external pure returns (bool) {
        return false;
    }
}

/// @dev The companion token for {FullBudgetIssuerCompliance}. A full-budget final read succeeds, while a
///      silently EIP-150-capped final read reverts.
contract FullBudgetIssuerGatedStockToken {
    address public immutable PAUSE_MANAGER;
    address public immutable COMPLIANCE;

    constructor(address pauseManager_, address compliance_) {
        PAUSE_MANAGER = pauseManager_;
        COMPLIANCE = compliance_;
    }

    function pauseManager() external view returns (address) {
        return PAUSE_MANAGER;
    }

    function compliance() external view returns (address) {
        return COMPLIANCE;
    }
}
