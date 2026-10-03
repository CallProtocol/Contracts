// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {ClearingPool} from "../src/ClearingPool.sol";
import {MerkleDistributor} from "../src/MerkleDistributor.sol";
import {Warrant} from "../src/Warrant.sol";
import {FactoryStub} from "../test/helpers/FactoryStub.sol";
import {MemeToken} from "../test/helpers/MemeToken.sol";
import {StockToken} from "../test/helpers/StockToken.sol";
import {VaultStub} from "../test/helpers/VaultStub.sol";

/// @title MerkleRoundtrip
/// @notice `script/merkle-roundtrip.test.sh` 的**一次性台子**：在一条本地链上把 issue #66 那条
///         「node 算 root → publisher 上链 → 持有人领取」的通路所需要的全部前置状态摆出来。
///
/// # 它为什么是一个脚本，而不是一个 forge 测试
///
/// 本票要证的那件事，`forge test` 在结构上证不了：merkle 的 root 与 proof 是**链下 node 算的**，
/// 而测试里没有外部命令（本仓库 `ffi` 未开，见 `foundry.toml`）。于是 `test/MerkleDistributor.t.sol`
/// 只能用 `test/helpers/MerkleTree.sol` 自己造一棵树来驱动 `claim` —— 那棵树**不是**官方库的布局
/// （它不排序、奇数层原样上浮），所以它能证明合约的门是对的，却一个字都证明不了
/// 「`offchain/merkle/build-root.js` 吐出来的那个 root 和那些 proof 能被这份合约吃下去」。
///
/// 那句话只有一条路能证：**真的起一条链、真的把 node 算的 root 发上去、真的领一次**。
/// 本文件是那条路上的第一段，判据在 `script/merkle-roundtrip.test.sh` 里。
///
/// # 🔴 它刻意**不** setRoot
///
/// 发布 root 是 `script/publish-root.sh` 的活，而往返测试要测的正是那个脚本。台子先把 root
/// 摆好，往返测试就只能测到「我们自己发的 root 我们自己领得走」——那正是它要避免的循环。
/// 于是这个脚本停在「权证已经铸给 distributor、四个持有人都准备好了、但没有任何归属」这一刻。
///
/// # 替身的边界与 `test/MerkleDistributor.t.sol` 完全一致
///
/// 真的是四合约（注册表 / 权证 / distributor / 清算池），替身只出现在外部依赖那一层
/// （金库、股票代币、MEME、工厂）—— 复用的就是那个测试的 `setUp` 里那批 helper，
/// 不另造一份。造一份新的，就等于让往返测试去证明一套只有它自己用的接线。
///
/// ```bash
/// anvil --port 8547 --silent &
/// forge script script/MerkleRoundtrip.s.sol --rpc-url http://127.0.0.1:8547 \
///   --broadcast --slow --private-key 0xac09…ff80
/// ```
contract MerkleRoundtrip is Script {
    /// @dev anvil 的内置账户。私钥是**公开**的（`anvil` 启动时就打在屏幕上），所以写进版本库
    ///      不是泄密 —— 但它也正因此绝不能碰到任何真链，见 {run} 开头那道 chainid 门。
    ///
    ///      🔴 这里只钉私钥，地址一律用 `vm.addr` 现算。两者都写死的话，它们迟早会漂成
    ///      「日志里打的是 A，而驱动器拿着 B 的钥匙去签」—— 那种失败看起来像 merkle 出了错。
    uint256 internal constant PK_DEPLOYER = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant PK_PUBLISHER = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    /// @dev 四个持有人（anvil #2..#5）。顺序即 `holder0..holder3`，与 {AMOUNTS} 一一对应。
    uint256 internal constant PK_HOLDER_0 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PK_HOLDER_1 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant PK_HOLDER_2 = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant PK_HOLDER_3 = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    /// @dev 与 `test/MerkleDistributor.t.sol` 同一组数：整周铸给 distributor 的量，
    ///      **恰好**等于四张 leaf 之和。
    ///
    ///      🔴「恰好」是承重的：多铸一点，「distributor 的余额兜得住全部未领取份额」这条性质
    ///      就会因为有富余而对错误不敏感 —— 一张多算了份额的 leaf 照样领得走。
    ///      驱动器把这条恒等式又核了一遍（它自己拼清单，抄错一位是可能的）。
    uint256 internal constant MINTED = 100 ether;
    uint128 internal constant STRIKE = 1850e18;

    /// @dev 声明门那两段文本的哈希。本地台子上是什么值不重要，重要的是**四个持有人签的是它**
    ///      —— 行权路径上 `ClearingPool` 查的就是受益人有没有声明过（`attestedVersion != 0`）。
    bytes32 internal constant TERMS_0 = keccak256("TERMS v0");
    bytes32 internal constant ATTESTATION_0 = keccak256("ATTESTATION v0");

    /// @dev 机器可读输出的键宽。见 {_row}。
    uint256 internal constant KEY_WIDTH = 12;

    AttestationRegistry internal registry;
    Warrant internal warrant;
    MerkleDistributor internal distributor;
    ClearingPool internal pool;
    FactoryStub internal factory;
    VaultStub internal vault;
    StockToken internal stock;
    MemeToken internal meme;

    function run() external {
        // 🔴 这条 require 是本文件唯一的安全边界。它部署的是**测试替身**（一只随便谁都能 mint 的
        //    MEME、一只随便谁都能 mint 的股票代币、一个绕开真工厂的身份根写入方），而且用的是
        //    公开私钥。落到任何一条真链上，得到的都是一套长得像我们、却谁都能铸的东西。
        require(block.chainid == 31_337 || block.chainid == 31_338, unicode"只在本地链上跑");

        address publisher = vm.addr(PK_PUBLISHER);
        uint256[4] memory holderKeys = [PK_HOLDER_0, PK_HOLDER_1, PK_HOLDER_2, PK_HOLDER_3];
        uint256[4] memory amounts = [uint256(40 ether), 30 ether, 20 ether, 10 ether];

        // 🔴 份额之和必须恰好等于铸出量，见 {MINTED}。这里算的是**这个文件里的这组数**，
        //    落在编译期常量上；驱动器那边核的是「链上真的铸了这么多」。两处都要。
        uint256 sum;
        for (uint256 i = 0; i < amounts.length; i++) {
            sum += amounts[i];
        }
        require(sum == MINTED, unicode"四份额之和与铸出量对不上 —— 台子自己就不自洽");

        _deploy(publisher);
        _prepareHolders(holderKeys);

        uint64 expiry = uint64(block.timestamp + 7 days);
        (uint256 seriesId, uint256 minted) = _openAndMint(expiry);
        require(minted == MINTED, unicode"实际铸出量与预期不符 —— 股票代币替身不该有税");

        _report(publisher, holderKeys, amounts, seriesId, expiry, minted);
    }

    // ─────────────────────────────── 接线 ───────────────────────────────

    /// @dev 接线顺序与 `test/MerkleDistributor.t.sol::setUp` 逐行一致。
    ///
    ///      两处 `setPool` 的调用方必须是**部署卫星合约的那个地址**（`PoolBound.deployer`），
    ///      所以它们不能挪到别的 broadcast 段里去 —— 这也是整段只有一个 signer 的原因。
    function _deploy(address publisher) private {
        vm.startBroadcast(PK_DEPLOYER);

        registry = new AttestationRegistry(publisher, TERMS_0, ATTESTATION_0);
        warrant = new Warrant();
        distributor = new MerkleDistributor(publisher);
        factory = new FactoryStub();
        pool = new ClearingPool(warrant, address(distributor), registry, factory.registry());
        warrant.setPool(address(pool));
        distributor.setPool(address(pool));

        vault = new VaultStub(pool);
        stock = new StockToken();
        meme = new MemeToken();

        // 身份根里登记这只 MEME 的金库 —— `openSeries` 那道门认的就是这条绑定。
        factory.bind(address(meme), address(vault));

        stock.mint(address(vault), 1e30);
        vault.approve(stock, type(uint256).max);

        vm.stopBroadcast();
    }

    /// @dev §6.4 里前端要引导用户做的那两步，**每个人用自己的钥匙真发一笔** ——
    ///      不是 `vm.prank`。这两笔是行权路径上仅有的两个用户侧前置：
    ///
    ///      | 这一笔 | 少了它会停在哪 |
    ///      |---|---|
    ///      | `registry.attest(0, …)` | `ClearingPool.exercise` 的声明门（查的是**受益人**） |
    ///      | `meme.approve(pool, max)` | MEME 的授权额度 —— 🔴 授权给**清算池**，不是 distributor |
    ///
    ///      MEME 由部署者铸（谁发都行，替身的 `mint` 无许可），但授权只能本人签。
    function _prepareHolders(uint256[4] memory holderKeys) private {
        vm.startBroadcast(PK_DEPLOYER);
        for (uint256 i = 0; i < holderKeys.length; i++) {
            meme.mint(vm.addr(holderKeys[i]), 1e31);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < holderKeys.length; i++) {
            vm.startBroadcast(holderKeys[i]);
            registry.attest(0, TERMS_0, ATTESTATION_0);
            meme.approve(address(pool), type(uint256).max);
            vm.stopBroadcast();
        }
    }

    /// @dev 开系列 + 把整周的权证一次性铸给 distributor —— 这就是「共享余额」的由来。
    ///      `depositAndMint` 之后 distributor 手里有 100 枚权证，而链上**没有任何归属信息**。
    function _openAndMint(uint64 expiry) private returns (uint256 seriesId, uint256 minted) {
        vm.startBroadcast(PK_DEPLOYER);
        seriesId = vault.openSeries(address(meme), address(stock), expiry, STRIKE);
        minted = vault.depositAndMint(seriesId, address(distributor), MINTED);
        vm.stopBroadcast();
    }

    // ─────────────────────────────── 输出 ───────────────────────────────

    /// @dev 机器可读的 `key value` 行，供 `awk '$1 == "distributor" {print $2}'` 取值 ——
    ///      同 `script/DeployAttestationRegistry.s.sol` 与 `script/ci.sh` 的 attestation 组。
    ///
    ///      ⚠️ 这些地址是**模拟阶段**算出来的，不是链上读回来的：`forge script` 的脚本体在
    ///      任何一笔交易发出之前就跑完了（理由整段写在 `script/verify-deployment.sh` 头部）。
    ///      所以驱动器拿到它们之后**逐个回链上核**，而不是当真。
    function _report(
        address publisher,
        uint256[4] memory holderKeys,
        uint256[4] memory amounts,
        uint256 seriesId,
        uint64 expiry,
        uint256 minted
    ) private view {
        _row("distributor", vm.toString(address(distributor)));
        _row("pool", vm.toString(address(pool)));
        _row("warrant", vm.toString(address(warrant)));
        _row("stock", vm.toString(address(stock)));
        _row("meme", vm.toString(address(meme)));
        _row("vault", vm.toString(address(vault)));
        _row("attestations", vm.toString(address(registry)));
        _row("publisher", vm.toString(publisher));
        _row("seriesId", vm.toString(seriesId));
        _row("expiry", vm.toString(uint256(expiry)));
        _row("strike", vm.toString(uint256(STRIKE)));
        for (uint256 i = 0; i < holderKeys.length; i++) {
            _row(string.concat("holder", vm.toString(i)), vm.toString(vm.addr(holderKeys[i])));
            _row(string.concat("amount", vm.toString(i)), vm.toString(amounts[i]));
        }
        _row("minted", vm.toString(minted));
    }

    /// @dev 键左对齐补到 {KEY_WIDTH}，值用一个空格隔开。
    ///
    ///      🔴 键**超宽就 revert**，不截断：截断会得到一个仍然长得像 `key value` 的行，
    ///      而驱动器的 `awk '$1 == "…"'` 会静默取不到值，于是后面每一条断言都对着空串跑。
    function _row(string memory key, string memory value) private pure {
        bytes memory raw = bytes(key);
        require(
            raw.length <= KEY_WIDTH, unicode"输出的键超过了列宽 —— 截断会让驱动器静默取到空值"
        );

        bytes memory padded = new bytes(KEY_WIDTH);
        for (uint256 i = 0; i < KEY_WIDTH; i++) {
            padded[i] = i < raw.length ? raw[i] : bytes1(" ");
        }
        console2.log(string.concat(string(padded), " ", value));
    }
}
