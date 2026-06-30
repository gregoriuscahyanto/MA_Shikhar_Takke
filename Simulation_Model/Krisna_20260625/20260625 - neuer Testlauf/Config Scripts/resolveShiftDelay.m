function [shiftDelay, shiftSource, gearboxTypeNorm, powerToWeight_kW_per_t] = resolveShiftDelay(cfg)
%RESOLVESHIFTDELAY Robust shift-delay assignment for DoE simulations.
%
% Priority:
%   1) Gearbox type from web-scraped dataset, if available
%      AT  -> 0.35 s
%      MT  -> 0.60 s
%      DCT -> 0.20 s
%      CVT -> 0.05 s
%   2) Fallback from power-to-weight if gearbox type is missing/unknown
%   3) Existing cfg.shiftDelay if available
%   4) Conservative default 0.35 s
%
% Usage in DoE_main.m:
%   [gb.shiftDelay, src, gbType, p2w] = resolveShiftDelay(cfg);
%   fprintf('RunID %d shiftDelay %.3f s (%s, type=%s, p2w=%.1f kW/t)\n', ...
%       runID, gb.shiftDelay, src, gbType, p2w);

    gearboxTypeRaw = getFirstExistingField(cfg, { ...
        'Gearbox_Type', 'gearbox_type', 'GearboxType', 'gearboxType', ...
        'Transmission_Type', 'transmission_type', 'TransmissionType', 'transmissionType', ...
        'Transmission', 'transmission', 'Gearbox', 'gearbox', ...
        'Getriebeart', 'getriebeart', 'Getriebe', 'getriebe'});

    gearboxTypeNorm = normalizeText(gearboxTypeRaw);
    [delayFromType, typeClass] = delayFromGearboxType(gearboxTypeNorm);

    if ~isnan(delayFromType)
        shiftDelay = delayFromType;
        shiftSource = ['gearbox_type_' typeClass];
        powerToWeight_kW_per_t = computePowerToWeight(cfg);
        return;
    end

    powerToWeight_kW_per_t = computePowerToWeight(cfg);
    if ~isnan(powerToWeight_kW_per_t)
        shiftDelay = delayFromPowerToWeight(powerToWeight_kW_per_t, cfg);
        shiftSource = 'power_to_weight_fallback';
        return;
    end

    oldDelay = getFirstExistingField(cfg, {'shiftDelay', 'ShiftDelay', 'shift_delay'});
    oldDelay = toDoubleScalar(oldDelay);
    if ~isnan(oldDelay) && oldDelay >= 0
        shiftDelay = oldDelay;
        shiftSource = 'existing_cfg_shiftDelay';
        return;
    end

    shiftDelay = 0.35;
    shiftSource = 'default_AT_like';
end

function [delay, typeClass] = delayFromGearboxType(txt)
    delay = NaN;
    typeClass = 'unknown';

    if strlength(txt) == 0
        return;
    end

    % Check the more specific patterns first.
    if contains(txt, 'dct') || contains(txt, 'dsg') || ...
       contains(txt, 'dualclutch') || contains(txt, 'doubleclutch') || ...
       contains(txt, 'doppelkuppl') || contains(txt, 'pdk') || ...
       contains(txt, 'stronic') || contains(txt, 's-tronic') || ...
       contains(txt, 'edc')
        delay = 0.20;
        typeClass = 'DCT';
        return;
    end

    if contains(txt, 'cvt') || contains(txt, 'continuouslyvariable') || ...
       contains(txt, 'e-cvt') || contains(txt, 'ecvt')
        delay = 0.05;
        typeClass = 'CVT';
        return;
    end

    if contains(txt, 'manual') || contains(txt, 'schalt') || ...
       contains(txt, 'handschalt') || strcmp(txt, 'mt') || ...
       startsWith(txt, 'mt') || endsWith(txt, 'mt')
        delay = 0.60;
        typeClass = 'MT';
        return;
    end

    if contains(txt, 'automatic') || contains(txt, 'automatik') || ...
       contains(txt, 'torqueconverter') || contains(txt, 'wandler') || ...
       contains(txt, 'tiptronic') || contains(txt, 'steptronic') || ...
       contains(txt, 'zf') || strcmp(txt, 'at') || startsWith(txt, 'at')
        delay = 0.35;
        typeClass = 'AT';
        return;
    end
end

function delay = delayFromPowerToWeight(p2w, cfg)
    % Fallback only when no reliable gearbox type is available.
    % p2w in kW/t. This is intentionally performance-oriented for 0-100 runs.

    noGears = toDoubleScalar(getFirstExistingField(cfg, {'No_Gears', 'NoGears', 'number_gears'}));
    isEV = toDoubleScalar(getFirstExistingField(cfg, {'EV', 'ev'}));

    if ~isnan(noGears) && noGears <= 1
        delay = 0.05;     % single-speed / CVT-like: no shift interruption
        return;
    end
    if ~isnan(isEV) && isEV == 1 && (~isnan(noGears) && noGears <= 2)
        delay = 0.05;
        return;
    end

    if p2w >= 250
        delay = 0.10;     % very high-performance unknown gearbox
    elseif p2w >= 180
        delay = 0.15;     % high-performance unknown gearbox
    elseif p2w >= 120
        delay = 0.20;     % DCT-like performance fallback
    elseif p2w >= 70
        delay = 0.35;     % AT-like normal fallback
    else
        delay = 0.45;     % slow/utility unknown gearbox; not as slow as confirmed MT
    end
end

function p2w = computePowerToWeight(cfg)
    m = toDoubleScalar(getFirstExistingField(cfg, {'m_curb', 'mass_kg', 'Mass_kg'}));
    if isnan(m) || m <= 0
        p2w = NaN;
        return;
    end

    P = NaN;

    % Prefer explicit system power if it exists.
    Psys = toDoubleScalar(getFirstExistingField(cfg, { ...
        'Pwr_System_max_kW', 'Pwr_system_max_kW', 'SystemPower_kW', ...
        'P_System_kW', 'Pwr_total_max_kW'}));
    if ~isnan(Psys) && Psys > 0
        P = Psys;
    else
        fields = {'Pwr_ICE_max_kW', 'Pwr_P2_max_kW', 'Pwr_P3_max_kW', 'Pwr_P4_max_kW', ...
                  'Pwr_EV_max_kW', 'Pwr_E0_max_kW', 'Pwr_E1_max_kW', 'Pwr_E2_max_kW', ...
                  'Pwr_E3_max_kW', 'Pwr_E4_max_kW'};
        P = 0;
        found = false;
        for i = 1:numel(fields)
            val = toDoubleScalar(getFirstExistingField(cfg, fields(i)));
            if ~isnan(val) && val > 0
                P = P + val;
                found = true;
            end
        end
        if ~found
            P = NaN;
        end
    end

    if isnan(P) || P <= 0
        p2w = NaN;
    else
        p2w = P / (m / 1000.0);  % kW/t
    end
end

function value = getFirstExistingField(s, names)
    value = [];
    if ~isstruct(s)
        return;
    end
    for i = 1:numel(names)
        name = char(names{i});
        if isfield(s, name)
            value = s.(name);
            return;
        end
    end
end

function x = toDoubleScalar(v)
    x = NaN;
    if isempty(v)
        return;
    end
    if isnumeric(v) || islogical(v)
        if isscalar(v)
            x = double(v);
        end
        return;
    end
    if isstring(v) || ischar(v)
        s = string(v);
        if ismissing(s) || strlength(strtrim(s)) == 0
            return;
        end
        x = str2double(strrep(strtrim(s), ',', '.'));
        return;
    end
end

function txt = normalizeText(v)
    if isempty(v)
        txt = "";
        return;
    end
    if iscell(v)
        if isempty(v{1})
            txt = "";
            return;
        end
        v = v{1};
    end
    if isnumeric(v) || islogical(v)
        txt = string(v);
    else
        txt = string(v);
    end
    if ismissing(txt)
        txt = "";
        return;
    end
    txt = lower(strtrim(txt));
    txt = replace(txt, "-", "");
    txt = replace(txt, "_", "");
    txt = replace(txt, " ", "");
    txt = replace(txt, ".", "");
    txt = replace(txt, "/", "");
end
