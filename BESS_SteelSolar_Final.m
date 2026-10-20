%% BESS_SteelSolar_Final.m
% Steel plant (real 15-min load, 22 Nov 2018) + 300 kWp solar (PVGIS-ERA5, hourly) + BESS.
% Compares: A) grid only, B) solar only, C) solar + BESS.  EKF SoC estimation included.
% Needs steel_day.mat and pv_day.mat in the same folder as this script.
clear; clc; close all; rng(1);

%% 0. Switches
useSolar = false;     % true = sunny day (real 22 Nov 2018 solar), false = no solar (cloudy-day check)
thr      = 400;      % peak-shaving threshold [kW]

%% 1. Simulation setup
dt  = 60;                 % time step [s]
N   = 1440;               % one day at 1-min resolution
t_h = (0:N-1)' * dt/3600; % time [h, IST]

%% 2. Load (real), solar (real, PVGIS) and tariff (Odisha)
S  = load('steel_day.mat');
SP = load('pv_day.mat');
tq15    = (0.25:0.25:24)';                                       % end-of-interval times [h]
load_kW = max(interp1(tq15-0.125, S.day_kW(:), t_h, 'linear', 'extrap'), 0);
pv_all  = max(interp1((0:23)', SP.pv_day(:), t_h, 'linear', 'extrap'), 0);
pv_kW   = pv_all * double(useSolar);
net_kW  = load_kW - pv_kW;                                       % what the grid supplies without a battery

% Odisha OERC FY2026-27 (EHT), low load-factor band. ToD from 1 Jul 2026:
% 10% lower in solar hours (8-16), 10% higher in peak hours (18-24)
base = 5.80;                                                     % Rs per unit
tariff = base*0.9*(t_h>=8 & t_h<16) + base*1.1*(t_h>=18) + base*(t_h<8 | (t_h>=16 & t_h<18));
demand_rate = 250;                                               % Rs per kVA per month (kW treated as kVA)

%% 3. BESS parameters (pack level)
Ns = 170;  Qah = 860;  Qkwh = 500;
R0 = 0.012; R1 = 0.008; C1 = 2000;
tau = R1*C1;  a = exp(-dt/tau);
ocv  = @(s) Ns*(3.0 + s - 0.5*s.^2 + 0.3*s.^3);
docv = @(s) Ns*(1 - s + 0.9*s.^2);
Pmax = 250;                                                      % PCS rating [kW]
socMin = 0.10; socMax = 0.90;

%% 4. EMS: discharge above the threshold; recharge from 11:30 onward whenever below it
chargeStart = 11.5;

%% 5. Simulation of true battery + EMS
soc = 0.90; V1 = 0;
SOC = zeros(N,1); I_true = zeros(N,1); Vt = zeros(N,1); Pbat = zeros(N,1);
for k = 1:N
    h = t_h(k); net = net_kW(k);

    P = 0;                                                       % P > 0 discharge, P < 0 charge
    if net > thr
        P = min(net - thr, Pmax);
    elseif h >= chargeStart
        P = -min(Pmax, thr - net);                               % uses solar surplus first, never creates a new peak
    end
    if P > 0, P = min(P, (soc-socMin)*Qkwh*3600/dt); end
    if P < 0, P = -min(-P, (socMax-soc)*Qkwh*3600/dt); end
    P = max(min(P, Pmax), -Pmax);

    Veff = ocv(soc) - V1;
    Pw   = P*1000;
    I    = (Veff - sqrt(Veff^2 - 4*R0*Pw)) / (2*R0);             % discharge positive
    Vt(k) = Veff - R0*I;
    SOC(k) = soc; I_true(k) = I; Pbat(k) = P;

    soc = soc - I*dt/(3600*Qah);
    V1  = V1*a + R1*(1-a)*I;
end
grid_kW = net_kW - Pbat;

%% 6. Sensors and estimators
Vm = Vt + 1.0*randn(N,1);                                        % voltage noise [V]
Im = I_true + 2.0*randn(N,1) + 3.0;                              % current noise + 3 A offset [A]

soc_cc = zeros(N,1); soc_cc(1) = 0.80;                           % initial guess 10% low
for k = 2:N
    soc_cc(k) = soc_cc(k-1) - Im(k-1)*dt/(3600*Qah);
end

x = [0.80; 0]; Pc = diag([0.1^2, 1]);
Qn = diag([1e-9, 0.1]); Rn = 1.0^2;
soc_ekf = zeros(N,1); soc_ekf(1) = x(1);
for k = 2:N
    F = [1 0; 0 a];
    x = [x(1) - Im(k-1)*dt/(3600*Qah); a*x(2) + R1*(1-a)*Im(k-1)];
    Pc = F*Pc*F' + Qn;
    H  = [docv(x(1)), -1];
    yh = ocv(x(1)) - R0*Im(k) - x(2);
    S_ = H*Pc*H' + Rn;
    Kg = Pc*H'/S_;
    x  = x + Kg*(Vm(k) - yh);
    Pc = (eye(2) - Kg*H)*Pc;
    soc_ekf(k) = x(1);
end

%% 7. Metrics: three cases
costA = sum(load_kW.*tariff)*dt/3600;                            % A: grid only
costB = sum(max(net_kW,0).*tariff)*dt/3600;                      % B: solar only
costC = sum(max(grid_kW,0).*tariff)*dt/3600;                     % C: solar + BESS (no export credit assumed)
peakA = max(load_kW); peakB = max(max(net_kW,0)); peakC = max(max(grid_kW,0));
loss_kWh = sum(I_true.^2*R0)*dt/3600/1000;
export_kWh = sum(max(-grid_kW,0))*dt/3600;
rmse_ekf = sqrt(mean((soc_ekf-SOC).^2))*100;
rmse_cc  = sqrt(mean((soc_cc -SOC).^2))*100;

if useSolar, sol = 'with solar'; else, sol = 'NO solar'; end
fprintf('\n===== RESULTS: steel plant, 22 Nov 2018, %s, threshold %d kW =====\n', sol, thr);
fprintf('Case                 Peak [kW]   Energy cost [Rs/day]\n');
fprintf('A  Grid only         %8.0f   %12.0f\n', peakA, costA);
fprintf('B  Solar only        %8.0f   %12.0f\n', peakB, costB);
fprintf('C  Solar + BESS      %8.0f   %12.0f\n', peakC, costC);
fprintf('Peak reduction A->C   : %.1f %%\n', 100*(peakA-peakC)/peakA);
fprintf('Demand-charge saving  : Rs %.0f per month (if this peak recurs)\n', (peakA-peakC)*demand_rate);
fprintf('   from solar alone   : Rs %.0f | added by BESS: Rs %.0f\n', (peakA-peakB)*demand_rate, (peakB-peakC)*demand_rate);
fprintf('Energy-cost saving    : Rs %.0f/day (solar) + Rs %.0f/day (BESS)\n', costA-costB, costB-costC);
fprintf('Max discharge / energy: %.0f kW / %.0f kWh | ohmic loss %.1f kWh\n', max(Pbat), sum(max(Pbat,0))*dt/3600, loss_kWh);
fprintf('Solar exported (unpaid): %.0f kWh\n', export_kWh);
fprintf('SoC RMSE  EKF / Coulomb: %.2f %% / %.2f %%\n', rmse_ekf, rmse_cc);
fprintf('SoC start / end        : %.0f %% / %.0f %%\n', SOC(1)*100, SOC(end)*100);

%% 8. Plots
f1 = figure('Position',[100 100 900 750]);
subplot(3,1,1);
plot(t_h,load_kW,'k','LineWidth',1.2); hold on;
plot(t_h,pv_kW,'Color',[0.9 0.6 0],'LineWidth',1.2); grid on;
ylabel('kW'); legend('Plant load','Solar PV'); title('Steel plant load and 300 kWp solar, 22 Nov 2018');
subplot(3,1,2);
plot(t_h,net_kW,'r--','LineWidth',1.3); hold on;
plot(t_h,grid_kW,'b','LineWidth',1.3);
yline(thr,'k:','Threshold'); grid on; ylabel('kW');
legend('Solar only','Solar + BESS'); title('Grid demand');
subplot(3,1,3);
plot(t_h,Pbat,'g','LineWidth',1.2); grid on; ylabel('kW'); xlabel('Hour of day (IST)');
title('BESS power (+ discharge / - charge)');
saveas(f1,'fig1_final_peak_shaving.png');

f2 = figure('Position',[150 150 900 600]);
subplot(2,1,1);
plot(t_h,SOC*100,'k','LineWidth',1.5); hold on;
plot(t_h,soc_ekf*100,'b',t_h,soc_cc*100,'r--'); grid on;
ylabel('SoC [%]'); legend('True','EKF','Coulomb counting');
title('SoC estimation (initial SoC guess 10% low, current offset)');
subplot(2,1,2);
plot(t_h,(soc_ekf-SOC)*100,'b',t_h,(soc_cc-SOC)*100,'r--'); grid on;
ylabel('Error [% SoC]'); xlabel('Hour of day (IST)'); legend('EKF','Coulomb counting');
saveas(f2,'fig2_final_soc.png');
