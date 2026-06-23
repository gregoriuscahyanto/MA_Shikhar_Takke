# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID POWERTRAIN SURROGATE MODEL — TRIPLE-TRACK ORACLE (New Parameters)
# Author: Shikhar Takke | Hochschule Esslingen
# ───────────────────────────────────────────────────────────────────────────────
# New simulation inputs added:
#   d_wheel   — wheel diameter (m)
#   A_front   — frontal area (m²)
#   shiftDelay   — gear shift delay (s)
#
# Feature expansion:
#   FEATURES_24  (base: S1 chain)
#   FEATURES_39  (extended: S3 and S5 chains)
#
# Routing Fixed:
#   S1: 0-100, 0-200 (Low-speed basics)
#   S3: 60-120, 80-120, max_launch_acc, max_speed, Avg_track_speed, Lap_Time
#       (Stacking + Aero + Shift features + Cube-root physics to kill outliers)
# ═══════════════════════════════════════════════════════════════════════════════

import pandas as pd
import numpy as np
import re
import warnings
import joblib
import os

warnings.filterwarnings('ignore')

from sklearn.model_selection import train_test_split
from sklearn.metrics import r2_score, mean_absolute_error, mean_squared_error, mean_absolute_percentage_error, accuracy_score
from sklearn.ensemble import StackingRegressor, RandomForestRegressor, GradientBoostingClassifier
from sklearn.linear_model import Ridge
from xgboost import XGBRegressor
import lightgbm as lgb

# ─────────────────────────────────────────────────────────────────────────────
# 1. LOAD & MERGE
# ─────────────────────────────────────────────────────────────────────────────
df_inp = pd.read_csv('DoE_Inp_Hybrid.csv')
df_kpi = pd.read_excel('Final_Simulation_Results_ALL_RUN_IDs.xlsx')
df = pd.merge(df_inp, df_kpi, on='RUN_ID', how='inner')
df = df.dropna(subset=df_kpi.columns.tolist()).reset_index(drop=True)
print(f'✔ Dataset: {df.shape[0]} rows × {df.shape[1]} cols')

# ─────────────────────────────────────────────────────────────────────────────
# 2. FEATURE ENGINEERING
# ─────────────────────────────────────────────────────────────────────────────
def parse_gear(s):
    vals = [float(x) for x in re.findall(r'\d+\.?\d*', str(s))]
    return vals if len(vals) > 1 else [1.0, 1.0]

df['_gr']         = df['Gear_Ratio'].apply(parse_gear)
df['GR_1st']      = df['_gr'].apply(lambda x: x[0])
df['GR_last']     = df['_gr'].apply(lambda x: x[-1])
df['GR_2nd']      = df['_gr'].apply(lambda x: x[1] if len(x) > 1 else x[0])
df['GR_3rd']      = df['_gr'].apply(lambda x: x[2] if len(x) > 2 else x[-1])
df['GR_spread']   = df['GR_1st'] / df['GR_last']
df['GR_step_geo'] = df['_gr'].apply(
    lambda x: float(np.exp(np.mean(np.diff(np.log(x))))) if len(x) > 2 else 1.0)

# ── Base physics (shared across all) ─────────────────────────────────────────
df['PW_ratio']        = df['Pwr_ICE_max_kW'] / df['m_curb']
df['TW_ratio']        = df['tq_ICE_max']     / df['m_curb']
df['Pwr_per_rpm']     = df['Pwr_ICE_max_kW'] / df['n_ICE_max']
df['GR_launch']       = df['GR_1st']  * df['iAG']
df['GR_topspeed']     = df['GR_last'] * df['iAG']
df['Tq_wheel_launch'] = df['tq_ICE_max'] * df['GR_launch']

# ── Wheel / aero / shift features ────────────────────────────────────────────
df['r_wheel']            = df['d_wheel'] / 2
df['shift_time_penalty'] = (df['No_Gears'] - 1) * df['shiftDelay']

# ── Extended physics for S3 and S5 ───────────────────────────────────────────
df['GR_mid']       = df['GR_2nd'] * df['GR_3rd'] * df['iAG']
df['speed_at_2nd'] = df['n_ICE_max'] / (df['GR_2nd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['speed_at_3rd'] = df['n_ICE_max'] / (df['GR_3rd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['AWD_factor']   = df['AWD'].apply(lambda x: 1.0 if x >= 1 else 0.6)
df['Eff_acc_launch']= df['Tq_wheel_launch'] * df['AWD_factor'] / df['m_curb']

df['v_max_theoretical'] = df['n_ICE_max'] / (df['GR_last'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['v_1st_gear_max']    = df['n_ICE_max'] / (df['GR_1st']  * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['Drag_to_power']     = df['A_front']   / df['Pwr_ICE_max_kW']
df['Drag_to_weight']    = df['A_front']   / df['m_curb']
df['Drag_power_index']  = df['A_front']   * df['m_curb'] / df['Pwr_ICE_max_kW']
df['shift_penalty_ratio'] = df['shiftDelay'] / df['No_Gears']

# ── NEW: Explicit shift triggers & TRUE Max Speed Physics ────────────────────
df['shift_in_80_120']  = ((df['speed_at_2nd'] > 80) & (df['speed_at_2nd'] < 120)).astype(int)
df['shift_before_100'] = (df['speed_at_2nd'] < 100).astype(int)
df['High_speed_push']  = df['Pwr_ICE_max_kW'] / (df['m_curb'] * df['A_front'])

# THE FIX: Aero-limited top speed scales with the CUBE ROOT of Power/Area.
df['Aero_v_max_cbrt']  = np.cbrt(df['Pwr_ICE_max_kW'] / df['A_front'])

# ─────────────────────────────────────────────────────────────────────────────
# 3. FEATURE SETS
# ─────────────────────────────────────────────────────────────────────────────
# S1 base  — 24 features
FEATURES_24 = [
    'HM_VA', 'AWD', 'iAG', 'm_curb', 'Wheelbase', 'No_Gears',
    'n_ICE_max', 'tq_ICE_idle', 'tq_ICE_max', 'Pwr_ICE_max_kW',
    'GR_1st', 'GR_last', 'GR_spread', 'GR_step_geo',
    'PW_ratio', 'TW_ratio', 'Pwr_per_rpm', 'GR_launch', 'GR_topspeed', 'Tq_wheel_launch',
    'r_wheel', 'A_front', 'shiftDelay', 'shift_time_penalty',
]

# S3 & S5 extended  — 39 features (Includes aero, shift triggers, and cubic root)
FEATURES_39 = FEATURES_24 + [
    'GR_mid', 'speed_at_2nd', 'speed_at_3rd', 'AWD_factor', 'Eff_acc_launch',
    'v_max_theoretical', 'v_1st_gear_max',
    'Drag_to_power', 'Drag_to_weight', 'Drag_power_index',
    'shift_penalty_ratio',
    'shift_in_80_120', 'shift_before_100', 'High_speed_push',
    'Aero_v_max_cbrt'  # Required for max speed accuracy
]

TARGETS_CHAIN = [
    'SL_time_0_to_100', 'SL_time_80_to_120', 'SL_time_60_to_120',
    'SL_max_launch_acc', 'SL_max_speed', 'Avg_track_speed', 'Lap_Time'
]

# ROUTING LOGIC: Stacking (S3) handles all complex physics to avoid XGBoost variance blowups.
KPI_ROUTING = {
    'SL_time_0_to_100':  'S1',
    'SL_time_80_to_120': 'S5',
    'SL_time_60_to_120': 'S5',
    'SL_max_launch_acc': 'S3',
    'SL_max_speed':      'S3',  # Moved to S3 to utilize the 39-feature set and reduce RMSE
    'Avg_track_speed':   'S3',
    'Lap_Time':          'S3',
    'SL_time_0_to_200':  'S1',
}

df['can_reach_200'] = (df['SL_time_0_to_200'] > 0).astype(int)
R2_THRESHOLD = 0.95

print(f'\n✔ Feature sets:  S1 → {len(FEATURES_24)} feat  |  S3 & S5 → {len(FEATURES_39)} feat')

# ─────────────────────────────────────────────────────────────────────────────
# 4. SPLIT
# ─────────────────────────────────────────────────────────────────────────────
Y     = df[TARGETS_CHAIN].values.astype(float)
y_200 = df['SL_time_0_to_200'].values.astype(float)
y_can = df['can_reach_200'].values

idx_tr, idx_te = train_test_split(np.arange(len(df)), test_size=0.2, random_state=42)

Y_tr,  Y_te   = Y[idx_tr],  Y[idx_te]
X24_tr = df[FEATURES_24].values[idx_tr];  X24_te = df[FEATURES_24].values[idx_te]
X39_tr = df[FEATURES_39].values[idx_tr];  X39_te = df[FEATURES_39].values[idx_te]

ycan_tr, ycan_te = y_can[idx_tr], y_can[idx_te]
y200_tr, y200_te = y_200[idx_tr], y_200[idx_te]

print(f'\n✔ Split: train={X24_tr.shape[0]} | test={X24_te.shape[0]}')

# ─────────────────────────────────────────────────────────────────────────────
# 5. MODEL FACTORIES
# ─────────────────────────────────────────────────────────────────────────────
def build_xgb_s1():
    return XGBRegressor(
        n_estimators=500, learning_rate=0.05, max_depth=6, subsample=0.8,
        colsample_bytree=0.8, min_child_weight=3, reg_alpha=0.1, reg_lambda=1.0,
        random_state=42, n_jobs=-1, verbosity=0
    )

def build_stacking_s3():
    return StackingRegressor(
        estimators=[
            ('xgb', XGBRegressor(n_estimators=800, learning_rate=0.03, max_depth=7,
                                  subsample=0.85, colsample_bytree=0.75, min_child_weight=2,
                                  reg_alpha=0.05, reg_lambda=1.5, gamma=0.1,
                                  random_state=42, n_jobs=-1, verbosity=0)),
            ('lgb', lgb.LGBMRegressor(n_estimators=800, learning_rate=0.03, num_leaves=63,
                                       min_child_samples=10, subsample=0.85, colsample_bytree=0.75,
                                       reg_alpha=0.05, reg_lambda=1.5, random_state=42,
                                       n_jobs=-1, verbose=-1)),
            ('rf',  RandomForestRegressor(n_estimators=300, max_depth=12, min_samples_leaf=3,
                                          max_features=0.7, random_state=42, n_jobs=-1)),
        ],
        final_estimator=Ridge(alpha=1.0), cv=5, n_jobs=-1, passthrough=True
    )

def build_xgb_s5():
    return XGBRegressor(
        n_estimators=600, learning_rate=0.04, max_depth=6, subsample=0.8,
        colsample_bytree=0.8, min_child_weight=3, reg_alpha=0.1, reg_lambda=1.0,
        random_state=42, n_jobs=-1, verbosity=0
    )

# ─────────────────────────────────────────────────────────────────────────────
# 6. GENERIC CHAIN RUNNER
# ─────────────────────────────────────────────────────────────────────────────
def run_full_chain(builder_func, X_tr_base, X_te_base, track_name):
    print(f'\n{"═"*85}\n {track_name}  ({X_tr_base.shape[1]} features)\n{"═"*85}')
    gates, models, results = {}, {}, {}
    X_tr_aug, X_te_aug = X_tr_base.copy(), X_te_base.copy()

    for i, kpi in enumerate(TARGETS_CHAIN):
        # Standalone gate check
        m_stand = builder_func()
        m_stand.fit(X_tr_base, Y_tr[:, i])
        r2_stand = r2_score(Y_te[:, i], m_stand.predict(X_te_base))
        gates[kpi] = r2_stand >= R2_THRESHOLD

        # Chain model
        m_chain = builder_func()
        m_chain.fit(X_tr_aug, Y_tr[:, i])
        yp  = m_chain.predict(X_te_aug)
        r2   = r2_score(Y_te[:, i], yp)
        mae  = mean_absolute_error(Y_te[:, i], yp)
        rmse = np.sqrt(mean_squared_error(Y_te[:, i], yp))
        mape = mean_absolute_percentage_error(Y_te[:, i], yp)

        models[kpi]  = m_chain
        results[kpi] = {'R2': r2, 'MAE': mae, 'RMSE': rmse, 'MAPE': mape}
        print(f'  {kpi:<26}  Gate: {"PASS" if gates[kpi] else "TUNE"}  R²={r2:.4f}  MAE={mae:.4f}  RMSE={rmse:.4f}  MAPE={mape:.4f}')

        if gates[kpi]:
            X_tr_aug = np.hstack([X_tr_aug, Y_tr[:, i].reshape(-1, 1)])
            X_te_aug = np.hstack([X_te_aug, yp.reshape(-1, 1)])

    return models, gates, results

# ─────────────────────────────────────────────────────────────────────────────
# 7. TRAIN THREE TRACKS
# ─────────────────────────────────────────────────────────────────────────────
s1_models, s1_gates, s1_res = run_full_chain(build_xgb_s1,      X24_tr, X24_te, 'TRACK S1 — XGBoost')
s3_models, s3_gates, s3_res = run_full_chain(build_stacking_s3, X39_tr, X39_te, 'TRACK S3 — Stacking (extended features)')
s5_models, s5_gates, s5_res = run_full_chain(build_xgb_s5,      X39_tr, X39_te, 'TRACK S5 — XGBoost (extended features)')

# ─────────────────────────────────────────────────────────────────────────────
# 8. SL_time_0_to_200  (S1 architecture, 24-feat base)
# ─────────────────────────────────────────────────────────────────────────────
print(f'\n{"═"*85}\n TRACK S1 — 0_to_200 Two-Stage\n{"═"*85}')
clf200 = GradientBoostingClassifier(n_estimators=300, max_depth=5,
                                     learning_rate=0.05, random_state=42)
clf200.fit(X24_tr, ycan_tr)
acc = accuracy_score(ycan_te, clf200.predict(X24_te))

mask_tr = ycan_tr == 1;  mask_te = ycan_te == 1
reg200  = build_xgb_s1()
reg200.fit(X24_tr[mask_tr], y200_tr[mask_tr])
yp_200   = reg200.predict(X24_te[mask_te])
r2_200   = r2_score(y200_te[mask_te], yp_200)
mae_200  = mean_absolute_error(y200_te[mask_te], yp_200)
rmse_200 = np.sqrt(mean_squared_error(y200_te[mask_te], yp_200))
mape_200 = mean_absolute_percentage_error(y200_te[mask_te], yp_200)
print(f'  Classifier  Acc={acc:.4f}  |  Regressor  R²={r2_200:.4f}  MAE={mae_200:.4f} s  RMSE={rmse_200:.4f} s  MAPE={mape_200:.4f}')

# ─────────────────────────────────────────────────────────────────────────────
# 9. FINAL ROUTING SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
print(f'\n{"═"*95}')
print(f' FINAL — Triple-Track Oracle (New Parameters & True Aero Physics)')
print(f'{"═"*95}')
print(f'  {"KPI":<26} {"Branch":>7}  {"R²":>7}  {"MAE":>9}  {"RMSE":>9}  {"MAPE":>9}')
print(f'  {"-"*75}')
for kpi in TARGETS_CHAIN:
    route = KPI_ROUTING[kpi]
    res   = s1_res if route == 'S1' else (s3_res if route == 'S3' else s5_res)
    print(f'  {kpi:<26} {route:>7}  {res[kpi]["R2"]:>7.4f}  {res[kpi]["MAE"]:>9.4f}  {res[kpi]["RMSE"]:>9.4f}  {res[kpi]["MAPE"]:>9.4f}')
print(f'  {"SL_time_0_to_200":<26} {"S1":>7}  {r2_200:>7.4f}  {mae_200:>9.4f}  {rmse_200:>9.4f}  {mape_200:>9.4f}')

# ─────────────────────────────────────────────────────────────────────────────
# 10. SAVE
# ─────────────────────────────────────────────────────────────────────────────
artifacts = {
    'strategy':       'Triple_Track_Oracle_newparam',
    'version_note':   'Added cubic aero physics and S3 extended tracking for all high-speed metrics',
    'param_note':     'Includes shift_in_80_120 and Aero_v_max_cbrt',
    'features_24':    FEATURES_24,
    'features_39':    FEATURES_39,
    'targets_chain':  TARGETS_CHAIN,
    'routing':        KPI_ROUTING,
    's1_models':      s1_models,   's1_gates': s1_gates,   's1_res': s1_res,
    's3_models':      s3_models,   's3_gates': s3_gates,   's3_res': s3_res,
    's5_models':      s5_models,   's5_gates': s5_gates,   's5_res': s5_res,
    'clf200':         clf200,
    'reg200':         reg200,
    'r2_200':         r2_200,
    'mae_200':        mae_200,
    'rmse_200':       rmse_200,
    'mape_200':       mape_200,
}
joblib.dump(artifacts, 'surrogate_triple_track_newparam.pkl')
print(f'\n✔ Saved → surrogate_triple_track_newparam.pkl')