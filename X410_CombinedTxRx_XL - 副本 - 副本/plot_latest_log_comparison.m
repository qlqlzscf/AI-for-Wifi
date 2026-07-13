% Plot latest algorithm comparison from newest log statistics

algorithms = {'AARF','OLLA','AOLLA','QLOLLA'};
scriptDir = fileparts(mfilename('fullpath'));
logDir = fullfile(scriptDir, 'logs');

throughput = zeros(1, numel(algorithms));
per = zeros(1, numel(algorithms));
pickedLogs = strings(1, numel(algorithms));

for k = 1:numel(algorithms)
    pattern = fullfile(logDir, sprintf('run_%s_*.log', algorithms{k}));
    files = dir(pattern);
    if isempty(files)
        error('No log found for %s under %s', algorithms{k}, logDir);
    end
    [~, idx] = max([files.datenum]);
    logFile = fullfile(files(idx).folder, files(idx).name);
    pickedLogs(k) = string(files(idx).name);

    txt = fileread(logFile);

    fb = regexp(txt, '^Iter\s+\d+\s+\|\s+fb=(ack|arq)\s+\|', 'tokens', 'lineanchors');
    ackCount = 0;
    arqCount = 0;
    for i = 1:numel(fb)
        tag = fb{i}{1};
        if strcmp(tag, 'ack')
            ackCount = ackCount + 1;
        elseif strcmp(tag, 'arq')
            arqCount = arqCount + 1;
        end
    end
    if ackCount + arqCount > 0
        per(k) = arqCount / (ackCount + arqCount);
    else
        per(k) = 0;
    end

    bitrateTokens = regexp(txt, '^\s+DataBitrate \(Mbps\):\s*([0-9.]+)', 'tokens', 'lineanchors');
    bitrateVals = zeros(1, numel(bitrateTokens));
    for i = 1:numel(bitrateTokens)
        bitrateVals(i) = str2double(bitrateTokens{i}{1});
    end
    if ~isempty(bitrateVals)
        throughput(k) = mean(bitrateVals);
    else
        throughput(k) = 0;
    end
end

fig = figure('Color','w','Position',[100 100 1100 620]);
ax1 = axes(fig);
hold(ax1,'on');

b1 = bar(ax1, throughput, 0.62, ...
    'FaceColor',[0.36 0.61 0.84], ...
    'EdgeColor',[0.12 0.12 0.12], ...
    'LineWidth',0.8);

yyaxis right
b2 = bar(per, 0.62, ...
    'FaceColor',[0.93 0.49 0.19], ...
    'FaceAlpha',0.65, ...
    'EdgeColor',[0.12 0.12 0.12], ...
    'LineWidth',0.8);
ylabel('PER');

yyaxis left
ylabel('Throughput (Mbps)');
xlabel('Algorithm');
title('Latest Algorithm Comparison: Throughput vs PER');
set(ax1,'XTick',1:numel(algorithms),'XTickLabel',algorithms);
grid(ax1,'on');
ax1.GridAlpha = 0.2;

yyaxis left
ylim([0, max(throughput)*1.25 + 1]);
for i = 1:numel(throughput)
    text(i, throughput(i) + 0.5, sprintf('%.2f', throughput(i)), ...
        'HorizontalAlignment','center', 'Color',[0.18 0.46 0.71], 'FontSize',10);
end

yyaxis right
ylim([0, max(per)*1.15 + 0.02]);
for i = 1:numel(per)
    text(i, per(i) + 0.02, sprintf('%.2f', per(i)), ...
        'HorizontalAlignment','center', 'Color',[0.77 0.35 0.07], 'FontSize',10);
end

legend([b1 b2], {'Throughput','PER'}, 'Location','northwest');

outFile = fullfile(fileparts(mfilename('fullpath')), 'latest_log_comparison.png');
exportgraphics(fig, outFile, 'Resolution', 150);
fprintf('Saved plot to: %s\n', outFile);
for k = 1:numel(algorithms)
    fprintf('%s -> throughput=%.2f Mbps, PER=%.2f, log=%s\n', ...
        algorithms{k}, throughput(k), per(k), pickedLogs(k));
end
