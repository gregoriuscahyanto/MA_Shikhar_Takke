function [SKO_WHEEL_TYP_CHAL, SKO_STREET_CHAL, cw] = VehicleParamSelector(cp, veh)
% VehicleParamSelector  —  Computes per-run tire type, drag coeff & frontal area
%
% INPUTS:
%   cp   - ComponentParams object (after computeXxxMap calls)
%   veh  - VehicleConfig object
%
% OUTPUTS (also written directly to MATLAB base workspace):
%   SKO_WHEEL_TYP_CHAL  - tire selector index  (1=Standard, 2=Sport,
%                          3=Performance, 4=Spezialreifen)
%   cw                  - drag coefficient [-]
%   A_front             - frontal area [m^2]
%
% Selection is based on specific system power:
%   sp = (P_ICE + P_P0 + P_P2 + P_P3 + P_P4) / m_curb  [kW/kg]
%
%  sp [kW/kg]    Tire    mu     cw     A_front (base, before AWD offset)
%  ----------    ----    ----   ----   ---------------------------------
%  < 0.08        1       1.0    0.34   mass bins below
%  0.08-0.15     2       1.1    0.32
%  0.15-0.22     3       1.2    0.30
%  >= 0.22       4       1.3    0.28
%
%  Mass -> A_front:  <1200kg->2.05 | 1200-1500->2.20 | 1500-1700->2.35 | >=1700->2.55
%  AWD adds +0.10 m^2

    %% --- Read power values from cp ---
    P_ICE = cp.Pwr_ICE_max_kW;
    P_P0  = cp.Pwr_P0_max_kW;
    P_P2  = cp.Pwr_P2_max_kW;
    P_P3  = cp.Pwr_P3_max_kW;
    P_P4  = cp.Pwr_P4_max_kW;
    P_sys = P_ICE + P_P0 + P_P2 + P_P3 + P_P4;

    %% --- Specific power [kW/kg] ---
    sp = P_sys / veh.m_curb ;

    %% --- Tire type (SKO_WHEEL_TYP_CHAL) ---
    if     sp < 0.08,  SKO_WHEEL_TYP_CHAL = 1; SKO_STREET_CHAL = 2;
    elseif sp < 0.15,  SKO_WHEEL_TYP_CHAL = 1; SKO_STREET_CHAL = 2;
    elseif sp < 0.22,  SKO_WHEEL_TYP_CHAL = 2; SKO_STREET_CHAL = 2;
    else,              SKO_WHEEL_TYP_CHAL = 3; SKO_STREET_CHAL = 1;
    end

    %% --- Drag coefficient (cw) --- %% not used --
    if     sp < 0.08,  cw = 0.34;
    elseif sp < 0.15,  cw = 0.32;
    elseif sp < 0.22,  cw = 0.30;
    else,              cw = 0.28;
    end


    %% --- Write to base workspace so Simulink can read directly ---
    assignin('base', 'SKO_WHEEL_TYP_CHAL', SKO_WHEEL_TYP_CHAL);
    assignin('base', 'SKO_STREET_CHAL', SKO_STREET_CHAL);
    assignin('base', 'cw',                  cw);

    %% --- Console log ---
    mu_map = [1.0, 1.1, 1.2, 1.3];
    fprintf('  [VehicleParamSelector] Tire=%d (mu=%.1f) | cw=%.2f | P_sys=%.0f kW | sp=%.3f kW/kg\n', ...
        SKO_WHEEL_TYP_CHAL, mu_map(SKO_WHEEL_TYP_CHAL), cw, P_sys, sp);

end