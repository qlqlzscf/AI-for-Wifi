# X410 Air Split Skeleton

These files are a starting point for splitting the enhanced single-host X410 loopback script into two OTA roles:

- `X410_Air_TXNode.m`: transmitter-side node. Sends Wi-Fi 6 data continuously and listens for ACK/ARQ feedback.
- `X410_Air_RXNode.m`: receiver-side node. Captures Wi-Fi 6 data, runs the existing decoder/adaptation algorithm, and transmits ACK/ARQ feedback.
- `X410_AirLink_Config.m`: shared radio/RF/MCS/gain settings. Edit the Radio Setup names first.
- `buildFeedbackWaveform.m`: wraps the algorithm decision in a robust feedback payload.
- `decodeFeedbackInfo.m`: decodes robust ACK/ARQ feedback and rejects stale or invalid payloads.
- `X410_AirSetupPath.m`: prefers the enhanced core directory when it exists.

Use order:

1. In MATLAB Radio Setup, save two separate X410 configurations, for example `X410_TX` and `X410_RX`.
2. Edit `X410_AirLink_Config.m` so `cfg.txRadioName` and `cfg.rxRadioName` match your saved names.
3. Keep `cfg.initialBWdec=2`, `cfg.initialMCS=0`, and `cfg.initialAMPDU=1` for bring-up.
4. Start `X410_Air_RXNode.m` first.
5. Start `X410_Air_TXNode.m` second.
6. After data and feedback decode are stable, tune MCS/AMPDU first; enable bandwidth adaptation last.

Notes:

- This is still not executed on your X410 hardware in this environment.
- The scripts prefer `..\X410_CombinedTxRx_XL - 副本 - 副本` as the enhanced core when present. That keeps the L-STF quality gate, CFO rejection, `recoveryDiag`, CSI output, and conservative control logic available.
- Start with low TX gain and sufficient physical separation/attenuation to avoid RX saturation.
- The feedback link is fixed to CBW20/MCS0 for robustness; the feedback payload carries `magic + version + sequence + ack/arq + MCS + AMPDU + BWdec + checksum`.
- TX ignores stale feedback sequence numbers and invalid checksums.
- TX rolls back to `cfg.rollbackMCS/cfg.rollbackAMPDU/cfg.rollbackBWdec` after `cfg.noFeedbackRollbackLimit` consecutive missing or stale feedback packets.
- RX freezes only after repeated hard failures and caps MCS jumps; successful decodes are treated as normal ACKs.
- RX passes `cfg.cfoRejectThresholdHz` into the enhanced decoder. The default is 50 kHz for independent-X410 OTA; the enhanced core still defaults to 5 kHz when called without this context.
- `cfg.enableBandwidthAdaptation=false` by default to avoid TX/RX CBW desynchronization during bring-up.
- `cfg.explorationEpsilon=0` disables QLOLLA online random exploration during deployment tests.
