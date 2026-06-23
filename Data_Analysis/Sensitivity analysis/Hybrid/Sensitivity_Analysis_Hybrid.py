import argparse
import itertools
import os
import re
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

POWERTRAIN = "hybrid"
GROUP_BINS = [0, 5, 7, 10, 13, 1000]
GROUP_LABELS = ["G1_lt5s", "G2_5to7s", "G3_7to10s", "G4_10to13s", "G5_gt13s"]
SIM_COL_CANDIDATES = ["SL_time_0_to_100", "SL_time_0_to_100_6.4", "SL_time_0_to_100_6", "time_0_to_100"]
ACTUAL_COL_CANDIDATES = ["Actual_0_to_100", "actual_0_100", "Actual 0 to 100", "Actual 0 to 100 time", "Actual 0-100 time"]

INPUT_CANDIDATES = [
    "DoE_Inp_Hybrid.csv",
    "Simulation_Model/DoE_Inp_Hybrid.csv",
    "Simulation_Vehicle_Data/DoE_Inp_Hybrid.csv",
    "Surrogate_Model/Hybrid Powertrain/DoE_Inp_Hybrid.csv",
]
RESULT_CANDIDATES = [
    "Final_Simulation_Results_ALL_RUN_IDs.xlsx",
    "Final_Simulation_Results_ALL_RUN_IDs_Hybrid.xlsx",
    "NewActual_Simulation_Comparison.xlsx",
]

SWEEP_CONFIG = {
    # fast real cars: failed simulations are usually too slow -> add system power, reduce shift delay
    "G1_lt5s": {"hyb_power_scale": [1.00, 1.05, 1.10, 1.15, 1.20], "shift_delta": [0.0, -0.1, -0.2, -0.3], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
    "G2_5to7s": {"hyb_power_scale": [1.00, 1.05, 1.10, 1.15], "shift_delta": [0.0, -0.1, -0.2, -0.3], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
    # near target: keep changes small
    "G3_7to10s": {"hyb_power_scale": [0.95, 1.00, 1.05], "shift_delta": [0.0, 0.1, 0.2], "mass_scale": [1.00], "bat_dis_scale": [1.00]},
    # slow real cars: failed simulations are often too fast -> reduce system power, increase shift delay/mass
    "G4_10to13s": {"hyb_power_scale": [0.80, 0.85, 0.90, 0.95, 1.00], "shift_delta": [0.0, 0.1, 0.2, 0.3], "mass_scale": [1.00, 1.02, 1.04, 1.06], "bat_dis_scale": [0.95, 1.00]},
    "G5_gt13s": {"hyb_power_scale": [0.60, 0.65, 0.70, 0.75, 0.80], "shift_delta": [0.0, 0.1, 0.2, 0.3], "mass_scale": [1.00, 1.03, 1.06, 1.09], "bat_dis_scale": [0.90, 1.00]},
}

ICE_SCALE_COLS = ["tq_ICE_max", "tq_ICE_idle", "Pwr_ICE_max_kW"]
EM_SCALE_COLS = [
    "tq_P0_max", "Pwr_P0_max_kW",
    "tq_P2_max", "Pwr_P2_max_kW",
    "tq_P3_max", "Pwr_P3_max_kW",
    "tq_P4_max", "Pwr_P4_max_kW",
]
BATTERY_SCALE_COLS = ["Cell_I_max_dis"]
CHANGED_PARAMS = ICE_SCALE_COLS + EM_SCALE_COLS + ["shiftDelay", "m_curb", "Cell_I_max_dis"]
SWEEP_PARAMS = ["hyb_power_scale", "shift_delta", "mass_scale", "bat_dis_scale"]
OUTPUT_COLS = ["error", "pct_error", "pass_fail", "group", "Actual_0_to_100", "SL_time_0_to_100"]


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


def find_existing(candidates, base_dir="."):
    base_dir = Path(base_dir)
    for cand in candidates:
        p = base_dir / cand
        if p.exists():
            return p
    for cand in candidates:
        matches = list(base_dir.rglob(Path(cand).name))
        if matches:
            return matches[0]
    return None


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


def scale_existing(new_row, row, cols, scale, skip_zero=True):
    for col in cols:
        if col not in row.index:
            continue
        val = safe_num(row[col])
        if np.isnan(val):
            continue
        if skip_zero and abs(val) < 1e-12:
            continue
        new_row[col] = val * scale


def result_file_for_group(work_dir, group):
    short = group.split("_")[0]
    candidates = [
        f"sweep_results_{POWERTRAIN}_{group}.xlsx",
        f"sweep_results_{POWERTRAIN}_{short}.xlsx",
        f"sweep_results_{group}.xlsx",
        f"sweep_results_{short}.xlsx",
        f"sweep_results_{POWERTRAIN}_{group}.csv",
        f"sweep_results_{POWERTRAIN}_{short}.csv",
        f"sweep_results_{group}.csv",
        f"sweep_results_{short}.csv",
    ]
    return find_existing(candidates, work_dir)


def split_inputs(args):
    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir or work_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    input_file = Path(args.input_csv) if args.input_csv else find_existing(INPUT_CANDIDATES, work_dir)
    result_file = Path(args.results_file) if args.results_file else find_existing(RESULT_CANDIDATES, work_dir)
    if input_file is None:
        raise FileNotFoundError("Hybrid input CSV not found. Pass --input_csv.")
    if result_file is None:
        raise FileNotFoundError("Result/comparison file not found. Pass --results_file.")

    df_inp = read_table(input_file)
    df_out = read_table(result_file)
    if "RUN_ID" not in df_inp.columns or "RUN_ID" not in df_out.columns:
        raise KeyError("Both input and result files must contain RUN_ID.")

    actual_col = find_col(df_out, ACTUAL_COL_CANDIDATES)
    sim_col = find_col(df_out, SIM_COL_CANDIDATES)
    df = pd.merge(df_inp, df_out[["RUN_ID", actual_col, sim_col]], on="RUN_ID", how="inner")
    df.rename(columns={actual_col: "Actual_0_to_100", sim_col: "SL_time_0_to_100"}, inplace=True)

    if "Hy" in df.columns:
        df = df[pd.to_numeric(df["Hy"], errors="coerce").fillna(0).astype(int) == 1].copy()
    if "EV" in df.columns:
        df = df[pd.to_numeric(df["EV"], errors="coerce").fillna(0).astype(int) == 0].copy()

    df = df.dropna(subset=["Actual_0_to_100", "SL_time_0_to_100"]).copy()
    df["error"] = df["SL_time_0_to_100"] - df["Actual_0_to_100"]
    df["pct_error"] = df["error"] / df["Actual_0_to_100"] * 100
    df["pass_fail"] = np.where(df["pct_error"].abs() > args.tolerance * 100, "FAIL", "PASS")
    df["group"] = pd.cut(df["Actual_0_to_100"], bins=GROUP_BINS, labels=GROUP_LABELS)

    input_cols = [c for c in df_inp.columns if c in df.columns]
    cols_to_save = input_cols + ["Actual_0_to_100", "SL_time_0_to_100", "error", "pct_error", "pass_fail", "group"]

    for g in GROUP_LABELS:
        gdf = df[df["group"] == g][cols_to_save]
        out = out_dir / f"sensitivity_{POWERTRAIN}_{g}.csv"
        gdf.to_csv(out, index=False)
        pass_rate = (gdf["pass_fail"] == "PASS").mean() * 100 if len(gdf) else 0.0
        print(f"{g}: {len(gdf)} runs | Pass: {pass_rate:.1f}% | saved {out}")


def generate_sweep_inputs(args):
    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir or work_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    for g in GROUP_LABELS:
        in_file = work_dir / f"sensitivity_{POWERTRAIN}_{g}.csv"
        if not in_file.exists():
            print(f"Skipping {g}: missing {in_file}")
            continue
        gdf = read_table(in_file)
        fails = gdf[gdf["pass_fail"].astype(str).str.upper() == "FAIL"].copy()
        all_input_cols = [c for c in gdf.columns if c not in OUTPUT_COLS]
        rows = []
        new_run_id = 1
        cfg = SWEEP_CONFIG[g]

        keys = ["hyb_power_scale", "shift_delta", "mass_scale", "bat_dis_scale"]
        for _, row in fails.iterrows():
            for hyb_scale, sd, ms, bs in itertools.product(*(cfg[k] for k in keys)):
                new_row = row[all_input_cols].copy()
                scale_existing(new_row, row, ICE_SCALE_COLS, hyb_scale)
                scale_existing(new_row, row, EM_SCALE_COLS, hyb_scale)
                scale_existing(new_row, row, BATTERY_SCALE_COLS, bs)
                if "shiftDelay" in row.index:
                    new_row["shiftDelay"] = float(np.clip(safe_num(row["shiftDelay"]) + sd, 0.05, 1.5))
                if "m_curb" in row.index:
                    new_row["m_curb"] = safe_num(row["m_curb"]) * ms

                new_row["ORIG_RUN_ID"] = row["RUN_ID"]
                new_row["SWEEP_RUN_ID"] = new_run_id
                new_row["hyb_power_scale"] = hyb_scale
                new_row["shift_delta"] = sd
                new_row["mass_scale"] = ms
                new_row["bat_dis_scale"] = bs
                new_row["actual_0_100"] = row["Actual_0_to_100"]
                rows.append(new_row)
                new_run_id += 1

        sweep_df = pd.DataFrame(rows)
        if len(sweep_df):
            tracking = ["SWEEP_RUN_ID", "ORIG_RUN_ID"] + SWEEP_PARAMS + ["actual_0_100"]
            sweep_df = sweep_df[tracking + [c for c in sweep_df.columns if c not in tracking]]
        out = out_dir / f"sweep_{POWERTRAIN}_{g}.csv"
        sweep_df.to_csv(out, index=False)
        print(f"{g}: {len(fails)} failed runs -> {len(sweep_df)} sweep combinations | saved {out}")


def load_sweep_results(args):
    work_dir = Path(args.work_dir)
    sweep_results_dir = Path(args.sweep_results_dir or work_dir)
    all_merged = []
    all_original = []
    all_failed = []

    for g in GROUP_LABELS:
        sweep_in = work_dir / f"sweep_{POWERTRAIN}_{g}.csv"
        orig_in = work_dir / f"sensitivity_{POWERTRAIN}_{g}.csv"
        res_file = result_file_for_group(sweep_results_dir, g)
        if not sweep_in.exists() or not orig_in.exists():
            print(f"Skipping {g}: missing sensitivity/sweep input CSV.")
            continue
        orig = read_table(orig_in)
        orig["group"] = g
        all_original.append(orig)
        all_failed.append(orig[orig["pass_fail"].astype(str).str.upper() == "FAIL"].copy())

        if res_file is None:
            print(f"Skipping {g}: no sweep result file found. Expected e.g. sweep_results_{POWERTRAIN}_{g}.xlsx")
            continue
        inp = read_table(sweep_in)
        res = read_table(res_file)
        sim_col = find_col(res, SIM_COL_CANDIDATES)
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


def analyze(args):
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    df_all, df_orig_all, df_fail_all = load_sweep_results(args)

    best_params = {}
    summary_rows = []
    for g in sorted(df_all["group"].unique().tolist(), key=GROUP_LABELS.index):
        gdf = df_all[df_all["group"] == g]
        agg = (gdf.groupby(SWEEP_PARAMS)
               .agg(mean_abs_err=("new_pct_error", lambda x: x.abs().mean()),
                    mean_pct_err=("new_pct_error", "mean"),
                    pass_rate=("new_pass", "mean"),
                    n_runs=("new_pass", "count"))
               .reset_index()
               .sort_values(["pass_rate", "mean_abs_err"], ascending=[False, True]))
        best = agg.iloc[0]
        best_params[g] = best
        summary_rows.append({"group": g, **best.to_dict()})
        print(f"{g} best: power x{best['hyb_power_scale']:.2f}, shift {best['shift_delta']:+.2f}s, mass x{best['mass_scale']:.2f}, battery x{best['bat_dis_scale']:.2f} | pass {best['pass_rate']*100:.1f}%")

    def best_sweep(g):
        bp = best_params[g]
        mask = df_all["group"].eq(g)
        for p in SWEEP_PARAMS:
            mask &= df_all[p].eq(bp[p])
        return df_all[mask].copy()

    # Plot A: original pass vs recovered by best sweep
    groups = [g for g in GROUP_LABELS if g in best_params]
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
    ax.set_title("Hybrid sensitivity: original pass rate + recovered runs")
    ax.set_ylim(0, 115)
    ax.grid(True, alpha=0.3, axis="y")
    ax.legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(output_dir / "plotA_hybrid_pass_rate_recovery.png", dpi=150)
    plt.close()

    # Plot B: original vs swept scatter per group
    for g in groups:
        orig = df_orig_all[df_orig_all["group"] == g].dropna(subset=["Actual_0_to_100", "SL_time_0_to_100"])
        best = best_sweep(g)
        if len(orig) == 0 or len(best) == 0:
            continue
        lim_max = max(orig["Actual_0_to_100"].max(), best["actual_0_100"].max(), orig["SL_time_0_to_100"].max(), best["SL_time_0_to_100_swept"].max()) + 1
        fig, axes = plt.subplots(1, 2, figsize=(12, 5))
        for ax, data, ycol, title, flag in [
            (axes[0], orig, "SL_time_0_to_100", "Original", orig["pass_fail"].astype(str).str.upper() == "PASS"),
            (axes[1], best, "SL_time_0_to_100_swept", "Best sweep", best["new_pass"]),
        ]:
            ax.scatter(data.loc[flag, data.columns.intersection(["Actual_0_to_100", "actual_0_100"])[0] if "Actual_0_to_100" in data.columns else "actual_0_100"], data.loc[flag, ycol], s=18, alpha=0.5, label="Pass")
            ax.scatter(data.loc[~flag, data.columns.intersection(["Actual_0_to_100", "actual_0_100"])[0] if "Actual_0_to_100" in data.columns else "actual_0_100"], data.loc[~flag, ycol], s=18, alpha=0.5, label="Fail")
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
        fig.suptitle(f"Hybrid {g}: actual vs simulated")
        plt.tight_layout()
        plt.savefig(output_dir / f"plotB_hybrid_scatter_{g}.png", dpi=150)
        plt.close()

    # Plot C + Excel export: recovered rows and mean parameter change
    export_path = output_dir / "hybrid_recovered_runs.xlsx"
    with pd.ExcelWriter(export_path, engine="openpyxl") as writer:
        pd.DataFrame(summary_rows).to_excel(writer, sheet_name="best_sweep_summary", index=False)
        for g in groups:
            best = best_sweep(g)
            passed = best[best["new_pass"]].copy()
            if len(passed) == 0:
                continue
            orig_fail = df_fail_all[df_fail_all["group"] == g].copy().set_index("RUN_ID")
            changes = {}
            for p in CHANGED_PARAMS:
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
            out_cols = ["ORIG_RUN_ID", "SWEEP_RUN_ID"] + SWEEP_PARAMS + [c for c in CHANGED_PARAMS if c in passed.columns] + ["actual_0_100", "SL_time_0_to_100_swept", "new_pct_error"]
            passed[[c for c in out_cols if c in passed.columns]].to_excel(writer, sheet_name=g[:31], index=False)
            if changes:
                fig, ax = plt.subplots(figsize=(8, 4))
                ax.barh(list(changes.keys()), list(changes.values()))
                ax.axvline(0, color="black", linestyle="--", linewidth=1)
                ax.set_xlabel("Mean % change from original")
                ax.set_title(f"Hybrid {g}: mean parameter change in recovered runs")
                ax.grid(True, alpha=0.3, axis="x")
                plt.tight_layout()
                plt.savefig(output_dir / f"plotC_hybrid_mean_param_change_{g}.png", dpi=150)
                plt.close()
    print(f"Saved analysis outputs to {output_dir}")


def main():
    parser = argparse.ArgumentParser(description="Hybrid sensitivity analysis: split -> sweep -> analyze.")
    sub = parser.add_subparsers(dest="cmd")

    p_split = sub.add_parser("split", help="Create sensitivity_hybrid_G*.csv from original inputs/results.")
    p_split.add_argument("--work_dir", default=".")
    p_split.add_argument("--input_csv", default=None)
    p_split.add_argument("--results_file", default=None)
    p_split.add_argument("--out_dir", default=None)
    p_split.add_argument("--tolerance", type=float, default=0.10)

    p_sweep = sub.add_parser("sweep", help="Create sweep_hybrid_G*.csv from failed rows.")
    p_sweep.add_argument("--work_dir", default=".")
    p_sweep.add_argument("--out_dir", default=None)

    p_an = sub.add_parser("analyze", help="Analyze sweep simulation results.")
    p_an.add_argument("--work_dir", default=".")
    p_an.add_argument("--sweep_results_dir", default=None)
    p_an.add_argument("--output_dir", default="hybrid_sensitivity_results")
    p_an.add_argument("--tolerance", type=float, default=0.10)

    args = parser.parse_args()
    if args.cmd == "split":
        split_inputs(args)
    elif args.cmd == "sweep":
        generate_sweep_inputs(args)
    elif args.cmd == "analyze":
        analyze(args)
    else:
        parser.print_help()
        print("\nTypical order:")
        print("  python Sensitivity_Analysis_Hybrid.py split --work_dir .")
        print("  python Sensitivity_Analysis_Hybrid.py sweep --work_dir .")
        print("  # run Simulink/SL simulations for sweep_hybrid_G*.csv and save sweep_results_hybrid_G*.xlsx")
        print("  python Sensitivity_Analysis_Hybrid.py analyze --work_dir . --sweep_results_dir .")


if __name__ == "__main__":
    main()
