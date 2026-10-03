// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev Flap 的 VaultPortal 建币入口。字段顺序是**实测**钉死的：把这 27 个字段拼成 tuple 签名，
///      算出的选择器 `0x1b806220` 出现在本链 VaultPortal 实现的 runtime 字节码里。
struct NewTokenV6WithVaultParams {
    string name;
    string symbol;
    string meta;
    uint8 dexThresh;
    bytes32 salt;
    uint8 migratorType;
    address quoteToken;
    uint256 quoteAmt;
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
    address vaultFactory;
    bytes vaultData;
}

interface IFlapVaultPortal {
    struct VaultInfo {
        address vault;
        address vaultFactory;
        string description;
        bool isOfficial;
        uint8 riskLevel;
    }

    function newTokenV6WithVault(NewTokenV6WithVaultParams calldata params) external payable returns (address token);
    function getVault(address taxToken) external view returns (VaultInfo memory info);
    function tryGetVault(address taxToken) external view returns (bool found, VaultInfo memory info);
    function vaultFactories(address factory)
        external
        view
        returns (bool enabled, bool official, uint8 riskLevel, bytes29 reserved);
    /// @dev `AUDITOR_ROLE` 专属：**重写**某只代币的 `token → vault` 绑定。
    function refreshTokenVault(address taxToken) external;
}

/// @title FlapLaunchTest
/// @notice 在 Robinhood Chain 分叉上**真的发一只带金库的 MEME** 所需要的全部机器。
///
/// 每一个取值都是实测钉死的，`docs/research/flap-vault-identity-spike.md` §4 / §5 记着复算过程。
/// 抽成基类，是因为它现在有两个用户，而这套参数只该有**一处**出处：
///
/// - `RobinhoodVaultIdentity.t.sol`（issue #23 的六条判据，探针工厂）
/// - `RobinhoodWarrantVaultFactory.t.sol`（issue #37 的验收，**真工厂**）
///
/// 两边各抄一份的话，Flap 哪天改了枚举取值，红的会是其中一个，而另一个会安静地继续跑一条
/// 已经不成立的路径。
abstract contract FlapLaunchTest is ForkTest {
    address internal constant VAULT_PORTAL = ForkConfig.FLAP_VAULT_PORTAL;
    address internal constant PORTAL = ForkConfig.FLAP_PORTAL;
    address internal constant TAX_TOKEN_V3_IMPL = ForkConfig.SUPPORTED_FLAP_TAX_TOKEN_V3_IMPLEMENTATION;

    IFlapVaultPortal internal vaultPortal = IFlapVaultPortal(VAULT_PORTAL);

    uint256 internal _launchNonce;

    /// @dev 🔴 **每次发射换一个发起人。** VaultPortal 对同一个地址有建币频率限制
    ///      （`RateLimitExceeded(user, lastCreationTime)` = `0xa7382e9b`，实测撞到过）。
    ///      同一个发起人连发两次，第二次会因为**与要证的事情完全无关**的理由红掉。
    function _launch(NewTokenV6WithVaultParams memory p) internal returns (address token) {
        address who = _freshLauncher();
        vm.prank(who, who);
        return vaultPortal.newTokenV6WithVault(p);
    }

    /// @dev 🔴 **两参数的 `vm.prank`**：频率限制看的是 `tx.origin`，不是 `msg.sender`。
    ///      单参数版本只换 `msg.sender`，`tx.origin` 还是 forge 的默认发送方，于是**第二次**
    ///      发射会撞 `RateLimitExceeded(0x1804c8Ab…, …)` —— 一个既不是要证的事情、
    ///      报出来的地址又不属于任何一个角色的红灯。实测踩过。
    function _freshLauncher() internal returns (address who) {
        who = makeAddr(string.concat("launcher-", vm.toString(_launchNonce++)));
        vm.deal(who, 10 ether);
    }

    /// @dev Robinhood Chain 上唯一走得通的建币组合，五个取值全是实测钉死的 —— 见 {ForkConfig}
    ///      那三个常量的注释（取别的值分别报什么错都记在那里）。
    ///      税率、`mktBps` 与 `taxDuration` 照 `docs/spec.zh.md` §6.1 的发射参数填，
    ///      好让这条路径与真实发射同形，而不是「随便凑一组能过的参数」。
    function _params(address vaultFactory, bytes32 salt) internal pure returns (NewTokenV6WithVaultParams memory p) {
        p.name = "Spike Warrant Token";
        p.symbol = "SPIKE";
        p.salt = salt;
        // 原生币不是唯一启用的计价币；这里测 VaultPortal 回调时序，选它无需授权或为发起人备货。
        p.quoteToken = address(0);
        p.quoteAmt = 0;
        p.dexThresh = ForkConfig.FLAP_DEX_THRESH_SUPPORTED;
        p.migratorType = ForkConfig.FLAP_MIGRATOR_TYPE_V2;
        p.dexId = 0;
        p.buyTaxRate = 300;
        p.sellTaxRate = 300;
        p.taxDuration = 3_153_600_000; // 100 年，见 §6.1（⚠️ 不用官方示例的 365 天）
        p.mktBps = 10_000;
        p.tokenVersion = ForkConfig.FLAP_TOKEN_VERSION_TAXED_V3;
        p.vaultFactory = vaultFactory;
    }

    function _mineVanitySalt() internal view returns (bytes32) {
        return _mineVanitySaltFrom(1);
    }

    /// @notice 挖一个能让**预测出来的**代币地址以 `7777` 结尾的 salt。
    ///
    /// @dev 🔴 **推导是实测反解出来的，不是抄的**：
    ///      `predicted = CREATE2(Portal, salt, keccak(EIP-1167(TaxTokenV3Impl)))` ——
    ///      注意部署者是 **Portal**（不是 VaultPortal），且 salt 直接用、不再哈希一层。
    ///      反解办法：拿两组 `(salt, 预测地址)` 样本（`InvalidVanity(address)` 会把预测地址
    ///      原样报出来），对候选部署者 × 候选 salt 变换做穷举比对。样本与复算见
    ///      `docs/research/flap-vault-identity-spike.md` §4。
    ///
    ///      现算而不写死一个 salt：初始化码哈希从**链上当前**的实现地址推出来，Flap 换了实现
    ///      这段会自己跟着变；写死的 salt 会在那天变成一句 `InvalidVanity`，而那时的红灯
    ///      指向的是「salt 过期了」，不是「Flap 换了实现」—— 差一层，排查就要多绕一圈。
    ///
    ///      期望迭代 2^16 次。用汇编在一块固定的 scratch 上算：`abi.encodePacked` 每轮都分配
    ///      一次内存，几十万轮之后是 `MemoryOOG`（实测撞到过），而那是个纯粹的工具问题。
    ///
    ///      🔴 **挖到还要看那个地址空不空。** 低位 salt 早被人用过了 —— `salt = 0x2d76`
    ///      对应的 `0x4ddc…7777` 在本链上已经住着一只代币，发射会撞
    ///      `TokenAlreadyStaged(address)`（`0x524b4af7`）。所以判据里加一条 `extcodesize == 0`：
    ///      少了它，这些文件会随着别人不断占用低位 salt 而慢慢烂掉，
    ///      而红灯说的将是「已被占用」，与它们要证的事情毫无关系。
    function _mineVanitySaltFrom(uint256 seed) internal view returns (bytes32 salt) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", TAX_TOKEN_V3_IMPL, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        address portal = PORTAL;

        assembly {
            let p := mload(0x40)
            mstore8(p, 0xff)
            mstore(add(p, 0x01), shl(96, portal))
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
}
