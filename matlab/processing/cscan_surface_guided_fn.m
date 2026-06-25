function [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file, opts)
% cscan_surface_guided_fn  Parameterized C-scan pipeline (no display).
%
%   [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file)
%   [cscan, surface_map] = cscan_surface_guided_fn(file_path, mat_file, txt_file, opts)
%
%   Inputs:
%     file_path  - directory containing the RF data files
%     mat_file   - filename of the _size.mat file
%     txt_file   - filename of the raw RF .txt file
%     opts       - optional struct with fields:
%       .search_range  [] = auto-detect; or [lo hi] sample indices
%       .threshold     minimum envelope amplitude for surface detection (default 500)
%       .buff_depth    samples below surface to skip before extraction (default 16)
%       .ax_len        extraction window thickness in samples (default 1)
%       .lat_range     element indices to include; [] = all elements
%
%   Outputs:
%     cscan       [n_acq × n_elem] single — envelope amplitude C-scan
%     surface_map [n_elem × n_acq] — detected surface sample index per element

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
fprintf('  load _size.mat...\n');
tic;
size_path = fullfile(file_path, mat_file);
load(size_path, 'rf_size');
fprintf('  load _size.mat:  %.2f s\n', toc);

tic;
txt_path = fullfile(file_path, txt_file);
fid = fopen(txt_path, 'r');
if fid == -1
    error('cscan_surface_guided_fn: cannot open: %s', txt_path);
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

% Resolve lat_range
if isempty(lat_range)
    trim      = floor(n_elem * 0.1);
    lat_range = (1 + trim) : (n_elem - trim);
end
lat_range = lat_range(lat_range >= 1 & lat_range <= n_elem);

%% Step 2: Surface detection
if isempty(search_range)
    tic;
    mean_env = mean(abs(hilbert(double(reshape(RFdata, n_samples, [])))), 2);
    [~, peak_loc] = max(mean_env);
    half_win     = round(n_samples * 0.02);
    search_range = [max(1, peak_loc - half_win), min(n_samples, peak_loc + half_win)];
    clear mean_env;
    fprintf('  auto search_range:   [%d %d]  (%.2f s)\n', ...
            search_range(1), search_range(2), toc);
end

tic;
surface_map = find_surface_rfdata(RFdata, search_range, threshold);
fprintf('  find_surface_rfdata: %.2f s\n', toc);

surface_idx = round(mean(surface_map, 1));   % [1 x n_acq]
fprintf('  Surface depth range: %d – %d samples\n', min(surface_idx), max(surface_idx));

%% Step 3: Windowed Hilbert envelope
surf_min  = min(surface_idx);
surf_max  = max(surface_idx);
pad       = buff_depth + ax_len + 32;
win_start = max(1, surf_min - pad);
win_end   = min(n_samples, surf_max + pad);
fprintf('  Hilbert window: samples %d – %d (%d of %d)\n', ...
        win_start, win_end, win_end - win_start + 1, n_samples);

tic;
RFwindow   = double(RFdata(win_start:win_end, :, :));
win_len    = size(RFwindow, 1);
RFcols     = reshape(RFwindow, win_len, n_elem * n_acq);
clear RFwindow;
RFenv_cols = single(abs(hilbert(RFcols)));
clear RFcols;
RFenv      = reshape(RFenv_cols, win_len, n_elem, n_acq);
clear RFenv_cols;
fprintf('  Hilbert envelope:    %.2f s\n', toc);

%% Step 4: C-scan extraction
tic;
cscan_full = zeros(n_acq, n_elem, 'single');
for ei = 1:n_acq
    s = surface_idx(ei) - win_start + 1;
    r = s + buff_depth : s + buff_depth + ax_len;
    r = r(r >= 1 & r <= win_len);
    if ~isempty(r)
        cscan_full(ei, :) = sum(RFenv(r, :, ei), 1);
    end
end
fprintf('  C-scan extraction:   %.2f s\n', toc);

cscan = cscan_full(:, lat_range);

end
