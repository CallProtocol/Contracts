// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {ClearingPool} from "../../src/ClearingPool.sol";
import {MerkleDistributor} from "../../src/MerkleDistributor.sol";
import {Warrant} from "../../src/Warrant.sol";
import {IAttestationRegistry} from "../../src/interfaces/IAttestationRegistry.sol";
import {IVaultRegistry} from "../../src/interfaces/IVaultRegistry.sol";
import {IWarrant} from "../../src/interfaces/IWarrant.sol";
import {FactoryStub} from "../helpers/FactoryStub.sol";
import {IssuerComplianceStub, IssuerGatedStockToken, IssuerPauseManagerStub} from "../helpers/IssuerGating.sol";
import {MemeToken} from "../helpers/MemeToken.sol";
import {VaultStub} from "../helpers/VaultStub.sol";
import {CollateralCheck} from "./Invariant1And2MintingPath.t.sol";

/// @notice 反证要装的三个后门。**三个坏的不是同一样东西**，所以一个探测器抓得到另一个，
///         就说明其中一个是多余的：
///
/// | 后门 | 它是什么 | 谁该响 |
/// |---|---|---|
/// | `withdraw` | 教科书式的管理员出口 | 不变量 5 的托管计数、不变量 1② |
/// | `rollThroughTheVault` | **被废除的那版原设计** —— 余量经金库回流 | 不变量 5、不变量 7 的余额款、不变量 1② |
/// | `rollWithoutZeroingTheRemainder` | 滚存忘了清零 —— 同一笔余量被数两遍 | 不变量 7 的守恒款、不变量 1②（托管计数**沉默**） |
///
/// 🔴 第二个后门值得单独说：它不是编的，它是 `claimExpired → 金库 → 再存入` 那条路径的最小形状
/// （`docs/design.md` §10-25 废除的正是它）。「滚存不构成转出」这句话之所以需要被验证，
/// 就是因为一个**几乎一模一样**的实现确实会把托管权交出去，而账面上的四个数照样对得上。
///
/// @dev 生产合约里这三个入口都不存在 —— 由 `test/ClearingPool.t.sol` 枚举编译产物的 ABI 证明
///      （「对外可写函数恰好六个」），而不是由「我们没写过」这句话证明。
///      后两个刻意**不带任何前置校验**：要坏掉的是「钱去哪儿了」与「账清没清」，不是那六道门。
contract LeakyPool is ClearingPool {
    constructor(
        IWarrant warrant_,
        address distributor_,
        IAttestationRegistry attestations_,
        IVaultRegistry vaultRegistry_
    ) ClearingPool(warrant_, distributor_, attestations_, vaultRegistry_) {}

    /// @dev 后门 ①：把抵押品直接转出去。不变量 5 禁止的那件事，写成代码就这么短。
    function withdraw(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    /// @dev 后门 ②：账**全部对**，但抵押品经金库走了一趟。
    ///      四个数（remainder 减少 / deposited 增 / minted 增 / 新铸权证）一个不差，
    ///      唯独池内余额少了一截 —— 「池内重新归属」与「转出」的差别恰好只有这一行。
    function rollThroughTheVault(uint256 seriesId, uint256 nextSeriesId, address vault_) external {
        Series storage s = _series[seriesId];
        Series storage n = _series[nextSeriesId];

        uint128 amount = s.remainder;
        s.remainder = 0;
        n.deposited += amount;
        n.minted += amount;

        warrant.mint(distributor, nextSeriesId, amount);
        IERC20(s.stockToken).transfer(vault_, amount); // ← 托管权在这一行交了出去
    }

    /// @dev 后门 ③：后继系列照记，前序的 `remainder` 忘了清 —— 同一笔抵押品被两处同时声称。
    ///      抵押品一个 wei 都没动，所以托管计数对它**是瞎的**；只有守恒款与不变量 1② 看得见。
    function rollWithoutZeroingTheRemainder(uint256 seriesId, uint256 nextSeriesId) external {
        Series storage s = _series[seriesId];
        Series storage n = _series[nextSeriesId];

        uint128 amount = s.remainder;
        n.deposited += amount;
        n.minted += amount;

        warrant.mint(distributor, nextSeriesId, amount);
    }
}

/// @notice 驱动**六个入口全集**的 handler —— 不变量 5 只有在完整的对外函数面上才有意义。
///
/// 🔴 **本合约的任何函数都不 revert**（同另外四个不变量文件的取舍）：不变量跑在
/// `fail_on_revert = false` 下，handler 里的 `assertEq` 失败就是一次 revert，会被 fuzzer 静静吞掉。
/// 所以违规一律**记进计数器**，由 `invariant_*` 去断言计数为零。
///
/// # 托管判据：每个动作按「它**允许**怎样动余额」分类
///
/// | 类 | 谁 | 允许的余额变化 |
/// |---|---|---|
/// | `DEPOSIT` | `depositAndMint` | 只增不减 |
/// | `EXERCISE` | `exercise` | 成功 ⟹ 恰好减少行权量；失败 ⟹ 分毫不动 |
/// | `NEUTRAL` | `openSeries` / `pokeGating` / `settleExpired` / **`rollExpired`** / `drain` | **一个 wei 都不许动** |
///
/// 这张表就是不变量 5 的动态款：抵押品只有一条出池路径，而滚存**不在**那条路径上。
/// 结构款（没有第七个入口）由 `test/ClearingPool.t.sol` 读 ABI 断言，两款合起来才是那句「无管理员出口」。
contract RollHandler is CommonBase, StdUtils {
    enum Sabotage {
        NONE,
        WITHDRAW,
        ROLL_THROUGH_VAULT,
        ROLL_WITHOUT_ZEROING
    }

    /// @dev 动作对余额的授权等级，见合约注释里那张表。
    enum Kind {
        NEUTRAL,
        DEPOSIT,
        EXERCISE
    }

    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");
    bytes32 internal constant ERC20_TRANSFER = keccak256("Transfer(address,address,uint256)");

    ClearingPool public immutable pool;
    Warrant public immutable warrant;
    AttestationRegistry public immutable registry;
    address public immutable distributor;
    Sabotage public immutable sabotage;

    VaultStub public immutable vault;
    IssuerPauseManagerStub public immutable issuerPause;
    IssuerComplianceStub public immutable issuerCompliance;
    IssuerGatedStockToken public immutable stock;
    MemeToken public immutable meme;

    address[3] public actors;
    uint64[3] public expiries;

    uint256[] public openedSeries;
    mapping(uint256 seriesId => bool) private known;

    /// @notice 不变量 5：抵押品在**不该**动的地方动了，或行权动的量不对。必须恒为 0。
    uint256 public custodyViolations;
    /// @notice 不变量 7（守恒款）：一次成功的滚存，四个数没有全部相等的次数。必须恒为 0。
    uint256 public rollConservationViolations;
    /// @notice 不变量 7（余额款）：一次成功的滚存改动了池内余额的次数。必须恒为 0。
    uint256 public rollBalanceViolations;
    /// @notice 一次成功的滚存发出了股票 ERC-20 `Transfer` 的次数。必须恒为 0。
    uint256 public rollTransferViolations;
    /// @notice 一次**被拒**的滚存改动了余量或余额的次数。必须恒为 0。
    uint256 public rollAtomicityViolations;

    // ── 覆盖度：四条断言全是「某个计数为 0」，一个什么都没干成的 handler 同样满足它们 ──
    uint256 public successfulDeposits;
    uint256 public successfulExercises;
    uint256 public successfulSettlements;
    uint256 public successfulRolls;
    uint256 public rejectedRolls;
    /// @notice 抵押品**合法**离开池子的次数（成功的行权）。为 0 就说明托管判据从没被真正考验过。
    uint256 public collateralOutflows;
    /// @notice `withdraw(address,address,uint256)` 打在池子上被拒的次数 —— 真实池子上恒等于调用次数。
    uint256 public drainsRejected;
    /// @notice 后门真的把钱拿走了的次数。真实池子上必须恒为 0。
    uint256 public drainsSucceeded;
    /// @notice 走到过「有未行权权证在外面」的步数 —— 不变量 5 的前提（`minted > exercised`）。
    uint256 public stepsWithOutstandingWarrants;

    constructor(
        ClearingPool pool_,
        Warrant warrant_,
        AttestationRegistry registry_,
        address distributor_,
        FactoryStub factory_,
        Sabotage sabotage_
    ) {
        pool = pool_;
        warrant = warrant_;
        registry = registry_;
        distributor = distributor_;
        sabotage = sabotage_;

        vault = new VaultStub(pool_);
        issuerPause = new IssuerPauseManagerStub();
        issuerCompliance = new IssuerComplianceStub();
        stock = new IssuerGatedStockToken(issuerPause, issuerCompliance);
        meme = new MemeToken();

        // 身份根里登记这只 MEME 的金库 —— 开系列那道门认的就是这条绑定（M2-5 / #37）。
        factory_.bind(address(meme), address(vault));

        // 🔴 三个 expiry 的分工就是**滚存能不能被撞到**的全部：远的那个（下标 0，fuzzer 偏爱 0）
        //    整轮都活着，永远有一个合法后继；近的那个一次 `warp` 就跨过去，于是
        //    「存入 → 结算 → 滚存」这条链在一轮里真的走得完；中间那个让「后继自己也过期了」
        //    这条拒绝路径也有机会撞到。
        //
        //    ⚠️ 取值是**量出来的，不是希望出来的**。第一版取 400 / 10 / 60 天：一轮 64 步下来
        //    连一次成功结算都撞不到（8 次 warp 均值 3.5 天，跨不过 10 天那个的次数太少），
        //    于是四条断言全绿、但滚存一次都没执行过。改成 400 / 2 / 12 天之后实测
        //    （`--fuzz-seed 1…8`，单轮）：存入 8/8、结算 7/8、**成功滚存 3/8**；
        //    CI 档（depth 128）单轮 **8/8**。默认档 256 轮合计约上百次。
        //
        //    单轮里成功滚存的上限实测是 1 次 —— 卡在 `roll` 的 (from, to) 两个下标同时选对的概率上。
        //    连续滚存（A → B → C）因此不靠 fuzz 的运气，由
        //    `test/ClearingPoolRoll.t.sol::test_roll_survivesAChainOfRolls` 确定性覆盖。
        expiries =
            [uint64(block.timestamp + 400 days), uint64(block.timestamp + 2 days), uint64(block.timestamp + 12 days)];
        actors = [makeAddrLike("holder A"), makeAddrLike("holder B"), makeAddrLike("holder C")];

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        for (uint256 i = 0; i < actors.length; i++) {
            meme.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            meme.approve(address(pool_), type(uint256).max);
            if (i < 2) {
                vm.prank(actors[i]);
                registry_.attest(0, TERMS_0, ATTESTATION_0);
            }
        }

        // distributor 也是受益人之一：滚存铸出来的权证全都落在它身上，
        // 而 `exercise` 允许它以自己的身份替受益人发起（#13 的 `claimAndExercise` 形状）。
        meme.mint(distributor_, 1e30);
        vm.prank(distributor_);
        meme.approve(address(pool_), type(uint256).max);
    }

    function seriesCount() external view returns (uint256) {
        return openedSeries.length;
    }

    function seriesIds() external view returns (uint256[] memory) {
        return openedSeries;
    }

    function stockAddresses() external view returns (address[] memory list) {
        list = new address[](1);
        list[0] = address(stock);
    }

    // ────────────────────────────── 动作 ──────────────────────────────

    function openSeries(uint256 expirySeed, uint128 strike) external {
        strike = uint128(bound(strike, 1e15, 1e21));

        uint256 balanceBefore = _poolBalance();
        (bool ok, bytes memory ret) = address(vault)
            .call(
                abi.encodeCall(
                    VaultStub.openSeries,
                    (address(meme), address(stock), expiries[expirySeed % expiries.length], strike)
                )
            );
        _checkCustody(Kind.NEUTRAL, balanceBefore, false, 0);
        if (!ok) return;

        uint256 seriesId = abi.decode(ret, (uint256));
        if (!known[seriesId]) {
            known[seriesId] = true;
            openedSeries.push(seriesId);
        }
    }

    function depositAndMint(uint256 seriesSeed, uint256 receiverSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        amount = bound(amount, 1e15, 1e24);

        uint256 balanceBefore = _poolBalance();
        (bool ok,) =
            address(vault).call(abi.encodeCall(VaultStub.depositAndMint, (seriesId, _actor(receiverSeed), amount)));
        _checkCustody(Kind.DEPOSIT, balanceBefore, ok, 0);

        if (ok) successfulDeposits++;
    }

    /// @dev 行权是抵押品**唯一**合法的出池路径 —— 托管判据的整个考验都落在这一个动作上。
    function exercise(uint256 seriesSeed, uint256 actorSeed, uint256 amount) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];
        address who = _actor(actorSeed);

        uint256 held = warrant.balanceOf(who, seriesId);
        amount = held == 0 ? bound(amount, 0, 1e24) : bound(amount, 1, held);

        uint256 balanceBefore = _poolBalance();
        vm.prank(who);
        (bool ok,) = address(pool).call(abi.encodeCall(ClearingPool.exercise, (seriesId, amount, who)));
        _checkCustody(Kind.EXERCISE, balanceBefore, ok, amount);

        if (ok) successfulExercises++;
    }

    function poke() external {
        uint256 balanceBefore = _poolBalance();
        address(pool).call(abi.encodeCall(ClearingPool.pokeGating, (address(stock))));
        _checkCustody(Kind.NEUTRAL, balanceBefore, false, 0);
    }

    function settleExpired(uint256 seriesSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[seriesSeed % openedSeries.length];

        uint256 balanceBefore = _poolBalance();
        (bool ok,) = address(pool).call(abi.encodeCall(ClearingPool.settleExpired, (seriesId)));
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        if (ok) successfulSettlements++;
    }

    /// @dev **不变量 7 的全部观察点就在这里。**
    ///
    ///      四个数必须一起动、动一样多：前序 `remainder` 的**减少量**、后继 `deposited` 与 `minted` 的
    ///      **增量**、铸给 `distributor` 的权证数。而池内余额必须一个 wei 都不动。
    function roll(uint256 fromSeed, uint256 toSeed) external {
        if (openedSeries.length == 0) return;

        uint256 seriesId = openedSeries[fromSeed % openedSeries.length];
        uint256 nextSeriesId = openedSeries[toSeed % openedSeries.length];

        uint256 balanceBefore = _poolBalance();
        uint128 remainderBefore = pool.series(seriesId).remainder;
        ClearingPool.Series memory nextBefore = pool.series(nextSeriesId);
        uint256 warrantsBefore = warrant.balanceOf(distributor, nextSeriesId);

        // 余额相等抓不住「先转走、又转回来」；记录股票合约本身发出的 `Transfer`，
        // 让每条成功滚存都同时满足“余额未变”与“过程未转账”。
        vm.recordLogs();
        (bool ok,) = address(pool).call(_rollCalldata(seriesId, nextSeriesId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        uint128 remainderAfter = pool.series(seriesId).remainder;

        if (!ok) {
            rejectedRolls++;
            // 被拒的滚存必须什么都没留下。EVM 里这是默认行为，但实现哪天改用低层调用而忘了
            // 检查返回值时，这里是第一道会红的地方。
            if (remainderAfter != remainderBefore || _poolBalance() != balanceBefore) rollAtomicityViolations++;
            return;
        }

        successfulRolls++;
        if (_sawStockTransfer(logs)) rollTransferViolations++;

        if (remainderAfter > remainderBefore) {
            rollConservationViolations++;
            return; // 余量倒着长，下面的增量比较没有意义
        }
        uint128 moved = remainderBefore - remainderAfter;

        ClearingPool.Series memory nextAfter = pool.series(nextSeriesId);
        uint256 warrantsAfter = warrant.balanceOf(distributor, nextSeriesId);

        // 🔴 `moved == 0` 也是违规：一次「成功」却什么都没搬的滚存，要么是空转，
        //    要么是余量被记进了别处 —— 两种都不该发生。
        if (
            moved == 0 || nextAfter.deposited - nextBefore.deposited != moved
                || nextAfter.minted - nextBefore.minted != moved || warrantsAfter - warrantsBefore != moved
        ) {
            rollConservationViolations++;
        }

        if (_poolBalance() != balanceBefore) rollBalanceViolations++;
    }

    /// @dev 🔴 **对池子调 `withdraw(address,address,uint256)`。**
    ///
    ///      真实池子上这个选择器不存在、也没有 fallback，所以它每一次都 revert ——
    ///      这条动作因此是不变量 5 在 fuzz 里的**活体**形式：不是「我们没写过 withdraw」，
    ///      而是「一整轮里没有任何一次调用成功过」。装了后门的那一份上它会成功，
    ///      于是托管计数当场响。
    function drain(uint256 amount) external {
        amount = bound(amount, 1, 1e24);

        uint256 balanceBefore = _poolBalance();
        (bool ok,) = address(pool)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(stock), address(vault), amount));
        _checkCustody(Kind.NEUTRAL, balanceBefore, ok, 0);

        if (ok) drainsSucceeded++;
        else drainsRejected++;
    }

    /// @dev 时间这一维。步长对着 `expiries` 调过：一轮 64 步里期望约 8 次 warp、均值 3.5 天，
    ///      于是近的那个 expiry（10 天）会在一轮里被稳稳跨过去，结算与滚存才有得跑。
    function warp(uint32 delta) external {
        vm.warp(block.timestamp + bound(delta, 1 hours, 7 days));
    }

    // ────────────────────────────── 判据 ──────────────────────────────

    /// @dev 托管判据 —— 不变量 5 的动态款。
    ///
    ///      🔴 `NEUTRAL` 一档要求的是**严格相等**，不是「没变少」。滚存落在这一档：
    ///      只要它哪天变成「先转出去再转回来」，余额差看不出区别，但这一档看得出
    ///      —— 前提是判据写的是相等。
    function _checkCustody(Kind kind, uint256 balanceBefore, bool ok, uint256 amount) private {
        uint256 balanceAfter = _poolBalance();

        if (kind == Kind.NEUTRAL) {
            if (balanceAfter != balanceBefore) custodyViolations++;
        } else if (kind == Kind.DEPOSIT) {
            if (balanceAfter < balanceBefore) custodyViolations++;
        } else if (!ok) {
            if (balanceAfter != balanceBefore) custodyViolations++;
        } else if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) {
            custodyViolations++;
        } else if (amount != 0) {
            collateralOutflows++;
        }

        if (_hasOutstandingWarrants()) stepsWithOutstandingWarrants++;
    }

    /// @dev 不变量 5 的前提：存在某个未结算系列，它的 `minted > exercised`。
    ///      记下来是为了证明那条断言不是在一个空池子上空转。
    function _hasOutstandingWarrants() private view returns (bool) {
        for (uint256 i = 0; i < openedSeries.length; i++) {
            ClearingPool.Series memory s = pool.series(openedSeries[i]);
            if (!s.settled && s.minted > s.exercised) return true;
        }
        return false;
    }

    function _rollCalldata(uint256 seriesId, uint256 nextSeriesId) private view returns (bytes memory) {
        if (sabotage == Sabotage.ROLL_THROUGH_VAULT) {
            return abi.encodeCall(LeakyPool.rollThroughTheVault, (seriesId, nextSeriesId, address(vault)));
        }
        if (sabotage == Sabotage.ROLL_WITHOUT_ZEROING) {
            return abi.encodeCall(LeakyPool.rollWithoutZeroingTheRemainder, (seriesId, nextSeriesId));
        }
        return abi.encodeCall(ClearingPool.rollExpired, (seriesId, nextSeriesId));
    }

    /// @dev 🔴 判据**宁松勿严**：这是一条否定式断言（「找不到才是对的」），多要求一个字段
    ///      就多一种能溜过去的形状。所以只比发出者与 topic0，不比 `topics.length` 与 `data.length`
    ///      —— 一只把 `Transfer` 编码得不规范的代币仍然应该被抓住，而不是被判据放过。
    ///      与 `test/ClearingPoolRoll.t.sol` 的 `_sawTransferFrom` 是同一条判据，
    ///      那边的正向对照见 `test_theTransferDetectorFiresOnARealStockTransfer`。
    function _sawStockTransfer(Vm.Log[] memory logs) private view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(stock)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == ERC20_TRANSFER) return true;
        }
        return false;
    }

    function _poolBalance() private view returns (uint256) {
        return stock.balanceOf(address(pool));
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 i = seed % 4;
        return i == 3 ? distributor : actors[i];
    }

    function makeAddrLike(string memory name) private pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}

/// @notice **不变量 5（无管理员出口）与不变量 7（滚存守恒）。**
///
/// | # | 不变量 | 断言 |
/// |---|---|---|
/// | 5 | 无管理员出口 | 没有任何函数能在 `minted > exercised` 时把抵押品**转出本合约**；`rollExpired` 是池内重新归属，不构成转出 |
/// | 7 | 滚存守恒 | `rollExpired` 前后池内余额不变；`remainder` 减少量 == 后继 `deposited` / `minted` 增量 == 新铸权证量 |
///
/// 🔴 **不变量 5 有两款，缺一不可。**
///
/// - **结构款**：对外可写函数恰好六个 —— 读编译产物的 ABI，见 `test/ClearingPool.t.sol`。
///   它证明的是「没有第七个入口」，而那是一句关于**不存在**的话，只能这样证。
/// - **动态款**（本文件）：把六个入口按 fuzz 出来的任意顺序跑遍，抵押品**只在 `exercise` 里
///   离开过池子，且每次恰好等于行权量**。它证明的是另一件事 —— 已有的六个里没有哪一个
///   在某条路径上偷偷把钱送出去了。
///
/// 这两款互相抓不到对方：ABI 枚举对「`settleExpired` 里藏了一行 transfer」是瞎的；
/// 动态款对「加了个从没被调用过的 `withdraw`」也是瞎的。issue #12 之所以把不变量 5 放在本票，
/// 正是因为函数集到这里才填满 —— 在一个还缺函数的合约上说「没有出口」是没有意义的。
contract Invariant5And7RollAndCustodyTest is Test {
    ClearingPool internal pool;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    AttestationRegistry internal registry;
    FactoryStub internal factory;
    RollHandler internal handler;

    // handler 的种子语义写成常量。写成裸数字的话，分档一动，下面这些测试会**照常变绿**，
    // 只是不再测它们声称在测的东西。
    uint256 internal constant FAR_EXPIRY = 0;
    uint256 internal constant NEAR_EXPIRY = 1;
    uint256 internal constant MID_EXPIRY = 2;
    uint256 internal constant SUCCESSOR = 0; // openedSeries[0] —— 先开的那个（远期）
    uint256 internal constant PREDECESSOR = 1; // openedSeries[1] —— 后开的那个（近期）
    uint256 internal constant HOLDER_ATTESTED = 0;

    function setUp() public {
        // 分叉测试跑在真实时间戳上，本地默认是 1；推到一个「48 小时早就过去了」的起点。
        vm.warp(1_800_000_000);

        (pool, warrant, distributor, registry, factory) = _deploySystem(false);
        handler = new RollHandler(pool, warrant, registry, address(distributor), factory, RollHandler.Sabotage.NONE);

        targetContract(address(handler));
    }

    function _deploySystem(bool leaky)
        internal
        returns (
            ClearingPool pool_,
            Warrant warrant_,
            MerkleDistributor distributor_,
            AttestationRegistry registry_,
            FactoryStub factory_
        )
    {
        registry_ = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant_ = new Warrant();
        distributor_ = new MerkleDistributor(makeAddr("publisher"));
        factory_ = new FactoryStub();
        pool_ = leaky
            ? ClearingPool(address(new LeakyPool(warrant_, address(distributor_), registry_, factory_.registry())))
            : new ClearingPool(warrant_, address(distributor_), registry_, factory_.registry());
        warrant_.setPool(address(pool_));
        distributor_.setPool(address(pool_));
    }

    function _sabotagedHandler(RollHandler.Sabotage mode) internal returns (RollHandler h) {
        (ClearingPool p, Warrant w, MerkleDistributor d, AttestationRegistry r, FactoryStub f) = _deploySystem(true);
        h = new RollHandler(p, w, r, address(d), f, mode);
    }

    /// @dev 「已结算的前序 + 活着的后继」这一对布景，四条反证共用。
    function _settledPredecessorAndLiveSuccessor(RollHandler h) internal {
        h.openSeries(FAR_EXPIRY, 1e18);
        h.openSeries(NEAR_EXPIRY, 1e18);
        h.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);
        h.exercise(PREDECESSOR, HOLDER_ATTESTED, 30 ether);

        vm.warp(h.expiries(NEAR_EXPIRY) + 1);
        h.settleExpired(PREDECESSOR);
    }

    // ─────────────────────────── 不变量 5 ───────────────────────────

    /// @notice 抵押品只在 `exercise` 里离开过池子，且每次恰好等于行权量。
    function invariant_5_collateralOnlyEverLeavesThroughExercise() public view {
        assertEq(
            handler.custodyViolations(),
            0,
            unicode"不变量 5：抵押品在不该动的地方动了，或行权动的量不对"
        );
    }

    /// @notice `withdraw(address,address,uint256)` 在整轮里一次都没能成功。
    /// @dev 这是「没有管理员出口」的活体形式 —— 与读 ABI 的结构款各证一半。
    function invariant_5_thereIsNoWithdrawEntrypoint() public view {
        assertEq(handler.drainsSucceeded(), 0, unicode"不变量 5：池子上竟然有一个能成功的 withdraw");
    }

    /// @notice 每次成功滚存都不应让股票合约发出 `Transfer`；余额最终相等不足以证明这一点。
    function invariant_5_rollNeverEmitsAStockTransfer() public view {
        assertEq(handler.rollTransferViolations(), 0, unicode"不变量 5：滚存交易中出现了股票代币转账");
    }

    /// @notice 全池偿付覆盖：`Σ_未结算(minted − exercised) + Σ remainder ≤ balanceOf(pool)`。
    /// @dev 用的是 `Invariant1And2MintingPath.t.sol` 里的**同一份** `CollateralCheck` ——
    ///      两处各写一遍判据，等于让其中一份去验证另一份。滚存正是它的全局那一款存在的理由。
    function invariant_1_collateralisationSurvivesTheRoll() public view {
        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, unicode"不变量 1①：某个未结算系列的债权超过了它的抵押品");
        assertEq(global, 0, unicode"不变量 1②：滚存之后池内余额兜不住全部债权");
    }

    // ─────────────────────────── 不变量 7 ───────────────────────────

    function invariant_7_rollConservesTheLedgerAndTheBalance() public view {
        assertEq(
            handler.rollConservationViolations(),
            0,
            unicode"不变量 7：remainder 减少量 ≠ 后继 deposited / minted 增量 ≠ 新铸权证量"
        );
        assertEq(handler.rollBalanceViolations(), 0, unicode"不变量 7：滚存改动了池内余额");
    }

    function invariant_7_aRejectedRollLeavesNothingBehind() public view {
        assertEq(handler.rollAtomicityViolations(), 0, unicode"一次被拒的滚存留下了痕迹");
    }

    // ──────────────── 覆盖度：四条断言不是在空转 ────────────────

    /// @dev 确定性地把整条链走一遍：存入 → 行权（抵押品**合法**出池一次）→ 结算 → 滚存
    ///      → 二次滚存被拒 → `withdraw` 被拒。四条断言各自的观察点因此都真的被撞到过。
    function test_handlerReachesTheRollAndEveryRejection() public {
        handler.openSeries(FAR_EXPIRY, 1e18);
        handler.openSeries(NEAR_EXPIRY, 1e18);
        assertEq(handler.seriesCount(), 2, unicode"handler 开不出两个系列");

        handler.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);
        assertEq(handler.successfulDeposits(), 1, unicode"handler 存不进去");
        assertGt(handler.stepsWithOutstandingWarrants(), 0, unicode"不变量 5 的前提从没成立过");

        handler.exercise(PREDECESSOR, HOLDER_ATTESTED, 30 ether);
        assertEq(handler.successfulExercises(), 1, unicode"handler 行不了权");
        assertEq(handler.collateralOutflows(), 1, unicode"抵押品合法出池那一次没被记下");

        // 还没到期：滚存撞在「还没结算」上
        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.rejectedRolls(), 1, unicode"「前序未结算」这条拒绝没被撞到");

        vm.warp(handler.expiries(NEAR_EXPIRY) + 1);
        handler.settleExpired(PREDECESSOR);
        assertEq(handler.successfulSettlements(), 1, unicode"handler 结算不了");

        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.successfulRolls(), 1, unicode"handler 滚存不了");
        assertEq(handler.rollConservationViolations(), 0, unicode"而且它是守恒的");
        assertEq(handler.rollBalanceViolations(), 0, unicode"余额也没动");
        assertEq(handler.rollTransferViolations(), 0, unicode"滚存交易也没有股票 Transfer");

        // 二次滚存：`remainder` 已经归零
        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.rejectedRolls(), 2, unicode"「不可二次滚存」这条拒绝没被撞到");
        assertEq(handler.rollAtomicityViolations(), 0, unicode"被拒的那次什么都没留下");

        // 自滚：前序已结算、后继未结算，同一个 id 上两者不可能同时成立
        handler.roll(SUCCESSOR, SUCCESSOR);
        assertEq(handler.rejectedRolls(), 3, unicode"「自滚」这条拒绝没被撞到");

        // 管理员出口：真实池子上根本没有这个选择器
        handler.drain(1 ether);
        assertEq(handler.drainsRejected(), 1, unicode"withdraw 那一笔没被撞到");
        assertEq(handler.drainsSucceeded(), 0, unicode"🔴 真实池子上 withdraw 竟然成功了");

        handler.poke();
        assertEq(handler.custodyViolations(), 0, unicode"以上全程托管判据零违规");
    }

    /// @dev 中期 expiry 那一档：**后继自己也过期了**，滚存必须被拒。
    ///      少了这条，`SuccessorExpired` 那道门在 fuzz 里可能一次都撞不到。
    function test_handlerReachesTheExpiredSuccessorRejection() public {
        handler.openSeries(MID_EXPIRY, 1e18);
        handler.openSeries(NEAR_EXPIRY, 1e18);
        handler.depositAndMint(PREDECESSOR, HOLDER_ATTESTED, 100 ether);

        vm.warp(handler.expiries(MID_EXPIRY) + 1);
        handler.settleExpired(PREDECESSOR);
        assertEq(handler.successfulSettlements(), 1, unicode"前置条件：前序确实结算了");

        handler.roll(PREDECESSOR, SUCCESSOR);
        assertEq(handler.successfulRolls(), 0, unicode"过期的后继不该收得下滚存");
        assertEq(handler.rejectedRolls(), 1, unicode"「后继已过期」这条拒绝没被撞到");
        assertEq(handler.rollAtomicityViolations(), 0, unicode"而且它什么都没留下");
    }

    // ──────────────── 反证：三个探测器真的会响 ────────────────

    /// @dev 不变量 5 的探测器：教科书式的管理员出口。
    ///      🔴 断言里带上「此刻确实 `minted > exercised`」—— 不变量 5 的原文就是这个前提，
    ///      少了它，这条反证证明的只是「一个空池子被搬空了」。
    function test_theDetectorDetects_anAdminWithdraw() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.WITHDRAW);
        h.openSeries(FAR_EXPIRY, 1e18);
        h.depositAndMint(0, HOLDER_ATTESTED, 100 ether);

        ClearingPool.Series memory s = h.pool().series(h.openedSeries(0));
        assertGt(s.minted, s.exercised, unicode"前置条件：确实有未行权的权证在外面");

        h.drain(40 ether);

        assertEq(h.drainsSucceeded(), 1, unicode"前置条件：后门确实把钱拿走了");
        assertEq(h.stock().balanceOf(address(h.pool())), 60 ether, unicode"池子真的少了 40");
        assertGt(h.custodyViolations(), 0, unicode"不变量 5 的托管探测器没响");

        (, uint256 global) = CollateralCheck.violations(h.pool(), h.stockAddresses(), h.seriesIds());
        assertGt(global, 0, unicode"不变量 1② 也该跟着响");
    }

    /// @dev 🔴 **这条反证就是决策 25 本身。**
    ///
    ///      后门实现的是被废除的 `claimExpired → 金库` 路径的最小形状：账上四个数**一个不差**，
    ///      唯独抵押品经金库走了一趟。所以：
    ///      - 不变量 7 的**守恒款一声不吭** —— 它查的是账，账是对的；
    ///      - 不变量 7 的**余额款当场响**，不变量 5 的托管计数也响。
    ///
    ///      「滚存不构成转出」这句话之所以需要被验证而不是被声明，全部理由就在这条测试里。
    function test_theDetectorDetects_aRollThatRoutesThroughTheVault() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.ROLL_THROUGH_VAULT);
        _settledPredecessorAndLiveSuccessor(h);

        uint256 poolBefore = h.stock().balanceOf(address(h.pool()));
        h.roll(PREDECESSOR, SUCCESSOR);

        assertEq(h.successfulRolls(), 1, unicode"前置条件：后门确实滚了一次");
        assertEq(h.stock().balanceOf(address(h.pool())), poolBefore - 70 ether, unicode"抵押品真的出池了");
        assertGt(h.rollBalanceViolations(), 0, unicode"不变量 7 的余额款没响");
        assertGt(h.rollTransferViolations(), 0, unicode"滚存的股票 Transfer 探测器没响");
        assertGt(h.custodyViolations(), 0, unicode"不变量 5 的托管探测器没响");
        assertEq(
            h.rollConservationViolations(),
            0,
            unicode"🔴 守恒款竟然响了？那这条反证就没在演示「账对不等于钱在」"
        );
    }

    /// @dev 不变量 7 守恒款的探测器：忘了清零 —— 同一笔余量被前序与后继同时声称。
    ///      抵押品一个 wei 都没动，所以**托管计数对它是瞎的**，那个计数器因此不是冗余的。
    function test_theDetectorDetects_aRollThatForgetsToZeroTheRemainder() public {
        RollHandler h = _sabotagedHandler(RollHandler.Sabotage.ROLL_WITHOUT_ZEROING);
        _settledPredecessorAndLiveSuccessor(h);

        uint256 poolBefore = h.stock().balanceOf(address(h.pool()));
        h.roll(PREDECESSOR, SUCCESSOR);

        assertEq(h.successfulRolls(), 1, unicode"前置条件：后门确实滚了一次");
        assertEq(h.stock().balanceOf(address(h.pool())), poolBefore, unicode"前置条件：钱一个 wei 都没动");
        assertGt(h.rollConservationViolations(), 0, unicode"不变量 7 的守恒款没响");
        assertEq(h.custodyViolations(), 0, unicode"托管计数对这种坏法本来就是瞎的");
        assertEq(h.rollBalanceViolations(), 0, unicode"余额款同样是瞎的");

        // 后果说清楚：70 被两处同时声称，而池子里只有 70。
        (, uint256 global) = CollateralCheck.violations(h.pool(), h.stockAddresses(), h.seriesIds());
        assertGt(global, 0, unicode"不变量 1② 才是抓到重复计账的那一条");
    }

    /// @dev 三个探测器的另一半：它们对**真实**的池子必须全部沉默，
    ///      否则上面三条证明的只是「它们总是响」。
    function test_theDetectorsAreSilentOnTheRealPool() public {
        test_handlerReachesTheRollAndEveryRejection();

        assertEq(handler.custodyViolations(), 0, "5");
        assertEq(handler.drainsSucceeded(), 0, "5'");
        assertEq(handler.rollConservationViolations(), 0, "7");
        assertEq(handler.rollBalanceViolations(), 0, "7'");
        assertEq(handler.rollTransferViolations(), 0, "5''");
        assertEq(handler.rollAtomicityViolations(), 0, "7''");

        (uint256 perSeries, uint256 global) =
            CollateralCheck.violations(pool, handler.stockAddresses(), handler.seriesIds());
        assertEq(perSeries, 0, "1a");
        assertEq(global, 0, "1b");
    }
}
