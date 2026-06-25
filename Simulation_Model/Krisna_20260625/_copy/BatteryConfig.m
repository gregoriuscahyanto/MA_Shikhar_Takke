classdef BatteryConfig
    % Cell + pack-level battery parameters for a simple table-based model
    
    %% === CELL-LEVEL USER INPUTS (edit these) ===
    properties
        % Single-cell datasheet values
        Cell_Cap_Ah    = 4.8;     % Ah, e.g. 4.8 Ah cell
        Cell_V_nom     = 3.7;     % V nominal
        Cell_R_inner   = 0.023;   % Ohm, average DCIR
        Cell_V_min     = 2.5;     % V, cutoff
        Cell_V_max     = 4.2;     % V, full charge
        Cell_I_max_chg = 4.8;     % A, max charge (≈1C)
        Cell_I_max_dis = 15.0;    % A, max discharge
        
        % OCV–SOC curve (single cell)
        SOC_Vector = [0, 0.1, 0.2, 0.3, 0.4, 0.5, ...
                      0.6, 0.7, 0.8, 0.9, 1.0];
        Cell_OCV_Vector = [2.8, 3.3, 3.45, 3.52, 3.60, 3.68, ...
                           3.75, 3.85, 3.95, 4.1, 4.2];
        
        % Pack topology
        n_s = 96;   % series cells (voltage) 96
        n_p = 46;   % parallel cells (capacity / current) 46
        
        % Initial SOC (0..1)
        facSocInit = 0.75;   % start SOC for simulation

        % SOC limit for recuperation
        SOC_Recup_Limit = 0.95; % Above this SOC, regenerative braking / charging is cut off.
        
        % SOC limit for power cut
        SOC_Bat_Discharge_Limit = 0.1 % Below this SOC, motor stops taking power

    end
    
    %% === PACK-LEVEL DERIVED PARAMETERS (auto-computed) ===
    properties
        Pack_Cap_Ah        double = NaN;   % Ah
        capBat_As          double = NaN;   % As, for integrator
        resBatInner        double = NaN;   % Ohm
        uBatMin            double = NaN;   % V 
        uBatMax            double = NaN;   % V
        iBatChrgMax        double = NaN;   % A
        iBatDisChrgMax     double = NaN;   % A
        Pack_OCV_Vector    double = [];    % V
        Soc_Axis           double = [];    % SOC axis for LUT
        uBatOcv_Table      double = [];    % OCV table for LUT
    end
    
    methods
        function obj = BatteryConfig()
            % Default constructor (you can override properties after creation)
        end
        
        function obj = computePack(obj)
            % Run once after setting n_s, n_p, and cell inputs.
            
            fprintf('Calculating Pack Parameters for %dS%dP configuration...\n', ...
                    obj.n_s, obj.n_p);
            
            % --- Capacity ---
            obj.Pack_Cap_Ah = obj.Cell_Cap_Ah * obj.n_p;
            obj.capBat_As   = obj.Pack_Cap_Ah * 3600;  % Ah -> As
            
            % --- Resistance ---
            obj.resBatInner = (obj.Cell_R_inner * obj.n_s) / obj.n_p;
            
            % --- Voltage limits ---
            obj.uBatMin = obj.Cell_V_min * obj.n_s;
            obj.uBatMax = obj.Cell_V_max * obj.n_s;
            
            % --- Current limits ---
            obj.iBatChrgMax    = obj.Cell_I_max_chg * obj.n_p;
            obj.iBatDisChrgMax = obj.Cell_I_max_dis * obj.n_p;
            
            % --- OCV lookup data (pack-level) ---
            obj.Pack_OCV_Vector = obj.Cell_OCV_Vector * obj.n_s;
            obj.Soc_Axis        = obj.SOC_Vector;
            obj.uBatOcv_Table   = obj.Pack_OCV_Vector;
        end
    end
end
