function ants = hTransmitAntennas(~)
%hTransmitAntennas Return common X410 transmit antenna ports.
% This project previously referenced MathWorks example helpers. To keep the
% code self-contained, we provide a minimal local version.
%
% Notes:
% - The exact available ports depend on your Radio Setup configuration and
%   daughterboard mapping. Adjust if your setup differs.

ants = [ ...
    "DB0:RF0:TX/RX0"
    "DB0:RF1:TX/RX0"
    "DB1:RF0:TX/RX0"
    "DB1:RF1:TX/RX0" ...
    ];
end

