clear; clc;

% doe_file = "DoE_Inp_Hybrid.csv";
% doe_file = "DoE_Inp_ICE.csv";
doe_file = "DoE_Inp.csv";

nPick = 15;

%% Datei
inputFile = fullfile("DoE", doe_file);

%% CSV einlesen
T = readtable(inputFile);

%% Plausibilitaet
if height(T) < nPick
    error("Die Datei enthaelt weniger als %d Zeilen.", nPick);
end

if ~ismember("Powertrain", string(T.Properties.VariableNames))
    error("Die Spalte 'Powertrain' fehlt in %s.", inputFile);
end

%% Powertrain-normalisierte Zufallsauswahl
% Ziel: ungefaehr 1/3 ICE, 1/3 Hybrid, 1/3 EV/BEV.
% Bei nPick = 15 ergibt das exakt 5 ICE, 5 Hybrid, 5 EV.
% Die Ausgabe bleibt in der Reihenfolge ICE -> Hybrid -> EV, damit der erste
% Eintrag ICE ist, sofern ICE-Zeilen vorhanden sind.
rng("shuffle");   % jedes Mal andere Zufallsauswahl

powertrainTargets = ["ICE", "Hybrid", "EV"];
nTypes = numel(powertrainTargets);

baseCount = floor(nPick / nTypes);
targetCounts = repmat(baseCount, 1, nTypes);
restCount = nPick - sum(targetCounts);
if restCount > 0
    targetCounts(1:restCount) = targetCounts(1:restCount) + 1;
end

% Powertrain-Spalte nur fuer die Auswahl normalisieren, Originaltabelle bleibt unveraendert.
ptNorm = upper(strtrim(string(T.Powertrain)));
ptNorm(ptNorm == "BEV") = "EV";   % BEV und EV gemeinsam behandeln

idx = [];
for iType = 1:nTypes
    target = upper(powertrainTargets(iType));
    candidateIdx = find(ptNorm == target);

    nTake = min(targetCounts(iType), numel(candidateIdx));
    if nTake < targetCounts(iType)
        warning("Powertrain '%s': nur %d von geplanten %d Zeilen vorhanden.", ...
            powertrainTargets(iType), nTake, targetCounts(iType));
    end

    if nTake > 0
        candidateIdx = candidateIdx(randperm(numel(candidateIdx), nTake));
        idx = [idx; candidateIdx(:)]; %#ok<AGROW>
    end
end

% Falls eine Kategorie nicht genug Zeilen hat, Rest zufaellig aus allen noch nicht
% ausgewaehlten Zeilen auffuellen.
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
fprintf("\nPowertrain-Verteilung in der Random-Auswahl:\n");
for iType = 1:nTypes
    fprintf("  %-6s: %d\n", powertrainTargets(iType), sum(ptOut == upper(powertrainTargets(iType))));
end

%% Optional speichern
[~, filename, ext] = fileparts(doe_file); %#ok<ASGLU>

outputFile = fullfile("DoE", filename + "_random" + num2str(nPick) + ".csv");
writetable(T_random, outputFile);

fprintf("\nRandom %d Zeilen gespeichert unter:\n%s\n", nPick, outputFile);
