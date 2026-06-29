function DoE_hpc_worker(plan_dir, sim_dir, local_results_dir, shared_results_dir, actual_values_filename, model_root)
% DoE_hpc_worker - low-I/O dynamic MATLAB worker for DoE_main.m.
%
% One MATLAB process stays alive, loads the model once, claims several chunks,
% runs DoE_main in the base workspace, writes chunk results to node-local SSD,
% and copies only finished CSV result chunks back to the shared results folder.

    if nargin < 1 || isempty(plan_dir)
        plan_dir = fullfile(pwd, 'logs', 'doe_current_plan');
    end
    if nargin < 2 || isempty(sim_dir)
        sim_dir = pwd;
    end
    if nargin < 3 || isempty(local_results_dir)
        local_results_dir = fullfile(tempdir, 'doe_worker_results');
    end
    if nargin < 4 || isempty(shared_results_dir)
        shared_results_dir = fullfile(pwd, 'DoE', 'DoE_Hybrid_HPC_Results', 'chunks');
    end
    if nargin < 5
        actual_values_filename = '';
    end
    if nargin < 6 || isempty(model_root)
        model_root = discoverModelRoot(sim_dir);
    end

    plan_dir = char(string(plan_dir));
    sim_dir = char(string(sim_dir));
    local_results_dir = char(string(local_results_dir));
    shared_results_dir = char(string(shared_results_dir));
    actual_values_filename = char(string(actual_values_filename));
    model_root = char(string(model_root));

    manifest_file = fullfile(plan_dir, 'manifest.csv');
    claim_root = fullfile(plan_dir, 'claims');
    done_root = fullfile(plan_dir, 'done');
    local_input_dir = fullfile(local_results_dir, 'inputs');

    if ~isfolder(plan_dir), error('Plan directory not found: %s', plan_dir); end
    if ~isfile(manifest_file), error('Manifest file not found: %s', manifest_file); end
    if ~isfolder(sim_dir), error('Simulation directory not found: %s', sim_dir); end
    if ~isfolder(model_root), error('Simulation_Model root not found: %s', model_root); end

    ensureDir(claim_root);
    ensureDir(done_root);
    ensureDir(local_results_dir);
    ensureDir(local_input_dir);
    ensureDir(shared_results_dir);

    worker_id = getenv('DOE_WORKER_INDEX');
    if isempty(worker_id), worker_id = getenv('SLURM_ARRAY_TASK_ID'); end
    if isempty(worker_id), worker_id = char(string(feature('getpid'))); end
    host_name = getenv('HOSTNAME');
    if isempty(host_name), [~, host_name] = system('hostname'); host_name = strtrim(host_name); end

    tmp_root = getenv('TMPDIR');
    if isempty(tmp_root), tmp_root = tempdir; end

    fprintf('============================================================\n');
    fprintf('DoE_hpc_worker low-I/O mode\n');
    fprintf('============================================================\n');
    fprintf('Worker id         : %s\n', worker_id);
    fprintf('Host              : %s\n', host_name);
    fprintf('Plan dir          : %s\n', plan_dir);
    fprintf('Sim dir local     : %s\n', sim_dir);
    fprintf('Model root local  : %s\n', model_root);
    fprintf('Local result dir  : %s\n', local_results_dir);
    fprintf('Shared chunks dir : %s\n', shared_results_dir);
    fprintf('TMPDIR            : %s\n', tmp_root);
    fprintf('MATLAB prefdir    : %s\n', prefdir);
    fprintf('============================================================\n');

    cd(sim_dir);
    % Repo-aware path setup. The active DoE_main.m lives in the test-run folder,
    % but Simulink models and shared classes can be elsewhere under Simulation_Model.
    % Add the whole model root at the end and the active run folder at the beginning
    % so local Krisna_20260625 files take precedence over _copy/Shikhar_MA variants.
    addpath(genpath(model_root), '-end');
    addpath(genpath(sim_dir), '-begin');

    try
        Simulink.fileGenControl('set', ...
            'CacheFolder', fullfile(tmp_root, 'simulink_cache'), ...
            'CodeGenFolder', fullfile(tmp_root, 'simulink_codegen'), ...
            'createDir', true);
    catch ME
        fprintf('WARNING: Simulink.fileGenControl failed: %s\n', ME.message);
    end

    manifest = readManifestTable(manifest_file);
    manifest = normalizeManifestColumns(manifest, manifest_file);

    doe_main_path = fullfile(sim_dir, 'DoE_main.m');
    if ~isfile(doe_main_path)
        error('DoE_main.m not found in local sim dir: %s', doe_main_path);
    end

    processed = 0;
    failed = 0;

    while true
        [row_idx, chunk_id] = claimNextChunk(manifest, claim_root, done_root, worker_id, host_name);
        if row_idx == 0
            fprintf('No open chunks left. Worker exits. Processed chunks: %d\n', processed);
            break;
        end

        chunk_csv_shared = char(manifest.chunk_csv(row_idx));
        output_csv_shared = char(manifest.output_csv(row_idx));
        local_chunk_csv = fullfile(local_input_dir, sprintf('DoE_chunk_%06d.csv', chunk_id));
        local_output_csv = fullfile(local_results_dir, sprintf('DoE_chunk_%06d.csv', chunk_id));
        done_marker = fullfile(done_root, sprintf('chunk_%06d.done', chunk_id));
        failed_marker = fullfile(done_root, sprintf('chunk_%06d.failed', chunk_id));

        fprintf('\n------------------------------------------------------------\n');
        fprintf('Chunk %06d claimed by worker %s\n', chunk_id, worker_id);
        fprintf('Input shared : %s\n', chunk_csv_shared);
        fprintf('Input local  : %s\n', local_chunk_csv);
        fprintf('Output local : %s\n', local_output_csv);
        fprintf('Output shared: %s\n', output_csv_shared);

        try
            % Recompute planned chunks even if an old shared CSV exists. A previous
            % failed model-path run can leave non-empty CSV files with NaN-only
            % simulation values; the planner only schedules rows that are missing
            % or invalid, so overwriting this output is intentional.

            if isfile(local_output_csv), delete(local_output_csv); end
            copyfile(chunk_csv_shared, local_chunk_csv, 'f');

            evalin('base', ['clear csv_filename output_filename actual_values_filename TaskID ChunkSize ', ...
                'DOE_HPC_MODE DOE_KEEP_MODEL_LOADED DOE_USE_FAST_RESTART ', ...
                'DOE_CLOSE_MODEL_AFTER_RUN DOE_SL_MODEL_NAME DOE_MODEL_ROOT DOE_TEMP_ROOT ', ...
                'DOE_ADD_ACTUAL_COMPARISON']);
            assignin('base', 'TaskID', 1);
            assignin('base', 'ChunkSize', []);
            assignin('base', 'csv_filename', local_chunk_csv);
            assignin('base', 'output_filename', local_output_csv);
            assignin('base', 'actual_values_filename', actual_values_filename);
            assignin('base', 'DOE_HPC_MODE', true);
            assignin('base', 'DOE_KEEP_MODEL_LOADED', true);

            % IMPORTANT: keep Fast Restart disabled by default. The DoE input
            % changes No_Gears/Gear_Ratio dimensions between runs. With Fast
            % Restart enabled, Simulink keeps the model compiled and then fails
            % with messages such as "Cannot change the dimensions of run-time
            % parameter ... from [1x8] to [1x7] while model is executing".
            % The model is still loaded only once; only the compiled FastRestart
            % state is not reused across rows. Set environment variable
            % DOE_USE_FAST_RESTART=1 only for pre-grouped runs with constant
            % gearbox dimensions.
            use_fast_restart_raw = getenv('DOE_USE_FAST_RESTART');
            use_fast_restart = strcmp(use_fast_restart_raw, '1') || strcmpi(use_fast_restart_raw, 'true');
            assignin('base', 'DOE_USE_FAST_RESTART', use_fast_restart);

            assignin('base', 'DOE_CLOSE_MODEL_AFTER_RUN', false);
            assignin('base', 'DOE_ADD_ACTUAL_COMPARISON', false);
            assignin('base', 'DOE_TEMP_ROOT', tmp_root);
            assignin('base', 'DOE_MODEL_ROOT', model_root);
            assignin('base', 'DOE_SL_MODEL_NAME', 'Simulation_Fahrmodell_v4_straight_line');

            evalin('base', sprintf('run(%s);', matlabQuote(doe_main_path)));

            if ~isFinishedOutput(local_output_csv)
                error('Local output was not created or is empty: %s', local_output_csv);
            end

            copyFileAtomic(local_output_csv, output_csv_shared);
            writeText(done_marker, sprintf('done worker=%s host=%s time=%s', worker_id, host_name, datestr(now)));
            processed = processed + 1;
            fprintf('Chunk %06d finished and copied back.\n', chunk_id);
        catch ME
            failed = failed + 1;
            writeText(failed_marker, getReport(ME, 'extended', 'hyperlinks', 'off'));
            fprintf('!!! Chunk %06d failed !!!\n', chunk_id);
            fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
            rethrow(ME);
        end
    end

    try
        mdl = 'Simulation_Fahrmodell_v3_straight_line';
        if bdIsLoaded(mdl)
            try, set_param(mdl, 'FastRestart', 'off'); catch, end
            close_system(mdl, 0);
        end
    catch ME
        fprintf('WARNING during model cleanup: %s\n', ME.message);
    end

    fprintf('Worker finished. processed=%d failed=%d\n', processed, failed);
end


function model_root = discoverModelRoot(sim_dir)
    model_root = char(string(sim_dir));
    current = model_root;
    for k = 1:8
        [parent, name] = fileparts(current);
        if strcmp(name, 'Simulation_Model')
            model_root = current;
            return;
        end
        if isempty(parent) || strcmp(parent, current)
            break;
        end
        current = parent;
    end
end

function T = readManifestTable(manifest_file)
    % Robust CSV import for the shared manifest. This avoids false failures when
    % MATLAB guesses another delimiter or changes variable names.
    first_line = '';
    fid = fopen(manifest_file, 'r');
    if fid >= 0
        cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
        first_line = fgetl(fid);
    end
    fprintf('Manifest file      : %s\n', manifest_file);
    fprintf('Manifest first line: %s\n', char(string(first_line)));

    try
        opts = detectImportOptions(manifest_file, ...
            'FileType', 'text', ...
            'Delimiter', ',', ...
            'VariableNamingRule', 'preserve');
        T = readtable(manifest_file, opts, 'TextType', 'string');
    catch ME1
        fprintf('WARNING: detectImportOptions/readtable failed: %s\n', ME1.message);
        T = readtable(manifest_file, ...
            'FileType', 'text', ...
            'Delimiter', ',', ...
            'TextType', 'string', ...
            'VariableNamingRule', 'preserve');
    end

    fprintf('Manifest columns detected:\n');
    for i = 1:numel(T.Properties.VariableNames)
        fprintf('  %02d: %s\n', i, T.Properties.VariableNames{i});
    end
end

function T = normalizeManifestColumns(T, manifest_file)
    names = string(T.Properties.VariableNames);
    norm_names = normalizeColumnNames(names);

    chunk_idx = findFirstColumn(norm_names, {'chunkid', 'chunk'});
    input_idx = findFirstColumn(norm_names, {'chunkcsv', 'inputcsv', 'pendingcsv'});
    output_idx = findFirstColumn(norm_names, {'outputcsv', 'outputxlsx'});

    if chunk_idx == 0 || input_idx == 0 || output_idx == 0
        msg = sprintf(['Manifest does not have the required columns after robust import.\n', ...
            'Required logical columns: chunk_id, chunk_csv/input_csv, output_csv/output_xlsx.\n', ...
            'File: %s\nDetected columns: %s'], ...
            manifest_file, strjoin(cellstr(names), ', '));
        error('%s', msg);
    end

    T.Properties.VariableNames{chunk_idx} = 'chunk_id';
    T.Properties.VariableNames{input_idx} = 'chunk_csv';
    T.Properties.VariableNames{output_idx} = 'output_csv';

    % Convert chunk_id explicitly. readtable can import it as string depending on
    % MATLAB settings and locale.
    if ~isnumeric(T.chunk_id)
        T.chunk_id = str2double(string(T.chunk_id));
    end
    bad = isnan(T.chunk_id);
    if any(bad)
        error('Manifest contains non-numeric chunk_id values. Bad rows: %s', mat2str(find(bad)'));
    end
end

function out = normalizeColumnNames(names)
    out = strings(size(names));
    for i = 1:numel(names)
        s = lower(string(names(i)));
        s = erase(s, char(65279)); % UTF-8 BOM, if present
        s = regexprep(s, '[^a-z0-9]', '');
        out(i) = s;
    end
end

function idx = findFirstColumn(norm_names, aliases)
    idx = 0;
    for a = 1:numel(aliases)
        hit = find(norm_names == string(aliases{a}), 1, 'first');
        if ~isempty(hit)
            idx = hit;
            return;
        end
    end
end

function [row_idx, chunk_id] = claimNextChunk(manifest, claim_root, done_root, worker_id, host_name)
    row_idx = 0;
    chunk_id = 0;
    for r = 1:height(manifest)
        cid = double(manifest.chunk_id(r));
        done_marker = fullfile(done_root, sprintf('chunk_%06d.done', cid));
        if isfile(done_marker)
            continue;
        end

        claim_dir = fullfile(claim_root, sprintf('chunk_%06d.claim', cid));
        cmd = sprintf('mkdir %s', shellQuote(claim_dir));
        [status, ~] = system(cmd);
        if status == 0
            writeText(fullfile(claim_dir, 'owner.txt'), sprintf('worker=%s\nhost=%s\ntime=%s\n', worker_id, host_name, datestr(now)));
            row_idx = r;
            chunk_id = cid;
            return;
        end
    end
end

function tf = isFinishedOutput(path)
    tf = false;
    if isfile(path)
        info = dir(path);
        tf = ~isempty(info) && info.bytes > 0;
    end
end

function ensureDir(path)
    if ~isfolder(path), mkdir(path); end
end

function writeText(path, text)
    parent = fileparts(path);
    if ~isempty(parent), ensureDir(parent); end
    fid = fopen(path, 'w');
    if fid < 0, error('Could not write marker: %s', path); end
    cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', text);
end

function copyFileAtomic(src, dst)
    parent = fileparts(dst);
    ensureDir(parent);
    tmp = [dst '.tmp.' char(java.util.UUID.randomUUID())];
    copyfile(src, tmp, 'f');
    movefile(tmp, dst, 'f');
end

function q = matlabQuote(path)
    sq = char(39);
    q = [sq strrep(char(path), sq, [sq sq]) sq];
end

function q = shellQuote(path)
    sq = char(39);
    q = [sq strrep(char(path), sq, [sq '"' sq '"' sq]) sq];
end
