% DoE_main.m - local + HPC capable DoE runner
%
% Local execution:
%   cd("Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf")
%   run("DoE_main.m")
%
% HPC execution:
%   DoE_hpc_worker assigns csv_filename/output_filename and runs this script in
%   the MATLAB base workspace. The script therefore remains close to the
%   original DoE_main logic, but supports local $TMPDIR execution and CSV output.

% Keep local execution robust: run relative paths from this script folder.
script_dir = fileparts(mfilename('fullpath'));
if ~isempty(script_dir)
    cd(script_dir);
end

% Allgemeiner DoE-Input: dieselbe Schema-Datei kann ICE, Hybrid und EV enthalten.
% Prefer the full generated input. Fall back to a random test subset when used
% inside an exported debug folder.

default_doe = 'DoE_Inp_random15.csv';

default_actualvalues    = 'DoE_Inp_ActualValues.xlsx';

default_sim             = 'Simulation_Fahrmodell_v4_straight_line';

% Get default chunk from table height
try
    temp_T = readtable(fullfile('DoE', default_doe));
    default_chunk = height(temp_T);
    clear temp_T
catch
    default_chunk = 1;
end

% --- 0. SAFETY CHECK / OPTIONAL HPC OVERRIDES ---
if ~exist('TaskID', 'var') || isempty(TaskID), TaskID = 1; end
if ~exist('ChunkSize', 'var'), ChunkSize = default_chunk; end
if ~exist('csv_filename', 'var') || isempty(csv_filename), csv_filename = fullfile('DoE', default_doe); end
if ~exist('output_filename', 'var') || isempty(output_filename), output_filename = fullfile('DoE', sprintf('Results_Chunk_%d.xlsx', TaskID)); end
if ~exist('actual_values_filename', 'var') || isempty(actual_values_filename), actual_values_filename = fullfile('DoE', default_actualvalues); end

if ~exist('DOE_HPC_MODE', 'var') || isempty(DOE_HPC_MODE), DOE_HPC_MODE = false; end
if ~exist('DOE_KEEP_MODEL_LOADED', 'var') || isempty(DOE_KEEP_MODEL_LOADED), DOE_KEEP_MODEL_LOADED = false; end
if ~exist('DOE_USE_FAST_RESTART', 'var') || isempty(DOE_USE_FAST_RESTART), DOE_USE_FAST_RESTART = false; end
if ~exist('DOE_CLOSE_MODEL_AFTER_RUN', 'var') || isempty(DOE_CLOSE_MODEL_AFTER_RUN), DOE_CLOSE_MODEL_AFTER_RUN = false; end
if ~exist('DOE_SL_MODEL_NAME', 'var') || isempty(DOE_SL_MODEL_NAME), DOE_SL_MODEL_NAME = default_sim; end
if ~exist('DOE_TEMP_ROOT', 'var'), DOE_TEMP_ROOT = ''; end
if ~exist('DOE_MODEL_ROOT', 'var') || isempty(DOE_MODEL_ROOT), DOE_MODEL_ROOT = discoverModelRoot(script_dir); end
if ~exist('DOE_ADD_ACTUAL_COMPARISON', 'var') || isempty(DOE_ADD_ACTUAL_COMPARISON)
    [~, ~, outExt] = fileparts(char(string(output_filename)));
    DOE_ADD_ACTUAL_COMPARISON = strcmpi(outExt, '.xlsx');
end

DOE_HPC_MODE = logical(DOE_HPC_MODE);
DOE_KEEP_MODEL_LOADED = logical(DOE_KEEP_MODEL_LOADED);
DOE_USE_FAST_RESTART = logical(DOE_USE_FAST_RESTART);
DOE_CLOSE_MODEL_AFTER_RUN = logical(DOE_CLOSE_MODEL_AFTER_RUN);
DOE_ADD_ACTUAL_COMPARISON = logical(DOE_ADD_ACTUAL_COMPARISON);

fprintf('=== DoE_main STARTED: TaskID %d | ChunkSize %s ===\n', TaskID, mat2str(ChunkSize));
fprintf('Input file : %s\n', char(string(csv_filename)));
fprintf('Output file: %s\n', char(string(output_filename)));
fprintf('HPC mode   : %d\n', DOE_HPC_MODE);

% Keep Simulink generated files off HOME/shared FS when DOE_TEMP_ROOT is set.
if strlength(string(DOE_TEMP_ROOT)) > 0
    try
        cacheFolder = fullfile(char(string(DOE_TEMP_ROOT)), 'simulink_cache');
        codegenFolder = fullfile(char(string(DOE_TEMP_ROOT)), 'simulink_codegen');
        Simulink.fileGenControl('set', ...
            'CacheFolder', cacheFolder, ...
            'CodeGenFolder', codegenFolder, ...
            'createDir', true);
        fprintf('Simulink CacheFolder : %s\n', cacheFolder);
        fprintf('Simulink CodeGenFolder: %s\n', codegenFolder);
    catch ME
        fprintf('WARNING: Could not set Simulink file generation folders: %s\n', ME.message);
    end
end

% Add Folders to Path
addpath(genpath("Config Scripts"))
addpath(genpath("DoE"))
addpath(genpath("Future"))
addpath(genpath("init_NBR Scripts"))
addpath(genpath("Reference Drive Cycle"))
addpath(genpath("Simulation Scripts"))
if strlength(string(DOE_MODEL_ROOT)) > 0 && isfolder(char(string(DOE_MODEL_ROOT)))
    addpath(genpath(char(string(DOE_MODEL_ROOT))), '-end');
    addpath(genpath(script_dir), '-begin');
    fprintf('Simulation_Model root: %s\n', char(string(DOE_MODEL_ROOT)));
end

% Load the straight-line model once without opening the Simulink UI.
% In HPC mode this stays loaded across chunks because DoE_hpc_worker runs
% several chunks in the same MATLAB process.
DOE_SL_MODEL_FILE = locateSimulinkModel(DOE_SL_MODEL_NAME, script_dir, DOE_MODEL_ROOT);
if isempty(DOE_SL_MODEL_FILE)
    error(['Could not find required Simulink model %s(.slx/.mdl).\n', ...
           'Searched current folder, MATLAB path, script folder, and Simulation_Model root.\n', ...
           'script_dir=%s\nDOE_MODEL_ROOT=%s'], ...
           char(string(DOE_SL_MODEL_NAME)), script_dir, char(string(DOE_MODEL_ROOT)));
end
[~, DOE_SL_MODEL_SIM_NAME, ~] = fileparts(DOE_SL_MODEL_FILE);
fprintf('Simulink model file: %s\n', DOE_SL_MODEL_FILE);
try
    if ~bdIsLoaded(DOE_SL_MODEL_SIM_NAME)
        load_system(DOE_SL_MODEL_FILE);
        fprintf('Loaded Simulink model once: %s\n', DOE_SL_MODEL_SIM_NAME);
    end
    % The ICE multi-speed branch contains 1-D lookup blocks for
    % Gear -> i_GET. In the original model their breakpoint vector is
    % [1:1:gb.No_Gears]. For valid one-speed DoE rows this evaluates to
    % a single breakpoint, which Simulink rejects during compilation.
    % Use dedicated lookup variables instead. DoE_main guarantees below
    % that gb_Gears_LUT and gb_Gear_Ratio_LUT contain at least two lookup
    % points. gb.No_Gears remains the physical gear count and is still
    % used by the shift manager.
    patchGearRatioLookupBreakpoints(DOE_SL_MODEL_SIM_NAME);

    if DOE_USE_FAST_RESTART
        try
            set_param(DOE_SL_MODEL_SIM_NAME, 'FastRestart', 'on');
            fprintf('FastRestart enabled for %s\n', DOE_SL_MODEL_SIM_NAME);
        catch MEfr
            fprintf('WARNING: Could not enable FastRestart: %s\n', MEfr.message);
        end
    else
        % DoE rows can change gearbox map dimensions, e.g. 8 gears -> 7 gears.
        % Fast Restart would keep the model compiled and then reject these
        % dimension changes. Keep the model loaded, but do not keep the compiled
        % FastRestart state across simulations.
        try
            set_param(DOE_SL_MODEL_SIM_NAME, 'FastRestart', 'off');
            fprintf('FastRestart disabled for variable-dimension DoE rows.\n');
        catch MEfrOff
            fprintf('WARNING: Could not disable FastRestart: %s\n', MEfrOff.message);
        end
    end
catch MEload
    error('Could not load Simulink model file %s: %s', DOE_SL_MODEL_FILE, MEload.message);
end

% --- 1. INITIALIZATION ---
% This is intentionally still script-style. When run locally it is the base
% workspace; when run by DoE_hpc_worker it is executed via evalin('base', ...).
if ~exist('Track', 'var')
    fprintf("Running init_NBR...\n");
    init_NBR();
end

% --- 2. LOAD CONFIGURATIONS ---
if isempty(which(csv_filename)) && ~isfile(csv_filename)
    error('Config file %s not found.', char(string(csv_filename)));
end

all_configs = loadConfig(csv_filename);
total_configs = length(all_configs);

% --- 3. DETERMINE LOOP RANGE ---
% If ChunkSize is empty, process the complete input CSV. This is used by the
% dynamic HPC worker because it passes already-small chunk CSVs.
if isempty(ChunkSize)
    start_idx = 1;
    end_idx = total_configs;
else
    start_idx = (TaskID - 1) * ChunkSize + 1;
    end_idx   = start_idx + ChunkSize - 1;
end

if start_idx > total_configs
    fprintf('Start index %d > Total configs %d. Exiting.\n', start_idx, total_configs);
    return;
end
if end_idx > total_configs, end_idx = total_configs; end

fprintf('Processing Rows %d to %d\n', start_idx, end_idx);

results_struct = [];

%% Prepare to save for Debug only if not HPC Mode
if ~DOE_HPC_MODE
    % Get actual datetime
    actual_datetime = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));

    % Create main folder if not yet exist
    save_dir_local = "Export_Debug_local";
    if ~exist(save_dir_local, 'dir')
        mkdir(save_dir_local)
    end

    % Create save folder
    save_dir = fullfile(save_dir_local, actual_datetime);
    mkdir(save_dir)

end

% --- 4. MAIN SIMULATION LOOP ---
for i = start_idx:end_idx
    
    cfg = all_configs(i);
    runID_value = NaN;
    if isfield(cfg, 'RUN_ID') && ~isempty(cfg.RUN_ID)
        runID_value = str2double(string(cfg.RUN_ID));
    end
    if isfinite(runID_value)
        runID = runID_value;
    else
        runID = i;
    end

    [cfg, inputWarnings, inputErrors] = validateAndRepairInput(cfg, runID);
    if ~isempty(inputErrors)
        fprintf('--- Skipping Row %d (RunID: %d) because of input error(s): %s ---\n', ...
            i, runID, char(strjoin(inputErrors, ' | ')));
        current_result = makeSkippedResult(cfg, runID, inputWarnings, inputErrors);
        if isempty(results_struct)
            results_struct = current_result;
        else
            results_struct = appendStruct(results_struct, current_result);
        end
        continue;
    end

    % --- Robust topology cleanup for AMS/legacy CSV inputs ---
    % Hybrid and EV are mutually exclusive with VM in VehicleConfig/PowertrainConfig.
    if isfield(cfg, 'EV') && cfg.EV == 1
        cfg.VM = 0;
        cfg.Hy = 0;
        % Pure EV must use E0-E4, not hybrid P-position flags.
        if ~isfield(cfg, 'E0'), cfg.E0 = 0; end
        if ~isfield(cfg, 'E1'), cfg.E1 = 0; end
        if ~isfield(cfg, 'E2'), cfg.E2 = 0; end
        if ~isfield(cfg, 'E3'), cfg.E3 = 0; end
        if ~isfield(cfg, 'E4'), cfg.E4 = 0; end
        if ~(cfg.E0 || cfg.E1 || cfg.E2 || cfg.E3 || cfg.E4)
            if isfield(cfg, 'AWD') && cfg.AWD == 1
                cfg.E2 = 1;
            else
                cfg.E0 = 1;
            end
        end

        % Legacy EV CSV fallback: older converter versions stored EV power in P2/P4.
        oldPwr = 0; oldTq = 0; oldN = 16000;
        if isfield(cfg, 'Pwr_EV_max_kW') && cfg.Pwr_EV_max_kW > 0, oldPwr = cfg.Pwr_EV_max_kW; end
        if isfield(cfg, 'Pwr_P2_max_kW') && cfg.Pwr_P2_max_kW > oldPwr, oldPwr = cfg.Pwr_P2_max_kW; end
        if isfield(cfg, 'Pwr_P4_max_kW') && cfg.Pwr_P4_max_kW > oldPwr, oldPwr = cfg.Pwr_P4_max_kW; end
        if isfield(cfg, 'tq_EV_max') && cfg.tq_EV_max > 0, oldTq = cfg.tq_EV_max; end
        if isfield(cfg, 'tq_P2_max') && cfg.tq_P2_max > oldTq, oldTq = cfg.tq_P2_max; end
        if isfield(cfg, 'tq_P4_max') && cfg.tq_P4_max > oldTq, oldTq = cfg.tq_P4_max; end
        if isfield(cfg, 'n_EV_max') && cfg.n_EV_max > 0, oldN = cfg.n_EV_max;
        elseif isfield(cfg, 'n_P2_max') && cfg.n_P2_max > 0, oldN = cfg.n_P2_max;
        elseif isfield(cfg, 'n_P4_max') && cfg.n_P4_max > 0, oldN = cfg.n_P4_max; end

        nMot = 1; hasSecondary = false;
        if cfg.E1 == 1, nMot = 2; end
        if cfg.E2 == 1, nMot = 2; hasSecondary = true; end
        if cfg.E3 == 1, nMot = 3; hasSecondary = true; end
        if cfg.E4 == 1, nMot = 4; hasSecondary = true; end
        if ~isfield(cfg, 'Pwr_EV_max_kW') || cfg.Pwr_EV_max_kW <= 0, cfg.Pwr_EV_max_kW = oldPwr / nMot; end
        if ~isfield(cfg, 'tq_EV_max') || cfg.tq_EV_max <= 0, cfg.tq_EV_max = oldTq / nMot; end
        if ~isfield(cfg, 'n_EV_max') || cfg.n_EV_max <= 0, cfg.n_EV_max = oldN; end
        if ~isfield(cfg, 'Pwr_EV_nmax_red_perc'), cfg.Pwr_EV_nmax_red_perc = 0.04; end
        if hasSecondary
            if ~isfield(cfg, 'Pwr_P4_max_kW') || cfg.Pwr_P4_max_kW <= 0, cfg.Pwr_P4_max_kW = oldPwr / nMot; end
            if ~isfield(cfg, 'tq_P4_max') || cfg.tq_P4_max <= 0, cfg.tq_P4_max = oldTq / nMot; end
            if ~isfield(cfg, 'n_P4_max') || cfg.n_P4_max <= 0, cfg.n_P4_max = oldN; end
        end

        cfg.P0 = 0; cfg.P2 = 0; cfg.P3 = 0; cfg.P4 = 0; cfg.P4_DM = 0;
    elseif isfield(cfg, 'Hy') && cfg.Hy == 1
        cfg.VM = 0;
        cfg.EV = 0;
    end
    % P4 single motor and P4 dual-motor are mutually exclusive. Prefer P4_DM.
    if isfield(cfg, 'P4') && isfield(cfg, 'P4_DM') && cfg.P4 == 1 && cfg.P4_DM == 1
        if isfield(cfg, 'RUN_ID')
            fprintf('WARNING RunID %d: P4 and P4_DM are both 1. Setting P4=0 and keeping P4_DM=1.\n', cfg.RUN_ID);
        else
            fprintf('WARNING: P4 and P4_DM are both 1. Setting P4=0 and keeping P4_DM=1.\n');
        end
        cfg.P4 = 0;
    end
    
    if isfield(cfg, 'RUN_ID'), runID = cfg.RUN_ID;
    else, runID = i; end

    fprintf('--- Processing Row %d (RunID: %d) ---\n', i, runID);

    % === OBJECT SETUP ===
    % These are now created in the BASE WORKSPACE. 
    % Simulink can see them immediately.
    
    % --- Vehicle Config ---
    veh = VehicleConfig();
    veh.VM     = cfg.VM;
    veh.EV     = cfg.EV;
    veh.Hy     = cfg.Hy;
    veh.HM_VA  = cfg.HM_VA;
    veh.AWD    = cfg.AWD;
    veh.iAG    = cfg.iAG;
    veh.m_curb     = cfg.m_curb;
    veh.Wheelbase = cfg.Wheelbase;
    veh.h_s = cfg.h_s;
    veh.weight_dist = cfg.weight_dist;
    veh.MainAxle_TorqueSplit_int = cfg.MainAxle_TorqueSplit_int;
    veh.Hybrid_ICE_priority = cfg.Hybrid_ICE_priority;
    veh.d_wheel = cfg.d_wheel;
    veh.A_front = cfg.A_front;

    % --- Component Params ---
    cp = ComponentParams();
    cp.n_ICE_idle = cfg.n_ICE_idle;
    cp.n_ICE_max = cfg.n_ICE_max;
    cp.tq_ICE_idle = cfg.tq_ICE_idle;
    cp.tq_ICE_max = cfg.tq_ICE_max;
    cp.Pwr_ICE_max_kW = cfg.Pwr_ICE_max_kW;
    cp.n_P0_max = cfg.n_P0_max;
    cp.tq_P0_max = cfg.tq_P0_max;
    cp.Pwr_P0_max_kW = cfg.Pwr_P0_max_kW;
    cp.Pwr_P0_nmax_red_perc = cfg.Pwr_P0_nmax_red_perc;
    cp.n_P2_max = cfg.n_P2_max;
    cp.tq_P2_max = cfg.tq_P2_max;
    cp.Pwr_P2_max_kW = cfg.Pwr_P2_max_kW;
    cp.Pwr_P2_nmax_red_perc = cfg.Pwr_P2_nmax_red_perc;
    cp.n_P3_max = cfg.n_P3_max;
    cp.tq_P3_max = cfg.tq_P3_max;
    cp.Pwr_P3_max_kW = cfg.Pwr_P3_max_kW;
    cp.Pwr_P3_nmax_red_perc = cfg.Pwr_P3_nmax_red_perc;
    cp.n_P4_max = cfg.n_P4_max;
    cp.tq_P4_max = cfg.tq_P4_max;
    cp.Pwr_P4_max_kW = cfg.Pwr_P4_max_kW;
    cp.Pwr_P4_nmax_red_perc = cfg.Pwr_P4_nmax_red_perc;
    % --- EV Component Params ---
    if isfield(cfg, 'n_EV_max'), cp.n_EV_max = cfg.n_EV_max; else, cp.n_EV_max = 16000; end
    if isfield(cfg, 'tq_EV_max'), cp.tq_EV_max = cfg.tq_EV_max; else, cp.tq_EV_max = 0; end
    if isfield(cfg, 'Pwr_EV_max_kW'), cp.Pwr_EV_max_kW = cfg.Pwr_EV_max_kW; else, cp.Pwr_EV_max_kW = 0; end
    if isfield(cfg, 'Pwr_EV_nmax_red_perc'), cp.Pwr_EV_nmax_red_perc = cfg.Pwr_EV_nmax_red_perc; else, cp.Pwr_EV_nmax_red_perc = 0.04; end


    cp = cp.computeICEMap(cfg.VM, cfg.Hy); 
    if isfield(cfg, 'P0'), cp = cp.computeP0Map(cfg.P0); end
    if isfield(cfg, 'P2'), cp = cp.computeP2Map(cfg.P2); end
    if isfield(cfg, 'P3'), cp = cp.computeP3Map(cfg.P3); end
    
    val_E0 = 0; if isfield(cfg, 'E0'), val_E0 = cfg.E0; end
    val_E1 = 0; if isfield(cfg, 'E1'), val_E1 = cfg.E1; end
    val_E2 = 0; if isfield(cfg, 'E2'), val_E2 = cfg.E2; end
    val_E3 = 0; if isfield(cfg, 'E3'), val_E3 = cfg.E3; end
    val_E4 = 0; if isfield(cfg, 'E4'), val_E4 = cfg.E4; end
    val_EV_primary = double(any([val_E0, val_E1, val_E2, val_E3, val_E4]));
    cp = cp.computeEVMap(val_EV_primary);

    val_P4 = 0; if isfield(cfg, 'P4'), val_P4 = cfg.P4; end
    val_P4_DM = 0; if isfield(cfg, 'P4_DM'), val_P4_DM = cfg.P4_DM; end
    
    % ----------------------------------------------------EV----------------
    % 2. HARDCODE zeros for EV-only flags (E2, E3, E4) since they are missing
    %%% val_E2 = 0;
    %%% val_E3 = 0;
    %%% val_E4 = 0;

    %val_E0    = 0; if isfield(cfg, 'E0'),    val_E0    = cfg.E0;    end
    %val_E1    = 0; if isfield(cfg, 'E1'),    val_E1    = cfg.E1;    end
    % ----------------------------------------------------EV----------------
    val_E2    = 0; if isfield(cfg, 'E2'),    val_E2    = cfg.E2;    end
    val_E3    = 0; if isfield(cfg, 'E3'),    val_E3    = cfg.E3;    end
    val_E4    = 0; if isfield(cfg, 'E4'),    val_E4    = cfg.E4;    end

    
    cp = cp.computeP4Map(val_P4, val_E2, val_P4_DM, val_E3, val_E4);

    % setup_turbo; % Beta/future scope

    % --- Gearbox Config ---
    gb = GearboxConfig();
    gb.i_GET_EV = cfg.i_GET_EV;
    gb.i_ges_P4 = cfg.i_ges_P4;
    gb.max_rpm = cfg.n_ICE_max;
    gb.mode = string(cfg.mode); 
    % gb.shiftDelay = cfg.shiftDelay; % nicht aus CSV übernehmen!
    gb.use_cus_val = logical(cfg.use_cus_val);
    gb.Gear_Ratio = parseNumericVector(cfg.Gear_Ratio);
    gb.No_Gears = cfg.No_Gears;
    if ~isempty(gb.Gear_Ratio)
        gb.No_Gears = numel(gb.Gear_Ratio);
    end
    gb.Gears = 1:max(0, gb.No_Gears);
    gb.pedal_pos = 0:0.1:1;

    isPureEV = isfield(cfg, 'EV') && cfg.EV == 1 && ...
               (~isfield(cfg, 'VM') || cfg.VM == 0) && ...
               (~isfield(cfg, 'Hy') || cfg.Hy == 0);

    if isPureEV
        % Pure EV rows do not use the ICE multi-speed branch, but Simulink
        % still parses the inactive lookup blocks during model compilation.
        % Therefore the EV row still needs a valid dummy 2D gearbox/RPM map.
        if isempty(gb.Gear_Ratio)
            gb.Gear_Ratio = 1;
        end
        if isempty(gb.No_Gears) || ~isfinite(gb.No_Gears) || gb.No_Gears < 1
            gb.No_Gears = numel(gb.Gear_Ratio);
        end
        if gb.No_Gears < 1
            gb.No_Gears = 1;
        end
        gb.Gears = 1:gb.No_Gears;
    elseif cfg.VM || cfg.Hy == 1
        if isempty(gb.Gear_Ratio) || gb.No_Gears < 1
            fprintf('WARNING RunID %d: Gear_Ratio/No_Gears missing although VM/Hy active. Using GearboxConfig.computeRatios() defaults.\n', runID);
            gb = gb.computeRatios();
        end
        gb = gb.computeShiftMaps();
    end

    % Always provide 2D RPM lookup tables for the Simulink gearbox selector.
    % This prevents EV rows from failing in the inactive ICE multi-speed branch
    % with "Table data is 1D, Number of table dimensions is 2".
    [gb, n_min_Upmin, n_max_Upmin] = ensureShiftLookupMaps2D(gb, cfg, cp, runID);

    % Re-apply the in-memory block patch after each row. This is cheap and
    % protects against model/link refreshes before sim() compiles the model.
    patchGearRatioLookupBreakpoints(DOE_SL_MODEL_SIM_NAME);

    % ShiftDelay 
    [gb.shiftDelay, shiftSrc, gbType, p2w] = resolveShiftDelay(cfg);
    if isfield(cfg, 'RUN_ID')
        fprintf('RunID %d: shiftDelay = %.3f s [%s], gearboxType="%s", P/m=%.1f kW/t\n', ...
            cfg.RUN_ID, gb.shiftDelay, shiftSrc, gbType, p2w);
    else
        fprintf('shiftDelay = %.3f s [%s], gearboxType="%s", P/m=%.1f kW/t\n', ...
            gb.shiftDelay, shiftSrc, gbType, p2w);
    end

    % --- Powertrain Config ---
    pt = PowertrainConfig();
    pt.VM = cfg.VM;
    pt.EV = cfg.EV;
    pt.Hy = cfg.Hy;
    
    pt.P0 = cfg.P0;
    pt.P2 = cfg.P2;
    pt.P3 = cfg.P3;
    pt.P4 = cfg.P4;
    pt.P4_DM = cfg.P4_DM;
    
    pt.E0 = 0; if isfield(cfg, 'E0'), pt.E0 = cfg.E0; end
    pt.E1 = 0; if isfield(cfg, 'E1'), pt.E1 = cfg.E1; end
    pt.E2 = 0; if isfield(cfg, 'E2'), pt.E2 = cfg.E2; end
    pt.E3 = 0; if isfield(cfg, 'E3'), pt.E3 = cfg.E3; end
    pt.E4 = 0; if isfield(cfg, 'E4'), pt.E4 = cfg.E4; end

    pt = pt.setupEV();
    pt = pt.setupHybrid();

    % --- Battery Config ---
    bat = BatteryConfig();
    bat.Cell_Cap_Ah = cfg.Cell_Cap_Ah;
    bat.Cell_V_nom = cfg.Cell_V_nom;
    bat.Cell_R_inner = cfg.Cell_R_inner;
    bat.Cell_V_min = cfg.Cell_V_min;
    bat.Cell_V_max = cfg.Cell_V_max;
    bat.Cell_I_max_chg = cfg.Cell_I_max_chg;
    bat.Cell_I_max_dis = cfg.Cell_I_max_dis;
    if ischar(cfg.SOC_Vector), bat.SOC_Vector = str2num(cfg.SOC_Vector); else, bat.SOC_Vector = cfg.SOC_Vector; end
    if ischar(cfg.Cell_OCV_Vector), bat.Cell_OCV_Vector = str2num(cfg.Cell_OCV_Vector); else, bat.Cell_OCV_Vector = cfg.Cell_OCV_Vector; end
    bat.n_s = cfg.n_s; bat.n_p = cfg.n_p;
    bat.facSocInit = cfg.facSocInit;
    bat.SOC_Recup_Limit = cfg.SOC_Recup_Limit;
    bat.SOC_Bat_Discharge_Limit = cfg.SOC_Bat_Discharge_Limit;
    bat = bat.computePack();

        %% === TIRE & AERO PARAMETER SELECTION ===
    [SKO_WHEEL_TYP_CHAL, SKO_STREET_CHAL, cw] = VehicleParamSelector(cp, veh);
    %[SKO_WHEEL_TYP_CHAL, cw] = VehicleParamSelector(cp, veh);
    % Variables are now in workspace AND pushed to base workspace by the function.
    % Simulink reads SKO_WHEEL_TYP_CHAL, cw, A_front directly from base workspace.
    veh.cw      = cw;

    %% Result / diagnostics placeholder
    current_result = initRunResult(cfg, runID, inputWarnings);
    current_result.ShiftDelay_used = gb.shiftDelay;
    current_result.ShiftDelay_source = string(shiftSrc);
    current_result.Gearbox_type_resolved = string(gbType);
    current_result.Power_to_weight_kW_per_t = p2w;
    current_result.GearCount_used = gb.No_Gears;
    current_result.GearRatio_used = string(mat2str(gb.Gear_Ratio));
    current_result.ElectricPower_req_kW_est = totalElectricPropulsionPowerMain(cfg);
    current_result.Battery_PackPower_dis_kW_est = estimatePackDischargePowerMain(cfg);
    current_result.Battery_Cell_I_max_dis_A_used = cfg.Cell_I_max_dis;
    current_result.Battery_n_s_used = cfg.n_s;
    current_result.Battery_n_p_used = cfg.n_p;
    current_result.SimStatus = "SETUP_OK";

    % Make actual Vmax/targets visible to optional Simulink stop/KPI blocks.
    vmaxLimit = getNumericField(cfg, 'Actual_max_speed_kmh', NaN);
    if ~isfinite(vmaxLimit) || vmaxLimit <= 0
        vmaxLimit = NaN;
    end
    current_result.Vmax_limit_used_kmh = vmaxLimit;
    current_result.Vmax_limiter_enabled = isfinite(vmaxLimit);
    if isfinite(vmaxLimit)
        vmaxDriverTarget = vmaxLimit;
    else
        vmaxDriverTarget = 350;
    end
    try
        assignin('base', 'Actual_max_speed_kmh', vmaxLimit);
        assignin('base', 'vmax_limit_kmh', vmaxLimit);
        assignin('base', 'vmax_driver_target_kmh', vmaxDriverTarget);
        assignin('base', 'SL_target_vmax_kmh', vmaxLimit);
        assignin('base', 'vmax_limiter_enable', double(isfinite(vmaxLimit)));
        assignin('base', 'vmax_limiter_band_kmh', 2.0);
    catch
    end

    % %% === RUN SIMULATION 1: Main Model ===
    % simOut_Main = [];
    % try
    %     simOut_Main = sim('Simulation_Fahrmodell_v3.slx');
    % catch ME
    %     fprintf('!!! CRITICAL ERROR Main Model (RunID: %d) !!!\n', runID);
    %     fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
    % end
    % 
    % % Extract Main
    % vars_main = {'SOC_Final', 'Lap_Time', 'Avg_track_speed', 'Energy_elc_consumed', 'Energy_elc_recuperated'}; 
    % current_result = extractVars(simOut_Main, vars_main, current_result, '');

    %% === RUN SIMULATION 2: Straight Line Model ===
    simOut_SL = [];
    try
        simOut_SL = sim(DOE_SL_MODEL_SIM_NAME);
        current_result.SimStatus = "OK";
    catch ME
        current_result.SimStatus = "SIM_ERROR";
        current_result.ErrorMessage = string(ME.message);
        fprintf('!!! CRITICAL ERROR SL Model (RunID: %d) !!!\n', runID);
        fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
    end

    % Extract SL. Missing variables are written as NaN, so this stays
    % compatible with the current SLX and with future diagnostic outputs.
    vars_SL = {'time_0_to_100', 'time_0_to_200', 'time_80_to_120', 'time_60_to_120', ...
               'max_speed', 'max_speed_physical', 'max_speed_limited', ...
               'max_launch_acc', 'v_final_kmh', 'v_max_kmh', ...
               'stop_reason', 'Reached_100', 'Reached_200', 'Reached_80_120', 'Reached_60_120'};
    current_result = extractVars(simOut_SL, vars_SL, current_result, 'SL_');
    current_result = sanitizeStraightLineKpis(current_result);

    %% === APPEND OUTPUTS ===

    % Append
    if isempty(results_struct)
        results_struct = current_result;
    else
        results_struct = appendStruct(results_struct, current_result);
    end
    
    %% Save to .mat for Debug only if not HPC Mode
    if ~DOE_HPC_MODE
        % Save log as .mat file to folder
        filename = "log_" + ...
            actual_datetime + "_" + ...
            "runID" + string(runID) + ... 
            ".mat";
        save(fullfile(save_dir, filename), "simOut_SL", "-mat");
    end

end % End Loop

%% Save to .mat for Debug only if not HPC Mode
if ~DOE_HPC_MODE
    
    % Copy DoE csv to folder
    copyfile(csv_filename, save_dir);

    % Copy slx file to folder
    copyfile(DOE_SL_MODEL_FILE, save_dir);
    % [~, filename, ext] = fileparts(DOE_SL_MODEL_FILE);
    % new_filename = filename + "_copy" + ext;
    % old_filename = [filename, ext];
    % movefile(fullfile(save_dir, old_filename), fullfile(save_dir, new_filename)); 

    % Copy DoE .m to folder
    copyfile("DoE_main.m", save_dir);
    
    % Save results table to folder
    filename = "results_" + actual_datetime + "_" + ...
        "runID" + string(runID) + ... 
        ".xlsx";
    results_table = struct2table(results_struct);
    if DOE_ADD_ACTUAL_COMPARISON
        results_table = addActualComparison(results_table, actual_values_filename);
    end
    results_file = fullfile(save_dir, filename);
    writetable(results_table, results_file);

    % Create comparison plot before zipping/deleting the debug folder.
    % The plot is only created when Actual_0_to_100_s and SL_time_0_to_100 are available.
    plot_filename = "Actual_vs_Simulated_0_to_100.png";
    plot_file = fullfile(save_dir, plot_filename);
    createActualVsSim0100Plot(results_table, plot_file);

    % .zip erstellen
    save_dir = string(save_dir);
    [parentFolder, zipName] = fileparts(save_dir);
    zipFile = fullfile(parentFolder, zipName + ".zip");
    % Inhalte des Ordners sammeln, aber "." und ".." ausschließen
    d = dir(save_dir);
    names = {d.name};
    names = names(~ismember(names, {'.', '..'}));
    % ZIP erstellen: Inhalte relativ zu save_dir packen
    zip(zipFile, names, save_dir);

    % Delete folder
    if isfile(zipFile)
        rmdir(char(save_dir), 's');
        fprintf('ZIP erstellt und Ordner gelöscht:\n%s\n', zipFile);
    else
        warning('ZIP wurde nicht erstellt. Ordner wurde nicht gelöscht.');
    end

end

%% === SAVE RESULTS if HPC MODE ===
if DOE_HPC_MODE

    if isempty(results_struct)
        results_table = table();
    else
        results_table = struct2table(results_struct);
        if DOE_ADD_ACTUAL_COMPARISON
            results_table = addActualComparison(results_table, actual_values_filename);
        end
    end
    
    outFolder = fileparts(char(string(output_filename)));
    if ~isempty(outFolder) && ~exist(outFolder, 'dir')
        mkdir(outFolder);
    end
    
    fprintf('Saving %d runs to %s...\n', height(results_table), char(string(output_filename)));
    writetable(results_table, output_filename);
    fprintf('Task %d Done.\n', TaskID);
    
    % In HPC mode the model intentionally stays loaded for the next chunk.
    if ~DOE_KEEP_MODEL_LOADED
        if DOE_USE_FAST_RESTART && exist('DOE_SL_MODEL_SIM_NAME', 'var') && bdIsLoaded(DOE_SL_MODEL_SIM_NAME)
            try
                set_param(DOE_SL_MODEL_SIM_NAME, 'FastRestart', 'off');
            catch
            end
        end
        if DOE_CLOSE_MODEL_AFTER_RUN && exist('DOE_SL_MODEL_SIM_NAME', 'var') && bdIsLoaded(DOE_SL_MODEL_SIM_NAME)
            try
                close_system(DOE_SL_MODEL_SIM_NAME, 0);
            catch
            end
        end
    end

end


%% === HELPER FUNCTIONS (Must be at bottom of script) ===


function model_root = discoverModelRoot(script_dir)
    model_root = '';
    if isempty(script_dir), script_dir = pwd; end
    current = char(string(script_dir));
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

function model_file = locateSimulinkModel(model_name, script_dir, model_root)
    model_file = '';
    model_name = char(erase(string(model_name), '.slx'));
    model_name = char(erase(string(model_name), '.mdl'));

    candidates = {};
    direct = char(string(model_name));
    if isfile(direct), candidates{end+1} = direct; end %#ok<AGROW>
    if isfile([direct '.slx']), candidates{end+1} = [direct '.slx']; end %#ok<AGROW>
    if isfile([direct '.mdl']), candidates{end+1} = [direct '.mdl']; end %#ok<AGROW>

    w = which([model_name '.slx']); if ~isempty(w), candidates{end+1} = w; end %#ok<AGROW>
    w = which([model_name '.mdl']); if ~isempty(w), candidates{end+1} = w; end %#ok<AGROW>
    w = which(model_name); if ~isempty(w), candidates{end+1} = w; end %#ok<AGROW>

    roots = unique(string({pwd, script_dir, char(string(model_root))}), 'stable');
    for r = 1:numel(roots)
        root = char(roots(r));
        if isempty(root) || ~isfolder(root), continue; end
        hits = [dir(fullfile(root, '**', [model_name '.slx'])); dir(fullfile(root, '**', [model_name '.mdl']))];
        for h = 1:numel(hits)
            candidates{end+1} = fullfile(hits(h).folder, hits(h).name); %#ok<AGROW>
        end
    end

    for c = 1:numel(candidates)
        if isfile(candidates{c})
            model_file = candidates{c};
            return;
        end
    end
end

function v = parseNumericVector(x)
    if ischar(x) || isstring(x)
        v = str2num(char(x)); %#ok<ST2NM>
    elseif isnumeric(x)
        v = x;
    else
        v = [];
    end
    if isempty(v)
        v = [];
        return;
    end
    v = double(v(:)).';
    v = v(isfinite(v));
end

function current_result = extractVars(simOut, varNames, current_result, prefix)
    % (Same as before)
    if isempty(simOut)
        for k = 1:length(varNames)
            current_result.([prefix, varNames{k}]) = NaN;
        end
        return;
    end
    available = simOut.who;
    for k = 1:length(varNames)
        rawName = varNames{k};
        saveName = [prefix, rawName];
        if ismember(rawName, available)
            dataObj = simOut.get(rawName);
            if isa(dataObj, 'timeseries')
                val = dataObj.Data(end);
            elseif isa(dataObj, 'struct') && isfield(dataObj, 'signals')
                val = dataObj.signals.values(end);
            elseif isnumeric(dataObj)
                val = dataObj(end);
            else
                val = NaN;
            end
            current_result.(saveName) = val;
        else
            current_result.(saveName) = NaN;
        end
    end
end

function all_configs = loadConfig(filename)
    T = readtable(filename);
    all_configs = table2struct(T);
end


function results_table = addActualComparison(results_table, actual_values_filename)
    % Adds ActualValues and error columns when DoE_ActualValues.xlsx is available.
    if isempty(results_table) || ~ismember('RUN_ID', results_table.Properties.VariableNames)
        return;
    end

    actualFile = char(string(actual_values_filename));
    if isempty(actualFile) || ~isfile(actualFile)
        fprintf('Actual values file not found or not set. Using Actual_* columns from results only.\n');
        return;
    end

    try
        actualT = readtable(actualFile, 'VariableNamingRule', 'preserve');
    catch
        actualT = readtable(actualFile);
    end

    actualVars = actualT.Properties.VariableNames;
    runCol = find(strcmpi(actualVars, 'RUN_ID'), 1);
    if isempty(runCol)
        fprintf('Actual values file has no RUN_ID column. Skipping comparison columns.\n');
        return;
    end

    resultRunIDs = str2double(string(results_table.RUN_ID));
    actualRunIDs = str2double(string(actualT{:, runCol}));
    [tf, loc] = ismember(resultRunIDs, actualRunIDs);

    actual0100Col = find(strcmpi(actualVars, 'Actual_0_to_100_s'), 1);
    if isempty(actual0100Col)
        actual0100Col = find(contains(lower(actualVars), 'actual') & contains(actualVars, '100'), 1);
    end
    if ~isempty(actual0100Col)
        actualVals = str2double(string(actualT{:, actual0100Col}));
        if ~ismember('Actual_0_to_100_s', results_table.Properties.VariableNames)
            results_table.Actual_0_to_100_s = NaN(height(results_table), 1);
        end
        results_table.Actual_0_to_100_s(tf) = actualVals(loc(tf));
    end

    actualVmaxCol = find(strcmpi(actualVars, 'Actual_max_speed_kmh'), 1);
    if isempty(actualVmaxCol)
        actualVmaxCol = find(contains(lower(actualVars), 'actual') & contains(lower(actualVars), 'max') & contains(lower(actualVars), 'speed'), 1);
    end
    if ~isempty(actualVmaxCol)
        actualVmax = str2double(string(actualT{:, actualVmaxCol}));
        if ~ismember('Actual_max_speed_kmh', results_table.Properties.VariableNames)
            results_table.Actual_max_speed_kmh = NaN(height(results_table), 1);
        end
        results_table.Actual_max_speed_kmh(tf) = actualVmax(loc(tf));
    end

    simCol = '';
    if ismember('SL_time_0_to_100', results_table.Properties.VariableNames)
        simCol = 'SL_time_0_to_100';
    elseif ismember('time_0_to_100', results_table.Properties.VariableNames)
        simCol = 'time_0_to_100';
    end

    if ~isempty(simCol) && ismember('Actual_0_to_100_s', results_table.Properties.VariableNames)
        simVals = str2double(string(results_table.(simCol)));
        actualVals = str2double(string(results_table.Actual_0_to_100_s));
        results_table.Error_0_to_100_s = simVals - actualVals;
        results_table.Error_0_to_100_pct = 100 .* results_table.Error_0_to_100_s ./ actualVals;
    end

    % Prefer the first simulated Vmax column that actually contains finite values.
    % Some model variants create SL_v_max_kmh as an empty/NaN placeholder while
    % the usable result is stored in SL_max_speed or SL_max_speed_physical.
    maxCol = pickFirstFiniteColumnMain(results_table, ...
        {'SL_max_speed_limited', 'SL_max_speed_physical', 'SL_max_speed', 'SL_v_max_kmh', 'max_speed'});
    if ~isempty(maxCol) && ismember('Actual_max_speed_kmh', results_table.Properties.VariableNames)
        simV = str2double(string(results_table.(maxCol)));
        actualV = str2double(string(results_table.Actual_max_speed_kmh));
        valid = isfinite(simV) & isfinite(actualV) & actualV > 0;
        results_table.Error_max_speed_kmh = NaN(height(results_table), 1);
        results_table.Error_max_speed_pct = NaN(height(results_table), 1);
        results_table.Error_max_speed_kmh(valid) = simV(valid) - actualV(valid);
        results_table.Error_max_speed_pct(valid) = 100 .* results_table.Error_max_speed_kmh(valid) ./ actualV(valid);
        results_table.SL_max_speed_compare_source = repmat(string(maxCol), height(results_table), 1);
    end
end

function mainStruct = appendStruct(mainStruct, newStruct)
    mainFields = fieldnames(mainStruct);
    newFields  = fieldnames(newStruct);
    missingInMain = setdiff(newFields, mainFields);
    for k = 1:length(missingInMain)
        [mainStruct.(missingInMain{k})] = deal(NaN); 
    end
    missingInNew = setdiff(mainFields, newFields);
    for k = 1:length(missingInNew)
        newStruct.(missingInNew{k}) = NaN;
    end
    mainStruct = [mainStruct; newStruct];
end



function [cfg, warnings, errors] = validateAndRepairInput(cfg, runID)
    warnings = strings(1, 0);
    errors = strings(1, 0);

    % Required numeric defaults. These keep older CSVs compatible with the
    % newer AMS converter output.
    numericDefaults = { ...
        'd_wheel', 0.6345; 'A_front', 2.25; 'HM_VA', 1; 'AWD', 0; 'iAG', 4.1; ...
        'm_curb', 1500; 'Wheelbase', 2.65; 'h_s', 0.45; 'weight_dist', 1.20; ...
        'MainAxle_TorqueSplit_int', 0.5; 'Hybrid_ICE_priority', 1; ...
        'VM', 1; 'EV', 0; 'Hy', 0; 'E0', 0; 'E1', 0; 'E2', 0; 'E3', 0; 'E4', 0; ...
        'i_GET_EV', 9.0; 'i_ges_P4', 9.0; 'use_cus_val', 1; 'No_Gears', 0; 'shiftDelay', NaN; ...
        'Displacement_cc', 0; 'Boost_Pressure_bar', 0; ...
        'P0', 0; 'P2', 0; 'P3', 0; 'P4', 0; 'P4_DM', 0; ...
        'n_ICE_idle', 0; 'n_ICE_max', 0; 'tq_ICE_idle', 0; 'tq_ICE_max', 0; 'Pwr_ICE_max_kW', 0; ...
        'tq_P0_max', 0; 'Pwr_P0_max_kW', 0; 'n_P0_max', 0; 'Pwr_P0_nmax_red_perc', 0; ...
        'tq_P2_max', 0; 'Pwr_P2_max_kW', 0; 'n_P2_max', 0; 'Pwr_P2_nmax_red_perc', 0; ...
        'tq_P3_max', 0; 'Pwr_P3_max_kW', 0; 'n_P3_max', 0; 'Pwr_P3_nmax_red_perc', 0; ...
        'tq_P4_max', 0; 'Pwr_P4_max_kW', 0; 'n_P4_max', 0; 'Pwr_P4_nmax_red_perc', 0; ...
        'tq_EV_max', 0; 'Pwr_EV_max_kW', 0; 'n_EV_max', 0; 'Pwr_EV_nmax_red_perc', 0.04; ...
        'Cell_Cap_Ah', 4.8; 'Cell_V_nom', 3.7; 'Cell_R_inner', 0.023; ...
        'Cell_V_min', 2.5; 'Cell_V_max', 4.2; 'Cell_I_max_chg', 4.8; 'Cell_I_max_dis', 15; ...
        'n_s', 1; 'n_p', 1; 'facSocInit', 0.95; 'SOC_Recup_Limit', 0.95; 'SOC_Bat_Discharge_Limit', 0.10; ...
        'Actual_0_to_100_s', NaN; 'Actual_max_speed_kmh', NaN; 'InputQualityScore', NaN};
    for k = 1:size(numericDefaults, 1)
        [cfg, wasDefaulted] = ensureNumericField(cfg, numericDefaults{k,1}, numericDefaults{k,2});
        if wasDefaulted
            warnings(end+1) = string(numericDefaults{k,1}) + " defaulted"; %#ok<AGROW>
        end
    end

    textDefaults = {'Powertrain', ''; 'mode', 'performance'; 'Gear_Ratio', '[]'; ...
        'Induction_Type', 'NA'; 'SOC_Vector', '[0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]'; ...
        'Cell_OCV_Vector', '[2.8, 3.3, 3.45, 3.52, 3.60, 3.68, 3.75, 3.85, 3.95, 4.1, 4.2]'; ...
        'Raw_Gearbox', ''; 'Raw_Fuel', ''; 'Transmission_Type', ''; 'Vehicle_Name', ''; 'InputWarnings', ''};
    for k = 1:size(textDefaults, 1)
        if ~isfield(cfg, textDefaults{k,1}) || isempty(cfg.(textDefaults{k,1})) || ismissing(string(cfg.(textDefaults{k,1})))
            cfg.(textDefaults{k,1}) = string(textDefaults{k,2});
        end
    end

    pt = upper(strtrim(string(cfg.Powertrain)));
    if strlength(pt) == 0 || pt == "0" || pt == "UNKNOWN"
        if cfg.EV == 1
            pt = "EV";
        elseif cfg.Hy == 1
            pt = "HYBRID";
        else
            pt = "ICE";
        end
        cfg.Powertrain = pt;
        warnings(end+1) = "Powertrain inferred from flags"; %#ok<AGROW>
    end

    isICE = pt == "ICE";
    isEV = pt == "EV" || pt == "BEV";
    isHybrid = pt == "HYBRID" || pt == "PHEV" || pt == "HEV";

    rawGearboxTxt = lower(string(getTextField(cfg, 'Raw_Gearbox')));
    gearboxAllTxt = lower(string(getTextField(cfg, 'Raw_Gearbox')) + " " + string(getTextField(cfg, 'Transmission_Type')));
    vehicleNameTxt = lower(string(getTextField(cfg, 'Vehicle_Name')));
    has2WDNameHint = contains2WDHintMain(vehicleNameTxt);
    hasAWDNameHint = containsAnyMain(vehicleNameTxt, ["awd", "4wd", "4x4", "allrad"]);

    if isCvtGearboxTextMain(gearboxAllTxt)
        errors(end+1) = "CVT/e-CVT excluded from this simulation"; %#ok<AGROW>
    end
    if has2WDNameHint && ~hasAWDNameHint && cfg.AWD == 1
        cfg.AWD = 0;
        cfg.HM_VA = 1;
        warnings(end+1) = "AWD repaired from vehicle-name 2WD/4x2 hint"; %#ok<AGROW>
    end
    if isEV && containsAnyMain(rawGearboxTxt, ["3-gang", "4-gang", "5-gang", "6-gang", "7-gang", "8-gang", "9-gang", "10-gang"])
        errors(end+1) = "Suspicious EV input: multi-speed ICE gearbox text in Raw_Gearbox"; %#ok<AGROW>
    end

    if isICE
        cfg.Powertrain = "ICE";
        cfg.VM = 1; cfg.EV = 0; cfg.Hy = 0;
        cfg.P0 = 0; cfg.P2 = 0; cfg.P3 = 0; cfg.P4 = 0; cfg.P4_DM = 0;
        cfg.E0 = 0; cfg.E1 = 0; cfg.E2 = 0; cfg.E3 = 0; cfg.E4 = 0;
        cfg.tq_P0_max = 0; cfg.Pwr_P0_max_kW = 0; cfg.n_P0_max = 0;
        cfg.tq_P2_max = 0; cfg.Pwr_P2_max_kW = 0; cfg.n_P2_max = 0;
        cfg.tq_P3_max = 0; cfg.Pwr_P3_max_kW = 0; cfg.n_P3_max = 0;
        cfg.tq_P4_max = 0; cfg.Pwr_P4_max_kW = 0; cfg.n_P4_max = 0;
        cfg.tq_EV_max = 0; cfg.Pwr_EV_max_kW = 0; cfg.n_EV_max = 0;
        cfg.n_s = max(1, cfg.n_s); cfg.n_p = max(1, cfg.n_p);
    elseif isEV
        cfg.Powertrain = "EV";
        cfg.VM = 0; cfg.EV = 1; cfg.Hy = 0;
        oldPwr = max([cfg.Pwr_EV_max_kW, cfg.Pwr_P2_max_kW, cfg.Pwr_P3_max_kW, cfg.Pwr_P4_max_kW, cfg.Pwr_ICE_max_kW]);
        oldTq  = max([cfg.tq_EV_max, cfg.tq_P2_max, cfg.tq_P3_max, cfg.tq_P4_max, cfg.tq_ICE_max]);
        oldN   = max([cfg.n_EV_max, cfg.n_P2_max, cfg.n_P3_max, cfg.n_P4_max, 16000]);
        cfg.Pwr_ICE_max_kW = 0; cfg.tq_ICE_max = 0; cfg.tq_ICE_idle = 0; cfg.n_ICE_idle = 0; cfg.n_ICE_max = 0;
        if has2WDNameHint && ~hasAWDNameHint
            cfg.AWD = 0;
            cfg.E0 = 1; cfg.E1 = 0; cfg.E2 = 0; cfg.E3 = 0; cfg.E4 = 0;
            cfg.Pwr_P4_max_kW = 0; cfg.tq_P4_max = 0; cfg.n_P4_max = 0;
            rawPowerFromText_kW = parseFirstNumberMain(getTextField(cfg, 'Raw_Power'));
            if isfinite(rawPowerFromText_kW) && rawPowerFromText_kW > 0 && cfg.Pwr_EV_max_kW > 1.35 * rawPowerFromText_kW
                cfg.Pwr_EV_max_kW = rawPowerFromText_kW;
                warnings(end+1) = "EV 2WD power capped from Raw_Power"; %#ok<AGROW>
            end
            warnings(end+1) = "EV topology forced to single primary motor from 2WD/4x2 hint"; %#ok<AGROW>
        end
        if ~(cfg.E0 || cfg.E1 || cfg.E2 || cfg.E3 || cfg.E4)
            if cfg.AWD == 1
                cfg.E2 = 1;
            else
                cfg.E0 = 1;
            end
            warnings(end+1) = "EV E-position inferred"; %#ok<AGROW>
        end
        nMot = max(1, 1 + double(cfg.E1 == 1 || cfg.E2 == 1) + double(cfg.E3 == 1) * 2 + double(cfg.E4 == 1) * 3);
        if cfg.Pwr_EV_max_kW <= 0 && oldPwr > 0, cfg.Pwr_EV_max_kW = oldPwr / nMot; end
        if cfg.tq_EV_max <= 0 && oldTq > 0, cfg.tq_EV_max = oldTq / nMot; end
        if cfg.n_EV_max <= 0, cfg.n_EV_max = oldN; end

        % EV torque plausibility: low torque with high power makes EVs far too slow.
        tqMinFromPower = estimateTorqueFromPowerMain(cfg.Pwr_EV_max_kW, 6000);
        if isfinite(tqMinFromPower) && tqMinFromPower > 0 && cfg.tq_EV_max < 0.75 * tqMinFromPower
            cfg.tq_EV_max = tqMinFromPower;
            warnings(end+1) = "EV torque raised from power plausibility"; %#ok<AGROW>
        end

        if cfg.Pwr_P4_max_kW <= 0 && (cfg.E2 || cfg.E3 || cfg.E4), cfg.Pwr_P4_max_kW = cfg.Pwr_EV_max_kW; end
        if cfg.tq_P4_max <= 0 && (cfg.E2 || cfg.E3 || cfg.E4), cfg.tq_P4_max = cfg.tq_EV_max; end
        if cfg.n_P4_max <= 0 && (cfg.E2 || cfg.E3 || cfg.E4), cfg.n_P4_max = cfg.n_EV_max; end

        % For pure EVs, i_GET_EV is the total reduction. Do not also multiply
        % by a final-drive iAG from an ICE/AMS gearbox field.
        if abs(cfg.iAG - 1.0) > 1e-6
            cfg.iAG = 1.0;
            warnings(end+1) = "EV iAG set to 1 to avoid i_GET_EV*iAG double reduction"; %#ok<AGROW>
        end
        estEVRatio = estimateEVTotalRatioMain(cfg.Actual_max_speed_kmh, cfg.d_wheel, cfg.n_EV_max);
        if isfinite(estEVRatio) && estEVRatio > 0
            cfg.i_GET_EV = estEVRatio;
            if cfg.E2 || cfg.E3 || cfg.E4
                cfg.i_ges_P4 = estEVRatio;
            end
            warnings(end+1) = "EV i_GET_EV estimated from Actual_max_speed"; %#ok<AGROW>
        else
            cfg.i_GET_EV = min(max(cfg.i_GET_EV, 6.5), 13.5);
            if cfg.E2 || cfg.E3 || cfg.E4
                cfg.i_ges_P4 = cfg.i_GET_EV;
            end
        end

        cfg.P0 = 0; cfg.P2 = 0; cfg.P3 = 0; cfg.P4 = 0; cfg.P4_DM = 0;
    elseif isHybrid
        cfg.Powertrain = "Hybrid";
        cfg.EV = 0; cfg.Hy = 1;
        if cfg.Pwr_ICE_max_kW <= 0
            errors(end+1) = "Hybrid has no ICE power"; %#ok<AGROW>
        end
        if cfg.P0 + cfg.P2 + cfg.P3 + cfg.P4 + cfg.P4_DM == 0 && max([cfg.Pwr_P0_max_kW, cfg.Pwr_P2_max_kW, cfg.Pwr_P3_max_kW, cfg.Pwr_P4_max_kW]) > 0
            cfg.P2 = 1;
            warnings(end+1) = "Hybrid P-position inferred as P2"; %#ok<AGROW>
        end
    else
        errors(end+1) = "Unknown Powertrain value: " + string(cfg.Powertrain); %#ok<AGROW>
    end

    % P4 single motor and dual-motor architecture are mutually exclusive.
    if cfg.P4 == 1 && cfg.P4_DM == 1
        cfg.P4 = 0;
        warnings(end+1) = "P4/P4_DM conflict repaired; kept P4_DM"; %#ok<AGROW>
    end

    % 48V/MHEV/P0-only entries should not be treated like full traction hybrids.
    % In this straight-line model P0 is not a real axle traction machine. Keeping
    % weak P0-only mild hybrids in the Hybrid topology makes some ICE-like cars
    % too optimistic and consumes battery logic that is not meaningful here.
    eTractionPower_kW = max([cfg.Pwr_P2_max_kW, 0]) + max([cfg.Pwr_P3_max_kW, 0]) + max([cfg.Pwr_P4_max_kW, 0]);
    eAllPowerNoEV_kW = max([cfg.Pwr_P0_max_kW, 0]) + eTractionPower_kW;
    rawAllTxt = lower(string(getTextField(cfg, 'Raw_Fuel')) + " " + ...
                      string(getTextField(cfg, 'Raw_Gearbox')) + " " + ...
                      string(getTextField(cfg, 'Vehicle_Name')) + " " + ...
                      string(getTextField(cfg, 'Raw_Power')));
    hasMildHint = containsAnyMain(rawAllTxt, ["mhev", "mild", "48v", "48 v", "mild-hybrid", "mildhybrid"]);
    lowVoltagePack = isfinite(cfg.n_s) && cfg.n_s > 0 && cfg.n_s <= 25;
    if cfg.Hy == 1 && cfg.P0 == 1 && cfg.P2 == 0 && cfg.P3 == 0 && cfg.P4 == 0 && cfg.P4_DM == 0 && ...
            eAllPowerNoEV_kW > 0 && eAllPowerNoEV_kW <= 25 && (hasMildHint || lowVoltagePack)
        cfg.Powertrain = "ICE";
        cfg.VM = 1; cfg.EV = 0; cfg.Hy = 0;
        cfg.P0 = 0; cfg.P2 = 0; cfg.P3 = 0; cfg.P4 = 0; cfg.P4_DM = 0;
        cfg.tq_P0_max = 0; cfg.Pwr_P0_max_kW = 0; cfg.n_P0_max = 0;
        cfg.tq_P2_max = 0; cfg.Pwr_P2_max_kW = 0; cfg.n_P2_max = 0;
        cfg.tq_P3_max = 0; cfg.Pwr_P3_max_kW = 0; cfg.n_P3_max = 0;
        cfg.tq_P4_max = 0; cfg.Pwr_P4_max_kW = 0; cfg.n_P4_max = 0;
        cfg.tq_EV_max = 0; cfg.Pwr_EV_max_kW = 0; cfg.n_EV_max = 0;
        warnings(end+1) = "P0-only mild hybrid treated as ICE"; %#ok<AGROW>
    end

    % Make the battery discharge current consistent with the requested electric
    % propulsion power. AMS/DoE fallbacks often produced e.g. 96S/46P but only
    % 15 A per cell, which limits a high-power EV/hybrid far below its motor map.
    [cfg, battWarn] = repairBatteryDischargePowerMain(cfg);
    if strlength(battWarn) > 0
        warnings(end+1) = battWarn; %#ok<AGROW>
    end

    gr = parseNumericVector(cfg.Gear_Ratio);
    if cfg.EV == 1 && cfg.Hy == 0 && cfg.VM == 0
        cfg.Gear_Ratio = "[1]";
        cfg.No_Gears = 1;
        cfg.i_GET_EV = max(cfg.i_GET_EV, 1);
    else
        if isempty(gr) || numel(gr) < 2 || cfg.No_Gears < 2
            nG = max(2, estimateGearCountMain(cfg));
            gr = defaultGearRatiosMain(nG, getTextField(cfg, 'Raw_Gearbox'));
            cfg.Gear_Ratio = formatVectorMain(gr);
            cfg.No_Gears = numel(gr);
            warnings(end+1) = "ICE/Hybrid gearbox ratios repaired"; %#ok<AGROW>
        else
            cfg.No_Gears = numel(gr);
        end
    end

    cfg.facSocInit = normalizeSocFraction(cfg.facSocInit, 0.95);
    cfg.SOC_Recup_Limit = normalizeSocFraction(cfg.SOC_Recup_Limit, 0.95);
    cfg.SOC_Bat_Discharge_Limit = normalizeSocFraction(cfg.SOC_Bat_Discharge_Limit, 0.10);
    if cfg.SOC_Bat_Discharge_Limit >= cfg.SOC_Recup_Limit
        cfg.SOC_Bat_Discharge_Limit = 0.10;
        cfg.SOC_Recup_Limit = 0.95;
        warnings(end+1) = "SOC limits repaired"; %#ok<AGROW>
    end

    if cfg.m_curb <= 200 || cfg.A_front <= 1.0 || cfg.Wheelbase <= 1.5
        errors(end+1) = "Invalid basic vehicle geometry/mass"; %#ok<AGROW>
    end
    totalPower = max([cfg.Pwr_ICE_max_kW, 0]) + max([cfg.Pwr_P0_max_kW, 0]) + max([cfg.Pwr_P2_max_kW, 0]) + ...
                 max([cfg.Pwr_P3_max_kW, 0]) + max([cfg.Pwr_P4_max_kW, 0]) + max([cfg.Pwr_EV_max_kW, 0]);
    if totalPower <= 0
        errors(end+1) = "No usable propulsion power"; %#ok<AGROW>
    end

    % Merge converter warnings with main repair warnings.
    oldWarn = strtrim(string(getTextField(cfg, 'InputWarnings')));
    if strlength(oldWarn) > 0 && oldWarn ~= "0"
        warnings = [split(oldWarn, " | ").', warnings]; %#ok<AGROW>
    end
    warnings = unique(warnings(strlength(warnings) > 0), 'stable');
    cfg.InputWarnings = strjoin(warnings, " | ");
    if ~isfinite(cfg.InputQualityScore)
        cfg.InputQualityScore = max(0, 100 - 5 * numel(warnings) - 20 * numel(errors));
    end

    if ~isempty(warnings)
        fprintf('RunID %d input warnings: %s\n', runID, char(strjoin(warnings, ' | ')));
    end
end

function current_result = initRunResult(cfg, runID, inputWarnings)
    current_result = struct();
    current_result.RUN_ID = runID;
    current_result.Vehicle_Name = string(getTextField(cfg, 'Vehicle_Name'));
    current_result.Powertrain = string(getTextField(cfg, 'Powertrain'));
    current_result.Actual_0_to_100_s = getNumericField(cfg, 'Actual_0_to_100_s', NaN);
    current_result.Actual_max_speed_kmh = getNumericField(cfg, 'Actual_max_speed_kmh', NaN);
    current_result.InputQualityScore = getNumericField(cfg, 'InputQualityScore', NaN);
    current_result.InputWarnings = string(strjoin(inputWarnings, ' | '));
    current_result.InputErrors = "";
    current_result.SimStatus = "INIT";
    current_result.ErrorMessage = "";
end

function current_result = makeSkippedResult(cfg, runID, inputWarnings, inputErrors)
    current_result = initRunResult(cfg, runID, inputWarnings);
    current_result.InputErrors = string(strjoin(inputErrors, ' | '));
    current_result.SimStatus = "SKIPPED_INPUT_ERROR";
    fields = {'SL_time_0_to_100','SL_time_0_to_200','SL_time_80_to_120','SL_time_60_to_120', ...
              'SL_max_speed','SL_max_speed_physical','SL_max_speed_limited', ...
              'SL_max_launch_acc','SL_v_final_kmh','SL_v_max_kmh'};
    for k = 1:numel(fields)
        current_result.(fields{k}) = NaN;
    end
    current_result.SL_Reached_100 = false;
    current_result.SL_Reached_200 = false;
    current_result.SL_Reached_80_120 = false;
    current_result.SL_Reached_60_120 = false;
end

function current_result = sanitizeStraightLineKpis(current_result)
    pairs = {'SL_time_0_to_100','SL_Reached_100'; 'SL_time_0_to_200','SL_Reached_200'; ...
             'SL_time_80_to_120','SL_Reached_80_120'; 'SL_time_60_to_120','SL_Reached_60_120'};
    for k = 1:size(pairs, 1)
        tName = pairs{k,1}; rName = pairs{k,2};
        if isfield(current_result, tName)
            val = double(current_result.(tName));
            if ~isfinite(val) || val <= 0
                current_result.(tName) = NaN;
                current_result.(rName) = false;
            else
                current_result.(rName) = true;
            end
        else
            current_result.(tName) = NaN;
            current_result.(rName) = false;
        end
    end
    if isfield(current_result, 'SL_max_speed_physical') && isfinite(double(current_result.SL_max_speed_physical))
        % Keep explicit physical Vmax from Simulink.
    elseif isfield(current_result, 'SL_v_max_kmh') && isfinite(double(current_result.SL_v_max_kmh))
        current_result.SL_max_speed_physical = current_result.SL_v_max_kmh;
    elseif isfield(current_result, 'SL_max_speed') && isfinite(double(current_result.SL_max_speed))
        current_result.SL_max_speed_physical = current_result.SL_max_speed;
    else
        current_result.SL_max_speed_physical = NaN;
    end

    if isfield(current_result, 'SL_max_speed_limited') && isfinite(double(current_result.SL_max_speed_limited))
        % Keep explicit limited Vmax from Simulink.
    else
        % Do not synthesize a limited Vmax here; otherwise Vmax validation would
        % be hidden even when the SLX limiter has not actually been implemented.
        current_result.SL_max_speed_limited = NaN;
    end
end

function [delay, source, gbType, p2w] = resolveShiftDelay(cfg)
    gbText = lower(string(getTextField(cfg, 'Raw_Gearbox')) + " " + string(getTextField(cfg, 'Transmission_Type')));
    pt = upper(string(getTextField(cfg, 'Powertrain')));
    totalPower = getNumericField(cfg, 'Pwr_ICE_max_kW', 0) + getNumericField(cfg, 'Pwr_P0_max_kW', 0) + ...
                 getNumericField(cfg, 'Pwr_P2_max_kW', 0) + getNumericField(cfg, 'Pwr_P3_max_kW', 0) + ...
                 getNumericField(cfg, 'Pwr_P4_max_kW', 0) + getNumericField(cfg, 'Pwr_EV_max_kW', 0);
    m = getNumericField(cfg, 'm_curb', NaN);
    if isfinite(m) && m > 0
        p2w = totalPower / m * 1000;
    else
        p2w = NaN;
    end

    if isCvtGearboxTextMain(gbText)
        delay = NaN; source = "cvt_excluded"; gbType = "cvt_excluded"; return;
    end
    if pt == "EV"
        delay = 0.05; source = "ev_single_speed"; gbType = "single_speed_ev"; return;
    end
    if containsAnyMain(gbText, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct"])
        gbType = "dct";
        if isfinite(p2w) && p2w > 250, delay = 0.10; else, delay = 0.18; end
        source = "gearbox_text";
    elseif containsAnyMain(gbText, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        gbType = "automatic"; delay = 0.35; source = "gearbox_text";
    elseif containsAnyMain(gbText, ["schalt", "manuell"])
        gbType = "manual"; delay = 0.80; source = "gearbox_text";
    else
        gbType = "unknown";
        csvDelay = getNumericField(cfg, 'shiftDelay', NaN);
        if isfinite(csvDelay) && csvDelay > 0.03 && csvDelay < 1.5
            delay = csvDelay; source = "csv_shiftDelay";
        elseif ~isfinite(p2w) || p2w < 80
            delay = 1.00; source = "power_to_weight_fallback";
        elseif p2w < 140
            delay = 0.70; source = "power_to_weight_fallback";
        elseif p2w < 250
            delay = 0.45; source = "power_to_weight_fallback";
        else
            delay = 0.10; source = "power_to_weight_fallback";
        end
    end
end

function col = pickFirstFiniteColumnMain(T, candidates)
    col = '';
    if isempty(T) || ~istable(T)
        return;
    end
    for k = 1:numel(candidates)
        c = candidates{k};
        if ismember(c, T.Properties.VariableNames)
            vals = str2double(string(T.(c)));
            if any(isfinite(vals))
                col = c;
                return;
            end
        end
    end
end

function P_kW = totalElectricPropulsionPowerMain(cfg)
    % Estimated total electric propulsion power required from the HV/LV battery.
    % For EV E2/E3/E4 topologies Pwr_EV_max_kW is the primary motor and
    % Pwr_P4_max_kW represents each secondary motor branch.
    P_kW = 0;
    if ~isstruct(cfg)
        return;
    end

    if getNumericField(cfg, 'EV', 0) == 1 && getNumericField(cfg, 'Hy', 0) == 0
        e0 = getNumericField(cfg, 'E0', 0);
        e1 = getNumericField(cfg, 'E1', 0);
        e2 = getNumericField(cfg, 'E2', 0);
        e3 = getNumericField(cfg, 'E3', 0);
        e4 = getNumericField(cfg, 'E4', 0);

        primaryMotors = double(e0 == 1 || e1 == 1 || e2 == 1 || e3 == 1 || e4 == 1);
        secondaryMotors = 0;
        if e2 == 1
            secondaryMotors = 1;
        elseif e3 == 1
            secondaryMotors = 2;
        elseif e4 == 1
            secondaryMotors = 3;
        end

        pEV = max(getNumericField(cfg, 'Pwr_EV_max_kW', 0), 0);
        pP4 = max(getNumericField(cfg, 'Pwr_P4_max_kW', 0), 0);
        if pP4 <= 0
            pP4 = pEV;
        end
        P_kW = primaryMotors * pEV + secondaryMotors * pP4;
    else
        P_kW = max(getNumericField(cfg, 'Pwr_P0_max_kW', 0), 0) + ...
               max(getNumericField(cfg, 'Pwr_P2_max_kW', 0), 0) + ...
               max(getNumericField(cfg, 'Pwr_P3_max_kW', 0), 0) + ...
               max(getNumericField(cfg, 'Pwr_P4_max_kW', 0), 0);
        if getNumericField(cfg, 'P4_DM', 0) == 1
            % P4_DM contains two secondary machines in the model. If the CSV
            % only contains one P4 power value, approximate the second branch.
            P_kW = P_kW + max(getNumericField(cfg, 'Pwr_P4_max_kW', 0), 0);
        end
    end
end

function Ppack_kW = estimatePackDischargePowerMain(cfg)
    Vnom = getNumericField(cfg, 'Cell_V_nom', NaN);
    Imax = getNumericField(cfg, 'Cell_I_max_dis', NaN);
    ns = getNumericField(cfg, 'n_s', NaN);
    np = getNumericField(cfg, 'n_p', NaN);
    if isfinite(Vnom) && Vnom > 0 && isfinite(Imax) && Imax > 0 && ...
            isfinite(ns) && ns > 0 && isfinite(np) && np > 0
        Ppack_kW = ns * Vnom * np * Imax / 1000;
    else
        Ppack_kW = NaN;
    end
end

function [cfg, warningText] = repairBatteryDischargePowerMain(cfg)
    warningText = "";
    if ~(getNumericField(cfg, 'EV', 0) == 1 || getNumericField(cfg, 'Hy', 0) == 1)
        return;
    end

    P_req_kW = totalElectricPropulsionPowerMain(cfg);
    if ~isfinite(P_req_kW) || P_req_kW <= 0
        return;
    end

    Vcell = getNumericField(cfg, 'Cell_V_nom', 3.7);
    ns = max(1, round(getNumericField(cfg, 'n_s', 1)));
    np = max(1, round(getNumericField(cfg, 'n_p', 1)));
    if ~isfinite(Vcell) || Vcell <= 0
        Vcell = 3.7;
        cfg.Cell_V_nom = Vcell;
    end
    cfg.n_s = ns;
    cfg.n_p = np;

    V_pack_nom = ns * Vcell;
    P_target_kW = 1.10 * P_req_kW;  % 10% reserve for losses / voltage sag
    I_req_A = P_target_kW * 1000 / (V_pack_nom * np);
    I_old_A = getNumericField(cfg, 'Cell_I_max_dis', 15);

    if isfinite(I_req_A) && I_req_A > I_old_A
        % Keep the cell current in a plausible generic high-power range. If a
        % row would need more than this, increase n_p instead of creating an
        % unrealistic cell current.
        I_cap_A = 60;
        if I_req_A <= I_cap_A
            cfg.Cell_I_max_dis = I_req_A;
        else
            cfg.Cell_I_max_dis = I_cap_A;
            np_req = ceil(P_target_kW * 1000 / (V_pack_nom * cfg.Cell_I_max_dis));
            if isfinite(np_req) && np_req > np
                cfg.n_p = np_req;
            end
        end
        warningText = sprintf("battery discharge capability raised for electric power plausibility: P_req=%.1f kW, Icell %.1f->%.1f A, n_p=%d", ...
            P_req_kW, I_old_A, cfg.Cell_I_max_dis, cfg.n_p);
    end
end

function [s, wasDefaulted] = ensureNumericField(s, fieldName, defaultVal)
    wasDefaulted = false;
    if ~isfield(s, fieldName) || isempty(s.(fieldName))
        s.(fieldName) = defaultVal; wasDefaulted = true; return;
    end
    val = s.(fieldName);
    if isstring(val) || ischar(val)
        tmp = str2double(string(val));
        if isfinite(tmp)
            s.(fieldName) = tmp; return;
        end
    elseif isnumeric(val) || islogical(val)
        if isscalar(val) && isfinite(double(val))
            s.(fieldName) = double(val); return;
        end
    end
    s.(fieldName) = defaultVal;
    wasDefaulted = true;
end

function v = getNumericField(s, fieldName, defaultVal)
    v = defaultVal;
    if isstruct(s) && isfield(s, fieldName)
        tmp = s.(fieldName);
        if isstring(tmp) || ischar(tmp)
            tmp = str2double(string(tmp));
        end
        if isnumeric(tmp) || islogical(tmp)
            tmp = double(tmp);
            if isscalar(tmp) && isfinite(tmp)
                v = tmp;
            end
        end
    end
end

function txt = getTextField(s, fieldName)
    txt = "";
    if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
        txt = string(s.(fieldName));
        if ismissing(txt), txt = ""; end
    end
end

function tq = estimateTorqueFromPowerMain(pwr_kW, rpm)
    if ~isfinite(pwr_kW) || pwr_kW <= 0 || ~isfinite(rpm) || rpm <= 0
        tq = NaN;
    else
        tq = 9550 * pwr_kW / rpm;
    end
end

function r = estimateEVTotalRatioMain(vmax_kmh, d_wheel_m, nEVmax_rpm)
    if nargin < 3 || ~isfinite(nEVmax_rpm) || nEVmax_rpm <= 0
        nEVmax_rpm = 16000;
    end
    if ~isfinite(vmax_kmh) || vmax_kmh <= 80 || ~isfinite(d_wheel_m) || d_wheel_m <= 0
        r = NaN;
        return;
    end
    r = nEVmax_rpm * pi * d_wheel_m * 60 / (vmax_kmh * 1000);
    r = min(max(r, 6.5), 13.5);
end

function x = normalizeSocFraction(x, defaultVal)
    if ~isfinite(x), x = defaultVal; end
    if x > 1.5, x = x / 100; end
    x = min(max(x, 0), 1);
end

function nG = estimateGearCountMain(cfg)
    txt = lower(string(getTextField(cfg, 'Raw_Gearbox')));
    if isCvtGearboxTextMain(txt)
        nG = NaN;
        return;
    end
    nG = getNumericField(cfg, 'No_Gears', NaN);
    if isfinite(nG) && nG > 1, nG = round(nG); return; end
    if containsAnyMain(txt, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct"])
        nG = 7;
    elseif containsAnyMain(txt, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        nG = 8;
    elseif containsAnyMain(txt, ["schalt", "manuell"])
        nG = 6;
    else
        nG = 6;
    end
end

function gr = defaultGearRatiosMain(nG, gearboxText)
    nG = max(2, round(nG));
    txt = lower(string(gearboxText));
    if nG == 5
        gr = [3.54 2.05 1.32 1.03 0.85];
    elseif nG == 6
        gr = [4.05 2.40 1.58 1.19 1.00 0.87];
    elseif nG == 7
        gr = [4.38 2.86 1.92 1.37 1.00 0.82 0.64];
    elseif nG >= 8
        if containsAnyMain(txt, ["automatik", "wandler", "zf"])
            gr = [5.00 3.20 2.14 1.72 1.31 1.00 0.82 0.64];
        else
            gr = [4.71 3.14 2.11 1.67 1.29 1.00 0.84 0.67];
        end
        gr = gr(1:min(nG, numel(gr)));
    else
        gr = linspace(3.8, 0.9, nG);
    end
end

function s = formatVectorMain(v)
    parts = strings(1, numel(v));
    for k = 1:numel(v)
        parts(k) = string(sprintf('%.5g', v(k)));
    end
    s = "[" + strjoin(parts, ", ") + "]";
end

function tf = isCvtGearboxTextMain(txt)
    txt = lower(string(txt));
    tf = containsAnyMain(txt, ["cvt", "e-cvt", "ecvt", "stufenlos", "stufenloses", ...
        "continuously variable", "continuous variable", "variator", "multitronic", "xtronic"]);
end

function tf = contains2WDHintMain(txt)
    txt = lower(string(txt));
    tf = containsAnyMain(txt, ["2wd", "2 wd", "4x2", "4 x 2", "two wheel drive"]);
end

function x = parseFirstNumberMain(s)
    s = char(string(s));
    tok = regexp(s, '[-+]?\d+(?:[.,]\d+)?', 'match', 'once');
    if isempty(tok)
        x = NaN;
    else
        x = str2double(strrep(tok, ',', '.'));
    end
end

function tf = containsAnyMain(txt, patterns)
    txt = lower(string(txt));
    patterns = lower(string(patterns));
    tf = false;
    for k = 1:numel(patterns)
        if contains(txt, patterns(k))
            tf = true; return;
        end
    end
end

function patchGearRatioLookupBreakpoints(modelName)
    % Patch model-in-memory only. Do not save the SLX.
    %
    % Reason: Lookup_n-D blocks for Gang -> i_GET originally use
    %   BreakpointsForDimension1 = [1:1:gb.No_Gears]
    %   Table                    = gb.Gear_Ratio
    %
    % For No_Gears = 1 this has only one breakpoint and Simulink rejects the
    % model. Do not change gb.No_Gears, because it is also used by the shift
    % logic. Instead, route these lookup blocks to dedicated LUT variables:
    %   gb_Gears_LUT       = [1 2] for one-speed rows, otherwise 1:nGear
    %   gb_Gear_Ratio_LUT  = duplicated ratio for one-speed rows
    try
        if ~bdIsLoaded(modelName)
            return;
        end

        lookupBlocks = find_system(modelName, ...
            'LookUnderMasks', 'all', ...
            'FollowLinks', 'on', ...
            'BlockType', 'Lookup_n-D');

        nPatched = 0;
        for k = 1:numel(lookupBlocks)
            try
                tbl = strtrim(get_param(lookupBlocks{k}, 'Table'));
                bp1 = strtrim(get_param(lookupBlocks{k}, 'BreakpointsForDimension1'));
                blockName = get_param(lookupBlocks{k}, 'Name');

                nameHasGang = ~isempty(strfind(blockName, 'Gang')); %#ok<STREMP>
                bpUsesNoGears = ~isempty(strfind(bp1, 'gb.No_Gears')); %#ok<STREMP>
                isGearRatioTable = strcmp(tbl, 'gb.Gear_Ratio') || strcmp(tbl, 'gb_Gear_Ratio_LUT');

                if (isGearRatioTable || nameHasGang) && (isGearRatioTable || bpUsesNoGears)
                    set_param(lookupBlocks{k}, 'BreakpointsForDimension1', 'gb_Gears_LUT');
                    set_param(lookupBlocks{k}, 'Table', 'gb_Gear_Ratio_LUT');
                    nPatched = nPatched + 1;
                end
            catch
                % Ignore nonstandard lookup block variants.
            end
        end

        if nPatched > 0
            fprintf('Patched %d gearbox ratio lookup block(s): table = gb_Gear_Ratio_LUT, breakpoint = gb_Gears_LUT.\n', nPatched);
        end
    catch ME
        fprintf('WARNING: Could not patch gearbox ratio lookup blocks: %s\n', ME.message);
    end
end

function [gb, n_min_Upmin, n_max_Upmin] = ensureShiftLookupMaps2D(gb, cfg, cp, runID)
    % Ensures that the RPM lookup tables used by the gearbox selector are 2D.
    % Important for pure EV rows: even inactive Simulink branches are compiled.

    if ~isfield(cfg, 'VM'), cfg.VM = 0; end
    if ~isfield(cfg, 'Hy'), cfg.Hy = 0; end
    if ~isfield(cfg, 'EV'), cfg.EV = 0; end

    isPureEV = cfg.EV == 1 && cfg.VM == 0 && cfg.Hy == 0;

    if ~ispropSafe(gb, 'pedal_pos') || isempty(gb.pedal_pos)
        gb.pedal_pos = 0:0.1:1;
    end
    if ~ispropSafe(gb, 'Gears') || isempty(gb.Gears)
        if ispropSafe(gb, 'No_Gears') && ~isempty(gb.No_Gears) && isfinite(gb.No_Gears) && gb.No_Gears >= 1
            gb.Gears = 1:gb.No_Gears;
        else
            gb.Gears = 1;
        end
    end

    nPedal = max(2, numel(gb.pedal_pos));

    % Simulink lookup blocks require at least two points in each lookup
    % dimension. This matters for valid one-speed DoE rows, e.g.
    % Gear_Ratio = [1], No_Gears = 1.
    %
    % Do NOT change gb.No_Gears here. It is the physical gear count and is
    % used by the shift manager. For one-speed rows gb.No_Gears stays 1, so
    % the shift manager remains in one-gear mode. gb.Gears and gb.Gear_Ratio
    % only get a duplicated dummy point so the lookup blocks can compile.
    if numel(gb.Gears) < 2
        gb.Gears = [1 2];
    end

    gb_Gear_Ratio_LUT = [];
    if ispropSafe(gb, 'Gear_Ratio')
        try
            gr = gb.Gear_Ratio;
            if isempty(gr) || ~isnumeric(gr)
                gr = 1;
            end
            gr = double(gr(:).');
            gr = gr(isfinite(gr));
            if isempty(gr)
                gr = 1;
            end
            if numel(gr) < 2
                gr = [gr(1), gr(1)];
            end
            gb.Gear_Ratio = gr;
            gb_Gear_Ratio_LUT = gr;
        catch
            % Keep existing object state if assignment is not supported.
        end
    end

    if isempty(gb_Gear_Ratio_LUT)
        gb_Gear_Ratio_LUT = ones(1, max(2, numel(gb.Gears)));
    end
    if numel(gb_Gear_Ratio_LUT) < 2
        gb_Gear_Ratio_LUT = [gb_Gear_Ratio_LUT(1), gb_Gear_Ratio_LUT(1)];
    end
    gb_Gear_Ratio_LUT = double(gb_Gear_Ratio_LUT(:).');
    gb_Gears_LUT = 1:numel(gb_Gear_Ratio_LUT);

    nGear  = max(2, numel(gb.Gears));

    if isPureEV
        nMaxDefault  = max([getFieldOrDefault(cfg, 'n_EV_max', 0), ...
                            getFieldOrDefault(cfg, 'n_P2_max', 0), ...
                            getFieldOrDefault(cfg, 'n_P3_max', 0), ...
                            getFieldOrDefault(cfg, 'n_P4_max', 0), ...
                            getPropOrDefault(cp, 'n_EV_max', 0), ...
                            getPropOrDefault(cp, 'n_P2_max', 0), ...
                            getPropOrDefault(cp, 'n_P3_max', 0), ...
                            getPropOrDefault(cp, 'n_P4_max', 0), 1000]);
        nMinDefault = 0;
        if ispropSafe(gb, 'max_rpm')
            gb.max_rpm = nMaxDefault;
        end
    else
        nMaxDefault = max([getFieldOrDefault(cfg, 'n_ICE_max', 0), ...
                           getPropOrDefault(cp, 'n_ICE_max', 0), 1000]);
        nMinDefault = max([getFieldOrDefault(cfg, 'n_ICE_idle', 0), ...
                           getPropOrDefault(cp, 'n_ICE_idle', 0), 800]);
    end

    n_min_raw = [];
    n_max_raw = [];
    if ispropSafe(gb, 'n_min_Upmin')
        n_min_raw = gb.n_min_Upmin;
    end
    if ispropSafe(gb, 'n_max_Upmin')
        n_max_raw = gb.n_max_Upmin;
    end

    n_min_Upmin = normalizeLookup2D(n_min_raw, nPedal, nGear, nMinDefault);
    n_max_Upmin = normalizeLookup2D(n_max_raw, nPedal, nGear, nMaxDefault);

    % Keep max >= min for all entries.
    n_max_Upmin = max(n_max_Upmin, n_min_Upmin + 1);

    if ispropSafe(gb, 'n_min_Upmin')
        try, gb.n_min_Upmin = n_min_Upmin; catch, end
    end
    if ispropSafe(gb, 'n_max_Upmin')
        try, gb.n_max_Upmin = n_max_Upmin; catch, end
    end

    % Make the direct variables and updated gearbox object available to
    % Simulink even if this script is triggered from another wrapper.
    try
        assignin('base', 'n_min_Upmin', n_min_Upmin);
        assignin('base', 'n_max_Upmin', n_max_Upmin);
        assignin('base', 'gb_Gears_LUT', gb_Gears_LUT);
        assignin('base', 'gb_Gear_Ratio_LUT', gb_Gear_Ratio_LUT);
        assignin('base', 'gb', gb);
    catch
    end
    try
        assignin('caller', 'n_min_Upmin', n_min_Upmin);
        assignin('caller', 'n_max_Upmin', n_max_Upmin);
        assignin('caller', 'gb_Gears_LUT', gb_Gears_LUT);
        assignin('caller', 'gb_Gear_Ratio_LUT', gb_Gear_Ratio_LUT);
        assignin('caller', 'gb', gb);
    catch
    end

    fprintf('RunID %d: gearbox RPM lookup maps set to %dx%d [%s]. gearRatioLUT=%dx%d, n_min=%.0f rpm, n_max=%.0f rpm\n', ...
        runID, size(n_max_Upmin, 1), size(n_max_Upmin, 2), ...
        ternaryText(isPureEV, 'EV dummy map', 'ICE/Hybrid map'), ...
        size(gb_Gear_Ratio_LUT, 1), size(gb_Gear_Ratio_LUT, 2), ...
        min(n_min_Upmin(:)), max(n_max_Upmin(:)));
end

function M = normalizeLookup2D(raw, nRows, nCols, defaultVal)
    if isempty(raw) || ~isnumeric(raw)
        M = defaultVal .* ones(nRows, nCols);
        return;
    end

    raw = double(raw);
    raw = squeeze(raw);

    if isempty(raw) || any(~isfinite(raw(:)))
        M = defaultVal .* ones(nRows, nCols);
    elseif isscalar(raw)
        M = raw .* ones(nRows, nCols);
    elseif isvector(raw)
        v = raw(:);
        if numel(v) == nRows
            M = repmat(v, 1, nCols);
        elseif numel(v) == nCols
            M = repmat(v.', nRows, 1);
        else
            M = defaultVal .* ones(nRows, nCols);
            nCopy = min(numel(v), nRows);
            M(1:nCopy, :) = repmat(v(1:nCopy), 1, nCols);
        end
    else
        if isequal(size(raw), [nRows, nCols])
            M = raw;
        elseif isequal(size(raw), [nCols, nRows])
            M = raw.';
        else
            M = defaultVal .* ones(nRows, nCols);
            rCopy = min(size(raw, 1), nRows);
            cCopy = min(size(raw, 2), nCols);
            M(1:rCopy, 1:cCopy) = raw(1:rCopy, 1:cCopy);
        end
    end

    M = double(reshape(M, nRows, nCols));
end

function tf = ispropSafe(obj, propName)
    try
        tf = isprop(obj, propName);
    catch
        tf = false;
    end
end

function v = getFieldOrDefault(s, fieldName, defaultVal)
    v = defaultVal;
    if isstruct(s) && isfield(s, fieldName)
        tmp = s.(fieldName);
        if ~isempty(tmp) && isnumeric(tmp)
            tmp = double(tmp(:));
            tmp = tmp(isfinite(tmp));
            if ~isempty(tmp)
                v = max(tmp);
            end
        end
    end
end

function v = getPropOrDefault(obj, propName, defaultVal)
    v = defaultVal;
    if ispropSafe(obj, propName)
        try
            tmp = obj.(propName);
            if ~isempty(tmp) && isnumeric(tmp)
                tmp = double(tmp(:));
                tmp = tmp(isfinite(tmp));
                if ~isempty(tmp)
                    v = max(tmp);
                end
            end
        catch
        end
    end
end

function txt = ternaryText(cond, trueText, falseText)
    if cond
        txt = trueText;
    else
        txt = falseText;
    end
end


function createActualVsSim0100Plot(results_table, output_file)
    % Creates an Actual-vs-Simulated 0-100 km/h comparison plot.
    % Intended for the local debug export folder before ZIP creation.

    if isempty(results_table) || height(results_table) < 1
        fprintf('No results available. Skipping 0-100 comparison plot.\n');
        return;
    end

    varNames = results_table.Properties.VariableNames;

    if ~ismember('Actual_0_to_100_s', varNames)
        fprintf('Actual_0_to_100_s not available. Skipping 0-100 comparison plot.\n');
        return;
    end

    if ismember('SL_time_0_to_100', varNames)
        simCol = 'SL_time_0_to_100';
    elseif ismember('time_0_to_100', varNames)
        simCol = 'time_0_to_100';
    else
        fprintf('Simulated 0-100 column not available. Skipping 0-100 comparison plot.\n');
        return;
    end

    actual = str2double(string(results_table.Actual_0_to_100_s));
    simVal = str2double(string(results_table.(simCol)));

    valid = isfinite(actual) & isfinite(simVal) & actual > 0 & simVal > 0;
    actual = actual(valid);
    simVal = simVal(valid);

    if isempty(actual)
        fprintf('No valid Actual/Simulated 0-100 values. Skipping comparison plot.\n');
        return;
    end

    within10 = abs(simVal - actual) <= 0.10 .* actual;
    nValid = numel(actual);
    nPass = sum(within10);
    passRate = 100 * nPass / nValid;

    maxVal = max([actual; simVal]);
    axisMax = ceil(maxVal * 1.05);
    if axisMax < 5
        axisMax = 5;
    end
    axisMin = 0;
    xLine = linspace(axisMin, axisMax, 200);

    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1100 950]);
    hold on;

    % Scatter groups. Colors match the intended readable green/orange style.
    if any(within10)
        scatter(actual(within10), simVal(within10), 55, ...
            'MarkerFaceColor', [0.20 0.78 0.45], ...
            'MarkerEdgeColor', 'w', ...
            'MarkerFaceAlpha', 0.85, ...
            'DisplayName', sprintf('Within 10%% Tolerance (%d runs)', nPass));
    else
        scatter(NaN, NaN, 55, ...
            'MarkerFaceColor', [0.20 0.78 0.45], ...
            'MarkerEdgeColor', 'w', ...
            'DisplayName', 'Within 10% Tolerance (0 runs)');
    end

    nFail = nValid - nPass;
    if any(~within10)
        scatter(actual(~within10), simVal(~within10), 55, ...
            'MarkerFaceColor', [0.93 0.45 0.12], ...
            'MarkerEdgeColor', 'w', ...
            'MarkerFaceAlpha', 0.85, ...
            'DisplayName', sprintf('Outside 10%% Tolerance (%d runs)', nFail));
    else
        scatter(NaN, NaN, 55, ...
            'MarkerFaceColor', [0.93 0.45 0.12], ...
            'MarkerEdgeColor', 'w', ...
            'DisplayName', 'Outside 10% Tolerance (0 runs)');
    end

    plot(xLine, xLine, ':', 'Color', [0.10 0.18 0.28], 'LineWidth', 3, ...
        'DisplayName', 'Perfect Match (y = x)');
    plot(xLine, 1.10 .* xLine, '--', 'Color', [0.00 0.45 0.74], 'LineWidth', 2.2, ...
        'DisplayName', '±10% Tolerance Bands');
    plot(xLine, 0.90 .* xLine, '--', 'Color', [0.00 0.45 0.74], 'LineWidth', 2.2, ...
        'HandleVisibility', 'off');

    grid on;
    box on;
    axis([axisMin axisMax axisMin axisMax]);
    axis square;

    title('Actual vs Simulated 0-100 km/h Time', 'FontSize', 22, 'FontWeight', 'bold');
    xlabel('Actual 0 to 100 km/h Time (seconds)', 'FontSize', 15);
    ylabel('Simulated 0 to 100 km/h Time (seconds)', 'FontSize', 15);
    set(gca, 'FontSize', 13);

    lgd = legend('Location', 'northwest');
    set(lgd, 'FontSize', 13);

    txt = sprintf('Pass Rate: %.1f%%\n(%d / %d runs)', passRate, nPass, nValid);
    text(0.98, 0.04, txt, ...
        'Units', 'normalized', ...
        'HorizontalAlignment', 'right', ...
        'VerticalAlignment', 'bottom', ...
        'FontSize', 14, ...
        'BackgroundColor', 'w', ...
        'EdgeColor', [0.65 0.65 0.65], ...
        'LineWidth', 1.2, ...
        'Margin', 8);

    try
        exportgraphics(fig, output_file, 'Resolution', 200);
    catch
        print(fig, output_file, '-dpng', '-r200');
    end
    close(fig);

    fprintf('0-100 comparison plot saved:\n%s\n', char(string(output_file)));
end

