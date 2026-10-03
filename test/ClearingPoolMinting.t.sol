// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {ReentrantWarrantReceiver} from "./helpers/ReentrantWarrantReceiver.sol";
import {ReentrantStockToken, StockToken} from "./helpers/StockToken.sol";
import {VaultStub} from "./helpers/VaultStub.sol";

/// @notice **M1-4 铸造路径**（issue #9）：开系列锁死行权价，存入股票代币按**实际到账增量**铸出权证。
///
/// 这张票只有两个函数，但它们决定了后面所有账目的口径：
///
/// - `seriesId` 是三元组的哈希 —— 权证按**项目**隔离（`spec.zh.md` §2.1：行权烧的是各自的 MEME，
///   支付资产不同就不可能是同一个资产）；
/// - 铸造量以**余额增量**为准 —— 带转账税的股票代币下，按请求量铸造就是直接超发；
/// - 全部数量是 raw `balanceOf` 单位 —— EIP-8056 下拆股改的是 `uiMultiplier`，
///   按「股数」记账会在首次拆股时错位。
///
/// 测试驱动的是真实的四合约（`spec.zh.md` §7 / issue #5 的测试纪律），
/// 只有「该系列的金库」用替身 —— 金库本身在 M2 才存在。
contract ClearingPoolMintingTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    address internal meme = makeAddr("MEME");

    uint64 internal expiry;
    uint128 internal constant STRIKE = 1850e18;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        expiry = uint64(block.timestamp + 7 days);

        // 🔴 身份根里登记这只 MEME 的金库 —— 没有这一行，`openSeries` 一次都开不出来。
        //    生产里这条绑定由 `WarrantVaultFactory` 在 Flap 建币的同一笔交易里写下，见 {FactoryStub}。
        factory.bind(meme, address(vault));

        stock.mint(address(vault), 1_000_000 ether);
        vault.approve(stock, type(uint256).max);
    }

    /// @dev 🔴 期望值在这里**独立算一遍**，不调池子的 `seriesIdOf` —— 用被测对象自己的公式
    ///      去验它自己的公式，什么也证明不了。
    function _expectedSeriesId(address memeToken, address stockToken, uint64 expiry_) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(memeToken, stockToken, expiry_)));
    }

    // ──────────────────────────── 开系列 ────────────────────────────

    function test_openSeries_idIsTheHashOfTheTriple_andEveryFieldIsRecorded() public {
        uint256 expected = _expectedSeriesId(meme, address(stock), expiry);

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.SeriesOpened(expected, address(vault), meme, address(stock), expiry, STRIKE);
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        assertEq(seriesId, expected, "seriesId == keccak256(abi.encode(meme, stock, expiry))");
        assertEq(pool.seriesIdOf(meme, address(stock), expiry), expected, unicode"池子对外给出的同一个公式");

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.vault, address(vault), unicode"开系列的那一位就是该系列的金库");
        assertEq(s.memeToken, meme, "memeToken");
        assertEq(s.stockToken, address(stock), "stockToken");
        assertEq(s.expiry, expiry, "expiry");
        assertEq(s.strike, STRIKE, "strike");
        assertEq(s.deposited, 0, "deposited");
        assertEq(s.minted, 0, "minted");
        assertEq(s.exercised, 0, "exercised");
        assertEq(s.remainder, 0, "remainder");
        assertFalse(s.settled, "settled");
    }

    /// @dev 三个分量都真的进了哈希。少一个就意味着两个本该不同的系列会撞成同一个 ERC-1155 id ——
    ///      撞上 `memeToken` 那一维尤其致命：两个项目的权证会共用同一份抵押品。
    function test_openSeries_eachComponentOfTheTripleChangesTheId() public {
        uint256 base = vault.openSeries(meme, address(stock), expiry, STRIKE);

        address otherMeme = makeAddr("another project's MEME");
        StockToken otherStock = new StockToken();
        uint64 otherExpiry = expiry + 7 days;

        // 另一个项目的 MEME 得先有自己的金库 —— 而这里**故意登记成同一个金库替身**：
        // 要测的是「三个分量各自都进了哈希」，多一个金库只会给这条断言多一个无关变量。
        factory.bind(otherMeme, address(vault));

        assertTrue(base != vault.openSeries(otherMeme, address(stock), expiry, STRIKE), "memeToken");
        assertTrue(base != vault.openSeries(meme, address(otherStock), expiry, STRIKE), "stockToken");
        assertTrue(base != vault.openSeries(meme, address(stock), otherExpiry, STRIKE), "expiry");
    }

    /// @dev 验收条款：**只能调一次；行权价此后不可改。**
    ///      「不可改」在这里是一句关于**不存在**的话，所以它有两处出处：
    ///      这条测试挡住「用第二次 `openSeries` 改」，而「没有别的入口能改」由
    ///      `test/ClearingPool.t.sol::test_writeSurface_isExactlySixFunctions` 枚举 ABI 证明。
    function test_openSeries_isOnceOnly_andTheStrikeIsFrozen() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        // 🔴 只有**登记在案的那个金库**才走得到「已开启」这道门 —— 别人被前一道身份门挡住，
        //    那条路径由 `test_openSeries_onlyTheRegisteredVaultCanOpen` 单独钉。
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesAlreadyOpen.selector, seriesId, address(vault)));
        vault.openSeries(meme, address(stock), expiry, STRIKE + 1);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.strike, STRIKE, unicode"那次尝试没能改动行权价");
        assertEq(s.vault, address(vault), unicode"也没能改动该系列的金库");
    }

    /// @notice 🔴 **验收（issue #37 / #9 改回）：仅该 MEME 登记在案的金库可以开系列。**
    ///
    /// @dev M1 这里曾经是**无许可**的（谁先开谁负责），残余敞口是抢注导致的当周停发。
    ///      issue #23 的六条分叉判据全过之后，那条路被裁掉，换成一道结构性的门：
    ///      `msg.sender == vaultRegistry.vaultOf(memeToken)` 且非零。
    ///
    ///      这条测试把三种「不是他」分开断言，因为它们在链下要被区别对待：
    ///
    ///      | 情形 | `NotRegisteredVault` 的第三个参数 |
    ///      |---|---|
    ///      | 陌生 EOA 来抢注 | 登记在案的金库地址 —— 有金库，但不是你 |
    ///      | 另一个项目的金库来抢注 | 同上 |
    ///      | 这只 MEME 根本没登记过 | `address(0)` —— 它没有金库，谁也开不了它的系列 |
    ///
    ///      最后一行是这道门最要紧的性质：**没有任何入口能给一只已经存在的 MEME 补登记**
    ///      （`VaultRegistry` 只认工厂，工厂只认 VaultPortal，而 VaultPortal 只在建币那一刻调它）。
    ///      抢注因此不是更难，是不存在。
    function test_openSeries_onlyTheRegisteredVaultCanOpen() public {
        address squatter = makeAddr("squatter");
        VaultStub otherVault = new VaultStub(pool);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, squatter, address(vault))
        );
        vm.prank(squatter);
        pool.openSeries(meme, address(stock), expiry, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, address(otherVault), address(vault))
        );
        otherVault.openSeries(meme, address(stock), expiry, 1);

        // 未登记的 MEME：连它自己的「金库」也开不出来 —— 名册上没有它。
        address unlisted = makeAddr("a MEME that never went through our factory");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, unlisted, address(vault), address(0))
        );
        vault.openSeries(unlisted, address(stock), expiry, STRIKE);

        assertEq(
            pool.series(_expectedSeriesId(meme, address(stock), expiry)).vault,
            address(0),
            unicode"一个都没开出来"
        );

        // 对照：登记在案的那一位开得出来。少了这一条，上面三条在一个「谁都开不了」的实现上也是绿的。
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        assertEq(pool.series(seriesId).vault, address(vault), unicode"登记在案的金库开得出来");
    }

    /// @dev 🔴 **身份门排在「已开启」之前。** 一个陌生地址来撞一个已开系列，应当被告知
    ///      「你不是这只 MEME 的金库」，而不是「这个系列已经开过了」—— 后者会把一次权限错误
    ///      报成一次时序错误，链下据此排查就会走去看日历，而不是去看发射用的哪个工厂。
    function test_openSeries_theIdentityGateComesBeforeTheAlreadyOpenGate() public {
        vault.openSeries(meme, address(stock), expiry, STRIKE);

        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotRegisteredVault.selector, meme, stranger, address(vault))
        );
        vm.prank(stranger);
        pool.openSeries(meme, address(stock), expiry, 1);
    }

    /// @dev 四条前置各挡一件「开出来就没救了」的事 —— 系列一经开启不可关闭、不可修改。
    function test_openSeries_rejectsZeroTokensZeroStrikeAndNonFutureExpiry() public {
        vm.expectRevert(ClearingPool.ZeroToken.selector);
        vault.openSeries(address(0), address(stock), expiry, STRIKE);

        vm.expectRevert(ClearingPool.ZeroToken.selector);
        vault.openSeries(meme, address(0), expiry, STRIKE);

        // strike == 0 有两个后果：行权白拿股票代币，且 #12 的「后继系列已开启」判据
        // （`n.strike != 0`）会把这个系列当成不存在。
        vm.expectRevert(ClearingPool.ZeroStrike.selector);
        vault.openSeries(meme, address(stock), expiry, 0);

        uint64 now_ = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExpiryNotInFuture.selector, now_, now_));
        vault.openSeries(meme, address(stock), now_, STRIKE);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.ExpiryNotInFuture.selector, now_ - 1, now_));
        vault.openSeries(meme, address(stock), now_ - 1, STRIKE);
    }

    // ─────────────────────────── 存入即铸 ───────────────────────────

    /// @dev 🔴 **本票的核心断言**：带转账税的股票代币下，铸造量等于**实际到账量**，不等于请求量。
    ///      按 `expectedAmount` 铸造就是凭空多发 3% 的权证，而多出来的那部分没有抵押品对应 ——
    ///      不变量 1 当场作废，且要到第一个行权失败的用户身上才会暴露。
    function test_depositAndMint_mintsWhatArrived_notWhatWasRequested() public {
        stock.setTaxBps(300); // 3%，与 Flap 的默认买卖税同档
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 requested = 1000 ether;
        uint256 arrived = 970 ether;

        vm.expectEmit(true, true, true, true, address(pool));
        emit ClearingPool.Deposited(seriesId, address(vault), address(distributor), requested, arrived);
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), requested);

        assertEq(minted, arrived, unicode"返回值是实际铸造量");
        assertEq(stock.balanceOf(address(pool)), arrived, unicode"池内真的只多了这么多");
        assertEq(warrant.balanceOf(address(distributor), seriesId), arrived, unicode"权证按到账量铸出");

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.deposited, arrived, "deposited");
        assertEq(s.minted, arrived, "minted");
    }

    /// @dev 不变量 2 的确定性形式：任意请求量、任意税率下，铸造量 == 池内余额增量。
    function testFuzz_depositAndMint_mintsExactlyTheBalanceDelta(uint96 requested, uint16 taxBps) public {
        taxBps = uint16(bound(taxBps, 0, 10_000));
        stock.setTaxBps(taxBps);
        // 金库存不出它没有的钱 —— 余额不足是 ERC-20 的事，不是这条断言要说的事。
        requested = uint96(bound(requested, 0, stock.balanceOf(address(vault))));

        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 before = stock.balanceOf(address(pool));
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), requested);
        uint256 delta = stock.balanceOf(address(pool)) - before;

        assertEq(minted, delta, unicode"不变量 2：铸造量 == 池内余额增量");
        assertEq(warrant.balanceOf(address(distributor), seriesId), delta, unicode"权证余额同口径");
        assertEq(pool.series(seriesId).minted, delta, "minted");
        assertLe(minted, requested, unicode"税只会让到账变少，不会变多");
    }

    function test_depositAndMint_accumulatesAcrossDeposits() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        vault.depositAndMint(seriesId, address(distributor), 400 ether);
        vault.depositAndMint(seriesId, address(distributor), 600 ether);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.deposited, 1000 ether, "deposited");
        assertEq(s.minted, 1000 ether, "minted");
        assertEq(
            warrant.balanceOf(address(distributor), seriesId),
            1000 ether,
            unicode"权证同质，两次铸到同一个 id"
        );
    }

    /// @dev 验收条款：**全部数量使用 raw `balanceOf` 单位。**
    ///      EIP-8056 的拆股改的是 `uiMultiplier`，`balanceOf` 一动不动 —— 所以一次 2:1 拆股
    ///      对池内账目**不应产生任何影响**。若哪天有人「顺手」把显示乘数读进记账，
    ///      这条测试会当场变红。
    function test_depositAndMint_isRawAccounting_soASplitChangesNothing() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        vault.depositAndMint(seriesId, address(distributor), 100 ether);

        stock.setUiMultiplier(2e18); // 2:1 拆股：显示值翻倍，raw 余额不变
        vault.depositAndMint(seriesId, address(distributor), 100 ether);

        ClearingPool.Series memory s = pool.series(seriesId);
        assertEq(s.minted, 200 ether, unicode"两次存入的记账口径完全一致");
        assertEq(s.minted, stock.balanceOf(address(pool)), unicode"账面等于池内 raw 余额");
    }

    /// @dev 验收条款：**非该系列的金库调用一律 revert。** 四类调用方各来一次 ——
    ///      另一个金库、陌生 EOA、distributor、以及部署了整套系统的这个测试合约。
    function test_depositAndMint_onlyTheSeriesVault() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        VaultStub otherVault = new VaultStub(pool);
        stock.mint(address(otherVault), 1000 ether);
        otherVault.approve(stock, type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(otherVault), address(vault))
        );
        otherVault.depositAndMint(seriesId, address(distributor), 1 ether);

        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, stranger, address(vault))
        );
        vm.prank(stranger);
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(distributor), address(vault))
        );
        vm.prank(address(distributor));
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ClearingPool.NotSeriesVault.selector, seriesId, address(this), address(vault))
        );
        pool.depositAndMint(seriesId, address(distributor), 1 ether);

        assertEq(warrant.balanceOf(address(distributor), seriesId), 0, unicode"四次尝试一枚权证都没铸出");
    }

    /// @dev 🔴 未开启的系列**显式拒绝**，不靠「`msg.sender` 不可能等于零地址」这条关于链的假设。
    ///
    ///      `address(0)` 在这里身兼两职：它是「该系列尚未开启」的哨兵值，也是一个能出现在
    ///      `msg.sender` 位置的取值。只写 `msg.sender != s.vault` 的话，这两个身份会在未开启期间
    ///      **撞成同一个值** —— 零地址调用者恰好通过授权判据，然后 `stockToken == address(0)`
    ///      上的 `balanceOf` 会 revert…… 也就是说这道门此刻是靠**另一个合约的偶然行为**关着的。
    ///      同 `PoolBound.onlyPool` 的取舍：把「未开启就拒绝」写成结构，比寄存在一条外部假设上便宜。
    function test_depositAndMint_rejectsUnopenedSeries_includingAZeroAddressCaller() public {
        uint256 unopened = _expectedSeriesId(meme, address(stock), expiry);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        vault.depositAndMint(unopened, address(distributor), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, unopened));
        vm.prank(address(0));
        pool.depositAndMint(unopened, address(distributor), 1 ether);
    }

    /// @dev `deposited` / `minted` 是 `uint128`，而 ERC-20 的数量是 `uint256`。
    ///      裸转换会**静默截断**：存入 2^128 + 5 会记成 5，权证却按 2^128 + 5 铸出。
    ///      真实 GME 到不了这个量级，但池子对**任何**股票代币都开着 —— 开系列那道门认的是
    ///      MEME 的金库身份，`stockToken` 这一维池子不解释、也无从解释。
    function test_depositAndMint_rejectsAmountsThatDoNotFitUint128() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);

        uint256 tooBig = uint256(type(uint128).max) + 1;
        stock.mint(address(vault), tooBig);

        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, tooBig));
        vault.depositAndMint(seriesId, address(distributor), tooBig);

        // 边界的另一侧照常工作
        uint256 minted = vault.depositAndMint(seriesId, address(distributor), type(uint128).max);
        assertEq(minted, type(uint128).max, unicode"恰好装得下的那一档");
    }

    /// @dev 🔴 余额差记账**天然对再入敏感**：内层的转入会被外层再数一遍，于是
    ///      抵押品进来 `T1 + T2`、权证铸出 `T1 + 2·T2`。见 `ReentrantStockToken` 的注释。
    ///
    ///      这条测试要求内层被拒**且外层的账依然精确** —— 只断言「整笔 revert」是更弱的说法，
    ///      它连「守住的是不是这件事」都说不清。
    function test_depositAndMint_isNotReentrant() public {
        ReentrantStockToken reentrant = new ReentrantStockToken();
        VaultStub reentrantVault = new VaultStub(pool);
        reentrant.mint(address(reentrantVault), 1000 ether);
        reentrantVault.approve(reentrant, type(uint256).max);

        // 另一个金库要开系列，就得是**另一只 MEME** 的登记金库：一只 MEME 只有一个合法金库。
        address reentrantMeme = makeAddr("MEME of the reentrancy project");
        factory.bind(reentrantMeme, address(reentrantVault));

        uint256 seriesId = reentrantVault.openSeries(reentrantMeme, address(reentrant), expiry, STRIKE);
        reentrant.armReentrancy(
            address(reentrantVault),
            abi.encodeCall(VaultStub.depositAndMint, (seriesId, address(distributor), 100 ether))
        );

        uint256 minted = reentrantVault.depositAndMint(seriesId, address(distributor), 400 ether);

        assertGt(reentrant.reentryAttempts(), 0, unicode"前置条件：回调真的打进来了");
        assertFalse(reentrant.reentrySucceeded(), unicode"内层的存入必须被拒");
        assertEq(
            reentrant.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护"
        );

        assertEq(minted, 400 ether, unicode"外层铸造量 == 实际到账量");
        assertEq(stock.balanceOf(address(pool)), 0, unicode"另一只股票代币的池内余额与本次无关");
        assertEq(reentrant.balanceOf(address(pool)), 400 ether, unicode"抵押品与铸造量一一对应");
        assertEq(warrant.balanceOf(address(distributor), seriesId), 400 ether, unicode"权证没有多铸一份");
    }

    /// @dev 🔴 **第二条交出控制权的路径**：`warrant.mint` 对合约收款方强制回调 `onERC1155Received`。
    ///      上一条测的是股票代币在转账里回调；这一条测的是**收款方**在收到权证的那一刻回调。
    ///
    ///      这里的收款方自己也开了一个系列，所以它是**那个系列的金库** —— 它的再入调用
    ///      **通过**授权检查。挡住它的只剩 `nonReentrant` 一件东西，这正是要断言的。
    function test_depositAndMint_isNotReentrantThroughTheWarrantCallback() public {
        ReentrantWarrantReceiver receiver = new ReentrantWarrantReceiver(pool);
        stock.mint(address(receiver), 1000 ether);
        receiver.approve(stock, type(uint256).max);

        // 收款方自己的系列 —— 它得先是**另一只 MEME** 的登记金库：一只 MEME 只有一个合法金库，
        // 而这条测试要的是「内层调用方本身完全合法，仍然被再入保护挡住」。
        address receiverMeme = makeAddr("MEME of the receiver's own project");
        factory.bind(receiverMeme, address(receiver));
        uint256 ownSeries = receiver.openOwnSeries(receiverMeme, address(stock), expiry + 1 days, STRIKE);
        receiver.armReentrancy(50 ether);

        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        uint256 minted = vault.depositAndMint(seriesId, address(receiver), 100 ether);

        assertGt(receiver.reentryAttempts(), 0, unicode"前置条件：回调真的打进来了");
        assertFalse(
            receiver.reentrySucceeded(), unicode"内层的存入必须被拒 —— 即使调用方是合法金库"
        );
        assertEq(
            receiver.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            unicode"被拒的理由是再入保护，不是授权检查"
        );

        assertEq(minted, 100 ether, unicode"外层铸造量 == 实际到账量");
        assertEq(stock.balanceOf(address(pool)), 100 ether, unicode"抵押品只进来一次");
        assertEq(warrant.balanceOf(address(receiver), seriesId), 100 ether, unicode"权证只铸了一次");

        ClearingPool.Series memory own = pool.series(ownSeries);
        assertEq(own.deposited, 0, unicode"内层那个系列一分钱都没进去");
        assertEq(own.minted, 0, "minted");
        assertEq(warrant.balanceOf(address(receiver), ownSeries), 0, unicode"也没铸出任何权证");
    }

    /// @dev 池子不读权证余额，也不读 `to` 是谁 —— 但铸给合约收款方时 ERC-1155 会强制回调。
    ///      distributor 接得住（它继承了 `ERC1155Holder`），一个不实现回调的合约必须被 revert 挡住，
    ///      否则权证会铸进一个永远取不出来的地方。
    function test_depositAndMint_mintsToWhoeverTheVaultNames() public {
        uint256 seriesId = vault.openSeries(meme, address(stock), expiry, STRIKE);
        address holder = makeAddr("some holder");

        vault.depositAndMint(seriesId, holder, 10 ether);
        assertEq(warrant.balanceOf(holder, seriesId), 10 ether, unicode"EOA 收得下");

        // 断具体的 error，不写空的 `expectRevert()` —— 后者连「存入是因为别的原因失败的」都会当成通过。
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(registry)));
        vault.depositAndMint(seriesId, address(registry), 10 ether);
    }
}
