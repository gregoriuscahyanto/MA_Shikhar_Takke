import pandas as pd
import numpy as np
import os
import re
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SWEEP_INPUT_DIR     = '.'
SWEEP_OUTPUT_DIR    = '.'
ORIGINAL_GROUPS_DIR = '.'

# Full original files — used for correct pass rate denominator
FULL_OUTPUT_FILE = 'Final_Simulation_Results_ALL_RUN_IDs_Original.xlsx'
FULL_INPUT_FILE  = 'DoE_Inp_ICE.csv'

RESULTS_FILES = {
    'G1_lt5s': 'sweep_results_G1.xlsx',
    'G2_5to7s':    'sweep_results_G2.xlsx',
    'G3_7to10s':   'sweep_results_G3.xlsx',
    'G4_10to13s':  'sweep_results_G4.xlsx',
    'G5_gt13s':    'sweep_results_G5.xlsx',
}

SIM_COL    = 'SL_time_0_to_100'
OUTPUT_DIR = 'step3_results_v4'
os.makedirs(OUTPUT_DIR, exist_ok=True)

GROUP_BINS   = [0, 5, 7, 10, 13, 1000]
GROUP_LABELS = ['G1_lt5s', 'G2_5to7s', 'G3_7to10s', 'G4_10to13s', 'G5_gt13s']

SWEEP_PARAMS = ['tq_scale', 'shift_delta', 'mass_scale']
INPUT_PARAMS = ['dRAD', 'A_front', 'HM_VA', 'AWD', 'iAG', 'm_curb',
                'Achsabstand', 'Gear_Ratio', 'No_Gears', 'shiftDelay',
                'n_ICE_idle', 'n_ICE_max', 'tq_ICE_idle', 'tq_ICE_max',
                'Pwr_ICE_max_kW']

CHANGED_PARAMS = {
    'tq_ICE_max':     'tq_ICE_max',
    'tq_ICE_idle':    'tq_ICE_idle',
    'Pwr_ICE_max_kW': 'Pwr_ICE_max_kW',
    'shiftDelay':     'shiftDelay',
    'm_curb':         'm_curb',
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def clean_col(c):
    return re.sub(r'[\t\n\r\xa0]+', ' ', str(c)).strip()

def load_file(path):
    ext = os.path.splitext(path)[1].lower()
    return pd.read_excel(path) if ext in ['.xlsx', '.xls'] else pd.read_csv(path)

def find_col(df, candidates):
    df_cols_lower = {c.lower().strip(): c for c in df.columns}
    for cand in candidates:
        if cand.lower().strip() in df_cols_lower:
            return df_cols_lower[cand.lower().strip()]
    raise KeyError(f"None of {candidates} found in: {list(df.columns)}")

# ─────────────────────────────────────────────────────────────────────────────
# LOAD GROUND TRUTH FROM NewActual_Simulation_Comparison.xlsx
# ─────────────────────────────────────────────────────────────────────────────

COMPARISON_FILE = 'NewActual_Simulation_Comparison.xlsx'
TOLERANCE_GT    = 0.10

df_gt = pd.read_excel(COMPARISON_FILE)
df_gt.columns = [clean_col(c) for c in df_gt.columns]

print("Comparison file columns:")
print(list(df_gt.columns))

# Detect actual time column
actual_col_gt = find_col(df_gt, [
    'Actual 0 to 100', 'Actual 0 to 100 time', 'actual 0 to 100',
    'Actual_0_to_100', 'actual_0_100'
])

# Detect sim time column — try versioned first, then generic
sim_col_gt = None
for candidate in ['SL_time_0_to_100_6.4', 'SL_time_0_to_100_6',
                  'SL_time_0_to_100', 'sl_time_0_to_100']:
    try:
        sim_col_gt = find_col(df_gt, [candidate])
        break
    except KeyError:
        continue
if sim_col_gt is None:
    raise KeyError("Cannot find SL_time_0_to_100 column in comparison file")

# Detect pre-computed pass column — must be exactly '6.4'
# (stored as string after clean_col, was float in Excel)
SIM_VER_GT = '6.4'

pass_col_gt = None
# First: look for exact version string match e.g. '6.4'
for col in df_gt.columns:
    if str(col).strip() == SIM_VER_GT:
        pass_col_gt = col
        break

# Second fallback: look for column named exactly like a version number (digit.digit)
if pass_col_gt is None:
    import re as _re
    for col in df_gt.columns:
        if _re.fullmatch(r'\d+\.\d+', str(col).strip()):
            pass_col_gt = col
            break

print(f"Detected actual col : '{actual_col_gt}'")
print(f"Detected sim col    : '{sim_col_gt}'")
print(f"Detected pass col   : '{pass_col_gt}'")

# OLD # Keep only rows with a valid actual time
# df_gt = df_gt.dropna(subset=[actual_col_gt]).copy().reset_index(drop=True)

# CORRECT — match validation script: drop rows missing EITHER actual OR sim
df_gt = df_gt.dropna(subset=[actual_col_gt, sim_col_gt]).copy().reset_index(drop=True)

# Compute pass_flag from '6.4' column (values are 0 or 1)
if pass_col_gt is not None:
    try:
        df_gt['pass_flag'] = pd.to_numeric(
            df_gt[pass_col_gt], errors='coerce'
        ).fillna(0).astype(int)
        print(f"Using pre-computed pass column: '{pass_col_gt}'")
        # Sanity check
        unique_vals = df_gt['pass_flag'].unique()
        print(f"  Unique values in pass column: {sorted(unique_vals)}")
        if not set(unique_vals).issubset({0, 1}):
            print("  WARNING: pass column has values other than 0/1 — recomputing")
            pass_col_gt = None
    except Exception as e:
        print(f"  Failed: {e} — recomputing")
        pass_col_gt = None

if pass_col_gt is None:
    # Recompute from scratch
    df_gt['pass_flag'] = np.where(
        df_gt[sim_col_gt].notna() &
        ((df_gt[sim_col_gt] - df_gt[actual_col_gt]).abs()
         / df_gt[actual_col_gt] <= TOLERANCE_GT),
        1, 0
    )
    print("Recomputed pass_flag from ±10% tolerance check")

# Assign performance groups
df_gt['group'] = pd.cut(
    df_gt[actual_col_gt], bins=GROUP_BINS, labels=GROUP_LABELS
)

print("\nGround truth — group sizes and original pass rates:")
for g in GROUP_LABELS:
    gdf    = df_gt[df_gt['group'] == g]
    n_tot  = len(gdf)
    n_pass = int(gdf['pass_flag'].sum())
    if n_tot > 0:
        print(f"  {g}: {n_tot} total | {n_pass} pass | {n_pass/n_tot*100:.1f}%")
# ─────────────────────────────────────────────────────────────────────────────
# LOAD SENSITIVITY CSVs + SWEEP RESULTS
# ─────────────────────────────────────────────────────────────────────────────

all_merged   = []
all_original = []
all_orig_fail= []

for g, res_filename in RESULTS_FILES.items():

    df_inp = pd.read_csv(os.path.join(SWEEP_INPUT_DIR, f'sweep_{g}.csv'))
    df_inp.columns = [clean_col(c) for c in df_inp.columns]

    df_res = load_file(os.path.join(SWEEP_OUTPUT_DIR, res_filename))
    df_res.columns = [clean_col(c) for c in df_res.columns]
    df_res = df_res.dropna(subset=['SWEEP_RUN_ID', SIM_COL])
    df_res['SWEEP_RUN_ID'] = df_res['SWEEP_RUN_ID'].astype(int)

    df = pd.merge(df_inp, df_res[['SWEEP_RUN_ID', SIM_COL]], on='SWEEP_RUN_ID', how='inner')
    df['new_pct_error'] = (df[SIM_COL] - df['actual_0_100']) / df['actual_0_100'] * 100
    df['new_pass']      = df['new_pct_error'].abs() <= 10
    df['group']         = g
    all_merged.append(df)

    df_orig = pd.read_csv(os.path.join(ORIGINAL_GROUPS_DIR, f'sensitivity_{g}.csv'))
    df_orig.columns = [clean_col(c) for c in df_orig.columns]
    df_orig['group'] = g
    all_original.append(df_orig)
    all_orig_fail.append(df_orig[df_orig['pass_fail'] == 'FAIL'].copy())

df_all       = pd.concat(all_merged,    ignore_index=True)
df_orig_all  = pd.concat(all_original,  ignore_index=True)
df_fail_all  = pd.concat(all_orig_fail, ignore_index=True)
completed_groups = df_all['group'].unique().tolist()

ACTUAL_COL_ORIG = find_col(df_orig_all, [
    'Actual 0 to 100 time', 'actual_0_to_100', 'actual 0 to 100',
    'Actual_0_to_100', 'actual_0_100'
])
SIM_COL_ORIG = find_col(df_orig_all, [
    'SL_time_0_to_100', 'sl_time_0_to_100'
])
print(f"\nSensitivity CSV actual col : '{ACTUAL_COL_ORIG}'")
print(f"Sensitivity CSV sim col    : '{SIM_COL_ORIG}'")

# ─────────────────────────────────────────────────────────────────────────────
# BEST SWEEP COMBINATION PER GROUP
# ─────────────────────────────────────────────────────────────────────────────

best_params = {}
for g in completed_groups:
    gdf = df_all[df_all['group'] == g]
    agg = (gdf
           .groupby(SWEEP_PARAMS)
           .agg(mean_abs_err=('new_pct_error', lambda x: x.abs().mean()),
                mean_pct_err=('new_pct_error', 'mean'),
                pass_rate   =('new_pass',      'mean'),
                n_runs      =('new_pass',       'count'))
           .reset_index()
           .sort_values(['pass_rate', 'mean_abs_err'], ascending=[False, True]))
    best_params[g] = agg.iloc[0]
    print(f"\n{g} best combo: tq×{agg.iloc[0]['tq_scale']:.2f}, "
          f"Δshift={agg.iloc[0]['shift_delta']:+.2f}s | "
          f"Pass rate (of failed runs): {agg.iloc[0]['pass_rate']*100:.1f}%")

def get_best_sweep(g):
    bp   = best_params[g]
    mask = ((df_all['group']       == g) &
            (df_all['tq_scale']    == bp['tq_scale']) &
            (df_all['shift_delta'] == bp['shift_delta']) &
            (df_all['mass_scale']  == bp['mass_scale']))
    return df_all[mask].copy()

# ─────────────────────────────────────────────────────────────────────────────
# PLOT A — Pass Rate: stacked bar  (FIXED denominator from full dataset)
# ─────────────────────────────────────────────────────────────────────────────

fig, ax = plt.subplots(figsize=(9, 5))
x = np.arange(len(completed_groups))
w = 0.4

for i, g in enumerate(completed_groups):

    # ── Ground-truth from comparison file ────────────────────────────────────────
    df_gt_g = df_gt[df_gt['group'] == g]
    n_total = len(df_gt_g)
    n_orig_pass = int(df_gt_g['pass_flag'].sum())
    n_orig_fail = n_total - n_orig_pass
    orig_rate = n_orig_pass / n_total * 100

    # ── Recovery from sweep ───────────────────────────────────────────────────
    best_g        = get_best_sweep(g)
    n_fail_sweep  = len(df_fail_all[df_fail_all['group'] == g])
    n_recovered   = best_g[best_g['new_pass']]['ORIG_RUN_ID'].nunique()
    recovered_pct = n_recovered / n_total * 100

    # Bar 1: original pass rate
    ax.bar(i - w/2, orig_rate, w,
           color='tomato', alpha=0.85,
           label='Original pass rate' if i == 0 else '')
    ax.text(i - w/2, orig_rate + 1.5,
            f'{orig_rate:.1f}%\n({int(n_orig_pass)}/{int(n_total)})',
            ha='center', va='bottom', fontsize=7,
            fontweight='bold', color='darkred')

    # Bar 2: stacked — grey base + green recovered
    ax.bar(i + w/2, orig_rate, w,
           color='silver', alpha=0.85,
           label='Original pass (base)' if i == 0 else '')
    ax.bar(i + w/2, recovered_pct, w, bottom=orig_rate,
           color='mediumseagreen', alpha=0.85,
           label='Recovered by sweep' if i == 0 else '')

    # Label inside grey portion
    ax.text(i + w/2, orig_rate / 2,
            f'{orig_rate:.1f}%\n({int(n_orig_pass)}/{int(n_total)})',
            ha='center', va='center', fontsize=7,
            color='dimgray', fontweight='bold')

    # Label inside green portion
    if recovered_pct > 0.5:
        ax.text(i + w/2, orig_rate + recovered_pct / 2,
                f'+{recovered_pct:.1f}%\n({int(n_recovered)}/{int(n_orig_fail)})',
                ha='center', va='center', fontsize=7,
                color='black', fontweight='bold')

    # Total label on top
    total_pct = orig_rate + recovered_pct
    ax.text(i + w/2, total_pct + 1.5,
            f'Total: {total_pct:.1f}%',
            ha='center', va='bottom', fontsize=8,
            color='darkgreen', fontweight='bold')

ax.axhline(72.5,  color='green', linestyle='--', linewidth=1.5, label='72.5% original pass rate')
ax.axhline(100, color='black', linestyle=':',  linewidth=0.8)
ax.set_xticks(x)
ax.set_xticklabels(completed_groups)
ax.set_ylabel('% of All Runs in Group')
ax.set_ylim(0, 118)
ax.set_title('Pass Rate: Original vs Original + Sweep Recovery', fontweight='bold')
ax.legend(loc='upper left', fontsize=8)
ax.grid(True, alpha=0.3, axis='y')
plt.tight_layout()
plt.savefig(os.path.join(OUTPUT_DIR, 'plotA_pass_rate_stacked.png'), dpi=150)
plt.close()
print("Saved: plotA_pass_rate_stacked.png")

# ─────────────────────────────────────────────────────────────────────────────
# PLOT B — Scatter: Actual vs Simulated with % annotations
# ─────────────────────────────────────────────────────────────────────────────

for g in completed_groups:
    df_all_g = df_orig_all[df_orig_all['group'] == g].dropna(
                   subset=[ACTUAL_COL_ORIG, SIM_COL_ORIG])
    n_total_g      = len(df_all_g)
    n_fail_g       = (df_all_g['pass_fail'] == 'FAIL').sum()
    fail_pct_g     = n_fail_g / n_total_g * 100

    best_g         = get_best_sweep(g)
    n_best_pass    = best_g['new_pass'].sum()
    n_best_total   = len(best_g)
    sweep_pass_pct = n_best_pass / n_best_total * 100

    all_actual = pd.concat([df_all_g[ACTUAL_COL_ORIG], best_g['actual_0_100']])
    lims = [0, all_actual.max() + 1]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5))

    pass_orig = df_all_g[df_all_g['pass_fail'] == 'PASS']
    fail_orig = df_all_g[df_all_g['pass_fail'] == 'FAIL']
    ax1.scatter(pass_orig[ACTUAL_COL_ORIG], pass_orig[SIM_COL_ORIG],
                alpha=0.4, s=15, color='mediumseagreen', label='Pass')
    ax1.scatter(fail_orig[ACTUAL_COL_ORIG], fail_orig[SIM_COL_ORIG],
                alpha=0.4, s=15, color='tomato', label='Fail')
    ax1.plot(lims, lims,              'k--', linewidth=1, label='Perfect (y=x)')
    ax1.plot(lims, [l*1.1 for l in lims], 'r:', linewidth=1, label='+10%')
    ax1.plot(lims, [l*0.9 for l in lims], 'r:', linewidth=1, label='-10%')
    ax1.set_xlim(lims); ax1.set_ylim(lims); ax1.set_aspect('equal')
    ax1.set_xlabel('Actual 0-100 time (s)')
    ax1.set_ylabel('Simulated 0-100 time (s)')
    ax1.set_title('Original — All Runs', fontweight='bold')
    ax1.legend(fontsize=7)
    ax1.grid(True, alpha=0.3)
    ax1.text(0.03, 0.97, f'{fail_pct_g:.1f}% of runs are failed',
             transform=ax1.transAxes, fontsize=9, va='top', color='tomato',
             fontweight='bold',
             bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))

    pass_sweep = best_g[best_g['new_pass']]
    fail_sweep = best_g[~best_g['new_pass']]
    bp = best_params[g]
    ax2.scatter(pass_sweep['actual_0_100'], pass_sweep[SIM_COL],
                alpha=0.4, s=15, color='mediumseagreen', label='Pass')
    ax2.scatter(fail_sweep['actual_0_100'], fail_sweep[SIM_COL],
                alpha=0.4, s=15, color='tomato', label='Fail')
    ax2.plot(lims, lims,              'k--', linewidth=1, label='Perfect (y=x)')
    ax2.plot(lims, [l*1.1 for l in lims], 'r:', linewidth=1, label='+10%')
    ax2.plot(lims, [l*0.9 for l in lims], 'r:', linewidth=1, label='-10%')
    ax2.set_xlim(lims); ax2.set_ylim(lims); ax2.set_aspect('equal')
    ax2.set_xlabel('Actual 0-100 time (s)')
    ax2.set_ylabel('Simulated 0-100 time (s)')
    ax2.set_title(f'Best Sweep  (tq×{bp["tq_scale"]:.2f}, '
                  f'Δshift{bp["shift_delta"]:+.2f}s)',
                  fontweight='bold')
    ax2.legend(fontsize=7)
    ax2.grid(True, alpha=0.3)
    ax2.text(0.03, 0.97, f'{sweep_pass_pct:.1f}% of failed runs now pass',
             transform=ax2.transAxes, fontsize=9, va='top',
             color='mediumseagreen', fontweight='bold',
             bbox=dict(boxstyle='round,pad=0.3', facecolor='white', alpha=0.8))

    fig.suptitle(f'{g} — Actual vs Simulated', fontweight='bold')
    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, f'plotB_scatter_{g}.png'), dpi=150)
    plt.close()
print("Saved: plotB_scatter_*.png")

# ─────────────────────────────────────────────────────────────────────────────
# PLOT C — Lollipop scatter: per-run parameter % change for FAIL→PASS runs
# ─────────────────────────────────────────────────────────────────────────────

for g in completed_groups:
    best_g = get_best_sweep(g)
    passed = best_g[best_g['new_pass']].copy().reset_index(drop=True)

    if len(passed) == 0:
        print(f"{g}: No newly passing runs — skipping plotC.")
        continue

    df_orig_fail_g = df_fail_all[df_fail_all['group'] == g].copy()
    id_col_orig    = find_col(df_orig_fail_g, ['RUN_ID', 'run_id'])
    df_orig_fail_g = df_orig_fail_g.set_index(id_col_orig)

    n_runs     = len(passed)
    n_params   = len(CHANGED_PARAMS)
    run_ids    = passed['ORIG_RUN_ID'].values
    param_list = list(CHANGED_PARAMS.keys())

    pct_matrix = np.zeros((n_params, n_runs))
    for j, (param_new, param_orig) in enumerate(CHANGED_PARAMS.items()):
        for k, (_, row) in enumerate(passed.iterrows()):
            orig_id = row['ORIG_RUN_ID']
            if orig_id in df_orig_fail_g.index and param_orig in df_orig_fail_g.columns:
                ov = df_orig_fail_g.loc[orig_id, param_orig]
                nv = row[param_new] if param_new in row.index else np.nan
                if pd.notna(ov) and pd.notna(nv) and ov != 0:
                    pct_matrix[j, k] = (nv - ov) / abs(ov) * 100

    fig, axes = plt.subplots(n_params, 1,
                             figsize=(max(12, n_runs * 0.45), 3.2 * n_params),
                             sharex=True)
    axes = np.array(axes).flatten()

    for j, param_new in enumerate(param_list):
        ax   = axes[j]
        vals = pct_matrix[j]
        colors = ['mediumseagreen' if v >= 0 else 'tomato' for v in vals]

        ax.axhline(0,   color='black', linestyle='--', linewidth=1.0, zorder=1)
        ax.axhline(10,  color='grey',  linestyle=':',  linewidth=0.8, zorder=1)
        ax.axhline(-10, color='grey',  linestyle=':',  linewidth=0.8, zorder=1)

        for k in range(n_runs):
            ax.vlines(k, 0, vals[k], colors=colors[k],
                      linewidth=0.8, alpha=0.5, zorder=2)

        ax.scatter(range(n_runs), vals, c=colors, s=40, zorder=3,
                   edgecolors='white', linewidths=0.5)

        mean_val = np.mean(vals)
        ax.axhline(mean_val, color='navy', linestyle='-.',
                   linewidth=1.2, alpha=0.8, zorder=2)

        ax.set_ylabel('% Change', fontsize=8)
        ax.set_title(param_new, fontsize=9, fontweight='bold')
        ax.grid(True, alpha=0.2, axis='y')
        ax.text(0.99, 0.95, f'Mean: {mean_val:+.2f}%',
                transform=ax.transAxes, ha='right', va='top', fontsize=8,
                color='navy',
                bbox=dict(boxstyle='round,pad=0.2', facecolor='white', alpha=0.8))

    axes[-1].set_xlabel('ORIG_RUN_ID of recovered run', fontsize=9)
    axes[-1].set_xticks(range(n_runs))
    axes[-1].set_xticklabels(run_ids.astype(int), rotation=90, fontsize=6)

    green_dot = plt.Line2D([0], [0], marker='o', color='w',
                            markerfacecolor='mediumseagreen', markersize=8,
                            label='Increased vs original')
    red_dot   = plt.Line2D([0], [0], marker='o', color='w',
                            markerfacecolor='tomato', markersize=8,
                            label='Decreased vs original')
    navy_line = plt.Line2D([0], [0], color='navy', linestyle='-.',
                            linewidth=1.5, label='Mean')
    fig.legend(handles=[green_dot, red_dot, navy_line],
               loc='upper right', fontsize=8, ncol=3,
               bbox_to_anchor=(0.99, 0.99))

    fig.suptitle(f'{g} — Parameter % Change per Recovered Run (FAIL→PASS)\n'
                 f'Best sweep: tq×{best_params[g]["tq_scale"]:.2f}, '
                 f'Δshift{best_params[g]["shift_delta"]:+.2f}s  |  '
                 f'{n_runs} runs recovered',
                 fontweight='bold')
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig(os.path.join(OUTPUT_DIR, f'plotC_param_change_perrun_{g}.png'), dpi=150)
    plt.close()
print("Saved: plotC_param_change_perrun_*.png")

# ─────────────────────────────────────────────────────────────────────────────
# PLOT D — Average parameter % change summary (horizontal bar)
# ─────────────────────────────────────────────────────────────────────────────

for g in completed_groups:
    best_g = get_best_sweep(g)
    passed = best_g[best_g['new_pass']].copy()

    if len(passed) == 0:
        print(f"{g}: No newly passing runs — skipping plotD.")
        continue

    df_orig_fail_g = df_fail_all[df_fail_all['group'] == g].copy()
    id_col_orig    = find_col(df_orig_fail_g, ['RUN_ID', 'run_id'])
    df_orig_fail_g = df_orig_fail_g.set_index(id_col_orig)

    summary = {}
    for param_new, param_orig in CHANGED_PARAMS.items():
        pct_changes = []
        for _, row in passed.iterrows():
            orig_id = row['ORIG_RUN_ID']
            if orig_id in df_orig_fail_g.index and param_orig in df_orig_fail_g.columns:
                ov = df_orig_fail_g.loc[orig_id, param_orig]
                nv = row[param_new] if param_new in row.index else np.nan
                if pd.notna(ov) and pd.notna(nv) and ov != 0:
                    pct_changes.append((nv - ov) / abs(ov) * 100)
        summary[param_new] = np.mean(pct_changes) if pct_changes else 0.0

    params = list(summary.keys())
    values = list(summary.values())
    colors = ['mediumseagreen' if v >= 0 else 'tomato' for v in values]

    fig, ax = plt.subplots(figsize=(8, 4))
    bars = ax.barh(params, values, color=colors, alpha=0.85, edgecolor='white')
    ax.axvline(0, color='black', linestyle='--', linewidth=1)
    for bar, val in zip(bars, values):
        offset = 0.3 if val >= 0 else -0.3
        ax.text(val + offset, bar.get_y() + bar.get_height()/2,
                f'{val:+.2f}%', va='center',
                ha='left' if val >= 0 else 'right', fontsize=7)
    # ───────────────────────────────────────────────
    # THE ONLY FIX ADDED → expand x‑axis for label room
    ax.set_xlim(ax.get_xlim()[0] * 1.25, ax.get_xlim()[1] * 1.25)
    # ───────────────────────────────────────────────


    ax.set_xlabel('Mean % Change from Original Value')
    ax.set_title(f'{g} — Average Parameter Change in FAIL→PASS Runs\n'
                 f'({len(passed)} runs recovered | '
                 f'tq×{best_params[g]["tq_scale"]:.2f}, '
                 f'Δshift{best_params[g]["shift_delta"]:+.2f}s)',
                 fontweight='bold')
    ax.grid(True, alpha=0.3, axis='x')
    green_patch = mpatches.Patch(color='mediumseagreen', label='Increased')
    red_patch   = mpatches.Patch(color='tomato',         label='Decreased')
    ax.legend(handles=[green_patch, red_patch], fontsize=8)
    plt.tight_layout()
    plt.savefig(os.path.join(OUTPUT_DIR, f'plotD_mean_param_change_{g}.png'), dpi=150)
    plt.close()
print("Saved: plotD_mean_param_change_*.png")

# ─────────────────────────────────────────────────────────────────────────────
# EXCEL EXPORT — Recovered runs with all inputs + IDs
# ─────────────────────────────────────────────────────────────────────────────

writer = pd.ExcelWriter(
    os.path.join(OUTPUT_DIR, 'recovered_runs_all_groups.xlsx'),
    engine='openpyxl')

for g in completed_groups:
    best_g = get_best_sweep(g)
    passed = best_g[best_g['new_pass']].copy()

    if len(passed) == 0:
        print(f"{g}: No passing runs to export.")
        continue

    df_orig_fail_g = df_fail_all[df_fail_all['group'] == g].copy()
    df_orig_fail_g.columns = [clean_col(c) for c in df_orig_fail_g.columns]
    id_col_orig    = find_col(df_orig_fail_g, ['RUN_ID', 'run_id'])
    df_orig_fail_g = df_orig_fail_g.set_index(id_col_orig)

    export_cols = (['ORIG_RUN_ID', 'SWEEP_RUN_ID'] +
                   SWEEP_PARAMS +
                   [p for p in INPUT_PARAMS if p in passed.columns] +
                   ['actual_0_100', SIM_COL, 'new_pct_error'])
    export_cols = [c for c in export_cols if c in passed.columns]

    out = passed[export_cols].copy()
    out.rename(columns={
        'actual_0_100':  'Actual_0_100_s',
        SIM_COL:         'Swept_SL_time_s',
        'new_pct_error': 'Swept_pct_error'
    }, inplace=True)

    for param in ['tq_ICE_max', 'tq_ICE_idle', 'Pwr_ICE_max_kW', 'shiftDelay', 'm_curb']:
        if param in df_orig_fail_g.columns:
            out[f'orig_{param}'] = out['ORIG_RUN_ID'].map(
                df_orig_fail_g[param].to_dict())

    pct_err_col = find_col(
        df_orig_fail_g.reset_index(),
        ['pct_error', 'Pct_error', 'PCT_ERROR']
    )
    out['orig_pct_error'] = out['ORIG_RUN_ID'].map(
        df_orig_fail_g[pct_err_col].to_dict())

    out.to_excel(writer, sheet_name=g[:31], index=False)
    print(f"Exported {len(out)} recovered runs for {g}")

writer.close()
print(f"\nSaved: recovered_runs_all_groups.xlsx")
print(f"\nAll outputs saved to ./{OUTPUT_DIR}/")