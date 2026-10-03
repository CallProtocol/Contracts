// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {VaultRegistry} from "../../src/VaultRegistry.sol";
import {VaultFactoryProbe} from "../helpers/VaultFactoryProbe.sol";
import {FlapLaunchTest, IFlapVaultPortal, NewTokenV6WithVaultParams} from "./FlapLaunch.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";

/// @title RobinhoodVaultIdentityForkTest
/// @notice 🔴 **issue #23 的判据 1 / 2 / 5：方案 A 能不能在真实的 Flap 上立起来。**
///
/// 判据 3 / 4（绑定一次性、`vaultOf` 永不 revert）说的是我们自己合约的性质，不需要分叉，
/// 住在 `test/VaultRegistry.t.sol`。判据 6 的 factory 侧接线在本文件末尾 —— 它要在**真实链的分叉上**
/// 走一遍，因为顺序的意义只有在真的把工厂接进 Portal 之后才成立。完整的双槽构造环由
/// `test/DeploySystem.t.sol` 覆盖。
///
/// # 这个文件要证的那一句话
///
/// > 真实的 `VaultPortal.newTokenV6WithVault(…, vaultFactory = 我们的工厂)` 确实会回调我们的工厂，
/// > 且我们能在那一刻拿到**可信的** `(memeToken, vault)` 绑定。
///
/// 「可信」这个词是有内容的，而内容不是「Portal 说了算」：
///
/// - 回调那一刻 `taxToken` **还没有字节码** —— 金库先于代币创建，Portal 交给我们的是一个
///   CREATE2 预测地址（{test_theVaultIsCreatedBeforeTheToken} 量了它）。所以「去问问那个代币」
///   这条路根本不存在；
/// - 可信性只能来自**同笔交易的原子性**：Portal 在代币真部署出来之后会核对它是否等于
///   当初交给我们的那个地址，不等就 `TokenAddressMismatch()` 整笔回滚。
///   交易成功 ⟹ 绑定的就是那只真代币。**我们写下的绑定与代币的存在是同生共死的。**
///
/// 这条论证与「相信 Portal 传对了参数」是两回事，所以下面把两件事分开测：
/// {test_launchBindsTheRealToken} 证成功路径的绑定确实指向真代币，
/// {test_ourRegistryAgreesWithTheChain} 拿链上的独立事实（Portal 自己那份 `tryGetVault`）复核它。
///
/// @dev 出处与全部实测命令：`docs/research/flap-vault-identity-spike.md`。
///      发射那套机器（27 字段参数、vanity salt 反解、限频规避）住在 {FlapLaunchTest} ——
///      M2-5（issue #37）之后它有了第二个用户（`RobinhoodWarrantVaultFactory.t.sol`），
///      而这套实测取值只该有一处出处。**本文件的断言一条没动。**
contract RobinhoodVaultIdentityForkTest is FlapLaunchTest {
    VaultFactoryProbe internal factory;
    VaultRegistry internal registry;

    address internal launcher = makeAddr("project launcher");

    function setUp() public {
        // 探针落在 VaultPortal 上 —— 该高度有没有状态，要在真正会被读的合约上问。
        ForkTarget memory target = ForkConfig.robinhood();
        target.probe = VAULT_PORTAL;
        selectFork(target);

        // 只走判据 6 的 factory 侧最小路径：factory + PendingLauncherSlot → 双槽 registry →
        // factory.setRegistry() 。这里不部署 pool，也不调 pendingSlot.setRegistry() ；完整的双槽接线
        // 和锁死由 DeploySystem 测试覆盖。
        factory = new VaultFactoryProbe();
        registry = new VaultRegistry(address(factory));
        factory.setRegistry(registry);

        vm.deal(launcher, 10 ether);
    }

    // ───────────────── 前置：分叉上跑的确实是那两个真合约 ─────────────────

    /// @dev 断言之前先证明**跑的是真实合约**。Flap 换实现时这一条会先红。
    function test_theVaultPortalIsReal() public view {
        assertGt(VAULT_PORTAL.code.length, 0, unicode"VaultPortal 应当有字节码");
        assertGt(PORTAL.code.length, 0, unicode"Portal 应当有字节码");
        assertGt(TAX_TOKEN_V3_IMPL.code.length, 0, unicode"TaxTokenV3 实现应当有字节码");

        // 🔴 两个 Portal 不是同一个合约 —— 这正是最容易搞错的那一处。
        assertTrue(VAULT_PORTAL != PORTAL, unicode"VaultPortal 与 Portal 必须是两个地址");

        console2.log(string.concat("  vaultPortal=", vm.toString(VAULT_PORTAL), "  portal=", vm.toString(PORTAL)));
    }

    // ─────────────── 判据 1：Portal 真的回调我们，且绑定可信 ───────────────

    /// @notice 🔴 **判据 1 的本体。**
    function test_launchBindsTheRealToken() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        VaultFactoryProbe.Recorded memory r = factory.last();

        assertEq(factory.callCount(), 1, unicode"工厂应当被回调恰好一次");
        assertEq(r.taxToken, token, unicode"回调时拿到的地址必须就是最终建出来的那只代币");
        assertGt(token.code.length, 0, unicode"代币在交易结束时应当已经部署");
        assertEq(registry.vaultOf(token), r.vault, unicode"身份根里记的必须是我们建的那个金库");

        console2.log(
            string.concat(
                unicode"  → token=",
                vm.toString(token),
                "  vault=",
                vm.toString(r.vault),
                "  creator=",
                vm.toString(r.creator)
            )
        );
    }

    /// @notice 🔴 **我们的工厂没有在 VaultPortal 上注册过，而发射照样成功。**
    ///
    /// @dev 这一条了结的是 Flap 文档里一处**三方自相矛盾**（`docs/research/flap-vault-identity-spike.md` §6）：
    ///      规范页与快速开始说「工厂无需注册」，而 VaultPortal 的发射指引说「选一个**已注册的**工厂」，
    ///      接口里也确实留着 `registerVaultFactory(…)` 与 `error VaultFactoryNotRegistered(address)`
    ///      （两个都在本链的部署字节码里）。
    ///
    ///      文档吵成什么样都不重要 —— 分叉上跑一遍就有答案：**未注册不挡发射**，
    ///      注册只影响 Flap 前端展示的 `riskLevel` / `official` 这类标记。
    ///      这条如果哪天翻了面，方案 A 就退化成「要 Flap 点头」，那时判据 1 当场不成立，
    ///      所以它必须是一条会红的测试，而不是文档里的一句话。
    function test_ourFactoryIsNotRegisteredYetTheLaunchSucceeds() public {
        (bool enabled, bool official, uint8 riskLevel,) = vaultPortal.vaultFactories(address(factory));

        assertFalse(enabled, unicode"前置：我们的工厂不该是已注册的");
        assertFalse(official, unicode"前置：更不该是 official");
        assertEq(riskLevel, 0, unicode"前置：riskLevel 应为 UNVERIFIED");

        address token = _launch(_params(address(factory), _mineVanitySalt()));

        assertEq(registry.vaultOf(token), factory.last().vault, unicode"未注册的工厂照样绑上了");
    }

    /// @notice 🔴 **判据 1 里「可信」二字的全部依据**：回调那一刻代币还不存在。
    ///
    /// @dev 这条一旦为真，任何「回调时去代币上核对点什么」的设计都是空的。
    ///      它把可信性的来源限死成同笔交易的原子性 —— 而那是**结构**保证，不是信任假设。
    function test_theVaultIsCreatedBeforeTheToken() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        VaultFactoryProbe.Recorded memory r = factory.last();

        assertEq(
            r.taxTokenCodeSize, 0, unicode"回调那一刻 taxToken 不该有字节码（金库先于代币创建）"
        );
        assertGt(r.taxToken.code.length, 0, unicode"但交易结束后它必须已经存在");
    }

    /// @notice 回调的 `msg.sender` 是 **VaultPortal**，不是 Portal。
    ///
    /// @dev 🔴 这一条决定了那道不可变的门该钉在哪个地址上。钉错 = 上线后永远开不出系列，
    ///      而它是个 `immutable`，改不了。
    function test_theCallerIsTheVaultPortalNotThePortal() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        assertEq(factory.last().caller, VAULT_PORTAL, unicode"newVault 的调用方");
        assertTrue(factory.last().caller != PORTAL, unicode"不是 Portal");
    }

    /// @notice 链上的独立事实复核我们那份绑定：Portal 自己也记了一份 `token → vault`。
    ///
    /// @dev ⚠️ 这**不是**我们采信 Portal 那份记录 —— 它住在一个 Flap 可升级的代理上，
    ///      正是身份根要独立出来的理由。这里只把它当**第二个观测者**：两份记录对不上，
    ///      说明我们对这条流程的理解有洞。
    function test_ourRegistryAgreesWithTheChain() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        (bool found, IFlapVaultPortal.VaultInfo memory info) = vaultPortal.tryGetVault(token);

        assertTrue(found, unicode"Portal 侧也应当记到这只代币的金库");
        assertEq(info.vault, registry.vaultOf(token), unicode"两份记录必须指向同一个金库");
        assertEq(info.vaultFactory, address(factory), unicode"Portal 记的工厂应当是我们");
    }

    // ────────── 为什么身份根必须是我们自己的那一份 ──────────

    /// @notice 🔴 **Flap 那份 `token → vault` 是可被改写的，而且已经被改写过。**
    ///
    /// @dev 这条不属于六条判据里的任何一条，但它是**整个分层架构的理由**，所以钉在这里：
    ///
    ///      VaultPortal 自己也维护一份 `token → vault`（{IFlapVaultPortal-getVault}）。
    ///      直接读它，池子就不用自己建 registry 了 —— 看起来省事。但它有一条
    ///      `refreshTokenVault(address)`，`AUDITOR_ROLE` 可调，作用就是**重写**那份绑定；
    ///      链上历史里已经有一只代币被这样改过两次
    ///      （`docs/research/flap-vault-identity-spike.md` §7）。
    ///
    ///      也就是说：把池子的授权门接到 Flap 那份记录上，等于把「谁能给某只 MEME 铸权证」
    ///      交给一个我们管不着的角色。**这正是身份根要独立、要不可变的全部理由。**
    ///
    ///      这里只证「那条改写路径存在且仅由角色把门」—— 我们枚举不出 `AUDITOR_ROLE` 的持有人，
    ///      所以证不了「谁能按那个开关」，只能证**开关在**。与 `ForkConfig` 里 mock 掉
    ///      Robinhood 门控 view 的那处取舍同构：mock 替代的是「谁按了开关」，不是「按下去会怎样」。
    function test_flapsOwnBindingIsRewritableWhereasOursIsNot() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        // 改写路径存在，且只被角色挡着 —— 不是「这个函数不存在」。
        vm.prank(makeAddr("not an auditor"));
        (bool ok, bytes memory ret) = VAULT_PORTAL.call(abi.encodeCall(IFlapVaultPortal.refreshTokenVault, (token)));
        assertFalse(ok, unicode"陌生地址不该改得动 —— 但它被拒的理由是**没有角色**");
        assertGt(ret.length, 0, unicode"应当带着 AccessControl 的理由被拒，而不是「没这个函数」");

        // 我们这一份没有对应的入口可拒 —— 写入面枚举里根本没有第二个函数。
        // 结构证明在 `test/VaultRegistry.t.sol::test_writeSurface_isExactlyOneFunction`。
        assertEq(registry.vaultOf(token), factory.last().vault, unicode"我们这份没动");
    }

    // ────────── 判据 2：注册面受限（一票否决项的分叉侧证据）──────────

    /// @notice 🔴 **判据 2 的分叉侧一半**：谁都能建币，但**建不出别人代币的金库**。
    ///
    /// @dev 判据 2 真正要挡的是「抢注下移一层」。它由两条合起来成立：
    ///      ① 工厂只认 VaultPortal（本条）；
    ///      ② 身份根只认工厂、且每只 MEME 只写得进一次
    ///         （`test/VaultRegistry.t.sol`，不需要分叉）。
    ///
    ///      合起来：一条绑定只可能诞生在「Portal 正在创建这只代币」的那一刻，
    ///      而那一刻代币还不存在 —— **一只已经存在的 MEME，任何人都没有办法再给它注册金库。**
    ///      抢注因此不是「更难」，是**没有入口**。
    function test_nobodyCanCallNewVaultExceptTheVaultPortal() public {
        address[3] memory strangers = [launcher, PORTAL, address(this)];

        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.OnlyVaultPortal.selector, strangers[i]));
            factory.newVault(makeAddr("victim MEME"), address(0), strangers[i], "");
        }

        assertEq(factory.callCount(), 0, unicode"一次都不该走进去");
        assertEq(registry.vaultOf(makeAddr("victim MEME")), address(0), unicode"更不该留下任何绑定");
    }

    /// @notice 抢注者就算真去发一只币，拿到的也只是**他自己那只**的金库。
    ///
    /// @dev 这条是判据 2 的正面表述，也是它**边界**的说明：
    ///
    ///      🔴 `msg.sender == VaultPortal` 挡住的是**调用方**，不是**发起人**。任何陌生 EOA
    ///      都能去调真实的 VaultPortal、在参数里填上我们的工厂，于是我们的 `newVault` 会带着
    ///      **攻击者选的 `vaultData`、攻击者的 `creator`** 执行一遍。工厂因此是一件公共设施 ——
    ///      这是无许可发射模型的应有之义，不是漏洞。
    ///
    ///      判据 2 问的是另一件事：**能不能给「别人的、已经存在的」代币注册金库。** 不能，
    ///      而且理由是结构性的 —— 绑定只诞生于「Portal 正在创建这只代币」的那一刻，
    ///      那一刻代币还不存在（{test_theVaultIsCreatedBeforeTheToken}），此后再无入口。
    ///
    ///      ⚠️ 但「工厂是公共设施」有一个**留给 #33 的**约束：金库模板必须在敌手可控的
    ///      `vaultData` 与 `creator` 下依然安全。本票不解决它，只把它记下来。
    function test_anAttackerOnlyEverBindsTheirOwnToken() public {
        address victim = _launch(_params(address(factory), _mineVanitySalt()));
        address victimVault = registry.vaultOf(victim);

        // 攻击者自己发一只，用同一个工厂
        address attackerToken =
            _launch(_params(address(factory), _mineVanitySaltFrom(uint256(keccak256("attacker")) % 1e6)));
        VaultFactoryProbe.Recorded memory r = factory.last();

        assertTrue(attackerToken != victim, unicode"两只代币应当不同");
        assertEq(registry.vaultOf(victim), victimVault, unicode"受害者的绑定一个字节都不该动");
        assertTrue(registry.vaultOf(attackerToken) != victimVault, unicode"攻击者拿到的是自己那只的金库");

        // `creator` 就是那个陌生发起人 —— 记下这一条，它是上面那段边界说明的实测依据。
        assertTrue(r.creator != address(this), unicode"creator 是发起人，不是我们");
        assertEq(r.taxToken, attackerToken, unicode"而且只绑他自己那只");
    }

    // ────────────── 判据 5：Flap 换掉 Portal 之后会怎样 ──────────────

    /// @notice 🔴 **判据 5**：换址之后**新项目断档，已绑定的不受影响**，且断档有明确失败信号。
    ///
    /// @dev 「Flap 换掉 Portal」的现实形态有两种，后果完全不同，所以分开说：
    ///
    ///      | 形态 | 后果 |
    ///      |---|---|
    ///      | 升级代理**背后的实现**（`0xe9F7…` 不变） | 我们这边**什么都不用做** —— 门钉的是代理地址 |
    ///      | 部署**新的** VaultPortal（新地址），旧的停用 | 新项目断档，需要重新部署一份工厂 |
    ///
    ///      本条测第二种。两件事必须同时成立才算「可打折」：
    ///      ① 已绑定项目照常 —— `vaultOf` 是纯 storage 读，与 Portal 无关；
    ///      ② 断档**不是静默的** —— 旧入口整笔 revert，新 Portal 也进不了我们的工厂
    ///        （后者由 {test_afterTheMove_aNewPortalStillCannotRegister} 单独钉）。
    ///
    ///      🔴 停用用 `vm.etch(…, hex"fe")`（INVALID）而不是 `hex"00"`：`0x00` 是 `STOP`，
    ///      调用它会**成功**并返回空 —— 那恰好是本条要排除的「静默」形状，拿它当停用模型
    ///      会让测试自己制造出想要的答案。
    function test_whenFlapMovesThePortal_boundProjectsSurvive_newOnesFailLoudly() public {
        address bound = _launch(_params(address(factory), _mineVanitySalt()));
        address boundVault = registry.vaultOf(bound);
        assertTrue(boundVault != address(0), unicode"前置：这只应当已经绑上了");

        // Flap 迁走，旧入口停用
        vm.etch(VAULT_PORTAL, hex"fe");

        // ① 已绑定的照常读得出来
        assertEq(registry.vaultOf(bound), boundVault, unicode"已绑定项目必须不受影响");

        // ② 新项目：从旧地址发射整笔失败，不会静默绑到别处
        address who = _freshLauncher();
        vm.prank(who, who);
        (bool ok,) = VAULT_PORTAL.call(
            abi.encodeCall(
                IFlapVaultPortal.newTokenV6WithVault, (_params(address(factory), _mineVanitySaltFrom(700_001)))
            )
        );
        assertFalse(ok, unicode"Portal 停用之后从旧地址发射必须失败");

        assertEq(factory.callCount(), 1, unicode"工厂不该被第二次回调");
    }

    /// @notice 换址之后，即便有人直接照着新 Portal 的身份来敲我们的工厂，也进不去。
    /// @dev 这是「失败信号明确」的另一半：不是「换个 Portal 就自动接上了」，
    ///      而是必须**重新部署一份工厂**（常量变了），已有绑定则跟着旧 registry 原样存在。
    function test_afterTheMove_aNewPortalStillCannotRegister() public {
        address newPortal = makeAddr("Flap's next VaultPortal");

        vm.prank(newPortal);
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.OnlyVaultPortal.selector, newPortal));
        factory.newVault(makeAddr("some MEME"), address(0), newPortal, "");
    }

    // ─────────────────── 判据 6：factory 侧接线已锁死 ───────────────────

    /// @notice 🔴 **判据 6 的 factory 侧**：`factory` + `PendingLauncherSlot` → 双槽 `VaultRegistry` →
    ///         `factory.setRegistry()`，且工厂那个一次性槽已锁死。
    ///
    /// @dev `setUp` 已经按这个最小顺序走过一遍了（在分叉上）。这里只断言 factory 在 registry
    ///      名单中、并且其 `setRegistry` 一次性槽已锁死；预留位的接线与锁死由 DeploySystem 测试另行验证。
    function test_theFactorySideOfTheIdentityRootIsWiredAndLocked() public {
        assertTrue(registry.isFactory(address(factory)), unicode"名单里有这个工厂");
        assertEq(address(factory.registry()), address(registry), "factory.registry");

        // 一次性：部署者自己也改不了第二次
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.RegistryAlreadySet.selector, address(registry)));
        factory.setRegistry(VaultRegistry(makeAddr("another registry")));

        // 抢跑：非部署者更不行
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.NotDeployer.selector, launcher));
        factory.setRegistry(VaultRegistry(makeAddr("hijacked registry")));

        assertEq(address(factory.registry()), address(registry), unicode"那两次尝试不该改动任何东西");
    }

    /// @notice 顺带记下 Portal 在发射过程中调过我们工厂哪些**未实现**的选择器。
    /// @dev 静默吞掉它们等于对「Flap 加了新的必需钩子」失明 —— 那种变更第一次出现时
    ///      多半还是可选的，等它变成必需就晚了。
    function test_reportUnknownSelectorsThePortalProbed() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        bytes4[] memory unknown = factory.unknownSelectors();
        for (uint256 i = 0; i < unknown.length; i++) {
            console2.log(string.concat(unicode"  Portal 还探测了：", vm.toString(unknown[i])));
        }
        console2.log(string.concat(unicode"  未实现选择器共 ", vm.toString(unknown.length), unicode" 个"));
    }
}
