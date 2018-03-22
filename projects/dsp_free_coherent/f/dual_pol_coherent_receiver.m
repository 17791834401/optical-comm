function Y = dual_pol_coherent_receiver(Erec, ELO, Rx, sim)
%% Dual polarization coherent receiver: includes 90deg hybrid, 4 balanced photodiodes, transimpedance amplifier adding thermal noise, and coarse automatic gain control
% Inputs:
% - Erec: electric field of received signal [2 x N]
% - ELO: electric field of local oscillator [2 x N]
% - Rx: receiver parameters
% - sim: simulation parameters
% Note: if Erec and ELO are for [2 x 1] i.e., OPLL simulation, then this
% function and subfunctions cannot performed filtering

rPBS = 10^(Rx.PolSplit.Rext/10);              % extinction ratio of PBS

E1rec = Erec(1,:);      % received signal in x pol.
E2rec = Erec(2,:);      % received signal in y pol.

% split signal + ASE
if strcmp(Rx.PolSplit.sig,'PBS')
    Es1 = [sqrt(rPBS/(1+rPBS))*E1rec;   % sig + ASE field in x pol. at output 1 of PBS
           sqrt(1/(1+rPBS))*E2rec];      % sig + ASE field in y pol. at output 1 of PBS
    Es2 = [sqrt(1/(1+rPBS))*E1rec;      % sig + ASE field in x pol. at output 2 of PBS   
           sqrt(rPBS/(1+rPBS))*E2rec];   % sig + ASE field in y pol. at output 2 of PBS
elseif strcmp(Rx.PolSplit.sig,'3dB')
    [Es1, Es2] = powerSplitter(Erec, 0, 0.5, 0);
end

% perform polarization splitting of LO (ignore phase shifts in beamsplitters, which don't affect performance)
if strcmp(Rx.PolSplit.LO,'PBS')
    EL1 = [sqrt(rPBS/(1+rPBS))*ELO(1, :);   % LO field in x pol. at output 1 of PBS
           sqrt(1/(1+rPBS))*ELO(2, :)];      % LO field in y pol. at output 1 of PBS
    EL2 = [sqrt(1/(1+rPBS))*ELO(1, :);      % LO field in x pol. at output 2 of PBS
            sqrt(rPBS/(1+rPBS))*ELO(2, :)];   % LO field in y pol. at output 2 of PBS
elseif strcmp(Rx.PolSplit.LO,'3dB')
    [EL1, EL2] = powerSplitter(ELO, 0, 0.5, 0);
end

% 90deg Hybrid
% Note: fields are 2 x N matrices, where each row is one polarization
% Power splitter of signal and LO for pol 1
[Es1i, Es1q] = powerSplitter(Es1, 0, Rx.Hybrid.fS, 0);
[EL1i, EL1q] = powerSplitter(EL1, 0, Rx.Hybrid.fL, 0);
% Power splitter of signal and LO for pol 2
[Es2i, Es2q] = powerSplitter(Es2, 0, Rx.Hybrid.fS, 0);
[EL2i, EL2q] = powerSplitter(EL2, 0, Rx.Hybrid.fL, 0);

% Note: last indices 1 and 2 refer to output ports rather than polarizations
% Power splitter of I of pol 1
[E1i1, E1i2] = powerSplitter(Es1i, EL1i*exp(-1j*pi/2), Rx.Hybrid.fI, Rx.Hybrid.phiI01deg, Rx.Hybrid.tauIps, sim.f);
% Power splitter of Q of pol 1
[E1q1, E1q2] = powerSplitter(Es1q, EL1q, Rx.Hybrid.fQ, Rx.Hybrid.phiQ01deg, Rx.Hybrid.tauQps, sim.f);

% Power splitter of I of pol 2
[E2i1, E2i2] = powerSplitter(Es2i, EL2i*exp(-1j*pi/2), Rx.Hybrid.fI, Rx.Hybrid.phiI02deg, Rx.Hybrid.tauIps, sim.f);
% Power splitter of Q of pol 2
[E2q1, E2q2] = powerSplitter(Es2q, EL2q, Rx.Hybrid.fQ, Rx.Hybrid.phiQ02deg, Rx.Hybrid.tauQps, sim.f);

% perform photodetection
Y1idet = Rx.PD.detect(E1i1, sim.fs, 'gaussian')...
    - Rx.PD.detect(E1i2, sim.fs, 'gaussian'); % I output, pol. branch 1

Y1qdet = Rx.PD.detect(E1q1, sim.fs, 'gaussian')...
    - Rx.PD.detect(E1q2, sim.fs, 'gaussian'); % Q output, pol. branch 1

Y2idet = Rx.PD.detect(E2i1, sim.fs, 'gaussian')...
    - Rx.PD.detect(E2i2, sim.fs, 'gaussian'); % I output, pol. branch 2

Y2qdet = Rx.PD.detect(E2q1, sim.fs, 'gaussian')...
    - Rx.PD.detect(E2q2, sim.fs, 'gaussian'); % Q output, pol. branch 2

% Add thermal noise
Y1idet = Y1idet + sqrt(Rx.N0*sim.fs/2)*randn(size(Y1idet));
Y1qdet = Y1qdet + sqrt(Rx.N0*sim.fs/2)*randn(size(Y1qdet));
Y2idet = Y2idet + sqrt(Rx.N0*sim.fs/2)*randn(size(Y2idet));
Y2qdet = Y2qdet + sqrt(Rx.N0*sim.fs/2)*randn(size(Y2qdet));

% Form output
Y = [Y1idet + 1j*Y1qdet; Y2idet + 1j*Y2qdet];