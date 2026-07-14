# X410 QLOLLA 环回链路排查清单

## 当前结论

从最近几轮日志看，链路已经证明具备高阶解调能力：

- 成功包的 `ChanEst mean|h|` 稳定在约 `1.06`
- `EVM per-sym` 大多在 `-28 ~ -33 dB`
- `EVM per-sc` 大多在 `-30 ~ -34 dB`
- 成功包可稳定解到 `MCS=10~11`
但仍存在两类不稳定现象：

1. `No packet detected(UN)`
2. `CFO out of range (>10kHz)`

这说明当前瓶颈主要在**包检测/前导锁定稳定性**，而不是均衡或数据解调本身。

---

## 如何区分是硬件问题还是代码问题

### 更像硬件问题的特征

- `CFO` 偶发出现几十 kHz 的野值
- 不同迭代之间的 `EVM` 波动较大，但成功包中 `ChanEst mean|h|` 仍接近 1
- `No packet detected` 与 `wrong target packet` 伴随连续模式、重采样、或半双工切换出现
- 降低增益后仍能看到相似的异常包检测行为

### 更像代码问题的特征

- 同一组波形，在离线 MATLAB 测试中 EVM 接近数值极限
- 只要绕过硬件，解调与均衡都稳定
- 异常主要出现在：
  - 包检测门限
  - 搜索窗口
  - 连续 TX 拼接边界
  - `searchOffset` 更新逻辑

### 当前更可能的判断

当前更像是**硬件 + 代码边界共同作用**：

- 硬件侧：X410 偶发 LO/PLL 或前端锁定异常，导致 CFO 野值
- 代码侧：连续发射 + 捕获窗口 + 重采样边界，使包检测对伪峰敏感

---

## 建议的排查顺序

1. 记录每次失败的原因
   - `No packet detected`
   - `CFO out of range`
   - `wrong target packet`

2. 看失败是否集中在特定状态
   - 是否集中在高 MCS
   - 是否集中在 AMPDU=5
   - 是否集中在包长较长时

3. 对比“成功包”和“失败前一包”的差异
   - `rxRMS`
   - `rxPeak`
   - `Estimated CFO`
   - `EVM`
   - `ChanEst mean|h|`

4. 做更小范围实验
   - 固定 `MCS=10`
   - 固定 `AMPDU=5`
   - 固定 `BWdec=16`
   - 只看 `No packet detected` 和 `CFO out of range` 是否仍然出现

5. 再做结构性实验
   - 改成更保守的 `duplexMode`
   - 增加 TX/RX 之间的静默间隔
   - 比较连续模式与 TDD 模式

---

## 当前脚本里最值得盯的变量

### `X410_runSingleHost_DualRole_AARF.m`

- `rxRMS`
- `rxPeak`
- `snrMetricDb`
- `MCS`
- `numampdunew`
- `ChannelBWnewDec`
- `fallbackCount`
- `realDecodeCount`
- `qLearningUpdateCount`

### `HEWLANDataRecovery.m`

- `Estimated CFO`
- `SNRest`
- `ChanEst mean|h|`
- `EVM per-sym`
- `EVM per-sc`
- `No packet detected`
- `wrong target packet detected`

---

## 建议的下一步代码优化

### 1. 为失败原因增加计数器
把每次：

- CFO 野值
- No packet detected
- wrong target packet

都单独计数，最后输出失败统计。

### 2. 为包检测增加更细的调试输出
当包检测失败时，打印：

- 失败前的 `rxRMS`
- `rxPeak`
- 搜索起点 `searchOffset`
- 当前 `MCS / AMPDU / BWdec`

### 3. 将异常包完全从控制器中剔除
不要让它们改变：

- `MCS`
- `AMPDU`
- `BWdec`

只作为日志样本保留。

---

## 快速判断准则

- 如果**离线 MATLAB 解调很好，在线只是不稳**，偏硬件/接口/时序问题
- 如果**离线也不好**，偏代码/波形生成/解调链问题
- 如果**成功包质量好，但失败包集中在检测阶段**，偏包检测与边界处理

---

## 当前推荐结论

目前最合理的判断是：

> 代码主解调链基本正确，主要瓶颈是硬件/接口侧偶发前导检测不稳，再叠加连续模式和重采样边界，使得少量包在进入解调前就失败。

因此后续重点不是重写解调，而是**增强检测鲁棒性、记录失败统计、减少边界伪峰**。
