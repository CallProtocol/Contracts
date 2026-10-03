// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ForkTarget} from "./ForkConfig.sol";

error RequiredForkUnavailable(string name, string reason);

/// @title ForkTest
/// @notice 分叉测试基类。
///
/// 唯一职责：**把「环境不具备」和「断言不成立」分开。**
/// 没网、没凭据、端点不给历史状态 —— 本地默认 `vm.skip`，CI required 模式明确失败；
/// 端点指错链、链上事实与断言不符 —— 一律失败。
///
/// 用法：在 `setUp()` 里调 `selectFork(...)`，跳过会作用于该合约的全部测试。
abstract contract ForkTest is Test {
    /// @notice 实际选中的端点的安全显示形式。未选中任何端点时为空串。
    ///         供测试断言「选中了哪个 host」，且即使断言失败也不泄露 path / query 中的凭据。
    string internal forkUrl;

    /// @notice 实际分叉到的高度。`0` 表示退回了 latest —— 即本次运行不可复现。
    uint256 internal forkHeight;

    /// @notice 建立并选中 `target` 描述的分叉；环境不可用时按 target 配置跳过或失败。
    ///
    /// 两轮遍历，**每一轮都把候选表走完**：
    ///   1. 按优先级找能服务钉死高度的端点 —— 可复现优先于连得上；
    ///   2. 都不行且非严格模式时，再按同样的优先级找能服务 latest 的端点。
    ///
    /// 🔴 两轮都必须遍历**全部**候选。早期版本只记住「第一个能响应 eth_chainId 的端点」
    /// 并拿它去跑第 2 轮，于是「首端点能报 chainId、但状态请求被限流」时会直接跳过，
    /// 后面明明可用的端点一个都轮不到 —— 静默丢掉整条分叉冒烟的覆盖。
    ///
    /// ⚠️ **只能在 `setUp()` 或测试函数里直接调用。** 本函数在环境不具备时走 `vm.skip`，
    /// 而 `vm.skip` 只在 test level 生效 —— 从嵌套的 external 调用里调它，跳过会变成一条
    /// `skip can only be used at test level` 的 revert。真要在嵌套调用里驱动它（例如为了
    /// 用 try/catch 断言失败），调用方必须自己先在顶层验好前置条件。
    function selectFork(ForkTarget memory target) internal {
        string memory unavailableReason = _selectFork(target);
        if (bytes(unavailableReason).length != 0) _skip(target, unavailableReason);
    }

    /// @dev 只执行选择策略；环境不可用时返回原因，不在这一层调 `vm.skip`。
    ///      测试因此能注入 fake backend，断言调用顺序和严格模式的停止位置。
    function _selectFork(ForkTarget memory target) internal returns (string memory) {
        if (target.rpcUrls.length == 0) {
            return unicode"未配置 RPC 端点";
        }

        bool anyReachable;

        // ── 第 1 轮：钉死高度 ────────────────────────────────────────────
        if (target.blockNumber != 0) {
            for (uint256 i = 0; i < target.rpcUrls.length; i++) {
                string memory url = target.rpcUrls[i];
                if (!_reachable(url)) continue;
                anyReachable = true;
                if (!_hasStateAt(url, target.probe, target.blockNumber)) continue;
                if (_tryFork(target, url, target.blockNumber)) return "";
            }

            if (!anyReachable) {
                return unicode"全部候选端点都连不上（无网络 / 被拦截 / 凭据无效）";
            }
            if (target.strictBlock) {
                return unicode"没有端点能服务钉死的高度，且 FORK_STRICT_BLOCK=true";
            }
            console2.log(
                string.concat(
                    unicode"[fork:",
                    target.name,
                    unicode"] ⚠️ 没有端点能服务高度 ",
                    vm.toString(target.blockNumber),
                    unicode"，退回 latest —— 本次运行不可复现"
                )
            );
        }

        // ── 第 2 轮：latest，同样按优先级把候选走完 ──────────────────────
        for (uint256 i = 0; i < target.rpcUrls.length; i++) {
            string memory url = target.rpcUrls[i];
            if (!_reachable(url)) continue;
            anyReachable = true;
            if (_tryFork(target, url, 0)) return "";
        }

        return anyReachable
            ? unicode"候选端点都能给区块头但给不了状态（非归档节点 / 状态请求被限流）"
            : unicode"全部候选端点都连不上（无网络 / 被拦截 / 凭据无效）";
    }

    /// @dev 尝试用 `url` 在 `height`（`0` 表示 latest）上建立分叉。
    ///      **环境原因**失败时返回 `false` 让调用方接着试下一个候选；
    ///      🔴 链 ID 不符是**配置错误**，在这里直接断言失败，绝不吞成「换下一个」。
    function _tryFork(ForkTarget memory target, string memory url, uint256 height) private returns (bool) {
        (bool created, uint256 chainId, uint256 actualHeight) = _backendCreateSelectFork(url, height);
        if (!created) return false;

        // forge 总会把分叉钉在一个**具体**高度上（即便传的是 latest）。端点若只发区块头
        // 不发该高度的状态，故障会推迟到测试中途的第一次 storage 读取才炸 —— 那时它表现为
        // 失败，不是跳过。在这里提前把它转成「换下一个候选」。
        if (!_hasStateAt(url, target.probe, actualHeight)) return false;

        assertEq(chainId, target.chainId, _wrongChainMessage(target, url));

        forkUrl = _safeUrl(url);
        forkHeight = height;

        console2.log(
            string.concat(
                "[fork:",
                target.name,
                "] chainId=",
                vm.toString(chainId),
                " block=",
                vm.toString(actualHeight),
                // 报的是**实际**取到的模式，不是配置里写的那个 —— 退回 latest 之后
                // 还打印 "pinned" 会把不可复现的运行伪装成可复现的。
                height == 0 ? unicode" (latest —— 不可复现)" : " (pinned)",
                " via ",
                _safeUrl(url)
            )
        );
        return true;
    }

    function _skip(ForkTarget memory target, string memory reason) private {
        if (target.required) revert RequiredForkUnavailable(target.name, reason);
        vm.skip(true, string.concat("[fork:", target.name, "] ", reason));
    }

    /// @dev 链 ID 配错时，这条断言的消息会被 forge 打进日志；绝不能带出 URL path 中的 key。
    function _wrongChainMessage(ForkTarget memory target, string memory url) internal pure returns (string memory) {
        return string.concat("[fork:", target.name, "] ", _safeUrl(url), unicode" 指向了错误的链");
    }

    /// @notice 日志里安全的端点写法：只留 scheme + host，路径、query、fragment 一律折叠成 `/…`。
    ///
    /// @dev 🔴 **带 key 的端点一旦原样打进日志，每跑一次分叉测试就把凭据往日志里写一次。**
    ///      归档端点现在实质上必须自带 key（`https://…/v2/<KEY>` 这种形状，见 {ForkConfig}），
    ///      而这行日志每次 `selectFork` 成功都会打。GitHub Actions 会给注册过的 secret 打码，
    ///      **但本地不会** —— 而「贴一段日志求助」正是最常见的泄露路径。
    ///
    ///      免 key 的端点没有路径部分，输出与从前一字不差，所以这不是一次日志格式变更。
    ///      `forkUrl` 也只保存本函数的返回值，避免测试断言失败时把单个列表成员写进日志。
    function _safeUrl(string memory url) internal pure returns (string memory) {
        bytes memory b = bytes(url);
        uint256 authorityStart;

        // URLs accepted by ForkConfig have `://`; find the first byte of their authority.
        for (uint256 i = 0; i + 2 < b.length; i++) {
            if (b[i] == 0x3a && b[i + 1] == 0x2f && b[i + 2] == 0x2f) {
                authorityStart = i + 3;
                break;
            }
        }

        if (authorityStart == 0) return url;

        uint256 authorityEnd = b.length;
        uint256 hostStart = authorityStart;
        for (uint256 i = authorityStart; i < b.length; i++) {
            if (b[i] == 0x40) hostStart = i + 1; // Drop URL userinfo too: it may be credentials.
            if (b[i] == 0x2f || b[i] == 0x3f || b[i] == 0x23) {
                authorityEnd = i;
                break;
            }
        }

        // No sensitive suffix or userinfo: preserve the historic display exactly.
        if (authorityEnd == b.length && hostStart == authorityStart) return url;

        bytes memory safe = new bytes(authorityStart + authorityEnd - hostStart);
        for (uint256 i = 0; i < authorityStart; i++) {
            safe[i] = b[i];
        }
        for (uint256 i = hostStart; i < authorityEnd; i++) {
            safe[authorityStart + i - hostStart] = b[i];
        }
        return string(abi.encodePacked(safe, unicode"/…"));
    }

    /// @dev 端点是否可达。只看调用成没成，不解析返回值。
    ///      子类用它做前置条件判定（环境不满足时跳过，而不是让断言红掉）。
    function _reachable(string memory url) internal returns (bool) {
        return _backendReachable(url);
    }

    function _backendReachable(string memory url) internal virtual returns (bool) {
        try vm.rpc(url, "eth_chainId", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev 端点能否服务 `height` 高度上的**状态**。
    ///
    /// 分叉后端要读 storage 也要读账户，而公共端点常常按方法分别限流
    /// （实测见过同一高度放行 `eth_call`、却把 `eth_getBalance` 判为归档请求的端点），
    /// 所以两者都探，任一失败即判定为不可用。
    function _hasStateAt(string memory url, address probe, uint256 height) internal returns (bool) {
        return _backendHasStateAt(url, probe, height);
    }

    function _backendHasStateAt(string memory url, address probe, uint256 height) internal virtual returns (bool) {
        string memory addr = vm.toString(probe);
        string memory blockTag = _hexQuantity(height);

        try vm.rpc(url, "eth_getStorageAt", string.concat('["', addr, '","0x0","', blockTag, '"]')) returns (
            bytes memory
        ) {}
        catch {
            return false;
        }

        try vm.rpc(url, "eth_getBalance", string.concat('["', addr, '","', blockTag, '"]')) returns (bytes memory) {}
        catch {
            return false;
        }

        return true;
    }

    /// @dev 默认 backend 使用 Foundry 建叉；fake 只需 override 这三个 `_backend*` 钩子。
    function _backendCreateSelectFork(string memory url, uint256 height)
        internal
        virtual
        returns (bool created, uint256 chainId, uint256 actualHeight)
    {
        if (height == 0) {
            try vm.createSelectFork(url) returns (uint256) {}
            catch {
                return (false, 0, 0);
            }
        } else {
            try vm.createSelectFork(url, height) returns (uint256) {}
            catch {
                return (false, 0, 0);
            }
        }
        return (true, block.chainid, block.number);
    }

    /// @dev revert 数据里是否出现过 `needle`。Foundry 断言使用带 selector 的自定义错误，
    ///      所以选择策略测试在整段 ABI 编码里找消息，不把任意 revert 当成成功。
    function _revertMentions(bytes memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        if (n.length == 0 || haystack.length < n.length) return false;
        for (uint256 i = 0; i <= haystack.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (haystack[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /// @dev JSON-RPC 的 QUANTITY 编码：`0x` 前缀、无前导零。补零的写法会被部分节点拒收。
    function _hexQuantity(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0x0";

        bytes16 alphabet = "0123456789abcdef";
        bytes memory digits = new bytes(64);
        uint256 start = 64;
        while (value != 0) {
            start--;
            digits[start] = alphabet[value & 0xf];
            value >>= 4;
        }

        bytes memory out = new bytes(66 - start);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = start; i < 64; i++) {
            out[2 + i - start] = digits[i];
        }
        return string(out);
    }
}
