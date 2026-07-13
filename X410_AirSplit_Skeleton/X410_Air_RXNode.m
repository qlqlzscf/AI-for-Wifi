%% X410 OTA RX node: data receiver + feedback transmitter
% Run this on the receiver-side PC/MATLAB session. Start this before TXNode.
clear; close all; clc;
runDir = fileparts(mfilename('fullpath'));
addpath(runDir);
cfg = X410_AirLink_Config("RX");
X410_AirSetupPath(cfg);

bb = basebandTransceiver(cfg.rxRadioName);
bb.CaptureDataType = "double";
bb.SampleRate = cfg.hwSampleRate;

txAnts = hTransmitAntennas(cfg.rxRadioName);
rxAnts = hCaptureAntennas(cfg.rxRadioName);
bb.TransmitAntennas = txAnts(cfg.txPortIdx);   % used for ACK
bb.CaptureAntennas  = rxAnts(cfg.rxPortIdx);   % used for data

bb.CaptureCenterFrequency = cfg.dataCenterFrequency;
bb.CaptureRadioGain = cfg.dataRxGain;
bb.TransmitCenterFrequency = cfg.ackCenterFrequency;
bb.TransmitRadioGain = cfg.ackTxGain;

MCS = cfg.initialMCS;
MCSbuffer = MCS;
numAMPDU = cfg.initialAMPDU;
BWdec = cfg.initialBWdec;
ctlinfoList = [];
PERList = [];
deltaThresholdList = [];
deltaOLLAList = [];
beta1 = 0.4;
beta2 = 1.8;
mcsStepCap = cfg.mcsStepCap;
qtableAvailable = false;
qtableMode = "none";
beta1Grid = 0.2:0.1:0.8;
beta2Grid = 1.2:0.1:2.4;
actVals = [-0.1; 0; 0.1];
runtimeBetaWindow = 25;

qtableFile = fullfile(cfg.enhancedCoreDir, "Qtable_X410.mat");
if exist(qtableFile, "file")
    qtab = load(qtableFile);
    if isfield(qtab, "Qtable_beta1") && isfield(qtab, "Qtable_beta2")
        Qtable_beta1 = qtab.Qtable_beta1;
        Qtable_beta2 = qtab.Qtable_beta2;
        if isfield(qtab, "beta1Grid"), beta1Grid = qtab.beta1Grid; end
        if isfield(qtab, "beta2Grid"), beta2Grid = qtab.beta2Grid; end
        if isfield(qtab, "actionSpace"), actVals = qtab.actionSpace; end
        if isfield(qtab, "WQLearning"), runtimeBetaWindow = qtab.WQLearning; end
        if isfield(qtab, "qtableMode")
            qtableMode = string(qtab.qtableMode);
        elseif size(Qtable_beta1, 2) == numel(beta1Grid) && size(Qtable_beta2, 2) == numel(beta2Grid)
            qtableMode = "beta-state";
        elseif size(Qtable_beta1, 2) == 12 && size(Qtable_beta2, 2) == 12
            qtableMode = "per-state";
        end
        qtableAvailable = true;
        fprintf("Loaded Q-tables (%s) from: %s\n", qtableMode, qtableFile);
    else
        fprintf("Q-table file exists but required variables are missing: %s\n", qtableFile);
    end
else
    fprintf("No Q-table found; QLOLLA uses default beta values.\n");
end

realDecodeCount = 0;
qLearningUpdateCount = 0;
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

feedbackProtocol = struct( ...
    'magic', cfg.feedbackMagic, ...
    'version', cfg.feedbackVersion);

if ~exist(cfg.csiLogDir, "dir"), mkdir(cfg.csiLogDir); end

prev_p = NaN; prev_q = NaN;
prevAck_p = NaN; prevAck_q = NaN;

fprintf("RX node started: data %.3f GHz -> ACK %.3f GHz\n", ...
    cfg.dataCenterFrequency/1e9, cfg.ackCenterFrequency/1e9);

for n = 1:cfg.N
    chanBW = localBWdec2Str(BWdec);
    wlanCfg = wlanHESUConfig;
    wlanCfg.ChannelBandwidth = char(chanBW);
    sr = wlanSampleRate(wlanCfg);
    [p, q, rFilterRx] = localRxResampler(cfg.hwSampleRate, sr, prev_p, prev_q);
    prev_p = p; prev_q = q;

    % Capture data packet(s).
    bb.CaptureCenterFrequency = cfg.dataCenterFrequency;
    bb.CaptureRadioGain = cfg.dataRxGain;
    rxDataHW = capture(bb, cfg.dataCaptureTime);
    rxRMS = sqrt(mean(abs(rxDataHW(:)).^2));
    rxPeak = max(abs(rxDataHW(:)));
    rxData = upfirdn(rxDataHW, rFilterRx, q, p);

    rxDiagCtx = struct('iter',n,'txPeriodSamples',NaN,'txPeriodHwSamples',NaN, ...
        'captureSamples',size(rxData,1),'sampleRate',sr,'hwSampleRate',cfg.hwSampleRate, ...
        'MCS',MCS,'AMPDU',numAMPDU,'BWdec',BWdec, ...
        'cfoRejectThresholdHz',cfg.cfoRejectThresholdHz);

    ctlinfo = 0; SNRest = []; rxnumampdu = numAMPDU; rmsEVMsym = []; rmsEVMsc = []; %#ok<NASGU>
    RXTime = []; csiData = []; chanEst = [];
    failStage = ""; recoveryDiag = localDefaultRecoveryDiag();
    try
        if nargout('HEWLANDataRecovery') >= 13
            [~,~,rxnumampdu,SNRest,RXTime,~,~,~,ctlinfo,rmsEVMsym,rmsEVMsc,failStage,recoveryDiag,csiData,chanEst] = ...
                HEWLANDataRecovery(char(chanBW), sr, rxData, cfg.idleTime, rxDiagCtx);
        else
            [~,~,rxnumampdu,SNRest,RXTime,~,~,~,ctlinfo,rmsEVMsym,rmsEVMsc] = ...
                HEWLANDataRecovery(char(chanBW), sr, rxData, cfg.idleTime);
        end
    catch ME
        failStage = "recovery_exception: " + string(ME.message);
        ctlinfo = 0;
    end
    recoveryDiag = localFillRecoveryDiag(recoveryDiag);
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
    else
        snrMetricDb = max(5, min(35, 20*log10(max(rxRMS,1e-6)/1e-2)));
    end

    fprintf("[RX %03d] ctlinfo=%d stage=%s SNR=%.2f dB RMS=%.3e Peak=%.3e MCS=%d AMPDU=%d BWdec=%d\n", ...
        n, ctlinfo, string(failStage), snrMetricDb, rxRMS, rxPeak, MCS, numAMPDU, BWdec);

    if ctlinfo ~= 0
        realDecodeCount = realDecodeCount + 1;
        ctlinfoList = [ctlinfoList; ctlinfo]; %#ok<AGROW>
        MCSbuffer = MCS;
        if exist('csiData','var') && ~isempty(csiData)
            csiTag = char(datetime("now", "Format", "yyyyMMdd_HHmmss"));
            csiFile = fullfile(cfg.csiLogDir, sprintf("csi_OTA_iter%03d_%s_MCS%d_AMPDU%d.mat", ...
                n, csiTag, MCS, numAMPDU));
            save(csiFile, 'csiData', 'chanEst', 'SNRest', 'MCS', 'chanBW', 'sr', ...
                'rmsEVMsym', 'rmsEVMsc', 'ctlinfo', 'rxnumampdu', 'RXTime', 'recoveryDiag', 'rxDiagCtx');
        end
    end

    % Conservative AMPDU update; keep BW fixed during OTA bring-up by default.
    numampdu_next = numAMPDU;
    if ctlinfo == 1 && ~isempty(rxnumampdu)
        numampdu_next = min(12, max(1, double(rxnumampdu) + 1));
    elseif ctlinfo == 2 && ~isempty(rxnumampdu)
        numampdu_next = max(1, double(rxnumampdu) - 1);
    end
    if cfg.enableBandwidthAdaptation
        bwdec_next = BWdec;
    else
        bwdec_next = cfg.initialBWdec;
    end

    prevMCS = MCS;
    ctlinfoAlg = ctlinfo;
    if ctlinfo == 0
        consecutiveHardFailCount = consecutiveHardFailCount + 1;
    else
        consecutiveHardFailCount = 0;
    end
    if freezeRemaining > 0
        ctlinfoAlg = 0;
        freezeRemaining = freezeRemaining - 1;
        controllerFreezeCount = controllerFreezeCount + 1;
        fprintf("[RX %03d] Controller frozen, remaining=%d.\n", n, freezeRemaining);
    elseif consecutiveHardFailCount >= cfg.freezeAfterConsecutiveEvents
        freezeRemaining = cfg.freezeDuration;
        ctlinfoAlg = 0;
        controllerFreezeCount = controllerFreezeCount + 1;
        fprintf("[RX %03d] Controller freeze triggered by consecutive hard failures.\n", n);
    end

    switch upper(char(cfg.algorithmMode))
        case 'AARF'
            [~, MCSnext, msduFb] = ackarqtxAARF(ctlinfoAlg, numampdu_next, bwdec_next, char(cfg.ackChanBW), MCS);
        case 'OLLA'
            [~, MCSnext, msduFb, deltaOLLAList] = ackarqtxOLLA(ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, char(cfg.ackChanBW), deltaOLLAList, MCSbuffer);
        case 'AOLLA'
            [~, MCSnext, msduFb, PERList, deltaThresholdList] = ackarqtx701LMS(ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, char(cfg.ackChanBW), ctlinfoList, PERList, deltaThresholdList, MCSbuffer);
        case 'QLOLLA'
            [~, MCSnext, msduFb, PERList, deltaThresholdList, numampdu_next] = ackarqtx1104QLearning(ctlinfoAlg, snrMetricDb, numampdu_next, bwdec_next, char(cfg.ackChanBW), ctlinfoList, PERList, deltaThresholdList, MCSbuffer, beta1, beta2);
            if ctlinfoAlg ~= 0
                qLearningUpdateCount = qLearningUpdateCount + 1;
            end
            if qtableAvailable && ctlinfoAlg ~= 0 && mod(qLearningUpdateCount, runtimeBetaWindow) == 0
                if qtableMode == "beta-state"
                    state1 = localBetaState(beta1, beta1Grid);
                    state2 = localBetaState(beta2, beta2Grid);
                    r1 = localSelectQAction(Qtable_beta1, state1, cfg.explorationEpsilon);
                    r2 = localSelectQAction(Qtable_beta2, state2, cfg.explorationEpsilon);
                    [beta1, ~] = localApplyBetaAction(beta1, actVals(r1), beta1Grid);
                    [beta2, ~] = localApplyBetaAction(beta2, actVals(r2), beta2Grid);
                elseif qtableMode == "per-state"
                    perState = localComputePERState(ctlinfoList, 25);
                    r1 = localSelectQAction(Qtable_beta1, perState, cfg.explorationEpsilon);
                    r2 = localSelectQAction(Qtable_beta2, perState, cfg.explorationEpsilon);
                    beta1 = max(0.2, min(0.8, round((actVals(r1) + beta1)*10)/10));
                    beta2 = max(1.2, min(2.4, round((actVals(r2) + beta2)*10)/10));
                end
            end
        otherwise
            error("Unsupported algorithmMode: %s", cfg.algorithmMode);
    end

    if ctlinfoAlg == 0
        MCSnext = prevMCS;
        msduFb(4) = prevMCS;
        msduFb(5) = numAMPDU;
        msduFb(6) = BWdec;
    elseif MCSnext > prevMCS + mcsStepCap
        MCSnext = prevMCS + mcsStepCap;
        msduFb(4) = MCSnext;
    elseif MCSnext < prevMCS - mcsStepCap
        MCSnext = prevMCS - mcsStepCap;
        msduFb(4) = MCSnext;
    end
    if ~cfg.enableBandwidthAdaptation
        msduFb(6) = cfg.initialBWdec;
    end

    MCS = max(0, min(11, MCSnext));
    numAMPDU = max(1, min(12, double(msduFb(5))));
    BWdec = double(msduFb(6));
    if ~ismember(BWdec, [2 4 8 16]), BWdec = cfg.initialBWdec; end

    % Transmit feedback over ACK frequency using fixed robust CBW20/MCS0 waveform.
    ackCfg = wlanHESUConfig;
    ackCfg.ChannelBandwidth = char(cfg.ackChanBW);
    ackSr = wlanSampleRate(ackCfg);
    [ack_p, ack_q, rFilterTxAck] = localTxResampler(cfg.hwSampleRate, ackSr, prevAck_p, prevAck_q);
    prevAck_p = ack_p; prevAck_q = ack_q;
    [ackWave, feedbackPayload] = buildFeedbackWaveform(msduFb, n, char(cfg.ackChanBW), cfg.idleTime, feedbackProtocol);
    ackWave = ackWave / max(abs(ackWave)) * cfg.feedbackTxScale;
    ackWaveHW = upfirdn(ackWave, rFilterTxAck, ack_p, ack_q);

    bb.TransmitCenterFrequency = cfg.ackCenterFrequency;
    bb.TransmitRadioGain = cfg.ackTxGain;
    transmit(bb, ackWaveHW, "once");
    pause(max(0.01, numel(ackWaveHW)/cfg.hwSampleRate + 0.005));
    fprintf("[RX %03d] Sent feedback=%s seq=%d bytes=%d next MCS=%d AMPDU=%d BWdec=%d\n", ...
        n, string(char(msduFb(1:3))), n, numel(feedbackPayload), MCS, numAMPDU, BWdec);
end

fprintf("RX node done. Final MCS=%d AMPDU=%d BWdec=%d\n", MCS, numAMPDU, BWdec);
fprintf("Stats | realDecode=%d (%.1f%%), qUpdate=%d\n", ...
    realDecodeCount, 100*realDecodeCount/max(1,cfg.N), qLearningUpdateCount);
fprintf("StatsDiag | CFOoutliers=%d, NoPkt=%d, WrongTarget=%d, PacketDetectFail=%d, HESIGACRC=%d, FCSFail=%d, Packet2Success=%d, CtrlFreeze=%d\n", ...
    cfoOutlierCount, noPacketCountDiag, wrongTargetCount, packetDetectFailCount, ...
    sigaCrcFailCount, fcsFailCount, packet2SuccessCount, controllerFreezeCount);

function out = localBWdec2Str(bwdec)
if bwdec == 2
    out = "CBW20";
elseif bwdec == 4
    out = "CBW40";
elseif bwdec == 8
    out = "CBW80";
else
    out = "CBW160";
end
end

function [p, q, rFilterRx] = localRxResampler(hwSR, sr, ~, ~)
g = gcd(round(hwSR), round(sr));
p = round(hwSR / g);
q = round(sr / g);
Nrx = 2 * q * ceil(0.01 * p * q) + 1;
rFilterRx = designMultirateFIR(q, p, Nrx-1);
end

function [p, q, rFilterTx] = localTxResampler(hwSR, sr, ~, ~)
g = gcd(round(hwSR), round(sr));
p = round(hwSR / g);
q = round(sr / g);
Ntx = 2 * p * ceil(0.01 * p * q) + 1;
rFilterTx = designMultirateFIR(p, q, Ntx-1);
end

function diag = localDefaultRecoveryDiag()
diag = struct( ...
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
    'lstfQualitySkipCount', 0, ...
    'candidateCount', 0, ...
    'cfoOutlierOffsets', [], ...
    'cfoOutlierPhase', [], ...
    'suspiciousSuccess', false);
end

function diag = localFillRecoveryDiag(diag)
defaults = localDefaultRecoveryDiag();
if isempty(diag) || ~isstruct(diag)
    diag = defaults;
    return;
end
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(diag, names{k})
        diag.(names{k}) = defaults.(names{k});
    end
end
end

function stateIdx = localComputePERState(ctlinfoList, windowSize)
if length(ctlinfoList) < windowSize
    stateIdx = 6;
    return;
end
recent = ctlinfoList(end-windowSize+1:end);
PER = localWeightedPER(recent);

if PER <= 0.01
    level = 1;
elseif PER <= 0.05
    level = 2;
elseif PER <= 0.15
    level = 3;
else
    level = 4;
end

half = floor(windowSize/2);
oldPER = localWeightedPER(recent(1:half));
newPER = localWeightedPER(recent(end-half+1:end));
delta = newPER - oldPER;

if delta < -0.02
    trend = 1;
elseif delta > 0.02
    trend = 3;
else
    trend = 2;
end

stateIdx = (level-1)*3 + trend;
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

function per = localWeightedPER(values)
per = sum(values == 2) / max(1, length(values));
end
