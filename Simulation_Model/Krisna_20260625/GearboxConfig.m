classdef GearboxConfig
    % Gearbox and shift configuration
    %
    % SECTION 1: EV MAIN GEARBOX (single-speed)
    %   - i_GET_EV: total gear ratio between EV main machine and wheels.
    %
    % SECTION 2: P4 / SECONDARY AXLE GEARBOX
    %   - i_ges_P4: total gear ratio for P4/secondary e-axle.
    %
    % SECTION 3: ICE MULTI-GEAR TRANSMISSION
    %   - Gear_Ratio, No_Gears, shift maps (standard / performance)
    
    properties
        %% === USER INPUT: EV MAIN GEARBOX (single-speed) ===
        % Total reduction from main EV motor shaft to driven axle
        i_GET_EV   = 6.0;   % Example: EV 1‑speed ratio
        
        %% === USER INPUT: P4 / SECONDARY AXLE GEARBOX OF ELECTRIC VEHICLE (E2,E3,E4) ===
        % Total reduction from P4 / rear e-axle motor(s) to wheels
        i_ges_P4   = 7.728; % Example from your original script
        
        %%
        shiftDelay = 0.80;


        %% === USER INPUT: ICE MULTI-GEAR TRANSMISSION ===
        max_rpm          % Engine max speed [rpm] (set from ICE config)
        use_cus_val = true;   % true: use explicit Gear_Ratio; false: generate progression
        Gear_Ratio            % [1 x No_Gears] array of gear ratios
        No_Gears              % number of gears
        Gears                  % gear index vector
        
        % Shift map configuration
        mode string = "standard";   % "standard" or "performance"
        
        %% === INTERNAL: GAS PEDAL & SHIFT MAPS ===
        pedal_pos             % pedal positions 0..1
        n_max_Upmin           % upshift RPM map  (size: nPedal x No_Gears)
        n_min_Upmin           % downshift RPM map
        
    end
    
    methods
        function obj = GearboxConfig(max_rpm)
            % Constructor: pass ICE max speed if you want shift maps scaled
            if nargin > 0
                obj.max_rpm = max_rpm;
            end
        end
        
        %% === SECTION 3A: DEFINE ICE GEAR RATIOS ===
        function obj = computeRatios(obj)
            % Define gear ratios for the ICE transmission.
            % Set use_cus_val = true and edit Gear_Ratio manually,
            % OR set use_cus_val = false and use progression logic.
            
            obj.use_cus_val = true;   % change to false to use progression
            
            if obj.use_cus_val
                % ---- USER-DEFINED OEM-LIKE RATIOS ----
                obj.Gear_Ratio = [5, 3.2, 2.143, 1.720, 1.313, 1.000, 0.823, 0.640];
                obj.No_Gears   = length(obj.Gear_Ratio);
                obj.Gears       = 1:obj.No_Gears;
            else
                % ---- GENERIC PROGRESSION LOGIC (you may tune or delete) ----
                i1                  = 5;     % 1st gear ratio
                obj.No_Gears        = 7;     % number of gears
                step_ratio_init = 0.71;  % initial step ratio
                use_k               = false; % true: custom k vector; false: constant
                
                if use_k
                    % progression factors: length = No_Gears - 2
                    k = [0.98, 0.98, 0.99, 1.0, 1.01, 1.02];
                    if length(k) ~= obj.No_Gears - 2
                        fprintf("Die länge von k ist falsch.\n");
                        return;
                    end
                else
                    k = ones(1, obj.No_Gears - 2);
                end
                
                Ueb = zeros(obj.No_Gears, 1);
                Stf = zeros(obj.No_Gears - 1, 1);
                Stf(1) = step_ratio_init;
                for n = 2:length(Stf)
                    Stf(n) = Stf(n-1) * k(n-1);
                end
                Ueb(1) = i1;
                for n = 2:obj.No_Gears
                    Ueb(n) = Ueb(n-1) * Stf(n-1);
                end
                obj.Gear_Ratio = Ueb;
                obj.Gears       = 1:obj.No_Gears;
            end
            
            % Shared pedal vector for all shift-map modes
            obj.pedal_pos = 0:0.1:1;
        end
        
        %% === SECTION 3B: GENERATE SHIFT MAPS (STANDARD / PERFORMANCE) ===
        function obj = computeShiftMaps(obj)
            if isempty(obj.Gear_Ratio)
                error('Call computeRatios() before computeShiftMaps().');
            end
            if isempty(obj.max_rpm) || obj.max_rpm <= 0
                error('max_rpm must be set (from ICE config) before computeShiftMaps().');
            end
            
            obj.No_Gears = length(obj.Gear_Ratio);
            No_Gears     = obj.No_Gears;
            max_rpm = obj.max_rpm;
            pedal_pos    = obj.pedal_pos;
            An_pedal_pos = length(pedal_pos);
            
            n_max_Upmin = zeros(An_pedal_pos, No_Gears);
            n_min_Upmin = zeros(An_pedal_pos, No_Gears);
            
            % Common percentage configuration
            pct_upshift_eco    = 0.35;
            pct_upshift_perf   = 1.00;
            pct_downshift_eco  = 0.20;
            pct_downshift_perf = 0.70;
            
            if strcmpi(obj.mode, "performance")
                % ===== PERFORMANCE GEAR CHANGING =====
                % Same upshift/downshift RPM in all gears for a given pedal.
                
                min_upshift_rpm   = max_rpm * pct_upshift_eco;
                max_upshift_rpm   = max_rpm * pct_upshift_perf;
                min_downshift_rpm = max_rpm * pct_downshift_eco;
                max_downshift_rpm = max_rpm * pct_downshift_perf;
                
                for i = 1:An_pedal_pos
                    current_pedal = pedal_pos(i);
                    
                    current_upshift = min_upshift_rpm + ...
                        current_pedal * (max_upshift_rpm - min_upshift_rpm);
                    
                    current_downshift = min_downshift_rpm + ...
                        current_pedal * (max_downshift_rpm - min_downshift_rpm);
                    
                    if current_downshift >= current_upshift
                        current_downshift = current_upshift * 0.85;
                    end
                    
                    for g = 1:No_Gears
                        n_max_Upmin(i, g) = round(current_upshift);
                        n_min_Upmin(i, g) = round(current_downshift);
                    end
                end
                
            else
                % ===== STANDARD GEAR CHANGING =====
                % Gear-dependent shift points with nonlinear pedal curve.
                
                min_up_rpm = max_rpm * pct_upshift_eco;
                max_up_rpm = max_rpm * pct_upshift_perf;
                min_dn_rpm = max_rpm * pct_downshift_eco;
                max_dn_rpm = max_rpm * pct_downshift_perf;
                
                gear_factor = linspace(0.90, 1.00, No_Gears);
                gear_factor = gear_factor .* linspace(0.85, 1.00, No_Gears);
                
                pedal_nl = sin(pedal_pos * pi/2);
                
                for i = 1:An_pedal_pos
                    p = pedal_nl(i);
                    
                    base_up = min_up_rpm + p * (max_up_rpm - min_up_rpm);
                    base_dn = min_dn_rpm + p * (max_dn_rpm - min_dn_rpm);
                    
                    for g = 1:No_Gears
                        g_up = base_up * gear_factor(g);
                        g_dn = base_dn * gear_factor(g);
                        
                        hysteresis = 0.10 + 0.02 * (g - 1);
                        
                        if g_dn >= g_up
                            g_dn = g_up * (1 - hysteresis);
                        end
                        
                        n_max_Upmin(i, g) = round(g_up);
                        n_min_Upmin(i, g) = round(g_dn);
                    end
                end
            end
            
            n_min_Upmin(:, 1) = 0;
            
            obj.n_max_Upmin = n_max_Upmin;
            obj.n_min_Upmin = n_min_Upmin;
        end
        
        %% === OPTIONAL: SUMMARY PRINT ===
        function report(obj)
            fprintf('--- GearboxConfig ---\n');
            fprintf('EV main gear ratio i_GET_EV: %.3f\n', obj.i_GET_EV);
            fprintf('P4 / secondary gear ratio i_ges_P4: %.3f\n', obj.i_ges_P4);
            if ~isempty(obj.Gear_Ratio)
                fprintf('ICE gears: %d\n', obj.No_Gears);
                fprintf('Gear ratios: %s\n', mat2str(obj.Gear_Ratio,3));
            end
        end
    end
end
