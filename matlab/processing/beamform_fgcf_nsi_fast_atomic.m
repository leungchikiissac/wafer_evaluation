% Atomic checkpoint beamform script with resumability
% Saves every N ei iterations (configurable). On crash, resume from last checkpoint.
% Checkpoint strategy: incremental batch files — only new slices saved each time (~260 MB constant).

clearvars

%% Configuration

CHECKPOINT_INTERVAL = 10;  % Save checkpoint every N ei iterations
REPORT_MULTIPLE     = 2;

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

out_depth = floor(depth / ua);
out_lat   = ele * 2;
n_ei      = 1200;
VAR_NAMES = {'ps_data_ds','zmlbf_ds','dcrbf_ds','dclbf_ds', ...
             'fcf_ds','cf_ds','gcf_ds','fgcf_ds', ...
             'fcf_weight_ds','fgcf_weight_ds', ...
             'zmlbf01_ds','dclbf01_ds','dcrbf01_ds'};

xloc    = 0:6.9:41.4;
last_xi = 3;   % Default: start from xi=3 (matches original script)
last_ei = 0;

% Always preallocate output arrays first
for v = VAR_NAMES
    eval([v{1} ' = zeros(out_depth, out_lat, n_ei, ''single'');']);
end

% Scan for incremental checkpoint files from a previous run
cp_files = dir(fullfile(CHECKPOINT_BASE, 'cp_xi*_ei*.mat'));
if ~isempty(cp_files)
    % Find the latest xi — use files from that xi only
    xi_nums = arrayfun(@(f) sscanf(f.name, 'cp_xi%d_ei%d.mat'), cp_files, 'UniformOutput', false);
    xi_nums = cellfun(@(x) x(1), xi_nums);
    last_xi = max(xi_nums);

    % Load all checkpoint files for last_xi in order to reconstruct state
    xi_files = cp_files(xi_nums == last_xi);
    ei_nums  = arrayfun(@(f) sscanf(f.name, 'cp_xi%d_ei%d.mat'), xi_files, 'UniformOutput', false);
    ei_nums  = cellfun(@(x) x(2), ei_nums);
    [ei_nums, sort_idx] = sort(ei_nums);
    xi_files = xi_files(sort_idx);

    fprintf('Resuming xi=%d — loading %d checkpoint files...\n', last_xi, numel(xi_files));
    for k = 1:numel(xi_files)
        S  = load(fullfile(CHECKPOINT_BASE, xi_files(k).name));
        ei_end   = ei_nums(k);
        ei_start = ei_end - CHECKPOINT_INTERVAL + 1;
        r = ei_start:ei_end;
        for v = VAR_NAMES
            eval([v{1} '(:,:,r) = S.' v{1} '_ck;']);
        end
    end
    last_ei = ei_nums(end);
    fprintf('Resuming from xi=%d, ei=%d\n', last_xi, last_ei);
else
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
        RF_tmp = fread(fid, 'double');
        fclose(fid);
        RFdata = reshape(RF_tmp, RF_Dim);

        toc

        % Reset output arrays for this xi position
        for v = VAR_NAMES
            eval([v{1} '(:) = 0;']);
        end

        % Inner loop over elements
        ei_times = zeros(1, n_ei);
        for ei = (last_ei + 1):n_ei

            ei_t_start = tic;

            if mod(ei, REPORT_MULTIPLE) == 0
                completed = ei - last_ei - 1;
                if completed > 0
                    avg_t     = mean(ei_times(last_ei+1 : ei-1));
                    remaining = n_ei - ei;
                    total_est = avg_t * n_ei;
                    eta       = datetime('now') + seconds(avg_t * remaining);
                    [~, gpu_str] = system('nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>nul');
                    gpu_util = str2double(strtrim(gpu_str));
                    if isnan(gpu_util), gpu_util = -1; end
                    fprintf('  ei=%d / %d | avg %.2fs | total est %.1fh | GPU %d%% | ETA %s\n', ...
                        ei, n_ei, avg_t, total_est/3600, gpu_util, ...
                        datestr(eta, 'dd-mmm-yyyy HH:MM:SS'));
                else
                    fprintf('  ei=%d / %d\n', ei, n_ei);
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
                 bf_fgcf_fast_execute_gpu(rf_0angle_cut_interp, bf_params, fs, ul, ua);

            % Store
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

            % Incremental checkpoint — save only the new CHECKPOINT_INTERVAL slices
            if mod(ei, CHECKPOINT_INTERVAL) == 0
                r  = (ei - CHECKPOINT_INTERVAL + 1):ei;
                cp = struct('xi', xi, 'ei', ei, 'downsample', downsample, 'dc', dc);
                for v = VAR_NAMES
                    cp.([v{1} '_ck']) = eval([v{1} '(:,:,r)']);
                end
                tmp_file = fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei%04d.tmp', xi, ei));
                cp_file  = fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei%04d.mat', xi, ei));
                save(tmp_file, '-struct', 'cp', '-v7.3');
                movefile(tmp_file, cp_file);   % atomic rename — no half-written files
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

        % Clean up checkpoint files for completed xi
        old_cps = dir(fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei*.mat', xi)));
        for f = old_cps'
            delete(fullfile(CHECKPOINT_BASE, f.name));
        end
        fprintf('Cleaned up %d checkpoint files for xi=%d\n', numel(old_cps), xi);

        last_ei = 0;  % Reset for next xi
    end
end

fprintf('\n=== All processing complete ===\n');
