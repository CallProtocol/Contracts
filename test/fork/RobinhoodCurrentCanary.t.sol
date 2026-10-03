// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

import {FlapGmeLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

interface ICurrentFlapTaxTokenV3 {
    function buyTaxRate() external view returns (uint256);
    function sellTaxRate() external view returns (uint256);
}

interface ICurrentFlapPortal {
    struct TokenStateV9Safe {
        uint8 status;
        uint256 reserve;
        uint256 circulatingSupply;
        uint256 price;
        uint8 tokenVersion;
        uint256 r;
        uint256 h;
        uint256 k;
        uint256 dexSupplyThresh;
        address quoteTokenAddress;
        bool nativeToQuoteSwapEnabled;
        bytes32 extensionID;
        uint256 buyTaxRate;
        uint256 sellTaxRate;
        address pool;
        uint256 progress;
        uint8 lpFeeProfile;
        uint8 dexId;
        uint16 bondingCurveFeeRate;
    }

    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function getTokenV9Safe(address token) external view returns (TokenStateV9Safe memory);

    /// @dev 枚举字段一律读成 `uint8` —— 与 `IFlapPortalLens` 走 `V8Safe` 是同一条理由：
    ///      Flap 往 `CurveType` 里加一个变体，声明成枚举的调用方会**从那一刻起解码即 revert**。
    ///      而这条 canary 存在的意义正是在那种时刻给出一条**可读**的红，不是一条解码错误。
    ///      （`CurveType` 确实在长：测试网实现只到 27，主网已到 ≥34。）
    function getQuoteTokenConfiguration(address quoteToken) external view returns (QuoteTokenConfiguration memory);

    /// @dev 🔴 **第二个专门用来关掉发币的开关**，与上面那个是**两处不同的存储**：
    ///      `setQuoteTokenConfiguration(quote, {enabled: 0, …})` 是「这只币不再是计价币」，
    ///      `setQuoteTokenCreationDisabled(quote, true)` 是「它还是计价币，但不许再用它发新币」。
    ///      两条都只要一笔普通交易，两条都让 `WarrantLauncher.launch` 停摆，
    ///      而**只盯其中一条会漏掉另一条**。
    ///
    ///      ⚠️ 它不在 `src/flap/IPortal.sol` 里 —— 那份是 Flap 示例仓库的**子集**。
    ///      本函数最初取自主网旧 Portal 实现 `0x7Bc20c2C…fA06` 的已验证 ABI（92 个函数）；
    ///      #146 又在新实现 `0xa3b9…ff44` 上实读确认该 selector 与返回语义仍在。
    function quoteTokenCreationDisabled(address quoteToken) external view returns (bool);
}

/// @notice 独立于固定历史验收的 latest canary：外部实现升级后必须在这里显式重新验收。
contract RobinhoodCurrentCanaryTest is ForkTest, FlapGmeLaunch {
    uint256 internal constant AMOUNT = 1 ether;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint8 internal constant FLAP_TAX_TOKEN_V3 = 6;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function setUp() public {
        selectFork(ForkConfig.robinhoodLatest());
    }

    function test_canaryRunsAgainstLatestState() public view {
        assertEq(forkHeight, 0, unicode"current canary 不得复用固定历史区块");
    }

    /// @dev ⚠️ 下面读 beacon 用的是 `ROBINHOOD_ACCESS_REGISTRY`，看着像读错了对象 —— 它没有。
    ///      **同一个地址身兼两职**：`isBlocked` / `paused` 和 `implementation()` 住在同一个合约里，
    ///      它既是全链共用的权限注册表，也是 GME 这只 BeaconProxy 的 beacon 本体。
    ///
    ///      🔴 所以先把这件事**证明**一遍再去读实现。否则将来 Robinhood 把两个职责拆开时，
    ///      这里会从一个陌生合约上读到一个陌生地址，然后以「GME beacon 已升级」的名义变红 ——
    ///      一条把人指向错误方向的告警。
    function test_currentGmeImplementationKeepsExactTransferSemantics() public {
        assertEq(
            address(uint160(uint256(vm.load(ForkConfig.GME, ERC1967_BEACON_SLOT)))),
            ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"GME 的 ERC-1967 beacon 槽不再指向权限注册表 —— 两个职责被拆开了，canary 该改读哪个合约要重定"
        );

        address implementation = IBeacon(ForkConfig.ROBINHOOD_ACCESS_REGISTRY).implementation();
        assertEq(
            implementation,
            ForkConfig.EXPECTED_GME_IMPLEMENTATION,
            unicode"GME beacon 已升级；必须重新核验实现后更新 canary"
        );
        assertGt(implementation.code.length, 0, unicode"GME implementation 没有代码");

        IERC20Metadata gme = IERC20Metadata(ForkConfig.GME);
        assertEq(gme.decimals(), 18, "GME.decimals()");
        assertEq(gme.symbol(), "GME", "GME.symbol()");

        address holder = makeAddr("current GME holder");
        address recipient = makeAddr("current GME recipient");
        deal(ForkConfig.GME, holder, AMOUNT);

        uint256 holderBefore = gme.balanceOf(holder);
        uint256 recipientBefore = gme.balanceOf(recipient);
        vm.prank(holder);
        assertTrue(gme.transfer(recipient, AMOUNT), unicode"GME transfer 应返回 true");

        assertEq(holderBefore - gme.balanceOf(holder), AMOUNT, unicode"GME 发送方必须恰好扣除名义额");
        assertEq(gme.balanceOf(recipient) - recipientBefore, AMOUNT, unicode"GME 接收方必须恰好收到名义额");
    }

    /// @dev 不能只盯一只旧 clone：Portal 为新发币选实现的路径是
    ///      proxy → Portal implementation 的 immutable launcher → launcher 的 immutable TaxTokenV3 implementation。
    ///      三份 codehash 与两条 PUSH 指令引用一起钉死这条选择链；任一环换实现都会先让 canary 变红。
    function test_currentPortalLaunchPathPinsTheSupportedTaxTokenImplementation() public view {
        address portalImplementation = _portalImplementation();
        assertEq(
            portalImplementation,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION,
            unicode"Flap Portal 已升级；必须重新核验新发币实现选择链"
        );
        assertEq(
            portalImplementation.codehash,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH,
            unicode"Flap Portal implementation runtime 已变化；必须重新核验 launcher"
        );
        assertTrue(
            _runtimePushesAddress(portalImplementation, ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER),
            unicode"当前 Portal implementation 不再固化预期 launcher"
        );

        address launcher = ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER;
        assertEq(
            launcher.codehash,
            ForkConfig.EXPECTED_FLAP_PORTAL_LAUNCHER_CODEHASH,
            unicode"Flap Portal launcher runtime 已变化；必须重新核验新发币实现"
        );
        assertTrue(
            _runtimePushesAddress(launcher, ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION),
            unicode"当前 launcher 不再固化 v1 支持的 FlapTaxTokenV3 implementation"
        );
        assertEq(
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION.codehash,
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION_CODEHASH,
            unicode"v1 支持的 FlapTaxTokenV3 runtime 已变化"
        );
    }

    /// @notice 🔴 **GME 此刻还是启用的计价币吗** —— 唯一盯得住「Flap 一笔普通交易让我们发不出币」的断言。
    ///
    /// @dev **它为什么不能待在 `RobinhoodTwapSource.t.sol` 里。** 那里有一条同名的
    ///      `test_gmeIsAnEnabledQuoteToken`，但那份文件跑的是 `ForkConfig.robinhood()` ——
    ///      **钉死高度**。它断言的是「区块 31,955,417 上 GME 是启用的」，一条**历史事实**：
    ///      结论没错，可它**在结构上永远发现不了将来的一次撤销**。要盯「此刻」，
    ///      断言就必须住在跑 `robinhoodLatest()` 的这份文件里。原来那条**保留**：
    ///      它锚的是那批钉死高度验收所依赖的前提，不是同一件事。
    ///
    ///      **它为什么不能被上面那条 codehash 钉子覆盖。** 升级 implementation 要动字节码，
    ///      `EXPECTED_FLAP_PORTAL_IMPLEMENTATION_CODEHASH` 会先红；而
    ///      `setQuoteTokenConfiguration(GME, {enabled: 0, …})` 只改**存储**，
    ///      字节码一个比特都不变 —— 那个钉子对它一无所知，而它便宜得多。
    ///
    ///      **两档断言，故意分开**：
    ///
    ///      | 档 | 判据 | 含义 |
    ///      |---|---|---|
    ///      | ① | `enabled == 1` **且** `quoteTokenCreationDisabled(GME) == false` | 🔴 **发行能力归零**。红了就是「今天起发不出新币」。🔴 **两个开关是两处不同的存储，必须都读** —— 只盯其中一条会漏掉另一条 |
    ///      | ② | 其余四项 == `ForkConfig` 的钉子 | ⚠️ Flap 改了 GME 的曲线档或兑换路由 —— 不停摆，但**经济参数变了**，须人工复核后再更新常量 |
    ///
    ///      两档都不影响**已发项目**：配置只在建币那一步被读，代币、金库、身份根绑定与
    ///      池内抵押品都不在 Flap 手里（边界的完整表在 `ForkConfig` 那五个常量的注释里）。
    ///
    ///      ⚠️ 与 `script/watch-market-wallet.sh` 同一条措辞规矩：**只陈述权限事实与后果边界，
    ///      不对动机下结论。** 我们对这个开关没有任何链上防御手段，能做的只有看见。
    ///
    ///      ✅ **阴性对照做过了。** 在主网分叉上冒充当前 `DEFAULT_ADMIN_ROLE` 持有人把配置改成
    ///      `(0,0,0,0,0)`，本条如期变红 —— **而同一轮里三份 codehash 的断言一条都没红**。
    ///      那两条 `[PASS]` 才是本断言必须独立存在的证明。复现见
    ///      `docs/research/robinhood-launchpad-alternatives.md` §5.1。
    function test_gmeIsStillAnEnabledQuoteTokenToday() public view {
        ICurrentFlapPortal.QuoteTokenConfiguration memory config =
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).getQuoteTokenConfiguration(ForkConfig.GME);

        // ① 停摆档 —— 两个开关都要读，只读一个会漏掉另一个。
        assertEq(
            config.enabled,
            ForkConfig.EXPECTED_GME_QUOTE_ENABLED,
            unicode"🔴 GME 不再是启用的计价币 —— WarrantLauncher 从此发不出新币（已发项目不受影响）"
        );
        assertFalse(
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).quoteTokenCreationDisabled(ForkConfig.GME),
            unicode"🔴 GME 档的建币开关被关掉了 —— 它仍是计价币，但不许再用它发新币（已发项目不受影响）"
        );

        // ② 变更档：不停摆，但经济参数变了，必须人工复核后再更新常量。
        assertEq(
            config.defaultCurve,
            ForkConfig.EXPECTED_GME_QUOTE_DEFAULT_CURVE,
            unicode"Flap 改了 GME 的默认曲线档；新发币的曲线参数与毕业线随之改变，须复核 spec §6.1"
        );
        assertEq(
            config.alternativeCurve,
            ForkConfig.EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE,
            unicode"Flap 改了 GME 的备用曲线档"
        );
        assertEq(
            config.nativeToQuoteSwapType,
            ForkConfig.EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            unicode"Flap 改了原生币→GME 的兑换路由；税收换回 GME 那一段须重新核验"
        );
        assertEq(config.dexId, ForkConfig.EXPECTED_GME_QUOTE_DEX_ID, unicode"Flap 改了 GME 档的 DEX 下标");
    }

    function test_supportedFlapImplementationKeepsExactDeadTransferSemantics() public {
        address portalImplementation = _portalImplementation();
        assertEq(
            portalImplementation,
            ForkConfig.EXPECTED_FLAP_PORTAL_IMPLEMENTATION,
            unicode"Flap Portal 已升级；必须重新核验发币实现后更新 canary"
        );
        assertGt(portalImplementation.code.length, 0, unicode"Flap Portal implementation 没有代码");

        // 每次现场发一只 GME 计价的 V3 税代币：这同时验证 launcher 的实际选择分支，
        // 不会因一只长期样本毕业而产生与实现链无关的告警。
        address token = _launchGmeQuotedToken("Implementation Canary", "ICANARY");
        ICurrentFlapPortal.TokenStateV9Safe memory state =
            ICurrentFlapPortal(ForkConfig.FLAP_PORTAL).getTokenV9Safe(token);
        assertTrue(state.status != 0, unicode"新发 Flap token 不被 Portal 识别");
        assertEq(state.quoteTokenAddress, ForkConfig.GME, unicode"新发 Flap token 必须以 GME 计价");
        assertEq(state.tokenVersion, FLAP_TAX_TOKEN_V3, unicode"新发 Flap token 不再是 V3 税代币");

        address tokenImplementation = _minimalProxyImplementation(token);
        assertEq(
            tokenImplementation,
            ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
            unicode"受支持的 FlapTaxTokenV3 实现已变化；必须重新核验销毁路径"
        );
        assertGt(tokenImplementation.code.length, 0, unicode"FlapTaxTokenV3 implementation 没有代码");

        ICurrentFlapTaxTokenV3 taxToken = ICurrentFlapTaxTokenV3(token);
        assertLe(taxToken.buyTaxRate(), 10_000, "buyTaxRate()");
        assertLe(taxToken.sellTaxRate(), 10_000, "sellTaxRate()");

        IERC20 meme = IERC20(token);
        uint256 portalBefore = meme.balanceOf(ForkConfig.FLAP_PORTAL);
        uint256 deadBefore = meme.balanceOf(BURN_ADDRESS);
        assertGe(portalBefore, AMOUNT * 2, unicode"新发 Flap token 的 Portal 库存不足两笔转账");

        vm.prank(ForkConfig.FLAP_PORTAL);
        assertTrue(meme.transfer(BURN_ADDRESS, AMOUNT), unicode"MEME transfer 应返回 true");
        assertEq(
            portalBefore - meme.balanceOf(ForkConfig.FLAP_PORTAL), AMOUNT, unicode"transfer 发送方必须恰好扣款"
        );
        assertEq(
            meme.balanceOf(BURN_ADDRESS) - deadBefore, AMOUNT, unicode"transfer 的 0xdead 必须恰好实收名义额"
        );

        portalBefore = meme.balanceOf(ForkConfig.FLAP_PORTAL);
        deadBefore = meme.balanceOf(BURN_ADDRESS);

        vm.prank(ForkConfig.FLAP_PORTAL);
        assertTrue(meme.approve(address(this), AMOUNT), unicode"MEME approve 应返回 true");
        assertTrue(
            meme.transferFrom(ForkConfig.FLAP_PORTAL, BURN_ADDRESS, AMOUNT), unicode"MEME transferFrom 应返回 true"
        );

        assertEq(
            portalBefore - meme.balanceOf(ForkConfig.FLAP_PORTAL),
            AMOUNT,
            unicode"transferFrom 发送方必须恰好扣款"
        );
        assertEq(
            meme.balanceOf(BURN_ADDRESS) - deadBefore,
            AMOUNT,
            unicode"transferFrom 的 0xdead 必须恰好实收名义额"
        );
    }

    function _minimalProxyImplementation(address token) private view returns (address implementation) {
        bytes memory runtimeCode = token.code;
        assertEq(runtimeCode.length, 45, unicode"当前 Flap 样本不再是 EIP-1167 minimal proxy");
        assembly ("memory-safe") {
            implementation := shr(96, mload(add(runtimeCode, 0x2a)))
        }
    }

    function _portalImplementation() private view returns (address) {
        return address(uint160(uint256(vm.load(ForkConfig.FLAP_PORTAL, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _runtimePushesAddress(address account, address expected) private view returns (bool) {
        bytes memory runtimeCode = account.code;
        uint256 i;
        while (i < runtimeCode.length) {
            uint8 opcode = uint8(runtimeCode[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                uint256 width = opcode - 0x5f;
                if (i + width >= runtimeCode.length) return false;

                bytes32 operand;
                assembly ("memory-safe") {
                    operand := mload(add(add(runtimeCode, 0x21), i))
                }
                if (width == 20 && address(uint160(uint256(operand) >> 96)) == expected) return true;
                if (width == 32 && operand == bytes32(uint256(uint160(expected)))) return true;

                i += width + 1;
            } else {
                i++;
            }
        }
        return false;
    }
}
