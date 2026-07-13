function [txWaveform, payload] = buildFeedbackWaveform(msduFb, seq, ackChanBW, idleTime, protocol)
%BUILDFEEDBACKWAVEFORM Build robust ACK/ARQ feedback waveform.
% Payload format:
%   magic(4) version(1) seq(2) tag(3) MCS(1) AMPDU(1) BWdec(1) flags(1) checksum(1)

if nargin < 5 || isempty(protocol)
    protocol = struct();
end
if ~isfield(protocol, 'magic'), protocol.magic = "X4FB"; end
if ~isfield(protocol, 'version'), protocol.version = 1; end

if numel(msduFb) < 6
    error("buildFeedbackWaveform:InvalidFeedback", ...
        "msduFb must contain tag, MCS, AMPDU, and BWdec.");
end

tag = uint8(msduFb(1:3));
seq16 = uint16(mod(double(seq), 65536));
seqHi = uint8(floor(double(seq16) / 256));
seqLo = uint8(mod(double(seq16), 256));
flags = uint8(0);

body = uint8([ ...
    uint8(char(protocol.magic)), ...
    uint8(protocol.version), ...
    seqHi, seqLo, ...
    tag(:).', ...
    uint8(max(0, min(11, double(msduFb(4))))), ...
    uint8(max(1, min(12, double(msduFb(5))))), ...
    uint8(double(msduFb(6))), ...
    flags]);
checksum = uint8(mod(sum(double(body)), 256));
payload = [body checksum].';

cfgSU = wlanHESUConfig;
cfgSU.ExtendedRange = false;
cfgSU.ChannelBandwidth = char(ackChanBW);
cfgSU.MCS = 0;
cfgSU.ChannelCoding = 'LDPC';
cfgSU.NumSpaceTimeStreams = 1;
cfgSU.NumTransmitAntennas = 1;

cfgMAC = wlanMACFrameConfig('FrameType','QoS Data','FrameFormat','HE-SU', ...
    'MPDUAggregation',false,'MSDUAggregation',false);
[macFrame, ampduLength] = wlanMACFrame(payload, cfgMAC, cfgSU, 'OutputFormat', 'bits');
cfgSU.APEPLength = ampduLength;

scramblerInitialization = randi([1 127],1,1);
txWaveform = wlanWaveformGenerator(macFrame, cfgSU, ...
    'NumPackets', 1, ...
    'IdleTime', idleTime, ...
    'ScramblerInitialization', scramblerInitialization);
end
