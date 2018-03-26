%% Calculate Levin-Campello algorithm for Margin-Adaptive (MA) problem
% This is the optimal solution for the problem of minimizing the required
% signal power to achieve a fixed bit rate B
%% input:
% B = fixed bit rate
% beta = Information Granularity: is the smallest incremental unit of information that can be transmitted
% Pb = target BER
% GNR = gain-to-noise ratio: bn = log2(1 + PnGNRn/Gamman)
%% output:
% b = optmized bit loading
% CS = QAM constellation size
% Pn = optmized power allocation
% Gamman = GAP for nth subcarrier

function [b, CS, Pn, Gamman] = Levin_Campello_MA(B, beta, Pb, GNR)

MaxIt = 1e3; % max number of iterations
bmax = 15; % max number of bits per constellation

% Calculate Gamma up to maxCS
if Pb == 1.8e-4 % has been calculated previously for bmax = 15
    Gamma = [6.36457532076524,4.24305021384349,5.30933146925728,4.06393391058273,3.93948889832585,3.90784828565409,3.75113964906551,3.77233893059315,3.61235757115905,3.65463901000649,3.49754120091491,3.55200069226729,3.40023475931313,3.46191408373199,3.31610809620358,3.38221243749296;];
else
    Gamma = zeros(1, bmax+1);
    for k = 1:bmax+1
        CS = 2^k;
        snr_pb = fzero(@(x) berqam(CS, x) - Pb, 10);
        snr_cap = fzero(@(x) log2(1 + 10^(x/10)) - log2(CS), 10);
        GammadB = snr_pb-snr_cap;
        Gamma(k) = 10^(GammadB/10);
    end
end

% Differential energy
dE = @(bn, gn) dEvector(bn, gn, beta, Gamma);

% Minimum number of bits per constellation
bmin = 0;

%% 1. Choose any b
% b = 2*ones(size(GNR));
% b = randi([2 bmax-4], size(GNR));
b = floor(B/length(GNR))*ones(size(GNR));

%% 2. Make b efficient with the EF algorithm (Efficientizing)
nz = find(b - beta >= bmin); % nonzero b >= bmin

enb = dE(b, GNR);
enbb = dE(b + beta, GNR);

[~, m] = min(enbb);
[~, n] = max(enb(nz));

k = 1;
while enbb(m) < enb(nz(n)) && k < MaxIt
    b(m) = b(m) + beta;
    b(nz(n)) = b(nz(n)) - beta; 

    enb = dE(b, GNR);
    enbb = dE(b + beta, GNR);
    
    [~, m] = min(enbb);
    nz = find(b - beta >= bmin); % nonzero b
    
    [~, n] = max(enb(nz)); 
    
    k = k + 1;
end

% assert(k ~= MaxIt, 'Efficientizing did not converge!')

% Check if EF converged. If it didnot converge it means that the algorithm
% wanted to set some subcarriers to zero, but the restriction on the
% minimum constellation size did not allow it.
% if k ==  MaxIt
%     %warning('EF did not converge!')
% end

%% 3. B-tighten the resultant b with the BT algorithm 
k = 1;
while sum(b) ~= B && k < MaxIt
    if sum(b) > B
        nz = find(b - beta >= bmin);
        enb = dE(b, GNR);       
        [~, n] = max(enb(nz));
        
        b(nz(n)) = b(nz(n)) - beta;
    else
        [~, m] = min(dE(b + beta, GNR));
        b(m) = b(m) + beta;
    end
    k = k + 1;
end

assert(k ~= MaxIt, 'B-tighten did not converge!')
assert(sum(b) == B, 'LC did not converge')

CS = zeros(size(b));
CS(b~=0) = 2.^b(b~=0);
Pn = zeros(size(b));
Pn(b~=0) = (Gamma(b(b~=0))./GNR(b~=0)).*(CS(b~=0)-1); % since b = log2(1 + PnGNRn/Gamman)
Gamman = zeros(size(b));
Gamman(b~=0) = Gamma(b(b~=0));
end

function dEn = dEvector(bn, gn, beta, Gamma) 
%% Incremental energy: E(b) - E(b - beta)
    E = @(bn, gn) 2*(Gamma(bn)./gn).*(2.^bn-1); %% Energy function for QAM constellation with gap approximation

    dEn = zeros(size(bn));
    for k = 1:length(bn)
        if bn(k) == 0 || gn(k) == 0
            dEn(k) = Inf;
        elseif bn(k) == 1
            dEn(k) = E(bn(k), gn(k));
        else
            dEn(k) = E(bn(k), gn(k)) - E(bn(k)-beta, gn(k)); % Incremental energy
        end
    end
end