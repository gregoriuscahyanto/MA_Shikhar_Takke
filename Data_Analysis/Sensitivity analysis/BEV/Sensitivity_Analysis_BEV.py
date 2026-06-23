from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from common_sensitivity import PipelineConfig, run_cli

EV_SCALE_COLS = ["tq_EV_max", "Pwr_EV_max_kW"]
GEAR_SCALE_COLS = ["i_GET_EV", "i_ges_P4"]
BATTERY_SCALE_COLS = ["Cell_I_max_dis"]

CONFIG = PipelineConfig(
    powertrain="bev",
    input_candidates=[
        "DoE_Inp_EV.csv",
        "Simulation_Vehicle_Data/DoE_Inp_EV.csv",
        "Simulation_Model/DoE_Inp_EV.csv",
        "Surrogate_Model/EV Powertrain/DoE_Inp_EV.csv",
    ],
    sweep_config={
        "G1_lt5s": {"ev_power_scale": [1.00, 1.05, 1.10, 1.15, 1.20], "gear_scale": [1.00, 1.03, 1.06], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
        "G2_5to7s": {"ev_power_scale": [1.00, 1.05, 1.10, 1.15], "gear_scale": [1.00, 1.03, 1.06], "mass_scale": [1.00], "bat_dis_scale": [1.00, 1.05]},
        "G3_7to10s": {"ev_power_scale": [0.95, 1.00, 1.05], "gear_scale": [0.98, 1.00, 1.02], "mass_scale": [1.00], "bat_dis_scale": [1.00]},
        "G4_10to13s": {"ev_power_scale": [0.80, 0.85, 0.90, 0.95, 1.00], "gear_scale": [0.94, 0.97, 1.00], "mass_scale": [1.00, 1.02, 1.04, 1.06], "bat_dis_scale": [0.95, 1.00]},
        "G5_gt13s": {"ev_power_scale": [0.60, 0.65, 0.70, 0.75, 0.80], "gear_scale": [0.90, 0.95, 1.00], "mass_scale": [1.00, 1.03, 1.06, 1.09], "bat_dis_scale": [0.90, 1.00]},
    },
    sweep_params=["ev_power_scale", "gear_scale", "mass_scale", "bat_dis_scale"],
    changed_params=EV_SCALE_COLS + GEAR_SCALE_COLS + ["m_curb", "Cell_I_max_dis"],
    scale_groups={
        "ev_power_scale": EV_SCALE_COLS,
        "gear_scale": GEAR_SCALE_COLS,
        "bat_dis_scale": BATTERY_SCALE_COLS,
    },
    filter_col_equals={"EV": 1, "Hy": 0},
    default_output_dir="bev_sensitivity_results",
)


if __name__ == "__main__":
    run_cli(CONFIG)
