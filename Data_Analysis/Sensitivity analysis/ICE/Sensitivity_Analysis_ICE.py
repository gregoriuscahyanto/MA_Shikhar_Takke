from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common_sensitivity import PipelineConfig, run_cli

ICE_SCALE_COLS = ["tq_ICE_max", "tq_ICE_idle", "Pwr_ICE_max_kW"]
GEAR_SCALE_COLS = ["iAG"]

CONFIG = PipelineConfig(
    powertrain="ice",
    input_candidates=[
        "fULLDoE_Inp_ICE.csv",
        "FULLDoE_Inp_ICE.csv",
        "FullDoE_Inp_ICE.csv",
        "DoE_Inp_ICE.csv",
        "Simulation_Model/fULLDoE_Inp_ICE.csv",
        "Simulation_Model/FULLDoE_Inp_ICE.csv",
        "Simulation_Model/DoE_Inp_ICE.csv",
        "Simulation_Vehicle_Data/fULLDoE_Inp_ICE.csv",
        "Simulation_Vehicle_Data/FULLDoE_Inp_ICE.csv",
        "Simulation_Vehicle_Data/DoE_Inp_ICE.csv",
        "Surrogate_Model/ICE Powertrain/fULLDoE_Inp_ICE.csv",
        "Surrogate_Model/ICE Powertrain/FULLDoE_Inp_ICE.csv",
        "Surrogate_Model/ICE Powertrain/DoE_Inp_ICE.csv",
    ],
    sweep_config={
        "G1_lt5s": {
            "ice_power_scale": [1.00, 1.05, 1.10, 1.15, 1.20],
            "gear_scale": [0.98, 1.00, 1.02, 1.04],
            "shift_delta": [0.0, -0.1, -0.2, -0.3],
            "mass_scale": [1.00],
        },
        "G2_5to7s": {
            "ice_power_scale": [1.00, 1.05, 1.10, 1.15],
            "gear_scale": [0.98, 1.00, 1.02, 1.04],
            "shift_delta": [0.0, -0.1, -0.2, -0.3],
            "mass_scale": [1.00],
        },
        "G3_7to10s": {
            "ice_power_scale": [0.95, 1.00, 1.05],
            "gear_scale": [0.98, 1.00, 1.02],
            "shift_delta": [0.0, 0.1, 0.2],
            "mass_scale": [1.00],
        },
        "G4_10to13s": {
            "ice_power_scale": [0.80, 0.85, 0.90, 0.95, 1.00],
            "gear_scale": [0.94, 0.97, 1.00],
            "shift_delta": [0.0, 0.1, 0.2, 0.3],
            "mass_scale": [1.00, 1.02, 1.04, 1.06],
        },
        "G5_gt13s": {
            "ice_power_scale": [0.60, 0.65, 0.70, 0.75, 0.80],
            "gear_scale": [0.90, 0.95, 1.00],
            "shift_delta": [0.0, 0.1, 0.2, 0.3],
            "mass_scale": [1.00, 1.03, 1.06, 1.09],
        },
    },
    sweep_params=["ice_power_scale", "gear_scale", "shift_delta", "mass_scale"],
    changed_params=ICE_SCALE_COLS + GEAR_SCALE_COLS + ["shiftDelay", "m_curb"],
    scale_groups={
        "ice_power_scale": ICE_SCALE_COLS,
        "gear_scale": GEAR_SCALE_COLS,
    },
    # ICE rows: combustion vehicle, not BEV, not hybrid.
    # If one of these columns is missing, common_sensitivity keeps the rows.
    filter_col_equals={"VM": 1, "EV": 0, "Hy": 0},
    default_output_dir="ice_sensitivity_results",
)


if __name__ == "__main__":
    run_cli(CONFIG)
