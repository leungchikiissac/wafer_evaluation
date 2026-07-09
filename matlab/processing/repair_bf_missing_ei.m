% repair_bf_missing_ei.m
% Re-beamform the zero-prefix ei and splice them into existing output .mat files.
%
% Use this to recover lanes corrupted by the resume-reset bug without
% recomputing the full 1200 ei.  Only the GPU path is used here (no parpool
% overhead), keeping memory usage minimal.
%
% Results are written back slice-by-slice via matfile (HDF5 partial write)
% so the already-correct tail ei are never touched.

clearvars

%% ── Configuration ─────────────────────────────────────────────────────────

WORKSPACE_FILE = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat';
DATA_DIR       = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';
OUTPUT_DIR     = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';

% Lanes to repair: [xi, first_missing_ei, last_missing_ei]
% Determined by the Step-0 diagnostic (first non-zero ei - 1 = last missing).
REPAIR = [ ...
    3,   1, 110; ...   % xi=3: ei 1..110 were zeroed by resume-reset bug
    5,   1, 710; ...   % xi=5: ei 1..710 were zeroed by resume-reset bug
];

depth = 2048;  ele = 128;  ua = 1;  ul = 1;
fs    = 117.6470588235294e6;
fNum  = 3;  dc = 1;  downsample = 1;
angle_val = 0;  ai = 1;
xloc  = 0:6.9:41.4;
n_ei  = 1200;

VAR_NAMES = {'ps_data_ds','zmlbf_ds','dcrbf_ds','dclbf_ds', ...
             'fcf_ds','cf_ds','gcf_ds','fgcf_ds', ...
             'fcf_weight_ds','fgcf_weight_ds', ...
             'zmlbf01_ds','dclbf01_ds','dcrbf01_ds'};

%% ── Workspace + bf_params ─────────────────────────────────────────────────

load(WORKSPACE_FILE);
frame_length = Receive.endSample;

bf_params = precompute_bf_geometry_hann(depth, ele*2, Trans.spacingMm*1e-3/2, fs, ...
                                        angle_val, dc, fNum, ul, ua);

% Interp grids (same as main beamform script)
[xo,  yo ] = meshgrid(1:128,       1:depth);
[xii, yii] = meshgrid(1:0.5:128.5, 1:depth);

%% ── GPU warmup ────────────────────────────────────────────────────────────

fprintf('GPU warmup...\n');
bf_fgcf_fast_execute_gpu(zeros(depth, ele*2, 'single'), bf_params, fs, ul, ua);
fprintf('GPU ready.\n\n');

%% ── Repair loop ───────────────────────────────────────────────────────────

for r = 1:size(REPAIR, 1)
    xi     = REPAIR(r, 1);
    ei_lo  = REPAIR(r, 2);
    ei_hi  = REPAIR(r, 3);
    xstr   = num2str(xloc(xi));
    n_miss = ei_hi - ei_lo + 1;

    out_file = fullfile(OUTPUT_DIR, ...
        ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', xstr, ...
         'mm_angle', num2str(ai), '_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);

    if ~exist(out_file, 'file')
        warning('Output file not found, skipping xi=%d: %s', xi, out_file); continue;
    end

    fprintf('=== Repairing xi=%d  ei=%d..%d (%d ei) ===\n', xi, ei_lo, ei_hi, n_miss);

    % Load raw RF
    fname_data = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x',xstr,'mm15-May-2026.txt']);
    fname_size = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x',xstr,'mm15-May-2026_size.mat']);
    load(fname_size); RF_Dim = rf_size;
    fid    = fopen(fname_data, 'r'); RF_tmp = fread(fid, 'double'); fclose(fid);
    RFdata = reshape(RF_tmp, RF_Dim);
    fprintf('  Raw RF loaded.\n');

    row0 = 3*(ai-1)*frame_length + 1;
    row1 = 3*(ai-1)*frame_length + frame_length;

    % Open output file for partial (slice) writes
    m = matfile(out_file, 'Writable', true);

    t_xi = tic;
    for ei = ei_lo:ei_hi
        rf_cut = RFdata(row0:row1, :, ei);
        din    = interp2(xo, yo, rf_cut(1:depth, :), xii, yii);

        [o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11,o12,o13] = ...
            bf_fgcf_fast_execute_gpu(din, bf_params, fs, ul, ua);

        % Write each variable slice directly into the .mat (HDF5 partial write)
        m.ps_data_ds(:, :, ei)     = single(o1);
        m.dclbf_ds(:, :, ei)       = single(o2);
        m.dcrbf_ds(:, :, ei)       = single(o3);
        m.zmlbf_ds(:, :, ei)       = single(o4);
        m.fcf_ds(:, :, ei)         = single(o5);
        m.cf_ds(:, :, ei)          = single(o6);
        m.gcf_ds(:, :, ei)         = single(o7);
        m.fgcf_ds(:, :, ei)        = single(o8);
        m.fcf_weight_ds(:, :, ei)  = single(o9);
        m.fgcf_weight_ds(:, :, ei) = single(o10);
        m.dclbf01_ds(:, :, ei)     = single(o11);
        m.dcrbf01_ds(:, :, ei)     = single(o12);
        m.zmlbf01_ds(:, :, ei)     = single(o13);

        if mod(ei - ei_lo + 1, 10) == 0 || ei == ei_hi
            done    = ei - ei_lo + 1;
            elapsed = toc(t_xi);
            rate    = done / elapsed;
            eta_s   = (n_miss - done) / rate;
            fprintf('  ei=%d/%d  (%.1f s elapsed | %.2f ei/s | ETA %.0f min)\n', ...
                ei, ei_hi, elapsed, rate, eta_s/60);
        end
    end

    fprintf('  xi=%d repair done in %.1f min.\n\n', xi, toc(t_xi)/60);
end

fprintf('=== Repair complete ===\n');
fprintf('Run the Step-0 diagnostic again to verify zero prefix is gone.\n');
