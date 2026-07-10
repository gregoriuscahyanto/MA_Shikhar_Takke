function extract_auffaellig51_doe(inputCsv, actualValuesXlsx, outputCsv, notesCsv)
% extract_auffaellig51_doe
% Creates a reproducible 51-row diagnostic DoE subset from a full AMS DoE CSV.
%
% Usage:
%   extract_auffaellig51_doe("DoE_Inp.csv", "DoE_Inp_ActualValues.xlsx")
%   extract_auffaellig51_doe("DoE_Inp_AMS_v15.csv", "DoE_Inp_AMS_v15_ActualValues.xlsx", ...
%       "DoE_Inp_auffaellig51.csv", "DoE_Inp_auffaellig51_selection_notes.csv")
%
% Selection goal:
%   - keep only simulation-capable rows with valid 0-100 km/h reference
%   - emphasize difficult/diagnostic cases: P2 HEV, P4/PHEV, e-Power/E-Tech,
%     high-performance PHEV, EV 2-speed/performance, and a few ICE extremes
%   - preserve original RUN_IDs so the large ActualValues file can still be used
%
% The script writes:
%   outputCsv  - same schema as inputCsv, 51 selected vehicles
%   notesCsv   - RUN_ID, Vehicle_Name, score, reason, actual value, architecture

    if nargin < 1 || strlength(string(inputCsv)) == 0
        inputCsv = "DoE_Inp.csv";
    end
    if nargin < 2 || strlength(string(actualValuesXlsx)) == 0
        actualValuesXlsx = "DoE_Inp_ActualValues.xlsx";
    end
    if nargin < 3 || strlength(string(outputCsv)) == 0
        outputCsv = "DoE_Inp_auffaellig51.csv";
    end
    if nargin < 4 || strlength(string(notesCsv)) == 0
        notesCsv = "DoE_Inp_auffaellig51_selection_notes.csv";
    end

    T = readtable(inputCsv, 'VariableNamingRule', 'preserve');
    T = ensureActual0100(T, actualValuesXlsx);

    n = height(T);
    score = zeros(n,1);
    reason = strings(n,1);

    actual0100 = getNum(T, 'Actual_0_to_100_s', NaN(n,1));
    valid = isfinite(actual0100) & actual0100 > 0 & actual0100 < 45;

    if hasVar(T, 'Valid_Actual_0_to_100')
        valid = valid & parseLogicalColumn(T.Valid_Actual_0_to_100);
    end

    powertrain = lower(getStr(T, 'Powertrain'));
    vehicle = lower(getStr(T, 'Vehicle_Name'));
    fuel = lower(getStr(T, 'Raw_Fuel'));
    gearbox = lower(getStr(T, 'Raw_Gearbox'));
    rawPower = lower(getStr(T, 'Raw_Power'));
    rawSystem = lower(getStr(T, 'Raw_SystemPower'));
    rawDrive = lower(getStr(T, 'Raw_Drive'));
    inputWarnings = lower(getStr(T, 'InputWarnings'));
    archClass = lower(getStr(T, 'HybridArchitectureClass'));
    allTxt = vehicle + " " + fuel + " " + gearbox + " " + rawPower + " " + rawSystem + " " + rawDrive + " " + inputWarnings + " " + archClass;

    isICE = powertrain == "ice";
    isHybrid = powertrain == "hybrid";
    isEV = powertrain == "ev";
    p2 = getNum(T, 'P2', zeros(n,1));
    p4 = getNum(T, 'P4', zeros(n,1));
    p4dm = getNum(T, 'P4_DM', zeros(n,1));
    e2 = getNum(T, 'E2', zeros(n,1));
    e3 = getNum(T, 'E3', zeros(n,1));
    e4 = getNum(T, 'E4', zeros(n,1));
    pIce = getNum(T, 'Pwr_ICE_max_kW', zeros(n,1));
    pP2 = getNum(T, 'Pwr_P2_max_kW', zeros(n,1));
    pP4 = getNum(T, 'Pwr_P4_max_kW', zeros(n,1));
    pEV = getNum(T, 'Pwr_EV_max_kW', zeros(n,1));
    m = getNum(T, 'm_curb', NaN(n,1));
    sysP = parsePowerColumn(getStr(T, 'Raw_SystemPower'));
    totalP = max(pIce,0) + max(pP2,0) + max(pP4,0) + max(pEV,0);
    p2w = 1000 .* totalP ./ max(m, 1);

    % Named anchor cases from the hybrid/EV debugging workflow.
    add(containsAnyText(allTxt, ["opel corsa", "santa fe", "renault 4", "tonale", "hybrid4", ...
        "qashqai", "x-trail", "e-power", "e tech", "e-tech", "outlander", "grandland", ...
        "ferrari f80", "sf90", "918 spyder", "taycan", "eletre", "emeya", "e-tron gt"]), 120, "named diagnostic case");

    % Hybrid architecture stress cases.
    add(isHybrid, 40, "hybrid baseline");
    add(isHybrid & p2 == 1, 45, "P2 hybrid");
    add(isHybrid & (p4 == 1 | p4dm == 1), 55, "P4/e-axle hybrid");
    add(isHybrid & containsAnyText(allTxt, ["phev", "plug-in", "plugin", "plug in", "4xe", "hybrid4", "q4"]), 45, "PHEV keyword");
    add(isHybrid & containsAnyText(allTxt, ["e-power", "epower", "e-tech", "e tech", "range extender"]), 55, "series-like/complex hybrid");
    add(isHybrid & isfinite(sysP) & sysP > 350, 70, "performance hybrid high system power");
    add(isHybrid & isfinite(sysP) & sysP > 500, 100, "hypercar/performance PHEV");
    add(isHybrid & pP2 > 0 & pP2 < 45, 30, "small P2 HEV");
    add(isHybrid & pP4 > 100, 35, "strong P4 e-axle");

    % EV stress cases.
    add(isEV, 15, "EV baseline");
    add(isEV & containsAnyText(gearbox, ["2-gang", "2 gang", "2-speed", "two-speed"]), 80, "EV 2-speed gearbox");
    add(isEV & (e2 == 1 | e3 == 1 | e4 == 1), 35, "AWD/multi-motor EV");
    add(isEV & p2w > 250, 45, "high-performance EV");
    add(isEV & pEV < 140 & actual0100 > 8, 25, "low-power EV acceleration check");

    % ICE control cases.
    add(isICE & p2w > 250, 35, "high-performance ICE control");
    add(isICE & p2w < 90, 25, "low-power ICE control");
    add(isICE & containsAnyText(allTxt, ["diesel", "tdi", "dci", "hdi", "bluehdi"]), 20, "diesel ICE control");
    add(isICE & containsAnyText(allTxt, ["saugmotor", "naturally", "lamborghini", "ferrari"]), 25, "NA/high-rpm ICE control");

    % Actual value extremes.
    add(actual0100 <= 3.2, 60, "very fast actual 0-100");
    add(actual0100 >= 9.0 & actual0100 <= 13.0, 20, "slow/mid acceleration check");

    % Penalize low-quality/problem rows but do not fully remove them if named.
    add(contains(inputWarnings, "excluded") | contains(inputWarnings, "suspicious ev"), -1000, "excluded/suspicious input warning");
    score(~valid) = -Inf;

    % Select with quotas so the set stays balanced and useful.
    idxHybrid = topK(find(valid & isHybrid), score, 25);
    idxEV     = topK(find(valid & isEV), score, 16);
    idxICE    = topK(find(valid & isICE), score, 10);
    selected = [idxHybrid; idxEV; idxICE];

    % Fill if a category has fewer rows than expected.
    if numel(selected) < 51
        remaining = setdiff(find(valid), selected, 'stable');
        selected = [selected; topK(remaining, score, 51-numel(selected))];
    end

    % Trim exactly 51 by score, stable for reproducibility.
    if numel(selected) > 51
        selected = topK(selected, score, 51);
    end

    selected = selected(:);
    Tout = T(selected, :);
    writetable(Tout, outputCsv);

    notes = table();
    notes.RUN_ID = getNum(Tout, 'RUN_ID', (1:height(Tout)).');
    notes.Vehicle_Name = getStr(Tout, 'Vehicle_Name');
    notes.Powertrain = getStr(Tout, 'Powertrain');
    notes.Actual_0_to_100_s = getNum(Tout, 'Actual_0_to_100_s', NaN(height(Tout),1));
    notes.SelectionScore = score(selected);
    notes.SelectionReason = reason(selected);
    if hasVar(Tout, 'HybridArchitectureClass')
        notes.HybridArchitectureClass = getStr(Tout, 'HybridArchitectureClass');
    end
    notes.Pwr_ICE_max_kW = getNum(Tout, 'Pwr_ICE_max_kW', NaN(height(Tout),1));
    notes.Pwr_P2_max_kW = getNum(Tout, 'Pwr_P2_max_kW', NaN(height(Tout),1));
    notes.Pwr_P4_max_kW = getNum(Tout, 'Pwr_P4_max_kW', NaN(height(Tout),1));
    notes.Pwr_EV_max_kW = getNum(Tout, 'Pwr_EV_max_kW', NaN(height(Tout),1));
    writetable(notes, notesCsv);

    fprintf('Wrote %d selected rows to %s\n', height(Tout), outputCsv);
    fprintf('Wrote selection notes to %s\n', notesCsv);
    disp(groupsummary(Tout, 'Powertrain'));

    function add(mask, points, txt)
        mask = logical(mask(:));
        score(mask) = score(mask) + points;
        r = reason(mask);
        empty = strlength(r) == 0;
        r(empty) = string(txt);
        r(~empty) = r(~empty) + " | " + string(txt);
        reason(mask) = r;
    end
end

function T = ensureActual0100(T, actualValuesXlsx)
    if hasVar(T, 'Actual_0_to_100_s') && any(isfinite(getNum(T, 'Actual_0_to_100_s', NaN(height(T),1))))
        return;
    end
    if nargin < 2 || ~isfile(actualValuesXlsx)
        return;
    end
    A = readtable(actualValuesXlsx, 'VariableNamingRule', 'preserve');
    if ~hasVar(T, 'RUN_ID') || ~hasVar(A, 'RUN_ID') || ~hasVar(A, 'Actual_0_to_100_s')
        return;
    end
    [tf, loc] = ismember(getNum(T, 'RUN_ID', NaN(height(T),1)), getNum(A, 'RUN_ID', NaN(height(A),1)));
    vals = NaN(height(T),1);
    aVals = getNum(A, 'Actual_0_to_100_s', NaN(height(A),1));
    vals(tf) = aVals(loc(tf));
    T.Actual_0_to_100_s = vals;
    if hasVar(A, 'Valid_Actual_0_to_100')
        v = false(height(T),1);
        av = parseLogicalColumn(A.Valid_Actual_0_to_100);
        v(tf) = av(loc(tf));
        T.Valid_Actual_0_to_100 = v;
    end
end

function idx = topK(candidates, score, k)
    candidates = candidates(:);
    if isempty(candidates) || k <= 0
        idx = [];
        return;
    end
    [~, order] = sortrows([-score(candidates), candidates]);
    idx = candidates(order(1:min(k, numel(order))));
end

function tf = hasVar(T, name)
    tf = any(strcmp(T.Properties.VariableNames, name));
end

function s = getStr(T, name)
    if hasVar(T, name)
        s = string(T.(name));
    else
        s = strings(height(T),1);
    end
    s(ismissing(s)) = "";
end

function x = getNum(T, name, defaultVal)
    if hasVar(T, name)
        x = str2double(string(T.(name)));
        if all(isnan(x)) && isnumeric(T.(name))
            x = double(T.(name));
        end
    else
        x = defaultVal;
    end
    x = x(:);
end

function tf = parseLogicalColumn(x)
    if isnumeric(x) || islogical(x)
        tf = logical(x);
    else
        sx = lower(strtrim(string(x)));
        tf = sx == "true" | sx == "1" | sx == "yes" | sx == "ja";
    end
    tf = tf(:);
end

function tf = containsAnyText(txt, patterns)
    txt = lower(string(txt));
    patterns = lower(string(patterns));
    tf = false(size(txt));
    for i = 1:numel(patterns)
        tf = tf | contains(txt, patterns(i));
    end
end

function p = parsePowerColumn(s)
    s = string(s);
    p = NaN(size(s));
    for i = 1:numel(s)
        txt = char(s(i));
        tok = regexp(txt, '([-+]?\d+(?:[.,]\d+)?)\s*kW', 'tokens', 'once', 'ignorecase');
        if ~isempty(tok)
            p(i) = str2double(strrep(tok{1}, ',', '.'));
            continue;
        end
        tok = regexp(txt, '([-+]?\d+(?:[.,]\d+)?)\s*PS', 'tokens', 'once', 'ignorecase');
        if ~isempty(tok)
            p(i) = str2double(strrep(tok{1}, ',', '.')) * 0.735499;
        end
    end
end
