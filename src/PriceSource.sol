// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDexPair, IFlapPortalLens} from "./interfaces/IFlapPortalLens.sol";

/// @title PriceSource
/// @notice 「**1e18 raw 单位股票代币值多少 raw MEME**」这一个读数，两个价格来源，一个失败码集合。
///
/// # 🔴 量纲：Flap 给的是**倒数**，不是我们要的那个数
///
/// 这是本票最容易出错、也最贵的一处，所以写在最前面。
///
/// Flap 的 `Portal.getTokenV8Safe(meme).price` 上游原文是
/// *"price (wei) of a token (1e18)"* —— 即 **1e18 raw MEME 值多少 raw 计价币**。
/// 而金库的 MEME 是**以股票代币计价**发射的（`vaultQuoteToken()` 必须等于所服务代币的计价币，
/// 见 `src/flap/VaultBaseV3.sol` 的实现须知 2），于是：
///
/// | | 谁的价格 | 用谁计价 |
/// |---|---|---|
/// | Flap 给的 `price` | MEME | 股票代币 |
/// | 我们要的 `strike` 同量纲读数 | **股票代币** | **MEME** |
///
/// 两者互为倒数。直接把 `price` 存进环形缓冲，得到的 strike 会**离谱到无法与真值混淆**
/// （量级差 10³⁰ 上下），但那不是安全性来源 —— 安全性来源是这里把反演写清楚并测掉：
///
/// ```
/// 1e18 MEME_raw  = price       股票_raw
/// 1    股票_raw   = 1e18/price MEME_raw
/// 1e18 股票_raw   = 1e36/price MEME_raw   ← 本库返回的就是它
/// ```
///
/// # 🔴 为什么在**采样时**反演，而不是读数时
///
/// 时间加权平均**不与取倒数交换**：算术平均的倒数是调和平均，两者不等（AM–HM）。
/// 也就是说「先存 Flap 的价、平均完再取倒数」与「先取倒数、再平均」是**两个不同的 strike**。
/// 二者都能自圆其说，所以这是一处必须定死的选择，理由有二：
///
/// 1. **票面口径**：环形缓冲的 `price` 被定义为「1 单位 stock 值多少 MEME」，与
///    `ClearingPool.Series.strike` 同量纲（issue #34 验收第 1 条）。在采样时反演，
///    M2-4 拿到的读数就**不需要再做任何换算** —— 少一次换算就少一处量纲事故；
/// 2. **偏向**：AM ≥ HM，所以本口径给出的 strike **不低于**另一口径。strike 偏高
///    = 行权要烧更多 MEME = 对金库与 MEME 持有人保守。两个口径都合理时，取保守的那个。
///
/// 反演的精度损失可以忽略：相对截断误差 ≤ `price / 1e36`，而 `price` 在真实曲线上是 1e9 量级
/// （实测见 `docs/research/flap-portal-price-semantics.md`），即 ~1e-27。
///
/// # 两个分支与切换条件
///
/// | Flap `status` | 分支 | 价格怎么来 |
/// |---|---|---|
/// | `1` Tradable（联合曲线上） | 曲线 | `1e36 / price` |
/// | `4` DEX（已毕业） | 池子 | `memeReserve * 1e18 / quoteReserve` |
/// | `0` Invalid · `2` InDuel · `3` Killed · `5` Staged | —— | 拒绝，{NOT_PRICEABLE} |
///
/// 🔴 **切换条件不是我们挑的，是 Flap 逼出来的**：毕业之后 `price` 字段**恒为 `0`**
/// （实测，见 `docs/research/flap-portal-price-semantics.md` §3）。所以「毕业后继续读曲线价」
/// 不是「精度差一点」，是**读到零**。反过来也一样：没毕业时 `pool` 是零地址，没有池子可读。
/// 两个分支各自只在自己的状态里有定义，没有重叠区，也没有真空。
///
/// # 一律不 revert
///
/// 每一条失败路径都返回一个**状态码**，而不是抛出去。理由是调用方 {WarrantVault.sampleTwap}
/// 要把失败变成一条链下可告警的事件（`docs/spec.zh.md` §9：样本缺失会影响 strike），
/// 而不是让 keeper 的交易红掉 —— keeper 一笔交易里可能扫很多金库，一个金库的坏消息
/// 不该连坐其余的。`Portal` 在代币不存在时是**真的会 revert** 的（`TokenNotFound(address)`，
/// 实测 `0xde6137d1`），所以这里必须走低层 `staticcall`。
library PriceSource {
    /// @notice 读数可用。
    uint8 internal constant OK = 0;
    /// @notice Portal 读不出来：revert（含 `TokenNotFound`）、返回数据不足、或烧光了限额 gas。
    uint8 internal constant PORTAL_UNREADABLE = 1;
    /// @notice 🔴 Flap 记的计价币不是本金库的收入币种 —— `price` 的分母不是我们的股票，读数作废。
    uint8 internal constant QUOTE_MISMATCH = 2;
    /// @notice 代币既不在曲线上也没毕业（Invalid / InDuel / Killed / Staged）。
    uint8 internal constant NOT_PRICEABLE = 3;
    /// @notice 曲线阶段却报了一个用不了的价（`0`，或反演之后归零）。
    uint8 internal constant CURVE_PRICE_INVALID = 4;
    /// @notice 池子读不出来，或它答的储备越出了 `uint112` —— 那就不是一个 V2 形状的配对。
    uint8 internal constant POOL_UNREADABLE = 5;
    /// @notice 池子的两条腿不是 (MEME, 股票代币)。
    uint8 internal constant POOL_MISMATCH = 6;
    /// @notice 池子有形状但没有货，价格无定义。
    uint8 internal constant POOL_EMPTY = 7;
    /// @notice 算出来的价装不进 `uint192`（环形缓冲的槽宽）。
    uint8 internal constant PRICE_OUT_OF_RANGE = 8;
    /// @notice 池子的储备在当前块刚更新过，不能把可被同块操纵的现货价采进来。
    uint8 internal constant POOL_UPDATED_THIS_BLOCK = 9;

    /// @notice 没取到价，所以没有来源。
    uint8 internal constant SOURCE_NONE = 0;
    /// @notice 这一条读自**联合曲线**。
    uint8 internal constant SOURCE_CURVE = 1;
    /// @notice 这一条读自**毕业后的 DEX 池**。
    ///
    /// @dev 🔴 把来源一起发进事件，是因为「这个项目什么时候从曲线切到池子」是一次**只发生一次、
    ///      且改变信任模型**的转变：曲线价来自 Flap 的一条纯函数，池价来自一个任何人都能加/撤流动性的
    ///      配对。链下要能一眼看出某条样本是哪边来的，而不是靠事后再去问一次 Portal
    ///      （那时状态已经变了，问不出当时的答案）。
    uint8 internal constant SOURCE_POOL = 2;

    /// @dev Flap `status` 的两个我们认的取值。其余一律 {NOT_PRICEABLE}。
    uint256 private constant STATUS_TRADABLE = 1;
    uint256 private constant STATUS_DEX = 4;

    /// @dev `TokenStateV8Safe` 是 18 个**静态**字，所以返回值就是它们平铺 576 字节。
    ///
    ///      🔴 只收这 576 字节、不用 `abi.decode`，两个理由：
    ///      ① `(bool, bytes memory) = addr.staticcall(…)` 会把**整个** returndata 复制进我们的内存，
    ///         那份内存扩张由我们付账且不在限额 gas 之内（与 `WarrantVault._quoteBalance` 同一处坑）；
    ///      ② `abi.decode` 解 `bool` / `uint8` 字段时，遇到**非规范编码**（高位有脏字节）会 revert，
    ///         而本库的全部承诺就是不 revert。按下标取字则完全不受影响。
    ///
    ///      下标与 {IFlapPortalLens.TokenStateV8Safe} 的字段顺序一一对应；写错了不会编译失败，
    ///      所以 `test/PriceSource.t.sol` 用一个按 struct **正规编码**的替身来交叉核对下标。
    uint256 private constant STATE_BYTES = 18 * 32;
    uint256 private constant W_STATUS = 0;
    uint256 private constant W_PRICE = 3;
    uint256 private constant W_QUOTE_TOKEN = 9;
    uint256 private constant W_POOL = 14;

    /// @dev 转发给 Portal 镜头的 gas 上限。
    ///
    ///      Portal 是 Flap 可升级的代理，它一次读要花多少 gas 不由我们决定；不封顶就等于把
    ///      「采样会不会把 keeper 的整笔交易烧干」交给别人的实现决定。50 万远大于实测开销
    ///      （真实 Portal 上的实际值由 `test/fork/RobinhoodTwapSource.t.sol` 打印并断言留有余量）。
    uint256 private constant PORTAL_READ_GAS = 500_000;

    /// @dev 转发给 DEX 配对的 gas 上限。三次读都是纯 storage，10 万绰绰有余。
    uint256 private constant POOL_READ_GAS = 100_000;

    /// @notice 当前的「1e18 raw 股票代币值多少 raw MEME」。
    ///
    /// @param portal      本链的 Flap `Portal`（金库从 `VaultBase._getPortal()` 拿）
    /// @param memeToken   本金库服务的那只 MEME
    /// @param quoteToken  本金库的收入币种 = 绑定的股票代币
    ///
    /// @return status       {OK} 或某一条失败码；非 {OK} 时 `memePerStock` 恒为 `0`
    /// @return memePerStock 1e18 raw 股票代币折合多少 raw MEME（与 `ClearingPool.Series.strike` 同量纲）
    /// @return source       {SOURCE_CURVE} / {SOURCE_POOL}；非 {OK} 时为 {SOURCE_NONE}
    /// @param wrapsNative 本项目是否**原生 BNB 计价**（C2，研究文档 §7.14）。为真时曲线阶段 Flap
    ///                    报 `quoteTokenAddress = address(0)`，而金库的 `quoteToken` 是 WBNB ——
    ///                    二者 1:1、同 18 位、price 数值一致，所以额外接受 `f[1] == 0`。毕业后池腿
    ///                    是 WBNB，`f[1]` 直接等于 WBNB，无需特判。
    function spot(address portal, address memeToken, address quoteToken, bool wrapsNative)
        internal
        view
        returns (uint8 status, uint256 memePerStock, uint8 source)
    {
        (bool readable, uint256[4] memory f) = _readState(portal, memeToken);
        if (!readable) return (PORTAL_UNREADABLE, 0, SOURCE_NONE);

        // 🔴 先对账计价币，再谈价格。整条比较落在**整个字**上而不是截断成 address：
        //    高位有脏字节时 `address(uint160(word))` 会静默把它们丢掉，而我们要的正是「不一致就停」。
        //    原生档额外放行 `f[1] == 0`（曲线阶段 Flap 报 address(0)，与金库的 WBNB 数值等价）。
        if (f[1] != uint256(uint160(quoteToken)) && !(wrapsNative && f[1] == 0)) {
            return (QUOTE_MISMATCH, 0, SOURCE_NONE);
        }

        if (f[0] == STATUS_TRADABLE) return _fromCurve(f[2]);
        if (f[0] == STATUS_DEX) {
            // `pool` 也是 ABI 中的 address。不能相信高 96 位已经是零：低层读取会原样得到那个字，
            // 截断会把畸形 Portal 响应静默导向一只真实的池子。
            if (f[3] > type(uint160).max) return (PORTAL_UNREADABLE, 0, SOURCE_NONE);
            return _fromPool(address(uint160(f[3])), memeToken, quoteToken);
        }
        return (NOT_PRICEABLE, 0, SOURCE_NONE);
    }

    /// @dev 曲线阶段：把 Flap 的 `price` 反演过来。见本库顶部的量纲推导。
    function _fromCurve(uint256 flapPrice) private pure returns (uint8, uint256, uint8) {
        if (flapPrice == 0) return (CURVE_PRICE_INVALID, 0, SOURCE_NONE);

        // `flapPrice` 非零 ⟹ 商 ≤ 1e36，永远装得进 uint192（上限约 6.28e57）；
        // 商为 0 只可能因为 `flapPrice > 1e36`，那是一只 MEME 比 1e18 份股票还贵 10^18 倍 ——
        // 真出现了也读不出有意义的 strike，明确拒掉。
        uint256 memePerStock = 1e36 / flapPrice;
        if (memePerStock == 0) return (CURVE_PRICE_INVALID, 0, SOURCE_NONE);
        return (OK, memePerStock, SOURCE_CURVE);
    }

    /// @dev 毕业之后：读 V2 配对的两条腿。
    ///
    ///      🔴 `token0()` 与 `token1()` **两个都读**，不是读一个再假定另一个。配对里出现我们不认识的
    ///      代币时要的是「停下来」，而不是「把它当成股票」—— 后者会用一个完全不相干的储备算出
    ///      一个**看起来正常**的价，然后被写进环形缓冲。
    function _fromPool(address pool, address memeToken, address quoteToken)
        private
        view
        returns (uint8, uint256, uint8)
    {
        if (pool == address(0)) return (POOL_UNREADABLE, 0, SOURCE_NONE);

        (bool ok0, uint256 token0) = _readWord(pool, abi.encodeCall(IDexPair.token0, ()));
        (bool ok1, uint256 token1) = _readWord(pool, abi.encodeCall(IDexPair.token1, ()));
        if (!ok0 || !ok1) return (POOL_UNREADABLE, 0, SOURCE_NONE);

        (bool okR, uint256[3] memory reserves) = _readReserves(pool);
        if (!okR) return (POOL_UNREADABLE, 0, SOURCE_NONE);
        // `getReserves()` 的前两个返回值是 `uint112`，第三个是 `uint32`。越界只可能来自一个
        // 不守 ABI 的对手方；前两字会让下面的乘法溢出，第三字则不能拿来判断同块更新。两种情形
        // 都不能让本库 revert 或把坏数据当成价格。
        if (reserves[0] > type(uint112).max || reserves[1] > type(uint112).max || reserves[2] > type(uint32).max) {
            return (POOL_UNREADABLE, 0, SOURCE_NONE);
        }

        // V2 把最后一次储备更新的时间记为 `uint32`。同一块里刚变过储备的现货价可被操纵，
        // 所以宁可缺样也不采它；比较前已验证第三字是规范的 `uint32`。
        if (reserves[2] == uint256(uint32(block.timestamp))) return (POOL_UPDATED_THIS_BLOCK, 0, SOURCE_NONE);

        uint256 meme = uint256(uint160(memeToken));
        uint256 quote = uint256(uint160(quoteToken));

        uint256 memeReserve;
        uint256 quoteReserve;
        if (token0 == meme && token1 == quote) {
            (memeReserve, quoteReserve) = (reserves[0], reserves[1]);
        } else if (token0 == quote && token1 == meme) {
            (memeReserve, quoteReserve) = (reserves[1], reserves[0]);
        } else {
            return (POOL_MISMATCH, 0, SOURCE_NONE);
        }

        if (memeReserve == 0 || quoteReserve == 0) return (POOL_EMPTY, 0, SOURCE_NONE);

        // 直接按目标量纲算，而不是「先算 MEME 的价再取倒数」—— 少一次取整，也少一次量纲翻转。
        // 上界：uint112 最大约 5.19e33，乘 1e18 = 5.19e51，离 uint256 还很远。
        uint256 memePerStock = (memeReserve * 1e18) / quoteReserve;
        if (memePerStock == 0) return (POOL_EMPTY, 0, SOURCE_NONE);
        if (memePerStock > type(uint192).max) return (PRICE_OUT_OF_RANGE, 0, SOURCE_NONE);
        return (OK, memePerStock, SOURCE_POOL);
    }

    /// @dev 读 Portal 镜头，取出我们依赖的四个字：`[status, quoteTokenAddress, price, pool]`。
    ///      返回值刻意按**用途**排序而不是按 ABI 下标排序，好让调用点读起来是一句话。
    function _readState(address portal, address token) private view returns (bool readable, uint256[4] memory f) {
        if (portal.code.length == 0) return (false, f);

        bytes memory callData = abi.encodeCall(IFlapPortalLens.getTokenV8Safe, (token));
        bytes memory buffer = new bytes(STATE_BYTES);

        bool ok;
        uint256 returned;
        assembly ("memory-safe") {
            ok := staticcall(
                PORTAL_READ_GAS,
                portal,
                add(callData, 0x20),
                mload(callData),
                add(buffer, 0x20),
                STATE_BYTES
            )
            returned := returndatasize()
        }
        // 🔴 **恰好** 576 字节，不是「至少」。静态 struct 的 ABI 编码长度是确定的，
        //    多一个字就说明对面返回的不是我们以为的那个形状 —— 那时按下标取字读到的是什么，
        //    没人知道。多出来的那种情况并不假想：`Flood` 那一档返回的正是一大片零，
        //    它在「至少」的判据下会一路走到「计价币对不上」，而真正的病因是形状不对。
        if (!ok || returned != STATE_BYTES) return (false, f);

        assembly ("memory-safe") {
            let head := add(buffer, 0x20)
            mstore(f, mload(add(head, mul(W_STATUS, 0x20))))
            mstore(add(f, 0x20), mload(add(head, mul(W_QUOTE_TOKEN, 0x20))))
            mstore(add(f, 0x40), mload(add(head, mul(W_PRICE, 0x20))))
            mstore(add(f, 0x60), mload(add(head, mul(W_POOL, 0x20))))
        }
        readable = true;
    }

    /// @dev 一次只收 32 字节的限额 `staticcall`。收款区用 scratch space（0x00–0x3f），
    ///      不动自由内存指针，因此是 memory-safe 的。
    function _readWord(address target, bytes memory callData) private view returns (bool ok, uint256 word) {
        uint256 returned;
        assembly ("memory-safe") {
            ok := staticcall(POOL_READ_GAS, target, add(callData, 0x20), mload(callData), 0x00, 0x20)
            returned := returndatasize()
            word := mload(0x00)
        }
        if (!ok || returned != 32) return (false, 0);
    }

    /// @dev `getReserves()` 是三个字，超出 scratch space，所以单独一条。
    function _readReserves(address pool) private view returns (bool ok, uint256[3] memory reserves) {
        bytes memory callData = abi.encodeCall(IDexPair.getReserves, ());
        uint256 returned;
        bool success;
        assembly ("memory-safe") {
            success := staticcall(POOL_READ_GAS, pool, add(callData, 0x20), mload(callData), reserves, 0x60)
            returned := returndatasize()
        }
        if (!success || returned != 0x60) return (false, reserves);
        ok = true;
    }
}
