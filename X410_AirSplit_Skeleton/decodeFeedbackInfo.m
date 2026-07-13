function [ok, fb, diag] = decodeFeedbackInfo(rxWaveHW, ackChanBW, hwSR, idleTime, protocol)
%DECODEFEEDBACKINFO Decode robust ACK/ARQ feedback from the RX node.

if nargin < 5 || isempty(protocol)
    protocol = struct();
end
if ~isfield(protocol, 'magic'), protocol.magic = "X4FB"; end
if ~isfield(protocol, 'version'), protocol.version = 1; end
if ~isfield(protocol, 'acceptLegacy'), protocol.acceptLegacy = false; end

ok = false;
fb = struct('tag',"",'ctlinfo',0,'MCS',NaN,'numAMPDU',NaN,'BWdec',NaN, ...
            'seq',NaN,'flags',uint8(0),'isLegacy',false,'SNRest',[], ...
            'RXTime',[],'rawPayload',[]);
diag = struct('ctlinfoRecovery',0,'failStage',"",'recoveryDiag',[]);

if isempty(rxWaveHW)
    diag.failStage = "empty_capture";
    return;
end

cfgSU = wlanHESUConfig;
cfgSU.ChannelBandwidth = char(ackChanBW);
sr = wlanSampleRate(cfgSU);

g = gcd(round(hwSR), round(sr));
p = round(hwSR / g);
q = round(sr / g);
Nrx = 2 * q * ceil(0.01 * p * q) + 1;
rFilterRx = designMultirateFIR(q, p, Nrx-1);
rxWave = upfirdn(rxWaveHW, rFilterRx, q, p);

rxDiagCtx = struct('iter',NaN,'txPeriodSamples',NaN,'txPeriodHwSamples',NaN, ...
                   'captureSamples',size(rxWave,1),'sampleRate',sr, ...
                   'hwSampleRate',hwSR,'MCS',0,'AMPDU',1,'BWdec',2);
try
    if nargout('HEWLANDataRecovery') >= 13
        [~, rxPayloads, ~, SNRest, RXTime, ~, ~, ~, ctlinfoRecovery, ~, ~, failStage, recoveryDiag] = ...
            HEWLANDataRecovery(char(ackChanBW), sr, rxWave, idleTime, rxDiagCtx);
    else
        [~, rxPayloads, ~, SNRest, RXTime, ~, ~, ~, ctlinfoRecovery] = ...
            HEWLANDataRecovery(char(ackChanBW), sr, rxWave, idleTime);
        failStage = "";
        recoveryDiag = [];
    end
catch ME
    diag.failStage = "feedback_exception: " + string(ME.message);
    return;
end

diag.ctlinfoRecovery = ctlinfoRecovery;
diag.failStage = string(failStage);
diag.recoveryDiag = recoveryDiag;
fb.SNRest = SNRest;
fb.RXTime = RXTime;

if ctlinfoRecovery ~= 1 || isempty(rxPayloads)
    if strlength(diag.failStage) == 0
        diag.failStage = "feedback_not_decoded";
    end
    return;
end

if ~iscell(rxPayloads)
    rxPayloads = num2cell(rxPayloads, 1);
end

for k = 1:numel(rxPayloads)
    b = uint8(rxPayloads{k}(:));
    [found, parsed] = localParseRobust(b, protocol);
    if found
        fb = localMergeFeedback(fb, parsed, b);
        ok = true;
        return;
    end
end

if protocol.acceptLegacy
    for k = 1:numel(rxPayloads)
        b = uint8(rxPayloads{k}(:));
        [found, parsed] = localParseLegacy(b);
        if found
            fb = localMergeFeedback(fb, parsed, b);
            ok = true;
            return;
        end
    end
end

diag.failStage = "feedback_payload_invalid";
end

function [ok, parsed] = localParseRobust(b, protocol)
ok = false;
parsed = struct();
magic = uint8(char(protocol.magic));
version = uint8(protocol.version);
frameLen = 15;

if numel(b) < frameLen
    return;
end

for s = 1:(numel(b)-frameLen+1)
    if ~isequal(b(s:s+3).', magic)
        continue;
    end
    if b(s+4) ~= version
        continue;
    end
    checksum = uint8(mod(sum(double(b(s:s+13))), 256));
    if checksum ~= b(s+14)
        continue;
    end
    tag = string(char(b(s+7:s+9).'));
    if tag ~= "ack" && tag ~= "arq"
        continue;
    end
    parsed.tag = tag;
    parsed.ctlinfo = double(tag == "ack") + 2*double(tag == "arq");
    parsed.seq = double(b(s+5))*256 + double(b(s+6));
    parsed.MCS = max(0, min(11, double(b(s+10))));
    parsed.numAMPDU = max(1, min(12, double(b(s+11))));
    parsed.BWdec = double(b(s+12));
    parsed.flags = b(s+13);
    parsed.isLegacy = false;
    if ~ismember(parsed.BWdec, [2 4 8 16])
        continue;
    end
    ok = true;
    return;
end
end

function [ok, parsed] = localParseLegacy(b)
ok = false;
parsed = struct();
if numel(b) < 6
    return;
end
for s = 1:(numel(b)-5)
    tag = string(char(b(s:s+2).'));
    if tag ~= "ack" && tag ~= "arq"
        continue;
    end
    parsed.tag = tag;
    parsed.ctlinfo = double(tag == "ack") + 2*double(tag == "arq");
    parsed.seq = NaN;
    parsed.MCS = max(0, min(11, double(b(s+3))));
    parsed.numAMPDU = max(1, min(12, double(b(s+4))));
    parsed.BWdec = double(b(s+5));
    parsed.flags = uint8(0);
    parsed.isLegacy = true;
    if ~ismember(parsed.BWdec, [2 4 8 16])
        parsed.BWdec = 2;
    end
    ok = true;
    return;
end
end

function fb = localMergeFeedback(fb, parsed, rawPayload)
fb.tag = parsed.tag;
fb.ctlinfo = parsed.ctlinfo;
fb.MCS = parsed.MCS;
fb.numAMPDU = parsed.numAMPDU;
fb.BWdec = parsed.BWdec;
fb.seq = parsed.seq;
fb.flags = parsed.flags;
fb.isLegacy = parsed.isLegacy;
fb.rawPayload = rawPayload;
end
