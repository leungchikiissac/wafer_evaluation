function [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file, opts)
% cscan_surface_guided_fn  Parameterized C-scan pipeline.
%
%   [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file)
%   [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file, opts)
%
%   file_path  directory containing the RF data files
%   mat_file   filename of the _size.mat file (just the name, not full path)
%   txt_file   filename of the .txt RF data file (just the name, not full path)
%
%   opts struct fields (all optional):
%     search_range  [row_start row_end] or [] for auto-detect (default [])
%     threshold     min envelope amplitude to count as surface (default 500)
%     buff_depth    samples below surface to extract (default 16)
%     ax_len        extraction window thickness in samples (default 1)
%     lat_range     element indices to display, [] = auto-trim 10% (default [])

if nargin < 4 || isempty(opts); opts = struct(); end
if ~isfield(opts, 'search_range'); opts.search_range = []; end
if ~isfield(opts, 'threshold');    opts.threshold    = 500; end
if ~isfield(opts, 'buff_depth');   opts.buff_depth   = 16;  end
if ~isfield(opts, 'ax_len');       opts.ax_len       = 1;   end
if ~isfield(opts, 'lat_range');    opts.lat_range    = [];  end

search_range = opts.search_range;
threshold    = opts.threshold;
buff_depth   = opts.buff_depth;
ax_len       = opts.ax_len;
lat_range    = opts.lat_range;

%% Step 1: Load RF data
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

trim = floor(n_elem * 0.1);
if isempty(lat_range)
    lat_range = (1 + trim) : (n_elem - trim);
end
lat_range = lat_range(lat_range >= 1 & lat_range <= n_elem);

%% Step 2: Find surface
fprintf('\n=== Step 2: Surface detection ===\n');

if isempty(search_range)
    tic;
    mean_env = mean(abs(hilbert(double(reshape(RFdata, n_samples, [])))), 2);
    [~, peak_loc] = max(mean_env);
    half_win = round(n_samples * 0.02);
    search_range = [max(1, peak_loc - half_win), min(n_samples, peak_loc + half_win)];
    clear mean_env;
    fprintf('  auto search_range:   [%d %d]  (%.2f s)\n', ...
            search_range(1), search_range(2), toc);
end

tic;
surface_map = find_surface_rfdata(RFdata, search_range, threshold);
fprintf('  find_surface_rfdata: %.2f s\n', toc);

surface_idx = round(mean(surface_map, 1));
fprintf('  Surface depth range: %d – %d samples\n', min(surface_idx), max(surface_idx));

%% Step 3: Envelope C-scan from raw RF
fprintf('\n=== Step 3: Envelope C-scan extraction ===\n');

surf_min  = min(surface_idx);
surf_max  = max(surface_idx);
pad       = buff_depth + ax_len + 32;
win_start = max(1, surf_min - pad);
win_end   = min(n_samples, surf_max + pad);
fprintf('  Hilbert window: samples %d – %d (%d of %d)\n', ...
        win_start, win_end, win_end - win_start + 1, n_samples);

tic;
RFwindow = double(RFdata(win_start:win_end, :, :));
win_len  = size(RFwindow, 1);
RFcols = reshape(RFwindow, win_len, n_elem * n_acq);
clear RFwindow;
RFenv_cols = single(abs(hilbert(RFcols)));
clear RFcols;
RFenv = reshape(RFenv_cols, win_len, n_elem, n_acq);
clear RFenv_cols;
fprintf('  Hilbert envelope:    %.2f s\n', toc);

tic;
cscan = zeros(n_acq, n_elem, 'single');
for ei = 1:n_acq
    s = surface_idx(ei) - win_start + 1;
    r = s + buff_depth : s + buff_depth + ax_len;
    r = r(r >= 1 & r <= win_len);
    if ~isempty(r)
        cscan(ei, :) = sum(RFenv(r, :, ei), 1);
    end
end
fprintf('  C-scan extraction:   %.2f s\n', toc);

%% Step 4: Display
fprintf('\n=== Step 4: Display ===\n');

figure(600); clf;
imagesc(cscan(:, lat_range));
colormap gray;
xlabel('element (lateral)');
ylabel('scan position (elevation)');
title(sprintf('C-scan  buff\\_depth=%d  ax\\_len=%d', buff_depth, ax_len));
colorbar;

cscan_norm = cscan ./ max(cscan(:));
figure(601); clf;
imagesc(20*log10(cscan_norm(:, lat_range) + eps));
colormap gray; caxis([-50 0]);
xlabel('element (lateral)');
ylabel('scan position (elevation)');
title('C-scan (dB, normalized)');
colorbar;

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
end
