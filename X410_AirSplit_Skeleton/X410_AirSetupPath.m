function X410_AirSetupPath(cfg)
%X410_AIRSETUPPATH Put AirSplit and selected project core on MATLAB path.

if isfield(cfg, 'airSplitDir') && isfolder(cfg.airSplitDir)
    addpath(cfg.airSplitDir, "-begin");
end

if isfield(cfg, 'preferEnhancedCore') && cfg.preferEnhancedCore && ...
        isfield(cfg, 'enhancedCoreDir') && isfolder(cfg.enhancedCoreDir)
    addpath(cfg.enhancedCoreDir, "-begin");
elseif isfield(cfg, 'projectRoot') && isfolder(cfg.projectRoot)
    warning("X410_AirSplit:CorePath", ...
        "Enhanced core directory not found; falling back to project root helpers.");
end

if isfield(cfg, 'projectRoot') && isfolder(cfg.projectRoot)
    addpath(cfg.projectRoot, "-end");
end
end
