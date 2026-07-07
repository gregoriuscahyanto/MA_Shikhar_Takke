#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Erzeugt einen Actual-vs.-Simulation-Plot fuer 0-100 km/h Zeiten
mit +/-10 %-Fenster aus DoE_Results_Comparison.xlsx.

Beispiel:
    python plot_actual_vs_sim_0_100.py DoE_Results_Comparison.xlsx

Optional:
    python plot_actual_vs_sim_0_100.py DoE_Results_Comparison.xlsx --output actual_vs_sim_0_100.png
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt


ACTUAL_COL_CANDIDATES = [
    "Actual_0_to_100_s",
    "Actual 0-100 km/h [s]",
    "Actual_0_100_s",
    "actual_0_to_100_s",
]

SIM_COL_CANDIDATES = [
    "SL_time_0_to_100",
    "Sim_0_to_100_s",
    "Simulation_0_to_100_s",
    "simuliert_0_to_100_s",
]


def pick_column(columns: Iterable[str], candidates: list[str], label: str) -> str:
    """Findet eine passende Spalte anhand einer Kandidatenliste."""
    columns_list = list(columns)
    normalized = {str(c).strip().lower(): c for c in columns_list}

    for candidate in candidates:
        key = candidate.strip().lower()
        if key in normalized:
            return normalized[key]

    raise KeyError(
        f"Keine passende {label}-Spalte gefunden.\n"
        f"Gesucht: {candidates}\n"
        f"Vorhanden: {columns_list}"
    )


def read_comparison_data(
    excel_path: Path,
    sheet_name: str | None,
    actual_col: str | None,
    sim_col: str | None,
) -> tuple[pd.DataFrame, str, str, str]:
    """Liest Excel und gibt DataFrame sowie genutzte Spalten zurueck."""
    xls = pd.ExcelFile(excel_path)

    if sheet_name is None:
        sheet_name = "Comparison" if "Comparison" in xls.sheet_names else xls.sheet_names[0]

    df = pd.read_excel(excel_path, sheet_name=sheet_name)

    if actual_col is None:
        actual_col = pick_column(df.columns, ACTUAL_COL_CANDIDATES, "Actual")
    if sim_col is None:
        sim_col = pick_column(df.columns, SIM_COL_CANDIDATES, "Simulation")

    return df, sheet_name, actual_col, sim_col


def create_plot(
    df: pd.DataFrame,
    actual_col: str,
    sim_col: str,
    output_path: Path,
    zoom_max: float = 30.0,
    tolerance: float = 0.10,
    dpi: int = 180,
) -> None:
    """Erstellt den Actual-vs.-Simulation-Plot."""
    actual = pd.to_numeric(df[actual_col], errors="coerce")
    sim = pd.to_numeric(df[sim_col], errors="coerce")

    valid = (
        actual.notna()
        & sim.notna()
        & np.isfinite(actual)
        & np.isfinite(sim)
        & (actual > 0)
        & (sim > 0)
    )

    # Zaehler nur im sichtbaren Zoom-Fenster, analog zum Screenshot.
    in_zoom = valid & (actual <= zoom_max) & (sim <= zoom_max)
    lower = (1.0 - tolerance) * actual
    upper = (1.0 + tolerance) * actual
    inside_tol = in_zoom & (sim >= lower) & (sim <= upper)
    outside_tol = in_zoom & ~inside_tol

    n_zoom = int(in_zoom.sum())
    n_inside = int(inside_tol.sum())
    pct_inside = 100.0 * n_inside / n_zoom if n_zoom else 0.0

    fig, ax = plt.subplots(figsize=(10, 7))

    # Reihenfolge wie im Screenshot: erst ausserhalb, dann innerhalb darueber.
    ax.scatter(
        actual[outside_tol],
        sim[outside_tol],
        s=16,
        alpha=0.55,
        label="au\u00dferhalb \u00b110 %",
    )
    ax.scatter(
        actual[inside_tol],
        sim[inside_tol],
        s=16,
        alpha=0.70,
        label="innerhalb \u00b110 %",
    )

    x_line = np.linspace(0.0, zoom_max, 300)
    ax.plot(x_line, x_line, linewidth=2.0, label="Ideal: sim = actual")
    ax.plot(
        x_line,
        (1.0 - tolerance) * x_line,
        linestyle="--",
        linewidth=1.5,
        label="-10 %",
    )
    ax.plot(
        x_line,
        (1.0 + tolerance) * x_line,
        linestyle="--",
        linewidth=1.5,
        label="+10 %",
    )

    ax.set_xlim(0, zoom_max)
    ax.set_ylim(0, zoom_max)
    ax.set_xlabel("Actual 0-100 km/h [s]")
    ax.set_ylabel("Simuliert 0-100 km/h [s]")
    ax.set_title(
        "Actual vs. Simulation 0-100 km/h mit \u00b110 %-Fenster "
        f"(Zoom 0-{zoom_max:g} s)\n"
        f"{n_inside}/{n_zoom} Punkte im Zoom innerhalb des Fensters "
        f"({pct_inside:.1f} %)"
    )
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=dpi)
    plt.close(fig)

    print(f"Plot gespeichert: {output_path}")
    print(f"Gueltige Punkte: {int(valid.sum())}")
    print(f"Punkte im Zoom: {n_zoom}")
    print(f"Innerhalb +/-{tolerance * 100:.0f} % im Zoom: {n_inside} ({pct_inside:.1f} %)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Actual-vs.-Simulation-Plot 0-100 km/h aus Excel erstellen."
    )
    parser.add_argument(
        "excel_path",
        nargs="?",
        default="DoE_Results_Comparison.xlsx",
        help="Pfad zur Excel-Datei. Default: DoE_Results_Comparison.xlsx",
    )
    parser.add_argument(
        "--sheet",
        default=None,
        help="Sheetname. Default: Comparison, falls vorhanden, sonst erstes Sheet.",
    )
    parser.add_argument(
        "--actual-col",
        default=None,
        help="Spaltenname fuer Actual 0-100. Default: automatische Erkennung.",
    )
    parser.add_argument(
        "--sim-col",
        default=None,
        help="Spaltenname fuer Simulation 0-100. Default: automatische Erkennung.",
    )
    parser.add_argument(
        "--output",
        default="actual_vs_sim_0_100.png",
        help="Ausgabedatei fuer den Plot. Default: actual_vs_sim_0_100.png",
    )
    parser.add_argument(
        "--zoom-max",
        type=float,
        default=30.0,
        help="Maximaler Achsenwert fuer x und y. Default: 30",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=0.10,
        help="Toleranzfenster als Anteil. Default: 0.10 fuer +/-10 %.",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=180,
        help="Aufloesung der PNG-Datei. Default: 180",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    excel_path = Path(args.excel_path)
    output_path = Path(args.output)

    df, sheet_name, actual_col, sim_col = read_comparison_data(
        excel_path=excel_path,
        sheet_name=args.sheet,
        actual_col=args.actual_col,
        sim_col=args.sim_col,
    )

    print(f"Excel: {excel_path}")
    print(f"Sheet: {sheet_name}")
    print(f"Actual-Spalte: {actual_col}")
    print(f"Simulations-Spalte: {sim_col}")

    create_plot(
        df=df,
        actual_col=actual_col,
        sim_col=sim_col,
        output_path=output_path,
        zoom_max=args.zoom_max,
        tolerance=args.tolerance,
        dpi=args.dpi,
    )


if __name__ == "__main__":
    main()
