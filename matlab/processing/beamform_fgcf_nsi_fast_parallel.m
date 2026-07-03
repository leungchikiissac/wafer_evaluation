% beamform_fgcf_nsi_fast_parallel.m
% Parallel CPU + GPU beamform with atomic checkpoints.
%
% Architecture (per round of ROUND_SIZE = K_CPU + K_GPU ei):
%   Main thread  : GPU  processes K_GPU ei sequentially (bf_fgcf_fast_execute_gpu)
%   parpool workers: CPU processes K_CPU ei in parallel  (bf_fgcf_fast_execute_v2)
%   Both streams run simultaneously → effective throughput ~0.106 ei/s (~3.1 h/xi)
%
% Scheduling per round:
%   1. Submit K_CPU parfeval futures to worker pool (returns immediately, async)
%   2. Run K_GPU GPU calls on main thread (workers are busy in parallel)
%   3. Harvest CPU results via fetchNext
%   4. Store all results, checkpoint every CHECKPOINT_ROUNDS rounds
%
% Checkpoint format: self-describing ei_list field so arbitrary ei order is safe.
% Resume: scan cp_xi*_ei*.mat, scatter slices by stored ei_list.

clearvars

%% ── Configuration ─────────────────────────────────────────────────────────

N_WORKERS         = 4;     % CPU parallel workers
K_CPU             = 4;     % ei per round on CPU workers  (≈ 119s / 4 workers in parallel)
K_GPU             = 6;     % ei per round on GPU main     (≈ 126s for 6 ei)
ROUND_SIZE        = K_CPU + K_GPU;   % 7 ei per round
CHECKPOINT_ROUNDS = 2;     % flush checkpoint every N rounds (= 14 ei)

WORKSPACE_FILE = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat';
DATA_DIR       = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';
CHECKPOINT_BASE= 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\checkpoints_parallel';
OUTPUT_DIR     = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform';

depth = 2048;  ele = 128;  ua = 1;  ul = 1;
fs   = 117.6470588235294e6;
f0   = 29.411764705882350e6;
fNum = 3;  dc = 1;  downsample = 1;
angle_val = 0;  ai = 1;
n_ei  = 1200;
xloc  = 0:6.9:41.4;

VAR_NAMES = {'ps_data_ds','zmlbf_ds','dcrbf_ds','dclbf_ds', ...
             'fcf_ds','cf_ds','gcf_ds','fgcf_ds', ...
             'fcf_weight_ds','fgcf_weight_ds', ...
             'zmlbf01_ds','dclbf01_ds','dcrbf01_ds'};
N_VAR     = numel(VAR_NAMES);
out_depth = floor(depth / ua);
out_lat   = ele * 2;

fprintf('=== Parallel beamform: GPU + %d CPU workers ===\n', N_WORKERS);
fprintf('    Round: K_GPU=%d + K_CPU=%d = %d ei | checkpoint every %d rounds (%d ei)\n\n', ...
    K_GPU, K_CPU, ROUND_SIZE, CHECKPOINT_ROUNDS, CHECKPOINT_ROUNDS*ROUND_SIZE);

%% ── Parallel pool ─────────────────────────────────────────────────────────

pool = gcp('nocreate');
if isempty(pool)
    fprintf('Opening parpool(%d)...\n', N_WORKERS);
    pool = parpool('local', N_WORKERS);
elseif pool.NumWorkers ~= N_WORKERS
    fprintf('Restarting parpool (%d→%d workers)...\n', pool.NumWorkers, N_WORKERS);
    delete(pool);
    pool = parpool('local', N_WORKERS);
else
    fprintf('Reusing parpool (%d workers)\n', pool.NumWorkers);
end

% Ensure v2 and bf_cpu_task are visible on each worker; set thread count.
% Workers default to 1 computational thread — set to floor(n_cores/N_WORKERS).
script_dir = fileparts(mfilename('fullpath'));
n_cores    = feature('numCores');
n_threads_per_worker = max(1, floor(n_cores / N_WORKERS));
spmd
    addpath(script_dir);
    maxNumCompThreads(n_threads_per_worker);
end
fprintf('Workers configured: %d physical cores / %d workers = %d threads/worker\n', ...
    n_cores, N_WORKERS, n_threads_per_worker);

% Quick parallel efficiency test — 4 workers × 5 s pause.
% Ideal: ~5 s wall. Serial: ~20 s wall.
fprintf('Parallel test (%d workers × 5 s pause)... ', N_WORKERS);
t_pt = tic;
f_pt = parallel.FevalFuture.empty;
for k = 1:N_WORKERS
    f_pt(k) = parfeval(pool, @pause, 0, 5);
end
for k = 1:N_WORKERS
    fetchOutputs(f_pt(k));
end
t_pt_wall = toc(t_pt);
fprintf('%.1f s (%.0f%% parallel efficiency)\n\n', t_pt_wall, 100*5/t_pt_wall);

%% ── Workspace + bf_params ─────────────────────────────────────────────────

load(WORKSPACE_FILE);
frame_length = Receive.endSample;
trans_pitch  = Trans.spacingMm * 1e-3;

bf_params = precompute_bf_geometry_hann(depth, ele*2, trans_pitch/2, fs, ...
                                        angle_val, dc, fNum, ul, ua);

% Broadcast bf_params to all workers once (~300 MB serialized, one-time cost)
fprintf('Broadcasting bf_params to workers... ');
bf_const = parallel.pool.Constant(bf_params);
fprintf('done\n\n');

%% ── Preallocate output arrays ─────────────────────────────────────────────

for v = VAR_NAMES
    eval([v{1} ' = zeros(out_depth, out_lat, n_ei, ''single'');']);
end
if ~exist(CHECKPOINT_BASE, 'dir'), mkdir(CHECKPOINT_BASE); end

% Interp grids used on main thread (GPU path); workers rebuild their own
[xo,  yo ] = meshgrid(1:128,       1:depth);
[xii, yii] = meshgrid(1:0.5:128.5, 1:depth);

%% ── Resume: scan checkpoints, reconstruct state ───────────────────────────

last_xi = 3;
last_ei = 0;

cp_files = dir(fullfile(CHECKPOINT_BASE, 'cp_xi*_ei*.mat'));
if ~isempty(cp_files)
    xi_nums = arrayfun(@(f) sscanf(f.name,'cp_xi%d_ei%d.mat'), cp_files, 'UniformOutput',false);
    xi_vals = cellfun(@(x) x(1), xi_nums);
    last_xi = max(xi_vals);

    xi_files = cp_files(xi_vals == last_xi);
    fprintf('Resuming xi=%d — loading %d checkpoint files...\n', last_xi, numel(xi_files));
    done_ei = false(1, n_ei);
    for k = 1:numel(xi_files)
        S  = load(fullfile(CHECKPOINT_BASE, xi_files(k).name));
        if isfield(S, 'ei_list')
            eil = S.ei_list;
        else   % backward-compatible with atomic script checkpoints
            nums = sscanf(xi_files(k).name,'cp_xi%d_ei%d.mat');
            nck  = size(S.([VAR_NAMES{1} '_ck']), 3);
            eil  = (nums(2) - nck + 1) : nums(2);
        end
        for vi = 1:N_VAR
            vn = VAR_NAMES{vi};
            eval([vn '(:,:,eil) = S.' vn '_ck;']);
        end
        done_ei(eil) = true;
    end
    first_todo = find(~done_ei, 1, 'first');
    if isempty(first_todo)
        last_ei = n_ei;
    else
        last_ei = first_todo - 1;
    end
    fprintf('  Contiguous ei done: 1..%d\n', last_ei);
else
    fprintf('Starting fresh from xi=%d\n', last_xi);
end

%% ── GPU warmup (build persistent cache before timing) ─────────────────────

fprintf('\nGPU warmup (building ~4.3 GB persistent cache)...\n');
bf_fgcf_fast_execute_gpu(zeros(depth, out_lat, 'single'), bf_params, fs, ul, ua);
fprintf('GPU ready.\n');

%% ── Worker warmup (JIT-compile v2 + cache bf_params persistently) ────────
% Worker warmup: JIT-compile v2 AND cache bf_params in each worker's
% persistent variable (bf_cpu_task.m stores cached_bp on first call with
% bf_const, skips deserialization on all subsequent calls with []).
fprintf('Worker warmup (JIT + persistent cache of bf_params on all %d workers)...\n', N_WORKERS);
t_wu = tic;
dummy_rf = zeros(depth, 128, 'double');
wf = parallel.FevalFuture.empty;
for k = 1:N_WORKERS
    % Pass bf_const so each worker unpacks .Value and caches it persistently
    wf(k) = parfeval(pool, @bf_cpu_task, 1, dummy_rf, bf_const, fs, ul, ua, depth);
end
for k = 1:N_WORKERS
    fetchOutputs(wf(k));
end
clear wf
t_wu_wall = toc(t_wu);
% If workers ran in parallel: wall ≈ 1 v2 call. Serial: wall ≈ N × call.
fprintf('Workers ready (%.1f s wall | %.1f s per worker if serial)\n\n', ...
    t_wu_wall, t_wu_wall / N_WORKERS);

%% ── Main xi loop ──────────────────────────────────────────────────────────

for xi = last_xi:7

    fprintf('\n=== Processing xi=%d (xloc=%.1f mm) ===\n', xi, xloc(xi));
    tic

    xstr       = num2str(xloc(xi));
    fname_data = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x',xstr,'mm15-May-2026.txt']);
    fname_size = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x',xstr,'mm15-May-2026_size.mat']);
    load(fname_size); RF_Dim = rf_size;
    fid    = fopen(fname_data, 'r'); RF_tmp = fread(fid, 'double'); fclose(fid);
    RFdata = reshape(RF_tmp, RF_Dim);
    fprintf('  Data loaded (%.1f s)\n', toc);

    % Reset output arrays for this xi
    for v = VAR_NAMES, eval([v{1} '(:) = 0;']); end

    row0 = 3*(ai-1)*frame_length + 1;
    row1 = 3*(ai-1)*frame_length + frame_length;

    % ── Round scheduling ────────────────────────────────────────────────────
    round_times  = [];
    pending_ei   = [];     % ei done since last checkpoint flush
    rounds_done  = 0;
    ei_cursor    = last_ei + 1;

    while ei_cursor <= n_ei

        round_end  = min(ei_cursor + ROUND_SIZE - 1, n_ei);
        round_ei   = ei_cursor:round_end;
        n_in_round = numel(round_ei);
        n_cpu_r    = min(K_CPU, n_in_round);
        n_gpu_r    = n_in_round - n_cpu_r;
        ei_cpu     = round_ei(1 : n_cpu_r);
        ei_gpu     = round_ei(n_cpu_r+1 : end);

        t_round = tic;

        % Step 1: Submit CPU jobs asynchronously (workers start immediately).
        % Pass [] for bf_const — workers use the persistent cached_bp from warmup.
        F = parallel.FevalFuture.empty;
        for k = 1:n_cpu_r
            rf_cut = RFdata(row0:row1, :, ei_cpu(k));
            F(k)   = parfeval(pool, @bf_cpu_task, 1, ...
                              rf_cut(1:depth,:), [], fs, ul, ua, depth);
        end

        % Step 2: GPU jobs on main thread (overlap with workers running above)
        for g = 1:n_gpu_r
            ei  = ei_gpu(g);
            rf_cut = RFdata(row0:row1, :, ei);
            din    = interp2(xo, yo, rf_cut(1:depth,:), xii, yii);
            [o1,o2,o3,o4,o5,o6,o7,o8,o9,o10,o11,o12,o13] = ...
                bf_fgcf_fast_execute_gpu(din, bf_params, fs, ul, ua);
            ps_data_ds(:,:,ei)     = single(o1);
            dclbf_ds(:,:,ei)       = single(o2);
            dcrbf_ds(:,:,ei)       = single(o3);
            zmlbf_ds(:,:,ei)       = single(o4);
            fcf_ds(:,:,ei)         = single(o5);
            cf_ds(:,:,ei)          = single(o6);
            gcf_ds(:,:,ei)         = single(o7);
            fgcf_ds(:,:,ei)        = single(o8);
            fcf_weight_ds(:,:,ei)  = single(o9);
            fgcf_weight_ds(:,:,ei) = single(o10);
            dclbf01_ds(:,:,ei)     = single(o11);
            dcrbf01_ds(:,:,ei)     = single(o12);
            zmlbf01_ds(:,:,ei)     = single(o13);
        end

        % Step 3: Harvest CPU results (process-as-done, workers likely finished)
        for k = 1:n_cpu_r
            try
                [idx, res] = fetchNext(F);   % idx = which future completed
            catch ME
                cancel(F);   % abort remaining if one errored
                rethrow(ME);
            end
            ei = ei_cpu(idx);
            ps_data_ds(:,:,ei)     = res{1};
            dclbf_ds(:,:,ei)       = res{2};
            dcrbf_ds(:,:,ei)       = res{3};
            zmlbf_ds(:,:,ei)       = res{4};
            fcf_ds(:,:,ei)         = res{5};
            cf_ds(:,:,ei)          = res{6};
            gcf_ds(:,:,ei)         = res{7};
            fgcf_ds(:,:,ei)        = res{8};
            fcf_weight_ds(:,:,ei)  = res{9};
            fgcf_weight_ds(:,:,ei) = res{10};
            dclbf01_ds(:,:,ei)     = res{11};
            dcrbf01_ds(:,:,ei)     = res{12};
            zmlbf01_ds(:,:,ei)     = res{13};
        end

        t_elapsed   = toc(t_round);
        round_times(end+1) = t_elapsed;            %#ok<AGROW>
        rounds_done = rounds_done + 1;
        pending_ei  = [pending_ei, round_ei];      %#ok<AGROW>
        ei_cursor   = round_end + 1;

        % Progress report
        recent      = round_times(max(1,end-4):end);
        ei_per_s    = ROUND_SIZE / mean(recent);
        ei_remaining= n_ei - round_end;
        eta         = datetime('now') + seconds(ei_remaining / ei_per_s);
        [~, gs]     = system('nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>nul');
        gpu_util    = str2double(strtrim(gs)); if isnan(gpu_util), gpu_util = -1; end
        fprintf('  ei=%d-%d | %.1fs/round | %.2f ei/s | GPU %d%% | ETA %s\n', ...
            round_ei(1), round_end, t_elapsed, ei_per_s, gpu_util, ...
            datestr(eta, 'dd-mmm-yyyy HH:MM:SS'));

        % Checkpoint every CHECKPOINT_ROUNDS rounds (or at end of xi)
        if mod(rounds_done, CHECKPOINT_ROUNDS) == 0 || ei_cursor > n_ei
            eil     = pending_ei;
            cp      = struct('xi',xi,'ei_list',eil,'downsample',downsample,'dc',dc);
            for v = VAR_NAMES
                cp.([v{1} '_ck']) = eval([v{1} '(:,:,eil)']);
            end
            tmp_f = fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei%04d.tmp', xi, max(eil)));
            cp_f  = fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei%04d.mat', xi, max(eil)));
            save(tmp_f, '-struct', 'cp', '-v7.3');
            movefile(tmp_f, cp_f);
            fprintf('    Checkpoint: xi=%d ei=%d..%d\n', xi, min(eil), max(eil));
            pending_ei = [];
        end
    end

    % ── Final save for this xi ───────────────────────────────────────────────
    save_name = fullfile(OUTPUT_DIR, ...
        ['RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x', xstr, ...
         'mm_angle', num2str(ai), '_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat']);
    save(save_name, 'ps_data_ds','zmlbf_ds','dcrbf_ds','dclbf_ds', ...
        'fcf_ds','cf_ds','gcf_ds','fgcf_ds','downsample','dc', ...
        'fcf_weight_ds','fgcf_weight_ds','zmlbf01_ds','dclbf01_ds','dcrbf01_ds');
    fprintf('Final save: %s\n', save_name);

    % Clean up checkpoint files for this xi
    old_cps = dir(fullfile(CHECKPOINT_BASE, sprintf('cp_xi%d_ei*.mat', xi)));
    for f = old_cps', delete(fullfile(CHECKPOINT_BASE, f.name)); end
    fprintf('Cleaned %d checkpoint files for xi=%d\n', numel(old_cps), xi);

    last_ei = 0;   % reset for next xi
end

fprintf('\n=== All processing complete ===\n');

% bf_cpu_task is in bf_cpu_task.m (same directory, on workers' path via addpath).
% It uses a persistent cached_bp populated during warmup so production calls
% never touch parallel.pool.Constant.Value (which serialises concurrent workers).
