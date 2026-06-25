# MA_Shikhar_Takke

Dieses Repository enthält das MATLAB-/Python-Projekt zur Sensitivitätsanalyse der Fahrzeug- und Antriebsstrangsimulation. Die Pipeline erzeugt Sensitivitäts- und Sweep-CSV-Dateien für Hybrid- und BEV-Konfigurationen, startet MATLAB/Simulink-Simulationen und wertet die Ergebnisdateien anschließend aus.

Auf dem bwUniCluster wird dieses Projekt typischerweise im Workspace `es_grcahyan-ws_grcahyan` ausgeführt. Die zugehörigen SLURM-Startskripte liegen im separaten Repository `bwunicluster_es_grcahyan`.

## Inhalt

| Pfad | Zweck |
| --- | --- |
| `run_sensitivity_pipeline.py` | Zentrale Python-Pipeline für Setup, Split/Sweep-Erzeugung, MATLAB-Start, Resume-Planung, Merge, Validierung und Analyse. |
| `requirements_sensitivity.txt` | Python-Abhängigkeiten für die Pipeline: `numpy`, `pandas`, `matplotlib`, `openpyxl`. |
| `Simulation_Model/DoE_main_sensitivity.m` | MATLAB-DoE-Runner für Hybrid- und BEV-Sweeps mit Checkpointing und Resume über `SWEEP_RUN_ID`. |
| `Data_Analysis/Sensitivity analysis/common_sensitivity.py` | Gemeinsame Funktionen für Datenimport, Gruppierung, Sweep-Erzeugung und Analyse. |
| `Data_Analysis/Sensitivity analysis/Hybrid/Sensitivity_Analysis_Hybrid.py` | Hybrid-spezifische Sensitivitätskonfiguration. |
| `Data_Analysis/Sensitivity analysis/BEV/Sensitivity_Analysis_BEV.py` | BEV-spezifische Sensitivitätskonfiguration. |
| `_alt/` | Ältere/alternative Pipeline-Versionen zur Referenz. |

## Voraussetzungen

- Python 3 mit `venv` und `pip`
- MATLAB mit Simulink
- Zugriff auf die benötigten Simulationsmodelle und Eingabedaten im Repository
- Für Clusterläufe: bwUniCluster-Workspace und das SLURM-Skript aus `bwunicluster_es_grcahyan`

Die Python-Abhängigkeiten werden bei einem Standardlauf automatisch in `.venv` installiert. Alternativ kann das Setup separat ausgeführt werden:

```bash
python run_sensitivity_pipeline.py setup-venv
```

## Lokaler Standardlauf

Aus dem Repository-Hauptverzeichnis:

```bash
python run_sensitivity_pipeline.py
```

Der Standardlauf erstellt bzw. verwendet `.venv`, erzeugt fehlende Sensitivitäts- und Sweep-Dateien, startet aber nur dann MATLAB automatisch, wenn die Pipeline entsprechend mit `--run-matlab` ausgeführt wird.

Für einen vollständigen lokalen Lauf inklusive MATLAB/Simulink:

```bash
python run_sensitivity_pipeline.py auto --powertrain both --run-matlab
```

Falls MATLAB nicht im `PATH` liegt:

```bash
python run_sensitivity_pipeline.py auto --powertrain both --run-matlab --matlab-exe "C:\Program Files\MATLAB\R2023b\bin\matlab.exe"
```

## Einzelne Pipeline-Schritte

### 1. CSVs vorbereiten

```bash
python run_sensitivity_pipeline.py pre-sim --powertrain both
```

Erzeugt Sensitivitäts- und Sweep-CSV-Dateien für `hybrid`, `bev` oder `both`.

### 2. MATLAB/Simulink-Sweeps ausführen

```bash
python run_sensitivity_pipeline.py matlab --powertrain both
```

Ohne SLURM-Array verarbeitet MATLAB jede Sweep-Datei komplett. Bei vorhandenen Ergebnisdateien setzt `DoE_main_sensitivity.m` über vorhandene `SWEEP_RUN_ID`s fort.

### 3. Ergebnisse mergen, validieren und analysieren

```bash
python run_sensitivity_pipeline.py post-sim --powertrain both
```

Dabei werden vorhandene finale Dateien, alte `*_taskXXX.xlsx`-Fragmente und neue `*_resume_*.xlsx`-Fragmente zusammengeführt. Bereits erfolgreich gemergte Task-/Resume-Fragmente werden anschließend gelöscht. Danach prüft die Pipeline, ob alle erwarteten `SWEEP_RUN_ID`s vorhanden sind, und startet die Analyse.

## Resume-Workflow für HPC-Läufe

Die Pipeline unterstützt einen gap-basierten Resume-Modus:

1. Vorhandene Ergebnisfragmente werden zuerst in finale Ergebnisdateien gemergt.
2. Die Pipeline vergleicht vorhandene `SWEEP_RUN_ID`s mit den Sweep-CSV-Dateien.
3. Nur fehlende Zeilen werden in kleine Pending-CSV-Chunks geschrieben.
4. MATLAB-Worker bearbeiten ausschließlich diese fehlenden Chunks.
5. Nach dem Abschluss werden die Fragmente erneut gemergt, validiert und analysiert.

Die manuelle Schrittfolge lautet:

```bash
python run_sensitivity_pipeline.py pre-sim --powertrain both
python run_sensitivity_pipeline.py plan-resume --powertrain both --plan-dir logs/sensitivity_current_plan --resume-chunk-size 10
python run_sensitivity_pipeline.py matlab-resume --powertrain both --plan-dir logs/sensitivity_current_plan
python run_sensitivity_pipeline.py post-sim --powertrain both
```

Auf dem bwUniCluster wird dieser Ablauf durch `run_sensitivity_pipeline_HPC.slurm` aus dem Repository `bwunicluster_es_grcahyan` automatisiert.

## Powertrain-Auswahl

Alle relevanten Befehle unterstützen:

```bash
--powertrain hybrid
--powertrain bev
--powertrain both
```

`both` ist der Standard und verarbeitet Hybrid und BEV nacheinander.

## Wichtige Ergebnisdateien

Typische Ergebnis- und Zwischendateien:

```text
Data_Analysis/Sensitivity analysis/Hybrid/sweep_hybrid_G*.csv
Data_Analysis/Sensitivity analysis/Hybrid/sweep_results_hybrid_G*.xlsx
Data_Analysis/Sensitivity analysis/BEV/sweep_bev_G*.csv
Data_Analysis/Sensitivity analysis/BEV/sweep_results_bev_G*.xlsx
logs/sensitivity_*/
```

Task- und Resume-Fragmente wie `sweep_results_*_task*.xlsx` und `sweep_results_*_resume_*.xlsx` sind temporär. Sie werden beim Merge eingelesen und danach automatisch gelöscht, sofern sie erfolgreich verarbeitet wurden.

## Git-Hinweise

Nicht ins Repository gehören insbesondere:

- `.venv/`
- `logs/`
- Simulink-Cache-Dateien wie `slprj/`, `*.slxc`, `*.slx.autosave`
- große temporäre MATLAB-/Simulationsergebnisse
- temporäre Sweep-Ergebnisfragmente `sweep_results_*_task*.xlsx` und `sweep_results_*_resume_*.xlsx`

## Typische Befehle

```bash
# Nur Python-Umgebung vorbereiten
python run_sensitivity_pipeline.py setup-venv

# CSVs erzeugen oder vorhandene wiederverwenden
python run_sensitivity_pipeline.py pre-sim --powertrain both

# MATLAB lokal starten
python run_sensitivity_pipeline.py matlab --powertrain both

# Ergebnisse zusammenführen und analysieren
python run_sensitivity_pipeline.py post-sim --powertrain both

# Alles lokal ausführen
python run_sensitivity_pipeline.py auto --powertrain both --run-matlab
```

## Troubleshooting

### MATLAB wird nicht gefunden

MATLAB entweder in den `PATH` aufnehmen oder explizit übergeben:

```bash
python run_sensitivity_pipeline.py matlab --matlab-exe "/path/to/matlab"
```

### Ergebnisdateien fehlen

Zuerst prüfen, ob die Sweep-CSV-Dateien vorhanden sind:

```bash
python run_sensitivity_pipeline.py pre-sim --powertrain both
```

Danach MATLAB-Simulationen erneut starten oder auf dem Cluster den Resume-Workflow verwenden.

### Analyse wird übersprungen

Die Analyse startet nur vollständig, wenn die erwarteten finalen Ergebnisdateien vorhanden und vollständig sind. Temporäre Task-/Resume-Fragmente zuerst mit `post-sim` mergen:

```bash
python run_sensitivity_pipeline.py post-sim --powertrain both
```

## Zusammenhang mit `bwunicluster_es_grcahyan`

Dieses Repository enthält den eigentlichen Projektcode. Das Repository `bwunicluster_es_grcahyan` enthält dagegen die SLURM-Dateien und Workspace-Helfer für den Clusterbetrieb. Für produktive HPC-Läufe wird im Cluster-Repo gestartet, die Ausführung wechselt dann in den bwUniCluster-Workspace dieses Projekts.
