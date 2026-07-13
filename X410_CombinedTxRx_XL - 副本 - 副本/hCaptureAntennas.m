function ants = hCaptureAntennas(~)
%hCaptureAntennas Return common X410 capture antenna ports.
% Minimal local version to replace MathWorks example helper.
%
% Notes:
% - Use RX1 for dedicated receive paths if your cabling expects it.
% - Adjust to match your Radio Setup configuration.

ants = [ ...
    "DB0:RF0:RX1"
    "DB0:RF1:RX1"
    "DB1:RF0:RX1"
    "DB1:RF1:RX1" ...
    ];
end

