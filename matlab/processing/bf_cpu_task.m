function res = bf_cpu_task(rf_cut, bf_const, fs, ul, ua, depth)
% Worker task: lateral interp + CPU v2 beamform.
%
% bf_const: on warmup/init call, pass the parallel.pool.Constant — the
%           value is unpacked once and stored in a persistent variable.
%           On all subsequent production calls, pass [] to skip unpacking
%           and use the cached copy instead (avoids repeated .Value locks).
%
% This pattern eliminates per-call deserialization of the ~500 MB bf_params
% struct, allowing 4 workers to run bf_fgcf_fast_execute_v2 in true
% parallel without competing on the Constant's internal read lock.

    persistent cached_bp;

    if ~isempty(bf_const)
        % First / init call: unpack Constant and cache locally
        cached_bp = bf_const.Value;
    end

    if isempty(cached_bp)
        error('bf_cpu_task: cached_bp not initialised — call with bf_const first.');
    end

    [xo,  yo ] = meshgrid(1:size(rf_cut,2), 1:depth);
    [xii, yii] = meshgrid(1:0.5:size(rf_cut,2)+0.5, 1:depth);
    din = interp2(xo, yo, double(rf_cut), xii, yii);

    res = cell(1, 13);
    [res{:}] = bf_fgcf_fast_execute_v2(din, cached_bp, fs, ul, ua);
    res = cellfun(@single, res, 'UniformOutput', false);
end
