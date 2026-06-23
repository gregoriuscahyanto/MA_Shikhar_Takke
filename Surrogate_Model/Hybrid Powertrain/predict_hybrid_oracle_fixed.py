# ═══════════════════════════════════════════════════════════════════════════════
# DEPLOYMENT — Hybrid Triple-Track Oracle (Final / Optuna)
# Author: Shikhar Takke | Hochschule Esslingen
# ───────────────────────────────────────────────────────────────────────────────
# Requires: surrogate_hybrid_oracle.pkl
#           KPIs_Predict_Test.csv
#
# Required raw columns in KPIs_Predict_Test.csv:
#   HM_VA, AWD, iAG, m_curb, Wheelbase, No_Gears, n_ICE_max
#   Gear_Ratio      — gear ratio string, e.g. "3.5,2.1,1.4,1.0,0.8"
#   d_wheel            — wheel diameter (m),   e.g. 0.664
#   A_front         — frontal area (m²),    e.g. 2.20
#   shiftDelay      — gear shift delay (s), e.g. 0.15
#   Pwr_ICE_max_kW, tq_ICE_max
#   Pwr_P0_max_kW, tq_P0_max   (0 if not present)
#   Pwr_P2_max_kW, tq_P2_max   (0 if not present)
#   Pwr_P3_max_kW, tq_P3_max   (0 if not present)
#   Pwr_P4_max_kW, tq_P4_max   (0 if not present)
#   P4_DM           — 1 if dual-motor P4 axle, else 0
#   i_ges_P4        — P4 axle gear ratio (0 if no P4)
# ═══════════════════════════════════════════════════════════════════════════════

import pandas as pd
import numpy as np
import re
import warnings
import joblib

warnings.filterwarnings('ignore')

print('═' * 70)
print(' HYBRID TRIPLE-TRACK ORACLE (Final / Optuna) — Deployment')
print('═' * 70)

# ── Load model artifacts ───────────────────────────────────────────────────────
try:
    art = joblib.load('surrogate_hybrid_oracle.pkl')
    print(f'✔ Model loaded: {art["strategy"]}')
except FileNotFoundError:
    print('❌ ERROR: surrogate_hybrid_oracle.pkl not found.')
    print('   Run Surrogate_Triple_Track_Hybrid_Final_optuna_opti.py first.')
    exit()

FEATURES_BASE = art['features_base']    # 28 features — S1, S3, clf200/reg200
FEATURES_EXT  = art['features_ext']     # 37 features — S5
TARGETS_CHAIN = art['targets_chain']
KPI_ROUTING   = art['routing']

print(f'  Base features : {len(FEATURES_BASE)} | Extended features: {len(FEATURES_EXT)}')
print(f'  KPIs in chain : {len(TARGETS_CHAIN)} + 1 (0_to_200 two-stage)')

# ── Load input CSV ─────────────────────────────────────────────────────────────
try:
    df = pd.read_csv('KPIs_Predict_Test.csv')
    print(f'✔ Input loaded: {df.shape[0]} row(s), {df.shape[1]} col(s)')
except FileNotFoundError:
    print('❌ ERROR: KPIs_Predict_Test.csv not found.')
    exit()

# ── Validate required raw input columns ───────────────────────────────────────
REQUIRED_RAW = [
    'HM_VA', 'AWD', 'iAG', 'm_curb', 'Wheelbase', 'No_Gears', 'n_ICE_max',
    'Gear_Ratio', 'd_wheel', 'A_front', 'shiftDelay',
    'Pwr_ICE_max_kW', 'tq_ICE_max',
    'Pwr_P4_max_kW', 'i_ges_P4', 'P4_DM',
]
missing_cols = [c for c in REQUIRED_RAW if c not in df.columns]
if missing_cols:
    print(f'\n❌ Missing required columns: {missing_cols}')
    print('   Check the header comment in this script for column descriptions.')
    exit()

# ── FIX #1: Sanitize ALL powertrain columns before any feature math ────────────
# The training file uses dropna() — models never saw NaN. We must guarantee
# no NaN enters feature engineering. ICE columns must be filled FIRST because
# they feed Total_Pwr_kW / Total_Tq_max / Tq_wheel_launch_total, all of which
# are in FEATURES_BASE. A NaN there causes StackingRegressor (Ridge/RF) to
# return NaN, which then cascades through the chain gate augmentation.
all_powertrain_cols = [
    'Pwr_ICE_max_kW', 'tq_ICE_max',            # ICE — must be included!
    'Pwr_P0_max_kW',  'tq_P0_max',
    'Pwr_P2_max_kW',  'tq_P2_max',
    'Pwr_P3_max_kW',  'tq_P3_max',
    'Pwr_P4_max_kW',  'tq_P4_max',
    'P4_DM', 'i_ges_P4',
]
for col in all_powertrain_cols:
    if col not in df.columns:
        df[col] = 0.0
    else:
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0.0)

# ── Feature engineering ────────────────────────────────────────────────────────
def parse_gear(s):
    vals = [float(x) for x in re.findall(r'\d+\.?\d*', str(s))]
    return vals if len(vals) > 1 else [1.0, 1.0]

df['_gr']         = df['Gear_Ratio'].apply(parse_gear)
df['GR_1st']      = df['_gr'].apply(lambda x: x[0])
df['GR_last']     = df['_gr'].apply(lambda x: x[-1])
df['GR_2nd']      = df['_gr'].apply(lambda x: x[1] if len(x) > 1 else x[0])
df['GR_3rd']      = df['_gr'].apply(lambda x: x[2] if len(x) > 2 else x[-1])
df['GR_spread']   = df['GR_1st'] / df['GR_last'].replace(0, np.nan)
df['GR_step_geo'] = df['_gr'].apply(
    lambda x: float(np.exp(np.mean(np.diff(np.log(np.maximum(x, 1e-9)))))) if len(x) > 2 else 1.0)
df['GR_launch']   = df['GR_1st'] * df['iAG']
df['GR_topspeed'] = df['GR_last'] * df['iAG']
df['r_wheel']     = df['d_wheel'] / 2

# P4 dual-motor multiplier
p4_multiplier  = np.where(df['P4_DM'] == 1, 2.0, 1.0)
actual_pwr_p4  = df['Pwr_P4_max_kW'] * p4_multiplier
actual_tq_p4   = df['tq_P4_max']     * p4_multiplier

# System-level power & torque
df['Total_Pwr_kW'] = (df['Pwr_ICE_max_kW'] + df['Pwr_P0_max_kW'] +
                      df['Pwr_P2_max_kW']   + df['Pwr_P3_max_kW'] + actual_pwr_p4)
df['Total_Tq_max'] = (df['tq_ICE_max']  + df['tq_P0_max'] +
                      df['tq_P2_max']   + df['tq_P3_max']  + actual_tq_p4)
df['Sys_PW_ratio'] = df['Total_Pwr_kW'] / df['m_curb']
df['Sys_TW_ratio'] = df['Total_Tq_max'] / df['m_curb']

# Topological torque routing to wheels
tq_through_gearbox = (df['tq_ICE_max'] + df['tq_P0_max'] + df['tq_P2_max']) * df['GR_launch']
tq_through_final   =  df['tq_P3_max']  * df['iAG']
tq_through_p4axle  =  actual_tq_p4     * df['i_ges_P4']

df['Tq_wheel_launch_total']  = tq_through_gearbox + tq_through_final + tq_through_p4axle
df['AWD_factor']             = df['AWD'].apply(lambda x: 1.0 if x >= 1 else 0.6)
df['Eff_acc_launch_total']   = df['Tq_wheel_launch_total'] * df['AWD_factor'] / df['m_curb']

df['shift_time_penalty']   = (df['No_Gears'] - 1) * df['shiftDelay']
df['shift_penalty_ratio']  = df['shiftDelay'] / df['No_Gears'].replace(0, np.nan)

# FIX #3: Guard divisions that go to 0 — use replace(0, nan) so they become
# NaN which fillna later converts to 0 (instead of propagating inf → nan chain)
total_pwr_safe             = df['Total_Pwr_kW'].replace(0, np.nan)
df['Drag_to_SysPower']     = df['A_front'] / total_pwr_safe
df['Drag_power_index_sys'] = df['A_front'] * df['m_curb'] / total_pwr_safe

# Extended physics (S5 only)
df['GR_mid']            = df['GR_2nd'] * df['GR_3rd'] * df['iAG']
df['speed_at_2nd']      = df['n_ICE_max'] / (df['GR_2nd'] * df['iAG']).replace(0, np.nan) * (np.pi / 30) * df['r_wheel']
df['speed_at_3rd']      = df['n_ICE_max'] / (df['GR_3rd'] * df['iAG']).replace(0, np.nan) * (np.pi / 30) * df['r_wheel']
df['v_max_theoretical'] = df['n_ICE_max'] / df['GR_topspeed'].replace(0, np.nan) * (np.pi / 30) * df['r_wheel']
df['v_1st_gear_max']    = df['n_ICE_max'] / df['GR_launch'].replace(0, np.nan)   * (np.pi / 30) * df['r_wheel']

# ── FIX #4: Explicit per-column sanitization (safer than bulk df[cols] = ...) ──
# Convert inf → NaN first, then fill NaN column by column.
# This matches the training pipeline: dropna removed all inf/NaN before model fit.
df.replace([np.inf, -np.inf], np.nan, inplace=True)
for col in FEATURES_EXT:          # FEATURES_BASE ⊂ FEATURES_EXT — both covered
    df[col] = df[col].fillna(0.0)

# ── Diagnostic: warn if any NaN remains in feature columns ────────────────────
nan_check = {col: int(df[col].isna().sum()) for col in FEATURES_EXT if df[col].isna().any()}
if nan_check:
    print(f'\n⚠ WARNING: NaN still present after sanitization: {nan_check}')
    print('  Check your CSV for these columns — setting to 0.0 as fallback.')
    for col in nan_check:
        df[col] = df[col].fillna(0.0)
else:
    print('✔ Feature matrix sanitized — no NaN detected.')

# ── Build input matrices ───────────────────────────────────────────────────────
X_base = df[FEATURES_BASE].values.astype(float)  # S1, S3, clf200/reg200
X_ext  = df[FEATURES_EXT].values.astype(float)   # S5

# ── Run Track S1 (XGBoost, base features) ─────────────────────────────────────
print(f'\n  Executing Track S1 — XGBoost ({len(FEATURES_BASE)} base feat)...')
s1_preds = {}
X_s1 = X_base.copy()
for kpi in TARGETS_CHAIN:
    p = art['s1_models'][kpi].predict(X_s1)
    s1_preds[kpi] = p
    if art['s1_gates'][kpi]:
        X_s1 = np.hstack([X_s1, p.reshape(-1, 1)])

# ── Run Track S3 (Stacking, base features) ────────────────────────────────────
print(f'  Executing Track S3 — Stacking ({len(FEATURES_BASE)} base feat)...')
s3_preds = {}
X_s3 = X_base.copy()
for kpi in TARGETS_CHAIN:
    p = art['s3_models'][kpi].predict(X_s3)
    s3_preds[kpi] = p
    if art['s3_gates'][kpi]:
        X_s3 = np.hstack([X_s3, p.reshape(-1, 1)])

# ── Run Track S5 (XGBoost, extended features) ─────────────────────────────────
print(f'  Executing Track S5 — XGBoost ({len(FEATURES_EXT)} extended feat)...')
s5_preds = {}
X_s5 = X_ext.copy()
for kpi in TARGETS_CHAIN:
    p = art['s5_models'][kpi].predict(X_s5)
    s5_preds[kpi] = p
    if art['s5_gates'][kpi]:
        X_s5 = np.hstack([X_s5, p.reshape(-1, 1)])

# ── Oracle routing ─────────────────────────────────────────────────────────────
id_col = 'RUN_ID' if 'RUN_ID' in df.columns else None
output = df[[id_col]].copy() if id_col else pd.DataFrame({'Row': df.index + 1})

print('\n  Applying Oracle Routing:')
for kpi in TARGETS_CHAIN:
    route = KPI_ROUTING[kpi]
    src   = s1_preds if route == 'S1' else (s3_preds if route == 'S3' else s5_preds)
    output[kpi] = src[kpi]
    print(f'  → {kpi:<26} from {route}')

# ── SL_time_0_to_200: two-stage (clf200 → reg200) ─────────────────────────────
print('\n  Predicting SL_time_0_to_200 (S1 two-stage clf → reg)...')
mask      = art['clf200'].predict(X_base) == 1
preds_200 = np.zeros(len(df))
if mask.any():
    preds_200[mask] = art['reg200'].predict(X_base[mask])
output['SL_time_0_to_200'] = preds_200
print(f'  → {"SL_time_0_to_200":<26} from S1 ({mask.sum()}/{len(df)} vehicles can reach 200)')

# ── Save output ────────────────────────────────────────────────────────────────
out_file = 'Hybrid_Oracle_Predictions.csv'
output.to_csv(out_file, index=False)
kpi_all = TARGETS_CHAIN + ['SL_time_0_to_200']
print(f'\n✔ Done. Saved → {out_file}')
print(f'  {len(df)} vehicle(s) × {len(kpi_all)} KPIs')

# ── NaN check on output ────────────────────────────────────────────────────────
nan_out = output[kpi_all].isna().sum()
if nan_out.any():
    print(f'\n⚠ NaN in output:')
    print(nan_out[nan_out > 0].to_string())
else:
    print('✔ Output is clean — no NaN in any KPI.')

# ── Pretty-print results ───────────────────────────────────────────────────────
print(f'\n{"═"*72}')
for _, row in output.iterrows():
    rid = row[id_col] if id_col else row['Row']
    print(f'\n  Vehicle: {rid}')
    for kpi in kpi_all:
        route_label = KPI_ROUTING.get(kpi, 'S1')
        print(f'  {kpi:<26} {row[kpi]:>10.4f}  [{route_label}]')
print(f'\n{"═"*72}')
