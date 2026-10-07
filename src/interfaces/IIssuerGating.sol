// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title IIssuerGating
/// @notice I'm a pool.**Read it.**Three external shapes used for the distribution door control - **BSC / bStocks Version**(Decision-making 53).
///
/// This is not the "interface we ask for the stock tokens" -- the pool is open for any stock tokens.`openSeries` The blogger says:
/// And the three signatures describe **bStocks Today's appearance**(Read it on the chain and check it out. See below).
/// The term "readable" is used to use the word "readless" for the use of unreadable tokens.fail-open + 48h Lend) , not "uncompliant" --
/// Full semantics {ClearingPool-pokeGating} and `docs/spec.md`.
///
/// CRITICAL **Don't write it. `ClearingPool` It's... `import` Anything else.** The pool calls them and they walk.
/// Low Layer `staticcall`(It has to swallow. revert),There's only one point to exist: let the chooser have it.**One.**
/// It's not a contract. `bytes4` Literally.
///
/// # CRITICAL and Robinhood The comparison of the version. `feature/bsc` Branches replaced by whole)
///
/// Robinhood `Stock` Three entrances to the bStock Go, go, go!**None of them exist.**  -  -  `paused()` and
/// `ACCESS_CONTROLLED_REGISTRY()` Direct revert.But... BSC Go, go, go!**Yes.**The first of these is the "Standards" of the government, which is the "Standards of the Nation" (Standards of the Nation).
/// It's just a different name:
///
/// | Semantics | Robinhood `Stock` | **bStocks((In this document)** |
/// |---|---|---|
/// | Has the token been frozen? | `stock.paused()` | `stock.pauseManager().isTokenPaused(stock)` |
/// | Where's the central access entrance? | `stock.ACCESS_CONTROLLED_REGISTRY()` | `stock.compliance()` |
/// | Did you get stopped at some address? | `registry.isBlocked(pool)` | `compliance.blockedAddresses(stock, pool)` **+** `compliance.sanctionedAddresses(pool)` |
///
/// The difference in shapes is worth remembering:
///
/// - **Blacklists are a little bit more than that.** Robinhood the key is the address;bStocks Yes. `(Currency, Address)` Two dollars, another one.**Global**
///   Sanctions list. So the pool went from three readings to one.**Five.**Read.
/// - **The whole thing is in the same reading.** Robinhood It's... `paused()` I'll be back.
///   `Hold on to your currency. || Global suspension of registration forms`;bStocks It's... `pauseAllTokens()` Actual**Will let
///   `isTokenPaused(stock)` And then we'll all turn it together. true**,So one reading over two sets -- this is the conclusion, not the inference.
///
/// @dev 2026-09-08 Yes. BSC Main online pairing GMEB `0x46cE...b15C` Read it in fact:
///      `pauseManager() = 0x9fc74Be6...700a`,`isTokenPaused(GMEB) = false`,
///      `compliance() = 0x53dBa7Aa...14F4`,`blockedAddresses(GMEB, Any) = false`,
///      `sanctionedAddresses(Any) = false`.26 Only bStock **Shared**Same. compliance and pauseManager.
///
///      CRITICAL **The behavioral surfaces have been checked, not just the interface.**:You're gonna be the real part of the chain. `pauseToken` /
///      `pauseAllTokens` / `addToBlocklist` / `addToSanctionsList` The blogger says:`transfer` Separate revert
///      `TokenPaused()` / `UserBlocked()` / `UserSanctioned()`,And...**These five are in every freeze.
///      Still read all of them.**(`readable = true`,`hit = true`) -  -  fail-open It doesn't make any mistake about the real freeze.
///      "No freeze." That's the decision. 53 The idea is to use the word "synthetic" instead of "accept the status quo" as a whole.
///      Source:`docs/research/bsc-flap-portal-probe.md` 6.3 / 6.4.
interface IIssuerGatedStock {
    /// @notice The token's the pauser.
    ///
    /// @dev CRITICAL **The address is read from the token itself, not written in the pool.** The pool is not upgraded. Write down an manager's address.
    ///      It's like assuming that there's always only one system of issuer privileges on this chain -- and that assumption can never be changed once it's expired.
    ///      (and Robinhood Version `ACCESS_CONTROLLED_REGISTRY()` (The same ground.)
    function pauseManager() external view returns (address);

    /// @notice Compliance module for the token (where the currency-by-currency blacklist and the global sanctions list are located).
    /// @dev Idem: Address from token.
    function compliance() external view returns (address);
}

/// @notice The one that the distributor's pause manager, the pool, reads.
///
/// @dev Freezing of Mono-currency (Female)`pauseToken`)And the whole world is out of control.`pauseAllTokens`)**It's all in this reading.**  -  -
///      Actual:`pauseAllTokens()` After `isTokenPaused(GMEB)` And then we'll all turn it together. `true`.
///      So I don't have to ask him again. `allTokensPaused()`;One more reading will only fail to call externally once more.
interface IIssuerPauseManager {
    function isTokenPaused(address token) external view returns (bool);
}

/// @notice The two functions that the distributioner is reading on the compliance module, the pool.
///
/// @dev CRITICAL Ikeko asked. **I'm the one who's got the pool.**(`address(this)`),Not the beneficiary.
///      The pool is still clean, so...**No extension to occur**:One address should not be blocked to allow the entire series to be extended.
///      It's a deliberate trade-off, but it's a real and irreversible user loss. `docs/spec.md`.
///
///      WARNING **Don't use it. `checkIsCompliant` When the door handles the hook.** It's... revert "Standed."
///      (`UserBlocked()` / `UserSanctioned()`),And here's what we want.**No, no. revert Number of readings**;
///      And its real signature is... `(address token, address user)`,and `msg.sender` Not relevant...
///      First press. `(from, to)` The assumption is no longer read.6.4 The project is designed to be a combination of different types of projects.
interface IIssuerCompliance {
    /// @notice Blacklist by Currency. The key is `(Currency, Address)` Two dollars -- comparison Robinhood That's a dimensional version.
    function blockedAddresses(address token, address account) external view returns (bool);

    /// @notice The global sanctions list is not related to tokens.
    function sanctionedAddresses(address account) external view returns (bool);
}
