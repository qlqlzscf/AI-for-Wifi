%% X410 OTA TX node: data transmitter + feedback receiver
% Run this on the transmitter-side PC/MATLAB session.
clear; close all; clc;
runDir = fileparts(mfilename('fullpath'));
addpath(runDir);
cfg = X410_AirLink_Config("TX");
X410_AirSetupPath(cfg);

% Create radio object for the TX-side X410.
bb = basebandTransceiver(cfg.txRadioName);
bb.CaptureDataType = "double";
bb.SampleRate = cfg.hwSampleRate;

txAnts = hTransmitAntennas(cfg.txRadioName);
rxAnts = hCaptureAntennas(cfg.txRadioName);
bb.TransmitAntennas = txAnts(cfg.txPortIdx);
bb.CaptureAntennas  = rxAnts(cfg.rxPortIdx);

bb.TransmitCenterFrequency = cfg.dataCenterFrequency;
bb.TransmitRadioGain = cfg.dataTxGain;
bb.CaptureCenterFrequency = cfg.ackCenterFrequency;
bb.CaptureRadioGain = cfg.ackRxGain;

cleanupObj = onCleanup(@() localStopTx(bb));
assert(~isempty(cleanupObj));

MCS = cfg.initialMCS;
numAMPDU = cfg.initialAMPDU;
BWdec = cfg.initialBWdec;
chanBW = cfg.initialChanBW;
payload = uint8(ceil(256*rand(cfg.payloadLength,1)) - 1);

lastSig = "";
currentTxWaveHW = [];
prev_p = NaN; prev_q = NaN;
isTxOn = false;
lastFeedbackSeq = NaN;
noFeedbackCount = 0;
feedbackProtocol = struct( ...
    'magic', cfg.feedbackMagic, ...
    'version', cfg.feedbackVersion, ...
    'acceptLegacy', cfg.acceptLegacyFeedback);

fprintf("TX node started: data %.3f GHz -> ACK %.3f GHz\n", ...
    cfg.dataCenterFrequency/1e9, cfg.ackCenterFrequency/1e9);

for n = 1:cfg.N
    chanBW = localBWdec2Str(BWdec);
    wlanCfg = wlanHESUConfig;
    wlanCfg.ChannelBandwidth = char(chanBW);
    sr = wlanSampleRate(wlanCfg);

    [p, q, rFilterTx] = localTxResampler(cfg.hwSampleRate, sr, prev_p, prev_q);
    prev_p = p; prev_q = q;

    sig = string(sprintf("%s|MCS%d|AMPDU%d|LEN%d", char(chanBW), MCS, numAMPDU, numel(payload)));
    if isempty(currentTxWaveHW) || sig ~= lastSig
        [~,~,~,txWave] = HEWLANDataGenerator(numAMPDU, cfg.idleTime, MCS, char(chanBW), payload, length(payload));
        txWave = txWave / max(abs(txWave)) * cfg.dataTxScale;
        currentTxWaveHW = upfirdn(txWave, rFilterTx, p, q);
        if isTxOn
            try
                stopTransmission(bb);
            catch
            end
        end
        transmit(bb, currentTxWaveHW, "continuous");
        isTxOn = true;
        lastSig = sig;
        pause(0.02);
        fprintf("[TX %03d] Started data waveform: %s, hwSamples=%d\n", n, sig, numel(currentTxWaveHW));
    end

    % Listen for feedback on the ACK frequency while data is replaying.
    bb.CaptureCenterFrequency = cfg.ackCenterFrequency;
    bb.CaptureRadioGain = cfg.ackRxGain;
    rxAckHW = capture(bb, cfg.ackCaptureTime);
    [ok, fb, diag] = decodeFeedbackInfo(rxAckHW, cfg.ackChanBW, cfg.hwSampleRate, cfg.idleTime, feedbackProtocol);

    if ok && (fb.isLegacy || localIsNewSeq(fb.seq, lastFeedbackSeq))
        old = [MCS, numAMPDU, BWdec];
        noFeedbackCount = 0;
        MCS = fb.MCS;
        numAMPDU = fb.numAMPDU;
        if cfg.enableBandwidthAdaptation
            BWdec = fb.BWdec;
        else
            BWdec = cfg.initialBWdec;
        end
        if ~fb.isLegacy
            lastFeedbackSeq = fb.seq;
        end
        fprintf("[TX %03d] Feedback=%s seq=%s -> MCS %d->%d, AMPDU %d->%d, BWdec %d->%d\n", ...
            n, fb.tag, string(fb.seq), old(1), MCS, old(2), numAMPDU, old(3), BWdec);
    elseif ok
        noFeedbackCount = noFeedbackCount + 1;
        fprintf("[TX %03d] Stale feedback ignored: tag=%s seq=%s lastSeq=%s\n", ...
            n, fb.tag, string(fb.seq), string(lastFeedbackSeq));
    else
        noFeedbackCount = noFeedbackCount + 1;
        fprintf("[TX %03d] No valid feedback. recovery=%d stage=%s; keep MCS=%d AMPDU=%d BWdec=%d\n", ...
            n, diag.ctlinfoRecovery, string(diag.failStage), MCS, numAMPDU, BWdec);
    end

    if noFeedbackCount >= cfg.noFeedbackRollbackLimit
        old = [MCS, numAMPDU, BWdec];
        MCS = cfg.rollbackMCS;
        numAMPDU = cfg.rollbackAMPDU;
        if cfg.enableBandwidthAdaptation
            BWdec = cfg.rollbackBWdec;
        else
            BWdec = cfg.initialBWdec;
        end
        currentTxWaveHW = [];
        lastSig = "";
        noFeedbackCount = 0;
        if isTxOn
            try
                stopTransmission(bb);
            catch
            end
            isTxOn = false;
        end
        fprintf("[TX %03d] Feedback missing limit reached -> rollback MCS %d->%d, AMPDU %d->%d, BWdec %d->%d\n", ...
            n, old(1), MCS, old(2), numAMPDU, old(3), BWdec);
    end
end

fprintf("TX node done. Final MCS=%d AMPDU=%d BWdec=%d\n", MCS, numAMPDU, BWdec);

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

function [p, q, rFilterTx] = localTxResampler(hwSR, sr, ~, ~)
g = gcd(round(hwSR), round(sr));
p = round(hwSR / g);
q = round(sr / g);
Ntx = 2 * p * ceil(0.01 * p * q) + 1;
rFilterTx = designMultirateFIR(p, q, Ntx-1);
end

function localStopTx(bb)
try
    stopTransmission(bb);
catch
end
end

function tf = localIsNewSeq(seq, lastSeq)
if isnan(seq)
    tf = true;
elseif isnan(lastSeq)
    tf = true;
else
    delta = mod(double(seq) - double(lastSeq), 65536);
    tf = delta > 0 && delta < 32768;
end
end
