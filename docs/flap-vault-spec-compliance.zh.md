# Flap Custom Vault checker 证据报告

规范和checker固定为官方commit `5949cc7eb99bcb5ac5f679cc710ae456e627f12a`。
本报告替代旧版「工厂/金库不再继承Flap，规则无对象」结论。
执行入口：`script/flap-vault-spec-check.sh --fork`；追加`--remote`核验上游逐字节一致性。

| 规则 | 结论与证据 | 适用性/限制 |
| --- | --- | --- |
| Rule001 | Vault直接继承VaultBaseV3/V2；不可升级；仅Guardian可全余额应急提款；Vault权限/重入测试 | Factory onlyVaultPortal是协议回调身份门，Guardian不能绕过创建。没有可撤销角色 |
| Rule002 | Factory继承VaultFactoryBaseV2，strict vaultData/schema、官方V6钩子校验及原子绑定测试；protocol收款人固定为commissionReceiver | WARNING：creator10% + Vault protocol fee10% + processor commission分别披露；未采用额外模板2%，平台接受性未确认 |
| Rule003 | Pool/Distributor/creator/quote与策略固定；24小时TWAP、小时心跳、缺口/过期与0.8折让回归 | Guardian可提款Vault收入，属于明确应急托管风险；不能提款Pool或改策略。未声称消除所有公开调用时机风险 |
| Rule004 | 自有Vault/Factory/Adapter用户错误为双语literal；schema方法说明与实际ABI遍历通过 | WARNING：官方基类/OZ错误逐字保留；Registry/Pool基础设施custom errors保留，接入方须使用ABI解码 |
| Rule005 | receive仅有界收入识别；余额staticcall≤200k；hostile余额读取/零ping/原生与包装gas回归 | 有界静态读取是Rule010所需，按Rule005的bounded exception评估；不在receive包装、转账或调用Pool |
| Rule006 | WarrantSchemaTest遍历35个真实暴露方法，核对输入/输出/写标志/approvals；protocol固定收款人、三项原始单位会计状态和无收款人参数领取入口纳入schema | flap.sh页面及后台真实触发未测试，不能将链上fork当成平台PASS；本次验证结果须以重新运行的测试输出为准 |
| Rule007 | N/A | 无AI oracle |
| Rule008 | 单Vault/动作请求、费用归请求者、官方sender、防重放、延迟/失效/清理/外部revert重试测试；生产Vault+Pool与最坏gas-burning action≤2M | 回调动作gas上限1.4M、仅复制固定返回数据；真实服务请求/费用+live Vault回调独立fork测量。后台角色实际交付未验 |
| Rule009 | 官方两种全余额接口/事件；onlyGuardian/共用锁；转账失败、回调入金、部分扣款及两类储备同比例impairment | 无auto-forward、amount/owner权限。quote提款歧义路径原子拒绝，native内部转移/wrapper目标拒绝；Pool抵押品不受影响 |
| Rule010 | quote/collateral分离；native两基线懒包装；6/8/18 decimals与实际Vault扣款/Pool到账；protocol收入确认时预留10%，creator按成功处理计提，完整处理80/10/10 | 两类损失永久且未来不补偿；除法余数跨收入累计；inTransit排除两类储备及可读未同步收入费用；protocol领取按Vault扣款、净到账可受转账税影响；领取拒绝quote ping/净回流及超储备发送方额外费用。未ping且被扣款抵消的同币回流不属于支持的转账行为 |

## 上游差异

同commit的checker `references/prelude`比`src/flap`旧：prelude地址表只支持56/97，
缺Robinhood及默认Portal/VaultPortal/Guardian地址；factory也缺新校验与发现接口。
本实现按固定commit的src/flap逐字复制，不混用prelude，不修改官方基类错误。
checker正文要求金额18位但Rule010和真实ERC20多decimals要求正确资产量纲，
本项目按用户要求显示raw units（schema decimals0），另有实例collateralDecimals()。
checker的Guardian所有权限泛化不用于Factory创建/Registry绑定门，否则会突破官方回调身份。

## 关键实现取舍

Factory不能把完整Vault initcode嵌入自身runtime而超过EIP-170；因此增加固定不可升级
WarrantVaultDeployer，由Factory构造时普通CREATE，只有该Factory能调用。
helper的所有业务依赖immutable，protocol收款人固定为既有commissionReceiver，不能选择资金去向或替换实现；Registry仍只有Factory写入。
它不是新管理员，也不是代理。部署与runtime大小回归同时检查Factory/Vault/helper。
helper构造时创建两个带STOP前缀的不可修改代码数据合约，每块最多16000字节；
部署Vault时用EXTCODECOPY拼接creation code与构造参数后普通CREATE，失败原子回滚。
数据地址和内容哈希纳入manifest与校验，不改变广播者Factory nonce预测。
Factory/Vault/helper与数据合约继续验证EIP-170，initcode继续验证EIP-3860。

Guardian quote提款先记录失去支持的两类储备，避免回调新收入填补旧损失。
全余额请求后若还有quote余额，无法区分部分扣款与新入金，整笔回滚。
零值ping重入亦拒绝；native回调的新入金在提款后识别一次。

## 发布门槛

链上固定区块证据见`research/flap-custom-vault-capabilities.md`与`evidence/flap-custom-vault/`。
flap.sh v2.1工厂发现、schema展示和V6参数组装 **UNVERIFIED**；creator10% + Vault protocol fee10% + processor commission收费结构平台接受性 **UNVERIFIED**。
默认manifest为planned，platformV21Verified=false、feeAcceptanceVerified=false；两项均须独立证据后才能promote。不得将这些项标记PASS或发布。
本次没有主网广播、平台登记、上线旧池或迁移旧抵押品。
