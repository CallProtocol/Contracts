// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IClearingPool} from "./interfaces/IClearingPool.sol";
import {PoolBound} from "./PoolBound.sol";

/// @title MerkleDistributor
/// @notice The clearing house will create a single certificate of title to the contract. merkle proof Take it away...
///         Or one step in place, with rights directly from this accumulated balance.
///
/// # CRITICAL This contract holds...**Someone else's.**Certificate
///
/// This phrase determines the shape of the code for each line below.`ClearingPool.depositAndMint` and `rollExpired` Put the whole series of calls.
/// It's a contract. They were before they were taken.**Share balance not received by all users**.So every consumer entry here is not.
/// The first one, the first one, was to spend its own money, but instead, "take someone's share of the share."
///
/// Same one. merkle leaf Yes.**Two.**Consumer entry (in thousands of US dollars){claim} and {claimAndExercise}),So:
///
/// ```
/// claimAndExercise(seriesId, account, amount, proof)     // Replay N Number of times
///    pool.exercise(..., beneficiary = account)
///          call.burn(msg.sender = distributor, seriesId, amount)
///                 Burned with the right to hold the present contract.
/// ```
///
/// The missing mark is not "repeat your share" but...**Stealing from the shared balance.**:Callers pay for themselves every time. MEME,
/// The other holders who have not yet received the shares -- those who hold the valid shares -- are the same. proof,The government has not yet made any progress.
///
/// So both paths are written together. {claimed},And...**It's not guaranteed by writing it over and over again.**:
/// They call the same one. private It's... {_consume},One. leaf "Cha." -> Check -> The first of these is the "Selection of the People" (Standing in the House of Representatives) and the "Standing in the House of Representatives" (Standing in the House of Representatives) of the Republic of Macedonia.
/// It's written in two, so it's important that they be remembered for consistency.
///
/// # Three access restrictions, one thing different.
///
/// | The entrance. | Who can switch? | Why is that answer? |
/// |---|---|---|
/// | {setRoot} | `publisher` | CRITICAL This system**Only Centralized Trust Point**(`docs/spec.md`) |
/// | {claim} | **Anyone.** | keeper Payable gas Batch delivery; only cards entry leaf Assigned `account`,I'll take it from you. |
/// | {claimAndExercise} | **Only `account` In person.** | The right flower is account It's... MEME,When a third party is not a substitute |
///
/// CRITICAL {claim} and {claimAndExercise} The license level is different because**Their consequences are different.**:The former is just one of the
/// It's all in the world. account He's got the right to the right to vote.**Spend him. MEME**.I'm authorized to give it to the pool.
/// MEME The amount is "I'm willing to pay for my rights" and not "everyone can choose for me."
///
/// @dev Recipients leaf See you at the code. {leafOf};Declaration Gate (Pilot)`attestations.attestedVersion(account) != 0`)
///      It's not in this contract -- it's long. `ClearingPool.exercise` Go on, and check it out.**Beneficiaries**.
///      The beneficiary of this contract is `account`,So, undeclared `account` And it's also being rejected under this path.
///      See you at the full design. `docs/spec.md` and issue #13.
///
///      CRITICAL Succession `ERC1155Holder` I'm not saying that I have no manners:ERC-1155 It's... `_mint` Forced call to contract payee
///      `onERC1155Received` And verify the return value - without it, the casting will be direct. revert,The whole casting path cannot run.
///      This ring is not visible in the connection, so it's made of `test/DeploySystem.t.sol` It's a four-party contract.
///      Two. `onERC1155*Received` Yes, yes, yes, yes, yes, yes, yes, yes, yes, yes, yes. view ..of theERC-1155 This is the norm, so it's a foreign writing in this contract.
///      Function set. This does not constitute an entry: the two do nothing but return to magic.
contract MerkleDistributor is PoolBound, ERC1155Holder, ReentrancyGuardTransient {
    /// @notice Weekly issues of attribution root The address.CRITICAL **The system is the only central trust point.**
    ///
    /// @dev It's... `immutable`,Same `AttestationRegistry.publisher`  -  -  Replaceable publisher Equal
    ///      Another path to "who can change the distribution rights on this chain" and not this contract. admin,No upgrade.
    ///      There's only one thing it can do: give it to me.**Not started**"and the series of the root(See {setRoot}).
    ///      It can't take any of the documents:`claim` Just to leaf Assigned `account` Delivery.
    address public immutable publisher;

    /// @notice Attribution of each series root.`bytes32(0)` = Not yet published.
    /// @dev No claim is available until it is issued, and the cast is retained in this contract;root Retroactivity is possible.
    mapping(uint256 seriesId => bytes32 root) public roots;

    /// @notice The series. root Freezing  First leaf The moment of consumption is set aside and it is never changed.
    ///
    /// @dev CRITICAL **This is... {setRoot} The line between the symbioticity of the issue and the "attributability of the issue cannot be retroactively rewritten" is the line between the two.**
    ///      There is a real pattern of failure at both extremes:
    ///
    ///      - **root Permanent write-once**:publisher One word, this week's distribution is all wrong and**Unrecoverable.**
    ///        (This contract is not. admin,The certificate of authority has been forged;
    ///      - **root Forever.**:The distribution has begun.publisher And still can re-inscribe the rest of the shares to anyone...
    ///        That's exactly the kind of power this contract should not have.
    ///
    ///      Freezing Point in First leaf "for consumption," because it was.**The first one relied on this. root Action** The moment:
    ///      The changes before then do not harm anyone (no one has done anything on that basis), and then the changes after that are rewritten retroactively.
    ///      And this is the guarantee.**Readable**:`rootFrozen[seriesId] == true`  The attribution of this series is determined to be dead.
    mapping(uint256 seriesId => bool frozen) public rootFrozen;

    /// @notice CRITICAL **The one who wrote the two consumption paths.** `true` = This one. leaf It's already been consumed.
    /// @dev One. (Series, Account) There's only one, so it's the same. account There's only one in the same series.**One.**Consumptionable leaf.
    ///      Attribution calculation (in thousands of United States dollars)M4 It's... Indexer)The only thing that must be recorded every week for each account -- two if you want to, is that you have to write a record of the account.
    ///      The second is never consumed.
    mapping(uint256 seriesId => mapping(address account => bool)) public claimed;

    /// @notice I've published a series of attributions. root.
    /// @param previousRoot The one that's been covered.`bytes32(0)` = This is the first time it has been published.
    ///                     CRITICAL It's written down to get this series. root "and changed it several times from what to what."
    ///                     The chain is full of information - the freeze only guarantees that it will not change after it starts to collect it, and that it will not change.
    event RootSet(uint256 indexed seriesId, bytes32 root, bytes32 previousRoot);

    /// @notice One. leaf It's consumed.
    ///
    /// @param exercised `false` = The certificate has been transferred. `account`({claim});
    ///                  `true`  = Direct rights of action, destruction of certificates from this contract, stock tokens, direct possessions `account`
    ///                            ({claimAndExercise},The power of execution itself is different. `ClearingPool.Exercised`)
    ///
    /// @dev CRITICAL **The two paths send the same event, distinguishing between one and the other.** The reason is the same symbol as they wrote:
    ///      This one. leaf "There should be only one source on the chain." If there are two kinds of events, answer under the chain.
    ///      This one. leaf "Can we get it?"
    event Claimed(uint256 indexed seriesId, address indexed account, uint256 amount, bool exercised);

    error ZeroPublisher();
    error NotPublisher(address caller);

    /// @dev nil root It's a "not yet published" sentry. Write it in, it's nothing, but it's gonna get...
    ///      `roots[id] != 0`  Published 'this finding is false - same {PoolBound-setPool} A trade-off for zero.
    error ZeroRoot(uint256 seriesId);

    /// @dev The series has been received by some people.root See you later. {rootFrozen}.
    error RootAlreadyFrozen(uint256 seriesId, bytes32 root);

    /// @dev This series is not yet in place. root.The certificate of authority may have been cast into this contract - etc. publisher Release it, no loss.
    error NoRoot(uint256 seriesId);

    /// @dev CRITICAL This error is the whole reason for the existence of the contract. See the re-statement of the contract head.
    error AlreadyClaimed(uint256 seriesId, address account);

    /// @dev proof With this series root Not at all.`amount` The most common reason is that the number is wrong, and the number is not the same.
    ///      Not proof It's a problem.
    error InvalidProof(uint256 seriesId, address account, uint256 amount);

    /// @dev {claimAndExercise} Only `account` I can do it myself -- it's his who's got power. MEME.
    error NotAccount(uint256 seriesId, address caller, address account);

    /// @dev See {_consume}:Zero share. leaf Consumables at both entrances were inconsistent and therefore blocked in the common door.
    error ZeroAmount(uint256 seriesId, address account);

    /// @dev No settlement pool has been secured yet.{PoolBound}).This contract was not issued with any call before the binding, and therefore this is not available in the real process;
    ///      The apparent block was meant to stop failure from a clear sentence, not a call to a zero address.
    error PoolNotBound();

    /// @param publisher_ Weekly issues of attribution root Chile
    ///
    /// @dev CRITICAL publisher and**Deployment**({PoolBound-deployer})Dissociation is deliberate, although deployment of scripts by default makes them equal.
    ///      The two keys are used at a different pace than the number of times: the deploying person will only use them once on the day of deployment (two times) `setPool` After
    ///      It's a power that's exhausted, and... publisher I'm gonna sign it every week. `setRoot`  -  -  It must be a hot key.
    ///      Welding the hot keys used in Zhou to the "first deployed" means requiring that the key be deployed on the line forever.
    constructor(address publisher_) {
        if (publisher_ == address(0)) revert ZeroPublisher();
        publisher = publisher_;
    }

    /// @notice leaf Other Organiser`keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))))`.
    ///
    /// @dev It's for the public. Indexer(M4)With Frontend**One.**Authority source -- the same code is copied twice, and one will float, sooner or later.
    ///      And the consequences of drifting are week after week. proof I can't tell you all about it.
    ///      WARNING But it should not be used to test itself:`test/MerkleDistributor.t.sol` I'll count it myself.
    ///      (Same `ClearingPool.seriesIdOf` The trade-off.
    ///
    ///      Both details are heavy:
    ///
    ///      CRITICAL **`seriesId` Yes. leaf Inside.** The markers are separated by series (in thousands of years).`claimed[seriesId][account]`),
    ///      So it looks redundant -- but it's blocking it.**The other way.**:publisher If you put the same root The first one was sent to the two series.
    ///      Same one. leaf This is done once in each of the two series, and the second move is to collect the shared balance of the other batch of unreceived users.
    ///      Stitch the line. leaf,This is not structurally possible, not by relying on it. publisher No mistakes.
    ///
    ///      CRITICAL **Hash twice.** This is... OpenZeppelin `StandardMerkleTree`  The agreement: the internal node is
    ///      64 Two bytes of Hashi. keccak,leaf If only Hashi once, one time**Just right. 64 Bytes**It's... leaf Image
    ///      It could be the original of an internal node at the same time -- so the middle node could be considered as a leaf Submit (Present)second preimage).
    ///      Dohashi once and for all let the originals of both be permanently staggered.
    ///      Indexer Side-to-side `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])`.
    function leafOf(uint256 seriesId, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(seriesId, account, amount))));
    }

    /// @notice The certificate of attorney contract.**The one from the pool. `immutable`**,There is no other copy of this contract.
    /// @dev One extra piece may point to a different place than the pool, and the two point at different points. `claim`  Will put one
    ///      It's nothing. ERC-1155 Go to the user. Before binding here revert({PoolNotBound}).
    function call() public view returns (IERC1155) {
        return IERC1155(address(_boundPool().call()));
    }

    /// @notice Publishs the attribution of a series root.Only `publisher`.
    ///
    /// @dev Three doors:
    ///
    ///      | # | Door. | It's blocking that. |
    ///      |---|---|---|
    ///      | (1) | Caller: publisher | Anyone can rewrite the distribution week after week. |
    ///      | (2) | root Non-zero | Zero is the "not yet published" sentry. |
    ///      | (3) | The series has not yet been collected | CRITICAL **Retrospective rewriting of distribution already initiated**  -  -  See {rootFrozen} |
    ///
    ///      (3) Yes.**First one. leaf Consumption**The previous permission to rewrite is a deliberately typified path:root The blogger says:
    ///      There is no other way to get the certificate to the right person. admin,The license has been made.
    ///      The wrong window was closed early -- the first person relied on this. root After the operation, it closed.
    function setRoot(uint256 seriesId, bytes32 root) external {
        if (msg.sender != publisher) revert NotPublisher(msg.sender);
        if (root == bytes32(0)) revert ZeroRoot(seriesId);

        bytes32 previousRoot = roots[seriesId];
        if (rootFrozen[seriesId]) revert RootAlreadyFrozen(seriesId, previousRoot);

        roots[seriesId] = root;
        emit RootSet(seriesId, root, previousRoot);
    }

    /// @notice (c) A certificate of entitlement.**No permission**  -  -  Anyone can take over. `account` Submit proof.
    ///
    /// @dev Hand over the things: not the address of the receipt. `msg.sender`,It's... **leaf The one that died. `account`**.
    ///      And... keeper(Or we can pay for it. gas The permit is also received by the holder in bulk delivery.
    ///
    ///      WARNING This path.**No, I don't.**The statement door, not touching it. MEME:It just gave one of the originals. `account` The right to vote
    ///      Send it to him. Users in restricted jurisdictions can therefore participate in the "possession" -> Cumulative -> Receipts -> The "Sale" (Sale)10).
    ///
    ///      The rights of the settled series are normally available - a powerless one. 4(1)).Here's no door:
    ///      It's just a state of uncertainty about where my share is, and the certificate itself is still... `account` assets.
    function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _consume(seriesId, account, amount, proof);

        // Recording (in thousands of United States dollars)`claimed` The first time that the contract was signed, the second time the contract was signed, the second time the contract was signed, the second time the contract was signed, the second time the contract was signed, the second time the contract was signed, the second time the date was signed, the second time the date was called.ERC-1155 I'll call it back.
        call().safeTransferFrom(address(this), account, seriesId, amount, "");

        emit Claimed(seriesId, account, amount, false);
    }

    /// @notice The right to receive and to be present,**Two completes.**(approve + This function). `account` I can do it myself.
    ///
    /// @dev Certificate**Not by.** `account` Hand: This contract is to be transferred as holder
    ///      `pool.exercise(seriesId, amount, beneficiary = account)`,And...
    ///
    ///      - Certificate from**This contract.**Destruction (`call.burn(msg.sender = distributor, ...)`);
    ///      - MEME From **`account`** Pull -- he has to first. `approve` Here. **`ClearingPool`**(Not this contract;
    ///      - Statement of doorcheck **`account`**(The rules on the other side of the pool. See you. `ClearingPool.exercise` No. No. 5 (a) Doors;
    ///      - Stock tokens**Straight to the point. `account`**.
    ///
    ///      User path thus from three (%2)claim + approve + exercise)Press two.
    ///
    ///      CRITICAL **`msg.sender == account` This door must be here, not just by the pool.** The name of the pool is White List.
    ///      Beneficiaries themselves**or** distributor -  -  This contract is on the white list, so the one on the side of the pool is the one that I saw.
    ///      Legal proxy. It can't tell if it's a proxy. `account` For yourself. Without this door,
    ///      Anyone can pick one right. `account` At the worst, he gave him authorization to Jiji. MEME In exchange for stock coins.
    function claimAndExercise(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        // CRITICAL Sequence: This door is at the sign.**Before**,But it doesn't write any status -- "Check the sign before you do anything."
        //    This rule is about...**Side effects**,No comparison. Put it in front of the third party to get it.
        //    You're not this one. leaf "The master of the land, not a word about what others have never received."
        if (msg.sender != account) revert NotAccount(seriesId, msg.sender, account);

        _consume(seriesId, account, amount, proof);

        _boundPool().exercise(seriesId, amount, account);

        emit Claimed(seriesId, account, amount, true);
    }

    /// @dev CRITICAL **One. leaf "Cha." -> Check -> "Sitting in place" is the only one that's ever achieved.**,{claim} and {claimAndExercise} Take it all.
    ///
    ///      It's both right, but then "the two entrances are identical" becomes an agreement that someone will remember to maintain.
    ///      It's a copy, it's guaranteed by the compiler. It's the most important line of the notes.
    ///
    ///      And in fixed order,**The sign is at the top.**:
    ///
    ///      | # | Door. | It's blocking that. |
    ///      |---|---|---|
    ///      | (1) | Not received | CRITICAL Replay - steal from the shared balance. |
    ///      | (2) | `amount != 0` | See? |
    ///      | (3) | Published root | - I'm looking at an empty space. root Check proof |
    ///      | 4 | proof It works. | Self-made leaf |
    ///
    ///      (2) It's not an attack.**The asymmetries between the two entrances**:`amount == 0` It's... leaf Yes.
    ///      {claimAndExercise} That side must have been turned off by the pool.`memeAmount` Other Organiser 0
    ///      `ExerciseRoundsToZeroMeme`),And... {claim} They'll consume it, turn it around. 0 A certificate of authority.
    ///      So it's the same one. leaf "Can you consume" has two answers -- the kind of asymmetries that the promissory notes are about to eliminate.
    ///
    ///      The location and freeze are written before return.**External calls always follow this function**(checks-effects-interactions):
    ///      The transfer of the right will be returned to the recipient, and the right to control will be given to the two at will. ERC-20.
    function _consume(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) private {
        if (claimed[seriesId][account]) revert AlreadyClaimed(seriesId, account);
        if (amount == 0) revert ZeroAmount(seriesId, account);

        bytes32 root = roots[seriesId];
        if (root == bytes32(0)) revert NoRoot(seriesId);
        if (!MerkleProof.verify(proof, root, leafOf(seriesId, account, amount))) {
            revert InvalidProof(seriesId, account, amount);
        }

        claimed[seriesId][account] = true;

        // First one. leaf Once consumed, the line is destined to die. See. {rootFrozen}.
        if (!rootFrozen[seriesId]) rootFrozen[seriesId] = true;
    }

    /// @dev The secured clearing pool. `pool == address(0)`,Only once you start calling it.
    ///      To Uncoded Address staticcall "Full and return empty." ABI Failed to decode -- the one revert
    ///      I don't know what to say. See you. {PoolBound} The same trade-off in the inside.
    function _boundPool() private view returns (IClearingPool) {
        address boundPool = pool;
        if (boundPool == address(0)) revert PoolNotBound();
        return IClearingPool(boundPool);
    }
}
