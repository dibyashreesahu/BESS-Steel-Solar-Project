%% prepare_data.m
% Builds steel_day.mat and pv_day.mat (inputs of BESS_SteelSolar_Final.m) from the raw public datasets.
%  1) Steel Industry Energy Consumption CSV  (Mendeley Data, DOI 10.17632/vts7r3mx79.1)
%  2) PVGIS hourly time-series CSV           (PVGIS-ERA5, 300 kWp, 14% loss, slope 20 deg, azimuth 0 deg, year 2018)
clear; clc;
d0 = datetime(2018,11,22);                         % chosen day: highest 15-min peak of the 2018 data set

%% 1. Steel plant load -> steel_day.mat
[f,p] = uigetfile('*.csv','Select the steel plant CSV');
T  = readtable(fullfile(p,f));
kW = T.Usage_kWh*4;                                % kWh per 15 min -> average kW
if isdatetime(T.date), ts = T.date; else, ts = datetime(T.date,'InputFormat','dd/MM/yyyy HH:mm'); end
dayid  = dateshift(ts - minutes(15),'start','day');% a reading stamped 00:15 covers 00:00-00:15
day_kW = kW(dayid == d0);                          % 96 values, 15-min averages
fprintf('Steel day: %d samples, peak %.0f kW\n', numel(day_kW), max(day_kW));
save('steel_day.mat','day_kW');

%% 2. PVGIS solar -> pv_day.mat  (PVGIS timestamps are UTC; India is UTC+5:30)
[f2,p2] = uigetfile('*.csv','Select the PVGIS hourly CSV');
txt = fileread(fullfile(p2,f2));
L = strsplit(txt, {'\r\n','\n'});
isdata = ~cellfun(@isempty, regexp(L,'^\d{8}:\d{4},'));
parts = cellfun(@(s) strsplit(s,','), L(isdata), 'UniformOutput', false);
tstr  = cellfun(@(c) c{1}, parts, 'UniformOutput', false);
P_W   = cellfun(@(c) str2double(c{2}), parts)';
t_ist = datetime(tstr,'InputFormat','yyyyMMdd:HHmm')' + hours(5.5);
idx = t_ist >= d0 & t_ist < d0 + days(1);
pv_day = P_W(idx)/1000;                            % kW, hourly values at 00:00 ... 23:00 IST
fprintf('Solar day: %d samples, peak %.0f kW\n', numel(pv_day), max(pv_day));
save('pv_day.mat','pv_day');
