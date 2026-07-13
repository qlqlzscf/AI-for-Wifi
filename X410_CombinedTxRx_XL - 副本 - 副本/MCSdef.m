function MCSnew = MCSdef(snr,ChannelBWnewDec)
SNRthreshold = [];
if ChannelBWnewDec == 2
    SNRthreshold = [11 14 16 21 23 25 28 31 33 35 37];
elseif ChannelBWnewDec == 4
    SNRthreshold = [10 13 15 20 23 24.5 27.5 29.5 32 34 37];
else
    SNRthreshold = [10 13 15 20 23 24.5 27.5 29.5 32 34 37];
end
if snr > SNRthreshold(end)
    MCSnew = 11;
elseif snr < SNRthreshold(1)
    MCSnew = 0;
else
    MCSnew = find(SNRthreshold < snr, 1, 'last');
end
end
