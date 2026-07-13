# X410 单机双角色闭环调试进展与后续计划

## 当前状态

主运行脚本：`X410_runSingleHost_DualRole_AARF.m`

辅助调优框架：`x410_tuning_framework.m`

核心解包函数：`HEWLANDataRecovery.m`

最近两轮正确目录下的新版运行结果已经达到直连环回目标：

- `realDecode = 96%`，`meanPER = 0.040`
- `realDecode = 95%`，`meanPER = 0.050`
- 降级控制器版本：`realDecode = 96%`，`CFOoutliers = 10`，`Packet2Success = 10`，`DegradedSuccess = 10`，`CtrlFreeze = 2`
- 平均吞吐约 `73~76 Mbps`
- 中位吞吐最高接近 `87 Mbps`

这说明 X410 直连环回主链路和 HE-SU 解调链路是可用的，当前问题已经从“链路能不能跑通”转向“异常检测样本如何不污染控制器”。

## 已确认的问题

### 1. 主解调链路正常

成功包中观察到：

- `ChanEst mean|h|` 基本稳定在 `1.03~1.04` 附近
- `EVM` 在好包中经常达到 `-35 dB` 到 `-40 dB`
- `MCS 10/11` 可持续解码

因此硬件主链路不是主要瓶颈。

### 2. 前导检测仍有偶发伪峰

日志中仍会出现：

- `CFO outlier rejected`
- `No packet detected`
- `RXTIME of packet 2`

这说明接收端有时先锁到一个伪峰或坏前导，然后跳过该包，在第二个候选包处成功恢复。

### 3. packet 2 成功污染控制器

典型现象：

- recovery 内部跳过 CFO outlier
- 第二个包解码成功
- 但吞吐计算被折半
- 控制器误判链路很差
- 出现 `new MCS = 3/4` 等异常回退

这不是链路真实能力下降，而是控制器把“降级成功样本”当成了普通成功样本。

## 本轮代码改进

### 1. `HEWLANDataRecovery.m` 增加 `recoveryDiag`

新增诊断结构，用于回传内部恢复过程：

- `cfoOutlierCount`
- `noPacketCount`
- `wrongTargetCount`
- `packetDetectFailCount`
- `sigaCrcFailCount`
- `fcsFailCount`
- `ampduDeaggFailCount`
- `lsigFailCount`
- `usedPacketIndex`
- `skippedBeforeSuccess`
- `suspiciousSuccess`

### 2. 主脚本增加 `degradedSuccess`

以下情况会被标记为降级成功：

- 解到 packet 2 或更后面的包
- recovery 内部发生过 CFO outlier skip
- recovery 内部跳过过坏候选包后才成功

降级成功仍记为链路可恢复，但不强训练控制器。

### 3. 控制器更新策略调整

规则变为：

1. packet 1 成功：正常更新控制器。
2. packet 2 成功：记为成功，但降权处理。
3. 内部 CFO outlier 后成功：记为 `degradedSuccess`，不强训练 QLOLLA。
4. 真正失败才作为失败输入：`pkt_detect`、`FCS`、`HE-SIG-A`、`wrong_target`。

### 4. 连续异常冻结控制器

新增保护逻辑：

- 连续 hard fail 或连续 degraded success 会触发短暂冻结
- 冻结时保持原 `MCS / AMPDU / BWdec`
- 防止控制器被异常样本拉到 MCS 3/4

### 5. 多参数调优框架接入

`x410_tuning_framework.m` 已经接入主循环，每轮记录：

- `MCS`
- `AMPDU`
- `BWdec`
- `TxPowerDb`
- `PER`
- `ThroughputMbps`
- `Success`
- `DegradedSuccess`

框架当前采用保守策略：

- PER 高于目标时降低 MCS/AMPDU，适当提高发射功率
- PER 低且吞吐不足时逐步提高 MCS/AMPDU
- 后续可以替换为 Q-learning / Bayesian optimization / CSI-aware 策略

## 新增日志指标

新版结尾会输出：

```text
StatsDiag | CFOoutliers=..., NoPkt=..., WrongTarget=..., PacketDetectFail=..., HESIGACRC=..., FCSFail=..., Packet2Success=..., DegradedSuccess=..., CtrlFreeze=...
```

重点观察：

- `Packet2Success` 是否仍然多
- `DegradedSuccess` 是否下降
- `CtrlFreeze` 是否频繁触发
- `MCS` 是否还被异常拉到 3/4
- `realDecode` 是否保持 `>= 90%`

## 后续计划

### 阶段 1：稳定控制器

目标：

- `realDecode >= 95%`
- `MCS` 不再被 packet 2 成功拉到 3/4
- `Packet2Success` 与 `DegradedSuccess` 明确统计

措施：

- 继续优化 degradedSuccess 的降权规则
- 调整 controller freeze 长度
- 区分 packet 2 成功与真正失败

### 阶段 2：减少伪峰和 packet 2

目标：

- 降低 `CFOoutliers`
- 降低 `Packet2Success`
- 降低 `pkt_detect` 失败

措施：

- 优化 `searchOffset`
- 调整 `roleSliceGuardMs`
- 增加 capture 边界保护
- 继续排查连续模式伪峰来源

### 阶段 3：多参数联合调优

目标：

- 在 `PER <= 5%` 前提下提高吞吐
- 优化 `MCS / AMPDU / TxPower / BWdec`

候选策略：

1. 保守规则策略：当前已接入。
2. Q-learning：基于 PER/throughput 状态更新动作。
3. CSI-aware：结合 `ChanEst`、EVM、SNR 判断是否提高 MCS 或 AMPDU。
4. 分阶段策略：先稳 packet 1 成功率，再提升 AMPDU 和带宽。

### 阶段 4：迁移到真实链路

条件：

- 环回 `realDecode >= 95%`
- `Packet2Success` 明显降低
- `FCSFail` 接近 0
- 控制器不再异常降 MCS

迁移后重点观察：

- 真实信道下 EVM/SNR 波动
- TxPower 对 PER 的影响
- AMPDU 对 packet detect 和 FCS 的影响
- 是否需要更长的保护间隔

## 当前建议运行方式

确保运行的是正确目录：

```matlab
run('C:\Users\welcome\Desktop\X410_CombinedTxRx_XL - 副本 - 副本\X410_runSingleHost_DualRole_AARF.m')
```

日志路径应包含：

```text
X410_CombinedTxRx_XL - 副本 - 副本
```

否则说明跑到了旧目录。
