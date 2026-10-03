// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title Bytecode
/// @notice 在**已部署的 runtime 字节码**上断言某个操作码不出现。
///
/// # 为什么 ABI 枚举不够
///
/// `test/helpers/WriteSurface.sol` 证明的是「没有第 N+1 个对外可写函数」。那一条挡不住
/// **代理**：beacon proxy 的 ABI 里同样没有 `upgradeTo` —— 它的实现地址是**从 beacon 读来的**，
/// 换实现根本不需要在自己身上暴露任何函数。
///
/// 🔴 而这正是 issue #23 判据 3 里「含 Flap Guardian」那半句要挡的东西：Guardian 的权力
/// 来自 beacon 升级，不是来自调用某个函数。要证明「Guardian 也改不了这份绑定」，
/// 必须证明这份合约**根本不会执行别处的代码** —— 也就是它的 runtime 里没有 `DELEGATECALL`。
///
/// # 两遍扫描，强的那遍先跑
///
/// | 遍 | 判据 | 强度 |
/// |---|---|---|
/// | 朴素 | 整段字节里**一个** `0xf4` 都没有 | 无条件成立，不依赖任何解析假设 |
/// | PUSH 感知 | 跳过 `PUSH1..PUSH32` 的立即数后不出现 | 需要「线性布局」这个假设 |
///
/// 朴素那遍过了就到此为止 —— 它不可能有假阴性。只有当某个 `0xf4` 落在立即数里（编译器把它
/// 塞进了某个常量）时才轮到第二遍，那时报告里会写清「靠的是 PUSH 感知扫描」，
/// 因为它的结论强度确实低一档。
///
/// @dev 只对**小合约**用这套。大合约里 `0xf4` 出现在常量里几乎是必然的，那时第一遍必然落空，
///      结论强度也就随之降级 —— 那种场合应当换用别的论证，而不是把这里的假设当成没有。
library Bytecode {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 internal constant DELEGATECALL = 0xf4;
    uint8 internal constant CALLCODE = 0xf2;
    uint8 internal constant SELFDESTRUCT = 0xff;

    /// @notice 断言 `target` 的 runtime 字节码里不存在 `opcode`。返回用的是哪一遍扫描。
    ///
    /// @param target  已部署的合约
    /// @param opcode  被禁的操作码
    /// @param name    人类可读的名字，只进报错与返回的说明里
    ///
    /// @return note 说明文字，形如 `DELEGATECALL：整段 1234 字节里一个 0xf4 都没有`。
    ///              测试把它 `console2.log` 出来 —— 结论**强度**必须留在证据里，
    ///              不能让「绿了」把两遍扫描抹平成同一件事。
    function assertNoOpcode(address target, uint8 opcode, string memory name)
        internal
        view
        returns (string memory note)
    {
        bytes memory code = target.code;
        vm.assertGt(code.length, 0, string.concat(unicode"没有字节码可扫描：", vm.toString(target)));

        if (!_containsByte(code, opcode)) {
            return string.concat(
                name,
                unicode"：整段 ",
                vm.toString(code.length),
                unicode" 字节里一个 0x",
                _hex(opcode),
                unicode" 都没有"
            );
        }

        // 落到这里说明某处**字节**上有它。逐条走一遍，把立即数排除掉。
        uint256 i;
        while (i < code.length) {
            uint8 b = uint8(code[i]);

            if (b >= 0x60 && b <= 0x7f) {
                i += 1 + (uint256(b) - 0x5f); // PUSH1..PUSH32：跳过立即数
                continue;
            }

            vm.assertTrue(
                b != opcode,
                string.concat(
                    unicode"字节码第 ",
                    vm.toString(i),
                    unicode" 位是 ",
                    name,
                    unicode" —— 它可以执行别处的代码"
                )
            );
            i++;
        }

        return string.concat(
            name,
            unicode"：字节里出现过 0x",
            _hex(opcode),
            unicode"，但全部落在 PUSH 立即数中（结论依赖线性布局假设，强度低一档）"
        );
    }

    function _containsByte(bytes memory code, uint8 b) private pure returns (bool) {
        for (uint256 i = 0; i < code.length; i++) {
            if (uint8(code[i]) == b) return true;
        }
        return false;
    }

    function _hex(uint8 b) private pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory out = new bytes(2);
        out[0] = alphabet[b >> 4];
        out[1] = alphabet[b & 0x0f];
        return string(out);
    }
}
