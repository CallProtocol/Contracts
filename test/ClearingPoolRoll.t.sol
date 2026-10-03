// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {IssuerComplianceStub, IssuerGatedStockToken, IssuerPauseManagerStub} from "./helpers/IssuerGating.sol";
import {MemeToken} from "./helpers/MemeToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";
import {CollateralCheck} from "./invariant/Invariant1And2MintingPath.t.sol";

/// @notice **M1-7 池内滚存**（issue #12）。
///
/// 这张票只有一件事是难的，而它不在那几行赋值里：**「滚存不是转出」这句话必须是可验证的，
/// 不是一句措辞。** 所以本文件的每一条成功路径都断言同一件事的三个面：
///
/// | 面 | 断言 |
/// |---|---|
/// | 余额 | 池内该股票代币的余额在滚存前后**一个 wei 都不动** |
/// | 事件 | 这笔交易里**没有**该股票代币的 `Transfer` —— 找不到才是对的 |
/// | 账 | `remainder` 的减少量 == 后继 `deposited` / `minted` 的增量 == 新铸权证量（不变量 7） |
///
/// 第二个面单独列出来，是因为前两个面都过、账却是错的这件事**发生过**的形状只有一种：
/// 某天有人在这里加了一笔「先转出去再转回来」。余额差看不见它，事件看得见。
///
/// 🔴 另一条主线是**不变量 1 跨滚存的形式**：滚存之后前序系列的 `deposited` 还留着那笔已经被
/// 重新归属的数，所以逐系列的 1① 只在**未结算**范围内有意义，跨滚存必须断言全局的 1②。
/// issue #5 点名：**不得把 1① 削弱成能通过的样子**。这两件事的区别由
/// `test_roll_theSettledPredecessorIsSoundOnlyBecause1aExcludesIt` 当场演示。
///
/// 不变量 5 / 7 的 fuzz 形式在 `test/invariant/Invariant5And7RollAndCustody.t.sol`；
/// 真实 GME 上的复核在 `test/fork/RobinhoodRoll.t.sol`。
contract ClearingPoolRollTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    IssuerPauseManagerStub internal issuerPause;
    IssuerComplianceStub internal issuerCompliance;
    IssuerGatedStockToken internal stock;
    MemeToken internal meme;

    /// @dev 第二对代币只为一件事服务：把「同 MEME、同股票代币」那道门的两维**分开**测。
    ///      共用一对的话，两条断言里总有一条其实是另一条的影子。
    IssuerGatedStockToken internal otherStock;
    MemeToken internal otherMeme;

    uint128 internal constant STRIKE = 1850e18;
    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant EXERCISED = 30 ether;
    uint128 internal constant REMAINDER = uint128(DEPOSIT - EXERCISED);

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev ERC-20 `Transfer(address,address,uint256)` 的 topic0。**字面量算一遍，不从代币身上读** ——
    ///      要证明「这里没有转账」，就不能拿被观察对象来定义什么叫转账。
    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    uint64 internal expiry;
    uint64 internal nextExpiry;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        otherStock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();
        otherMeme = new MemeToken();

        // 两只 MEME 各自登记 —— 这里**故意登记成同一个金库替身**：滚存要证的是「后继必须是同一对
        // (MEME, 股票代币)」，多一个金库只会给那条断言多一个无关变量。
        factory.bind(address(meme), address(vault));
        factory.bind(address(otherMeme), address(vault));

        // 同 `ClearingPoolSettlement.t.sol`：本地默认时间戳是 1，而 `clearedAt + 48h` 与 `expiry`
        // 的大小关系不该被一个不真实的起点左右。
        vm.warp(1_800_000_000);
        expiry = uint64(block.timestamp + 7 days);
        nextExpiry = uint64(block.timestamp + 14 days);

        stock.mint(address(vault), 1e30);
        otherStock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);
        vault.approve(otherStock, type(uint256).max);

        vm.prank(alice);
        registry.attest(0, TERMS_0, ATTESTATION_0);
        meme.mint(alice, 1e31);
        vm.prank(alice);
        meme.approve(address(pool), type(uint256).max);
    }

    // ─────────────────────────────── 脚手架 ───────────────────────────────

    /// @dev 一个**已结算、余量 70** 的前序系列。三条被反复用到的性质写在一处：
    ///      存入 100、行权 30、到期结算 ⟹ `remainder == 70`，且池内确实还剩 70。
    function _settledPredecessor() internal returns (uint256 seriesId) {
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.prank(alice);
        pool.exercise(seriesId, EXERCISED, alice);

        vm.warp(expiry);
        pool.settleExpired(seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"前置条件：余量是 70");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"前置条件：池里也确实剩 70");
    }

    function _openSuccessor() internal returns (uint256) {
        return vault.openSeries(address(meme), address(stock), nextExpiry, STRIKE);
    }

    function _stocks() internal view returns (address[] memory list) {
        list = new address[](2);
        list[0] = address(stock);
        list[1] = address(otherStock);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    /// @dev 这一批日志里有没有 `token` 发出的 ERC-20 `Transfer`。
    function _sawTransferFrom(Vm.Log[] memory logs, address token) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != token) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER_TOPIC) return true;
        }
        return false;
    }

    /// @dev 每条成功滚存都要看它自己的日志，不能只凭最终余额推断中途没有转出再转回。
    function _rollAndAssertNoStockTransfer(uint256 seriesId, uint256 nextSeriesId) internal {
        _rollAndAssertNoStockTransferAs(address(0), seriesId, nextSeriesId);
    }

    /// @dev `address(0)` 保留测试合约作为调用方；其余地址用于钉住无许可路径。
    function _rollAndAssertNoStockTransferAs(address caller, uint256 seriesId, uint256 nextSeriesId) internal {
        vm.recordLogs();
        if (caller != address(0)) vm.prank(caller);
        pool.rollExpired(seriesId, nextSeriesId);

        assertFalse(
            _sawTransferFrom(vm.getRecordedLogs(), address(stock)),
            unicode"🔴 滚存里出现了一次股票代币转账"
        );
    }

    // ─────────────────── 判据自检：这个探测器不是睡着的 ───────────────────

    /// @dev 🔴 `_sawTransferFrom` 是本文件里九条断言共用的判据，而它们**全都是否定式**的
    ///      （「找不到才是对的」）。否定式断言有一种独有的坏法：判据本身失灵时，
    ///      九条断言会**一起**静默变成空转 —— 还是绿的，但什么都不再检查。
    ///
    ///      不变量文件里同一件事由 `ROLL_THROUGH_VAULT` 后门反证（那里的探测器**必须响**）；
    ///      这个文件里没有后门，所以正向对照写在这里：行权确实会让股票代币发出 `Transfer`，
    ///      判据必须看得见它。
    ///
    ///      **两个方向都要。** 只证明「它会响」的话，一个恒真的判据同样通过 ——
    ///      所以第二条断言拿一只全程没动过的代币问同一个判据，它必须沉默。
    function test_theTransferDetectorFiresOnARealStockTransfer() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);

        vm.recordLogs();
        vm.prank(alice);
        pool.exercise(seriesId, EXERCISED, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            _sawTransferFrom(logs, address(stock)),
            unicode"行权真的转走了股票代币，判据却没看见 —— 那九条「没有 Transfer」全是空转"
        );
        assertFalse(
            _sawTransferFrom(logs, address(otherStock)), unicode"判据对一只全程没动过的代币也响了"
        );
    }

    // ──────────────────── 不变量 7：滚存守恒，且抵押品不出池 ────────────────────

    /// @notice 本票的核心：**四个数相等，而池内余额一个 wei 都不动。**
    ///
    /// @dev 顺带钉住无许可：调用方是一个跟这个系列毫无关系的陌生地址。
    ///      「任何人可调」不是接口上的一句话，它是活性保证 —— 运营方消失时余量不该卡住（user story 19）。
    function test_roll_reattributesInsideThePoolWithoutMovingAWei() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        uint256 poolBalanceBefore = stock.balanceOf(address(pool));
        uint256 distributorWarrantsBefore = warrant.balanceOf(address(distributor), nextSeriesId);
        ClearingPool.Series memory nextBefore = pool.series(nextSeriesId);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Rolled(seriesId, nextSeriesId, REMAINDER);
        _rollAndAssertNoStockTransferAs(stranger, seriesId, nextSeriesId);

        // ① 余额：一个 wei 都不动
        assertEq(stock.balanceOf(address(pool)), poolBalanceBefore, unicode"🔴 抵押品离开过池子");

        // ② 事件：共享 helper 已断言这笔交易没有该股票代币的 Transfer

        // ③ 账：四个数相等
        ClearingPool.Series memory prior = pool.series(seriesId);
        ClearingPool.Series memory next = pool.series(nextSeriesId);
        assertEq(prior.remainder, 0, unicode"前序余量归零");
        assertEq(next.deposited - nextBefore.deposited, REMAINDER, unicode"后继 deposited 增量");
        assertEq(next.minted - nextBefore.minted, REMAINDER, unicode"后继 minted 增量");
        assertEq(
            warrant.balanceOf(address(distributor), nextSeriesId) - distributorWarrantsBefore,
            REMAINDER,
            unicode"新铸权证量"
        );

        // 前序那本账**不改写**：`deposited` / `minted` / `exercised` 记的是它自己的历史。
        assertEq(prior.deposited, DEPOSIT, unicode"前序 deposited 不动");
        assertEq(prior.minted, DEPOSIT, unicode"前序 minted 不动");
        assertEq(prior.exercised, EXERCISED, unicode"前序 exercised 不动");
        assertTrue(prior.settled, "settled");
    }

    /// @dev 滚出来的权证**真的能用**：由 `distributor` 代 alice 行权（#13 的 `claimAndExercise` 形状），
    ///      抵押品这才第一次离开池子 —— 而且恰好等于行权量。
    ///
    ///      少了这条，「滚存成功」只证明了几个计数器对得上，没证明用户拿得到东西。
    function test_roll_theRolledWarrantsAreExercisableInTheSuccessor() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        uint256 memeBefore = meme.balanceOf(alice);

        // distributor 以**自己**的身份调，受益人是 alice —— 声明门查的是 alice（见 `exercise`）。
        vm.prank(address(distributor));
        pool.exercise(nextSeriesId, REMAINDER, alice);

        assertEq(stock.balanceOf(alice), EXERCISED + REMAINDER, unicode"滚过来的那部分照常兑付");
        assertEq(stock.balanceOf(address(pool)), 0, unicode"池子清空 —— 每一枚都兑给了持有人");
        assertEq(warrant.balanceOf(address(distributor), nextSeriesId), 0, unicode"权证按量销毁");
        assertEq(
            memeBefore - meme.balanceOf(alice),
            (uint256(REMAINDER) * STRIKE) / 1e18,
            unicode"MEME 按后继系列的行权价扣除"
        );
    }

    /// @dev 滚存不读发行方门控，也不动代币，所以**发行方冻结拦不住它**。
    ///      结算被门控结构性阻止（那是延期），但一旦结算发生，池内记账不该再受外部合约摆布。
    function test_roll_worksWhileTheIssuerGatesThePool() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        issuerCompliance.setBlocked(address(stock), address(pool), true);
        pool.pokeGating(address(stock));
        assertEq(pool.exerciseDeadline(nextSeriesId), type(uint64).max, unicode"前置条件：门控已被观测到");

        _rollAndAssertNoStockTransferAs(keeper, seriesId, nextSeriesId);

        assertEq(pool.series(seriesId).remainder, 0, unicode"门控期间照常滚存");
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, "minted");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"而抵押品仍然一个 wei 没动");
    }

    /// @dev 守恒对任意存入 / 行权组合都成立，不只是 100 / 30 那一组。
    function testFuzz_roll_conservesEveryWei(uint128 deposit, uint128 exercised) public {
        deposit = uint128(bound(deposit, 1e15, 1e24));
        exercised = uint128(bound(exercised, 0, deposit));

        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, deposit);

        if (exercised != 0 && (uint256(exercised) * STRIKE) / 1e18 != 0) {
            vm.prank(alice);
            pool.exercise(seriesId, exercised, alice);
        } else {
            exercised = 0;
        }

        vm.warp(expiry);
        pool.settleExpired(seriesId);

        uint128 remainder = deposit - exercised;
        uint256 nextSeriesId = _openSuccessor();
        uint256 poolBalanceBefore = stock.balanceOf(address(pool));

        if (remainder == 0) {
            vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
            pool.rollExpired(seriesId, nextSeriesId);
            return;
        }

        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        assertEq(stock.balanceOf(address(pool)), poolBalanceBefore, unicode"滚存前后池内余额必须相等");
        assertEq(pool.series(seriesId).remainder, 0, "remainder");
        assertEq(pool.series(nextSeriesId).deposited, remainder, "deposited");
        assertEq(pool.series(nextSeriesId).minted, remainder, "minted");
        assertEq(warrant.balanceOf(address(distributor), nextSeriesId), remainder, unicode"新铸权证量");
    }

    // ──────────────── 不变量 1 跨滚存：只有全局那一款还成立 ────────────────

    /// @notice 🔴 **验收条款：已结算的前序系列正因被排除在 1① 之外才成立。**
    ///
    /// @dev 滚存之后前序系列的账上还写着 `minted − exercised == 70`，而属于它的抵押品**已经交给后继了**。
    ///      如果把 1① 的求和范围放宽到全部系列（或者更糟 —— 为了让它过而把判据改写成别的东西），
    ///      同一批抵押品会被数两遍：下面第一段断言的正是那个错误答案 140 > 池内余额 70。
    ///
    ///      让这件事**没有害处**的不是判据的措辞，是 `settled ⟹ exercise revert`（不变量 4①）：
    ///      前序那 70 枚权证从结算那一刻起就不再是债权。所以正确的读法只有一种 ——
    ///      逐系列那一款只在**未结算**范围内有意义，跨滚存的偿付覆盖由全局的 1② 负责。
    function test_roll_theSettledPredecessorIsSoundOnlyBecause1aExcludesIt() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        ClearingPool.Series memory prior = pool.series(seriesId);
        ClearingPool.Series memory next = pool.series(nextSeriesId);

        // ① 把已结算的系列一起数进去 —— 得到的是一个池子兜不住的数字。
        uint256 naiveClaim = (prior.minted - prior.exercised) + (next.minted - next.exercised);
        assertEq(
            naiveClaim,
            2 * uint256(REMAINDER),
            unicode"前置条件：天真求和确实把同一批抵押品数了两遍"
        );
        assertGt(naiveClaim, stock.balanceOf(address(pool)), unicode"而池内余额兜不住那个数");

        // ② 它无害的**唯一**理由：前序那批权证已经不是债权了。
        assertGt(
            prior.minted - prior.exercised, 0, unicode"前置条件：前序确实还有未行权的权证在外面"
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.exercise(seriesId, 1, alice);

        // ③ 正确的判据 —— 用不变量文件里的**同一份** `CollateralCheck`，不在这里另写一份。
        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, _stocks(), _ids(seriesId, nextSeriesId));
        assertEq(perSeries, 0, unicode"不变量 1①（未结算范围）");
        assertEq(global, 0, unicode"不变量 1②（全局形式）");
    }

    /// @dev 连滚两次：A → B → C。每一步之后全局形式都必须成立 ——
    ///      「一次滚存对得上」和「滚存链对得上」不是同一件事。
    function test_roll_survivesAChainOfRolls() public {
        uint256 a = _settledPredecessor();
        uint256 b = _openSuccessor();
        _rollAndAssertNoStockTransfer(a, b);

        // B 到期，无人行权 ⟹ 余量原样再滚一次
        vm.warp(nextExpiry);
        pool.settleExpired(b);
        assertEq(pool.series(b).remainder, REMAINDER, unicode"B 的余量就是滚进来的那笔");

        uint64 thirdExpiry = uint64(block.timestamp + 7 days);
        uint256 c = vault.openSeries(address(meme), address(stock), thirdExpiry, STRIKE);
        _rollAndAssertNoStockTransfer(b, c);

        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"两次滚存之后余额还是那 70");
        assertEq(pool.series(c).minted, REMAINDER, "C.minted");
        assertEq(warrant.balanceOf(address(distributor), c), REMAINDER, unicode"权证也只有那 70");

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        (uint256 perSeries, uint256 global) = CollateralCheck.violations(pool, _stocks(), ids);
        assertEq(perSeries, 0, unicode"不变量 1①");
        assertEq(global, 0, unicode"不变量 1②：两次滚存之后池内余额仍兜得住");
    }

    // ──────────────────────── 六道门，一道一条 ────────────────────────

    /// @dev ①：打错 id 时给「这个系列不存在」，而不是「它还没结算」。
    function test_roll_rejectsAnUnopenedPredecessor() public {
        uint256 nextSeriesId = _openSuccessor();
        uint256 ghost = uint256(keccak256("nobody opened this"));

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, ghost));
        pool.rollExpired(ghost, nextSeriesId);
    }

    /// @dev ②：`remainder` 要到结算那一刻才算定 —— 之前它是 0，滚存无从谈起。
    function test_roll_rejectsAnUnsettledPredecessor() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
        uint256 nextSeriesId = _openSuccessor();

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotSettled.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // 结算之后同一笔调用就通了 —— 被拒的理由确实是「还没结算」，不是别的。
        vm.warp(expiry);
        pool.settleExpired(seriesId);
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);
        assertEq(pool.series(nextSeriesId).minted, DEPOSIT, unicode"结算之后照常滚存");
    }

    /// @dev ③：**这道门就是「不可二次滚存」的全部实现。** 滚完 `remainder` 归零，
    ///      于是第二次不管滚向哪里都撞在同一句话上 —— 不需要另一个「已滚过」的标志位。
    function test_roll_cannotHappenTwice() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // 换一个后继也一样 —— 否则「滚两次」就成了凭空复制一份债权。
        uint256 third = vault.openSeries(address(meme), address(stock), nextExpiry + 7 days, STRIKE);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, third);

        assertEq(warrant.balanceOf(address(distributor), third), 0, unicode"第二个后继一枚权证都没拿到");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"池内余额也没被复制出第二份");
    }

    /// @dev ③ 的另一半：全部行权掉的系列结算后余量就是 0，滚存干净地无事可做。
    function test_roll_rejectsAFullyExercisedPredecessor() public {
        uint256 seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, alice, DEPOSIT);
        vm.prank(alice);
        pool.exercise(seriesId, DEPOSIT, alice);

        vm.warp(expiry);
        pool.settleExpired(seriesId);
        uint256 nextSeriesId = _openSuccessor();

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.NothingToRoll.selector, seriesId));
        pool.rollExpired(seriesId, nextSeriesId);
    }

    /// @notice ④ 与验收条款「无后继系列时干净 revert；开出新系列后可恢复」。
    ///
    /// @dev 🔴 **只有延迟，没有损失** —— 这是无 admin 的必然结果，也是它唯一诚实的说法：
    ///      项目停摆时余量停在池子里，没有人能把它取走，也没有人需要来取。
    function test_roll_revertsCleanlyWithoutASuccessorAndRecoversOnceOneOpens() public {
        uint256 seriesId = _settledPredecessor();
        uint256 unopened = pool.seriesIdOf(address(meme), address(stock), nextExpiry);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        pool.rollExpired(seriesId, unopened);

        // 什么都没变：余量还在账上，抵押品还在池子里。
        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"余量原封不动");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"抵押品原封不动");

        // 三周之后才有人想起来开新系列 —— 那时滚存立刻恢复。
        vm.warp(block.timestamp + 21 days);
        uint256 late = vault.openSeries(address(meme), address(stock), uint64(block.timestamp + 7 days), STRIKE);
        _rollAndAssertNoStockTransfer(seriesId, late);

        assertEq(pool.series(late).minted, REMAINDER, unicode"一枚不少地滚了过去");
        assertEq(stock.balanceOf(address(pool)), REMAINDER, unicode"整段停摆期间余额都没动过");
    }

    /// @dev ⑤ 的第一维，**承重的那一维**：换一只股票代币，就等于让 A 的抵押品去支撑 B 的债权。
    ///      拦下来之后顺手证明「拦对了」—— 另一只代币在池内的余额是 0，滚进去当场击穿不变量 1②。
    function test_roll_rejectsAMismatchedStockToken() public {
        uint256 seriesId = _settledPredecessor();
        uint256 wrong = vault.openSeries(address(meme), address(otherStock), nextExpiry, STRIKE);

        assertEq(
            otherStock.balanceOf(address(pool)), 0, unicode"前置条件：另一只股票代币池里一枚都没有"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorTokenMismatch.selector, wrong, address(meme), address(otherStock)
            )
        );
        pool.rollExpired(seriesId, wrong);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"余量没被挪走");
        assertEq(warrant.balanceOf(address(distributor), wrong), 0, unicode"也没有凭空铸出权证");
    }

    /// @dev ⑤ 的第二维：换一只 MEME。抵押品对得上，但行权要烧的是**各自项目的** MEME
    ///      （`spec.zh.md` §2.1），所以那批权证的持有人永远付不出正确的价钱。
    function test_roll_rejectsAMismatchedMemeToken() public {
        uint256 seriesId = _settledPredecessor();
        uint256 wrong = vault.openSeries(address(otherMeme), address(stock), nextExpiry, STRIKE);

        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorTokenMismatch.selector, wrong, address(otherMeme), address(stock)
            )
        );
        pool.rollExpired(seriesId, wrong);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"余量没被挪走");
    }

    /// @dev ⑥ 的第一半：后继已经结算过了 —— 滚进去的权证一枚也行权不了（不变量 4①）。
    ///      顺带钉住 `nextSeriesId == seriesId`：前序**已**结算、后继**未**结算，
    ///      同一个 id 上两者不可能同时成立，所以自滚不需要单独一道门。
    function test_roll_rejectsASettledSuccessorIncludingItself() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        vm.warp(nextExpiry);
        pool.settleExpired(nextSeriesId);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, nextSeriesId));
        pool.rollExpired(seriesId, nextSeriesId);

        // 自己滚给自己：撞的是同一道门。
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesSettled.selector, seriesId));
        pool.rollExpired(seriesId, seriesId);

        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"两次都没动到账");
    }

    /// @dev ⑥ 的第二半，**边界钉死在那一秒上**：`expiry` 前一秒可以滚，`expiry` 那一秒不行。
    ///      判据与 `exercise` 的 `block.timestamp >= deadline` 同向 —— 到期那一刻系列就是死的。
    function test_roll_rejectsAnExpiredSuccessorExactlyAtItsExpiry() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        vm.warp(uint256(nextExpiry) - 1);
        uint256 snapshotId = vm.snapshotState();
        _rollAndAssertNoStockTransfer(seriesId, nextSeriesId);
        assertEq(pool.series(nextSeriesId).minted, REMAINDER, unicode"到期前一秒仍然滚得进去");

        vm.revertToState(snapshotId);
        vm.warp(nextExpiry);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearingPool.SuccessorExpired.selector, nextSeriesId, nextExpiry, uint256(nextExpiry)
            )
        );
        pool.rollExpired(seriesId, nextSeriesId);
        assertEq(pool.series(seriesId).remainder, REMAINDER, unicode"被拒之后余量还在");
    }

    /// @dev ⑥ 用的是 `n.expiry`，**不是** deadline。门控延期把后继的行权窗口撑开了，
    ///      但它仍然不是合法的滚存目标 —— 合法后继的集合越小越好，理由见 {ClearingPool-rollExpired}。
    ///
    ///      这条测试是**取舍的锚**：哪天有人把判据换成 `_exerciseDeadline(n)`，它会红。
    function test_roll_refusesAnExpiredSuccessorEvenWhileGatingKeepsItExercisable() public {
        uint256 seriesId = _settledPredecessor();
        uint256 nextSeriesId = _openSuccessor();

        issuerCompliance.setBlocked(address(stock), address(pool), true);
        pool.pokeGating(address(stock));
        vm.warp(uint256(nextExpiry) + 30 days);

        assertEq(
            pool.exerciseDeadline(nextSeriesId), type(uint64).max, unicode"前置条件：后继此刻仍可行权"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.SuccessorExpired.selector, nextSeriesId, nextExpiry, block.timestamp)
        );
        pool.rollExpired(seriesId, nextSeriesId);
    }
}
