# Warrant Flap Custom Vault 接入与部署

本说明替代旧 D0 Launcher、Flap 前缀新合约和 Pending→activateProject 草稿。
新 BSC 系统使用现有 WarrantVaultFactory / WarrantVault；不可升级。
A（flap.sh）和 B（自有前端）都直接调用官方 VaultPortal 的 newTokenV6WithVault。
创建成功时，Token、Vault、Registry 已绑定且业务权限生效；开系列仍须满足24小时 TWAP 和原有时间条件。

## 固定参数

规范 commit：`5949cc7eb99bcb5ac5f679cc710ae456e627f12a`。
BSC chainId：56。

| 字段 | 值 |
| --- | --- |
| tokenVersion | TOKEN_TAXED_V3，即6 |
| buyTaxRate / sellTaxRate | 各300 bps |
| taxDuration | 3153600000秒 |
| mktBps | 10000 |
| deflationBps / dividendBps / lpBps | 各0 |
| minimumShareBalance | 0 |
| dividendToken | 与quoteToken一致；原生为零地址 |
| commissionReceiver | 读取Factory.commissionReceiver()，不得替换 |
| dexThresh / migratorType / dexId / lpFeeProfile | 1 / 1 / 0 / 0 |
| vaultFactory | 同一个已部署WarrantVaultFactory |
| vaultData | abi.encode(uint16(1))，严格32字节 |

`vaultData = 0x0000000000000000000000000000000000000000000000000000000000000001`。
名称、symbol、meta、salt、extension和首买参数按官方协议组装。
antiFarmerDuration仍由项目提交，官方协议检查不超过一年。
工厂固定100年税期、税率、分配及收益去向，vaultData不能覆盖creator、Pool、Distributor或protocol收款人。
creator只使用官方回调提供的地址；合约不读取tx.origin。

B前端参数示例（viem，ABI见`docs/abi/`）：

```typescript
const params = {
  name, symbol, meta, salt,
  dexThresh: 1, migratorType: 1, dexId: 0, lpFeeProfile: 0,
  quoteToken, quoteAmt, permitData: '0x',
  extensionID: zeroHash, extensionData: '0x',
  buyTaxRate: 300, sellTaxRate: 300, taxDuration: 3153600000n,
  antiFarmerDuration, mktBps: 10000, deflationBps: 0,
  dividendBps: 0, lpBps: 0, minimumShareBalance: 0n,
  dividendToken: quoteToken,
  commissionReceiver: await readContract({address: factory, abi: factoryAbi, functionName: 'commissionReceiver'}),
  tokenVersion: 6, vaultFactory: factory,
  vaultData: encodeAbiParameters([{type: 'uint16'}], [1]),
};
await writeContract({address: vaultPortal, abi: vaultPortalAbi,
  functionName: 'newTokenV6WithVault', args: [params], value});
```

ERC20首买须先向 **VaultPortal** 授权quoteAmt，不是向Vault/Factory/Pool授权。
原生quote为零地址，发送与首买对应的BNB value；固定fork已验证0.1 BNB首买及ERC20 10 GMEB首买。
无首买的原生创建使用1 gwei成功；这仅是固定区块实测，不是永久费用承诺。
UI应按官方当前费用/quote规则估计value，处理钱包拒签、协议revert和退款；退款由官方协议处理。
不要给Factory转BNB，不要用自有wrapper覆盖creator。

以官方`FlapTaxVaultTokenCreated(token,vault,vaultFactory)`和Registry `VaultBound(token,vault)`
识别项目；同一成功交易应两者一致。不再监听旧Launcher事件或展示Pending/激活按钮。

## 资产、权限与会计

`vaultQuoteToken()`表示发币quote，原生为零地址；`collateralToken()`表示Pool接收的ERC20，原生为WBNB。
`collateralDecimals()`返回实际decimals及readable；schema金额均为raw units，不能把所有ERC20标成18位。
Vault每笔实际到账收入确认时立即预留10% protocol fee，固定支付给Factory的`commissionReceiver`，
部署后不可修改。正常完整处理下，每到账100原始单位分为protocol 10、creator 10、Pool 80。
protocol fee的除法余数跨次收入累计，拆分小额入金不能绕过收费；余数本身不可领取。
`processRevenue()`先排除两类已计提储备，按剩余业务资金的1/9请求creator计提，
再按实际Vault扣款确认creator分成；Pool仅按实际抵押品到账铸造权证。
Vault protocol fee、creator分成与TaxProcessor的processor commission分别记账和披露；
protocol fee与processor commission共用固定收款地址，不额外添加模板2% developer fee。
平台是否认可此收费结构尚未确认。

sync、sampleTwap、openSeries、processRevenue、claimCreatorFee、claimProtocolFee均无许可。
`claimProtocolFee()`无需TWAP或开系列，任何人可触发，但没有收款人参数。
原生项目以WBNB支付，ERC20项目以对应collateral支付；返回值及`protocolClaimed`均按实际Vault扣款计量。
扣费代币的10%指Vault承担的资产扣款，接收钱包净到账可能受转账税影响，不由Pool或creator补贴。
零扣款不增加累计领取，部分扣款保留未付储备；转账失败整笔回滚。
协议领取拒绝转账期间的零值quote回调ping及可观察的quote净回流，并原子回滚。
支持的collateral须使转账前后净余额差能代表Vault真实扣款；未发ping、且被扣款抵消的同币回流
无法仅由ERC20余额读数区分，因此不属于支持的转账行为。
若代币额外向发送方扣费，导致protocol领取实际扣款超过该储备，领取整笔回滚；
这类储备可能持续无法领取，直到代币转账行为改变，不会由业务资金或creator储备补贴。
原生收入只在sync/业务支出时懒包装；receive只做有界识别。
包装、Pool支出、费用领取与应急提款只调整余额基线，不能再次计提收入手续费。
`inTransit()`排除creator和protocol储备，并在余额可读时扣除尚未同步收入应计提的protocol fee；
Trigger以此判断收入处理条件，不会把手续费储备送入Pool。
Guardian仅可对Vault调用`emergencyWithdrawNative(to)`、`emergencyWithdrawToken(token,to)`全余额提款。
不能提Pool抵押品、改Registry、creator、root、行权价或收益去向。
余额损失先由未预留业务资金承担，资产不足支持两类储备时按金额比例削减。
creator剩余储备向下取整，protocol储备取剩余支持金额，两类储备总和不超过现存资产。
损失分别永久记入`creatorImpaired`、`protocolImpaired`，未来税收不偿还历史损失。
UI必须分别显示`protocolAccrued`、`protocolClaimed`、`protocolImpaired`，并使用实例collateralDecimals格式化原始金额。
三项分别是当前可支持储备、累计已消耗领取、累计永久受损；不要将受损金额作为未来待支付债权。
对应`ProtocolFeeAccrued`、`ProtocolFeeClaimed`、`ProtocolFeeImpaired`事件提供本次数量及累计金额，
事件名与字段以`docs/abi/WarrantVault.json`为准。
quote提款遇到部分扣款、同币回调入金（含无ping）或异常余额读数会整笔回滚，以避免将新收入用于填补旧损失。
原生提款拒绝Vault自身及canonical wrapper作为接收地址，防止将内部转移/包装误记成提款。

## Trigger

`WarrantTriggerAdapter.schedule(vault,action)`，action 0=sampleTwap、1=openSeries、2=processRevenue。
请求者支付官方TriggerService.getFee()，随调用作为msg.value发送，Vault税收不补贴。
执行时刻链上推导；每个Vault/动作只有一个待处理请求。仅官方服务可trigger(requestId)。
回调重新检查实时条件；安全失效结束请求并记录原因；外部执行revert保留原请求以便重试。
到期两小时后可无许可cancelExpiredRequest。直接调用Vault入口继续可用。
本次不增加自动领取protocol fee的Trigger动作，直接调用`claimProtocolFee()`即可。

## 新部署

`script/DeploySystem.s.sol`只部署全新BSC栈，不接旧Pool或抵押品。
顺序：Registry（写入方是预测Factory）、AttestationRegistry、Warrant、Distributor、Pool、Factory，
两次卫星setPool，再部署TriggerAdapter。Factory地址由广播者nonce+5推导并复算。
Factory构造时创建不可升级WarrantVaultDeployer，固定Factory/Pool/Distributor/Portal/WBNB/protocol收款人，
只有该Factory能调用它，以普通CREATE部署Vault。这是为满足EIP-170而增加的固定依赖，非管理层。
helper构造时将Vault creation code存入两个不可修改的代码数据合约，各块最多16,000字节，
runtime以STOP前缀保存；部署时EXTCODECOPY拼接完整creation code和构造参数后CREATE，失败直接回滚。
两个数据合约由helper创建，不改变广播者nonce+5的Factory地址预测。
CREATE helper部署Vault后，Factory立即Registry.bind；失败整笔回滚。

运行部署模拟需要RPC_BSC归档端点，以及按VersionZero规则钉死BSC定稿法律文本哈希。
实际广播、主网部署和平台发布不在本次任务中。
脚本只输出`deployments/56.planned.json`，不能把模拟清单当成链上权威地址。
manifest包含规范commit、chainId、两个Portal、Guardian、Factory、CREATE helper、两个数据地址与内容哈希、固定protocol收款人、Registry、Pool、
Distributor、Warrant、AttestationRegistry、WBNB、commissionReceiver、TriggerService/Adapter和Factory nonce。
`script/verify-deployment.sh`在同一区块重新检查地址、代码大小、nonce与完整依赖；
成功晋级的清单记录verifiedAtBlock，并以原子写入保留失败前的清单。
继续强制EIP-170 runtime与EIP-3860 initcode限制，不放宽部署门禁。
只有分别补齐flap.sh v2.1的发现/schema/V6组装证据，以及平台对creator 10% + Vault protocol fee 10% + processor commission的认可证据后，才允许--promote。
两项确认必须是布尔true且各自有证据字段，收费认可的`feeAcceptanceScope`须为
`creator10+protocol10+processorCommission`；旧费用范围的认可不能用于晋级。
模拟清单默认platformV21Verified=false、feeAcceptanceVerified=false。

`script/ci.sh deploy`运行离线部署和校验器回归，不广播交易；
`script/ci.sh fork`包含新BSC协议能力、创建收入和部署模拟套件。
完整本次迁移验收可运行`script/flap-vault-spec-check.sh --remote --fork`。

发布仍被平台入口兼容性和收费结构确认阻断；链上测试成功不能替代平台证据。
