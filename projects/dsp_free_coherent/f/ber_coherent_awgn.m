function [ber_ideal, ber_noise_enhancement, SNRdBtheory] = ber_coherent_awgn(Tx, Fiber, Rx, sim)
%% Estimate ideal BER of a coherent detection system
% System consists of coherent detection, mathced filtering, symbol-rate
% sampling, and linear equalization
% Calculations assume rectangular pulse shape
% Inputs:
% - Tx: transmitter parameters {filt: transmiter filter, Mod: modulator
% parameters}
% - Fiber: fiber parameters
% - Rx: receiver parameters
% - sim: simulation parameters {M: modulation order, ModFormat: modulation
% format, Rs: symbol rate, Mct: oversampling ratio to emulate continuous
% time, f: frequency vector}
% Outputs:
% - ber_ideal: BER of a system whose receiver filter is matched to the
% transmitter pulse shape. This doesn't take into account any frequency
% response of the channel and noise enhancement penalty
% - ber_noise_enhancement: BER of a system whose receiver filter is matched 
% to the receiver pulse shape and there is symbol rate liner equalization. 

% BER in AWGN channel
M = sim.ModFormat.M;
berAWGN = @(SNRdB) berawgn(SNRdB - 10*log10(log2(M)), lower(sim.ModFormat.type), M);

% Power levels
Prx = dBm2Watt(Tx.PlaunchdBm)/Fiber.link_attenuation(Tx.Laser.lambda); % received power
Plo = dBm2Watt(Rx.LO.PdBm);                                            % local oscillator power

Sase = zeros(size(Prx));
if sim.preAmp
    for k = 1:length(Prx)
        Rx.OptAmp.adjust_gain(Watt2dBm(Prx(k))); % Assign gain to compute ASE PSD
        Sase(k) = 4*Rx.PD.R^2*Plo*Rx.OptAmp.Ssp/(2*sim.Npol*sim.Npol); % One-sided ASE PSD per real dimension
        Prx(k) = Prx(k)*Rx.OptAmp.Gain;
    end
end

Ppd = abs(sqrt(Plo/(4*sim.Npol)) + sqrt(Prx/(4*sim.Npol))).^2;         % incident power in each photodiode
Psig = Rx.PD.R^2*Plo*Prx/(2*sim.Npol*sim.Npol);                        % Signal power per real dimension

%% Theory
% Estimate SNR of an ideal symbol-rate linear equalizer   
Rs = sim.ModFormat.Rs;
noiseBW = Rs/2;  % one-sided noise bandwidth of matched filter. 
% This assumes rectangular pulse shape and doesn't include noise enhancement penalty
varShot = 2*Rx.PD.varShot(Ppd, noiseBW);                               % Shot noise variance per real dimension
% Note: factor of 2 is due to balanced photodetection
varThermal = Rx.N0*noiseBW;    
varASE = Sase*noiseBW;

SNRdBtheory = 10*log10(Psig./(varASE + varShot + varThermal));
ber_ideal = berAWGN(SNRdBtheory);

%% Including noise enhancement penalty (coarse)
% Design linear equalizer to estimate noise enhancement penalty
% Calculate noise bandwidth of an ideal receiver consisting of a matched 
% filter and symbol-rate linear equalization. This is only used to
% estimate theoretical BER
eq.type = 'fixed td-sr-le';
eq.Ntaps = 31;
pulse_shape = select_pulse_shape('rect', sim.Mct); % assumes rectangular pulse shape
Htxpshape = freqz(pulse_shape.h/abs(sum(pulse_shape.h)), 1, sim.f, sim.fs);
HrxPshape = conj(Htxpshape.*Tx.filt.H(sim.f/sim.fs).*Tx.Mod.H.*Fiber.Hdisp(sim.f, Tx.Laser.lambda));
[~, eq] = equalize(eq, [], HrxPshape, [], sim); % this generates zero-forcing linear equalizer, which should be a good
% approximation of MMSE linear equalizer.
noiseBW_noiseEnhance = trapz(sim.f, abs(eq.Hrx.*eq.Hff(sim.f/Rs)).^2)/2; % one-sided noise bandwidth

% Estimate SNR including noise enhacement penalty of an ideal symbol-rate linear equalizer   
varShot = 2*Rx.PD.varShot(Ppd, noiseBW_noiseEnhance);                               % Shot noise variance per real dimension
varThermal = Rx.N0*noiseBW_noiseEnhance;                                            % Thermal noise variance per real dimension
varASE = Sase*noiseBW_noiseEnhance;
SNRdB_noise_enhancement = 10*log10(Psig./(varASE + varShot + varThermal));
ber_noise_enhancement = berAWGN(SNRdB_noise_enhancement);
