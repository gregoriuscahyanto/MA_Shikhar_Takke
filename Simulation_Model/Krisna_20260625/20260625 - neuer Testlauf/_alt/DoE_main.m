% DoE_main.m - RUNNING AS A SCRIPT (Global Scope)

% --- 0. SAFETY CHECK ---
% If running locally for test, define defaults if variables don't exist
if ~exist('TaskID', 'var'), TaskID = 1; end
if ~exist('ChunkSize', 'var'), ChunkSize = 1; end

fprintf('=== WORKER STARTED: TaskID %d | ChunkSize %d ===\n', TaskID, ChunkSize);

% Add Folders to Path
addpath(genpath("Config Scripts"))
addpath(genpath("DoE"))
addpath(genpath("Future"))
addpath(genpath("init_NBR Scripts"))
addpath(genpath("Reference Drive Cycle"))
addpath(genpath("Simulation Scripts"))

% --- 1. INITIALIZATION ---
% Since this is a script, this runs in Base Workspace automatically.
% Simulink will see EVERYTHING created here.
if ~exist('Track', 'var')
    fprintf("Running init_NBR...\n");
    init_NBR(); 
end

% --- 2. LOAD CONFIGURATIONS ---
csv_filename = 'DoE_Inp_Hybrid.csv'; 
if isempty(which(csv_filename))
    error('Config file %s not found.', csv_filename);
end

all_configs = loadConfig(csv_filename);
total_configs = length(all_configs);

% --- 3. DETERMINE LOOP RANGE ---
start_idx = (TaskID - 1) * ChunkSize + 1;
end_idx   = start_idx + ChunkSize - 1;

if start_idx > total_configs
    fprintf('Start index %d > Total configs %d. Exiting.\n', start_idx, total_configs);
    return;
end
if end_idx > total_configs, end_idx = total_configs; end

fprintf('Processing Rows %d to %d\n', start_idx, end_idx);

results_struct = []; 

% --- 4. MAIN SIMULATION LOOP ---
for i = start_idx:end_idx
    
    cfg = all_configs(i); 
    
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
    % Enable For EV -----------------------------------------EV------------
    %cp.n_EV_max = cfg.n_EV_max;
    %cp.tq_EV_max = cfg.tq_EV_max;
    %cp.Pwr_EV_max_kW = cfg.Pwr_EV_max_kW;
    %cp.Pwr_EV_nmax_red_perc = cfg.Pwr_EV_nmax_red_perc;
   % ----------------------------------------------------EV----------------


    cp = cp.computeICEMap(cfg.VM, cfg.Hy); 
    if isfield(cfg, 'P0'), cp = cp.computeP0Map(cfg.P0); end
    if isfield(cfg, 'P2'), cp = cp.computeP2Map(cfg.P2); end
    if isfield(cfg, 'P3'), cp = cp.computeP3Map(cfg.P3); end
    
    if isfield(cfg, 'E0'), cp = cp.computeEVMap(cfg.E0); end
    if isfield(cfg, 'E1'), cp = cp.computeEVMap(cfg.E1); end

    % ----------------------------------------------------EV----------------
    %if isfield(cfg, 'E2'), cp = cp.computeEVMap(cfg.E2); end
    %if isfield(cfg, 'E3'), cp = cp.computeEVMap(cfg.E3); end
    %if isfield(cfg, 'E4'), cp = cp.computeEVMap(cfg.E4); end
    % ----------------------------------------------------EV----------------


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

    
    cp = cp.computeP4Map(val_P4, 0, val_P4_DM, 0, 0);

    % setup_turbo; % Beta/future scope

    % --- Gearbox Config ---
    gb = GearboxConfig();
    gb.i_GET_EV = cfg.i_GET_EV;
    gb.i_ges_P4 = cfg.i_ges_P4;
    gb.max_rpm = cfg.n_ICE_max;
    gb.mode = string(cfg.mode); 
    gb.shiftDelay = cfg.shiftDelay;
    gb.use_cus_val = logical(cfg.use_cus_val);
    if ischar(cfg.Gear_Ratio) || isstring(cfg.Gear_Ratio)
        gb.Gear_Ratio = str2num(cfg.Gear_Ratio); 
    else
        gb.Gear_Ratio = cfg.Gear_Ratio;
    end
    gb.No_Gears = cfg.No_Gears;
    gb.Gears = 1:gb.No_Gears;
    gb.pedal_pos = 0:0.1:1;
    if cfg.VM || cfg.Hy == 1
        gb = gb.computeShiftMaps();
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

    %% Place holder
    current_result = struct();
    current_result.RUN_ID = runID; 

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
        simOut_SL = sim('Simulation_Fahrmodell_v3_straight_line.slx');
    catch ME
        fprintf('!!! CRITICAL ERROR SL Model (RunID: %d) !!!\n', runID);
        fprintf('%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
    end

    % Extract SL
    vars_SL = {'time_0_to_100', 'time_0_to_200', 'time_80_to_120', 'time_60_to_120', 'max_speed', 'max_launch_acc'};
    current_result = extractVars(simOut_SL, vars_SL, current_result, 'SL_');

    %% === APPEND OUTPUTS ===

    % Append
    if isempty(results_struct)
        results_struct = current_result;
    else
        results_struct = appendStruct(results_struct, current_result);
    end
    
end % End Loop

%% === SAVE RESULTS ===
output_filename = sprintf('Results_Chunk_%d.mat', TaskID);
fprintf('Saving %d runs to %s...\n', length(results_struct), output_filename);
save(output_filename, 'results_struct');
fprintf('Task %d Done.\n', TaskID);

%% === HELPER FUNCTIONS (Must be at bottom of script) ===

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