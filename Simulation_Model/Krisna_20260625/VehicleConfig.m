classdef VehicleConfig
    % High-level vehicle parameters and main-axle selection
    
    properties
        % Axle / chassis
        HM_VA               = 0;        % 1: main motor on Front Axle, 0: Rear
        AWD                 = 1;        % 1: Yes, 0: No


        m_curb   = 2000;  % Curb weight [kg]
        d_wheel     = 0.7075 % Wheel diameter
        % --- MISSING PARAMETERS YOU NEED TO ADD ---
        % m_load   = 75;    % Driver weight [kg]
        cw       = 0.28;  % Drag coefficient [-]
        A_front  = 2.4;   % Frontal Area [m^2]
        % f_roll   = 0.011; % Rolling resistance [-]
        
        % Continue with existing...

        iAG                 = 3.204;    % Differential ratio (ICE)
        Wheelbase         = 2.862;    % Wheelbase [m]
        h_s                 = 0.4;      % CG height [m]
        weight_dist  = 1;        % Static weight distribution VA/HA
        
        MainAxle_TorqueSplit_int = 0.6; % Percentage of total powertrain torque sent to the "main" (ICE or EV) axle.
                                        % Example: 0.7 -> 70% to main axle, 30% to secondary axle.
        
        Hybrid_ICE_priority = 0;    % Hybrid torque source priority
                                        % 1  -> ICE-priority: give max desired torque to ICE, remainder to EM.
                                        % 0  -> EM-priority: give max desired torque to EM, remainder to ICE.


        % Powertrain selection flags
        VM  = 0;    % 1: conventional ICE
        EV  = 0;    % 1: BEV
        Hy  = 1;    % 1: Hybrid
    end
    
    methods
        function obj = VehicleConfig()
            % You can change defaults above, or in this constructor if needed.
        end
        
        function report(obj)
            % Main motor position
            if obj.HM_VA == 0
                disp('Main Engine/Motor Position: Front axle');
            else
                disp('Main Engine/Motor Position: Rear axle');
            end
            
            % Powertrain type validation + display
            PT_architecture_flags = [obj.VM, obj.EV, obj.Hy];
            if sum(PT_architecture_flags) == 0
                error('Please select Powertrain type.');
            end
            if sum(PT_architecture_flags) > 1
                error('Only one Powertrain type can be selected. Please ensure only one parameter is set to 1.');
            end
            
            PTnames  = {'ICE Vehicle', 'Electric Vehicle', 'Hybrid Vehicle'};
            PTvalues = [obj.VM, obj.EV, obj.Hy];
            selectedPTparams = PTnames(PTvalues == 1);
            PTparam = sprintf('Powertrain type: %s', strjoin(selectedPTparams, ','));
            disp(PTparam);
            
            % Common prints
            disp(['    Differential Ratio: ' num2str(obj.iAG)]);
            disp(['Wheel Base: ' num2str(obj.Achsabstand)]);
        end
    end
end
