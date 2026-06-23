#!/usr/bin/env python3
"""
Root-level helper for the Hybrid and BEV sensitivity-analysis workflow.

Typical workflow from repository root:

  python run_sensitivity_pipeline.py setup-venv
  .venv\Scripts\activate              # Windows PowerShell/CMD
  # or: source .venv/bin/activate       # Linux/macOS

  python run_sensitivity_pipeline.py pre-sim --powertrain both

  # Run the generated sweep_*.csv files through Simulink/MATLAB.
  # Save results as sweep_results_hybrid_G1.xlsx ... sweep_results_hybrid_G5.xlsx
  # and/or sweep_results_bev_G1.xlsx ... sweep_results_bev_G5.xlsx.

  python run_sensitivity_pipeline.py post-sim --powertrain both

You can also run everything that is possible without Simulink via:

  python run_sensitivity_pipeline.py auto --powertrain both

The auto command runs setup check, split and sweep, then analyzes only if all required
sweep result files are already present.
"""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
import venv
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent
VENV_DIR = ROOT / ".venv"
REQ_FILE = ROOT / "requirements_sensitivity.txt"

GROUP_SHORT = ["G1", "G2", "G3", "G4", "G5"]
POWERTRAINS = {
    "hybrid": {
        "script": ROOT / "Data_Analysis" / "Sensitivity analysis" / "Hybrid" / "Sensitivity_Analysis_Hybrid.py",
        "work_dir": ROOT / "Data_Analysis" / "Sensitivity analysis" / "Hybrid",
        "result_prefix": "sweep_results_hybrid",
        "output_dir": "hybrid_sensitivity_results",
    },
    "bev": {
        "script": ROOT / "Data_Analysis" / "Sensitivity analysis" / "BEV" / "Sensitivity_Analysis_BEV.py",
        "work_dir": ROOT / "Data_Analysis" / "Sensitivity analysis" / "BEV",
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
    if value == "both":
        return ["hybrid", "bev"]
    return [value]


def ensure_paths(powertrains: Iterable[str]) -> None:
    for pt in powertrains:
        cfg = POWERTRAINS[pt]
        if not cfg["script"].exists():
            raise FileNotFoundError(f"Missing script for {pt}: {cfg['script']}")
        cfg["work_dir"].mkdir(parents=True, exist_ok=True)


def setup_venv(args: argparse.Namespace) -> None:
    if not VENV_DIR.exists():
        print(f"Creating virtual environment: {VENV_DIR}")
        venv.EnvBuilder(with_pip=True, clear=False).create(VENV_DIR)
    else:
        print(f"Virtual environment already exists: {VENV_DIR}")

    py = venv_python()
    if not py.exists():
        raise FileNotFoundError(f"Could not find venv Python: {py}")

    run([py, "-m", "pip", "install", "--upgrade", "pip"])
    run([py, "-m", "pip", "install", "-r", REQ_FILE])

    print("\nVenv is ready.")
    if is_windows():
        print(r"Activate it with: .venv\Scripts\activate")
    else:
        print("Activate it with: source .venv/bin/activate")


def warn_if_not_venv(args: argparse.Namespace) -> None:
    if args.no_venv_check:
        return
    if not VENV_DIR.exists():
        print("WARNING: .venv does not exist yet. Run: python run_sensitivity_pipeline.py setup-venv")
        return
    if not in_expected_venv():
        print("WARNING: You are not using the repo .venv Python.")
        print(f"Current Python: {current_python()}")
        print(f"Expected Python: {venv_python()}")
        print("Continue is allowed, but activate .venv if packages are missing.")


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
    result_dir = Path(args.sweep_results_dir) if args.sweep_results_dir else None
    return [p for p in result_candidates(pt, result_dir) if not p.exists()]


def print_simulation_todo(powertrains: Iterable[str], args: argparse.Namespace) -> None:
    print("\nNext step: run the generated sweep CSVs through Simulink/MATLAB.")
    for pt in powertrains:
        cfg = POWERTRAINS[pt]
        print(f"\n{pt.upper()} sweep input files:")
        for p in sorted(cfg["work_dir"].glob(f"sweep_{pt}_G*.csv")):
            print(f"  {p.relative_to(ROOT)}")
        print(f"\nExpected {pt.upper()} result files:")
        for p in result_candidates(pt, Path(args.sweep_results_dir) if args.sweep_results_dir else None):
            print(f"  {p.relative_to(ROOT) if p.is_relative_to(ROOT) else p}")


def cmd_pre_sim(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    for pt in pts:
        print(f"\n=== {pt.upper()}: split ===")
        run_split(pt, args)
        print(f"\n=== {pt.upper()}: sweep ===")
        run_sweep(pt, args)
    print_simulation_todo(pts, args)


def cmd_post_sim(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    for pt in pts:
        missing = missing_result_files(pt, args)
        if missing and not args.ignore_missing_results:
            print(f"\nCannot analyze {pt.upper()} yet. Missing result files:")
            for p in missing:
                print(f"  {p}")
            print("Use --ignore-missing-results only if your result files use alternative names supported by the analysis script.")
            continue
        print(f"\n=== {pt.upper()}: analyze ===")
        run_analyze(pt, args)


def cmd_auto(args: argparse.Namespace) -> None:
    pts = selected_powertrains(args.powertrain)
    warn_if_not_venv(args)
    ensure_paths(pts)
    for pt in pts:
        print(f"\n=== {pt.upper()}: split ===")
        run_split(pt, args)
        print(f"\n=== {pt.upper()}: sweep ===")
        run_sweep(pt, args)

    any_missing = False
    for pt in pts:
        missing = missing_result_files(pt, args)
        if missing:
            any_missing = True
            print(f"\n{pt.upper()} analyze skipped because result files are missing:")
            for p in missing:
                print(f"  {p}")

    if any_missing:
        print_simulation_todo(pts, args)
        return

    for pt in pts:
        print(f"\n=== {pt.upper()}: analyze ===")
        run_analyze(pt, args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Automate Hybrid/BEV sensitivity-analysis Python steps.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_setup = sub.add_parser("setup-venv", help="Create .venv and install requirements_sensitivity.txt.")
    p_setup.set_defaults(func=setup_venv)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--powertrain", choices=["hybrid", "bev", "both"], default="both")
        p.add_argument("--tolerance", type=float, default=0.10, help="Relative pass/fail tolerance; default 0.10 = +/-10%%.")
        p.add_argument("--input_csv", default=None, help="Optional explicit input CSV path for split.")
        p.add_argument("--results_file", default=None, help="Optional explicit original results/comparison file for split.")
        p.add_argument("--sweep_results_dir", default=None, help="Directory containing sweep_results_*.xlsx/csv for analyze.")
        p.add_argument("--output_dir", default=None, help="Optional output dir for analyze. For both, prefer leaving this empty.")
        p.add_argument("--no-venv-check", action="store_true", help="Do not warn when current Python is not .venv Python.")

    p_pre = sub.add_parser("pre-sim", help="Run split and sweep. Stop before Simulink/MATLAB simulation.")
    add_common(p_pre)
    p_pre.set_defaults(func=cmd_pre_sim)

    p_post = sub.add_parser("post-sim", help="Run analyze after sweep result files are available.")
    add_common(p_post)
    p_post.add_argument("--ignore-missing-results", action="store_true")
    p_post.set_defaults(func=cmd_post_sim)

    p_auto = sub.add_parser("auto", help="Run split+sweep, and analyze only when result files already exist.")
    add_common(p_auto)
    p_auto.set_defaults(func=cmd_auto)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
