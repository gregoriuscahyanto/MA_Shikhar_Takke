# ═══════════════════════════════════════════════════════════════════════════════
# DEPLOYMENT — Triple-Track Oracle (New Parameters)
# Author: Shikhar Takke | Hochschule Esslingen
# ───────────────────────────────────────────────────────────────────────────────
# New inputs required in KPIs_Predict_Test.csv:
# d_wheel       — wheel diameter (m)   e.g. 0.664
# A_front    — frontal area (m²)    e.g. 2.20
# shiftDelay — gear shift delay (s) e.g. 0.15
#
# Requires: surrogate_triple_track_newparam.pkl
# ═══════════════════════════════════════════════════════════════════════════════

import pandas as pd
import numpy as np
import re
import warnings
import joblib

warnings.filterwarnings('ignore')

print('═' * 70)
print(' TRIPLE-TRACK ORACLE (New Parameters) — Deployment')
print('═' * 70)

try:
    art = joblib.load('surrogate_triple_track_newparam.pkl')
    print(f'✔ Model loaded: {art["strategy"]}')
    print(f'  Note: {art["param_note"]}')
except FileNotFoundError:
    print('❌ ERROR: surrogate_triple_track_newparam.pkl not found.')
    print('   Run Triple_Track_Oracle_newparam.py first.')
    exit()

FEATURES_24   = art['features_24']
FEATURES_39   = art['features_39']   # FIX: was art['features_35'] — key does not exist in pkl
TARGETS_CHAIN = art['targets_chain']
KPI_ROUTING   = art['routing']

try:
    df = pd.read_csv('KPIs_Predict_Test.csv')
    print(f'✔ Input loaded: {df.shape[0]} row(s)')
except FileNotFoundError:
    print('❌ ERROR: KPIs_Predict_Test.csv not found.')
    exit()

# ── Validate new required columns ─────────────────────────────────────────────
REQUIRED_NEW = ['d_wheel', 'A_front', 'shiftDelay']
missing = [c for c in REQUIRED_NEW if c not in df.columns]
if missing:
    print(f'\n❌ Missing new columns: {missing}')
    print('   Add these to KPIs_Predict_Test.csv:')
    print('   d_wheel       — wheel diameter (m), e.g. 0.664')
    print('   A_front    — frontal area (m²),  e.g. 2.20')
    print('   shiftDelay — shift delay (s),    e.g. 0.15')
    exit()

# ── Feature engineering ───────────────────────────────────────────────────────
def parse_gear(s):
    vals = [float(x) for x in re.findall(r'\d+\.?\d*', str(s))]
    return vals if len(vals) > 1 else [1.0, 1.0]

df['_gr']        = df['Gear_Ratio'].apply(parse_gear)
df['GR_1st']    = df['_gr'].apply(lambda x: x[0])
df['GR_last']   = df['_gr'].apply(lambda x: x[-1])
df['GR_2nd']    = df['_gr'].apply(lambda x: x[1] if len(x) > 1 else x[0])
df['GR_3rd']    = df['_gr'].apply(lambda x: x[2] if len(x) > 2 else x[-1])
df['GR_spread'] = df['GR_1st'] / df['GR_last']
df['GR_step_geo'] = df['_gr'].apply(
    lambda x: float(np.exp(np.mean(np.diff(np.log(x))))) if len(x) > 2 else 1.0)

df['PW_ratio']        = df['Pwr_ICE_max_kW'] / df['m_curb']
df['TW_ratio']        = df['tq_ICE_max']     / df['m_curb']
df['Pwr_per_rpm']     = df['Pwr_ICE_max_kW'] / df['n_ICE_max']
df['GR_launch']       = df['GR_1st']  * df['iAG']
df['GR_topspeed']     = df['GR_last'] * df['iAG']
df['Tq_wheel_launch'] = df['tq_ICE_max'] * df['GR_launch']

# Wheel / shift
df['r_wheel']            = df['d_wheel'] / 2
df['shift_time_penalty'] = (df['No_Gears'] - 1) * df['shiftDelay']

# Extended physics (S3 / S5)
df['GR_mid']         = df['GR_2nd'] * df['GR_3rd'] * df['iAG']
df['speed_at_2nd']   = df['n_ICE_max'] / (df['GR_2nd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['speed_at_3rd']   = df['n_ICE_max'] / (df['GR_3rd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['AWD_factor']     = df['AWD'].apply(lambda x: 1.0 if x >= 1 else 0.6)
df['Eff_acc_launch'] = df['Tq_wheel_launch'] * df['AWD_factor'] / df['m_curb']

df['v_max_theoretical'] = df['n_ICE_max'] / (df['GR_last'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['v_1st_gear_max']    = df['n_ICE_max'] / (df['GR_1st'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['Drag_to_power']     = df['A_front'] / df['Pwr_ICE_max_kW']
df['Drag_to_weight']    = df['A_front'] / df['m_curb']
df['Drag_power_index']  = df['A_front'] * df['m_curb'] / df['Pwr_ICE_max_kW']
df['shift_penalty_ratio'] = df['shiftDelay'] / df['No_Gears']

# FIX: These 4 features were missing — required by FEATURES_39 for S3 & S5 tracks
df['shift_in_80_120'] = ((df['speed_at_2nd'] > 80) & (df['speed_at_2nd'] < 120)).astype(int)
df['shift_before_100']= (df['speed_at_2nd'] < 100).astype(int)
df['High_speed_push'] = df['Pwr_ICE_max_kW'] / (df['m_curb'] * df['A_front'])
df['Aero_v_max_cbrt'] = np.cbrt(df['Pwr_ICE_max_kW'] / df['A_front'])

# ── Build input matrices ───────────────────────────────────────────────────────
X_s1 = df[FEATURES_24].values.astype(float)
X_s3 = df[FEATURES_39].values.astype(float)   # FIX: was df[FEATURES_35] — variable never defined
X_s5 = df[FEATURES_39].values.astype(float)   # FIX: was df[FEATURES_35] — variable never defined

# ── Run three tracks ───────────────────────────────────────────────────────────
print(f'\n  Executing Track S1 (XGBoost, {len(FEATURES_24)} feat)...')
s1_preds = {}
for kpi in TARGETS_CHAIN:
    p = art['s1_models'][kpi].predict(X_s1)
    s1_preds[kpi] = p
    if art['s1_gates'][kpi]:
        X_s1 = np.hstack([X_s1, p.reshape(-1, 1)])

print(f'  Executing Track S3 (Stacking, {len(FEATURES_39)} feat)...')
s3_preds = {}
for kpi in TARGETS_CHAIN:
    p = art['s3_models'][kpi].predict(X_s3)
    s3_preds[kpi] = p
    if art['s3_gates'][kpi]:
        X_s3 = np.hstack([X_s3, p.reshape(-1, 1)])

print(f'  Executing Track S5 (XGBoost, {len(FEATURES_39)} feat)...')
s5_preds = {}
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

# ── 0_to_200 two-stage ─────────────────────────────────────────────────────────
print('\n  Predicting SL_time_0_to_200 (S1 two-stage)...')
X_base    = df[FEATURES_24].values.astype(float)
mask      = art['clf200'].predict(X_base) == 1
preds_200 = np.zeros(len(df))
if mask.any():
    preds_200[mask] = art['reg200'].predict(X_base[mask])
output['SL_time_0_to_200'] = preds_200

# ── Save ───────────────────────────────────────────────────────────────────────
out_file = 'Triple_Track_NewParam_Predictions.csv'
output.to_csv(out_file, index=False)
print(f'\n✔ Done. Saved → {out_file}')
print(f'  {len(df)} vehicle(s) × {len(TARGETS_CHAIN) + 1} KPIs')

# ── Pretty print ──────────────────────────────────────────────────────────────
print(f'\n{"═"*72}')
kpi_all = TARGETS_CHAIN + ['SL_time_0_to_200']
for _, row in output.iterrows():
    rid = row[id_col] if id_col else row['Row']
    print(f'\n  Vehicle: {rid}')
    for kpi in kpi_all:
        print(f'  {kpi:<26} {row[kpi]:>10.4f}  [{KPI_ROUTING.get(kpi, "S1")}]')
print(f'\n{"═"*72}')
