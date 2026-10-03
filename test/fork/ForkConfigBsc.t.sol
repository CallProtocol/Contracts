// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";

/// @notice BSC 分叉配置的**离线**回归网 —— 一次网络请求都不发。
///
/// 分叉测试本身要 RPC 才跑得起来，于是「配置写错了」这件事在没有端点的环境里
/// （CI 的大多数 job、以及任何没配 `RPC_BSC` 的开发机）根本没人看。这个文件补上那一半：
/// 凡是**不需要连链就能证伪**的性质，都在这里钉住。
contract ForkConfigBscTest is Test {
    // ─────────────────────── 目标结构 ───────────────────────

    function test_theForkTargetIsShapedForBsc() public view {
        ForkTarget memory t = ForkConfigBsc.bsc();

        assertEq(t.chainId, 56, unicode"chainId 必须是 BSC 主网");
        assertEq(t.probe, ForkConfigBsc.GMEB, unicode"状态探针应当落在真正会被读的那个合约上");
        assertEq(t.blockNumber, ForkConfigBsc.DEFAULT_BLOCK_BSC, unicode"默认钉死高度");
        assertGt(t.rpcUrls.length, 0, unicode"候选端点表不能是空的");
    }

    /// @notice latest canary 目标：不钉高度，且**拒绝回退**。
    ///
    /// @dev `strictBlock = true` 是这条的全部意义：canary 问的是「上游今天怎么样」，
    ///      退回任何历史高度都会把问题答错，而且答得像是通过了。
    function test_theLatestTargetRefusesToFallBack() public view {
        ForkTarget memory t = ForkConfigBsc.bscLatest();

        assertEq(t.blockNumber, 0, unicode"latest 目标不钉高度");
        assertTrue(t.strictBlock, unicode"latest canary 必须拒绝回退到历史高度");
        assertEq(t.chainId, 56, "chainId");
    }

    // ─────────────────────── 🔴 与 Robinhood 的对照 ───────────────────────

    /// @notice 🔴 **决策 54 的核心事实写成断言**：GMEB 的计价币五元组与 Robinhood GME 逐位相同。
    ///
    /// @dev 它是「迁到 BSC 不必换标的资产」这句话的全部依据 —— 同一档曲线（29）、
    ///      同一个 `nativeToQuoteSwapType`（7）。这条红了意味着两条链的曲线档位分叉了，
    ///      那时经济模型算例、法务文案、前端显示乘数都要重新过一遍。
    function test_gmebQuoteConfigMatchesRobinhoodGmeByteForByte() public pure {
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_ENABLED, ForkConfig.EXPECTED_GME_QUOTE_ENABLED, "enabled"
        );
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEFAULT_CURVE,
            ForkConfig.EXPECTED_GME_QUOTE_DEFAULT_CURVE,
            unicode"defaultCurve —— 两条链同为 29（CURVE_RH_25_ASSET）"
        );
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_ALTERNATIVE_CURVE,
            ForkConfig.EXPECTED_GME_QUOTE_ALTERNATIVE_CURVE,
            "alternativeCurve"
        );
        assertEq(
            ForkConfigBsc.EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            ForkConfig.EXPECTED_GME_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE,
            "nativeToQuoteSwapType"
        );
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEX_ID, ForkConfig.EXPECTED_GME_QUOTE_DEX_ID, "dexId");

        // 顺带钉住它的绝对值 —— 上面五条只证明「两边一样」，一起改掉仍会绿。
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_DEFAULT_CURVE, 29, unicode"曲线档就是 29");
        assertEq(ForkConfigBsc.EXPECTED_GMEB_QUOTE_NATIVE_TO_QUOTE_SWAP_TYPE, 7, "swapType 7");
    }

    /// @notice ✅ 建币枚举与 Robinhood 一致 —— 那组常量在 `WarrantLauncher` 里是烧死的，
    ///         两条链共用同一份 launcher 源码，所以它们**必须**一致。
    function test_theLaunchEnumsAreTheSameOnBothChains() public pure {
        assertEq(
            ForkConfigBsc.FLAP_TOKEN_VERSION_TAXED_V3, ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3, "tokenVersion"
        );
        assertEq(ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2, ForkConfig.FLAP_MIGRATOR_TYPE_V2, "migratorType");
        assertEq(ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED, ForkConfig.FLAP_DEX_THRESH_SUPPORTED, "dexThresh");
        assertEq(ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2, 1, unicode"V2_MIGRATOR —— 3（Infinity CL）在 BSC 上被拒");
    }

    /// @notice 🔴 **「抄过来居然能读到东西」是最危险的那种错法。**
    ///
    /// @dev `ForkConfig` 的注释里记过反方向的同一件事：BSC 的 Portal 地址在 Robinhood Chain 上
    ///      **确实有 23,959 字节代码**却不是那条链的 Portal。这条测试守的是正方向 ——
    ///      BSC 这份配置里，凡是「两条链必须不同」的地址都真的不同。
    ///      它们一旦相等，分叉测试会读到一个有代码、答得出 getter、但语义完全错的合约。
    function test_theAddressesThatMustDifferReallyDo() public pure {
        assertTrue(ForkConfigBsc.FLAP_PORTAL != ForkConfig.FLAP_PORTAL, unicode"两条链的 Portal 不同址");
        assertTrue(ForkConfigBsc.GMEB != ForkConfig.GME, unicode"GMEB 与 GME 是两只不同的代币");
        assertTrue(
            ForkConfigBsc.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION
                != ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION,
            unicode"两条链的 FlapTaxTokenV3 实现不同址 —— 靓号挖矿的初始化码依赖它"
        );
        assertTrue(
            ForkConfigBsc.PINNED_GRADUATED_TAX_TOKEN_V3_SAMPLE != ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE,
            unicode"样本代币不同"
        );
        assertTrue(
            ForkConfigBsc.BSTOCK_COMPLIANCE != ForkConfig.ROBINHOOD_ACCESS_REGISTRY,
            unicode"合规模块与 Robinhood 的中央注册表不同址"
        );
    }

    // ─────────────────────── 靓号挖矿 ───────────────────────

    /// @notice 🔴 **靓号初始化码哈希必须含 BSC 那份 TaxTokenV3 实现，不是 Robinhood 那份。**
    ///
    /// @dev 这是调研报告没有预见的那条约束（`VanityAddressRequirementNotMet`，`0xca4c5b2d`）：
    ///      BSC Portal 强制代币地址以 `7777` 结尾，而挖矿的初始化码里嵌的正是实现地址。
    ///      拿 Robinhood 那份实现去挖，挖出来的 salt 在 BSC 上**一个都不对**，
    ///      每一笔发射都会在 `Portal.newTokenV6` 当场 revert。
    ///
    ///      这里独立重算一遍，不调被测函数自己的实现 —— 否则两边同时写错也会绿。
    function test_theVanityInitCodeHashEmbedsTheBscImplementation() public pure {
        bytes32 expected = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                bytes20(0x024f18294970B5c76c0691b87f138A0317156422),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertEq(ForkConfigBsc.vanityInitCodeHash(), expected, unicode"初始化码哈希");

        bytes32 robinhoodFlavoured = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
                bytes20(ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertTrue(
            ForkConfigBsc.vanityInitCodeHash() != robinhoodFlavoured,
            unicode"🔴 挖矿常量必须换成 BSC 那一份 —— 抄 Robinhood 的会让每一笔发射都 revert"
        );
    }

    /// @notice 用真实挖出来的一个 salt 复算：CREATE2 部署者是 **Portal 自己**，且地址确实以 7777 结尾。
    ///
    /// @dev salt `0x272fd24bb0` 与代币地址 `0x2f3a5Ac3…7777` 取自**同一次**真实成功的分叉发射
    ///      （`.context/bsc-probe`，2026-09-08）：那条调用树里 `newTokenV6` 的入参含该 salt，
    ///      而 `TaxProcessor.initialize` 的入参里带着算出来的代币地址 —— 两端互为交叉验证。
    ///      这条同时钉住三件事：初始化码哈希对、**部署者是 Portal 而不是 launcher**、以及靓号规则是末 2 字节。
    ///
    ///      ⚠️ 写这条测试时把两次不同运行的 salt 与地址配错过一次，被它当场抓住 ——
    ///      这正是「独立重算」比「照抄日志里的一行」值钱的地方。
    function test_aRealMinedSaltReproducesTheTokenAddress() public pure {
        bytes32 salt = bytes32(uint256(0x272fd24bb0));
        address predicted = vm.computeCreate2Address(
            salt, ForkConfigBsc.vanityInitCodeHash(), ForkConfigBsc.FLAP_PORTAL
        );

        assertEq(
            predicted,
            0x2f3a5Ac3e01748104445bF27894296Ed72397777,
            unicode"复算不出那次真实发射的代币地址 —— 初始化码或部署者变了"
        );
        assertEq(uint256(uint160(predicted)) & 0xffff, 0x7777, unicode"靓号规则：末两字节必须是 0x7777");
    }

    // ─────────────────────── 端点表 ───────────────────────

    /// @notice 没配 `RPC_BSC` 时，候选表里那个公共端点**只是个 latest 端点**。
    ///
    /// @dev 这条不测网络，测的是「我们没有偷偷把一个非归档端点当成可复现基线」：
    ///      表里只有一项，而 {ForkTest} 的第一轮（钉死高度）在它上面必然落空、
    ///      记成「没有端点能服务钉死的高度」。那是**可见的失败**，正是我们要的。
    function test_theFallbackTableHasExactlyOnePublicEndpoint() public view {
        if (bytes(vm.envOr(ForkConfigBsc.ENV_RPC_BSC, string(""))).length != 0) return; // 本机配了就跳过
        if (bytes(vm.envOr(ForkConfigBsc.ENV_RPC_BSC_LIST, string(""))).length != 0) return;

        ForkTarget memory t = ForkConfigBsc.bsc();
        assertEq(t.rpcUrls.length, 1, unicode"没有社区兜底 —— BSC 上不存在能服务历史高度的免费端点");
        assertEq(t.rpcUrls[0], ForkConfigBsc.RPC_BSC_PUBLIC, unicode"兜底项就是那个公共端点");
        assertTrue(ForkConfig.looksLikeRpcUrl(t.rpcUrls[0]), unicode"它得像个 URL");
    }
}
