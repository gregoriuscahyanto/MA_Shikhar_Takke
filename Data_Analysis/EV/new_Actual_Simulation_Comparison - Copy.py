import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D

# Configuration
file_name = "Comparison_EV_Final_Simulation_Results_ALL_RUN_IDs.xlsx"
actual_col = "Actual 0 to 100"
error_col = "Faster than actual 2"
sim_col = "SL_time_0_to_100 2"

# DEFINE YOUR PERCENTAGE TOLERANCE HERE
tolerance_pct = 10.0  # 10% error limit

# Load the data
try:
    df = pd.read_excel(file_name)
except FileNotFoundError:
    raise FileNotFoundError(f"Cannot find '{file_name}'.")

# Verify ALL required columns exist
required_cols = [actual_col, error_col, sim_col]
missing_cols = [col for col in required_cols if col not in df.columns]
if missing_cols:
    raise ValueError(f"Missing required columns in your Excel file: {missing_cols}")

# Clean Data: drop any row missing the actual time, sim time, or error
df_clean = df.dropna(subset=[actual_col, error_col, sim_col]).copy()

# Sort by actual time so the tolerance cone draws cleanly from left to right
df_clean = df_clean.sort_values(by=actual_col)

# Calculate dynamic limits and pass/fail metrics
df_clean['Allowed Error'] = (tolerance_pct / 100) * df_clean[actual_col]
df_clean['Pass'] = df_clean[error_col].abs() <= df_clean['Allowed Error']

total_runs = len(df_clean)
passing_runs = df_clean['Pass'].sum()
pass_rate = (passing_runs / total_runs) * 100

print(f"Total Valid Runs Analysed: {total_runs}")
print(f"Runs within +/- {tolerance_pct}%: {passing_runs}")
print(f"Pass Rate: {pass_rate:.1f}%")

if pass_rate < 80:
    print(f"WARNING: Your model is failing the {tolerance_pct}% standard. Fix your math.")

# ─────────────────────────────────────────────
# FIGURE 1: Error Scatter + Histogram (original)
# ─────────────────────────────────────────────
fig1, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 6))

# --- PLOT 1: Scatter Plot with Percentage Cone ---
colors = ['green' if passed else 'red' for passed in df_clean['Pass']]

ax1.scatter(df_clean[actual_col], df_clean[error_col], c=colors, alpha=0.7, edgecolor='black')
ax1.axhline(y=0, color='black', linestyle='--', linewidth=1)

ax1.fill_between(df_clean[actual_col],
                 -df_clean['Allowed Error'],
                 df_clean['Allowed Error'],
                 color='green', alpha=0.1, label=f'Acceptable Range (+/- {tolerance_pct}%)')

ax1.set_title("Simulation Error vs Actual Time (Percentage Limit)", fontweight='bold')
ax1.set_xlabel("Actual 0 to 100 km/h Time (seconds)")
ax1.set_ylabel("Absolute Error: Faster than actual (seconds)")
ax1.grid(True, linestyle='--', alpha=0.6)
ax1.legend()

# --- PLOT 2: Histogram of PERCENTAGE Errors ---
df_clean['Percentage Error'] = (df_clean[error_col] / df_clean[actual_col]) * 100

counts, bins, patches = ax2.hist(df_clean['Percentage Error'], bins=15, edgecolor='black', alpha=0.7)

for patch, left_edge, right_edge in zip(patches, bins[:-1], bins[1:]):
    if right_edge < -tolerance_pct or left_edge > tolerance_pct:
        patch.set_facecolor('red')
    else:
        patch.set_facecolor('green')

ax2.axvline(-tolerance_pct, color='red', linestyle='dashed', linewidth=2)
ax2.axvline(tolerance_pct, color='red', linestyle='dashed', linewidth=2,
            label=f'Tolerance Limit (+/- {tolerance_pct}%)')

stats_text = (f"Total Valid Runs: {total_runs}\n"
              f"Pass: {passing_runs} ({pass_rate:.1f}%)\n"
              f"Fail: {total_runs - passing_runs}")
ax2.text(0.05, 0.95, stats_text, transform=ax2.transAxes, fontsize=12,
         verticalalignment='top', bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

ax2.set_title("Distribution of Percentage Errors", fontweight='bold')
ax2.set_xlabel("Percentage Error (%)")
ax2.set_ylabel("Number of Runs")
ax2.grid(True, linestyle='--', alpha=0.6)
ax2.legend()

fig1.tight_layout()
fig1.savefig("error_analysis_percentage_xxxxxxxxxxxx.png", dpi=300, bbox_inches='tight')
print("Saved Figure 1.")

# ─────────────────────────────────────────────
# FIGURE 2: Actual vs Simulated 0-to-100 Time
# ─────────────────────────────────────────────
fig2, ax3 = plt.subplots(figsize=(8, 8))

# Colours: teal for pass, coral/orange for fail — easy to distinguish
COLOR_PASS = '#2ecc71'   # emerald green
COLOR_FAIL = '#e67e22'   # warm orange

colors_p3 = [COLOR_PASS if passed else COLOR_FAIL for passed in df_clean['Pass']]

ax3.scatter(df_clean[actual_col], df_clean[sim_col],
            c=colors_p3, alpha=0.85, edgecolor='white', linewidths=0.6,
            s=70, zorder=3)

# Reference line range
val_min = min(df_clean[actual_col].min(), df_clean[sim_col].min()) * 0.93
val_max = max(df_clean[actual_col].max(), df_clean[sim_col].max()) * 1.05
ref_line = np.linspace(val_min, val_max, 300)

# Perfect match line — thick dotted dark navy
ax3.plot(ref_line, ref_line,
         color='#2c3e50', linestyle='dotted', linewidth=2.5,
         label='Perfect Match (y = x)', zorder=4)

# Tolerance lines — dashed steel blue
ax3.plot(ref_line, ref_line * (1 + tolerance_pct / 100),
         color='#2980b9', linestyle='--', linewidth=1.8,
         label=f'+{tolerance_pct:.0f}% Tolerance', zorder=4)
ax3.plot(ref_line, ref_line * (1 - tolerance_pct / 100),
         color='#2980b9', linestyle='--', linewidth=1.8,
         label=f'-{tolerance_pct:.0f}% Tolerance', zorder=4)

# Shaded tolerance band
ax3.fill_between(ref_line,
                 ref_line * (1 - tolerance_pct / 100),
                 ref_line * (1 + tolerance_pct / 100),
                 color='#2980b9', alpha=0.08, zorder=2)

# Custom legend
legend_elements = [
    Line2D([0], [0], marker='o', color='w', markerfacecolor=COLOR_PASS,
           markeredgecolor='gray', markersize=10,
           label=f'Within {tolerance_pct:.0f}% Tolerance  ({passing_runs} runs)'),
    Line2D([0], [0], marker='o', color='w', markerfacecolor=COLOR_FAIL,
           markeredgecolor='gray', markersize=10,
           label=f'Outside {tolerance_pct:.0f}% Tolerance  ({total_runs - passing_runs} runs)'),
    Line2D([0], [0], color='#2c3e50', linestyle='dotted', linewidth=2.5,
           label='Perfect Match (y = x)'),
    Line2D([0], [0], color='#2980b9', linestyle='--', linewidth=1.8,
           label=f'±{tolerance_pct:.0f}% Tolerance Bands'),
]
ax3.legend(handles=legend_elements, fontsize=10, loc='upper left',
           framealpha=0.9, edgecolor='lightgray')

# Stats annotation inside plot
stats_text = f"Pass Rate: {pass_rate:.1f}%\n({passing_runs} / {total_runs} runs)"
ax3.text(0.97, 0.05, stats_text, transform=ax3.transAxes, fontsize=11,
         ha='right', va='bottom',
         bbox=dict(boxstyle='round,pad=0.5', facecolor='white', edgecolor='lightgray', alpha=0.9))

ax3.set_title("Actual vs Simulated 0–100 km/h Time", fontweight='bold', fontsize=14, pad=12)
ax3.set_xlabel("Actual 0 to 100 km/h Time (seconds)", fontsize=12)
ax3.set_ylabel("Simulated 0 to 100 km/h Time (seconds)", fontsize=12)
ax3.set_xlim(val_min, val_max)
ax3.set_ylim(val_min, val_max)
ax3.set_aspect('equal', adjustable='box')
ax3.grid(True, linestyle='--', alpha=0.4, color='gray')
ax3.set_facecolor('#f9f9f9')

fig2.tight_layout()
fig2.savefig("actual_vs_simulated_0to100.png", dpi=300, bbox_inches='tight')
print("Saved Figure 2.")
