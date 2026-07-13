function cfg = X410_AirLink_Config(role)
%X410_AIRLINK_CONFIG Shared settings for two-USRP OTA Wi-Fi 6 link.
% Copy these files into your existing project folder so they can reuse:
% HEWLANDataGenerator.m, HEWLANDataRecovery.m, ackarqtx*.m, hTransmitAntennas.m, hCaptureAntennas.m.

if nargin < 1, role = ""; end
cfg.role = string(role);

cfg.airSplitDir = fileparts(mfilename("fullpath"));
cfg.projectRoot = fileparts(cfg.airSplitDir);
cfg.enhancedCoreDir = fullfile(cfg.projectRoot, "X410_CombinedTxRx_XL - 副本 - 副本");
cfg.preferEnhancedCore = isfolder(cfg.enhancedCoreDir);

% ---- Radio Setup names: EDIT THESE after saving two X410s in Radio Setup ----
cfg.txRadioName = "X410_TX";  % transmitter-side X410 saved configuration name
cfg.rxRadioName = "X410_RX";  % receiver-side X410 saved configuration name

% ---- RF plan ----
cfg.dataCenterFrequency = 3.184e9;  % data downlink frequency
cfg.ackCenterFrequency  = 1.784e9;  % feedback uplink frequency; keep separated from data

% Start conservative for OTA. Increase only after packet detection is stable.
cfg.dataTxGain = 5;     % dB, TX node data transmit gain
cfg.dataRxGain = 25;    % dB, RX node data receive gain
cfg.ackTxGain  = 0;     % dB, RX node ACK transmit gain
cfg.ackRxGain  = 35;    % dB, TX node ACK receive gain

% X410 native rate used by your original project. Keep it fixed to avoid reloads.
cfg.hwSampleRate = 250e6;

% Start at CBW20/MCS0/AMPDU1 for OTA bring-up; widen later.
cfg.initialChanBW = "CBW20";
cfg.initialBWdec  = 2;       % 2=CBW20, 4=CBW40, 8=CBW80, 16=CBW160
cfg.ackChanBW     = "CBW20"; % fixed robust feedback channel
cfg.initialMCS    = 0;
cfg.initialAMPDU  = 1;
cfg.payloadLength = 2304;    % bytes
cfg.idleTime      = 8e-6;    % larger than loopback to reduce packet-boundary false locks
cfg.dataTxScale   = 0.6;
cfg.feedbackTxScale = 0.6;

% Capture lengths. Increase RX capture if it misses packets; decrease after stable.
cfg.dataCaptureTime = milliseconds(50);
cfg.ackCaptureTime  = milliseconds(40);

% Antenna indices into hTransmitAntennas/hCaptureAntennas.
cfg.txPortIdx = 1; % DB0:RF0:TX/RX0 in your helper
cfg.rxPortIdx = 1; % DB0:RF0:RX1 in your helper

% Run control
cfg.N = 200;
cfg.algorithmMode = "QLOLLA";  % AARF | OLLA | AOLLA | QLOLLA
cfg.csiLogDir = fullfile(pwd, "CSI_LOGS_X410_OTA");

% OTA safety defaults. Independent X410 LOs can create CFO above the
% loopback-only 5 kHz rejection gate, so keep a wider reject threshold.
cfg.cfoRejectThresholdHz = 50e3;
cfg.enableBandwidthAdaptation = false;
cfg.explorationEpsilon = 0;
cfg.noFeedbackRollbackLimit = 5;
cfg.rollbackMCS = 0;
cfg.rollbackAMPDU = 1;
cfg.rollbackBWdec = 2;

% Feedback protocol. The robust payload wraps the original ack/arq decision
% to avoid random payload bytes being mistaken for control feedback.
cfg.feedbackMagic = "X4FB";
cfg.feedbackVersion = 1;
cfg.acceptLegacyFeedback = false;

% Conservative controller protection inherited from the single-host enhanced link.
cfg.mcsStepCap = 2;
cfg.freezeAfterConsecutiveEvents = 2;
cfg.freezeDuration = 1;
end
