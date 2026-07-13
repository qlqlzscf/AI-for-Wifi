%% Verify L-STF quality: half-PPDU vs complete PPDU
%  Simulates continuous TX replay + random capture offsets
clear; close all;

chanBW = 'CBW160';
cfgSU = wlanHESUConfig;
cfgSU.ChannelBandwidth = chanBW;
cfgSU.MCS = 5;
cfgSU.APEPLength = 2000;
cfgSU.NumTransmitAntennas = 1;
cfgSU.NumSpaceTimeStreams = 1;

sr = wlanSampleRate(cfgSU);
psdu = randi([0 1], getPSDULength(cfgSU), 1);
txWave = wlanWaveformGenerator(psdu, cfgSU);

ind = wlanFieldIndices(cfgSU);
lstfStart = ind.LSTF(1);
lstfEnd = ind.LSTF(2);
D = round(0.8e-6 * sr);
ppduLen = length(txWave);

fprintf('=== L-STF Quality Verification ===\n');
fprintf('BW=%s sr=%.0fMHz PPDU=%d samples L-STF=[%d,%d] D=%d\n', ...
    chanBW, sr/1e6, ppduLen, lstfStart, lstfEnd, D);

%% Test 1: Clean L-STF from generated PPDU
lstfClean = txWave(lstfStart:lstfEnd,:);
ac = sum(conj(lstfClean(1:end-D,:)).*lstfClean(D+1:end,:),1);
qClean = abs(sum(ac))/(norm(lstfClean(1:end-D,:),'fro')^2+eps);
fprintf('Test 1 — Clean L-STF: qual=%.4f\n\n', qClean);

%% Test 2: 50 random capture offsets
nTests = 50;
captureLen = round(3e-3 * sr);  % 3ms
replay = repmat(txWave, 100, 1);  % 100 copies = 16000*100 = 1.6M samples

allQuals = []; allLabels = {};
captureQualsCell = cell(nTests,1);
captureOffsets = zeros(nTests,1);

for t = 1:nTests
    % Random offset: sometimes inside data section to hit wraparound
    if rand < 0.4, captureStart = randi([ppduLen - 2000, ppduLen]);
    else,          captureStart = randi([500, ppduLen - 100]);
    end
    captureOffsets(t) = captureStart;
    rxCapture = replay(captureStart : captureStart + captureLen - 1, :);

    searchOffset = 0;
    qualsThis = [];
    cand = 0;
    while (searchOffset + D*5) <= captureLen && cand < 8
        pktOff = wlanPacketDetect(rxCapture, chanBW, searchOffset);
        if pktOff < 0, break; end
        pktOff = double(searchOffset + pktOff);
        if (pktOff + lstfEnd) <= captureLen
            lstf = rxCapture(pktOff+(lstfStart:lstfEnd),:);
            acV = sum(conj(lstf(1:end-D,:)).*lstf(D+1:end,:),1);
            q = abs(sum(acV))/(norm(lstf(1:end-D,:),'fro')^2+eps);
            cand = cand + 1;
            qualsThis(cand) = q;
        end
        searchOffset = pktOff + max(1, D);
    end
    allQuals = [allQuals qualsThis];
    captureQualsCell{t} = qualsThis;
end

halfIdx = allQuals < 0.7;
completeIdx = allQuals >= 0.7;
fprintf('Test 2 — %d captures: %d total candidates\n', nTests, length(allQuals));
fprintf('Half-PPDU (qual<0.7): %d  mean=%.4f\n', sum(halfIdx), mean(allQuals(halfIdx)));
fprintf('Complete  (qual>0.7): %d  mean=%.4f\n\n', sum(completeIdx), mean(allQuals(completeIdx)));

%% ====== FIGURE ======
figure('Position', [30 50 1500 850], 'Name', 'L-STF Quality: Half-PPDU Detection');

% 1. Scatter: all candidates
subplot(2,3,1); hold on; grid on;
scatter(find(halfIdx), allQuals(halfIdx), 40, 'r', 'filled');
scatter(find(completeIdx), allQuals(completeIdx), 40, 'g', 'filled');
yline(0.7, 'k--', 'LineWidth', 2);
xlabel('Candidate #'); ylabel('Quality'); ylim([0 1.05]);
title(sprintf('All %d Candidates', length(allQuals)));
legend(sprintf('Half (n=%d)', sum(halfIdx)), sprintf('Complete (n=%d)', sum(completeIdx)));

% 2. Histogram
subplot(2,3,2); hold on; grid on;
h1 = histogram(allQuals(halfIdx), 0:0.04:1.04, 'FaceColor','r','FaceAlpha',0.6);
h2 = histogram(allQuals(completeIdx), 0:0.04:1.04, 'FaceColor','g','FaceAlpha',0.6);
xline(0.7, 'k--', 'LineWidth', 2);
xlabel('Quality'); ylabel('Count');
title('Quality Distribution');

% 3. One capture with wraparound — zoomed waveform
subplot(2,3,3); hold on; grid on;
% Find capture with half-PPDU
for ts = 1:nTests
    qs = captureQualsCell{ts};
    if any(qs < 0.7) && length(qs) >= 4
        captureStart = captureOffsets(ts);
        rxCap = replay(captureStart : captureStart + captureLen - 1, :);
        plotLen = min(3000, captureLen);
        plot(1:plotLen, real(rxCap(1:plotLen)), 'b-', 'LineWidth', 0.5);
        % Mark candidate positions
        searchOffset = 0; cand = 0;
        while (searchOffset + D*5) <= captureLen && cand < 8
            pktOff = wlanPacketDetect(rxCap, chanBW, searchOffset);
            if pktOff < 0, break; end
            pktOff = double(searchOffset + pktOff);
            if pktOff <= plotLen
                cand = cand + 1;
                if cand <= length(qs)
                    clr = ternary(qs(cand)<0.7, 'r', 'g');
                    xline(pktOff, clr, 'LineWidth', ternary(qs(cand)<0.7, 2, 1));
                end
            end
            searchOffset = pktOff + max(1, D);
        end
        xlabel('Sample offset in capture'); ylabel('Amplitude');
        title(sprintf('Waveform: half-PPDU (red) → complete (green)'));
        break;
    end
end

% 4. Consecutive skip pattern (first 6 captures with half-PPDU)
subplot(2,3,4); hold on; grid on;
count = 0;
for ts = 1:nTests
    qs = captureQualsCell{ts};
    if any(qs < 0.7) && count < 8
        count = count + 1;
        xs = (1:length(qs)) + (count-1)*0.15;
        for k = 1:length(qs)
            clr = ternary(qs(k)<0.7, [1 0.3 0.3], [0.2 0.7 0.2]);
            bar(xs(k), qs(k), 0.14, 'FaceColor', clr);
        end
    end
end
yline(0.7, 'k--', 'LineWidth', 1.5);
xlabel('Capture × Candidate'); ylabel('Quality'); ylim([0 1.05]);
title('Consecutive Skips in 8 Captures');

% 5. Box plot
subplot(2,3,5); hold on; grid on;
halfQ = allQuals(halfIdx); completeQ = allQuals(completeIdx);
boxplot([halfQ(:); completeQ(:)], [zeros(size(halfQ(:))); ones(size(completeQ(:)))], ...
    'Labels', {'Half-PPDU', 'Complete PPDU'});
yline(0.7, 'k--');
ylabel('Quality'); title('Box Plot Comparison');

% 6. Quality by candidate position within capture
subplot(2,3,6); hold on; grid on;
maxCand = 6; candQuals = cell(maxCand, 1);
for ts = 1:nTests
    qs = captureQualsCell{ts};
    for k = 1:min(maxCand, length(qs))
        candQuals{k}(end+1) = qs(k);
    end
end
for k = 1:maxCand
    if ~isempty(candQuals{k})
        idx = candQuals{k} < 0.7;
        scatter(repmat(k, sum(idx), 1), candQuals{k}(idx), 30, 'r', 'filled');
        scatter(repmat(k, sum(~idx), 1), candQuals{k}(~idx), 30, 'g', 'filled');
        plot([k-0.3 k+0.3], [mean(candQuals{k}) mean(candQuals{k})], 'k-', 'LineWidth', 2);
    end
end
yline(0.7, 'k--');
xlabel('Candidate position (1=first found, 2=second...)');
ylabel('Quality'); ylim([0 1.05]);
title('Quality vs. Candidate Position');

sgtitle('L-STF Quality: Half-PPDU Detection — Offline Verification', 'FontSize', 14, 'FontWeight', 'bold');
saveas(gcf, 'verify_lstf_quality.png');
fprintf('Figure saved.\n');

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end
