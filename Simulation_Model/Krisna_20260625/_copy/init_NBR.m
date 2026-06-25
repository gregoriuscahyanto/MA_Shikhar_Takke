function init_NBR()

    % === Load all MAT-files into structs (safe, clean) ===
    S.Vehicle   = load("TotalHybridVehicle_Hybrid2025_V03_Ma.mat");
    S.Battery   = load("Batterie_102s1p.mat");
    S.GET       = load("GET.mat");
    S.Slip      = load("init_slip.mat");
    S.Mass      = load("massenfaktor_kennfeld.mat");
    S.vMax      = load("vMax_Fwd.mat");

    % === Push ALL variables from all MAT-files to base workspace ===
    assignStructToBase(S.Vehicle);
    assignStructToBase(S.Battery);
    assignStructToBase(S.GET);
    assignStructToBase(S.Slip);
    assignStructToBase(S.Mass);
    assignStructToBase(S.vMax);

    % === Build Track struct ===
    Track.RoundOnly = S.vMax.Trk;
    Track.RoundOnly.vMax__km_per_h = S.vMax.vMax_Fwd.';

    index = 40 + Track.RoundOnly.Idx_PStart : height(Track.RoundOnly.x__m);
    Track.RoundOnly.s__m               = Track.RoundOnly.s__m(index,:);
    Track.RoundOnly.R__m               = Track.RoundOnly.R__m(index,:);
    Track.RoundOnly.Agl_Elevation__deg = Track.RoundOnly.Agl_Elevation__deg(index,:);
    Track.RoundOnly.vMax__km_per_h     = Track.RoundOnly.vMax__km_per_h(index,:);
    Track.RoundOnly.s_cum__m           = cumsum(Track.RoundOnly.s__m);

    % === Initial conditions ===
    T_init_degC     = 25;
    cp_Zelle_JpkgK  = 800;
    v_Fzg_init_kmph = 30;

    % === Load drive cycle ===
    T = readtable("Abgleich_PHEV_NBR.xlsx", ...
                  Sheet="Munka1", Range="A2:G2350");

    T.time = seconds(T.Zeit_s_);
    T.v_Fzg_kmph = T.Geschwindigkeit_km_h_;
    TT_sliced = table2timetable(T, RowTimes="time");
    TT_sliced.s_m = local_integral(seconds(TT_sliced.time), TT_sliced.v_Fzg_kmph./3.6);
    TT_sliced = TT_sliced(2:end,:);

    % === Export remaining variables ===
    assignin("base","Track",Track);
    assignin("base","TT_sliced",TT_sliced);
    assignin("base","T_init_degC",T_init_degC);
    assignin("base","cp_Zelle_JpkgK",cp_Zelle_JpkgK);
    assignin("base","v_Fzg_init_kmph",v_Fzg_init_kmph);

end


% === Helper: push all fields of a struct to base workspace ===
function assignStructToBase(S)
    names = fieldnames(S);
    for k = 1:numel(names)
        assignin("base", names{k}, S.(names{k}));
    end
end


% === Local integral ===
function i = local_integral(t,x)
    i = [0; cumsum(diff(t).*x(1:end-1))];
end


% function init_NBR()
%     load("TotalHybridVehicle_Hybrid2025_V03_Ma.mat")
%     load("Batterie_102s1p.mat");
%     load("GET.mat");
%     load("init_slip.mat");
%     load("massenfaktor_kennfeld.mat");
%     load("vMax_Fwd.mat");
% 
%     Track.RoundOnly = Trk;
%     Track.RoundOnly.vMax__km_per_h = vMax_Fwd.';
% 
%     index = 40+Track.RoundOnly.Idx_PStart : height(Track.RoundOnly.x__m);
%     Track.RoundOnly.s__m               = Track.RoundOnly.s__m(index,:);
%     Track.RoundOnly.R__m               = Track.RoundOnly.R__m(index,:);
%     Track.RoundOnly.Agl_Elevation__deg = Track.RoundOnly.Agl_Elevation__deg(index,:);
%     Track.RoundOnly.vMax__km_per_h     = Track.RoundOnly.vMax__km_per_h(index,:);
%     Track.RoundOnly.s_cum__m           = cumsum(Track.RoundOnly.s__m);
% 
%     T_init_degC     = 25;
%     cp_Zelle_JpkgK  = 800;
%     v_Fzg_init_kmph = 30;
% 
%     T = readtable("Abgleich_PHEV_NBR.xlsx", ...
%                   Sheet="Munka1", Range="A2:G2350");
% 
%     T.time = seconds(T.Zeit_s_);
%     T.v_Fzg_kmph = T.Geschwindigkeit_km_h_;
%     TT_sliced = table2timetable(T, RowTimes="time");
%     TT_sliced.s_m = local_integral(seconds(TT_sliced.time), TT_sliced.v_Fzg_kmph./3.6);
%     TT_sliced = TT_sliced(2:end,:);
% 
%     % Push everything to base workspace for Simulink
%     assignin("base","Track",Track);
%     assignin("base","TT_sliced",TT_sliced);
%     assignin("base","T_init_degC",T_init_degC);
%     assignin("base","cp_Zelle_JpkgK",cp_Zelle_JpkgK);
%     assignin("base","v_Fzg_init_kmph",v_Fzg_init_kmph);
% end
% 
% function i = local_integral(t,x)
%     i = [0; cumsum(diff(t).*x(1:end-1))];
% end
