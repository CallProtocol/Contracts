// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @dev 下面三个都是**依赖夹具**，不是我们自己合约的替身 ——
///      M1 的四个合约还不存在（本票不交付业务逻辑），这些只用来证明依赖装对了、能编译、能跑。
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

/// @dev SafeERC20 是给**合约**调用方用的，所以得从一个合约里调才算真的走过这条路径。
contract SafeERC20Caller {
    using SafeERC20 for IERC20;

    function payOut(IERC20 token, address to, uint256 amount) external {
        token.safeTransfer(to, amount);
    }
}

/// @notice 依赖冒烟：`forge test` 跑得起来，且 issue #6 点名的三块 OpenZeppelin
///         （ERC-1155 / SafeERC20 / MerkleProof）确实装好并可用。
///
/// 不需要网络。分叉冒烟在 `test/fork/` 下。
contract DependenciesTest is Test {
    function test_erc1155_mintsBurnsAndTransfers() public {
        ERC1155Fixture warrantLike = new ERC1155Fixture();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 id = uint256(keccak256("series"));

        warrantLike.mint(alice, id, 100);
        assertEq(warrantLike.balanceOf(alice, id), 100, "mint");

        vm.prank(alice);
        warrantLike.safeTransferFrom(alice, bob, id, 40, "");
        assertEq(warrantLike.balanceOf(alice, id), 60, unicode"转出方余额");
        assertEq(warrantLike.balanceOf(bob, id), 40, unicode"接收方余额");

        warrantLike.burn(bob, id, 40);
        assertEq(warrantLike.balanceOf(bob, id), 0, "burn");
    }

    function test_safeERC20_transfersFromAContract() public {
        SafeERC20Caller custodian = new SafeERC20Caller();
        ERC20Fixture token = new ERC20Fixture(address(custodian), 1000 ether);
        address beneficiary = makeAddr("beneficiary");

        custodian.payOut(IERC20(address(token)), beneficiary, 250 ether);

        assertEq(token.balanceOf(beneficiary), 250 ether, unicode"受益人到账");
        assertEq(token.balanceOf(address(custodian)), 750 ether, unicode"托管方余额");
    }

    /// @dev 这里只验证库本身可用。leaf 的具体编码（双哈希、`seriesId` 在里面）已由 #13 定案，
    ///      权威出处是 `MerkleDistributor.leafOf`，测试侧的独立实现在 `test/helpers/MerkleTree.sol`。
    function test_merkleProof_verifiesAndRejects() public pure {
        bytes32 leafA = keccak256(abi.encode(address(0xA11CE), uint256(1 ether)));
        bytes32 leafB = keccak256(abi.encode(address(0xB0B), uint256(2 ether)));
        bytes32 root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));

        bytes32[] memory proofOfA = new bytes32[](1);
        proofOfA[0] = leafB;
        assertTrue(MerkleProof.verify(proofOfA, root, leafA), unicode"合法 leaf 应当通过");

        bytes32 tampered = keccak256(abi.encode(address(0xA11CE), uint256(3 ether)));
        assertFalse(MerkleProof.verify(proofOfA, root, tampered), unicode"被篡改的 leaf 必须被拒");
    }
}
