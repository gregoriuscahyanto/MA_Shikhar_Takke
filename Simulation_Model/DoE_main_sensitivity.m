function T_out = DoE_main_sensitivity(csv_filename, output_filename, task_id, chunk_size)
% DoE_main_sensitivity.m
% Generic DoE runner for sensitivity sweeps.
% Compatible with Hybrid and BEV CSV inputs.
%
% Features:
%   - Resume support: existing SWEEP_RUN_IDs in output_filename are skipped.
%   - Checkpointing: output_filename is updated after every completed run.
%   - Suppresses noisy Simulink warnings/diagnostics during batch runs.
%
% Usage:
%   DoE_main_sensitivity('C:/.../sweep_hybrid_G1_lt5s.csv', 'C:/.../sweep_results_hybrid_G1.xlsx')
%   DoE_main_sensitivity('C:/.../sweep_bev_G1_lt5s.csv', 'C:/.../sweep_results_bev_G1.xlsx')

    % === Clean batch output ===
    oldWarnTop = warning('off', 'all');
    cleanupWarnTop = onCleanup(@() warning(oldWarnTop)); %#ok<NASGU>

    if nargin < 1 || isempty(csv_filename)
        csv_filename = 'DoE_Inp_Hybrid.csv';
    end
    if nargin < 2 || isempty(output_filename)
        [p, n, ~] = fileparts(csv_filename);
        output_filename = fullfile(p, ['sweep_results_' n '.xlsx']);
    end
    if nargin < 3 || isempty(task_id)
        task_id = 1;
    end

    sim_dir = fileparts(mfilename('fullpath'));
    old_dir = pwd;
    cleanupDir = onCleanup(@() cd(old_dir)); %#ok<NASGU>
    cd(sim_dir);
    addpath(sim_dir);

    csv_filename = char(csv_filename);
    output_filename = char(output_filename);

    if ~isfile(csv_filename)
        error('Config file not found: %s', csv_filename);
    end

    fprintf('=== SENSITIVITY DOE STARTED ===\n');
    fprintf('Input CSV : %s\n', csv_filename);
    fprintf('Output XLSX: %s\n', output_filename);

    % Load models early and suppress diagnostics before initialization/sim calls.
    suppressBatchDiagnostics();

    if evalin('base', 'exist(''Track'', ''var'')') ~= 1
        fprintf('Running init_NBR...\n');
        evalc('init_NBR();');  % suppress readtable/header warnings inside init_NBR
    end

    suppressBatchDiagnostics();

    all_configs = loadConfig(csv_filename);
    total_configs = length(all_configs);

    task_id = normalizePositiveInteger(task_id, 1);

    if nargin < 4 || isempty(chunk_size) || isinf(doubleOrNaN(chunk_size))
        chunk_size = total_configs;
    end
    chunk_size = normalizePositiveInteger(chunk_size, total_configs);

    start_idx = (task_id - 1) * chunk_size + 1;
    end_idx = min(start_idx + chunk_size - 1, total_configs);

    fprintf('Task ID    : %d\n', task_id);
    fprintf('Chunk size : %d\n', chunk_size);

    if start_idx > total_configs
        fprintf('Start index %d > total configs %d. Returning empty table.\n', start_idx, total_configs);
        T_out = table();
        return;
    end

    fprintf('Processing rows %d to %d of %d\n', start_idx, end_idx, total_configs);

    % === Resume support ===
    existing_results = table();
    done_sweep_ids = [];
    done_run_ids = [];

    if isfile(output_filename)
        [existing_results, read_ok] = readExistingResults(output_filename);

        if read_ok && height(existing_results) > 0
            if ismember('SWEEP_RUN_ID', existing_results.Properties.VariableNames)
                done_sweep_ids = numericColumn(existing_results.SWEEP_RUN_ID);
                done_sweep_ids = done_sweep_ids(~isnan(done_sweep_ids));
                fprintf('Resume mode: found %d existing SWEEP_RUN_IDs.\n', numel(done_sweep_ids));
            elseif ismember('RUN_ID', existing_results.Properties.VariableNames)
                done_run_ids = numericColumn(existing_results.RUN_ID);
                done_run_ids = done_run_ids(~isnan(done_run_ids));
                fprintf('Resume mode: found %d existing RUN_IDs.\n', numel(done_run_ids));
            else
                fprintf('Resume mode: existing output has no SWEEP_RUN_ID/RUN_ID column. Continuing carefully.\n');
            end
        elseif ~read_ok
            fprintf('Existing output could not be read. It was renamed; starting a new checkpoint file.\n');
            existing_results = table();
        end
    end

    results_struct = [];

    for i = start_idx:end_idx
        cfg = all_configs(i);

        runID = cfgNum(cfg, 'RUN_ID', i);
        sweepRunID = cfgNum(cfg, 'SWEEP_RUN_ID', i);
        origRunID = cfgNum(cfg, 'ORIG_RUN_ID', runID);

        if ~isempty(done_sweep_ids) && ~isnan(sweepRunID) && any(done_sweep_ids == sweepRunID)
            fprintf('Skipping SWEEP_RUN_ID %g because it already exists in output.\n', sweepRunID);
            continue;
        end

        if isempty(done_sweep_ids) && ~isempty(done_run_ids) && any(done_run_ids == runID)
            fprintf('Skipping RUN_ID %g because it already exists in output.\n', runID);
            continue;
        end

        fprintf('--- Row %d | RUN_ID: %g | SWEEP_RUN_ID: %g | ORIG_RUN_ID: %g ---\n', ...
            i, runID, sweepRunID, origRunID);

        current_result = struct();
        current_result.RUN_ID = runID;
        current_result.SWEEP_RUN_ID = sweepRunID;
        current_result.ORIG_RUN_ID = origRunID;

        try
            [veh, cp, gb, pt, bat] = buildObjects(cfg);

            assignin('base', 'cfg', cfg);
            assignin('base', 'veh', veh);
            assignin('base', 'cp', cp);
            assignin('base', 'gb', gb);
            assignin('base', 'pt', pt);
            assignin('base', 'bat', bat);
            assignin('base', 'A_front', veh.A_front);

            try
                % Keep output quiet but still assign variables.
                evalc('[SKO_WHEEL_TYP_CHAL, SKO_STREET_CHAL, cw] = VehicleParamSelector(cp, veh);');
                veh.cw = cw;
                assignin('base', 'veh', veh);
                assignin('base', 'SKO_WHEEL_TYP_CHAL', SKO_WHEEL_TYP_CHAL);
                assignin('base', 'SKO_STREET_CHAL', SKO_STREET_CHAL);
                assignin('base', 'cw', cw);
            catch ME
                fprintf('WARNING: VehicleParamSelector failed for RUN_ID %g.\n', runID);
                fprintf('%s\n', ME.message);
            end

            suppressBatchDiagnostics();

            simOut_Main = [];
            try
                simOut_Main = runSimQuiet('Simulation_Fahrmodell_v3.slx');
            catch ME
                fprintf('!!! ERROR Main Model | RUN_ID %g !!!\n', runID);
                fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
            end

            suppressBatchDiagnostics();

            simOut_SL = [];
            try
                simOut_SL = runSimQuiet('Simulation_Fahrmodell_v3_straight_line.slx');
            catch ME
                fprintf('!!! ERROR Straight Line Model | RUN_ID %g !!!\n', runID);
                fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
            end

            vars_main = {'SOC_Final', 'Lap_Time', 'Avg_track_speed', ...
                         'Energy_elc_consumed', 'Energy_elc_recuperated'};
            current_result = extractVars(simOut_Main, vars_main, current_result, '');

            vars_SL = {'time_0_to_100', 'time_0_to_200', 'time_80_to_120', ...
                       'time_60_to_120', 'max_speed', 'max_launch_acc'};
            current_result = extractVars(simOut_SL, vars_SL, current_result, 'SL_');

        catch ME
            fprintf('!!! FULL ROW FAILURE | RUN_ID %g !!!\n', runID);
            fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));

            current_result.SOC_Final = NaN;
            current_result.Lap_Time = NaN;
            current_result.Avg_track_speed = NaN;
            current_result.Energy_elc_consumed = NaN;
            current_result.Energy_elc_recuperated = NaN;
            current_result.SL_time_0_to_100 = NaN;
            current_result.SL_time_0_to_200 = NaN;
            current_result.SL_time_80_to_120 = NaN;
            current_result.SL_time_60_to_120 = NaN;
            current_result.SL_max_speed = NaN;
            current_result.SL_max_launch_acc = NaN;
        end

        if isempty(results_struct)
            results_struct = current_result;
        else
            results_struct = appendStruct(results_struct, current_result);
        end

        % === Checkpoint after every run ===
        existing_results = writeCheckpoint(existing_results, results_struct, output_filename);

        % Mark this row as done in this MATLAB session too.
        if ~isnan(sweepRunID)
            done_sweep_ids(end + 1, 1) = sweepRunID; %#ok<AGROW>
        else
            done_run_ids(end + 1, 1) = runID; %#ok<AGROW>
        end

        % Clear incremental struct because it has already been written.
        results_struct = [];
    end

    if isfile(output_filename)
        [T_out, read_ok] = readExistingResults(output_filename);
        if ~read_ok
            T_out = table();
        end
    else
        T_out = table();
    end

    fprintf('SUCCESS: Saved %d rows to %s\n', height(T_out), output_filename);
end


function simOut = runSimQuiet(modelName)
    % Hard suppression around sim(). Some Simulink diagnostics are not fully
    % controlled by warning IDs, so evalc captures command-window output.
    oldWarn = warning('off', 'all');
    cleanupWarn = onCleanup(@() warning(oldWarn)); %#ok<NASGU>

    suppressBatchDiagnostics();

    simOut = [];
    cmd = sprintf('simOut = sim(''%s'', ''SrcWorkspace'', ''base'');', modelName);
    evalc(cmd);
end


function suppressBatchDiagnostics()
    % Suppress MATLAB warnings
    warning('off', 'all');
    warning('off', 'backtrace');
    warning('off', 'MATLAB:table:ModifiedAndSavedVarnames');

    models = {'Simulation_Fahrmodell_v3', ...
              'Simulation_Fahrmodell_v3_straight_line'};

    for k = 1:numel(models)
        mdl = models{k};

        try
            load_system(mdl);
        catch
            continue;
        end

        % Common Simulink diagnostics
        setDiagSafe(mdl, 'SignalInfNanChecking', 'none');
        setDiagSafe(mdl, 'ZeroDivisionMsg', 'none');
        setDiagSafe(mdl, 'DivideByZeroMsg', 'none');
        setDiagSafe(mdl, 'AlgebraicLoopMsg', 'none');
        setDiagSafe(mdl, 'MinStepSizeMsg', 'none');
        setDiagSafe(mdl, 'SolverPrmCheckMsg', 'none');
        setDiagSafe(mdl, 'InheritedTsInSrcMsg', 'none');

        try
            cs = getActiveConfigSet(mdl);
            setDiagSafe(cs, 'SignalInfNanChecking', 'none');
            setDiagSafe(cs, 'ZeroDivisionMsg', 'none');
            setDiagSafe(cs, 'DivideByZeroMsg', 'none');
            setDiagSafe(cs, 'AlgebraicLoopMsg', 'none');
            setDiagSafe(cs, 'MinStepSizeMsg', 'none');
            setDiagSafe(cs, 'SolverPrmCheckMsg', 'none');
            setDiagSafe(cs, 'InheritedTsInSrcMsg', 'none');
        catch
        end
    end
end


function setDiagSafe(target, paramName, paramValue)
    try
        set_param(target, paramName, paramValue);
    catch
    end
end


function existing_results = writeCheckpoint(existing_results, results_struct, output_filename)
    new_table = struct2table(results_struct, 'AsArray', true);

    if isempty(existing_results) || height(existing_results) == 0
        combined_table = new_table;
    else
        combined_table = appendTablesByName(existing_results, new_table);
    end

    if ismember('SWEEP_RUN_ID', combined_table.Properties.VariableNames)
        sweep_ids = numericColumn(combined_table.SWEEP_RUN_ID);
        combined_table = combined_table(~isnan(sweep_ids), :);
        sweep_ids = sweep_ids(~isnan(sweep_ids));
        [~, ia] = unique(sweep_ids, 'stable');
        combined_table = combined_table(ia, :);
        combined_table = sortrows(combined_table, 'SWEEP_RUN_ID');
    elseif ismember('RUN_ID', combined_table.Properties.VariableNames)
        run_ids = numericColumn(combined_table.RUN_ID);
        [~, ia] = unique(run_ids, 'stable');
        combined_table = combined_table(ia, :);
        combined_table = sortrows(combined_table, 'RUN_ID');
    end

    out_dir = fileparts(output_filename);
    if ~isempty(out_dir) && ~isfolder(out_dir)
        mkdir(out_dir);
    end

    % Safer checkpointing:
    % First write a complete temporary XLSX, then replace the target file.
    % If the job is killed during writetable(), the old output_filename remains intact.
    if isempty(out_dir)
        tmp_file = [tempname(pwd), '.xlsx'];
    else
        tmp_file = [tempname(out_dir), '.xlsx'];
    end

    try
        writetable(combined_table, tmp_file);
        movefile(tmp_file, output_filename, 'f');
    catch ME
        if isfile(tmp_file)
            try
                delete(tmp_file);
            catch
            end
        end
        rethrow(ME);
    end

    fprintf('Checkpoint saved: %s | rows: %d\n', output_filename, height(combined_table));

    existing_results = combined_table;
end

function T = appendTablesByName(T1, T2)
    names1 = T1.Properties.VariableNames;
    names2 = T2.Properties.VariableNames;
    allNames = unique([names1, names2], 'stable');

    for k = 1:numel(allNames)
        name = allNames{k};

        if ~ismember(name, names1)
            T1.(name) = missingColumn(height(T1));
        end

        if ~ismember(name, names2)
            T2.(name) = missingColumn(height(T2));
        end
    end

    T1 = T1(:, allNames);
    T2 = T2(:, allNames);

    T = [T1; T2];
end


function col = missingColumn(n)
    col = NaN(n, 1);
end


function [veh, cp, gb, pt, bat] = buildObjects(cfg)

    VM = cfgNum(cfg, 'VM', 0);
    EV = cfgNum(cfg, 'EV', 0);
    Hy = cfgNum(cfg, 'Hy', 0);

    veh = VehicleConfig();
    veh.VM = VM;
    veh.EV = EV;
    veh.Hy = Hy;
    veh.HM_VA = cfgNum(cfg, 'HM_VA', 0);
    veh.AWD = cfgNum(cfg, 'AWD', 0);
    veh.iAG = cfgNum(cfg, 'iAG', 1);
    veh.m_curb = cfgNum(cfg, 'm_curb', 1500);
    veh.Wheelbase = cfgNum(cfg, 'Wheelbase', 2.7);
    veh.h_s = cfgNum(cfg, 'h_s', 0.4);
    veh.weight_dist = cfgNum(cfg, 'weight_dist', 0.5);
    veh.MainAxle_TorqueSplit_int = cfgNum(cfg, 'MainAxle_TorqueSplit_int', 0.5);
    veh.Hybrid_ICE_priority = cfgNum(cfg, 'Hybrid_ICE_priority', 1);
    veh.d_wheel = cfgNum(cfg, 'd_wheel', 0.65);
    veh.A_front = cfgNum(cfg, 'A_front', 2.5);

    cp = ComponentParams();

    cp.n_ICE_idle = cfgNum(cfg, 'n_ICE_idle', cp.n_ICE_idle);
    cp.n_ICE_max = cfgNum(cfg, 'n_ICE_max', cp.n_ICE_max);
    cp.tq_ICE_idle = cfgNum(cfg, 'tq_ICE_idle', cp.tq_ICE_idle);
    cp.tq_ICE_max = cfgNum(cfg, 'tq_ICE_max', cp.tq_ICE_max);
    cp.Pwr_ICE_max_kW = cfgNum(cfg, 'Pwr_ICE_max_kW', cp.Pwr_ICE_max_kW);

    cp.n_P0_max = cfgNum(cfg, 'n_P0_max', cp.n_P0_max);
    cp.tq_P0_max = cfgNum(cfg, 'tq_P0_max', cp.tq_P0_max);
    cp.Pwr_P0_max_kW = cfgNum(cfg, 'Pwr_P0_max_kW', cp.Pwr_P0_max_kW);
    cp.Pwr_P0_nmax_red_perc = cfgNum(cfg, 'Pwr_P0_nmax_red_perc', cp.Pwr_P0_nmax_red_perc);

    cp.n_P2_max = cfgNum(cfg, 'n_P2_max', cp.n_P2_max);
    cp.tq_P2_max = cfgNum(cfg, 'tq_P2_max', cp.tq_P2_max);
    cp.Pwr_P2_max_kW = cfgNum(cfg, 'Pwr_P2_max_kW', cp.Pwr_P2_max_kW);
    cp.Pwr_P2_nmax_red_perc = cfgNum(cfg, 'Pwr_P2_nmax_red_perc', cp.Pwr_P2_nmax_red_perc);

    cp.n_P3_max = cfgNum(cfg, 'n_P3_max', cp.n_P3_max);
    cp.tq_P3_max = cfgNum(cfg, 'tq_P3_max', cp.tq_P3_max);
    cp.Pwr_P3_max_kW = cfgNum(cfg, 'Pwr_P3_max_kW', cp.Pwr_P3_max_kW);
    cp.Pwr_P3_nmax_red_perc = cfgNum(cfg, 'Pwr_P3_nmax_red_perc', cp.Pwr_P3_nmax_red_perc);

    cp.n_P4_max = cfgNum(cfg, 'n_P4_max', cp.n_P4_max);
    cp.tq_P4_max = cfgNum(cfg, 'tq_P4_max', cp.tq_P4_max);
    cp.Pwr_P4_max_kW = cfgNum(cfg, 'Pwr_P4_max_kW', cp.Pwr_P4_max_kW);
    cp.Pwr_P4_nmax_red_perc = cfgNum(cfg, 'Pwr_P4_nmax_red_perc', cp.Pwr_P4_nmax_red_perc);

    cp.n_EV_max = cfgNum(cfg, 'n_EV_max', cp.n_EV_max);
    cp.tq_EV_max = cfgNum(cfg, 'tq_EV_max', cp.tq_EV_max);
    cp.Pwr_EV_max_kW = cfgNum(cfg, 'Pwr_EV_max_kW', cp.Pwr_EV_max_kW);
    cp.Pwr_EV_nmax_red_perc = cfgNum(cfg, 'Pwr_EV_nmax_red_perc', cp.Pwr_EV_nmax_red_perc);

    P0 = cfgNum(cfg, 'P0', 0);
    P2 = cfgNum(cfg, 'P2', 0);
    P3 = cfgNum(cfg, 'P3', 0);
    P4 = cfgNum(cfg, 'P4', 0);
    P4_DM = cfgNum(cfg, 'P4_DM', 0);

    E0 = cfgNum(cfg, 'E0', 0);
    E1 = cfgNum(cfg, 'E1', 0);
    E2 = cfgNum(cfg, 'E2', 0);
    E3 = cfgNum(cfg, 'E3', 0);
    E4 = cfgNum(cfg, 'E4', 0);

    % BEV compatibility: use EV motor values for P4 fallback if needed.
    if EV == 1
        if cp.tq_P4_max == 0
            cp.tq_P4_max = cp.tq_EV_max;
        end
        if cp.Pwr_P4_max_kW == 0
            cp.Pwr_P4_max_kW = cp.Pwr_EV_max_kW;
        end
        if cp.n_P4_max == 0
            cp.n_P4_max = cp.n_EV_max;
        end
        if cp.Pwr_P4_nmax_red_perc == 0
            cp.Pwr_P4_nmax_red_perc = cp.Pwr_EV_nmax_red_perc;
        end
    end

    cp = cp.computeICEMap(VM, Hy);
    cp = cp.computeP0Map(P0);
    cp = cp.computeP2Map(P2);
    cp = cp.computeP3Map(P3);

    if any([E0, E1, E2, E3, E4] == 1)
        cp = cp.computeEVMap(1);
    end

    cp = cp.computeP4Map(P4, E2, P4_DM, E3, E4);

    gb = GearboxConfig();

    gb.i_GET_EV = cfgNum(cfg, 'i_GET_EV', 1);
    gb.i_ges_P4 = cfgNum(cfg, 'i_ges_P4', 1);

    if EV == 1 && Hy == 0 && VM == 0
        gb.max_rpm = cp.n_EV_max;
    else
        gb.max_rpm = cp.n_ICE_max;
    end

    gb.mode = string(cfgRaw(cfg, 'mode', 'performance'));
    gb.shiftDelay = cfgNum(cfg, 'shiftDelay', 0.05);
    gb.use_cus_val = logical(cfgNum(cfg, 'use_cus_val', 1));

    gear_ratio = cfgVector(cfg, 'Gear_Ratio', 1);
    gb.Gear_Ratio = gear_ratio;

    gb.No_Gears = cfgNum(cfg, 'No_Gears', max(1, numel(gear_ratio)));
    if gb.No_Gears < 1
        gb.No_Gears = 1;
    end

    gb.Gears = 1:gb.No_Gears;
    gb.pedal_pos = 0:0.1:1;

    if VM == 1 || Hy == 1
        gb = gb.computeShiftMaps();
    end

    pt = PowertrainConfig();
    pt.VM = VM;
    pt.EV = EV;
    pt.Hy = Hy;

    pt.P0 = P0;
    pt.P2 = P2;
    pt.P3 = P3;
    pt.P4 = P4;
    pt.P4_DM = P4_DM;

    pt.E0 = E0;
    pt.E1 = E1;
    pt.E2 = E2;
    pt.E3 = E3;
    pt.E4 = E4;

    % Suppress display output from setup methods.
    try
        evalc('pt = pt.setupEV();');
    catch
        pt = pt.setupEV();
    end

    try
        evalc('pt = pt.setupHybrid();');
    catch
        pt = pt.setupHybrid();
    end

    bat = BatteryConfig();
    bat.Cell_Cap_Ah = cfgNum(cfg, 'Cell_Cap_Ah', bat.Cell_Cap_Ah);
    bat.Cell_V_nom = cfgNum(cfg, 'Cell_V_nom', bat.Cell_V_nom);
    bat.Cell_R_inner = cfgNum(cfg, 'Cell_R_inner', bat.Cell_R_inner);
    bat.Cell_V_min = cfgNum(cfg, 'Cell_V_min', bat.Cell_V_min);
    bat.Cell_V_max = cfgNum(cfg, 'Cell_V_max', bat.Cell_V_max);
    bat.Cell_I_max_chg = cfgNum(cfg, 'Cell_I_max_chg', bat.Cell_I_max_chg);
    bat.Cell_I_max_dis = cfgNum(cfg, 'Cell_I_max_dis', bat.Cell_I_max_dis);
    bat.SOC_Vector = cfgVector(cfg, 'SOC_Vector', bat.SOC_Vector);
    bat.Cell_OCV_Vector = cfgVector(cfg, 'Cell_OCV_Vector', bat.Cell_OCV_Vector);
    bat.n_s = cfgNum(cfg, 'n_s', bat.n_s);
    bat.n_p = cfgNum(cfg, 'n_p', bat.n_p);
    bat.facSocInit = cfgNum(cfg, 'facSocInit', bat.facSocInit);
    bat.SOC_Recup_Limit = cfgNum(cfg, 'SOC_Recup_Limit', bat.SOC_Recup_Limit);
    bat.SOC_Bat_Discharge_Limit = cfgNum(cfg, 'SOC_Bat_Discharge_Limit', bat.SOC_Bat_Discharge_Limit);

    try
        evalc('bat = bat.computePack();');
    catch
        bat = bat.computePack();
    end
end


function current_result = extractVars(simOut, varNames, current_result, prefix)
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
    try
        opts = detectImportOptions(filename, 'VariableNamingRule', 'preserve');
        T = readtable(filename, opts);
    catch
        T = readtable(filename);
    end

    T.Properties.VariableNames = matlab.lang.makeValidName(T.Properties.VariableNames);
    all_configs = table2struct(T);
end


function mainStruct = appendStruct(mainStruct, newStruct)
    mainFields = fieldnames(mainStruct);
    newFields = fieldnames(newStruct);

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


function [T, ok] = readExistingResults(filename)
    ok = false;
    T = table();

    try
        T = readtable(filename, 'VariableNamingRule', 'preserve');
        T.Properties.VariableNames = matlab.lang.makeValidName(T.Properties.VariableNames);
        ok = true;
    catch ME
        fprintf('Could not read existing output file for resume: %s\n', filename);
        fprintf('%s\n', ME.message);

        try
            [p, n, e] = fileparts(filename);
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            corrupt_name = fullfile(p, [n, '.corrupt_', stamp, e]);
            movefile(filename, corrupt_name, 'f');
            fprintf('Unreadable output file renamed to: %s\n', corrupt_name);
        catch ME2
            fprintf('Could not rename unreadable output file. Leaving it untouched.\n');
            fprintf('%s\n', ME2.message);
        end
    end
end


function val = normalizePositiveInteger(raw, defaultVal)
    val = doubleOrNaN(raw);

    if isnan(val) || isinf(val) || val < 1
        val = defaultVal;
    end

    val = max(1, floor(val));
end


function val = doubleOrNaN(raw)
    try
        if isnumeric(raw)
            if isempty(raw)
                val = NaN;
            else
                val = double(raw(1));
            end
            return;
        end

        if isstring(raw) || ischar(raw)
            val = str2double(string(raw));
            return;
        end
    catch
    end

    val = NaN;
end


function col = numericColumn(colIn)
    if isnumeric(colIn)
        col = double(colIn);
        return;
    end

    if iscell(colIn)
        col = NaN(numel(colIn), 1);
        for k = 1:numel(colIn)
            col(k) = doubleOrNaN(colIn{k});
        end
        return;
    end

    if isstring(colIn) || ischar(colIn)
        col = str2double(string(colIn));
        col = col(:);
        return;
    end

    try
        col = double(colIn);
        col = col(:);
    catch
        col = NaN(numel(colIn), 1);
    end
end


function raw = cfgRaw(cfg, name, default)
    safeName = matlab.lang.makeValidName(name);

    if isfield(cfg, safeName)
        raw = cfg.(safeName);
        if isMissing(raw)
            raw = default;
        end
    else
        raw = default;
    end
end


function val = cfgNum(cfg, name, default)
    raw = cfgRaw(cfg, name, default);

    if isnumeric(raw)
        if isempty(raw) || any(isnan(raw(:)))
            val = default;
        else
            val = raw;
            if numel(val) > 1
                val = val(1);
            end
        end
        return;
    end

    if isstring(raw) || ischar(raw)
        val = str2double(string(raw));
        if isnan(val)
            val = default;
        end
        return;
    end

    val = default;
end


function vec = cfgVector(cfg, name, default)
    raw = cfgRaw(cfg, name, default);

    if isnumeric(raw)
        if isempty(raw)
            vec = default;
        else
            vec = raw;
        end
        return;
    end

    if isstring(raw) || ischar(raw)
        txt = char(raw);
        parsed = str2num(txt); %#ok<ST2NM>
        if isempty(parsed)
            numVal = str2double(txt);
            if isnan(numVal)
                vec = default;
            else
                vec = numVal;
            end
        else
            vec = parsed;
        end
        return;
    end

    vec = default;
end


function tf = isMissing(v)
    tf = false;

    try
        m = ismissing(v);
        if any(m(:))
            tf = true;
            return;
        end
    catch
    end

    if isnumeric(v) && isscalar(v) && isnan(v)
        tf = true;
    end
end
