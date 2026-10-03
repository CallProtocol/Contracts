// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";
import {WarrantVault} from "../../src/WarrantVault.sol";
import {ForkConfig} from "./ForkConfig.sol";

/// @dev Flap `Portal` 的建币入口（不带金库那一支）。字段顺序抄自 Blockscout 上**已验证**的
///      `Portal` 实现里的 `NewTokenV6Params`（`src/interfaces/IPortal.sol`）。
///      枚举字段一律写成 `uint8` —— 我们只需要编码对，不需要它们的类型。
struct FlapNewTokenV6Params {
    string name;
    string symbol;
    string meta;
    uint8 dexThresh;
    bytes32 salt;
    uint8 migratorType;
    address quoteToken;
    uint256 quoteAmt;
    address beneficiary;
    bytes permitData;
    bytes32 extensionID;
    bytes extensionData;
    uint8 dexId;
    uint8 lpFeeProfile;
    uint16 buyTaxRate;
    uint16 sellTaxRate;
    uint64 taxDuration;
    uint64 antiFarmerDuration;
    uint16 mktBps;
    uint16 deflationBps;
    uint16 dividendBps;
    uint16 lpBps;
    uint256 minimumShareBalance;
    address dividendToken;
    address commissionReceiver;
    uint8 tokenVersion;
}

interface IFlapPortalLaunch {
    function newTokenV6(FlapNewTokenV6Params calldata params) external payable returns (address token);
}

/// @title FlapGmeLaunch
/// @notice 在**真实** Flap `Portal` 上发一只 **GME 计价** 的 `TOKEN_TAXED_V3`。
///
/// 分叉测试里凡是要「真实 TWAP 读数」的，都得先有一只 GME 计价的 MEME：钉死高度上那只
/// `PINNED_FLAP_TAX_TOKEN_V3_SAMPLE` 是**原生币计价**的，我们的金库会按
/// {PriceSource.QUOTE_MISMATCH} 拒采它（`RobinhoodTwapSource.t.sol` 有一条测试专门钉这件事）。
///
/// @dev 由 `RobinhoodOpenSeries.t.sol` 与 `RobinhoodTwapSource.t.sol` 共享。除了真实发币，二者
///      还共用严格 24 小时 TWAP ring 的铺设；只有 `RobinhoodVaultIdentity.t.sol` 走的是带金库的
///      `newTokenV6WithVault`，与本文件不是同一个入口。
abstract contract FlapGmeLaunch {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant FLAP_PORTAL_ADDRESS = ForkConfig.FLAP_PORTAL;
    address internal constant GME_ADDRESS = ForkConfig.GME;

    /// @dev 发射参数照 `docs/spec.zh.md` §6.1（买卖各 300 bps、税期 100 年、税收全额进金库）。
    uint16 internal constant LAUNCH_BUY_TAX_BPS = 300;
    uint16 internal constant LAUNCH_SELL_TAX_BPS = 300;
    uint64 internal constant LAUNCH_TAX_DURATION = 3_153_600_000;
    uint256 private constant LAUNCH_SALT_SEED_STRIDE = 7919;

    uint256 private _launchNonce;

    /// @notice 发一只 GME 计价的 `TOKEN_TAXED_V3`，返回代币地址。
    ///
    /// @dev 🔴 **每次换一个发起人**：Portal 对同一个 `tx.origin` 有建币频率限制
    ///      （`RateLimitExceeded`），同一个地址连发两次，第二次会因为与被测内容无关的理由红掉。
    ///      两参数的 `vm.prank` 是必需的 —— 限制看的是 `tx.origin`，不是 `msg.sender`。
    function _launchGmeQuotedToken() internal returns (address token) {
        return _launchGmeQuotedToken("Warrant Series Probe", "WSERIES");
    }

    /// @dev 名称和代码可按测试的可读性定制；真实 Portal 路径、salt 挖矿和发起人轮换统一留在这里。
    function _launchGmeQuotedToken(string memory name, string memory symbol) internal returns (address token) {
        FlapNewTokenV6Params memory params;
        params.name = name;
        params.symbol = symbol;
        params.salt = _mineVanitySaltFrom(1 + _launchNonce * LAUNCH_SALT_SEED_STRIDE);
        params.quoteToken = GME_ADDRESS; // 🔴 整条 TWAP 链路的前提就在这一行
        params.quoteAmt = 0;
        params.beneficiary = vm.addr(uint256(keccak256(abi.encodePacked("beneficiary", _launchNonce))));
        params.dexThresh = ForkConfig.FLAP_DEX_THRESH_SUPPORTED;
        params.migratorType = ForkConfig.FLAP_MIGRATOR_TYPE_V2;
        params.dexId = 0;
        params.buyTaxRate = LAUNCH_BUY_TAX_BPS;
        params.sellTaxRate = LAUNCH_SELL_TAX_BPS;
        params.taxDuration = LAUNCH_TAX_DURATION;
        params.mktBps = 10_000;
        // 计价币不是原生币时，分红币种必须显式给出（`DividendTokenMustEqualQuoteToken()`）。
        params.dividendToken = GME_ADDRESS;
        params.tokenVersion = ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3;

        address who = vm.addr(uint256(keccak256(abi.encodePacked("gme launcher", _launchNonce++))));
        vm.deal(who, 10 ether);
        vm.prank(who, who);
        token = IFlapPortalLaunch(FLAP_PORTAL_ADDRESS).newTokenV6(params);
    }

    /// @dev Portal 要求代币地址以 `7777` 结尾，所以得先挖一个 salt。代币走的是最小代理
    ///      （EIP-1167）+ CREATE2，初始化码因此完全可预测。
    function _mineVanitySaltFrom(uint256 seed) internal view returns (bytes32 salt) {
        address implementation = ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION;
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        address portalAddress = FLAP_PORTAL_ADDRESS;

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

    /// @dev Portal 镜头上那只代币此刻的状态。
    function _tokenState(address token) internal view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        return IFlapPortalLens(FLAP_PORTAL_ADDRESS).getTokenV8Safe(token);
    }

    /// @dev 生成严格 trailing 24h 覆盖：空环写 t0..t24 共 25 条；已有首样本时只补 24 条。
    ///      逐轮读取时间戳才能保留生产实现的每小时采样纪律。
    function _fillTwapRing(WarrantVault vault, address sampler) internal returns (bool) {
        uint256 writes = vault.lastSampleAt() == 0 ? 25 : 24;
        for (uint256 i = 0; i < writes; i++) {
            if (vault.lastSampleAt() != 0) vm.warp(block.timestamp + 1 hours);
            vm.prank(sampler);
            if (!vault.sampleTwap()) return false;
        }
        return true;
    }
}
