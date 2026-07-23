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

[cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file, opts);

%% ── Display ───────────────────────────────────────────────────────────────
figure('Name', 'C-scan (surface-guided)', 'NumberTitle', 'off');

subplot(1, 2, 1);
imagesc(cscan);
axis image;
colormap('gray');
colorbar;
title('C-scan envelope amplitude');
xlabel('Element (lateral)');
ylabel('Acquisition (step)');

subplot(1, 2, 2);
imagesc(mean(surface_map, 1));
axis image;
colormap('jet');
colorbar;
title('Detected surface depth (samples)');
xlabel('Acquisition (step)');
ylabel('Element (lateral)');
