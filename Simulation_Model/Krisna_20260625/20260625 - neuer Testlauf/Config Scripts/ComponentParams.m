classdef ComponentParams 
    % All engine and motor parameter calculations + torque-speed maps
    
    properties (Constant)
        % Common conversion constant
        CONV_CONST = 9549.3;  % (kW * 9549.3) / rpm = Nm
    end
    
    %% ---- ICE user parameters ----
    properties
        n_ICE_idle      = 1000;      % Idle speed (rpm)
        tq_ICE_idle     = 100;       % Torque at idle (Nm)
        tq_ICE_max      = 650;       % Max torque limiter (Nm)
        Pwr_ICE_max_kW  = 405;   % Max power (kW)
        n_ICE_max       = 7000;      % Max speed (rpm)

        % ICE map type selected in DoE_main.m.
        % 'turbo' keeps an early torque plateau, 'na' gives a later
        % naturally-aspirated torque build-up.
        ICE_map_type    = 'turbo';
        ICE_fuel_type   = '';

        a2_ICE_shape    = 0.000020;  % Legacy parabolic shape, kept for compatibility
        a1_ICE_shape    = 0.32;      % Legacy parabolic shape, kept for compatibility

        % n_ICE_idle      = 1000;      % Idle speed (rpm)
        % tq_ICE_idle     = 350;       % Torque at idle (Nm)
        % tq_ICE_max      = 850;       % Max torque limiter (Nm)
        % Pwr_ICE_max_kW  = 459.562;   % Max power (kW)
        % n_ICE_max       = 7000;      % Max speed (rpm)
        % a2_ICE_shape    = 0.000020;  % Parabolic shape
        % a1_ICE_shape    = 0.32;      % Parabolic shape

        % ICE outputs
        speed_breakpoints_ICE   double = [];
        torque_values_ICE       double = [];
        n_ICE_plateau_start     double = NaN;
        n_ICE_plateau_end       double = NaN;
    end
    
    %% ---- P0 user parameters ----
    properties
        tq_P0_max               = 220;     % Max torque (Nm)
        Pwr_P0_max_kW           = 160;     % Max power (kW)
        n_P0_max                = 10000;   % Max speed (rpm)
        Pwr_P0_nmax_red_perc    = 0.04;    % Power reduction at n_max
        
        speed_breakpoints_P0    double = [];
        torque_values_P0        double = [];
    end
    
    %% ---- P2 user parameters ----
    properties
        tq_P2_max               = 340;     % Max torque (Nm)
        Pwr_P2_max_kW           = 220;     % Max power (kW)
        n_P2_max                = 18000;   % Max speed (rpm)
        Pwr_P2_nmax_red_perc    = 0.04;
        
        speed_breakpoints_P2    double = [];
        torque_values_P2        double = [];
    end
    
    %% ---- P3 user parameters ----
    properties
        tq_P3_max               = 340;     % Max torque (Nm)
        Pwr_P3_max_kW           = 220;     % Max power (kW)
        n_P3_max                = 18000;   % Max speed (rpm)
        Pwr_P3_nmax_red_perc    = 0.04;
        
        speed_breakpoints_P3    double = [];
        torque_values_P3        double = [];
    end
    
    %% ---- P4 / EV secondary axle user parameters ----
    properties
        tq_P4_max               = 340;     % Max torque (Nm)
        Pwr_P4_max_kW           = 220;     % Max power (kW)
        n_P4_max                = 18000;   % Max speed (rpm)
        Pwr_P4_nmax_red_perc    = 0.04;
               
        speed_breakpoints_P4    double = [];
        torque_values_P4        double = [];
    end
    
    %% ---- EV main motor user parameters ----
    properties
        tq_EV_max               = 340;     % Max torque (Nm)
        Pwr_EV_max_kW           = 220;     % Max power (kW)
        n_EV_max                = 18000;   % Max speed (rpm)
        Pwr_EV_nmax_red_perc    = 0.04;
        
        speed_breakpoints_EV    double = [];
        torque_values_EV        double = [];
    end
    
    methods
        %% ===== ICE torque-speed map =====
        function obj = computeICEMap(obj, VM, Hy)
            % Only compute if ICE is present (VM or Hybrid)
            if ~(VM == 1 || Hy == 1), return; end

            n_idle   = obj.n_ICE_idle;
            M_idle   = obj.tq_ICE_idle;
            M_max    = obj.tq_ICE_max;
            P_max_kW = obj.Pwr_ICE_max_kW;
            n_max    = obj.n_ICE_max;

            % Defensive checks keep old/partial DoE rows from creating invalid maps.
            if ~isfinite(n_idle) || ~isfinite(n_max) || ~isfinite(M_max) || ~isfinite(P_max_kW) || ...
                    n_idle <= 0 || n_max <= n_idle || M_max <= 0 || P_max_kW <= 0
                obj.speed_breakpoints_ICE = [];
                obj.torque_values_ICE     = [];
                obj.n_ICE_plateau_start   = NaN;
                obj.n_ICE_plateau_end     = NaN;
                return;
            end

            speed_vec = linspace(n_idle, n_max, 500);
            mapType = lower(strtrim(string(obj.ICE_map_type)));

            if any(mapType == ["na", "naturally_aspirated", "naturally aspirated", "saugmotor"])
                [torque_vec, n_plateau_start, n_plateau_end] = obj.computeNaturallyAspiratedICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            else
                [torque_vec, n_plateau_start, n_plateau_end] = obj.computeTurboICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            end

            obj.n_ICE_plateau_start = n_plateau_start;
            obj.n_ICE_plateau_end   = n_plateau_end;
            obj.speed_breakpoints_ICE = speed_vec;
            obj.torque_values_ICE     = torque_vec;
        end

        %% ===== Turbo / charged ICE map =====
        function [torque_vec, n_plateau_start, n_plateau_end] = computeTurboICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Turbocharged engines usually reach high torque early and can hold
            % an approximately flat torque plateau before the constant-power area.
            if ~isfinite(M_idle) || M_idle <= 0
                M_idle = 0.45 * M_max;
            end
            M_idle = min(max(M_idle, 0.25 * M_max), 0.75 * M_max);

            n_plateau_start = max(n_idle + 300, 0.25 * n_max);
            n_plateau_start = min(n_plateau_start, 2200);
            n_plateau_start = min(max(n_plateau_start, n_idle + 200), 0.55 * n_max);

            n_plateau_end = (P_max_kW * obj.CONV_CONST) / max(M_max, eps);
            n_plateau_end = max(n_plateau_end, n_plateau_start + 500);
            n_plateau_end = min(n_plateau_end, 0.88 * n_max);

            torque_vec = zeros(size(speed_vec));
            for i = 1:length(speed_vec)
                n = speed_vec(i);
                if n < n_plateau_start
                    x = (n - n_idle) / max(n_plateau_start - n_idle, 1);
                    x = min(max(x, 0), 1);
                    torque_vec(i) = M_idle + (M_max - M_idle) * sin(x * pi/2);
                elseif n < n_plateau_end
                    torque_vec(i) = M_max;
                else
                    torque_vec(i) = (P_max_kW * obj.CONV_CONST) / n;
                end
            end

            torque_vec = min(torque_vec, M_max);
            torque_vec = min(torque_vec, (P_max_kW * obj.CONV_CONST) ./ speed_vec);
            torque_vec = max(torque_vec, 0);
        end

        %% ===== Naturally aspirated ICE map =====
        function [torque_vec, n_tq_peak, n_pwr_peak] = computeNaturallyAspiratedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Naturally aspirated engines should not receive the early turbo-like
            % torque plateau. The torque build-up is delayed and the peak torque
            % is placed in the mid/high rpm range. This mainly slows old/small NA
            % ICE vehicles in 0-100 without affecting EVs.
            if ~isfinite(M_idle) || M_idle <= 0
                M_idle = 0.30 * M_max;
            end
            M_idle = min(max(M_idle, 0.18 * M_max), 0.45 * M_max);

            % Estimated peak torque speed for NA engines. Without explicit
            % n_ICE_tq_max from the input converter, this is a robust fallback.
            n_tq_peak = 0.62 * n_max;
            n_tq_peak = max(n_tq_peak, n_idle + 1800);
            n_tq_peak = min(n_tq_peak, 0.78 * n_max);

            % Estimate power-peak speed from power and torque. Keep it above
            % torque peak and below n_max to obtain a plausible high-rpm tail.
            n_pwr_peak = (P_max_kW * obj.CONV_CONST) / max(0.92 * M_max, eps);
            n_pwr_peak = max(n_pwr_peak, n_tq_peak + 500);
            n_pwr_peak = min(n_pwr_peak, 0.96 * n_max);

            tq_at_pwr_peak = (P_max_kW * obj.CONV_CONST) / max(n_pwr_peak, 1);
            tq_at_pwr_peak = min(max(tq_at_pwr_peak, 0.65 * M_max), M_max);

            tq_at_nmax = 0.88 * (P_max_kW * obj.CONV_CONST) / max(n_max, 1);
            tq_at_nmax = min(max(tq_at_nmax, 0.45 * M_max), 0.95 * M_max);

            n_bp = [ ...
                n_idle, ...
                max(n_idle + 600, 0.28 * n_max), ...
                max(n_idle + 1300, 0.42 * n_max), ...
                n_tq_peak, ...
                n_pwr_peak, ...
                n_max];

            tq_bp = [ ...
                M_idle, ...
                0.48 * M_max, ...
                0.72 * M_max, ...
                M_max, ...
                tq_at_pwr_peak, ...
                tq_at_nmax];

            % Ensure strictly usable breakpoints for interp1.
            [n_bp, order] = sort(n_bp);
            tq_bp = tq_bp(order);
            [n_bp, ia] = unique(n_bp, 'stable');
            tq_bp = tq_bp(ia);

            if numel(n_bp) < 2
                torque_vec = min(M_max, (P_max_kW * obj.CONV_CONST) ./ speed_vec);
            else
                torque_vec = interp1(n_bp, tq_bp, speed_vec, 'pchip', 'extrap');
            end

            torque_vec = min(torque_vec, M_max);
            torque_vec = min(torque_vec, (P_max_kW * obj.CONV_CONST) ./ speed_vec);
            torque_vec = max(torque_vec, 0);
        end

        %% ===== Generic helper: constant-torque + field-weakening EM =====
        function [speed_vec, torque_vec] = emMap(obj, tq_max, P_max_kW, n_max, P_red_perc)
            n_corner    = (P_max_kW * obj.CONV_CONST) / tq_max;
            P_at_nmax   = P_max_kW * (1 - P_red_perc);
            tq_at_nmax  = (P_at_nmax * obj.CONV_CONST) / n_max; %#ok<NASGU> (kept for clarity)
            
            speed_vec  = linspace(0, n_max, 500);
            torque_vec = zeros(size(speed_vec));
            
            for i = 1:length(speed_vec)
                n = speed_vec(i);
                if n < n_corner
                    torque_vec(i) = tq_max; %#ok<*NBRAK> (MATLAB uses (), keep as () in your editor)
                else
                    if (n_max - n_corner) > 0
                        current_power_kW = P_max_kW - ...
                           (P_max_kW - P_at_nmax) * ((n - n_corner) / (n_max - n_corner));
                    else
                        current_power_kW = P_max_kW;
                    end
                    torque_vec(i) = (current_power_kW * obj.CONV_CONST) / n;
                end
            end
        end
        
        %% ===== P0 map =====
        function obj = computeP0Map(obj, P0_flag)
            if P0_flag ~= 1, return; end
            
            [speed_vec, torque_vec] = obj.emMap( ...
                obj.tq_P0_max, obj.Pwr_P0_max_kW, obj.n_P0_max, obj.Pwr_P0_nmax_red_perc);
            
            obj.speed_breakpoints_P0 = speed_vec;
            obj.torque_values_P0     = torque_vec;
        end
        
        %% ===== P2 map =====
        function obj = computeP2Map(obj, P2_flag)
            if P2_flag ~= 1, return; end
            
            [speed_vec, torque_vec] = obj.emMap( ...
                obj.tq_P2_max, obj.Pwr_P2_max_kW, obj.n_P2_max, obj.Pwr_P2_nmax_red_perc);
            
            obj.speed_breakpoints_P2 = speed_vec;
            obj.torque_values_P2     = torque_vec;
        end
        
        %% ===== P3 map =====
        function obj = computeP3Map(obj, P3_flag)
            if P3_flag ~= 1, return; end
            
            [speed_vec, torque_vec] = obj.emMap( ...
                obj.tq_P3_max, obj.Pwr_P3_max_kW, obj.n_P3_max, obj.Pwr_P3_nmax_red_perc);
            
            obj.speed_breakpoints_P3 = speed_vec;
            obj.torque_values_P3     = torque_vec;
        end
        
        %% ===== P4 / EV secondary axle map =====
        function obj = computeP4Map(obj, P4_flag, E2_flag, P4_DM_flag, E3_flag, E4_flag)
            % Compute if any P4 / EV secondary axle machine is present
            % if ~(P4_flag == 1)
            if ~(P4_flag == 1 || E2_flag == 1 || P4_DM_flag == 1 || E3_flag == 1 || E4_flag == 1)
                return;
            end

            [speed_vec, torque_vec] = obj.emMap( ...
                obj.tq_P4_max, obj.Pwr_P4_max_kW, obj.n_P4_max, obj.Pwr_P4_nmax_red_perc);
            
            obj.speed_breakpoints_P4 = speed_vec;
            obj.torque_values_P4     = torque_vec;
        end
        
        %% ===== EV main motor map =====
        function obj = computeEVMap(obj, EV_flag)
            if EV_flag ~= 1, return; end
            
            [speed_vec, torque_vec] = obj.emMap( ...
                obj.tq_EV_max, obj.Pwr_EV_max_kW, obj.n_EV_max, obj.Pwr_EV_nmax_red_perc);
            
            obj.speed_breakpoints_EV = speed_vec;
            obj.torque_values_EV     = torque_vec;
        end
    end
end
