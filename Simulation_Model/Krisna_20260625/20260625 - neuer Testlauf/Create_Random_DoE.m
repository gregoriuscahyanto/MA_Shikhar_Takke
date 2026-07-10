clear; clc;

% doe_file = "DoE_Inp_Hybrid.csv";
% doe_file = "DoE_Inp_ICE.csv";
doe_file = "DoE_Inp.csv";

nPick = 200;
requireActual0100 = true;   % nur Zeilen mit vorhandenem 0-100-Actual-Wert ziehen
minInputQualityScore = 0;   % optional z.B. 40 setzen, wenn schlechte Inputs raus sollen
excludeSuspiciousRows = true;

%% Datei
inputFile = fullfile("DoE", doe_file);

%% CSV einlesen
T = readtable(inputFile);

%% Falls Actual_0_to_100_s nicht im DoE-CSV steht: aus ActualValues per RUN_ID nachziehen
if ~ismember("Actual_0_to_100_s", string(T.Properties.VariableNames))
    actualFile = fullfile("DoE", "DoE_Inp_ActualValues.xlsx");
    if isfile(actualFile)
        A = readtable(actualFile);
        if ismember("RUN_ID", string(T.Properties.VariableNames)) && ...
           ismember("RUN_ID", string(A.Properties.VariableNames)) && ...
           ismember("Actual_0_to_100_s", string(A.Properties.VariableNames))
            T = outerjoin(T, A(:, ["RUN_ID", "Actual_0_to_100_s"]), ...
                "Keys", "RUN_ID", "MergeKeys", true, "Type", "left");
        end
    end
end

%% Plausibilitaet
if ~ismember("Powertrain", string(T.Properties.VariableNames))
    error("Die Spalte 'Powertrain' fehlt in %s.", inputFile);
end

if requireActual0100
    if ~ismember("Actual_0_to_100_s", string(T.Properties.VariableNames))
        error("Die Spalte 'Actual_0_to_100_s' fehlt. Bitte ams_json_to_DoE_Inp neu laufen lassen oder DoE_Inp_ActualValues.xlsx bereitstellen.");
    end

    actual0100 = str2double(string(T.Actual_0_to_100_s));
    validActual = isfinite(actual0100) & actual0100 > 0;

    fprintf("Zeilen vor 0-100-Filter: %d\n", height(T));
    fprintf("Zeilen mit Actual_0_to_100_s: %d\n", sum(validActual));

    T = T(validActual, :);
end

if excludeSuspiciousRows && ismember("InputWarnings", string(T.Properties.VariableNames))
    warnTxt = lower(string(T.InputWarnings));
    keep = ~contains(warnTxt, "suspicious");
    fprintf("Zeilen nach suspicious-Filter: %d\n", sum(keep));
    T = T(keep, :);
end

if ismember("InputQualityScore", string(T.Properties.VariableNames)) && minInputQualityScore > 0
    q = str2double(string(T.InputQualityScore));
    q(~isfinite(q)) = 0;
    T = T(q >= minInputQualityScore, :);
end

if height(T) < nPick
    error("Nach Filterung sind nur %d Zeilen vorhanden, aber nPick=%d.", height(T), nPick);
end

%% Powertrain-normalisierte Zufallsauswahl
% Ziel: ungefaehr 1/3 ICE, 1/3 Hybrid, 1/3 EV/BEV.
rng("shuffle");

powertrainTargets = ["ICE", "Hybrid", "EV"];
nTypes = numel(powertrainTargets);

baseCount = floor(nPick / nTypes);
targetCounts = repmat(baseCount, 1, nTypes);
restCount = nPick - sum(targetCounts);
if restCount > 0
    targetCounts(1:restCount) = targetCounts(1:restCount) + 1;
end

% Powertrain-Spalte nur fuer die Auswahl normalisieren.
ptNorm = upper(strtrim(string(T.Powertrain)));
ptNorm(ptNorm == "BEV") = "EV";
ptNorm(ptNorm == "PHEV" | ptNorm == "HEV") = "HYBRID";

idx = [];
for iType = 1:nTypes
    target = upper(powertrainTargets(iType));
    if target == "HYBRID"
        candidateIdx = find(ptNorm == "HYBRID");
    else
        candidateIdx = find(ptNorm == target);
    end

    nTake = min(targetCounts(iType), numel(candidateIdx));
    if nTake < targetCounts(iType)
        warning("Powertrain '%s': nur %d von geplanten %d Zeilen mit 0-100-Wert vorhanden.", ...
            powertrainTargets(iType), nTake, targetCounts(iType));
    end

    if nTake > 0
        candidateIdx = candidateIdx(randperm(numel(candidateIdx), nTake));
        idx = [idx; candidateIdx(:)]; %#ok<AGROW>
    end
end

% Falls eine Kategorie nicht genug Zeilen hat, Rest zufaellig aus allen noch nicht
% ausgewaehlten, aber weiterhin 0-100-gueltigen Zeilen auffuellen.
missingCount = nPick - numel(idx);
if missingCount > 0
    remainingIdx = setdiff((1:height(T))', idx, 'stable');
    if numel(remainingIdx) < missingCount
        error("Es konnten nur %d von %d Zeilen ausgewaehlt werden.", numel(idx), nPick);
    end

    fillIdx = remainingIdx(randperm(numel(remainingIdx), missingCount));
    idx = [idx; fillIdx(:)];
end

T_random = T(idx, :);

%% Anzeigen
disp(T_random);

%% Verteilung anzeigen
ptOut = upper(strtrim(string(T_random.Powertrain)));
ptOut(ptOut == "BEV") = "EV";
ptOut(ptOut == "PHEV" | ptOut == "HEV") = "HYBRID";

fprintf("\nPowertrain-Verteilung in der Random-Auswahl:\n");
fprintf("  %-6s: %d\n", "ICE", sum(ptOut == "ICE"));
fprintf("  %-6s: %d\n", "Hybrid", sum(ptOut == "HYBRID"));
fprintf("  %-6s: %d\n", "EV", sum(ptOut == "EV"));

if ismember("Actual_0_to_100_s", string(T_random.Properties.VariableNames))
    fprintf("\nActual_0_to_100_s Bereich: %.2f ... %.2f s\n", ...
        min(str2double(string(T_random.Actual_0_to_100_s))), ...
        max(str2double(string(T_random.Actual_0_to_100_s))));
end

%% Speichern
[~, filename, ~] = fileparts(doe_file);
outputFile = fullfile("DoE", filename + "_random" + num2str(nPick) + ".csv");
writetable(T_random, outputFile);

fprintf("\nRandom %d Zeilen mit Actual_0_to_100_s gespeichert unter:\n%s\n", nPick, outputFile);
