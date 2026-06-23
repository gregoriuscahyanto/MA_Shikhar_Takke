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
        a2_ICE_shape    = 0.000020;  % Parabolic shape
        a1_ICE_shape    = 0.32;      % Parabolic shape

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
            a2       = obj.a2_ICE_shape;
            a1       = obj.a1_ICE_shape;
            
            % Offset so parabola passes through (n_idle, M_idle)
            a0 = M_idle - (a2 * n_idle^2) - (a1 * n_idle);
            
            % Where parabola hits M_max limiter
            p = [a2, a1, (a0 - M_max)];
            roots_n = roots(p);
            n_plateau_start = min(roots_n(imag(roots_n) == 0 & roots_n > n_idle));
            
            % Where power hyperbola hits M_max limiter
            n_plateau_end = (P_max_kW * obj.CONV_CONST) / M_max;
            
            obj.n_ICE_plateau_start = n_plateau_start;
            obj.n_ICE_plateau_end   = n_plateau_end;
            
            % Generate final torque curve
            speed_vec  = linspace(n_idle, n_max, 500);
            torque_vec = zeros(size(speed_vec));
            for i = 1:length(speed_vec)
                n = speed_vec(i);
                if n < n_plateau_start
                    torque_vec(i) = a2*n^2 + a1*n + a0;            % parabola
                elseif n < n_plateau_end
                    torque_vec(i) = M_max;                          % plateau
                else
                    torque_vec(i) = (P_max_kW * obj.CONV_CONST)/n;  % hyperbola
                end
            end
            
            obj.speed_breakpoints_ICE = speed_vec;
            obj.torque_values_ICE     = torque_vec;
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
