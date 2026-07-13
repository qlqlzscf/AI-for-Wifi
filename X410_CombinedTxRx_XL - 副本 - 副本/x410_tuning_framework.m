function state = x410_tuning_framework(action, state, sample)
%X410_TUNING_FRAMEWORK  Reusable stub for multi-parameter link tuning.
%
% This framework is intentionally lightweight so it can be called from the
% main closed-loop script now, and expanded later to consume CSI, PER, and
% throughput measurements for joint AMPDU/MCS/power optimization.
%
% Usage:
%   state = x410_tuning_framework('init')
%   state = x410_tuning_framework('update', state, sample)
%   [next, state] = x410_tuning_framework('next', state)
%   summary = x410_tuning_framework('summary', state)

if nargin < 1
    action = 'init';
end

switch lower(string(action))
    case "init"
        state = struct();
        state.iter = 0;
        state.successCount = 0;
        state.failCount = 0;
        state.totalBytes = 0;
        state.totalAirTimeSec = 0;
        state.avgThroughputMbps = 0;
        state.perHistory = zeros(0,1);
        state.throughputHistory = zeros(0,1);
        state.mcsHistory = zeros(0,1);
        state.ampduHistory = zeros(0,1);
        state.bwHistory = zeros(0,1);
        state.txPowerHistory = zeros(0,1);
        state.lastDecision = struct('MCS', 0, 'AMPDU', 1, 'BWdec', 2, 'TxPowerDb', 20);
        state.config = struct( ...
            'mcsStepCap', 1, ...
            'ampduStepCap', 1, ...
            'txPowerStepDb', 2, ...
            'targetPer', 0.10, ...
            'targetThroughputMbps', 100);
        state.summary = struct();
        state = state;

    case "update"
        if nargin < 3 || isempty(sample)
            error('x410_tuning_framework:update requires a sample struct.');
        end
        state.iter = state.iter + 1;
        state.mcsHistory(end+1,1) = sample.MCS;
        state.ampduHistory(end+1,1) = sample.AMPDU;
        state.bwHistory(end+1,1) = sample.BWdec;
        state.txPowerHistory(end+1,1) = sample.TxPowerDb;
        state.perHistory(end+1,1) = sample.PER;
        state.throughputHistory(end+1,1) = sample.ThroughputMbps;
        state.successCount = state.successCount + double(sample.Success);
        state.failCount = state.failCount + double(~sample.Success);
        state.totalBytes = state.totalBytes + double(sample.BytesDelivered);
        state.totalAirTimeSec = state.totalAirTimeSec + double(sample.AirTimeSec);
        if state.totalAirTimeSec > 0
            state.avgThroughputMbps = (state.totalBytes * 8 / 1e6) / state.totalAirTimeSec;
        end
        state.lastDecision = sample.NextDecision;

    case "next"
        if nargin < 2 || isempty(state)
            state = x410_tuning_framework('init');
        end
        next = state.lastDecision;
        if isfield(state, 'perHistory') && ~isempty(state.perHistory)
            recentPer = mean(state.perHistory(max(1,end-4):end));
            recentTp = mean(state.throughputHistory(max(1,end-4):end));
            if recentPer > state.config.targetPer
                next.MCS = max(0, next.MCS - state.config.mcsStepCap);
                next.AMPDU = max(1, next.AMPDU - state.config.ampduStepCap);
                next.TxPowerDb = min(30, next.TxPowerDb + state.config.txPowerStepDb);
            elseif recentPer < state.config.targetPer/2 && recentTp < state.config.targetThroughputMbps
                next.MCS = min(11, next.MCS + state.config.mcsStepCap);
                next.AMPDU = min(12, next.AMPDU + state.config.ampduStepCap);
            end
            state.lastDecision = next;
        end

    case "summary"
        summary = struct();
        summary.iter = state.iter;
        summary.successCount = state.successCount;
        summary.failCount = state.failCount;
        summary.avgThroughputMbps = state.avgThroughputMbps;
        summary.meanPer = mean(state.perHistory, 'omitnan');
        summary.medianThroughputMbps = median(state.throughputHistory, 'omitnan');
        state = summary;

    otherwise
        error('Unsupported action: %s', action);
end
end
