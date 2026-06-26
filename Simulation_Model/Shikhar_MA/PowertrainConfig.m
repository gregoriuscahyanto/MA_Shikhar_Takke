classdef PowertrainConfig
    % Architecture flags for EV and Hybrid powertrains
    
    properties
        % Input flags (set from outside or defaults)
        VM  = 0;
        EV  = 0;
        Hy  = 0;
        
        % EV architectures
        E0 = 0;   % 1 EM two-wheel drive 
        E1 = 0;   % 2 EM two-wheel drive (same axle)
        E2 = 0;   % 2 EM four-wheel drive (different axle)
        E3 = 0;   % 3 EM four-wheel drive (2 on one axle)
        E4 = 0;   % 4 EM four-wheel drive (one per wheel)
        
        % Hybrid architectures
        P0    = 0;
        P2    = 0;
        P3    = 0;
        P4    = 0;
        P4_DM = 0;
        
        % Derived
        cfg_E0     = 0;
        cfg_E1     = 0;
        cfg_E2     = 0;
        cfg_E3     = 0;
        cfg_E4     = 0;
        cfg_P0     = 0;
        cfg_P2     = 0;
        cfg_P3     = 0;
        cfg_P4     = 0;
        cfg_P4_DM  = 0;
    end
    
    methods
        function obj = PowertrainConfig(VM, EV, Hy)
            if nargin >= 1, obj.VM = VM; end
            if nargin >= 2, obj.EV = EV; end
            if nargin >= 3, obj.Hy = Hy; end
        end
        
        function obj = setupEV(obj)
            if obj.EV ~= 1
                return;
            end
            
            % Copy flags for downstream scripts
            obj.cfg_E0 = obj.E0;
            obj.cfg_E1 = obj.E1;
            obj.cfg_E2 = obj.E2;
            obj.cfg_E3 = obj.E3;
            obj.cfg_E4 = obj.E4;
            
            % Validation: only one EV architecture
            EV_architecture_flags = [obj.E1, obj.E2, obj.E3, obj.E4];
            if sum(EV_architecture_flags) > 1
                error('Only one EV architecture can be selected. Please ensure only one parameter is set to 1.');
            end
            
            EVnames  = {'1 EM  two-wheel drive', ...
                        '2 EM  two-wheel drive (same axle)', ...
                        '2 EM four-wheel drive (different axle)', ...
                        '3 EM four-wheel drive (2 on one axle)', ...
                        '4 EM four-wheel drive (on each wheel)'};
            EVvalues = [obj.E0, obj.E1, obj.E2, obj.E3, obj.E4];
            selectedEVparams = EVnames(EVvalues == 1);
            EVparam = sprintf('Electric configuration type: %s', strjoin(selectedEVparams, ','));
            disp(EVparam);
            
            % Activation logic (same as original)
            if obj.E2 == 1
                obj.E0    = 1;
                obj.P4    = 1;
                obj.P4_DM = 0;
            end
            if obj.E3 == 1
                obj.E0    = 1;
                obj.P4_DM = 1;
                obj.P4    = 0;
            end
            if obj.E4 == 1
                obj.E1    = 1;
                obj.P4_DM = 1;
                obj.P4    = 0;
            end
        end
        
        function obj = setupHybrid(obj)
            if obj.Hy ~= 1
                return;
            end
            
            % Copy flags for downstream
            obj.cfg_P0    = obj.P0;
            obj.cfg_P2    = obj.P2;
            obj.cfg_P3    = obj.P3;
            obj.cfg_P4    = obj.P4;
            obj.cfg_P4_DM = obj.P4_DM;
            
            % Validation
            if obj.P4 + obj.P4_DM > 1
                error('Only one P4 architecture can be selected');
            end
            
            Hynames  = {'P0', 'P1/P2', 'P3', 'P4', 'P4 Dual Motor'};
            Hyvalues = [obj.P0, obj.P2, obj.P3, obj.P4, obj.P4_DM];
            selectedHyparams = Hynames(Hyvalues == 1);
            Hyparam = sprintf('Hybrid type: %s', strjoin(selectedHyparams, ','));
            disp(Hyparam);
        end
    end
end
