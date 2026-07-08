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
        Pwr_ICE_max_kW  = 405;       % Max power (kW)
        n_ICE_max       = 7000;      % Max speed (rpm)

        % ICE map type selected in DoE_main.m.
        % Supported values:
        %   diesel_turbo
        %   small_na, large_na, high_rpm_na
        %   small_turbo_petrol, turbo_petrol, performance_turbo
        % Compatibility aliases: 'turbo' -> turbo_petrol, 'na' -> large_na.
        ICE_map_type    = 'turbo_petrol';
        ICE_fuel_type   = '';

        a2_ICE_shape    = 0.000020;  % Legacy parabolic shape, kept for compatibility
        a1_ICE_shape    = 0.32;      % Legacy parabolic shape, kept for compatibility

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

            if any(mapType == ["diesel_turbo", "turbo_diesel", "diesel"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computeDieselTurboICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            elseif any(mapType == ["small_na", "na_small", "old_small_na"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computeSmallNaturallyAspiratedICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            elseif any(mapType == ["high_rpm_na", "na_high_rpm", "highrev_na", "high_rev_na"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computeHighRpmNaturallyAspiratedICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            elseif any(mapType == ["large_na", "na", "naturally_aspirated", "naturally aspirated", "saugmotor"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computeLargeNaturallyAspiratedICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            elseif any(mapType == ["small_turbo_petrol", "small_turbo", "kompressor_small"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computeSmallTurboPetrolICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            elseif any(mapType == ["performance_turbo", "turbo_performance", "sport_turbo"])
                [torque_vec, n_marker_1, n_marker_2] = obj.computePerformanceTurboICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            else
                % Compatibility fallback: old 'turbo' rows use normal turbo petrol.
                [torque_vec, n_marker_1, n_marker_2] = obj.computeTurboPetrolICEMap( ...
                    speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
            end

            obj.n_ICE_plateau_start = n_marker_1;
            obj.n_ICE_plateau_end   = n_marker_2;
            obj.speed_breakpoints_ICE = speed_vec;
            obj.torque_values_ICE     = torque_vec;
        end

        %% ===== More specific ICE map families =====
        function [torque_vec, n_tq_start, n_tq_end] = computeDieselTurboICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Early torque, but early high-rpm fall-off.
            rpmFrac = [0.00 0.20 0.32 0.55 0.75 1.00];
            tqFrac  = [0.65 0.95 1.00 1.00 0.75 0.45];
            [torque_vec, n_tq_start, n_tq_end] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_peak, n_pwr_peak] = computeSmallNaturallyAspiratedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Small NA: weak low-end torque, peak torque late.
            rpmFrac = [0.00 0.30 0.45 0.65 0.85 1.00];
            tqFrac  = [0.18 0.40 0.65 1.00 0.92 0.75];
            [torque_vec, n_tq_peak, n_pwr_peak] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_peak, n_pwr_peak] = computeLargeNaturallyAspiratedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Large NA: better mid-range than small NA, still no early turbo plateau.
            rpmFrac = [0.00 0.28 0.45 0.62 0.85 1.00];
            tqFrac  = [0.28 0.55 0.78 1.00 0.93 0.78];
            [torque_vec, n_tq_peak, n_pwr_peak] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_peak, n_pwr_peak] = computeHighRpmNaturallyAspiratedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % High-rpm NA: e.g. Porsche/Ferrari/Lamborghini style engines.
            % Intentionally weaker below mid-rpm, strong at high rpm.
            rpmFrac = [0.00 0.35 0.55 0.75 0.92 1.00];
            tqFrac  = [0.18 0.42 0.68 1.00 0.95 0.82];
            [torque_vec, n_tq_peak, n_pwr_peak] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_start, n_tq_end] = computeSmallTurboPetrolICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Small turbo petrol: some low-rpm weakness / boost build-up.
            rpmFrac = [0.00 0.22 0.34 0.60 0.82 1.00];
            tqFrac  = [0.25 0.55 1.00 1.00 0.82 0.65];
            [torque_vec, n_tq_start, n_tq_end] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_start, n_tq_end] = computeTurboPetrolICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Normal turbo petrol: early plateau, moderate high-rpm fall-off.
            rpmFrac = [0.00 0.22 0.30 0.62 0.85 1.00];
            tqFrac  = [0.40 0.85 1.00 1.00 0.82 0.68];
            [torque_vec, n_tq_start, n_tq_end] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_tq_start, n_tq_end] = computePerformanceTurboICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            % Performance turbo: very strong low/mid torque, better high-rpm support.
            rpmFrac = [0.00 0.20 0.28 0.70 0.88 1.00];
            tqFrac  = [0.50 0.95 1.00 1.00 0.88 0.75];
            [torque_vec, n_tq_start, n_tq_end] = obj.computeShapedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac);
        end

        function [torque_vec, n_marker_1, n_marker_2] = computeShapedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, rpmFrac, tqFrac)
            rpmFrac = double(rpmFrac(:).');
            tqFrac  = double(tqFrac(:).');
            if numel(rpmFrac) ~= numel(tqFrac) || numel(rpmFrac) < 2
                rpmFrac = [0 1];
                tqFrac = [1 1];
            end

            if ~isfinite(M_idle) || M_idle <= 0
                M_idle = tqFrac(1) * M_max;
            end
            M_idle = min(max(M_idle, 0.10 * M_max), 0.80 * M_max);

            n_bp = rpmFrac .* n_max;
            n_bp(1) = n_idle;
            n_bp(end) = n_max;
            n_bp = max(n_bp, n_idle);
            n_bp = min(n_bp, n_max);

            tq_bp = tqFrac .* M_max;
            tq_bp(1) = M_idle;
            tq_bp = min(max(tq_bp, 0), M_max);

            [n_bp, order] = sort(n_bp);
            tq_bp = tq_bp(order);
            [n_bp, ia] = unique(n_bp, 'stable');
            tq_bp = tq_bp(ia);

            if numel(n_bp) < 2
                torque_vec = min(M_max, (P_max_kW * obj.CONV_CONST) ./ max(speed_vec, 1));
            else
                torque_vec = interp1(n_bp, tq_bp, speed_vec, 'pchip', 'extrap');
            end

            % Enforce max torque and max-power envelope. The power envelope is
            % intentionally kept as a ceiling, not as a requested curve.
            torque_vec = min(torque_vec, M_max);
            torque_vec = min(torque_vec, (P_max_kW * obj.CONV_CONST) ./ max(speed_vec, 1));
            torque_vec = max(torque_vec, 0);

            % Marker outputs are used only for diagnostics. Use the region with
            % the highest requested torque before the power ceiling.
            [~, idxMax] = max(tq_bp);
            n_marker_1 = n_bp(max(1, idxMax));
            n_marker_2 = n_bp(min(numel(n_bp), max(idxMax + 1, idxMax)));
        end

        %% ===== Backward-compatible wrappers =====
        function [torque_vec, n_plateau_start, n_plateau_end] = computeTurboICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            [torque_vec, n_plateau_start, n_plateau_end] = obj.computeTurboPetrolICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
        end

        function [torque_vec, n_tq_peak, n_pwr_peak] = computeNaturallyAspiratedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max)
            [torque_vec, n_tq_peak, n_pwr_peak] = obj.computeLargeNaturallyAspiratedICEMap(speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max);
        end

        %% ===== Generic helper: constant-torque + field-weakening EM =====
        function [speed_vec, torque_vec] = emMap(obj, tq_max, P_max_kW, n_max, P_red_perc)
            if ~isfinite(tq_max) || tq_max <= 0 || ~isfinite(P_max_kW) || P_max_kW <= 0 || ~isfinite(n_max) || n_max <= 0
                speed_vec = linspace(0, max(n_max, 1), 500);
                torque_vec = zeros(size(speed_vec));
                return;
            end

            n_corner    = (P_max_kW * obj.CONV_CONST) / tq_max;
            P_at_nmax   = P_max_kW * (1 - P_red_perc);

            speed_vec  = linspace(0, n_max, 500);
            torque_vec = zeros(size(speed_vec));

            for i = 1:length(speed_vec)
                n = speed_vec(i);
                if n < n_corner
                    torque_vec(i) = tq_max;
                else
                    if (n_max - n_corner) > 0
                        current_power_kW = P_max_kW - ...
                           (P_max_kW - P_at_nmax) * ((n - n_corner) / (n_max - n_corner));
                    else
                        current_power_kW = P_max_kW;
                    end
                    torque_vec(i) = (current_power_kW * obj.CONV_CONST) / max(n, 1);
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
            % Compute if any P4 / EV secondary axle machine is present.
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
