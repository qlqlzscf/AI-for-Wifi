%% Offline TX EVM test — bypass X410, measure TX waveform quality directly
clear; close all;

chanBW = 'CBW80';
numampdu = 5;
idleTime = 20e-6;
MCS = 5;
payload = randi([0 1], 800, 1);

% Generate TX waveform
fprintf('=== TX waveform (MCS=%d, AMPDU=%d, %s) ===\n', MCS, numampdu, chanBW);
[~, sr, ~, txWave] = HEWLANDataGenerator(numampdu, idleTime, MCS, chanBW, payload, length(payload));
txWave = txWave / max(abs(txWave)) * 0.7;
fprintf('Samples=%d sr=%.0f MHz peak=%.3f rms=%.3f\n', ...
    length(txWave), sr/1e6, max(abs(txWave)), sqrt(mean(abs(txWave).^2)));

% SU config for RX processing
cfgSU = wlanHESUConfig;
cfgSU.ChannelBandwidth = chanBW;
cfgSU.MCS = MCS;
cfgSU.NumSpaceTimeStreams = 1;
cfgSU.NumTransmitAntennas = 1;
cfgSU.APEPLength = length(payload);

ind = wlanFieldIndices(cfgSU);
ruAlloc = ruInfo(cfgSU);
ruSize = ruAlloc.RUSizes(1);
ruIndex = ruAlloc.RUIndices(1);
gi = 0.8;  % microseconds (not seconds)
fprintf('HELTF [%d %d]  HEData [%d %d]  RU=%d\n', ...
    ind.HELTF(1), ind.HELTF(2), ind.HEData(1), ind.HEData(2), ruSize);

if ind.HELTF(2) > size(txWave,1)
    error('HELTF end (%d) > wavelen (%d)', ind.HELTF(2), size(txWave,1));
end

% ---- HE-LTF demod + channel estimation ----
rxHELTF = txWave(ind.HELTF(1):ind.HELTF(2), :);
heltfDemod = wlanHEDemodulate(rxHELTF, 'HE-LTF', chanBW, gi, cfgSU.HELTFType, [ruSize ruIndex]);
[chanEst, pilotEst] = heLTFChannelEstimate(heltfDemod, cfgSU, 1);
fprintf('ChanEst |h| mean: %.4f\n', mean(abs(chanEst(:))));

% ---- HE-Data demod (no HELTFType arg for data!) ----
heInfo = wlanHEOFDMInfo('HE-Data', chanBW, gi, [ruSize ruIndex]);
rxData = txWave(ind.HEData(1):ind.HEData(2), :);
demodSym = wlanHEDemodulate(rxData, 'HE-Data', chanBW, gi, [ruSize ruIndex]);

% ---- Noise + equalize ----
demodPilotSym = demodSym(heInfo.PilotIndices, :, :);
nVarEst = heNoiseEstimate(demodPilotSym, pilotEst, cfgSU);
[eqSym, ~] = heEqualizeCombine(demodSym, chanEst, nVarEst, cfgSU);
eqSymUser = eqSym(heInfo.DataIndices, :, :);

% ---- EVM ----
evmSym = 20*log10(mean(myHePlotEVMPerSymbol(eqSymUser, cfgSU)));
evmSC  = 20*log10(mean(myHePlotEVMPerSubcarrier(eqSymUser, cfgSU)));
fprintf('\n=== Offline EVM (no X410, no CFO, no noise) ===\n');
fprintf('EVM per-sym: %.2f dB | EVM per-sc: %.2f dB\n\n', evmSym, evmSC);

% ---- MCS sweep ----
fprintf('=== MCS sweep ===\n');
for testMCS = [1 3 5 7 9 11]
    cfgSU.MCS = testMCS;
    cfgSU.APEPLength = 100;
    [~, ~, ~, txW] = HEWLANDataGenerator(1, 20e-6, testMCS, chanBW, ...
        randi([0 1], 100, 1), 100);
    txW = txW / max(abs(txW)) * 0.7;

    ind2 = wlanFieldIndices(cfgSU);
    ra2 = ruInfo(cfgSU);
    rs2 = ra2.RUSizes(1); ri2 = ra2.RUIndices(1);

    if ind2.HELTF(2) > size(txW,1) || ind2.HEData(2) > size(txW,1)
        fprintf('  MCS=%2d: SKIP\n', testMCS); continue;
    end

    rxH = txW(ind2.HELTF(1):ind2.HELTF(2), :);
    hDemod = wlanHEDemodulate(rxH, 'HE-LTF', chanBW, gi, cfgSU.HELTFType, [rs2 ri2]);
    [chEst, pEst] = heLTFChannelEstimate(hDemod, cfgSU, 1);

    info2 = wlanHEOFDMInfo('HE-Data', chanBW, gi, [rs2 ri2]);
    rxD = txW(ind2.HEData(1):ind2.HEData(2), :);
    dSym = wlanHEDemodulate(rxD, 'HE-Data', chanBW, gi, [rs2 ri2]);

    dPS = dSym(info2.PilotIndices, :, :);
    nv = heNoiseEstimate(dPS, pEst, cfgSU);
    [eSym, ~] = heEqualizeCombine(dSym, chEst, nv, cfgSU);
    eSU = eSym(info2.DataIndices, :, :);

    fprintf('  MCS=%2d | EVM per-sym: %5.1f dB | EVM per-sc: %5.1f dB\n', ...
        testMCS, 20*log10(mean(myHePlotEVMPerSymbol(eSU, cfgSU))), ...
        20*log10(mean(myHePlotEVMPerSubcarrier(eSU, cfgSU))));
end

fprintf('\nEVM < -35 dB: TX chain clean -> X410 hardware issue\n');
fprintf('EVM > -25 dB: TX or demod chain issue\n');
