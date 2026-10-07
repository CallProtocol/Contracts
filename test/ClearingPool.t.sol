// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";
import {Call} from "../src/Call.sol";
import {IVaultRegistry} from "../src/interfaces/IVaultRegistry.sol";
import {FactoryStub} from "./helpers/FactoryStub.sol";
import {WriteSurface} from "./helpers/WriteSurface.sol";

/// @notice The clearing pool.**Shape**:Four real. `immutable`,and**Six.**Externally Available
///         (M1-3,#8;Fourth immutable Yes. M2-5 / #37 The government has been working on the issue of the identity of the vault.
///
/// Business logic has separate documents: open series and deposit cast (in the form of a book)#9)Yes. `ClearingPoolMinting.t.sol`,
/// Right to exercise (art.#10)Yes. `ClearingPoolExercise.t.sol`;Settlement and extension of door control (#11)Yes.
/// `ClearingPoolSettlement.t.sol`;Pool Circulation (CyberCluster)#12)Yes. `ClearingPoolRoll.t.sol`.
contract ClearingPoolTest is Test {
    AttestationRegistry internal registry;
    Call internal call;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;

    FactoryStub internal factory;
    VaultRegistry internal vaults;

    function setUp() public {
        registry = new AttestationRegistry(makeAddr("publisher"), keccak256("TERMS v0"), keccak256("ATTESTATION v0"));
        call = new Call();
        distributor = new MerkleDistributor(makeAddr("publisher"));
        factory = new FactoryStub();
        vaults = factory.registry();
        pool = new ClearingPool(call, address(distributor), registry, vaults);
    }

    //  Four addresses: once, permanent effect

    function test_constructor_wiresFourImmutables() public view {
        assertEq(address(pool.call()), address(call), "call");
        assertEq(pool.distributor(), address(distributor), "distributor");
        assertEq(address(pool.attestations()), address(registry), "attestations");
        assertEq(address(pool.vaultRegistry()), address(vaults), "vaultRegistry");
    }

    /// @dev The error is only one pool that can be redeployed -- and "redeployment" is an option that does not exist for a contract that holds collateral.
    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(Call(address(0)), address(distributor), registry, vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(call, address(0), registry, vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(call, address(distributor), AttestationRegistry(address(0)), vaults);

        vm.expectRevert(ClearingPool.ZeroAddress.selector);
        new ClearingPool(call, address(distributor), registry, IVaultRegistry(address(0)));
    }

    /// @dev "No change." It's not a promise.**No, no, no, no, no, no.**:Replaceable = Could be pointed at a constant return false of the Republic of Korea
    ///      = Freedom of all rights; tougher identity - changeable = But it's pointed to a list of "everyone is a legal vault."
    ///      = The door open in the series is scrapped. The next few choices are "If there is a back door, it's more like this"
    ///      **Prove it.**By `test_writeSurface_isExactlySixFunctions` Give.
    function test_noSetterForTheFourImmutables() public {
        string[8] memory backdoors = [
            "setCall(address)",
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
            assertFalse(ok, string.concat(unicode"Unexpectedly:", backdoors[i]));
        }

        assertEq(address(pool.call()), address(call), unicode"Four addresses never pass through.");
        assertEq(pool.distributor(), address(distributor));
        assertEq(address(pool.attestations()), address(registry));
        assertEq(address(pool.vaultRegistry()), address(vaults));
    }

    //  Externally writeable set: Exactly six (no variable) 5 (b) The right to life

    /// @dev Acceptance and acceptance clauses:**The list of external writingable functions is available and only six are asserted.**
    ///
    ///      None admin,None pause,None withdraw,None upgradeThe project is the only trust building block.
    ///      And it's about...**Cannot initialise Evolution's mail component.**And then -- one by one, the functions that you know cannot prove it.
    ///      It's a translation. ABI,All entrances are open, including `receive` / `fallback`.
    ///
    ///      Downwards. `ClearingPool is IClearingPool` Let the compiler promise.
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

    //  All six entry points have functions, and none of them have any signatures left.

    /// @dev M1-7(#12)The one thing that was nailed here was, "What entrances are there?" `revert NotImplemented()` -  -
    ///      The list was shortened with each ticket, and the promissory note had reduced it to nothing.
    ///
    ///      CRITICAL **When it got empty, the nails turned upside down.**:Every single entry point in the six entrances must be responsible for the**Operations**Reasons rejected.
    ///      Without this, returning any function "unrealized" will not make any test red --
    ///      `test_writeSurface_isExactlySixFunctions` The same number of cases is six, because it reads the signature, not the act.
    ///
    ///      The assertion is...**Exact**The wrong data, not "failed," "for other reasons."
    ///      It's all passed, and the only thing to prove here is failure.**Rationale**.
    function test_everyEntrypointIsLive() public {
        address self = address(this);

        // Series: zero address tokens
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.openSeries, (address(0), address(0), uint64(1), uint128(1))),
            abi.encodeWithSelector(ClearingPool.ZeroToken.selector),
            "openSeries"
        );

        //  And you're gonna be  / Right to exercise authority / Settlement / Rolling: They're all on "No one's ever opened this series."
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.depositAndMint, (1, self, 1)),
            abi.encodeWithSelector(ClearingPool.SeriesNotOpen.selector, uint256(1)),
            "depositAndMint"
        );
        // CRITICAL `beneficiary` Remove `msg.sender` Me, or I'll park on the caller's white list first...
        //    That door is... `rollExpired` It existed before, and it was used as evidence that nothing had been delivered.
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

        // Gate control observation: zero address
        _assertRejectedWith(
            abi.encodeCall(ClearingPool.pokeGating, (address(0))),
            abi.encodeWithSelector(ClearingPool.ZeroToken.selector),
            "pokeGating"
        );
    }

    /// @dev Go low. `call` Not `vm.expectRevert`:That's right.**The whole article** revert Data (Selections) + (Aggregations),
    ///      And not just that it failed.
    function _assertRejectedWith(bytes memory callData, bytes memory expectedError, string memory what) private {
        (bool ok, bytes memory ret) = address(pool).call(callData);
        assertFalse(ok, string.concat(what, unicode":It's time to be rejected and it works."));
        assertEq(
            ret, expectedError, string.concat(what, unicode":Wrong reason for refusing (still \"not yet achieved\"?")
        );
    }

    /// @dev The pool doesn't receive original coins: no. `receive`,No, I'm not. `payable` The entrance.
    ///      The collateral is... ERC-20,You can only get a dollar in your original currency, and no one can take it away. admin,None withdraw).
    function test_poolRejectsNativeValue() public {
        vm.deal(address(this), 1 ether);

        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertFalse(ok, unicode"I shouldn't have taken the original coin.");
        assertEq(address(pool).balance, 0);
    }
}
