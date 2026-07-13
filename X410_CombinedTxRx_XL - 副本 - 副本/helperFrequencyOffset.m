function y = helperFrequencyOffset(x, fs, freqOffsetHz)
%helperFrequencyOffset Apply a frequency offset correction.
%   y = helperFrequencyOffset(x, fs, freqOffsetHz) mixes x by
%   exp(1j*2*pi*freqOffsetHz*n/fs) to apply a frequency shift.
%
% This helper is referenced by the recovery functions in this project.
% It is normally provided in some MathWorks examples; we include a minimal
% local implementation to keep the repository self-contained.

if isempty(x)
    y = x;
    return;
end

N = size(x,1);
n = (0:N-1).';
rot = exp(1j*2*pi*freqOffsetHz*n/fs);

% Support multiple channels/antennas (columns)
y = x .* rot;
end

