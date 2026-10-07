// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {PoolBound} from "../src/PoolBound.sol";
import {Call} from "../src/Call.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {MerkleTree} from "./helpers/MerkleTree.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice CRITICAL **Counter-argument. distributor:The only difference with real realization is the omission of the logo.**
///
/// The only reason it exists is to prove it."distributor The balance of the certificate of authority is never less than the total amount not received leaf "and the sum of the two."
/// **I can really catch it.**The attack -- a claim that is always true and a correct one looks exactly like it.
/// Same `test/invariant/` Down `LeakyPool` / `OvermintingPool`:**Counter-argument is not a double.**,
/// It doesn't pretend to be anything we're going to release, it's just for a probe that has to be red.
///
/// @dev Both entrances are authentic, but neither is checked nor written. `claimed`  -  -  That's it. issue #13 That's the loophole in the picture.
contract ForgetfulDistributor is PoolBound, ERC1155Holder {
    mapping(uint256 seriesId => bytes32 root) public roots;

    function setRoot(uint256 seriesId, bytes32 root) external {
        roots[seriesId] = root;
    }

    function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external {
        _verify(seriesId, account, amount, proof);
        IERC1155 book = IERC1155(address(IClearingPool(pool).call()));
        book.safeTransferFrom(address(this), account, seriesId, amount, "");
    }

    function claimAndExercise(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external {
        require(msg.sender == account, "not account");
        _verify(seriesId, account, amount, proof);
        IClearingPool(pool).exercise(seriesId, amount, account);
    }

    function _verify(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) private view {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))));
        require(MerkleProof.verify(proof, roots[seriesId], leaf), "bad proof");
    }
}

/// @notice One.**Contractual status**The holder of the card, call again in the back of the card. `claim`.
/// @dev Reconciling must take the inner layer to failure.**Swallow it and write it down.**:If the outer layer does not swallow, then the backsliding will not see the reason why the inner layer is rejected.
contract ReclaimingWallet is ERC1155Holder {
    MerkleDistributor public distributor;
    bytes public armedCall;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryError;

    function arm(MerkleDistributor distributor_, bytes calldata call_) external {
        distributor = distributor_;
        armedCall = call_;
    }

    function claim(uint256 seriesId, uint256 amount, bytes32[] calldata proof) external {
        distributor.claim(seriesId, address(this), amount, proof);
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes memory data)
        public
        override
        returns (bytes4)
    {
        if (armedCall.length != 0 && !reentered) {
            reentered = true;
            (bool ok, bytes memory ret) = address(distributor).call(armedCall);
            reentrySucceeded = ok;
            reentryError = ret;
        }
        return super.onERC1155Received(operator, from, id, value, data);
    }
}

/// @notice **M1-8 Receipts + Right to merge lines**(issue #13).
///
/// This ticket is not delivered as "two convenience functions" but as a structure:**This contract is in the possession of another person's license.**,
/// And the same one. merkle leaf There are two consumption points on the top. The missing sign is not "repeated" for the "repeated share."
/// It's stealing from the shared balance -- the caller pays for himself. MEME,The shares have been taken from the recipients who have not yet received them.
///
/// So the focus of this paper is not on the path to success, but on four things:
///
/// - **Both paths are one and the same.**,Four-direction complete (Gymmetrical)claim2,c&e2,claim->c&e,c&e->claim);
/// - **The balance of the certificate of authority is never less than the total amount not received leaf The sum of the two.**  -  -  The direct line of defense for the attack, certainty and fuzz One by one,
///   Plus one. CRITICAL **Counter-argument**({ForgetfulDistributor})The claim is proven to have been fulfilled by missing signage;
/// - **The license levels for both paths are different.**:`claim` No permit, no permit.`claimAndExercise` (a) In person only;
/// - **Statement of the beneficiaries of the door check**,So, undeclared `account` Yes. distributor The same is true of the path.
///
/// Test drive for real four contracts (issue #5 The only ones that appear outside are vaults, stock coins, stock coins, stock exchange bonds, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock exchange, stock, stock exchange, stock, stock exchange, stock, stock exchange, stock, stock exchange, stock, stock, stock, stock, stock, stock, stock, stock, stock, stock, stock, and stock exchange, stock, stock, stock, and stock value, stock, and stock value, and stock value, value, and stock value, value, and stock value, value, value, value value, value, value, value, value value, value, value, value, value,MEME.
/// The real mark is in the right place. `test/fork/RobinhoodDistributor.t.sol`.
contract MerkleDistributorTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    uint64 internal expiry;
    uint256 internal seriesId;

    uint128 internal constant STRIKE = 1850e18;

    /// @dev A week of casting. distributor The amount of the -- it's exactly four. leaf And the sum.
    ///      The idea that the balance is not available is not sensitive.
    uint256 internal constant MINTED = 100 ether;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    address internal publisher = makeAddr("publisher");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    /// @dev The order is leaf Order.
    address[4] internal accounts;
    uint256[4] internal amounts;

    /// @dev Test the "which one" you're maintaining. leaf The government has already consumed it."
    ///      CRITICAL **No contract. `claimed`**:That's the balance. >= "The sum not received" will be defined by the client's own account.
    ///      "Not received," and the omission of the mark is true under this claim -- see {ForgetfulDistributor}.
    bool[4] internal consumed;

    function setUp() public {
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
        expiry = uint64(block.timestamp + 7 days);

        // I.D.'s registered with this one. MEME The vault... the one that opened the series... that tied it up, see? {FactoryStub}.
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave")];
        amounts = [uint256(40 ether), 30 ether, 20 ether, 10 ether];

        for (uint256 i = 0; i < accounts.length; i++) {
            _prepare(accounts[i]);
        }

        // The whole week's license is cast once and for all. distributor  -  -  This is the reason for sharing the balance.
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), MINTED);

        vm.prank(publisher);
        distributor.setRoot(seriesId, MerkleTree.root(_leaves(seriesId)));
    }

    //  Scaffolding.

    /// @dev 6.4 The steps that the front end of the room is going to direct the user to: sign a statement, put it on the table. MEME - Authority to**Clearinghouse**(No, it's not. distributor).
    function _prepare(address who) internal {
        vm.prank(who);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        vm.prank(who);
        meme.approve(address(pool), type(uint256).max);
        meme.mint(who, 1e31);
    }

    function _leaves(uint256 series) internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            leaves[i] = MerkleTree.leafOf(series, accounts[i], amounts[i]);
        }
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory) {
        return MerkleTree.proofFor(_leaves(seriesId), i);
    }

    function _expectedMeme(uint256 amount) internal pure returns (uint256) {
        return (amount * STRIKE) / 1e18;
    }

    /// @dev Those that haven't been consumed yet. leaf The sum of the sum of the distributor Right now.**I'm in debt.**The certificate.
    function _unclaimed() internal view returns (uint256 total) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!consumed[i]) total += amounts[i];
        }
    }

    /// @dev CRITICAL **The core of the note.**:The trust card will always hold everything that hasn't been taken away. leaf.
    ///      It's set up after every change of state -- so every test down there is right after the action.
    /// @param book   The certificate contract. The test ran on another system, so it was a parameter, not a field.
    /// @param holder Host (%2)distributor)
    function _assertCustodyCoversUnclaimed(Call book, address holder, uint256 series) internal view {
        assertGe(
            book.balanceOf(holder, series),
            _unclaimed(),
            unicode"CRITICAL distributor Balance of certificates less than uncollected leaf And the sum of the shares that someone took from the share."
        );
    }

    /// @dev The one on the real system, two parameters that are the same every time.
    function _assertCustodyCoversUnclaimed() internal view {
        _assertCustodyCoversUnclaimed(call, address(distributor), seriesId);
    }

    function _claim(uint256 i) internal {
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[i], amounts[i], _proof(i));
        consumed[i] = true;
    }

    function _claimAndExercise(uint256 i) internal {
        vm.prank(accounts[i]);
        distributor.claimAndExercise(seriesId, accounts[i], amounts[i], _proof(i));
        consumed[i] = true;
    }

    //  Shape: Externally write to the six

    /// @dev and `ClearingPool` The same source (`test/ClearingPool.t.sol`):**Read and compile the product. ABI**,
    ///      Instead of going over the functions you know. Then you add them. `sweepCalls()` It's not because
    ///      No test called it and it's not working -- and the contract is being held by**All users not received**A witness,
    ///      It's one more size to write, and one more size to the pool.
    ///
    ///      Two. `onERC1155*Received` Press ERC-1155 The norm is right and wrong. view So they're on this list.
    ///      They do not constitute an entrance: nothing but return to magic.
    function test_writeSurface_isExactlySixFunctions() public view {
        string[] memory expected = new string[](6);
        expected[0] = "setPool(address)";
        expected[1] = "setRoot(uint256,bytes32)";
        expected[2] = "claim(uint256,address,uint256,bytes32[])";
        expected[3] = "claimAndExercise(uint256,address,uint256,bytes32[])";
        expected[4] = "onERC1155Received(address,address,uint256,uint256,bytes)";
        expected[5] = "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)";

        WriteSurface.assertIsExactly("out/MerkleDistributor.sol/MerkleDistributor.json", expected);
    }

    /// @dev publisher Yes. immutable,We can only redeploy one of the errors. distributor(The government is not going to let them go.
    ///      Because of the pool. `distributor` Yeah. immutable) -  -  So zero addresses are blocked in the construction function.
    function test_constructor_rejectsAZeroPublisher() public {
        vm.expectRevert(MerkleDistributor.ZeroPublisher.selector);
        new MerkleDistributor(address(0));

        assertEq(distributor.publisher(), publisher, unicode"publisher It's in there.");
    }

    /// @dev CRITICAL publisher Two keys to the deployment: the former sign a weekly payment. `setRoot`,The latter was only used once on the day of deployment.
    function test_publisherAndDeployerAreSeparateKeys() public view {
        assertEq(distributor.publisher(), publisher, "publisher");
        assertEq(distributor.deployer(), address(this), "deployer");
        assertTrue(distributor.publisher() != distributor.deployer(), unicode"Two keys can be different.");
    }

    /// @dev distributor The card you read, the one from the pool. `immutable`  -  -  It doesn't save one of its own.
    function test_callIsReadFromThePool() public view {
        assertEq(address(distributor.call()), address(call), "call");
    }

    //  setRoot:Only publisher

    /// @dev Acceptance and acceptance clauses:**`setRoot` Only publisher.** Not even the deploying man -- it has two lines of authority. `setPool` It was all over since then.
    function test_setRoot_isOnlyForThePublisher() public {
        uint256 other = seriesId + 1;
        bytes32 root = keccak256("root");

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotPublisher.selector, stranger));
        vm.prank(stranger);
        distributor.setRoot(other, root);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotPublisher.selector, address(this)));
        distributor.setRoot(other, root);

        assertEq(distributor.roots(other), bytes32(0), unicode"I tried twice without writing it in.");

        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.RootSet(other, root, bytes32(0));
        vm.prank(publisher);
        distributor.setRoot(other, root);
        assertEq(distributor.roots(other), root, "root");
    }

    /// @dev Zero is the "not yet published" sentry -- writing it means nothing, but it's going to make "yes." root  The blogger says that the government is not taking any action to stop the violence.
    function test_setRoot_rejectsTheZeroRoot() public {
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.ZeroRoot.selector, seriesId + 1));
        vm.prank(publisher);
        distributor.setRoot(seriesId + 1, bytes32(0));
    }

    /// @dev CRITICAL root Other Organiser**Before you start collecting, you can change the first one. leaf They are consumed and permanently die.**
    ///
    ///      Both extremes are unacceptable - permanent write-once Let a wrong number root The whole week was sent out with a full amount of mispayment and irretrievable.
    ///      Always. publisher The remaining shares could be re-signed to anyone after distribution had already begun.
    ///      Freezing point in "The First Person Based on this." root The moment of action.
    function test_setRoot_mayBeCorrectedUntilTheFirstLeafIsConsumed() public {
        uint256 fresh = seriesId + 7;
        assertFalse(distributor.rootFrozen(fresh), unicode"No one's got it yet.  Unfreezed");

        // Wrong number -- change it.
        vm.prank(publisher);
        distributor.setRoot(fresh, keccak256("typo"));
        vm.prank(publisher);
        distributor.setRoot(fresh, keccak256("corrected"));
        assertEq(distributor.roots(fresh), keccak256("corrected"), unicode"The correction is in effect.");

        // Someone's been in this series.  Freeze
        assertFalse(distributor.rootFrozen(seriesId), unicode"Prefix: Not accepted");
        _claim(0);
        assertTrue(distributor.rootFrozen(seriesId), unicode"First one. leaf It's frozen after the consumption.");

        bytes32 published = distributor.roots(seriesId);
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.RootAlreadyFrozen.selector, seriesId, published));
        vm.prank(publisher);
        distributor.setRoot(seriesId, keccak256("rewrite"));

        assertEq(
            distributor.roots(seriesId),
            published,
            unicode"That attempt didn't change the attributions that were released."
        );
    }

    /// @dev `claimAndExercise` It's also frozen. root  -  -  The two paths must also be consistent in this matter.
    function test_setRoot_isAlsoFrozenByTheCombinedPath() public {
        _claimAndExercise(0);
        assertTrue(distributor.rootFrozen(seriesId), unicode"Merge Path also freezes");
    }

    //  leaf Encoding: Series nails inside.

    /// @dev The code is the bottom of the chain. Indexer(M4)It's a link-validated.**Common**- Promise, so here it's a separate alignment;
    ///      And nail "Hashi twice" - less Hashi will make a one-time move. 64 Bytes leaf The image is a collision with the internal node.
    function test_leafOf_isTheDoubleHashedTriple() public view {
        bytes32 expectedLeaf = keccak256(bytes.concat(keccak256(abi.encode(seriesId, accounts[0], amounts[0]))));

        assertEq(distributor.leafOf(seriesId, accounts[0], amounts[0]), expectedLeaf, "leafOf");
        assertTrue(
            distributor.leafOf(seriesId, accounts[0], amounts[0])
                != keccak256(abi.encode(seriesId, accounts[0], amounts[0])),
            unicode"It has to be Hash twice, not once."
        );
    }

    /// @dev This group. golden vector By `@openzeppelin/merkle-tree@1.0.8` Default
    ///      `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])` Generate.
    ///      Entering was deliberately disordered and five were in. leaf,Overwrite Default leaf Sort with complete-tree shapes;not available in this repository
    ///      `MerkleTree` helper The 'testing for conformity' is not an interoperability certificate.
    ///
    ///      CRITICAL **A group of false but pacified vectors ran as green as the real one.** So the value of these words depends on the value of the word.
    ///      They're really from that library. The restart command is written in**Function**Lee, don't write here:NatSpec Yes. at Behind the symbol
    ///      The whole file cannot be compiled as a document label.
    ///
    ///       **2026-08-18(issue #66)That is no longer an order to run by hand.** This warehouse has JS The tool chain.
    ///      (`offchain/merkle`,Decision-making 44),So every time the door was closed, the reader was examined, and the two steps were taken:
    ///      (1) `offchain/merkle/test/selfcheck.js` Take it in. `node_modules` The official bank is now counted, and
    ///      `offchain/merkle/test/vectors/oz-standard-v1.json` (a) Place-to-place ratio;
    ///      (2) `offchain/merkle/test/crosscheck-solidity-vector.js` Take the vector and**The following fonts**
    ///      Bitwise (%1)root,Five by input order leaf,`_ozProof` Five of them. proof,The government is not the only one who is not a member of the government.
    ///      And reverse to confirm that none of these functions are in the right place. 32 Byte node is outside the vector.
    ///      The entrance is... `script/ci.sh merkle`.CRITICAL Any word here must be changed at the same time, or the sentence is red.
    function test_claim_acceptsDefaultOpenZeppelinStandardMerkleTreeVectors() public {
        // Recalculate this vector (output should be below) root,Five. leaf,Five. proof Same bytes:
        //
        //   npm install @openzeppelin/merkle-tree@1.0.8
        //   node -e '
        //     const {StandardMerkleTree} = require("@openzeppelin/merkle-tree");
        //     const S = "424242", E = n => (BigInt(n) * 10n ** 18n).toString();
        //     const v = [[S,"0x00000000000000000000000000000000000000D4",E(5)],
        //                [S,"0x00000000000000000000000000000000000000A1",E(11)],
        //                [S,"0x00000000000000000000000000000000000000ff",E(7)],
        //                [S,"0x0000000000000000000000000000000000000003",E(13)],
        //                [S,"0x0000000000000000000000000000000000000077",E(17)]];
        //     const t = StandardMerkleTree.of(v, ["uint256","address","uint256"]);
        //     console.log(t.root);
        //     for (const [i, x] of t.entries()) console.log(t.leafHash(x), t.getProof(i));
        //   '
        //
        // WARNING `t.entries()` Press OZ **Sort After**the order given, and the array below press**Input**in order.
        uint256 ozSeries = 424_242;
        address[5] memory ozAccounts = [
            address(0x00000000000000000000000000000000000000D4),
            address(0x00000000000000000000000000000000000000A1),
            address(0x00000000000000000000000000000000000000ff),
            address(0x0000000000000000000000000000000000000003),
            address(0x0000000000000000000000000000000000000077)
        ];
        uint256[5] memory ozAmounts = [uint256(5 ether), 11 ether, 7 ether, 13 ether, 17 ether];
        bytes32 ozRoot = 0x0be6318e06bdbd7604908f6dbbbc37f7a6037a792d7869f4309263efd26f9a41;

        // Press**Input**Ordered leaf Hash. OZ Sorts in order.
        bytes32[5] memory ozLeaves = [
            bytes32(0x0ed17eb0fafe9f345158c5b9ff095543e945eeab332c12ba36ac5efd0a8c188f),
            0x74ff1c5b473bb8bb974ae6036c209645970923b11abd8328eae1e1c8c80bd389,
            0xe6c399aba69ff17239528d179875accd36f96b35eb2b8afa7d2734b43541a2e9,
            0x3ec0664ea8f4cf630d334482c2508f8a9ea014db54a34e0e5588b4926ff2148c,
            0x68cbfd96b29cf80bfba8bcf5ddf8f85795182a25985c6c139cec0ca5b4bb0ae4
        ];

        for (uint256 i = 0; i < ozAccounts.length; i++) {
            assertEq(distributor.leafOf(ozSeries, ozAccounts[i], ozAmounts[i]), ozLeaves[i], "OZ leaf");
        }

        vm.prank(publisher);
        distributor.setRoot(ozSeries, ozRoot);

        // CRITICAL in vector seriesId Yes.**Fixed value**,And... `openSeries` Calculated id The dynamic address with the clips and the expiry  -  -
        //    So this series can't come out. It's made as a pool. distributor,It's still real, bound. `Call`
        //    It's the same as the real authorized caller. `test/DeploySystem.t.sol::test_distributorCanReceiveCalls` The precedent of the #Presentation.
        //    WARNING So this test proves that**Encoding with proof Interoperating**,Not the hosting path -- the hosting is specifically a claim.
        vm.prank(address(pool));
        call.mint(address(distributor), ozSeries, 53 ether);

        // Every piece proof From the same time. StandardMerkleTree Copy it in the output as it is.
        vm.prank(keeper);
        distributor.claim(ozSeries, ozAccounts[0], ozAmounts[0], _ozProof(0));
        vm.prank(keeper);
        distributor.claim(ozSeries, ozAccounts[1], ozAmounts[1], _ozProof(1));
        vm.prank(keeper);
        distributor.claim(ozSeries, ozAccounts[2], ozAmounts[2], _ozProof(2));
        vm.prank(keeper);
        distributor.claim(ozSeries, ozAccounts[3], ozAmounts[3], _ozProof(3));
        vm.prank(keeper);
        distributor.claim(ozSeries, ozAccounts[4], ozAmounts[4], _ozProof(4));

        for (uint256 i = 0; i < ozAccounts.length; i++) {
            assertEq(call.balanceOf(ozAccounts[i], ozSeries), ozAmounts[i], "OZ proof delivered the call");
        }
    }

    function _ozProof(uint256 index) private pure returns (bytes32[] memory proof) {
        if (index == 0) {
            proof = new bytes32[](3);
            proof[0] = 0x3ec0664ea8f4cf630d334482c2508f8a9ea014db54a34e0e5588b4926ff2148c;
            proof[1] = 0xe6c399aba69ff17239528d179875accd36f96b35eb2b8afa7d2734b43541a2e9;
            proof[2] = 0xa5ad25979a2857078f3f6a9225ab7bca4448cae3b96a7adc7f216e5a15bb5433;
        } else if (index == 1) {
            proof = new bytes32[](2);
            proof[0] = 0x68cbfd96b29cf80bfba8bcf5ddf8f85795182a25985c6c139cec0ca5b4bb0ae4;
            proof[1] = 0xa94680f095a92636d10854b9c6bbd22a4e02a7eda45e9177dd918e7610e3bcc7;
        } else if (index == 2) {
            proof = new bytes32[](2);
            proof[0] = 0x0b190b68db625169644fd42a7b788f04445add9733b6f18c9558164886f0a9eb;
            proof[1] = 0xa5ad25979a2857078f3f6a9225ab7bca4448cae3b96a7adc7f216e5a15bb5433;
        } else if (index == 3) {
            proof = new bytes32[](3);
            proof[0] = 0x0ed17eb0fafe9f345158c5b9ff095543e945eeab332c12ba36ac5efd0a8c188f;
            proof[1] = 0xe6c399aba69ff17239528d179875accd36f96b35eb2b8afa7d2734b43541a2e9;
            proof[2] = 0xa5ad25979a2857078f3f6a9225ab7bca4448cae3b96a7adc7f216e5a15bb5433;
        } else if (index == 4) {
            proof = new bytes32[](2);
            proof[0] = 0x74ff1c5b473bb8bb974ae6036c209645970923b11abd8328eae1e1c8c80bd389;
            proof[1] = 0xa94680f095a92636d10854b9c6bbd22a4e02a7eda45e9177dd918e7610e3bcc7;
        } else {
            revert("OZ vector index out of range");
        }
    }

    /// @dev CRITICAL **`seriesId` Yes. leaf Lee, so it's the same one. root The two series were mistransmitted and nothing was stolen.**
    ///      The sign is separated by series, so this dimension is missing. leaf You can consume it in two series once...
    ///      The second move was another batch of unreceiptable shared balances.
    function test_leafIsBoundToItsSeries_soTheSameProofCannotTravel() public {
        // Open the second series and cast the same number of calls. distributor,And then you put**First series. root** It was sent wrong.
        uint256 otherSeries = vault.openSeries(address(meme), address(stock), expiry + 1 days, STRIKE);
        vault.depositAndMint(otherSeries, address(distributor), MINTED);
        vm.prank(publisher);
        distributor.setRoot(otherSeries, MerkleTree.root(_leaves(seriesId)));

        // First series. proof I can't tell from the second series that... leaf - Yes. seriesId Different.
        vm.expectRevert(
            abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, otherSeries, accounts[0], amounts[0])
        );
        vm.prank(keeper);
        distributor.claim(otherSeries, accounts[0], amounts[0], _proof(0));

        assertEq(call.balanceOf(address(distributor), otherSeries), MINTED, unicode"The second series is still intact.");
    }

    //  claim:permissionless,Just go in. leaf Assigned account

    /// @dev Acceptance and acceptance clauses:**`claim` permissionless;Only the license. leaf Assigned `account`.**
    ///
    ///      - No, not the address. `msg.sender`.That's what it is."keeper On behalf of the gas,
    ///      The reason for the decision is that the owner can also receive zero.
    function test_claim_isPermissionlessAndDeliversOnlyToTheLeafAccount() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.Claimed(seriesId, accounts[0], amounts[0], false);
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));
        consumed[0] = true;

        assertEq(call.balanceOf(accounts[0], seriesId), amounts[0], unicode"The license's in. leaf Designated accounts");
        assertEq(call.balanceOf(keeper, seriesId), 0, unicode"I can't get one for the submitr.");
        assertEq(
            call.balanceOf(address(distributor), seriesId),
            MINTED - amounts[0],
            unicode"This is the only one missing from the share."
        );
        assertTrue(distributor.claimed(seriesId, accounts[0]), "claimed");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev The right to vote is...**Really?**Certificate of entitlement: The holder may either exercise his or her own right or sell it.
    ///      `claim` This path doesn't touch the door to the declaration. MEME  -  -  Users in restricted jurisdictions are thus fully involved.
    ///      Hold -> Cumulative -> Receipts -> I'm not sure if I'm going to sell it.
    function test_claim_deliversCallsTheHolderCanUseHimself() public {
        _claim(1);

        vm.prank(accounts[1]);
        pool.exercise(seriesId, amounts[1], accounts[1]);

        assertEq(stock.balanceOf(accounts[1]), amounts[1], unicode"You're doing your job.");
        assertEq(meme.balanceOf(0x000000000000000000000000000000000000dEaD), _expectedMeme(amounts[1]), "meme");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev Acceptance and acceptance clauses:**Same. proof Second submission revert.**
    function test_claim_rejectsAReplayedProof() public {
        _claim(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(call.balanceOf(accounts[0], seriesId), amounts[0], unicode"There's no second.");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev I can't even figure it out -- this is... merkle That's what that means.
    function test_claim_rejectsATamperedAmount() public {
        uint256 inflated = amounts[0] + 1;

        vm.expectRevert(
            abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, seriesId, accounts[0], inflated)
        );
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], inflated, _proof(0));

        // I can't change one person:proof belong to leaf,Not a Author
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, seriesId, stranger, amounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, stranger, amounts[0], _proof(0));

        _assertCustodyCoversUnclaimed();
    }

    /// @dev root The permit is already in place. distributor I'm on it. Wait. publisher Release it
    ///      **There's only delay, no loss.**(Same `rollExpired` No subsequent series.
    function test_claim_rejectsBeforeTheRootIsPublished() public {
        uint256 fresh = vault.openSeries(address(meme), address(stock), expiry + 2 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), MINTED);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, accounts[0], amounts[0]);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NoRoot.selector, fresh));
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], amounts[0], MerkleTree.proofFor(leaves, 0));

        // Retroactive after re-sentation
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], amounts[0], MerkleTree.proofFor(leaves, 0));
        assertEq(
            call.balanceOf(accounts[0], fresh), amounts[0], unicode"root Repayment of the contract after re-payment"
        );
    }

    /// @dev CRITICAL Zero share. leaf Two entrances.**I have to.**It's the same. If you don't stop, `claim` I'll consume one.
    ///      `claimAndExercise` It's never gonna be consumed. leaf(Take the pool and get it. 0 Yes. revert) -  -
    ///      Two entrances to what? leaf "Consumable" offers two answers, the kind of asymmetries that the promissory notes are about to eliminate.
    function test_bothPathsRejectAZeroAmountLeaf() public {
        uint256 fresh = seriesId + 99;
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, accounts[0], 0);
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));

        bytes32[] memory proof = MerkleTree.proofFor(leaves, 0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.ZeroAmount.selector, fresh, accounts[0]));
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], 0, proof);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.ZeroAmount.selector, fresh, accounts[0]));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(fresh, accounts[0], 0, proof);

        assertFalse(distributor.claimed(fresh, accounts[0]), unicode"I haven't consumed this twice. leaf");
    }

    //  claimAndExercise:Two completes, just me.

    /// @dev Acceptance and acceptance clauses:**User path is two times - approve + claimAndExercise.**
    ///
    ///      Certificate**Not by.** account Hand: From distributor Direct destruction;MEME From account Pull it out.
    ///      (What he authorized was...**I'm a pool.**);Stock tokens directly available account.
    function test_claimAndExercise_completesInTwoTransactions() public {
        address alice = accounts[0];
        uint256 amount = amounts[0];
        uint256 memeCost = _expectedMeme(amount);
        uint256 memeBefore = meme.balanceOf(alice);

        // I'm sorry. 1 T: Authorization (Authorization)`setUp` Lee already did. It's written here because it's one of two.
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);

        // I'm sorry. 2 Pen: right to parallel rights
        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.Claimed(seriesId, alice, amount, true);
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amount, _proof(0));
        consumed[0] = true;

        assertEq(call.balanceOf(alice, seriesId), 0, unicode"The license never passed the beneficiary's hand.");
        assertEq(call.balanceOf(address(distributor), seriesId), MINTED - amount, unicode"Destroy from shared balance");
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"MEME From account Take it off the books.");
        assertEq(stock.balanceOf(alice), amount, unicode"Stock tokens directly available account");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev Acceptance and acceptance clauses:**Not `account` Called by Me `claimAndExercise` Rejected.**
    ///
    ///      CRITICAL This door must grow. distributor Up: The Ziquko caller's white list is "The Beneficiaries themselves**or** distributor,
    ///      And this contract is on the white list -- the pool can't tell if it's the right to do it. `account` You want it.
    ///      So, every condition that is actually in place is set out below: the beneficiary has declared, authorized,proof It's true too.
    function test_claimAndExercise_rejectsEveryCallerButTheAccount() public {
        address alice = accounts[0];

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, keeper, alice));
        vm.prank(keeper);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        // Company publisher Not even a chance.
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, publisher, alice));
        vm.prank(publisher);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        assertFalse(distributor.claimed(seriesId, alice), unicode"leaf Not consumed");
        assertEq(meme.balanceOf(alice), 1e31, unicode"One. MEME He didn't get burned by anyone else.");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev Acceptance and acceptance clauses:**Unsigned `account` Yes. distributor The same is true of the path.**
    ///
    ///      CRITICAL This is the observable consequence of "designing the beneficiaries of the door, not checking the caller" on this path.
    ///      distributor All the users pass the door once -- the door will be empty.
    ///      Door.**The structure doesn't kill anyone.**(No Variable 6(3)):He signed it himself once.
    function test_claimAndExercise_rejectsAnUnattestedAccount() public {
        address newcomer = makeAddr("newcomer");
        uint256 share = 5 ether;
        uint256 fresh = vault.openSeries(address(meme), address(stock), expiry + 3 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), share);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, newcomer, share);
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));
        bytes32[] memory proof = MerkleTree.proofFor(leaves, 0);

        meme.mint(newcomer, 1e31);
        vm.prank(newcomer);
        meme.approve(address(pool), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NotAttested.selector, newcomer));
        vm.prank(newcomer);
        distributor.claimAndExercise(fresh, newcomer, share, proof);

        // Rolling back in the pen.  leaf He's not consumed. He can use it after signing.
        assertFalse(distributor.claimed(fresh, newcomer), unicode"The rejected one didn't eat him. leaf");

        vm.prank(newcomer);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        vm.prank(newcomer);
        distributor.claimAndExercise(fresh, newcomer, share, proof);
        assertEq(stock.balanceOf(newcomer), share, unicode"After signing, we'll do as we please.");
    }

    /// @dev When power fails**Rolling back in the pen.**,Especially. `claimed`  -  -  Otherwise, a failed right will turn the user on. leaf
    ///      Eat it for nothing, and the certificate is still there. distributor Hand: That's a loss nobody can fix. admin).
    ///      Here you can use the "Sequence settled" to trigger failure. 4(1)).
    function test_claimAndExercise_doesNotBurnTheLeafWhenTheExerciseFails() public {
        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertFalse(distributor.claimed(seriesId, accounts[0]), unicode"leaf Still there.");
        assertFalse(distributor.rootFrozen(seriesId), unicode"And I didn't. root Freeze.");

        // After settlement `claim` Still available: a power card is not available, but it is still available. account Assets
        _claim(0);
        assertEq(call.balanceOf(accounts[0], seriesId), amounts[0], unicode"Payable after settlement");
    }

    /// @dev Merges the path to replay itself.
    function test_claimAndExercise_rejectsAReplayedProof() public {
        _claimAndExercise(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(stock.balanceOf(accounts[0]), amounts[0], unicode"Only one.");
        _assertCustodyCoversUnclaimed();
    }

    //  CRITICAL Both paths are one: four directions.

    /// @dev Acceptance and acceptance clauses:**`claim` After `claimAndExercise` Yes. revert.**
    function test_claimThenClaimAndExercise_isRejected() public {
        _claim(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(stock.balanceOf(accounts[0]), 0, unicode"No extra stock coins to go out of the pool.");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev Acceptance and acceptance clauses:**And vice versa... `claimAndExercise` After `claim` Yes. revert.**
    ///
    ///      CRITICAL This direction is the shape of the attack: the right to move has been burned out of shared balances. `amount`,
    ///      If I can do it again, `claim` Once, the other one's share.
    function test_claimAndExerciseThenClaim_isRejected() public {
        _claimAndExercise(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(call.balanceOf(accounts[0], seriesId), 0, unicode"I didn't get an extra license.");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev The four holders each go one path, and the middle is plugged in and re-played -- every step after that must be able to keep the rest of the people out of the way.
    function test_custodyCoversUnclaimedThroughAMixedSequence() public {
        _assertCustodyCoversUnclaimed();

        _claimAndExercise(0);
        _assertCustodyCoversUnclaimed();

        _claim(1);
        _assertCustodyCoversUnclaimed();

        // We'll have to replay both directions once. We'll have to bounce back.
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[1]));
        vm.prank(accounts[1]);
        distributor.claimAndExercise(seriesId, accounts[1], amounts[1], _proof(1));

        _claim(2);
        _assertCustodyCoversUnclaimed();

        _claimAndExercise(3);
        _assertCustodyCoversUnclaimed();

        // Four. leaf All consumed, all shared balances zero -- one small, one large.
        assertEq(call.balanceOf(address(distributor), seriesId), 0, unicode"The whole week's license is just finished.");
        assertEq(_unclaimed(), 0, unicode"No outstanding leaf Yes.");
    }

    /// @dev The same thing. fuzz Edition: Random sequence, random path, random replay, every step after which the trust is asserted to be in order.
    ///      The failed action must be asserted - a rejected playback**I shouldn't.**Change anything.
    function testFuzz_custodyCoversUnclaimedUnderAnyOrderOfActions(uint256 seed) public {
        for (uint256 step = 0; step < 12; step++) {
            uint256 i = seed % 4;
            uint256 action = (seed / 4) % 2;
            seed /= 8;

            if (action == 0) {
                vm.prank(keeper);
                try distributor.claim(seriesId, accounts[i], amounts[i], _proof(i)) {
                    consumed[i] = true;
                } catch {}
            } else {
                vm.prank(accounts[i]);
                try distributor.claimAndExercise(seriesId, accounts[i], amounts[i], _proof(i)) {
                    consumed[i] = true;
                } catch {}
            }

            _assertCustodyCoversUnclaimed();
        }
    }

    /// @dev CRITICAL **Counter-argument: Remove the signpost, the statement above must be red.**
    ///
    ///      A claim that always is true and the correct one looks exactly the same, so here's the input that the probe must catch:
    ///      {ForgetfulDistributor} Same as the actual line by line, with only a "Chae" missing. + The two words, "Sitting in the chair."
    ///      And... alice Play it again, from 100 ether Take it from the shared balance. 80  -  -
    ///      **She paid for it. MEME,And the thing that took it was... bob / carol / dave Share tokens**,
    ///      And those three are holding it. proof,There is no match for the goods.
    function test_theDetectorDetects_aDistributorThatForgetsTheClaimedFlag() public {
        (ForgetfulDistributor forgetful, ClearingPool badPool, Call badCall) = _deployForgetfulSystem();

        address alice = accounts[0];
        bytes32[] memory leaves = _leaves(seriesId);
        bytes32[] memory proof = MerkleTree.proofFor(leaves, 0);

        vm.prank(alice);
        meme.approve(address(badPool), type(uint256).max);

        vm.prank(alice);
        forgetful.claimAndExercise(seriesId, alice, amounts[0], proof);
        consumed[0] = true;
        _assertCustodyCoversUnclaimed(badCall, address(forgetful), seriesId); // First time legal, still valid.

        // The second time was replayed -- no sign of it.
        vm.prank(alice);
        forgetful.claimAndExercise(seriesId, alice, amounts[0], proof);

        assertEq(stock.balanceOf(alice), 2 * amounts[0], unicode"She took two. One of them wasn't hers.");
        assertLt(
            badCall.balanceOf(address(forgetful), seriesId),
            _unclaimed(),
            unicode"The trustees can't afford the unreceiptable. leaf  -  -  The probe must be red here."
        );

        // The victims are specific:bob Hold it. proof,But there's no more to talk about.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector,
                address(forgetful),
                MINTED - 2 * amounts[0],
                amounts[1],
                seriesId
            )
        );
        vm.prank(accounts[1]);
        forgetful.claimAndExercise(seriesId, accounts[1], amounts[1], MerkleTree.proofFor(leaves, 1));
    }

    /// @dev Counter-proof system: real pool and call, only distributor The one that missed the sign.
    ///      The registration form is used as usual - four holders have already stated above, and the declaration is not related to the pool.
    function _deployForgetfulSystem()
        private
        returns (ForgetfulDistributor forgetful, ClearingPool badPool, Call badCall)
    {
        badCall = new Call();
        forgetful = new ForgetfulDistributor();
        // The anti-proof system has its own root: it's another pool, and the pool. authenticator Yes. immutable.
        FactoryStub badFactory = new FactoryStub();
        badPool = new ClearingPool(badCall, address(forgetful), registry, badFactory.registry());
        badCall.setPool(address(badPool));
        forgetful.setPool(address(badPool));

        VaultStub badVault = new VaultStub(badPool);
        badFactory.bind(address(meme), address(badVault));
        stock.mint(address(badVault), 1e30);
        badVault.approve(stock, type(uint256).max);

        uint256 id = badVault.openSeries(address(meme), address(stock), expiry, STRIKE);
        assertEq(id, seriesId, unicode"The same parameters in both systems. seriesId");
        badVault.depositAndMint(id, address(forgetful), MINTED);

        forgetful.setRoot(id, MerkleTree.root(_leaves(id)));
    }

    //  Re-enter and Unbound

    /// @dev `claim` Handing over control to the recipient (inERC-1155 The sign is already on the way.**Before**
    ///      Place yourself, so it's the same one. leaf The re-playing of the project is not going to be possible.`nonReentrant` It's the second way above this...
    ///      It makes the "two entrances interlocking" structural.
    ///
    ///      CRITICAL Here's the one that's coming back.**Another account.**It's... leaf(`claim` (No permit, submission is legal)
    ///      Because the second one in the same account. leaf It's not gonna be enough. (Series, Account) (One sign)
    ///      If you take that as input, this test will be due to**Something else.**Reasons adopted.
    ///      The cost is therefore specific: the bulk delivered contract wallet cannot be taken in the reverse hand in the next one, in two pieces.
    function test_claim_isNotReentrant() public {
        ReclaimingWallet wallet = new ReclaimingWallet();
        uint256 fresh = vault.openSeries(address(meme), address(stock), expiry + 4 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), 30 ether);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleTree.leafOf(fresh, address(wallet), 10 ether);
        leaves[1] = MerkleTree.leafOf(fresh, accounts[0], 20 ether); // It's from another account. leaf
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));

        wallet.arm(
            distributor,
            abi.encodeCall(MerkleDistributor.claim, (fresh, accounts[0], 20 ether, MerkleTree.proofFor(leaves, 1)))
        );
        wallet.claim(fresh, 10 ether, MerkleTree.proofFor(leaves, 0));

        assertTrue(wallet.reentered(), unicode"Precondition: Reconverting is actually in.");
        assertFalse(wallet.reentrySucceeded(), unicode"Inner collection must be denied.");
        assertEq(
            wallet.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"The reason for the rejection was re-entry."
        );
        assertEq(call.balanceOf(address(wallet), fresh), 10 ether, unicode"Only the one on the outside.");
        assertFalse(distributor.claimed(fresh, accounts[0]), unicode"The one in the inner room. leaf Not consumed.");

        // Two copies of the same -- the only thing that's blocked is the "stagger," not the receipt itself.
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], 20 ether, MerkleTree.proofFor(leaves, 1));
        assertEq(call.balanceOf(accounts[0], fresh), 20 ether, unicode"Second one, the same.");
    }

    /// @dev Unbound distributor Yes.**Inertity**No permit is available, and no delivery is possible.
    ///      This one's not in the real process. broadcast The government has been able to provide the necessary information to the government.
    ///      The aim of the block is to stop failure from being a clear word.
    function test_claim_revertsBeforeTheDistributorIsBoundToAPool() public {
        MerkleDistributor unbound = new MerkleDistributor(publisher);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(seriesId, accounts[0], amounts[0]);

        vm.prank(publisher);
        unbound.setRoot(seriesId, MerkleTree.root(leaves));

        vm.expectRevert(MerkleDistributor.PoolNotBound.selector);
        vm.prank(keeper);
        unbound.claim(seriesId, accounts[0], amounts[0], MerkleTree.proofFor(leaves, 0));

        vm.expectRevert(MerkleDistributor.PoolNotBound.selector);
        unbound.call();
    }

    //  Next week after the roller.

    /// @dev When collateral that expired was rolled into the trunk, the certificate was cast. **distributor** ..of the`rollExpired`) -  -
    ///      So next week. root Once it's released, the license will be accepted. This one. M1-7 Pick up the promissory note.
    function test_rolledCallsAreClaimableUnderTheNextWeeksRoot() public {
        _claimAndExercise(0); // alice It's all right, all right. 60 ether I'll be gone.

        uint64 nextExpiry = expiry + 7 days;
        uint256 nextSeries = vault.openSeries(address(meme), address(stock), nextExpiry, STRIKE);

        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);
        pool.rollExpired(seriesId, nextSeries);

        uint256 rolled = MINTED - amounts[0];
        assertEq(call.balanceOf(address(distributor), nextSeries), rolled, unicode"It's a cast. distributor");

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(nextSeries, accounts[1], rolled);
        vm.prank(publisher);
        distributor.setRoot(nextSeries, MerkleTree.root(leaves));

        vm.prank(keeper);
        distributor.claim(nextSeries, accounts[1], rolled, MerkleTree.proofFor(leaves, 0));
        assertEq(call.balanceOf(accounts[1], nextSeries), rolled, unicode"Next week, as usual.");
    }
}
