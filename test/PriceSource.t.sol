// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PriceSource} from "../src/PriceSource.sol";
import {IFlapPortalLens} from "../src/interfaces/IFlapPortalLens.sol";
import {DexPairStub} from "./helpers/DexPairStub.sol";
import {FlapPortalStub} from "./helpers/FlapPortalStub.sol";
import {PriceSourceProbe} from "./helpers/PriceSourceProbe.sol";

/// @notice {PriceSource}：量纲、两个分支的切换条件，以及「一律不 revert」。
///
/// 真实 Portal 上的那一份在 `test/fork/RobinhoodTwapSource.t.sol` —— 替身证明不了
/// 「Flap 真的这么编码、真的在毕业后把 price 归零」，那些是关于**别人合约**的事实。
/// 这里证的是我们自己那段代码在给定输入下的行为，以及**字下标读对了**。
contract PriceSourceTest is Test {
    address internal meme = makeAddr("meme");
    address internal stock = makeAddr("stock");
    address internal stranger = makeAddr("stranger token");

    FlapPortalStub internal portal;
    PriceSourceProbe internal probe;

    function setUp() public {
        portal = new FlapPortalStub();
        probe = new PriceSourceProbe();
    }

    function _spot() internal view returns (uint8 status, uint256 price, uint8 source) {
        return probe.spot(address(portal), meme, stock);
    }

    // ───────────────────────── 下标：非循环的那条 ─────────────────────────

    /// @notice 🔴 **`PriceSource` 按字下标读的那四个字段，确实是 struct 里的那四个。**
    ///
    /// @dev 证法不是「再抄一遍下标对比」（那是循环的），而是让替身用 **Solidity 自己的 ABI 编码器**
    ///      按 {IFlapPortalLens.TokenStateV8Safe} 返回一个**每个字段都互不相同**的状态：
    ///      任何一个下标写错，读到的都会是另一个字段的值，于是下面某一条断言必然红。
    ///
    ///      特意让 `price` 与 `reserve` / `circulatingSupply` 不同、`quoteTokenAddress` 与 `pool` 不同 ——
    ///      相邻字段最容易读串。
    function test_wordOffsets_matchTheStructDeclaration() public {
        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 1; // 下标 0
        state.reserve = 11;
        state.circulatingSupply = 22;
        state.price = 1e18; // 下标 3 —— 反演之后恰好是 1e18
        state.tokenVersion = 6;
        state.r = 55;
        state.h = 66;
        state.k = 77;
        state.dexSupplyThresh = 88;
        state.quoteTokenAddress = stock; // 下标 9
        state.nativeToQuoteSwapEnabled = true;
        state.extensionID = bytes32(uint256(99));
        state.buyTaxRate = 300;
        state.sellTaxRate = 300;
        state.pool = stranger; // 下标 14
        state.progress = 1e17;
        state.lpFeeProfile = 1;
        state.dexId = 2;

        portal.setState(meme, state);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK, unicode"status 读的是下标 0（否则这里读到的是 reserve 之类）");
        assertEq(price, 1e18, unicode"price 读的是下标 3");
        assertEq(source, PriceSource.SOURCE_CURVE, unicode"status = 1 走曲线分支");

        // `quoteTokenAddress` 若读串成 `pool`，这条会变成 QUOTE_MISMATCH。
        state.quoteTokenAddress = stranger;
        portal.setState(meme, state);
        (status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"quoteTokenAddress 读的是下标 9");

        // `pool` 若读串成别的字段，毕业分支就会去问一个不存在的地址。
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(2e18, 1e18);
        state.status = 4;
        state.price = 0;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);
        (status, price, source) = _spot();
        assertEq(status, PriceSource.OK, unicode"pool 读的是下标 14");
        assertEq(price, 2e18, unicode"2 份 MEME 兑 1 份股票");
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    // ───────────────────────── 量纲：反演对不对 ─────────────────────────

    /// @notice 🔴 **Flap 给的是倒数。** 这条把两个方向都钉住，因为「忘了反演」在数值上
    ///         恰恰是「把 price 原样存进去」—— 一个能编译、能跑、能算出 strike 的错误。
    function test_curve_invertsFlapsPrice() public {
        // 1e18 raw MEME 值 2e18 raw 股票 ⟹ 1e18 raw 股票值 0.5e18 raw MEME。
        portal.setCurve(meme, stock, 2e18);
        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 0.5e18, unicode"MEME 比股票贵一倍时，1 份股票只值半个 MEME");

        // 反过来：MEME 很便宜。
        portal.setCurve(meme, stock, 1e9);
        (, price,) = _spot();
        assertEq(price, 1e27, unicode"1e36 / 1e9");
    }

    /// @notice 真实曲线上的量级：`price ≈ 1.73e9`（实测，见 docs/research/flap-portal-price-semantics.md）。
    /// @dev 这条钉的是**结果落在一个人能核对的范围里**，而不是某个精确值 ——
    ///      量纲一旦搞反，这里会差三十个数量级，一眼看得出来。
    function test_curve_realWorldMagnitude() public {
        portal.setCurve(meme, stock, 1_733_439_722);
        (uint8 status, uint256 price,) = _spot();

        assertEq(status, PriceSource.OK);
        // 1e36 / 1.733e9 ≈ 5.77e26 —— 「1 份股票约合 5.8 亿个 MEME」，与「10% 税、10 亿供应、
        // 曲线刚启动」的直觉一致。
        assertGt(price, 5e26, unicode"下界");
        assertLt(price, 6e26, unicode"上界");
    }

    /// @notice 反演的相对截断误差 ≤ `flapPrice / 1e36`。
    function testFuzz_curve_inversionRoundTripsWithinOneUlp(uint256 flapPrice) public {
        flapPrice = bound(flapPrice, 1, 1e30);
        portal.setCurve(meme, stock, flapPrice);

        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 1e36 / flapPrice, unicode"就是那一次整除，没有别的加工");
        assertLe(price * flapPrice, 1e36, unicode"只往下取整，绝不放大");
        assertGt((price + 1) * flapPrice, 1e36, unicode"而且只差不到一个 ulp");
    }

    // ───────────────────────── 切换条件：曲线 ↔ 池子 ─────────────────────────

    /// @notice 🔴 **切换条件是 Flap 的 `status`，而两个分支没有重叠区。**
    ///
    /// @dev 毕业之后 Flap 把 `price` 归零（实测）。所以「毕业后忘了切分支」不是精度问题，
    ///      是读到零 —— 这条断言把那个事实固定下来：`status = 4` 时哪怕 `price` 非零也不看它。
    function test_branchSwitch_isDrivenByStatusNotByWhicheverFieldLooksUsable() public {
        DexPairStub pair = new DexPairStub(stock, meme); // 顺序反过来也要认得出
        pair.setReserves(1e18, 7e18); // stock=1e18, meme=7e18

        portal.setGraduated(meme, stock, address(pair));
        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 7e18, unicode"1 份股票兑 7 份 MEME —— 与两条腿的顺序无关");
        assertEq(source, PriceSource.SOURCE_POOL);

        // 把曲线价也塞上一个**看起来能用**的值：毕业之后它必须被无视。
        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 4;
        state.price = 3e18;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);

        (, price, source) = _spot();
        assertEq(price, 7e18, unicode"🔴 status = 4 时曲线价一眼都不能看");
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    /// @notice 曲线阶段读的是曲线，哪怕 `pool` 字段上挂着一个真实存在的池子。
    function test_branchSwitch_curveStageIgnoresAnyPool() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(100e18, 1e18);

        IFlapPortalLens.TokenStateV8Safe memory state;
        state.status = 1;
        state.price = 2e18;
        state.quoteTokenAddress = stock;
        state.pool = address(pair);
        portal.setState(meme, state);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 0.5e18, unicode"曲线阶段就是曲线价");
        assertEq(source, PriceSource.SOURCE_CURVE);
    }

    /// @notice 其余四个状态一律拒绝 —— 它们要么没价，要么那个价没有意义。
    function test_otherStatuses_areRefused() public {
        uint8[4] memory refused = [0, 2, 3, 5]; // Invalid / InDuel / Killed / Staged

        for (uint256 i = 0; i < refused.length; i++) {
            portal.setCurve(meme, stock, 2e18);
            portal.setStatus(meme, refused[i]);

            (uint8 status, uint256 price, uint8 source) = _spot();
            assertEq(status, PriceSource.NOT_PRICEABLE, string.concat("status=", vm.toString(refused[i])));
            assertEq(price, 0);
            assertEq(source, PriceSource.SOURCE_NONE);
        }
    }

    // ───────────────────────── 计价币对账 ─────────────────────────

    /// @notice 🔴 **Flap 记的计价币不是我们的股票时，那个价的分母就不是我们的股票。**
    ///
    /// @dev 这一条挡的是最难发现的一类错：读数**不报错、量级也正常**，只是在拿另一种资产计价。
    ///      原生币计价的 Flap 代币（`quoteTokenAddress == address(0)`）也走这条路被拒。
    function test_quoteMismatch_isRefusedEvenThoughThePriceLooksFine() public {
        portal.setCurve(meme, stranger, 2e18);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"别的 ERC20 计价");

        portal.setCurve(meme, address(0), 2e18);
        (status,,) = _spot();
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"原生币计价");
    }

    // ───────────────────────── 池子那一侧的拒绝 ─────────────────────────

    function test_pool_refusesAPairThatIsNotOurTwoLegs() public {
        DexPairStub pair = new DexPairStub(meme, stranger);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price,) = _spot();
        assertEq(status, PriceSource.POOL_MISMATCH, unicode"配对里没有我们的股票");
        assertEq(price, 0);
    }

    function test_pool_refusesEmptyReserves() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_EMPTY, unicode"两条腿都是空的");

        pair.setReserves(1e18, 0);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_EMPTY, unicode"分母是零");
    }

    /// @notice 🔴 越出 `uint112` 的储备必须被挡在乘法之前 —— 否则那次乘法会**溢出 revert**。
    function test_pool_refusesReservesThatBreakTheAbi() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(type(uint256).max, 1e18);
        pair.setMode(DexPairStub.Mode.DirtyReserves);
        portal.setGraduated(meme, stock, address(pair));

        (bool ok, bytes memory ret) =
            address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
        assertTrue(ok, unicode"🔴 越界储备也不能让读价 revert");

        (uint8 status,,) = abi.decode(ret, (uint8, uint256, uint8));
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    /// @notice `getReserves()` 的第三字也必须严格是 `uint32`，不能静默截断后参与同块判断。
    function test_pool_refusesTimestampThatBreaksTheAbi() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setMode(DexPairStub.Mode.DirtyTimestamp);
        portal.setGraduated(meme, stock, address(pair));

        (bool ok, bytes memory ret) =
            address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
        assertTrue(ok, unicode"🔴 越界时间戳也不能让读价 revert");

        (uint8 status,,) = abi.decode(ret, (uint8, uint256, uint8));
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    /// @notice Portal 返回的 `pool` 也是 address word；高 96 位带脏数据不能被静默截断。
    function test_poolAddressWithHighBitsIsUnreadable() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));
        portal.setMode(FlapPortalStub.Mode.DirtyPool);

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.PORTAL_UNREADABLE);
        assertEq(price, 0);
        assertEq(source, PriceSource.SOURCE_NONE);
    }

    function test_pool_acceptsReservesFromAnEarlierBlock() public {
        vm.warp(1 days);
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setBlockTimestampLast(uint32(block.timestamp - 1));
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.OK);
        assertEq(price, 7e18);
        assertEq(source, PriceSource.SOURCE_POOL);
    }

    /// @notice 🔴 同一块里刚改过储备的现货价可能被操纵，宁可少一条样本也不能采它。
    function test_pool_refusesReservesUpdatedThisBlock() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(7e18, 1e18);
        pair.setBlockTimestampLast(uint32(block.timestamp));
        portal.setGraduated(meme, stock, address(pair));

        (uint8 status, uint256 price, uint8 source) = _spot();
        assertEq(status, PriceSource.POOL_UPDATED_THIS_BLOCK, unicode"同块更新的储备不能采样");
        assertEq(price, 0);
        assertEq(source, PriceSource.SOURCE_NONE);
    }

    function test_pool_refusesAPoolThatCannotBeRead() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        pair.setMode(DexPairStub.Mode.RevertAll);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"三个读都 revert");

        pair.setMode(DexPairStub.Mode.ShortReserves);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"getReserves 返回不足三个字");
    }

    /// @notice V2 的静态返回值长度固定；额外 word 也不能作为一个可信的 pair ABI 放行。
    function test_pool_refusesOverlongAbiReturns() public {
        DexPairStub pair = new DexPairStub(meme, stock);
        pair.setReserves(1e18, 1e18);
        portal.setGraduated(meme, stock, address(pair));

        pair.setMode(DexPairStub.Mode.LongToken0);
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"token0 多返回一个字也必须拒绝");

        pair.setMode(DexPairStub.Mode.LongReserves);
        (status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE, unicode"getReserves 多返回一个字也必须拒绝");
    }

    /// @notice 毕业了却没有池子地址 —— 别把零地址当成一个能问的对象。
    function test_pool_refusesTheZeroAddress() public {
        portal.setGraduated(meme, stock, address(0));
        (uint8 status,,) = _spot();
        assertEq(status, PriceSource.POOL_UNREADABLE);
    }

    // ───────────────────────── 「一律不 revert」 ─────────────────────────

    /// @notice 🔴 Portal 怎么坏，读价都只是返回一个失败码。
    ///
    /// @dev 真实 Portal 在代币不存在时**是真的 revert 的**（`TokenNotFound(address)`），
    ///      所以这不是一个假想的失败模式，而是**默认**的那个。
    function test_portal_neverRevertsWhateverItDoes() public {
        portal.setCurve(meme, stock, 2e18);

        FlapPortalStub.Mode[4] memory modes = [
            FlapPortalStub.Mode.Revert,
            FlapPortalStub.Mode.Short,
            FlapPortalStub.Mode.BurnGas,
            FlapPortalStub.Mode.Flood
        ];

        for (uint256 i = 0; i < modes.length; i++) {
            portal.setMode(modes[i]);

            (bool ok, bytes memory ret) =
                address(probe).staticcall(abi.encodeCall(PriceSourceProbe.spot, (address(portal), meme, stock)));
            assertTrue(ok, string.concat(unicode"模式 ", vm.toString(i), unicode" 让读价 revert 了"));

            (uint8 status, uint256 price,) = abi.decode(ret, (uint8, uint256, uint8));
            assertEq(status, PriceSource.PORTAL_UNREADABLE, unicode"读不出来就是读不出来");
            assertEq(price, 0);
        }

        // 恢复之后立刻又能读 —— 失败是**当次**的，不留后遗症。
        portal.setMode(FlapPortalStub.Mode.Honest);
        (uint8 finalStatus,,) = _spot();
        assertEq(finalStatus, PriceSource.OK);
    }

    /// @notice Portal 地址上根本没有代码 —— `staticcall` 会**成功**且返回空，最容易被当成「读到了」。
    function test_portal_withoutCodeIsUnreadable() public {
        (uint8 status,,) = probe.spot(makeAddr("not a portal"), meme, stock);
        assertEq(status, PriceSource.PORTAL_UNREADABLE);
    }

    /// @notice 🔴 返回一大片数据时，复制它的开销**不该**落在我们头上。
    ///
    /// @dev 与金库 `receive()` 那条同一处坑：`(bool, bytes memory) = addr.staticcall(…)`
    ///      会把整个 returndata 复制进调用方内存，而那笔内存扩张不在限额 gas 之内。
    ///      本库只收 576 字节，所以这条断言量的是「那份复制没有发生」。
    function test_portal_doesNotPayForAFloodedReturnValue() public {
        portal.setCurve(meme, stock, 2e18);
        portal.setMode(FlapPortalStub.Mode.Flood);

        (uint256 gasUsed, uint8 status) = probe.spotGas(address(portal), meme, stock);

        assertEq(status, PriceSource.PORTAL_UNREADABLE);
        // 上界 = 转发出去的 50 万（对方自己烧掉的）+ 我们这一侧的余量。
        // 复制 9000 个字要再花约 18.5 万，越过这条线。
        assertLt(gasUsed, 560_000, unicode"🔴 returndata 被复制进来了 —— 开销上界失控");
    }

    // ───────────────────── 原生计价档的计价币对账（A-3，§7.14）─────────────────────

    /// @dev WBNB 替身的地址（金库在原生档下的 `_quoteToken`）。
    address internal wbnb = makeAddr("WBNB");

    /// @notice 🔴 **原生档放行**：曲线阶段 Flap 报 `quoteTokenAddress = address(0)`，金库的
    ///         quote 是 WBNB —— 二者数值等价（1:1、同 18 位），`wrapsNative = true` 时不判 mismatch。
    function test_native_curveAcceptsZeroQuoteTokenAddress() public {
        portal.setCurve(meme, address(0), 2e18); // Flap 报原生计价（address(0)）
        (uint8 status,, uint8 source) = probe.spotNative(address(portal), meme, wbnb);
        assertEq(status, PriceSource.OK, unicode"🔴 原生档：f[1]==0 放行，不报 QUOTE_MISMATCH");
        assertEq(source, PriceSource.SOURCE_CURVE, unicode"走曲线");
    }

    /// @notice 🔴 **失败用例（对照）**：同样的 `f[1] == 0`，但**非原生档**（`wrapsNative = false`）——
    ///         仍报 `QUOTE_MISMATCH`。放行只在原生档，不是对所有金库都松了这道门。
    function test_native_nonNativeStillMismatchesOnZeroQuoteTokenAddress() public {
        portal.setCurve(meme, address(0), 2e18);
        (uint8 status,,) = probe.spot(address(portal), meme, wbnb); // wrapsNative=false
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"🔴 非原生档：f[1]==0 仍是 mismatch");
    }

    /// @notice 🔴 **失败用例**：原生档只接受 `f[1] == 0`，**不**接受任意别的地址。Flap 若报一个
    ///         既不是 0、也不是 WBNB 的计价币，说明这只代币根本不是原生计价 —— 照样 mismatch。
    function test_native_rejectsANonZeroNonWbnbQuoteTokenAddress() public {
        portal.setCurve(meme, makeAddr("some other quote"), 2e18);
        (uint8 status,,) = probe.spotNative(address(portal), meme, wbnb);
        assertEq(status, PriceSource.QUOTE_MISMATCH, unicode"🔴 原生放行只认 address(0)，不认别的地址");
    }

    /// @notice 毕业后池腿是 WBNB（`f[1] == wbnb`）：原生档下**对账直接匹配**，不靠 `f[1]==0` 那条
    ///         特判 —— 与非原生档同一条路。这里只证对账放行（不卡在 `QUOTE_MISMATCH`）；池子本身
    ///         读不读得出是另一回事（这里的池子是空壳，所以后续会落到「池不可读」，那不是对账问题）。
    function test_native_graduatedReconcilesOnWbnbPoolLeg() public {
        portal.setGraduated(meme, wbnb, makeAddr("the V2 pool"));
        (uint8 status,,) = probe.spotNative(address(portal), meme, wbnb);
        assertTrue(status != PriceSource.QUOTE_MISMATCH, unicode"🔴 f[1]==WBNB 对账通过，不卡在 mismatch");
    }
}
