%% X410 Q-Learning Offline Training
% 训练 Q 表以优化 QLOLLA 的 beta1/beta2 参数。
% 跑 N 轮后保存 Qtable_X410.mat，可被 X410_runSingleHost_DualRole_AARF.m 加载。
%
% 硬件前提：
% - X410 已通电，通过 10GbE 与电脑在同一子网
% - Radio Setup 已配置并验证
% - TX/RX 端口间有电缆环回 + 衰减器

clear all; close all; clc;

%% Training parameters
N = 10000;                      % total iterations
saveInterval = 1000;            % save Q-table every N iterations
enableRunDiary = false;         % set true to log to file
runDir = fileparts(mfilename("fullpath"));
qtableFile = fullfile(runDir, "Qtable_X410.mat");

if enableRunDiary
    logDir = fullfile(runDir, "logs");
    if ~exist(logDir, "dir"), mkdir(logDir); end
    runTag = datestr(now, "yyyymmdd_HHMMSS");
    logFile = fullfile(logDir, sprintf("run_QLOLLA_TRAIN_%s.log", runTag));
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
        "Unable to create basebandTransceiver: " + string(radioName)
        "Make sure X410 is powered on and reachable."
        "Original error:"
        string(ME.message)
    ], newline));
end

txPortIdx = 1; % DB0:RF0:TX/RX0
rxPortIdx = 1; % DB0:RF0:RX1
txAnts = hTransmitAntennas(radioName);
rxAnts = hCaptureAntennas(radioName);
bb.TransmitAntennas = txAnts(txPortIdx);
bb.CaptureAntennas = rxAnts(rxPortIdx);

%% RF parameters
txCenterFrequency  = 3.184e9;
ackCenterFrequency = 1.784e9;
gainDataTx = 20;
gainDataRx = 25;
gainAckTx  = 0;
gainAckRx  = 45;
duplexMode = "simultaneous";
gainStepRx = 5;
gainStepTx = 5;

% Channel profiles for training diversity (covers all 12 PER states)
% Each profile: {attenuation dB, probability weight}
% Att applied to BOTH TX and RX to simulate path loss realistically
channelProfiles = {
    25, 0.04;   % TX= 0 RX= 0  → SNR~25dB → PER 15-30% → states 10-12
    20, 0.08;   % TX= 0 RX= 5  → SNR~30dB → PER 5-15%  → states 7-9
    15, 0.13;   % TX= 5 RX=10  → SNR~35dB → PER 1-5%   → states 4-6
    10, 0.20;   % TX=10 RX=15  → SNR~40dB → PER ≤1%    → states 1-3
     5, 0.25;   % TX=15 RX=20  → SNR~45dB → PER ~0%    → states 1-2
     0, 0.30;   % TX=20 RX=25  → SNR~50dB → PER ~0%    → states 1-2
};
chanCumWts = cumsum(cell2mat(channelProfiles(:,2)));

fprintf("X410 Q-Learning Training | N=%d | saveInterval=%d\n", N, saveInterval);
fprintf("  Q-table file: %s\n", qtableFile);
fprintf("  TX=%g dB RX=%g dB\n", gainDataTx, gainDataRx);

%% Packet timing
idleTime = 2e-6;

%% Initial link state (conservative start)
MCS = 0;
numampdunew = 1;
ChannelBWnewDec = 2; % CBW20

%% Payload
length_txcode = 2304;
payload = uint8(ceil(256*rand(length_txcode,1)) - 1);

%% LMS state
ctlinfoList = [];
PERList = [];
deltaThresholdList = [];
MCSbuffer = MCS;
snrMetricDbLast = 15;

%% Q-learning state
WQLearning = 25;
Nt = 0;
kQL = 1;
epsilon = 1;
epsilonTarget = 0.05;
gamaQL = 0.9;
alpha1_q = 0.1;
alpha2_q = 0.1;
beta1new = 0.4;
beta2new = 1.8;
qtableMode = "beta-state";

% Paper-aligned state: each Q-table uses its own beta value as the state.
% Existing MCSdef1104QLearning uses beta1 in [0.2,0.8] and beta2 in [1.2,2.4].
beta1Grid = 0.2:0.1:0.8;
beta2Grid = 1.2:0.1:2.4;
actionSpace = [-0.1; 0; 0.1];
numActions = numel(actionSpace);
Qtable_beta1 = zeros(numActions, numel(beta1Grid));
Qtable_beta2 = zeros(numActions, numel(beta2Grid));
Qvisit_beta1 = false(size(Qtable_beta1));
Qvisit_beta2 = false(size(Qtable_beta2));
currentState1 = localBetaState(beta1new, beta1Grid);
currentState2 = localBetaState(beta2new, beta2Grid);
activeState1 = currentState1;
activeState2 = currentState2;
windowStartNt = 1;
epsilonDecayUpdates = max(1, ceil(N / WQLearning));
epsilonStep = (epsilon - epsilonTarget) / epsilonDecayUpdates;

feedbackQ = zeros(6, N);

% Reward history for plotting
rewardHistory = zeros(ceil(N / WQLearning), 1);
rewardIter = zeros(ceil(N / WQLearning), 1);
rewardIdx = 0;

% Training trajectory tracking
beta1History = zeros(ceil(N / WQLearning), 1);
beta2History = zeros(ceil(N / WQLearning), 1);
stateHistory = zeros(ceil(N / WQLearning), 2);
epsilonHistory = zeros(ceil(N / WQLearning), 1);
mcsHistory = [];
perHistoryAll = [];
stateVisits1 = zeros(numel(beta1Grid), 1);
stateVisits2 = zeros(numel(beta2Grid), 1);

PacketDuration = [
    1348 3908 0     0     0;
    708  1988 3908  0     0;
    484  1348 2628  3908  5188;
    388  1028 1988  2948  3908;
    276  708  1348  1988  2628;
    228  548  1028  1508  1988;
    196  484  916   1348  1764;
    196  452  836   1220  1604;
    164  388  708   1028  1348;
    164  356  644   932   1220;
    148  324  580   836   1092;
    132  292  516   756   980
];

%% Helpers
bwDec2Str = @(bwdec) ternary(bwdec==2, "CBW20", ternary(bwdec==4, "CBW40", "CBW80"));

%% Main training loop
isTxOn = false;
currentTxWaveHW = [];
lastTxSignature = "";

% X410 native sample rate (WLAN rate requires software resampling)
hwSR = 250e6;
bb.SampleRate = hwSR;
pause(0.2);  % let FPGA reconfigure after sample rate change

fprintf("\n=== Starting training loop ===\n");
tic;

% Select the first action once, then keep it for one Q-learning window.
[action1, action2] = fActionSelect(epsilon, Qtable_beta1, Qtable_beta2, ...
    Qvisit_beta1, Qvisit_beta2, activeState1, activeState2, actionSpace);
[beta1new, currentState1] = localApplyBetaAction(beta1new, action1, beta1Grid);
[beta2new, currentState2] = localApplyBetaAction(beta2new, action2, beta2Grid);
fprintf("Initial Q action | beta1 %.1f -> %.1f, beta2 %.1f -> %.1f, eps=%.2f\n", ...
    beta1Grid(activeState1), beta1new, beta2Grid(activeState2), beta2new, epsilon);

for n = 1:N
    chanBW = char(bwDec2Str(ChannelBWnewDec));

    cfgSU = wlanHESUConfig;
    cfgSU.ChannelBandwidth = chanBW;
    sr = wlanSampleRate(cfgSU);
    % hwSR / bb.SampleRate set once outside the loop
    % Resample ratio p/q: hwSR/sr = p/q
    g = gcd(round(hwSR), round(sr));
    p = round(hwSR / g);
    q = round(sr / g);

    %% Channel variation — pick random profile for training diversity
    r = rand(1);
    chanIdx = find(chanCumWts >= r, 1);
    attnDB = channelProfiles{chanIdx, 1};

    %% TX
    bb.TransmitCenterFrequency = txCenterFrequency;
    bb.TransmitRadioGain = max(0, gainDataTx - attnDB);
    bb.CaptureCenterFrequency = txCenterFrequency;
    bb.CaptureRadioGain = max(0, gainDataRx - attnDB);

    txSig = sprintf("%s|%d|%d|%d", chanBW, MCS, numampdunew, length(payload));
    if isempty(currentTxWaveHW) || ~strcmp(txSig, lastTxSignature)
        [~,~,~,txWave] = HEWLANDataGenerator(numampdunew, idleTime, MCS, chanBW, payload, length(payload));
        txWave = txWave / max(abs(txWave)) * 0.7;
        % Resample to X410 native sample rate
        currentTxWaveHW = resample(txWave, p, q);
        lastTxSignature = txSig;
        if isTxOn
            try, stopTransmission(bb); catch, end
            isTxOn = false;
        end
    end

    txDurationSec = numel(currentTxWaveHW) / hwSR;
    captureTimeData = milliseconds(max(35, ceil(1000 * min(0.25, 2 * txDurationSec))));

    if duplexMode == "simultaneous"
        if ~isTxOn
            for txRetry = 1:3
                try
                    transmit(bb, currentTxWaveHW, "continuous");
                    isTxOn = true;
                    break;
                catch ME
                    fprintf("  [TX retry %d/3] %s\n", txRetry, ME.message);
                    pause(0.5);
                end
            end
            if ~isTxOn
                error("Transmit failed after 3 retries.");
            end
            pause(0.02);
        end
        rxDataWave = capture(bb, captureTimeData);
    else
        [~,~,~,txWave] = HEWLANDataGenerator(numampdunew, idleTime, MCS, chanBW, payload, length(payload));
        txWave = txWave / max(abs(txWave)) * 0.8;
        txWaveHW = resample(txWave, p, q);
        transmit(bb, txWaveHW, "continuous");
        pause(max(0.02, 2*(numel(txWaveHW)/hwSR)));
        try, stopTransmission(bb); catch, end
        pause(0.01);
        rxDataWave = capture(bb, captureTimeData);
    end

    dropMs = 5;
    dropSamp = min(size(rxDataWave,1), round((dropMs/1000)*hwSR));
    if dropSamp > 0 && size(rxDataWave,1) > dropSamp
        rxDataWave = rxDataWave(dropSamp+1:end,:);
    end

    rxRMS = sqrt(mean(abs(rxDataWave).^2));
    rxPeak = max(abs(rxDataWave));

    % Resample captured data from hwSR back to WLAN sample rate sr
    rxDataWave = resample(rxDataWave, q, p);

    if rxPeak > 0.9
        gainDataTx = max(0, gainDataTx - gainStepTx);
        gainDataRx = max(0, gainDataRx - gainStepRx);
        fprintf("  [AutoGain] n=%d Saturation -> TX=%g RX=%g\n", n, gainDataTx, gainDataRx);
    end

    %% RX decode
    ctlinfo = 0;
    rmsEVMsym = [];
    rmsEVMsc = [];
    SNRest = [];
    try
        [~,~,rxnumampdu,SNRest,~,~,~,~,ctlinfo,rmsEVMsym,rmsEVMsc] = HEWLANDataRecovery(chanBW, sr, rxDataWave, idleTime);
    catch
        ctlinfo = 0;
    end
    if ~isempty(SNRest)
        snrMetricDb = mean(SNRest);
        snrMetricDbLast = snrMetricDb;
    else
        snrMetricDb = 20*log10(max(rxRMS,1e-6)/1e-2);
        snrMetricDb = max(5, min(35, snrMetricDb));
        snrMetricDbLast = snrMetricDb;
    end
    if ctlinfo ~= 0
        ctlinfoList = [ctlinfoList; ctlinfo]; %#ok<AGROW>
    end

    %% AMPDU heuristic
    numampdu_next = numampdunew;
    if ~isempty(rmsEVMsym) && rxnumampdu > 0
        SNRSwap = ceil(length(rmsEVMsym)/rxnumampdu);
        SNRtime = [];
        if SNRSwap > 0
            for i = 1:max(1, ceil(length(rmsEVMsym)/SNRSwap))
                lo = 1+(i-1)*SNRSwap;
                hi = min(i*SNRSwap, length(rmsEVMsym));
                if lo <= hi
                    SNRtime(i) = mean(rmsEVMsym(lo:hi)); %#ok<AGROW>
                end
            end
        end
        if ~isempty(SNRtime)
            if max(SNRtime)-min(SNRtime) > 8
                numampdu_next = max(1, rxnumampdu-3);
            elseif ctlinfo == 1
                numampdu_next = min(12, rxnumampdu+3);
            else
                numampdu_next = rxnumampdu;
            end
        end
    end

    bwdec_next = min(ChannelBWnewDec, 16);

    %% QLOLLA decision
    prevMCS = MCS;
    [ackWave, MCS, msduFb, PERList, deltaThresholdList, numampdu_next] = ackarqtx1104QLearning( ...
        ctlinfo, snrMetricDb, numampdu_next, bwdec_next, chanBW, ctlinfoList, PERList, deltaThresholdList, MCSbuffer, beta1new, beta2new);
    if ctlinfo ~= 0
        MCSbuffer = MCS;
    end
    ackWave = ackWave / max(abs(ackWave)) * 0.8;

    %% Feedback recording
    ampdu_used = numampdunew;
    bw_used = ChannelBWnewDec;
    if ctlinfo ~= 0
        Nt = Nt + 1;
        feedbackQ(1, Nt) = ctlinfo;
        feedbackQ(2, Nt) = prevMCS;
        feedbackQ(3, Nt) = ampdu_used;
        feedbackQ(4, Nt) = bw_used;
        feedbackQ(5, Nt) = snrMetricDb;
        feedbackQ(6, Nt) = txDurationSec;
        mcsHistory(end+1) = prevMCS;
        if length(ctlinfoList) >= 25
            perHistoryAll(end+1) = sum(ctlinfoList(end-24:end) == 2) / 25;
        end
    end

    %% Q-learning update
    while Nt - windowStartNt + 1 >= WQLearning
        rewardState = feedbackQ(:, windowStartNt : windowStartNt + WQLearning - 1);
        reward_k = fRewardCal(rewardState, PacketDuration);
        rewardIdx = rewardIdx + 1;
        rewardHistory(rewardIdx) = reward_k;
        rewardIter(rewardIdx) = n;
        beta1History(rewardIdx) = beta1new;
        beta2History(rewardIdx) = beta2new;
        stateHistory(rewardIdx, :) = [currentState1 currentState2];
        epsilonHistory(rewardIdx) = epsilon;
        stateVisits1(currentState1) = stateVisits1(currentState1) + 1;
        stateVisits2(currentState2) = stateVisits2(currentState2) + 1;

        [Qtable_beta1, Qtable_beta2, Qvisit_beta1, Qvisit_beta2] = fQtableUpdate( ...
            reward_k, Qtable_beta1, Qtable_beta2, Qvisit_beta1, Qvisit_beta2, ...
            action1, action2, activeState1, activeState2, currentState1, currentState2, ...
            gamaQL, alpha1_q, alpha2_q, actionSpace);

        epsilon = max(epsilonTarget, epsilon - epsilonStep);
        kQL = kQL + 1;

        if length(ctlinfoList) >= 25
            recent25 = ctlinfoList(end-24:end);
            dispPER = sum(recent25 == 2) / 25 * 100;
        else
            dispPER = NaN;
        end
        fprintf("[Q-update %03d] n=%d/%d | PER25=%.1f%% beta1=%.1f(s%d) beta2=%.1f(s%d) | rew=%.2f MB/s eps=%.3f | chan=%s\n", ...
            kQL-1, n, N, dispPER, beta1new, currentState1, beta2new, currentState2, ...
            reward_k/1e6, epsilon, attnDB);

        activeState1 = currentState1;
        activeState2 = currentState2;
        [action1, action2] = fActionSelect(epsilon, Qtable_beta1, Qtable_beta2, ...
            Qvisit_beta1, Qvisit_beta2, activeState1, activeState2, actionSpace);
        [beta1new, currentState1] = localApplyBetaAction(beta1new, action1, beta1Grid);
        [beta2new, currentState2] = localApplyBetaAction(beta2new, action2, beta2Grid);
        windowStartNt = windowStartNt + WQLearning;
    end

    %% Per-iteration log every 200 iters (compact)
    if mod(n, 200) == 0
        if length(ctlinfoList) >= 25
            p25 = sum(ctlinfoList(end-24:end) == 2) / 25 * 100;
        elseif ~isempty(ctlinfoList)
            p25 = sum(ctlinfoList == 2) / length(ctlinfoList) * 100;
        else
            p25 = NaN;
        end
        fprintf("  [iter %d/%d] PER25=%.1f%% beta1=%.1f(s%d) beta2=%.1f(s%d) MCS=%d AMPDU=%d\n", ...
            n, N, p25, beta1new, currentState1, beta2new, currentState2, MCS, numampdunew);
    end

    %% State distribution summary every 1000 iters
    if mod(n, 1000) == 0
        trainedBeta1 = find(any(Qvisit_beta1, 1));
        trainedBeta2 = find(any(Qvisit_beta2, 1));
        fprintf("  [State coverage] beta1=%d/%d states, beta2=%d/%d states\n", ...
            numel(trainedBeta1), numel(beta1Grid), numel(trainedBeta2), numel(beta2Grid));
    end

    %% Update state for next iteration
    numampdunew = min(msduFb(5), 12);
    ChannelBWnewDec = msduFb(6);

    %% Periodic save
    if mod(n, saveInterval) == 0
        save(qtableFile, "Qtable_beta1", "Qtable_beta2", "Qvisit_beta1", "Qvisit_beta2", ...
            "qtableMode", "beta1Grid", "beta2Grid", "actionSpace", "WQLearning");
        elapsed = toc;
        fprintf("--- [SAVE] n=%d/%d (%.1f%%), Q-updates=%d, elapsed=%.0fs, Q-table saved ---\n", ...
            n, N, 100*n/N, kQL-1, elapsed);
    end

    %% Progress every 100
    if mod(n, 100) == 0
        elapsed = toc;
        if length(ctlinfoList) >= 25
            p100 = sum(ctlinfoList(end-24:end) == 2) / 25 * 100;
        else
            p100 = NaN;
        end
        fprintf("--- [%d/%d %.0f%%] Q-upd=%d MCS=%d AMPDU=%d PER25=%.1f%% beta1=%.1f(s%d) beta2=%.1f(s%d) t=%.0fs ---\n", ...
            n, N, 100*n/N, kQL-1, MCS, numampdunew, p100, beta1new, currentState1, ...
            beta2new, currentState2, elapsed);
    end
end

%% Training complete
elapsed = toc;
fprintf("\n=== Training finished ===\n");
fprintf("Total iterations: %d\n", N);
fprintf("Q-learning updates: %d\n", kQL-1);
fprintf("Elapsed: %.0f s (%.1f min)\n", elapsed, elapsed/60);
fprintf("Final: MCS=%d AMPDU=%d BWdec=%d SNR=%.2f beta1=%.1f beta2=%.1f\n", ...
    MCS, numampdunew, ChannelBWnewDec, snrMetricDbLast, beta1new, beta2new);

% Final save
save(qtableFile, "Qtable_beta1", "Qtable_beta2", "Qvisit_beta1", "Qvisit_beta2", ...
    "qtableMode", "beta1Grid", "beta2Grid", "actionSpace", "WQLearning");
fprintf("Q-table saved to: %s\n", qtableFile);

%% ====== Training Dashboard ======
rewardHistory = rewardHistory(1:rewardIdx);
rewardIter = rewardIter(1:rewardIdx);
beta1History = beta1History(1:rewardIdx);
beta2History = beta2History(1:rewardIdx);
stateHistory = stateHistory(1:rewardIdx, :);
epsilonHistory = epsilonHistory(1:rewardIdx);

if rewardIdx == 0
    fprintf("No Q-learning window completed; dashboard skipped.\n");
    if enableRunDiary, diary off; end
    return;
end

figure('Name', 'Q-Learning Training Dashboard', 'Position', [30 50 1600 900]);

% 1. Reward curve
subplot(3,4,1);
plot(rewardIter, rewardHistory/1e6, 'b-', 'LineWidth', 1); grid on;
xlabel('Iteration'); ylabel('MB/s');
title(sprintf('Reward (%d updates)', rewardIdx));
if length(rewardHistory) > 10
    hold on;
    win = max(5, round(length(rewardHistory)/50));
    plot(rewardIter(win:end), movmean(rewardHistory(win:end)/1e6, win), 'r-', 'LineWidth', 2);
end

% 2. Beta1 trajectory
subplot(3,4,2);
plot(rewardIter, beta1History, 'r-', 'LineWidth', 1.5); grid on;
xlabel('Iteration'); ylabel('beta1');
title(sprintf('beta1: %.1f → %.1f', beta1History(1), beta1History(end)));
ylim([0.1 0.9]);

% 3. Beta2 trajectory
subplot(3,4,3);
plot(rewardIter, beta2History, 'b-', 'LineWidth', 1.5); grid on;
xlabel('Iteration'); ylabel('beta2');
title(sprintf('beta2: %.1f → %.1f', beta2History(1), beta2History(end)));
ylim([1.1 2.5]);

% 4. Epsilon decay
subplot(3,4,4);
plot(rewardIter, epsilonHistory, 'k-', 'LineWidth', 1.5); grid on;
xlabel('Iteration'); ylabel('epsilon');
title(sprintf('Exploration (final=%.3f)', epsilonHistory(end)));

% 5. Beta-state visitation
subplot(3,4,5);
beta1Labels = arrayfun(@(x) sprintf('%.1f', x), beta1Grid, 'UniformOutput', false);
beta2Labels = arrayfun(@(x) sprintf('%.1f', x), beta2Grid, 'UniformOutput', false);
actionLabels = arrayfun(@(x) sprintf('%+.1f', x), actionSpace, 'UniformOutput', false);
bar(1:numel(beta1Grid), stateVisits1, 'FaceColor', [0.8 0.2 0.2]); grid on;
set(gca, 'XTick', 1:numel(beta1Grid), 'XTickLabel', beta1Labels, 'FontSize', 7);
xlabel('beta1 state'); ylabel('Visits');
title(sprintf('beta1 visits (total=%d)', sum(stateVisits1)));

% 6. MCS distribution
subplot(3,4,6);
if ~isempty(mcsHistory)
    histogram(mcsHistory, -0.5:1:11.5, 'FaceColor', [0.2 0.7 0.3]); grid on;
    xlabel('MCS'); ylabel('Count');
    title(sprintf('MCS (mean=%.1f)', mean(mcsHistory)));
end

% 7. PER distribution
subplot(3,4,7);
if ~isempty(perHistoryAll)
    histogram(perHistoryAll*100, 20, 'FaceColor', [0.9 0.4 0.2]); grid on;
    xlabel('PER (%)'); ylabel('Count');
    title(sprintf('PER (mean=%.1f%%)', mean(perHistoryAll)*100));
end

% 8. Beta correlation scatter
subplot(3,4,8);
scatter(beta1History, beta2History, 15, rewardHistory/1e6, 'filled'); grid on;
xlabel('beta1'); ylabel('beta2');
title('beta1 vs beta2 (colored by reward)');
colorbar; colormap('hot');

% 9. Q-table heatmap (beta1)
subplot(3,4,9);
imagesc(Qtable_beta1); colorbar;
set(gca, 'XTick', 1:numel(beta1Grid), 'XTickLabel', beta1Labels, 'FontSize', 6);
set(gca, 'YTick', 1:numActions, 'YTickLabel', actionLabels);
xlabel('beta1 state'); ylabel('Action'); title('Q-table: beta1');

% 10. Q-table heatmap (beta2)
subplot(3,4,10);
imagesc(Qtable_beta2); colorbar;
set(gca, 'XTick', 1:numel(beta2Grid), 'XTickLabel', beta2Labels, 'FontSize', 6);
set(gca, 'YTick', 1:numActions, 'YTickLabel', actionLabels);
xlabel('beta2 state'); ylabel('Action'); title('Q-table: beta2');

% 11. State transition over time
subplot(3,4,11);
plot(rewardIter, stateHistory(:,1), 'r.-', 'LineWidth', 1); hold on;
plot(rewardIter, stateHistory(:,2), 'b.-', 'LineWidth', 1); grid on;
xlabel('Iteration'); ylabel('State');
title('Beta State Trajectory');
legend({'beta1','beta2'}, 'Location', 'best');

% 12. Cumulative reward
subplot(3,4,12);
plot(rewardIter, cumsum(rewardHistory)/1e6, 'm-', 'LineWidth', 1.5); grid on;
xlabel('Iteration'); ylabel('Cumulative MB/s');
title(sprintf('Total reward: %.1f GB/s', sum(rewardHistory)/1e9));

sgtitle(sprintf('Q-Learning Training beta1:%.1f->%.1f beta2:%.1f->%.1f updates=%d', ...
    beta1History(1), beta1History(end), beta2History(1), beta2History(end), rewardIdx), ...
    'FontSize', 14, 'FontWeight', 'bold');
saveas(gcf, fullfile(runDir, 'training_dashboard.png'));
fprintf('Training dashboard saved.\n');

if enableRunDiary
    diary off;
end

%% Local helpers
function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

function localStopTx(bb)
try, stopTransmission(bb); catch, end
end

function reward = fRewardCal(rewardState, PacketDuration)
Nbyte = 0;
nPkts = size(rewardState, 2);
TdataSec = zeros(1, nPkts);
TprotocolSec = (84 + 10) * 1e-6;
ampduToCol = [1 3 6 9 12];
for i = 1:nPkts
    ampduVal = rewardState(3, i);
    if size(rewardState, 1) >= 6 && rewardState(6, i) > 0
        TdataSec(i) = rewardState(6, i);
    else
        mcsIdx = rewardState(2, i) + 1;
        [~, col] = min(abs(ampduToCol - ampduVal));
        if mcsIdx >= 1 && mcsIdx <= size(PacketDuration, 1)
            TdataSec(i) = PacketDuration(mcsIdx, col) * 1e-6;
        end
    end
    if rewardState(1, i) == 1
        Nbyte = Nbyte + 2304 * ampduVal;
    end
end
TdataSumSec = sum(TdataSec) + nPkts * TprotocolSec;
if TdataSumSec > 0
    reward = Nbyte / TdataSumSec;
else
    reward = 0;
end
end

function label = stateLabel(stateIdx)
% Convert state index to human-readable label
levels = {'vLo','Lo','Med','Hi'};
trends = {'+imp','=stb','-wrs'};
level = floor((stateIdx-1)/3) + 1;
trend = mod(stateIdx-1, 3) + 1;
label = [levels{level} trends{trend}];
end

function stateIdx = computePERState(ctlinfoList, windowSize)
% Compute PER-based state index
% stateIdx = (PER_level-1)*3 + trend, range 1..12
if length(ctlinfoList) < windowSize
    stateIdx = 6;  % default: medium PER, stable
    return;
end
recent = ctlinfoList(end-windowSize+1:end);
PER = sum(recent == 2) / length(recent);  % 2 = ARQ/failure

% PER level
if PER <= 0.01
    level = 1;  % very low
elseif PER <= 0.05
    level = 2;  % low
elseif PER <= 0.15
    level = 3;  % medium
else
    level = 4;  % high
end

% Trend
half = floor(windowSize/2);
oldPER = sum(recent(1:half) == 2) / half;
newPER = sum(recent(end-half+1:end) == 2) / half;
delta = newPER - oldPER;

if delta < -0.02
    trend = 1;  % improving
elseif delta > 0.02
    trend = 3;  % worsening
else
    trend = 2;  % stable
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

function [Q1, Q2, visit1, visit2] = fQtableUpdate(reward, Q1, Q2, visit1, visit2, ...
    action1, action2, prevState1, prevState2, currentState1, currentState2, ...
    gama, alpha1, alpha2, actionSpace)
% Q-learning update over beta-state Q-tables.

actRow1 = localActionRow(action1, actionSpace);
actRow2 = localActionRow(action2, actionSpace);

% Update beta1 Q-table
if ~visit1(actRow1, prevState1)
    Q1(actRow1, prevState1) = reward / max(1e-9, 1 - gama);
else
    nextVisited = visit1(:, currentState1);
    if any(nextVisited)
        nextMax = max(Q1(nextVisited, currentState1));
    else
        nextMax = 0;
    end
    Q1(actRow1, prevState1) = Q1(actRow1, prevState1) + ...
        alpha1 * (reward + gama * nextMax - Q1(actRow1, prevState1));
end
visit1(actRow1, prevState1) = true;

% Update beta2 Q-table
if ~visit2(actRow2, prevState2)
    Q2(actRow2, prevState2) = reward / max(1e-9, 1 - gama);
else
    nextVisited = visit2(:, currentState2);
    if any(nextVisited)
        nextMax = max(Q2(nextVisited, currentState2));
    else
        nextMax = 0;
    end
    Q2(actRow2, prevState2) = Q2(actRow2, prevState2) + ...
        alpha2 * (reward + gama * nextMax - Q2(actRow2, prevState2));
end
visit2(actRow2, prevState2) = true;
end

function row = localActionRow(actionVal, actionSpace)
[~, row] = min(abs(actionSpace - actionVal));
end

function [action1, action2] = fActionSelect(epsilon, Q1, Q2, visit1, visit2, ...
    state1, state2, actionSpace)
% Epsilon-greedy action selection for current beta states
if rand(1) > epsilon
    row1 = localBestActionRow(Q1, visit1, state1, actionSpace);
    row2 = localBestActionRow(Q2, visit2, state2, actionSpace);
else
    row1 = randi(numel(actionSpace));
    row2 = randi(numel(actionSpace));
end
action1 = actionSpace(row1);
action2 = actionSpace(row2);
end

function row = localBestActionRow(Q, visit, stateIdx, actionSpace)
visited = visit(:, stateIdx);
if any(visited)
    stateValues = Q(:, stateIdx);
    maxVal = max(stateValues(visited));
    candidates = find(visited & stateValues == maxVal);
    row = candidates(randi(numel(candidates)));
else
    row = randi(numel(actionSpace));
end
end
