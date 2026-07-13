function runX410AllAlgorithms()
% Run the four X410 link-adaptation algorithms sequentially.

runDir = fileparts(mfilename("fullpath"));
mainFile = fullfile(runDir, "X410_runSingleHost_DualRole_AARF.m");
algorithms = ["AARF","OLLA","AOLLA","QLOLLA"];

if ~isfile(mainFile)
    error("Main script not found: %s", mainFile);
end

originalText = fileread(mainFile);
restoreObj = onCleanup(@() localRestore(mainFile, originalText));

for k = 1:numel(algorithms)
    alg = algorithms(k);
    fprintf("\n==============================\n");
    fprintf("Running algorithm: %s\n", alg);
    fprintf("==============================\n");

    txt = fileread(mainFile);
    txt = regexprep(txt, ...
        'algorithmMode\s*=\s*"[A-Za-z0-9_]+"\s*;', ...
        sprintf('algorithmMode = "%s";', alg), ...
        'once');

    fid = fopen(mainFile, 'w');
    if fid < 0
        error("Unable to open main script for writing: %s", mainFile);
    end
    fwrite(fid, txt);
    fclose(fid);

    evalin('base', 'try, clear classes; catch, end');
    evalin('base', sprintf('run("%s")', strrep(mainFile, '\', '\\')));
end

fprintf("\nAll algorithms finished.\n");
end

function localRestore(mainFile, originalText)
fid = fopen(mainFile, 'w');
if fid >= 0
    fwrite(fid, originalText);
    fclose(fid);
end
end
