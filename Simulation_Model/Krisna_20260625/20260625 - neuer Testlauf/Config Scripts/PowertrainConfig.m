classdef PowertrainConfig
    % PowertrainConfig - pure topology setup for Simulink routing.
    %
    % V14c contract:
    %   - ams_json_to_DoE_Inp.m must provide clean, canonical topology flags.
    %   - DoE_main.m only transfers cfg values into this object.
    %   - This class validates the topology and derives Simulink routing flags.
    %   - It does not infer vehicle data from text and does not repair inputs.
    %
    % Powertrain flags:
    %   VM = 1: ICE vehicle
    %   EV = 1: pure EV
    %   Hy = 1: hybrid
    %
    % EV architecture flags from converter:
    %   E0: one primary motor / one driven axle
    %   E1: two motors on primary axle
    %   E2: one primary + one secondary axle motor
    %   E3: one primary + two secondary axle motors
    %   E4: two primary + two secondary axle motors
    %
    % Hybrid architecture flags from converter:
    %   P0, P2, P3, P4, P4_DM
    %
    % Note:
    %   For pure EV E2/E3/E4, the Simulink model still uses internal P4/P4_DM
    %   routing for the secondary e-axle. Therefore setupEV derives P4/P4_DM
    %   and cfg_P4/cfg_P4_DM from E2/E3/E4. This is model routing, not input
    %   preprocessing.

    properties
        %% Powertrain type
        VM  = 0;
        EV  = 0;
        Hy  = 0;

        %% EV architectures
        E0 = 0;
        E1 = 0;
        E2 = 0;
        E3 = 0;
        E4 = 0;

        %% Hybrid architectures / secondary e-axle routing
        P0    = 0;
        P2    = 0;
        P3    = 0;
        P4    = 0;
        P4_DM = 0;

        %% Derived routing/config flags used by Simulink
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

            obj.assertSinglePowertrainType();

            evFlags = [obj.E0, obj.E1, obj.E2, obj.E3, obj.E4];
            if sum(evFlags) ~= 1
                error('Exactly one EV architecture E0/E1/E2/E3/E4 must be selected for EV rows.');
            end

            % Store converter-level EV architecture exactly as provided.
            obj.cfg_E0 = obj.E0;
            obj.cfg_E1 = obj.E1;
            obj.cfg_E2 = obj.E2;
            obj.cfg_E3 = obj.E3;
            obj.cfg_E4 = obj.E4;

            % Pure EV must not carry hybrid P0/P2/P3 input flags.
            if obj.P0 ~= 0 || obj.P2 ~= 0 || obj.P3 ~= 0
                error('Pure EV rows must not contain P0/P2/P3 hybrid flags.');
            end

            % Reset model-routing P4 flags first; derive them from E-architecture.
            obj.P4 = 0;
            obj.P4_DM = 0;
            obj.cfg_P0 = 0;
            obj.cfg_P2 = 0;
            obj.cfg_P3 = 0;
            obj.cfg_P4 = 0;
            obj.cfg_P4_DM = 0;

            % Simulink routing for primary/secondary EV axles.
            if obj.E0 == 1
                % One primary motor only.
            elseif obj.E1 == 1
                % Two motors on the primary axle, no secondary e-axle.
            elseif obj.E2 == 1
                % Primary axle + one secondary e-axle motor.
                obj.E0 = 1;
                obj.P4 = 1;
                obj.cfg_P4 = 1;
            elseif obj.E3 == 1
                % Primary axle + two secondary e-axle motors.
                obj.E0 = 1;
                obj.P4_DM = 1;
                obj.cfg_P4_DM = 1;
            elseif obj.E4 == 1
                % Two primary axle motors + two secondary e-axle motors.
                obj.E1 = 1;
                obj.P4_DM = 1;
                obj.cfg_P4_DM = 1;
            end

            EVnames  = {'E0: 1 EM two-wheel drive', ...
                        'E1: 2 EM two-wheel drive same axle', ...
                        'E2: 2 EM AWD different axles', ...
                        'E3: 3 EM AWD', ...
                        'E4: 4 EM AWD'};
            selectedEVparams = EVnames(evFlags == 1);
            disp(['Electric configuration type: ' strjoin(selectedEVparams, ',')]);
        end

        function obj = setupHybrid(obj)
            if obj.Hy ~= 1
                return;
            end

            obj.assertSinglePowertrainType();

            hyFlags = [obj.P0, obj.P2, obj.P3, obj.P4, obj.P4_DM];
            if sum(hyFlags) < 1
                error('At least one hybrid architecture P0/P2/P3/P4/P4_DM must be selected for Hybrid rows.');
            end

            if obj.P4 + obj.P4_DM > 1
                error('Only one P4 architecture can be selected: P4 or P4_DM.');
            end

            % Hybrid rows must not carry pure EV architecture flags.
            if obj.E0 ~= 0 || obj.E1 ~= 0 || obj.E2 ~= 0 || obj.E3 ~= 0 || obj.E4 ~= 0
                error('Hybrid rows must not contain EV architecture flags E0/E1/E2/E3/E4.');
            end

            % Copy converter-level hybrid architecture to Simulink config flags.
            obj.cfg_P0    = obj.P0;
            obj.cfg_P2    = obj.P2;
            obj.cfg_P3    = obj.P3;
            obj.cfg_P4    = obj.P4;
            obj.cfg_P4_DM = obj.P4_DM;

            % EV config flags stay inactive for Hybrid rows.
            obj.cfg_E0 = 0;
            obj.cfg_E1 = 0;
            obj.cfg_E2 = 0;
            obj.cfg_E3 = 0;
            obj.cfg_E4 = 0;

            Hynames  = {'P0', 'P2', 'P3', 'P4', 'P4 Dual Motor'};
            selectedHyparams = Hynames(hyFlags == 1);
            disp(['Hybrid type: ' strjoin(selectedHyparams, ',')]);
        end

        function obj = setupICE(obj)
            if obj.VM ~= 1
                return;
            end

            obj.assertSinglePowertrainType();

            % ICE rows must not carry EV or Hybrid architecture flags.
            if any([obj.E0, obj.E1, obj.E2, obj.E3, obj.E4, obj.P0, obj.P2, obj.P3, obj.P4, obj.P4_DM] ~= 0)
                error('ICE rows must not contain EV or Hybrid architecture flags.');
            end

            obj.cfg_E0 = 0; obj.cfg_E1 = 0; obj.cfg_E2 = 0; obj.cfg_E3 = 0; obj.cfg_E4 = 0;
            obj.cfg_P0 = 0; obj.cfg_P2 = 0; obj.cfg_P3 = 0; obj.cfg_P4 = 0; obj.cfg_P4_DM = 0;
        end

        function assertSinglePowertrainType(obj)
            flags = [obj.VM, obj.EV, obj.Hy];
            if sum(flags) ~= 1
                error('Exactly one powertrain type VM/EV/Hy must be selected.');
            end
        end
    end
end
