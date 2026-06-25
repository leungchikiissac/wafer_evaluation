%% cscan_6lane_combine.m
%
% Load RF data from 6 sweep lanes, compute a C-scan for each using
% cscan_surface_guided_fn, then concatenate into one combined C-scan image.
%
% Reference: matlab/processing/cscan_surface_guided.m

%% ── Configuration ────────────────────────────────────────────────────────
file_path = 'E:\issac\chip_point_simu_txt_save19-June-2026';
date_str  = '19-June-2026';

N_LANES   = 6;
DY        = 6.9;    % mm between lanes
SX        = 60.0;   % mm sweep length per lane
STEP      = 0.05;   % mm per acquisition step

% C-scan parameters (shared across all lanes)
opts.search_range = [];    % [] = auto-detect per lane
opts.threshold    = 500;
opts.buff_depth   = 16;
opts.ax_len       = 1;
opts.lat_range    = [];    % overridden to all elements below

%% ── Loop through lanes ───────────────────────────────────────────────────
cscans       = cell(1, N_LANES);
surface_maps = cell(1, N_LANES);
n_elem_vec   = zeros(1, N_LANES);
n_acq_vec    = zeros(1, N_LANES);

for k = 1:N_LANES
    lat_mm   = (k - 1) * DY;
    lat_tag  = sprintf('%.1fmm', lat_mm);
    base     = sprintf('RFbatch_5angle_PI_single_step0.05mm_x41.4mm_%s_%srotated90deg', ...
                       lat_tag, date_str);
    mat_file = [base '_size.mat'];
    txt_file = [base '.txt'];

    fprintf('\n=== Lane %d / %d  (Y = %.1f mm) ===\n', k, N_LANES, lat_mm);

    % Use all elements so lanes stitch without gaps
    lane_opts            = opts;
    lane_opts.lat_range  = [];   % resolved to 1:n_elem inside fn

    [cscan, smap] = cscan_surface_guided_fn(file_path, mat_file, txt_file, lane_opts);

    % Override trim: keep all elements for seamless stitching
    [n_acq, n_elem] = size(cscan);
    n_acq_vec(k)    = n_acq;
    n_elem_vec(k)   = n_elem;

    % Re-run if fn applied trimming (lat_range was empty → fn trims ~10%)
    % Detect by checking if cscan columns < n_elem from _size.mat
    size_path = fullfile(file_path, mat_file);
    load(size_path, 'rf_size');
    full_n_elem = rf_size(2);
    if n_elem < full_n_elem
        lane_opts.lat_range = 1:full_n_elem;
        [cscan, smap] = cscan_surface_guided_fn(file_path, mat_file, txt_file, lane_opts);
        [n_acq, n_elem] = size(cscan);
        n_acq_vec(k)  = n_acq;
        n_elem_vec(k) = n_elem;
    end

    cscans{k}       = cscan;
    surface_maps{k} = smap;

    % ── Per-lane figures (600–605) ────────────────────────────────────────
    fig_base = 599 + k;
    figure(fig_base); clf;
    x_mm = linspace(0, DY, n_elem);
    y_mm = linspace(0, SX, n_acq);
    imagesc(x_mm, y_mm, cscan);
    colormap gray; colorbar;
    xlabel('Lateral within lane (mm)');
    ylabel('Sweep position (mm)');
    title(sprintf('Lane %d  —  Y = %.1f mm  (linear)', k, lat_mm));
    set(gca, 'YDir', 'normal');

    fprintf('  Lane %d done: cscan size [%d × %d]\n', k, n_acq, n_elem);
end

%% ── Sanity check ─────────────────────────────────────────────────────────
if any(n_acq_vec ~= n_acq_vec(1))
    warning('Lanes have different n_acq: %s — combined image may be uneven.', ...
            mat2str(n_acq_vec));
end
if any(n_elem_vec ~= n_elem_vec(1))
    warning('Lanes have different n_elem: %s — combined image may be uneven.', ...
            mat2str(n_elem_vec));
end

%% ── Combine ──────────────────────────────────────────────────────────────
fprintf('\n=== Combining %d lanes ===\n', N_LANES);
combined = cat(2, cscans{:});   % [n_acq × (N_LANES * n_elem)]
[n_acq_c, n_elem_c] = size(combined);
fprintf('  Combined size: [%d × %d]\n', n_acq_c, n_elem_c);

x_mm_full = linspace(0, N_LANES * DY, n_elem_c);   % 0 → 41.4 mm
y_mm_full = linspace(0, SX, n_acq_c);              % 0 → 60 mm

%% ── Combined figure — linear (610) ──────────────────────────────────────
figure(610); clf;
imagesc(x_mm_full, y_mm_full, combined);
colormap gray; colorbar;
xlabel('Lateral (mm)');
ylabel('Sweep position (mm)');
title(sprintf('6-Lane Combined C-scan  [%s]', date_str));
set(gca, 'YDir', 'normal');

% Lane boundary lines
hold on;
for k = 1:N_LANES - 1
    xb = k * DY;
    xline(xb, '--', sprintf('L%d|L%d', k, k+1), ...
          'Color', [0.9 0.4 0.1], 'Alpha', 0.6, 'LabelColor', [0.9 0.4 0.1]);
end
hold off;

%% ── Combined figure — dB (611) ───────────────────────────────────────────
combined_norm = combined ./ max(combined(:));
combined_db   = 20 * log10(combined_norm + eps);

figure(611); clf;
imagesc(x_mm_full, y_mm_full, combined_db);
colormap gray; clim([-50 0]); colorbar;
xlabel('Lateral (mm)');
ylabel('Sweep position (mm)');
title(sprintf('6-Lane Combined C-scan  dB  [%s]', date_str));
set(gca, 'YDir', 'normal');

hold on;
for k = 1:N_LANES - 1
    xb = k * DY;
    xline(xb, '--', sprintf('L%d|L%d', k, k+1), ...
          'Color', [0.9 0.4 0.1], 'Alpha', 0.6, 'LabelColor', [0.9 0.4 0.1]);
end
hold off;

fprintf('\nDone. Figures 600–605: per-lane  |  610: combined linear  |  611: combined dB\n');
