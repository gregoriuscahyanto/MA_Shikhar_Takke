% ============================================================
% setup_turbo.m 
%
% Fits directly into your DoE_main.m structure.
% Call AFTER cp.computeICEMap() in your loop.
%
% READS from workspace (all come from cfg struct in DoE_main):
%   cfg.VM               - ICE present flag
%   cfg.Induction_Type   - 'Turbo' / 'NA' / 'Supercharger' / 'Twincharger'
%                          ADD THIS COLUMN to DoE_Inp_Hybrid.csv
%   cfg.Displacement_cc  - Engine displacement in cm3
%                          ADD THIS COLUMN to DoE_Inp_Hybrid.csv
%   cfg.Boost_Pressure_bar - Turbo boost pressure [bar], NaN if unknown
%                          ADD THIS COLUMN to DoE_Inp_Hybrid.csv
%   cp                   - ComponentParams object (already computed)
%   runID                - Run identifier (replaces Car_Name)
%
% SETS in workspace (read by Simulink blocks directly by variable name):
%   use_turbo_model            [0/1]    -> Switch block condition port
%   facSettlIn                 [=50]    -> Gain block
%   Ice_n_axis                 [1x12]   -> Breakpoints 2 of 2D Lookup Tables
%   Ice_rl_axis_norm           [1x10]   -> Breakpoints 1 of 2D Lookup Tables
%   Ice_derfacLoadIncrease_MAP [10x12]  -> Table data: derfacLoadIncrease block
%   Ice_derfacLoadDecrease_MAP [10x12]  -> Table data: derfacLoadDecrease block
%   Ice_relLoadMax_CUR_n       [1xN]    -> Breakpoints: relLoadMax 1D Lookup
%   Ice_relLoadMax_CUR_val     [1xN]    -> Table data:  relLoadMax 1D Lookup
%
% ON INTERPOLATION:
%   The maps are fixed 10x12 grids scaled once here at setup.
%   During simulation, Simulink's 2D Lookup Table blocks perform
%   bilinear interpolation at every timestep as n_ICE and rl change.
%   You do NOT need to handle interpolation yourself — Simulink does it.
% ============================================================

%% ================================================================
%% SECTION 1: Base maps — loaded once per session
%% ================================================================
if ~exist('Ice_derfacLoadIncrease_base', 'var')

    Ice_n_axis       = [500, 1000, 1100, 1250, 1320, 1500, 1750, 2000, 2500, 3000, 4500, 6000];
    Ice_rl_axis_norm = [0.0000, 0.4430, 0.5700, 0.6330, 0.6960, 0.7590, 0.8230, 0.8860, 0.9490, 1.0000];

    % Prince engine base map [norm_rl/s] — normalised by rl_max_Prince=158%
    % Ref: Mallebrein & Auerbach (2025), Hochschule Esslingen
    %      Eriksson & Nielsen (2014), Modelling and Control of Engines
    Ice_derfacLoadIncrease_base = [
    1.7722, 2.0253, 2.2152, 3.7975, 3.1646, 5.0633, 6.3291, 7.5949, 6.3291, 8.2278, 9.4937, 10.1266;
    0.0380, 0.0696, 0.0949, 0.1266, 0.3797, 0.2215, 0.6329, 1.8987, 5.0633, 5.0633, 5.6962, 6.3291;
    0.0000, 0.0633, 0.0633, 0.0886, 0.1582, 0.0949, 0.1899, 0.3165, 1.8987, 1.3924, 1.2658, 1.8987;
    0.0000, 0.0253, 0.0380, 0.0633, 0.1266, 0.0949, 0.1582, 0.2532, 0.9494, 0.7595, 1.1392, 1.2658;
    0.0000, 0.0000, 0.0000, 0.0380, 0.1582, 0.0633, 0.1266, 0.2405, 0.5696, 0.6329, 0.9494, 0.6329;
    0.0000, 0.0000, 0.0000, 0.0000, 0.2215, 0.0506, 0.1266, 0.2025, 0.5696, 0.6329, 0.7595, 0.3165;
    0.0000, 0.0000, 0.0000, 0.0000, 0.2532, 0.0316, 0.0949, 0.1582, 0.5696, 0.6329, 0.6329, 0.0000;
    0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0316, 0.0633, 0.1266, 0.5696, 0.6329, 0.2532, 0.0000;
    0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0696, 0.1013, 0.5063, 0.3797, 0.0000, 0.0000;
    0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000;
];

    Ice_derfacLoadDecrease_base = min(Ice_derfacLoadIncrease_base * 10.0, 200);

    tau_ref         = 0.70;   % Prince engine reference [s]
    n_plateau_ref   = 1750;   % Prince engine full-boost onset [rpm]
    facSettlIn      = 50;     % Integrator gain — do not change

    disp('[setup_turbo] Base maps loaded.');
end

%% ================================================================
%% SECTION 2: Per-run setup — reads cfg fields and cp object
%% ================================================================

%% --- Read required fields from cfg ---
% These three columns must exist in DoE_Inp_Hybrid.csv
Induction_Type     = char(cfg.Induction_Type);
Displacement_cc    = cfg.Displacement_cc;
Boost_Pressure_bar = cfg.Boost_Pressure_bar;

% n_ICE_plateau_start: computed by ComponentParams.computeICEMap()
% It is the RPM where the parabolic torque curve hits tq_ICE_max
% = the RPM at which full boost is first established
n_ICE_plateau_start = cp.n_ICE_plateau_start;

%% --- Guard: skip for NA or EV-only runs ---
if cfg.VM == 0
    % No ICE in this run (pure EV): bypass entirely
    use_turbo_model = 0;
    Ice_derfacLoadIncrease_MAP = Ice_derfacLoadIncrease_base;
    Ice_derfacLoadDecrease_MAP = Ice_derfacLoadDecrease_base;
    Ice_relLoadMax_CUR_n   = [500, 6000];
    Ice_relLoadMax_CUR_val = [1.0,  1.0];
    fprintf('[setup_turbo] RUN_ID %d: EV/no-ICE — turbo bypassed\n', runID);
    return;
end

%% --- Compute tau from actual engine parameters ---
switch Induction_Type
    case 'NA'
        use_turbo_model = 0;
        Turbo_Lag_tau_s = 0.0;

    case 'Supercharger'
        use_turbo_model = 1;
        Turbo_Lag_tau_s = 0.10;

    case 'Twincharger'
        use_turbo_model = 1;
        Turbo_Lag_tau_s = 0.20;

    case 'Turbo'
        use_turbo_model = 1;
        % Base tau from displacement (primary driver of turbine inertia)
        if     Displacement_cc <= 1600, tau_base = 0.40;
        elseif Displacement_cc <= 2500, tau_base = 0.70;
        else,                           tau_base = 1.10;
        end
        % Refine with boost pressure: higher boost -> smaller turbine -> faster spool
        % Correction bounded to +-20%
        if ~isnan(Boost_Pressure_bar) && Boost_Pressure_bar > 0
            boost_corr = 1.0 / (1.0 + 0.15 * (Boost_Pressure_bar - 1.0));
            boost_corr = max(0.80, min(1.20, boost_corr));
            Turbo_Lag_tau_s = tau_base * boost_corr;
        else
            Turbo_Lag_tau_s = tau_base;
        end

    otherwise
        use_turbo_model = 0;
        Turbo_Lag_tau_s = 0.0;
end

%% --- Build relLoadMax_CUR using n_ICE_plateau_start from ComponentParams ---
% Scales the RPM axis of the boost-onset curve to match this engine's
% plateau start RPM (= full-boost RPM), computed analytically by computeICEMap.
if use_turbo_model && ~isnan(n_ICE_plateau_start)
    rpm_scale = n_ICE_plateau_start / n_plateau_ref;  % ratio vs Prince engine

    % Prince engine base curve breakpoints (RPM) and values (0-1)
    rl_max_rpm_base = [500,    1000,   1250,   1500,   1750,  2000,  6000];
    rl_max_val_base = [0.5063, 0.6519, 0.7384, 0.8228, 1.0,   1.0,   1.0];

    Ice_relLoadMax_CUR_n   = max(rl_max_rpm_base * rpm_scale, 100);
    Ice_relLoadMax_CUR_val = rl_max_val_base;
else
    % Fallback: flat 1.0 (no RPM-dependent ceiling applied)
    Ice_relLoadMax_CUR_n   = [500, 6000];
    Ice_relLoadMax_CUR_val = [1.0,  1.0];
end

%% --- Scale derfacLoadIncrease MAP ---
if use_turbo_model
    scale_factor = tau_ref / Turbo_Lag_tau_s;
    Ice_derfacLoadIncrease_MAP = Ice_derfacLoadIncrease_base * scale_factor;
    Ice_derfacLoadDecrease_MAP = Ice_derfacLoadDecrease_base;
    fprintf('[setup_turbo] RUN_ID %d: %-12s Disp=%4.0fcc Boost=%.1fbar n_plat=%4.0frpm tau=%.2fs scale=%.3f\n', ...
        runID, Induction_Type, Displacement_cc, Boost_Pressure_bar, ...
        n_ICE_plateau_start, Turbo_Lag_tau_s, scale_factor);
else
    Ice_derfacLoadIncrease_MAP = Ice_derfacLoadIncrease_base;
    Ice_derfacLoadDecrease_MAP = Ice_derfacLoadDecrease_base;
    fprintf('[setup_turbo] RUN_ID %d: NA — turbo BYPASSED\n', runID);
end
