# MA_Shikhar_Takke

This repository contains the MATLAB/Python environment for vehicle and powertrain simulations. There are currently two relevant workflows:

1. the older sensitivity-analysis pipeline,
2. the new DoE Hybrid Simulation v4 for straight-line KPIs such as 0–100 km/h, 0–200 km/h and additional acceleration metrics.

The current DoE version focuses on simulating the hybrid input dataset `DoE_Inp_Hybrid.csv` with the Simulink model:

```text
Simulation_Fahrmodell_v4_straight_line
```

Intermediate results are written as CSV chunks to reduce I/O load. After the simulation, all chunks are merged into one final Excel comparison file.

---

## Important files

| File / folder                                                                                 | Purpose                                                                                                                                 |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `run_doe_hybrid_pipeline.py`                                                                  | Python helper for DoE-v4 planning and postprocessing. It creates missing RUN_ID chunks and merges completed results.                    |
| `Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE_main.m`                       | Active DoE runner for local and HPC execution. It loads the DoE configuration, runs the v4 straight-line model and writes result files. |
| `Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE_hpc_worker.m`                 | MATLAB HPC worker. It dynamically claims the next open chunk, simulates it locally on the node and copies the result back.              |
| `Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Inp_Hybrid.csv`           | Input file for the hybrid DoE simulation. Each row represents one simulation case.                                                      |
| `Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_ActualValues_Hybrid.xlsx` | Reference values used to compare simulated results with actual values.                                                                  |
| `Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Hybrid_HPC_Results/`      | Result folder for DoE-v4 runs. Contains result chunks and the final comparison Excel file.                                              |
| `bwunicluster_es_grcahyan/submit_DoE_Hybrid_HPC.sh`                                           | Submit helper for the HPC run.                                                                                                          |
| `bwunicluster_es_grcahyan/run_DoE_Hybrid_HPC.slurm`                                           | SLURM script for planning, MATLAB workers and postprocessing in one array job.                                                          |

---

## Requirements

For local execution:

```text
Python 3
pandas
openpyxl
MATLAB with Simulink
```

For HPC execution:

```text
bwUniCluster workspace
MATLAB module
GPU partition, e.g. gpu_a100_short
Repository MA_Shikhar_Takke inside the workspace
Repository bwunicluster_es_grcahyan containing the SLURM scripts
```

Prepare the Python environment locally:

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install pandas openpyxl
```

On Windows:

```powershell
python -m venv .venv
.venv\Scripts\activate
python -m pip install pandas openpyxl
```

---

# Running DoE Simulation v4 locally

From the repository root:

```bash
cd MA_Shikhar_Takke
```

## 1. Optional: plan missing chunks

```bash
python run_doe_hybrid_pipeline.py plan --chunk-size 5
```

By default, the script uses the following files:

```text
Input:
Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Inp_Hybrid.csv

Results:
Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Hybrid_HPC_Results

Plan:
logs/doe_current_plan
```

## 2. Run the complete DoE locally with MATLAB

```bash
cd "Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf"

matlab -batch "TaskID=1; ChunkSize=[]; csv_filename=fullfile('DoE','DoE_Inp_Hybrid.csv'); output_filename=fullfile('DoE','DoE_Hybrid_HPC_Results','chunks','DoE_chunk_local.csv'); DOE_SL_MODEL_NAME='Simulation_Fahrmodell_v4_straight_line'; run('DoE_main.m'); exit(0);"
```

Important:

* `ChunkSize=[]` means that all rows from `DoE_Inp_Hybrid.csv` are processed.
* Without this setting, `DoE_main.m` only processes a small task range.
* The output is written as a CSV chunk to reduce I/O load.

## 3. Merge results and create the final Excel file

Go back to the repository root:

```bash
cd ../../..
python run_doe_hybrid_pipeline.py post
```

The final file is written to:

```text
Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Hybrid_HPC_Results/DoE_Hybrid_Results_Comparison.xlsx
```

The Excel file usually contains:

```text
Comparison
Summary
Missing_RUN_IDs
Invalid_RUN_IDs
```

---

# Running DoE Simulation v4 on the HPC

The HPC workflow is started from the separate repository:

```text
bwunicluster_es_grcahyan
```

The workflow runs as one single SLURM array job:

```text
Task 0              = planning missing chunks
Task 1..N           = MATLAB workers
Task N+1            = postprocessing / final Excel file
```

## Standard run with 20 workers

Inside the cluster repository:

```bash
cd bwunicluster_es_grcahyan
chmod +x submit_DoE_Hybrid_HPC.sh

./submit_DoE_Hybrid_HPC.sh 20
```

## Example with 75 workers and at most 30 running in parallel

```bash
./submit_DoE_Hybrid_HPC.sh 75 30 gpu_a100_short 00:30:00 12
```

Meaning of the arguments:

```text
1: number of MATLAB workers
2: maximum number of parallel array tasks
3: GPU partition
4: walltime per array task
5: CPUs per task
```

Example configuration:

```text
75 workers
30 running in parallel
gpu_a100_short
30 minutes
12 CPUs per task
```

## Alternative GPU partitions

```bash
./submit_DoE_Hybrid_HPC.sh 8 8 gpu_h100_short 00:30:00 24
./submit_DoE_Hybrid_HPC.sh 8 8 gpu_h100 03:00:00 24
```

---

## Dynamic task distribution

The DoE-v4 HPC version uses dynamic chunk distribution:

1. Python plans only missing or invalid RUN_IDs.
2. Missing rows are split into small CSV chunks.
3. MATLAB workers claim the next open chunk dynamically.
4. A fast worker automatically continues with the next available chunk.
5. Finished chunk results are written back as CSV files.
6. Postprocessing merges all chunks into one final Excel file.

This means that it is not critical if individual simulations take different amounts of time.

---

## Important result files

During the HPC run:

```text
Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Hybrid_HPC_Results/chunks/DoE_chunk_*.csv
```

After postprocessing:

```text
Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE/DoE_Hybrid_HPC_Results/DoE_Hybrid_Results_Comparison.xlsx
```

Logs:

```text
logs/doe_hybrid_gpu_<RESUME_TAG>/
```

Plan and marker files:

```text
logs/doe_<RESUME_TAG>_plan/
logs/doe_<RESUME_TAG>_markers/
```

---

## Monitoring on the HPC

After submitting, the script prints the SLURM job ID.

Check job status:

```bash
squeue -j <JOB_ID>
```

Follow logs live:

```bash
tail -f logs/doe_hybrid_gpu_<RESUME_TAG>/doe_hybrid_gpu_<JOB_ID>_*.out
```

Check error logs:

```bash
ls logs/doe_hybrid_gpu_<RESUME_TAG>/*.err
```

---

## Resume / rerun

The workflow can be restarted. Already valid RUN_IDs are detected by the planner and are not simulated again.

Run the same command again:

```bash
./submit_DoE_Hybrid_HPC.sh 75 30 gpu_a100_short 00:30:00 12
```

The pipeline checks existing chunk and final result files and only replans missing or invalid RUN_IDs.

---

## Troubleshooting

### `sbatch: Slurm temporarily unable to accept job`

This is usually a temporary SLURM scheduler issue and not a DoE pipeline error.

Check the queue and priority:

```bash
squeue -u $USER
sprio -u $USER -l
```

Then submit again or reduce the parallelism:

```bash
./submit_DoE_Hybrid_HPC.sh 75 20 gpu_a100_short 00:30:00 12
```

---

### `required file not found`

Check whether the project exists in the workspace and whether the default paths are correct:

```bash
ls "$PROJECT_DIR/run_doe_hybrid_pipeline.py"
ls "$PROJECT_DIR/Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE_main.m"
ls "$PROJECT_DIR/Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf/DoE_hpc_worker.m"
```

Set the paths explicitly if required:

```bash
export PROJECT_DIR="/pfs/work9/workspace/scratch/es_grcahyan-ws_grcahyan"
export SIM_RUN_REL="Simulation_Model/Krisna_20260625/20260625 - neuer Testlauf"

./submit_DoE_Hybrid_HPC.sh 75 30 gpu_a100_short 00:30:00 12
```

---

### Simulink model not found

The active DoE-v4 version expects:

```text
Simulation_Fahrmodell_v4_straight_line.slx
```

The SLURM script therefore copies the complete `Simulation_Model` folder to the node-local TMPDIR instead of only copying the active DoE run folder. This allows MATLAB/Simulink to find models and dependencies located elsewhere below `Simulation_Model`.

---

### Fast Restart errors caused by different gearbox dimensions

Fast Restart is disabled by default because `Gear_Ratio` and `No_Gears` can change between DoE rows.

Only enable it if all rows use the same gearbox dimensions:

```bash
export DOE_USE_FAST_RESTART=1
```

Normally, this variable should remain unset.

---

## Git notes

The following files and folders should not be committed:

```text
.venv/
logs/
slprj/
*.slxc
*.slxc.lock
*.autosave
DoE_Hybrid_HPC_Results/
```

Temporary result files and large simulation outputs should not be committed.

---

## Older sensitivity-analysis pipeline

The older sensitivity-analysis pipeline is still available:

```bash
python run_sensitivity_pipeline.py setup-venv
python run_sensitivity_pipeline.py pre-sim --powertrain both
python run_sensitivity_pipeline.py matlab --powertrain both
python run_sensitivity_pipeline.py post-sim --powertrain both
```

For new DoE Hybrid v4 runs, use the following files instead:

```text
run_doe_hybrid_pipeline.py
DoE_main.m
DoE_hpc_worker.m
submit_DoE_Hybrid_HPC.sh
run_DoE_Hybrid_HPC.slurm
```
