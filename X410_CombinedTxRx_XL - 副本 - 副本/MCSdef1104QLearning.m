function  [MCSnew,PERList,deltaThresholdList] = MCSdef1104QLearning(snr,ChannelBWnewDec,ctlinfoList,PERList,deltaThresholdList,beta1,beta2)
global nt;
if isempty(nt), nt=0; end
global u;
global deltaThreshold;
if nt<= 99999
    PERest = 10*log10(0.1);
else
    PERest = 10*log10(0.05);
end
if length(ctlinfoList) <= 10
    recent = ctlinfoList;
else
    recent = ctlinfoList(end-9:end);
end
PER = sum(recent == 2) / max(1, length(recent));
PERList = [PERList PER];
if PER ==0
    PER = -20;
else
    PER = 10*log10(PER);
end
e = PER - PERest;
if e > 0, e = beta2*e; end
if e < 0, e = beta1*e; end
if isempty(u), u = 0.1; end
if isempty(deltaThreshold), deltaThreshold = 0; end
deltaThreshold = deltaThreshold + u * e;
u = 0.002 * (u + 3 * abs(e));
deltaThresholdList = [deltaThresholdList deltaThreshold];
if ChannelBWnewDec == 2
    SNRthreshold = [11 14 16 21 23 25 28 31 33 35 37] + deltaThreshold;
else
    SNRthreshold = [10 13 15 20 23 24.5 27.5 29.5 32 34 37] + deltaThreshold;
end
if snr>SNRthreshold(end)
    MCSnew = 11;
elseif snr<SNRthreshold(1)
    MCSnew = 0;
else
    MCSnew = find(SNRthreshold<snr, 1, 'last' );
end
nt = nt+1;
end
