function BER = DQPSK_Analog_BER_qsub(fiberLengthKm, wavelengthnm, ModBWGHz, linewidthKHz)
%% Estimate BER of a DQPSK system based on analog receiver
% - fiberLength: fiber length in km
% - Modulator: type of bandwidth bandwidth response. Either 'MZM': limited 
% by velocity mismatch and loss or 'SiPhotonics': parasitics 
% - ModBW: modulator bandwidth in GHz. Only used when Modulator == 'SiPhotonics'
% - linewidth: laser linewidth in kHz

addpath f/
addpath analog/
addpath ../f/
addpath ../apd/

%
filename = sprintf('results/DQPSK_Analog_BER_L=%skm_lamb=%snm_ModBW=%sGHz_linewidth=%skHz.mat',...
        fiberLengthKm, wavelengthnm, ModBWGHz, linewidthKHz)

% convert inputs to double (on cluster inputs are passed as strings)
if ~all(isnumeric([fiberLengthKm, wavelengthnm, ModBWGHz, linewidthKHz]))
    fiberLength = 1e3*str2double(fiberLengthKm);
    wavelength = 1e-9*str2double(wavelengthnm);
    ModBW = 1e9*str2double(ModBWGHz);
    linewidth = 1e3*str2double(linewidthKHz);
end

%% Simulation launched power swipe
Tx.PlaunchdBm = -38:0.5:-28;
% Tx.PlaunchdBm = -25;

%% ======================== Simulation parameters =========================
sim.Nsymb = 2^17; % Number of symbols in montecarlo simulation
sim.Mct = 4;    % Oversampling ratio to simulate continuous time 
sim.BERtarget = 1.8e-4; 
sim.Ndiscard = 1024; % number of symbols to be discarded from the begining and end of the sequence 
sim.N = sim.Mct*sim.Nsymb; % number points in 'continuous-time' simulation
sim.Rb = 2*112e9; % Bit rate
sim.Npol = 2;                                                              % number of polarizations
sim.Modulator = 'SiPhotonics';                                             % Modulator bandwidth limitation: {'MZM': limited by loss and velocity mismatch, 'SiPhotonics' : limited by parasitics (2nd-order response)}
sim.pulse_shape = select_pulse_shape('rect', sim.Mct);                     % pulse shape
sim.ModFormat = DPSK(4, sim.Rb/sim.Npol, sim.pulse_shape);                     % M-DPSK modulation format
sim.Realizations = 4;

% Simulation control
sim.RIN = true; 
sim.PMD = false;
sim.phase_noise = (linewidth ~= 0);
sim.preAmp = false;
sim.stopWhenBERreaches0 = true;                                            % whether to stop simulation after counter BER reaches 0
sim.save = true;

%% Plots
Plots = containers.Map();                                                   % List of figures 
Plots('BER')                  = 0; 
Plots('Eye diagram') = 0;
Plots('Channel frequency response') = 0;
Plots('Constellations') = 0;
Plots('Diff group delay')       = 0;
Plots('Phase tracker') = 0;
Plots('EPLL phase error') = 0;
Plots('Time recovery') = 0;
Plots('Phase error variance') = 0;
sim.Plots = Plots;
sim.shouldPlot = @(x) sim.Plots.isKey(x) && sim.Plots(x);

%% Time and frequency
sim.Rs = sim.ModFormat.Rs; % symbol rate
sim.fs = sim.ModFormat.Rs*sim.Mct;  % sampling frequency for 'continuous-time' simulation
[sim.f, sim.t] = freq_time(sim.N, sim.fs);

%% ===================== Transmitter Electric Filter ====================== 
Tx.filt = design_filter('bessel', 5, 0.7*sim.ModFormat.Rs/(sim.fs/2));      % design_filter(type, order, normalized cutoff frequency)
Tx.Delx  = 0;                                                               % Delay of x pol. in pol. mux. (symbol intervals)
Tx.Dely  = 0;                                                               % Delay of y pol. in pol. mux. (symbol intervals)

%% ========================== Transmitter Laser =========================== 
% Laser constructor: laser(lambda (nm), PdBm (dBm), RIN (dB/Hz), linewidth (Hz), frequency offset (Hz))
% lambda : wavelength (nm)
% PdBm : output power (dBm)
% RIN : relative intensity noise (dB/Hz)
% linewidth : laser linewidth (Hz)
% freqOffset : frequency offset with respect to wavelength (Hz)
Tx.Laser = laser(wavelength, 0, -150, linewidth, 0);

%% ============================= Modulator ================================
if strcmpi(sim.Modulator, 'MZM') 
    %% Mach-Zehnder (limited by velocity mismatch and loss)
    % Mod = mzm_frequency_response(ratio : velocity mismatch, L : iteractive length in m, f: frequency vector, verbose: whether to plot results)
    Tx.Mod = mzm_frequency_response(0.98, 0.05, sim.f, true);
elseif strcmpi(sim.Modulator, 'SiPhotonics') 
    %% Si Photonics (limited by parasitics, 2nd-order response)
    Tx.Mod.BW = ModBW;
    Tx.Mod.fc = Tx.Mod.BW/sqrt(sqrt(2)-1); % converts to relaxation frequency
    Tx.Mod.grpdelay = 2/(2*pi*Tx.Mod.fc);  % group delay of second-order filter in seconds
    Tx.Mod.H = exp(1j*2*pi*sim.f*Tx.Mod.grpdelay)./(1 + 2*1j*sim.f/Tx.Mod.fc - (sim.f/Tx.Mod.fc).^2);  % laser freq. resp. (unitless) f is frequency vector (Hz)
end

%% =============================== Fiber ==================================
% Constructor: fiber(L, att(lamb) (optional), D(lamb) (optional)) 
% L : fiber length (m)
% att(lamb) : function handle of attenuation (att) at wavelength (lamb),
% deafault is att(lamb) = 0 dB/km
% D(lamb) : function handle of dispersion (D) at wavelength (lamb) in ps/(kmnm),
% default is D(lamb) = SSMF with lamb0 @ 1310 ps/(kmnm)
Fiber = fiber(fiberLength);
Fiber.PMD = sim.PMD;                                                       % whether to similate PMD
Fiber.meanDGDps = 0.1;                                                     % Mean DGD (ps)
Fiber.PMD_section_length = 1e3;                                            % Controls number of sections to simulate PMD (m)

%% ======================== Optical Amplifier =============================
% Constructor: OpticalAmplifier(Operation, param, Fn, Wavelength)
% - Opertation: either 'ConstantOutputPower' or 'ConstantGain'
% - param: GaindB if Operation = 'ConstantGain', or outputPower
% if Operation = 'ConstantOutputPower'
% - Fn:  noise figure in dB
% - Wavelength: operationl wavelength in m
Rx.OptAmp = OpticalAmplifier('ConstantOutputPower', 0, 5, Tx.Laser.wavelength);
% Rx.OptAmp = OpticalAmplifier('ConstantGain', 20, 5, Tx.Laser.wavelength);
% Note: the amplifier here operates in the constant output power mode,
% where the output power after amplification is set to Rx.AmpOutPowerdBm

%% ======================= Local Oscilator ================================
Rx.LO = Tx.Laser;                                                          % Copy parameters from TX laser
Rx.LO.PdBm = 15;                                                           % Total local oscillator power (dBm)
Rx.LO.freqOffset = 0e9;                                                    % Frequency shift with respect to transmitter laser in Hz

%% ============================ Hybrid ====================================
% polarization splitting --------------------------------------------------
Rx.PolSplit.sig  = 'PBS';                                                   % pbs: polarization beamsplitter
Rx.PolSplit.LO   = 'PBS';                                                   % 3dB: 3-dB coupler     
Rx.PolSplit.Rext = 30;                                                      % PBS extinction ratio (dB), default = 30
Rx.PolSplit.R3dB = 1/2;                                                     % power splitting ratio of nominally 3-dB coupler (system performance should be insensitive to this parameter)
% 90-degree hybrid, same parameter for two polarizations ------------------
Rx.Hybrid.fS = 0.5;                                                         % power splitting ratio for signal coupler (W/W), default = 0.5
Rx.Hybrid.fL = 0.5;                                                         % power splitting ratio for LO coupler (W/W), default = 0.5
Rx.Hybrid.fI = 0.5;                                                         % power splitting ratio for in-phase coupler (W/W), default = 0.5
Rx.Hybrid.fQ = 0.5;                                                         % power splitting ratio for quadrature coupler (W/W), default = 0.5
Rx.Hybrid.tauIps = 0;                                                       % delay in in-phase branch (ps), default = 0
Rx.Hybrid.tauQps = 0;                                                       % delay in quadrature branch (ps), default = 0
Rx.Hybrid.phiI01deg = 0;                                                   % d.c. phase shift in I branch of pol. 1 (degrees), default = 0
Rx.Hybrid.phiQ01deg = 0;                                                    % d.c. phase shift in Q branch of pol. 1 (degrees), default = 0
Rx.Hybrid.phiI02deg = 0;                                                   % d.c. phase shift in I branch of pol. 2 (degrees), default = 0
Rx.Hybrid.phiQ02deg = 0;                                                    % d.c. phase shift in Q branch of pol. 2 (degrees), default = 0

%% ============================= Photodiodes ==============================
% Constructor: pin(R, Id, BW (optional))
% R : responsivity in A/W
% Id : dark current in A
% BW : bandwidth, default = Inf. Frequency response is a
% first-order filter with bandwidth BW.
Rx.PD = pin(1, 10e-9);

%% ======================== Transimpedance Amplifier ======================
Rx.N0 = (30e-12)^2;                                                        % One-sided thermal noise PSD per real dimension
% Note: ADC filter includes all the frequecy responses from the receiver

%% ========================= Analog Components ============================
%% Receiver filter
Rx.Analog.filt = design_filter('butter', 5, 0.7*sim.ModFormat.Rs/(sim.fs/2));

%% ========================= Time recovery ================================
% Two types are supported: 'spectral-line'
% Spectral line method: nonlinearity (squarer) -> BPF or PLL
% Rx.TimeRec.type = 'spectral-line-bpf';
% Rx.TimeRec.type = 'spectral-line-pll';
Rx.TimeRec.type = 'none';

% Additional paramters for 'spectral-line-bpf'
BW = 1e9;
Rx.TimeRec.Mct = 16; % oversampling ratio of continuous time used in TimeRecovery
Rx.TimeRec.fs = Rx.TimeRec.Mct*sim.ModFormat.Rs;
lpf = design_filter('bessel', 5, BW/(Rx.TimeRec.fs/2));
[bpf.num, bpf.den] = iirlp2bp(lpf.num, lpf.den, BW/(Rx.TimeRec.fs/2), sim.ModFormat.Rs/(Rx.TimeRec.fs/2) + BW/(Rx.TimeRec.fs/2)*[-1 1]); % converts to BPF
Rx.TimeRec.bpf = bpf;
Rx.TimeRec.bpf.H = @(f) freqz(bpf.num, bpf.den, 2*pi*f).*exp(1j*2*pi*f*grpdelay(bpf.num, bpf.den, 1));

% Additional paramters for 'spectral-line-pll'
Rx.TimeRec.csi = sqrt(2)/2; % damping
Rx.TimeRec.wn = 2*pi*3e9; % relaxation frequency of PLL
Rx.TimeRec.CT2DT = 'bilinear'; % continuous-time to discrete-time conversion method 
Rx.TimeRec.detect = @(x) sign(x); % decision device 

%% Generate summary
coherent_simulation_summary(sim, Tx, Fiber, Rx);

%% Runs simulation
parfor k = 1:sim.Realizations
    BER(k) = ber_coherent_analog_dpsk(Tx, Fiber, Rx, sim);
end

if sim.save   
    % delete large variables
    sim = rmfield(sim, 'f');
    sim = rmfield(sim, 't');
    Tx.Mod = rmfield(Tx.Mod, 'H');
    save(filename)
end