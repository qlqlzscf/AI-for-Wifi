function  [txWaveform,MCSnew,msdu,deltaOLLAList] = ackarqtxOLLA(ctlinfo,snr,numampdunew,ChannelBWnewDec,chanBW,deltaOLLAList,MCSbuffer)
% OLLA delta up = 1dB
%      delta down = 0.1dB
deltaUP = 1;
deltaDown = 0.1;
global deltaOLLA;
if isempty(deltaOLLA)
    deltaOLLA = 0;
end
deltaOLLAList = [deltaOLLAList deltaOLLA];
if ctlinfo == 1
    deltaOLLA = deltaOLLA - deltaDown;
else
    if ctlinfo == 2
        deltaOLLA = deltaOLLA + deltaUP;
    end
end
snr = snr - deltaOLLA;
disp(['deltaOLLA ' num2str(deltaOLLA)]);
asciiack = abs('ack');
asciiarq = abs('arq');
MCSnew = MCSdef(snr,ChannelBWnewDec);
if ctlinfo == 0
    MCSnew = MCSbuffer;
end
if ctlinfo == 1
    msdu = [asciiack,MCSnew];
    disp('ack');
    fprintf('new MCS = %d\n',MCSnew);
else
    msdu = [asciiarq,MCSnew];
    fprintf('new MCS = %d\n',MCSnew);
    disp('arq');
end
if ((MCSnew == 3)||(MCSnew == 2))&&(ChannelBWnewDec == 2)
    if numampdunew >6
        numampdunew = 6;
    end
end
if (MCSnew == 1)&&(ChannelBWnewDec == 2)
    if numampdunew >3
        numampdunew = 3;
    end
end
if (MCSnew == 0)&&(ChannelBWnewDec == 2)
    if numampdunew >1
        numampdunew = 1;
    end
end
if (MCSnew == 1)&&(ChannelBWnewDec == 4)
    if numampdunew >6
        numampdunew = 6;
    end
end
if (MCSnew == 0)&&(ChannelBWnewDec == 4)
    if numampdunew >3
        numampdunew = 3;
    end
end
msdu = [msdu,numampdunew,ChannelBWnewDec];

MCS = 0;
idleTime = 2e-6;
cfgSU = wlanHESUConfig;
cfgSU.ExtendedRange = false;
cfgSU.ChannelBandwidth = chanBW;
cfgSU.MCS = MCS;
cfgSU.ChannelCoding = 'LDPC';
cfgSU.NumSpaceTimeStreams = 1;
cfgSU.NumTransmitAntennas = 1;

numTxPkt = 1;
cfgAMPDU = wlanMACFrameConfig('FrameType','QoS Data','FrameFormat','HE-SU', ...
    'MPDUAggregation',false,'MSDUAggregation',false);
frameBody = msdu;
[macFrames, ampduLength]= wlanMACFrame(frameBody, cfgAMPDU,cfgSU,'OutputFormat','bits');
txPSDUPerUser = macFrames;
cfgSU.APEPLength = ampduLength;
scramblerInitialization = randi([1 127],1,1);
txWaveform = wlanWaveformGenerator(txPSDUPerUser,cfgSU, ...
      'NumPackets',numTxPkt,'IdleTime',idleTime,'ScramblerInitialization',scramblerInitialization);
end
