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
import {Warrant} from "../src/Warrant.sol";
import {IClearingPool} from "../src/interfaces/IClearingPool.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {MerkleTree} from "./helpers/MerkleTree.sol";
import {StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice 🔴 **反证用的 distributor：与真实实现的唯一区别是漏掉了标志位。**
///
/// 它存在的唯一理由，是证明「distributor 的权证余额永不低于全部未领取 leaf 之和」这条断言
/// **真的抓得住**那个攻击 —— 一条永远为真的断言和一条正确的断言长得一模一样。
/// 同 `test/invariant/` 下的 `LeakyPool` / `OvermintingPool`：**反证不是替身**，
/// 它不冒充任何我们要发布的东西，只用来给探测器一个必须变红的输入。
///
/// @dev 两个入口都照抄真实实现，但既不查也不写 `claimed` —— 也就是 issue #13 那张图里的那个漏洞。
contract ForgetfulDistributor is PoolBound, ERC1155Holder {
    mapping(uint256 seriesId => bytes32 root) public roots;

    function setRoot(uint256 seriesId, bytes32 root) external {
        roots[seriesId] = root;
    }

    function claim(uint256 seriesId, address account, uint256 amount, bytes32[] calldata proof) external {
        _verify(seriesId, account, amount, proof);
        IERC1155 book = IERC1155(address(IClearingPool(pool).warrant()));
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

/// @notice 一个**合约身份**的持有人，在收到权证的回调里再打一次 `claim`。
/// @dev 回调必须把内层的失败**吞掉并记下来**：不吞的话外层跟着回滚，就看不出内层被拒的理由了。
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

/// @notice **M1-8 领取 + 合并行权**（issue #13）。
///
/// 这张票交付的不是「两个便利函数」，而是一条结构：**本合约持有的是别人的权证**，
/// 而同一张 merkle leaf 上有两个消费入口。漏掉标志位不是「重复领自己的份额」，
/// 而是从共享余额里偷别人的 —— 调用者付自己的 MEME，拿走的是尚未领取者对应的股票代币。
///
/// 因此本文件的重心不在成功路径上，而在四件事上：
///
/// - **两条路径共写同一位**，四个方向全测（claim×2、c&e×2、claim→c&e、c&e→claim）；
/// - **权证余额永不低于全部未领取 leaf 之和** —— 那个攻击的直接防线，确定性与 fuzz 各一条，
///   外加一条 🔴 **反证**（{ForgetfulDistributor}）证明这条断言抓得住漏掉标志位的实现；
/// - **两条路径的许可级别不同**：`claim` 无许可、`claimAndExercise` 仅本人；
/// - **声明门查受益人**，因此未声明的 `account` 在 distributor 路径下同样被拒。
///
/// 测试驱动真实的四合约（issue #5 的测试缝），替身只出现在外部依赖那一层：金库、股票代币、MEME。
/// 真实标的上的复核在 `test/fork/RobinhoodDistributor.t.sol`。
contract MerkleDistributorTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    uint64 internal expiry;
    uint256 internal seriesId;

    uint128 internal constant STRIKE = 1850e18;

    /// @dev 整周铸给 distributor 的量 —— 恰好等于四张 leaf 之和。
    ///      「恰好」是刻意的：多铸一点会让「余额兜得住未领取」这条断言变得不敏感。
    uint256 internal constant MINTED = 100 ether;

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    address internal publisher = makeAddr("publisher");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    /// @dev 四个持有人与他们的份额。顺序即 leaf 顺序。
    address[4] internal accounts;
    uint256[4] internal amounts;

    /// @dev 测试自己维护的「哪张 leaf 已经被消费掉了」。
    ///      🔴 **不读合约的 `claimed`**：那样「余额 ≥ 未领取之和」会用被测对象自己的记账来定义
    ///      「未领取」，漏掉标志位的实现在这条断言下反而永远为真 —— 见 {ForgetfulDistributor}。
    bool[4] internal consumed;

    function setUp() public {
        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(publisher);
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        meme = new MemeToken();
        expiry = uint64(block.timestamp + 7 days);

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定，见 {FactoryStub}。
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave")];
        amounts = [uint256(40 ether), 30 ether, 20 ether, 10 ether];

        for (uint256 i = 0; i < accounts.length; i++) {
            _prepare(accounts[i]);
        }

        // 整周的权证一次性铸给 distributor —— 这就是「共享余额」的由来。
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), MINTED);

        vm.prank(publisher);
        distributor.setRoot(seriesId, MerkleTree.root(_leaves(seriesId)));
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev §6.4 里前端要引导用户做的那两步：签一次声明、把 MEME 授权给**清算池**（不是 distributor）。
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

    /// @dev 还没被消费掉的那些 leaf 的总额 —— 也就是 distributor 此刻**欠着**的权证。
    function _unclaimed() internal view returns (uint256 total) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!consumed[i]) total += amounts[i];
        }
    }

    /// @dev 🔴 **本票的核心断言**：托管的权证永远兜得住所有还没被领走的 leaf。
    ///      它在每一次状态变化之后都要成立 —— 所以下面每条测试都在动作之后立刻调它。
    /// @param book   权证合约。反证那条测试跑在另一套系统上，所以它是参数而不是字段。
    /// @param holder 托管方（distributor）
    function _assertCustodyCoversUnclaimed(Warrant book, address holder, uint256 series) internal view {
        assertGe(
            book.balanceOf(holder, series),
            _unclaimed(),
            unicode"🔴 distributor 的权证余额低于未领取 leaf 之和 —— 有人从共享余额里拿走了别人的份额"
        );
    }

    /// @dev 真实系统上的那一份，省掉两个每次都一样的参数。
    function _assertCustodyCoversUnclaimed() internal view {
        _assertCustodyCoversUnclaimed(warrant, address(distributor), seriesId);
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

    // ──────────────────── 形状：对外可写入口恰好这六个 ────────────────────

    /// @dev 与 `ClearingPool` 那条同源（`test/ClearingPool.t.sol`）：**读编译产物的 ABI**，
    ///      而不是挨个调一遍自己知道的函数。后来加进去的 `sweepWarrants()` 不会因为
    ///      没有哪条测试调用它而失效 —— 而本合约托管的是**全体未领取用户**的权证，
    ///      它多一个可写入口的分量，和池子多一个是同一量级的事。
    ///
    ///      两个 `onERC1155*Received` 按 ERC-1155 规范是非 view 的，所以它们在这张清单里。
    ///      它们不构成入口：除了返回魔数之外什么都不做。
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

    /// @dev publisher 是 immutable，填错只能重新部署一份 distributor（连带重新部署池子，
    ///      因为池子的 `distributor` 也是 immutable）—— 所以零地址在构造函数里挡掉。
    function test_constructor_rejectsAZeroPublisher() public {
        vm.expectRevert(MerkleDistributor.ZeroPublisher.selector);
        new MerkleDistributor(address(0));

        assertEq(distributor.publisher(), publisher, unicode"publisher 写进去了");
    }

    /// @dev 🔴 publisher 与部署者是两把钥匙：前者每周签一笔 `setRoot`，后者只在部署那天用一次。
    function test_publisherAndDeployerAreSeparateKeys() public view {
        assertEq(distributor.publisher(), publisher, "publisher");
        assertEq(distributor.deployer(), address(this), "deployer");
        assertTrue(distributor.publisher() != distributor.deployer(), unicode"两把钥匙可以不同");
    }

    /// @dev distributor 读到的权证，就是池子那个 `immutable` —— 它自己不另存一份。
    function test_warrantIsReadFromThePool() public view {
        assertEq(address(distributor.warrant()), address(warrant), "warrant");
    }

    // ──────────────────────── setRoot：仅 publisher ────────────────────────

    /// @dev 验收条款：**`setRoot` 仅 publisher。** 连部署者都不行 —— 它的权限在两笔 `setPool` 之后就用尽了。
    function test_setRoot_isOnlyForThePublisher() public {
        uint256 other = seriesId + 1;
        bytes32 root = keccak256("root");

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotPublisher.selector, stranger));
        vm.prank(stranger);
        distributor.setRoot(other, root);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotPublisher.selector, address(this)));
        distributor.setRoot(other, root);

        assertEq(distributor.roots(other), bytes32(0), unicode"两次尝试都没写进去");

        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.RootSet(other, root, bytes32(0));
        vm.prank(publisher);
        distributor.setRoot(other, root);
        assertEq(distributor.roots(other), root, "root");
    }

    /// @dev 零是「尚未发布」的哨兵值 —— 写进去等于什么都没做，却会让「有 root ⟹ 可领取」失真。
    function test_setRoot_rejectsTheZeroRoot() public {
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.ZeroRoot.selector, seriesId + 1));
        vm.prank(publisher);
        distributor.setRoot(seriesId + 1, bytes32(0));
    }

    /// @dev 🔴 root 的纠错窗口：**开始领取之前可改，第一张 leaf 被消费之后永久定死。**
    ///
    ///      两个极端都不可接受 —— 永久 write-once 让一个打错的 root 把整周分发全数错付且无法挽回；
    ///      永远可改则意味着 publisher 能在分发已经开始之后把剩下的份额重新指给任何人。
    ///      冻结点选在「第一个人依据这份 root 行动」的那一刻。
    function test_setRoot_mayBeCorrectedUntilTheFirstLeafIsConsumed() public {
        uint256 fresh = seriesId + 7;
        assertFalse(distributor.rootFrozen(fresh), unicode"还没人领 ⟹ 未冻结");

        // 打错了 —— 改过来
        vm.prank(publisher);
        distributor.setRoot(fresh, keccak256("typo"));
        vm.prank(publisher);
        distributor.setRoot(fresh, keccak256("corrected"));
        assertEq(distributor.roots(fresh), keccak256("corrected"), unicode"纠正生效了");

        // 本系列已经有人领过 ⟹ 冻结
        assertFalse(distributor.rootFrozen(seriesId), unicode"前置条件：还没人领");
        _claim(0);
        assertTrue(distributor.rootFrozen(seriesId), unicode"第一张 leaf 消费之后就冻上了");

        bytes32 published = distributor.roots(seriesId);
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.RootAlreadyFrozen.selector, seriesId, published));
        vm.prank(publisher);
        distributor.setRoot(seriesId, keccak256("rewrite"));

        assertEq(distributor.roots(seriesId), published, unicode"那次尝试没改动已发布的归属");
    }

    /// @dev `claimAndExercise` 同样会冻结 root —— 两条路径在这件事上也必须一致。
    function test_setRoot_isAlsoFrozenByTheCombinedPath() public {
        _claimAndExercise(0);
        assertTrue(distributor.rootFrozen(seriesId), unicode"合并路径同样冻结");
    }

    // ─────────────────────── leaf 编码：系列钉在里面 ───────────────────────

    /// @dev 编码是链下 Indexer（M4）与链上验证的**共同**约定，所以这里独立算一遍对齐；
    ///      同时钉住「哈希两次」—— 少哈希一次会让一段 64 字节的 leaf 原像与内部节点原像撞型。
    function test_leafOf_isTheDoubleHashedTriple() public view {
        bytes32 expectedLeaf = keccak256(bytes.concat(keccak256(abi.encode(seriesId, accounts[0], amounts[0]))));

        assertEq(distributor.leafOf(seriesId, accounts[0], amounts[0]), expectedLeaf, "leafOf");
        assertTrue(
            distributor.leafOf(seriesId, accounts[0], amounts[0])
                != keccak256(abi.encode(seriesId, accounts[0], amounts[0])),
            unicode"必须是哈希两次，不是一次"
        );
    }

    /// @dev 这组 golden vector 由 `@openzeppelin/merkle-tree@1.0.8` 的默认
    ///      `StandardMerkleTree.of(values, ["uint256", "address", "uint256"])` 生成。
    ///      输入故意乱序且有五张 leaf，覆盖默认的 leaf 排序与 complete-tree 形状；不能用本仓库的
    ///      `MerkleTree` helper 重算，否则又变成「测试实现与自己一致」而不是互操作证明。
    ///
    ///      🔴 **一组伪造但自洽的向量，跑起来和真的一模一样绿。** 所以这些字面量的价值全部取决于
    ///      它们真的来自那个库。复算命令写在**函数体**里，不写在这里：NatSpec 会把 at 符号后面
    ///      那一串当成文档标签，整个文件编不过。
    ///
    ///      ✅ **2026-08-18（issue #66）起这句话不再需要靠人手跑那条命令。** 本仓库有 JS 工具链了
    ///      （`offchain/merkle`，决策 44），于是每次门禁都替读者验一遍，两步接起来：
    ///      ① `offchain/merkle/test/selfcheck.js` 拿装在 `node_modules` 里的官方库现算，与
    ///      `offchain/merkle/test/vectors/oz-standard-v1.json` 逐位比；
    ///      ② `offchain/merkle/test/crosscheck-solidity-vector.js` 拿那份向量与**下面这些字面量**
    ///      逐位比（root、按输入次序的五个 leaf、`_ozProof` 的五条 proof，顺序也比），
    ///      并反过来确认这段函数里没有任何一个 32 字节字面量是向量之外的。
    ///      入口是 `script/ci.sh merkle`。🔴 改这里的任何一个字面量，都要同时改那份向量，否则判红。
    function test_claim_acceptsDefaultOpenZeppelinStandardMerkleTreeVectors() public {
        // 复算这组向量（输出应与下面的 root、五个 leaf、五条 proof 逐字节相同）：
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
        // ⚠️ `t.entries()` 按 OZ **排序后**的次序给出，而下面的数组按**输入**次序排列。
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

        // 按**输入**次序排列的 leaf 哈希（不是 OZ 排序后的次序）。
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

        // 🔴 向量里的 seriesId 是**固定值**，而 `openSeries` 算出的 id 含夹具的动态地址与 expiry ——
        //    所以这个系列开不出来。这里以池子的身份铸给 distributor，走的仍是真实的、已绑定的 `Warrant`
        //    与它真实的授权调用方（同 `test/DeploySystem.t.sol::test_distributorCanReceiveWarrants` 的先例）。
        //    ⚠️ 因此这条测试证明的是**编码与 proof 的互操作**，不是托管路径 —— 托管另有专门的断言。
        vm.prank(address(pool));
        warrant.mint(address(distributor), ozSeries, 53 ether);

        // 每条 proof 都从同一次 StandardMerkleTree 输出里原样抄来。
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
            assertEq(warrant.balanceOf(ozAccounts[i], ozSeries), ozAmounts[i], "OZ proof delivered the warrant");
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

    /// @dev 🔴 **`seriesId` 在 leaf 里，所以同一份 root 误发给两个系列也偷不到东西。**
    ///      标志位是按系列分开的，因此少了这一维，一张 leaf 就能在两个系列上各消费一次 ——
    ///      第二次动的是另一批未领取用户的共享余额。
    function test_leafIsBoundToItsSeries_soTheSameProofCannotTravel() public {
        // 开第二个系列，铸同样多的权证给 distributor，然后把**第一个系列的 root** 误发给它
        uint256 otherSeries = vault.openSeries(address(meme), address(stock), expiry + 1 days, STRIKE);
        vault.depositAndMint(otherSeries, address(distributor), MINTED);
        vm.prank(publisher);
        distributor.setRoot(otherSeries, MerkleTree.root(_leaves(seriesId)));

        // 第一个系列的 proof 在第二个系列上验不过 —— leaf 里的 seriesId 不同
        vm.expectRevert(
            abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, otherSeries, accounts[0], amounts[0])
        );
        vm.prank(keeper);
        distributor.claim(otherSeries, accounts[0], amounts[0], _proof(0));

        assertEq(warrant.balanceOf(address(distributor), otherSeries), MINTED, unicode"第二个系列一枚没动");
    }

    // ──────────────────── claim：permissionless，只进 leaf 指定的 account ────────────────────

    /// @dev 验收条款：**`claim` permissionless；权证只进 leaf 指定的 `account`。**
    ///
    ///      代提交拿不走东西 —— 收货地址不是 `msg.sender`。这正是「keeper 代付 gas，
    ///      持有者零操作也能收到」成立的原因。
    function test_claim_isPermissionlessAndDeliversOnlyToTheLeafAccount() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.Claimed(seriesId, accounts[0], amounts[0], false);
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));
        consumed[0] = true;

        assertEq(warrant.balanceOf(accounts[0], seriesId), amounts[0], unicode"权证进了 leaf 指定的账户");
        assertEq(warrant.balanceOf(keeper, seriesId), 0, unicode"代提交者一枚都拿不到");
        assertEq(
            warrant.balanceOf(address(distributor), seriesId),
            MINTED - amounts[0],
            unicode"共享余额只少了这一份"
        );
        assertTrue(distributor.claimed(seriesId, accounts[0]), "claimed");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 领到的权证是**真的**权证：持有人可以自己行权，也可以卖掉。
    ///      `claim` 这条路径不碰声明门、不碰 MEME —— 受限辖区的用户因此能完整参与
    ///      「持有 → 累积 → 领取 → 卖出」。
    function test_claim_deliversWarrantsTheHolderCanUseHimself() public {
        _claim(1);

        vm.prank(accounts[1]);
        pool.exercise(seriesId, amounts[1], accounts[1]);

        assertEq(stock.balanceOf(accounts[1]), amounts[1], unicode"自己行权照常");
        assertEq(meme.balanceOf(0x000000000000000000000000000000000000dEaD), _expectedMeme(amounts[1]), "meme");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 验收条款：**同一 proof 第二次提交必 revert。**
    function test_claim_rejectsAReplayedProof() public {
        _claim(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(warrant.balanceOf(accounts[0], seriesId), amounts[0], unicode"没有第二份");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 改一个数就验不过 —— 这是 merkle 那一半的意义所在。
    function test_claim_rejectsATamperedAmount() public {
        uint256 inflated = amounts[0] + 1;

        vm.expectRevert(
            abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, seriesId, accounts[0], inflated)
        );
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], inflated, _proof(0));

        // 换个人也不行：proof 属于 leaf，不属于提交者
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.InvalidProof.selector, seriesId, stranger, amounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, stranger, amounts[0], _proof(0));

        _assertCustodyCoversUnclaimed();
    }

    /// @dev root 未发布时干净拒绝。权证已经在 distributor 手上了，等 publisher 发布即可 ——
    ///      **只有延迟，没有损失**（同 `rollExpired` 无后继系列时的那一档）。
    function test_claim_rejectsBeforeTheRootIsPublished() public {
        uint256 fresh = vault.openSeries(address(meme), address(stock), expiry + 2 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), MINTED);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(fresh, accounts[0], amounts[0]);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NoRoot.selector, fresh));
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], amounts[0], MerkleTree.proofFor(leaves, 0));

        // 补发之后可追溯领取
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], amounts[0], MerkleTree.proofFor(leaves, 0));
        assertEq(warrant.balanceOf(accounts[0], fresh), amounts[0], unicode"root 补发后照常领取");
    }

    /// @dev 🔴 零份额的 leaf 在两个入口上**必须**同样被拒。不挡的话 `claim` 会消费掉一张
    ///      `claimAndExercise` 永远消费不掉的 leaf（池子那边取整到 0 必 revert）——
    ///      两个入口对「哪些 leaf 可消费」给出两个答案，正是本票要消灭的那类不对称。
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

        assertFalse(distributor.claimed(fresh, accounts[0]), unicode"两次都没消费掉这张 leaf");
    }

    // ──────────────────── claimAndExercise：两笔完成，仅本人 ────────────────────

    /// @dev 验收条款：**用户路径为两笔 —— approve + claimAndExercise。**
    ///
    ///      权证**不经过** account 的手：从 distributor 直接销毁；MEME 从 account 拉走
    ///      （他授权的是**池子**）；股票代币直达 account。
    function test_claimAndExercise_completesInTwoTransactions() public {
        address alice = accounts[0];
        uint256 amount = amounts[0];
        uint256 memeCost = _expectedMeme(amount);
        uint256 memeBefore = meme.balanceOf(alice);

        // 第 1 笔：授权（`setUp` 里已经做过，这里把它写出来是因为它是「两笔」中的一笔）
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);

        // 第 2 笔：领取并行权
        vm.expectEmit(true, true, true, true, address(distributor));
        emit MerkleDistributor.Claimed(seriesId, alice, amount, true);
        vm.prank(alice);
        distributor.claimAndExercise(seriesId, alice, amount, _proof(0));
        consumed[0] = true;

        assertEq(warrant.balanceOf(alice, seriesId), 0, unicode"权证从头到尾没经过受益人的手");
        assertEq(warrant.balanceOf(address(distributor), seriesId), MINTED - amount, unicode"从共享余额里销毁");
        assertEq(memeBefore - meme.balanceOf(alice), memeCost, unicode"MEME 从 account 账上扣走");
        assertEq(stock.balanceOf(alice), amount, unicode"股票代币直达 account");
        assertEq(pool.series(seriesId).exercised, amount, "exercised");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 验收条款：**非 `account` 本人调用 `claimAndExercise` 被拒。**
    ///
    ///      🔴 这道门必须长在 distributor 上：池子的调用方白名单是「受益人本人**或** distributor」，
    ///      而本合约正好在白名单里 —— 池子分辨不出这次代行权是不是 `account` 自己要的。
    ///      所以下面把每一个「其实都齐了」的条件都摆上：受益人已声明、已授权、proof 也是真的。
    function test_claimAndExercise_rejectsEveryCallerButTheAccount() public {
        address alice = accounts[0];

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, keeper, alice));
        vm.prank(keeper);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        // 连 publisher 都不行
        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.NotAccount.selector, seriesId, publisher, alice));
        vm.prank(publisher);
        distributor.claimAndExercise(seriesId, alice, amounts[0], _proof(0));

        assertFalse(distributor.claimed(seriesId, alice), unicode"leaf 没有被消费");
        assertEq(meme.balanceOf(alice), 1e31, unicode"一枚 MEME 都没被别人替他烧掉");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 验收条款：**未签声明的 `account` 在 distributor 路径下同样被拒。**
    ///
    ///      🔴 这是「声明门查受益人、不查调用方」在本路径上的可观察后果。查调用方的话，
    ///      distributor 签一次全体用户就都过门了 —— 这道门会被整个掏空。
    ///      门**结构上锁不死任何人**（不变量 6③）：他自己签一次就过了。
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

        // 整笔回滚 ⟹ leaf 没被消费掉，他签完照样能用
        assertFalse(distributor.claimed(fresh, newcomer), unicode"被拒的那一笔没有吃掉他的 leaf");

        vm.prank(newcomer);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        vm.prank(newcomer);
        distributor.claimAndExercise(fresh, newcomer, share, proof);
        assertEq(stock.balanceOf(newcomer), share, unicode"签过之后照常");
    }

    /// @dev 行权失败时**整笔回滚**，尤其是 `claimed` —— 否则一次失败的行权会把用户的 leaf
    ///      白白吃掉，而权证还在 distributor 手上：那是一种谁也修不了的损失（无 admin）。
    ///      这里用「系列已结算」触发失败（不变量 4①）。
    function test_claimAndExercise_doesNotBurnTheLeafWhenTheExerciseFails() public {
        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertFalse(distributor.claimed(seriesId, accounts[0]), unicode"leaf 还在");
        assertFalse(distributor.rootFrozen(seriesId), unicode"也没有把 root 冻上");

        // 结算之后 `claim` 仍然可用：领到的是一份行权不了的权证，但它仍是 account 的资产
        _claim(0);
        assertEq(warrant.balanceOf(accounts[0], seriesId), amounts[0], unicode"结算后仍可领取");
    }

    /// @dev 合并路径自己的重放。
    function test_claimAndExercise_rejectsAReplayedProof() public {
        _claimAndExercise(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(stock.balanceOf(accounts[0]), amounts[0], unicode"只拿到一份");
        _assertCustodyCoversUnclaimed();
    }

    // ──────────────── 🔴 两条路径共写同一位：四个方向全测 ────────────────

    /// @dev 验收条款：**`claim` 之后 `claimAndExercise` 必 revert。**
    function test_claimThenClaimAndExercise_isRejected() public {
        _claim(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(accounts[0]);
        distributor.claimAndExercise(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(stock.balanceOf(accounts[0]), 0, unicode"没有额外的股票代币出池");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 验收条款：**反向亦然 —— `claimAndExercise` 之后 `claim` 必 revert。**
    ///
    ///      🔴 这个方向才是那个攻击的形状：行权已经从共享余额里烧掉了 `amount`，
    ///      若还能再 `claim` 一次，转出去的就是别人的那一份。
    function test_claimAndExerciseThenClaim_isRejected() public {
        _claimAndExercise(0);

        vm.expectRevert(abi.encodeWithSelector(MerkleDistributor.AlreadyClaimed.selector, seriesId, accounts[0]));
        vm.prank(keeper);
        distributor.claim(seriesId, accounts[0], amounts[0], _proof(0));

        assertEq(warrant.balanceOf(accounts[0], seriesId), 0, unicode"没有凭空多出一份权证");
        _assertCustodyCoversUnclaimed();
    }

    /// @dev 四个持有人各走一条路径，中间穿插重放尝试 —— 每一步之后托管都必须兜得住剩下的人。
    function test_custodyCoversUnclaimedThroughAMixedSequence() public {
        _assertCustodyCoversUnclaimed();

        _claimAndExercise(0);
        _assertCustodyCoversUnclaimed();

        _claim(1);
        _assertCustodyCoversUnclaimed();

        // 两个方向的重放各来一次，都必须弹回去
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

        // 四张 leaf 全部消费完，共享余额归零 —— 一枚不多、一枚不少
        assertEq(warrant.balanceOf(address(distributor), seriesId), 0, unicode"整周的权证正好分完");
        assertEq(_unclaimed(), 0, unicode"没有未领取的 leaf 了");
    }

    /// @dev 同一件事的 fuzz 版：随机顺序、随机路径、随机重放，每一步之后都断言托管兜得住。
    ///      失败的动作照样要断言 —— 一次被拒的重放**不该**改变任何东西。
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

    /// @dev 🔴 **反证：把标志位拿掉，上面那条断言必须变红。**
    ///
    ///      一条永远为真的断言和一条正确的断言长得一模一样，所以这里给探测器一个必须抓住的输入：
    ///      {ForgetfulDistributor} 与真实实现逐行相同，只少了「查 + 置位」那两句。
    ///      于是 alice 重放两次，从 100 ether 的共享余额里拿走 80 ——
    ///      **她付的是自己的 MEME，拿走的却是 bob / carol / dave 的股票代币**，
    ///      而那三个人手里握着有效 proof，已无货可兑。
    function test_theDetectorDetects_aDistributorThatForgetsTheClaimedFlag() public {
        (ForgetfulDistributor forgetful, ClearingPool badPool, Warrant badWarrant) = _deployForgetfulSystem();

        address alice = accounts[0];
        bytes32[] memory leaves = _leaves(seriesId);
        bytes32[] memory proof = MerkleTree.proofFor(leaves, 0);

        vm.prank(alice);
        meme.approve(address(badPool), type(uint256).max);

        vm.prank(alice);
        forgetful.claimAndExercise(seriesId, alice, amounts[0], proof);
        consumed[0] = true;
        _assertCustodyCoversUnclaimed(badWarrant, address(forgetful), seriesId); // 第一次合法，仍然成立

        // 第二次是重放 —— 没有标志位挡它
        vm.prank(alice);
        forgetful.claimAndExercise(seriesId, alice, amounts[0], proof);

        assertEq(stock.balanceOf(alice), 2 * amounts[0], unicode"她拿走了两份，其中一份不是她的");
        assertLt(
            badWarrant.balanceOf(address(forgetful), seriesId),
            _unclaimed(),
            unicode"托管已经兜不住未领取的 leaf —— 探测器必须在这里变红"
        );

        // 受害者是具体的：bob 握着有效 proof，却已无货可兑
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

    /// @dev 反证系统：真实的池子与权证，只把 distributor 换成漏了标志位的那一份。
    ///      注册表照旧复用 —— 四个持有人已经在上面声明过了，而声明与池子无关。
    function _deployForgetfulSystem()
        private
        returns (ForgetfulDistributor forgetful, ClearingPool badPool, Warrant badWarrant)
    {
        badWarrant = new Warrant();
        forgetful = new ForgetfulDistributor();
        // 反证系统自带一份身份根：它是另一个池子，而池子的 authenticator 是 immutable。
        FactoryStub badFactory = new FactoryStub();
        badPool = new ClearingPool(badWarrant, address(forgetful), registry, badFactory.registry());
        badWarrant.setPool(address(badPool));
        forgetful.setPool(address(badPool));

        VaultStub badVault = new VaultStub(badPool);
        badFactory.bind(address(meme), address(badVault));
        stock.mint(address(badVault), 1e30);
        badVault.approve(stock, type(uint256).max);

        uint256 id = badVault.openSeries(address(meme), address(stock), expiry, STRIKE);
        assertEq(id, seriesId, unicode"两套系统里同一组参数算出同一个 seriesId");
        badVault.depositAndMint(id, address(forgetful), MINTED);

        forgetful.setRoot(id, MerkleTree.root(_leaves(id)));
    }

    // ──────────────────────────── 再入与未绑定 ────────────────────────────

    /// @dev `claim` 把控制权交给收款方（ERC-1155 对合约收款方强制回调）。标志位已经在回调**之前**
    ///      置位，所以同一张 leaf 的重放本来就进不来；`nonReentrant` 是在此之上的第二道 ——
    ///      它让「两个入口不能交错」成为结构。
    ///
    ///      🔴 这里回调里领的是**另一个账户**的 leaf（`claim` 无许可，代提交是合法用法），
    ///      因为同一账户的第二张 leaf 本来就消费不掉（一个 (系列, 账户) 只有一位标志）——
    ///      拿那个当输入的话，这条测试会因为**别的**理由通过。
    ///      代价因此是具体的：批量投递的合约钱包不能在回调里顺手领下一张，分两笔即可。
    function test_claim_isNotReentrant() public {
        ReclaimingWallet wallet = new ReclaimingWallet();
        uint256 fresh = vault.openSeries(address(meme), address(stock), expiry + 4 days, STRIKE);
        vault.depositAndMint(fresh, address(distributor), 30 ether);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleTree.leafOf(fresh, address(wallet), 10 ether);
        leaves[1] = MerkleTree.leafOf(fresh, accounts[0], 20 ether); // 另一个账户的 leaf
        vm.prank(publisher);
        distributor.setRoot(fresh, MerkleTree.root(leaves));

        wallet.arm(
            distributor,
            abi.encodeCall(MerkleDistributor.claim, (fresh, accounts[0], 20 ether, MerkleTree.proofFor(leaves, 1)))
        );
        wallet.claim(fresh, 10 ether, MerkleTree.proofFor(leaves, 0));

        assertTrue(wallet.reentered(), unicode"前置条件：回调真的打进来了");
        assertFalse(wallet.reentrySucceeded(), unicode"内层领取必须被拒");
        assertEq(
            wallet.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护"
        );
        assertEq(warrant.balanceOf(address(wallet), fresh), 10 ether, unicode"只领到了外层那一份");
        assertFalse(distributor.claimed(fresh, accounts[0]), unicode"内层那张 leaf 没被消费");

        // 分两笔就照常 —— 被挡住的只是「交错」，不是这次领取本身
        vm.prank(keeper);
        distributor.claim(fresh, accounts[0], 20 ether, MerkleTree.proofFor(leaves, 1));
        assertEq(warrant.balanceOf(accounts[0], fresh), 20 ether, unicode"第二笔照常");
    }

    /// @dev 未绑定的 distributor 是**惰性**的：收不到权证，也发不出货。
    ///      这条在真实流程里不可达（部署脚本同一段 broadcast 里就绑好了），
    ///      挡掉是为了让失败停在一句说得清的话上。
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
        unbound.warrant();
    }

    // ────────────────────────── 滚存之后的下一周 ──────────────────────────

    /// @dev 到期未行权的抵押品滚进后继系列时，权证也是铸给 **distributor** 的（`rollExpired`）——
    ///      所以下一周的 root 一发布，那批权证照常可领。这条把 M1-7 与本票接起来。
    function test_rolledWarrantsAreClaimableUnderTheNextWeeksRoot() public {
        _claimAndExercise(0); // alice 行权了，剩下 60 ether 会滚走

        uint64 nextExpiry = expiry + 7 days;
        uint256 nextSeries = vault.openSeries(address(meme), address(stock), nextExpiry, STRIKE);

        vm.warp(expiry);
        pool.pokeGating(address(stock));
        vm.warp(block.timestamp + 48 hours);
        pool.settleExpired(seriesId);
        pool.rollExpired(seriesId, nextSeries);

        uint256 rolled = MINTED - amounts[0];
        assertEq(warrant.balanceOf(address(distributor), nextSeries), rolled, unicode"滚存铸给了 distributor");

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = MerkleTree.leafOf(nextSeries, accounts[1], rolled);
        vm.prank(publisher);
        distributor.setRoot(nextSeries, MerkleTree.root(leaves));

        vm.prank(keeper);
        distributor.claim(nextSeries, accounts[1], rolled, MerkleTree.proofFor(leaves, 0));
        assertEq(warrant.balanceOf(accounts[1], nextSeries), rolled, unicode"下一周照常领取");
    }
}
