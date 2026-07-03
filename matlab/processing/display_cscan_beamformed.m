% display_cscan_beamformed.m
% Surface-guided C-scan display from beamformed output files.
%
% Surface detection is delegated to cscan_surface_guided_fn (raw RF).
% Beamformed arrays [2048 × 256 × 1200] are read one variable at a time
% through a narrow axial window to keep memory under ~1 GB peak.
%
% Output figure: one tile per variable (ps_data, fgcf, gcf, cf, nsi, …)
% plus optional raw-RF C-scan tile for registration comparison.
%
% Style follows cscan_6lane_combine.m; NSI formula from beamform_fgcf_partdata_showmap.m.

clearvars

%% ── Configuration ─────────────────────────────────────────────────────────

BF_DIR         = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';
RAW_DIR        = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';
WORKSPACE_FILE = fullfile(RAW_DIR, 'matlab_workspace.mat');
CACHE_DIR      = fullfile(BF_DIR, 'surface_cache');

xloc    = 0:6.9:41.4;    % lateral positions of xi positions (mm)
XI_LIST = 3:7;            % xi indices to load (what was actually beamformed)

% Geometry
STEP_MM      = 0.05;    % mm per acquisition (sweep step)
DEPTH_BF     = 2048;    % beamformed axial samples
N_LAT_BF     = 256;     % beamformed lateral columns (128 elem × 2 interp)
N_EI         = 1200;    % acquisitions per xi file
N_FRAMES_RAW = 15;      % angle frames stacked in raw RF (5 angles × 3 PI)

% Variables to extract and display.
% Names must match variables in the beamformed .mat files, or use 'nsi'
% (computed as abs(0.5*(|dcl|+|dcr|) - |zml|) from the directional outputs).
VARIABLES = {'ps_data_ds', 'fgcf_ds', 'gcf_ds', 'cf_ds', 'nsi'};

% Surface detection — opts passed to cscan_surface_guided_fn
SURF_OPTS            = struct();
SURF_OPTS.search_range = [];   % [] = auto-detect peak from mean envelope
SURF_OPTS.threshold    = 500;
SURF_OPTS.buff_depth   = 16;   % used for raw C-scan output inside fn
SURF_OPTS.ax_len       = 1;

% Gate applied to beamformed depth (samples below detected surface)
BUFF_DEPTH = 16;    % samples to skip below surface
AX_LEN     = 2;    % integration window thickness in samples
REDUCE     = 'sum'; % 'sum' | 'max' | 'mean'

% Lateral trim per beamformed lane ([] = all 256 columns)
LAT_TRIM = 25:232;

% Display
SHOW_RAW    = true;          % include raw-RF C-scan tile for comparison
DB_SCALE    = false;         % true = 20*log10 normalised, clim [-50 0] dB
CLIM_MODE   = 'percentile';  % 'percentile' | 'manual' | 'auto'
CLIM_PRC    = [1 99.5];
CLIM_MANUAL = [];
CMAP        = 'gray';
SAVE_FIG    = false;
SAVE_PATH   = fullfile(BF_DIR, 'cscan_bf_display.png');

USE_CACHE = true;  % cache surface_map so raw-txt re-read is skipped on reruns

%% ── Preflight ─────────────────────────────────────────────────────────────

addpath(fileparts(mfilename('fullpath')));

if exist(WORKSPACE_FILE, 'file')
    ws = load(WORKSPACE_FILE, 'Receive', 'Trans');
    frame_length = ws.Receive.endSample;
    pitch_mm     = ws.Trans.spacingMm;   % element pitch (mm)
    fprintf('Workspace: frame_length=%d, element pitch=%.4f mm\n', frame_length, pitch_mm);
else
    frame_length = 2048;
    pitch_mm     = 6.9 / 128;
    warning('display_cscan_beamformed: workspace not found — using fallback geometry.');
end
col_pitch_mm = pitch_mm / 2;   % beamformed column pitch (2× lateral interp)

if ~exist(CACHE_DIR, 'dir'), mkdir(CACHE_DIR); end

needs_nsi = any(strcmp(VARIABLES, 'nsi'));
bf_vars   = VARIABLES(~strcmp(VARIABLES, 'nsi'));  % actual saved variable names

%% ── Per-lane loop ─────────────────────────────────────────────────────────

kept_xi   = [];
slabs     = {};   % {k}.(varname) = [N_EI × n_lat_trim] single
raw_slabs = {};

for k = 1:numel(XI_LIST)
    xi   = XI_LIST(k);
    xstr = num2str(xloc(xi));

    bf_file  = fullfile(BF_DIR, ...
        ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', xstr, ...
         'mm_angle1_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);
    raw_txt  = ['RFbatch_5angle_PI_single_step0.05mm_x', xstr, 'mm15-May-2026.txt'];
    raw_size = ['RFbatch_5angle_PI_single_step0.05mm_x', xstr, 'mm15-May-2026_size.mat'];
    cache_f  = fullfile(CACHE_DIR, sprintf('surface_xi%d.mat', xi));

    if ~exist(bf_file, 'file')
        warning('BF file missing, skipping xi=%d: %s', xi, bf_file); continue;
    end
    if ~exist(fullfile(RAW_DIR, raw_txt), 'file')
        warning('Raw txt missing, skipping xi=%d', xi); continue;
    end

    fprintf('\n── xi=%d  (xloc=%.1f mm) ──────────────────────────\n', xi, xloc(xi));
    kept_xi(end+1) = xi; %#ok<SAGROW>

    %% ── Surface detection (cached) ──────────────────────────────────────
    cache_ok = USE_CACHE && exist(cache_f, 'file');
    if cache_ok
        C = load(cache_f);
        cache_ok = isfield(C, 'surface_map') && isfield(C, 'cscan_raw');
    end

    if cache_ok
        surface_map = C.surface_map;
        cscan_raw   = C.cscan_raw;
        fprintf('  Surface: loaded from cache (%s)\n', cache_f);
    else
        fprintf('  Surface: running cscan_surface_guided_fn...\n');
        sz_s = load(fullfile(RAW_DIR, raw_size), 'rf_size');
        opts_k             = SURF_OPTS;
        opts_k.lat_range   = 1:sz_s.rf_size(2);   % all elements (no auto-trim)
        [cscan_raw, surface_map] = cscan_surface_guided_fn(RAW_DIR, raw_size, raw_txt, opts_k);
        save(cache_f, 'surface_map', 'cscan_raw');
        fprintf('  Surface: cached → %s\n', cache_f);
    end

    %% ── Fold raw stacked-frame indices → within-frame ───────────────────
    % Raw RF is [n_frames*frame_length × n_elem × n_acq]; surface indices
    % may land in any frame.  Beamformed input was frame ai=1, rows 1:depth,
    % so fold with mod to get the equivalent within-frame sample index.
    surf_bf  = mod(double(surface_map) - 1, frame_length) + 1;  % [n_elem × N_EI]
    surf_acq = round(mean(surf_bf, 1));   % [1 × N_EI] averaged across elements

    fprintf('  Within-frame surface: %d – %d samples\n', min(surf_acq), max(surf_acq));
    gate_max = max(surf_acq) + BUFF_DEPTH + AX_LEN;
    if gate_max > DEPTH_BF
        warning('Gate top at sample %d > DEPTH_BF=%d for xi=%d — reduce BUFF_DEPTH or AX_LEN.', ...
            gate_max, DEPTH_BF, xi);
    end

    %% ── Axial window spanning all surface positions ──────────────────────
    pad      = BUFF_DEPTH + AX_LEN + 32;
    win_lo   = max(1,        min(surf_acq) - pad);
    win_hi   = min(DEPTH_BF, max(surf_acq) + pad);
    win_rows = win_lo : win_hi;
    win_len  = numel(win_rows);
    fprintf('  Axial window: samples %d–%d  (%d rows)\n', win_lo, win_hi, win_len);

    if isempty(LAT_TRIM)
        lat_cols = 1:N_LAT_BF;
    else
        lat_cols = LAT_TRIM(LAT_TRIM >= 1 & LAT_TRIM <= N_LAT_BF);
    end

    slabs{k} = struct(); %#ok<SAGROW>

    %% ── NSI: read 3 components together to amortise I/O ─────────────────
    if needs_nsi
        fprintf('  Extracting nsi (dcl+dcr+zml)... ');  t0 = tic;
        e_dcl = env_block(read_bf_window(bf_file, 'dclbf_ds', win_rows));
        e_dcr = env_block(read_bf_window(bf_file, 'dcrbf_ds', win_rows));
        e_zml = env_block(read_bf_window(bf_file, 'zmlbf_ds', win_rows));
        nsi_blk = abs(0.5 * (e_dcl + e_dcr) - e_zml);
        clear e_dcl e_dcr e_zml;
        slabs{k}.nsi = gate_slab(nsi_blk, surf_acq, win_lo, win_len, ...
                                  BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        clear nsi_blk;
        fprintf('%.1f s\n', toc(t0));
    end

    %% ── Standard beamformed variables ───────────────────────────────────
    for vi = 1:numel(bf_vars)
        vname = bf_vars{vi};
        fprintf('  Extracting %-20s ... ', vname);  t0 = tic;

        blk = read_bf_window(bf_file, vname, win_rows);

        % *_weight_ds variables are CF scalars [0,1] — skip Hilbert
        if length(vname) >= 10 && strcmp(vname(end-9:end), '_weight_ds')
            env = single(blk);
        else
            env = env_block(blk);
        end
        clear blk;

        slabs{k}.(vname) = gate_slab(env, surf_acq, win_lo, win_len, ...
                                       BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        clear env;
        fprintf('%.1f s\n', toc(t0));
    end

    %% ── Raw-RF C-scan tile ───────────────────────────────────────────────
    if SHOW_RAW
        raw_slabs{k} = single(cscan_raw); %#ok<SAGROW>
    end
end

if isempty(kept_xi)
    error('display_cscan_beamformed: no valid data found for XI_LIST.');
end

%% ── Stack lanes ───────────────────────────────────────────────────────────

K = numel(kept_xi);
fprintf('\n── Stacking %d lanes ─────────────────────────────────\n', K);

for vi = 1:numel(VARIABLES)
    vn = VARIABLES{vi};
    parts = cellfun(@(s) s.(vn), slabs, 'UniformOutput', false);
    stacked.(vn) = cat(2, parts{:});   % [N_EI × K*n_lat]
end

if SHOW_RAW && ~isempty(raw_slabs)
    stacked.raw_cscan = cat(2, raw_slabs{:});  % [N_EI × K*n_elem]
end

% Axis vectors
n_lat_trim  = numel(lat_cols);
y_mm        = (0 : N_EI - 1) * STEP_MM;       % sweep (rows)
x0_mm       = xloc(kept_xi(1));
x_bf_mm     = x0_mm + (0 : K*n_lat_trim - 1) * col_pitch_mm;
lane_x_mm   = xloc(kept_xi(2:end));            % lane boundaries for xline

if SHOW_RAW && isfield(stacked, 'raw_cscan')
    n_raw_cols     = size(stacked.raw_cscan, 2);
    n_raw_per_lane = round(n_raw_cols / K);
    x_raw_mm       = x0_mm + (0 : n_raw_cols - 1) * (6.9 / n_raw_per_lane);
end

%% ── Display ───────────────────────────────────────────────────────────────

all_vars = VARIABLES;
if SHOW_RAW && isfield(stacked, 'raw_cscan')
    all_vars{end+1} = 'raw_cscan';
end
N_TILES = numel(all_vars);
nc = ceil(sqrt(N_TILES));
nr = ceil(N_TILES / nc);

fig = figure('Name', 'C-scan — beamformed outputs', ...
             'Units', 'normalized', 'Position', [0.02 0.04 0.96 0.88]);
tl  = tiledlayout(nr, nc, 'TileSpacing', 'compact', 'Padding', 'compact');

for vi = 1:N_TILES
    vn = all_vars{vi};
    nexttile(tl);

    if strcmp(vn, 'raw_cscan')
        img  = double(stacked.raw_cscan);
        xax  = x_raw_mm;
        ttl  = 'Raw RF C-scan';
    else
        img  = double(stacked.(vn));
        xax  = x_bf_mm;
        ttl  = strrep(vn, '_', '\_');
    end

    if DB_SCALE
        mx  = max(img(:));
        img = 20 * log10(img ./ (mx + eps) + eps);
    end

    imagesc(xax, y_mm, img);
    axis image;
    set(gca, 'YDir', 'normal');   % sweep origin at bottom
    colormap(gca, CMAP);
    colorbar;

    if DB_SCALE
        clim([-50 0]);
    else
        switch CLIM_MODE
            case 'percentile'
                cl = prctile(img(:), CLIM_PRC);
                if cl(1) >= cl(2), cl(2) = cl(1) + eps; end
                clim(cl);
            case 'manual'
                if ~isempty(CLIM_MANUAL), clim(CLIM_MANUAL); end
            % 'auto': MATLAB default
        end
    end

    xlabel('Lateral (mm)');
    ylabel('Sweep (mm)');
    title(ttl, 'Interpreter', 'tex');

    hold on;
    for lb = lane_x_mm
        xline(lb, '--', 'Color', [0.9 0.4 0.1], 'LineWidth', 0.8, 'Alpha', 0.7);
    end
    hold off;
end

sgtitle(sprintf('Beamformed C-scan  |  xi=%d:%d  (%.1f–%.1f mm)  |  gate +%d/%d smp  |  %s', ...
    kept_xi(1), kept_xi(end), xloc(kept_xi(1)), xloc(kept_xi(end)), ...
    BUFF_DEPTH, AX_LEN, REDUCE), 'FontWeight', 'bold');

fprintf('\n=== Done ===\n');
fprintf('Stacked C-scan: %d × %d  (%d lanes | %d vars)\n', ...
    size(stacked.(VARIABLES{1})), K, numel(VARIABLES));

if SAVE_FIG
    exportgraphics(fig, SAVE_PATH, 'Resolution', 200);
    fprintf('Figure saved: %s\n', SAVE_PATH);
end

%% ════════════════════════════════════════════════════════════════════════════
%  Local functions
%% ════════════════════════════════════════════════════════════════════════════

function blk = read_bf_window(bf_file, vname, win_rows)
%READ_BF_WINDOW  Read an axial row-subset from a beamformed .mat variable.
%   Returns [numel(win_rows) × N_LAT_BF × N_EI] single.
%   Tries matfile (partial HDF5 read) first; falls back to full load.
    try
        m   = matfile(bf_file);
        blk = m.(vname)(win_rows, :, :);
    catch
        S   = load(bf_file, vname);
        blk = S.(vname)(win_rows, :, :);
        clear S;
    end
end

function env = env_block(blk)
%ENV_BLOCK  Hilbert envelope along axial dim of [win_len × N_lat × N_ei] block.
%   Input single, output single.
    [wl, nc, ne] = size(blk);
    env = single(abs(hilbert(reshape(double(blk), wl, nc * ne))));
    env = reshape(env, wl, nc, ne);
end

function slab = gate_slab(env, surf_acq, win_lo, win_len, ...
                           buff_depth, ax_len, reduce, n_ei, lat_cols)
%GATE_SLAB  Extract and reduce gate window from envelope.
%   env:      [win_len × N_lat × n_ei] single
%   surf_acq: [1 × n_ei] surface sample index (absolute, same frame as env)
%   Returns:  [n_ei × numel(lat_cols)] single
    slab    = zeros(n_ei, numel(lat_cols), 'single');
    n_clamp = 0;
    for ei = 1:n_ei
        s = surf_acq(ei) - win_lo + 1;     % surface row within window
        r = (s + buff_depth) : (s + buff_depth + ax_len - 1);
        r = r(r >= 1 & r <= win_len);
        if isempty(r), n_clamp = n_clamp + 1; continue; end
        patch = env(r, lat_cols, ei);       % [ax_len × n_lat]
        switch reduce
            case 'sum',  slab(ei, :) = sum(patch,  1);
            case 'max',  slab(ei, :) = max(patch,  [], 1);
            case 'mean', slab(ei, :) = mean(patch, 1);
        end
    end
    if n_clamp > 0
        warning('gate_slab: %d/%d acquisitions clamped (gate outside window).', n_clamp, n_ei);
    end
end
