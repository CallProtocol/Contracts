// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICall} from "./ICall.sol";

/// @title IClearingPool
/// @notice The clearing pool.**All**It's a foreign writing portal -- six, not many; plus two satellite contracts. view.
///
/// This is the "No" line. admin,None pause,None withdraw,None upgradeIt's a code:
/// The pool is non-upgradable, one in each chain, and the only user-deposit claim, so its functional set is**Freeze**Yeah.
/// There are three uses for separate documents:
///
/// - `MerkleDistributor` It's... `claimAndExercise` I'm gonna have to change it as part of this contract. `exercise`(M1-8,issue #13);
/// - Six signatures have an authoritative source, dispersing. M1-4...M1-7 Four tickets are not separate;
/// - It's the "just six" assertion.**Bottom**:Compiler forces the person who achieves at least six functions and the signature is not different.
///   (no seventh) ABI To assert, see. `test/ClearingPool.t.sol`.The two sides together are "just as well".
///
/// WARNING {call} and {seriesIdOf} Yes. **view / pure**,So they're not in the "just six" count...
/// That's what it says.**Writable** The entrance, and  ABI And the count is just as it is. `stateMutability` Filtered (see `test/helpers/WriteSurface.sol`).
/// Both of them are applied on two occasions on the same ground:**A value must be stated in both contracts at the same time, and it should have only one source.**
///
/// - {call}:M1-8 It's... `claim` I'm transferring the license. leaf Assigned account,And there's only one authority source for the address of the certificate of authority...
///   The one from the pool. `immutable`.distributor If you save another one, it will be an extra road to drift.
/// - {seriesIdOf}:M2-3 It's... `CallVault.processRevenue()` To figure out which series it should be in today.
///   The same Hash formula is copied twice, and one will float -- and the consequence is that the vault deposits the money into one.**Cannot initialise Evolution's mail component.**Series
///   (`SeriesNotOpen`,"Inventory in the vault" or worse, in the vault.**Someone else.**The series.
///
/// CRITICAL **Add a writingable function to this interface, which is equal to adding a port to a non-upgraded hosting contract.** See `docs/spec.md`.
interface IClearingPool {
    /// @notice Certificate of Rights (Certificate)ERC-1155).The pool is the only casting and destroying party.
    /// @dev Here. `MerkleDistributor` With:`claim` We're gonna transfer the certificate as the holder of this contract. account.
    function call() external view returns (ICall);

    /// @notice Series identifier:`keccak256(abi.encode(memeToken, stockToken, expiry))`,It's also a call. ERC-1155 id.
    /// @dev Here. `CallVault` And the only authoritative answer to the question of which line to save this week is to use the service below the chain.
    ///      WARNING It's not supposed to be the other way around.`test/ClearingPoolMinting.t.sol` A self-determined expectation.
    function seriesIdOf(address memeToken, address stockToken, uint64 expiry) external pure returns (uint256);

    /// @notice Opens a new series and locks down the right price. The same series.**It's only open once.**,The right-to-hand price is not subject to change thereafter.
    ///
    /// @dev CRITICAL **Just... MEME The vaults registered in the identity base are retraceable.**(`msg.sender == vaultRegistry.vaultOf(memeToken)`
    ///      It's not zero. It's the only one who can do it. `depositAndMint`.The roster is our own one that we can't change;
    ///      The immutable writer is `CallVaultFactory`, which creates and binds
    ///      the vault in the official VaultPortal launch transaction.
    ///      issue #23 I've got six separate sentences. A((d) Set the target; the connection between the achievement and deployment is issue #37.
    ///      I'll see the whole thing. {ClearingPool}  The contract notes and `docs/research/flap-vault-identity-spike.md`.
    ///
    /// @param memeToken   The tokens destroyed during the exercise of power.**Also an identity root query key**  -  -  One. MEME There's only one legal vault.
    /// @param stockToken  Mortgages.
    /// @param expiry      The product is calibrated on Friday. 21:00 UTC,But...**The pool doesn't explain the value.**
    /// @param strike      Right-of-hand price: per cent **1e18 raw Units**Stock tokens need to be destroyed. MEME(raw).
    ///                    Right-of-the-hand formula `memeAmount = amount * strike / 1e18`(- Take it down. See. {exercise}
    /// @return seriesId   `keccak256(abi.encode(memeToken, stockToken, expiry))`
    function openSeries(address memeToken, address stockToken, uint64 expiry, uint128 strike)
        external
        returns (uint256 seriesId);

    /// @notice The collateral is deposited and the equivalent certificate is forged.
    /// @param seriesId        Series
    /// @param to              Authorisation recipient (%)`MerkleDistributor`)
    /// @param expectedAmount  Request for deposit
    /// @return minted         Actual Casting = I'm a gill.**Increase in balance**((Direct currency less than request)
    function depositAndMint(uint256 seriesId, address to, uint256 expectedAmount) external returns (uint256 minted);

    /// @notice Right to: destruction of the certificate of authority + Destruction of beneficiaries MEME + Stock tokens transferred to beneficiaries, atomic execution.
    ///
    /// @dev CRITICAL **Only the beneficiary himself or herself `MerkleDistributor` It's defunct.** MEME The mandate says, "I'm willing to do it for myself."
    ///      "Everyone can choose me when."
    ///      CRITICAL **Statement of doorcheck `beneficiary`,Do not check the caller**  -  -  Otherwise... distributor The right path to the right of option (in the case of theissue #13)
    ///      The door is empty. {ClearingPool-exercise}.
    ///      MEME It has to be from beneficiary **Just the right amount.**Results of pricing formulae, but no requirements `0xdead` (b) Full collection;
    ///      Stock tokens must come from the pool.**Just the right amount.** `amount`,But it's allowed. beneficiary Less collection due to receipt of tax.
    ///
    /// @param seriesId     Series
    /// @param amount       Right of line (in the case of rights)raw (a) Stock tokens) and the number of weights destroyed.
    ///                     Destroyed MEME Yes `amount * strike / 1e18`(removing down;to 0 The government has been unable to provide any information on the situation.
    ///                     Otherwise, it's a token of the stock. `uint128` The amount of the goods is rejected.
    /// @param beneficiary  Beneficiaries - Statement of door-to-door inspection,MEME Pulling it from him, taking stock coins straight to him.
    function exercise(uint256 seriesId, uint256 amount, address beneficiary) external;

    /// @notice Watch and record the issuer's door control status of the stock token.**Flip**.Anyone can be called.
    ///
    /// @dev CRITICAL `clearedAt` Only**Leave**Door control (or**Enter**This side is written on. Every time "clean" poke
    ///      If you write, anyone will. 47 One shift an hour can push it all the way... `settleExpired` Permanent revert,
    ///      And the series that the attackers should have had was taken out.**Free and indefinite extension**.See the complete tri-state transfer form. {ClearingPool-_observe}.
    ///      CRITICAL Sufficient performance must be retained before each internal reading gas:Get healthy. view Starvation is one side. This is the reading threshold.
    ///      It's not a whole deal. gas limit;Monitor As in actual sender,calldata Execute with Call Packaging Path
    ///      `eth_estimateGas` And leave a balance.
    function pokeGating(address stockToken) external;

    /// @notice The maturity settlement (inertity, anyone can adjust). The door control period is structurally blocked -- that's "automated delay".
    ///
    /// @dev Internal observation (self-rehabilitation old records) and request real time doorless and past deadline,
    ///      - It's just a matter of time. `settled = true`,`remainder = deposited  exercised`.
    ///      WARNING That observation was only closed.**Success** I'll stay on the chain; I'll give you a broad clock, turn  {pokeGating}.
    function settleExpired(uint256 seriesId) external;

    /// @notice Pool rolling: crediting the balance of the settled series in the subsequent series and casting the certificate to the distributor.Anyone can be called.
    ///
    /// @dev CRITICAL Mortgages.**Never leave the pool.**  -  -  There was no transfer in the call, and the balance of the stock in the pool remained constant.
    ///      (No Variable 7).It's a pool re-entry. It doesn't constitute a transfer. It doesn't have a variable. 5 The wording relies on this.
    ///
    ///      **No permission**,Because all six doors can be self-proved by the pool: the front line is open, settled,`remainder != 0`;
    ///      Then it's started. `strike != 0`),Same (MEME, Stock tokens) Yes, outstanding and `now < expiry`.
    ///      Full reason and residual exposure (lawful follow-up specified by caller, see issue #21 / #23)See {ClearingPool-rollExpired}.
    ///
    ///      WARNING Clean up when no follow-up series available revert,The rest of the amount is parked in the pool -- creating a new series that will expire in the future will be restored.
    ///      **There was only delay, no loss.**
    ///
    /// @param seriesId      Cleared front series
    /// @param nextSeriesId  Follow-up series - Certificate cast `distributor`,The amount equals the previous order `remainder`
    function rollExpired(uint256 seriesId, uint256 nextSeriesId) external;
}
