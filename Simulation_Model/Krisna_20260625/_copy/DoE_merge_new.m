%% === MERGE SCRIPT FOR SLURM RESULTS ===
clear; clc;

% 1. Find all result files
files = dir('Results_Chunk_*.mat');
num_files = length(files);
fprintf('Found %d chunk files. Starting merge...\n', num_files);

master_results = [];
files_merged = 0;

% 2. Loop through each file
for k = 1:num_files
    filename = files(k).name;

    try
        % Load the file
        loadedData = load(filename);

        % Check if 'results_struct' exists and is not empty
        if isfield(loadedData, 'results_struct') && ~isempty(loadedData.results_struct)
            chunk_data = loadedData.results_struct;

            % Initialize or Append
            if isempty(master_results)
                master_results = chunk_data;
            else
                master_results = appendStruct(master_results, chunk_data);
            end

            files_merged = files_merged + 1;
        else
            fprintf('WARNING: File %s is empty or missing "results_struct". Skipping.\n', filename);
        end

    catch ME
        fprintf('ERROR: Could not load %s. Message: %s\n', filename, ME.message);
    end

    % Optional: Progress bar every 10 files
    if mod(k, 10) == 0
        fprintf('Processed %d / %d files...\n', k, num_files);
    end
end

%% === 3. WRITE TO EXCEL ===
if ~isempty(master_results)
    fprintf('Merging complete. %d files combined.\n', files_merged);
    fprintf('Converting to Table...\n');

    % Convert Structure Array to Table
    T_out = struct2table(master_results, 'AsArray', true);

    %% === FORCE EMPTY ROWS FOR MISSING RUN_IDs ===
    if ismember('RUN_ID', T_out.Properties.VariableNames)

        % Automatically detect expected RUN_ID range
        minID = min(T_out.RUN_ID);
        maxID = max(T_out.RUN_ID);
        expected_RUN_IDs = minID:maxID;

        existing = T_out.RUN_ID;
        missing = setdiff(expected_RUN_IDs, existing);

        if ~isempty(missing)
            fprintf('Adding %d empty rows for missing RUN_IDs...\n', length(missing));

            % Create empty rows (all NaN except RUN_ID)
            emptyRows = array2table(NaN(length(missing), width(T_out)), ...
                                    'VariableNames', T_out.Properties.VariableNames);
            emptyRows.RUN_ID = missing(:);

            % Append and sort
            T_out = [T_out; emptyRows];
        end

        % Final sorting
        T_out = sortrows(T_out, 'RUN_ID');
    end

    %% === WRITE TO EXCEL ===
    output_filename = 'Final_Simulation_Results_ALL_RUN_IDs.xlsx';
    fprintf('Writing to %s ... (This may take a minute)\n', output_filename);
    writetable(T_out, output_filename);

    fprintf('SUCCESS! All data saved.\n');

else
    fprintf('CRITICAL WARNING: No valid data was found in any of the .mat files.\n');
end


%% === HELPER FUNCTION (Must be at the bottom) ===
function mainStruct = appendStruct(mainStruct, newStruct)
    % Get field names
    mainFields = fieldnames(mainStruct);
    newFields  = fieldnames(newStruct);

    % 1. Add missing fields to MAIN (fill with NaN)
    missingInMain = setdiff(newFields, mainFields);
    for k = 1:length(missingInMain)
        [mainStruct.(missingInMain{k})] = deal(NaN);
    end

    % 2. Add missing fields to NEW (fill with NaN)
    missingInNew = setdiff(mainFields, newFields);
    for k = 1:length(missingInNew)
        [newStruct.(missingInNew{k})] = deal(NaN);
    end

    % 3. Concatenate
    mainStruct = [mainStruct; newStruct];
end