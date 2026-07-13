function noiseVar = helperNoiseEstimate(x)
%helperNoiseEstimate Estimate noise variance from repeated training symbols.
% Minimal local replacement for MathWorks example helper used by recovery.
%
% Input:
%   x - demodulated training field symbols (typically L-LTF), size:
%       Nsubcarriers x Nsymbols x Nr
%
% Output:
%   noiseVar - scalar noise variance estimate

if isempty(x)
    noiseVar = 1e-6;
    return;
end

if ndims(x) < 3
    x = reshape(x,size(x,1),size(x,2),1);
end

numSym = size(x,2);
if numSym >= 2
    % Repeated training symbols: noise from inter-symbol mismatch
    d = x(:,2:end,:) - x(:,1:end-1,:);
    noiseVar = mean(abs(d(:)).^2)/2;
else
    % Fallback: residual around mean
    mu = mean(x,2);
    d = x - mu;
    noiseVar = mean(abs(d(:)).^2);
end

if ~isfinite(noiseVar) || noiseVar <= 0
    noiseVar = 1e-6;
end
end

