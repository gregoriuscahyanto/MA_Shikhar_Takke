function [SKO_WHEEL_TYP_CHAL, SKO_STREET_CHAL, cw] = VehicleParamSelector(cp, veh)
% VehicleParamSelector - Per-run tire type, road class and drag coefficient.
%
% V15_CONSERVATIVE:
%   - Fixes the real bug from the EV test: Pwr_EV_max_kW is now included.
%   - Keeps the old/conservative tire thresholds so ICE/Hybrid behavior does
%     not change unnecessarily.
%   - Does NOT assign tire class 4 automatically. In the current SLX this made
%     some high-performance ICE cases worse and reduced the 52-run pass rate.
%
% Outputs:
%   SKO_WHEEL_TYP_CHAL: 1=Standard, 2=Sport, 3=Performance, 4=Spezialreifen
%   SKO_STREET_CHAL:    road/surface selector used by the Simulink model
%   cw:                 drag coefficient [-]

    %% --- Robust readout from cp / veh ---
    P_ICE = max(getPropOrDefaultLocal(cp, 'Pwr_ICE_max_kW', 0), 0);
    P_P0  = max(getPropOrDefaultLocal(cp, 'Pwr_P0_max_kW', 0), 0);
    P_P2  = max(getPropOrDefaultLocal(cp, 'Pwr_P2_max_kW', 0), 0);
    P_P3  = max(getPropOrDefaultLocal(cp, 'Pwr_P3_max_kW', 0), 0);
    P_P4  = max(getPropOrDefaultLocal(cp, 'Pwr_P4_max_kW', 0), 0);
    P_EV  = max(getPropOrDefaultLocal(cp, 'Pwr_EV_max_kW', 0), 0);

    m_curb = max(getPropOrDefaultLocal(veh, 'm_curb', 1500), 1);
    EV     = round(getPropOrDefaultLocal(veh, 'EV', 0));
    Hy     = round(getPropOrDefaultLocal(veh, 'Hy', 0));
    AWD    = round(getPropOrDefaultLocal(veh, 'AWD', 0));
    A_front_cfg = getPropOrDefaultLocal(veh, 'A_front', NaN);

    %% --- System power estimate for tire selection ---
    % Main correction: pure EVs must include Pwr_EV_max_kW. The previous file
    % only used ICE/P0/P2/P3/P4, so many strong EVs stayed on tire class 1.
    if EV == 1 && Hy == 0
        P_sys = P_EV + P_P4;
    else
        % Keep old behavior for ICE/Hybrid as much as possible. P0 is included
        % here for compatibility, but the conservative thresholds below prevent
        % most MHEV rows from being over-upgraded.
        P_sys = P_ICE + P_P0 + P_P2 + P_P3 + P_P4;
    end

    if ~isfinite(P_sys) || P_sys <= 0
        P_sys = max([P_ICE, P_EV, P_P0, P_P2, P_P3, P_P4, 0]);
    end

    %% --- Specific power ---
    sp = P_sys / m_curb;        % kW/kg
    p2w_kW_per_t = sp * 1000;  % kW/t

    %% --- Conservative tire type selection ---
    % Use the old effective thresholds:
    %   <150 kW/t: standard tire
    %   150-220 kW/t: sport tire
    %   >=220 kW/t: performance tire
    % Do not use tire class 4 automatically until the SLX tire/street model is
    % separately validated for this class.
    if sp < 0.15
        SKO_WHEEL_TYP_CHAL = 1;
        SKO_STREET_CHAL = 2;
    elseif sp < 0.22
        SKO_WHEEL_TYP_CHAL = 2;
        SKO_STREET_CHAL = 2;
    else
        SKO_WHEEL_TYP_CHAL = 3;
        SKO_STREET_CHAL = 1;
    end

    % Safety net: high-power AWD EV should never remain tire class 1 if the
    % power distribution fields are incomplete. Keep the upgrade conservative.
    if EV == 1 && AWD == 1 && p2w_kW_per_t >= 220
        SKO_WHEEL_TYP_CHAL = max(SKO_WHEEL_TYP_CHAL, 3);
        SKO_STREET_CHAL = 1;
    end

    %% --- Drag coefficient ---
    if sp < 0.08
        cw = 0.34;
    elseif sp < 0.15
        cw = 0.32;
    elseif sp < 0.22
        cw = 0.30;
    else
        cw = 0.28;
    end

    %% --- Frontal area fallback for Simulink base workspace ---
    if isfinite(A_front_cfg) && A_front_cfg > 1.0
        A_front = A_front_cfg;
    else
        if m_curb < 1200
            A_front = 2.05;
        elseif m_curb < 1500
            A_front = 2.20;
        elseif m_curb < 1700
            A_front = 2.35;
        else
            A_front = 2.55;
        end
        if AWD == 1
            A_front = A_front + 0.10;
        end
    end

    %% --- Write to base workspace so Simulink can read directly ---
    assignin('base', 'SKO_WHEEL_TYP_CHAL', SKO_WHEEL_TYP_CHAL);
    assignin('base', 'SKO_STREET_CHAL', SKO_STREET_CHAL);
    assignin('base', 'cw', cw);
    assignin('base', 'A_front', A_front);
    assignin('base', 'P_sys_tire_kW', P_sys);
    assignin('base', 'P2W_tire_kW_per_t', p2w_kW_per_t);

    %% --- Console log ---
    mu_map = [1.0, 1.1, 1.2, 1.3];
    tireIdx = min(max(round(SKO_WHEEL_TYP_CHAL), 1), numel(mu_map));
    fprintf('  [VehicleParamSelector V15] Tire=%d (mu=%.1f) | Street=%d | cw=%.2f | A=%.2f m2 | P_sys=%.0f kW | P/m=%.1f kW/t\n', ...
        SKO_WHEEL_TYP_CHAL, mu_map(tireIdx), SKO_STREET_CHAL, cw, A_front, P_sys, p2w_kW_per_t);
end

function val = getPropOrDefaultLocal(obj, propName, defaultVal)
    val = defaultVal;
    try
        if isstruct(obj)
            if isfield(obj, propName)
                tmp = obj.(propName);
            else
                return;
            end
        else
            if isprop(obj, propName)
                tmp = obj.(propName);
            else
                return;
            end
        end

        if isstring(tmp) || ischar(tmp)
            tmp = str2double(string(tmp));
        end

        if isnumeric(tmp) || islogical(tmp)
            tmp = double(tmp);
            if isscalar(tmp) && isfinite(tmp)
                val = tmp;
            end
        end
    catch
        val = defaultVal;
    end
end
