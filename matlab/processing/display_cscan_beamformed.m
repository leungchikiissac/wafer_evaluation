% display_cscan_beamformed.m
% Surface-guided C-scan display from beamformed output files.
%
% Depths below the detected surface are specified in mm and converted to
% samples using fs and C_SOUND.  All specified depths are extracted in a
% single pass (one env-block load per variable per lane).
%
% Figure 1 — gating comparison for COMPARE_VAR:
%   rows = GATE_DEPTHS_MM,  cols = [Global mean | Per-acq mean | Per-column]
%
% Figure 2 — main C-scan (gate = GATE_MAIN):
%   rows = GATE_DEPTHS_MM,  cols = variables (ps, fgcf, gcf, cf, nsi, …)
%
% Figure 3 — raw-RF C-scan reference (if SHOW_RAW, one tile, depth-independent)
%
% Figure 4 — surface profile with global plane-fit overlay:
%   left  = surface depth vs step (per lane) + dashed plane fit per lane
%   right = surface depth vs lateral (stitched) + red-dashed plane fit
%
% Surface gating optionally uses a global plane regressed across all lanes
% (USE_SURFACE_REGRESSION); Pass A detects surfaces, the plane is fit, then
% Pass B gates on either the fitted plane or the raw detected surface.

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

% ── Depth specification ────────────────────────────────────────────────────
% Depths below the detected surface to gate, in mm.
GATE_DEPTHS_MM = [0.0, 0.05, 0.1];

% Gate window thickness in mm (integration depth per gate).
AX_LEN_MM = 0.05;

% Speed of sound in scan medium (m/s).
% Water at ~22 °C: 1480 m/s.  Change if scanning through another medium.
C_SOUND = 1480;

% ── Variables ──────────────────────────────────────────────────────────────
% Names in the beamformed .mat files, or 'nsi' (computed from dcl/dcr/zml).
VARIABLES = {'ps_data_ds', 'fgcf_ds', 'gcf_ds', 'cf_ds', 'nsi'};

% Gating comparison / main-figure selection
GATE_MAIN   = 'per_acq';     % 'global' | 'per_acq' | 'per_col' — Figure 2
COMPARE_VAR = 'ps_data_ds';  % variable shown in Figure 1 (3-way comparison)

% Surface detection opts passed to cscan_surface_guided_fn
SURF_OPTS              = struct();
SURF_OPTS.search_range = [892, 1000];  % samples; surface at ~5.8–6.1 mm ≈ 922–970 smp, ±30 smp margin
SURF_OPTS.threshold    = 500;
SURF_OPTS.buff_depth   = 16;
SURF_OPTS.ax_len       = 1;

% Lateral trim per beamformed lane ([] = all 256 columns)
LAT_TRIM = 25:232;

REDUCE = 'sum';   % gate reduction: 'sum' | 'max' | 'mean'

% Display
SHOW_RAW    = true;
DB_SCALE    = false;
CLIM_MODE   = 'percentile';
CLIM_PRC    = [1 99.5];
CLIM_MANUAL = [];
CMAP        = 'gray';
SAVE_FIG    = true;
SAVE_DIR    = fullfile(BF_DIR, 'figures');   % created automatically if absent

USE_CACHE = true;

USE_SURFACE_REGRESSION = true;   % gate on fitted plane instead of raw surface
REG_DS_ELEM            = 8;      % element downsample factor for plane fit
REG_DS_STEP            = 5;      % acquisition downsample factor for plane fit

%% ── Preflight ─────────────────────────────────────────────────────────────

addpath(fileparts(mfilename('fullpath')));

valid_modes = struct('global', 0, 'per_acq', 0, 'per_col', 0);
if ~isfield(valid_modes, GATE_MAIN)
    error('display_cscan_beamformed: unknown GATE_MAIN ''%s''.', GATE_MAIN);
end

% Load geometry from workspace
if exist(WORKSPACE_FILE, 'file')
    ws = load(WORKSPACE_FILE, 'Receive', 'Trans');
    frame_length = ws.Receive.endSample;
    pitch_mm     = ws.Trans.spacingMm;
    if isfield(ws.Receive, 'decimSampleRate')
        fs = ws.Receive(1).decimSampleRate * 1e6;   % Hz
    else
        fs = 117.65e6;
    end
else
    frame_length = 2048;
    pitch_mm     = 6.9 / 128;
    fs           = 117.65e6;
    warning('display_cscan_beamformed: workspace not found — using fallback geometry.');
end
col_pitch_mm = pitch_mm / 2;

% Convert depths from mm → samples  (round-trip: depth = c*t/2 → t = 2*depth/c)
smp_per_mm       = 2 * fs / (C_SOUND * 1e3);         % samples per mm (one-way)
buff_depths_smp  = round(GATE_DEPTHS_MM * smp_per_mm);
ax_len_smp       = max(1, round(AX_LEN_MM * smp_per_mm));
N_DEPTHS         = numel(GATE_DEPTHS_MM);

fprintf('fs=%.2f MHz  |  c=%d m/s  |  %.4f mm/sample\n', fs/1e6, C_SOUND, 1/smp_per_mm);
fprintf('Gate depths:'); fprintf('  %.2f mm (%d smp)', [GATE_DEPTHS_MM; buff_depths_smp]); fprintf('\n');
fprintf('Gate window: %.2f mm (%d smp)\n\n', AX_LEN_MM, ax_len_smp);

if ~exist(CACHE_DIR, 'dir'), mkdir(CACHE_DIR); end

needs_nsi = any(strcmp(VARIABLES, 'nsi'));
bf_vars   = VARIABLES(~strcmp(VARIABLES, 'nsi'));

%% ── Per-lane loop ─────────────────────────────────────────────────────────
% Each slab entry is [N_EI × n_lat_trim × N_DEPTHS] — all depths in one block.

%% ── Pass A: surface detection ─────────────────────────────────────────────

kept_xi      = [];
surface_maps = {};   % {k} = surf_bf [n_elem × N_EI] after mod-unwrap
cscan_raws   = {};   % {k} = cscan_raw from surface detection
elem_lats    = {};   % {k} = elem_lat_mm [n_elem × 1] lateral coords
fit_pts      = {};   % {k} = [n_pts × 3]: [lat_mm, step_mm, depth_mm]

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

    fprintf('── xi=%d  (xloc=%.1f mm) ──────────────────────────\n', xi, xloc(xi));
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
        fprintf('  Surface: from cache\n');
    else
        fprintf('  Surface: running cscan_surface_guided_fn...\n');
        sz_s = load(fullfile(RAW_DIR, raw_size), 'rf_size');
        opts_k           = SURF_OPTS;
        opts_k.lat_range = 1:sz_s.rf_size(2);
        [cscan_raw, surface_map] = cscan_surface_guided_fn(RAW_DIR, raw_size, raw_txt, opts_k);
        save(cache_f, 'surface_map', 'cscan_raw');
        fprintf('  Surface: cached\n');
    end

    surf_bf = mod(double(surface_map) - 1, frame_length) + 1;   % [n_elem × N_EI]
    n_elem  = size(surf_bf, 1);
    surface_maps{k} = surf_bf; %#ok<SAGROW>
    cscan_raws{k}   = cscan_raw; %#ok<SAGROW>

    % Lateral coordinate of each element (maps element index to BF column space)
    elem_lat_mm = xloc(xi) + (linspace(1, N_LAT_BF, n_elem)' - 1) * col_pitch_mm;  % [n_elem × 1]
    elem_lats{k} = elem_lat_mm; %#ok<SAGROW>

    % Downsampled points for plane fit
    ei_e = 1:REG_DS_ELEM:n_elem;
    ei_s = 1:REG_DS_STEP:N_EI;
    step_v_ds = (ei_s - 1) * STEP_MM;                     % [1 × n_ds_step]
    [L, S] = ndgrid(elem_lat_mm(ei_e), step_v_ds);        % [n_ds_elem × n_ds_step]
    D = surf_bf(ei_e, ei_s) / smp_per_mm;                 % samples → mm
    fit_pts{k} = [L(:), S(:), D(:)]; %#ok<SAGROW>

    % Surface stats for console
    surf_acq_tmp = round(mean(surf_bf, 1));
    if isempty(LAT_TRIM)
        lat_cols_tmp = 1:N_LAT_BF;
    else
        lat_cols_tmp = LAT_TRIM(LAT_TRIM >= 1 & LAT_TRIM <= N_LAT_BF);
    end
    elem_x_tmp    = linspace(1, N_LAT_BF, n_elem);
    surf_col_tmp  = round(interp1(elem_x_tmp', surf_bf, lat_cols_tmp'));  % [n_lat_trim × N_EI]
    fprintf('  Surface: global=%d | per-acq %d–%d | per-col %d–%d\n', ...
        round(mean(surf_bf(:))), min(surf_acq_tmp), max(surf_acq_tmp), ...
        min(surf_col_tmp(:)), max(surf_col_tmp(:)));
end

%% ── Plane fit ─────────────────────────────────────────────────────────────

P        = vertcat(fit_pts{:});                       % [n_pts × 3]
A_fit    = [P(:,1), P(:,2), ones(size(P,1),1)];
reg_coef = A_fit \ P(:,3);                            % [a; b; c]
reg_a = reg_coef(1);  reg_b = reg_coef(2);  reg_c = reg_coef(3);
resid    = P(:,3) - A_fit * reg_coef;
reg_rms_mm = sqrt(mean(resid.^2));
fprintf('\nSurface plane fit (%d pts, ds %d×%d):\n', size(P,1), REG_DS_ELEM, REG_DS_STEP);
fprintf('  depth = %+.5f·lat %+.5f·step %+.4f  [mm]\n', reg_a, reg_b, reg_c);
fprintf('  RMS residual: %.4f mm (%.2f samples) | tilt: lat %.4f°, step %.4f°\n\n', ...
    reg_rms_mm, reg_rms_mm * smp_per_mm, atand(reg_a), atand(reg_b));
if reg_rms_mm * smp_per_mm > SURF_OPTS.buff_depth
    warning('Surface plane RMS residual (%.2f smp) exceeds buff_depth (%d smp) — plane fit may be poor.', ...
        reg_rms_mm * smp_per_mm, SURF_OPTS.buff_depth);
end

step_v = (0:N_EI-1) * STEP_MM;   % [1 × N_EI]  — used in Pass B and Figure 4

%% ── Pass B: gating ────────────────────────────────────────────────────────

slabs_g   = {};
slabs_a   = {};
slabs_c   = {};
raw_slabs = {};

surf_vs_step = {};
surf_vs_lat  = {};

for k = 1:numel(kept_xi)
    xi   = kept_xi(k);
    xstr = num2str(xloc(xi));

    bf_file  = fullfile(BF_DIR, ...
        ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', xstr, ...
         'mm_angle1_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);

    surf_bf = surface_maps{k};
    n_elem  = size(surf_bf, 1);
    elem_lat_mm = elem_lats{k};

    fprintf('── xi=%d  (xloc=%.1f mm) ──────────────────────────\n', xi, xloc(xi));

    %% ── Raw gating surfaces ──────────────────────────────────────────────
    surf_global = repmat(round(mean(surf_bf(:))), 1, N_EI);
    surf_acq    = round(mean(surf_bf, 1));

    if isempty(LAT_TRIM)
        lat_cols = 1:N_LAT_BF;
    else
        lat_cols = LAT_TRIM(LAT_TRIM >= 1 & LAT_TRIM <= N_LAT_BF);
    end

    elem_x        = linspace(1, N_LAT_BF, n_elem);
    surf_col_full = interp1(elem_x', double(surf_bf), (1:N_LAT_BF)');
    surf_col      = round(surf_col_full(lat_cols, :));

    surf_vs_step{k} = mean(double(surf_bf), 1); %#ok<SAGROW>
    surf_vs_lat{k}  = mean(double(surf_col), 2); %#ok<SAGROW>

    %% ── Regressed gating surfaces ────────────────────────────────────────
    % Regressed surface (analytic from plane coefficients)
    col_lat_mm   = xloc(xi) + (lat_cols(:) - 1) * col_pitch_mm;          % [n_lat_trim × 1]
    surf_reg_acq = round((reg_a * mean(elem_lat_mm) + reg_b * step_v + reg_c) * smp_per_mm);  % [1 × N_EI]
    surf_reg_col = round((reg_a * col_lat_mm       + reg_b * step_v + reg_c) * smp_per_mm);  % [n_lat_trim × N_EI]
    surf_reg_glo = repmat(round((reg_a * mean(elem_lat_mm) + reg_b * mean(step_v) + reg_c) * smp_per_mm), 1, N_EI);

    if USE_SURFACE_REGRESSION
        surf_g_use = surf_reg_glo;
        surf_a_use = surf_reg_acq;
        surf_c_use = surf_reg_col;
        fprintf('  Gate surface: plane-regressed\n');
    else
        surf_g_use = surf_global;
        surf_a_use = surf_acq;
        surf_c_use = surf_col;
        fprintf('  Gate surface: raw detected\n');
    end

    %% ── Axial window (covers all surfaces + deepest gate) ────────────────
    all_surf = [surf_g_use(:); surf_a_use(:); surf_c_use(:)];
    max_buff = max(buff_depths_smp);
    gate_max = max(all_surf) + max_buff + ax_len_smp;
    if gate_max > DEPTH_BF
        warning('Deepest gate at sample %d > DEPTH_BF=%d for xi=%d.', gate_max, DEPTH_BF, xi);
    end
    win_lo   = max(1,        min(all_surf) - 32);
    win_hi   = min(DEPTH_BF, max(all_surf) + max_buff + ax_len_smp + 32);
    win_rows = win_lo : win_hi;
    win_len  = numel(win_rows);
    fprintf('  Window: samples %d–%d  (%d rows)\n', win_lo, win_hi, win_len);

    slabs_g{k} = struct(); %#ok<SAGROW>
    slabs_a{k} = struct(); %#ok<SAGROW>
    slabs_c{k} = struct(); %#ok<SAGROW>

    %% ── NSI ─────────────────────────────────────────────────────────────
    if needs_nsi
        fprintf('  nsi... ');  t0 = tic;
        e_dcl   = env_block(read_bf_window(bf_file, 'dclbf_ds', win_rows));
        e_dcr   = env_block(read_bf_window(bf_file, 'dcrbf_ds', win_rows));
        e_zml   = env_block(read_bf_window(bf_file, 'zmlbf_ds', win_rows));
        nsi_blk = abs(0.5 * (e_dcl + e_dcr) - e_zml);
        clear e_dcl e_dcr e_zml;
        slabs_g{k}.nsi = gate_depths(nsi_blk,              surf_g_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, lat_cols, false);
        slabs_a{k}.nsi = gate_depths(nsi_blk,              surf_a_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, lat_cols, false);
        slabs_c{k}.nsi = gate_depths(nsi_blk(:,lat_cols,:), surf_c_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, [],       true);
        clear nsi_blk;
        fprintf('%.1f s\n', toc(t0));
    end

    %% ── Standard variables ───────────────────────────────────────────────
    for vi = 1:numel(bf_vars)
        vname = bf_vars{vi};
        fprintf('  %-20s ... ', vname);  t0 = tic;
        blk = read_bf_window(bf_file, vname, win_rows);
        is_weight = length(vname) >= 10 && strcmp(vname(end-9:end), '_weight_ds');
        env = select_env(blk, is_weight);
        clear blk;
        slabs_g{k}.(vname) = gate_depths(env,              surf_g_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, lat_cols, false);
        slabs_a{k}.(vname) = gate_depths(env,              surf_a_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, lat_cols, false);
        slabs_c{k}.(vname) = gate_depths(env(:,lat_cols,:), surf_c_use, win_lo, win_len, buff_depths_smp, ax_len_smp, REDUCE, N_EI, [],       true);
        clear env;
        fprintf('%.1f s\n', toc(t0));
    end

    if SHOW_RAW
        raw_slabs{k} = single(cscan_raws{k}); %#ok<SAGROW>
    end
end

if isempty(kept_xi)
    error('display_cscan_beamformed: no valid data found for XI_LIST.');
end
if ~isfield(slabs_a{1}, COMPARE_VAR)
    error('display_cscan_beamformed: COMPARE_VAR ''%s'' not in VARIABLES.', COMPARE_VAR);
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
    % Each is [N_EI × K*n_lat_trim × N_DEPTHS]
end

raw_cscan_stacked = [];
if SHOW_RAW && ~isempty(raw_slabs)
    raw_cscan_stacked = cat(2, raw_slabs{:});
end

% Axis vectors
n_lat_trim = size(slabs_a{1}.(VARIABLES{1}), 2);
y_mm       = (0 : N_EI - 1) * STEP_MM;
x0_mm      = xloc(kept_xi(1));
x_bf_mm    = x0_mm + (0 : K*n_lat_trim - 1) * col_pitch_mm;
lane_x_mm  = xloc(kept_xi(2:end));

if ~isempty(raw_cscan_stacked)
    n_raw_cols     = size(raw_cscan_stacked, 2);
    n_raw_per_lane = round(n_raw_cols / K);
    x_raw_mm       = x0_mm + (0 : n_raw_cols-1) * (6.9 / n_raw_per_lane);
end

% Display config
cfg = struct('DB_SCALE', DB_SCALE, 'CLIM_MODE', CLIM_MODE, 'CLIM_PRC', CLIM_PRC, ...
             'CLIM_MANUAL', CLIM_MANUAL, 'CMAP', CMAP, 'y_mm', y_mm, 'lane_x_mm', lane_x_mm);

switch GATE_MAIN
    case 'global',  stacked_main = stacked_g;  gate_lbl = 'global mean';
    case 'per_acq', stacked_main = stacked_a;  gate_lbl = 'per-acq mean';
    case 'per_col', stacked_main = stacked_c;  gate_lbl = 'per-column';
end

depth_labels = arrayfun(@(d) sprintf('%.2f mm', d), GATE_DEPTHS_MM, 'UniformOutput', false);

%% ── Figure 1: gating comparison (N_DEPTHS × 3) ───────────────────────────

cmp_srcs  = {stacked_g,     stacked_a,       stacked_c};
cmp_names = {'Global mean', 'Per-acq mean',  'Per-column'};

fig_cmp = figure('Name', ['Gating comparison — ' COMPARE_VAR], ...
                 'Units', 'normalized', 'Position', [0.02 0.1 0.96 0.85]);
tl_cmp  = tiledlayout(N_DEPTHS, 3, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl_cmp, sprintf('Gating comparison  |  %s  |  xi=%d:%d  |  %s  |  %s', ...
    strrep(COMPARE_VAR,'_','\_'), kept_xi(1), kept_xi(end), REDUCE, ...
    sprintf('c=%d m/s', C_SOUND)), 'FontWeight', 'bold');

for d = 1:N_DEPTHS
    for j = 1:3
        nexttile(tl_cmp);
        draw_tile(cmp_srcs{j}.(COMPARE_VAR)(:,:,d), x_bf_mm, ...
                  sprintf('%s  |  %s', cmp_names{j}, depth_labels{d}), cfg);
    end
end

%% ── Figure 2: all variables at all depths (N_DEPTHS × N_VARS) ────────────

N_VARS  = numel(VARIABLES);
fig_main = figure('Name', 'C-scan — beamformed outputs', ...
                  'Units', 'normalized', 'Position', [0.02 0.04 0.96 0.92]);
tl_main  = tiledlayout(N_DEPTHS, N_VARS, 'TileSpacing', 'compact', 'Padding', 'compact');
title(tl_main, sprintf('Beamformed C-scan  [%s gate]  |  xi=%d:%d  (%.1f–%.1f mm)  |  %s', ...
    gate_lbl, kept_xi(1), kept_xi(end), xloc(kept_xi(1)), xloc(kept_xi(end)), REDUCE), ...
    'FontWeight', 'bold');

for d = 1:N_DEPTHS
    for vi = 1:N_VARS
        vn = VARIABLES{vi};
        nexttile(tl_main);
        draw_tile(stacked_main.(vn)(:,:,d), x_bf_mm, ...
                  sprintf('%s  |  %s', strrep(vn,'_','\_'), depth_labels{d}), cfg);
    end
end

%% ── Figure 3: raw-RF C-scan reference (depth-independent) ────────────────

if SHOW_RAW && ~isempty(raw_cscan_stacked)
    fig_raw = figure('Name', 'Raw RF C-scan reference', ...
                     'Units', 'normalized', 'Position', [0.1 0.2 0.8 0.5]);
    tiledlayout(1, 1, 'Padding', 'compact');
    nexttile;
    draw_tile(raw_cscan_stacked, x_raw_mm, 'Raw RF C-scan', cfg);
    title(gca, sprintf('Raw RF C-scan  |  xi=%d:%d', kept_xi(1), kept_xi(end)));
end

%% ── Figure 4: surface profile ─────────────────────────────────────────────

fig_surf = figure('Name', 'Surface profile', ...
                  'Units', 'normalized', 'Position', [0.05 0.15 0.9 0.45]);
tiledlayout(1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

% Left: mean surface depth vs step (Y direction)
nexttile;
hold on;
for k = 1:numel(kept_xi)
    xi   = kept_xi(k);
    s_mm = surf_vs_step{k} / fs * (C_SOUND * 1e3) / 2;
    h = plot(y_mm, s_mm, 'DisplayName', sprintf('xi=%d (x=%.1f mm)', xi, xloc(xi)));
    % Overlay plane fit for this lane (dashed, same colour)
    s_reg_mm = reg_a * mean(elem_lats{k}) + reg_b * y_mm + reg_c;
    plot(y_mm, s_reg_mm, '--', 'Color', h.Color, 'LineWidth', 1.2, 'HandleVisibility', 'off');
end
hold off;
xlabel('Step position (mm)');
ylabel('Surface depth (mm)');
title('Surface depth vs step  (mean over elements)');
legend('Location', 'best');
grid on;
set(gca, 'YDir', 'normal');

% Right: mean surface depth vs lateral (X direction, stitched across lanes)
% Uses x_bf_mm — same X axis as the C-scan — so trimmed columns tile without overlap.
nexttile;
tmp = cellfun(@(v) v(:)', surf_vs_lat, 'UniformOutput', false);
surf_lat_all = cat(2, tmp{:});   % [1 × K*n_lat_trim], matches x_bf_mm
surf_lat_mm  = surf_lat_all(:) / fs * (C_SOUND * 1e3) / 2;
plot(x_bf_mm, surf_lat_mm);
hold on;
plot(x_bf_mm, reg_a * x_bf_mm + reg_b * mean(step_v) + reg_c, 'r--', 'LineWidth', 1.5, 'DisplayName', sprintf('Plane fit (RMS %.4f mm)', reg_rms_mm));
legend('Raw', 'Plane fit', 'Location', 'best');
hold off;
xlabel('Lateral position (mm)');
ylabel('Surface depth (mm)');
title('Surface depth vs lateral  (mean over steps, stitched)');
grid on;
set(gca, 'YDir', 'normal');
for lb = lane_x_mm
    xline(lb, '--', 'Color', [0.9 0.4 0.1], 'LineWidth', 0.8, 'Alpha', 0.7);
end
if USE_SURFACE_REGRESSION
    reg_lbl = sprintf('gate: plane (RMS %.4f mm)', reg_rms_mm);
else
    reg_lbl = 'gate: raw';
end
sgtitle(sprintf('Surface profile  |  xi=%d:%d  |  fs=%.2f MHz  |  c=%d m/s  |  %s', ...
    kept_xi(1), kept_xi(end), fs/1e6, C_SOUND, reg_lbl), 'FontWeight', 'bold');

%% ── Report ────────────────────────────────────────────────────────────────

fprintf('\n=== Done ===\n');
fprintf('Surface regression: %s', mat2str(USE_SURFACE_REGRESSION));
if USE_SURFACE_REGRESSION
    fprintf('  (RMS %.4f mm = %.2f samples)', reg_rms_mm, reg_rms_mm * smp_per_mm);
end
fprintf('\n');
fprintf('Stacked: %d × %d × %d depths  (%d lanes | %d vars | gate: %s)\n', ...
    size(stacked_main.(VARIABLES{1}), 1), size(stacked_main.(VARIABLES{1}), 2), ...
    N_DEPTHS, K, N_VARS, GATE_MAIN);

if SAVE_FIG
    if ~exist(SAVE_DIR, 'dir'), mkdir(SAVE_DIR); end
    gate_tag = regexprep(GATE_MAIN, '_', '');       % 'peracq' | 'global' | 'percol'
    reg_tag  = char('R' * USE_SURFACE_REGRESSION + 'r' * ~USE_SURFACE_REGRESSION);  % 'R'=regression, 'r'=raw
    stamp    = char(datetime('now', 'Format', 'yyyyMMdd_HHmm'));
    base     = sprintf('xi%d-%d_%s_%s_%s', kept_xi(1), kept_xi(end), gate_tag, reg_tag, stamp);

    save_png = @(fig, tag) print(fig, fullfile(SAVE_DIR, [base '_' tag]), '-dpng', '-r200');

    save_png(fig_main, 'cscan');
    save_png(fig_cmp,  'compare');
    save_png(fig_surf, 'surface');
    if SHOW_RAW && exist('fig_raw', 'var')
        save_png(fig_raw, 'raw');
    end
    fprintf('Figures saved to %s\n  prefix: %s\n', SAVE_DIR, base);
end

%% ════════════════════════════════════════════════════════════════════════════
%  Local functions
%% ════════════════════════════════════════════════════════════════════════════

function out = gate_depths(env, surf_arr, win_lo, win_len, buff_smp_vec, ax_len, reduce, n_ei, lat_cols, percol)
%GATE_DEPTHS  Gate env at multiple depths; returns [N_EI × n_lat × N_depths].
%   percol=false: surf_arr is [1 × n_ei], lat_cols selects from env dim 2.
%   percol=true:  surf_arr is [n_lat × n_ei], env is already lat-trimmed.
    N_depths = numel(buff_smp_vec);
    if percol
        n_lat = size(env, 2);
    else
        n_lat = numel(lat_cols);
    end
    out = zeros(n_ei, n_lat, N_depths, 'single');
    for d = 1:N_depths
        if percol
            out(:,:,d) = gate_slab_percol(env, surf_arr, win_lo, win_len, ...
                                          buff_smp_vec(d), ax_len, reduce, n_ei);
        else
            out(:,:,d) = gate_slab(env, surf_arr, win_lo, win_len, ...
                                   buff_smp_vec(d), ax_len, reduce, n_ei, lat_cols);
        end
    end
end

function env = select_env(blk, is_weight)
%SELECT_ENV  Hilbert envelope, or pass-through for weight variables.
    if is_weight
        env = single(blk);
    else
        env = env_block(blk);
    end
end

function draw_tile(img_in, xax, ttl, cfg)
%DRAW_TILE  imagesc + clim + lane markers into the current axes.
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
    [wl, nc, ne] = size(blk);
    env = single(abs(hilbert(reshape(double(blk), wl, nc * ne))));
    env = reshape(env, wl, nc, ne);
end

function slab = gate_slab(env, surf_arr, win_lo, win_len, buff_depth, ax_len, reduce, n_ei, lat_cols)
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

function slab = gate_slab_percol(env, surf_col, win_lo, win_len, buff_depth, ax_len, reduce, n_ei)
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
