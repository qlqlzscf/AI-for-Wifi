function [packetSeq,rxBitMatrix,rxnumampdu,SNRest,RXTime,pktind,searchOffset,ConstellationDiagram,ctlinfo,rmsEVMsym,rmsEVMsc,failStage,recoveryDiag,csiData,chanEst] = HEWLANDataRecovery(chanBW,sr,rx,idleTime,rxDiagCtx)
if nargin < 5 || isempty(rxDiagCtx)
    rxDiagCtx = struct();
end
%% 功能：WLAN HESU解包
%input:
%chanBW：带宽
%sr：采样率
%rx：接收基带波形
%idleTime：包间隔时间
%output:
%packerSeq：包序列号（MAC帧序列号）
%rxBitMatrix：接收MSDU乱序
%rxnumampdu：接收计算的MAC帧聚合数
%SNRest：接收机估计的信噪比
%RXTime：包数据占用时间
%pktind：处理到第几个包的
%searchOffset：数据指针
%ConstellationDiagram：接受眼图
%ctlinfo:ack/arq指示，1是ack，0是arq
%%
packetSeq = [];
rxnumampdu = [];
SNRest = [];
RXTime = [];
pktind = [];
searchOffset = [];
ConstellationDiagram = [];
ctlinfo = 0;
breakind = 0;
rmsEVMsym = [];
rmsEVMsc = [];
csiData = [];
chanEst = [];
failStage = "";
recoveryDiag = struct( ...
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
returnAfterFirstSuccess = true;

% Front-end conditioning for robust packet detection:
% - remove DC offset
% - normalize power (avoid very small/large scaling)
if ~isempty(rx)
    rx = rx - mean(rx,1);
    p = mean(abs(rx(:)).^2);
    if isfinite(p) && p > 0
        rx = rx ./ sqrt(p);
    end
end
%接收处理，先配置接收相关参数
pilotTracking = 'Joint';
% Create an HE recovery configuration object and set the channel bandwidth
cfgRx = wlanHERecoveryConfig;
cfgRx.ChannelBandwidth = chanBW;
% The recovery configuration object is used to get the start and end
% indices of the pre-HE-SIG-B field.
ind = wlanFieldIndices(cfgRx);   %此时HE-SIG-A之前所有格式数据分布已确定，是HE packet都有的部分
% Setup plots for the example
% [spectrumAnalyzer,timeScope,ConstellationDiagram,EVMPerSubcarrier,EVMPerSymbol] = heSigRecSetupPlots(sr);
% ConstellationDiagram.Position = [400 40 1080 720];
% Minimum packet length is 10 OFDM symbols
lstfLength = double(ind.LSTF(2));
minPktLen = lstfLength*5; % Number of samples in L-STF
pktind = 1;
rxWaveLen = double(size(rx,1)); 
summpduList = zeros(0,1);
rxBitMatrix = zeros(0,1);
packetSeq = [];
sumRXTime = 0;
frontGuardSamples = round(8e-6 * sr);
searchOffset = 0; % Offset from start of waveform in samples
%前端处理，即包检测，频率粗矫正，定时同步，频率细矫正，searchOffset超出rx索引范围时包检测失败
searchOffset = 0; % Offset from start of waveform in samples
while (searchOffset + minPktLen) <= rxWaveLen
    recoveryDiag.candidateCount = recoveryDiag.candidateCount + 1;
    candidateIdx = recoveryDiag.candidateCount;
    % Packet detection包探测，找到数据包的第一个符号，一般要提前一些，不是真正开始的符号，这么
    %做是因为方便之后频率校准的自相关操作和定时同步的精确校准
    pktOffset = wlanPacketDetect(rx,chanBW,searchOffset);  %延迟自相关算法
    if pktOffset < 0
         disp('** No packet detected * *');
         ctlinfo = 0;
         failStage = "pkt_detect";
         recoveryDiag.noPacketCount = recoveryDiag.noPacketCount + 1;
         recoveryDiag.packetDetectFailCount = recoveryDiag.packetDetectFailCount + 1;
        break;
    end
    if isempty(pktOffset) 
         disp('** No packet detect * *');
         ctlinfo = 0;
         failStage = "pkt_detect";
         recoveryDiag.noPacketCount = recoveryDiag.noPacketCount + 1;
         recoveryDiag.packetDetectFailCount = recoveryDiag.packetDetectFailCount + 1;
        break;
    end
    % Adjust packet offset
    pktOffsetRaw = double(searchOffset + pktOffset);
    pktOffset = pktOffsetRaw;
    if pktOffsetRaw < frontGuardSamples
        fprintf('  [FrontGuard] skip early candidate: cand=%d raw=%d guard=%d search=%d\n', ...
            candidateIdx, round(pktOffsetRaw), frontGuardSamples, round(searchOffset));
        recoveryDiag.frontGuardSkipCount = recoveryDiag.frontGuardSkipCount + 1;
        searchOffset = double(frontGuardSamples);
        continue;
    end
    if ((pktOffset == 0) || (pktOffset + ind.LSIG(2) > rxWaveLen))
        if pktind==1   
            disp('** No packet detected **');
            ctlinfo = 0;
            failStage = "pkt_detect";
            recoveryDiag.noPacketCount = recoveryDiag.noPacketCount + 1;
            recoveryDiag.packetDetectFailCount = recoveryDiag.packetDetectFailCount + 1;
            break;
        end
    end
    
    % L-STF auto-correlation quality check: half-PPDU locks from
    % continuous-TX wraparound have weak L-STF periodicity.
    lstfLen = double(ind.LSTF(2) - ind.LSTF(1) + 1);
    if (pktOffset + ind.LSTF(2)) <= rxWaveLen
        lstfRaw = rx(pktOffset + (ind.LSTF(1):ind.LSTF(2)), :);
        D = round(0.8e-6 * sr);  % L-STF repetition period in samples
        ac = sum(conj(lstfRaw(1:end-D,:)) .* lstfRaw(D+1:end,:), 1);
        lstfQuality = abs(sum(ac)) / (norm(lstfRaw(1:end-D,:),'fro')^2 + eps);
        fprintf('  [LSTF-Q] qual=%.4f cand=%d raw=%d\n', lstfQuality, candidateIdx, round(pktOffsetRaw));
        if lstfQuality < 0.7
            fprintf('  [LSTF-Q] weak corr=%.3f cand=%d raw=%d → half-PPDU, skip\n', ...
                lstfQuality, candidateIdx, round(pktOffsetRaw));
            recoveryDiag.lstfQualitySkipCount = recoveryDiag.lstfQualitySkipCount + 1;
            searchOffset = double(pktOffsetRaw + max(1, D));
            continue;
        end
    end

    %挑出传统前缀
    rxPre = rx(pktOffset+(ind.LSTF(1):ind.HESIGA(2)),:);
    %   frequency offset estimation and correction using L-STF粗频率校准
    rxLSTF = rxPre((ind.LSTF(1):ind.LSTF(2)), :);
    coarseFreqOffset = wlanCoarseCFOEstimate(rxLSTF,chanBW);
    rxPre = helperFrequencyOffset(rxPre,sr,-coarseFreqOffset);

    % Symbol timing synchronization符号定时同步（互相关算法），
    searchBufferLLTF = rxPre((ind.LSTF(1):ind.LSIG(2)),:);
    timeoffset = double(wlanSymbolTimingEstimate(searchBufferLLTF,chanBW));
    pktOffset = double(pktOffset + timeoffset);
    if pktOffset < 0
        disp('** No packet detected(UN) **');
        fprintf('  [PktDiag] timing moved before capture: cand=%d search=%d raw=%d timeoff=%d pkt=%d\n', ...
            candidateIdx, round(searchOffset), round(pktOffsetRaw), round(timeoffset), round(pktOffset));
        ctlinfo = 0;
        failStage = "pkt_detect";
        recoveryDiag.noPacketCount = recoveryDiag.noPacketCount + 1;
        recoveryDiag.packetDetectFailCount = recoveryDiag.packetDetectFailCount + 1;
        break;
    end
    rxPre = rx(pktOffset+(ind.LSTF(1):ind.HESIGA(2)),:);
    rxPre = helperFrequencyOffset(rxPre,sr,-coarseFreqOffset);
    
    % Fine frequency offset estimation and correction using
    % L-LTF细频率校准（SDR例程是只对前导码粗频率校准，在解得L-SIG的样本采样数后再对一个WLAN范围细频率校准，此魔改例子是对整个rx频率校准，会有处理时延等问题，有待优化）
    rxLLTF = rxPre((ind.LLTF(1):ind.LLTF(2)),:);
    fineFreqOffset = wlanFineCFOEstimate(rxLLTF,chanBW);
    rxPre = helperFrequencyOffset(rxPre,sr,-fineFreqOffset);

    % Timing synchronization complete: packet detected
%     fprintf('Packet detected at index %d\n',pktOffset + 1);

    % Display estimated carrier frequency offset
    cfoCorrection = coarseFreqOffset + fineFreqOffset; % Total CFO
    cfoRejectThresholdHz = 5e3;
    if isfield(rxDiagCtx, 'cfoRejectThresholdHz') && ...
            isfinite(rxDiagCtx.cfoRejectThresholdHz) && rxDiagCtx.cfoRejectThresholdHz > 0
        cfoRejectThresholdHz = double(rxDiagCtx.cfoRejectThresholdHz);
    end
    fprintf('  Estimated CFO: %5.1f Hz (reject threshold %.1f Hz)\n', ...
        cfoCorrection, cfoRejectThresholdHz);

    % Reject wild CFO estimates before they corrupt the packet search.
    % In a cable loopback link, values in the tens of kHz are not physical
    % and usually indicate packet mis-detection or a bad preamble lock.
    if ~isfinite(cfoCorrection) || abs(cfoCorrection) > cfoRejectThresholdHz
        txPeriodSamples = NaN;
        phaseInTx = NaN;
        if isfield(rxDiagCtx, 'txPeriodSamples') && isfinite(rxDiagCtx.txPeriodSamples) && rxDiagCtx.txPeriodSamples > 0
            txPeriodSamples = double(rxDiagCtx.txPeriodSamples);
            phaseInTx = mod(double(pktOffset), txPeriodSamples);
        end
        iterForDiag = NaN;
        if isfield(rxDiagCtx, 'iter')
            iterForDiag = double(rxDiagCtx.iter);
        end
        recoveryDiag.cfoOutlierOffsets(end+1,1) = double(pktOffset);
        recoveryDiag.cfoOutlierPhase(end+1,1) = double(phaseInTx);
        fprintf(['  ** CFO outlier rejected: %.1f Hz | iter=%g cand=%d search=%d raw=%d ' ...
            'timeoff=%d pkt=%d phase=%g/%g coarse=%.1f fine=%.1f **\n'], ...
            cfoCorrection, iterForDiag, candidateIdx, round(searchOffset), round(pktOffsetRaw), ...
            round(timeoffset), round(pktOffset), phaseInTx, txPeriodSamples, coarseFreqOffset, fineFreqOffset);
        ctlinfo = 0;
        failStage = "cfo_outlier";
        recoveryDiag.cfoOutlierCount = recoveryDiag.cfoOutlierCount + 1;
        recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
        searchOffset = double(pktOffset + max(1, ind.LSIG(2)));
        pktind = pktind + 1;
        continue;
    end

    % Apply CFO correction to waveform from current packet onward
    rx(pktOffset:end, :) = helperFrequencyOffset(rx(pktOffset:end, :), sr, -cfoCorrection);

    % Additional sanity gate for packet detection stability.
    % If the front-end channel estimate looks implausible, skip this packet
    % instead of feeding a bad lock into HE-SIG-A / HE-Data recovery.
    if ~isfinite(coarseFreqOffset) || ~isfinite(fineFreqOffset)
        fprintf('  ** CFO estimate invalid, skip packet **\n');
        ctlinfo = 0;
        failStage = "cfo_invalid";
        recoveryDiag.cfoOutlierCount = recoveryDiag.cfoOutlierCount + 1;
        recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
        searchOffset = double(pktOffset + max(1, ind.LSIG(2)));
        pktind = pktind + 1;
        continue;
    end


%Scale the waveform based on L-STF power (AGC)
%根据L-STF的功率归一化接收信号的功率，达到AGC效果
gain = 1./(sqrt(mean(rxLSTF.*conj(rxLSTF)))); 
rx = rx.*gain;

%包格式检测
%先对L-LTF(not include tone rotation for each 20 MHz segment)序列解调做信道估计，噪声估计，再通过这些信息从L-LTF至HE-SIG-A序列中判断包格式
rxLLTF = rxPre((ind.LLTF(1):ind.LLTF(2)),:);
lltfDemod = wlanLLTFDemodulate(rxLLTF,chanBW);
lltfChanEst = wlanLLTFChannelEstimate(lltfDemod,chanBW,11);   %信道估计(LS),使用了频率平滑
noiseVar = helperNoiseEstimate(lltfDemod);  %关于空时流的问题

% disp('Detect packet format...');
rxSIGA = rxPre((ind.LSIG(1):ind.HESIGA(2)),:);
pktFormat = wlanFormatDetect(rxSIGA,lltfChanEst,noiseVar,chanBW);
% fprintf('  %s packet detected\n\n',pktFormat);
if ~(numel(pktFormat) == 5)
    disp('** wrong target packet detected');
    ctlinfo = 0;
    failStage = "wrong_target";
    recoveryDiag.wrongTargetCount = recoveryDiag.wrongTargetCount + 1;
    recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
    searchOffset = double(pktOffset + ind.HEData(2));
    pktind = pktind + 1;
    continue;
else
    regpktFormat = (pktFormat == 'HE-SU');
    if ~(regpktFormat(4) == 1)
        ctlinfo = 0;
        failStage = "wrong_target";
        disp('** wrong target packet detected');
        recoveryDiag.wrongTargetCount = recoveryDiag.wrongTargetCount + 1;
        recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
        searchOffset = double(pktOffset + ind.HEData(2));
        pktind = pktind + 1;
        continue;
    end
end
    

% Set the packet format in the recovery object and update the field indices
cfgRx.PacketFormat = pktFormat;
ind = wlanFieldIndices(cfgRx);   %由于未知是否进行HE-SIG-B压缩操作，即有可能是全带宽MU-MIMO，所以此时ind未更新
                                 %HE-SIG-B部分，若包是HE SU Ext格式，会更新HE-SIG-A长度
% 
%使用L-LTF（include tone rotation for each 20 MHz segment）做信道估计(LS)，用于在HE-LTF之前的符号做信道均衡 
lltfDemod = wlanHEDemodulate(rxLLTF,'L-LTF',chanBW);
lltfChanEst = wlanLLTFChannelEstimate(lltfDemod,chanBW,11);

%L-SIG 和 RL-SIG 的解码
% disp('Decoding L-SIG... ');
% Extract L-SIG and RL-SIG fields
rxLSIG = rxPre((ind.LSIG(1):ind.RLSIG(2)),:);

% OFDM demodulate
helsigDemod = wlanHEDemodulate(rxLSIG,'L-SIG',chanBW);

% Estimate CPE and phase correct symbols
helsigDemod = preHECommonPhaseErrorTracking(helsigDemod,lltfChanEst,'L-SIG',chanBW);

% Estimate channel on extra 4 subcarriers per subchannel and create full
% channel estimate
preheInfo = wlanHEOFDMInfo('L-SIG',chanBW);
preHEChanEst = preHEChannelEstimate(helsigDemod,lltfChanEst,preheInfo.NumSubchannels);

% Average L-SIG and RL-SIG before equalization
helsigDemod = mean(helsigDemod,2);

% Equalize data carrying subcarriers, merging 20 MHz subchannelsm（SISO默认ZF均衡，其它可选MMSE）
[eqLSIGSym,csi] = preHESymbolEqualize(helsigDemod(preheInfo.DataIndices,:,:), ...
    preHEChanEst(preheInfo.DataIndices,:,:),noiseVar,preheInfo.NumSubchannels);

% Decode L-SIG field
[~,failCheck,lsigInfo] = wlanLSIGBitRecover(eqLSIGSym,noiseVar,csi);

if failCheck
    disp(' ** L-SIG check fail **');
    ctlinfo = 0;
    failStage = "lsig_check";
    recoveryDiag.lsigFailCount = recoveryDiag.lsigFailCount + 1;
    recoveryDiag.skippedBeforeSuccess = recoveryDiag.skippedBeforeSuccess + 1;
    searchOffset = double(pktOffset + ind.HEData(2));
    pktind = pktind + 1;
    continue;
end
    
% else
%     disp(' L-SIG check pass');
% end
% Get the length information from the recovered L-SIG bits and update the
% L-SIG length property of the recovery configuration object
lsigLength = lsigInfo.Length; %从L-SIG到RL-SIG的解码中得到了PSDU字节数
cfgRx.LSIGLength = lsigLength;

% % Measure EVM of L-SIG symbols
% EVM = comm.EVM;
% EVM.ReferenceSignalSource = 'Estimated from reference constellation';
% EVM.Normalization = 'Average constellation power';
% EVM.ReferenceConstellation = wlanReferenceSymbols('BPSK');
% rmsEVM = EVM(eqLSIGSym);
% fprintf(' L-SIG EVM: %2.1fdB\n\n',20*log10(rmsEVM/100));

%Calculate the receive time and corresponding number of samples in the
%packet
RXTime(pktind) = double(ceil((double(lsigLength) + 3)/3) * 4 + 20); % In microseconds
numRxSamples = double(round(RXTime(pktind) * 1e-6 * sr));   % Number of samples in time
fprintf(' RXTIME of packet %d: %dus\n',pktind,RXTime(pktind));
% fprintf(' Number of samples in the packet: %d\n\n',numRxSamples);
if (numRxSamples+pktOffset)>length(rx)
    disp('**Not enough samples to decode packet **');
    ctlinfo = 0;
    searchOffset = double(pktOffset + ind.HEData(2));
    pktind = pktind + 1;
    continue;
end

    %Apply CFO correction to the entire packet
    cfoSpan = double(1:(numRxSamples + round(idleTime*sr*0.75)));
    cfoIdx = double(pktOffset) + cfoSpan;
    cfoIdx = cfoIdx(cfoIdx >= 1 & cfoIdx <= size(rx,1));
    rx(cfoIdx,:) = helperFrequencyOffset(rx(cfoIdx,:),sr,-cfoCorrection);
%在解得持续时间和采样点数后可以画出接收信号波形和频谱
% sampleOffset = max((-lstfLength + pktOffset),1); % First index to plot
% sampleSpan = numRxSamples + 2*lstfLength; % Number samples to plot
% % Plot as much of the packet (and extra samples) as we can
% plotIdx = sampleOffset:min(sampleOffset + sampleSpan,rxWaveLen);

% % Configure timeScope to display the packet
% timeScope.TimeSpan = sampleSpan/sr;
% timeScope.TimeDisplayOffset = sampleOffset/sr;
% timeScope.YLimits = [0 max(abs(rx(:)))];
% timeScope(abs(rx(plotIdx,:)));
% % release(timeScope);

% Display the spectrum of the detected packet
% spectrumAnalyzer(rx(pktOffset + (1:numRxSamples),:));
% release(spectrumAnalyzer);

% HE-SIG-A域解码
% disp('Decoding HE-SIG-A...')
rxSIGA = rx(pktOffset+(ind.HESIGA(1):ind.HESIGA(2)),:);
sigaDemod = wlanHEDemodulate(rxSIGA,'HE-SIG-A',chanBW);
hesigaDemod = preHECommonPhaseErrorTracking(sigaDemod,preHEChanEst,'HE-SIG-A',chanBW);

% Equalize data carrying subcarriers, merging 20 MHz subchannels
preheInfo = wlanHEOFDMInfo('HE-SIG-A',chanBW);
[eqSIGASym,csi] = preHESymbolEqualize(hesigaDemod(preheInfo.DataIndices,:,:), ...
                                      preHEChanEst(preheInfo.DataIndices,:,:), ...
                                      noiseVar,preheInfo.NumSubchannels);
% Recover HE-SIG-A bits
[sigaBits,failCRC] = wlanHESIGABitRecover(eqSIGASym,noiseVar,csi);

% % Perform the CRC on HE-SIG-A bits
if failCRC
    disp(' ** HE-SIG-A CRC fail **');
    ctlinfo = 2;
    failStage = "hesiga_crc";
    recoveryDiag.sigaCrcFailCount = recoveryDiag.sigaCrcFailCount + 1;
    if exist('sigaCrcFailCount','var')
        sigaCrcFailCount = sigaCrcFailCount + 1;
    end
    break;
end
%     disp(' HE-SIG-A CRC pass');
% end

% Measure EVM of HE-SIG-A symbols
% release(EVM);
% if strcmp(pktFormat,'HE-EXT-SU')
%     % The second symbol of an HE-SIG-A field for an HE-EXT-SU packet is
%     % QBPSK.
%     EVM.ReferenceConstellation = wlanReferenceSymbols('BPSK',[0 pi/2 0 0]);
%     % Account for scaling of L-LTF for an HE-EXT-SU packet
%     rmsEVM = EVM(eqSIGASym*sqrt(2));
% else
%     EVM.ReferenceConstellation = wlanReferenceSymbols('BPSK');
%     rmsEVM = EVM(eqSIGASym);
% end
% fprintf(' HE-SIG-A EVM: %2.2fdB\n\n',20*log10(mean(rmsEVM)/100));

cfgRx = interpretHESIGABits(cfgRx,sigaBits);          
ind = wlanFieldIndices(cfgRx); % Update field indices解码HE-SIG-A后除HE-PE部分，其它部分数据分布全部确定
                                                    %可知HE-SIG-A含有较多数据包格式信息
% disp(cfgRx)

%HE-SIG-B解码
if strcmp(pktFormat,'HE-MU')
    fprintf('Decoding HE-SIG-B...\n');
    if ~cfgRx.SIGBCompression
        fprintf(' Decoding HE-SIG-B common field...\n');
        s = getSIGBLength(cfgRx);
        % Get common field symbols. The start of HE-SIG-B field is known
        rxSym = rx(pktOffset+(ind.HESIGA(2)+(1:s.NumSIGBCommonFieldSamples)),:);
        % Decode HE-SIG-B common field
        [status,cfgRx] = heSIGBCommonFieldDecode(rxSym,preHEChanEst,noiseVar,cfgRx);

        % CRC on HE-SIG-B content channels
        if strcmp(status,'Success')
            fprintf('  HE-SIG-B (common field) CRC pass\n');
        elseif strcmp(status,'ContentChannel1CRCFail')
            fprintf('  ** HE-SIG-B CRC fail for content channel-1\n **');
            failStage = "hesigb_crc";
        elseif strcmp(status,'ContentChannel2CRCFail')
            fprintf('  ** HE-SIG-B CRC fail for content channel-2\n **');
            failStage = "hesigb_crc";
        elseif any(strcmp(status,{'UnknownNumUsersContentChannel1','UnknownNumUsersContentChannel2'}))
            failStage = "hesigb_unknown";
            error('  ** Unknown packet length, discard packet\n **');
        else
            % Discard the packet if all HE-SIG-B content channels fail
            failStage = "hesigb_crc";
            error('  ** HE-SIG-B CRC fail **');
        end
        % Update field indices as the number of HE-SIG-B symbols are
        % updated
        ind = wlanFieldIndices(cfgRx);
    end

    % Get complete HE-SIG-B field samples
    rxSIGB = rx(pktOffset+(ind.HESIGB(1):ind.HESIGB(2)),:);
    fprintf(' Decoding HE-SIG-B user field... \n');
    % Decode HE-SIG-B user field
    [failCRC,cfgUsers] = heSIGBUserFieldDecode(rxSIGB,preHEChanEst,noiseVar,cfgRx);

    % CRC on HE-SIG-B users
    if ~all(failCRC)
        fprintf('  HE-SIG-B (user field) CRC pass\n\n');
        numUsers = numel(cfgUsers);
    elseif all(failCRC)
        % Discard the packet if all users fail the CRC
        failStage = "hesigb_user_crc";
        error('  ** HE-SIG-B CRC fail for all users **');
    else
        fprintf('  ** HE-SIG-B CRC fail for at least one user\n **');
        failStage = "hesigb_user_crc";
        % Only process users with valid CRC
        numUsers = numel(cfgUsers);
    end

else % HE-SU, HE-EXT-SU
    cfgUsers = {cfgRx};
    numUsers = 1;
end

% HE-DATA 解码
% Use plain struct to avoid dependency on wlan.internal.ConfigBase.
cfgDataRec = struct( ...
    'PilotTracking', pilotTracking, ...
    'PilotTrackingWindow', 9, ...
    'PilotGainTracking', false, ...
    'OFDMSymbolOffset', 0.75);

% fprintf('Decoding HE-Data...\n');
for iu = 1:numUsers
    decodeStage = "user_start";
    % Get recovery configuration object for each user
    user = cfgUsers{iu};  %单独的user的配置（原例程有4users)
%     if strcmp(pktFormat,'HE-MU')
%         fprintf(' Decoding User:%d, STAID:%d, RUSize:%d\n',iu,user.STAID,user.RUSize);
%     else
%         fprintf(' Decoding RUSize:%d\n',user.RUSize);
%     end

    decodeStage = "he_ofdm_info";
    heInfo = wlanHEOFDMInfo('HE-Data',chanBW,user.GuardInterval,[user.RUSize user.RUIndex]);

    % HE-LTF demodulation and channel estimation  
    decodeStage = "he_ltf_extract";
    rxHELTF = rx(pktOffset+(ind.HELTF(1):ind.HELTF(2)),:);
    decodeStage = "he_ltf_demod";
    heltfDemod = wlanHEDemodulate(rxHELTF,'HE-LTF',chanBW,user.GuardInterval, ...
        user.HELTFType,[user.RUSize user.RUIndex]);
    decodeStage = "he_ltf_channel_est";
    [chanEst,pilotEst] = heLTFChannelEstimate(heltfDemod,user,11);
    Nltf = size(heltfDemod, 2);  % HE-LTF symbols used for channel averaging

    % Diagnostic: mean channel magnitude (should be ~1 for loopback)
    fprintf('  ChanEst mean|h|: %.3f | HE-LTF rms: %.3f\n', ...
        mean(abs(chanEst(:))), sqrt(mean(rxHELTF.*conj(rxHELTF),'all')));

    % Number of expected data OFDM symbols
    symLen = heInfo.FFTLength+heInfo.CPLength;
    numOFDMSym = (ind.HEData(2)-ind.HEData(1)+1)/symLen;

    % HE-Data demodulation with pilot phase and timing tracking
    % Account for extra samples when extracting data field from the packet
    % for sample rate offset tracking. Extra samples may be required if the
    % receiver clock is significantly faster than the transmitter.
    maxSRO = 120; % Parts per million
    Ne = double(ceil(numRxSamples*maxSRO*1e-6)); % Number of extra samples
    Ne = double(min(Ne,rxWaveLen-numRxSamples)); % Limited to length of waveform
    numRxSamplesProcess = double(numRxSamples+Ne);
    decodeStage = "he_data_extract";
    dataIdx = double(pktOffset) + double(ind.HEData(1):numRxSamplesProcess);
    dataIdx = dataIdx(dataIdx >= 1 & dataIdx <= size(rx,1));
    rxData = rx(dataIdx,:);
    if user.RUSize==26
        % Force CPE only tracking for 26-tone RU as algorithm susceptible
        % to noise
        cfgDataRec.PilotTracking = 'CPE';
    else
        cfgDataRec.PilotTracking = pilotTracking;
    end
    decodeStage = "he_tracking_demod";
    try
        [demodSym,~,~] = heTrackingOFDMDemodulate(rxData,chanEst,numOFDMSym,user,cfgDataRec);
    catch ME
        failStage = decodeStage;
        failStage = decodeStage;
        error("HEWLANDataRecovery stage=%s | %s", decodeStage, ME.message);
    end

    % Estimate noise power in HE fields
    decodeStage = "he_noise_est";
    demodPilotSym = demodSym(heInfo.PilotIndices,:,:);
    nVarEst = heNoiseEstimate(demodPilotSym,pilotEst,user);

    % Equalize(MMSE)
    decodeStage = "he_equalize";
    [eqSym,csi] = heEqualizeCombine(demodSym,chanEst,nVarEst,user);
    SNRest(pktind) = 10*log10(max(mean(abs(chanEst(heInfo.DataIndices,:)).^2,'all') - nVarEst/Nltf, 1e-12) / nVarEst);
    % Discard pilot subcarriers
    decodeStage = "he_discard_pilots";
    eqSymUser = eqSym(heInfo.DataIndices,:,:);
    csiData = csi(heInfo.DataIndices,:);
    rmsind(pktind) = max(size(eqSymUser(1,:)));

    % EVM measurement (always on for diagnostics)
    rmsEVMsym = myHePlotEVMPerSymbol(eqSymUser,user);
    rmsEVMsc = myHePlotEVMPerSubcarrier(eqSymUser,user);
    evmSymDB = 20*log10(mean(rmsEVMsym));
    evmSCdb  = 20*log10(mean(rmsEVMsc));

    % Per-symbol EVM trend: show first 3, middle 3, last 3 symbols
    numSym = length(rmsEVMsym);
    if numSym >= 9
        idx = [1 2 3, floor(numSym/2)-1, floor(numSym/2), floor(numSym/2)+1, numSym-2, numSym-1, numSym];
        evmTrend = 20*log10(rmsEVMsym(idx));
        fprintf('  EVM trend [sym1..mid..end]: %s dB\n', strjoin(cellstr(num2str(evmTrend(:),'%.1f'))',' '));
    end
    fprintf('  EVM per-sym: %.2f dB | EVM per-sc: %.2f dB\n', evmSymDB, evmSCdb);

    % Plotting is intentionally disabled in closed-loop runs because figure
    % updates slow the timing path and can perturb packet capture stability.
    % Keep numeric EVM diagnostics above, and enable plots only in offline debug.
    enableEVMPlots = false;
    if enableEVMPlots && pktind >= 2 && rmsind(pktind)>=rmsind(pktind-1)
        % Plot EVM per symbol of the recovered HE data symbols
        rmsEVMsym = myHePlotEVMPerSymbol(eqSymUser,user,true);
        % Plot EVM per subcarrier of the recovered HE data symbols
        rmsEVMsc = myHePlotEVMPerSubcarrier(eqSymUser,user,true);
    end
    % Demap and decode bits//'offset-min-sum' 'norm-min-sum' 'layered-bp' 'bp'
    decodeStage = "he_data_bit_recover";
    rxPSDU = wlanHEDataBitRecover(eqSymUser,nVarEst,csiData,user,'LDPCDecodingMethod','norm-min-sum');
    decodeStage = "databitrate";
    Databitrate(pktind) = length(rxPSDU)/(RXTime(pktind)+idleTime*1e6);
    fprintf(' Databitrate of packet %d: %2.2f(Mbps)\n',pktind,Databitrate(pktind));
    % Deaggregate the A-MPDU
    decodeStage = "ampdu_deaggregate";
    [mpduList,~,status] = wlanAMPDUDeaggregate(rxPSDU,wlanHESUConfig);%这里都转换成SU
     rxnumampdu = numel(mpduList);
    if strcmp(status,'Success')
        fprintf('  A-MPDU deaggregation successful \n');
    else
        fprintf('  A-MPDU deaggregation unsuccessful \n');
        ctlinfo = 2;
        failStage = "ampdu_deaggregate";
        recoveryDiag.ampduDeaggFailCount = recoveryDiag.ampduDeaggFailCount + 1;
        breakind = 1;
        break;
    end
     summpduList = [summpduList, mpduList];
    % Decode the list of MPDUs and check the FCS for each MPDU
    for i = 1:numel(mpduList)
        decodeStage = "mpdu_decode";
        [cfgheMAC,hedatapayload{i},status] = wlanMPDUDecode(mpduList{i},wlanHESUConfig,'DataFormat','octets');
        if strcmp(status,'Success')
%             fprintf('  FCS pass for MPDU:%d\n',i);
        else
            fprintf('  FCS fail for MPDU:%d\n',i);
            ctlinfo = 2;
            failStage = "fcs_fail";
            recoveryDiag.fcsFailCount = recoveryDiag.fcsFailCount + 1;
            breakind = 1;
            SNRest(pktind) = 10*log10(max(mean(abs(chanEst(heInfo.DataIndices,:)).^2,'all') - nVarEst/Nltf, 1e-12) / nVarEst);
            % fprintf('SNRset= %2.2fdB\n',SNRset);
            fprintf('SNRest=%2.2fdB\n\n ',SNRest(pktind));
            break;
        end
    end

    decodeStage = "packet_seq";
    seqEnd = double(cfgheMAC.SequenceNumber);
    seqStart = double(seqEnd - rxnumampdu + 1);
    outStart = double((pktind-1)*rxnumampdu + 1);
    outEnd = double(pktind*rxnumampdu);
    packetSeq(outStart:outEnd) = seqStart:seqEnd;
    decodeStage = "rx_bit_matrix";
    rxBitMatrix = [rxBitMatrix, hedatapayload];
    % Plot equalized constellation of the recovered HE data symbols for all
    % spatial streams per user
    
%     hePlotEQConstellation(eqSymUser,user,ConstellationDiagram,iu,numUsers);

    % Measure EVM of HE-Data symbols
%     release(EVM);
%     EVM.ReferenceConstellation = wlanReferenceSymbols(user);
%     rmsEVM = EVM(eqSymUser(:));
%     fprintf('  HE-Data EVM:%2.2fdB\n\n',20*log10(rmsEVM/100));
% %     % Plot EVM per symbol of the recovered HE data symbols
%         rmsEVMsym = myHePlotEVMPerSymbol(eqSymUser,user);
% %     % Plot EVM per subcarrier of the recovered HE data symbols
%         rmsEVMsc = myHePlotEVMPerSubcarrier(eqSymUser,user);
end
    if breakind == 1
        break;
    end
% SNRset = awgnChannel.SNR;
decodeStage = "snr_finalize";
SNRest(pktind) = 10*log10(max(mean(abs(chanEst(heInfo.DataIndices,:)).^2,'all') - nVarEst/Nltf, 1e-12) / nVarEst);
% fprintf('SNRset= %2.2fdB\n',SNRset);
fprintf('SNRest=%2.2fdB\n\n ',SNRest(pktind));

if returnAfterFirstSuccess
    ctlinfo = 1;
    recoveryDiag.usedPacketIndex = pktind;
    break;
end

decodeStage = "search_offset";
searchOffset = double(pktOffset + ind.HEData(2));
if (length(unique(packetSeq))<length(packetSeq))  %适用于SDR
    break;
end
pktind =pktind +1;
end
if ctlinfo == 1 && exist('Databitrate','var') && ~isempty(Databitrate)
DataBitrate = mean(Databitrate);
  fprintf(' DataBitrate (Mbps): %2.2f\n',DataBitrate);
elseif ctlinfo == 1
ctlinfo = 0;
if strlength(string(failStage)) == 0
    failStage = "pkt_detect";
end
end
end
