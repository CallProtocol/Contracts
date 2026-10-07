// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MemeToken} from "../helpers/MemeToken.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

interface IFlapTaxTokenV3 {
    function buyTaxRate() external view returns (uint256);
    function sellTaxRate() external view returns (uint256);
    function quoteToken() external view returns (address);
    function taxProcessor() external view returns (address);
    function owner() external view returns (address);
}

/// @notice **Review of destruction pathways:`transferFrom(user, 0xdead, X)` It has to be exactly the same as the collection. X.**
///
/// `ClearingPool.exercise` No. No. 2 The beneficiaries. MEME Transfer `0xdead`.Two facts on this path.
/// It's a shape that determines what's going on. Both of them are real.`docs/research/flap-tax-and-burn-path.md`):
///
/// - **No original. `burn()` / `burnFrom()`**  `transferFrom -> 0xdead` (a) The only available destruction path;
/// - **Transfer `0x0` Yes. revert**  The destruction address must be `0xdead`.
///
/// CRITICAL I'm a pool.**Do not check** `0xdead` The increase in the balance -- the reason for the trade-off is just that it's not the only reason that you're not gonna get it. `src/ClearingPool.sol` It's...
/// `exercise` Go, go, go. It's just taken.**Consequences**:"It's true that there's so much burning."**There's no contract.
/// Guard, this is the only file.**.It reviews the current behaviour of the external contract, so it is all worth "when and when you have to know it."
///
/// # WARNING A still open mouth: positive contrasts not on the target chain.
///
/// `flap-tax-and-burn-path.md` 5 Remember the pits the author stepped on himself:**Just observe the tax-free samples and you'll get it steady.
/// No taxes."** In history BSC I got a positive sample against it.MarsCoin The official pool is a reality. 3.00%),But... Robinhood Chain Go, go, go!
/// I can't get it -- there's no one in this chain who's graduated and has his own registered deal. Flap Currency (in US$)issue #5 It's... Further Notes
/// Remember this. residual gap,I tried. 7 The goal is zero tax.
///
/// So, use it down there. `test_theMeasurementItselfDetectsTax` Top: Take it.**Same measurement function**Go measure a local one.
/// 3% Tax tokens. It proves that "this set of measurements captures taxes."**No, it's not.**Flap The tax collection branch was validated on the target chain."
/// The latter is still on, all right. issue #5 Close. This difference must be written here, not by a permanent green test pretending it's closed.
contract RobinhoodFlapBurnForkTest is ForkTest {
    /// @dev Robinhood Chain Top `FlapTaxTokenV3` Achieved. The chain's on. Flap All the tokens are to it. EIP-1167 The smallest agent,
    ///      And history BSC Samples achieved `0x024f1829...` It's... 46 individual selector Fully consistent; the comparison does not constitute v1 It's... BSC Dependence.
    address internal constant FLAP_TAX_TOKEN_V3_IMPL = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;

    /// @dev Sample tokens and Flap Portal.CRITICAL **Do not write address volumes here**  -  -  They're defined as {ForkConfig},
    ///      Only aliases here.PR #29 Review P2:The four fork tests were each written at the same address.
    ///      Tax rate 300/300,The total supply is still of the same nature as the conic curve. {ForkConfig} .
    address internal constant MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev and `src/ClearingPool.sol` constant**Independence**Write dead.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant AMOUNT = 1 ether;

    IERC20 internal meme;

    function setUp() public {
        // The sample was read when you were detecting the "state of the altitude". MEME Not GME  -  -  The probes are on a contract that will really be read.
        ForkTarget memory target = ForkConfig.robinhood();
        target.probe = MEME;
        selectFork(target);

        meme = IERC20(MEME);
    }

    /// @dev One with a call. `transferFrom`,Return to Target**Actual receipt**Number.
    ///      The difference between nominal and actual collection is tax -- that's exactly what it is. 2 The probes do that thing on the chain.
    function _receivedBy(IERC20 token, address holder, address to, uint256 amount) internal returns (uint256) {
        uint256 before = token.balanceOf(to);
        vm.prank(holder);
        token.approve(address(this), amount);
        token.transferFrom(holder, to, amount);
        return token.balanceOf(to) - before;
    }

    //  Precondition: The measure is indeed the one that made it happen.

    /// @dev - I'll prove it before I say anything.**It's a real contract.**.Byte code length recognizes both proxy and realization -
    ///      Flap This is the red one when it comes to implementation, and that is why this document exists.
    function test_theSampleIsTheRealFlapTaxToken() public view {
        assertEq(MEME.code.length, 45, unicode"The sample token should be EIP-1167 Mint Agent");
        assertEq(FLAP_TAX_TOKEN_V3_IMPL.code.length, 19_020, unicode"Bytes of contract length achieved");
        assertEq(IFlapTaxTokenV3(MEME).buyTaxRate(), 300, "buyTaxRate()");
        assertEq(IFlapTaxTokenV3(MEME).sellTaxRate(), 300, "sellTaxRate()");
        assertGt(meme.balanceOf(PORTAL), 0, unicode"The conic should hold the balance");

        console2.log(
            string.concat(
                "  impl=",
                vm.toString(FLAP_TAX_TOKEN_V3_IMPL),
                " taxProcessor=",
                vm.toString(IFlapTaxTokenV3(MEME).taxProcessor()),
                " owner=",
                vm.toString(IFlapTaxTokenV3(MEME).owner())
            )
        );
    }

    //  Core assertion

    /// @notice CRITICAL **Acceptance and acceptance clauses:`transferFrom(user, 0xdead, X)` The exact exact exact same as the exact receipt. X.**
    ///
    /// @dev When this one doesn't work, the user pays the whole thing. `memeAmount`,The only thing that could be burned -- the pool is invisible.
    ///      Because it doesn't check the increment. `exercise`).So it's gonna be...**Silence**I'm sorry.
    ///      Only this test will shout.
    function test_burnPathDeliversExactlyTheFullAmount() public {
        uint256 received = _receivedBy(meme, PORTAL, BURN_ADDRESS, AMOUNT);

        assertEq(received, AMOUNT, unicode"0xdead The collection must be exactly the same as the transfer.");

        console2.log(
            string.concat(
                unicode"  -> 0xdead  Transfer ", vm.toString(AMOUNT), unicode"  Received ", vm.toString(received)
            )
        );
    }

    /// @notice Control group: Transfer to stranger EOA And no taxes -- no zero taxes. `0xdead` - The special treatment.
    function test_plainTransferToAFreshEoaIsUntaxed() public {
        assertEq(_receivedBy(meme, PORTAL, makeAddr("stranger"), AMOUNT), AMOUNT, unicode"Strange. EOA Received");
    }

    /// @notice CRITICAL **The Methodist Guard.**:Prove this set of measurements.**I'll get the tax.**.
    ///
    /// @dev The goal of tax-freeness is to produce a "no tax" that is stable.`flap-tax-and-burn-path.md` 5 I remember.
    ///      The author stepped on this pit. Real positive control requires one.**The tax collection branch is active. Flap Currency**,
    ///      And... Robinhood Chain Not at the moment (see headline and headline of this contract) issue #5).
    ///
    ///      So here's a step back, just to prove it.**Measuring Functions per se**Not always back to full: the same. `_receivedBy`
    ///      Take one of them local. 3% Tax tokens. They have to be measured. 3%.
    ///      WARNING It's...**No, no.**The positive contrast on the alternative target chain is still on.
    function test_theMeasurementItselfDetectsTax() public {
        MemeToken taxed = new MemeToken();
        taxed.setTaxBps(300);
        address holder = makeAddr("taxed holder");
        taxed.mint(holder, AMOUNT);

        uint256 received = _receivedBy(IERC20(address(taxed)), holder, makeAddr("taxed recipient"), AMOUNT);

        assertLt(received, AMOUNT, unicode"No taxes on the number of measurements.  The zero tax conclusion is empty.");
        assertEq(received, AMOUNT - (AMOUNT * 300) / 10_000, unicode"And that's what I measured. 3%");
    }

    //  Why can't we just destroy the address? 0xdead

    /// @notice Transfer `0x0` I have to. revert  -  -  Specification Selection `0xdead` Not `0x0` It's...**All**Basis.
    ///
    /// @dev CRITICAL Break Specific revert Data, not empty. `vm.expectRevert()`.The whole point of this test is failure.
    ///      **Reason**,The empty assertion is considered to have been adopted even if it failed for other reasons - for example, the authorization was not set, and the authorities were not authorized to do so.
    ///      It was green, but it proved nothing. `ClearingPoolMinting.t.sol` The rules.
    ///
    ///      This string is...**Actual**It's not from... BSC The research notes are taken from:Robinhood Up the byte code and
    ///      BSC That one's different.19,020 vs 19,331),So, "It's old-fashioned, too. require The string's got to measure this thing.
    ///      Recalculate:`cast call <MEME> "transfer(address,uint256)" 0x0 1e18 --from <PORTAL>`.
    function test_transferToTheZeroAddressReverts() public {
        vm.prank(PORTAL);
        meme.approve(address(this), AMOUNT);

        vm.expectRevert("ERC20: transfer to the zero address");
        meme.transferFrom(PORTAL, address(0), AMOUNT);
    }

    /// @notice No original. `burn()` / `burnFrom()`  `transferFrom -> 0xdead` It is indeed the only path to destruction.
    function test_thereIsNoNativeBurnFunction() public {
        (bool okBurn,) = MEME.call(abi.encodeWithSignature("burn(uint256)", AMOUNT));
        (bool okBurnFrom,) = MEME.call(abi.encodeWithSignature("burnFrom(address,uint256)", PORTAL, AMOUNT));

        assertFalse(okBurn, unicode"It shouldn't exist. burn(uint256)");
        assertFalse(okBurnFrom, unicode"It shouldn't exist. burnFrom(address,uint256)");
    }
}
