%% cscan_surface_guided.m
%
% Thin wrapper around cscan_surface_guided_fn — edit file_path/mat_file/txt_file
% and opts below, then run this script for manual one-off processing.

%% ── Data files ───────────────────────────────────────────────────────────
file_path = 'E:\issac\chip_point_simu_txt_save29-May-2026';
mat_file  = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg_size.mat';
txt_file  = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg.txt';

%% ── Options (all optional — leave empty for defaults) ────────────────────
opts.search_range = [];   % [] = auto-detect; or e.g. [3800 4200]
opts.threshold    = 500;
opts.buff_depth   = 16;
opts.ax_len       = 1;
opts.lat_range    = [];

cscan_surface_guided_fn(file_path, mat_file, txt_file, opts);
