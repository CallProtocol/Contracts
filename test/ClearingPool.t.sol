// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {Warrant} from "../src/Warrant.sol";
import {IVaultRegistry} from "../src/interfaces/IVaultRegistry.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice 清算池的**形状**：四个真 `immutable`，以及**恰好六个**对外可写入口
///         （M1-3，#8；第四个 immutable 是 M2-5 / #37 接上的金库身份根）。
///
/// 业务逻辑各有各的文件：开系列与存入即铸（#9）在 `ClearingPoolMinting.t.sol`，
/// 行权（#10）在 `ClearingPoolExercise.t.sol`；结算与门控延期（#11）在
/// `ClearingPoolSettlement.t.sol`；池内滚存（#12）在 `ClearingPoolRoll.t.sol`。
contract ClearingPoolTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultRegistry internal vaults;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        vaults = factory.registry();
        pool = new ClearingPool(warrant, address(distributor), registry, vaults);
    }

    // ─────────────────────── 四个地址：写一次，永久生效 ───────────────────────

    function test_constructor_wiresFourImmutables() public view {
        assertEq(address(pool.warrant()), address(warrant), "warrant");
        assertEq(pool.distributor(), address(distributor), "distributor");
        assertEq(address(pool.attestations()), address(registry), "attestations");
        assertEq(address(pool.vaultRegistry()), address(vaults), "vaultRegistry");
    }

    /// @dev 传错只能重新部署一份池子 —— 而「重新部署」对一个托管着抵押品的合约来说是不存在的选项。
    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(Warrant(address(0)), address(distributor), registry, vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(warrant, address(0), registry, vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(warrant, address(distributor), AttestationRegistry(address(0)), vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(warrant, address(distributor), registry, IVaultRegistry(address(0)));
    }

    /// @dev 「不可更换」不是一句承诺，是**没有那个函数**：可更换 = 可被指向一个恒返回 false 的注册表
    ///      = 可冻结全部行权；身份根那一个更狠 —— 可更换 = 可被指向一份「谁都算合法金库」的名册
    ///      = 开系列那道门当场作废。下面这几个选择器是「如果真有后门，多半长这样」；
    ///      **证明**由 `test_writeSurface_isExactlySixFunctions` 给出。
    function test_noSetterForTheFourImmutables() public {
        string[8] memory backdoors = [
            "setWarrant(address)",
            "setDistributor(address)",
            "setAttestations(address)",
            "setAttestationRegistry(address)",
            "setVaultRegistry(address)",
            "setRegistry(address)",
            "upgradeTo(address)",
            "withdraw(address,uint256)"
        ];

        for (uint256 i = 0; i < backdoors.length; i++) {
            (bool ok,) = address(pool).call(abi.encodeWithSignature(backdoors[i], address(1), uint256(0)));
            assertFalse(ok, string.concat(unicode"意料之外地存在：", backdoors[i]));
        }

        assertEq(address(pool.warrant()), address(warrant), unicode"四个地址自始至终没被动过");
        assertEq(pool.distributor(), address(distributor));
        assertEq(address(pool.attestations()), address(registry));
        assertEq(address(pool.vaultRegistry()), address(vaults));
    }

    // ─────────────────── 对外可写函数集：恰好六个（不变量 5 的依据）───────────────────

    /// @dev 验收条款：**枚举对外可写函数集并断言只有预期的六个。**
    ///
    ///      「无 admin、无 pause、无 withdraw、无 upgrade」是这个项目唯一的信任基石，
    ///      而它是一句关于**不存在**的话 —— 挨个调一遍自己知道的函数证明不了它。
    ///      这里读的是编译产物的 ABI，全部入口一个不漏，包括 `receive` / `fallback`。
    ///
    ///      下界（这六个确实都在、签名一字不差）由 `ClearingPool is IClearingPool` 让编译器保证。
    function test_writeSurface_isExactlySixFunctions() public view {
        string[] memory expected = new string[](6);
        expected[0] = "openSeries(address,address,uint64,uint128)";
        expected[1] = "depositAndMint(uint256,address,uint256)";
        expected[2] = "exercise(uint256,uint256,address)";
        expected[3] = "pokeGating(address)";
        expected[4] = "settleExpired(uint256)";
        expected[5] = "rollExpired(uint256,uint256)";

        WriteSurface.assertIsExactly("out/ClearingPool.sol/ClearingPool.json", expected);
    }

    // ─────────────────── 六个入口全部有函数体，一个都不剩下签名 ───────────────────

    /// @dev M1-7（#12）之前这里钉的是「哪些入口还只有一句 `revert NotImplemented()`」——
    ///      那条清单随每张票缩短，本票把它缩到了空。
    ///
    ///      🔴 **缩到空之后，要钉的事情翻了个面**：六个入口每一个都必须因**业务**理由被拒。
    ///      少了这条，把任意一个函数体退回「尚未实现」不会让任何测试变红 ——
    ///      `test_writeSurface_isExactlySixFunctions` 照样数得出六个，因为它读的是签名，不是行为。
    ///
    ///      断言的是**精确的**错误数据，不是「反正失败了」：后者连「因为别的原因失败」
    ///      都算通过，而这里唯一要证明的就是失败的**理由**。
    function test_everyEntrypointIsLive() public {
        address self = address(this);

        // 开系列：零地址代币
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.openSeries, (address(0), address(0), uint64(1), uint128(1))),
            abi.encodeWithSelector(ClearingPool.ZeroToken.selector),
            "openSeries"
        );

        // 存入即铸 / 行权 / 结算 / 滚存：都停在「这个系列没人开过」
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.depositAndMint, (1, self, 1)),
            abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, uint256(1)),
            "depositAndMint"
        );
        // 🔴 `beneficiary` 取 `msg.sender` 本人，否则会先停在调用方白名单上 ——
        //    那条门在 `rollExpired` 之前就存在，用它当证据证明不了本票交付了什么。
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.exercise, (1, 1, self)),
            abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, uint256(1)),
            "exercise"
        );
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.settleExpired, (1)),
            abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, uint256(1)),
            "settleExpired"
        );
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.rollExpired, (1, 2)),
            abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, uint256(1)),
            "rollExpired"
        );

        // 门控观测：零地址
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.pokeGating, (address(0))),
            abi.encodeWithSelector(ClearingPool.ZeroToken.selector),
            "pokeGating"
        );
    }

    /// @dev 走低层 `call` 而不是 `vm.expectRevert`：要比对的是**整条** revert 数据（选择器 + 参数），
    ///      而不只是它失败了。
    function _assertRejectedWith(bytes memory callData, bytes memory expectedError, string memory what) private {
        (bool ok, bytes memory ret) = address(pool).call(callData);
        assertFalse(ok, string.concat(what, unicode"：该被拒却成功了"));
        assertEq(
            ret,
            expectedError,
            string.concat(what, unicode"：拒绝的理由不对（还停在「尚未实现」？）")
        );
    }

    /// @dev 池子不接收原生代币：没有 `receive`、没有 `payable` 入口。
    ///      抵押品是 ERC-20，收得下原生代币只会得到一笔谁也取不走的钱（无 admin、无 withdraw）。
    function test_poolRejectsNativeValue() public {
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, unicode"池子不该收得下原生代币");
        assertEq(address(pool).balance, 0);
    }
}
