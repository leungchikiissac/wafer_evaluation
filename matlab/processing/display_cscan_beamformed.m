% display_cscan_beamformed.m
% Surface-guided C-scan display from beamformed output files.
%
% Three gating approaches are computed and shown side-by-side in Figure 1:
%   1. Global mean  — mean(surface_map(:))      : one depth for the whole lane
%   2. Per-acq mean — mean(surface_map, 1)      : tracks sweep, flat per frame
%   3. Per-column   — per-element interpolated  : full lateral + sweep tracking
%
% Figure 2 shows all variables using the approach selected by GATE_MAIN.
%
% Surface detection delegates to cscan_surface_guided_fn (raw RF, cached).
% Beamformed arrays [2048 × 256 × 1200] are read through a narrow axial window.

clearvars

%% ── Configuration ─────────────────────────────────────────────────────────

BF_DIR         = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';
RAW_DIR        = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';
WORKSPACE_FILE = fullfile(RAW_DIR, 'matlab_workspace.mat');
CACHE_DIR      = fullfile(BF_DIR, 'surface_cache');

xloc    = 0:6.9:41.4;
XI_LIST = 3:7;

% Geometry
STEP_MM      = 0.05;
DEPTH_BF     = 2048;
N_LAT_BF     = 256;
N_EI         = 1200;
N_FRAMES_RAW = 15;  %#ok<NASGU>

% Variables to extract ('nsi' = abs(0.5*(|dcl|+|dcr|) - |zml|))
VARIABLES = {'ps_data_ds', 'fgcf_ds', 'gcf_ds', 'cf_ds', 'nsi'};

% Gating comparison / main-figure selection
GATE_MAIN   = 'per_acq';     % 'global' | 'per_acq' | 'per_col' — used for Figure 2
COMPARE_VAR = 'ps_data_ds';  % variable shown in the 3-way comparison Figure 1

% Surface detection opts passed to cscan_surface_guided_fn
SURF_OPTS              = struct();
SURF_OPTS.search_range = [];
SURF_OPTS.threshold    = 500;
SURF_OPTS.buff_depth   = 16;
SURF_OPTS.ax_len       = 1;

% Gate (applied to beamformed depth axis)
BUFF_DEPTH = 16;
AX_LEN     = 2;
REDUCE     = 'sum';   % 'sum' | 'max' | 'mean'

% Lateral trim per beamformed lane ([] = all 256 columns)
LAT_TRIM = 25:232;

% Display
SHOW_RAW    = true;
DB_SCALE    = false;
CLIM_MODE   = 'percentile';   % 'percentile' | 'manual' | 'auto'
CLIM_PRC    = [1 99.5];
CLIM_MANUAL = [];
CMAP        = 'gray';
SAVE_FIG    = false;
SAVE_PATH   = fullfile(BF_DIR, 'cscan_bf_display.png');

USE_CACHE = true;

%% ── Preflight ─────────────────────────────────────────────────────────────

addpath(fileparts(mfilename('fullpath')));

if ~isfield(struct('global',0,'per_acq',0,'per_col',0), GATE_MAIN)
    error('display_cscan_beamformed: unknown GATE_MAIN ''%s''.', GATE_MAIN);
end

if exist(WORKSPACE_FILE, 'file')
    ws = load(WORKSPACE_FILE, 'Receive', 'Trans');
    frame_length = ws.Receive.endSample;
    pitch_mm     = ws.Trans.spacingMm;
    fprintf('Workspace: frame_length=%d, element pitch=%.4f mm\n', frame_length, pitch_mm);
else
    frame_length = 2048;
    pitch_mm     = 6.9 / 128;
    warning('display_cscan_beamformed: workspace not found — using fallback geometry.');
end
col_pitch_mm = pitch_mm / 2;

if ~exist(CACHE_DIR, 'dir'), mkdir(CACHE_DIR); end

needs_nsi = any(strcmp(VARIABLES, 'nsi'));
bf_vars   = VARIABLES(~strcmp(VARIABLES, 'nsi'));

%% ── Per-lane loop ─────────────────────────────────────────────────────────

kept_xi  = [];
slabs_g  = {};   % {k}.(varname) = [N_EI × n_lat_trim] — global-mean gate
slabs_a  = {};   % {k}.(varname) = [N_EI × n_lat_trim] — per-acq-mean gate
slabs_c  = {};   % {k}.(varname) = [N_EI × n_lat_trim] — per-column gate
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
        fprintf('  Surface: loaded from cache\n');
    else
        fprintf('  Surface: running cscan_surface_guided_fn...\n');
        sz_s = load(fullfile(RAW_DIR, raw_size), 'rf_size');
        opts_k           = SURF_OPTS;
        opts_k.lat_range = 1:sz_s.rf_size(2);
        [cscan_raw, surface_map] = cscan_surface_guided_fn(RAW_DIR, raw_size, raw_txt, opts_k);
        save(cache_f, 'surface_map', 'cscan_raw');
        fprintf('  Surface: cached → %s\n', cache_f);
    end

    %% ── Fold stacked-frame indices → within-frame ───────────────────────
    surf_bf = mod(double(surface_map) - 1, frame_length) + 1;   % [n_elem × N_EI]
    n_elem  = size(surf_bf, 1);

    % Approach 1 — global mean (one depth for the whole lane)
    surf_global = repmat(round(mean(surf_bf(:))), 1, N_EI);     % [1 × N_EI]

    % Approach 2 — per-acquisition mean (existing behaviour)
    surf_acq = round(mean(surf_bf, 1));                         % [1 × N_EI]

    % Lateral trim (moved before surf_col — needed for column mapping)
    if isempty(LAT_TRIM)
        lat_cols = 1:N_LAT_BF;
    else
        lat_cols = LAT_TRIM(LAT_TRIM >= 1 & LAT_TRIM <= N_LAT_BF);
    end

    % Approach 3 — per-column (interp element grid → BF column grid, then trim)
    elem_x        = linspace(1, N_LAT_BF, n_elem);
    surf_col_full = interp1(elem_x', double(surf_bf), (1:N_LAT_BF)');  % [N_LAT_BF × N_EI]
    surf_col      = round(surf_col_full(lat_cols, :));                 % [n_lat_trim × N_EI]

    fprintf('  Within-frame surface: global=%d | per-acq %d–%d | per-col %d–%d\n', ...
        surf_global(1), min(surf_acq), max(surf_acq), min(surf_col(:)), max(surf_col(:)));

    %% ── Axial window spanning all three surface arrays ──────────────────
    all_surf = [surf_global(:); surf_acq(:); surf_col(:)];
    gate_max = max(all_surf) + BUFF_DEPTH + AX_LEN;
    if gate_max > DEPTH_BF
        warning('Gate top at sample %d > DEPTH_BF=%d for xi=%d.', gate_max, DEPTH_BF, xi);
    end

    pad      = BUFF_DEPTH + AX_LEN + 32;
    win_lo   = max(1,        min(all_surf) - pad);
    win_hi   = min(DEPTH_BF, max(all_surf) + pad);
    win_rows = win_lo : win_hi;
    win_len  = numel(win_rows);
    fprintf('  Axial window: samples %d–%d  (%d rows)\n', win_lo, win_hi, win_len);

    slabs_g{k} = struct(); %#ok<SAGROW>
    slabs_a{k} = struct(); %#ok<SAGROW>
    slabs_c{k} = struct(); %#ok<SAGROW>

    %% ── NSI: read 3 components together, gate three ways ────────────────
    if needs_nsi
        fprintf('  nsi... ');  t0 = tic;
        e_dcl   = env_block(read_bf_window(bf_file, 'dclbf_ds', win_rows));
        e_dcr   = env_block(read_bf_window(bf_file, 'dcrbf_ds', win_rows));
        e_zml   = env_block(read_bf_window(bf_file, 'zmlbf_ds', win_rows));
        nsi_blk = abs(0.5 * (e_dcl + e_dcr) - e_zml);
        clear e_dcl e_dcr e_zml;

        slabs_g{k}.nsi = gate_slab(nsi_blk, surf_global, win_lo, win_len, ...
                                    BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        slabs_a{k}.nsi = gate_slab(nsi_blk, surf_acq,    win_lo, win_len, ...
                                    BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        slabs_c{k}.nsi = gate_slab_percol(nsi_blk(:, lat_cols, :), surf_col, ...
                                    win_lo, win_len, BUFF_DEPTH, AX_LEN, REDUCE, N_EI);
        clear nsi_blk;
        fprintf('%.1f s\n', toc(t0));
    end

    %% ── Standard variables: read once, gate three ways ──────────────────
    for vi = 1:numel(bf_vars)
        vname = bf_vars{vi};
        fprintf('  %-20s ... ', vname);  t0 = tic;

        blk = read_bf_window(bf_file, vname, win_rows);
        if length(vname) >= 10 && strcmp(vname(end-9:end), '_weight_ds')
            env = single(blk);
        else
            env = env_block(blk);
        end
        clear blk;

        slabs_g{k}.(vname) = gate_slab(env, surf_global, win_lo, win_len, ...
                                         BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        slabs_a{k}.(vname) = gate_slab(env, surf_acq,    win_lo, win_len, ...
                                         BUFF_DEPTH, AX_LEN, REDUCE, N_EI, lat_cols);
        slabs_c{k}.(vname) = gate_slab_percol(env(:, lat_cols, :), surf_col, ...
                                         win_lo, win_len, BUFF_DEPTH, AX_LEN, REDUCE, N_EI);
        clear env;
        fprintf('%.1f s\n', toc(t0));
    end

    if SHOW_RAW
        raw_slabs{k} = single(cscan_raw); %#ok<SAGROW>
    end
end

if isempty(kept_xi)
    error('display_cscan_beamformed: no valid data found for XI_LIST.');
end
if ~isfield(slabs_a{1}, COMPARE_VAR)
    error('display_cscan_beamformed: COMPARE_VAR ''%s'' is not in VARIABLES.', COMPARE_VAR);
end

%% ── Stack lanes ───────────────────────────────────────────────────────────

K = numel(kept_xi);
fprintf('\n── Stacking %d lanes ─────────────────────────────────\n', K);

for vi = 1:numel(VARIABLES)
    vn = VARIABLES{vi};
    pg = cellfun(@(s) s.(vn), slabs_g, 'UniformOutput', false);
    pa = cellfun(@(s) s.(vn), slabs_a, 'UniformOutput', false);
    pc = cellfun(@(s) s.(vn), slabs_c, 'UniformOutput', false);
    stacked_g.(vn) = cat(2, pg{:});
    stacked_a.(vn) = cat(2, pa{:});
    stacked_c.(vn) = cat(2, pc{:});
end

if SHOW_RAW && ~isempty(raw_slabs)
    raw_cscan_stacked = cat(2, raw_slabs{:});
else
    raw_cscan_stacked = [];
end

% Axis vectors
n_lat_trim = numel(lat_cols);
y_mm       = (0 : N_EI - 1) * STEP_MM;
x0_mm      = xloc(kept_xi(1));
x_bf_mm    = x0_mm + (0 : K*n_lat_trim - 1) * col_pitch_mm;
lane_x_mm  = xloc(kept_xi(2:end));

if ~isempty(raw_cscan_stacked)
    n_raw_cols     = size(raw_cscan_stacked, 2);
    n_raw_per_lane = round(n_raw_cols / K);
    x_raw_mm       = x0_mm + (0 : n_raw_cols - 1) * (6.9 / n_raw_per_lane);
end

% Display config struct (passed to draw_tile to avoid repeated arguments)
cfg = struct('DB_SCALE', DB_SCALE, 'CLIM_MODE', CLIM_MODE, 'CLIM_PRC', CLIM_PRC, ...
             'CLIM_MANUAL', CLIM_MANUAL, 'CMAP', CMAP, 'y_mm', y_mm, 'lane_x_mm', lane_x_mm);

% Main gate source
switch GATE_MAIN
    case 'global',  stacked_main = stacked_g;  gate_lbl = 'global mean';
    case 'per_acq', stacked_main = stacked_a;  gate_lbl = 'per-acq mean';
    case 'per_col', stacked_main = stacked_c;  gate_lbl = 'per-column';
end

%% ── Figure 1: gating comparison (1 × 3) ──────────────────────────────────

cmp_srcs  = {stacked_g,    stacked_a,      stacked_c};
cmp_names = {'Global mean','Per-acq mean', 'Per-column'};

fig_cmp = figure('Name', ['C-scan gating comparison — ' COMPARE_VAR], ...
                 'Units', 'normalized', 'Position', [0.04 0.1 0.92 0.8]);
tl_cmp  = tiledlayout(1, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
for j = 1:3
    nexttile(tl_cmp);
    draw_tile(cmp_srcs{j}.(COMPARE_VAR), x_bf_mm, cmp_names{j}, cfg);
end
sgtitle(sprintf('Gating comparison  |  %s  |  xi=%d:%d  |  gate +%d/%d smp  |  %s', ...
    strrep(COMPARE_VAR, '_', '\_'), kept_xi(1), kept_xi(end), ...
    BUFF_DEPTH, AX_LEN, REDUCE), 'FontWeight', 'bold');

%% ── Figure 2: main C-scan (all variables, gate = GATE_MAIN) ──────────────

all_vars = VARIABLES;
if SHOW_RAW && ~isempty(raw_cscan_stacked)
    all_vars{end+1} = 'raw_cscan';
end
N_TILES = numel(all_vars);
nc = ceil(sqrt(N_TILES));
nr = ceil(N_TILES / nc);

fig_main = figure('Name', 'C-scan — beamformed outputs', ...
                  'Units', 'normalized', 'Position', [0.02 0.04 0.96 0.88]);
tl_main  = tiledlayout(nr, nc, 'TileSpacing', 'compact', 'Padding', 'compact');
for vi = 1:N_TILES
    vn = all_vars{vi};
    nexttile(tl_main);
    if strcmp(vn, 'raw_cscan')
        draw_tile(raw_cscan_stacked, x_raw_mm, 'Raw RF C-scan', cfg);
    else
        draw_tile(stacked_main.(vn), x_bf_mm, strrep(vn, '_', '\_'), cfg);
    end
end
sgtitle(sprintf('Beamformed C-scan [%s gate]  |  xi=%d:%d  (%.1f–%.1f mm)  |  gate +%d/%d smp  |  %s', ...
    gate_lbl, kept_xi(1), kept_xi(end), xloc(kept_xi(1)), xloc(kept_xi(end)), ...
    BUFF_DEPTH, AX_LEN, REDUCE), 'FontWeight', 'bold');

fprintf('\n=== Done ===\n');
fprintf('Stacked: %d × %d  (%d lanes | %d vars | main gate: %s)\n', ...
    size(stacked_main.(VARIABLES{1}), 1), size(stacked_main.(VARIABLES{1}), 2), ...
    K, numel(VARIABLES), GATE_MAIN);

if SAVE_FIG
    exportgraphics(fig_main, SAVE_PATH, 'Resolution', 200);
    [sp_dir, sp_name, sp_ext] = fileparts(SAVE_PATH);
    cmp_path = fullfile(sp_dir, [sp_name '_compare' sp_ext]);
    exportgraphics(fig_cmp, cmp_path, 'Resolution', 200);
    fprintf('Figures saved:\n  %s\n  %s\n', SAVE_PATH, cmp_path);
end

%% ════════════════════════════════════════════════════════════════════════════
%  Local functions
%% ════════════════════════════════════════════════════════════════════════════

function draw_tile(img_in, xax, ttl, cfg)
%DRAW_TILE  imagesc + clim + lane boundary lines into the current axes.
    img = double(img_in);
    if cfg.DB_SCALE
        mx  = max(img(:));
        img = 20 * log10(img ./ (mx + eps) + eps);
    end
    imagesc(xax, cfg.y_mm, img);
    axis image;
    set(gca, 'YDir', 'normal');
    colormap(gca, cfg.CMAP);
    colorbar;
    if cfg.DB_SCALE
        clim([-50 0]);
    else
        switch cfg.CLIM_MODE
            case 'percentile'
                cl = prctile(img(:), cfg.CLIM_PRC);
                if cl(1) >= cl(2), cl(2) = cl(1) + eps; end
                clim(cl);
            case 'manual'
                if ~isempty(cfg.CLIM_MANUAL), clim(cfg.CLIM_MANUAL); end
        end
    end
    xlabel('Lateral (mm)');
    ylabel('Sweep (mm)');
    title(ttl, 'Interpreter', 'tex');
    hold on;
    for lb = cfg.lane_x_mm
        xline(lb, '--', 'Color', [0.9 0.4 0.1], 'LineWidth', 0.8, 'Alpha', 0.7);
    end
    hold off;
end

function blk = read_bf_window(bf_file, vname, win_rows)
%READ_BF_WINDOW  Read an axial row-subset from a beamformed .mat variable.
%   Returns [numel(win_rows) × N_LAT_BF × N_EI] single.
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
    [wl, nc, ne] = size(blk);
    env = single(abs(hilbert(reshape(double(blk), wl, nc * ne))));
    env = reshape(env, wl, nc, ne);
end

function slab = gate_slab(env, surf_arr, win_lo, win_len, ...
                           buff_depth, ax_len, reduce, n_ei, lat_cols)
%GATE_SLAB  Uniform gating: surf_arr is [1 × n_ei], same depth for all columns per frame.
    slab    = zeros(n_ei, numel(lat_cols), 'single');
    n_clamp = 0;
    for ei = 1:n_ei
        s = surf_arr(ei) - win_lo + 1;
        r = (s + buff_depth) : (s + buff_depth + ax_len - 1);
        r = r(r >= 1 & r <= win_len);
        if isempty(r), n_clamp = n_clamp + 1; continue; end
        patch = env(r, lat_cols, ei);
        switch reduce
            case 'sum',  slab(ei, :) = sum(patch,  1);
            case 'max',  slab(ei, :) = max(patch,  [], 1);
            case 'mean', slab(ei, :) = mean(patch, 1);
        end
    end
    if n_clamp > 0
        warning('gate_slab: %d/%d frames clamped.', n_clamp, n_ei);
    end
end

function slab = gate_slab_percol(env, surf_col, win_lo, win_len, ...
                                  buff_depth, ax_len, reduce, n_ei)
%GATE_SLAB_PERCOL  Per-column gating: each lateral column has its own gate row.
%   env:      [win_len × n_lat × n_ei] single (already lat-trimmed by caller)
%   surf_col: [n_lat × n_ei] per-column surface sample index (absolute)
%   Returns:  [n_ei × n_lat] single
    n_lat   = size(surf_col, 1);
    slab    = zeros(n_ei, n_lat, 'single');
    n_clamp = 0;
    for ei = 1:n_ei
        for ci = 1:n_lat
            s = surf_col(ci, ei) - win_lo + 1;
            r = (s + buff_depth) : (s + buff_depth + ax_len - 1);
            r = r(r >= 1 & r <= win_len);
            if isempty(r), n_clamp = n_clamp + 1; continue; end
            col = env(r, ci, ei);
            switch reduce
                case 'sum',  slab(ei, ci) = sum(col);
                case 'max',  slab(ei, ci) = max(col);
                case 'mean', slab(ei, ci) = mean(col);
            end
        end
    end
    if n_clamp > 0
        warning('gate_slab_percol: %d/%d cells clamped.', n_clamp, n_ei * n_lat);
    end
end
