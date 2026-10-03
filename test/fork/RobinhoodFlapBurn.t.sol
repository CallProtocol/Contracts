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

/// @notice **销毁路径的复核：`transferFrom(user, 0xdead, X)` 实收必须恰好等于 X。**
///
/// `ClearingPool.exercise` 的第 2 步把受益人的 MEME 转给 `0xdead`。这条路径上的两个事实
/// 决定了实现的形状，两个都是实测得来的（`docs/research/flap-tax-and-burn-path.md`）：
///
/// - **没有原生 `burn()` / `burnFrom()`** ⟹ `transferFrom → 0xdead` 是唯一可用的销毁路径；
/// - **转给 `0x0` 会 revert** ⟹ 销毁地址必须是 `0xdead`。
///
/// 🔴 池子**不核对** `0xdead` 的余额增量 —— 那个取舍与它的理由只写在 `src/ClearingPool.sol` 的
/// `exercise` 上，这里不复述。这里只承接它的**后果**：「烧掉的确实是那么多」这条性质**没有合约层的
/// 守卫，只有这个文件**。它复核的是外部合约现在的行为，所以价值全在「哪天变了要立刻知道」。
///
/// # ⚠️ 一个仍然敞着的口子：阳性对照不在目标链上
///
/// `flap-tax-and-burn-path.md` §5 记着作者自己踩过的坑：**只观察无税的样本，会稳定地得出
/// 「没有税」。** 在历史 BSC 对照上拿到了阳性样本（MarsCoin 的官方池实测 3.00%），但在 Robinhood Chain 上
/// 拿不到 —— 这条链上还找不到一个已毕业、拥有自己注册交易对的 Flap 代币（issue #5 的 Further Notes
/// 记了这条 residual gap，试过的 7 个目标全部零税）。
///
/// 所以下面用 `test_theMeasurementItselfDetectsTax` 顶上：它拿**同一个测量函数**去量一只本地的
/// 3% 税代币。它证明的是「这套测量抓得到税」，**不是**「Flap 的收税分支在目标链上被验证过」。
/// 后者仍然开着，随 issue #5 关闭。这个区别必须写在这里，不能靠一条恒绿的测试假装它已经关上了。
contract RobinhoodFlapBurnForkTest is ForkTest {
    /// @dev Robinhood Chain 上的 `FlapTaxTokenV3` 实现。该链的 Flap 代币都是指向它的 EIP-1167 最小代理，
    ///      与历史 BSC 样本实现 `0x024f1829…` 的 46 个 selector 完全一致；该比较不构成 v1 的 BSC 依赖。
    address internal constant FLAP_TAX_TOKEN_V3_IMPL = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;

    /// @dev 样本代币与 Flap Portal。🔴 **不在这里写地址字面量** —— 它们定义在 {ForkConfig}，
    ///      这里只取别名（PR #29 复审 P2：此前四个分叉测试各写了一遍同一个地址）。
    ///      税率 300/300、全部供应仍在联合曲线上等性质见 {ForkConfig} 的注释。
    address internal constant MEME = ForkConfig.PINNED_FLAP_TAX_TOKEN_V3_SAMPLE;
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;

    /// @dev 与 `src/ClearingPool.sol` 的常量**独立**写死。
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant AMOUNT = 1 ether;

    IERC20 internal meme;

    function setUp() public {
        // 探测「该高度有没有状态」时读的是样本 MEME 而不是 GME —— 探针要落在真正会被读的合约上。
        ForkTarget memory target = ForkConfig.robinhood();
        target.probe = MEME;
        selectFork(target);

        meme = IERC20(MEME);
    }

    /// @dev 一次带授权的 `transferFrom`，返回目标**实际收到**的数量。
    ///      名义额与实收之差就是税 —— 这正是 §2 的探针在链上做的那件事。
    function _receivedBy(IERC20 token, address holder, address to, uint256 amount) internal returns (uint256) {
        uint256 before = token.balanceOf(to);
        vm.prank(holder);
        token.approve(address(this), amount);
        token.transferFrom(holder, to, amount);
        return token.balanceOf(to) - before;
    }

    // ─────────────────── 前置条件：量的确实是那个实现 ───────────────────

    /// @dev 断言之前先证明**跑的是真实合约**。字节码长度既认代理也认实现 ——
    ///      Flap 换实现时这一条会先红，而那正是本文件存在的理由。
    function test_theSampleIsTheRealFlapTaxToken() public view {
        assertEq(MEME.code.length, 45, unicode"样本代币应当是 EIP-1167 最小代理");
        assertEq(FLAP_TAX_TOKEN_V3_IMPL.code.length, 19_020, unicode"实现合约字节码长度");
        assertEq(IFlapTaxTokenV3(MEME).buyTaxRate(), 300, "buyTaxRate()");
        assertEq(IFlapTaxTokenV3(MEME).sellTaxRate(), 300, "sellTaxRate()");
        assertGt(meme.balanceOf(PORTAL), 0, unicode"联合曲线应当持有余额");

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

    // ─────────────────────────── 核心断言 ───────────────────────────

    /// @notice 🔴 **验收条款：`transferFrom(user, 0xdead, X)` 实收恰好等于 X。**
    ///
    /// @dev 这条不成立时，用户付了完整的 `memeAmount`，却只烧掉了其中一部分 —— 池子看不见，
    ///      因为它不核对增量（那是刻意的取舍，见 `exercise`）。所以退化会是**无声**的，
    ///      只有这条测试会喊。
    function test_burnPathDeliversExactlyTheFullAmount() public {
        uint256 received = _receivedBy(meme, PORTAL, BURN_ADDRESS, AMOUNT);

        assertEq(received, AMOUNT, unicode"0xdead 实收必须恰好等于转出额");

        console2.log(
            string.concat(
                unicode"  → 0xdead  转出 ", vm.toString(AMOUNT), unicode"  实收 ", vm.toString(received)
            )
        );
    }

    /// @notice 对照组：转给陌生 EOA 同样不收税 —— 说明零税不是 `0xdead` 的特例待遇。
    function test_plainTransferToAFreshEoaIsUntaxed() public {
        assertEq(_receivedBy(meme, PORTAL, makeAddr("stranger"), AMOUNT), AMOUNT, unicode"陌生 EOA 实收");
    }

    /// @notice 🔴 **方法论守卫**：证明这套测量**抓得到税**。
    ///
    /// @dev 只量无税的目标，会稳定地得出「没有税」——`flap-tax-and-burn-path.md` §5 记的就是
    ///      作者自己踩的这个坑。真正的阳性对照要求一个**收税分支处于激活状态的 Flap 代币**，
    ///      而 Robinhood Chain 上目前没有（见本合约头部与 issue #5）。
    ///
    ///      所以这里退一步，只证明**测量函数本身**不是恒等地返回全额：同一个 `_receivedBy`
    ///      量一只本地的 3% 税代币，必须量出那 3%。
    ///      ⚠️ 它**不**替代目标链上的阳性对照，那一条仍然开着。
    function test_theMeasurementItselfDetectsTax() public {
        MemeToken taxed = new MemeToken();
        taxed.setTaxBps(300);
        address holder = makeAddr("taxed holder");
        taxed.mint(holder, AMOUNT);

        uint256 received = _receivedBy(IERC20(address(taxed)), holder, makeAddr("taxed recipient"), AMOUNT);

        assertLt(received, AMOUNT, unicode"测量函数量不出税 ⟹ 上面那条「零税」的结论是空的");
        assertEq(received, AMOUNT - (AMOUNT * 300) / 10_000, unicode"而且量出来的就是那 3%");
    }

    // ────────────────── 为什么销毁地址只能是 0xdead ──────────────────

    /// @notice 转给 `0x0` 必须 revert —— 规格选 `0xdead` 而不是 `0x0` 的**全部**依据。
    ///
    /// @dev 🔴 断具体的 revert 数据，不写空的 `vm.expectRevert()`。这条测试的全部意义就是失败的
    ///      **原因**，而空断言连「因为别的原因失败了」都会当成通过 —— 比如授权额度没设上，
    ///      那时它照样是绿的，却什么也没证明。同 `ClearingPoolMinting.t.sol` 的规矩。
    ///
    ///      这串字面量是**实测**来的，不是从 BSC 的调研笔记里抄的：Robinhood 上的实现字节码与
    ///      BSC 那份不同（19,020 vs 19,331），所以「它也用老式的 require 字符串」这件事必须自己量一遍。
    ///      复算：`cast call <MEME> "transfer(address,uint256)" 0x0 1e18 --from <PORTAL>`。
    function test_transferToTheZeroAddressReverts() public {
        vm.prank(PORTAL);
        meme.approve(address(this), AMOUNT);

        vm.expectRevert("ERC20: transfer to the zero address");
        meme.transferFrom(PORTAL, address(0), AMOUNT);
    }

    /// @notice 没有原生 `burn()` / `burnFrom()` ⟹ `transferFrom → 0xdead` 确实是唯一销毁路径。
    function test_thereIsNoNativeBurnFunction() public {
        (bool okBurn,) = MEME.call(abi.encodeWithSignature("burn(uint256)", AMOUNT));
        (bool okBurnFrom,) = MEME.call(abi.encodeWithSignature("burnFrom(address,uint256)", PORTAL, AMOUNT));

        assertFalse(okBurn, unicode"不应存在 burn(uint256)");
        assertFalse(okBurnFrom, unicode"不应存在 burnFrom(address,uint256)");
    }
}
