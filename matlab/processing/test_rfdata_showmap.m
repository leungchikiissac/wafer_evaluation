%% Load rf data from txt file

file_path = 'E:\issac\chip_point_simu_txt_save29-May-2026';
mat_file_name = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg_size.mat';
txt_file_name = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg.txt';

txt_file_path = fullfile(file_path, txt_file_name);
filename_size = fullfile(file_path, mat_file_name);

load(filename_size);

fid = fopen(txt_file_path,'r');
RF_tmp = int16(fread(fid,'double'));

RF_Dim = rf_size;
RFdata= reshape(RF_tmp,RF_Dim);

imagesc(RFdata(:,:,50));

%% ── Parameters ───────────────────────────────────────────────
fs          = 120e6;       % sample rate (30 MHz × 4, NS200BW)
c           = 1540;        % m/s in water
elem_pitch  = 0.069e-3;    % m
n_elem      = 256;
na          = 5;           % steering angles
buff_depth  = 16;          % samples below surface to extract
ax_len      = 1;           % extraction window thickness

% Search window (adjust to your standoff depth ~6mm)
% 6mm at 120MHz: 6e-3 / (c/2) * fs = 6e-3*120e6/770 ≈ 935 samples
% search_range = [800, 1100];
search_range = [3800, 4200];

threshold    = 500;         % adjust to your noise floor

%% ── Step 1: Find surface in RFdata ──────────────────────────
[n_samples, ~, n_acq] = size(RFdata);

% Use center elements approach (fast, reliable)
surface_idx = find_surface_center_elements(RFdata, search_range, ...
                threshold, 32);
% surface_idx: [1 × n_acq]  — one surface depth per scan position

%% ── Optional: per-element surface map ───────────────────────
surface_map = find_surface_rfdata(RFdata, search_range, threshold);
% surface_map: [256 × n_acq] — surface per element per scan position

imagesc(surface_map);