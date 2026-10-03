// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IWarrant} from "../../src/interfaces/IWarrant.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {StockToken} from "../helpers/StockToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";

/// @notice 不变量 1 的两款写成一处，供不变量测试与「探测器反证」共用同一份判据。
///
/// 🔴 两条测试各写一遍判据，等于让反证去验证另一份代码 —— 反证要证明的恰恰是**这一份**会响。
library CollateralCheck {
    /// @param ids 全部已开启的系列
    /// @return perSeries 违反 1① 的系列数
    /// @return global    违反 1② 的股票代币数
    ///
    /// @dev 1① 的「归属该 series 的部分」在本项目里就是 `deposited − exercised`：
    ///      权证按项目隔离（`spec.zh.md` §2.1），因此**每个系列只有一个出资方**，
    ///      不存在按比例分账（§4.2「单一金库设计」）。于是 1① 化简成 `minted ≤ deposited`
    ///      —— 一个系列永远不能声称比它自己存进来的更多。
    ///
    ///      1② 才是跨系列的那一层：同一只股票代币的池内余额是**共用**的，
    ///      所以全部未结算系列的未行权量、加上全部待滚存的余量，必须一并被余额兜住。
    function violations(ClearingPool pool, address[] memory stocks, uint256[] memory ids)
        internal
        view
        returns (uint256 perSeries, uint256 global)
    {
        for (uint256 i = 0; i < ids.length; i++) {
            ClearingPool.Series memory s = pool.series(ids[i]);

            // 🔴 **限定在未结算范围，这是不变量 1① 的原文，不是为了让它过。**
            //    已结算系列的权证不可行权，本就不需要抵押；而滚存（#12）把余量记进后继系列之后，
            //    前序系列的 `deposited` 还留着那笔已经被重新归属的数 —— 对它继续断言逐系列充足
            //    是在拿一本已经交出去的账问余额。跨滚存的那一层由 1② 的全局形式负责。
            //    issue #5：**不得把 1① 削弱成能通过的样子** —— 削弱的是判据，这里删掉的是不适用的前提。
            if (s.settled) continue;

            // `exercised > minted` 本身就是账目坏掉的样子（行权量超过铸造量）。
            // 记一次违规而不是让减法 revert —— view 里 revert 会把「哪一条不变量断了」糊掉。
            if (s.exercised > s.minted || s.exercised > s.deposited) perSeries++;
            else if (s.minted - s.exercised > s.deposited - s.exercised) perSeries++;
        }

        for (uint256 t = 0; t < stocks.length; t++) {
            uint256 claim;
            for (uint256 i = 0; i < ids.length; i++) {
                ClearingPool.Series memory s = pool.series(ids[i]);
                if (s.stockToken != stocks[t]) continue;
                if (!s.settled && s.minted >= s.exercised) claim += s.minted - s.exercised;
                claim += s.remainder;
            }
            if (claim > IERC20(stocks[t]).balanceOf(address(pool))) global++;
        }
    }
}

/// @notice **只用于反证探测器真的会响。** 它把不变量 1 与 2 要禁止的两件事各做成一个函数。
///
/// 两个后门刻意分开，因为它们坏的不是同一样东西 —— 一个探测器抓得到另一个，就说明其中一个是多余的：
///
/// | 后门 | 谁该响 | 谁该沉默 |
/// |---|---|---|
/// | `overmint` 记账与权证一起虚增，但没有抵押品 | 不变量 1①②、不变量 2 的守恒计数 | 权证计数（账与权证仍然一致） |
/// | `mintPhantomWarrants` 只铸权证，不动账 | 权证计数 | 不变量 1（它读的是账，账没被动过） |
///
/// 生产合约里这两个入口都不存在 —— 由 `test/ClearingPool.t.sol` 枚举编译产物的 ABI 证明
/// （「对外可写函数恰好六个」），而不是由「我们没写过」这句话证明。
contract OvermintingPool is ClearingPool {
    constructor(
        IWarrant warrant_,
        address distributor_,
        IAttestationRegistry attestations_,
        IVaultRegistry vaultRegistry_
    ) ClearingPool(warrant_, distributor_, attestations_, vaultRegistry_) {}

    /// @dev 不存抵押品就把 `minted` 抬高，并铸出对应的权证。
    function overmint(uint256 seriesId, address to, uint128 amount) external {
        _series[seriesId].minted += amount;
        warrant.mint(to, seriesId, amount);
    }

    /// @dev 只铸权证，账目一动不动 —— 池子的账因此低估了自己的债务。
    function mintPhantomWarrants(uint256 seriesId, address to, uint256 amount) external {
        warrant.mint(to, seriesId, amount);
    }
}

/// @notice 驱动铸造路径的 handler。
///
/// 🔴 **本合约的任何函数都不 revert**（同 `Invariant6AttestationGate.t.sol` 的取舍）：
/// 不变量跑在 `fail_on_revert = false` 下，handler 里的 `assertEq` 失败就是一次 revert，
/// 会被 fuzzer 静静吞掉 —— 断言写了等于没写。所以违规一律**记进计数器**，
/// 由 `invariant_*` 去断言计数为零；对池子的调用全部走低层 `call`。
///
/// 计数器本身能不能抓到违规，由 `test_theDetectorDetects_*` 反证。
contract MintingHandler is CommonBase, StdUtils {
    ClearingPool public immutable pool;
    Warrant public immutable warrant;

    /// @dev 🔴 三个金库替身、两只股票代币、两个 MEME、四个 expiry ——
    ///      刻意把宇宙做小：系列总数上限 2×2×4 = 16，于是
    ///      ① 不变量函数遍历全部系列仍然便宜（它在每一步之后都要跑一遍）；
    ///      ② 同一个三元组会被反复撞上，「只能开一次」那条路径才有覆盖；
    ///      ③ 金库三选一 ⟹ 约 2/3 的存入打在**不是该系列金库**的调用方上。
    ///
    ///      🔴 **金库比 MEME 多一个，是刻意的**（M2-5 / #37）：身份根里只登记
    ///      `memes[i] → vaults[i]`（i < 2），于是 `vaults[2]` **永远不是任何一只 MEME 的合法金库** ——
    ///      开系列那道身份门因此在每一轮都有真实覆盖，而不是靠 fuzzer 碰巧撞上。
    VaultStub[3] public vaults;
    StockToken[2] public stocks;
    address[2] public memes;
    address[3] public receivers;
    uint64[4] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice 不变量 2：某次动作前后 `minted` 增量 ≠ 池内该股票代币余额增量的次数。必须恒为 0。
    uint256 public conservationViolations;
    /// @notice 权证侧的同一件事：铸出的权证数 ≠ `minted` 增量的次数。必须恒为 0。
    uint256 public warrantViolations;
    /// @notice 池内该股票代币余额**减少**的次数。铸造路径里没有任何转出，必须恒为 0。
    uint256 public outflowViolations;

    /// @dev 覆盖度计数：三条不变量都是「某个计数为 0」，而一个什么都没干成的 handler 同样满足它们。
    uint256 public successfulOpens;
    uint256 public successfulDeposits;
    uint256 public rejectedOpens;
    uint256 public rejectedDeposits;

    /// @dev 探测器反证的接线：**真实运行里两个都恒为 0**。非 0 时每次成功存入之后额外凭空铸一点，
    ///      用来证明上面那些计数器不是睡着的。见 `test_theDetectorDetects_*`。
    uint128 public immutable sabotagePerDeposit;
    uint128 public immutable phantomWarrantsPerDeposit;

    constructor(
        ClearingPool pool_,
        Warrant warrant_,
        address distributor_,
        FactoryStub factory_,
        uint128 sabotagePerDeposit_,
        uint128 phantomWarrantsPerDeposit_
    ) {
        pool = pool_;
        warrant = warrant_;
        sabotagePerDeposit = sabotagePerDeposit_;
        phantomWarrantsPerDeposit = phantomWarrantsPerDeposit_;

        memes = [makeAddrLike("MEME A"), makeAddrLike("MEME B")];
        receivers = [distributor_, makeAddrLike("holder 1"), makeAddrLike("holder 2")];
        expiries = [
            uint64(block.timestamp + 30 days),
            uint64(block.timestamp + 60 days),
            uint64(block.timestamp + 90 days),
            uint64(block.timestamp + 365 days)
        ];

        for (uint256 i = 0; i < stocks.length; i++) {
            stocks[i] = new StockToken();
        }
        stocks[1].setTaxBps(300); // 一只带 3% 转账税：「按到账量铸造」在零税代币下看不出区别

        for (uint256 i = 0; i < vaults.length; i++) {
            VaultStub v = new VaultStub(pool_);
            vaults[i] = v;
            // 前 `memes.length` 个金库各登记一只 MEME；多出来的那一个**故意不登记**，见字段注释。
            if (i < memes.length) factory_.bind(memes[i], address(v));
            for (uint256 t = 0; t < stocks.length; t++) {
                stocks[t].mint(address(v), 1e30);
                v.approve(stocks[t], type(uint256).max);
            }
        }
    }

    function seriesCount() external view returns (uint256) {
        return openedSeries.length;
    }

    function stockAddresses() external view returns (address[] memory list) {
        list = new address[](stocks.length);
        for (uint256 i = 0; i < stocks.length; i++) {
            list[i] = address(stocks[i]);
        }
    }

    function seriesIds() external view returns (uint256[] memory) {
        return openedSeries;
    }

    // ────────────────────────────── 动作 ──────────────────────────────

    function openSeries(uint256 vaultSeed, uint256 memeSeed, uint256 stockSeed, uint256 expirySeed, uint128 strike)
        external
    {
        // strike == 0 会被合约拒（`ZeroStrike`），单元测试已覆盖；这里让开系列尽量走得通，
        // 否则一整轮下来可能一个系列都没开出来，后面的存入全都空转。
        strike = uint128(bound(strike, 1, type(uint128).max));

        (bool ok, bytes memory ret) = address(vaults[vaultSeed % vaults.length])
            .call(
                abi.encodeCall(
                    VaultStub.openSeries,
                    (
                        memes[memeSeed % memes.length],
                        address(stocks[stockSeed % stocks.length]),
                        expiries[expirySeed % expiries.length],
                        strike
                    )
                )
            );

        if (!ok) {
            rejectedOpens++;
            return;
        }
        successfulOpens++;

        uint256 seriesId = abi.decode(ret, (uint256));
        if (!known[seriesId]) {
            known[seriesId] = true;
            openedSeries.push(seriesId);
        }
    }

    function depositAndMint(uint256 vaultSeed, uint256 seriesSeed, uint256 receiverSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address to = receivers[receiverSeed % receivers.length];
        amount = bound(amount, 0, 1e24);

        IERC20 stock = IERC20(pool.series(seriesId).stockToken);
        uint256 balanceBefore = stock.balanceOf(address(pool));
        uint256 mintedBefore = pool.series(seriesId).minted;
        uint256 warrantBefore = warrant.balanceOf(to, seriesId);

        (bool ok,) = address(vaults[vaultSeed % vaults.length])
            .call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, to, amount)));
        if (ok) {
            successfulDeposits++;
            if (sabotagePerDeposit != 0) {
                OvermintingPool(address(pool)).overmint(seriesId, to, sabotagePerDeposit);
            }
            if (phantomWarrantsPerDeposit != 0) {
                OvermintingPool(address(pool)).mintPhantomWarrants(seriesId, to, phantomWarrantsPerDeposit);
            }
        } else {
            rejectedDeposits++;
        }

        uint256 balanceAfter = stock.balanceOf(address(pool));
        if (balanceAfter < balanceBefore) {
            outflowViolations++;
            return; // 余额倒流之后，下面的增量比较没有意义
        }

        uint256 mintedDelta = pool.series(seriesId).minted - mintedBefore;
        if (mintedDelta != balanceAfter - balanceBefore) conservationViolations++;
        if (warrant.balanceOf(to, seriesId) - warrantBefore != mintedDelta) warrantViolations++;
    }

    /// @dev 时间这一维：存入可以发生在开系列很久之后，也可以发生在 `expiry` **之后**
    ///      （门控延期下那是合法的，见 issue #11）—— 铸造量守恒与时间无关，这条动作把它钉住。
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 2 days));
    }

    /// @dev `makeAddr` 住在 forge-std 的 `Test` 上，handler 继承的是 `CommonBase`。
    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **不变量 1（未结算形式）与不变量 2 —— 铸造永远不能跑到抵押品前面。**
///
/// | # | 不变量 | 断言 |
/// |---|---|---|
/// | 1① | 抵押充足（逐系列） | ∀ 未结算 series：`minted − exercised ≤ 归属该 series 的部分` |
/// | 1② | 抵押充足（全局） | ∀ 股票代币：`Σ_未结算(minted − exercised) + Σ remainder ≤ balanceOf(pool)` |
/// | 2 | 铸造量守恒 | 每次 `depositAndMint` 后 `minted` 增量 == 池内该股票代币余额增量 |
///
/// **本文件的 handler 只驱动铸造路径**，所以这里 `exercised` / `remainder` / `settled` 恒为初值。
/// 但断言**按最终形态写**：`exercised` 的写入路径已随 M1-5（#10）落地，`Invariant3ExerciseAtomicity.t.sol`
/// 用**同一份** `CollateralCheck` 在真实的行权序列上再跑一遍 1①②；`remainder` / `settled` 等 #11 / #12。
/// 判据本身不该跟着改 —— 尤其 1① 的「未结算」限定，issue #5 点名它**不得被削弱成能通过的样子**。
contract Invariant1And2MintingPathTest is Test {
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    FactoryStub internal factory;
    MintingHandler internal handler;

    function setUp() public {
        (pool, warrant, distributor, factory) = _deploySystem(false);
        handler = new MintingHandler(pool, warrant, address(distributor), factory, 0, 0);

        targetContract(address(handler));
    }

    /// @dev 部署的是**真实的四合约**并完成两处绑定（issue #5 的测试缝：部署后合约集的对外 ABI），
    ///      外加一份真实的身份根 —— 池子的第四个 `immutable`（M2-5 / #37）。
    ///      `overminting = true` 时把池子换成带后门的那一份 —— 只有反证用。
    function _deploySystem(bool overminting)
        internal
        returns (ClearingPool pool_, Warrant warrant_, MerkleDistributor distributor_, FactoryStub factory_)
    {
        AttestationRegistry registry =
            new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant_ = new Warrant();
        distributor_ = new MerkleDistributor(makeAddr("publisher"));
        factory_ = new FactoryStub();
        pool_ = overminting
            ? ClearingPool(address(new OvermintingPool(warrant_, address(distributor_), registry, factory_.registry())))
            : new ClearingPool(warrant_, address(distributor_), registry, factory_.registry());
        warrant_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    // ─────────────────────────── 不变量 1 与 2 ───────────────────────────

    /// @notice 1① 每个未结算系列的未行权量，都被它自己存进来的抵押品兜住。
    function invariant_1a_everyUnsettledSeriesIsCollateralised() public view {
        (uint256 perSeries,) = CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"不变量 1①：某个未结算系列的 minted 超过了它存入的抵押品");
    }

    /// @notice 1② 同一只股票代币下，全部未结算系列的未行权量 + 全部待滚存余量 ≤ 池内余额。
    function invariant_1b_theWholePoolIsCollateralised() public view {
        (, uint256 global) = CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(global, 0, unicode"不变量 1②：某只股票代币的池内余额兜不住全部债权");
    }

    /// @notice 2 每次 `depositAndMint` 后，`minted` 增量 == 池内该股票代币余额增量。
    function invariant_2_mintedTracksTheBalanceDelta() public view {
        assertEq(handler.conservationViolations(), 0, unicode"不变量 2：minted 增量 ≠ 池内余额增量");
        assertEq(handler.warrantViolations(), 0, unicode"不变量 2：铸出的权证数 ≠ minted 增量");
        assertEq(handler.outflowViolations(), 0, unicode"铸造路径上不该有任何抵押品流出池子");
    }

    // ──────────────────── 反证：上面三条不是空转 ────────────────────

    /// @dev 三条不变量全是「某个计数为 0」/「某个和 ≤ 余额」，而一个**什么都没干成**的 handler
    ///      同样满足它们。这里确定性地证明成功路径确实走得通，并且拒绝路径也真的被撞到了。
    function test_handlerReachesTheSuccessPathsAndTheRejections() public {
        handler.openSeries(0, 0, 0, 0, 1e18);
        assertEq(handler.successfulOpens(), 1, unicode"handler 开不出系列");
        assertEq(handler.seriesCount(), 1, unicode"开出来的系列没被记下");

        // 同一个金库、同一个三元组第二次开 ⟹ 被拒（`SeriesAlreadyOpen`）；系列数不增加
        handler.openSeries(0, 0, 0, 0, 1e18);
        assertEq(handler.rejectedOpens(), 1, unicode"「只能开一次」这条路径没被撞到");
        assertEq(handler.seriesCount(), 1, unicode"被拒的开系列不该产生新系列");

        // 🔴 另一个金库来开同一只 MEME ⟹ 被身份门拒（`NotRegisteredVault`，M2-5 / #37）。
        //    换一个还没被开过的 expiry，好让它撞的确实是身份门而不是「已开启」。
        handler.openSeries(1, 0, 0, 1, 1e18);
        assertEq(handler.rejectedOpens(), 2, unicode"开系列那道身份门这条路径没被撞到");
        assertEq(handler.seriesCount(), 1, unicode"不是它的 MEME，一个系列都开不出来");

        // vaultSeed 0 == 开系列的那个金库 ⟹ 成功
        handler.depositAndMint(0, 0, 0, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler 存不进去");
        assertGt(warrant.balanceOf(address(distributor), handler.openedSeries(0)), 0, unicode"权证真的铸出来了");

        // vaultSeed 1 != 该系列的金库 ⟹ 被拒
        handler.depositAndMint(1, 0, 0, 100 ether);
        assertEq(handler.rejectedDeposits(), 1, unicode"「非该系列金库」这条路径没被撞到");

        assertEq(handler.conservationViolations(), 0, unicode"以上全程没有守恒违规");
    }

    /// @dev 探测器反证：把「不存抵押品就能铸」与「只铸权证不记账」两个后门装进池子，
    ///      不变量 1 的两款、不变量 2 的守恒计数与权证计数必须**当场全响**。
    ///
    ///      🔴 少了这条，那三条断言随时可能因为判据本身写错而**永远为真**
    ///      —— 那正是一条不变量最坏的失效方式：它还在，还是绿的，但已经不检查任何东西。
    ///
    ///      🔴 两个虚增量**刻意不相等**（1 wei / 2 wei）。取成一样的话，账虚增 1、权证也虚增 1，
    ///      「权证数 == minted 增量」反而重新成立 —— 两个后门互相抵消，权证探测器一起哑掉。
    function test_theDetectorDetects_overmintingAndPhantomWarrants() public {
        (ClearingPool bad, Warrant badWarrant, MerkleDistributor badDistributor, FactoryStub badFactory) =
            _deploySystem(true);
        MintingHandler h = new MintingHandler(bad, badWarrant, address(badDistributor), badFactory, 1 wei, 2 wei);

        h.openSeries(0, 0, 0, 0, 1e18);
        h.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(bad, h.stockAddresses(), h.seriesIds());
        assertGt(perSeries, 0, unicode"不变量 1① 的探测器没响");
        assertGt(global, 0, unicode"不变量 1② 的探测器没响");
        assertGt(h.conservationViolations(), 0, unicode"不变量 2 的探测器没响");
        assertGt(h.warrantViolations(), 0, unicode"权证侧的探测器没响");
    }

    /// @dev 权证计数**独家**覆盖的那条缝：只铸权证、账目一动不动。
    ///      不变量 1 读的是账，账没被动过 —— 它对这种坏法是瞎的，所以那个计数器不是冗余的。
    function test_theWarrantDetectorCatchesWhatTheLedgerCheckCannot() public {
        (ClearingPool bad, Warrant badWarrant, MerkleDistributor badDistributor, FactoryStub badFactory) =
            _deploySystem(true);
        MintingHandler h = new MintingHandler(bad, badWarrant, address(badDistributor), badFactory, 0, 1 wei);

        h.openSeries(0, 0, 0, 0, 1e18);
        h.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) = CollateralCheck.violations(bad, h.stockAddresses(), h.seriesIds());
        assertEq(perSeries, 0, unicode"不变量 1① 对「只铸权证」是瞎的");
        assertEq(global, 0, unicode"不变量 1② 对「只铸权证」是瞎的");
        assertEq(h.conservationViolations(), 0, unicode"守恒计数对「只铸权证」也是瞎的");
        assertGt(h.warrantViolations(), 0, unicode"这条缝只有权证计数看得见");
    }

    /// @dev 探测器反证的另一半：判据必须对**真实**的池子给出零违规，
    ///      否则上一条测试证明的只是「它总是响」。
    function test_theDetectorIsSilentOnTheRealPool() public {
        handler.openSeries(0, 0, 0, 0, 1e18);
        handler.depositAndMint(0, 0, 0, 100 ether);

        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"真实池子上 1① 不该响");
        assertEq(global, 0, unicode"真实池子上 1② 不该响");
    }
}
