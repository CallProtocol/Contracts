// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PoolBound
/// @notice 卫星合约（`Warrant` / `MerkleDistributor`）指向 `ClearingPool` 的**一次性**绑定槽：
///         仅部署者可写、只能写一次、写后永久锁死。
///
/// # 为什么这个槽长在卫星上，而不长在池子上
///
/// 接口冻结之后这是一个三方构造环 —— `Warrant → pool`、`MerkleDistributor → pool`、
/// `pool → {warrant, distributor, attestations}`，而**靠排序解不开**：CREATE2 的地址由 init code
/// 推导，init code 又含构造参数，所以当池子的构造参数依赖池子自身地址时，它的地址无法预计算。
///
/// 解法是把「可写一次」的槽放在**卫星**上：信任集中在池子，于是池子的三个地址保持真 `immutable`，
/// 部署之后不存在任何写入路径。**信任集中在哪里，不可变性就留在哪里。**
/// 代价是 `pool` 从 immutable 变成一次 storage 读（每次调用多几百 gas）—— 换掉的是整个 CREATE2 环节。
///
/// 已否决的备选是 Uniswap V3 那套（池子构造函数留空、回读 `IDeployer(msg.sender).parameters()`）：
/// 同样的结果、更多活动部件，而且仍然依赖 CREATE2。
///
/// # 未绑定的合约是惰性的，不是敞开的
///
/// 绑定前 `pool == address(0)`，而 `onlyPool` 在这种状态下**显式拒绝**——不是靠
/// 「`msg.sender` 不可能等于零地址」这条关于链的假设。零地址在这里身兼两职：既是「尚未绑定」的
/// 哨兵值，又是一个能出现在 `msg.sender` 位置的取值；只比较 `msg.sender != pool` 的话，
/// 这两个身份在未绑定期间会撞成同一个值。见 `onlyPool` 的注释与
/// `test/PoolBound.t.sol::test_unbound_zeroSenderIsRejectedToo`。
///
/// 于是部署与绑定之间的那段窗口里，没有任何调用者能铸造或销毁权证。这条性质由测试直接驱动，不靠推理。
///
/// @dev 见 `docs/spec.zh.md` §5.3 / §12 与 issue #8。
abstract contract PoolBound {
    /// @notice 绑定的 `ClearingPool`。`address(0)` 表示**尚未绑定**。
    /// @dev 🔴 本合约**没有**任何别的写入路径 —— `setPool` 是唯一一处，且带 `pool == address(0)` 前置。
    address public pool;

    /// @notice 唯一有权绑定的地址：部署本合约的那一个。
    /// @dev `spec.zh.md` §5.3 的草图里它是 `private`。这里做成 `public`，因为 §12 要求部署完当场核验
    ///      两处绑定 —— 核验的人不该只能靠翻构造交易的 calldata 才知道「谁本来有权绑」。
    address public immutable deployer;

    /// @notice 绑定完成。全生命周期至多出现一次。
    event Bound(address indexed pool);

    error NotDeployer(address caller);
    error AlreadyBound(address pool);
    error ZeroPool();
    error PoolHasNoCode(address pool);
    error NotPool(address caller);

    /// @dev 未绑定时**显式拒绝**，而不是靠「`msg.sender` 不可能等于 `address(0)`」。
    ///
    ///      🔴 `address(0)` 在这里身兼两职：它是「尚未绑定」的哨兵值，也是一个能出现在
    ///      `msg.sender` 位置的取值。只写 `msg.sender != pool` 的话，这两个身份会在未绑定期间
    ///      **撞成同一个值** —— 零地址调用者恰好通过授权判据，`mint(非零收款方, …)` 会真的铸出权证
    ///      （ERC-1155 只拦零**收款方**，拦不住零**调用方**）。已由
    ///      `test/PoolBound.t.sol::test_unbound_zeroSenderIsRejectedToo` 钉住。
    ///
    ///      这条零地址调用在今天的以太坊上极难构造（没有那个私钥，合约也不可能部署在零地址），
    ///      但那是一条关于**链**的假设，不是关于**本合约**的性质。目标链是 Arbitrum Orbit L2，
    ///      系统交易的发起方语义由链定义且我们改不了；而卫星合约绑定之后这道门永久不可变。
    ///      把「未绑定就拒绝」写成结构，比把它寄存在一条外部假设上便宜得多 —— 代价是一次比较。
    modifier onlyPool() {
        address boundPool = pool;
        if (boundPool == address(0) || msg.sender != boundPool) revert NotPool(msg.sender);
        _;
    }

    constructor() {
        deployer = msg.sender;
    }

    /// @notice 绑定清算池。**仅部署者、仅一次、写后永久锁死。**
    ///
    /// @dev 四道检查各挡一件事，顺序是刻意的：
    ///      ① 非部署者 —— 抢跑。任何人都能看到卫星合约已部署但未绑定，抢先绑到自己的合约上，
    ///         就等于拿到无限铸造权；
    ///      ② 已绑定 —— 重绑。这是本函数存在的全部理由，`AlreadyBound` 把现值一并报出来，
    ///         好让运维当场看出「已经绑给谁了」；
    ///      ③ 零地址 —— 它是「未绑定」这个状态的哨兵值。写进去等于什么都没做，却会让
    ///         「`pool != address(0)` ⟹ 已锁死」这个判据失真，于是显式拒绝；
    ///      ④ 无字节码 —— 打错地址（EOA、或者尚未部署的预计算地址）。绑定必须发生在池子部署**之后**，
    ///         所以真实流程里这一条永远不会命中；命中就说明地址错了，而这一步只有一次机会。
    ///
    ///      被拒的调用不留痕迹，可以改对了再来 —— 锁死的是**成功**的那一次。
    function setPool(address p) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        if (pool != address(0)) revert AlreadyBound(pool);
        if (p == address(0)) revert ZeroPool();
        if (p.code.length == 0) revert PoolHasNoCode(p);

        pool = p;
        emit Bound(p);
    }
}
