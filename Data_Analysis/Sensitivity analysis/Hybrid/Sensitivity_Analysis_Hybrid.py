from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common_sensitivity import PipelineConfig, run_cli

ICE_SCALE_COLS = ["tq_ICE_max", "tq_ICE_idle", "Pwr_ICE_max_kW"]
EM_SCALE_COLS = [
    "tq_P0_max", "Pwr_P0_max_kW",
    "tq_P2_max", "Pwr_P2_max_kW",
    "tq_P3_max", "Pwr_P3_max_kW",
    "tq_P4_max", "Pwr_P4_max_kW",
]
BATTERY_SCALE_COLS = ["Cell_I_max_dis"]

CONFIG = PipelineConfig(
    powertrain="hybrid",
    input_candidates=[
        "DoE_Inp_Hybrid.csv",
        "Simulation_Model/DoE_Inp_Hybrid.csv",
        "Simulation_Vehicle_Data/DoE_Inp_Hybrid.csv",
        "Surrogate_Model/Hybrid Powertrain/DoE_Inp_Hybrid.csv",
    ],
    sweep_config={
        "G1_lt5s": {"hyb_power_scale": [1.00, 1.05, 1.10, 1.15, 1.20], "shift_delta": [0.0, -0.1, -0.2, -0.3], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
        "G2_5to7s": {"hyb_power_scale": [1.00, 1.05, 1.10, 1.15], "shift_delta": [0.0, -0.1, -0.2, -0.3], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
        "G3_7to10s": {"hyb_power_scale": [0.95, 1.00, 1.05], "shift_delta": [0.0, 0.1, 0.2], "mass_scale": [1.00], "bat_dis_scale": [1.00]},
        "G4_10to13s": {"hyb_power_scale": [0.80, 0.85, 0.90, 0.95, 1.00], "shift_delta": [0.0, 0.1, 0.2, 0.3], "mass_scale": [1.00, 1.02, 1.04, 1.06], "bat_dis_scale": [0.95, 1.00]},
        "G5_gt13s": {"hyb_power_scale": [0.60, 0.65, 0.70, 0.75, 0.80], "shift_delta": [0.0, 0.1, 0.2, 0.3], "mass_scale": [1.00, 1.03, 1.06, 1.09], "bat_dis_scale": [0.90, 1.00]},
    },
    sweep_params=["hyb_power_scale", "shift_delta", "mass_scale", "bat_dis_scale"],
    changed_params=ICE_SCALE_COLS + EM_SCALE_COLS + ["shiftDelay", "m_curb", "Cell_I_max_dis"],
    scale_groups={
        "hyb_power_scale": ICE_SCALE_COLS + EM_SCALE_COLS,
        "bat_dis_scale": BATTERY_SCALE_COLS,
    },
    filter_col_equals={"Hy": 1, "EV": 0},
    default_output_dir="hybrid_sensitivity_results",
)


if __name__ == "__main__":
    run_cli(CONFIG)
