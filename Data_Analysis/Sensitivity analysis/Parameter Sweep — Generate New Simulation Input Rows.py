import pandas as pd
import numpy as np
import re

# ── Sweep configuration per group ────────────────────────────────────────────
SWEEP_CONFIG = {
    # Sim TOO SLOW (+error) → need MORE torque and MORE shift delay
    'G1_lt5s':    {'tq_scale':    [1.00, 1.05, 1.10, 1.15, 1.20],
                   'shift_delta': [0.0,  -0.1,  -0.2,  -0.3,  -0.4],
                   'mass_scale':  [1.00]},

    # Sim slightly too slow (+error) → increase torque and shift delay
    'G2_5to7s':   {'tq_scale':    [1.00, 1.05, 1.10, 1.15],
                   'shift_delta': [0.0,  -0.1,  -0.2,  -0.3],
                   'mass_scale':  [1.00]},

    # Sim nearly correct, slight negative error → small torque reduction
    'G3_7to10s':  {'tq_scale':    [0.95, 1.00, 1.05],
                   'shift_delta': [0.0,  0.1,  0.2],   # only increase or keep same
                   'mass_scale':  [1.00]},

    # Sim TOO FAST (-error) → reduce torque, INCREASE shift delay, add mass
    'G4_10to13s': {'tq_scale':    [0.80, 0.85, 0.90, 0.95, 1.00],
                   'shift_delta': [0.0,  0.1,  0.2,  0.3],   # ← was negative, now positive
                   'mass_scale':  [1.00, 1.02, 1.04, 1.06]},

    # Sim VERY TOO FAST (-error) → aggressively reduce torque, increase delay and mass
    'G5_gt13s':   {'tq_scale':    [0.60, 0.65, 0.70, 0.75, 0.80],
                   'shift_delta': [0.0,  0.1,  0.2,  0.3],   # ← was negative, now positive
                   'mass_scale':  [1.00, 1.03, 1.06, 1.09]},
}

labels_g = ['G1_lt5s', 'G2_5to7s', 'G3_7to10s', 'G4_10to13s', 'G5_gt13s']

# ── Columns that are modified by the sweep ────────────────────────────────────
# All other columns are passed through unchanged
SWEPT_PARAMS = ['tq_ICE_max', 'tq_ICE_idle', 'Pwr_ICE_max_kW', 'shiftDelay', 'm_curb']

for g in labels_g:
    cfg   = SWEEP_CONFIG[g]
    gdf   = pd.read_csv(f'sensitivity_{g}.csv')
    fails = gdf[gdf['pass_fail'] == 'FAIL'].copy()

    # Identify all original input columns (everything except computed output cols)
    output_cols = ['error', 'pct_error', 'pass_fail', 'group',
                   'Actual_0_to_100', 'SL_time_0_to_100']
    all_input_cols = [c for c in gdf.columns if c not in output_cols]

    sweep_rows = []
    new_run_id = 1

    for _, row in fails.iterrows():
        for tq_s in cfg['tq_scale']:
            for sd in cfg['shift_delta']:
                for ms in cfg['mass_scale']:

                    # Start with ALL original columns unchanged
                    new_row = row[all_input_cols].copy()

                    # ── Apply sweep modifications ─────────────────────────
                    new_row['tq_ICE_max']     = row['tq_ICE_max']     * tq_s
                    new_row['tq_ICE_idle']    = row['tq_ICE_idle']    * tq_s
                    new_row['Pwr_ICE_max_kW'] = row['Pwr_ICE_max_kW'] * tq_s
                    new_row['shiftDelay']     = float(np.clip(row['shiftDelay'] + sd, 0.05, 1.5))
                    new_row['m_curb']         = row['m_curb']         * ms

                    # ── Sweep tracking metadata ───────────────────────────
                    new_row['ORIG_RUN_ID']  = row['RUN_ID']
                    new_row['SWEEP_RUN_ID'] = new_run_id
                    new_row['tq_scale']     = tq_s
                    new_row['shift_delta']  = sd
                    new_row['mass_scale']   = ms
                    new_row['actual_0_100'] = row['Actual_0_to_100']

                    sweep_rows.append(new_row)
                    new_run_id += 1

    sweep_df = pd.DataFrame(sweep_rows)

    # ── Reorder: tracking cols at front, then all original input cols ─────────
    tracking_cols = ['SWEEP_RUN_ID', 'ORIG_RUN_ID', 'tq_scale',
                     'shift_delta', 'mass_scale', 'actual_0_100']
    remaining_cols = [c for c in sweep_df.columns if c not in tracking_cols]
    sweep_df = sweep_df[tracking_cols + remaining_cols]

    sweep_df.to_csv(f'sweep_{g}.csv', index=False)
    print(f"{g}: {len(fails)} failed runs → {len(sweep_df)} sweep combinations")