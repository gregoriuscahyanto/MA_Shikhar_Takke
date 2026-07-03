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

    fprintf("ams_json_to_DoE_Inp POWERTRAIN_FIELDMATCH_FIX_V6\n");

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
            metaRows(end+1, 1) = meta; %#ok<AGROW>

            if isfinite(raw.actual0100_s) || isfinite(raw.vmax_kmh)
                a = makeEmptyActualRow();
                a.RUN_ID = runID;
                a.Vehicle_Name = raw.vehicleName;
                a.Powertrain = row.Powertrain;
                a.Actual_0_to_100_s = raw.actual0100_s;
                a.Actual_max_speed_kmh = raw.vmax_kmh;
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

    combustionFuelHint = containsAny(fuel, ["benzin", "diesel", "super", "normal", "autogas", "erdgas", "wasserstoff"]);
    hasICE = ~contains(fuel, "elektro") && ( ...
             (isfinite(raw.displacement_cc) && raw.displacement_cc > 0) || ...
             (isfinite(raw.cylinders) && raw.cylinders > 0) || ...
             combustionFuelHint);

    % IMPORTANT: Systemleistung alone is NOT an electric-machine evidence in
    % the AMS data. Many pure ICE entries have total/fahrzeug power fields.
    % Do not use plain "hev" as substring: it also matches names like Chevrolet.
    hasExplicitHybridHint = containsAny(allTxt, ["hybrid", "plug-in", "plugin", "phev", "mhev", ...
        "mildhybrid", "mild-hybrid", "48v", "e-hybrid", "e-power", "range extender", "ibrida"]);
    hasExplicitEVHint = contains(fuel, "elektro") || containsAny(allTxt, ["bev", "electric"]);
    hasExplicitElectricMotor = (isfinite(raw.ePower_kW) && raw.ePower_kW > 0) || ...
        (isfinite(raw.ePower2_kW) && raw.ePower2_kW > 0) || ...
        (isfinite(raw.eTorque_Nm) && raw.eTorque_Nm > 0) || ...
        (isfinite(raw.eTorque2_Nm) && raw.eTorque2_Nm > 0) || ...
        (isfinite(raw.eMotorCount) && raw.eMotorCount > 0) || ...
        strlength(strtrim(safeStringScalar(raw.eLocText))) > 0 || strlength(strtrim(safeStringScalar(raw.eLoc2Text))) > 0;

    isEV = ~hasICE && (hasExplicitEVHint || hasExplicitElectricMotor);
    isHybrid = ~isEV && hasICE && (hasExplicitHybridHint || hasExplicitElectricMotor);

    if isEV
        row.Powertrain = "EV";
        row.VM = 0; row.EV = 1; row.Hy = 0;
    elseif isHybrid
        row.Powertrain = "Hybrid";
        % Keep VM=1 in the CSV as physical ICE-present information. DoE_main
        % maps this to the topology required by PowertrainConfig.
        row.VM = 1; row.EV = 0; row.Hy = 1;
    else
        row.Powertrain = "ICE";
        row.VM = 1; row.EV = 0; row.Hy = 0;
        if isfinite(raw.system_kW) && raw.system_kW > 0 && ~hasExplicitHybridHint && ~hasExplicitElectricMotor
            warnings(end+1) = "system_kW ignored for ICE classification"; %#ok<AGROW>
        end
    end

    row.Vehicle_Name = raw.vehicleName;
    row.Source_URL = raw.techdataUrl;
    row.Raw_Fuel = raw.fuelText;
    row.Raw_Gearbox = raw.gearboxText;
    row.Raw_Drive = raw.driveText;
    row.Raw_Power = raw.powerText;
    row.Raw_Torque = raw.torqueText;
    row.Raw_SystemPower = raw.systemPowerText;
    row.Actual_0_to_100_s = raw.actual0100_s;
    row.Actual_max_speed_kmh = raw.vmax_kmh;

    row.m_curb = fallback(raw.mass_kg, 1500);
    if ~isfinite(raw.mass_kg), warnings(end+1) = "mass fallback"; end %#ok<AGROW>
    row.Wheelbase = fallback(raw.wheelbase_m, estimateWheelbase(raw.length_m, body));
    if ~isfinite(raw.wheelbase_m), warnings(end+1) = "wheelbase estimated"; end %#ok<AGROW>
    row.d_wheel = estimateWheelDiameter(raw.length_m, raw.height_m, body);
    row.A_front = estimateFrontalArea(raw.width_m, raw.height_m, body);
    row.h_s = estimateCgHeight(raw.height_m, body);

    row.AWD = double(contains(drive, "allrad") || contains(drive, "4x4") || contains(drive, "awd"));
    row.HM_VA = double(contains(drive, "vorderrad") || contains(engineLoc, "vorn") || row.AWD == 1);
    if contains(drive, "hinterrad") && row.AWD == 0
        row.HM_VA = 0;
    end

    row.weight_dist = estimateWeightDist(row.AWD, row.HM_VA, drive, engineLoc, body, isEV);
    row.MainAxle_TorqueSplit_int = 0.5;
    row.Hybrid_ICE_priority = 1;

    row.iAG = fallback(raw.finalDrive, estimateFinalDrive(row.Powertrain, row.AWD));
    if row.iAG <= 0
        row.iAG = estimateFinalDrive(row.Powertrain, row.AWD);
        warnings(end+1) = "final drive estimated"; %#ok<AGROW>
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
    row.Induction_Type = estimateInductionType(raw.boostText, raw.power_kW, raw.displacement_cc);
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

    if isHybrid
        if isfinite(voltage) && voltage <= 80 && isfinite(ePwr1) && ePwr1 <= 35
            row.P0 = 1;
            row.tq_P0_max = eTq1;
            row.Pwr_P0_max_kW = ePwr1;
            row.n_P0_max = 12000;
        elseif contains(eLoc, "hinten") || (row.AWD == 1 && isfinite(ePwr2))
            row.P4 = 1;
            row.P4_DM = 0;
            row.tq_P4_max = fallback(eTq1, eTq2);
            row.Pwr_P4_max_kW = fallback(ePwr1, ePwr2);
            row.n_P4_max = 16000;
            row.i_ges_P4 = 9.0;
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

        if row.P0 + row.P2 + row.P3 + row.P4 + row.P4_DM == 0
            warnings(end+1) = "hybrid without usable e-motor data; weak P2 fallback inserted"; %#ok<AGROW>
            row.P2 = 1;
            row.Pwr_P2_max_kW = max(10, 0.08 * row.Pwr_ICE_max_kW);
            row.tq_P2_max = estimateTorqueFromPower(row.Pwr_P2_max_kW, 4000);
            row.n_P2_max = 12000;
        end
    end

    if isEV
        row.i_GET_EV = 9.0;
        totalPwr = fallback(ePwr1, fallback(raw.system_kW, raw.power_kW));
        totalTq = fallback(eTq1, fallback(raw.system_Nm, raw.torque_Nm));
        if ~isfinite(totalPwr) || totalPwr <= 0
            totalPwr = 120;
            warnings(end+1) = "EV power fallback"; %#ok<AGROW>
        end
        if ~isfinite(totalTq) || totalTq <= 0
            totalTq = estimateTorqueFromPower(totalPwr, 4500);
            warnings(end+1) = "EV torque estimated"; %#ok<AGROW>
        end

        nMot = max(1, round(fallback(raw.eMotorCount, 1)));
        if row.AWD == 1 && nMot < 2
            nMot = 2;
        end
        perMotorPwr = totalPwr / nMot;
        perMotorTq = totalTq / nMot;

        if row.AWD == 1 || contains(eLoc, "hinten") || nMot >= 2
            row.E2 = 1;
            row.Pwr_EV_max_kW = perMotorPwr;
            row.tq_EV_max = perMotorTq;
            row.n_EV_max = 16000;
            row.Pwr_EV_nmax_red_perc = 0.04;
            row.Pwr_P4_max_kW = perMotorPwr;
            row.tq_P4_max = perMotorTq;
            row.n_P4_max = 16000;
            row.i_ges_P4 = 9.0;
        else
            row.E0 = 1;
            row.Pwr_EV_max_kW = perMotorPwr;
            row.tq_EV_max = perMotorTq;
            row.n_EV_max = 16000;
            row.Pwr_EV_nmax_red_perc = 0.04;
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

    row.facSocInit = 0.95;
    row.SOC_Recup_Limit = 0.95;
    row.SOC_Bat_Discharge_Limit = 0.10;

    quality = 100;
    quality = quality - 5 * sum(contains(warnings, "estimated"));
    quality = quality - 8 * sum(contains(warnings, "fallback"));
    quality = quality - 10 * sum(contains(warnings, "repaired"));
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
    tf = hasMass && hasPower && hasWheelbase && hasArea;
end

%% ------------------------- DoE schema -------------------------

function cols = getDoeColumns()
    cols = { ...
        'RUN_ID', 'Vehicle_Name', 'Source_URL', 'Powertrain', 'Raw_Fuel', 'Raw_Gearbox', ...
        'Raw_Drive', 'Raw_Power', 'Raw_Torque', 'Raw_SystemPower', ...
        'Actual_0_to_100_s', 'Actual_max_speed_kmh', 'InputQualityScore', 'InputWarnings', ...
        'd_wheel', 'A_front', 'HM_VA', 'AWD', 'iAG', ...
        'm_curb', 'Wheelbase', 'h_s', 'weight_dist', 'MainAxle_TorqueSplit_int', ...
        'Hybrid_ICE_priority', 'VM', 'EV', 'Hy', 'E0', 'E1', 'E2', 'E3', 'E4', ...
        'i_GET_EV', 'i_ges_P4', 'mode', 'use_cus_val', 'Gear_Ratio', 'No_Gears', ...
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
end

function a = makeEmptyActualRow()
    a = struct();
    a.RUN_ID = 0;
    a.Vehicle_Name = "";
    a.Powertrain = "";
    a.Actual_0_to_100_s = NaN;
    a.Actual_max_speed_kmh = NaN;
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

    tok = regexp(c, '[-+]?\d+(?:[\.,]\d+)?', 'match', 'once');
    if isempty(tok)
        x = NaN;
    else
        x = str2double(strrep(tok, ',', '.'));
    end
end

function x = parsePositiveNumber(s)
    x = parseFirstNumber(s);
    if ~isfinite(x) || x <= 0
        x = NaN;
    end
end

function v = parseSpeedKmh(s)
    str = safeLowerString(s);
    str = replace(str, ",", ".");
    if strlength(str) == 0
        v = NaN;
        return;
    end
    toks = regexp(char(str), '([-+]?\d+(\.\d+)?)\s*km\s*/?\s*h', 'tokens');
    if ~isempty(toks)
        vals = cellfun(@(c) str2double(c{1}), toks);
        vals = vals(isfinite(vals) & vals > 20);
        if ~isempty(vals)
            v = vals(end);
            return;
        end
    end
    v = parseFirstNumber(str);
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
    tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*kW', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        p = str2double(strrep(tok{1}, ',', '.'));
        return;
    end
    tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*PS', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        p = str2double(strrep(tok{1}, ',', '.')) * 0.735499;
    end
end

function tq = parseTorqueNm(s)
    c = safeChar(s);
    tq = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*Nm', 'tokens', 'once', 'ignorecase');
    if ~isempty(tok)
        tq = str2double(strrep(tok{1}, ',', '.'));
    end
end

function rpm = parseRpmAt(s)
    c = safeChar(s);
    rpm = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, 'bei\s*(\d+(?:[\.,]\d+)?)\s*U\s*/\s*min', 'tokens', 'once', 'ignorecase');
    if isempty(tok)
        tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*U\s*/\s*min', 'tokens', 'once', 'ignorecase');
    end
    if ~isempty(tok)
        rpm = str2double(strrep(tok{1}, ',', '.'));
    end
end

function r = parseRatio(s)
    c = safeChar(s);
    r = NaN;
    if isempty(strtrim(c))
        return;
    end
    tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*:?\s*1?', 'tokens', 'once');
    if ~isempty(tok)
        r = str2double(strrep(tok{1}, ',', '.'));
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
        tok = regexp(line, '^(I|II|III|IV|V|VI|VII|VIII|IX|X)\.\s*(\d+(?:[\.,]\d+)?)', 'tokens', 'once', 'ignorecase');
        if ~isempty(tok)
            gr(end+1) = str2double(strrep(tok{2}, ',', '.')); %#ok<AGROW>
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
    tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*x\s*(\d+(?:[\.,]\d+)?)\s*x\s*(\d+(?:[\.,]\d+)?)\s*mm', 'tokens', 'once', 'ignorecase');
    if isempty(tok)
        tok = regexp(c, '(\d+(?:[\.,]\d+)?)\s*x\s*(\d+(?:[\.,]\d+)?)\s*x\s*(\d+(?:[\.,]\d+)?)', 'tokens', 'once', 'ignorecase');
    end
    if ~isempty(tok)
        L = str2double(strrep(tok{1}, ',', '.')) / 1000;
        W = str2double(strrep(tok{2}, ',', '.')) / 1000;
        H = str2double(strrep(tok{3}, ',', '.')) / 1000;
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
    if string(powertrain) == "EV"
        delay = 0.05;
        return;
    end

    p2w = 0;
    if isfinite(pwr_kW) && isfinite(mass_kg) && mass_kg > 0
        p2w = pwr_kW / mass_kg * 1000;
    end

    if containsAny(txt, ["doppelkuppl", "dsg", "pdk", "s tronic", "m dct"])
        delay = 0.18;
    elseif containsAny(txt, ["automatik", "wandler", "tiptronic", "steptronic", "zf"])
        delay = 0.35;
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
    if string(powertrain) == "EV"
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

function type = estimateInductionType(boostText, power_kW, disp_cc)
    txt = safeLowerString(boostText);
    if contains(txt, "turbo") || contains(txt, "kompressor") || contains(txt, "lader")
        type = "Turbo";
    elseif isfinite(power_kW) && isfinite(disp_cc) && disp_cc > 0 && power_kW / (disp_cc/1000) > 80
        type = "Turbo";
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
        rpmMax = 6500;
    else
        rpmMax = 6500;
    end
    rpmMax = min(max(rpmMax, 4500), 8000);
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
