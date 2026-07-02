% Atomic checkpoint beamform script with resumability
% Saves every N ei iterations (configurable). On crash, resume from last checkpoint.

clearvars

%% Configuration

CHECKPOINT_INTERVAL = 10;  % Save checkpoint every N ei iterations
REPORT_MULTIPLE = 2;

% Paths (modify these as needed)
WORKSPACE_FILE   = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat';
DATA_DIR         = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';
CHECKPOINT_BASE  = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\checkpoints';
OUTPUT_DIR       = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';

% Beamform parameters (must match those used in bf_params precomputation)
depth = 2048;
ele   = 128;
ua    = 1;

%% Setup & Resume

addpath(fileparts(DATA_DIR));
load(WORKSPACE_FILE);

if ~exist(CHECKPOINT_BASE, 'dir')
    mkdir(CHECKPOINT_BASE);
end

xloc    = 0:6.9:41.4;
last_xi = 3;   % Default: start from xi=3 (matches original script)
last_ei = 0;

% Scan checkpoint_base (not a new subdir) for existing checkpoints
checkpoint_files = dir(fullfile(CHECKPOINT_BASE, '**', 'checkpoint_xi*.mat'));
if ~isempty(checkpoint_files)
    for f = checkpoint_files'
        parts = sscanf(f.name, 'checkpoint_xi%d_ei%d.mat');
        if numel(parts) == 2
            if parts(1) > last_xi || (parts(1) == last_xi && parts(2) > last_ei)
                last_xi = parts(1);
                last_ei = parts(2);
            end
        end
    end

    % Load the latest checkpoint
    checkpoint_file = fullfile(CHECKPOINT_BASE, sprintf('checkpoint_xi%d_ei%d.mat', last_xi, last_ei));
    fprintf('Loading checkpoint: xi=%d, ei=%d\n', last_xi, last_ei);
    load(checkpoint_file);
    fprintf('Resuming from xi=%d, ei=%d\n', last_xi, last_ei);
else
    % First run: initialize output arrays with correct dimensions
    out_depth = floor(depth / ua);
    out_lat   = ele * 2;  % interp2 doubles lateral resolution
    n_ei      = 1200;

    ps_data_ds    = zeros(out_depth, out_lat, n_ei, 'single');
    zmlbf_ds      = zeros(out_depth, out_lat, n_ei, 'single');
    dcrbf_ds      = zeros(out_depth, out_lat, n_ei, 'single');
    dclbf_ds      = zeros(out_depth, out_lat, n_ei, 'single');
    zmlbf01_ds    = zeros(out_depth, out_lat, n_ei, 'single');
    dcrbf01_ds    = zeros(out_depth, out_lat, n_ei, 'single');
    dclbf01_ds    = zeros(out_depth, out_lat, n_ei, 'single');
    fcf_ds        = zeros(out_depth, out_lat, n_ei, 'single');
    cf_ds         = zeros(out_depth, out_lat, n_ei, 'single');
    gcf_ds        = zeros(out_depth, out_lat, n_ei, 'single');
    fgcf_ds       = zeros(out_depth, out_lat, n_ei, 'single');
    fcf_weight_ds = zeros(out_depth, out_lat, n_ei, 'single');
    fgcf_weight_ds= zeros(out_depth, out_lat, n_ei, 'single');

    fprintf('Starting fresh run from xi=%d, ei=1\n', last_xi);
end

% Precompute interpolation grids once (same for all ei and xi)
[xo, yo]   = meshgrid(1:128, 1:depth);
[xii, yii] = meshgrid(1:0.5:128.5, 1:depth);

%% Main processing loop

frame_length = Receive.endSample;
f0      = 29.411764705882350e6;
fs      = 117.6470588235294e6;
f_clock = 500e6;
downsample = 1;
dc         = 1;

angles = 0;
for ai = 1:1

    angle       = angles(ai);
    fNum        = 3;
    trans_pitch = Trans.spacingMm*1e-3;

    angle_val = 0;
    ul        = 1;

    bf_params = precompute_bf_geometry_hann(depth, ele*2, trans_pitch/2, fs, angle_val, dc, fNum, ul, ua);

    for xi = last_xi:7

        fprintf('\n=== Processing xi=%d (xloc=%.1f mm) ===\n', xi, xloc(xi));
        tic

        filename_read = fullfile(DATA_DIR, ...
            ['RFbatch_5angle_PI_single_step0.05mm_x', num2str(xloc(xi)), 'mm15-May-2026.txt']);
        filename_size = fullfile(DATA_DIR, ...
            ['RFbatch_5angle_PI_single_step0.05mm_x', num2str(xloc(xi)), 'mm15-May-2026_size.mat']);

        load(filename_size);
        RF_Dim = rf_size;

        fid    = fopen(filename_read, 'r');
        RF_tmp = fread(fid, 'double');   % read as double directly — avoids int16 cast inside loop
        fclose(fid);
        RFdata = reshape(RF_tmp, RF_Dim);

        toc

        % Inner loop over elements
        ei_times = zeros(1, 1200);
        for ei = (last_ei + 1):1200

            ei_t_start = tic;

            if mod(ei, REPORT_MULTIPLE) == 0
                completed = ei - last_ei - 1;
                if completed > 0
                    avg_t = mean(ei_times(last_ei+1 : ei-1));
                    remaining = 1200 - ei;
                    eta = datetime('now') + seconds(avg_t * remaining);
                    fprintf('  ei=%d / 1200 | avg %.2fs | ETA %s\n', ei, avg_t, datestr(eta, 'HH:MM:SS'));
                else
                    fprintf('  ei=%d / 1200\n', ei);
                end
            end

            rf_0angle     = RFdata(3*(ai-1)*frame_length+1 : 3*(ai-1)*frame_length+frame_length, :, ei);
            rf_0angle_cut = rf_0angle(1:depth, :);

            % Interpolation — grids precomputed outside loop
            rf_0angle_cut_interp = interp2(xo, yo, rf_0angle_cut, xii, yii);

            % Beamform
            [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, ...
                 cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, ...
                 spectral_cf_weight, spectral_gcf_weight, dclbf01, dcrbf01, zmlbf01] = ...
                 bf_fgcf_fast_execute(rf_0angle_cut_interp, bf_params, fs, ul, ua);

            % Store (ua=1 so 1:ua:end is full array)
            ps_data_ds(:,:,ei)    = single(ps_data);
            zmlbf_ds(:,:,ei)      = single(zmlbf);
            dcrbf_ds(:,:,ei)      = single(dcrbf);
            dclbf_ds(:,:,ei)      = single(dclbf);
            zmlbf01_ds(:,:,ei)    = single(zmlbf01);
            dcrbf01_ds(:,:,ei)    = single(dcrbf01);
            dclbf01_ds(:,:,ei)    = single(dclbf01);
            fcf_ds(:,:,ei)        = single(spectral_cf_weighted_data);
            cf_ds(:,:,ei)         = single(cf_weighted_data);
            gcf_ds(:,:,ei)        = single(gcf_weighted_data);
            fgcf_ds(:,:,ei)       = single(spectral_gcf_weighted_data);
            fcf_weight_ds(:,:,ei) = single(spectral_cf_weight);
            fgcf_weight_ds(:,:,ei)= single(spectral_gcf_weight);

            ei_times(ei) = toc(ei_t_start);

            % Checkpoint every N iterations
            if mod(ei, CHECKPOINT_INTERVAL) == 0
                checkpoint_file = fullfile(CHECKPOINT_BASE, sprintf('checkpoint_xi%d_ei%d.mat', xi, ei));
                save(checkpoint_file, ...
                    'ps_data_ds', 'zmlbf_ds', 'dcrbf_ds', 'dclbf_ds', ...
                    'fcf_ds', 'cf_ds', 'gcf_ds', 'fgcf_ds', ...
                    'fcf_weight_ds', 'fgcf_weight_ds', ...
                    'zmlbf01_ds', 'dclbf01_ds', 'dcrbf01_ds', ...
                    'downsample', 'dc', 'xi', 'ei', '-v7.3');
                fprintf('    Checkpoint saved: xi=%d, ei=%d\n', xi, ei);
            end
        end

        % Final save for this xi position
        save_name = fullfile(OUTPUT_DIR, ...
            ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', num2str(xloc(xi)), ...
             'mm_angle', num2str(ai), '_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);

        save(save_name, 'ps_data_ds', 'zmlbf_ds', 'dcrbf_ds', 'dclbf_ds', ...
            'fcf_ds', 'cf_ds', 'gcf_ds', 'fgcf_ds', 'downsample', 'dc', ...
            'fcf_weight_ds', 'fgcf_weight_ds', 'zmlbf01_ds', 'dclbf01_ds', 'dcrbf01_ds');

        fprintf('Final save: %s\n', save_name);

        last_ei = 0;  % Reset for next xi
    end
end

fprintf('\n=== All processing complete ===\n');
