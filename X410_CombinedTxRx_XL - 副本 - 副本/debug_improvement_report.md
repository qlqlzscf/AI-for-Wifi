# X410 单机双角色链路调试与改进说明

本文档梳理 `X410_CombinedTxRx_XL - 副本 - 副本` 中当前版本相对根目录同名主函数的主要改进，说明调试过程中遇到的问题、原因判断、采取的解决方法，以及后续建议。

涉及的主要文件：

- `X410_runSingleHost_DualRole_AARF.m`
- `HEWLANDataRecovery.m`
- `logs/run_QLOLLA_20260611_222803.log`
- `logs/run_QLOLLA_20260611_224951.log`
- `logs/run_QLOLLA_20260611_230206.log`

## 1. 总体结论

当前副本版本的主要改进目标不是单纯提高吞吐，而是先让 `160 MHz`、X410 环回线直连、单机双角色模式下的真实解码链路稳定运行，并把 CFO 野值、包检测误锁、控制器错误更新等问题暴露并隔离。

最新有效日志 `run_QLOLLA_20260611_230206.log` 的结果：

```text
Stats | fallback=0 (0.0%), realDecode=100 (100.0%), qUpdate=87
StatsDiag | CFOoutliers=11, NoPkt=0, WrongTarget=0, PacketDetectFail=0, HESIGACRC=0, FCSFail=1, Packet2Success=11, DegradedSuccess=11, CtrlFreeze=4
StatsTP | meanTput=217.31 Mbps, medianTput=219.43 Mbps, peakTput=271.06 Mbps
Final state | MCS=9 AMPDU=3 BWdec=16 lastSNR=30.97 dB
```

这说明：

- `160 MHz` 模式可以稳定真实解码，`realDecode=100%`。
- 没有出现 `NoPkt`、`WrongTarget`、`PacketDetectFail`、`HESIGACRC` 等系统性失败。
- CFO 野值仍存在，但从错误实验版本的 `34` 次下降到 `11` 次。
- QLOLLA 控制器仍能正常更新，`qUpdate=87`，没有被异常诊断长期冻结。

## 2. 相比根目录主函数的主要改进

根目录 `X410_runSingleHost_DualRole_AARF.m` 是一个较基础的单机双角色运行脚本。副本版本在以下方面做了增强。

### 2.1 固定 160 MHz 带宽运行

当前副本版本中：

```matlab
ChannelBWnewDec = 16; % 2->CBW20, 4->CBW40, 8->CBW80, 16->CBW160
```

并且控制器带宽上限保持为：

```matlab
bwdec_next = min(ChannelBWnewDec,16);
```

目的：

- 保证实验始终在 `CBW160` 条件下运行。
- 防止 ACK/ARQ 或控制器反馈把带宽回退到旧的上限。

### 2.2 使用固定硬件环回工作点

当前脚本保持：

```matlab
gainDataTx = 20;
gainDataRx = 25;
txPortIdx = 1;
rxPortIdx = 1;
```

目的：

- 对应当前硬件“环回线直连”的工作方式。
- 避免调试过程中自动增益变化掩盖 CFO/同步问题。

### 2.3 使用预设计多速率 FIR 进行重采样

副本版本中使用：

```matlab
rFilterTx = designMultirateFIR(p, q, Ntx-1);
rFilterRx = designMultirateFIR(q, p, Nrx-1);
currentTxWaveHW = upfirdn(txWave, rFilterTx, p, q);
rxDataWave = upfirdn(rxDataWave, rFilterRx, q, p);
```

目的：

- 避免每次循环调用 `resample` 时重复设计滤波器。
- 让 TX/RX 的多速率转换行为更明确，便于后续分析。
- 降低循环内不必要开销。

调试结论：

- CFO 野值的主因不是重采样本身。
- 因为在重采样逻辑基本不变的情况下，仅改变 replay 边界静默后，CFO 野值明显下降。

### 2.4 增加 TX replay 诊断日志

副本版本增加了：

```matlab
fprintf("  [TxDiag] iter=%d TXperiod=%d hwSamp/%d wlanSamp | MCS=%d AMPDU=%d BWdec=%d\n", ...
    n, numel(currentTxWaveHW), txPeriodWlanSamples, MCS, numampdunew, ChannelBWnewDec);
```

日志示例：

```text
[TxDiag] iter=95 TXperiod=37124 hwSamp/23759 wlanSamp | MCS=11 AMPDU=3 BWdec=16
```

目的：

- 明确每次 continuous replay 的周期长度。
- 将 CFO 野值出现的位置映射到 replay 周期内的相位。
- 判断 CFO 野值是否集中在 replay 边界或 PPDU 前沿附近。

### 2.5 增加 replayGuardTime

当前副本版本引入：

```matlab
replayGuardTime = 20e-6; % seconds: silence around each continuous replay period
```

并在 continuous replay 的硬件波形前后插入静默：

```matlab
if replayGuardTime > 0
    replayGuardSamplesHW = round(replayGuardTime * hwSR);
    currentTxWaveHW = [zeros(replayGuardSamplesHW, 1); currentTxWaveHW; zeros(replayGuardSamplesHW, 1)];
end
```

原来的 continuous replay 等价于：

```text
[PPDU][PPDU][PPDU][PPDU]...
```

加入 guard 后变为：

```text
[静默][PPDU][静默][静默][PPDU][静默]...
```

目的：

- 减少接收端从半截 PPDU 或 replay 边界切入后产生的假前导锁定。
- 让接收端更像从“空闲信道”中看到完整 PPDU。
- 验证 CFO 野值是否来自 continuous replay 的实验伪影。

注意：

- 这个 guard 会降低 SDR continuous 实验链路的真实占空比。
- 当前 `StatsTP` 主要反映包内 PHY 解码速率，不完整反映加入 guard 后的 wall-clock 吞吐。
- 因此它适合作为同步/解码调试手段，不适合作为最终真实 WiFi 吞吐模型。

### 2.6 增加 throughput 默认值保护

调试中曾出现：

```text
函数或变量 'throughputNow' 无法识别。
```

原因：

- 某些异常路径下没有成功进入吞吐计算分支。
- 后续 `sampleForTuning` 仍然引用 `throughputNow`。

副本版本在每轮恢复前初始化：

```matlab
throughputNow = 0;
bytesDelivered = 0;
airTimeSec = max(txDurationSec, 1e-6);
```

目的：

- 保证失败路径也有明确默认值。
- 防止诊断或控制器更新阶段因变量未定义而中断实验。

### 2.7 增加恢复诊断上下文 rxDiagCtx

副本主函数调用恢复函数时传入：

```matlab
rxDiagCtx = struct( ...
    'iter', n, ...
    'txPeriodSamples', txPeriodWlanSamples, ...
    'txPeriodHwSamples', numel(currentTxWaveHW), ...
    'captureSamples', size(rxDataWave,1), ...
    'sampleRate', sr, ...
    'hwSampleRate', hwSR, ...
    'MCS', MCS, ...
    'AMPDU', numampdunew, ...
    'BWdec', ChannelBWnewDec);
```

目的：

- 让 `HEWLANDataRecovery` 在发现 CFO 野值时能输出更多上下文。
- 记录野值发生在哪次迭代、哪个候选包、replay 周期内哪个相位。

示例日志：

```text
** CFO outlier rejected: -39513.0 Hz | iter=95 cand=1 search=0 raw=2260 timeoff=-315 pkt=1945 phase=1945/23759 coarse=-4113.7 fine=-35399.3 **
```

这类日志能判断：

- 野值主要发生在 PPDU 前沿附近。
- 异常主要由 fine CFO 贡献。
- 不是 X410 的真实频偏突然跳变。

## 3. HEWLANDataRecovery 的主要改进

根目录版本的 `HEWLANDataRecovery.m` 只返回基础解码结果。副本版本增加了失败阶段、诊断结构、CFO 野值处理和 guard 统计。

### 3.1 输出 failStage 和 recoveryDiag

副本版本函数签名变为：

```matlab
function [packetSeq,rxBitMatrix,rxnumampdu,SNRest,RXTime,pktind,searchOffset,ConstellationDiagram,ctlinfo,rmsEVMsym,rmsEVMsc,failStage,recoveryDiag] = HEWLANDataRecovery(chanBW,sr,rx,idleTime,rxDiagCtx)
```

新增诊断结构包含：

```matlab
recoveryDiag = struct( ...
    'cfoOutlierCount', 0, ...
    'noPacketCount', 0, ...
    'wrongTargetCount', 0, ...
    'packetDetectFailCount', 0, ...
    'sigaCrcFailCount', 0, ...
    'fcsFailCount', 0, ...
    'ampduDeaggFailCount', 0, ...
    'lsigFailCount', 0, ...
    'usedPacketIndex', 0, ...
    'skippedBeforeSuccess', 0, ...
    'frontGuardSkipCount', 0, ...
    'candidateCount', 0, ...
    'cfoOutlierOffsets', [], ...
    'cfoOutlierPhase', [], ...
    'suspiciousSuccess', false);
```

目的：

- 区分失败类型，而不是只看 `ctlinfo=0`。
- 统计 CFO outlier、包检测失败、FCS 失败、SIG-A CRC 失败等。
- 让主控制器知道某次成功是否可疑，避免用异常包训练控制器。

### 3.2 修复包检测 guard

调试过程中发现原始文件中存在乱码注释，曾导致：

```matlab
if pktOffset < 0
```

被吞进注释或控制流显示异常。

副本版本显式保留：

```matlab
pktOffset = wlanPacketDetect(rx,chanBW,searchOffset);
if pktOffset < 0
    ...
end
```

目的：

- 防止 `No packet detected` 分支无条件执行或控制流错位。
- 确保包检测失败时能够正确退出或统计。

### 3.3 增加 frontGuardSamples

副本版本保留轻量前沿保护：

```matlab
frontGuardSamples = round(8e-6 * sr);
```

如果候选包位置太靠近捕获窗口开头：

```matlab
if pktOffsetRaw < frontGuardSamples
    fprintf('  [FrontGuard] skip early candidate: cand=%d raw=%d guard=%d search=%d\n', ...);
    recoveryDiag.frontGuardSkipCount = recoveryDiag.frontGuardSkipCount + 1;
    searchOffset = double(frontGuardSamples);
    continue;
end
```

目的：

- 跳过捕获窗口最前面的 TX/RX 切换瞬态或半截 replay 残留。
- 避免把明显不完整的窗口前沿当成 PPDU 前导。

调试中曾尝试把 front guard 扩大到一个完整 replay 周期。结果：

```text
CFOoutliers=34
DegradedSuccess=100
CtrlFreeze=99
qUpdate=0
```

原因：

- 每次正常跳过 replay 周期都被误计为 degraded success。
- QLOLLA 控制器几乎全程冻结。
- 且 continuous replay 每个周期完全相同，跳过一个周期并不能消除下一个周期的边界问题。

因此最终撤回该方案，只保留固定 `8 us` front guard，并把 replay 边界问题转移到 TX 波形结构上解决。

### 3.4 CFO 野值检测与跳过

根目录版本中 CFO 阈值为：

```matlab
if abs(cfoCorrection) > 10000
```

副本版本改为更严格且带诊断：

```matlab
if ~isfinite(cfoCorrection) || abs(cfoCorrection) > 5e3
    ...
    fprintf(['  ** CFO outlier rejected: %.1f Hz | iter=%g cand=%d search=%d raw=%d ' ...
        'timeoff=%d pkt=%d phase=%g/%g coarse=%.1f fine=%.1f **\n'], ...);
    ctlinfo = 0;
    failStage = "cfo_outlier";
    recoveryDiag.cfoOutlierCount = recoveryDiag.cfoOutlierCount + 1;
    recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
    searchOffset = double(pktOffset + max(1, ind.LSIG(2)));
    pktind = pktind + 1;
    continue;
end
```

原因：

- 环回线直连时真实 CFO 不应突然达到几十 kHz。
- 日志中正常包 CFO 多数在几百 Hz 内。
- 野值通常表现为 fine CFO 极大，说明前导/timing 锁错，而非真实频偏。

处理方式：

- 不用野值去校正后续波形。
- 跳过该候选，继续搜索后续候选包。
- 将该次成功标记为 degraded，降低控制器更新权重。

### 3.5 Databitrate 未定义保护

调试中曾出现：

```text
函数或变量 'Databitrate' 无法识别。
```

原因：

- 某些异常路径下 `ctlinfo` 被置为成功或半成功，但实际没有生成 `Databitrate`。

副本版本增加：

```matlab
if ctlinfo == 1 && exist('Databitrate','var') && ~isempty(Databitrate)
    DataBitrate = mean(Databitrate);
    fprintf(' DataBitrate (Mbps): %2.2f\n',DataBitrate);
elseif ctlinfo == 1
    ctlinfo = 0;
    if strlength(string(failStage)) == 0
        failStage = "pkt_detect";
    end
end
```

目的：

- 防止未定义变量中断主循环。
- 避免没有完整数据速率计算的包被误认为有效成功。

### 3.6 EVM 和信道估计诊断

副本版本保留了：

```matlab
fprintf('  ChanEst mean|h|: %.3f | HE-LTF rms: %.3f\n', ...);
fprintf('  EVM per-sym: %.2f dB | EVM per-sc: %.2f dB\n', ...);
```

目的：

- 判断问题是链路质量差、非线性、FCS 错误，还是同步误锁。
- 最新日志中多数正常包 EVM/SNR 都较好，支持“CFO 野值主要来自同步误锁，而不是硬件链路质量差”的判断。

## 4. 问题、原因与解决方法

### 问题 1：CFO 出现几十 kHz 野值

现象：

```text
Estimated CFO: -39513.0 Hz
** CFO outlier rejected: -39513.0 Hz | iter=95 cand=1 search=0 raw=2260 timeoff=-315 pkt=1945 phase=1945/23759 coarse=-4113.7 fine=-35399.3 **
```

原因判断：

- 环回线直连下真实 CFO 不应达到几十 kHz。
- 正常包 CFO 多数在几百 Hz 内。
- 野值主要由 fine CFO 贡献。
- 野值常出现在 PPDU 前沿附近或 replay 边界附近。
- 说明 `wlanPacketDetect` 或 `wlanSymbolTimingEstimate` 偶尔锁到了半截 PPDU/边界候选。

解决方法：

- 在恢复函数中拒绝不物理的 CFO 候选。
- 记录候选编号、searchOffset、raw offset、timing offset、replay phase。
- 在 TX continuous replay 波形前后加入静默 guard，降低边界误锁概率。

效果：

```text
无外层静默 guard 的可运行基线:
CFOoutliers=21

错误的整周期 front guard 实验:
CFOoutliers=34

TX replay 前后加静默后的最新版本:
CFOoutliers=11
```

### 问题 2：直接跳过整 replay 周期导致控制器冻结

现象：

```text
DegradedSuccess=100
CtrlFreeze=99
qUpdate=0
Final state | MCS=0 AMPDU=1
```

原因：

- front guard 被扩大到一个完整 replay 周期。
- 每一轮都会发生 front guard 跳过。
- 该跳过最初被计入 `skippedBeforeSuccess`。
- 主控制器把每次成功都认为是 degraded success，于是冻结更新。

解决方法：

- 新增 `frontGuardSkipCount`。
- 将预期内的 front guard 跳过与真正异常跳过分开。
- 最终撤销“跳过整周期”实验，恢复轻量 `8 us` front guard。
- 改为在 TX 波形结构中增加静默，避免在 RX 端猜测周期边界。

### 问题 3：`throughputNow` 未定义

现象：

```text
函数或变量 'throughputNow' 无法识别。
```

原因：

- 解码异常路径没有进入吞吐计算。
- 后续 tuning sample 仍引用该变量。

解决方法：

- 每轮恢复前设置默认值：

```matlab
throughputNow = 0;
bytesDelivered = 0;
airTimeSec = max(txDurationSec, 1e-6);
```

### 问题 4：`Databitrate` 未定义

现象：

```text
函数或变量 'Databitrate' 无法识别。
```

原因：

- 恢复函数某些异常路径没有计算 `Databitrate`。
- 末尾仍执行 `mean(Databitrate)`。

解决方法：

- 使用 `exist('Databitrate','var')` 做 guard。
- 如果没有合法 `Databitrate`，不再把该包作为成功包处理。

### 问题 5：continuous replay 不符合真实 WiFi 链路

当前模式：

```matlab
transmit(bb, currentTxWaveHW, "continuous")
```

实际效果：

```text
[PPDU][PPDU][PPDU][PPDU]...
```

真实 WiFi 更接近：

```text
空闲 -> PPDU -> SIFS/ACK/退避/调度间隔 -> 下一个 PPDU
```

问题：

- RX capture 会从 replay 的任意位置切入。
- 可能从半截 PPDU 或边界开始检测。
- 这会制造真实 WiFi 中不常见的同步误锁。

解决方法：

- 短期：在 continuous replay 周期前后加 `replayGuardTime` 静默。
- 长期：切换到 burst/TDD，每轮发有限长度 PPDU，而不是无限 replay。

## 5. 调试过程摘要

### 阶段 1：建立 160 MHz 可运行基线

目标：

- 将链路切到 `CBW160`。
- 确保能真实解码，不依赖 fallback ACK。

结果：

```text
realDecode=100%
NoPkt=0
PacketDetectFail=0
```

但仍有 CFO 野值：

```text
CFOoutliers=21
Packet2Success=21
DegradedSuccess=36
```

### 阶段 2：分析 CFO 野值

通过日志发现：

- 野值 CFO 多为 `-10 kHz` 到 `-40 kHz`。
- 正常 CFO 多为几百 Hz。
- 野值的 fine CFO 分量异常大。
- 后续候选包通常能正常解码。

判断：

- 不是硬件频偏真的跳变。
- 主要是包检测/timing 在 continuous replay 边界或前沿附近误锁。

### 阶段 3：尝试跳过一个 replay 周期

方法：

- 将 front guard 从固定 `8 us` 扩大到一个 `txPeriodSamples`。

结果变差：

```text
CFOoutliers=34
DegradedSuccess=100
CtrlFreeze=99
qUpdate=0
```

结论：

- continuous replay 每个周期相同，跳过一个周期不能根治边界问题。
- RX 端强行跳周期会干扰控制器诊断。

### 阶段 4：改 TX replay 波形结构

方法：

- 在 `currentTxWaveHW` 前后加入静默：

```matlab
currentTxWaveHW = [zeros(replayGuardSamplesHW, 1); currentTxWaveHW; zeros(replayGuardSamplesHW, 1)];
```

结果：

```text
CFOoutliers=11
Packet2Success=11
DegradedSuccess=11
CtrlFreeze=4
qUpdate=87
realDecode=100%
```

结论：

- CFO 野值与 continuous replay 边界强相关。
- 加静默能显著降低误锁概率。
- 降采样/重采样不是 CFO 野值的主因。

## 6. 对吞吐统计的说明

`replayGuardTime` 会降低 SDR continuous 实验链路的真实占空比。因为每个周期多了静默：

```text
真实周期时间 = 静默 + PPDU + 静默
```

当前日志中的 `StatsTP` 更接近包内 PHY 解码吞吐，不完整反映 wall-clock 空口吞吐。因此：

- 用它评估 MCS、SNR、EVM、FCS、控制器行为是可以的。
- 用它报告真实 WiFi 链路吞吐时，需要把 `replayGuardTime`、ACK、退避、调度间隔等计入总 airtime。

## 7. 当前版本仍需注意的问题

### 7.1 CFO 野值没有完全消失

最新版本仍有：

```text
CFOoutliers=11
```

剩余野值仍集中在 PPDU 前沿附近，说明偶发前导误锁还存在。

可选改进：

- 轻微增加 `replayGuardTime`，例如 `30 us` 或 `50 us`。
- 增加更可靠的候选验证，例如 L-STF/L-LTF 相关峰质量、HE-SIG-A CRC 前的候选筛选。
- 切换到 burst/TDD 模式，从根上消除 continuous replay 边界。

### 7.2 `replayGuardTime` 不应作为最终真实吞吐方案

它适合用于调试和稳定收包，但最终真实链路模型应考虑：

- 单个 PPDU 的有限发送。
- ACK/ARQ 时序。
- 包间隔、退避或调度。
- 真实 airtime 吞吐计算。

### 7.3 TDD 分支仍需单独验证

当前主流程仍使用：

```matlab
duplexMode = "simultaneous";
```

TDD/burst 是更真实的方向，但需要重新验证：

- TX 停止和 RX 捕获时序。
- 捕获窗口是否覆盖完整 PPDU。
- 是否会出现 start/stop 硬件延迟或漏包。

## 8. 建议的下一步实验

建议按以下顺序继续：

1. 固定当前版本，连续跑 3 次 100 iteration，观察 `CFOoutliers` 是否稳定在较低水平。
2. 将 `replayGuardTime` 分别设为 `10 us`、`20 us`、`30 us`、`50 us`，比较：

```text
CFOoutliers
DegradedSuccess
CtrlFreeze
FCSFail
qUpdate
StatsTP
```

3. 如果 `replayGuardTime` 增大后 CFO 野值继续下降，说明 replay 边界仍是主要来源。
4. 如果 CFO 野值下降到平台期，再考虑实现 burst/TDD。
5. 如果要报告真实吞吐，新增 wall-clock throughput：

```text
有效 payload bits / (PPDU airtime + guard + ACK/ARQ + 间隔)
```

## 9. 当前调试判断

当前证据支持以下判断：

- CFO 野值主因不是硬件真实 CFO。
- CFO 野值主因不是降采样/重采样。
- CFO 野值主要来自 continuous replay 下的包检测/timing 误锁。
- 在 replay 周期中加入静默能显著改善。
- 当前版本适合作为 `160 MHz` 环回线直连下的稳定调试基线。
- 如果目标是逼近真实 WiFi 链路，最终应从 continuous replay 转向有限 burst/TDD。
