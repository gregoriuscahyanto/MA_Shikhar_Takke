import pandas as pd
import numpy as np
import os
import re
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SWEEP_INPUT_DIR  = '.'   # folder with sweep_G*.csv files
SWEEP_OUTPUT_DIR = '.'   # folder with Simulink output Excel files

# Add only the groups whose Simulink runs are COMPLETE
# Comment out groups still running
RESULTS_FILES = {
    'G1_lt5s':    'sweep_results_G1.xlsx',
    # 'G2_5to7s':   'sweep_results_G2.xlsx',   # ← uncomment when ready
    # 'G3_7to10s':  'sweep_results_G3.xlsx',
    # 'G4_10to13s': 'sweep_results_G4.xlsx',
    # 'G5_gt13s':   'sweep_results_G5.xlsx',
}

# Column name for simulated 0-100 time in Simulink output
SIM_COL = 'SL_time_0_to_100'

OUTPUT_DIR = 'step3_results'
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

def clean_col(c):
    return re.sub(r'[\t\n\r\xa0]+', ' ', str(c)).strip()

def load_file(path):
    """Load CSV or Excel automatically based on file extension."""
    ext = os.path.splitext(path)[1].lower()
    if ext in ['.xlsx', '.xls']:
        return pd.read_excel(path)
    return pd.read_csv(path)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3A — Load, clean, merge per group
# ─────────────────────────────────────────────────────────────────────────────

all_merged = []

for g, res_filename in RESULTS_FILES.items():

    print(f"\nProcessing {g}...")

    # ── Load sweep inputs ─────────────────────────────────────────────────────
    inp_path = os.path.join(SWEEP_INPUT_DIR, f'sweep_{g}.csv')
    df_inp = pd.read_csv(inp_path)
    df_inp.columns = [clean_col(c) for c in df_inp.columns]

    # ── Load Simulink results (Excel or CSV) ──────────────────────────────────
    res_path = os.path.join(SWEEP_OUTPUT_DIR, res_filename)
    df_res = load_file(res_path)
    df_res.columns = [clean_col(c) for c in df_res.columns]

    # ── Drop rows with empty SWEEP_RUN_ID or empty SIM_COL ───────────────────
    before = len(df_res)
    df_res = df_res.dropna(subset=['SWEEP_RUN_ID', SIM_COL])
    df_res['SWEEP_RUN_ID'] = df_res['SWEEP_RUN_ID'].astype(int)
    after  = len(df_res)
    if before != after:
        print(f"  Dropped {before - after} rows with empty SWEEP_RUN_ID or {SIM_COL}")

    # ── Merge inputs + results on SWEEP_RUN_ID ────────────────────────────────
    df = pd.merge(df_inp, df_res[['SWEEP_RUN_ID', SIM_COL]], on='SWEEP_RUN_ID', how='inner')
    print(f"  Matched {len(df)} / {len(df_inp)} sweep runs")

    # ── Compute new error ─────────────────────────────────────────────────────
    df['new_error']     = df[SIM_COL] - df['actual_0_100']
    df['new_pct_error'] = (df['new_error'] / df['actual_0_100']) * 100
    df['new_pass']      = df['new_pct_error'].abs() <= 10
    df['group']         = g

    all_merged.append(df)
    print(f"  Pass rate : {df['new_pass'].mean()*100:.1f}%")
    print(f"  Mean error: {df['new_error'].mean():+.3f}s")

if not all_merged:
    print("No completed groups found. Exiting.")
    exit()

df_all = pd.concat(all_merged, ignore_index=True)
completed_groups = df_all['group'].unique().tolist()

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3B — Best combination per group
# ─────────────────────────────────────────────────────────────────────────────

print("\n" + "="*60)
print("BEST CALIBRATION COMBINATION PER GROUP")
print("="*60)

best_summary = []

for g in completed_groups:
    gdf = df_all[df_all['group'] == g]

    agg = (gdf
           .groupby(['tq_scale', 'shift_delta', 'mass_scale'])
           .agg(
               mean_abs_pct_err=('new_pct_error', lambda x: x.abs().mean()),
               mean_pct_err    =('new_pct_error', 'mean'),
               pass_rate       =('new_pass',      'mean'),
               n_runs          =('new_pass',       'count')
           )
           .reset_index()
           .sort_values('mean_abs_pct_err'))

    best = agg.iloc[0]
    best_summary.append({
        'Group':          g,
        'tq_scale':       best['tq_scale'],
        'shift_delta':    best['shift_delta'],
        'mass_scale':     best['mass_scale'],
        'mean_pct_error': round(best['mean_pct_err'], 2),
        'mean_abs_error': round(best['mean_abs_pct_err'], 2),
        'pass_rate_%':    round(best['pass_rate'] * 100, 1),
        'n_runs':         int(best['n_runs'])
    })

    print(f"\n{g}:")
    print(f"  Best tq_scale    : {best['tq_scale']:.2f}x")
    print(f"  Best shift_delta : {best['shift_delta']:+.2f}s")
    print(f"  Best mass_scale  : {best['mass_scale']:.2f}x")
    print(f"  Mean % error     : {best['mean_pct_err']:+.2f}%")
    print(f"  Pass rate        : {best['pass_rate']*100:.1f}%")

    agg.to_csv(os.path.join(OUTPUT_DIR, f'agg_{g}.csv'), index=False)

best_df = pd.DataFrame(best_summary)
best_df.to_csv(os.path.join(OUTPUT_DIR, 'best_calibration_summary.csv'), index=False)
print(f"\nSaved: {OUTPUT_DIR}/best_calibration_summary.csv")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3C — Plots (only for completed groups)
# ─────────────────────────────────────────────────────────────────────────────

n = len(completed_groups)
ncols = min(n, 3)
nrows = int(np.ceil(n / ncols))

for plot_var, color, xlabel, filename in [
    ('tq_scale',    'steelblue',  'tq_scale',        'error_vs_tq_scale.png'),
    ('shift_delta', 'darkorange', 'shift_delta (s)',  'error_vs_shift_delta.png'),
]:
    fig, axes = plt.subplots(nrows, ncols, figsize=(5*ncols, 4*nrows))
    axes = np.array(axes).flatten()

    for i, g in enumerate(completed_groups):
        ax  = axes[i]
        gdf = df_all[df_all['group'] == g]

        agg = (gdf
               .groupby(plot_var)['new_pct_error']
               .mean()
               .reset_index())

        ax.plot(agg[plot_var], agg['new_pct_error'],
                marker='o', linewidth=2, color=color)
        ax.axhline(0,   color='black', linestyle='--', linewidth=0.8)
        ax.axhline(10,  color='red',   linestyle=':',  linewidth=1)
        ax.axhline(-10, color='red',   linestyle=':',  linewidth=1)
        ax.set_title(g, fontsize=11, fontweight='bold')
        ax.set_xlabel(xlabel)
        ax.set_ylabel('Mean % Error')
        ax.grid(True, alpha=0.3)
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter('%.1f%%'))

    # Hide unused subplots
    for j in range(i+1, len(axes)):
        axes[j].set_visible(False)

    fig.suptitle(f'Mean % Error vs {xlabel}', fontsize=13, fontweight='bold')
    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, filename), dpi=150)
    plt.close()
    print(f"Saved plot: {OUTPUT_DIR}/{filename}")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3D — Save full merged results
# ─────────────────────────────────────────────────────────────────────────────

df_all.to_csv(os.path.join(OUTPUT_DIR, 'all_sweep_results_merged.csv'), index=False)
print(f"Saved: {OUTPUT_DIR}/all_sweep_results_merged.csv")