function frequency_tracking_coherent_analog_qpsk(Tx, Fiber, Rx, sim)
%% Hold in range of coherent receiver

Qpsk = sim.ModFormat;
Analog = Rx.Analog;

% Ensures that modulation format is QPSK
assert(strcmpi(class(Qpsk), 'QAM') && Qpsk.M == 4, 'ber_coherent_analog: Modulation format must be QPSK')

%% Generate transmitted symbols
% Note 1: this implement assumes that no DAC is being used so ModFormat.signal
% generates rectangular pulses sampled at sim.fs
% Note 2: ModFormat.signal does not remove group delay due to pulse shaping
% so the center of the pulse is at (Mct+1)/2, if pulse shape is 'rect'
dataTX = randi([0 Qpsk.M-1], [2, sim.Nsymb]); % symbol stream for each polarization
Nzero = 10; % zero Nzero first and last symbols to make sequence periodic
dataTX(:, 1:Nzero) = 0;
dataTX(:, end-Nzero+1:end) = 0;

[Vin, symbolsTX] = Qpsk.signal(dataTX); % X & Y pol

% Filter drive waveforms for modulators txfilt.
% group delay of Tx.filt.H has already been removed
Htx = ifftshift(Tx.filt.H(sim.f/sim.fs).*exp(1j*2*pi*sim.f/sim.fs*(Qpsk.pulse_shape_grpdelay))); % transmitter filter and remove group delay due to pulse shaping in ModFormat
Vout(1, :) = real(ifft(fft(real(Vin(1, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(1, :))).*Htx)); 
Vout(2, :)= real(ifft(fft(real(Vin(2, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(2, :))).*Htx));

%% ========= Modulator ==========
Tx.Laser.PdBm = Tx.PlaunchdBm;
Ein = Tx.Laser.cw(sim); % Generates electric field with intensity and phase noise
Ein = mzm(Ein, Vout, Tx.Mod); % modulate optical signal using eletro-optical modulator (EOM)

% Ensure that transmitted power is at desired level
Ein = Ein*sqrt(dBm2Watt(Tx.PlaunchdBm)/sum(mean(abs(Ein).^2, 2)));

%% ========= Propagation ==========
Fiber.PMD = false; 
% Note: since polarization demultiplexing is not done here, the fiber
% must maitain polarization states.
Erec = Fiber.linear_propagation(Ein, sim.f, Tx.Laser.lambda);

%% ========= Receiver =============
ELO = Rx.LO.cw(sim); % generates continuous-wave electric field in 1 pol with intensity and phase noise
ELO = [sqrt(1/2)*ELO;    % LO field in x polarization at PBS or BS input
       sqrt(1/2)*ELO];    % LO field in y polarization at PBS or BS input
Yrx = dual_pol_coherent_receiver(Erec, ELO, Rx, sim);

%% Receiver filter
Hrx = ifftshift(Analog.filt.H(sim.f/sim.fs));
Ys = [real(ifft(fft(real(Yrx(1, :))).*Hrx)) + 1j*real(ifft(fft(imag(Yrx(1, :))).*Hrx));...
      real(ifft(fft(real(Yrx(2, :))).*Hrx)) + 1j*real(ifft(fft(imag(Yrx(2, :))).*Hrx))];

%% Carrier phase recovery
switch lower(Analog.CarrierPhaseRecovery)
    case 'epll' %% Carrier phase recovery via electric PLL (EPLL)
        switch lower(Analog.CPRmethod)
            case 'costas' % EPLL using Costas loop for phase estimation
               [Xs, Analog, S, Sf] = analog_epll_costas(Ys, Tx.Laser.linewidth + Rx.LO.linewidth, Analog, sim);
            case 'logic' % EPLL using logic (XOR) operations for phase estimation
               [Xs, Analog, S, Sf] = analog_epll_logic(Ys, Tx.Laser.linewidth + Rx.LO.linewidth, Analog, sim);
            case '4th-power' % EPLL using 4th-power for phase estimation
                [Xs, Analog, S, Sf] = analog_epll_4thpower(Ys, Tx.Laser.linewidth + Rx.LO.linewidth, Analog, sim);
            otherwise
                error('ber_coherent_analog_epll: invalid electric PLL type %s\nAnalog.receiver must be either Costas or Logic\n', Analog.CPRmethod)
        end
    case 'feedforward'
        [Xs, Analog] = analog_feedforward(Ys, Analog, sim, sim.shouldPlot('Feedforward phase recovery'));
    case 'opll'
        error('ber_coherent_analog_epll: OPLL not implemented yet.')
    otherwise
        error('ber_coherent_analog_epll: invalid carrier phase recovery method %s\nAnalog.CarrierPhaseRecovery must be either EPLL, OPLL, or Feedforward\n',...
            Analog.CarrierPhaseRecovery)
end

dt = sim.t(2) - sim.t(1);
Ntaps = 101;
Sffilt = filtfilt(ones(1, Ntaps)/Ntaps, 1, Sf); 
figure(1), box on, hold on
plot(sim.t*1e9, Rx.LO.freqOffset/1e6, 'k')
plot(sim.t*1e9, diff([Sffilt Sffilt(end)])/(2*pi*dt*1e6))
xlabel('Time (ns)')
ylabel('Frequency (MHz)')
legend('LO Frequency', sprintf('VCO: PD = %s', Analog.CPRmethod), 'Location', 'SouthEast')
title('Frequency tracking')
axis tight

figure(2), box on, hold on
plot(sim.t*1e9, cumtrapz(sim.t, Rx.LO.freqOffset), 'k')
plot(sim.t*1e9, Sffilt)
xlabel('Time (ns)')
ylabel('Phase (rad/s)')
legend('LO phase', sprintf('VCO: PD = %s', Analog.CPRmethod), 'Location', 'SouthEast')
title('Phase tracking')
axis tight

%% Time recovery and sampling
% Note: clock obtained from I is used in Q in order to prevent
% differences in sampling between I and Q
[X(1, :), ~, Nsetup] = analog_time_recovery(Xs(1, :), Rx.TimeRec, sim, sim.shouldPlot('Time recovery'));
X(2, :) = analog_time_recovery(Xs(2, :), Rx.TimeRec, sim);

% Automatic gain control
X = [sqrt(2/mean(abs(X(1, :)).^2))*X(1, :);
     sqrt(2/mean(abs(X(2, :)).^2))*X(2, :)];

%% Align received sequence and correct for phase rotation
[c(1, :), ind] = xcorr(symbolsTX(1, :), X(1, :), 20, 'coeff');
c(2, :) = xcorr(symbolsTX(2, :), X(2, :), 20, 'coeff');

% maximum correlation position
[~, p] = max(abs(c), [], 2);
theta = [angle(c(1, p(1))), angle(c(2, p(2)))];

% Circularly shift symbol sequence
X = [circshift(X(1, :), [0 ind(p(1))]);...
    circshift(X(2, :), [0 ind(p(2))])];

% Rotate constellations
X = [X(1, :).*exp(+1j*theta(1)); X(2, :).*exp(+1j*theta(2))];

%% Detection
dataRX = Qpsk.demod(X);

% Valid range for BER measurement
validInd = sim.Ndiscard+Nsetup(1)+1:sim.Nsymb-sim.Ndiscard-Nsetup(2);

% BER calculation
[~, berX] = biterr(dataTX(1, validInd), dataRX(1, validInd))
[~, berY] = biterr(dataTX(2, validInd), dataRX(2, validInd))
ber.count = 0.5*(berX + berY);

% Constellation plots
if sim.shouldPlot('Constellations')
   figure(203), clf
   subplot(121)
   plot_constellation(X(1, validInd), dataTX(1, validInd), Qpsk.M);
   axis square
   title('Pol X')       
   subplot(122)
   plot_constellation(X(2, validInd), dataTX(2, validInd), Qpsk.M);
   axis square
   title('Pol Y')   
   drawnow
end 

if sim.shouldPlot('Symbol errors')
    figure(204), clf
    subplot(121)
    stem(dataTX(1, validInd) ~= dataRX(1, validInd))
    title('Pol X')       
    subplot(122)
    stem(dataTX(2, validInd) ~= dataRX(2, validInd))
    title('Pol Y')   
    drawnow
end

