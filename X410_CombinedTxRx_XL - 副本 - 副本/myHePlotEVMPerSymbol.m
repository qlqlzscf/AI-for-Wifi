function rmsEVMsym = myHePlotEVMPerSymbol(eqSym,user,enablePlot,axHandle)
%MYHEPLOTEVMPERSYMBOL Compute RMS EVM per OFDM symbol
if nargin < 3 || isempty(enablePlot)
    enablePlot = false;
end
if nargin < 4
    axHandle = [];
end

refConst = wlanReferenceSymbols(user);
refPower = max(abs(refConst).^2,eps);
[~,numSym,numSS] = size(eqSym);

rmsEVMsym = zeros(numSym,1);
for symIdx = 1:numSym
    symSlice = reshape(eqSym(:,symIdx,:),[],1);
    if isempty(symSlice), continue; end
    diffMat = abs(symSlice - refConst.').^2;
    [~,minIdx] = min(diffMat,[],2);
    refSym = refConst(minIdx);
    denom = refPower(minIdx);
    evm = abs(symSlice - refSym).^2 ./ denom;
    rmsEVMsym(symIdx) = sqrt(mean(evm));
end

if enablePlot
    if isempty(axHandle) || ~ishandle(axHandle)
        figure('Name','HE Data EVM per Symbol','NumberTitle','off');
        axHandle = gca;
    end
    plot(axHandle,0:numSym-1,20*log10(rmsEVMsym),'-o','LineWidth',1.2);
    grid(axHandle,'on');
    xlabel(axHandle,'OFDM Symbol Index');
    ylabel(axHandle,'RMS EVM (dB)');
    title(axHandle,sprintf('Per-Symbol RMS EVM (%d spatial streams)',numSS));
end
end
