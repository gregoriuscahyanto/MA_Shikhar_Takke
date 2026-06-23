import argparse
import itertools
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

GROUP_BINS = [0, 5, 7, 10, 13, 1000]
GROUP_LABELS = ["G1_lt5s", "G2_5to7s", "G3_7to10s", "G4_10to13s", "G5_gt13s"]
GROUP_SHORT = ["G1", "G2", "G3", "G4", "G5"]

SIM_COL_CANDIDATES = [
    "SL_time_0_to_100",
    "SL_time_0_to_100_6.4",
    "SL_time_0_to_100_6",
    "time_0_to_100",
]
ACTUAL_COL_CANDIDATES = [
    "Actual_0_to_100",
    "actual_0_100",
    "actual_0_to_100",
    "Actual 0 to 100",
    "Actual 0 to 100 time",
    "Actual 0-100 time",
    "Actual 0-100",
    "0-100 actual",
    "0_to_100_actual",
]
RUN_ID_CANDIDATES = ["RUN_ID", "run_id", "Run_ID", "Run ID", "ID"]

RESULT_CANDIDATES = [
    "Final_Simulation_Results_ALL_RUN_IDs.xlsx",
    "Final_Simulation_Results_ALL_RUN_IDs_Hybrid.xlsx",
    "Final_Simulation_Results_ALL_RUN_IDs_BEV.xlsx",
    "Final_Simulation_Results_ALL_RUN_IDs_EV.xlsx",
    "NewActual_Simulation_Comparison.xlsx",
]
ACTUAL_FILE_CANDIDATES = [
    "NewActual_Simulation_Comparison.xlsx",
    "Actual_Simulation_Comparison.xlsx",
    "Actual_0_to_100.xlsx",
    "Actual_0_to_100.csv",
    "actual_0_to_100.xlsx",
    "actual_0_to_100.csv",
]

OUTPUT_COLS = ["error", "pct_error", "pass_fail", "group", "Actual_0_to_100", "SL_time_0_to_100"]


@dataclass
class PipelineConfig:
    powertrain: str
    input_candidates: list[str]
    sweep_config: dict
    sweep_params: list[str]
    changed_params: list[str]
    scale_groups: dict[str, list[str]]
    filter_col_equals: dict[str, int]
    default_output_dir: str


def clean_col(c):
    return re.sub(r"[\ufeff\t\n\r\xa0]+", " ", str(c)).strip()


def read_table(path):
    path = Path(path)
    if path.suffix.lower() in [".xlsx", ".xls"]:
        df = pd.read_excel(path)
    else:
        df = pd.read_csv(path, encoding="utf-8-sig")
    df.columns = [clean_col(c) for c in df.columns]
    return df[[c for c in df.columns if not c.lower().startswith("unnamed")]].copy()


def find_col(df, candidates, required=True):
    lookup = {clean_col(c).lower(): c for c in df.columns}
    for cand in candidates:
        key = clean_col(cand).lower()
        if key in lookup:
            return lookup[key]
    if required:
        raise KeyError(f"None of {candidates} found in columns: {list(df.columns)}")
    return None


def safe_num(v):
    try:
        return float(v)
    except Exception:
        return np.nan


def candidate_paths(candidates, base_dir):
    base_dir = Path(base_dir)
    seen = set()
    paths = []

    for cand in candidates:
        p = base_dir / cand
        if p.exists() and p not in seen:
            paths.append(p)
            seen.add(p)

    for cand in candidates:
        name = Path(cand).name
        for p in base_dir.rglob(name):
            if ".git" in p.parts or ".venv" in p.parts:
                continue
            if p.exists() and p not in seen:
                paths.append(p)
                seen.add(p)

    return paths


def discover_actual_like_files(base_dir):
    base_dir = Path(base_dir)
    files = []
    for pattern in ["*.xlsx", "*.xls", "*.csv"]:
        for p in base_dir.rglob(pattern):
            if ".git" in p.parts or ".venv" in p.parts:
                continue
            name = p.name.lower()
            if "actual" in name or "comparison" in name or "vergleich" in name:
                files.append(p)
    return files


def find_existing(candidates, base_dir):
    paths = candidate_paths(candidates, base_dir)
    return paths[0] if paths else None


def find_sim_result_file(work_dir, explicit_path=None):
    candidates = [Path(explicit_path)] if explicit_path else candidate_paths(RESULT_CANDIDATES, work_dir)
    errors = []
    for p in candidates:
        try:
            df = read_table(p)
            sim_col = find_col(df, SIM_COL_CANDIDATES, required=False)
            if sim_col is not None:
                return Path(p), df, sim_col
            errors.append(f"{p}: no simulation column found")
        except Exception as exc:
            errors.append(f"{p}: {exc}")
    raise FileNotFoundError(
        "No simulation result file with a 0-100 simulation column was found.\n"
        "Expected one of these columns: " + ", ".join(SIM_COL_CANDIDATES) + "\n"
        "Use --results_file to pass the correct result file.\n"
        + "\n".join(errors[:10])
    )


def normalize_run_id(df, source_name):
    run_col = find_col(df, RUN_ID_CANDIDATES, required=False)
    if run_col is None:
        return df, None
    if run_col != "RUN_ID":
        df = df.rename(columns={run_col: "RUN_ID"})
    return df, "RUN_ID"


def find_actual_source(work_dir, result_path, df_result, explicit_actuals_file=None):
    actual_col = find_col(df_result, ACTUAL_COL_CANDIDATES, required=False)
    if actual_col is not None:
        return result_path, df_result.copy(), actual_col

    if explicit_actuals_file:
        paths = [Path(explicit_actuals_file)]
    else:
        paths = candidate_paths(ACTUAL_FILE_CANDIDATES, work_dir) + discover_actual_like_files(work_dir)

    seen = set()
    for p in paths:
        p = Path(p)
        if p in seen:
            continue
        seen.add(p)
        if p == Path(result_path):
            continue
        try:
            df = read_table(p)
            actual_col = find_col(df, ACTUAL_COL_CANDIDATES, required=False)
            if actual_col is not None:
                return p, df, actual_col
        except Exception:
            continue

    raise FileNotFoundError(
        "The selected simulation result file does not contain an Actual 0-100 column.\n"
        f"Selected result file: {result_path}\n"
        f"Columns found: {list(df_result.columns)}\n\n"
        "For the sensitivity split, one reference/actual 0-100 value per RUN_ID is required.\n"
        "Place a file such as 'NewActual_Simulation_Comparison.xlsx' in the repo or pass it explicitly:\n"
        "  python run_sensitivity_pipeline.py auto --actuals_file path\\to\\NewActual_Simulation_Comparison.xlsx\n\n"
        "The actual file should contain either:\n"
        "  - RUN_ID + Actual_0_to_100, or\n"
        "  - Actual_0_to_100 in the same row order as the simulation results."
    )


def attach_actual_values(df_base, df_result, df_actual, actual_col):
    df_actual, actual_run_col = normalize_run_id(df_actual.copy(), "actual")

    if actual_run_col == "RUN_ID":
        actual_small = df_actual[["RUN_ID", actual_col]].copy()
        actual_small.rename(columns={actual_col: "Actual_0_to_100"}, inplace=True)
        return pd.merge(df_base, actual_small, on="RUN_ID", how="inner")

    if len(df_actual) == len(df_base):
        df_base = df_base.copy().reset_index(drop=True)
        df_base["Actual_0_to_100"] = df_actual[actual_col].reset_index(drop=True)
        print("WARNING: Actual file has no RUN_ID. Actual values were attached by current row order.")
        return df_base

    if len(df_actual) == len(df_result) and "RUN_ID" in df_result.columns:
        actual_small = pd.DataFrame({
            "RUN_ID": df_result["RUN_ID"].values,
            "Actual_0_to_100": df_actual[actual_col].values,
        })
        print("WARNING: Actual file has no RUN_ID. Actual values were mapped to result RUN_ID by row order.")
        return pd.merge(df_base, actual_small, on="RUN_ID", how="inner")

    raise ValueError(
        "Actual file has no RUN_ID and row-order mapping is not possible.\n"
        f"Rows in merged input/result data: {len(df_base)}\n"
        f"Rows in actual file: {len(df_actual)}\n"
        "Add a RUN_ID column to the actual/comparison file or pass a matching file with --actuals_file."
    )


def scale_existing(new_row, row, cols, scale, skip_zero=True, lower=None, upper=None):
    for col in cols:
        if col not in row.index:
            continue
        val = safe_num(row[col])
        if np.isnan(val):
            continue
        if skip_zero and abs(val) < 1e-12:
            continue
        nv = val * scale
        if lower is not None or upper is not None:
            lo = -np.inf if lower is None else lower
            hi = np.inf if upper is None else upper
            nv = float(np.clip(nv, lo, hi))
        new_row[col] = nv


def apply_powertrain_filter(df, config):
    df = df.copy()
    for col, expected in config.filter_col_equals.items():
        if col in df.columns:
            values = pd.to_numeric(df[col], errors="coerce").fillna(0).astype(int)
            df = df[values == expected].copy()
    return df


def result_file_for_group(work_dir, config, group):
    short = group.split("_")[0]
    candidates = [
        f"sweep_results_{config.powertrain}_{group}.xlsx",
        f"sweep_results_{config.powertrain}_{short}.xlsx",
        f"sweep_results_{group}.xlsx",
        f"sweep_results_{short}.xlsx",
        f"sweep_results_{config.powertrain}_{group}.csv",
        f"sweep_results_{config.powertrain}_{short}.csv",
        f"sweep_results_{group}.csv",
        f"sweep_results_{short}.csv",
    ]
    return find_existing(candidates, work_dir)


def split_inputs(args, config):
    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir or work_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    input_file = Path(args.input_csv) if args.input_csv else find_existing(config.input_candidates, work_dir)
    if input_file is None:
        raise FileNotFoundError(f"{config.powertrain.upper()} input CSV not found. Pass --input_csv.")

    result_file, df_result, sim_col = find_sim_result_file(work_dir, args.results_file)
    df_result, result_run_col = normalize_run_id(df_result, "result")
    if result_run_col is None:
        raise KeyError(f"Result file must contain RUN_ID: {result_file}")

    actual_file, df_actual, actual_col = find_actual_source(work_dir, result_file, df_result, args.actuals_file)
    print(f"Input file : {input_file}")
    print(f"Result file: {result_file}")
    print(f"Actual file: {actual_file}")
    print(f"Sim column : {sim_col}")
    print(f"Actual col : {actual_col}")

    df_inp = read_table(input_file)
    df_inp, input_run_col = normalize_run_id(df_inp, "input")
    if input_run_col is None:
        raise KeyError(f"Input file must contain RUN_ID: {input_file}")

    df_sim = df_result[["RUN_ID", sim_col]].copy()
    df_sim.rename(columns={sim_col: "SL_time_0_to_100"}, inplace=True)
    df = pd.merge(df_inp, df_sim, on="RUN_ID", how="inner")
    df = attach_actual_values(df, df_result, df_actual, actual_col)

    df = apply_powertrain_filter(df, config)
    df = df.dropna(subset=["Actual_0_to_100", "SL_time_0_to_100"]).copy()
    if len(df) == 0:
        raise RuntimeError(
            f"No {config.powertrain.upper()} rows remain after merge/filter. Check RUN_ID mapping and EV/Hy flags."
        )

    df["Actual_0_to_100"] = pd.to_numeric(df["Actual_0_to_100"], errors="coerce")
    df["SL_time_0_to_100"] = pd.to_numeric(df["SL_time_0_to_100"], errors="coerce")
    df = df.dropna(subset=["Actual_0_to_100", "SL_time_0_to_100"]).copy()

    df["error"] = df["SL_time_0_to_100"] - df["Actual_0_to_100"]
    df["pct_error"] = df["error"] / df["Actual_0_to_100"] * 100
    df["pass_fail"] = np.where(df["pct_error"].abs() > args.tolerance * 100, "FAIL", "PASS")
    df["group"] = pd.cut(df["Actual_0_to_100"], bins=GROUP_BINS, labels=GROUP_LABELS)

    input_cols = [c for c in df_inp.columns if c in df.columns]
    cols_to_save = input_cols + ["Actual_0_to_100", "SL_time_0_to_100", "error", "pct_error", "pass_fail", "group"]

    for g in GROUP_LABELS:
        gdf = df[df["group"] == g][cols_to_save]
        out = out_dir / f"sensitivity_{config.powertrain}_{g}.csv"
        gdf.to_csv(out, index=False)
        pass_rate = (gdf["pass_fail"] == "PASS").mean() * 100 if len(gdf) else 0.0
        print(f"{g}: {len(gdf)} runs | Pass: {pass_rate:.1f}% | saved {out}")


def generate_sweep_inputs(args, config):
    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir or work_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for g in GROUP_LABELS:
        in_file = work_dir / f"sensitivity_{config.powertrain}_{g}.csv"
        if not in_file.exists():
            print(f"Skipping {g}: missing {in_file}")
            continue
        gdf = read_table(in_file)
        fails = gdf[gdf["pass_fail"].astype(str).str.upper() == "FAIL"].copy()
        all_input_cols = [c for c in gdf.columns if c not in OUTPUT_COLS]
        rows = []
        new_run_id = 1
        cfg = config.sweep_config[g]
        keys = config.sweep_params

        for _, row in fails.iterrows():
            for combo in itertools.product(*(cfg[k] for k in keys)):
                combo_map = dict(zip(keys, combo))
                new_row = row[all_input_cols].copy()

                for scale_name, cols in config.scale_groups.items():
                    if scale_name not in combo_map:
                        continue
                    if scale_name == "gear_scale":
                        scale_existing(new_row, row, cols, combo_map[scale_name], lower=0.05, upper=20.0)
                    else:
                        scale_existing(new_row, row, cols, combo_map[scale_name])

                if "shift_delta" in combo_map and "shiftDelay" in row.index:
                    new_row["shiftDelay"] = float(np.clip(safe_num(row["shiftDelay"]) + combo_map["shift_delta"], 0.05, 1.5))
                if "mass_scale" in combo_map and "m_curb" in row.index:
                    new_row["m_curb"] = safe_num(row["m_curb"]) * combo_map["mass_scale"]

                new_row["ORIG_RUN_ID"] = row["RUN_ID"]
                new_row["SWEEP_RUN_ID"] = new_run_id
                for p in config.sweep_params:
                    new_row[p] = combo_map[p]
                new_row["actual_0_100"] = row["Actual_0_to_100"]
                rows.append(new_row)
                new_run_id += 1

        sweep_df = pd.DataFrame(rows)
        if len(sweep_df):
            tracking = ["SWEEP_RUN_ID", "ORIG_RUN_ID"] + config.sweep_params + ["actual_0_100"]
            sweep_df = sweep_df[tracking + [c for c in sweep_df.columns if c not in tracking]]
        out = out_dir / f"sweep_{config.powertrain}_{g}.csv"
        sweep_df.to_csv(out, index=False)
        print(f"{g}: {len(fails)} failed runs -> {len(sweep_df)} sweep combinations | saved {out}")


def load_sweep_results(args, config):
    work_dir = Path(args.work_dir)
    sweep_results_dir = Path(args.sweep_results_dir or work_dir)
    all_merged = []
    all_original = []
    all_failed = []

    for g in GROUP_LABELS:
        sweep_in = work_dir / f"sweep_{config.powertrain}_{g}.csv"
        orig_in = work_dir / f"sensitivity_{config.powertrain}_{g}.csv"
        res_file = result_file_for_group(sweep_results_dir, config, g)
        if not sweep_in.exists() or not orig_in.exists():
            print(f"Skipping {g}: missing sensitivity/sweep input CSV.")
            continue
        orig = read_table(orig_in)
        orig["group"] = g
        all_original.append(orig)
        all_failed.append(orig[orig["pass_fail"].astype(str).str.upper() == "FAIL"].copy())

        if res_file is None:
            print(f"Skipping {g}: no sweep result file found. Expected e.g. sweep_results_{config.powertrain}_{g}.xlsx")
            continue
        inp = read_table(sweep_in)
        res = read_table(res_file)
        sim_col = find_col(res, SIM_COL_CANDIDATES)
        res, res_run_col = normalize_run_id(res, "sweep result")
        if "SWEEP_RUN_ID" not in res.columns:
            raise KeyError(f"{res_file} must contain SWEEP_RUN_ID.")
        res = res.dropna(subset=["SWEEP_RUN_ID", sim_col]).copy()
        res["SWEEP_RUN_ID"] = res["SWEEP_RUN_ID"].astype(int)
        inp["SWEEP_RUN_ID"] = inp["SWEEP_RUN_ID"].astype(int)
        merged = pd.merge(inp, res[["SWEEP_RUN_ID", sim_col]], on="SWEEP_RUN_ID", how="inner")
        merged.rename(columns={sim_col: "SL_time_0_to_100_swept"}, inplace=True)
        merged["new_pct_error"] = (merged["SL_time_0_to_100_swept"] - merged["actual_0_100"]) / merged["actual_0_100"] * 100
        merged["new_pass"] = merged["new_pct_error"].abs() <= args.tolerance * 100
        merged["group"] = g
        all_merged.append(merged)
        print(f"Loaded {g}: {len(merged)} swept result rows from {res_file}")

    if not all_original:
        raise RuntimeError("No original sensitivity CSVs found. Run split first.")
    if not all_merged:
        raise RuntimeError("No sweep result files found. Run simulations for sweep_*.csv first, then analyze.")
    return pd.concat(all_merged, ignore_index=True), pd.concat(all_original, ignore_index=True), pd.concat(all_failed, ignore_index=True)


def analyze(args, config):
    output_dir = Path(args.output_dir or config.default_output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    df_all, df_orig_all, df_fail_all = load_sweep_results(args, config)

    best_params = {}
    summary_rows = []
    completed_groups = [g for g in GROUP_LABELS if g in set(df_all["group"])]
    for g in completed_groups:
        gdf = df_all[df_all["group"] == g]
        agg = (
            gdf.groupby(config.sweep_params)
            .agg(
                mean_abs_err=("new_pct_error", lambda x: x.abs().mean()),
                mean_pct_err=("new_pct_error", "mean"),
                pass_rate=("new_pass", "mean"),
                n_runs=("new_pass", "count"),
            )
            .reset_index()
            .sort_values(["pass_rate", "mean_abs_err"], ascending=[False, True])
        )
        best = agg.iloc[0]
        best_params[g] = best
        summary_rows.append({"group": g, **best.to_dict()})
        combo_text = ", ".join(f"{p}={best[p]}" for p in config.sweep_params)
        print(f"{g} best: {combo_text} | pass {best['pass_rate'] * 100:.1f}%")

    def best_sweep(g):
        bp = best_params[g]
        mask = df_all["group"].eq(g)
        for p in config.sweep_params:
            mask &= df_all[p].eq(bp[p])
        return df_all[mask].copy()

    groups = list(best_params.keys())

    fig, ax = plt.subplots(figsize=(10, 5))
    x = np.arange(len(groups))
    w = 0.35
    for i, g in enumerate(groups):
        orig = df_orig_all[df_orig_all["group"] == g]
        n_total = len(orig)
        n_orig_pass = int((orig["pass_fail"].astype(str).str.upper() == "PASS").sum())
        orig_rate = n_orig_pass / n_total * 100 if n_total else 0
        best = best_sweep(g)
        n_recovered = best[best["new_pass"]]["ORIG_RUN_ID"].nunique()
        rec_rate = n_recovered / n_total * 100 if n_total else 0
        ax.bar(i - w / 2, orig_rate, w, label="Original pass" if i == 0 else "")
        ax.bar(i + w / 2, orig_rate, w, label="Original base" if i == 0 else "")
        ax.bar(i + w / 2, rec_rate, w, bottom=orig_rate, label="Recovered by sweep" if i == 0 else "")
        ax.text(i - w / 2, orig_rate + 1, f"{orig_rate:.1f}%", ha="center", fontsize=8)
        ax.text(i + w / 2, orig_rate + rec_rate + 1, f"{orig_rate + rec_rate:.1f}%", ha="center", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(groups, rotation=20)
    ax.set_ylabel("% of all runs in group")
    ax.set_title(f"{config.powertrain.upper()} sensitivity: original pass rate + recovered runs")
    ax.set_ylim(0, 115)
    ax.grid(True, alpha=0.3, axis="y")
    ax.legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(output_dir / f"plotA_{config.powertrain}_pass_rate_recovery.png", dpi=150)
    plt.close()

    for g in groups:
        orig = df_orig_all[df_orig_all["group"] == g].dropna(subset=["Actual_0_to_100", "SL_time_0_to_100"])
        best = best_sweep(g)
        if len(orig) == 0 or len(best) == 0:
            continue
        lim_max = max(
            orig["Actual_0_to_100"].max(),
            best["actual_0_100"].max(),
            orig["SL_time_0_to_100"].max(),
            best["SL_time_0_to_100_swept"].max(),
        ) + 1
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        panels = [
            (axes[0], orig, "Actual_0_to_100", "SL_time_0_to_100", "Original", orig["pass_fail"].astype(str).str.upper() == "PASS"),
            (axes[1], best, "actual_0_100", "SL_time_0_to_100_swept", "Best sweep", best["new_pass"]),
        ]
        for ax, data, xcol, ycol, title, flag in panels:
            ax.scatter(data.loc[flag, xcol], data.loc[flag, ycol], s=18, alpha=0.5, label="Pass")
            ax.scatter(data.loc[~flag, xcol], data.loc[~flag, ycol], s=18, alpha=0.5, label="Fail")
            ax.plot([0, lim_max], [0, lim_max], "k--", linewidth=1)
            ax.plot([0, lim_max], [0, lim_max * 1.1], "r:", linewidth=1)
            ax.plot([0, lim_max], [0, lim_max * 0.9], "r:", linewidth=1)
            ax.set_xlim(0, lim_max)
            ax.set_ylim(0, lim_max)
            ax.set_aspect("equal")
            ax.set_xlabel("Actual 0-100 time (s)")
            ax.set_ylabel("Simulated 0-100 time (s)")
            ax.set_title(title)
            ax.grid(True, alpha=0.3)
            ax.legend(fontsize=8)
        fig.suptitle(f"{config.powertrain.upper()} {g}: actual vs simulated")
        plt.tight_layout()
        plt.savefig(output_dir / f"plotB_{config.powertrain}_scatter_{g}.png", dpi=150)
        plt.close()

    export_path = output_dir / f"{config.powertrain}_recovered_runs.xlsx"
    with pd.ExcelWriter(export_path, engine="openpyxl") as writer:
        pd.DataFrame(summary_rows).to_excel(writer, sheet_name="best_sweep_summary", index=False)
        for g in groups:
            best = best_sweep(g)
            passed = best[best["new_pass"]].copy()
            if len(passed) == 0:
                continue
            orig_fail = df_fail_all[df_fail_all["group"] == g].copy().set_index("RUN_ID")
            changes = {}
            for p in config.changed_params:
                vals = []
                if p not in passed.columns or p not in orig_fail.columns:
                    continue
                for _, row in passed.iterrows():
                    oid = row["ORIG_RUN_ID"]
                    if oid in orig_fail.index:
                        ov, nv = safe_num(orig_fail.loc[oid, p]), safe_num(row[p])
                        if not np.isnan(ov) and not np.isnan(nv) and abs(ov) > 1e-12:
                            vals.append((nv - ov) / abs(ov) * 100)
                if vals:
                    changes[p] = float(np.mean(vals))
            out_cols = ["ORIG_RUN_ID", "SWEEP_RUN_ID"] + config.sweep_params + [c for c in config.changed_params if c in passed.columns] + ["actual_0_100", "SL_time_0_to_100_swept", "new_pct_error"]
            passed[[c for c in out_cols if c in passed.columns]].to_excel(writer, sheet_name=g[:31], index=False)
            if changes:
                fig, ax = plt.subplots(figsize=(8, 4))
                ax.barh(list(changes.keys()), list(changes.values()))
                ax.axvline(0, color="black", linestyle="--", linewidth=1)
                ax.set_xlabel("Mean % change from original")
                ax.set_title(f"{config.powertrain.upper()} {g}: mean parameter change in recovered runs")
                ax.grid(True, alpha=0.3, axis="x")
                plt.tight_layout()
                plt.savefig(output_dir / f"plotC_{config.powertrain}_mean_param_change_{g}.png", dpi=150)
                plt.close()
    print(f"Saved analysis outputs to {output_dir}")


def run_cli(config):
    parser = argparse.ArgumentParser(description=f"{config.powertrain.upper()} sensitivity analysis: split -> sweep -> analyze.")
    sub = parser.add_subparsers(dest="cmd")

    p_split = sub.add_parser("split", help=f"Create sensitivity_{config.powertrain}_G*.csv from original inputs/results.")
    p_split.add_argument("--work_dir", default=".")
    p_split.add_argument("--input_csv", default=None)
    p_split.add_argument("--results_file", default=None)
    p_split.add_argument("--actuals_file", default=None)
    p_split.add_argument("--out_dir", default=None)
    p_split.add_argument("--tolerance", type=float, default=0.10)

    p_sweep = sub.add_parser("sweep", help=f"Create sweep_{config.powertrain}_G*.csv from failed rows.")
    p_sweep.add_argument("--work_dir", default=".")
    p_sweep.add_argument("--out_dir", default=None)

    p_an = sub.add_parser("analyze", help="Analyze sweep simulation results.")
    p_an.add_argument("--work_dir", default=".")
    p_an.add_argument("--sweep_results_dir", default=None)
    p_an.add_argument("--output_dir", default=config.default_output_dir)
    p_an.add_argument("--tolerance", type=float, default=0.10)

    args = parser.parse_args()
    if args.cmd == "split":
        split_inputs(args, config)
    elif args.cmd == "sweep":
        generate_sweep_inputs(args, config)
    elif args.cmd == "analyze":
        analyze(args, config)
    else:
        parser.print_help()
        print("\nTypical order:")
        print(f"  python {Path(__file__).name} split --work_dir .")
        print(f"  python {Path(__file__).name} sweep --work_dir .")
        print(f"  # run Simulink/SL simulations for sweep_{config.powertrain}_G*.csv")
        print(f"  python {Path(__file__).name} analyze --work_dir . --sweep_results_dir .")
