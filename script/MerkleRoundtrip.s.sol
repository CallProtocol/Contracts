// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "../test/helpers/FactoryStub.sol";
import {MemeToken} from "../test/helpers/MemeToken.sol";
import {StockToken} from "../test/helpers/StockToken.sol";
import {VaultStub} from "../test/helpers/VaultStub.sol";

/// @title MerkleRoundtrip
/// @notice `script/merkle-roundtrip.test.sh` It's...**One-time table.**:Put it on a local chain. issue #66 That one.
///         node Fine. root -> publisher - Uplink. -> The owner receives'all the pre-positions he needs to get through the road.
///
/// # Why is it a script, not a script? forge Test
///
/// And that which the check of the right hand is required,`forge test` It's not structurally proven:merkle It's... root and proof Yes.**Underlink node It's not.**,
/// And there's no external order in the test. `ffi` - No, I'm not. See you. `foundry.toml`).And... `test/MerkleDistributor.t.sol`
/// I can only use it. `test/helpers/MerkleTree.sol` Build a tree to drive. `claim`  -  -  The tree.**No, it's not.**The layout of the official library
/// (It doesn't sort, it floats up the odd-numbered layer, so it can prove the door to the contract is right, but it can't prove a word.
/// `offchain/merkle/build-root.js` The one who threw up. root And those. proof The contract is the only one that can be eaten."
///
/// There's only one roadway to that:**It's a real chain. It's a real chain. node It's not. root Send it up. I'll take it once.**.
/// This is the first part of the road. `script/merkle-roundtrip.test.sh` Lee.
///
/// # CRITICAL It's deliberate.**No, no.** setRoot
///
/// Release root Yes. `script/publish-root.sh` And the script is the one that's going to be tested. The table is going to be taken. root
/// Set it up. The only thing we can do is get a round-the-clock test. root We can take it ourselves  -  that's the cycle it's about to avoid.
/// So this script stops at the "Assence Certificate" distributor,The four holders were ready, but not belonging to them at this point.
///
/// # The border between the double and `test/MerkleDistributor.t.sol` Exactly.
///
/// It's really a four-contract. / Certificate / distributor / The double is only on the outside.
/// (Treasury, stock coins,MEME,- That's the test. `setUp` The Ree. helper,
/// No other. A new one is equal to a round-trip test to prove a single connection that only it uses.
///
/// ```bash
/// anvil --port 8547 --silent &
/// forge script script/MerkleRoundtrip.s.sol --rpc-url http://127.0.0.1:8547 \
///   --broadcast --slow --private-key 0xac09...ff80
/// ```
contract MerkleRoundtrip is Script {
    /// @dev anvil . Private key is**Public**..of the`anvil` It's on the screen when it starts. It's written in the version library.
    ///      It's not a leak -- but it's not gonna get into any real chain, see. {run} The opening one. chainid Door.
    ///
    ///      CRITICAL There's only a key. Use the address. `vm.addr` Now count. If both of them die, they'll float.
    ///      The log was playing A,And the drive is in hand. B "The key to sign" -- the kind of failure that looks like merkle Wrong.
    uint256 internal constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_PUBLISHER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    /// @dev Four holders (%)anvil #2..#5).The order is... `holder0..holder3`,and {AMOUNTS} One-on-one.
    uint256 internal constant PK_HOLDER_0 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_HOLDER_1 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_HOLDER_2 = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant PK_HOLDER_3 = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    /// @dev and `test/MerkleDistributor.t.sol` Number of groups: cast throughout the week distributor The amount,
    ///      **Just right.**That's four. leaf And the sum.
    ///
    ///      CRITICAL"The right thing is to be strong: make more, "distributor "and the balance of the balance of the balance of the unearned share of the balance of the sum of the unearned shares of the sum of the shares of the shares of the unearned."
    ///      You'll be unsensitive to mistakes because you have more than enough -- one over-rated. leaf And you can get away with it.
    ///      The drive has re-established this constant equation (it is possible to spell itself out and copy one wrong).
    uint256 internal constant MINTED = 100 ether;
    uint128 internal constant STRIKE = 1850e18;

    /// @dev It's not important what's on the local stage, it's important.**It's signed by the four holders.**
    ///       -  -  Right-of-the-way path `ClearingPool` It's just that the beneficiary has made a declaration.`attestedVersion != 0`).
    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev The machine can read output with a wide key. {_row}.
    uint256 internal constant KEY_WIDTH = 12;

    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    function run() external {
        // CRITICAL This one. require It's the only safe border in this document. It's deployed.**Test the double.**(One can be anyone. mint It's...
        //    MEME,One can be anyone. mint The shares are coins, the root of the identity of the factory that bypassed the real plant)
        //    Open private keys. Put on any real chain, get a set of things that look like us, but can be made by anyone.
        require(block.chainid == 31_337 || block.chainid == 31_338, unicode"Run only on local chains");

        address publisher = vm.addr(PK_PUBLISHER);
        uint256[4] memory holderKeys = [PK_HOLDER_0, PK_HOLDER_1, PK_HOLDER_2, PK_HOLDER_3];
        uint256[4] memory amounts = [uint256(40 ether), 30 ether, 20 ether, 10 ether];

        // CRITICAL The sum of the shares must be exactly the same as the amount of the cast. {MINTED}.Here's the thing.**This is the number in this file.**,
        //    It's on the compilation period constant; the drive is "so much of the chain." Both places.
        uint256 sum;
        for (uint256 i = 0; i < amounts.length; i++) {
            sum += amounts[i];
        }
        require(
            sum == MINTED,
            unicode"The sum of the four shares is not matched by the amount of the cast -- the table itself is not in touch."
        );

        _deploy(publisher);
        _prepareHolders(holderKeys);

        uint64 expiry = uint64(block.timestamp + 7 days);
        (uint256 seriesId, uint256 minted) = _openAndMint(expiry);
        require(
            minted == MINTED,
            unicode"The actual amount of the cast is not what it was expected - stock tokens should not be taxed."
        );

        _report(publisher, holderKeys, amounts, seriesId, expiry, minted);
    }

    //  Connect

    /// @dev Line Orders and `test/MerkleDistributor.t.sol::setUp` Line by line.
    ///
    ///      Two places. `setPool` ..the caller must be**The address of the satellite contract.**(`PoolBound.deployer`),
    ///      So they can't move to anything else. broadcast In the section -- that's the only part of the whole. signer Reason.
    function _deploy(address publisher) private {
        vm.startBroadcast(PK_DEPLOYER);

        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        call = new Call();
        distributor = new MerkleDistributor(publisher);
        factory = new FactoryStub();
        pool = new ClearingPool(call, address(distributor), registry, factory.registry());
        call.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        meme = new MemeToken();

        // I.D.'s registered with this one. MEME the vault of the... `openSeries` That's the binding.
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        vm.stopBroadcast();
    }

    /// @dev 6.4 The steps that the front end is going to direct users to do,**Everyone gives a real one with their own keys.**  -  -
    ///      No, it's not. `vm.prank`.These are the only two user sided forwards on the right path:
    ///
    ///      | This one. | Where would it stop without it? |
    ///      |---|---|
    ///      | `registry.attest(0, ...)` | `ClearingPool.exercise` The statement.**Beneficiaries**) |
    ///      | `meme.approve(pool, max)` | MEME Amount of authorization  -  CRITICAL - Authority to**Clearinghouse**,No, it's not. distributor |
    ///
    ///      MEME It's made by the deploying man. `mint` No permit) but authorization may only be signed by the person.
    function _prepareHolders(uint256[4] memory holderKeys) private {
        vm.startBroadcast(PK_DEPLOYER);
        for (uint256 i = 0; i < holderKeys.length; i++) {
            meme.mint(vm.addr(holderKeys[i]), 1e31);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < holderKeys.length; i++) {
            vm.startBroadcast(holderKeys[i]);
            registry.attest(0, TERMS_0, ATTESTATION_0);
            meme.approve(address(pool), type(uint256).max);
            vm.stopBroadcast();
        }
    }

    /// @dev Open the line. + I'll cast the entire week's license once and for all. distributor  -  -  This is the reason for sharing the balance.
    ///      `depositAndMint` After distributor I have it. 100 A mural, and a chain.**No information on affiliation.**.
    function _openAndMint(uint64 expiry) private returns (uint256 seriesId, uint256 minted) {
        vm.startBroadcast(PK_DEPLOYER);
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        minted = vault.depositAndMint(seriesId, address(distributor), MINTED);
        vm.stopBroadcast();
    }

    //  Output

    /// @dev Machine-readable. `key value` Okay, I'll give you a hand. `awk '$1 == "distributor" {print $2}'` Take Value  -
    ///      Same `script/DeployAttestationRegistry.s.sol` and `script/ci.sh` It's... attestation Group.
    ///
    ///      WARNING These addresses are...**Simulation phase**It's not from the chain.`forge script`  The script body is in
    ///      I ran away before any of the deals were issued. `script/verify-deployment.sh` Head.
    ///      So when the drive gets them,**Back to the chain one by one.**,Not for real.
    function _report(
        address publisher,
        uint256[4] memory holderKeys,
        uint256[4] memory amounts,
        uint256 seriesId,
        uint64 expiry,
        uint256 minted
    ) private view {
        _row("distributor", vm.toString(address(distributor)));
        _row("pool", vm.toString(address(pool)));
        _row("call", vm.toString(address(call)));
        _row("stock", vm.toString(address(stock)));
        _row("meme", vm.toString(address(meme)));
        _row("vault", vm.toString(address(vault)));
        _row("attestations", vm.toString(address(registry)));
        _row("publisher", vm.toString(publisher));
        _row("seriesId", vm.toString(seriesId));
        _row("expiry", vm.toString(uint256(expiry)));
        _row("strike", vm.toString(uint256(STRIKE)));
        for (uint256 i = 0; i < holderKeys.length; i++) {
            _row(string.concat("holder", vm.toString(i)), vm.toString(vm.addr(holderKeys[i])));
            _row(string.concat("amount", vm.toString(i)), vm.toString(amounts[i]));
        }
        _row("minted", vm.toString(minted));
    }

    /// @dev Left-System To {KEY_WIDTH},Value separated by one space.
    ///
    ///      CRITICAL Keys**It's a big one. revert**,Uninterrupted: Cutting will get a still-looking one. `key value` Okay,
    ///      And the drive. `awk '$1 == "..."'` They took off of value silently, so each of the following claims ran in a parallel to the air.
    function _row(string memory key, string memory value) private pure {
        bytes memory raw = bytes(key);
        require(
            raw.length <= KEY_WIDTH,
            unicode"Output key exceeding column width - cut will keep the drive silently to empty values"
        );

        bytes memory padded = new bytes(KEY_WIDTH);
        for (uint256 i = 0; i < KEY_WIDTH; i++) {
            padded[i] = i < raw.length ? raw[i] : bytes1(" ");
        }
        console2.log(string.concat(string(padded), " ", value));
    }
}
