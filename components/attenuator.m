function xatt = attenuator(x, attdB)
%% Attenuate signal x by attdB dB
xatt = x*sqrt(10^(-attdB/10));