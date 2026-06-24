#!/usr/bin/env python3
r"""
One-command sensitivity pipeline runner with resume-safe CSV handling.

Default:

  python run_sensitivity_pipeline.py

Behavior:
  - Creates/uses .venv.
  - Reuses existing sweep CSV files by default.
  - Calls MATLAB even when result XLSX exists, so MATLAB can resume internally.
  - MATLAB DoE_main_sensitivity.m skips existing SWEEP_RUN_IDs inside the XLSX.
  - HPC resume mode can merge all existing *_taskXXX.xlsx files, detect missing SWEEP_RUN_IDs,
    split only the missing rows into fixed-size chunks, and distribute those chunks over workers.
  - Use --force-regenerate-csv to recreate split/sweep CSV files.

If MATLAB is not in PATH, edit DEFAULT_MATLAB_EXE below or run:

  python run_sensitivity_pipeline.py --matlab-exe "C:\Program Files\MATLAB\R2023b\bin\matlab.exe"
"""

from __future__ import annotations

import argparse
import csv
import math
import shutil
import os
import platform
import re
import subprocess
import sys
import venv
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent
VENV_DIR = ROOT / ".venv"
REQ_FILE = ROOT / "requirements_sensitivity.txt"
SIM_DIR = ROOT / "Simulation_Model"

# Change this if MATLAB is not in PATH:
DEFAULT_MATLAB_EXE = "matlab"
# Example:
# DEFAULT_MATLAB_EXE = r"C:\Program Files\MATLAB\R2023b\bin\matlab.exe"

GROUP_SHORT = ["G1", "G2", "G3", "G4", "G5"]
GROUP_LABELS = ["G1_lt5s", "G2_5to7s", "G3_7to10s", "G4_10to13s", "G5_gt13s"]

POWERTRAINS = {
    "hybrid": {
        "script": ROOT / "Data_Analysis" / "Sensitivity analysis" / "Hybrid" / "Sensitivity_Analysis_Hybrid.py",
        "work_dir": ROOT / "Data_Analysis" / "Sensitivity analysis" / "Hybrid",
        "sensitivity_prefix": "sensitivity_hybrid",
        "sweep_prefix": "sweep_hybrid",
        "sweep_pattern": "sweep_hybrid_G*.csv",
        "result_prefix": "sweep_results_hybrid",
        "output_dir": "hybrid_sensitivity_results",
    },
    "bev": {
        "script": ROOT / "Data_Analysis" / "Sensitivity analysis" / "BEV" / "Sensitivity_Analysis_BEV.py",
        "work_dir": ROOT / "Data_Analysis" / "Sensitivity analysis" / "BEV",
        "sensitivity_prefix": "sensitivity_bev",
        "sweep_prefix": "sweep_bev",
        "sweep_pattern": "sweep_bev_G*.csv",
        "result_prefix": "sweep_results_bev",
        "output_dir": "bev_sensitivity_results",
    },
}


def is_windows() -> bool:
    return platform.system().lower().startswith("win")


def venv_python() -> Path:
    if is_windows():
        return VENV_DIR / "Scripts" / "python.exe"
    return VENV_DIR / "bin" / "python"


def current_python() -> Path:
    return Path(sys.executable).resolve()


def in_expected_venv() -> bool:
    try:
        return current_python() == venv_python().resolve()
    except FileNotFoundError:
        return False


def run(cmd: list[str | os.PathLike[str]], *, cwd: Path = ROOT, check: bool = True) -> subprocess.CompletedProcess[str]:
    printable = " ".join(f'"{str(c)}"' if " " in str(c) else str(c) for c in cmd)
    print(f"\n>>> {printable}")
    return subprocess.run([str(c) for c in cmd], cwd=str(cwd), text=True, check=check)


def selected_powertrains(value: str) -> list[str]:
    return ["hybrid", "bev"] if value == "both" else [value]


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def ensure_paths(powertrains: Iterable[str]) -> None:
    for pt in powertrains:
        cfg = POWERTRAINS[pt]
        if not cfg["script"].exists():
            raise FileNotFoundError(f"Missing script for {pt}: {cfg['script']}")
        cfg["work_dir"].mkdir(parents=True, exist_ok=True)


def setup_venv(args: argparse.Namespace | None = None) -> None:
    if not VENV_DIR.exists():
        print(f"Creating virtual environment: {VENV_DIR}")
        venv.EnvBuilder(with_pip=True, clear=False).create(VENV_DIR)
    else:
        print(f"Virtual environment already exists: {VENV_DIR}")

    py = venv_python()
    if not py.exists():
        raise FileNotFoundError(f"Could not find venv Python: {py}")

    run([py, "-m", "pip", "install", "--upgrade", "pip"])

    if REQ_FILE.exists():
        run([py, "-m", "pip", "install", "-r", REQ_FILE])
    else:
        run([py, "-m", "pip", "install", "numpy", "pandas", "matplotlib", "openpyxl"])

    print("\nVenv is ready.")


def warn_if_not_venv(args: argparse.Namespace) -> None:
    if getattr(args, "no_venv_check", False):
        return

    if not VENV_DIR.exists():
        print("WARNING: .venv does not exist yet. It will be created by the default run.")
        return

    if not in_expected_venv():
        print("WARNING: You are not using the repo .venv Python.")
        print(f"Current Python : {current_python()}")
        print(f"Expected Python: {venv_python()}")


def default_args() -> argparse.Namespace:
    return argparse.Namespace(
        powertrain="both",
        tolerance=0.10,
        input_csv=None,
        results_file=None,
        actuals_file=None,
        sweep_results_dir=None,
        output_dir=None,
        no_venv_check=True,
        run_matlab=True,
        matlab_exe=DEFAULT_MATLAB_EXE,
        dry_run=False,
        ignore_missing_results=False,
        force_regenerate_csv=False,
    )


def run_default_no_args() -> None:
    if not in_expected_venv():
        setup_venv()
        py = venv_python()
        print("\nRe-launching full pipeline with the repo .venv Python...")
        run([
            py,
            Path(__file__).resolve(),
            "auto",
            "--powertrain",
            "both",
            "--run-matlab",
            "--no-venv-check",
        ])
        return

    cmd_auto(default_args())


def sensitivity_files(pt: str) -> list[Path]:
    cfg = POWERTRAINS[pt]
    return [cfg["work_dir"] / f"{cfg['sensitivity_prefix']}_{label}.csv" for label in GROUP_LABELS]


def sweep_files_expected(pt: str) -> list[Path]:
    cfg = POWERTRAINS[pt]
    return [cfg["work_dir"] / f"{cfg['sweep_prefix']}_{label}.csv" for label in GROUP_LABELS]


def all_files_exist(paths: Iterable[Path]) -> bool:
    return all(p.exists() for p in paths)


def print_existing_csv_status(pt: str) -> None:
    print(f"\nExisting {pt.upper()} sensitivity CSV files:")
    for p in sensitivity_files(pt):
        print(f"  {'OK     ' if p.exists() else 'MISSING'} {display_path(p)}")

    print(f"\nExisting {pt.upper()} sweep CSV files:")
    for p in sweep_files_expected(pt):
        print(f"  {'OK     ' if p.exists() else 'MISSING'} {display_path(p)}")


def run_split(pt: str, args: argparse.Namespace) -> None:
    cfg = POWERTRAINS[pt]

    cmd = [
        sys.executable,
        cfg["script"],
        "split",
        "--work_dir",
        ROOT,
        "--out_dir",
        cfg["work_dir"],
        "--tolerance",
        str(args.tolerance),
    ]

    if args.input_csv:
        cmd += ["--input_csv", Path(args.input_csv)]
    if args.results_file:
        cmd += ["--results_file", Path(args.results_file)]
    if getattr(args, "actuals_file", None):
        cmd += ["--actuals_file", Path(args.actuals_file)]

    run(cmd)


def run_sweep(pt: str, args: argparse.Namespace) -> None:
    cfg = POWERTRAINS[pt]

    cmd = [
        sys.executable,
        cfg["script"],
        "sweep",
        "--work_dir",
        cfg["work_dir"],
        "--out_dir",
        cfg["work_dir"],
    ]

    run(cmd)


def maybe_run_split_and_sweep(pt: str, args: argparse.Namespace) -> None:
    sensitivity_ok = all_files_exist(sensitivity_files(pt))
    sweep_ok = all_files_exist(sweep_files_expected(pt))

    if not args.force_regenerate_csv and sensitivity_ok and sweep_ok:
        print(f"\n=== {pt.upper()}: split/sweep skipped ===")
        print("Existing sensitivity and sweep CSV files found. Reusing them for safe resume.")
        print_existing_csv_status(pt)
        return

    if not args.force_regenerate_csv and sensitivity_ok and not sweep_ok:
        print(f"\n=== {pt.upper()}: split skipped ===")
        print("Existing sensitivity CSV files found. Reusing them.")
        print_existing_csv_status(pt)

        print(f"\n=== {pt.upper()}: sweep ===")
        run_sweep(pt, args)
        return

    print(f"\n=== {pt.upper()}: split ===")
    run_split(pt, args)

    print(f"\n=== {pt.upper()}: sweep ===")
    run_sweep(pt, args)


def run_analyze(pt: str, args: argparse.Namespace) -> None:
    cfg = POWERTRAINS[pt]

    cmd = [
        sys.executable,
        cfg["script"],
        "analyze",
        "--work_dir",
        cfg["work_dir"],
        "--sweep_results_dir",
        args.sweep_results_dir or cfg["work_dir"],
        "--output_dir",
        args.output_dir or str(cfg["work_dir"] / cfg["output_dir"]),
        "--tolerance",
        str(args.tolerance),
    ]

    run(cmd)


def result_candidates(pt: str, sweep_results_dir: Path | None = None) -> list[Path]:
    cfg = POWERTRAINS[pt]
    result_dir = sweep_results_dir or cfg["work_dir"]
    prefix = cfg["result_prefix"]
    return [result_dir / f"{prefix}_{g}.xlsx" for g in GROUP_SHORT]


def missing_result_files(pt: str, args: argparse.Namespace) -> list[Path]:
    # Only require final result files for sweep CSVs that actually contain rows.
    # Empty groups may legitimately have no result file and are skipped by the analyzer.
    result_dir = Path(args.sweep_results_dir) if args.sweep_results_dir else None
    if result_dir is not None:
        cfg = POWERTRAINS[pt]
        files = []
        for sweep_file in find_sweep_files(pt):
            if count_csv_data_rows(sweep_file) <= 0:
                continue
            group_short = group_short_from_filename(sweep_file)
            candidate = result_dir / f"{cfg['result_prefix']}_{group_short}.xlsx"
            if not candidate.exists():
                files.append(candidate)
        return files

    files = []
    for sweep_file in find_sweep_files(pt):
        if count_csv_data_rows(sweep_file) <= 0:
            continue
        candidate = output_path_for_sweep(pt, sweep_file)
        if not candidate.exists():
            files.append(candidate)
    return files


def matlab_quote(path_or_text: str | Path) -> str:
    text = str(path_or_text).replace("\\", "/").replace("'", "''")
    return f"'{text}'"


def group_short_from_filename(path: Path) -> str:
    match = re.search(r"_(G[1-5])(?:_|\.|$)", path.name)
    if not match:
        raise ValueError(f"Could not detect group G1-G5 from filename: {path.name}")
    return match.group(1)


def find_sweep_files(pt: str) -> list[Path]:
    cfg = POWERTRAINS[pt]
    files = sorted(cfg["work_dir"].glob(cfg["sweep_pattern"]))

    # Prefer expected exact names in G1..G5 order if they exist.
    expected = [p for p in sweep_files_expected(pt) if p.exists()]
    return expected if expected else files


def output_path_for_sweep(pt: str, sweep_file: Path, task_id: int | None = None) -> Path:
    cfg = POWERTRAINS[pt]
    group_short = group_short_from_filename(sweep_file)
    base = cfg["work_dir"] / f"{cfg['result_prefix']}_{group_short}"

    # Non-array run: one complete result file per group.
    if task_id is None:
        return base.with_suffix(".xlsx")

    # SLURM-array run: one independent result file per task.
    # This is critical: never let parallel tasks write into the same XLSX.
    return cfg["work_dir"] / f"{cfg['result_prefix']}_{group_short}_task{task_id:03d}.xlsx"


def chunk_output_pattern_for_sweep(pt: str, sweep_file: Path) -> str:
    cfg = POWERTRAINS[pt]
    group_short = group_short_from_filename(sweep_file)
    return f"{cfg['result_prefix']}_{group_short}_task*.xlsx"


def count_csv_data_rows(csv_file: Path) -> int:
    # Fast enough for sweep CSVs and avoids importing pandas in the MATLAB phase.
    with csv_file.open("r", encoding="utf-8", errors="ignore") as f:
        line_count = sum(1 for _ in f)
    return max(0, line_count - 1)


def slurm_array_context() -> tuple[int, int, int] | None:
    raw_task_id = os.environ.get("SLURM_ARRAY_TASK_ID")
    if not raw_task_id:
        return None

    task_id = int(raw_task_id)
    task_min = int(os.environ.get("SLURM_ARRAY_TASK_MIN", "1"))

    if os.environ.get("SLURM_ARRAY_TASK_COUNT"):
        task_count = int(os.environ["SLURM_ARRAY_TASK_COUNT"])
    elif os.environ.get("SLURM_ARRAY_TASK_MAX"):
        task_max = int(os.environ["SLURM_ARRAY_TASK_MAX"])
        task_count = task_max - task_min + 1
    else:
        task_count = 1

    # MATLAB chunk indexing should always be 1..task_count even if the SLURM
    # array uses a different minimum index. With --array=1-75 this equals task_id.
    local_task_index = task_id - task_min + 1

    if local_task_index < 1 or local_task_index > task_count:
        raise RuntimeError(
            f"Invalid SLURM array context: task_id={task_id}, "
            f"task_min={task_min}, task_count={task_count}"
        )

    return task_id, local_task_index, task_count


def build_matlab_batch_command(
    sweep_file: Path,
    output_file: Path,
    task_index: int | None = None,
    chunk_size: int | None = None,
) -> str:
    sim_dir = matlab_quote(SIM_DIR)
    sweep = matlab_quote(sweep_file)
    out = matlab_quote(output_file)

    if task_index is None or chunk_size is None:
        doe_call = f"DoE_main_sensitivity({sweep}, {out});"
    else:
        doe_call = f"DoE_main_sensitivity({sweep}, {out}, {task_index}, {chunk_size});"

    return (
        f"cd({sim_dir}); "
        f"addpath({sim_dir}); "
        f"try; {doe_call} "
        f"catch ME; disp(getReport(ME, 'extended', 'hyperlinks', 'off')); exit(1); end;"
    )


def run_one_matlab_job(
    matlab_exe: str,
    sweep_file: Path,
    output_file: Path,
    dry_run: bool,
    task_index: int | None = None,
    chunk_size: int | None = None,
) -> None:
    batch_command = build_matlab_batch_command(sweep_file, output_file, task_index, chunk_size)

    cmd = [matlab_exe, "-batch", batch_command]

    print("\n============================================================")
    print("MATLAB simulation")
    print(f"Input     : {display_path(sweep_file)}")
    print(f"Output    : {display_path(output_file)}")
    if task_index is not None and chunk_size is not None:
        print(f"Task index: {task_index}")
        print(f"Chunk size: {chunk_size}")
    print("Command:")
    print(" ".join(f'"{c}"' if " " in c else c for c in cmd))

    if dry_run:
        return

    subprocess.run(cmd, cwd=str(ROOT), check=True)



def result_files_for_sweep(pt: str, sweep_file: Path) -> list[Path]:
    """Return all XLSX result files/fragments for one powertrain/group.

    This is intentionally broad for backward compatibility. It includes:
      - final files:        sweep_results_hybrid_G1.xlsx
      - old static chunks:  sweep_results_hybrid_G1_task001.xlsx
      - new gap chunks:    sweep_results_hybrid_G1_resume_000001.xlsx
    """
    cfg = POWERTRAINS[pt]
    group_short = group_short_from_filename(sweep_file)
    prefix = f"{cfg['result_prefix']}_{group_short}"
    files = []
    seen = set()

    for p in sorted(cfg["work_dir"].glob(f"{prefix}*.xlsx")):
        name = p.name
        if name.startswith("~$") or name.endswith(".tmp.xlsx") or name.endswith(".part.xlsx"):
            continue
        if p not in seen:
            files.append(p)
            seen.add(p)

    return files


def is_cleanup_fragment_result_file(pt: str, sweep_file: Path, result_file: Path) -> bool:
    """Return True for old per-task/per-resume XLSX fragments safe to delete after merge."""
    final_file = output_path_for_sweep(pt, sweep_file)
    if result_file.resolve() == final_file.resolve():
        return False

    cfg = POWERTRAINS[pt]
    group_short = group_short_from_filename(sweep_file)
    prefix = f"{cfg['result_prefix']}_{group_short}"
    name = result_file.name

    return (
        name.startswith(prefix + "_task")
        or name.startswith(prefix + "_resume_")
    ) and name.endswith(".xlsx")


def cleanup_merged_result_fragments(pt: str, sweep_file: Path, merged_files: Iterable[Path]) -> int:
    """Delete old task/resume fragments after their rows were merged into the final XLSX.

    Only files that were read successfully and match the known fragment naming
    schemes are removed. The final result XLSX is never deleted.
    """
    deleted = 0
    for result_file in merged_files:
        if not is_cleanup_fragment_result_file(pt, sweep_file, result_file):
            continue
        try:
            result_file.unlink()
            deleted += 1
            print(f"Deleted merged fragment: {display_path(result_file)}")
        except FileNotFoundError:
            continue
        except Exception as exc:
            print(f"WARNING: Could not delete merged fragment {display_path(result_file)}: {exc}")
    return deleted


def normalize_id_value(value):
    try:
        x = float(value)
    except Exception:
        return None
    if not math.isfinite(x):
        return None
    rounded = round(x)
    if abs(x - rounded) < 1e-9:
        return int(rounded)
    return x


def ids_from_dataframe(df, preferred_col: str = "SWEEP_RUN_ID") -> set:
    if preferred_col in df.columns:
        col = preferred_col
    elif "RUN_ID" in df.columns:
        col = "RUN_ID"
    else:
        return set()

    ids = set()
    for value in df[col].tolist():
        norm = normalize_id_value(value)
        if norm is not None:
            ids.add(norm)
    return ids


def ids_from_excel_file(path: Path, preferred_col: str = "SWEEP_RUN_ID") -> set:
    try:
        import pandas as pd
        df = pd.read_excel(path)
    except Exception as exc:
        print(f"WARNING: Could not read result file for ID scan {display_path(path)}: {exc}")
        return set()
    return ids_from_dataframe(df, preferred_col)


def merge_existing_results_for_sweep(pt: str, sweep_file: Path) -> tuple[Path, set]:
    """Merge all existing fragments for one sweep into the final result file.

    Returns the final file path and the set of completed SWEEP_RUN_IDs.
    Corrupt or half-written XLSX files are ignored, so a timeout during an XLSX write
    does not destroy the rest of the resume plan.
    """
    try:
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError("pandas is required for merging result fragments") from exc

    final_file = output_path_for_sweep(pt, sweep_file)
    result_files = result_files_for_sweep(pt, sweep_file)

    frames = []
    merged_files = []
    for result_file in result_files:
        try:
            df = pd.read_excel(result_file)
        except Exception as exc:
            print(f"WARNING: Could not read {display_path(result_file)}: {exc}")
            continue
        merged_files.append(result_file)
        if len(df) > 0:
            frames.append(df)

    if not frames:
        print(f"No existing result fragments found for {display_path(sweep_file)}")
        return final_file, set()

    combined = pd.concat(frames, ignore_index=True, sort=False)

    if "SWEEP_RUN_ID" in combined.columns:
        combined = combined[combined["SWEEP_RUN_ID"].notna()].copy()
        combined["SWEEP_RUN_ID"] = pd.to_numeric(combined["SWEEP_RUN_ID"], errors="coerce")
        combined = combined[combined["SWEEP_RUN_ID"].notna()].copy()
        combined = combined.drop_duplicates(subset=["SWEEP_RUN_ID"], keep="first")
        combined = combined.sort_values("SWEEP_RUN_ID")
    elif "RUN_ID" in combined.columns:
        combined = combined.drop_duplicates(subset=["RUN_ID"], keep="first")
        combined = combined.sort_values("RUN_ID")

    final_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = final_file.with_name(final_file.stem + ".tmp.xlsx")
    combined.to_excel(tmp_file, index=False)
    tmp_file.replace(final_file)

    deleted_fragments = cleanup_merged_result_fragments(pt, sweep_file, merged_files)

    done_ids = ids_from_dataframe(combined, "SWEEP_RUN_ID")
    print(
        f"Merged progress for {display_path(sweep_file)} -> {display_path(final_file)} | "
        f"files: {len(result_files)} | rows: {len(combined)} | "
        f"done ids: {len(done_ids)} | deleted fragments: {deleted_fragments}"
    )
    return final_file, done_ids


def merge_chunk_outputs_for_powertrain(pt: str) -> None:
    # Backward-compatible merge. Includes old *_taskXXX.xlsx files and new
    # *_resume_XXXXXX.xlsx gap chunk files.
    for sweep_file in find_sweep_files(pt):
        merge_existing_results_for_sweep(pt, sweep_file)


def validate_final_results_for_powertrain(pt: str) -> None:
    try:
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError("pandas is required for validating merged MATLAB outputs") from exc

    for sweep_file in find_sweep_files(pt):
        final_file = output_path_for_sweep(pt, sweep_file)
        sweep_df = pd.read_csv(sweep_file)

        if len(sweep_df) == 0:
            print(f"Validation skipped for empty sweep file: {display_path(sweep_file)}")
            continue

        if not final_file.exists():
            raise FileNotFoundError(f"Missing final result file: {display_path(final_file)}")

        result_df = pd.read_excel(final_file)

        if "SWEEP_RUN_ID" in sweep_df.columns and "SWEEP_RUN_ID" in result_df.columns:
            expected_ids = ids_from_dataframe(sweep_df, "SWEEP_RUN_ID")
            result_ids = ids_from_dataframe(result_df, "SWEEP_RUN_ID")
            missing_ids = sorted(expected_ids - result_ids)

            if missing_ids:
                preview = ", ".join(str(x) for x in missing_ids[:20])
                more = "" if len(missing_ids) <= 20 else f" ... (+{len(missing_ids) - 20} more)"
                raise RuntimeError(
                    f"Incomplete result file {display_path(final_file)}. "
                    f"Missing {len(missing_ids)} SWEEP_RUN_ID(s): {preview}{more}"
                )

            print(f"Validated {display_path(final_file)}: {len(result_ids)}/{len(expected_ids)} SWEEP_RUN_IDs present")
            continue

        expected_rows = len(sweep_df)
        result_rows = len(result_df)
        if result_rows < expected_rows:
            raise RuntimeError(
                f"Incomplete result file {display_path(final_file)}. "
                f"Rows present: {result_rows}, expected at least: {expected_rows}"
            )

        print(f"Validated {display_path(final_file)}: {result_rows}/{expected_rows} rows present")


def plan_resume_chunks(powertrains: Iterable[str], args: argparse.Namespace) -> None:
    """Create a gap-based resume plan from all existing result files.

    The planner first merges all existing fragments, then compares the merged
    SWEEP_RUN_IDs against every sweep CSV. Only missing rows are written into
    fixed-size pending chunk CSVs. Worker tasks later consume the manifest.
    """
    try:
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError("pandas is required for planning resume chunks") from exc

    plan_dir = Path(args.plan_dir).resolve()
    pending_dir = plan_dir / "pending"
    worker_marker_dir = plan_dir / "worker_markers"
    manifest_file = plan_dir / "manifest.csv"
    summary_file = plan_dir / "summary.txt"

    chunk_size = int(args.resume_chunk_size)
    if chunk_size < 1:
        raise ValueError("--resume-chunk-size must be >= 1")

    plan_dir.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(pending_dir, ignore_errors=True)
    shutil.rmtree(worker_marker_dir, ignore_errors=True)
    pending_dir.mkdir(parents=True, exist_ok=True)
    worker_marker_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    summary_lines = []
    global_chunk_id = 1

    for pt in powertrains:
        sweep_files = find_sweep_files(pt)
        if not sweep_files:
            print(f"No sweep files found for {pt.upper()}. Expected in {POWERTRAINS[pt]['work_dir']}")
            continue

        for sweep_file in sweep_files:
            group_short = group_short_from_filename(sweep_file)
            final_file, done_ids = merge_existing_results_for_sweep(pt, sweep_file)

            sweep_df = pd.read_csv(sweep_file)
            if len(sweep_df) == 0:
                line = f"{pt.upper()} {group_short}: sweep file is empty; no chunks planned."
                print(line)
                summary_lines.append(line)
                continue

            if "SWEEP_RUN_ID" not in sweep_df.columns:
                print(f"WARNING: {display_path(sweep_file)} has no SWEEP_RUN_ID. Creating row-order SWEEP_RUN_ID for planning.")
                sweep_df = sweep_df.copy()
                sweep_df.insert(0, "SWEEP_RUN_ID", range(1, len(sweep_df) + 1))

            sweep_df["SWEEP_RUN_ID"] = pd.to_numeric(sweep_df["SWEEP_RUN_ID"], errors="coerce")
            sweep_df = sweep_df[sweep_df["SWEEP_RUN_ID"].notna()].copy()
            sweep_df["__norm_id__"] = sweep_df["SWEEP_RUN_ID"].map(normalize_id_value)

            missing_df = sweep_df[~sweep_df["__norm_id__"].isin(done_ids)].copy()
            missing_df = missing_df.drop(columns=["__norm_id__"])

            total = len(sweep_df)
            done = total - len(missing_df)
            missing = len(missing_df)
            line = f"{pt.upper()} {group_short}: total={total}, done={done}, missing={missing}, chunk_size={chunk_size}"
            print(line)
            summary_lines.append(line)

            if missing == 0:
                continue

            for start in range(0, missing, chunk_size):
                chunk_df = missing_df.iloc[start:start + chunk_size].copy()
                chunk_id = global_chunk_id
                pending_csv = pending_dir / f"resume_chunk_{chunk_id:06d}_{pt}_{group_short}.csv"
                output_xlsx = POWERTRAINS[pt]["work_dir"] / f"{POWERTRAINS[pt]['result_prefix']}_{group_short}_resume_{chunk_id:06d}.xlsx"

                chunk_df.to_csv(pending_csv, index=False)
                ids = [normalize_id_value(v) for v in chunk_df["SWEEP_RUN_ID"].tolist()]
                ids = [v for v in ids if v is not None]

                rows.append({
                    "chunk_id": chunk_id,
                    "powertrain": pt,
                    "group": group_short,
                    "n_rows": len(chunk_df),
                    "first_sweep_run_id": ids[0] if ids else "",
                    "last_sweep_run_id": ids[-1] if ids else "",
                    "source_sweep_file": str(sweep_file),
                    "pending_csv": str(pending_csv),
                    "output_xlsx": str(output_xlsx),
                    "final_xlsx": str(final_file),
                })
                global_chunk_id += 1

    fieldnames = [
        "chunk_id", "powertrain", "group", "n_rows",
        "first_sweep_run_id", "last_sweep_run_id",
        "source_sweep_file", "pending_csv", "output_xlsx", "final_xlsx",
    ]
    with manifest_file.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    summary_lines.append(f"planned_chunks={len(rows)}")
    summary_lines.append(f"manifest={manifest_file}")
    summary_file.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    (plan_dir / "chunk_count.txt").write_text(str(len(rows)) + "\n", encoding="utf-8")

    print("\n============================================================")
    print("Resume plan created")
    print("============================================================")
    print(f"Plan dir       : {plan_dir}")
    print(f"Manifest       : {manifest_file}")
    print(f"Pending chunks : {len(rows)}")
    print(f"Chunk size     : {chunk_size}")


def load_resume_manifest(plan_dir: Path) -> list[dict]:
    manifest_file = plan_dir / "manifest.csv"
    if not manifest_file.exists():
        raise FileNotFoundError(f"Resume manifest not found: {manifest_file}")
    with manifest_file.open("r", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def run_resume_manifest_worker(args: argparse.Namespace) -> None:
    doe_file = SIM_DIR / "DoE_main_sensitivity.m"

    if not SIM_DIR.exists():
        raise FileNotFoundError(f"Simulation_Model folder not found: {SIM_DIR}")
    if not doe_file.exists():
        raise FileNotFoundError(f"Missing MATLAB file: {doe_file}")

    plan_dir = Path(args.plan_dir).resolve()
    manifest_rows = load_resume_manifest(plan_dir)
    array_ctx = slurm_array_context()

    if array_ctx is None:
        actual_task_id = 1
        task_index = 1
        task_count = 1
    else:
        actual_task_id, task_index, task_count = array_ctx

    assigned = [
        row for row in manifest_rows
        if ((int(row["chunk_id"]) - 1) % task_count) == (task_index - 1)
    ]

    print("\n============================================================")
    print("Resume manifest worker")
    print("============================================================")
    print(f"Plan dir            : {plan_dir}")
    print(f"Manifest chunks     : {len(manifest_rows)}")
    print(f"SLURM task id       : {actual_task_id}")
    print(f"Worker index/count  : {task_index}/{task_count}")
    print(f"Assigned chunks     : {len(assigned)}")

    if not assigned:
        print("No chunks assigned to this worker. Nothing to do.")
        return

    for row in assigned:
        chunk_id = int(row["chunk_id"])
        pending_csv = Path(row["pending_csv"])
        output_xlsx = Path(row["output_xlsx"])
        n_rows = row.get("n_rows", "")

        print("\n------------------------------------------------------------")
        print(f"Resume chunk {chunk_id}")
        print(f"Powertrain : {row.get('powertrain')}")
        print(f"Group      : {row.get('group')}")
        print(f"Rows       : {n_rows}")
        print(f"Input CSV  : {display_path(pending_csv)}")
        print(f"Output XLSX: {display_path(output_xlsx)}")

        if not pending_csv.exists():
            raise FileNotFoundError(f"Pending CSV not found: {pending_csv}")

        # Copy the small pending chunk to node-local TMPDIR when available.
        # This protects MATLAB from a plan-directory race on shared storage and
        # also reduces repeated metadata reads from the workspace filesystem.
        matlab_input_csv = pending_csv
        tmp_root_raw = os.environ.get("TMPDIR", "")
        if tmp_root_raw:
            try:
                tmp_input_dir = Path(tmp_root_raw) / "sensitivity_resume_inputs"
                tmp_input_dir.mkdir(parents=True, exist_ok=True)
                matlab_input_csv = tmp_input_dir / pending_csv.name
                shutil.copy2(pending_csv, matlab_input_csv)
                print(f"Copied input CSV to node-local file: {matlab_input_csv}")
            except Exception as exc:
                matlab_input_csv = pending_csv
                print(f"WARNING: Could not copy pending CSV to TMPDIR. Using original file. Reason: {exc}")

        # The pending CSV already contains only missing rows, so process the whole file.
        # Existing output_xlsx is still resume-safe because DoE_main_sensitivity skips
        # SWEEP_RUN_IDs already present inside that file.
        run_one_matlab_job(args.matlab_exe, matlab_input_csv, output_xlsx, args.dry_run)

def run_matlab_sweeps(powertrains: Iterable[str], args: argparse.Namespace) -> None:
    doe_file = SIM_DIR / "DoE_main_sensitivity.m"

    if not SIM_DIR.exists():
        raise FileNotFoundError(f"Simulation_Model folder not found: {SIM_DIR}")

    if not doe_file.exists():
        raise FileNotFoundError(
            f"Missing MATLAB file: {doe_file}\n"
            "Create Simulation_Model/DoE_main_sensitivity.m first."
        )

    array_ctx = slurm_array_context()

    if array_ctx is None:
        print("\nNo SLURM array detected: each sweep CSV is processed completely.")
        actual_task_id = None
        task_index = None
        task_count = None
    else:
        actual_task_id, task_index, task_count = array_ctx
        print("\nSLURM array detected.")
        print(f"SLURM_ARRAY_TASK_ID : {actual_task_id}")
        print(f"Local task index    : {task_index}")
        print(f"Array task count    : {task_count}")

    any_file = False

    for pt in powertrains:
        sweep_files = find_sweep_files(pt)

        if not sweep_files:
            print(f"\nNo sweep files found for {pt.upper()}. Expected in: {POWERTRAINS[pt]['work_dir']}")
            continue

        print(f"\nFound {len(sweep_files)} {pt.upper()} sweep files.")

        for sweep_file in sweep_files:
            any_file = True

            if array_ctx is None:
                output_file = output_path_for_sweep(pt, sweep_file)
                if output_file.exists():
                    print(f"Existing result file found. MATLAB will resume inside it: {display_path(output_file)}")
                run_one_matlab_job(args.matlab_exe, sweep_file, output_file, args.dry_run)
                continue

            total_rows = count_csv_data_rows(sweep_file)
            chunk_size = max(1, (total_rows + task_count - 1) // task_count)
            output_file = output_path_for_sweep(pt, sweep_file, actual_task_id)

            start_idx = (task_index - 1) * chunk_size + 1
            end_idx = min(start_idx + chunk_size - 1, total_rows)

            print("\nChunk assignment")
            print(f"Sweep file : {display_path(sweep_file)}")
            print(f"Rows total : {total_rows}")
            print(f"Rows task  : {start_idx}..{end_idx}")
            print(f"Output     : {display_path(output_file)}")

            if start_idx > total_rows:
                print("No rows assigned to this task for this sweep file. Skipping MATLAB call.")
                continue

            if output_file.exists():
                print(f"Existing task result found. MATLAB will resume inside it: {display_path(output_file)}")

            run_one_matlab_job(
                args.matlab_exe,
                sweep_file,
                output_file,
                args.dry_run,
                task_index,
                chunk_size,
            )

    if not any_file:
        raise RuntimeError(
            "No sweep CSV files found. Run with --force-regenerate-csv or check the sensitivity folders."
        )


def print_simulation_todo(powertrains: Iterable[str], args: argparse.Namespace) -> None:
    print("\nNext step: run the generated sweep CSVs through MATLAB/Simulink.")

    for pt in powertrains:
        cfg = POWERTRAINS[pt]

        print(f"\n{pt.upper()} sweep input files:")
        for p in find_sweep_files(pt):
            print(f"  {display_path(p)}")

        print(f"\nExpected {pt.upper()} result files:")
        for p in result_candidates(pt, Path(args.sweep_results_dir) if args.sweep_results_dir else None):
            print(f"  {display_path(p)}")


def cmd_pre_sim(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)

    for pt in pts:
        maybe_run_split_and_sweep(pt, args)

    if getattr(args, "run_matlab", False):
        run_matlab_sweeps(pts, args)
    else:
        print_simulation_todo(pts, args)


def cmd_matlab(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    run_matlab_sweeps(pts, args)


def cmd_post_sim(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)

    for pt in pts:
        merge_chunk_outputs_for_powertrain(pt)

        if not args.ignore_missing_results:
            validate_final_results_for_powertrain(pt)

        missing = missing_result_files(pt, args)

        if missing and not args.ignore_missing_results:
            print(f"\nCannot analyze {pt.upper()} yet. Missing result files:")
            for p in missing:
                print(f"  {display_path(p)}")
            continue

        print(f"\n=== {pt.upper()}: analyze ===")
        run_analyze(pt, args)


def cmd_plan_resume(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    plan_resume_chunks(pts, args)


def cmd_matlab_resume(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    # pts is validated here so a wrong --powertrain fails early. The manifest itself
    # carries the exact pending chunks.
    run_resume_manifest_worker(args)


def cmd_auto(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)

    for pt in pts:
        maybe_run_split_and_sweep(pt, args)

    if getattr(args, "run_matlab", False):
        print("\n=== MATLAB/Simulink sweep simulation ===")
        run_matlab_sweeps(pts, args)

    any_missing = False

    for pt in pts:
        merge_chunk_outputs_for_powertrain(pt)
        missing = missing_result_files(pt, args)

        if missing:
            any_missing = True
            print(f"\n{pt.upper()} analyze skipped because result files are missing:")
            for p in missing:
                print(f"  {display_path(p)}")

    if any_missing:
        print_simulation_todo(pts, args)
        return

    for pt in pts:
        print(f"\n=== {pt.upper()}: analyze ===")
        run_analyze(pt, args)


def add_common_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--powertrain", choices=["hybrid", "bev", "both"], default="both")
    p.add_argument("--tolerance", type=float, default=0.10)
    p.add_argument("--input_csv", default=None)
    p.add_argument("--results_file", default=None)
    p.add_argument("--actuals_file", default=None)
    p.add_argument("--sweep_results_dir", default=None)
    p.add_argument("--output_dir", default=None)
    p.add_argument("--no-venv-check", action="store_true")

    p.add_argument("--run-matlab", action="store_true")
    p.add_argument("--matlab-exe", default=DEFAULT_MATLAB_EXE)
    p.add_argument("--dry-run", action="store_true")

    p.add_argument(
        "--force-regenerate-csv",
        action="store_true",
        help="Recreate sensitivity_*.csv and sweep_*.csv even when they already exist.",
    )


def add_resume_plan_args(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--plan-dir",
        default=str(ROOT / "logs" / "sensitivity_current_plan"),
        help="Directory for the generated gap-based resume manifest and pending chunk CSVs.",
    )
    p.add_argument(
        "--resume-chunk-size",
        type=int,
        default=int(os.environ.get("RESUME_CHUNK_SIZE", "10")),
        help="Fixed number of missing sweep rows per generated resume chunk CSV.",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Automate Hybrid/BEV sensitivity-analysis workflow.")
    sub = parser.add_subparsers(dest="cmd", required=False)

    p_setup = sub.add_parser("setup-venv")
    p_setup.set_defaults(func=setup_venv)

    p_pre = sub.add_parser("pre-sim")
    add_common_args(p_pre)
    p_pre.set_defaults(func=cmd_pre_sim)

    p_matlab = sub.add_parser("matlab")
    add_common_args(p_matlab)
    p_matlab.set_defaults(func=cmd_matlab)

    p_plan = sub.add_parser("plan-resume")
    add_common_args(p_plan)
    add_resume_plan_args(p_plan)
    p_plan.set_defaults(func=cmd_plan_resume)

    p_matlab_resume = sub.add_parser("matlab-resume")
    add_common_args(p_matlab_resume)
    add_resume_plan_args(p_matlab_resume)
    p_matlab_resume.set_defaults(func=cmd_matlab_resume)

    p_post = sub.add_parser("post-sim")
    add_common_args(p_post)
    p_post.add_argument("--ignore-missing-results", action="store_true")
    p_post.set_defaults(func=cmd_post_sim)

    p_auto = sub.add_parser("auto")
    add_common_args(p_auto)
    p_auto.set_defaults(func=cmd_auto)

    return parser


def normalize_argv() -> None:
    if len(sys.argv) <= 1:
        return

    known_commands = {"setup-venv", "pre-sim", "matlab", "plan-resume", "matlab-resume", "post-sim", "auto"}

    first = sys.argv[1]

    if first not in known_commands and first.startswith("-"):
        sys.argv.insert(1, "auto")


def main() -> None:
    if len(sys.argv) == 1:
        run_default_no_args()
        return

    normalize_argv()

    parser = build_parser()
    args = parser.parse_args()

    if not hasattr(args, "func"):
        run_default_no_args()
        return

    args.func(args)


if __name__ == "__main__":
    main()
