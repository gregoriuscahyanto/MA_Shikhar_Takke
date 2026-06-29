#!/usr/bin/env python3
"""Low-I/O dynamic DoE Hybrid HPC helper.

Intermediate HPC results are CSV to avoid heavy Excel I/O. The post step writes
one final Excel workbook for comparison with DoE_ActualValues_Hybrid.xlsx.
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import shutil
from pathlib import Path
from typing import Iterable

import pandas as pd

ROOT = Path(__file__).resolve().parent
DEFAULT_SIM_REL = Path("Simulation_Model") / "Krisna_20260625" / "20260625 - neuer Testlauf"
DEFAULT_DOE_REL = DEFAULT_SIM_REL / "DoE"


def normalize_id(value):
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


def ids_from_df(df: pd.DataFrame, col: str = "RUN_ID") -> set:
    if col not in df.columns:
        return set()
    out = set()
    for value in df[col].tolist():
        v = normalize_id(value)
        if v is not None:
            out.add(v)
    return out


def result_valid_mask(df: pd.DataFrame) -> pd.Series:
    """Return rows that should count as completed simulations.

    Old failed HPC attempts can create non-empty CSV chunks where every SL_*
    value is NaN because the Simulink model was not found. Those rows must not
    be treated as done during resume planning.
    """
    if df.empty:
        return pd.Series([], dtype=bool)

    preferred = [
        "SL_time_0_to_100",
        "time_0_to_100",
        "SL_time_0_to_200",
        "SL_max_speed",
        "max_speed",
    ]
    sim_cols = [c for c in preferred if c in df.columns]
    if not sim_cols:
        # For non-simulation files, fall back to RUN_ID presence.
        return pd.Series([True] * len(df), index=df.index)

    valid = pd.Series([False] * len(df), index=df.index)
    for col in sim_cols:
        vals = pd.to_numeric(df[col], errors="coerce")
        valid = valid | vals.notna()
    return valid


def valid_ids_from_result_df(df: pd.DataFrame, col: str = "RUN_ID") -> set:
    if col not in df.columns or df.empty:
        return set()
    mask = result_valid_mask(df)
    return ids_from_df(df.loc[mask].copy(), col)


def read_result_file(path: Path) -> pd.DataFrame:
    if path.suffix.lower() == ".csv":
        return pd.read_csv(path)
    if path.suffix.lower() in {".xlsx", ".xlsm", ".xls"}:
        return pd.read_excel(path)
    raise ValueError(f"Unsupported result file: {path}")


def iter_existing_result_files(results_dir: Path) -> Iterable[Path]:
    chunks_dir = results_dir / "chunks"
    if chunks_dir.exists():
        for pattern in ("DoE_chunk_*.csv", "DoE_chunk_*.xlsx"):
            for path in sorted(chunks_dir.glob(pattern)):
                if path.name.startswith("~$") or ".tmp." in path.name:
                    continue
                yield path
    final_file = results_dir / "DoE_Hybrid_Results_Comparison.xlsx"
    if final_file.exists():
        yield final_file


def existing_done_ids(results_dir: Path) -> set:
    done = set()
    for path in iter_existing_result_files(results_dir):
        try:
            df = read_result_file(path)
        except Exception as exc:
            print(f"WARNING: cannot read existing result {path}: {exc}")
            continue
        valid_ids = valid_ids_from_result_df(df, "RUN_ID")
        invalid_count = max(0, len(df) - len(valid_ids))
        if invalid_count:
            print(f"Resume ignores {invalid_count} invalid/NaN row(s) in {path}")
        done.update(valid_ids)
    return done


def add_actual_comparison(results: pd.DataFrame, actuals_file: Path | None) -> pd.DataFrame:
    if results.empty or "RUN_ID" not in results.columns:
        return results
    if actuals_file is None or not actuals_file.exists():
        print("ActualValues file missing. Final Excel will not contain Actual/Error columns.")
        return results

    actuals = pd.read_excel(actuals_file)
    if "RUN_ID" not in actuals.columns:
        print("ActualValues has no RUN_ID column. Skipping comparison columns.")
        return results

    actual_col = None
    for col in actuals.columns:
        c = str(col).lower()
        if "actual" in c and "100" in c:
            actual_col = col
            break
    if actual_col is None:
        candidates = [c for c in actuals.columns if c != "RUN_ID"]
        if not candidates:
            return results
        actual_col = candidates[0]

    out = results.copy()
    out["RUN_ID"] = out["RUN_ID"].map(normalize_id)
    actual_map = {
        normalize_id(rid): val
        for rid, val in zip(actuals["RUN_ID"], actuals[actual_col])
        if normalize_id(rid) is not None
    }
    out["Actual_0_to_100_s"] = out["RUN_ID"].map(actual_map)

    sim_col = None
    for candidate in ("SL_time_0_to_100", "time_0_to_100"):
        if candidate in out.columns:
            sim_col = candidate
            break
    if sim_col:
        sim = pd.to_numeric(out[sim_col], errors="coerce")
        actual = pd.to_numeric(out["Actual_0_to_100_s"], errors="coerce")
        out["Error_0_to_100_s"] = sim - actual
        out["Error_0_to_100_pct"] = 100.0 * out["Error_0_to_100_s"] / actual
    return out


def cmd_plan(args: argparse.Namespace) -> None:
    input_csv = Path(args.input_csv).resolve()
    results_dir = Path(args.results_dir).resolve()
    plan_dir = Path(args.plan_dir).resolve()
    chunk_size = int(args.chunk_size)

    if chunk_size < 1:
        raise ValueError("--chunk-size must be >= 1")
    if not input_csv.exists():
        raise FileNotFoundError(input_csv)

    df = pd.read_csv(input_csv)
    if "RUN_ID" not in df.columns:
        df.insert(0, "RUN_ID", range(1, len(df) + 1))
    df["__norm_run_id__"] = df["RUN_ID"].map(normalize_id)

    done_ids = existing_done_ids(results_dir)
    missing = df[~df["__norm_run_id__"].isin(done_ids)].copy()
    missing = missing.drop(columns=["__norm_run_id__"])

    pending_dir = plan_dir / "pending"
    claim_dir = plan_dir / "claims"
    done_dir = plan_dir / "done"
    worker_marker_dir = plan_dir / "worker_markers"

    for d in (pending_dir, claim_dir, done_dir, worker_marker_dir):
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True, exist_ok=True)

    results_chunks_dir = results_dir / "chunks"
    results_chunks_dir.mkdir(parents=True, exist_ok=True)

    manifest_rows: list[dict] = []
    chunk_id = 1
    for start in range(0, len(missing), chunk_size):
        chunk_df = missing.iloc[start:start + chunk_size].copy()
        chunk_csv = pending_dir / f"DoE_chunk_{chunk_id:06d}.csv"
        output_csv = results_chunks_dir / f"DoE_chunk_{chunk_id:06d}.csv"
        chunk_df.to_csv(chunk_csv, index=False)
        ids = [normalize_id(v) for v in chunk_df["RUN_ID"].tolist()]
        ids = [v for v in ids if v is not None]
        manifest_rows.append({
            "chunk_id": chunk_id,
            "n_rows": len(chunk_df),
            "first_run_id": ids[0] if ids else "",
            "last_run_id": ids[-1] if ids else "",
            "chunk_csv": str(chunk_csv),
            "output_csv": str(output_csv),
        })
        chunk_id += 1

    manifest_file = plan_dir / "manifest.csv"
    fieldnames = ["chunk_id", "n_rows", "first_run_id", "last_run_id", "chunk_csv", "output_csv"]
    with manifest_file.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(manifest_rows)

    summary_lines = [
        f"input_csv={input_csv}",
        f"results_dir={results_dir}",
        f"total_input_rows={len(df)}",
        f"already_done_rows={len(done_ids)}",
        f"missing_rows={len(missing)}",
        f"chunk_size={chunk_size}",
        f"planned_chunks={len(manifest_rows)}",
        f"manifest={manifest_file}",
    ]
    (plan_dir / "summary.txt").write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    (plan_dir / "chunk_count.txt").write_text(str(len(manifest_rows)) + "\n", encoding="utf-8")

    print("============================================================")
    print("DoE low-I/O plan created")
    print("============================================================")
    print("\n".join(summary_lines))


def cmd_post(args: argparse.Namespace) -> None:
    input_csv = Path(args.input_csv).resolve()
    actuals_file = Path(args.actuals_file).resolve() if args.actuals_file else None
    results_dir = Path(args.results_dir).resolve()
    chunks_dir = results_dir / "chunks"
    final_file = results_dir / "DoE_Hybrid_Results_Comparison.xlsx"

    if not input_csv.exists():
        raise FileNotFoundError(input_csv)
    if not chunks_dir.exists() and not final_file.exists():
        raise FileNotFoundError(f"No chunks or final result found below {results_dir}")

    frames = []
    if final_file.exists():
        try:
            old_final = pd.read_excel(final_file, sheet_name="Comparison")
        except Exception:
            old_final = pd.read_excel(final_file)
        if not old_final.empty:
            old_final["SourceFile"] = "previous_final"
            frames.append(old_final)

    if chunks_dir.exists():
        for pattern in ("DoE_chunk_*.csv", "DoE_chunk_*.xlsx"):
            for path in sorted(chunks_dir.glob(pattern)):
                if path.name.startswith("~$") or ".tmp." in path.name:
                    continue
                try:
                    df = read_result_file(path)
                except Exception as exc:
                    print(f"WARNING: skipping unreadable chunk result {path}: {exc}")
                    continue
                if not df.empty:
                    df["SourceFile"] = path.name
                    frames.append(df)

    combined = pd.concat(frames, ignore_index=True, sort=False) if frames else pd.DataFrame()
    if "RUN_ID" in combined.columns:
        combined["RUN_ID"] = combined["RUN_ID"].map(normalize_id)
        combined = combined.dropna(subset=["RUN_ID"])
        combined = combined.drop_duplicates(subset=["RUN_ID"], keep="last").sort_values("RUN_ID")

    combined = add_actual_comparison(combined, actuals_file)

    input_df = pd.read_csv(input_csv)
    expected_ids = ids_from_df(input_df, "RUN_ID")
    valid_result_ids = valid_ids_from_result_df(combined, "RUN_ID")
    result_ids = ids_from_df(combined, "RUN_ID")
    missing_ids = sorted(expected_ids - valid_result_ids)
    invalid_ids = sorted(result_ids - valid_result_ids)

    results_dir.mkdir(parents=True, exist_ok=True)
    tmp_file = final_file.with_suffix(".tmp.xlsx")
    with pd.ExcelWriter(tmp_file, engine="openpyxl") as writer:
        combined.to_excel(writer, index=False, sheet_name="Comparison")
        summary = pd.DataFrame([
            {"Metric": "Rows in DoE_Inp_Hybrid", "Value": len(input_df)},
            {"Metric": "Rows in merged results", "Value": len(combined)},
            {"Metric": "Missing/invalid RUN_ID count", "Value": len(missing_ids)},
            {"Metric": "Invalid/NaN RUN_ID count", "Value": len(invalid_ids)},
            {"Metric": "Chunk result CSV files", "Value": len(list(chunks_dir.glob('DoE_chunk_*.csv'))) if chunks_dir.exists() else 0},
            {"Metric": "Final file", "Value": str(final_file)},
        ])
        summary.to_excel(writer, index=False, sheet_name="Summary")
        pd.DataFrame({"Missing_or_Invalid_RUN_ID": missing_ids}).to_excel(writer, index=False, sheet_name="Missing_RUN_IDs")
        pd.DataFrame({"Invalid_NaN_RUN_ID": invalid_ids}).to_excel(writer, index=False, sheet_name="Invalid_RUN_IDs")
    tmp_file.replace(final_file)

    print("============================================================")
    print("DoE final Excel written")
    print("============================================================")
    print(f"Final file       : {final_file}")
    print(f"Rows merged      : {len(combined)}")
    print(f"Expected rows    : {len(input_df)}")
    print(f"Missing/invalid RUN_IDs: {len(missing_ids)}")
    print(f"Invalid/NaN RUN_IDs    : {len(invalid_ids)}")
    if missing_ids:
        preview = ", ".join(str(x) for x in missing_ids[:20])
        more = "" if len(missing_ids) <= 20 else f" ... (+{len(missing_ids)-20} more)"
        print(f"WARNING missing/invalid: {preview}{more}")
        if not args.allow_incomplete:
            raise RuntimeError("Final result is incomplete. Re-submit the SLURM script to resume missing rows.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Low-I/O dynamic DoE Hybrid HPC helper")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--input-csv", default=str(ROOT / DEFAULT_DOE_REL / "DoE_Inp_Hybrid.csv"))
    p_plan.add_argument("--results-dir", default=str(ROOT / DEFAULT_DOE_REL / "DoE_Hybrid_HPC_Results"))
    p_plan.add_argument("--plan-dir", default=str(ROOT / "logs" / "doe_current_plan"))
    p_plan.add_argument("--chunk-size", type=int, default=int(os.environ.get("DOE_CHUNK_SIZE", "10")))
    p_plan.set_defaults(func=cmd_plan)

    p_post = sub.add_parser("post")
    p_post.add_argument("--input-csv", default=str(ROOT / DEFAULT_DOE_REL / "DoE_Inp_Hybrid.csv"))
    p_post.add_argument("--actuals-file", default=str(ROOT / DEFAULT_DOE_REL / "DoE_ActualValues_Hybrid.xlsx"))
    p_post.add_argument("--results-dir", default=str(ROOT / DEFAULT_DOE_REL / "DoE_Hybrid_HPC_Results"))
    p_post.add_argument("--allow-incomplete", action="store_true")
    p_post.set_defaults(func=cmd_post)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
