// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @dev All three of them.**Dependency on the clamp**,Not our own contract double...
///      M1 The four contracts do not yet exist (not a promissory note delivered business logic), and are used only to prove reliance on correct, compiled and run.
contract ERC1155Fixture is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burn(from, id, amount);
    }
}

contract ERC20Fixture is ERC20 {
    constructor(address holder, uint256 supply) ERC20("Fixture", "FIX") {
        _mint(holder, supply);
    }
}

/// @dev SafeERC20 Here.**Contract**The caller, so it's a contract to get through this path.
contract SafeERC20Caller {
    using SafeERC20 for IERC20;

    function payOut(IERC20 token, address to, uint256 amount) external {
        token.safeTransfer(to, amount);
    }
}

/// @notice Reliance on smoke:`forge test` I can run up and... issue #6 Three rollers. OpenZeppelin
///         (ERC-1155 / SafeERC20 / MerkleProof)It's really loaded and available.
///
/// No network needed. The swipes smoked in `test/fork/` Down.
contract DependenciesTest is Test {
    function test_erc1155_mintsBurnsAndTransfers() public {
        ERC1155Fixture callLike = new ERC1155Fixture();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 id = uint256(keccak256("series"));

        callLike.mint(alice, id, 100);
        assertEq(callLike.balanceOf(alice, id), 100, "mint");

        vm.prank(alice);
        callLike.safeTransferFrom(alice, bob, id, 40, "");
        assertEq(callLike.balanceOf(alice, id), 60, unicode"Transferor balance");
        assertEq(callLike.balanceOf(bob, id), 40, unicode"Receiver balance");

        callLike.burn(bob, id, 40);
        assertEq(callLike.balanceOf(bob, id), 0, "burn");
    }

    function test_safeERC20_transfersFromAContract() public {
        SafeERC20Caller custodian = new SafeERC20Caller();
        ERC20Fixture token = new ERC20Fixture(address(custodian), 1000 ether);
        address beneficiary = makeAddr("beneficiary");

        custodian.payOut(IERC20(address(token)), beneficiary, 250 ether);

        assertEq(token.balanceOf(beneficiary), 250 ether, unicode"Beneficiary accounts");
        assertEq(token.balanceOf(address(custodian)), 750 ether, unicode"Host balance");
    }

    /// @dev Only the authentication library itself is available here.leaf The specific code (Turkish,`seriesId`  Inside  #13 The decision is made.
    ///      The authority is... `MerkleDistributor.leafOf`,The test side is independent. `test/helpers/MerkleTree.sol`.
    function test_merkleProof_verifiesAndRejects() public pure {
        bytes32 leafA = keccak256(abi.encode(address(0xA11CE), uint256(1 ether)));
        bytes32 leafB = keccak256(abi.encode(address(0xB0B), uint256(2 ether)));
        bytes32 root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));

        bytes32[] memory proofOfA = new bytes32[](1);
        proofOfA[0] = leafB;
        assertTrue(MerkleProof.verify(proofOfA, root, leafA), unicode"Legal leaf Should be adopted");

        bytes32 tampered = keccak256(abi.encode(address(0xA11CE), uint256(3 ether)));
        assertFalse(
            MerkleProof.verify(proofOfA, root, tampered), unicode"It's been tampered with. leaf It has to be rejected."
        );
    }
}
