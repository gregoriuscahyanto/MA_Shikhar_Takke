clear; clc;

% doe_file = "DoE_Inp_Hybrid.csv";
% doe_file = "DoE_Inp_ICE.csv";
doe_file = "DoE_Inp.csv";

nPick = 20;

%% Datei
inputFile = fullfile("DoE", doe_file);

%% CSV einlesen
T = readtable(inputFile);

%% Anzahl zufälliger Zeilen
if height(T) < nPick
    error("Die Datei enthält weniger als %d Zeilen.", nPick);
end

%% Zufällige Auswahl
rng("shuffle");   % jedes Mal andere Zufallsauswahl
idx = randperm(height(T), nPick);

T_random = T(idx, :);

%% Anzeigen
disp(T_random);

%% Optional speichern

[~, filename, ext] = fileparts(doe_file);

outputFile = fullfile("DoE", filename + "_random" + num2str(nPick) + ".csv");
writetable(T_random, outputFile);

fprintf("Random %d Zeilen gespeichert unter:\n%s\n", nPick, outputFile);