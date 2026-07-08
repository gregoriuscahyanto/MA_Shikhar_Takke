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

        % Diagnostics for automatic ICE redline repair.
        % n_ICE_max is used by the vehicle model as redline / shift rpm.
        % Some input rows contain the nominal-power rpm instead. If the
        % generated map cannot reach Pwr_ICE_max_kW, computeICEMap raises
        % n_ICE_max and recomputes the map within plausible bounds.
        n_ICE_max_input             double = NaN;
        n_ICE_max_repaired          double = NaN;
        ICE_map_Pmax_initial_kW     double = NaN;
        ICE_map_Pmax_final_kW       double = NaN;
        ICE_redline_repair_active   logical = false;
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

            % Reset diagnostics for this map calculation.
            obj.n_ICE_max_input           = n_max;
            obj.n_ICE_max_repaired        = n_max;
            obj.ICE_map_Pmax_initial_kW   = NaN;
            obj.ICE_map_Pmax_final_kW     = NaN;
            obj.ICE_redline_repair_active = false;

            % Defensive checks keep old/partial DoE rows from creating invalid maps.
            if ~isfinite(n_idle) || ~isfinite(n_max) || ~isfinite(M_max) || ~isfinite(P_max_kW) || ...
                    n_idle <= 0 || n_max <= n_idle || M_max <= 0 || P_max_kW <= 0
                obj.speed_breakpoints_ICE = [];
                obj.torque_values_ICE     = [];
                obj.n_ICE_plateau_start   = NaN;
                obj.n_ICE_plateau_end     = NaN;
                return;
            end

            mapType = lower(strtrim(string(obj.ICE_map_type)));

            % First calculation with the input n_ICE_max.
            speed_vec = linspace(n_idle, n_max, 500);
            [torque_vec, n_marker_1, n_marker_2] = obj.computeSelectedICEMap( ...
                speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, mapType);

            P_map_max = obj.getMapMaxPower_kW(speed_vec, torque_vec);
            obj.ICE_map_Pmax_initial_kW = P_map_max;

            % If the map cannot reach nominal power, n_ICE_max is probably
            % a nominal-power rpm instead of the real redline. Raise it and
            % recompute until the map reaches nominal power or a plausible
            % type-specific rpm cap is reached.
            if isfinite(P_map_max) && P_map_max < 0.98 * P_max_kW
                [rpmFloor, rpmCap] = obj.getICERedlineRepairBounds(mapType);
                n_req_from_torque = (P_max_kW * obj.CONV_CONST) / max(M_max, 1);

                n_candidate = max([n_max, rpmFloor, 1.08 * n_req_from_torque]);
                n_candidate = min(n_candidate, rpmCap);

                n_try = n_candidate;
                for it = 1:8
                    speed_try = linspace(n_idle, n_try, 500);
                    [torque_try, n_m1_try, n_m2_try] = obj.computeSelectedICEMap( ...
                        speed_try, n_idle, M_idle, M_max, P_max_kW, n_try, mapType);

                    P_try = obj.getMapMaxPower_kW(speed_try, torque_try);
                    if isfinite(P_try) && P_try >= 0.98 * P_max_kW
                        speed_vec = speed_try;
                        torque_vec = torque_try;
                        n_marker_1 = n_m1_try;
                        n_marker_2 = n_m2_try;
                        n_max = n_try;
                        P_map_max = P_try;
                        break;
                    end

                    % Keep best available try even if the cap is reached.
                    if isfinite(P_try) && (~isfinite(P_map_max) || P_try > P_map_max)
                        speed_vec = speed_try;
                        torque_vec = torque_try;
                        n_marker_1 = n_m1_try;
                        n_marker_2 = n_m2_try;
                        n_max = n_try;
                        P_map_max = P_try;
                    end

                    if n_try >= rpmCap - 1
                        break;
                    end
                    n_try = min(rpmCap, max(n_try + 300, 1.07 * n_try));
                end
            end

            % Final safety: if plausible redline repair alone was not enough,
            % raise the high-rpm part of the shaped map up to the nominal-power
            % envelope at one physically feasible operating region. This keeps
            % Pwr_ICE_max_kW as an actually reachable nominal power, not only
            % as a ceiling.
            if isfinite(P_map_max) && P_map_max < 0.98 * P_max_kW
                [torque_vec, P_map_max] = obj.enforceNominalPowerSupport( ...
                    speed_vec, torque_vec, M_max, P_max_kW, n_max, mapType);
            end

            obj.n_ICE_max = n_max;
            obj.n_ICE_max_repaired = n_max;
            obj.ICE_map_Pmax_final_kW = P_map_max;
            obj.ICE_redline_repair_active = abs(obj.n_ICE_max_repaired - obj.n_ICE_max_input) > 1;

            obj.n_ICE_plateau_start = n_marker_1;
            obj.n_ICE_plateau_end   = n_marker_2;
            obj.speed_breakpoints_ICE = speed_vec;
            obj.torque_values_ICE     = torque_vec;
        end

        function [torque_vec, n_marker_1, n_marker_2] = computeSelectedICEMap(obj, speed_vec, n_idle, M_idle, M_max, P_max_kW, n_max, mapType)
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

        function Pmax_kW = getMapMaxPower_kW(obj, rpm_vec, tq_vec) %#ok<INUSL>
            Pmax_kW = NaN;
            try
                rpm_vec = double(rpm_vec(:));
                tq_vec  = double(tq_vec(:));
                n = min(numel(rpm_vec), numel(tq_vec));
                if n < 1
                    return;
                end
                P_kW = rpm_vec(1:n) .* tq_vec(1:n) ./ obj.CONV_CONST;
                Pmax_kW = max(P_kW);
            catch
                Pmax_kW = NaN;
            end
        end

        function [torque_vec, Pmax_kW] = enforceNominalPowerSupport(obj, rpm_vec, torque_vec, M_max, P_max_kW, n_max, mapType)
            % If the shape is too conservative, make nominal power reachable
            % in a narrow high-rpm band while respecting both max torque and
            % the max-power envelope.
            Pmax_kW = obj.getMapMaxPower_kW(rpm_vec, torque_vec);

            if ~isfinite(P_max_kW) || ~isfinite(M_max) || ~isfinite(n_max) || ...
                    P_max_kW <= 0 || M_max <= 0 || n_max <= 0
                return;
            end

            n_req = (P_max_kW * obj.CONV_CONST) / M_max;
            if ~isfinite(n_req) || n_req >= 0.98 * n_max
                return;
            end

            rpm_vec = double(rpm_vec(:)).';
            torque_vec = double(torque_vec(:)).';

            powerFrac = obj.getNominalPowerRpmFraction(mapType);
            n_target = max(1.03 * n_req, powerFrac * n_max);
            n_target = min(n_target, 0.96 * n_max);

            if n_target <= n_req
                n_target = min(0.96 * n_max, 1.03 * n_req);
            end

            bandWidth = max(250, 0.075 * n_max);
            band = abs(rpm_vec - n_target) <= bandWidth & rpm_vec >= n_req & rpm_vec <= n_max;

            if ~any(band)
                [~, idxNearest] = min(abs(rpm_vec - n_target));
                band(idxNearest) = true;
            end

            targetTorque = (P_max_kW * obj.CONV_CONST) ./ max(rpm_vec, 1);
            torque_vec(band) = max(torque_vec(band), targetTorque(band));

            torque_vec = min(torque_vec, M_max);
            torque_vec = min(torque_vec, targetTorque);
            torque_vec = max(torque_vec, 0);

            Pmax_kW = obj.getMapMaxPower_kW(rpm_vec, torque_vec);
        end

        function powerFrac = getNominalPowerRpmFraction(obj, mapType) %#ok<INUSL>
            typeTxt = lower(strtrim(string(mapType)));

            if contains(typeTxt, "diesel")
                powerFrac = 0.82;
            elseif contains(typeTxt, "high_rpm") || contains(typeTxt, "highrev") || contains(typeTxt, "high_rev")
                powerFrac = 0.90;
            elseif contains(typeTxt, "small_na") || contains(typeTxt, "large_na") || contains(typeTxt, "naturally") || contains(typeTxt, "saugmotor")
                powerFrac = 0.86;
            elseif contains(typeTxt, "performance") || contains(typeTxt, "sport_turbo")
                powerFrac = 0.82;
            else
                % Normal turbo petrol / petrol hybrid.
                powerFrac = 0.80;
            end
        end

        function [rpmFloor, rpmCap] = getICERedlineRepairBounds(obj, mapType)
            % Bounds are intentionally conservative. They only define where
            % automatic redline repair may search if the map cannot reach
            % nominal power.
            fuelTxt = lower(strtrim(string(obj.ICE_fuel_type)));
            typeTxt = lower(strtrim(string(mapType)));
            allTxt = fuelTxt + " " + typeTxt;

            isDiesel = contains(allTxt, "diesel") || contains(allTxt, "tdi") || ...
                       contains(allTxt, "cdi") || contains(allTxt, "dci") || ...
                       contains(allTxt, "hdi") || contains(allTxt, "crdi");
            isHighRpmNA = contains(allTxt, "high_rpm") || contains(allTxt, "highrev") || ...
                          contains(allTxt, "high_rev");
            isNA = contains(allTxt, "_na") || contains(allTxt, " na") || ...
                   contains(allTxt, "naturally") || contains(allTxt, "saugmotor");
            isPerformanceTurbo = contains(allTxt, "performance") || contains(allTxt, "sport_turbo");

            if isDiesel
                rpmFloor = 4800;
                rpmCap   = 5600;
            elseif isHighRpmNA
                rpmFloor = 7000;
                rpmCap   = 9000;
            elseif isNA
                rpmFloor = 6500;
                rpmCap   = 8000;
            elseif isPerformanceTurbo
                rpmFloor = 6500;
                rpmCap   = 7800;
            else
                % Normal turbo petrol / petrol hybrid fallback.
                rpmFloor = 6500;
                rpmCap   = 7500;
            end
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
