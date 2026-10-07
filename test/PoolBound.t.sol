// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {PoolBound} from "../src/PoolBound.sol";
import {Call} from "../src/Call.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";

/// @notice The satellite contract.**One-time**External behaviour in the binding of slots: only the deploying, only once, and permanently locked after writing;
///         Unbound `pool == address(0)` and `onlyPool` All calls are denied.
///
/// The semantics are: M1-3 All the content -- it's wrong, all the tests of the later milestones are on the sand.
///
/// Two satellites shared {PoolBound} One of them is a reality, so every semantic is.**Run it on both contracts.**:
/// The benefits realized by the shared realization are only established when both sides are actually using it.
/// The four contracts that were deployed were real, and there was no double -- "real connections can't be bypassed" -- that was what it was about.
contract PoolBoundTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    /// @dev This test contract is the deployment of the four contracts and is therefore the only address that has the right to be bound.
    address internal deployer = address(this);
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SERIES = uint256(keccak256("series"));

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        pool = new ClearingPool(call, address(distributor), registry, new FactoryStub().registry());
        // CRITICAL I'm doing it.**No, no.**Yes. setUp The following test claims that the "pre-coup" is the same.
        //    The root of identity is only a construction parameter in this document, and none of the tests go to the door in the series.
    }

    //  Unbounded contracts are inert, not open.

    function test_unbound_poolIsZero() public view {
        assertEq(call.pool(), address(0), unicode"Call Unbound");
        assertEq(distributor.pool(), address(0), unicode"MerkleDistributor Unbound");
    }

    /// @dev Acceptance and acceptance clauses:**Unbound Call Go, go, go! `mint` Yes. revert.**
    ///      Unbound `onlyPool` It's a big rejection, so this door is right.**Every one of them.**Callers are closed...
    ///      The deploying, strangers, the pool that has not yet been tied up, and the zero address itself (see the next article), are no exception.
    function test_unbound_onlyPoolRejectsEveryone() public {
        address[3] memory callers = [deployer, stranger, address(pool)];

        for (uint256 i = 0; i < callers.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, callers[i]));
            vm.prank(callers[i]);
            call.mint(callers[i], SERIES, 1 ether);

            vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, callers[i]));
            vm.prank(callers[i]);
            call.burn(callers[i], SERIES, 1 ether);

            assertEq(call.balanceOf(callers[i], SERIES), 0, unicode"No permits were cast until the bond was tied.");
        }
    }

    /// @dev CRITICAL `address(0)` It's a "not tied up" sentry, and it's a possible presence. `msg.sender` The value of the position...
    ///      So "no one" and "the authorized one" are there. `msg.sender == pool` This ruling.**It was the same value.**.
    ///      The recipients are not zero.ERC-1155 The floor can't stop. The Council was actually cast.
    ///
    ///      This is not a "test for a scenario that cannot be created": it is a direct consequence of the sentry values sharing with authorized subjects, and it is a direct consequence of the fact that the government is not able to use the same value as the other members of the police force.
    ///      And... `onlyPool` It's the only permanent boundary in the system (satellite contracts are bound and never change).
    function test_unbound_zeroSenderIsRejectedToo() public {
        address recipient = makeAddr("recipient");

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, address(0)));
        vm.prank(address(0));
        call.mint(recipient, SERIES, 1 ether);

        assertEq(call.balanceOf(recipient, SERIES), 0, unicode"No valid address until it's tied.");
    }

    /// @dev Unbound Call Go, go, go! `mint` Yes. revert,Whatever. fuzz To who? **There's no gap in the address space.**.
    ///
    ///      I had it here for a while. `vm.assume(caller != address(0))`,The reason is, "Zero address is not possible on the chain.
    ///      `msg.sender`.That reason puts one in.**Assumptions about chains**It's not the nature of the contract, and it's not the nature of the cover.
    ///      cheatcode The eccentricity is that sentry values are collided with authorized subjects in the same extraction value (see previous test).
    ///      `onlyPool` The blogger says that the government is not a party to the law.assume No more. This one. fuzz The site is also covered by the address.
    function testFuzz_unbound_mintRevertsForAnyCaller(address caller, uint256 id, uint256 amount) public {
        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, caller));
        vm.prank(caller);
        call.mint(caller, id, amount);
    }

    //  Tie it this time.

    function test_setPool_bindsAndEmits() public {
        vm.expectEmit(true, false, false, false, address(call));
        emit PoolBound.Bound(address(pool));
        call.setPool(address(pool));

        vm.expectEmit(true, false, false, false, address(distributor));
        emit PoolBound.Bound(address(pool));
        distributor.setPool(address(pool));

        assertEq(call.pool(), address(pool), "Call.pool");
        assertEq(distributor.pool(), address(pool), "MerkleDistributor.pool");
    }

    function test_deployer_isWhoeverConstructedIt() public {
        assertEq(call.deployer(), deployer, "Call.deployer");
        assertEq(distributor.deployer(), deployer, "MerkleDistributor.deployer");

        // I'm not sure if you're going to be able to do this.`deployer` It's the moment it's tied up. `msg.sender`,Not anything else.
        vm.prank(stranger);
        Call other = new Call();
        assertEq(other.deployer(), stranger, unicode"Another deploymenter.");
    }

    //  Only deployers, and only once.

    /// @dev Robbing: Between the deployment of the satellite contract and the binding, anyone can see it empty.
    ///      Being tied to his own contract would be tantamount to an unlimited right to cast, so the restriction was not formalistic.
    function testFuzz_setPool_onlyDeployer(address caller) public {
        vm.assume(caller != deployer);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotDeployer.selector, caller));
        vm.prank(caller);
        call.setPool(address(pool));

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotDeployer.selector, caller));
        vm.prank(caller);
        distributor.setPool(address(pool));

        assertEq(call.pool(), address(0), unicode"No marks of a rejected tie.");
        assertEq(distributor.pool(), address(0), unicode"No marks of a rejected tie.");
    }

    /// @dev Acceptance and acceptance clauses:**Second Bed. revert.**
    ///      With one.**Different.**The only thing that can stop it is the "beltted" article. If you try the same address, you can try the same address.
    ///      One would be confused with the fact that it would only be rejected as "co-value-tagged."
    function test_setPool_isOneShot() public {
        _bindAll();

        PoolBound[2] memory satellites = [PoolBound(address(call)), PoolBound(address(distributor))];
        address other = address(new Call()); // Byte code, non-zero, and not current binding value

        for (uint256 i = 0; i < satellites.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(PoolBound.AlreadyBound.selector, address(pool)));
            satellites[i].setPool(other);

            // Not even "tighten the line" -- it's this slot that's locked, not a value.
            vm.expectRevert(abi.encodeWithSelector(PoolBound.AlreadyBound.selector, address(pool)));
            satellites[i].setPool(address(pool));

            assertEq(
                satellites[i].pool(), address(pool), unicode"The binding values were not altered by the two attempts."
            );
        }
    }

    /// @dev The binding leaves the deployment with only one identity: a regular caller. This is the drop point on the satellite side of the phrase "there is no manager in the pool."
    function testFuzz_setPool_lockedForever(address caller, address target, uint64 timeJump) public {
        _bindAll();
        vm.warp(block.timestamp + timeJump);

        vm.prank(caller);
        (bool ok,) = address(call).call(abi.encodeCall(PoolBound.setPool, (target)));

        assertFalse(ok, unicode"No caller can write this slot after binding.");
        assertEq(call.pool(), address(pool), unicode"The bound value remains unchanged");
    }

    //  Two wrong-laced shapes

    /// @dev The zero address is the "unbound" sentry.
    ///       But I'll let `pool != address(0)`  The verdict is false.
    function test_setPool_rejectsZero() public {
        vm.expectRevert(PoolBound.ZeroPool.selector);
        call.setPool(address(0));

        assertEq(call.pool(), address(0), unicode"Still can be tied again -- the lock was the one that made it.");
        call.setPool(address(pool));
        assertEq(call.pool(), address(pool), unicode"You can tie it again if you change the right.");
    }

    /// @dev Error Address (Present)EOA,Or an address that has not been deployed. The binding has only one chance, and this is not visible to the naked eye.
    function test_setPool_rejectsAddressWithoutCode() public {
        address eoa = makeAddr("someone's wallet");

        vm.expectRevert(abi.encodeWithSelector(PoolBound.PoolHasNoCode.selector, eoa));
        call.setPool(eoa);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.PoolHasNoCode.selector, eoa));
        distributor.setPool(eoa);
    }

    //  After the tie: only the pool is in charge.

    function test_bound_onlyPoolCanMintAndBurn() public {
        _bindAll();

        vm.prank(address(pool));
        call.mint(stranger, SERIES, 3 ether);
        assertEq(call.balanceOf(stranger, SERIES), 3 ether, unicode"The pool can be forged.");

        vm.prank(address(pool));
        call.burn(stranger, SERIES, 1 ether);
        assertEq(call.balanceOf(stranger, SERIES), 2 ether, unicode"The pool is sold.");

        // CRITICAL The holder cannot destroy it itself - the destruction of the license only occurs on the right path and is initiated by the pool.
        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, stranger));
        vm.prank(stranger);
        call.burn(stranger, SERIES, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(PoolBound.NotPool.selector, deployer));
        call.mint(deployer, SERIES, 1 ether);

        assertEq(call.balanceOf(stranger, SERIES), 2 ether, unicode"No trace of a call that has been denied.");
    }

    /// @dev Certificate**Transfer of complete freedom**:This is... Seaport The first step in the process is to create a "soldable" premise between users of restricted jurisdictions and the government.
    ///      The door to the statement of compliance is only there. `ClearingPool.exercise()` Go. Ties should not be hand-held to transfer door.
    function test_bound_transfersAreFree() public {
        _bindAll();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(address(pool));
        call.mint(alice, SERIES, 5 ether);

        vm.prank(alice);
        call.safeTransferFrom(alice, bob, SERIES, 5 ether, "");

        assertEq(call.balanceOf(bob, SERIES), 5 ether, unicode"No one's permission is required for the transfer.");
    }

    function _bindAll() private {
        call.setPool(address(pool));
        distributor.setPool(address(pool));
    }
}
