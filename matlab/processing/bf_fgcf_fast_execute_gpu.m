function [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, spectral_cf_data, spectral_gcf_data, dclbf01, dcrbf01, zmlbf01] = bf_fgcf_fast_execute_gpu(data, params, fs, ul, ua)
    % GPU-accelerated beamform / coherence-factor executor.
    % Drop-in replacement for bf_fgcf_fast_execute[_v2] — identical signature and
    % outputs. Algorithm is identical to V2; all heavy math runs on the GPU.
    %
    % Design notes
    %   - params is BUILT ONCE by the caller and reused for all 1200 calls per
    %     dataset (see beamform_fgcf_nsi_fast_atomic.m). Its large arrays
    %     (delay_indices, b_apod, apod, apod01) are therefore transferred to the
    %     GPU ONCE and held in a PERSISTENT cache. Re-running with a different
    %     geometry auto-rebuilds the cache; use `clear bf_fgcf_fast_execute_gpu`
    %     to force a reset.
    %   - Everything is single precision. The Quadro P6000 (Pascal) has a 1:32
    %     FP64:FP32 ratio, so double-precision GPU math would be ~30x slower.
    %   - Outputs are gathered back to the CPU before returning (same signature).

    persistent G

    Na = params.Na;
    Nl = params.Nl;
    C  = params.ele;                 % num_channels
    total_lines = Nl * ul;
    fs_up = fs * ua;

    win_len  = 64;
    half_len = floor(win_len/2) + 1; % 33

    % ---- Build / validate the persistent GPU cache (transfers happen ONCE) ----
    sig = local_sig(params, Na, Nl, C, ul, win_len);
    if isempty(G) || ~isequal(G.sig, sig)
        G = local_build_cache(params, Na, Nl, C, ul, win_len, half_len, sig);
    end

    % ---- Spectral pass-band indices (cheap, depend on fs_up; host then GPU) ---
    freqs    = (0:win_len-1) * (fs_up / win_len);
    f_low = 25e6; f_high = 40e6;
    idx_pass = find((freqs(1:half_len) >= f_low) & (freqs(1:half_len) <= f_high));
    has_pass = ~isempty(idx_pass);
    idx_pass = gpuArray(idx_pass(:));

    % ---- 1. Interpolation (kept on GPU; exact interp2 'cubic', V2-compatible) -
    data_g = gpuArray(single(data));
    if G.gpu_interp
        dataup = interp2(G.Xi, G.Zi, data_g, G.XQ, G.ZQ, 'cubic');
    else
        % CPU fallback: griddedInterpolant (bit-identical to V2), then upload.
        F = griddedInterpolant({G.zg, G.xg}, double(data), 'cubic', 'none');
        dataup = gpuArray(single(F(params.ZQ, params.XQ)));
    end
    dataup(isnan(dataup)) = 0;

    % ---- Preallocate outputs on the GPU (single) -----------------------------
    z = zeros(Na, total_lines, 'single', 'gpuArray');
    ps_data = z; dclbf = z; dcrbf = z; zmlbf = z;
    dclbf01 = z; dcrbf01 = z; zmlbf01 = z;
    cf_weighted_data = z; gcf_weighted_data = z;
    spectral_cf_data = z; spectral_cf_weighted_data = z;
    spectral_gcf_data = z; spectral_gcf_weighted_data = z;

    e = eps;                          % match V2 (double eps, promotes harmlessly)

    % ---- Main loop over lateral lines (the ai loop is fully vectorized) -------
    for ei = 1:Nl
        b_apod_cur = G.b_apod(:,:,ei);
        a_dcl   = G.apod(:,:,ei,1);   a_dcr   = G.apod(:,:,ei,2);   a_zml   = G.apod(:,:,ei,3);
        a01_dcl = G.apod01(:,:,ei,1); a01_dcr = G.apod01(:,:,ei,2); a01_zml = G.apod01(:,:,ei,3);

        for upsample = 1:ul
            cur_line = (ei-1)*ul + upsample;

            % --- Gather delayed samples via precomputed linear-index map ---
            idx_map = G.delay_indices(:,:,ei,upsample);   % int32 gpuArray
            raw     = dataup(idx_map);                     % [Na x C] gpuArray

            % --- DAS / NSI beamforming (row-sums) ---
            aligned = raw .* b_apod_cur;
            ps_data(:, cur_line) = sum(aligned,        2);
            dclbf(:, cur_line)   = sum(raw .* a_dcl,   2);
            dcrbf(:, cur_line)   = sum(raw .* a_dcr,   2);
            zmlbf(:, cur_line)   = sum(raw .* a_zml,   2);
            dclbf01(:, cur_line) = sum(raw .* a01_dcl, 2);
            dcrbf01(:, cur_line) = sum(raw .* a01_dcr, 2);
            zmlbf01(:, cur_line) = sum(raw .* a01_zml, 2);

            % ============ Vectorized CF & GCF ============
            A        = abs(aligned) > 0;
            Nrow     = sum(single(A), 2);
            valid    = single(Nrow >= 2);
            sum_sig  = sum(aligned, 2);
            sum_sig2 = sum(aligned.^2, 2);

            cf = (sum_sig.^2) ./ (Nrow .* sum_sig2 + e);
            cf_weighted_data(:, cur_line) = (cf .* sum_sig) .* valid;

            Nsafe  = max(Nrow, 1);
            posIdx = cumsum(single(A), 2);
            ph1    = (2*pi) * (posIdx - 1) ./ Nsafe;
            X1     = sum(aligned .* exp(-1j * ph1),     2);
            X2     = sum(aligned .* exp(-1j * 2 * ph1), 2);
            add4   = single(Nrow >= 4);
            add6   = single(Nrow >= 6);
            gnum   = sum_sig.^2 + 2*abs(X1).^2 .* add4 + 2*abs(X2).^2 .* add6;
            gcf    = gnum ./ (Nrow .* sum_sig2 + e);
            gcf_weighted_data(:, cur_line) = (gcf .* sum_sig) .* valid;

            % ============ Batch STFT for spectral FCF & FGCF ============
            W  = reshape(aligned(G.SRlin, :), [win_len, Na, C]);
            W  = W .* G.winValidS;                         % zero-pad (bcast over C)
            Wf = fft(W, win_len, 1);                        % cuFFT batched along dim 1
            spec = Wf(1:half_len, :, :);                    % [half_len x Na x C]

            % --- Spectral FCF ---
            sum_spec   = sum(spec, 3);
            power_spec = sum(abs(spec).^2, 3);
            cf_per_freq = abs(sum_spec).^2 ./ (C * power_spec + e);
            if has_pass
                spectral_cf = mean(cf_per_freq(idx_pass, :), 1).';
            else
                spectral_cf = zeros(Na, 1, 'single', 'gpuArray');
            end
            spectral_cf_data(:, cur_line)          = spectral_cf .* valid;
            spectral_cf_weighted_data(:, cur_line) = (spectral_cf .* sum_sig) .* valid;

            % --- Spectral FGCF (mainlobe via 4-bin matmul, no full spatial FFT) ---
            P_total = C * power_spec;
            Sr   = reshape(spec, [half_len*Na, C]);
            Bk   = Sr * G.Ebins;                            % [half_len*Na x 4]
            pB1  = reshape(abs(Bk(:,1)).^2, [half_len, Na]);
            pB2  = reshape(abs(Bk(:,2)).^2, [half_len, Na]);
            pBm2 = reshape(abs(Bk(:,3)).^2, [half_len, Na]);
            pBm1 = reshape(abs(Bk(:,4)).^2, [half_len, Na]);
            pB0  = abs(sum_spec).^2;

            add2_f = single(Nrow >= 4).';
            add3_f = single(Nrow >= 6).';
            P_main = pB0 + (pB1 + pBm1) .* add2_f + (pB2 + pBm2) .* add3_f;

            gcf_per_freq = P_main ./ (P_total + e);
            if has_pass
                spectral_gcf = mean(gcf_per_freq(idx_pass, :), 1).';
            else
                spectral_gcf = zeros(Na, 1, 'single', 'gpuArray');
            end
            spectral_gcf_data(:, cur_line)          = spectral_gcf .* valid;
            spectral_gcf_weighted_data(:, cur_line) = (spectral_gcf .* sum_sig) .* valid;
        end
    end

    % ---- Gather outputs back to CPU (same signature as V1/V2) ----------------
    ps_data = gather(ps_data);
    dclbf   = gather(dclbf);   dcrbf   = gather(dcrbf);   zmlbf   = gather(zmlbf);
    dclbf01 = gather(dclbf01); dcrbf01 = gather(dcrbf01); zmlbf01 = gather(zmlbf01);
    cf_weighted_data           = gather(cf_weighted_data);
    gcf_weighted_data          = gather(gcf_weighted_data);
    spectral_cf_data           = gather(spectral_cf_data);
    spectral_cf_weighted_data  = gather(spectral_cf_weighted_data);
    spectral_gcf_data          = gather(spectral_gcf_data);
    spectral_gcf_weighted_data = gather(spectral_gcf_weighted_data);
end

% ==========================================================================
function s = local_sig(params, Na, Nl, C, ul, win_len)
    % Cheap signature to detect whether the cached geometry is still valid.
    di = params.delay_indices;
    s = [Na, Nl, C, ul, win_len, numel(di), ...
         double(di(1)), double(di(end)), ...
         double(params.b_apod(1)), double(params.apod(end)), ...
         double(params.apod01(end))];
end

% ==========================================================================
function G = local_build_cache(params, Na, Nl, C, ul, win_len, half_len, sig)
    % One-time transfer of all reusable params to the GPU.
    G.sig = sig;
    G.Na = Na; G.Nl = Nl; G.C = C; G.ul = ul;

    % Large reusable weight tensors (single) and index tensor (int32).
    % Sizes for Na=2048,C=256,Nl=256: delay_indices 537MB (int32),
    % b_apod 537MB, apod 1.6GB, apod01 1.6GB  => ~4.3GB resident.
    G.delay_indices = gpuArray(int32(params.delay_indices));
    G.b_apod = gpuArray(single(params.b_apod));
    G.apod   = gpuArray(single(params.apod));
    G.apod01 = gpuArray(single(params.apod01));

    % Interpolation grids (kept on GPU for the interp2 path).
    G.Xi = gpuArray(single(params.Xi));
    G.Zi = gpuArray(single(params.Zi));
    G.XQ = gpuArray(single(params.XQ));
    G.ZQ = gpuArray(single(params.ZQ));
    G.zg = double(params.Zi(:,1));      % for CPU fallback interpolant
    G.xg = double(params.Xi(1,:));
    G.xg = G.xg(:);

    % Probe once whether interp2 'cubic' is supported on this GPU/release.
    try
        tst = interp2(G.Xi, G.Zi, gpuArray(single(zeros(size(params.Xi)))), ...
                      G.XQ, G.ZQ, 'cubic'); %#ok<NASGU>
        G.gpu_interp = true;
    catch
        G.gpu_interp = false;
    end

    % Batch-STFT source-row index and zero-pad mask (depend only on Na,win_len).
    ai_vec   = 1:Na;
    start_ai = max(1,  ai_vec - floor(win_len/2));
    end_ai   = min(Na, ai_vec + floor(win_len/2) - 1 + mod(win_len,2));
    len_ai   = end_ai - start_ai + 1;
    kcol     = (1:win_len).';
    SR       = start_ai + (kcol - 1);
    winValid = kcol <= len_ai;
    SR(~winValid) = 1;
    G.SRlin     = gpuArray(int32(SR(:)));
    G.winValidS = gpuArray(single(winValid));

    % FGCF spatial DFT basis: 4 non-DC mainlobe bins (+1,+2,-2,-1).
    cc  = single((0:C-1).');
    w0  = 2*pi/C;
    G.Ebins = gpuArray(complex([exp(-1j*w0*1*cc), exp(-1j*w0*2*cc), ...
                                exp(-1j*w0*(C-2)*cc), exp(-1j*w0*(C-1)*cc)]));
end
