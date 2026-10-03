// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest, RequiredForkUnavailable} from "./ForkTest.sol";

/// @notice `ForkTest.selectFork` 的端点选择契约。
///
/// 后面七张票的分叉测试全部继承这套选择逻辑，所以它自己得有测试。
/// 这里断言的是**选中了哪个端点、钉在哪个高度**，不是链上事实。
///
/// 下面这个合约保留真 RPC 集成覆盖：钉死高度的排序、列表解析与日志脱敏。
/// 文件末尾的 {ForkSelectionBackendTest} 则 override 三个 `_backend*` 钩子，离线锁住
/// `firstReachable` 回归、严格模式与错链立即失败。
contract ForkSelectionTest is ForkTest {
    /// @dev 连接会被立即拒绝，用来占位一个「连不上」的候选。
    string internal constant UNREACHABLE = "http://127.0.0.1:1";

    function _target(string[] memory urls) internal pure returns (ForkTarget memory) {
        return ForkTarget({
            name: "Robinhood Chain",
            chainId: ForkConfig.ROBINHOOD_CHAIN_ID,
            rpcUrls: urls,
            blockNumber: ForkConfig.DEFAULT_BLOCK_ROBINHOOD,
            // 🔴 一律严格：这些测试绝不能建立 latest 分叉。否则「CI 的分叉步骤只跑钉死高度」
            //    这句话就不成立了 —— 那正是本文件上一版被评审抓到的问题。
            strictBlock: true,
            required: false,
            probe: ForkConfig.GME
        });
    }

    function _urls(string memory a, string memory b) internal pure returns (string[] memory urls) {
        urls = new string[](2);
        urls[0] = a;
        urls[1] = b;
    }

    /// @dev 🔴 这些测试断言的是**选择策略**，而策略的输入是端点此刻的能力 —— 那是环境。
    ///      归档端点被限流时，选择器会合法地跳过，断言「选中了归档端点」就会红。
    ///      那正是本 harness 明令禁止的：环境问题必须跳过，不能变成失败。
    ///      所以每条测试先在**顶层**验前置条件，不满足就跳过（`vm.skip` 只在顶层有效）。
    ///
    ///      ⚠️ **但「合法地跳过」也是一种失效方式。** 2026-08-13 之前，被试端点是写死的
    ///      `RPC_ROBINHOOD_ARCHIVE`；那个社区端点退化成非归档之后，这三条测试**全部静默 skip**，
    ///      CI 照常绿 —— 而选择策略从此一个字节都没被验过。现在被试对象改成
    ///      {ForkConfig-pinnedCandidate}：配了 `RPC_ROBINHOOD` 或 `RPC_ROBINHOOD_LIST`（CI 走 repo secret）就用它，
    ///      于是「有归档端点」这件事同时驱动验收测试与本文件，两者不会再分头失效。
    function _requirePinnedServable(string memory url) internal {
        if (!_reachable(url) || !_hasStateAt(url, ForkConfig.GME, ForkConfig.DEFAULT_BLOCK_ROBINHOOD)) {
            // 🔴 跳过原因里用 `_safeUrl` —— 端点可能自带 key，而 skip 消息是会被打印的。
            vm.skip(
                true,
                string.concat(
                    unicode"前置条件不满足：", _safeUrl(url), unicode" 此刻服务不了钉死的高度"
                )
            );
        }
    }

    /// @notice 🔴 **显式列表配成两个端点时，第一个不可达要退到第二个。**
    ///
    /// @dev 这是多端点列表存在的**全部理由**：required 模式下单点失败就是全仓库 CI 变红，
    ///      而 2026-08-13 已经实测发生过一次。所以这条测试走的是**完整那条路** ——
    ///      从一个原始配置字符串出发，经 {ForkConfig-parseRpcList} 解析，再交给 `selectFork`，
    ///      断言它落在第二个端点上。
    ///
    ///      ⚠️ 唯一没被它覆盖的一跳是 `vm.envOr` 那次读取。那需要 `vm.setEnv`，而 `setEnv` 改的是
    ///      **进程**环境：同一次 `forge test` 里跑的每一条后续测试都会看到被改过的值（文件之间还是
    ///      并行的），于是「为了测一行解析」会把归档端点从别的测试脚下抽走。不划算，也不安全。
    function test_fallsBackToTheSecondConfiguredEndpoint() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        // `RPC_ROBINHOOD_LIST` 的形状：优先端点在前，兜底在后，以空白分隔。
        string[] memory urls = ForkConfig.parseRpcList(string.concat(UNREACHABLE, " ", ForkConfig.pinnedCandidate()));
        assertEq(urls.length, 2, unicode"两个端点应当解析成两个候选");

        selectFork(_target(urls));

        assertEq(forkUrl, _safeUrl(ForkConfig.pinnedCandidate()), unicode"第一个端点挂了就该用第二个");
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"应当钉在指定高度");
        assertEq(block.number, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, "block.number");
    }

    /// @notice 两种配置语义：旧单值逐字节不变，显式列表以空白分隔。
    ///
    /// @dev 与 {test_malformedRpcUrlIsRejectedAndGoodOnesAreNot} 同理：判据是纯函数，
    ///      所以这条测试**不碰环境变量**。
    function test_parsesExplicitWhitespaceSeparatedEndpointList() public {
        // ① 旧单值：一个候选，逐字节原样，URL 中合法的逗号也绝不能触发拆分。
        string memory commaUrl = "https://a.example/v2/key,backup?methods=a,b#fragment,c";
        string[] memory single = ForkConfig.parseConfiguredRpcs(commaUrl, "");
        assertEq(single.length, 1, unicode"单值应当解析成一个候选");
        assertEq(single[0], commaUrl, unicode"含逗号的单值不得被拆分或改写");

        string memory trailingWhitespaceAndNewline = "https://a.example/v2/key \n";
        single = ForkConfig.parseConfiguredRpcs(trailingWhitespaceAndNewline, "");
        assertEq(single[0], trailingWhitespaceAndNewline, unicode"单值尾随空白和换行必须逐字节保留");
        _assertConfiguredRejects(
            " https://a.example", "", ForkConfig.ENV_RPC_ROBINHOOD, unicode"单值前导空白沿用旧行为：拒绝"
        );

        // ② 多值：必须显式走列表变量；按写的顺序，以空格 / Tab / LF 分隔。
        string[] memory many = ForkConfig.parseRpcList(" https://a.example\t\thttps://b.example\n");
        assertEq(many.length, 2, unicode"两项");
        assertEq(many[0], "https://a.example", unicode"第一项按空白分隔");
        assertEq(many[1], "https://b.example", unicode"第二项按 Tab 和换行分隔");

        // ③ 逗号是 URL 内容，不是分隔符。
        many = ForkConfig.parseRpcList("https://a.example/v2/key,backup https://b.example?methods=a,b");
        assertEq(many.length, 2, unicode"含逗号的两个 URL 仍应解析成两项");
        assertEq(many[0], "https://a.example/v2/key,backup", unicode"第一项的 URL 逗号必须保留");
        assertEq(many[1], "https://b.example?methods=a,b", unicode"第二项 query 的 URL 逗号必须保留");

        // ④ 空串 = 没配；只有空白的显式列表不能伪装成未配置。
        assertEq(ForkConfig.parseRpcList("").length, 0, unicode"空串 = 未配置");
        _assertListRejects("  \n ", unicode"列表只有空白不是未配置");
    }

    /// @notice 🔴 列表里**任何一项**配错都必须当场说清楚，不能只看第一项。
    ///
    /// @dev 只校验第一项的实现同样能过 {test_parsesExplicitWhitespaceSeparatedEndpointList}：
    ///      那条测试里每一项都是合法的。这条从反面钉住它。
    function test_malformedEntryAnywhereInTheListIsRejected() public {
        _assertListRejects("RPC_ROBINHOOD_LIST=https://a.example", unicode"单项：变量名粘进值里");
        _assertListRejects("https://a.example example.com", unicode"第二项没有 scheme");
        _assertListRejects('https://a.example "https://b.example"', unicode"第二项带引号");
        _assertListRejects(" ,  ,", unicode"逗号不是 URL，唯一项必须被拒");
    }

    /// @notice 两个变量同时设置时不能猜覆盖顺序，否则会把用户指定的端点悄悄换掉。
    function test_rejectsSimultaneousSingleAndListConfiguration() public {
        _assertConfiguredRejects(
            "https://a.example", "https://b.example", ForkConfig.ENV_RPC_ROBINHOOD, unicode"单值与列表同时设置"
        );
    }

    /// @notice 错误链 ID 的断言消息不能把归档 URL path 中的凭据打进日志。
    function test_wrongChainMessageRedactsEndpointPathCredentials() public pure {
        ForkTarget memory target = _target(_urls("", ""));
        string memory pathUrl = "https://archive.example/v2/top-secret-key";
        string memory pathMessage = _wrongChainMessage(target, pathUrl);

        assertEq(
            pathMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/… 指向了错误的链",
            unicode"错误链消息只应显示 scheme 和 host"
        );
        assertFalse(_contains(pathMessage, "/v2/top-secret-key"), unicode"错误链消息不得包含 URL path / key");

        string memory queryUrl = "https://archive.example?api_key=top-secret-key";
        string memory queryMessage = _wrongChainMessage(target, queryUrl);
        assertEq(
            queryMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/… 指向了错误的链",
            unicode"query 中的凭据同样必须隐藏"
        );
        assertFalse(_contains(queryMessage, "api_key=top-secret-key"), unicode"错误链消息不得包含 query key");

        string memory userinfoUrl = "https://credential:top-secret@archive.example#fragment-secret";
        string memory userinfoMessage = _wrongChainMessage(target, userinfoUrl);
        assertEq(
            userinfoMessage,
            unicode"[fork:Robinhood Chain] https://archive.example/… 指向了错误的链",
            unicode"userinfo 与 fragment 中的凭据同样必须隐藏"
        );
        assertFalse(_contains(userinfoMessage, "credential"), unicode"错误链消息不得包含 userinfo 用户名");
        assertFalse(_contains(userinfoMessage, "top-secret"), unicode"错误链消息不得包含 userinfo 密码");
        assertFalse(_contains(userinfoMessage, "fragment-secret"), unicode"错误链消息不得包含 fragment");
    }

    /// @dev 必须是 external，try/catch 才拦得住。
    function parseRpcListExternal(string memory raw) external pure returns (string[] memory) {
        return ForkConfig.parseRpcList(raw);
    }

    /// @dev 必须是 external，try/catch 才拦得住。
    function parseConfiguredRpcsExternal(string memory single, string memory list)
        external
        pure
        returns (string[] memory)
    {
        return ForkConfig.parseConfiguredRpcs(single, list);
    }

    /// @dev 断言 `raw` 被拒，且**理由指向配置本身** —— 不能是别的异常顺手把测试染绿了。
    function _assertListRejects(string memory raw, string memory what) private {
        try this.parseRpcListExternal(raw) {
            fail(string.concat(unicode"这个值必须被拒：", what));
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, ForkConfig.ENV_RPC_ROBINHOOD_LIST),
                string.concat(unicode"报错必须点名 RPC_ROBINHOOD_LIST：", what)
            );
        }
    }

    function _assertConfiguredRejects(
        string memory single,
        string memory list,
        string memory variableName,
        string memory what
    ) private {
        try this.parseConfiguredRpcsExternal(single, list) {
            fail(string.concat(unicode"这个配置必须被拒：", what));
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, variableName), string.concat(unicode"报错必须点名配置变量：", what)
            );
        }
    }

    /// @notice 连不上的候选要被跳过，继续试下一个 —— 而不是就此放弃。
    function test_skipsUnreachableCandidateAndUsesTheNext() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        selectFork(_target(_urls(UNREACHABLE, ForkConfig.pinnedCandidate())));

        assertEq(forkUrl, _safeUrl(ForkConfig.pinnedCandidate()), unicode"应当选中第二个候选");
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"应当钉在指定高度");
        assertEq(block.number, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, "block.number");
    }

    /// @notice 第一个端点连得上、但服务不了钉死的高度时，必须继续找后面能服务的那个。
    ///         「可复现」优先于「连得上」——官方端点没有归档，归档端点排在它后面也要被选中。
    function test_prefersALaterCandidateThatCanServeThePinnedBlock() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        selectFork(_target(_urls(ForkConfig.RPC_ROBINHOOD_OFFICIAL, ForkConfig.pinnedCandidate())));

        assertEq(forkUrl, _safeUrl(ForkConfig.pinnedCandidate()), unicode"不能停在第一个连得上的端点");
        assertEq(forkHeight, ForkConfig.DEFAULT_BLOCK_ROBINHOOD, unicode"应当钉在指定高度");
    }

    /// @notice 🔴 链 ID 不符是**配置错误**，必须失败，不能被吞成「换下一个候选」或跳过。
    ///
    /// ⚠️ 这条测试上一版是**假阳性**：它用宽泛的 `vm.expectRevert()` 包住一次 external 调用，
    /// 而断网时 `selectFork` 内部的 `vm.skip` 在嵌套调用里会以
    /// `skip can only be used at test level` revert —— 那个异常同样满足 `expectRevert()`，
    /// 于是测试在**根本没跑到链 ID 断言**的情况下变绿。已实测复现。
    ///
    /// 现在改成：顶层先验前置条件；再用 try/catch 断言**失败原因确实是链 ID 不符**；
    /// 若撞上 `skip` 误用（说明端点在前置检查之后掉了），按环境问题在顶层跳过。
    function test_wrongChainIdFailsAndIsNotSwallowed() public {
        _requirePinnedServable(ForkConfig.pinnedCandidate());

        string[] memory urls = new string[](1);
        urls[0] = ForkConfig.pinnedCandidate();

        try this.selectForkExpectingWrongChain(_target(urls)) {
            fail(unicode"链 ID 不符时 selectFork 必须失败，而不是通过");
        } catch (bytes memory reason) {
            if (_revertMentions(reason, "skip can only be used")) {
                vm.skip(true, unicode"前置检查之后端点掉了，selectFork 走到了跳过分支");
            }
            assertTrue(
                _revertMentions(reason, unicode"指向了错误的链"),
                unicode"失败原因必须是链 ID 不符，不能是别的异常"
            );
        }
    }

    /// @notice 🔴 **配错的 `RPC_ROBINHOOD` 必须当场说清楚，不能伪装成「连不上」。**
    ///
    /// @dev 这条测试来自一次真实事故：secret 里把变量名连同值一起粘了进去
    ///      （`RPC_ROBINHOOD=https://…`）。那个值不会报「配错了」——
    ///      它一路走到 `vm.rpc` 失败，被记成「全部候选端点都连不上（无网络 / 被拦截 /
    ///      凭据无效）」，于是三条分支的 CI 同时红，而所有人都去查网络和 API key 额度了。
    ///
    ///      判据是纯函数，所以这条测试**不碰环境变量** —— `vm.setEnv` 会污染同一进程里
    ///      后续的每一条测试，为了测一句校验去动全局状态不划算。
    ///
    ///      两个方向都断言：只测「坏值被拒」的话，一个恒为 false 的判据同样通过。
    function test_malformedRpcUrlIsRejectedAndGoodOnesAreNot() public pure {
        // 真实事故里的那个形状，以及它的两个近亲
        assertFalse(
            ForkConfig.looksLikeRpcUrl("RPC_ROBINHOOD=https://example.com/v2/key"),
            unicode"变量名粘进值里 —— 必须被判为不是 URL"
        );
        assertFalse(ForkConfig.looksLikeRpcUrl('"https://example.com"'), unicode"带引号");
        assertFalse(ForkConfig.looksLikeRpcUrl(" https://example.com"), unicode"前导空格");
        assertFalse(ForkConfig.looksLikeRpcUrl("example.com"), unicode"没有 scheme");
        assertFalse(ForkConfig.looksLikeRpcUrl("http"), unicode"只有半截 scheme");

        // 反过来：真实会用到的形状一个都不能误伤
        assertTrue(ForkConfig.looksLikeRpcUrl(ForkConfig.RPC_ROBINHOOD_OFFICIAL), unicode"官方端点");
        assertTrue(ForkConfig.looksLikeRpcUrl(ForkConfig.RPC_ROBINHOOD_COMMUNITY), unicode"社区端点");
        assertTrue(
            ForkConfig.looksLikeRpcUrl("https://robinhood-mainnet.g.alchemy.com/v2/deadbeef"),
            unicode"带 key 的归档端点"
        );
        assertTrue(ForkConfig.looksLikeRpcUrl("http://127.0.0.1:8545"), unicode"本地 anvil");
        assertTrue(ForkConfig.looksLikeRpcUrl("wss://example.com/v2/key"), unicode"WebSocket");
    }

    /// @notice CI required 模式下，环境不可用必须让测试失败，不能再伪装成绿色 skip。
    function test_requiredModeFailsWhenEveryCandidateIsUnreachable() public {
        ForkTarget memory target = ForkConfig.robinhood();
        target.rpcUrls = new string[](1);
        target.rpcUrls[0] = UNREACHABLE;
        target.required = true;

        vm.expectRevert(
            abi.encodeWithSelector(
                RequiredForkUnavailable.selector,
                "Robinhood Chain",
                unicode"全部候选端点都连不上（无网络 / 被拦截 / 凭据无效）"
            )
        );
        this.selectForkInRequiredMode(target);
    }

    /// @dev 必须是 external，try/catch 才拦得住 —— internal 调用不是一次 call。
    function selectForkExpectingWrongChain(ForkTarget memory target) external {
        target.chainId = 1; // 以太坊主网，与端点实际所在的链不符
        selectFork(target);
    }

    function selectForkInRequiredMode(ForkTarget memory target) external {
        selectFork(target);
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        return _revertMentions(bytes(haystack), needle);
    }
}

/// @notice 不碰网络的端点选择回归网。
/// @dev 用 override 注入脚本化 fake backend；每条测试都由自己的 Forge 快照隔离状态。
contract ForkSelectionBackendTest is ForkTest {
    enum Scenario {
        None,
        FallbackToBLatest,
        StrictPinnedOnly,
        WrongChain
    }

    string internal constant A = "https://a.example";
    string internal constant B = "https://b.example";
    uint256 internal constant PINNED = 35_482_396;
    uint256 internal constant A_LATEST = 40_000_001;
    uint256 internal constant B_LATEST = 40_000_002;

    Scenario internal scenario;
    uint256 internal chainIdAttempts;
    uint256 internal pinnedStateAttempts;
    uint256 internal latestForkAttempts;
    uint256 internal latestStateAttempts;

    function test_firstReachableWithoutStateFallsThroughToBLatest() public {
        scenario = Scenario.FallbackToBLatest;

        string memory reason = _selectFork(_target(false));

        assertEq(reason, "", unicode"B latest 可用，不应返回跳过原因");
        assertEq(forkUrl, B, unicode"A 的 latest 状态失败后必须继续尝试 B");
        assertEq(forkHeight, 0, unicode"选中的是 B latest");
        assertEq(chainIdAttempts, 4, unicode"钉死高度与 latest 两轮都应该询问 A、B");
        assertEq(pinnedStateAttempts, 2, unicode"A、B 都应先探钉死高度");
        assertEq(latestForkAttempts, 2, unicode"A latest 给不了状态后还要建 B latest");
        assertEq(latestStateAttempts, 2, unicode"A、B 建 latest 后都必须探实际高度的状态");
    }

    function test_strictModeStopsBeforeLatestAndReturnsTheSkipReason() public {
        scenario = Scenario.StrictPinnedOnly;

        string memory reason = _selectFork(_target(true));

        assertEq(reason, unicode"没有端点能服务钉死的高度，且 FORK_STRICT_BLOCK=true");
        assertEq(latestForkAttempts, 0, unicode"严格模式绝不建 latest 分叉");
        assertEq(latestStateAttempts, 0, unicode"严格模式绝不探 latest 状态");
    }

    function test_wrongChainFailsInsteadOfTryingTheNextCandidate() public {
        scenario = Scenario.WrongChain;

        // A 报错链；B 被脚本为可成功。若错链被吞掉，这次调用会选中 B 并正常返回。
        try this.selectWrongChainTarget() {
            fail(unicode"错链必须立即失败，不能继续尝试 B");
        } catch (bytes memory reason) {
            assertTrue(
                _revertMentions(reason, unicode"指向了错误的链"), unicode"失败原因必须是链 ID 不符"
            );
        }
    }

    function selectWrongChainTarget() external {
        _selectFork(_target(true));
    }

    function _target(bool strictBlock) private pure returns (ForkTarget memory target) {
        target.name = "Robinhood Chain";
        target.chainId = ForkConfig.ROBINHOOD_CHAIN_ID;
        target.rpcUrls = new string[](2);
        target.rpcUrls[0] = A;
        target.rpcUrls[1] = B;
        target.blockNumber = PINNED;
        target.strictBlock = strictBlock;
        target.probe = ForkConfig.GME;
    }

    function _backendReachable(string memory url) internal override returns (bool) {
        chainIdAttempts++;
        return _is(url, A) || _is(url, B);
    }

    function _backendHasStateAt(string memory url, address, uint256 height) internal override returns (bool) {
        if (height == PINNED) {
            pinnedStateAttempts++;
            return scenario == Scenario.WrongChain;
        }

        latestStateAttempts++;
        return scenario == Scenario.FallbackToBLatest && _is(url, B) && height == B_LATEST;
    }

    function _backendCreateSelectFork(string memory url, uint256 height)
        internal
        override
        returns (bool, uint256, uint256)
    {
        if (height == 0) latestForkAttempts++;

        if (scenario == Scenario.FallbackToBLatest) {
            return (true, ForkConfig.ROBINHOOD_CHAIN_ID, _is(url, A) ? A_LATEST : B_LATEST);
        }
        if (scenario == Scenario.WrongChain) {
            return (true, _is(url, A) ? 1 : ForkConfig.ROBINHOOD_CHAIN_ID, PINNED);
        }
        return (false, 0, 0);
    }

    function _is(string memory left, string memory right) private pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
