%% X410 Single-Host Dual-Role Closed Loop (AARF)
% 单机“双实例/双角色”闭环：
% - 角色A(TX节点)：发送数据包（txCenterFrequency），等待反馈更新参数
% - 角色B(RX节点)：接收数据包，解包得到 ACK/ARQ(ctlinfo)，AARF 生成反馈包并回传（ackCenterFrequency）
%
% 硬件前提：
% - 同一台机器同一块 X410
% - 需要物理回环（例如 TX 口到 RX 口的线缆+衰减器）或 OTA，使得同机可收到自身发射信号
%
% 注意：
% - Wireless Testbench `basebandTransceiver` 对同一 radio 一般要求独占，
%   因此这里用“一个对象 + 时分角色切换”实现单机闭环，而不是开两个 MATLAB 会话抢占硬件。

clear all; close all; clc;

%% Algorithm mode
% Supported: "AARF" | "OLLA" | "AOLLA" | "QLOLLA"
algorithmMode = "QLOLLA";
enableRunDiary = true;
if enableRunDiary
    runDir = fileparts(mfilename("fullpath"));
    logDir = fullfile(runDir, "logs");
    if ~exist(logDir, "dir"), mkdir(logDir); end
    runTag = datestr(now, "yyyymmdd_HHMMSS");
    logFile = fullfile(logDir, sprintf("run_%s_%s.log", char(algorithmMode), runTag));
    diary(logFile); diary on;
    fprintf("Run log file: %s\n", logFile);
end

%% Toolbox check
if isempty(ver('wlan'))
    error('Please install WLAN Toolbox.');
elseif ~license('test','WLAN_System_Toolbox')
    error('Need WLAN System Toolbox license.');
end

%% Select radio configuration
configs = radioConfigurations;
if isempty(configs)
    error("No saved radio configurations found. Run Radio Setup (Wireless Testbench) first.");
end
radioName = configs(1).Name;

try
    bb = basebandTransceiver(radioName);
    bb.CaptureDataType = "double";
    cleanupObj = onCleanup(@() localStopTx(bb));
catch ME
    error(strjoin([
        "Unable to create basebandTransceiver for saved configuration: " + string(radioName)
        "This typically means the radio is not connected or the saved configuration is not valid on this machine."
        "Fix:"
        "  - Make sure the X410 is powered on and reachable (same NIC/subnet as configured)"
        "  - Run Radio Setup (Wireless Testbench) and click Revalidate for '" + string(radioName) + "'"
        "  - In MATLAB you can check saved configs with: configs = radioConfigurations"
        ""
        "Original error:"
        string(ME.message)
    ], newline));
end

% Select the two ports you actually connected for cable loopback.
% Common index mapping for X410 in this setup:
%   1 -> DB0:RF0
%   2 -> DB0:RF1
%   3 -> DB1:RF0
%   4 -> DB1:RF1
%
% For same-port DB0:RF0 loopback, use (1,1):
%   TX on DB0:RF0:TX/RX0 and RX on DB0:RF0:RX1.
txPortIdx = 1; % DB0:RF0:TX/RX0
rxPortIdx = 1; % DB0:RF0:RX1
txAnts = hTransmitAntennas(radioName);
rxAnts = hCaptureAntennas(radioName);
bb.TransmitAntennas = txAnts(txPortIdx);
bb.CaptureAntennas = rxAnts(rxPortIdx);

%% RF parameters
txCenterFrequency  = 3.184e9; % Data link
ackCenterFrequency = 1.784e9; % Feedback link
% Stable DB0:RF0 cable-loopback point verified by X410_decodeChainBringup:
% use a fixed operating point first, then compare algorithms under the same link.
gainDataTx = 20;
gainDataRx = 25;
gainAckTx  = 0;
gainAckRx  = 45;

% In single-host dual-role mode, you do NOT need to over-the-air transmit
% the ACK/ARQ and then capture+decode it again just to update the state.
% Keep this off by default to avoid long packet-detect loops when no ACK exists.
doOverAirFeedback = false;

% Duplex mode selection:
% - "simultaneous": keep TX on (continuous) while capturing (may distort on half-duplex setups,
%   but matches your requested behavior and avoids stopTransmission issues).
% - "tdd": transmit for a short time, stop, then capture.
duplexMode = "simultaneous";

% Baseline mode: keep known-good settings from X410_linkSanityCheck first.
enableAutoGainSweep = false;
enablePacketDetectFallbackACK = false;
allowFallbackToTrainAARF = false;
% Demo-oriented switch: let OLLA-family update even on fallback ACKs.
% Turn this OFF for strict training/analysis. Keep strict mode by default
% now that real decode is available on the cable loopback.
allowFallbackToTrainOLLAFamily = false;

% Role切片间隔：给TX/RX切换更充足的保护时间，减少边界伪峰。
roleSliceGuardMs = 8;

% Diagnostics counters to distinguish hard failures from decode failures.
cfoOutlierCount = 0;
noPacketCountDiag = 0;
wrongTargetCount = 0;
packetDetectFailCount = 0;
sigaCrcFailCount = 0;
fcsFailCount = 0;
packet2SuccessCount = 0;
controllerFreezeCount = 0;
consecutiveHardFailCount = 0;
freezeRemaining = 0;

fprintf("Algorithm mode: %s\n", algorithmMode);
fprintf("Stable loopback point | TX=%g dB RX=%g dB | strict real-decode mode\n", gainDataTx, gainDataRx);

%% Packet timing
idleTime = 2e-6; % seconds (IMPORTANT): wider guard for CBW160 continuous replay

%% Initial link state
MCS = 0;
% Start with a short packet to make packet detection robust, then you can
% increase AMPDU gradually after OTA link is stable.
numampdunew = 1;
% Your installed basebandTransceiver does not expose MasterClockRate, so
% keep SampleRate within the fixed hardware constraints.
% Start at CBW20 for robust packet detection, then you can widen later.
ChannelBWnewDec = 16; % 2->CBW20, 4->CBW40, 8->CBW80, 16->CBW160

% Auto gain sweep stays available for recovery experiments, but keep it off
% during algorithm comparison so all runs see the same channel conditions.
noPktCount = 0;
maxNoPktBeforeStep = 3;
maxGainRx = 60;
maxGainTx = 10;
gainStepRx = 5;
gainStepTx = 5;

%% Simple payload generator (replace with your own segmentation)
% Keep payload short while debugging OTA (improves chance capture window contains a full preamble)
length_txcode = 2304; % bytes
payload = uint8(ceil(256*rand(length_txcode,1)) - 1);

% State for non-AARF algorithms
ctlinfoList = [];
PERList = [];
deltaThresholdList = [];
deltaOLLAList = [];
MCSbuffer = MCS;
beta1 = 0.4; % for QLOLLA
beta2 = 1.8; % for QLOLLA
mcsStepCap = 2; % prevent overly aggressive jumps
runtimeExplorationEpsilon = 0;
qtableAvailable = false;
qtableMode = "none";
beta1Grid = 0.2:0.1:0.8;
beta2Grid = 1.2:0.1:2.4;
actVals = [-0.2; 0; 0.2];
runtimeBetaWindow = 25;
% Load trained Q-tables. Only beta-state tables are accepted.
qtableFile = fullfile(runDir, "Qtable_X410.mat");
if exist(qtableFile, "file")
    qtab = load(qtableFile);
    if isfield(qtab, "Qtable_beta1") && isfield(qtab, "Qtable_beta2")
        Qtable_beta1 = qtab.Qtable_beta1;
        Qtable_beta2 = qtab.Qtable_beta2;
        if isfield(qtab, "beta1Grid"), beta1Grid = qtab.beta1Grid; end
        if isfield(qtab, "beta2Grid"), beta2Grid = qtab.beta2Grid; end
        if isfield(qtab, "actionSpace"), actVals = qtab.actionSpace; end
        if isfield(qtab, "WQLearning"), runtimeBetaWindow = qtab.WQLearning; end
        if size(Qtable_beta1, 2) == numel(beta1Grid) && size(Qtable_beta2, 2) == numel(beta2Grid)
            qtableMode = "beta-state";
            qtableAvailable = true;
            fprintf("Loaded Q-tables (%s) from: %s\n", qtableMode, qtableFile);
        else
            fprintf("Ignoring non beta-state Q-table: %s\n", qtableFile);
        end
    else
        fprintf("Q-table file exists but required variables are missing: %s\n", qtableFile);
    end
else
    fprintf("No Q-table found; QLOLLA uses default beta values.\n");
end
snrMetricDbLast = 15;
fallbackCount = 0;
realDecodeCount = 0;
qLearningUpdateCount = 0;
perHistory = zeros(0,1);
throughputHistoryMbps = zeros(0,1);
bytesDeliveredHistory = zeros(0,1);
airTimeHistorySec = zeros(0,1);
tuningState = x410_tuning_framework('init');

%% Helper: BWdec -> string and sample rate
bwDec2Str = @(bwdec) ( ...
    ternary(bwdec==2,"CBW20", ...
    ternary(bwdec==4,"CBW40", ...
    ternary(bwdec==8,"CBW80", ...
    "CBW160"))));

%% Main loop
N = 100;

isTxOn = false;
currentTxWaveHW = [];
lastTxSignature = "";

% X410 native sample rate (WLAN rate requires software resampling)
hwSR = 250e6;
bb.SampleRate = hwSR;

for n = 1:N
    chanBW = char(bwDec2Str(ChannelBWnewDec));

    % Update sample rate to match BW
    cfgSU = wlanHESUConfig;
    cfgSU.ChannelBandwidth = chanBW;
    sr = wlanSampleRate(cfgSU);
    % hwSR / bb.SampleRate set once outside the loop
    % Resample ratio p/q: hwSR/sr = p/q
    g = gcd(round(hwSR), round(sr));
    p = round(hwSR / g);
    q = round(sr / g);

    if ~exist('rFilterTx','var') || ~exist('prev_p','var') || p ~= prev_p || q ~= prev_q
        Ntx = 2 * p * ceil(0.01 * p * q) + 1;
        rFilterTx = designMultirateFIR(p, q, Ntx-1);
        Nrx = 2 * q * ceil(0.01 * p * q) + 1;
        rFilterRx = designMultirateFIR(q, p, Nrx-1);
        prev_p = p;
        prev_q = q;
    end

    %% ================= Role A: TX data (and capture data as Role B) =================
    bb.TransmitCenterFrequency = txCenterFrequency;
    bb.TransmitRadioGain = gainDataTx;
    bb.CaptureCenterFrequency = txCenterFrequency;
    bb.CaptureRadioGain = gainDataRx;

    % Build/update transmit waveform when needed (MCS/AMPDU/BW may change)
    txSig = sprintf("%s|%d|%d|%d", chanBW, MCS, numampdunew, length(payload));
    if isempty(currentTxWaveHW) || ~strcmp(txSig,lastTxSignature)
        [~,~,~,txWave] = HEWLANDataGenerator(numampdunew,idleTime,MCS,chanBW,payload,length(payload));
        txWave = txWave / max(abs(txWave)) * 0.7;
        % Resample to X410 native sample rate
        currentTxWaveHW = upfirdn(txWave, rFilterTx, p, q);
        lastTxSignature = txSig;
        if isTxOn
            try
                stopTransmission(bb);
            catch
            end
            isTxOn = false;
        end
    end

    txDurationSec = numel(currentTxWaveHW)/hwSR;
    txPeriodWlanSamples = max(1, round(numel(currentTxWaveHW) * sr / hwSR));
    fprintf("  [TxDiag] iter=%d TXperiod=%d hwSamp/%d wlanSamp | MCS=%d AMPDU=%d BWdec=%d\n", ...
        n, numel(currentTxWaveHW), txPeriodWlanSamples, MCS, numampdunew, ChannelBWnewDec);
    % Shorter capture keeps replay/capture pressure lower on X410 while
    % still covering the packet in the verified cable-loopback setup.
    captureTimeData = milliseconds(max(35,ceil(1000*min(0.25,2*txDurationSec))));

    if duplexMode == "simultaneous"
        if ~isTxOn
            try
                transmit(bb, currentTxWaveHW, "continuous");
                isTxOn = true;
                pause(0.02);
        pause(roleSliceGuardMs/1000);
            catch ME
                error(strjoin([
                    "Transmit failed for configuration: " + string(radioName)
                    "This usually means the radio is not connected or the saved configuration is not compatible."
                    "Please revalidate the radio configuration using Radio Setup (Wireless Testbench)."
                    ""
                    "Original error:"
                    string(ME.message)
                ], newline));
            end
        end
        pause((roleSliceGuardMs + 2*rand(1))/1000);
        rxDataWave = capture(bb, captureTimeData);
    else
        % TDD mode (fallback)
        [~,~,~,txWave] = HEWLANDataGenerator(numampdunew,idleTime,MCS,chanBW,payload,length(payload));
        txWave = txWave / max(abs(txWave)) * 0.8;
        txWaveHW = upfirdn(txWave, rFilterTx, p, q);
        transmit(bb, txWaveHW, "continuous");
        pause(max(0.02, 2*(numel(txWaveHW)/hwSR)));
        try, stopTransmission(bb); catch, end
        pause(0.01);
        pause(roleSliceGuardMs/1000);
        rxDataWave = capture(bb, captureTimeData);
    end

    % Drop initial transient samples (TX/RX settling, LO spur, etc.)
    dropMs = 5;
    dropSamp = min(size(rxDataWave,1), round((dropMs/1000)*hwSR));
    if dropSamp > 0 && size(rxDataWave,1) > dropSamp
        rxDataWave = rxDataWave(dropSamp+1:end,:);
    end

    % Quick diagnostic on captured signal (at hwSR) before resampling
    rxRMS = sqrt(mean(abs(rxDataWave).^2));
    rxPeak = max(abs(rxDataWave));
    fprintf("  Gains: TX=%g dB, RX=%g dB | RX diag: RMS=%.3e, Peak=%.3e\n", gainDataTx, gainDataRx, rxRMS, rxPeak);

    % Resample captured data from hwSR back to WLAN sample rate sr
    rxDataWave = upfirdn(rxDataWave, rFilterRx, q, p);

    % If the capture is clearly saturated, back off gains immediately.
    if rxPeak > 0.9
        gainDataTx = max(0, gainDataTx - gainStepTx);
        gainDataRx = max(0, gainDataRx - gainStepRx);
        gainAckRx = gainDataRx;
        fprintf("  [AutoGain] Saturation detected (Peak>0.9) -> back off to TX=%g dB, RX=%g dB\n", gainDataTx, gainDataRx);
    end

    %% ================= Role B: decode data -> decide ACK/ARQ + AMPDU/BW heuristics =================
    ctlinfo = 0;
    fallbackUsed = false;
    rmsEVMsym = [];
    rmsEVMsc = [];
    SNRest = [];
    RXTime = [];
    throughputNow = 0;
    bytesDelivered = 0;
    airTimeSec = max(txDurationSec, 1e-6);
    recoveryDiag = struct('cfoOutlierCount',0,'noPacketCount',0,'wrongTargetCount',0, ...
        'packetDetectFailCount',0,'sigaCrcFailCount',0,'fcsFailCount',0, ...
        'ampduDeaggFailCount',0,'lsigFailCount',0,'usedPacketIndex',0, ...
        'skippedBeforeSuccess',0,'suspiciousSuccess',false);
    try
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
        [~,~,rxnumampdu,SNRest,RXTime,~,~,~,ctlinfo,rmsEVMsym,rmsEVMsc,failStage,recoveryDiag,csiData,chanEst] = HEWLANDataRecovery(chanBW,sr,rxDataWave,idleTime,rxDiagCtx);
    catch ME
        ctlinfo = 0;
        failStage = "recovery_exception";
        recoveryDiag.packetDetectFailCount = recoveryDiag.packetDetectFailCount + 1;
        fprintf("  [Diag] Recovery exception: %s\n", ME.message);
    end
    % ---- Save CSI to .mat file when available ----
    if exist('csiData','var') && ~isempty(csiData)
        csiDir = 'C:\Users\welcome\Desktop\CSI_LOGS_X410';
        if ~exist(csiDir, "dir"), mkdir(csiDir); end
        csiTag = datestr(now, "yyyymmdd_HHMMSS");
        csiFile = fullfile(csiDir, sprintf("csi_DL_iter%03d_%s_%s_MCS%d_AMPDU%d.mat", ...
            n, char(algorithmMode), csiTag, MCS, numampdunew));

        csiPayload = struct();
        csiPayload.csiData = csiData;
        csiPayload.chanEst = chanEst;
        csiPayload.SNRest = SNRest;
        csiPayload.MCS = MCS;
        csiPayload.chanBW = chanBW;
        csiPayload.sampleRate = sr;
        csiPayload.iter = n;
        csiPayload.algorithmMode = algorithmMode;
        csiPayload.linkDir = "DL";
        csiPayload.role = "RX";
        csiPayload.txCenterFrequency = txCenterFrequency;
        csiPayload.rxCenterFrequency = txCenterFrequency;
        csiPayload.rmsEVMsym = rmsEVMsym;
        csiPayload.rmsEVMsc = rmsEVMsc;
        csiPayload.failStage = failStage;
        csiPayload.ctlinfo = ctlinfo;
        csiPayload.rxnumampdu = rxnumampdu;
        csiPayload.RXTime = RXTime;
        csiPayload.recoveryDiag = recoveryDiag;
        csiPayload.rxDiagCtx = rxDiagCtx;
        csiPayload.timestamp = datetime('now');

        save(csiFile, '-struct', 'csiPayload');
        fprintf("  [CSI] Saved DL CSI to: %s\n", csiFile);
        fprintf("  [CSI] csiData size: [%d x %d], chanEst size: [%d x %d x %d]\n", ...
            size(csiData,1), size(csiData,2), size(chanEst,1), size(chanEst,2), size(chanEst,3));
        fprintf("  [CSI] Save directory: %s\n", csiDir);
    end
    % -------------------------------------------------
    cfoOutlierCount = cfoOutlierCount + recoveryDiag.cfoOutlierCount;
    noPacketCountDiag = noPacketCountDiag + recoveryDiag.noPacketCount;
    wrongTargetCount = wrongTargetCount + recoveryDiag.wrongTargetCount;
    packetDetectFailCount = packetDetectFailCount + recoveryDiag.packetDetectFailCount;
    sigaCrcFailCount = sigaCrcFailCount + recoveryDiag.sigaCrcFailCount;
    fcsFailCount = fcsFailCount + recoveryDiag.fcsFailCount;
    if recoveryDiag.usedPacketIndex > 1
        packet2SuccessCount = packet2SuccessCount + 1;
    end
    if ~isempty(SNRest)
        snrMetricDb = mean(SNRest);
        snrMetricDbLast = snrMetricDb;
    else
        % Fallback SNR proxy from capture power when decoder SNR is unavailable.
        % Keep bounded to avoid extreme threshold drift.
        snrMetricDb = 20*log10(max(rxRMS,1e-6)/1e-2);
        snrMetricDb = max(5, min(35, snrMetricDb));
        snrMetricDbLast = snrMetricDb;
    end

    if ctlinfo == 0
        if strlength(string(failStage)) > 0
            fprintf("  [Diag] Recovery failed stage=%s, SNRest=%d, rxRMS=%.3e, rxPeak=%.3e\n", ...
                string(failStage), isempty(SNRest), rxRMS, rxPeak);
        else
            fprintf("  [Diag] Recovery failed: ctlinfo=0, SNRest=%d, rxRMS=%.3e, rxPeak=%.3e\n", ...
                isempty(SNRest), rxRMS, rxPeak);
        end
    elseif ctlinfo == 2
        fprintf("  [Diag] Decode/FCS failure stage=%s, rxRMS=%.3e, rxPeak=%.3e\n", string(failStage), rxRMS, rxPeak);
    end

    % PER / throughput accounting for future multi-parameter tuning.
    if ~isempty(SNRest)
        rxNum = double(rxnumampdu);
        if isempty(rxNum) || ~isfinite(rxNum) || rxNum <= 0
            rxNum = 1;
        end
        bytesDelivered = double(ctlinfo ~= 0) * double(length_txcode);
        airTimeSec = 0;
        if ~isempty(RXTime) && isnumeric(RXTime)
            airTimeSec = double(RXTime(end)) * 1e-6;
        end
        if airTimeSec <= 0
            airTimeSec = max(txDurationSec, 1e-6);
        end
        perNow = double(ctlinfo == 0);
        throughputNow = (bytesDelivered * 8 / 1e6) / max(airTimeSec, 1e-6);
        perHistory(end+1,1) = perNow;
        throughputHistoryMbps(end+1,1) = throughputNow;
        bytesDeliveredHistory(end+1,1) = bytesDelivered;
        airTimeHistorySec(end+1,1) = airTimeSec;
    end

    % Optional fallback: if full recovery fails but packet detect succeeds,
    % treat it as ACK to establish closed-loop bring-up first.
    if enablePacketDetectFallbackACK && ctlinfo == 0
        pktOffset = wlanPacketDetect(rxDataWave, chanBW, 0);
        if ~isempty(pktOffset) && pktOffset > 0
            ctlinfo = 1;
            fallbackUsed = true;
            fallbackCount = fallbackCount + 1;
            fprintf("  [Fallback] Packet detected at offset=%d -> temporary ACK.\n", pktOffset);
        end
    end
    if ~fallbackUsed && ctlinfo ~= 0
        realDecodeCount = realDecodeCount + 1;
        ctlinfoList = [ctlinfoList; ctlinfo]; %#ok<AGROW>
    end

    % Optional auto gain sweep (disabled in baseline mode)
    if enableAutoGainSweep
        if ctlinfo == 0
            noPktCount = noPktCount + 1;
            noPacketCountDiag = noPacketCountDiag + 1;
            packetDetectFailCount = packetDetectFailCount + 1;
            if noPktCount >= maxNoPktBeforeStep
                noPktCount = 0;
                if gainDataRx < maxGainRx
                    gainDataRx = min(maxGainRx, gainDataRx + gainStepRx);
                    gainAckRx = gainDataRx;
                    fprintf("  [AutoGain] No packet -> increase RX gain to %g dB\n", gainDataRx);
                elseif gainDataTx < maxGainTx
                    gainDataTx = min(maxGainTx, gainDataTx + gainStepTx);
                    fprintf("  [AutoGain] No packet -> increase TX gain to %g dB\n", gainDataTx);
                else
                    fprintf("  [AutoGain] Reached max gains, still no packet.\n");
                end
            end
        else
            noPktCount = 0;
        end
    end

    % AMPDU heuristic (ported from old RX scripts idea)
    % Keep updates conservative so the controller does not overreact to
    % single-packet CFO/detection anomalies.
    numampdu_next = numampdunew;
    if ~isempty(rmsEVMsym) && rxnumampdu > 0
        SNRSwap = ceil(length(rmsEVMsym)/rxnumampdu);
        SNRtime = [];
        if SNRSwap > 0
            for i = 1:max(1,ceil(length(rmsEVMsym)/SNRSwap))
                lo = 1+(i-1)*SNRSwap;
                hi = min(i*SNRSwap,length(rmsEVMsym));
                if lo <= hi
                    SNRtime(i) = mean(rmsEVMsym(lo:hi)); %#ok<AGROW>
                end
            end
        end
        if ~isempty(SNRtime)
            if max(SNRtime)-min(SNRtime) > 8
                numampdu_next = max(1,rxnumampdu-1);
            elseif ctlinfo == 1
                numampdu_next = min(12,rxnumampdu+1);
            else
                numampdu_next = rxnumampdu;
            end
        end
    end

    % BW heuristic:
    % Keep bandwidth within hardware-supported sample rates.
    bwdec_next = min(ChannelBWnewDec,16); % cap at CBW160

    %% Generate feedback waveform (algorithm-dependent)
    prevMCS = MCS;
    ctlinfoAlg = ctlinfo;
    isOLLAFamily = any(strcmpi(char(algorithmMode), {'OLLA','AOLLA','QLOLLA'}));
    % For strict mode, skip OLLA-family learning updates on fallback.
    % For demo mode, keep fallback ACK as valid update so all algorithms show adaptation.
    if isOLLAFamily && fallbackUsed && ~allowFallbackToTrainOLLAFamily
        ctlinfoAlg = 0;
    end
    if ctlinfo == 0
        consecutiveHardFailCount = consecutiveHardFailCount + 1;
    else
        consecutiveHardFailCount = 0;
    end
    if freezeRemaining > 0
        ctlinfoAlg = 0;
        freezeRemaining = freezeRemaining - 1;
        controllerFreezeCount = controllerFreezeCount + 1;
        fprintf("  [Ctrl] Controller frozen for this iteration, remaining=%d.\n", freezeRemaining);
    elseif consecutiveHardFailCount >= 2
        freezeRemaining = 1;
        ctlinfoAlg = 0;
        controllerFreezeCount = controllerFreezeCount + 1;
        fprintf("  [Ctrl] Freeze triggered by consecutive hard failures.\n");
    end
    switch upper(char(algorithmMode))
        case 'AARF'
            [ackWave, MCS, msduFb] = ackarqtxAARF(ctlinfo,numampdu_next,bwdec_next,chanBW,MCS);
            if fallbackUsed && ~allowFallbackToTrainAARF
                % Conservative mode: do not train AARF state from fallback ACKs.
                MCS = prevMCS;
                msduFb(4) = MCS;
            end
        case 'OLLA'
            [ackWave, MCS, msduFb, deltaOLLAList] = ackarqtxOLLA( ...
                ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, chanBW, deltaOLLAList, MCSbuffer);
        case 'AOLLA'
            [ackWave, MCS, msduFb, PERList, deltaThresholdList] = ackarqtx701LMS( ...
                ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, chanBW, ctlinfoList, PERList, deltaThresholdList, MCSbuffer);
        case 'QLOLLA'
            [ackWave, MCS, msduFb, PERList, deltaThresholdList, numampdu_next] = ackarqtx1104QLearning( ...
                ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, chanBW, ctlinfoList, PERList, deltaThresholdList, MCSbuffer, beta1, beta2);
            if ctlinfoAlg ~= 0
                qLearningUpdateCount = qLearningUpdateCount + 1;
            end
            % Keep QLOLLA conservative: clamp the MCS jump and avoid
            % updating beta aggressively when the packet was only partially trusted.
            if ctlinfoAlg == 0
                MCS = prevMCS;
            elseif MCS > prevMCS + mcsStepCap
                MCS = prevMCS + mcsStepCap;
            elseif MCS < prevMCS - mcsStepCap
                MCS = prevMCS - mcsStepCap;
            end
            MCS = max(0, min(11, MCS));
            msduFb(4) = MCS;

            if qtableAvailable && mod(qLearningUpdateCount, runtimeBetaWindow) == 0
                state1 = localBetaState(beta1, beta1Grid);
                state2 = localBetaState(beta2, beta2Grid);
                r1 = localSelectQAction(Qtable_beta1, state1, runtimeExplorationEpsilon);
                r2 = localSelectQAction(Qtable_beta2, state2, runtimeExplorationEpsilon);
                [beta1, ~] = localApplyBetaAction(beta1, actVals(r1), beta1Grid);
                [beta2, ~] = localApplyBetaAction(beta2, actVals(r2), beta2Grid);
            end
        otherwise
            error("Unsupported algorithmMode: %s", algorithmMode);
    end
    if ctlinfo ~= 0
        MCSbuffer = MCS;
    end
    ackWave = ackWave / max(abs(ackWave)) * 0.8;
    ackWaveHW = upfirdn(ackWave, rFilterTx, p, q);  % resample to X410 rate

    % Update local state directly from feedback msdu (no need to decode over RF)
    ackarqinfo = string(char(msduFb(1:3)));
    numampduCandidate = min(msduFb(3+2),12);
    ChannelBWCandidate = msduFb(3+3);
    if ctlinfoAlg == 0
        % Do not let invalid / fallback packets move the controller state.
        MCS = prevMCS;
        numampduCandidate = numampdunew;
        ChannelBWCandidate = ChannelBWnewDec;
    end
    numampdunew = numampduCandidate;
    ChannelBWnewDec = ChannelBWCandidate;

    sampleForTuning = struct( ...
        'MCS', prevMCS, ...
        'AMPDU', numampdunew, ...
        'BWdec', ChannelBWnewDec, ...
        'TxPowerDb', gainDataTx, ...
        'PER', double(ctlinfo == 0), ...
        'ThroughputMbps', throughputNow, ...
        'Success', ctlinfo ~= 0, ...
        'BytesDelivered', bytesDelivered, ...
        'AirTimeSec', airTimeSec, ...
        'NextDecision', struct('MCS', MCS, 'AMPDU', numampdunew, 'BWdec', ChannelBWnewDec, 'TxPowerDb', gainDataTx));
    tuningState = x410_tuning_framework('update', tuningState, sampleForTuning);

    if doOverAirFeedback
        %% Optional: transmit feedback OTA (for realism/debug)
        bb.TransmitCenterFrequency = ackCenterFrequency;
        bb.TransmitRadioGain = gainAckTx;
        bb.CaptureCenterFrequency = ackCenterFrequency;
        bb.CaptureRadioGain = gainAckRx;

        ackDurationSec = numel(ackWaveHW)/hwSR;
        captureTimeAck = milliseconds(max(30,ceil(1000*min(0.3,3*ackDurationSec))));
        transmit(bb, ackWaveHW, "continuous");
        pause(0.005);
        stopTransmission(bb);
    end

    fprintf("Iter %d | fb=%s | next: MCS=%d AMPDU=%d BWdec=%d\n", ...
        n, ackarqinfo, MCS, numampdunew, ChannelBWnewDec);
    if mod(n,10) == 0
        fprintf("---- Progress %d/%d | current MCS=%d AMPDU=%d BWdec=%d ----\n", ...
            n, N, MCS, numampdunew, ChannelBWnewDec);
    end
end

fprintf("Done.\n");
fprintf("Stats | fallback=%d (%.1f%%), realDecode=%d (%.1f%%), qUpdate=%d\n", ...
    fallbackCount, 100*fallbackCount/max(1,N), ...
    realDecodeCount, 100*realDecodeCount/max(1,N), ...
    qLearningUpdateCount);
fprintf("StatsDiag | CFOoutliers=%d, NoPkt=%d, WrongTarget=%d, PacketDetectFail=%d, HESIGACRC=%d, FCSFail=%d, Packet2Success=%d, CtrlFreeze=%d\n", ...
    cfoOutlierCount, noPacketCountDiag, wrongTargetCount, packetDetectFailCount, ...
    sigaCrcFailCount, fcsFailCount, packet2SuccessCount, controllerFreezeCount);
if ~isempty(perHistory)
    fprintf("StatsPER | meanPER=%.3f, medianPER=%.3f\n", mean(perHistory), median(perHistory));
else
    fprintf("StatsPER | meanPER=NaN, medianPER=NaN\n");
end
if ~isempty(throughputHistoryMbps)
    fprintf("StatsTP | meanTput=%.2f Mbps, medianTput=%.2f Mbps, peakTput=%.2f Mbps\n", ...
        mean(throughputHistoryMbps), median(throughputHistoryMbps), max(throughputHistoryMbps));
else
    fprintf("StatsTP | meanTput=NaN Mbps, medianTput=NaN Mbps, peakTput=NaN Mbps\n");
end
fprintf("Final state | MCS=%d AMPDU=%d BWdec=%d lastSNR=%.2f dB\n", ...
    MCS, numampdunew, ChannelBWnewDec, snrMetricDbLast);
if enableRunDiary
    diary off;
end

%% Local helper (avoid extra files)
function out = ternary(cond,a,b)
if cond
    out = a;
else
    out = b;
end
end

function localStopTx(bb)
try
    stopTransmission(bb);
catch
end
end

function stateIdx = localBetaState(betaVal, betaGrid)
[~, stateIdx] = min(abs(betaGrid - betaVal));
end

function [betaNew, stateIdx] = localApplyBetaAction(betaVal, actionVal, betaGrid)
target = round((betaVal + actionVal) * 10) / 10;
target = max(betaGrid(1), min(betaGrid(end), target));
[~, stateIdx] = min(abs(betaGrid - target));
betaNew = betaGrid(stateIdx);
end

function row = localSelectQAction(Qtable, stateIdx, epsilon)
if rand(1) <= epsilon
    row = randi(size(Qtable, 1));
    return;
end
stateValues = Qtable(:, stateIdx);
maxVal = max(stateValues);
candidates = find(stateValues == maxVal);
row = candidates(randi(numel(candidates)));
end
