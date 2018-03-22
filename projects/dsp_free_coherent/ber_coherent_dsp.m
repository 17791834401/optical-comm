function [ber, SNRdBtheory, OSNRdBtheory] = ber_coherent_dsp(Tx, Fiber, Rx, sim)
%% Calculate BER of coherent system with DSP-based receiver for values of launched power specified Tx.PlaunchdB

ModFormat = sim.ModFormat;

% Ensures that modulation format is QPSK or DQPSK
% assert(ModFormat.M == 4, 'ber_coherent_dsp: Modulation format must be quarternary')

%% Generate transmitted symbols
% Note 1: this implement assumes that no DAC is being used so ModFormat.signal
% generates rectangular pulses sampled at sim.fs
% Note 2: ModFormat.signal does not remove group delay due to pulse shaping
% so the center of the pulse is at (Mct+1)/2, if pulse shape is 'rect'
dataTX = randi([0 ModFormat.M-1], [2, sim.Nsymb]); % symbol stream for each polarization
Nzero = 10; % zero Nzero first and last symbols to make sequence periodic
dataTX(:, 1:Nzero) = 0;
dataTX(:, end-Nzero+1:end) = 0;

[Vin, symbolsTX] = ModFormat.signal(dataTX); % X & Y pol

% Filter drive waveforms for modulators txfilt.
% group delay of Tx.filt.H has already been removed
Htx = ifftshift(Tx.filt.H(sim.f/sim.fs).*exp(1j*2*pi*sim.f/sim.fs*ModFormat.pulse_shape_grpdelay)); % transmitter filter and remove group delay due to pulse shaping in ModFormat
Vout(1, :) = real(ifft(fft(real(Vin(1, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(1, :))).*Htx)); 
Vout(2, :)= real(ifft(fft(real(Vin(2, :))).*Htx)) + 1j*real(ifft(fft(imag(Vin(2, :))).*Htx));

% BER of ideal system with receiver filtering equal to matched filter
[ber.theory, ~, SNRdBtheory] = ber_coherent_awgn(Tx, Fiber, Rx, sim);
% Note: SNRdBtheory is calculated assuming that the receiver noise
% bandwidth is Rs/2. This approximation is good for DSP-based systems,
% since the cascade of antialiasing filter + equalizer approximately
% matches an ideal receiver with matched filtering. However, for
% analog-based systems this approximation may lead to 1-2 dB error in the
% SNRdB due to imperfect receiver filtering

%% Swipe launched power
% Transmitted power swipe
ber.count = zeros(size(Tx.PlaunchdBm));
M = ModFormat.M;
Enorm = mean(abs(pammod(0:log2(M)-1, log2(M))).^2);
OSNRdBtheory = Inf + zeros(size(Tx.PlaunchdBm)); % only meaningful if system is amplified
for k = 1:length(Tx.PlaunchdBm)
    fprintf('-- Launch power: %.2f dBm\n', Tx.PlaunchdBm(k));
    Nvalid = 1; % when the window to measure BER starts
    
    %% ========= Modulator ==========
    Tx.Laser.PdBm = Tx.PlaunchdBm(k);
    Ein = Tx.Laser.cw(sim); % Generates electric field with intensity and phase noise       
    Ein = mzm(Ein, Vout, Tx.Mod); % modulate optical signal using eletro-optical modulator (EOM)
    
    % Ensure that transmitted power is a desired level
    Ein = Ein*sqrt(dBm2Watt(Tx.PlaunchdBm(k))/sum(mean(abs(Ein).^2, 2)));

    %% ========= Propagation ========== 
    Erec = Fiber.linear_propagation(Ein, sim.f, Tx.Laser.lambda);
    
    if isfield(sim, 'preAmp') && sim.preAmp % only included if sim.preAmp is true
        disp('- IMPORTANT: Simulation including optical amplifier!')
        [Erec, OSNRdBtheory(k)] = Rx.OptAmp.amp(Erec, sim.fs);
        Rx.OptAmp.GaindB
        % Measure OSNR
        Osa = OSA(0.4); % optical spectrum analyser with resolution 0.4nm
        % Uses resolution high enough to capture all signal power, then
        % convert OSNR to 0.1nm
        [~, OSNRdBmeasured] = Osa.estimate_osnr(Erec, Tx.Laser.wavelength, sim.f, sim.shouldPlot('OSNR'));

        fprintf('OSNR = %.2f dB (theory)\nOSNR = %.2f dB (measured)\n', OSNRdBtheory(k), OSNRdBmeasured)
               
        % check
%         OSNRdBtheorycheck = 10*log10(dBm2Watt(Tx.PlaunchdBm(k))/(2*Rx.OptAmp.nsp*Rx.OptAmp.h*Rx.OptAmp.c/Tx.Laser.lambda*12.5e9))
%         SNRdBtheorycheck = 10*log10(dBm2Watt(Tx.PlaunchdBm(k))/(Rx.OptAmp.nsp*Rx.OptAmp.h*Rx.OptAmp.c/Tx.Laser.lambda*sim.Rs))
    end
    
    %% ========= Receiver =============
    ELO = Rx.LO.cw(sim); % generates continuous-wave electric field in 1 pol with intensity and phase noise
    ELO = [sqrt(1/2)*ELO;    % LO field in x polarization at PBS or BS input
           sqrt(1/2)*ELO];    % LO field in y polarization at PBS or BS input
    Yrx = dual_pol_coherent_receiver(Erec, ELO, Rx, sim);
    
    %% Automatic gain control (AGC)
    Yrx = [sqrt(Enorm./mean(abs(Yrx(1, :)).^2))*Yrx(1, :);...
        sqrt(Enorm./mean(abs(Yrx(2, :)).^2))*Yrx(2, :)];
      
    % Introduces skew between X and Y polarizations
    if isfield(sim, 'polSkewSamples') && sim.polSkewSamples > 0
        fprintf('> Y pol delayed by %d samples (%.3f ps)\n', sim.polSkewSamples, 1e12*sim.polSkewSamples/sim.fs)
        Yrx(2, :) = circshift(Yrx(2, :), [0 sim.polSkewSamples]); % delays  Y polarization by sim.polSkewSamples samples     end
    end
    
    %% Sampling    
    % Digital to analog conversion: antialiasing filter, sampling, and
    % quantization
    [Yxi, varQ(1)] = adc(real(Yrx(1, :)), Rx.ADC, sim);
    [Yxq, varQ(2)] = adc(imag(Yrx(1, :)), Rx.ADC, sim);
    [Yyi, varQ(3)] = adc(real(Yrx(2, :)), Rx.ADC, sim);
    [Yyq, varQ(4)] = adc(imag(Yrx(2, :)), Rx.ADC, sim);

    Ys = [Yxi + 1j*Yxq; Yyi + 1j*Yyq];
       
    %% Equalization
    switch upper(Rx.AdEq.type) 
        case 'CMA'
            [Yeq, W, MSE] = fse_cma(Ys, Rx.AdEq, sim.shouldPlot('Equalizer')); % equalization
        case 'LMS'
            Rx.AdEq.trainSeq = symbolsTX;
            Rx.AdEq.M = ModFormat.M;
            [Yeq, W, MSE] = lms_td_fse(Ys, Rx.AdEq, sim.shouldPlot('Equalizer'));
        otherwise
            error('ber_coherent/Unknown Rx.AdEq.type option')
    end
    Nvalid = Nvalid + Rx.AdEq.Ntrain; % discard symbols used in training equalizer
    Yeq(:, 1:Rx.AdEq.Ntrain) = [];    
    Y = Yeq;
    
    %% Carrier frequency estimation
    if Rx.LO.freqOffset ~= 0 && ModFormat.M == 4
        Rx.FreqRec.Rs = ModFormat.Rs;
        Y = qpsk_freq_rec(Yeq, Rx.FreqRec, sim.shouldPlot('Frequency offset estimation'));
        Nvalid = Nvalid + Rx.FreqRec.Ntrain; % discard symbols used in training phase tracking algorithm
        Y(:, 1:Rx.FreqRec.Ntrain) = [];             
    end
    % Note: only course frequency offset compensation may be necessary for
    % DQPSK
    
    %% Carrier phase recovery algorithm
    if strcmpi(ModFormat.type, 'QAM') % not done if DQPSK
        Ycpr = Y;
        Rx.CPR.trainSeq = symbolsTX(:, Nvalid:end);
        if strcmpi(Rx.CPR.type, 'feedforward')
            Rx.CPR.SNRdB = SNRdBtheory(k);
            Rx.CPR.varPN = Tx.Laser.varPN(sim.Rs) + Rx.LO.varPN(sim.Rs);
            
            % Feedforward carrier recovery
            Ycpr = feedforward_cpr(Ycpr, Rx.CPR, ModFormat, sim.shouldPlot('Feedforward phase error'));      
            Nvalid = Nvalid + Rx.CPR.Ntrain; % discard symbols used in training carrier phase recovery algorithm
            Ycpr(:, 1:Rx.CPR.Ntrain) = [];            
        elseif strcmpi(Rx.CPR.type, 'DPLL')
            % DPLL
            Ycpr = dpll(Yeq, Rx.CPR, ModFormat, sim.shouldPlot('DPLL phase error'));
            Nvalid = Nvalid + Rx.CPR.Ntrain; % discard symbols used in training carrier phase recovery algorithm
            Ycpr(:, 1:Rx.CPR.Ntrain) = [];
        elseif strcmpi(Rx.CPR.type, 'None')
            disp('Skipping carrier phase recovery.')
        else
            error('ber_coherent/invalid carrier phase recovery type')
        end  
        Y = Ycpr;
    end
    
    %% Automatic gain control
    Y = [sqrt(2/mean(abs(Y(1, :)).^2))*Y(1, :);
         sqrt(2/mean(abs(Y(2, :)).^2))*Y(2, :)];
    
    %% Align received sequence and correct for phase rotation
    [c(1, :), ind] = xcorr(symbolsTX(1, Nvalid:end), Y(1, :), 20, 'coeff');
    c(2, :) = xcorr(symbolsTX(2, Nvalid:end), Y(2, :), 20, 'coeff');
       
    % maximum correlation position
    [~, p] = max(abs(c), [], 2);
    theta = [angle(c(1, p(1))), angle(c(2, p(2)))];
    
    % Circularly shift symbol sequence
    Y = [circshift(Y(1, :), [0 ind(p(1))]);...
        circshift(Y(2, :), [0 ind(p(2))])];
       
    % Rotate constellations
    Y = [Y(1, :).*exp(+1j*theta(1)); Y(2, :).*exp(+1j*theta(2))];
          
    fprintf('> X pol signal was shifted by %d samples\n', ind(p(1)))
    fprintf('> Y pol signal was shifted by %d samples\n', ind(p(2)))
    fprintf('> X pol constellation was rotated by %.2f deg\n', rad2deg(theta(1)))
    fprintf('> Y pol constellation was rotated by %.2f deg\n', rad2deg(theta(2)))
    
    %% Detection
    Nvalid = Nvalid + sim.Ndiscard;
    if strcmpi(ModFormat.type, 'QAM')
        dataRX = ModFormat.demod(Y(:, sim.Ndiscard+1:end-sim.Ndiscard));
    elseif strcmpi(ModFormat.type, 'DPSK')
        % Note: since DPSK has differential enconding, detection for BER
        % measurement is done after several symbols so that measurements are
        % not currepted by adaptitation, fft windowing, etc
        dataRX = ModFormat.demod(Y(:, sim.Ndiscard+1:end-sim.Ndiscard), symbolsTX(:, Nvalid-1));
    end

    %% BER calculation
    validRange = Nvalid:sim.Nsymb-sim.Ndiscard;
    [~, berX(k)] = biterr(dataTX(1, validRange), dataRX(1, :))
    [~, berY(k)] = biterr(dataTX(2, validRange), dataRX(2, :))
    ber.count(k) = 0.5*(berX(k) + berY(k));

   % Constellation plots
   if strcmpi(ModFormat.type, 'QAM') && sim.shouldPlot('Constellations')
       figure(203), clf
       subplot(221)
       plot_constellation(Yeq(1, sim.Ndiscard+1:end-sim.Ndiscard),...
           dataTX(1, Rx.AdEq.Ntrain+sim.Ndiscard+1:end-sim.Ndiscard), ModFormat.M);
       axis square
       title('Pol X: After equalization')
       subplot(222)
       plot_constellation(Y(1, sim.Ndiscard+1:end-sim.Ndiscard),...
           dataTX(1, sim.Nsymb-length(Y)+sim.Ndiscard+1:end-sim.Ndiscard), ModFormat.M);
       axis square
       title('Pol X: After CPR')   
       drawnow
       subplot(223)
       plot_constellation(Yeq(2, sim.Ndiscard+1:end-sim.Ndiscard),...
           dataTX(2, Rx.AdEq.Ntrain+sim.Ndiscard+1:end-sim.Ndiscard), ModFormat.M);
       axis square
       title('Pol Y: After equalization')
       subplot(224)
       plot_constellation(Y(2, sim.Ndiscard+1:end-sim.Ndiscard),...
           dataTX(2, sim.Nsymb-length(Y)+sim.Ndiscard+1:end-sim.Ndiscard), ModFormat.M);
       axis square
       title('Pol Y: After CPR')   
       drawnow
   end 
   
   % Stop simulation when counted BER reaches 0
   if isfield(sim, 'stopWhenBERreaches0') && sim.stopWhenBERreaches0 && ber.count(k) == 0
       break
   end   
end

plots

if sim.shouldPlot('BER') && length(ber.count) > 1
    figure(100), box on, hold on
    [~, link_attdB] = Fiber.link_attenuation(Tx.Laser.lambda);
    Prx = Tx.PlaunchdBm - link_attdB;
    plot(Prx, log10(ber.theory), '-', 'DisplayName', 'Theory');
    plot(Prx, log10(ber.count), '-o', 'DisplayName', 'Count');
    legend('-dynamiclegend')
    xlabel('Received Power (dBm)')
    ylabel('log_{10}(BER)')
    axis([Prx(1) Prx(end) -8 0])
    
    if sim.preAmp
        figure(101), box on, hold on
        plot(OSNRdBtheory, log10(ber.theory), '-', 'DisplayName', 'Theory');
        plot(OSNRdBtheory, log10(ber.count), '-o', 'DisplayName', 'Count');
        legend('-dynamiclegend')
        xlabel('OSNR (dB)')
        ylabel('log_{10}(BER)')
        axis([floor(OSNRdBtheory(1)) ceil(OSNRdBtheory(end)) -8 0])
    end
end
    
