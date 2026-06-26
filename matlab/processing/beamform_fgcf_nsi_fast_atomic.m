% Atomic checkpoint beamform script with resumability
% Saves every N ei iterations (configurable). On crash, resume from last checkpoint.

%% Configuration

CHECKPOINT_INTERVAL = 10;  % Save checkpoint every N ei iterations

%% Setup & Resume

clearvars
addpath('E:\dbz\chip_scan\');
load E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat

checkpoint_base = 'E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026\checkpoints';
if ~exist(checkpoint_base, 'dir')
    mkdir(checkpoint_base);
end

checkpoint_subdir = fullfile(checkpoint_base, datestr(now, 'yyyy-mm-dd_HH-MM-SS'));
mkdir(checkpoint_subdir);
fprintf('Checkpoint directory: %s\n', checkpoint_subdir);

xloc = 0:6.9:41.4;
last_xi = 2;  % Start from xi=3 (loop begins at 3)
last_ei = 0;

% Scan for existing checkpoints in this run
checkpoint_files = dir(fullfile(checkpoint_subdir, 'checkpoint_xi*.mat'));
if ~isempty(checkpoint_files)
    for f = checkpoint_files'
        parts = sscanf(f.name, 'checkpoint_xi%d_ei%d.mat');
        if parts(1) > last_xi || (parts(1) == last_xi && parts(2) > last_ei)
            last_xi = parts(1);
            last_ei = parts(2);
        end
    end

    % Pre-load latest checkpoint
    checkpoint_file = fullfile(checkpoint_subdir, sprintf('checkpoint_xi%d_ei%d.mat', last_xi, last_ei));
    fprintf('Loading checkpoint: xi=%d, ei=%d\n', last_xi, last_ei);
    load(checkpoint_file);
    fprintf('Resuming from xi=%d, ei=%d\n', last_xi, last_ei);
else
    % First run: initialize output arrays
    ps_data_ds = zeros(1024, 128, 1200, 'single');
    zmlbf_ds = zeros(1024, 128, 1200, 'single');
    dcrbf_ds = zeros(1024, 128, 1200, 'single');
    dclbf_ds = zeros(1024, 128, 1200, 'single');
    zmlbf01_ds = zeros(1024, 128, 1200, 'single');
    dcrbf01_ds = zeros(1024, 128, 1200, 'single');
    dclbf01_ds = zeros(1024, 128, 1200, 'single');
    fcf_ds = zeros(1024, 128, 1200, 'single');
    cf_ds = zeros(1024, 128, 1200, 'single');
    gcf_ds = zeros(1024, 128, 1200, 'single');
    fgcf_ds = zeros(1024, 128, 1200, 'single');
    fcf_weight_ds = zeros(1024, 128, 1200, 'single');
    fgcf_weight_ds = zeros(1024, 128, 1200, 'single');

    fprintf('Starting fresh run from xi=3, ei=1\n');
end

%% Main processing loop

frame_length = Receive.endSample;
f0 = 29.411764705882350e6;
fs = 117.6470588235294e6;
f_clock = 500e6;

angles = 0;
for ai = 1:1

    angle = angles(ai);
    dc = 1;
    fNum = 3;
    trans_pitch = Trans.spacingMm*1e-3;

    depth = 2048;
    ele = 128;
    angle_val = 0;
    ul = 1;
    ua = 1;

    bf_params = precompute_bf_geometry_hann(depth, ele*2, trans_pitch/2, fs, angle_val, dc, fNum, ul, ua);

    for xi = last_xi:7

        fprintf('\n=== Processing xi=%d (xloc=%.1f) ===\n', xi, xloc(xi));
        tic

        filename_read = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026' ...
            '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm15-May-2026.txt'];

        filename_size = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026' ...
            '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm15-May-2026_size.mat'];

        load(filename_size);
        RF_Dim = rf_size;

        fid = fopen(filename_read,'r');
        RF_tmp = int16(fread(fid,'double'));
        RFdata = reshape(RF_tmp, RF_Dim);
        fclose(fid);

        toc

        % Inner loop over elements
        for ei = (last_ei + 1):1200

            % Print progress
            if mod(ei, 100) == 0
                fprintf('  ei=%d / 1200\n', ei);
            end

            rf_0angle = double(RFdata(3*(ai-1)*frame_length+1:3*(ai-1)*frame_length+frame_length,:,ei));
            rf_0angle_cut = rf_0angle(1:depth, :);

            [xo,yo] = meshgrid(1:128, 1:depth);
            [xii,yii] = meshgrid(1:0.5:128.5, 1:depth);
            rf_0angle_cut_interp = interp2(xo, yo, rf_0angle_cut, xii, yii);

            % Beamform
            [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, ...
                 cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, ...
                 spectral_cf_weight, spectral_gcf_weight, dclbf01, dcrbf01, zmlbf01] = ...
                 bf_fgcf_fast_execute(rf_0angle_cut_interp, bf_params, fs, ul, ua);

            % Downsample and store
            st_fm = 0;
            downsample = 1;

            if downsample == 1
                ps_data_ds(:,:,ei) = single(ps_data(1:ua:end,:));
                zmlbf_ds(:,:,ei) = single(zmlbf(1:ua:end,:));
                dcrbf_ds(:,:,ei) = single(dcrbf(1:ua:end,:));
                dclbf_ds(:,:,ei) = single(dclbf(1:ua:end,:));
                zmlbf01_ds(:,:,ei) = single(zmlbf01(1:ua:end,:));
                dcrbf01_ds(:,:,ei) = single(dcrbf01(1:ua:end,:));
                dclbf01_ds(:,:,ei) = single(dclbf01(1:ua:end,:));
                fcf_ds(:,:,ei) = single(spectral_cf_weighted_data(1:ua:end,:));
                cf_ds(:,:,ei) = single(cf_weighted_data(1:ua:end,:));
                gcf_ds(:,:,ei) = single(gcf_weighted_data(1:ua:end,:));
                fgcf_ds(:,:,ei) = single(spectral_gcf_weighted_data(1:ua:end,:));
                fcf_weight_ds(:,:,ei) = single(spectral_cf_weight(1:ua:end,:));
                fgcf_weight_ds(:,:,ei) = single(spectral_gcf_weight(1:ua:end,:));
            end

            % Save checkpoint every N iterations
            if mod(ei, CHECKPOINT_INTERVAL) == 0
                checkpoint_file = fullfile(checkpoint_subdir, sprintf('checkpoint_xi%d_ei%d.mat', xi, ei));
                save(checkpoint_file, ...
                    'ps_data_ds', 'zmlbf_ds', 'dcrbf_ds', 'dclbf_ds', ...
                    'fcf_ds', 'cf_ds', 'gcf_ds', 'fgcf_ds', ...
                    'fcf_weight_ds', 'fgcf_weight_ds', ...
                    'zmlbf01_ds', 'dclbf01_ds', 'dcrbf01_ds', ...
                    'downsample', 'dc', 'xi', 'ei', '-v7.3');
                fprintf('    Checkpoint saved: xi=%d, ei=%d\n', xi, ei);
            end
        end

        % Save final .mat for this xi position
        save_name = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform'...
            '\RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x',num2str(xloc(xi)),'mm_angle',num2str(ai),'_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat'];

        save(save_name, "ps_data_ds", "zmlbf_ds", "dcrbf_ds", "dclbf_ds", ...
            'fcf_ds', 'cf_ds', 'gcf_ds', "fgcf_ds", 'downsample', 'dc', ...
            "fcf_weight_ds", "fgcf_weight_ds", 'zmlbf01_ds', 'dclbf01_ds', 'dcrbf01_ds');

        fprintf('Final save: %s\n', save_name);

        % Reset last_ei for next xi
        last_ei = 0;
    end
end

fprintf('\n=== All processing complete ===\n');
