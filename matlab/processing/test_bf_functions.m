% test_bf_functions.m
% Compare bf_fgcf_fast_execute (ref), bf_fgcf_fast_execute_v2 (CPU),
% and bf_fgcf_fast_execute_gpu (GPU) for speed and data integrity.
%
% Tests ei = [1, 601, 1200] from xi=3 of the standard dataset.
% Integrity is checked by relative error vs the double-precision reference,
% comparing single(ref) vs single(test) to avoid penalising precision loss.

clearvars

%% ── Config ────────────────────────────────────────────────────────────────

WORKSPACE_FILE = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat';
DATA_DIR       = 'E:\issac\chip_scan\chip_4inch_0angle_txt_save15-May-2026';

depth = 2048;  ele = 128;  ua = 1;  ul = 1;
fs  = 117.6470588235294e6;
ai  = 1;   xi = 3;   xloc = 0:6.9:41.4;
angle_val = 0;  fNum = 3;  dc = 1;

EI_LIST = [1, 601, 1200];
N_EI    = numel(EI_LIST);

OUT_NAMES = {'ps_data','dclbf','dcrbf','zmlbf', ...
             'spectral_cf_weighted_data','cf_weighted_data', ...
             'gcf_weighted_data','spectral_gcf_weighted_data', ...
             'spectral_cf_data','spectral_gcf_data', ...
             'dclbf01','dcrbf01','zmlbf01'};
N_OUT = numel(OUT_NAMES);

TH_PASS = 1e-4;   % rel ≤ this → PASS
TH_FAIL = 1e-2;   % rel > this → FAIL  (between = WARN)

fprintf('=== bf_fgcf benchmark & integrity test ===\n\n');

%% ── Setup ─────────────────────────────────────────────────────────────────

addpath(fileparts(mfilename('fullpath')));

assert(exist('precompute_bf_geometry_hann','file') == 2, ...
    'precompute_bf_geometry_hann not on path. Add its directory with addpath().');

load(WORKSPACE_FILE);
frame_length = Receive.endSample;
trans_pitch  = Trans.spacingMm * 1e-3;

bf_params = precompute_bf_geometry_hann(depth, ele*2, trans_pitch/2, fs, ...
                                        angle_val, dc, fNum, ul, ua);

%% ── Load RF data (xi=3) ──────────────────────────────────────────────────

xstr       = num2str(xloc(xi));
fname_data = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x', xstr, 'mm15-May-2026.txt']);
fname_size = fullfile(DATA_DIR, ['RFbatch_5angle_PI_single_step0.05mm_x', xstr, 'mm15-May-2026_size.mat']);

assert(exist(fname_data,'file')==2, 'RF data file not found: %s', fname_data);
assert(exist(fname_size,'file')==2, 'RF size file not found: %s', fname_size);

load(fname_size);  RF_Dim = rf_size;

fprintf('Loading RF data... ');  tLoad = tic;
fid    = fopen(fname_data, 'r');
RF_tmp = fread(fid, 'double');
fclose(fid);
RFdata = reshape(RF_tmp, RF_Dim);
fprintf('done (%.1f s)\n', toc(tLoad));

assert(size(RFdata,3) >= max(EI_LIST), ...
    'RFdata has only %d frames but test needs ei=%d', size(RFdata,3), max(EI_LIST));

%% ── Pre-compute per-ei interpolated inputs ────────────────────────────────

[xo,  yo ] = meshgrid(1:128,       1:depth);
[xii, yii] = meshgrid(1:0.5:128.5, 1:depth);

inputs = cell(1, N_EI);
for k = 1:N_EI
    ei   = EI_LIST(k);
    row0 = 3*(ai-1)*frame_length + 1;
    row1 = 3*(ai-1)*frame_length + frame_length;
    rf   = RFdata(row0:row1, :, ei);
    inputs{k} = rf(1:depth, :);
    inputs{k} = interp2(xo, yo, inputs{k}, xii, yii);
end
fprintf('Per-ei inputs ready for ei = %s\n\n', mat2str(EI_LIST));

%% ── Reference runs (double CPU, ground truth) ─────────────────────────────

fprintf('--- Reference (bf_fgcf_fast_execute, double CPU) ---\n');
call_bf(@bf_fgcf_fast_execute, inputs{1}, bf_params, fs, ul, ua);  % JIT warmup

t_ref   = zeros(1, N_EI);
ref_out = cell(1, N_EI);
for k = 1:N_EI
    t = tic;
    ref_out{k} = call_bf(@bf_fgcf_fast_execute, inputs{k}, bf_params, fs, ul, ua);
    t_ref(k)   = toc(t);
    fprintf('  ei=%4d  %.2f s\n', EI_LIST(k), t_ref(k));
end

%% ── V2 runs (single CPU vectorised) ──────────────────────────────────────

fprintf('\n--- V2 (bf_fgcf_fast_execute_v2, single CPU) ---\n');
call_bf(@bf_fgcf_fast_execute_v2, inputs{1}, bf_params, fs, ul, ua);  % warmup

t_v2   = zeros(1, N_EI);
v2_out = cell(1, N_EI);
for k = 1:N_EI
    t = tic;
    v2_out{k} = call_bf(@bf_fgcf_fast_execute_v2, inputs{k}, bf_params, fs, ul, ua);
    t_v2(k)   = toc(t);
    fprintf('  ei=%4d  %.2f s\n', EI_LIST(k), t_v2(k));
end

%% ── GPU runs (first call COLD, subsequent WARM) ───────────────────────────

gpu_out = cell(1, N_EI);
t_gpu   = nan(1, N_EI);
gpu_ran = false;

if gpuDeviceCount() > 0
    fprintf('\n--- GPU (bf_fgcf_fast_execute_gpu) ---\n');
    g = gpuDevice();
    fprintf('  Device: %s | %.1f GB VRAM\n', g.Name, g.TotalMemory/1e9);

    clear bf_fgcf_fast_execute_gpu   % flush persistent GPU cache

    for k = 1:N_EI
        label = 'warm';
        if k == 1, label = 'COLD'; end
        try
            wait(gpuDevice());
            t = tic;
            gpu_out{k} = call_bf(@bf_fgcf_fast_execute_gpu, inputs{k}, bf_params, fs, ul, ua);
            wait(gpuDevice());
            t_gpu(k) = toc(t);
            fprintf('  ei=%4d  %.2f s  [%s]\n', EI_LIST(k), t_gpu(k), label);
        catch ME
            fprintf('  ei=%4d  ERROR: %s\n', EI_LIST(k), ME.message);
        end
    end
    gpu_ran = true;
else
    fprintf('\n--- GPU: no GPU device found, skipping ---\n');
end

%% ── Timing summary ────────────────────────────────────────────────────────

fprintf('\n%s\n', repmat('=',1,72));
fprintf('TIMING TABLE (seconds)\n');
fprintf('%s\n', repmat('-',1,72));
fprintf('%-6s  %10s  %10s  %12s  %12s\n', ...
    'ei', 'ref(dbl)', 'v2(sgl)', 'gpu', 'speedup_gpu');
fprintf('%s\n', repmat('-',1,72));
for k = 1:N_EI
    if gpu_ran && ~isnan(t_gpu(k))
        gpu_str = sprintf('%.2f', t_gpu(k));
        spd_str = sprintf('%.1fx', t_ref(k) / t_gpu(k));
    else
        gpu_str = 'N/A';  spd_str = 'N/A';
    end
    note = '';
    if k == 1 && gpu_ran, note = ' *cold'; end
    fprintf('%-6d  %10.2f  %10.2f  %12s  %12s%s\n', ...
        EI_LIST(k), t_ref(k), t_v2(k), gpu_str, spd_str, note);
end
fprintf('%s\n', repmat('-',1,72));
fprintf('%-6s  %10.2f  %10.2f', 'mean', mean(t_ref), mean(t_v2));
if gpu_ran && any(~isnan(t_gpu))
    warm = t_gpu(2:end);  warm = warm(~isnan(warm));
    fprintf('  %12.2f  %12.1fx', mean(t_gpu(~isnan(t_gpu))), mean(t_ref)/mean(warm));
end
fprintf('\n');
fprintf('%s\n', repmat('=',1,72));
fprintf('Speedup v2  vs ref: %.1fx\n', mean(t_ref)/mean(t_v2));
if gpu_ran && ~isempty(warm)
    fprintf('Speedup gpu vs ref: %.1fx  (warm mean)\n', mean(t_ref)/mean(warm));
end

%% ── Integrity comparison ──────────────────────────────────────────────────

fprintf('\n%s\n', repmat('=',1,72));
fprintf('INTEGRITY vs REFERENCE  (single-precision comparison)\n');
fprintf('  PASS: rel ≤ %.0e  |  WARN: ≤ %.0e  |  FAIL: > %.0e\n', ...
    TH_PASS, TH_FAIL, TH_FAIL);
fprintf('%s\n', repmat('=',1,72));

% V2
v2_abs = zeros(N_OUT, N_EI);
v2_rel = zeros(N_OUT, N_EI);
v2_sta = repmat("PASS", N_OUT, N_EI);
for k = 1:N_EI
    [v2_abs(:,k), v2_rel(:,k), v2_sta(:,k)] = ...
        cmp_outputs(ref_out{k}, v2_out{k}, N_OUT, TH_PASS, TH_FAIL);
end
print_table('V2 (single CPU vectorised)', OUT_NAMES, v2_abs, v2_rel, v2_sta);

% GPU
if gpu_ran && ~isempty(gpu_out{1})
    gpu_abs = zeros(N_OUT, N_EI);
    gpu_rel = zeros(N_OUT, N_EI);
    gpu_sta = repmat("PASS", N_OUT, N_EI);
    for k = 1:N_EI
        if ~isempty(gpu_out{k})
            [gpu_abs(:,k), gpu_rel(:,k), gpu_sta(:,k)] = ...
                cmp_outputs(ref_out{k}, gpu_out{k}, N_OUT, TH_PASS, TH_FAIL);
        else
            gpu_sta(:,k) = "SKIP";
        end
    end
    print_table('GPU (bf_fgcf_fast_execute_gpu)', OUT_NAMES, gpu_abs, gpu_rel, gpu_sta);
else
    fprintf('\nGPU: skipped\n');
end

%% ── Expose last-ei outputs to workspace ───────────────────────────────────

[ps_data__ref,  dclbf__ref,  dcrbf__ref,  zmlbf__ref, ...
 spectral_cf_weighted__ref,  cf_weighted__ref, ...
 gcf_weighted__ref,          spectral_gcf_weighted__ref, ...
 spectral_cf__ref,           spectral_gcf__ref, ...
 dclbf01__ref,               dcrbf01__ref,  zmlbf01__ref] = deal(ref_out{end}{:});

[ps_data__v2,   dclbf__v2,   dcrbf__v2,   zmlbf__v2, ...
 spectral_cf_weighted__v2,   cf_weighted__v2, ...
 gcf_weighted__v2,           spectral_gcf_weighted__v2, ...
 spectral_cf__v2,            spectral_gcf__v2, ...
 dclbf01__v2,                dcrbf01__v2,   zmlbf01__v2] = deal(v2_out{end}{:});

if gpu_ran && ~isempty(gpu_out{end})
    [ps_data__gpu,  dclbf__gpu,  dcrbf__gpu,  zmlbf__gpu, ...
     spectral_cf_weighted__gpu,  cf_weighted__gpu, ...
     gcf_weighted__gpu,          spectral_gcf_weighted__gpu, ...
     spectral_cf__gpu,           spectral_gcf__gpu, ...
     dclbf01__gpu,               dcrbf01__gpu,  zmlbf01__gpu] = deal(gpu_out{end}{:});
end

fprintf('\nLast-ei (ei=%d) outputs available as ps_data__ref, ps_data__v2, ps_data__gpu, etc.\n', ...
    EI_LIST(end));
fprintf('Done.\n');

%% ════════════════════════════════════════════════════════════════════════════
%  Local functions — must be at end of script file
%% ════════════════════════════════════════════════════════════════════════════

function outs = call_bf(fn, data, params, fs, ul, ua)
    outs = cell(1,13);
    [outs{1},outs{2},outs{3},outs{4},outs{5},outs{6},outs{7}, ...
     outs{8},outs{9},outs{10},outs{11},outs{12},outs{13}] = ...
        fn(data, params, fs, ul, ua);
end

function [max_abs, max_rel, status] = cmp_outputs(ref_k, test_k, N_OUT, TH_PASS, TH_FAIL)
    max_abs = zeros(N_OUT, 1);
    max_rel = zeros(N_OUT, 1);
    status  = repmat("PASS", N_OUT, 1);
    for j = 1:N_OUT
        r = single(ref_k{j});
        x = single(test_k{j});
        if ~isequal(size(r), size(x))
            status(j) = "FAIL(size)";
            max_abs(j) = Inf;  max_rel(j) = Inf;
            continue
        end
        ab  = max(abs(r(:) - x(:)));
        den = max(max(abs(r(:))), eps('single'));
        re  = ab / den;
        max_abs(j) = ab;
        max_rel(j) = re;
        if     re > TH_FAIL, status(j) = "FAIL";
        elseif re > TH_PASS, status(j) = "WARN";
        end
    end
end

function print_table(title, out_names, t_abs, t_rel, statuses)
    N = numel(out_names);
    fprintf('\n>>> %s\n', title);
    fprintf('%-40s  %10s  %10s  %6s\n', 'Output (worst across ei)', 'MaxAbsErr', 'MaxRelErr', 'Status');
    fprintf('%s\n', repmat('-',1,72));
    overall_pass = true;
    for j = 1:N
        wa = max(t_abs(j,:));
        wr = max(t_rel(j,:));
        ws = "PASS";
        for k = 1:size(statuses,2)
            s = statuses(j,k);
            if s == "FAIL" || s == "FAIL(size)", ws = s; break; end
            if s == "WARN", ws = "WARN"; end
        end
        if ws ~= "PASS", overall_pass = false; end
        flag = '';
        if ws == "FAIL" || ws == "FAIL(size)", flag = '  <<<'; end
        if ws == "WARN",                        flag = '  ^';   end
        fprintf('%-40s  %10.2e  %10.2e  %6s%s\n', out_names{j}, wa, wr, ws, flag);
    end
    fprintf('%s\n', repmat('-',1,72));
    if overall_pass
        fprintf('  OVERALL: PASS\n');
    else
        fprintf('  OVERALL: ISSUES DETECTED\n');
    end
end
