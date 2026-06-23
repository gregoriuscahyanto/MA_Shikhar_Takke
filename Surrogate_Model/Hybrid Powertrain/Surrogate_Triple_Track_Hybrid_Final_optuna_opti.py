# ═══════════════════════════════════════════════════════════════════════════════
# HYBRID POWERTRAIN SURROGATE MODEL — TRIPLE-TRACK ORACLE (FINAL)
# ───────────────────────────────────────────────────────────────────────────────
# Fixes: Dual Motor (P4_DM) 2x multiplier applied to system power and torque.
# ═══════════════════════════════════════════════════════════════════════════════

import pandas as pd
import numpy as np
import re
import warnings
import joblib

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


# ─────────────────────────────────────────────────────────────────────────────
# 2. FEATURE ENGINEERING (Physics & Topologies)
# ─────────────────────────────────────────────────────────────────────────────
def parse_gear(s):
    vals = [float(x) for x in re.findall(r'\d+\.?\d*', str(s))]
    return vals if len(vals) > 1 else [1.0, 1.0]


df['_gr'] = df['Gear_Ratio'].apply(parse_gear)
df['GR_1st'] = df['_gr'].apply(lambda x: x[0])
df['GR_last'] = df['_gr'].apply(lambda x: x[-1])
df['GR_2nd'] = df['_gr'].apply(lambda x: x[1] if len(x) > 1 else x[0])
df['GR_3rd'] = df['_gr'].apply(lambda x: x[2] if len(x) > 2 else x[-1])
df['GR_spread'] = df['GR_1st'] / df['GR_last']
df['GR_step_geo'] = df['_gr'].apply(lambda x: float(np.exp(np.mean(np.diff(np.log(x))))) if len(x) > 2 else 1.0)
df['GR_launch'] = df['GR_1st'] * df['iAG']
df['GR_topspeed'] = df['GR_last'] * df['iAG']
df['r_wheel'] = df['d_wheel'] / 2

# Fill missing motor stats with 0 to prevent NaN math
motor_cols = ['Pwr_P0_max_kW', 'tq_P0_max', 'Pwr_P2_max_kW', 'tq_P2_max',
              'Pwr_P3_max_kW', 'tq_P3_max', 'Pwr_P4_max_kW', 'tq_P4_max', 'P4_DM']
for col in motor_cols:
    if col not in df.columns:
        df[col] = 0.0
    else:
        df[col] = df[col].fillna(0.0)

# --- DUAL MOTOR P4 MULTIPLIER ---
p4_multiplier = np.where(df['P4_DM'] == 1, 2.0, 1.0)
actual_pwr_p4 = df['Pwr_P4_max_kW'] * p4_multiplier
actual_tq_p4 = df['tq_P4_max'] * p4_multiplier

# Total System Calculations
df['Total_Pwr_kW'] = df['Pwr_ICE_max_kW'] + df['Pwr_P0_max_kW'] + df['Pwr_P2_max_kW'] + df[
    'Pwr_P3_max_kW'] + actual_pwr_p4
df['Total_Tq_max'] = df['tq_ICE_max'] + df['tq_P0_max'] + df['tq_P2_max'] + df['tq_P3_max'] + actual_tq_p4
df['Sys_PW_ratio'] = df['Total_Pwr_kW'] / df['m_curb']
df['Sys_TW_ratio'] = df['Total_Tq_max'] / df['m_curb']

# Topological Torque Routing
tq_through_gearbox = (df['tq_ICE_max'] + df['tq_P0_max'] + df['tq_P2_max']) * df['GR_launch']
tq_through_final = df['tq_P3_max'] * df['iAG']
tq_through_p4axle = actual_tq_p4 * df['i_ges_P4']

df['Tq_wheel_launch_total'] = tq_through_gearbox + tq_through_final + tq_through_p4axle
df['AWD_factor'] = df['AWD'].apply(lambda x: 1.0 if x >= 1 else 0.6)
df['Eff_acc_launch_total'] = df['Tq_wheel_launch_total'] * df['AWD_factor'] / df['m_curb']

df['shift_time_penalty'] = (df['No_Gears'] - 1) * df['shiftDelay']
df['shift_penalty_ratio'] = df['shiftDelay'] / df['No_Gears']
df['Drag_to_SysPower'] = df['A_front'] / df['Total_Pwr_kW']
df['Drag_power_index_sys'] = df['A_front'] * df['m_curb'] / df['Total_Pwr_kW']

# Extended Physics (S5)
df['GR_mid'] = df['GR_2nd'] * df['GR_3rd'] * df['iAG']
df['speed_at_2nd'] = df['n_ICE_max'] / (df['GR_2nd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['speed_at_3rd'] = df['n_ICE_max'] / (df['GR_3rd'] * df['iAG']) * (np.pi / 30) * df['r_wheel']
df['v_max_theoretical'] = df['n_ICE_max'] / df['GR_topspeed'] * (np.pi / 30) * df['r_wheel']
df['v_1st_gear_max'] = df['n_ICE_max'] / df['GR_launch'] * (np.pi / 30) * df['r_wheel']

# ─────────────────────────────────────────────────────────────────────────────
# 3. FEATURE SETS & SANITIZATION
# ─────────────────────────────────────────────────────────────────────────────
# Included P4_DM to flag torque vectoring capabilities
FEATURES_BASE_HYB = [
    'HM_VA', 'AWD', 'iAG', 'm_curb', 'Wheelbase', 'No_Gears', 'n_ICE_max',
    'GR_1st', 'GR_last', 'GR_spread', 'GR_step_geo', 'GR_launch', 'GR_topspeed',
    'r_wheel', 'A_front', 'shiftDelay', 'shift_time_penalty',
    'Total_Pwr_kW', 'Total_Tq_max', 'Sys_PW_ratio', 'Sys_TW_ratio',
    'Tq_wheel_launch_total', 'Pwr_P0_max_kW', 'Pwr_P2_max_kW', 'Pwr_P3_max_kW',
    'Pwr_P4_max_kW', 'i_ges_P4', 'P4_DM'
]

FEATURES_EXT_HYB = FEATURES_BASE_HYB + [
    'GR_mid', 'speed_at_2nd', 'speed_at_3rd', 'AWD_factor', 'Eff_acc_launch_total',
    'v_max_theoretical', 'v_1st_gear_max', 'Drag_to_SysPower', 'Drag_power_index_sys'
]

TARGETS_CHAIN = [
    'SL_time_0_to_100', 'SL_time_80_to_120', 'SL_time_60_to_120',
    'SL_max_launch_acc', 'SL_max_speed', 'Avg_track_speed', 'Lap_Time',
    'Energy_elc_consumed', 'Energy_elc_recuperated'
]

KPI_ROUTING = {
    'SL_time_0_to_100': 'S1',
    'SL_time_80_to_120': 'S1',
    'SL_time_60_to_120': 'S3',
    'SL_max_launch_acc': 'S3',
    'SL_max_speed': 'S5',
    'Avg_track_speed': 'S1',
    'Lap_Time': 'S1',
    'Energy_elc_consumed': 'S3',  # Prioritizing Stack for Energy
    'Energy_elc_recuperated': 'S3',  # Prioritizing Stack for Energy
    'SL_time_0_to_200': 'S1',
}

df.replace([np.inf, -np.inf], np.nan, inplace=True)
df['can_reach_200'] = (df['SL_time_0_to_200'] > 0).astype(int)
df = df.dropna(subset=FEATURES_EXT_HYB + TARGETS_CHAIN + ['SL_time_0_to_200']).reset_index(drop=True)

R2_THRESHOLD = 0.95
Y = df[TARGETS_CHAIN].values.astype(float)
y_200 = df['SL_time_0_to_200'].values.astype(float)
y_can = df['can_reach_200'].values

idx_tr, idx_te = train_test_split(np.arange(len(df)), test_size=0.2, random_state=42)

Y_tr, Y_te = Y[idx_tr], Y[idx_te]
X_b_tr, X_b_te = df[FEATURES_BASE_HYB].values[idx_tr], df[FEATURES_BASE_HYB].values[idx_te]
X_e_tr, X_e_te = df[FEATURES_EXT_HYB].values[idx_tr], df[FEATURES_EXT_HYB].values[idx_te]
ycan_tr, ycan_te = y_can[idx_tr], y_can[idx_te]
y200_tr, y200_te = y_200[idx_tr], y_200[idx_te]

# ─────────────────────────────────────────────────────────────────────────────
# 4. OPTUNA DYNAMIC OVERRIDES
# ─────────────────────────────────────────────────────────────────────────────
TUNED_XGB_OVERRIDES = {
    'SL_time_0_to_100': {
        'n_estimators': 1182, 'learning_rate': 0.04902021598341908, 'max_depth': 12,
        'subsample': 0.7532571638375523, 'colsample_bytree': 0.5651530596008407,
        'min_child_weight': 2, 'reg_alpha': 0.04341832406552826, 'reg_lambda': 0.26491452587952036,
        'gamma': 0.08629804396539931
    },
    'SL_max_launch_acc': {
        'n_estimators': 678, 'learning_rate': 0.028244249368324575, 'max_depth': 11,
        'subsample': 0.8945089480134938, 'colsample_bytree': 0.9889092171039257,
        'min_child_weight': 6, 'reg_alpha': 0.027716506721210666, 'reg_lambda': 0.7891940742475069,
        'gamma': 0.06301560914967197
    },
    'SL_max_speed': {
        'n_estimators': 494, 'learning_rate': 0.04348661303922218, 'max_depth': 8,
        'subsample': 0.6001770113937767, 'colsample_bytree': 0.7811086054976368,
        'min_child_weight': 2, 'reg_alpha': 0.016129792053006388, 'reg_lambda': 4.848861333242017,
        'gamma': 0.28720243351723973
    }
}


def get_xgb_params(kpi_name, default_params):
    params = default_params.copy()
    if kpi_name in TUNED_XGB_OVERRIDES:
        params.update(TUNED_XGB_OVERRIDES[kpi_name])
    return params


def build_xgb_s1(kpi_name):
    defaults = {'n_estimators': 800, 'learning_rate': 0.03, 'max_depth': 7, 'subsample': 0.85, 'colsample_bytree': 0.8,
                'min_child_weight': 2, 'reg_alpha': 0.1, 'reg_lambda': 1.0}
    params = get_xgb_params(kpi_name, defaults)
    return XGBRegressor(**params, random_state=42, n_jobs=-1, verbosity=0)


def build_stacking_s3(kpi_name):
    xgb_defaults = {'n_estimators': 1000, 'learning_rate': 0.02, 'max_depth': 8, 'subsample': 0.85,
                    'colsample_bytree': 0.75, 'min_child_weight': 2, 'reg_alpha': 0.05, 'reg_lambda': 1.5, 'gamma': 0.1}
    xgb_params = get_xgb_params(kpi_name, xgb_defaults)

    return StackingRegressor(
        estimators=[
            ('xgb', XGBRegressor(**xgb_params, random_state=42, n_jobs=-1, verbosity=0)),
            ('lgb', lgb.LGBMRegressor(n_estimators=1000, learning_rate=0.02, num_leaves=63, min_child_samples=10,
                                      subsample=0.85, colsample_bytree=0.75, reg_alpha=0.05, reg_lambda=1.5,
                                      random_state=42, n_jobs=-1, verbose=-1)),
            ('rf', RandomForestRegressor(n_estimators=400, max_depth=15, min_samples_leaf=2, max_features=0.7,
                                         random_state=42, n_jobs=-1)),
        ],
        final_estimator=Ridge(alpha=1.0), cv=5, n_jobs=-1, passthrough=True
    )


def build_xgb_s5(kpi_name):
    defaults = {'n_estimators': 800, 'learning_rate': 0.03, 'max_depth': 7, 'subsample': 0.85, 'colsample_bytree': 0.8,
                'min_child_weight': 2, 'reg_alpha': 0.1, 'reg_lambda': 1.0}
    params = get_xgb_params(kpi_name, defaults)
    return XGBRegressor(**params, random_state=42, n_jobs=-1, verbosity=0)


# ─────────────────────────────────────────────────────────────────────────────
# 5. CHAIN RUNNER
# ─────────────────────────────────────────────────────────────────────────────
def run_full_chain(builder_func, X_tr_base, X_te_base, track_name):
    print(f'\n{"═" * 85}\n {track_name}  ({X_tr_base.shape[1]} features)\n{"═" * 85}')
    gates, models, results = {}, {}, {}
    X_tr_aug, X_te_aug = X_tr_base.copy(), X_te_base.copy()

    for i, kpi in enumerate(TARGETS_CHAIN):
        m_stand = builder_func(kpi)
        m_stand.fit(X_tr_base, Y_tr[:, i])
        r2_stand = r2_score(Y_te[:, i], m_stand.predict(X_te_base))
        gates[kpi] = r2_stand >= R2_THRESHOLD

        m_chain = builder_func(kpi)
        m_chain.fit(X_tr_aug, Y_tr[:, i])
        yp = m_chain.predict(X_te_aug)
        r2 = r2_score(Y_te[:, i], yp)
        mae = mean_absolute_error(Y_te[:, i], yp)
        rmse = np.sqrt(mean_squared_error(Y_te[:, i], yp))
        mape = mean_absolute_percentage_error(Y_te[:, i], yp)

        models[kpi], results[kpi] = m_chain, {'R2': r2, 'MAE': mae, 'RMSE': rmse, 'MAPE': mape}
        print(f'  {kpi:<26} Gate: {"PASS" if gates[kpi] else "TUNE"}  R²={r2:.4f}  MAE={mae:.4f}  RMSE={rmse:.4f}  MAPE={mape:.4f}')

        if gates[kpi]:
            X_tr_aug = np.hstack([X_tr_aug, Y_tr[:, i].reshape(-1, 1)])
            X_te_aug = np.hstack([X_te_aug, yp.reshape(-1, 1)])

    return models, gates, results


# ─────────────────────────────────────────────────────────────────────────────
# 6. TRAIN THREE TRACKS & FINAL ROUTING
# ─────────────────────────────────────────────────────────────────────────────
s1_models, s1_gates, s1_res = run_full_chain(build_xgb_s1, X_b_tr, X_b_te, 'TRACK S1 — XGBoost')
s3_models, s3_gates, s3_res = run_full_chain(build_stacking_s3, X_b_tr, X_b_te, 'TRACK S3 — Stacking')
s5_models, s5_gates, s5_res = run_full_chain(build_xgb_s5, X_e_tr, X_e_te, 'TRACK S5 — XGBoost (Extended)')

print(f'\n{"═" * 85}\n TRACK S1 — 0_to_200 Two-Stage\n{"═" * 85}')
clf200 = GradientBoostingClassifier(n_estimators=300, max_depth=5, learning_rate=0.05, random_state=42)
clf200.fit(X_b_tr, ycan_tr)
acc = accuracy_score(ycan_te, clf200.predict(X_b_te))

mask_tr, mask_te = ycan_tr == 1, ycan_te == 1
reg200 = build_xgb_s1('SL_time_0_to_200')
reg200.fit(X_b_tr[mask_tr], y200_tr[mask_tr])
yp_200 = reg200.predict(X_b_te[mask_te])

r2_200 = r2_score(y200_te[mask_te], yp_200)
mae_200 = mean_absolute_error(y200_te[mask_te], yp_200)
rmse_200 = np.sqrt(mean_squared_error(y200_te[mask_te], yp_200))
mape_200 = mean_absolute_percentage_error(y200_te[mask_te], yp_200)

print(f'  Classifier  Acc={acc:.4f}  |  Regressor  R²={r2_200:.4f}  MAE={mae_200:.4f} s  RMSE={rmse_200:.4f} s  MAPE={mape_200:.4f}')

print(f'\n{"═" * 95}\n FINAL — Hybrid Triple-Track Oracle\n{"═" * 95}')
print(f'  {"KPI":<26} {"Branch":>7}  {"R²":>7}  {"MAE":>9}  {"RMSE":>9}  {"MAPE":>9}')
print(f'  {"-" * 75}')
for kpi in TARGETS_CHAIN:
    route = KPI_ROUTING[kpi]
    res = s1_res if route == 'S1' else (s3_res if route == 'S3' else s5_res)
    print(f'  {kpi:<26} {route:>7}  {res[kpi]["R2"]:>7.4f}  {res[kpi]["MAE"]:>9.4f}  {res[kpi]["RMSE"]:>9.4f}  {res[kpi]["MAPE"]:>9.4f}')
print(f'  {"SL_time_0_to_200":<26} {"S1":>7}  {r2_200:>7.4f}  {mae_200:>9.4f}  {rmse_200:>9.4f}  {mape_200:>9.4f}')

artifacts = {
    'strategy': 'Triple_Track_Oracle_Hybrid_Final',
    'features_base': FEATURES_BASE_HYB,
    'features_ext': FEATURES_EXT_HYB,
    'targets_chain': TARGETS_CHAIN,
    'routing': KPI_ROUTING,
    's1_models': s1_models, 's1_gates': s1_gates,
    's3_models': s3_models, 's3_gates': s3_gates,
    's5_models': s5_models, 's5_gates': s5_gates,
    'clf200': clf200, 'reg200': reg200,
    'r2_200': r2_200, 'mae_200': mae_200,
    'rmse_200': rmse_200, 'mape_200': mape_200
}
joblib.dump(artifacts, 'surrogate_hybrid_oracle.pkl')
print(f'\n✔ Saved → surrogate_hybrid_oracle.pkl')