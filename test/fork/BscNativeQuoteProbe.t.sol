// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {FlapNewTokenV6Params, IFlapPortalLaunch} from "./FlapGmeLaunch.sol";
import {ForkConfigBsc} from "./ForkConfigBsc.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev 与 `RobinhoodSelfLaunch.t.sol` 同构的最小声明 —— 两处都只声明自己用到的面。
struct ExactInputParams {
    address inputToken;
    address outputToken;
    uint256 inputAmount;
    uint256 minOutputAmount;
    bytes permitData;
}

interface IFlapPortalSwap {
    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

interface ITaxProcessorProbeFace {
    function dispatch() external;
    function dispatchThreshold() external view returns (uint256);
    function marketAddress() external view returns (address);
    function marketQuoteBalance() external view returns (uint256);
    function quoteToken() external view returns (address);
    function dividendToken() external view returns (address);
}

interface IErc20ProbeFace {
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IDexPairProbeFace {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @dev `Portal.getQuoteTokenConfiguration` 的裸 uint8 声明（枚举字段一律 uint8，
///      理由与 `ForkConfigBsc` 注释里 `nativeToQuoteSwapType = 7 超出 vendored 枚举` 相同）。
interface IQuoteConfigProbeFace {
    struct QuoteTokenConfiguration {
        uint8 enabled;
        uint8 defaultCurve;
        uint8 alternativeCurve;
        uint8 nativeToQuoteSwapType;
        uint8 dexId;
    }

    function getQuoteTokenConfiguration(address quoteToken)
        external
        view
        returns (QuoteTokenConfiguration memory config);
}

/// @notice 记录「税收交付那一刻我拿到了多少 gas」的探针收款人。
///
/// @dev 🔴 receive 里**只发一条事件**（≈1.4k gas）：若上游用 `transfer`/`send`（2300 津贴），
///      这条路径也活得下来、把数记出来；写存储的话 2300 下会 revert，
///      测出来的就是「交付失败」而不是「津贴是多少」—— 探针自己不能改变被测量的东西。
contract GasStipendProbe {
    event Rx(uint256 gasAtEntry, uint256 value);

    receive() external payable {
        emit Rx(gasleft(), msg.value);
    }
}

/// @title BscNativeQuoteProbeForkTest
/// @notice 🔴 **原生币计价档的三条实测探针**（研究文档 §7.6 的 1/2/3/4/5 项）。
///
/// 这些不是回归测试，是**测量**：每一条的价值一半在断言、一半在它打印出来的数。
/// 全部跑在 `bscLatest()` 上 —— 问的是「今天的 Portal 什么行为」，钉死高度会把问题答错。
///
/// | 探针 | 回答的问题（研究文档编号） |
/// |---|---|
/// | probe1 | §7.6-2 原生档 `dividendToken` 要求什么；§7.6-5 原生档 price 量纲 |
/// | probe2 | §7.6-1 税收交付的 gas 津贴（`receive()` 原生档形态的依据）；§7.6-3 毕业池腿是不是 WBNB |
/// | probe3 | §7.6-4 `enabled` 门是否已废除（任意 ERC-20 计价） |
contract BscNativeQuoteProbeForkTest is ForkTest {
    address internal constant PORTAL = ForkConfigBsc.FLAP_PORTAL;

    /// @dev canonical WBNB；值与研究文档 §7.1 一致。
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @dev 牛来 —— 2026-09-14 实测 `getQuoteTokenConfiguration` 的 `enabled = 0`，
    ///      但它自己是一只真实存在、已毕业的税代币（QQQB 计价）。probe3 拿它当
    ///      「enabled=0 的 ERC-20 计价币」样本。
    address internal constant NIULAI = 0xBEEA1D618e533a387D941F58a7d4c9b7bD377777;

    uint8 internal constant STATUS_TRADABLE = 1;
    uint8 internal constant STATUS_DEX = 4;

    uint256 private _nonce;

    // ──────────────────── probe0：挖矿自检（离线，不连链） ────────────────────

    /// @notice 挖矿循环的离线自检：从 seed=1 起必须在 1e6 内挖到一个 7777 尾号 salt，
    ///         且独立用 `vm.computeCreate2Address` 复算出同一个地址。
    ///
    /// @dev 2026-09-14 首轮探针三条全部倒在「挖不到 salt」上（统计上 1e6 次期望命中 ~15），
    ///      这条把「挖矿数学对不对」与「分叉环境的干扰」分开 —— 它不 selectFork。
    function test_probe0_offline_saltMiningSelfCheck() public view {
        bytes32 salt = _mineSalt(1);
        address predicted = vm.computeCreate2Address(salt, ForkConfigBsc.vanityInitCodeHash(), PORTAL);
        console2.log(unicode"[probe0] 挖到 salt =", uint256(salt));
        console2.log(unicode"[probe0] 预测地址  =", predicted);
        require(uint160(predicted) & 0xffff == 0x7777, unicode"复算地址不以 7777 结尾 —— 汇编与 computeCreate2Address 分叉了");
    }

    // ─────────────────────────── probe1：dividendToken ───────────────────────────

    /// @notice §7.6-2：原生档 `newTokenV6` 的 `dividendToken` 要求什么？
    ///
    /// @dev ERC-20 档的硬性要求是 `= quoteToken`（`WarrantLauncher.sol:341`，留空撞
    ///      `DividendTokenMustEqualQuoteToken()`）。原生档下 `quoteToken = address(0)`，
    ///      「相等」意味着留零 —— 但这是推断，这里两种取值都发一遍，让链自己回答。
    function test_probe1_nativeQuote_dividendTokenRequirement() public {
        selectFork(ForkConfigBsc.bscLatest());

        _logQuoteConfig(unicode"address(0) 的计价币配置", address(0));
        // 备选方案的可行性读数（用户 2026-09-14）：若原生档实测代价太大，退一步用 WBNB
        // 当普通 ERC-20 计价币 —— 那时这格配置（尤其 nativeToQuoteSwapType）决定
        // flap.sh 上能不能仍旧掏裸 BNB 买。
        _logQuoteConfig(unicode"WBNB 的计价币配置", WBNB);

        // ① dividendToken = address(0)（与 quoteToken「相等」的原生档读法）
        (bool ok0, bytes memory err0, address token0) = _tryLaunch(address(0), address(0), vm.addr(0xd1));
        _logLaunchOutcome(unicode"① dividendToken = address(0)", ok0, err0, token0);

        // ② dividendToken = WBNB（「原生的 ERC-20 化身」这种理解对不对）
        (bool ok1, bytes memory err1, address token1) = _tryLaunch(address(0), WBNB, vm.addr(0xd2));
        _logLaunchOutcome(unicode"② dividendToken = WBNB", ok1, err1, token1);

        require(ok0 || ok1, unicode"两种 dividendToken 取值都发不出原生计价币 —— 读上面的 revert 数据");

        // §7.6-5：量纲探针。买入 1 BNB，对照镜头报的 price 与实收数量。
        address token = ok0 ? token0 : token1;
        address buyer = makeAddr("dimension-buyer");
        vm.deal(buyer, 2 ether);
        vm.prank(buyer, buyer);
        uint256 got = IFlapPortalSwap(PORTAL).swapExactInput{value: 1 ether}(
            ExactInputParams({
                inputToken: address(0),
                outputToken: token,
                inputAmount: 1 ether,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        IFlapPortalLens.TokenStateV8Safe memory s = _state(token);
        console2.log(unicode"[量纲] 1 BNB 买到 raw MEME       =", got);
        console2.log(unicode"[量纲] 镜头 price（raw quote/1e18 MEME）=", s.price);
        console2.log(unicode"[量纲] price 反推 1 BNB 应得      =", s.price == 0 ? 0 : uint256(1e36) / s.price);
        console2.log(unicode"[量纲] quoteTokenAddress          =", s.quoteTokenAddress);
        console2.log(unicode"[量纲] status                     =", uint256(s.status));
    }

    // ────────────────────── probe2：交付 gas 津贴 + 毕业池腿 ──────────────────────

    /// @notice §7.6-1 + §7.6-3：原生档税收交付给 beneficiary 的调用带多少 gas？
    ///         毕业后的 DEX 池那条腿是不是 WBNB？
    ///
    /// @dev 🔴 §7.6-1 是 `receive()` 原生档形态的**全部依据**：
    ///      2300 津贴 ⟹ 现有 `_recognize`（SLOAD+SSTORE+event）都超限，急切包装免谈；
    ///      全额转发 ⟹ 急切包装可行（研究文档 §7.8 的混合形态）。
    ///      探针收款人只发一条事件，两种津贴下都能把 `gasleft()` 记出来。
    function test_probe2_nativeQuote_taxDeliveryGasAndPoolLeg() public {
        selectFork(ForkConfigBsc.bscLatest());

        GasStipendProbe probe = new GasStipendProbe();
        (bool ok, bytes memory err, address token) = _tryLaunch(address(0), address(0), address(probe));
        if (!ok) {
            // probe1 已经回答了 dividendToken 的问题；这里跟着它的答案换一种取值再试。
            (ok, err, token) = _tryLaunch(address(0), WBNB, address(probe));
        }
        require(ok, string.concat(unicode"发原生计价探针币失败：", vm.toString(err)));
        console2.log(unicode"[probe2] 探针币 =", token);

        // ── 用原生币买穿曲线（§7.6-6 顺带记录毕业成本）─────────────────────
        address whale = makeAddr("native-whale");
        uint256 spent;
        for (uint256 i = 0; i < 200 && _state(token).status != STATUS_DEX; i++) {
            vm.deal(whale, 5 ether);
            vm.prank(whale, whale);
            IFlapPortalSwap(PORTAL).swapExactInput{value: 5 ether}(
                ExactInputParams({
                    inputToken: address(0),
                    outputToken: token,
                    inputAmount: 5 ether,
                    minOutputAmount: 0,
                    permitData: ""
                })
            );
            spent += 5 ether;
        }
        require(_state(token).status == STATUS_DEX, unicode"1000 BNB 仍未毕业 —— 调大步长再跑");
        console2.log(unicode"[probe2] 毕业花费（wei，原生）=", spent);

        // ── §7.6-3：毕业池的两条腿 ────────────────────────────────────────
        address pool = _state(token).pool;
        console2.log(unicode"[probe2] 毕业池   =", pool);
        console2.log(unicode"[probe2] token0   =", IDexPairProbeFace(pool).token0());
        console2.log(unicode"[probe2] token1   =", IDexPairProbeFace(pool).token1());
        console2.log(unicode"[probe2] WBNB 对照 =", WBNB);

        // ── TaxProcessor 侧的身份读数 ─────────────────────────────────────
        ITaxProcessorProbeFace tp = ITaxProcessorProbeFace(_taxProcessorOf(token));
        require(address(tp) != address(0), unicode"TOKEN_TAXED_V3 应当有 taxProcessor");
        console2.log(unicode"[probe2] taxProcessor        =", address(tp));
        console2.log(unicode"[probe2] tp.quoteToken       =", tp.quoteToken());
        console2.log(unicode"[probe2] tp.dividendToken    =", tp.dividendToken());
        console2.log(unicode"[probe2] tp.marketAddress    =", tp.marketAddress());
        console2.log(unicode"[probe2] tp.dispatchThreshold=", tp.dispatchThreshold());

        // ── 毕业后交易几轮攒税，然后显式 dispatch ─────────────────────────
        vm.recordLogs();
        for (uint256 round = 0; round < 4; round++) {
            address trader = makeAddr(string.concat("post-dex-", vm.toString(round)));
            vm.deal(trader, 3 ether);
            vm.startPrank(trader, trader);
            uint256 bought = IFlapPortalSwap(PORTAL).swapExactInput{value: 2 ether}(
                ExactInputParams({
                    inputToken: address(0),
                    outputToken: token,
                    inputAmount: 2 ether,
                    minOutputAmount: 0,
                    permitData: ""
                })
            );
            IErc20ProbeFace(token).approve(PORTAL, bought);
            IFlapPortalSwap(PORTAL).swapExactInput(
                ExactInputParams({
                    inputToken: token,
                    outputToken: address(0),
                    inputAmount: bought,
                    minOutputAmount: 0,
                    permitData: ""
                })
            );
            vm.stopPrank();
        }
        console2.log(unicode"[probe2] 交易后 marketQuoteBalance =", tp.marketQuoteBalance());
        if (tp.marketQuoteBalance() != 0) tp.dispatch();

        // ── 读探针记下的每一次交付 ────────────────────────────────────────
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rxTopic = keccak256("Rx(uint256,uint256)");
        uint256 deliveries;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(probe) || logs[i].topics[0] != rxTopic) continue;
            (uint256 gasAtEntry, uint256 value) = abi.decode(logs[i].data, (uint256, uint256));
            deliveries++;
            console2.log(unicode"[probe2] 🔴 交付：receive 入口 gasleft =", gasAtEntry);
            console2.log(unicode"[probe2]        msg.value              =", value);
        }
        console2.log(unicode"[probe2] 原生交付笔数        =", deliveries);
        console2.log(unicode"[probe2] 探针最终原生余额    =", address(probe).balance);
        console2.log(unicode"[probe2] 探针最终 WBNB 余额  =", IErc20ProbeFace(WBNB).balanceOf(address(probe)));
        require(
            deliveries != 0 || address(probe).balance != 0
                || IErc20ProbeFace(WBNB).balanceOf(address(probe)) != 0,
            unicode"没有观测到任何交付 —— 门限没过？读上面的 marketQuoteBalance"
        );
    }

    // ──────────────────────── probe3：enabled 门是否已废除 ────────────────────────

    /// @notice §7.6-4：拿一只 `enabled = 0` 的 ERC-20（牛来）当计价币直接 `newTokenV6`。
    ///
    /// @dev 背景：用户在 flap.sh 界面手测「牛来计价」已经可用，而我们在最新块上读到的配置
    ///      仍是 `enabled = 0` —— 两个观测并存，说明 `enabled` 可能已不再是发币的门。
    ///      这里让链自己回答，成功与失败都是答案。
    function test_probe3_arbitraryQuote_enabledGate() public {
        selectFork(ForkConfigBsc.bscLatest());

        _logQuoteConfig(unicode"牛来的计价币配置", NIULAI);

        (bool ok, bytes memory err, address token) = _tryLaunch(NIULAI, NIULAI, vm.addr(0xd3));
        _logLaunchOutcome(unicode"牛来（enabled=0）计价", ok, err, token);

        if (ok) {
            IFlapPortalLens.TokenStateV8Safe memory s = _state(token);
            console2.log(unicode"[probe3] 新币 quoteTokenAddress =", s.quoteTokenAddress);
            console2.log(unicode"[probe3] 新币 status            =", uint256(s.status));
        }
    }

    // ─────────────────────────────── 辅助 ───────────────────────────────

    /// @dev 外部自调是为了 try/catch：把 Portal 的 revert 变成一个**可打印的返回值**，
    ///      而不是让整条测试红掉 —— 探针要的是答案，不是通过。
    function launchExternal(address quote, address dividend, address beneficiary)
        external
        returns (address token)
    {
        FlapNewTokenV6Params memory p;
        p.name = "Native Quote Probe";
        p.symbol = "NQPRB";
        // 🔴 seed 取 64 位哈希高位起点，不从小数起：BSC 主网上低位 salt 空间已被真实发射
        //    耗光（2026-09-14 实测：seed 1..1e6 里每一个 7777 命中位上都已有代码，三条探针
        //    全倒在「挖不到空闲 salt」上；仓库里那次真实发射的 salt ≈ 1.68e11 亦是旁证）。
        //    Robinhood 版 FlapGmeLaunch 用小 seed 能活，是因为那条链发射少 —— 抄它会在这里翻车。
        p.salt = _mineSalt(uint256(keccak256(abi.encodePacked("nq-salt", _nonce, block.number))) >> 192);
        p.quoteToken = quote;
        p.quoteAmt = 0;
        p.beneficiary = beneficiary;
        p.dexThresh = ForkConfigBsc.FLAP_DEX_THRESH_SUPPORTED;
        p.migratorType = ForkConfigBsc.FLAP_MIGRATOR_TYPE_V2;
        p.dexId = ForkConfigBsc.FLAP_DEX_ID_SUPPORTED;
        p.lpFeeProfile = ForkConfigBsc.FLAP_LP_FEE_PROFILE_STANDARD;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000;
        p.mktBps = 10_000;
        p.dividendToken = dividend;
        p.tokenVersion = ForkConfigBsc.FLAP_TOKEN_VERSION_TAXED_V3;

        // 🔴 每次换发起人：Portal 按 tx.origin 限频（RateLimitExceeded）。
        address who = vm.addr(uint256(keccak256(abi.encodePacked("nq-launcher", _nonce++))));
        vm.deal(who, 10 ether);
        vm.prank(who, who);
        token = IFlapPortalLaunch(PORTAL).newTokenV6(p);
    }

    function _tryLaunch(address quote, address dividend, address beneficiary)
        private
        returns (bool ok, bytes memory err, address token)
    {
        try this.launchExternal(quote, dividend, beneficiary) returns (address t) {
            return (true, "", t);
        } catch (bytes memory reason) {
            return (false, reason, address(0));
        }
    }

    function _logLaunchOutcome(string memory label, bool ok, bytes memory err, address token) private {
        if (ok) {
            console2.log(string.concat(unicode"[发射] ", label, unicode" → 成功"), token);
        } else {
            console2.log(string.concat(unicode"[发射] ", label, unicode" → revert，数据："));
            console2.logBytes(err);
        }
    }

    function _logQuoteConfig(string memory label, address quote) private {
        try IQuoteConfigProbeFace(PORTAL).getQuoteTokenConfiguration(quote) returns (
            IQuoteConfigProbeFace.QuoteTokenConfiguration memory c
        ) {
            console2.log(
                string.concat(
                    unicode"[配置] ", label, " = (",
                    vm.toString(c.enabled), ", ",
                    vm.toString(c.defaultCurve), ", ",
                    vm.toString(c.alternativeCurve), ", ",
                    vm.toString(c.nativeToQuoteSwapType), ", ",
                    vm.toString(c.dexId), ")"
                )
            );
        } catch {
            console2.log(string.concat(unicode"[配置] ", label, unicode" 读不出来（revert）"));
        }
    }

    /// @dev 与 `FlapGmeLaunch._mineVanitySaltFrom` 同一段汇编，常量换成 BSC 那一份
    ///      （`ForkConfigBsc.t.sol` 钉过：拿 Robinhood 的初始化码在 BSC 上挖，一个 salt 都不对）。
    function _mineSalt(uint256 seed) private view returns (bytes32 salt) {
        bytes32 initCodeHash = ForkConfigBsc.vanityInitCodeHash();
        address portalAddress = PORTAL;

        assembly {
            let p := mload(0x40)
            mstore8(p, 0xff)
            mstore(add(p, 0x01), shl(96, portalAddress))
            mstore(add(p, 0x35), initCodeHash)
            for { let i := seed } lt(i, add(seed, 1000000)) { i := add(i, 1) } {
                mstore(add(p, 0x15), i)
                let predicted := and(keccak256(p, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
                if eq(and(predicted, 0xffff), 0x7777) {
                    if iszero(extcodesize(predicted)) {
                        salt := i
                        break
                    }
                }
            }
        }

        require(salt != 0, unicode"挖不到空闲的 7777 尾号 salt —— 初始化码或部署者变了？");
    }

    function _state(address token) private view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(PORTAL).getTokenV8Safe(token);
    }

    function _taxProcessorOf(address token) private view returns (address processor) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("taxProcessor()"));
        if (ok && ret.length == 32) processor = abi.decode(ret, (address));
    }
}
