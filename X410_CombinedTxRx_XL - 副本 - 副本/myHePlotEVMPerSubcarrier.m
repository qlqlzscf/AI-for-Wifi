function rmsEVMsc = myHePlotEVMPerSubcarrier(eqSym,user,enablePlot,axHandle)
%MYHEPLOTEVMPERSUBCARRIER Compute RMS EVM per subcarrier
if nargin < 3 || isempty(enablePlot)
    enablePlot = false;
end
if nargin < 4
    axHandle = [];
end

refConst = wlanReferenceSymbols(user);
refPower = max(abs(refConst).^2,eps);
[numSC,~,numSS] = size(eqSym);

rmsEVMsc = zeros(numSC,1);
for scIdx = 1:numSC
    scSlice = reshape(eqSym(scIdx,:,:),[],1);
    if isempty(scSlice), continue; end
    diffMat = abs(scSlice - refConst.').^2;
    [~,minIdx] = min(diffMat,[],2);
    refSym = refConst(minIdx);
    denom = refPower(minIdx);
    evm = abs(scSlice - refSym).^2 ./ denom;
    rmsEVMsc(scIdx) = sqrt(mean(evm));
end

if enablePlot
    if isempty(axHandle) || ~ishandle(axHandle)
        figure('Name','HE Data EVM per Subcarrier','NumberTitle','off');
        axHandle = gca;
    end
    plot(axHandle,1:numSC,20*log10(rmsEVMsc),'-','LineWidth',1.2);
    grid(axHandle,'on');
    xlabel(axHandle,'Subcarrier Index');
    ylabel(axHandle,'RMS EVM (dB)');
    title(axHandle,sprintf('Per-Subcarrier RMS EVM (%d spatial streams)',numSS));
end
end
