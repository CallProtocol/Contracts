# 当前合约业务规范

当前合约栈使用官方 VaultPortal v2.1 和不可修改的 WarrantVaultFactory 创建项目，由
Factory 写入 VaultRegistry 身份绑定。旧 Launcher 架构的说明已归档。

Vault 按实际确认收入固定预留 10% protocol fee，跨次收入累积取整余数；收款人为部署时
固定的 commissionReceiver。creator 仍在业务收入成功处理后计提。完整处理下每到账 100
分配 Pool 80、creator 10、protocol 10。任何人可触发官方领取，不能改变收款人。原生项目
支付 WBNB，ERC20 项目支付对应 collateral；计提、领取和 impairment 均按资产原始单位记录。

领取按 Vault 实际扣款确认，转账税不由 Pool 或 creator 补贴。两类已计提储备按比例承担
永久资产损失，未来收入不补偿旧损失；inTransit 和 Trigger 业务可用性均排除两类储备。
Pool 按实际抵押品到账铸造；已进入 Pool 的资产不属于 Vault 的费用储备或 Guardian 提款。

完整参数、事件、接口和边界规则见 [Custom Vault 接入说明](flap-custom-vault.zh.md)、
[Rule001–010 报告](flap-vault-spec-compliance.zh.md) 和 [接口包说明](interfaces.md)。
合约测试和固定 BSC fork 测试提供可执行业务断言。legal/attestation-v0 的原文保持不变。

历史综合仓库规范和运维文档保存在 archive/d0-legacy/，不可作为当前部署操作依据。
平台 v2.1 接入验证及 creator 10% + protocol 10% + processor commission 收费认可仍阻断发布。
