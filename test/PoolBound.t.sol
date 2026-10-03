// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {PoolBound} from "../src/PoolBound.sol";
import {Warrant} from "../src/Warrant.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";

/// @notice 卫星合约那个**一次性**绑定槽的对外行为：仅部署者、仅一次、写后永久锁死；
///         未绑定时 `pool == address(0)` 且 `onlyPool` 拒绝一切调用。
///
/// 这套语义是 M1-3 的全部内容 —— 它错了，后面所有里程碑的测试都建在沙上。
///
/// 两个卫星共用 {PoolBound} 的一份实现，所以每条语义都**在两个合约上各跑一遍**：
/// 共用实现的收益只有在两边都真的用着它的时候才成立。
/// 部署的是真实的四个合约，不用替身 —— 「真实接线无法被绕过」正是要证明的东西。
contract PoolBoundTest is Test {
    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    /// @dev 本测试合约就是四个合约的部署者，因此也是唯一有权绑定的地址。
    address internal deployer = address(this);
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SERIES = uint256(keccak256("series"));

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        warrant = new Warrant();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        pool = new ClearingPool(warrant, address(distributor), registry, new FactoryStub().registry());
        // 🔴 刻意**不**在 setUp 里绑定：下面一半的测试断言的正是「绑定之前」的样子。
        //    身份根在本文件里只是构造参数，没有任何一条测试走到开系列那道门。
    }

    // ───────────────────── 未绑定的合约是惰性的，不是敞开的 ─────────────────────

    function test_unbound_poolIsZero() public view {
        assertEq(warrant.pool(), address(0), unicode"Warrant 未绑定");
        assertEq(distributor.pool(), address(0), unicode"MerkleDistributor 未绑定");
    }

    /// @dev 验收条款：**未绑定的 Warrant 上 `mint` 必 revert。**
    ///      未绑定时 `onlyPool` 显式拒绝，所以这道门对**每一个**调用者都关着 ——
    ///      部署者、陌生人、尚未绑上去的池子，以及零地址本身（见下一条），一个都不例外。
    function test_unbound_onlyPoolRejectsEveryone() public {
        address[3] memory callers = [deployer, stranger, address(pool)];

        for (uint256 i = 0; i < callers.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, callers[i]));
            vm.prank(callers[i]);
            warrant.mint(callers[i], SERIES, 1 ether);

            vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, callers[i]));
            vm.prank(callers[i]);
            warrant.burn(callers[i], SERIES, 1 ether);

            assertEq(warrant.balanceOf(callers[i], SERIES), 0, unicode"未绑定期间没有任何权证被铸出来");
        }
    }

    /// @dev 🔴 `address(0)` 既是「尚未绑定」的哨兵值，又是一个可以出现在 `msg.sender` 位置的值 ——
    ///      于是「没有人」和「被授权的那一个」在 `msg.sender == pool` 这个判据下**撞成了同一个值**。
    ///      收款方非零时，ERC-1155 那层也拦不住，权证会真的被铸出来。
    ///
    ///      这不是「为一个造不出来的场景写测试」：它是哨兵值与授权主体共用一个取值的直接后果，
    ///      而 `onlyPool` 是这套系统里唯一一道永久性的边界（卫星合约绑定后再也改不了）。
    function test_unbound_zeroSenderIsRejectedToo() public {
        address recipient = makeAddr("recipient");

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, address(0)));
        vm.prank(address(0));
        warrant.mint(recipient, SERIES, 1 ether);

        assertEq(warrant.balanceOf(recipient, SERIES), 0, unicode"未绑定期间零地址也铸不出权证");
    }

    /// @dev 未绑定的 Warrant 上 `mint` 会 revert，无论 fuzz 到谁 —— **地址空间不留缺口**。
    ///
    ///      这里一度带着 `vm.assume(caller != address(0))`，理由是「零地址在链上不是一个可能的
    ///      `msg.sender`」。那个理由把一条**关于链的假设**当成了本合约的性质，而且它掩盖的不是
    ///      cheatcode 的怪癖，是哨兵值与授权主体撞成同一个取值（见上一条测试）。
    ///      `onlyPool` 改成显式拒绝未绑定之后，assume 不再需要，这条 fuzz 也随之覆盖全部地址。
    function testFuzz_unbound_mintRevertsForAnyCaller(address caller, uint256 id, uint256 amount) public {
        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, caller));
        vm.prank(caller);
        warrant.mint(caller, id, amount);
    }

    // ────────────────────────────── 绑定这一次 ──────────────────────────────

    function test_setPool_bindsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(warrant));
        emit PoolBound.Bound(address(pool));
        warrant.setPool(address(pool));

        vm.expectEmit(true, false, false, false, address(distributor));
        emit PoolBound.Bound(address(pool));
        distributor.setPool(address(pool));

        assertEq(warrant.pool(), address(pool), "Warrant.pool");
        assertEq(distributor.pool(), address(pool), "MerkleDistributor.pool");
    }

    function test_deployer_isWhoeverConstructedIt() public {
        assertEq(warrant.deployer(), deployer, "Warrant.deployer");
        assertEq(distributor.deployer(), deployer, "MerkleDistributor.deployer");

        // 换个人部署，`deployer` 就跟着换 —— 它绑的是构造那一刻的 `msg.sender`，不是别的什么
        vm.prank(stranger);
        Warrant other = new Warrant();
        assertEq(other.deployer(), stranger, unicode"另一个部署者");
    }

    // ─────────────────────── 只有部署者，且只有一次 ───────────────────────

    /// @dev 抢跑：卫星合约部署完到绑定完之间，任何人都能看到它还是空的。
    ///      抢先绑到自己的合约上就等于拿到无限铸造权，所以这道限制不是形式主义。
    function testFuzz_setPool_onlyDeployer(address caller) public {
        vm.assume(caller != deployer);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotDeployer.selector, caller));
        vm.prank(caller);
        warrant.setPool(address(pool));

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotDeployer.selector, caller));
        vm.prank(caller);
        distributor.setPool(address(pool));

        assertEq(warrant.pool(), address(0), unicode"被拒的绑定不得留下痕迹");
        assertEq(distributor.pool(), address(0), unicode"被拒的绑定不得留下痕迹");
    }

    /// @dev 验收条款：**第二次必 revert。**
    ///      用一个**不同**的合约地址去试 —— 只有「已绑定」这一条能挡住它。拿同一个地址试的话，
    ///      一个只会拒绝「绑成同一个值」的实现会蒙混过关。
    function test_setPool_isOneShot() public {
        _bindAll();

        PoolBound[2] memory satellites = [PoolBound(address(warrant)), PoolBound(address(distributor))];
        address other = address(new Warrant()); // 有字节码、非零、且不是当前绑定值

        for (uint256 i = 0; i < satellites.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(PoolBound.AlreadyBound.selector, address(pool)));
            satellites[i].setPool(other);

            // 连「原样再绑一次」也不行 —— 锁死的是这个槽，不是某一个值
            vm.expectRevert(abi.encodeWithSelector(PoolBound.AlreadyBound.selector, address(pool)));
            satellites[i].setPool(address(pool));

            assertEq(satellites[i].pool(), address(pool), unicode"绑定值没被那两次尝试改动");
        }
    }

    /// @dev 绑定后连部署者都只剩一个身份：普通调用者。这一条是「池子里没有管理员」那句话在卫星侧的落点。
    function testFuzz_setPool_lockedForever(address caller, address target, uint64 timeJump) public {
        _bindAll();
        vm.warp(block.timestamp + timeJump);

        vm.prank(caller);
        (bool ok,) = address(warrant).call(abi.encodeCall(PoolBound.setPool, (target)));

        assertFalse(ok, unicode"绑定之后没有任何调用者能再写这个槽");
        assertEq(warrant.pool(), address(pool), unicode"绑定值不变");
    }

    // ─────────────────────────── 两种绑错的形状 ───────────────────────────

    /// @dev 零地址是「未绑定」这个状态的哨兵值。写进去等于什么都没做，
    ///      却会让「`pool != address(0)` ⟹ 已锁死」这个判据失真。
    function test_setPool_rejectsZero() public {
        vm.expectRevert(PoolBound.ZeroPool.selector);
        warrant.setPool(address(0));

        assertEq(warrant.pool(), address(0), unicode"仍然可以再绑 —— 锁死的是成功的那一次");
        warrant.setPool(address(pool));
        assertEq(warrant.pool(), address(pool), unicode"改对了还能接着绑");
    }

    /// @dev 打错地址（EOA、或者一个还没部署的地址）。绑定只有一次机会，而这一类错拿肉眼看不出来。
    function test_setPool_rejectsAddressWithoutCode() public {
        address eoa = makeAddr("someone's wallet");

        vm.expectRevert(abi.encodeWithSelector(PoolBound.PoolHasNoCode.selector, eoa));
        warrant.setPool(eoa);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.PoolHasNoCode.selector, eoa));
        distributor.setPool(eoa);
    }

    // ──────────────────────── 绑定之后：只有池子说了算 ────────────────────────

    function test_bound_onlyPoolCanMintAndBurn() public {
        _bindAll();

        vm.prank(address(pool));
        warrant.mint(stranger, SERIES, 3 ether);
        assertEq(warrant.balanceOf(stranger, SERIES), 3 ether, unicode"池子铸得出来");

        vm.prank(address(pool));
        warrant.burn(stranger, SERIES, 1 ether);
        assertEq(warrant.balanceOf(stranger, SERIES), 2 ether, unicode"池子销得掉");

        // 🔴 持有人自己也不能销毁 —— 权证的销毁只发生在行权路径上，由池子发起
        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, stranger));
        vm.prank(stranger);
        warrant.burn(stranger, SERIES, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, deployer));
        warrant.mint(deployer, SERIES, 1 ether);

        assertEq(warrant.balanceOf(stranger, SERIES), 2 ether, unicode"被拒的调用不得留下痕迹");
    }

    /// @dev 权证**转让完全自由**：这是 Seaport 撮合与「受限辖区用户可以卖掉」的前提，
    ///      合规声明那道门只出现在 `ClearingPool.exercise()` 上。绑定不该顺手给转让加门。
    function test_bound_transfersAreFree() public {
        _bindAll();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(address(pool));
        warrant.mint(alice, SERIES, 5 ether);

        vm.prank(alice);
        warrant.safeTransferFrom(alice, bob, SERIES, 5 ether, "");

        assertEq(warrant.balanceOf(bob, SERIES), 5 ether, unicode"转让不需要任何人许可");
    }

    function _bindAll() private {
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));
    }
}
