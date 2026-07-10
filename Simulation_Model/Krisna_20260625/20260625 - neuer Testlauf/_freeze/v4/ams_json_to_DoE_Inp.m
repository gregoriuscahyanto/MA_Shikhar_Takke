function ams_json_to_DoE_Inp(inputFile, outBase)
% ams_json_to_DoE_Inp
% Converts the auto-motor-und-sport scraper JSON/ZIP into a DoE input table
% compatible with DoE_main.m / main_DoE.m style inputs.
%
% Usage:
%   ams_json_to_DoE_Inp("webscraper_auto_motor_sport_marken_modelle.zip")
%   ams_json_to_DoE_Inp("webscraper_auto_motor_sport_marken_modelle.json", "DoE_Inp_AMS")
%
% Output:
%   <outBase>.xlsx  with sheets: DoE_Inp, ActualValues, Meta
%   <outBase>.csv   same schema as DoE_Inp.csv, directly usable as DoE input
%
% Notes:
%   - The AMS JSON does not contain every simulation parameter directly.
%     Missing parameters are filled with transparent fallback values.
%   - The DoE_Inp sheet keeps exactly the columns used by your current
%     DoE_Inp_random15.csv.
%   - Actual 0-100 km/h values are written to a separate sheet/file because
%     they are validation targets, not simulation inputs.

    fprintf("ams_json_to_DoE_Inp FINAL_V14_SIM_READY_INPUT\n");

    if nargin < 1 || strlength(safeStringScalar(inputFile)) == 0
        if isfile("webscraper_auto_motor_sport_marken_modelle.zip")
            inputFile = "webscraper_auto_motor_sport_marken_modelle.zip";
        elseif isfile("webscraper_auto_motor_sport_marken_modelle.json")
            inputFile = "webscraper_auto_motor_sport_marken_modelle.json";
        else
            error("No input file given and no default AMS JSON/ZIP found in the current folder.");
        end
    end

    if nargin < 2 || strlength(safeStringScalar(outBase)) == 0
        outBase = "DoE_Inp";
    end

    inputFile = string(inputFile);
    outBase   = string(outBase);

    [jsonFile, tmpFolder] = prepareJsonInput(inputFile);
    cleanupObj = onCleanup(@() cleanupTempFolder(tmpFolder)); %#ok<NASGU>

    fprintf("Reading JSON: %s\n", jsonFile);
    txt = fileread(jsonFile);
    data = jsondecode(txt);

    if ~isfield(data, "items")
        error("JSON does not contain an 'items' field.");
    end

    items = data.items;
    nItems = numel(items);
    fprintf("Items in JSON: %d\n", nItems);

    doeCols = getDoeColumns();
    emptyRow = makeEmptyDoeRow(doeCols);

    rows = repmat(emptyRow, 0, 1);
    metaRows = repmat(makeEmptyMetaRow(), 0, 1);
    actualRows = repmat(makeEmptyActualRow(), 0, 1);

    runID = 0;
    nSkipped = 0;

    for iItem = 1:nItems

        fprintf("Item %d from %d\n", iItem, nItems);

        item = items(iItem);
        cols = getVariantColumns(item);
        if isempty(cols)
            cols = {""};
        end

        for iCol = 1:numel(cols)
            raw = extractRawVehicle(item, iCol);
            row = convertRawToDoeRow(raw, emptyRow);

            if ~isUsableDoeRow(row)
                nSkipped = nSkipped + 1;
                continue;
            end

            runID = runID + 1;
            row.RUN_ID = runID;

            [actualP2W_kW_per_t, actual0100Valid, actual0100Warning] = ...
                checkActual0100Plausibility(row, raw.actual0100_s);

            rows(end+1, 1) = row; %#ok<AGROW>

            meta = makeEmptyMetaRow();
            meta.RUN_ID = runID;
            meta.Vehicle_Name = raw.vehicleName;
            meta.Brand_URL = raw.brandUrl;
            meta.Series_URL = raw.seriesUrl;
            meta.Generation_URL = raw.generationUrl;
            meta.Techdata_URL = raw.techdataUrl;
            meta.Bodytype = raw.bodytype;
            meta.Source_Year_or_Column = string(cols{iCol});
            meta.Powertrain_Resolved = row.Powertrain;
            meta.InputQualityScore = row.InputQualityScore;
            meta.InputWarnings = row.InputWarnings;
            meta.Raw_Fuel = raw.fuelText;
            meta.Raw_Power = raw.powerText;
            meta.Raw_Torque = raw.torqueText;
            meta.Raw_SystemPower = raw.systemPowerText;
            meta.Raw_SystemTorque = raw.systemTorqueText;
            meta.Raw_Gearbox = raw.gearboxText;
            meta.Raw_Drive = raw.driveText;
            meta.Raw_Dimensions = raw.dimText;
            meta.Raw_Weight = raw.weightText;
            meta.Actual_0_to_100_s = raw.actual0100_s;
            meta.Actual_max_speed_kmh = raw.vmax_kmh;
            meta.PowerToWeight_kW_per_t = actualP2W_kW_per_t;
            meta.Valid_Actual_0_to_100 = actual0100Valid;
            meta.Actual_0_to_100_Warning = actual0100Warning;
            metaRows(end+1, 1) = meta; %#ok<AGROW>

            if isfinite(raw.actual0100_s) || isfinite(raw.vmax_kmh)
                a = makeEmptyActualRow();
                a.RUN_ID = runID;
                a.Vehicle_Name = raw.vehicleName;
                a.Powertrain = row.Powertrain;
                a.Actual_0_to_100_s = raw.actual0100_s;
                a.Actual_max_speed_kmh = raw.vmax_kmh;
                a.PowerToWeight_kW_per_t = actualP2W_kW_per_t;
                a.Valid_Actual_0_to_100 = actual0100Valid;
                a.Actual_0_to_100_Warning = actual0100Warning;
                a.Source_URL = raw.techdataUrl;
                actualRows(end+1, 1) = a; %#ok<AGROW>
            end
        end
    end

    if isempty(rows)
        error("No usable vehicles found. Check JSON structure or filtering rules.");
    end

    doeT = struct2table(rows);
    doeT = doeT(:, doeCols);

    metaT = struct2table(metaRows);
    actualT = struct2table(actualRows);

    outFolder = fileparts(char(outBase));
    if ~isempty(outFolder) && ~isfolder(outFolder)
        mkdir(outFolder);
    end

    xlsxPath = outBase + ".xlsx";
    csvPath  = outBase + ".csv";
    actualCsvPath = outBase + "_ActualValues.xlsx";

    if isfile(xlsxPath)
        delete(xlsxPath);
    end

    fprintf("Writing DoE table: %s\n", csvPath);
    writetable(doeT, csvPath);

    fprintf("Writing Excel workbook: %s\n", xlsxPath);
    writetable(doeT, xlsxPath, "Sheet", "DoE_Inp");
    writetable(actualT, xlsxPath, "Sheet", "ActualValues");
    writetable(metaT, xlsxPath, "Sheet", "Meta");

    fprintf("Writing actual-values CSV: %s\n", actualCsvPath);
    writetable(actualT, actualCsvPath);

    fprintf("Done. Usable rows: %d | skipped rows: %d\n", height(doeT), nSkipped);
    fprintf("Use this as DoE input: %s\n", csvPath);
    fprintf("Use this for actual comparison: %s\n", actualCsvPath);
end

%% ------------------------- core mapping -------------------------

function raw = extractRawVehicle(item, idx)
    raw = struct();

    raw.vehicleName = firstNonEmptyString({ ...
        getTopString(item, "overlay_subhead"), ...
        getTopString(item, "variant_list_title"), ...
        getTopString(item, "overlay_title")});

    raw.brandUrl      = getTopString(item, "brand_url");
    raw.seriesUrl     = getTopString(item, "series_url");
    raw.generationUrl = getTopString(item, "generation_url");
    raw.techdataUrl   = getTopString(item, "techdata_url");
    raw.bodytype      = getTopString(item, "block_bodytype");
    raw.variantMeta   = getTopString(item, "variant_list_meta");

    raw.powerText     = getTableValue(item, {"Antrieb"}, {"Leistung"}, idx);
    raw.torqueText    = getTableValue(item, {"Antrieb"}, {"max. Drehmoment"}, idx);
    raw.dispText      = getTableValue(item, {"Antrieb"}, {"Hubraum / Verdichtung"}, idx);
    raw.cylText       = getTableValue(item, {"Antrieb"}, {"Zylinderzahl / Motorbauart"}, idx);
    raw.engineLocText = getTableValue(item, {"Antrieb"}, {"Einbaulage / Richtung"}, idx);
    raw.fuelText      = getTableValue(item, {"Verbrauch und Emissionswerte"}, {"Kraftstoff"}, idx);
    raw.driveText     = getTableValue(item, {"Antrieb"}, {"Antriebsart"}, idx);
    raw.gearboxText   = getTableValue(item, {"Antrieb"}, {"Getriebe"}, idx);
    raw.ratiosText    = getTableValue(item, {"Antrieb"}, {"Uebersetzungen", "Übersetzungen"}, idx);
    raw.finalDriveText= getTableValue(item, {"Antrieb"}, {"Achsantrieb"}, idx);
    raw.boostText     = getTableValue(item, {"Antrieb"}, {"Aufladung"}, idx);

    raw.dimText       = getTableValue(item, {"Karosserie und Abmessungen"}, {"Aussenmasse", "Außenmaße"}, idx);
    raw.wheelbaseText = getTableValue(item, {"Karosserie und Abmessungen"}, {"Radstand"}, idx);
    raw.weightText    = getTableValue(item, {"Gewichte"}, {"Leergewicht"}, idx);

    raw.vmaxText      = getTableValue(item, {"Beschleunigung"}, {"Hoechstgeschwindigkeit", "Höchstgeschwindigkeit"}, idx);
    raw.accelText     = getTableValue(item, {"Beschleunigung"}, {"0-100 km/h", "0 100 km h"}, idx);

    raw.eMotorCountText = getTableValue(item, {"Antrieb"}, {"Elektromotoren Anzahl"}, idx);
    raw.systemPowerText = getTableValue(item, {"Antrieb"}, {"Systemleistung"}, idx);
    raw.systemTorqueText= getTableValue(item, {"Antrieb"}, {"Systemdrehmoment"}, idx);
    raw.ePowerText      = getTableValue(item, {"Antrieb"}, {"E-Motor Leistung"}, idx);
    raw.eTorqueText     = getTableValue(item, {"Antrieb"}, {"E-Motor max. Drehmoment"}, idx);
    raw.eLocText        = getTableValue(item, {"Antrieb"}, {"Einbauort E-Motor"}, idx);
    raw.ePower2Text     = getTableValue(item, {"Antrieb"}, {"Leistung Motor 2"}, idx);
    raw.eTorque2Text    = getTableValue(item, {"Antrieb"}, {"max. Drehmoment Motor 2"}, idx);
    raw.eLoc2Text       = getTableValue(item, {"Antrieb"}, {"Einbauort Motor 2"}, idx);
    raw.battVoltageText = getTableValue(item, {"Antrieb"}, {"Batteriespannung"}, idx);
    raw.battGrossText   = getTableValue(item, {"Antrieb"}, {"Energiegehalt brutto"}, idx);
    raw.battNetText     = getTableValue(item, {"Antrieb"}, {"Energiegehalt netto"}, idx);

    raw.power_kW     = parsePowerKW(raw.powerText);
    raw.power_rpm    = parseRpmAt(raw.powerText);
    raw.torque_Nm    = parseTorqueNm(raw.torqueText);
    raw.system_kW    = parsePowerKW(raw.systemPowerText);
    raw.system_Nm    = parseTorqueNm(raw.systemTorqueText);
    raw.ePower_kW    = parsePowerKW(raw.ePowerText);
    raw.eTorque_Nm   = parseTorqueNm(raw.eTorqueText);
    raw.ePower2_kW   = parsePowerKW(raw.ePower2Text);
    raw.eTorque2_Nm  = parseTorqueNm(raw.eTorque2Text);
    raw.displacement_cc = parseFirstNumber(raw.dispText);
    raw.cylinders    = parseFirstNumber(raw.cylText);
    raw.mass_kg      = parseFirstNumber(raw.weightText);
    raw.wheelbase_m  = parseFirstNumber(raw.wheelbaseText) / 1000;
    raw.finalDrive   = parseRatio(raw.finalDriveText);
    raw.gearRatios   = parseGearRatios(raw.ratiosText);
    raw.noGears      = parseFirstNumber(raw.gearboxText);
    raw.actual0100_s = parseFirstNumber(raw.accelText);
    raw.eMotorCount  = parseFirstNumber(raw.eMotorCountText);
    raw.actual0100_s = parsePositiveNumber(raw.actual0100_s);
    raw.vmax_kmh     = parseSpeedKmh(raw.vmaxText);
    if ~isfinite(raw.vmax_kmh)
        raw.vmax_kmh = parseSpeedKmh(raw.variantMeta);
    end
    raw.battVoltage_V = parseFirstNumber(raw.battVoltageText);
    raw.battGross_kWh = parseFirstNumber(raw.battGrossText);
    raw.battNet_kWh   = parseFirstNumber(raw.battNetText);

    [raw.length_m, raw.width_m, raw.height_m] = parseDimensions(raw.dimText);
end

function row = convertRawToDoeRow(raw, emptyRow)
    row = emptyRow;
    warnings = strings(1, 0);

    fuel  = safeLowerString(raw.fuelText);
    drive = safeLowerString(raw.driveText);
    body  = safeLowerString(raw.bodytype);
    eLoc  = safeLowerString(safeStringScalar(raw.eLocText) + " " + safeStringScalar(raw.eLoc2Text));
    engineLoc = safeLowerString(raw.engineLocText);
    gearboxTxt = safeLowerString(raw.gearboxText); %#ok<NASGU>
    allTxt = safeLowerString(strjoin([safeStringScalar(raw.vehicleName), safeStringScalar(raw.fuelText), ...
        safeStringScalar(raw.powerText), safeStringScalar(raw.torqueText), safeStringScalar(raw.systemPowerText), ...
        safeStringScalar(raw.ePowerText), safeStringScalar(raw.ePower2Text), safeStringScalar(raw.eMotorCountText), ...
        safeStringScalar(raw.eLocText), safeStringScalar(raw.eLoc2Text), safeStringScalar(raw.gearboxText), ...
        safeStringScalar(raw.variantMeta)], " "));
    nameVariantTxt = safeLowerString(strjoin([safeStringScalar(raw.vehicleName), safeStringScalar(raw.variantMeta)], " "));
    has2WDNameHint = contains2WDHint(nameVariantTxt);
    hasAWDNameHint = containsAny(nameVariantTxt, ["awd", "4wd", "4x4", "allrad", "quattro", "xdrive", "4matic", "4matic+", "4motion", "e-four", "dual motor"]);
    hasCVTGearbox = isCvtGearboxText(raw.gearboxText);

    % IMPORTANT: Systemleistung alone is NOT an electric-machine evidence in
    % the AMS data. Many pure ICE entries have total/fahrzeug power fields.
    % Do not use plain "hev" as substring: it also matches names like Chevrolet.
    hasExplicitHybridHint = containsAny(allTxt, ["hybrid", "plug-in", "plugin", "phev", "mhev", ...
        "mildhybrid", "mild-hybrid", "48v", "e-hybrid", "e-power", "range extender", "ibrida", "e-tech"]);
    hasExplicitEVHint = contains(fuel, "elektro") || containsAny(allTxt, ["bev", "electric"]);
    hasExplicitElectricMotor = (isfinite(raw.ePower_kW) && raw.ePower_kW > 0) || ...
        (isfinite(raw.ePower2_kW) && raw.ePower2_kW > 0) || ...
        (isfinite(raw.eTorque_Nm) && raw.eTorque_Nm > 0) || ...
        (isfinite(raw.eTorque2_Nm) && raw.eTorque2_Nm > 0) || ...
        (isfinite(raw.eMotorCount) && raw.eMotorCount > 0) || ...
        strlength(strtrim(safeStringScalar(raw.eLocText))) > 0 || strlength(strtrim(safeStringScalar(raw.eLoc2Text))) > 0;

    hasICEHardware = (isfinite(raw.displacement_cc) && raw.displacement_cc > 100) || ...
                     (isfinite(raw.cylinders) && raw.cylinders > 0);
    combustionFuelHint = containsAny(fuel, ["benzin", "diesel", "super", "normal", "autogas", "erdgas", "wasserstoff"]);
    hasHighVoltageEvidence = isfinite(raw.battVoltage_V) && raw.battVoltage_V >= 180;
    hasSingleSpeedElectricGearbox = isfinite(raw.noGears) && raw.noGears <= 1 && ...
        containsAny(safeLowerString(raw.gearboxText), ["automatik", "1-gang", "1 gang", "single speed"]);

    % AMS occasionally labels pure EVs as "Super Benzin" although the row has
    % no ICE hardware and contains a HV battery + e-motor, e.g. Renault 4 E-Tech.
    % In that case the hardware evidence must dominate the fuel text.
    powerLooksEVOnly = (isfinite(raw.power_kW) && raw.power_kW > 0) || ...
        (isfinite(raw.system_kW) && raw.system_kW > 0);
    systemEqualsPower = isfinite(raw.power_kW) && isfinite(raw.system_kW) && ...
        abs(raw.power_kW - raw.system_kW) <= max(2, 0.03 * max(raw.system_kW, 1));
    looksPureElectricEtech = containsAny(nameVariantTxt, ["e-tech", "e tech"]) && ...
        ~hasICEHardware && powerLooksEVOnly && ...
        (hasHighVoltageEvidence || hasSingleSpeedElectricGearbox) && ...
        (systemEqualsPower || ~isfinite(raw.system_kW) || ~isfinite(raw.power_kW));

    fuelLooksWrongForEV = combustionFuelHint && ~hasICEHardware && ...
        (hasExplicitElectricMotor || looksPureElectricEtech) && ...
        (hasHighVoltageEvidence || hasSingleSpeedElectricGearbox) && ...
        ~containsAny(allTxt, ["range extender", "rex"]);

    hasICE = ~contains(fuel, "elektro") && ~fuelLooksWrongForEV && ...
             (hasICEHardware || combustionFuelHint);

    isEV = (~hasICE && (hasExplicitEVHint || hasExplicitElectricMotor)) || fuelLooksWrongForEV;
    isHybrid = ~isEV && hasICE && (hasExplicitHybridHint || hasExplicitElectricMotor);

    if isEV
        row.Powertrain = "EV";
        row.VM = 0; row.EV = 1; row.Hy = 0;
        if fuelLooksWrongForEV
            warnings(end+1) = "fuel text ignored: EV hardware dominates classification"; %#ok<AGROW>
        end
    elseif isHybrid
        row.Powertrain = "Hybrid";
        % Keep VM=1 in the CSV as physical ICE-present information. DoE_main
        % maps this to the topology required by PowertrainConfig.
        row.VM = 0; row.EV = 0; row.Hy = 1;
    else
        row.Powertrain = "ICE";
        row.VM = 1; row.EV = 0; row.Hy = 0;
        if isfinite(raw.system_kW) && raw.system_kW > 0 && ~hasExplicitHybridHint && ~hasExplicitElectricMotor
            warnings(end+1) = "system_kW ignored for ICE classification"; %#ok<AGROW>
        end
    end

    row.Vehicle_Name = raw.vehicleName;
    row.Source_URL = raw.techdataUrl;

    urlVehicleName = vehicleNameFromAmsUrl(row.Source_URL);
    if isGenericVehicleName(row.Vehicle_Name) && strlength(urlVehicleName) > 0
        row.Vehicle_Name = urlVehicleName;
        warnings(end+1) = "vehicle name repaired from AMS URL"; %#ok<AGROW>
    end
    row.Raw_Fuel = raw.fuelText;
    row.Raw_Gearbox = raw.gearboxText;
    row.Raw_Drive = raw.driveText;
    row.Raw_Power = raw.powerText;
    row.Raw_Torque = raw.torqueText;
    row.Raw_SystemPower = raw.systemPowerText;
    row.Actual_0_to_100_s = raw.actual0100_s;
    row.Actual_max_speed_kmh = raw.vmax_kmh;

    if hasCVTGearbox
        warnings(end+1) = "CVT/e-CVT excluded"; %#ok<AGROW>
    end

    % Plausibility gate for known scraper mix-ups:
    % A pure EV with a normal 7/8/9-speed automatic gearbox is very likely
    % not a clean EV row (example: "S 450 ...", fuel="Elektro", gearbox="9-Gang").
    % Porsche Taycan-like 2-speed EVs are still allowed.
    if isEV && isfinite(raw.noGears) && raw.noGears >= 3
        warnings(end+1) = "suspicious EV with multi-speed gearbox >=3"; %#ok<AGROW>
    end

    row.m_curb = fallback(raw.mass_kg, 1500);
    if ~isfinite(raw.mass_kg), warnings(end+1) = "mass fallback"; end %#ok<AGROW>
    row.Wheelbase = fallback(raw.wheelbase_m, estimateWheelbase(raw.length_m, body));
    if ~isfinite(raw.wheelbase_m), warnings(end+1) = "wheelbase estimated"; end %#ok<AGROW>
    row.d_wheel = estimateWheelDiameter(raw.length_m, raw.height_m, body);
    row.A_front = estimateFrontalArea(raw.width_m, raw.height_m, body);
    row.h_s = estimateCgHeight(raw.height_m, body);

    row.AWD = double(contains(drive, "allrad") || contains(drive, "4x4") || contains(drive, "awd") || ...
        containsAny(drive, ["quattro", "xdrive", "4matic", "4motion", "e-four", "dual motor"]));
    row.HM_VA = double(contains(drive, "vorderrad") || contains(engineLoc, "vorn") || row.AWD == 1);
    if contains(drive, "hinterrad") && row.AWD == 0
        row.HM_VA = 0;
    end
    if hasAWDNameHint && ~has2WDNameHint && row.AWD == 0
        row.AWD = 1;
        row.HM_VA = 1;
        warnings(end+1) = "AWD repaired from vehicle-name AWD/quattro/xDrive hint"; %#ok<AGROW>
    end
    if has2WDNameHint && ~hasAWDNameHint && row.AWD == 1
        row.AWD = 0;
        if contains(drive, "hinterrad") || contains(eLoc, "hinten")
            row.HM_VA = 0;
        else
            row.HM_VA = 1;
        end
        warnings(end+1) = "AWD repaired from vehicle-name 2WD/4x2 hint"; %#ok<AGROW>
    end

    if isEV && row.AWD == 0 && ~has2WDNameHint && ...
            ((containsAny(eLoc, ["vorn", "vorne", "front"]) && containsAny(eLoc, ["hinten", "rear"])) || ...
             containsAny(eLoc, ["allrad", "awd", "4x4", "dual motor"]))
        row.AWD = 1;
        row.HM_VA = 1;
        warnings(end+1) = "EV AWD repaired from e-motor location hint"; %#ok<AGROW>
    end

    row.weight_dist = estimateWeightDist(row.AWD, row.HM_VA, drive, engineLoc, body, isEV);
    row.MainAxle_TorqueSplit_int = 0.5;
    row.Hybrid_ICE_priority = 1;

    row.iAG = fallback(raw.finalDrive, estimateFinalDrive(row.Powertrain, row.AWD));
    if row.iAG <= 0
        row.iAG = estimateFinalDrive(row.Powertrain, row.AWD);
        warnings(end+1) = "final drive estimated"; %#ok<AGROW>
    end

    % For pure EVs the model uses i_GET_EV as the total reduction.
    % Therefore iAG must be 1.0, otherwise the model multiplies i_GET_EV*iAG
    % and the EV becomes much too slow / speed-limited.
    if isEV
        if isfinite(row.iAG) && abs(row.iAG - 1.0) > 1e-6
            warnings(end+1) = "EV final drive moved into i_GET_EV; iAG set to 1"; %#ok<AGROW>
        end
        row.iAG = 1.0;
    end

    row.mode = "performance";
    row.use_cus_val = 1;

    if ~isempty(raw.gearRatios)
        row.Gear_Ratio = formatNumVector(raw.gearRatios);
        row.No_Gears = numel(raw.gearRatios);
    else
        nRaw = raw.noGears;
        if isfinite(nRaw) && nRaw <= 1 && ~isEV
            % AMS contains entries like "0-Gang". For ICE/Hybrid this means
            % missing gearbox data, not one physical gear.
            nRaw = NaN;
            warnings(end+1) = "gear count repaired from <=1 for ICE/Hybrid"; %#ok<AGROW>
        end
        nG = fallback(nRaw, estimateGearCount(raw.gearboxText, row.Powertrain));
        if row.VM == 1 || row.Hy == 1
            gr = defaultGearRatios(nG, raw.gearboxText);
            row.Gear_Ratio = formatNumVector(gr);
            row.No_Gears = numel(gr);
        else
            row.Gear_Ratio = "[1]";
            row.No_Gears = 1;
        end
    end

    row.shiftDelay = estimateShiftDelay(raw.gearboxText, row.Powertrain, raw.power_kW, row.m_curb);
    row.Transmission_Type = resolveTransmissionType(raw.gearboxText, row.Powertrain);

    row.Displacement_cc = fallback(raw.displacement_cc, 0);
    row.Induction_Type = estimateInductionType(raw.boostText, raw.power_kW, raw.displacement_cc, raw.power_rpm, raw.fuelText, raw.vehicleName, raw.powerText);
    row.Boost_Pressure_bar = estimateBoostPressure(row.Induction_Type);

    if row.VM == 1 || row.Hy == 1
        row.n_ICE_idle = 1000;
        row.n_ICE_max = estimateIceMaxRpm(raw.power_rpm, raw.fuelText, row.Induction_Type);
        row.Pwr_ICE_max_kW = fallback(raw.power_kW, NaN);
        if ~isfinite(row.Pwr_ICE_max_kW) && isHybrid && isfinite(raw.system_kW) && isfinite(raw.ePower_kW)
            row.Pwr_ICE_max_kW = max(raw.system_kW - raw.ePower_kW, 0);
        end
        row.Pwr_ICE_max_kW = fallback(row.Pwr_ICE_max_kW, 0);
        row.tq_ICE_max = fallback(raw.torque_Nm, estimateTorqueFromPower(row.Pwr_ICE_max_kW, raw.power_rpm));
        row.tq_ICE_idle = 0.20 * row.tq_ICE_max;
    else
        row.n_ICE_idle = 0;
        row.n_ICE_max = 0;
        row.Pwr_ICE_max_kW = 0;
        row.tq_ICE_max = 0;
        row.tq_ICE_idle = 0;
    end

    % Electric-machine mapping.
    ePwr1 = NaN;
    eTq1 = NaN;
    if isfinite(raw.ePower_kW) && raw.ePower_kW > 0
        ePwr1 = raw.ePower_kW;
    elseif isEV && isfinite(raw.system_kW) && raw.system_kW > 0
        ePwr1 = raw.system_kW;
    elseif isEV && isfinite(raw.power_kW) && raw.power_kW > 0
        ePwr1 = raw.power_kW;
    elseif isHybrid && isfinite(raw.system_kW) && raw.system_kW > row.Pwr_ICE_max_kW
        ePwr1 = raw.system_kW - row.Pwr_ICE_max_kW;
    end
    if isfinite(raw.eTorque_Nm) && raw.eTorque_Nm > 0
        eTq1 = raw.eTorque_Nm;
    elseif isEV && isfinite(raw.system_Nm) && raw.system_Nm > 0
        eTq1 = raw.system_Nm;
    else
        eTq1 = estimateTorqueFromPower(ePwr1, 5000);
    end
    ePwr2 = raw.ePower2_kW;
    eTq2  = raw.eTorque2_Nm;
    voltage = raw.battVoltage_V;

    % Hybrid e-machine plausibility repair at conversion stage. This prevents
    % DoE_main from having to repair rows afterwards.
    isMildHybridText = containsAny(allTxt, ["mhev", "mild", "48v", "48 v", "mild-hybrid", "mildhybrid"]);
    isPluginHybridText = containsAny(allTxt, ["phev", "plug-in", "plugin", "plug in", "e-hybrid", "4xe"]);
    isDctHybridGearbox = containsAny(safeLowerString(raw.gearboxText), ["doppelkuppl", "dsg", "dct", "edct", "e-dct"]);
    isHybridP4Hint = contains(eLoc, "hinten") || containsAny(allTxt, ["hybrid4", "4xe", "q4", "e-four"]);
    if isHybrid && row.AWD == 1 && isPluginHybridText && isfinite(raw.eMotorCount) && raw.eMotorCount >= 2
        isHybridP4Hint = true;
    end

    if isHybrid && isfinite(raw.system_kW) && raw.system_kW > 0 && row.Pwr_ICE_max_kW > 0 && ...
            isfinite(ePwr1) && ePwr1 > 0
        sysGap_kW = raw.system_kW - row.Pwr_ICE_max_kW;

        % In AMS, "E-Motor Leistung" can be copied from system power.
        % For non-plug-in P2/HEV rows, use the ICE-to-system gap instead.
        if ~isPluginHybridText && sysGap_kW > 5 && ePwr1 > 1.15 * sysGap_kW
            oldEPwr1 = ePwr1;
            ePwr1 = sysGap_kW;
            warnings(end+1) = sprintf("hybrid e-motor power repaired from system-power gap: %.1f -> %.1f kW", ...
                oldEPwr1, ePwr1); %#ok<AGROW>

            tqCapFromGap = estimateTorqueFromPower(ePwr1, 3000);
            if isfinite(tqCapFromGap) && tqCapFromGap > 0 && isfinite(eTq1) && eTq1 > tqCapFromGap
                oldETq1 = eTq1;
                eTq1 = tqCapFromGap;
                warnings(end+1) = sprintf("hybrid e-motor torque capped after power repair: %.1f -> %.1f Nm", ...
                    oldETq1, eTq1); %#ok<AGROW>
            end
        elseif ~isPluginHybridText && sysGap_kW <= 5 && ePwr1 > 0.80 * raw.system_kW && ~isMildHybridText
            % Cannot infer a traction e-machine if system power is not above ICE power.
            oldEPwr1 = ePwr1;
            ePwr1 = NaN;
            eTq1 = NaN;
            warnings(end+1) = sprintf("hybrid e-motor ignored: system-power gap <= 5 kW and e-power looked copied: %.1f kW", ...
                oldEPwr1); %#ok<AGROW>
        end
    end

    if isHybrid
        % 48V belt-starter P0 systems are usually <=15-18 kW and not inside a DCT.
        % Stronger 48V DCT/front machines, e.g. Opel/Stellantis hybrid, are traction P2.
        isLikelyP0MildHybrid = isfinite(voltage) && voltage <= 80 && isfinite(ePwr1) && ePwr1 <= 18 && ...
            ~isDctHybridGearbox && ~containsAny(eLoc, ["vorn", "vorne", "front", "getriebe", "transmission"]);

        if isLikelyP0MildHybrid
            row.P0 = 1;
            row.tq_P0_max = eTq1;
            row.Pwr_P0_max_kW = ePwr1;
            row.n_P0_max = 12000;
        elseif isHybridP4Hint || (row.AWD == 1 && isfinite(ePwr2))
            row.P4 = 1;
            row.P4_DM = 0;
            row.tq_P4_max = fallback(eTq1, eTq2);
            row.Pwr_P4_max_kW = fallback(ePwr1, ePwr2);
            row.n_P4_max = 16000;
            row.i_ges_P4 = 9.0;
            warnings(end+1) = "hybrid e-machine mapped to P4 from rear/AWD/PHEV architecture hint"; %#ok<AGROW>
        else
            row.P2 = 1;
            row.tq_P2_max = eTq1;
            row.Pwr_P2_max_kW = ePwr1;
            row.n_P2_max = 16000;
        end

        if isfinite(ePwr2) && ePwr2 > 0
            if contains(safeLowerString(raw.eLoc2Text), "hinten") || row.AWD == 1
                row.P4 = 1;
                row.P4_DM = 0;
                row.tq_P4_max = fallback(row.tq_P4_max, 0) + fallback(eTq2, estimateTorqueFromPower(ePwr2, 5000));
                row.Pwr_P4_max_kW = fallback(row.Pwr_P4_max_kW, 0) + ePwr2;
                row.n_P4_max = 16000;
                row.i_ges_P4 = 9.0;
            else
                row.P2 = 1;
                row.tq_P2_max = fallback(row.tq_P2_max, 0) + fallback(eTq2, estimateTorqueFromPower(ePwr2, 5000));
                row.Pwr_P2_max_kW = fallback(row.Pwr_P2_max_kW, 0) + ePwr2;
                row.n_P2_max = 16000;
            end
        end

        % P4 / e-axle usability and torque plausibility at conversion stage.
        % Normal SUV/family PHEVs often cannot use the catalog e-machine value
        % as full continuous 0-100 boost, while performance PHEVs/hypercars must
        % not be torque-starved by scraper torque fields.
        if (row.P4 == 1 || row.P4_DM == 1) && isfinite(row.Pwr_P4_max_kW) && row.Pwr_P4_max_kW > 0
            isPerformanceHybrid = isfinite(raw.system_kW) && raw.system_kW >= 350;
            isHypercarHybrid = isfinite(raw.system_kW) && raw.system_kW >= 500 && row.Pwr_P4_max_kW >= 120;

            if isPluginHybridText && ~isPerformanceHybrid
                p4UsableFactor = 0.75;
                row.Pwr_P4_max_kW = row.Pwr_P4_max_kW * p4UsableFactor;
                if isfinite(row.tq_P4_max) && row.tq_P4_max > 0
                    row.tq_P4_max = row.tq_P4_max * p4UsableFactor;
                end
                warnings(end+1) = "normal PHEV P4 usable power factor applied"; %#ok<AGROW>
            end

            tqFloorRpm = 3000;
            if isHypercarHybrid
                tqFloorRpm = 2500;
            end
            tqMinP4_Nm = estimateTorqueFromPower(row.Pwr_P4_max_kW, tqFloorRpm);
            if isfinite(tqMinP4_Nm) && tqMinP4_Nm > 0 && ...
                    (~isfinite(row.tq_P4_max) || row.tq_P4_max <= 0 || row.tq_P4_max < 0.75 * tqMinP4_Nm)
                oldTqP4 = row.tq_P4_max;
                row.tq_P4_max = tqMinP4_Nm;
                warnings(end+1) = sprintf("P4 torque raised from power plausibility: %.1f -> %.1f Nm", ...
                    oldTqP4, row.tq_P4_max); %#ok<AGROW>
            end
        end

        % Clear architecture flags that did not receive a usable electric-machine
        % power value. Do not export rows like Hybrid + P2=1 + P2 power=0.
        if row.P0 == 1 && (~isfinite(row.Pwr_P0_max_kW) || row.Pwr_P0_max_kW <= 0)
            row.P0 = 0; row.tq_P0_max = 0; row.Pwr_P0_max_kW = 0; row.n_P0_max = 0;
            warnings(end+1) = "P0 flag cleared: no usable e-machine power"; %#ok<AGROW>
        end
        if row.P2 == 1 && (~isfinite(row.Pwr_P2_max_kW) || row.Pwr_P2_max_kW <= 0)
            row.P2 = 0; row.tq_P2_max = 0; row.Pwr_P2_max_kW = 0; row.n_P2_max = 0;
            warnings(end+1) = "P2 flag cleared: no usable e-machine power"; %#ok<AGROW>
        end
        if row.P3 == 1 && (~isfinite(row.Pwr_P3_max_kW) || row.Pwr_P3_max_kW <= 0)
            row.P3 = 0; row.tq_P3_max = 0; row.Pwr_P3_max_kW = 0; row.n_P3_max = 0;
            warnings(end+1) = "P3 flag cleared: no usable e-machine power"; %#ok<AGROW>
        end
        if (row.P4 == 1 || row.P4_DM == 1) && (~isfinite(row.Pwr_P4_max_kW) || row.Pwr_P4_max_kW <= 0)
            row.P4 = 0; row.P4_DM = 0; row.tq_P4_max = 0; row.Pwr_P4_max_kW = 0; row.n_P4_max = 0;
            warnings(end+1) = "P4 flag cleared: no usable e-machine power"; %#ok<AGROW>
        end

        % General HEV P2 torque plausibility cap. This is intentionally in the
        % converter so generated CSVs already contain realistic P2 torque.
        onlyP2Hybrid = row.P2 == 1 && row.P0 == 0 && row.P3 == 0 && row.P4 == 0 && row.P4_DM == 0;
        if onlyP2Hybrid && ~isPluginHybridText && isfinite(row.Pwr_P2_max_kW) && row.Pwr_P2_max_kW > 0 && ...
                isfinite(row.tq_P2_max) && row.tq_P2_max > 0
            tqCapFromP2Power = estimateTorqueFromPower(row.Pwr_P2_max_kW, 3000);
            if isfinite(tqCapFromP2Power) && tqCapFromP2Power > 0 && row.tq_P2_max > tqCapFromP2Power
                oldP2Tq = row.tq_P2_max;
                row.tq_P2_max = tqCapFromP2Power;
                warnings(end+1) = sprintf("HEV P2 torque capped from power plausibility: %.1f -> %.1f Nm", ...
                    oldP2Tq, row.tq_P2_max); %#ok<AGROW>
            end
        end

        if row.P0 + row.P2 + row.P3 + row.P4 + row.P4_DM == 0
            % Do not synthesize a traction hybrid in the launcher. If AMS does
            % not provide usable e-machine data, the row is excluded from the
            % DoE instead of being repaired later in DoE_main.
            warnings(end+1) = "hybrid excluded: no usable e-machine data"; %#ok<AGROW>
        end
    end

    if isEV
        row.n_EV_max = 16000;
        row.i_GET_EV = estimateEVTotalRatio(raw.vmax_kmh, row.d_wheel, row.n_EV_max);

        % EV power fields in AMS can mean system power, motor power or boost
        % power depending on the vehicle. For pure EVs use the largest
        % positive power value as total system power, then split by motor count.
        evMotorPowerSum = NaN;
        if isfinite(raw.ePower_kW) && raw.ePower_kW > 0 && isfinite(raw.ePower2_kW) && raw.ePower2_kW > 0
            evMotorPowerSum = raw.ePower_kW + raw.ePower2_kW;
        end
        evPwrCandidates = [raw.system_kW, raw.power_kW, evMotorPowerSum, ePwr1, raw.ePower2_kW];
        evPwrCandidates = evPwrCandidates(isfinite(evPwrCandidates) & evPwrCandidates > 0);
        if has2WDNameHint && ~hasAWDNameHint && isfinite(raw.power_kW) && raw.power_kW > 0 && ...
                isfinite(raw.system_kW) && raw.system_kW > 1.35 * raw.power_kW
            totalPwr = raw.power_kW;
            warnings(end+1) = "EV 2WD power_kW preferred over doubled system_kW"; %#ok<AGROW>
        elseif isempty(evPwrCandidates)
            totalPwr = 120;
            warnings(end+1) = "EV power fallback"; %#ok<AGROW>
        else
            totalPwr = max(evPwrCandidates);
        end

        evMotorTorqueSum = NaN;
        if isfinite(raw.eTorque_Nm) && raw.eTorque_Nm > 0 && isfinite(raw.eTorque2_Nm) && raw.eTorque2_Nm > 0
            evMotorTorqueSum = raw.eTorque_Nm + raw.eTorque2_Nm;
        end
        evTqCandidates = [raw.system_Nm, raw.torque_Nm, evMotorTorqueSum, eTq1, raw.eTorque2_Nm];
        evTqCandidates = evTqCandidates(isfinite(evTqCandidates) & evTqCandidates > 0);
        if isempty(evTqCandidates)
            totalTq = estimateTorqueFromPower(totalPwr, 4500);
            warnings(end+1) = "EV torque estimated"; %#ok<AGROW>
        else
            totalTq = max(evTqCandidates);
        end

        nMot = max(1, round(fallback(raw.eMotorCount, 1)));
        if has2WDNameHint && ~hasAWDNameHint
            nMot = 1;
        elseif row.AWD == 1 && nMot < 2
            nMot = 2;
        end
        perMotorPwr = totalPwr / nMot;
        perMotorTq = totalTq / nMot;

        % Plausibility floor: if AMS gives a very low motor torque while power
        % is high, the acceleration becomes unrealistically slow. Approximate
        % minimum constant-power base speed at 6000 rpm.
        tqMinFromPower = estimateTorqueFromPower(perMotorPwr, 6000);
        if isfinite(tqMinFromPower) && tqMinFromPower > 0 && perMotorTq < 0.75 * tqMinFromPower
            perMotorTq = tqMinFromPower;
            warnings(end+1) = "EV torque raised from power plausibility"; %#ok<AGROW>
        end

        % Only AWD EVs are mapped to E2/E3/E4 and the secondary axle in
        % this Simulink model. If AMS reports multiple motors but no AWD
        % evidence, they are combined into one equivalent E0 machine on the
        % driven axle. This avoids invalid rows like AWD=0 with E2/E4 and
        % Pwr_P4_max_kW > 0.
        isMultiMotorEV = row.AWD == 1 && ~(has2WDNameHint && ~hasAWDNameHint);
        if ~isMultiMotorEV && nMot > 1
            warnings(end+1) = "EV multi-motor but non-AWD mapped as equivalent E0; no secondary axle"; %#ok<AGROW>
        end

        if isMultiMotorEV
            if nMot >= 4
                row.E4 = 1;
            elseif nMot == 3
                row.E3 = 1;
            else
                row.E2 = 1;
            end
            row.Pwr_EV_max_kW = perMotorPwr;
            row.tq_EV_max = perMotorTq;
            row.n_EV_max = 16000;
            row.Pwr_EV_nmax_red_perc = 0.04;
            row.Pwr_P4_max_kW = perMotorPwr;
            row.tq_P4_max = perMotorTq;
            row.n_P4_max = 16000;
            row.i_ges_P4 = row.i_GET_EV;
            evArch = 2;
            if nMot == 3
                evArch = 3;
            elseif nMot >= 4
                evArch = 4;
            end
            warnings(end+1) = sprintf("EV multi-motor mapped to E%d; P4 flag kept 0 for pure EV", evArch); %#ok<AGROW>
        else
            % Single-motor EVs, including rear-wheel-drive vehicles with the
            % motor located at the rear axle, must stay on E0. They must not
            % get a synthetic P4/secondary-axle copy, otherwise the battery
            % check and the Simulink input effectively see 2x EV power.
            row.E0 = 1;
            row.Pwr_EV_max_kW = totalPwr;
            row.tq_EV_max = totalTq;
            row.n_EV_max = 16000;
            row.Pwr_EV_nmax_red_perc = 0.04;
            row.Pwr_P4_max_kW = 0;
            row.tq_P4_max = 0;
            row.n_P4_max = 0;
            row.i_ges_P4 = 0;
            if contains(eLoc, "hinten") && row.AWD == 0
                row.HM_VA = 0;
                row.weight_dist = estimateWeightDist(row.AWD, row.HM_VA, "hinterrad", engineLoc, body, true);
                warnings(end+1) = "EV rear single motor mapped to E0 primary axle; no P4 duplication"; %#ok<AGROW>
            end
        end
        % Pure EV must not be routed through hybrid P flags.
        row.P0 = 0; row.P2 = 0; row.P3 = 0; row.P4 = 0; row.P4_DM = 0;
    end

    if ~isEV && ~isHybrid
        % Pure ICE: no artificial electric components.
        row.P0 = 0; row.P2 = 0; row.P3 = 0; row.P4 = 0; row.P4_DM = 0;
        row.E0 = 0; row.E1 = 0; row.E2 = 0; row.E3 = 0; row.E4 = 0;
        row.Pwr_EV_max_kW = 0; row.tq_EV_max = 0; row.n_EV_max = 0; row.Pwr_EV_nmax_red_perc = 0;
    end

    % Treat weak 48V/P0-only mild hybrids as ICE for the straight-line model.
    % The model does not represent P0 as a real axle traction machine; keeping
    % these rows as full Hybrid made ICE-like vehicles too optimistic.
    eTractionPower_kW = fallback(row.Pwr_P2_max_kW, 0) + fallback(row.Pwr_P3_max_kW, 0) + fallback(row.Pwr_P4_max_kW, 0);
    eAllPowerNoEV_kW = fallback(row.Pwr_P0_max_kW, 0) + eTractionPower_kW;
    mildOnlyP0 = isHybrid && row.P0 == 1 && row.P2 == 0 && row.P3 == 0 && row.P4 == 0 && row.P4_DM == 0 && ...
        eAllPowerNoEV_kW > 0 && eAllPowerNoEV_kW <= 25 && ...
        (containsAny(allTxt, ["mhev", "mild", "48v", "48 v", "mild-hybrid", "mildhybrid"]) || ...
         (isfinite(voltage) && voltage <= 80));
    if mildOnlyP0
        % Some AMS mild-hybrid rows expose the 48V boost machine as
        % "Leistung" and the actual combustion/system vehicle power as
        % "Systemleistung". If we convert such P0-only vehicles to ICE
        % without repairing Pwr_ICE_max_kW, they become unrealistically slow
        % in the straight-line simulation.
        pIceBeforeP0 = max(fallback(row.Pwr_ICE_max_kW, 0), 0);
        if isfinite(raw.system_kW) && raw.system_kW > max(50, 2.5 * max(pIceBeforeP0, 1))
            row.Pwr_ICE_max_kW = raw.system_kW;
            row.tq_ICE_max = fallback(raw.system_Nm, fallback(raw.torque_Nm, estimateTorqueFromPower(row.Pwr_ICE_max_kW, raw.power_rpm)));
            if ~isfinite(row.tq_ICE_max) || row.tq_ICE_max <= 0
                row.tq_ICE_max = estimateTorqueFromPower(row.Pwr_ICE_max_kW, 5000);
            end
            row.tq_ICE_idle = 0.20 * row.tq_ICE_max;
            warnings(end+1) = "P0-only mild hybrid ICE power repaired from system power"; %#ok<AGROW>
        elseif pIceBeforeP0 <= 25 && ~isfinite(raw.system_kW)
            warnings(end+1) = "P0-only mild hybrid has no system power; validation quality reduced"; %#ok<AGROW>
        end

        row.Powertrain = "ICE";
        row.VM = 1; row.EV = 0; row.Hy = 0;
        row.P0 = 0; row.P2 = 0; row.P3 = 0; row.P4 = 0; row.P4_DM = 0;
        row.E0 = 0; row.E1 = 0; row.E2 = 0; row.E3 = 0; row.E4 = 0;
        row.tq_P0_max = 0; row.Pwr_P0_max_kW = 0; row.n_P0_max = 0;
        row.tq_P2_max = 0; row.Pwr_P2_max_kW = 0; row.n_P2_max = 0;
        row.tq_P3_max = 0; row.Pwr_P3_max_kW = 0; row.n_P3_max = 0;
        row.tq_P4_max = 0; row.Pwr_P4_max_kW = 0; row.n_P4_max = 0;
        row.tq_EV_max = 0; row.Pwr_EV_max_kW = 0; row.n_EV_max = 0; row.Pwr_EV_nmax_red_perc = 0;
        isHybrid = false;
        warnings(end+1) = "P0-only mild hybrid treated as ICE"; %#ok<AGROW>
    end

    % Replace invalid E-machine values by zero.
    emFields = {"tq_P0_max","Pwr_P0_max_kW","n_P0_max","tq_P2_max","Pwr_P2_max_kW","n_P2_max", ...
                "tq_P3_max","Pwr_P3_max_kW","n_P3_max","tq_P4_max","Pwr_P4_max_kW","n_P4_max", ...
                "tq_EV_max","Pwr_EV_max_kW","n_EV_max"};
    for k = 1:numel(emFields)
        f = emFields{k};
        if ~isfinite(row.(f))
            row.(f) = 0;
        end
    end

    row.Pwr_P0_nmax_red_perc = 0.0;
    row.Pwr_P2_nmax_red_perc = 0.0;
    row.Pwr_P3_nmax_red_perc = 0.0;
    row.Pwr_P4_nmax_red_perc = 0.0;
    if ~isfield(row, 'Pwr_EV_nmax_red_perc') || ~isfinite(row.Pwr_EV_nmax_red_perc)
        row.Pwr_EV_nmax_red_perc = 0.04;
    end

    % Simulation-control outputs from converter. DoE_main only reads these.
    row.HybridArchitectureClass = classifyHybridArchitectureConverter(row, allTxt);
    [row.hybrid_p2_cont_factor, row.hybrid_p2_shift_factor] = ...
        estimateHybridP2FactorsConverter(row, allTxt);
    row = assignEV2SpeedDefaultsConverter(row, raw, warnings);

    % Battery/cell fallback. ICE gets a tiny dummy pack so BatteryConfig can
    % still compute without creating a fake 96S46P traction battery.
    row.Cell_Cap_Ah = 4.8;
    row.Cell_V_nom = 3.7;
    row.Cell_R_inner = 0.023;
    row.Cell_V_min = 2.5;
    row.Cell_V_max = 4.2;
    row.Cell_I_max_chg = 4.8;
    row.Cell_I_max_dis = 15;
    row.SOC_Vector = "[0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]";
    row.Cell_OCV_Vector = "[2.8, 3.3, 3.45, 3.52, 3.60, 3.68, 3.75, 3.85, 3.95, 4.1, 4.2]";

    packEnergy_kWh = fallback(raw.battNet_kWh, raw.battGross_kWh);
    if isEV || isHybrid
        if isfinite(raw.battVoltage_V) && raw.battVoltage_V > 0
            row.n_s = max(1, round(raw.battVoltage_V / row.Cell_V_nom));
        elseif isHybrid && isfinite(ePwr1) && ePwr1 <= 35
            row.n_s = 13;  % approx. 48 V mild hybrid
            warnings(end+1) = "48V battery voltage estimated"; %#ok<AGROW>
        else
            row.n_s = 96;
            warnings(end+1) = "battery voltage estimated"; %#ok<AGROW>
        end

        if isfinite(packEnergy_kWh) && packEnergy_kWh > 0
            row.n_p = max(1, round(packEnergy_kWh * 1000 / (row.n_s * row.Cell_V_nom * row.Cell_Cap_Ah)));
        elseif isHybrid && row.n_s <= 20
            row.n_p = 2;
            warnings(end+1) = "mild-hybrid battery capacity estimated"; %#ok<AGROW>
        elseif isHybrid
            row.n_p = 6;
            warnings(end+1) = "hybrid battery capacity estimated"; %#ok<AGROW>
        else
            row.n_p = 46;
            warnings(end+1) = "EV battery capacity estimated"; %#ok<AGROW>
        end
    else
        row.n_s = 1;
        row.n_p = 1;
    end

    if isEV || isHybrid
        [row, battWarn] = repairBatteryDischargePowerConverter(row);
        if strlength(battWarn) > 0
            warnings(end+1) = battWarn; %#ok<AGROW>
        end
    end

    row.facSocInit = 0.95;
    row.SOC_Recup_Limit = 0.95;
    row.SOC_Bat_Discharge_Limit = 0.10;

    quality = 100;
    quality = quality - 5 * sum(contains(warnings, "estimated"));
    quality = quality - 8 * sum(contains(warnings, "fallback"));
    quality = quality - 10 * sum(contains(warnings, "repaired"));
    quality = quality - 40 * sum(contains(warnings, "suspicious"));
    row.InputQualityScore = max(0, quality);
    row.InputWarnings = strjoin(warnings, " | ");
end

function tf = isUsableDoeRow(row)
    hasMass = isfinite(row.m_curb) && row.m_curb > 200;
    hasPower = (isfinite(row.Pwr_ICE_max_kW) && row.Pwr_ICE_max_kW > 0) || ...
               (isfinite(row.Pwr_EV_max_kW) && row.Pwr_EV_max_kW > 0) || ...
               (isfinite(row.Pwr_P0_max_kW) && row.Pwr_P0_max_kW > 0) || ...
               (isfinite(row.Pwr_P2_max_kW) && row.Pwr_P2_max_kW > 0) || ...
               (isfinite(row.Pwr_P4_max_kW) && row.Pwr_P4_max_kW > 0);
    hasWheelbase = isfinite(row.Wheelbase) && row.Wheelbase > 1.5;
    hasArea = isfinite(row.A_front) && row.A_front > 1.0;
    isSuspiciousEV = strcmpi(string(row.Powertrain), "EV") && contains(string(row.InputWarnings), "suspicious EV");
    isCvtExcluded = contains(string(row.InputWarnings), "CVT/e-CVT excluded") || ...
        (isfield(row, 'Transmission_Type') && strcmpi(string(row.Transmission_Type), "cvt_excluded"));
    isHybridExcluded = strcmpi(string(row.Powertrain), "Hybrid") && ...
        contains(string(row.InputWarnings), "hybrid excluded");
    hybridHasUsableEM = ~strcmpi(string(row.Powertrain), "Hybrid") || ...
        ((row.P0 == 1 && row.Pwr_P0_max_kW > 0) || ...
         (row.P2 == 1 && row.Pwr_P2_max_kW > 0) || ...
         (row.P3 == 1 && row.Pwr_P3_max_kW > 0) || ...
         ((row.P4 == 1 || row.P4_DM == 1) && row.Pwr_P4_max_kW > 0));
    tf = hasMass && hasPower && hasWheelbase && hasArea && ~isSuspiciousEV && ...
        ~isCvtExcluded && ~isHybridExcluded && hybridHasUsableEM;
end

%% ------------------------- DoE schema -------------------------

function cols = getDoeColumns()
    cols = { ...
        'RUN_ID', 'Vehicle_Name', 'Source_URL', 'Powertrain', 'Raw_Fuel', 'Raw_Gearbox', ...
        'Raw_Drive', 'Raw_Power', 'Raw_Torque', 'Raw_SystemPower', ...
        'Actual_0_to_100_s', 'Actual_max_speed_kmh', 'InputQualityScore', 'InputWarnings', ...
        'd_wheel', 'A_front', 'HM_VA', 'AWD', 'iAG', ...
        'm_curb', 'Wheelbase', 'h_s', 'weight_dist', 'MainAxle_TorqueSplit_int', ...
        'Hybrid_ICE_priority', 'HybridArchitectureClass', ...
        'hybrid_p2_cont_factor', 'hybrid_p2_shift_factor', ...
        'VM', 'EV', 'Hy', 'E0', 'E1', 'E2', 'E3', 'E4', ...
        'i_GET_EV', 'i_ges_P4', ...
        'EV_2speed_enable', 'i_GET_EV_gear1', 'i_GET_EV_gear2', ...
        'i_ges_P4_gear1', 'i_ges_P4_gear2', 'ev_shift_v_up_kmh', 'ev_shift_v_down_kmh', ...
        'mode', 'use_cus_val', 'Gear_Ratio', 'No_Gears', ...
        'shiftDelay', 'Transmission_Type', 'Displacement_cc', 'Induction_Type', 'Boost_Pressure_bar', ...
        'P0', 'P2', 'P3', 'P4', 'P4_DM', ...
        'n_ICE_idle', 'n_ICE_max', 'tq_ICE_idle', 'tq_ICE_max', 'Pwr_ICE_max_kW', ...
        'tq_P0_max', 'Pwr_P0_max_kW', 'n_P0_max', 'Pwr_P0_nmax_red_perc', ...
        'tq_P2_max', 'Pwr_P2_max_kW', 'n_P2_max', 'Pwr_P2_nmax_red_perc', ...
        'tq_P3_max', 'Pwr_P3_max_kW', 'n_P3_max', 'Pwr_P3_nmax_red_perc', ...
        'tq_P4_max', 'Pwr_P4_max_kW', 'n_P4_max', 'Pwr_P4_nmax_red_perc', ...
        'tq_EV_max', 'Pwr_EV_max_kW', 'n_EV_max', 'Pwr_EV_nmax_red_perc', ...
        'Cell_Cap_Ah', 'Cell_V_nom', 'Cell_R_inner', 'Cell_V_min', 'Cell_V_max', ...
        'Cell_I_max_chg', 'Cell_I_max_dis', 'SOC_Vector', 'Cell_OCV_Vector', ...
        'n_s', 'n_p', 'facSocInit', 'SOC_Recup_Limit', 'SOC_Bat_Discharge_Limit'};
end

function row = makeEmptyDoeRow(cols)
    row = struct();
    for k = 1:numel(cols)
        row.(cols{k}) = 0;
    end
    row.Vehicle_Name = "";
    row.Source_URL = "";
    row.Powertrain = "ICE";
    row.Raw_Fuel = "";
    row.Raw_Gearbox = "";
    row.Raw_Drive = "";
    row.Raw_Power = "";
    row.Raw_Torque = "";
    row.Raw_SystemPower = "";
    row.InputWarnings = "";
    row.HybridArchitectureClass = "none";
    row.hybrid_p2_cont_factor = 1.0;
    row.hybrid_p2_shift_factor = 1.0;
    row.EV_2speed_enable = 0;
    row.i_GET_EV_gear1 = 0;
    row.i_GET_EV_gear2 = 0;
    row.i_ges_P4_gear1 = 0;
    row.i_ges_P4_gear2 = 0;
    row.ev_shift_v_up_kmh = 1e6;
    row.ev_shift_v_down_kmh = 1e6;
    row.mode = "performance";
    row.Gear_Ratio = "[]";
    row.Transmission_Type = "unknown";
    row.Induction_Type = "NA";
    row.SOC_Vector = "[0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]";
    row.Cell_OCV_Vector = "[2.8, 3.3, 3.45, 3.52, 3.60, 3.68, 3.75, 3.85, 3.95, 4.1, 4.2]";
end

function meta = makeEmptyMetaRow()
    meta = struct();
    meta.RUN_ID = 0;
    meta.Vehicle_Name = "";
    meta.Brand_URL = "";
    meta.Series_URL = "";
    meta.Generation_URL = "";
    meta.Techdata_URL = "";
    meta.Bodytype = "";
    meta.Source_Year_or_Column = "";
    meta.Powertrain_Resolved = "";
    meta.InputQualityScore = NaN;
    meta.InputWarnings = "";
    meta.Raw_Fuel = "";
    meta.Raw_Power = "";
    meta.Raw_Torque = "";
    meta.Raw_SystemPower = "";
    meta.Raw_SystemTorque = "";
    meta.Raw_Gearbox = "";
    meta.Raw_Drive = "";
    meta.Raw_Dimensions = "";
    meta.Raw_Weight = "";
    meta.Actual_0_to_100_s = NaN;
    meta.Actual_max_speed_kmh = NaN;
    meta.PowerToWeight_kW_per_t = NaN;
    meta.Valid_Actual_0_to_100 = false;
    meta.Actual_0_to_100_Warning = "";
end

function a = makeEmptyActualRow()
    a = struct();
    a.RUN_ID = 0;
    a.Vehicle_Name = "";
    a.Powertrain = "";
    a.Actual_0_to_100_s = NaN;
    a.Actual_max_speed_kmh = NaN;
    a.PowerToWeight_kW_per_t = NaN;
    a.Valid_Actual_0_to_100 = false;
    a.Actual_0_to_100_Warning = "";
    a.Source_URL = "";
end

%% ------------------------- JSON helpers -------------------------

function [jsonFile, tmpFolder] = prepareJsonInput(inputFile)
    tmpFolder = "";
    inputFile = string(inputFile);
    if ~isfile(inputFile)
        error("Input file not found: %s", inputFile);
    end

    [~, ~, ext] = fileparts(inputFile);
    ext = safeLowerString(ext);

    if ext == ".zip"
        tmpFolder = string(tempname);
        mkdir(tmpFolder);
        files = unzip(inputFile, tmpFolder);
        filesStr = string(files);
        jsonFiles = files(endsWith(lower(filesStr), ".json"));
        if isempty(jsonFiles)
            error("ZIP contains no JSON file: %s", inputFile);
        end
        jsonFile = string(jsonFiles(1));
    elseif ext == ".json"
        jsonFile = inputFile;
    else
        error("Input must be .json or .zip, got: %s", ext);
    end
end

function cleanupTempFolder(tmpFolder)
    if strlength(string(tmpFolder)) > 0 && isfolder(tmpFolder)
        try
            rmdir(tmpFolder, 's');
        catch
        end
    end
end

function cols = getVariantColumns(item)
    cols = {};
    try
        if isfield(item, "table") && isfield(item.table, "columns")
            c = item.table.columns;
            if iscell(c)
                cols = c(:).';
            elseif isstring(c)
                cols = cellstr(c(:).');
            elseif ischar(c)
                cols = {c};
            end
        end
    catch
        cols = {};
    end
end

function s = getTopString(item, fieldName)
    s = "";
    f = findFieldName(item, fieldName);
    if strlength(f) == 0
        return;
    end
    v = item.(f);
    s = valueToString(v, 1);
end

function s = getTableValue(item, sectionNames, fieldNames, idx)
    s = "";
    if ~isfield(item, "table") || ~isfield(item.table, "sections")
        return;
    end
    sections = item.table.sections;

    for k = 1:numel(sectionNames)
        secName = findFieldName(sections, sectionNames{k});
        if strlength(secName) == 0
            continue;
        end
        sec = sections.(secName);
        s = getValueFromStruct(sec, fieldNames, idx);
        if strlength(s) > 0
            return;
        end
    end

    % Fallback: search all sections.
    secNames = fieldnames(sections);
    for i = 1:numel(secNames)
        sec = sections.(secNames{i});
        if ~isstruct(sec)
            continue;
        end
        s = getValueFromStruct(sec, fieldNames, idx);
        if strlength(s) > 0
            return;
        end
    end
end

function s = getValueFromStruct(st, fieldNames, idx)
    s = "";
    if ~isstruct(st)
        return;
    end

    fNames = fieldnames(st);
    for k = 1:numel(fieldNames)
        target = string(fieldNames{k});
        f = findFieldName(st, target);
        if strlength(f) > 0
            s = valueToString(st.(f), idx);
            if strlength(s) > 0
                return;
            end
        end

        % Special robust match for 0-100 km/h after jsondecode name mangling.
        if contains(normalizeLabel(target), "0100") || contains(normalizeLabel(target), "100kmh")
            for i = 1:numel(fNames)
                nf = normalizeLabel(fNames{i});
                if contains(nf, "100") && (contains(nf, "km") || contains(nf, "h"))
                    s = valueToString(st.(fNames{i}), idx);
                    if strlength(s) > 0
                        return;
                    end
                end
            end
        end
    end
end

function f = findFieldName(st, target)
    f = "";
    if ~isstruct(st)
        return;
    end
    names = fieldnames(st);
    if isempty(names)
        return;
    end

    targetNorm = normalizeLabel(target);
    if strlength(targetNorm) == 0
        return;
    end

    % Exact normalized match.
    for i = 1:numel(names)
        if normalizeLabel(names{i}) == targetNorm
            f = string(names{i});
            return;
        end
    end

    % Controlled contains match: allow only field-name contains target.
    % DO NOT allow contains(target, field), otherwise a target like
    % "E-Motor Leistung" incorrectly matches the generic AMS field "Leistung".
    % That was the reason almost every ICE became Hybrid.
    for i = 1:numel(names)
        n = normalizeLabel(names{i});
        if strlength(n) >= strlength(targetNorm) + 3 && contains(n, targetNorm)
            f = string(names{i});
            return;
        end
    end
end

function n = normalizeLabel(s)
    s = safeLowerString(s);
    s = replace(s, ["ä","ö","ü","ß","é","è","à"], ["ae","oe","ue","ss","e","e","a"]);
    s = regexprep(s, "[^a-z0-9]", "");
    n = s;
end

function s = valueToString(v, idx)
    if nargin < 2 || ~isfinite(idx) || idx < 1
        idx = 1;
    end
    try
        if iscell(v)
            if isempty(v)
                s = "";
            elseif idx <= numel(v)
                s = safeStringScalar(v{idx});
            else
                s = safeStringScalar(v{1});
            end
        elseif isstring(v)
            if isempty(v)
                s = "";
            elseif idx <= numel(v)
                s = safeStringScalar(v(idx));
            else
                s = safeStringScalar(v(1));
            end
        elseif isnumeric(v) || islogical(v)
            if isempty(v)
                s = "";
            elseif idx <= numel(v)
                s = safeStringScalar(v(idx));
            else
                s = safeStringScalar(v(1));
            end
        else
            s = safeStringScalar(v);
        end
    catch
        s = "";
    end
end

%% ------------------------- robust string helpers -------------------------

function s = safeStringScalar(v)
    % MATLAB string <missing> cannot be converted with char(string(v)).
    % This helper converts missing/empty/cell/numeric values into a safe
    % scalar string and returns "" for values that cannot be represented.
    s = "";
    try
        if nargin < 1 || isempty(v)
            return;
        end
        if iscell(v)
            if isempty(v)
                return;
            end
            s = safeStringScalar(v{1});
            return;
        elseif isstring(v)
            if isempty(v)
                return;
            end
            s = v(1);
        elseif ischar(v)
            s = string(v);
        elseif isnumeric(v) || islogical(v)
            if isempty(v)
                return;
            end
            val = v(1);
            if isnumeric(val) && ~isfinite(val)
                return;
            end
            s = string(val);
        else
            s = string(v);
        end
    catch
        s = "";
        return;
    end

    try
        if any(ismissing(s), "all")
            s = "";
            return;
        end
    catch
        try
            if any(ismissing(s))
                s = "";
                return;
            end
        catch
            s = "";
            return;
        end
    end

    try
        s = strtrim(s);
    catch
        s = "";
    end
end

function s = safeLowerString(v)
    s = lower(safeStringScalar(v));
end

function c = safeChar(v)
    c = char(safeStringScalar(v));
end

function x = parseLocalizedNumberToken(tok, allowThousands)
    % Parses German/English numeric tokens robustly.
    % Examples with allowThousands=true:
    %   "1.103" -> 1103, "1,103" -> 1103, "1.103,5" -> 1103.5
    % Examples with allowThousands=false:
    %   "3.54" -> 3.54, "3,54" -> 3.54
    if nargin < 2
        allowThousands = true;
    end

    tok = safeChar(tok);
    tok = strtrim(tok);
    tok = regexprep(tok, '\s+', '');
    if isempty(tok)
        x = NaN;
        return;
    end

    hasDot = ~isempty(strfind(tok, '.'));
    hasComma = ~isempty(strfind(tok, ','));

    if hasDot && hasComma
        idxDot = find(tok == '.', 1, 'last');
        idxComma = find(tok == ',', 1, 'last');
        if idxComma > idxDot
            % German style: 1.103,5
            tok = strrep(tok, '.', '');
            tok = strrep(tok, ',', '.');
        else
            % English style: 1,103.5
            tok = strrep(tok, ',', '');
        end
    elseif hasComma
        if allowThousands && ~isempty(regexp(tok, '^[+-]?\d{1,3}(,\d{3})+$', 'once'))
            tok = strrep(tok, ',', '');
        else
            tok = strrep(tok, ',', '.');
        end
    elseif hasDot
        if allowThousands && ~isempty(regexp(tok, '^[+-]?\d{1,3}(\.\d{3})+$', 'once'))
            tok = strrep(tok, '.', '');
        end
    end

    x = str2double(tok);
end

%% ------------------------- parsers -------------------------

function x = parseFirstNumber(s)
    if isnumeric(s) && isscalar(s)
        if isfinite(s)
            x = double(s);
        else
            x = NaN;
        end
        return;
    end

    c = safeChar(s);
    if isempty(strtrim(c))
        x = NaN;
        return;
    end

    tok = regexp(c, '[-+]?\d+(?:[\.,]\d+)*', 'match', 'once');
    if isempty(tok)
        x = NaN;
    else
        x = parseLocalizedNumberToken(tok, true);
    end
end

function x = parsePositiveNumber(s)
    x = parseFirstNumber(s);
    if ~isfinite(x) || x <= 0
        x = NaN;
    end
end

function v = parseSpeedKmh(s)
    c = safeChar(s);
    v = NaN;
    if isempty(strtrim(c))
        return;
    end
    toks = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*km\s*/?\s*h', 'tokens', 'ignorecase');
    if ~isempty(toks)
        vals = cellfun(@(cc) parseLocalizedNumberToken(cc{1}, true), toks);
        vals = vals(isfinite(vals) & vals > 20);
        if ~isempty(vals)
            v = vals(end);
            return;
        end
    end
    v = parseFirstNumber(c);
    if ~isfinite(v) || v <= 20
        v = NaN;
    end
end

function p = parsePowerKW(s)
    c = safeChar(s);
    p = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*kW', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        p = parseLocalizedNumberToken(tok{1}, true);
        return;
    end
    tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*PS', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        p = parseLocalizedNumberToken(tok{1}, true) * 0.735499;
    end
end

function tq = parseTorqueNm(s)
    c = safeChar(s);
    tq = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*Nm', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        tq = parseLocalizedNumberToken(tok{1}, true);
    end
end

function rpm = parseRpmAt(s)
    c = safeChar(s);
    rpm = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, 'bei\s*([-+]?\d+(?:[\.,]\d+)*)\s*U\s*/\s*min', 'tokens', 'once', 'ignorecase');
    if isempty(tok)
        tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*U\s*/\s*min', 'tokens', 'once', 'ignorecase');
    end
    if ~isempty(tok)
        rpm = parseLocalizedNumberToken(tok{1}, true);
    end
end

function r = parseRatio(s)
    c = safeChar(s);
    r = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*:?\s*1?', 'tokens', 'once');
    if ~isempty(tok)
        r = parseLocalizedNumberToken(tok{1}, false);
    end
end

function gr = parseGearRatios(s)
    gr = [];
    c = safeChar(s);
    if isempty(strtrim(c))
        return;
    end
    lines = regexp(c, '\r\n|\n|\r', 'split');
    for i = 1:numel(lines)
        line = strtrim(lines{i});
        tok = regexp(line, '^(I|II|III|IV|V|VI|VII|VIII|IX|X)\.\s*([-+]?\d+(?:[\.,]\d+)*)', 'tokens', 'once', 'ignorecase');
        if ~isempty(tok)
            gr(end+1) = parseLocalizedNumberToken(tok{2}, false); %#ok<AGROW>
        end
    end
    gr = gr(isfinite(gr) & gr > 0);
end

function [L, W, H] = parseDimensions(s)
    L = NaN; W = NaN; H = NaN;
    c = safeChar(s);
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*x\s*([-+]?\d+(?:[\.,]\d+)*)\s*x\s*([-+]?\d+(?:[\.,]\d+)*)\s*mm', 'tokens', 'once', 'ignorecase');
    if isempty(tok)
        tok = regexp(c, '([-+]?\d+(?:[\.,]\d+)*)\s*x\s*([-+]?\d+(?:[\.,]\d+)*)\s*x\s*([-+]?\d+(?:[\.,]\d+)*)', 'tokens', 'once', 'ignorecase');
    end
    if ~isempty(tok)
        L = parseLocalizedNumberToken(tok{1}, true) / 1000;
        W = parseLocalizedNumberToken(tok{2}, true) / 1000;
        H = parseLocalizedNumberToken(tok{3}, true) / 1000;
    end
end

function P_kW = totalElectricPropulsionPowerConverter(row)
    P_kW = 0;
    if ~isstruct(row)
        return;
    end
    if isfield(row, 'EV') && row.EV == 1 && row.Hy == 0
        primaryMotors = double(row.E0 == 1 || row.E1 == 1 || row.E2 == 1 || row.E3 == 1 || row.E4 == 1);
        secondaryMotors = 0;
        if row.E2 == 1
            secondaryMotors = 1;
        elseif row.E3 == 1
            secondaryMotors = 2;
        elseif row.E4 == 1
            secondaryMotors = 3;
        end
        pEV = max(fallback(row.Pwr_EV_max_kW, 0), 0);
        pP4 = max(fallback(row.Pwr_P4_max_kW, 0), 0);
        % Do not silently copy pEV to pP4. A rear single-motor EV uses E0 and
        % Pwr_P4_max_kW = 0. Copying pEV here was the root cause for the
        % apparent 2x battery power request in several RWD EV rows.
        P_kW = primaryMotors * pEV + secondaryMotors * pP4;
    else
        P_kW = max(fallback(row.Pwr_P0_max_kW, 0), 0) + ...
               max(fallback(row.Pwr_P2_max_kW, 0), 0) + ...
               max(fallback(row.Pwr_P3_max_kW, 0), 0) + ...
               max(fallback(row.Pwr_P4_max_kW, 0), 0);
        if isfield(row, 'P4_DM') && row.P4_DM == 1
            P_kW = P_kW + max(fallback(row.Pwr_P4_max_kW, 0), 0);
        end
    end
end


function P_kW = totalVehiclePowerForPlausibility(row)
    P_kW = NaN;
    if ~isstruct(row)
        return;
    end
    if isfield(row, 'EV') && row.EV == 1 && isfield(row, 'Hy') && row.Hy == 0
        P_kW = totalElectricPropulsionPowerConverter(row);
        return;
    end

    pICE = max(fallback(row.Pwr_ICE_max_kW, 0), 0);
    pEM  = totalElectricPropulsionPowerConverter(row);
    if isfield(row, 'Hy') && row.Hy == 1
        % Conservative validation power: ICE plus traction e-machine power.
        % This is only used for flagging impossible actual 0-100 values, not
        % as a simulation input.
        P_kW = pICE + pEM;
    else
        P_kW = pICE;
    end
end

function [p2w_kW_per_t, validActual, warningText] = checkActual0100Plausibility(row, t0100_s)
    P_kW = totalVehiclePowerForPlausibility(row);
    if isfinite(P_kW) && isfield(row, 'm_curb') && isfinite(row.m_curb) && row.m_curb > 0
        p2w_kW_per_t = P_kW / row.m_curb * 1000;
    else
        p2w_kW_per_t = NaN;
    end

    validActual = true;
    warningText = "";

    if ~isfinite(t0100_s) || t0100_s <= 0
        validActual = false;
        warningText = "actual 0-100 missing";
        return;
    end

    if t0100_s < 2.0 || t0100_s > 45.0
        validActual = false;
        warningText = "actual 0-100 outside physical validation range";
        return;
    end

    warnStr = "";
    if isfield(row, 'InputWarnings')
        warnStr = string(row.InputWarnings);
    end
    if isfield(row, 'Powertrain') && strcmpi(string(row.Powertrain), "EV") && contains(warnStr, "EV power fallback")
        validActual = false;
        warningText = "actual 0-100 excluded: EV power fallback";
        return;
    end
    if contains(warnStr, "mass fallback")
        validActual = false;
        warningText = "actual 0-100 excluded: mass fallback";
        return;
    end

    if ~isfinite(p2w_kW_per_t)
        warningText = "actual 0-100 not checked: power-to-weight unavailable";
        return;
    end

    isLaunchCapable = false;
    if isfield(row, 'AWD') && row.AWD == 1
        isLaunchCapable = true;
    end
    if isfield(row, 'EV') && row.EV == 1
        isLaunchCapable = true;
    end

    tooFast = false;
    if isLaunchCapable
        % AWD/EV/launch-control vehicles can achieve very short 0-100 times
        % despite only moderate kW/t because the start is traction-limited.
        if p2w_kW_per_t < 50 && t0100_s < 8.5
            tooFast = true;
        elseif p2w_kW_per_t < 75 && t0100_s < 6.8
            tooFast = true;
        elseif p2w_kW_per_t < 100 && t0100_s < 5.3
            tooFast = true;
        elseif p2w_kW_per_t < 150 && t0100_s < 4.0
            tooFast = true;
        elseif p2w_kW_per_t < 200 && t0100_s < 3.2
            tooFast = true;
        elseif p2w_kW_per_t < 300 && t0100_s < 2.4
            tooFast = true;
        end
    else
        if p2w_kW_per_t < 50 && t0100_s < 8.5
            tooFast = true;
        elseif p2w_kW_per_t < 75 && t0100_s < 6.8
            tooFast = true;
        elseif p2w_kW_per_t < 100 && t0100_s < 5.5
            tooFast = true;
        elseif p2w_kW_per_t < 150 && t0100_s < 4.3
            tooFast = true;
        elseif p2w_kW_per_t < 200 && t0100_s < 3.4
            tooFast = true;
        elseif p2w_kW_per_t < 300 && t0100_s < 2.5
            tooFast = true;
        end
    end

    tooSlow = false;
    if p2w_kW_per_t > 250 && t0100_s > 12.0
        tooSlow = true;
    elseif p2w_kW_per_t > 150 && t0100_s > 18.0
        tooSlow = true;
    end

    if tooFast
        validActual = false;
        warningText = sprintf("actual 0-100 implausibly fast for %.1f kW/t", p2w_kW_per_t);
    elseif tooSlow
        validActual = false;
        warningText = sprintf("actual 0-100 implausibly slow for %.1f kW/t", p2w_kW_per_t);
    end
end

function [row, warningText] = repairBatteryDischargePowerConverter(row)
    warningText = "";
    P_req_kW = totalElectricPropulsionPowerConverter(row);
    if ~isfinite(P_req_kW) || P_req_kW <= 0
        return;
    end

    Vcell = fallback(row.Cell_V_nom, 3.7);
    if ~isfinite(Vcell) || Vcell <= 0
        Vcell = 3.7;
        row.Cell_V_nom = Vcell;
    end
    row.n_s = max(1, round(fallback(row.n_s, 1)));
    row.n_p = max(1, round(fallback(row.n_p, 1)));

    V_pack_nom = row.n_s * Vcell;
    P_target_kW = 1.10 * P_req_kW;
    I_req_A = P_target_kW * 1000 / (V_pack_nom * row.n_p);
    I_old_A = fallback(row.Cell_I_max_dis, 15);

    if isfinite(I_req_A) && I_req_A > I_old_A
        I_cap_A = 60;
        if I_req_A <= I_cap_A
            row.Cell_I_max_dis = I_req_A;
        else
            row.Cell_I_max_dis = I_cap_A;
            np_req = ceil(P_target_kW * 1000 / (V_pack_nom * row.Cell_I_max_dis));
            if isfinite(np_req) && np_req > row.n_p
                row.n_p = np_req;
            end
        end
        warningText = sprintf("battery discharge capability raised for electric power plausibility: P_req=%.1f kW, Icell %.1f->%.1f A, n_p=%d", ...
            P_req_kW, I_old_A, row.Cell_I_max_dis, row.n_p);
    end
end


function tf = isGenericVehicleName(name)
    s = safeLowerString(name);
    if strlength(s) == 0
        tf = true;
        return;
    end
    genericTokens = ["coup", "sportwagen", "limousine", "suv", "gelaende", "kombi", ...
        "van", "benziner", "diesel", "elektro", "ab "];
    hasSpecificUrlLikeName = containsAny(s, ["ferrari", "porsche", "bmw", "mercedes", "audi", ...
        "opel", "peugeot", "renault", "hyundai", "nissan", "mitsubishi", "volkswagen", ...
        "vw", "toyota", "honda", "tesla", "lotus"]);
    tf = (~hasSpecificUrlLikeName && containsAny(s, genericTokens)) || ...
         (strlength(s) < 4) || contains(s, "/");
end

function nameOut = vehicleNameFromAmsUrl(urlText)
    nameOut = "";
    u = safeLowerString(urlText);
    if strlength(u) == 0
        return;
    end
    try
        parts = split(u, "/");
        parts = parts(strlength(parts) > 0);
        idx = find(parts == "technische-daten", 1);
        if isempty(idx) || idx < 3
            return;
        end
        brand = parts(idx-2);
        model = parts(idx-1);
        brand = titleCaseSlug(brand);
        model = titleCaseSlug(model);
        nameOut = strtrim(brand + " " + model);
    catch
        nameOut = "";
    end
end

function s = titleCaseSlug(x)
    x = replace(safeLowerString(x), ["-", "_"], " ");
    words = split(x);
    out = strings(size(words));
    for i = 1:numel(words)
        w = words(i);
        if strlength(w) == 0
            out(i) = "";
        elseif any(w == ["amg", "bmw", "vw", "gti", "phev", "gt", "ev"])
            out(i) = upper(w);
        else
            c = char(w);
            out(i) = string([upper(c(1)), c(2:end)]);
        end
    end
    s = strjoin(out(strlength(out) > 0), " ");
end

function cls = classifyHybridArchitectureConverter(row, allTxt)
    if ~(isfield(row, 'Hy') && row.Hy == 1)
        cls = "none";
        return;
    end
    txt = safeLowerString(allTxt);
    if containsAny(txt, ["e-power", "epower", "range extender", "rex"])
        cls = "series_like_or_complex";
    elseif containsAny(txt, ["e-tech", "e tech"])
        cls = "series_like_or_complex";
    elseif row.P4 == 1 || row.P4_DM == 1
        if containsAny(txt, ["phev", "plug-in", "plugin", "plug in", "hybrid4", "4xe", "q4"])
            cls = "p4_phev_eaxle";
        else
            cls = "p4_hybrid_eaxle";
        end
    elseif row.P2 == 1
        if containsAny(txt, ["phev", "plug-in", "plugin", "plug in"])
            cls = "p2_phev";
        else
            cls = "p2_hev";
        end
    elseif row.P0 == 1
        cls = "p0_mhev";
    else
        cls = "hybrid_other";
    end
end

function [contFactor, shiftFactor] = estimateHybridP2FactorsConverter(row, allTxt)
    contFactor = 1.0;
    shiftFactor = 1.0;
    if ~(isfield(row, 'Hy') && row.Hy == 1 && isfield(row, 'P2') && row.P2 == 1)
        return;
    end
    txt = safeLowerString(allTxt);
    p2Power_kW = max(fallback(row.Pwr_P2_max_kW, 0), 0);
    isMHEV = containsAny(txt, ["mhev", "mild", "48v", "48 v", "mild-hybrid", "mildhybrid"]);
    isPHEV = containsAny(txt, ["phev", "plug-in", "plugin", "plug in"]);

    if isMHEV || p2Power_kW <= 20
        contFactor = 0.00;
        shiftFactor = 0.15;
    elseif isPHEV || p2Power_kW >= 60
        contFactor = 0.50;
        shiftFactor = 0.90;
    else
        contFactor = 0.20;
        shiftFactor = 0.55;
    end
end

function row = assignEV2SpeedDefaultsConverter(row, raw, warnings) %#ok<INUSD>
    row.EV_2speed_enable = 0;
    row.i_GET_EV_gear1 = fallback(row.i_GET_EV, 9.0);
    row.i_GET_EV_gear2 = fallback(row.i_GET_EV, 9.0);
    row.i_ges_P4_gear1 = fallback(row.i_ges_P4, row.i_GET_EV_gear1);
    row.i_ges_P4_gear2 = fallback(row.i_ges_P4, row.i_GET_EV_gear2);
    row.ev_shift_v_up_kmh = 1e6;
    row.ev_shift_v_down_kmh = 1e6;

    if ~(isfield(row, 'EV') && row.EV == 1)
        return;
    end

    rawGearboxTxt = safeLowerString(raw.gearboxText);
    isTwoSpeedEV = containsAny(rawGearboxTxt, ["2-gang", "2 gang", "2-speed", ...
        "two-speed", "two speed", "zweigang", "zwei-gang"]);
    if ~isTwoSpeedEV
        return;
    end

    row.EV_2speed_enable = 1;
    row.i_GET_EV_gear2 = fallback(row.i_GET_EV, 9.0);
    row.i_ges_P4_gear2 = fallback(row.i_ges_P4, row.i_GET_EV_gear2);

    EV_2speed_ratio_spread = 1.55;
    n_shift_up_rpm = 0.92 * max(fallback(row.n_EV_max, 16000), 16000);
    if isfinite(row.d_wheel) && row.d_wheel > 0
        i1_max_at_105 = n_shift_up_rpm * pi * row.d_wheel * 60 / (105 * 1000);
    else
        i1_max_at_105 = 20;
    end

    row.i_GET_EV_gear1 = min(max(EV_2speed_ratio_spread * row.i_GET_EV_gear2, row.i_GET_EV_gear2), i1_max_at_105);
    row.i_ges_P4_gear1 = min(max(EV_2speed_ratio_spread * row.i_ges_P4_gear2, row.i_ges_P4_gear2), i1_max_at_105);

    if isfinite(row.d_wheel) && row.d_wheel > 0 && row.i_GET_EV_gear1 > 0
        row.ev_shift_v_up_kmh = n_shift_up_rpm * pi * row.d_wheel * 60 / (row.i_GET_EV_gear1 * 1000);
        row.ev_shift_v_down_kmh = max(20, row.ev_shift_v_up_kmh - 15);
    end
end

%% ------------------------- engineering fallbacks -------------------------

function y = fallback(x, defaultValue)
    if isnumeric(x) && isscalar(x) && isfinite(x)
        y = x;
    else
        y = defaultValue;
    end
end

function r = estimateEVTotalRatio(vmax_kmh, d_wheel_m, nEVmax_rpm)
    % Estimate EV total gear reduction from top speed if available.
    % v[km/h] = n_motor[rpm] / i_total * pi*d[m] * 60 / 1000
    if nargin < 3 || ~isfinite(nEVmax_rpm) || nEVmax_rpm <= 0
        nEVmax_rpm = 16000;
    end
    if ~isfinite(vmax_kmh) || vmax_kmh <= 80 || ~isfinite(d_wheel_m) || d_wheel_m <= 0
        r = 9.0;
        return;
    end
    r = nEVmax_rpm * pi * d_wheel_m * 60 / (vmax_kmh * 1000);
    r = min(max(r, 6.5), 13.5);
end

function wb = estimateWheelbase(length_m, body)
    if isfinite(length_m) && length_m > 2.5
        wb = min(max(0.60 * length_m, 2.1), 3.3);
    elseif contains(body, "suv") || contains(body, "gelaende")
        wb = 2.85;
    else
        wb = 2.65;
    end
end

function d = estimateWheelDiameter(length_m, height_m, body)
    if contains(body, "suv") || contains(body, "gelaende") || (isfinite(height_m) && height_m > 1.62)
        d = 0.70;
    elseif isfinite(length_m) && length_m < 3.8
        d = 0.58;
    elseif isfinite(length_m) && length_m < 4.2
        d = 0.61;
    else
        d = 0.6345;
    end
end

function A = estimateFrontalArea(width_m, height_m, body)
    if isfinite(width_m) && isfinite(height_m) && width_m > 1.2 && height_m > 1.0
        shapeFactor = 0.84;
        if contains(body, "cabrio") || contains(body, "roadster")
            shapeFactor = 0.80;
        elseif contains(body, "van") || contains(body, "suv") || contains(body, "gelaende")
            shapeFactor = 0.88;
        end
        A = width_m * height_m * shapeFactor;
        A = min(max(A, 1.55), 3.40);
    elseif contains(body, "suv") || contains(body, "van")
        A = 2.75;
    elseif contains(body, "coupe") || contains(body, "coup") || contains(body, "sport")
        A = 2.05;
    else
        A = 2.25;
    end
end

function h = estimateCgHeight(height_m, body)
    if isfinite(height_m) && height_m > 1.0
        h = 0.32 * height_m;
        if contains(body, "suv") || contains(body, "gelaende") || contains(body, "van")
            h = 0.36 * height_m;
        end
        h = min(max(h, 0.38), 0.70);
    else
        h = 0.40;
    end
end

function wd = estimateWeightDist(AWD, HM_VA, drive, engineLoc, body, isEV)
    if isEV
        if AWD
            wd = 1.00;       % EV AWD, usually balanced
        elseif contains(drive, "hinterrad")
            wd = 0.90;
        else
            wd = 1.10;
        end
        return;
    end

    if contains(engineLoc, "mitte") || contains(engineLoc, "hinten")
        wd = 0.75;
    elseif AWD
        if contains(body, "suv") || contains(body, "gelaende") || contains(body, "van")
            wd = 1.30;
        else
            wd = 1.20;
        end
    elseif HM_VA == 1
        wd = 1.35;
    elseif contains(drive, "hinterrad")
        wd = 1.10;           % front engine RWD fallback
    else
        wd = 1.00;
    end
end

function fd = estimateFinalDrive(powertrain, AWD)
    if string(powertrain) == "EV"
        fd = 1.0;
    elseif AWD
        fd = 3.7;
    else
        fd = 4.1;
    end
end

function nG = estimateGearCount(gearboxText, powertrain)
    txt = safeLowerString(gearboxText);
    nG = parseFirstNumber(txt);
    if isCvtGearboxText(txt)
        nG = NaN;
        return;
    end
    if string(powertrain) == "EV"
        nG = 1;
        return;
    end
    if isfinite(nG) && nG > 1
        nG = round(nG);
        return;
    end
    if containsAny(txt, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct"])
        nG = 7;
    elseif containsAny(txt, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        nG = 8;
    elseif containsAny(txt, ["schalt", "manuell"])
        nG = 6;
    else
        nG = 6;
    end
end

function gr = defaultGearRatios(nG, gearboxText)
    nG = max(1, round(fallback(nG, 6)));
    txt = safeLowerString(gearboxText);
    if nG <= 1
        gr = 1;
    elseif nG == 5
        gr = [3.54 2.05 1.32 1.03 0.85];
    elseif nG == 6
        gr = [4.05 2.40 1.58 1.19 1.00 0.87];
    elseif nG == 7
        gr = [4.38 2.86 1.92 1.37 1.00 0.82 0.64];
    elseif nG >= 8
        if contains(txt, "automatik")
            gr = [5.00 3.20 2.14 1.72 1.31 1.00 0.82 0.64];
        else
            gr = [4.71 3.14 2.11 1.67 1.29 1.00 0.84 0.67];
        end
        gr = gr(1:min(nG, numel(gr)));
    else
        gr = linspace(3.8, 0.9, nG);
    end
end

function delay = estimateShiftDelay(gearboxText, powertrain, pwr_kW, mass_kg)
    txt = safeLowerString(gearboxText);
    pt = string(powertrain);
    if isCvtGearboxText(txt)
        delay = NaN;
        return;
    end
    if pt == "EV"
        delay = 0.05;
        return;
    end

    p2w = 0;
    if isfinite(pwr_kW) && isfinite(mass_kg) && mass_kg > 0
        p2w = pwr_kW / mass_kg * 1000;
    end

    if containsAny(txt, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct", "edct", "e-dct"])
        if pt == "Hybrid" && p2w < 120
            delay = 0.22;
        else
            delay = 0.18;
        end
    elseif containsAny(txt, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        if pt == "Hybrid" && containsAny(txt, ["6-gang", "6 gang"])
            delay = 0.40;
        else
            delay = 0.35;
        end
    elseif containsAny(txt, ["schalt", "manuell"])
        delay = 0.80;
    else
        if p2w < 80
            delay = 1.00;
        elseif p2w < 140
            delay = 0.70;
        elseif p2w < 250
            delay = 0.45;
        else
            delay = 0.25;
        end
    end
end

function type = resolveTransmissionType(gearboxText, powertrain)
    txt = safeLowerString(gearboxText);
    if isCvtGearboxText(txt)
        type = "cvt_excluded";
    elseif string(powertrain) == "EV"
        type = "single_speed_ev";
    elseif containsAny(txt, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct"])
        type = "dct";
    elseif containsAny(txt, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        type = "automatic";
    elseif containsAny(txt, ["schalt", "manuell"])
        type = "manual";
    elseif strlength(strtrim(txt)) == 0 || contains(txt, "0-gang")
        type = "unknown";
    else
        type = "unknown";
    end
end

function type = estimateInductionType(boostText, power_kW, disp_cc, powerRpm, fuelText, vehicleName, powerText)
    % Robust induction classification for AMS data.
    % Do not classify high-specific-output engines as turbo solely from kW/l.
    % Example: Porsche 918 / Ferrari / Lamborghini high-rpm NA engines can
    % exceed 80 kW/l but are still naturally aspirated.
    txt = safeLowerString(strjoin([safeStringScalar(boostText), safeStringScalar(fuelText), ...
        safeStringScalar(vehicleName), safeStringScalar(powerText)], " "));

    hasForcedInductionHint = containsAny(txt, ["turbo", "biturbo", "bi-turbo", "twin turbo", ...
        "kompressor", "supercharged", "supercharger", "lader", "aufladung", ...
        "tsi", "tfsi", "tdi", "cdi", "dci", "hdi", "jtd", "crdi", "bluehdi"]);
    hasNAHint = containsAny(txt, ["saugmotor", "sauger", "naturally aspirated", "naturally-aspirated"]);
    isDiesel = contains(txt, "diesel") || containsAny(txt, ["tdi", "cdi", "dci", "hdi", "jtd", "crdi", "bluehdi"]);

    if hasForcedInductionHint || isDiesel
        type = "Turbo";
        return;
    end

    % High power rpm without any forced-induction hint is a strong NA signal.
    if hasNAHint || (isfinite(powerRpm) && powerRpm >= 7500)
        type = "NA";
        return;
    end

    % Weak fallback only: high specific output suggests forced induction mainly
    % when peak power is not at very high rpm.
    if isfinite(power_kW) && isfinite(disp_cc) && disp_cc > 0
        specificPower = power_kW / (disp_cc/1000);
        if specificPower > 95 && (~isfinite(powerRpm) || powerRpm < 7200)
            type = "Turbo";
        else
            type = "NA";
        end
    else
        type = "NA";
    end
end

function p = estimateBoostPressure(inductionType)
    if string(inductionType) == "Turbo"
        p = 0.5;
    else
        p = 0;
    end
end

function rpmMax = estimateIceMaxRpm(powerRpm, fuelText, inductionType)
    fuel = safeLowerString(fuelText);
    if isfinite(powerRpm) && powerRpm > 0
        rpmMax = ceil((powerRpm + 500) / 100) * 100;
    elseif contains(fuel, "diesel")
        rpmMax = 5000;
    elseif string(inductionType) == "Turbo"
        rpmMax = 7000;
    else
        rpmMax = 7200;
    end

    % Keep normal engines in the previous range, but allow high-rpm NA engines
    % from AMS entries such as "447 kW bei 8700 U/min".
    if isfinite(powerRpm) && powerRpm >= 7500
        upperRpm = 9500;
    elseif contains(fuel, "diesel")
        upperRpm = 5500;
    else
        upperRpm = 8000;
    end
    rpmMax = min(max(rpmMax, 4500), upperRpm);
end

function tq = estimateTorqueFromPower(pwr_kW, rpm)
    if ~isfinite(pwr_kW) || pwr_kW <= 0
        tq = NaN;
        return;
    end
    if ~isfinite(rpm) || rpm <= 0
        rpm = 5000;
    end
    tq = 9550 * pwr_kW / rpm;
end

function s = formatNumVector(v)
    if isempty(v)
        s = "[]";
        return;
    end
    parts = strings(1, numel(v));
    for i = 1:numel(v)
        parts(i) = string(sprintf('%.5g', v(i)));
    end
    s = "[" + strjoin(parts, ", ") + "]";
end

function tf = isCvtGearboxText(txt)
    txt = safeLowerString(txt);
    tf = containsAny(txt, ["cvt", "e-cvt", "ecvt", "stufenlos", "stufenloses", ...
        "continuously variable", "continuous variable", "variator", "multitronic", "xtronic"]);
end

function tf = contains2WDHint(txt)
    txt = safeLowerString(txt);
    tf = containsAny(txt, ["2wd", "2 wd", "4x2", "4 x 2", "two wheel drive"]);
end

function tf = containsAny(txt, patterns)
    tf = false;
    txt = safeLowerString(txt);
    patterns = lower(string(patterns));
    for k = 1:numel(patterns)
        if contains(txt, patterns(k))
            tf = true;
            return;
        end
    end
end

function s = firstNonEmptyString(vals)
    s = "";
    for k = 1:numel(vals)
        x = strtrim(safeStringScalar(vals{k}));
        if strlength(x) > 0 && ~ismissing(x)
            s = x;
            return;
        end
    end
end
