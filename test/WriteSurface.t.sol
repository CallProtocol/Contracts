// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AbiEntry, WriteSurface} from "./helpers/WriteSurface.sol";

/// @dev 只为枚举而存在的样本：一个 `receive`、一个 `fallback`、一个普通可写函数、一个 view。
contract SurfaceSample {
    uint256 public counter;

    receive() external payable {
        counter++;
    }

    fallback() external {
        counter++;
    }

    function poke(uint256 by) external {
        counter += by;
    }
}

/// @dev 把断言放到一次 external 调用后面，好让「它应当失败」变成一条可断言的事实。
///      `vm.assert*` 失败时是 revert，只有跨调用边界才抓得住。
contract SurfaceProbe {
    function assertIsExactly(string memory artifactPath, string[] memory expected) external view {
        WriteSurface.assertIsExactly(artifactPath, expected);
    }
}

/// @notice {WriteSurface} 自己的契约。
///
/// 🔴 为什么给一个测试辅助库写测试：本项目「证明某个开关不存在」的断言全部经由它 ——
/// 不变量 5（清算池无管理员出口）、不变量 6（声明门不可锁死），以及金库那两条
/// 「没有权限函数」「没有用户提取出口」（`docs/flap-vault-spec-compliance.zh.md`）。
/// 它自己漏掉一类入口的话，上面每一条都会**继续变绿**，只是不再检查原来那件事。
///
/// 这里钉的正是最容易漏的那一类：`receive` / `fallback` 在 ABI 里不是 `"function"`，
/// 也**没有 `name` 字段**，照着普通函数的路子解析会当场读空。
contract WriteSurfaceTest is Test {
    string internal constant SAMPLE = "out/WriteSurface.t.sol/SurfaceSample.json";

    function test_enumeratesReceiveAndFallbackAlongsideOrdinaryFunctions() public view {
        string[] memory expected = new string[](3);
        expected[0] = "receive()";
        expected[1] = "fallback()";
        expected[2] = "poke(uint256)";

        WriteSurface.assertIsExactly(SAMPLE, expected);
    }

    /// @dev 反证一：漏掉 `receive()` 必须红。这是这套机制最要紧的一条 ——
    ///      「合约不该有 receive」以前靠一条特判，现在靠同一条集合相等。
    function test_undeclaredReceiveIsRejected() public {
        SurfaceProbe probe = new SurfaceProbe();

        string[] memory missingReceive = new string[](2);
        missingReceive[0] = "fallback()";
        missingReceive[1] = "poke(uint256)";

        vm.expectRevert();
        probe.assertIsExactly(SAMPLE, missingReceive);
    }

    /// @dev 反证二：多写一个不存在的入口也必须红（少掉的那个方向）。
    function test_vanishedEntryIsRejected() public {
        SurfaceProbe probe = new SurfaceProbe();

        string[] memory extra = new string[](4);
        extra[0] = "receive()";
        extra[1] = "fallback()";
        extra[2] = "poke(uint256)";
        extra[3] = "withdraw()";

        vm.expectRevert();
        probe.assertIsExactly(SAMPLE, extra);
    }

    /// @dev 全量枚举里 view 也在，而且读写属性分得清 —— 金库的 schema 交叉核对靠这个。
    function test_entriesCarryMutabilityForReadsAndWrites() public view {
        AbiEntry[] memory entries = WriteSurface.entries(SAMPLE);
        assertEq(entries.length, 4, unicode"receive + fallback + poke + counter");

        for (uint256 i = 0; i < entries.length; i++) {
            bytes32 name = keccak256(bytes(entries[i].name));
            bool readOnly = WriteSurface.isReadOnly(entries[i].mutability);

            if (name == keccak256("counter")) {
                assertTrue(readOnly, unicode"public 变量的 getter 是 view");
            } else {
                assertFalse(readOnly, string.concat(unicode"应当是可写入口：", entries[i].signature));
            }
        }
    }
}
