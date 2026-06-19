%% cscan_surface_guided.m
%
% Self-contained C-scan pipeline:
%   1. Load raw RF data from .txt + _size.mat files
%   2. Detect wafer surface on raw RF (find_surface_rfdata)
%   3. Extract envelope amplitude just below the surface per element
%   4. Display C-scan map
%
% No external beamformer required — envelope is computed from raw RF.

%% ── Data files ───────────────────────────────────────────────────────────
file_path    = 'E:\issac\chip_point_simu_txt_save29-May-2026';
mat_file     = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg_size.mat';
txt_file     = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg.txt';

%% ── Parameters ───────────────────────────────────────────────────────────
search_range = [3800, 4200];  % sample window to search for surface echo
threshold    = 500;           % minimum envelope amplitude to count as surface
buff_depth   = 16;            % samples below surface to extract
ax_len       = 1;             % extraction window thickness (samples)
lat_range    = [];            % [] = use all elements (set after loading data)

%% ── Step 1: Load RF data ─────────────────────────────────────────────────
fprintf('=== Step 1: Load RF data ===\n');

tic;
size_path = fullfile(file_path, mat_file);
load(size_path, 'rf_size');
fprintf('  load _size.mat:  %.2f s\n', toc);

tic;
txt_path = fullfile(file_path, txt_file);
fid = fopen(txt_path, 'r');
if fid == -1
    error('Cannot open: %s', txt_path);
end
RF_tmp = int16(fread(fid, 'double'));
fclose(fid);
fprintf('  fread .txt:      %.2f s  (%d elements)\n', toc, numel(RF_tmp));

tic;
RFdata = reshape(RF_tmp, rf_size);
fprintf('  reshape:         %.2f s  (size %s)\n', toc, mat2str(size(RFdata)));
clear RF_tmp;

[n_samples, n_elem, n_acq] = size(RFdata);
fprintf('  RF shape: %d samples x %d elements x %d acquisitions\n', ...
        n_samples, n_elem, n_acq);

% Set lateral display range now that n_elem is known
% Trim ~10% from each edge; fall back to all elements if array is small
trim = floor(n_elem * 0.1);
if isempty(lat_range)
    lat_range = (1 + trim) : (n_elem - trim);
end
lat_range = lat_range(lat_range >= 1 & lat_range <= n_elem);

%% ── Step 2: Find surface ─────────────────────────────────────────────────
fprintf('\n=== Step 2: Surface detection ===\n');

tic;
surface_map = find_surface_rfdata(RFdata, search_range, threshold);
fprintf('  find_surface_rfdata: %.2f s\n', toc);
% surface_map: [n_elem x n_acq]

% Mean across elements → one representative depth per scan position
surface_idx = round(mean(surface_map, 1));   % [1 x n_acq]
fprintf('  Surface depth range: %d – %d samples\n', min(surface_idx), max(surface_idx));

%% ── Step 3: Envelope C-scan from raw RF ──────────────────────────────────
fprintf('\n=== Step 3: Envelope C-scan extraction ===\n');

% Hilbert envelope of entire RFdata — heavy step
tic;
RFenv = zeros(size(RFdata), 'single');
for ei = 1:n_acq
    RFenv(:,:,ei) = single(abs(hilbert(double(RFdata(:,:,ei)))));
end
fprintf('  Hilbert envelope:    %.2f s\n', toc);

% Extract slice just below surface for each scan position
tic;
cscan = zeros(n_acq, n_elem, 'single');
for ei = 1:n_acq
    s = surface_idx(ei);
    r = s + buff_depth : s + buff_depth + ax_len;
    % clamp to valid range
    r = r(r >= 1 & r <= n_samples);
    if ~isempty(r)
        cscan(ei, :) = sum(RFenv(r, :, ei), 1);
    end
end
fprintf('  C-scan extraction:   %.2f s\n', toc);

%% ── Step 4: Display ──────────────────────────────────────────────────────
fprintf('\n=== Step 4: Display ===\n');

figure(600); clf;
imagesc(cscan(:, lat_range));
colormap gray;
xlabel('element (lateral)');
ylabel('scan position (elevation)');
title(sprintf('C-scan  buff\\_depth=%d  ax\\_len=%d', buff_depth, ax_len));
colorbar;

% Log-scale version
cscan_norm = cscan ./ max(cscan(:));
figure(601); clf;
imagesc(20*log10(cscan_norm(:, lat_range) + eps));
colormap gray; caxis([-50 0]);
xlabel('element (lateral)');
ylabel('scan position (elevation)');
title('C-scan (dB, normalized)');
colorbar;

%% ── Step 5: Surface QC plots ─────────────────────────────────────────────
figure(602); clf;
imagesc(surface_map);
xlabel('scan position'); ylabel('element');
title('surface\_map: detected surface sample index per element');
colorbar;

figure(603); clf;
plot(surface_idx);
xlabel('scan position'); ylabel('sample index');
title('mean surface depth per scan position');
grid on;

fprintf('Done.\n');
