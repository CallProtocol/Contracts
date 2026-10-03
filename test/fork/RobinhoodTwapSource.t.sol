// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PriceSource} from "../../src/PriceSource.sol";
import {WarrantVault} from "../../src/WarrantVault.sol";
import {IClearingPool} from "../../src/interfaces/IClearingPool.sol";
import {IDexPair, IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {WarrantVaultHarness} from "../helpers/WarrantVaultHarness.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";
import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";

/// @dev 一次「拿 X 换 Y」的兑换。原生币用零地址。
struct ExactInputParams {
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 minOutputAmount;
    bytes permitData;
}

/// @dev 本文件用到的 Portal 面。读的那一半住在 `src/interfaces/IFlapPortalLens.sol`（生产代码）；
///      这里只补上兑换与计价币配置 —— 发币走共享的 {FlapGmeLaunch}。
interface IFlapPortal {
    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
    function getQuoteTokenConfiguration(address quoteToken) external view returns (QuoteTokenConfiguration memory);
}

/// @title RobinhoodTwapSourceForkTest
/// @notice 🔴 **M2-2 那条「必须实测确认」的验收（issue #34），以及 spec §14-6 的收口。**
///
/// 票面把 `getTokenV8Safe().price` 的精度与语义列为**开放项**，要求「在分叉上对真实 Portal 读一次」。
/// 这个文件就是那一次读，而且它读出来的结论**推翻了票面的一处默认假设**：
///
/// > Flap 给的 `price` 是**这只 MEME 值多少计价币**；而环形缓冲要的是**一份股票值多少 MEME**。
/// > 两者互为倒数。
///
/// 只要 MEME 是以股票代币计价发射的（Flap 规范要求 `vaultQuoteToken()` 等于所服务代币的计价币），
/// 这个反演就是必需的。完整推导与取舍在 {PriceSource} 的注释里，实测记录在
/// `docs/research/flap-portal-price-semantics.md`。
///
/// # 这里证的四件替身证不了的事
///
/// | | 为什么只能在真链上证 |
/// |---|---|
/// | 镜头返回**恰好** 18 个静态字 | 字段顺序与宽度是 Flap 的事实，不是我们的约定 |
/// | `price` 就是曲线的**边际价**（用 `r/h/k/s` 复算对得上） | 这是量纲论证的算术形式，替身里我们想让它等于几就等于几 |
/// | **GME 是这条链上启用的计价币**，而且真发得出一只 GME 计价的 TOKEN_TAXED_V3 | 整个产品成立的前提。仓库旧注释写的是「原生币是唯一启用的计价币」 |
/// | 一笔**真实的**大额买入之后，24 小时读数几乎不动 | 价格冲击由真实曲线给出，不是我们摆出来的数 |
///
/// 毕业分支那两条事实（`price` 归零、池子是 V2 形状）同样在这里读真链；真实 pair 的
/// `blockTimestampLast` 与标准 cumulative getter 也在形状测试中核对。那只能证明外部 ABI 的事实，
/// **不能**把本文件的曲线买入测试说成 V2 抗操纵证明：本链还没有 GME 计价的已毕业代币，
/// 所以我们自己的池子分支与同块拦截只能用替身跑完整路径。
contract RobinhoodTwapSourceForkTest is ForkTest, FlapGmeLaunch {
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;
    address internal constant GME = ForkConfig.GME;

    /// @dev 镜头返回值的字节数 —— 18 个静态字。**独立写死**，不从 {PriceSource} 读。
    uint256 internal constant LENS_RETURN_BYTES = 18 * 32;

    /// @notice 一只**已毕业**的真实 Flap 代币，以及它的池子。
    ///
    /// @dev 挑选判据有三条，缺一不可：
    ///      ① 毕业发生在**钉死高度之前**（区块 30,990,499 < 31,955,417）—— 否则钉死那一层跑不到；
    ///      ② 毕业是**不可逆**的，所以它在 latest 上同样成立，两种高度用同一个样本；
    ///      ③ 它是**原生币计价**的（本链目前没有 GME 计价的已毕业代币），因此它在这里
    ///         只用来证「Flap 毕业后长什么样」，不用来跑我们金库的池子分支。
    ///
    ///      出处：Portal 的 `LaunchedToDEX(address,address,uint256,uint256)` 日志
    ///      （topic0 `0x6e4f4763…`），全历史共 269 条，本条在区块 30,990,499。
    address internal constant GRADUATED_TOKEN = 0x7c646A41572B441527169C576ef0c0A40c667777;
    address internal constant GRADUATED_POOL = 0x0390E65412d4704A612997432E4eeA8B7688232B;

    IFlapPortal internal portal;

    function setUp() public {
        ForkTarget memory target = ForkConfig.robinhood();
        // 探针落在 Portal 上 —— 该高度有没有状态，要在真正会被读的合约上问。
        target.probe = PORTAL;
        selectFork(target);

        portal = IFlapPortal(PORTAL);
    }

    // ─────────────────── 前置：跑的确实是那个真合约 ───────────────────

    function test_thePortalIsReal() public view {
        assertEq(block.chainid, ForkConfig.ROBINHOOD_CHAIN_ID, unicode"这份测试只在 Robinhood Chain 上有意义");
        assertGt(PORTAL.code.length, 0, unicode"Portal 地址上应当有代码");
        assertGt(GME.code.length, 0, unicode"GME 应当有代码");
    }

    // ─────────────────── 镜头的形状：恰好 18 个静态字 ───────────────────

    /// @notice 🔴 {PriceSource} 按**字下标**取值，前提是返回值恰好这么长。
    ///
    /// @dev 这条断言的价值在于它会**先于**一次静默读错值变红：Flap 若把镜头的返回结构改了，
    ///      按下标取到的就是别的字段，而那不会报错 —— 只会得出一个错误的 strike。
    function test_theLensReturnsExactlyEighteenStaticWords() public {
        address token = _launchGmeQuoted();

        (bool ok, bytes memory ret) = PORTAL.staticcall(abi.encodeCall(IFlapPortalLens.getTokenV8Safe, (token)));
        assertTrue(ok, unicode"镜头应当读得通");
        assertEq(ret.length, LENS_RETURN_BYTES, unicode"🔴 返回值不是 18 个字了 —— 下标全部作废");

        // 顺带证明它确实可以按 struct 解开（两条路殊途同归）。
        IFlapPortalLens.TokenStateV8Safe memory state = abi.decode(ret, (IFlapPortalLens.TokenStateV8Safe));
        assertEq(state.quoteTokenAddress, GME, unicode"下标 9 是计价币");
        assertEq(state.tokenVersion, ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3, unicode"下标 4 是代币版本");
    }

    // ─────────────────── 语义：price 是曲线的边际价 ───────────────────

    /// @notice 🔴 **`price` 的语义与精度，用算术钉死。**
    ///
    /// @dev Flap 上游 `LibCurve` 的原文是
    ///      *"price (wei) of a token (1e18) if you buy/sell infinitesimal amount at current supply"*，
    ///      公式 `k / (1e9 + h - s)²`（WAD 定点）。这里在**真实链上**把它复算一遍：
    ///      拿镜头自己给的 `r / h / k / circulatingSupply` 算出 `price`，与镜头给的 `price` 逐位比较。
    ///
    ///      对上了，就同时证明了三件事，而且不依赖任何文档：
    ///      ① `price` 的分子单位是**计价币的最小单位**（因为 `reserve` 也是，且 `reserve` 的复算同样对上）；
    ///      ② 分母是 **1e18 raw 单位的该代币**；
    ///      ③ 它是 **18 位定点**（公式里的 `mulWad` / `divWad` 就是那两次 1e18）。
    ///
    ///      于是「1e18 raw 股票值多少 raw MEME」= `1e36 / price` 这一步的量纲就是封闭的。
    function test_curvePriceIsTheMarginalCurvePriceInQuoteUnits() public {
        address token = _launchGmeQuoted();
        IFlapPortalLens.TokenStateV8Safe memory state = _state(token);

        assertEq(state.status, 1, unicode"刚发出来的代币在曲线上");
        assertEq(
            state.quoteTokenAddress,
            GME,
            unicode"🔴 计价币是 GME —— 于是 price 的分子是 GME 的最小单位"
        );

        uint256 denominator = 1_000_000_000 ether + state.h - state.circulatingSupply;
        uint256 recomputedPrice = (state.k * 1e18) / ((denominator * denominator) / 1e18);
        assertEq(state.price, recomputedPrice, unicode"🔴 price == k / (1e9 + h - s)²，逐位相等");

        // 储备也复算一遍：两条独立的恒等式同时成立，才说明我们读懂的是**同一条曲线**。
        uint256 recomputedReserve = _divWadUp(state.k, denominator) - state.r;
        assertEq(state.reserve, recomputedReserve, unicode"reserve == k/(1e9+h-s) - r");

        console2.log(
            string.concat(
                unicode"  真实 Portal：price=",
                vm.toString(state.price),
                unicode" GME-wei / 1e18 MEME  ⇒  反演后 ",
                vm.toString(uint256(1e36) / state.price),
                unicode" MEME / 1e18 GME"
            )
        );
        console2.log(
            string.concat("  r=", vm.toString(state.r), "  h=", vm.toString(state.h), "  k=", vm.toString(state.k))
        );
    }

    /// @notice 🔴 **GME 是这条链上启用的计价币** —— 整个产品架构成立的前提。
    ///
    /// @dev 仓库此前的注释写的是「原生币是这条链唯一启用的计价币」
    ///      （`test/fork/RobinhoodVaultIdentity.t.sol` 的 `_params`）。那句话是**错的**：
    ///      Flap 在区块 17,391,936 一次性给五只资产开了计价币配置（2026-08-16 按配置事件复核：
    ///      该块恰好 5 条，块 22,527,427 又开 1 只，当前共 6 只 ERC20 + 原生币），GME 是其中之一，
    ///      默认曲线是 `CURVE_RH_25_ASSET`（`r = 177.68330498`，注释写着「~$25 参考价、$10K 毕业」）——
    ///      一条**为 25 美元档资产定制**的曲线。
    ///
    ///      这条断言若变红，说明 Flap 关掉了 GME 计价，那时整个 M2 的发射路径都要重新设计，
    ///      所以它值得单独站一条。
    function test_gmeIsAnEnabledQuoteToken() public view {
        IFlapPortal.QuoteTokenConfiguration memory config = portal.getQuoteTokenConfiguration(GME);
        assertEq(config.enabled, 1, unicode"🔴 GME 必须是启用的计价币");

        console2.log(
            string.concat(
                unicode"  GME 计价配置：enabled=",
                vm.toString(uint256(config.enabled)),
                " defaultCurve=",
                vm.toString(uint256(config.defaultCurve)),
                " nativeToQuoteSwapType=",
                vm.toString(uint256(config.nativeToQuoteSwapType))
            )
        );
    }

    // ─────────────────── 毕业之后：两条只能在真链上读的事实 ───────────────────

    /// @notice 🔴 **毕业之后 `price` 恒为 0，池子是 Uniswap V2 形状。**
    ///
    /// @dev 这两条合起来才让「双分支」成为**必需**而不是优化：
    ///      ① 毕业后继续读曲线价，读到的是零，不是一个略微失真的价；
    ///      ② 池子答得上 `token0/token1/getReserves`、答不上 `slot0()` —— 所以它是 V2，
    ///         这与「本链只有 `V2_MIGRATOR` 走得通」对得上（{ForkConfig} 那三个常量）。
    function test_graduatedTokenReportsZeroCurvePriceAndAV2ShapedPool() public {
        IFlapPortalLens.TokenStateV8Safe memory state = _state(GRADUATED_TOKEN);

        assertEq(state.status, 4, unicode"这只样本应当已经毕业（status = DEX）");
        assertEq(
            state.price, 0, unicode"🔴 毕业之后曲线价恒为 0 —— 不是「略有失真」，是读到零"
        );
        assertEq(state.pool, GRADUATED_POOL, unicode"池子地址与毕业事件里的一致");
        assertEq(state.progress, 1e18, unicode"进度 100%");

        // V2 形状：三个读都答得上。
        address token0 = IDexPair(GRADUATED_POOL).token0();
        address token1 = IDexPair(GRADUATED_POOL).token1();
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IDexPair(GRADUATED_POOL).getReserves();
        assertTrue(token0 == GRADUATED_TOKEN || token1 == GRADUATED_TOKEN, unicode"配对里有这只代币");
        assertGt(uint256(reserve0), 0, unicode"池子有货");
        assertGt(uint256(reserve1), 0, unicode"池子有货");
        assertGt(
            uint256(blockTimestampLast), 0, unicode"V2 getReserves 的第三字应是最后一次储备更新时间"
        );
        assertLe(
            uint256(blockTimestampLast),
            uint256(uint32(block.timestamp)),
            unicode"在当前未发生 uint32 回绕的链高，最后更新时间不应晚于本块"
        );

        // 标准 V2 pair 也暴露累计价 getter；生产读价尚未接它们。这里核对接口形状，不能把它
        // 误写成「已经用了完整累计预言机」或「已经证明 V2 安全」。
        (bool hasPrice0Cumulative, bytes memory price0Cumulative) =
            GRADUATED_POOL.staticcall(abi.encodeWithSignature("price0CumulativeLast()"));
        (bool hasPrice1Cumulative, bytes memory price1Cumulative) =
            GRADUATED_POOL.staticcall(abi.encodeWithSignature("price1CumulativeLast()"));
        assertTrue(hasPrice0Cumulative, unicode"V2 pair 应暴露 price0CumulativeLast()");
        assertTrue(hasPrice1Cumulative, unicode"V2 pair 应暴露 price1CumulativeLast()");
        assertEq(price0Cumulative.length, 32, unicode"price0CumulativeLast() 应返回一个静态字");
        assertEq(price1Cumulative.length, 32, unicode"price1CumulativeLast() 应返回一个静态字");

        // 而 V3 的标志性入口答不上 —— 这才是「它是 V2」的**否定面**证据。
        (bool isV3,) = GRADUATED_POOL.staticcall(abi.encodeWithSignature("slot0()"));
        assertFalse(isV3, unicode"🔴 slot0() 应当读不通 —— 读得通就说明它不是 V2 配对");

        console2.log(string.concat("  graduated pool token0=", vm.toString(token0), " token1=", vm.toString(token1)));
        console2.log(string.concat("  V2 blockTimestampLast=", vm.toString(uint256(blockTimestampLast))));
    }

    /// @notice 🔴 **原生币计价的真实 MEME 会被拒**，而不是被当成「以股票计价」读出一个正常数。
    ///
    /// @dev 这是替身里那条 {PriceSource.QUOTE_MISMATCH} 在真链上的形式，也是最难发现的一类错：
    ///      读数不报错、量级也正常，只是在拿另一种资产计价。
    function test_aNativeQuotedTokenIsRefusedByAGmeVault() public {
        WarrantVault vault = _deployVault(ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE);

        vm.expectEmit(false, false, false, true, address(vault));
        emit WarrantVault.TwapSampleFailed(PriceSource.QUOTE_MISMATCH);
        assertFalse(vault.sampleTwap(), unicode"原生币计价的 MEME 不该被采进来");
        assertEq(vault.lastSampleAt(), 0, unicode"什么都没写");
    }

    // ─────────────────── 金库接真实 Portal ───────────────────

    /// @notice 金库对着真实 Portal 采一条样，读数与反演结果逐位相等；顺带量一次 gas。
    function test_theVaultSamplesTheRealPortal() public {
        address token = _launchGmeQuoted();
        WarrantVault vault = _deployVault(token);

        uint256 flapPrice = _state(token).price;

        uint256 before = gasleft();
        assertTrue(vault.sampleTwap(), unicode"真实 Portal 上应当采得到");
        uint256 gasUsed = before - gasleft();

        assertEq(vault.lastSampleAt(), uint64(block.timestamp));

        // 环还只有一条，读数当然不可用 —— 但那条样本的值可以从 description() 之外的路径核对：
        // 再补 24 个每小时观测点，组成 t0..t24 的严格 24 小时覆盖，读数应当恰好等于反演值。
        assertTrue(_fillTwapRing(vault, address(this)), unicode"每小时那一条都该写进去");
        (uint256 status, uint256 price) = vault.twap();
        assertEq(status, 0, unicode"攒满之后可用");
        assertEq(price, uint256(1e36) / flapPrice, unicode"🔴 读数就是 1e36 / Flap 的 price");

        // 🔴 gas：远小于 {PriceSource} 转发给镜头的 50 万上限。上限存在的理由是 Portal 可升级；
        //    这条断言保证我们没有把上限设得离实际开销太近（那会在 Flap 稍微变重时静默停采）。
        assertLt(gasUsed, 200_000, unicode"一次采样（含镜头读 + 两次 SSTORE）应当远低于 gas 上限");
        console2.log(string.concat(unicode"  真实 Portal 上首次 sampleTwap gas=", vm.toString(gasUsed)));
    }

    /// @notice 🔴 🔴 **本票的核心验收：一笔真实的大额买入，移不动 24 小时加权读数。**
    ///
    /// @dev 这里的价格冲击不是摆出来的 —— 是拿真 GME 在真实的联合曲线上买出来的。
    ///
    ///      流程：攒满一整环（价格全程不变）→ 一笔大额买入把现价推上去 →
    ///      攻击者立刻采一条（他能做到的最快动作）→ 立刻读。
    ///
    ///      两条断言分别对应两层防御：
    ///      ① **尾段权重**：刚写下的那条样本在位时长为 0，所以立刻读时读数**一点没动**；
    ///      ② **1/24 的正常权重**：严格每小时的本测试中，等满一小时后这条离散 spot 恰好拿
    ///         1/24。`twap()` 最终的整数除法向下取整，因此两个整数读数之差按 raw 单位比较时要
    ///         允许小于一个 raw 单位的向上取整。生产的硬上界是 `MAX_SAMPLE_GAP / 24h`；它仍是离散
    ///         采样，不是连续观测或累计预言机。
    function test_aSingleLargeBuyBarelyMovesTheDayLongReading() public {
        address token = _launchGmeQuoted();
        WarrantVault vault = _deployVault(token);

        assertTrue(_fillTwapRing(vault, address(this)), unicode"每小时那一条都该写进去");
        (uint256 status, uint256 calm) = vault.twap();
        assertEq(status, 0, unicode"先有一个可用的平静读数");

        uint256 spotBefore = uint256(1e36) / _state(token).price;

        // ── 一笔大额买入。曲线的毕业线约 400 GME（$10K @ ~$25），所以这是**整条曲线量级**的单笔。
        uint256 size = 200e18;
        address whale = makeAddr("whale");
        deal(GME, whale, size);
        vm.startPrank(whale, whale);
        IERC20(GME).approve(PORTAL, size);
        uint256 bought = portal.swapExactInput(
            ExactInputParams({
                inputToken: GME, outputToken: token, inputAmount: size, minOutputAmount: 0, permitData: ""
            })
        );
        vm.stopPrank();
        assertGt(bought, 0, unicode"这一笔应当真的成交了");

        uint256 spotAfter = uint256(1e36) / _state(token).price;
        assertLt(
            spotAfter, spotBefore, unicode"🔴 买入之后股票该换到的 MEME 变少了 —— 现价确实动了"
        );

        // ① 拉盘 → 立刻采样 → 立刻读：尾段权重为零，读数纹丝不动。
        vm.warp(block.timestamp + 1 hours);
        assertTrue(vault.sampleTwap(), unicode"攻击者抢到了这一小时的样本");
        (, uint256 immediately) = vault.twap();
        assertEq(immediately, calm, unicode"🔴 刚写下的样本在位 0 秒，对读数没有任何贡献");

        // ② 等满一小时让它在严格每小时的这一条路径上拿到完整 1/24 权重。
        vm.warp(block.timestamp + 1 hours);
        (uint256 latestStatus, uint256 afterAnHour) = vault.twap();
        assertEq(latestStatus, 0);

        uint256 spotDrop = spotBefore - spotAfter; // 现价被推走了多少
        uint256 twapDrop = calm > afterAnHour ? calm - afterAnHour : 0;

        // `twap()` 对整个加权和向下取整；因此两个整数读数的差会是这里理论 1/24 影响的上取整。
        // 比较 ceil(spotDrop / 24)，只容纳该次最终整除带来的不足一个 raw 单位误差。
        assertLe(
            twapDrop,
            (spotDrop + 23) / 24,
            unicode"🔴 严格每小时下，单段现货价对 24h 读数至多占 1/24（含最终整除取整）"
        );

        console2.log(
            string.concat(
                unicode"  单笔买入 200 GME：现价 ",
                vm.toString(spotBefore),
                unicode" → ",
                vm.toString(spotAfter),
                unicode"（跌 ",
                vm.toString(spotDrop * 100 / spotBefore),
                "%)"
            )
        );
        console2.log(
            string.concat(
                unicode"                 24h TWAP ",
                vm.toString(calm),
                unicode" → ",
                vm.toString(afterAnHour),
                unicode"（跌 ",
                vm.toString(twapDrop * 100 / calm),
                "%)"
            )
        );
    }

    // ──────────────────────────── 辅助 ────────────────────────────

    function _state(address token) internal view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(PORTAL).getTokenV8Safe(token);
    }

    /// @dev 与工厂将要做的事同形：**一行 `new`**（决策 39-A3）。取价 Portal 是构造参数，
    ///      这里传的就是本链真实的那一个 —— 本文件要证的正是它答得出真价。
    ///      This fork suite only samples prices, so nonzero immutable destinations are sufficient for deployment.
    function _deployVault(address memeToken) internal returns (WarrantVault vault) {
        vault = new WarrantVaultHarness(
            IClearingPool(makeAddr("unused clearing pool")),
            makeAddr("unused distributor"),
            PORTAL,
            memeToken,
            GME,
            makeAddr("unused creator")
        , false);
    }

    /// @dev 保留本文件的名称与代码，调用点也继续直接表达「发一只 GME 计价的测试币」；
    ///      `newTokenV6`、发起人轮换与 `7777` salt 挖矿均由 {FlapGmeLaunch} 统一实现。
    function _launchGmeQuoted() internal returns (address token) {
        return _launchGmeQuotedToken("Warrant TWAP Probe", "WTWAP");
    }

    /// @dev solady `FixedPointMathLib.divWadUp` 的等价写法，只为复算 `reserve`。
    function _divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18 + y - 1) / y;
    }
}
