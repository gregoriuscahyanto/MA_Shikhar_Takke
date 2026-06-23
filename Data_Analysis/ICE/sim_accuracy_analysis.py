#!/usr/bin/env python3
"""
Simulation 6.4 Accuracy Analysis
Generates pass rate chart, mean % error chart, and summary table.
Requires: pandas, openpyxl, plotly, kaleido
Install:  pip install pandas openpyxl plotly kaleido
Usage:    python sim_accuracy_analysis.py
          Place "NewActual_Simulation_Comparison-3.xlsx" in the same folder.
"""

import pandas as pd
import numpy as np
import plotly.graph_objects as go
import json
import os

# ── Config ──────────────────────────────────────────────────────────────────
XLSX_FILE  = "NewActual_Simulation_Comparison.xlsx"
OUT_DIR    = "output"
SIM_VER    = "6.4"          # change if you update the column name
TOLERANCE  = 0.10           # ±10 %
BINS       = [0, 5, 7, 10, 13, 20]
LABELS     = ["<5s", "5-7s", "7-10s", "10-13s", ">13s"]
# BINS       = [0, 5, 7, 9, 12, 14, 20]
# LABELS     = ["<5s", "5-7s", "7-9s", "9-12s", "12-14s", ">12s"]

os.makedirs(OUT_DIR, exist_ok=True)

# ── Load & clean ─────────────────────────────────────────────────────────────
df = pd.read_excel(XLSX_FILE)
sim_col = f"SL_time_0_to_100_{SIM_VER}"
pass_col = float(SIM_VER)          # column header stored as float in Excel

df_v = df.dropna(subset=["Actual 0 to 100", sim_col]).copy()
df_v["error_s"]   = df_v[sim_col] - df_v["Actual 0 to 100"]   # positive = sim slower
df_v["pct_err"]   = df_v["error_s"] / df_v["Actual 0 to 100"] * 100
df_v["pass"]      = df_v[pass_col].astype(int)
df_v["bucket"]    = pd.cut(df_v["Actual 0 to 100"], bins=BINS, labels=LABELS)

# ── Aggregate ────────────────────────────────────────────────────────────────
bstats = (
    df_v.groupby("bucket", observed=True)
        .agg(total=("pass","count"), passes=("pass","sum"), mean_err=("pct_err","mean"))
        .reset_index()
)
bstats["pass_rate"] = bstats["passes"] / bstats["total"] * 100

combo = (
    df_v.groupby(["bucket","AWD"], observed=True)
        .agg(total=("pass","count"), passes=("pass","sum"), mean_err=("pct_err","mean"))
        .reset_index()
)
combo["pass_rate"] = combo["passes"] / combo["total"] * 100

# ── Summary table ─────────────────────────────────────────────────────────────
overall_pass  = df_v["pass"].sum()
overall_total = len(df_v)

print("=" * 68)
print(f"  Simulation {SIM_VER} Accuracy Summary  (±{TOLERANCE*100:.0f}% tolerance)")
print("=" * 68)
print(f"  Overall: {overall_pass}/{overall_total} runs pass  ({overall_pass/overall_total*100:.1f}%)")
print("-" * 68)
print(f"  {'Bucket':<14} {'Total':>6} {'Pass':>6} {'PassRate':>9} {'MeanErr':>9} {'Issue'}")
print("-" * 68)
for _, r in bstats.iterrows():
    flag = ""
    if r["pass_rate"] < 60:
        flag = "⚠  LOW PASS RATE"
    elif abs(r["mean_err"]) > 10:
        flag = "⚠  BIAS OUTSIDE ±10%"
    print(f"  {str(r['bucket']):<14} {int(r['total']):>6} {int(r['passes']):>6} "
          f"{r['pass_rate']:>8.1f}%  {r['mean_err']:>+8.1f}%  {flag}")
print("-" * 68)

print("\n  AWD breakdown:")
for _, r in combo.iterrows():
    label = "AWD" if r["AWD"] == 1 else "2WD"
    print(f"    {str(r['bucket']):<10}  {label}  pass={r['pass_rate']:.0f}%  "
          f"mean_err={r['mean_err']:+.1f}%  (n={int(r['total'])})")

# ── Chart helpers ─────────────────────────────────────────────────────────────
COLORS = ["#6366f1", "#f97316"]   # indigo / orange

def save_meta(path, caption, description=""):
    with open(path + ".meta.json", "w") as f:
        json.dump({"caption": caption, "description": description}, f)

# ── Chart 1: Pass rate by bucket ──────────────────────────────────────────────
fig1 = go.Figure()
fig1.add_trace(go.Bar(
    x=bstats["bucket"].astype(str),
    y=bstats["pass_rate"],
    marker_color=COLORS[0],
    text=[f"{v:.0f}%" for v in bstats["pass_rate"]],
    textposition="outside",
))
fig1.add_hline(
    y=overall_pass / overall_total * 100,
    line_dash="dot", line_color="red",
    annotation_text=f"Overall {overall_pass/overall_total*100:.1f}%",
    annotation_position="top right",
)
fig1.update_xaxes(title_text="0-100 km/h Actual Time")
fig1.update_yaxes(title_text="Pass Rate (%)", range=[0, 112])
fig1.update_layout(
    title={
        "text": (
            f"Sim Pass Rate <br>"
            # f"Sim {SIM_VER}: Pass Rate Drops for Slow Cars (>13s)<br>"
            "<span style=\'font-size:16px;font-weight:normal;\'>"
            # "Only 32% pass for >13s vs 94% for 7-10s</span>"
        )
    },
    showlegend=False,
)
fig1.update_traces(cliponaxis=False)
out1 = os.path.join(OUT_DIR, "passrate_by_bucket.png")
fig1.write_image(out1)
save_meta(out1, f"Sim {SIM_VER}: Pass rate by 0-100 km/h bucket")
print(f"\n  Saved → {out1}")

# ── Chart 2: Mean % error by bucket & AWD ────────────────────────────────────
c2 = combo[combo["AWD"] == 0].set_index("bucket").reindex(LABELS).reset_index()
c1 = combo[combo["AWD"] == 1].set_index("bucket").reindex(LABELS).reset_index()

fig2 = go.Figure()
fig2.add_trace(go.Bar(
    x=c2["bucket"].astype(str), y=c2["mean_err"],
    name="2WD", marker_color=COLORS[0],
    text=[f"{v:+.1f}%" for v in c2["mean_err"]], textposition="outside",
))
fig2.add_trace(go.Bar(
    x=c1["bucket"].astype(str), y=c1["mean_err"],
    name="AWD", marker_color=COLORS[1],
    text=[f"{v:+.1f}%" for v in c1["mean_err"]], textposition="outside",
))
fig2.add_hline(y= 10, line_dash="dot", line_color="red",  annotation_text="+10% limit")
fig2.add_hline(y=-10, line_dash="dot", line_color="red",  annotation_text="-10% limit")
fig2.add_hline(y=  0, line_dash="solid", line_color="gray", line_width=1)
fig2.update_xaxes(title_text="0-100 km/h Actual Time")
fig2.update_yaxes(title_text="Mean % Error", range=[-32, 42])
fig2.update_layout(
    title={
        "text": (
            f"Sim Mean % Error — AWD Fast Cars & Slow Cars Out of Bounds<br>"
             # f"Sim {SIM_VER}: Mean % Error — AWD Fast Cars & Slow Cars Out of Bounds<br>"
            "<span style=\'font-size:16px;font-weight:normal;\'>"
            # "Positive = sim slower than actual | Negative = sim faster</span>"
        )
    },
    legend=dict(orientation="h", yanchor="bottom", y=1.05, xanchor="center", x=0.5),
    barmode="group",
)
fig2.update_traces(cliponaxis=False)
out2 = os.path.join(OUT_DIR, "mean_error_breakdown.png")
fig2.write_image(out2)
save_meta(out2, f"Sim {SIM_VER}: Mean % error by speed bucket and AWD vs 2WD")
print(f"  Saved → {out2}")
print("\nDone.")
