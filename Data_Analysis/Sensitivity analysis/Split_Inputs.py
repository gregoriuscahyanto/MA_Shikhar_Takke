import pandas as pd
import numpy as np
import re

# ── Load files ────────────────────────────────────────────────────────────────
df_out = pd.read_excel('Final_Simulation_Results_ALL_RUN_IDs.xlsx')
df_inp = pd.read_csv('fULLDoE_Inp_ICE.csv')

# ── Clean column names ────────────────────────────────────────────────────────
def clean_col(c):
    return re.sub(r'[\t\n\r\xa0]+', ' ', str(c)).strip()

df_out.columns = [clean_col(c) for c in df_out.columns]
df_inp.columns = [clean_col(c) for c in df_inp.columns]

# ── Merge on RUN_ID ───────────────────────────────────────────────────────────
df = pd.merge(df_inp, df_out[['RUN_ID', 'Actual_0_to_100', 'SL_time_0_to_100']], on='RUN_ID')

# ── Drop rows with missing KPI values ─────────────────────────────────────────
df = df.dropna(subset=['Actual_0_to_100', 'SL_time_0_to_100'])

# ── Compute error and pass/fail ───────────────────────────────────────────────
df['error']     = df['SL_time_0_to_100'] - df['Actual_0_to_100']
df['pct_error'] = (df['error'] / df['Actual_0_to_100']) * 100
df['pass_fail'] = np.where(df['pct_error'].abs() > 10, 'FAIL', 'PASS')

# ── Assign groups ─────────────────────────────────────────────────────────────
bins     = [0, 5, 7, 10, 13, 1000]
labels_g = ['G1_lt5s', 'G2_5to7s', 'G3_7to10s', 'G4_10to13s', 'G5_gt13s']
df['group'] = pd.cut(df['Actual_0_to_100'], bins=bins, labels=labels_g)

# ── Build cols_to_save dynamically ────────────────────────────────────────────
input_cols   = [c for c in df_inp.columns if c in df.columns]
output_cols  = ['Actual_0_to_100', 'SL_time_0_to_100',
                'error', 'pct_error', 'pass_fail', 'group']
cols_to_save = input_cols + output_cols

# ── Save one CSV per group ────────────────────────────────────────────────────
for g in labels_g:
    gdf = df[df['group'] == g][cols_to_save]
    gdf.to_csv(f'sensitivity_{g}.csv', index=False)
    pass_rate = (gdf['pass_fail'] == 'PASS').mean() * 100
    print(f"{g}: {len(gdf)} runs | Pass: {pass_rate:.1f}% | Mean error: {gdf['error'].mean():.2f}s")