function [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, spectral_cf_data, spectral_gcf_data, dclbf01, dcrbf01, zmlbf01] = bf_fgcf_fast_execute_gpu(data, params, fs, ul, ua)
    % GPU-accelerated beamform + coherence factor calculator (batched version).
    % Drop-in replacement for bf_fgcf_fast_execute — identical signature/outputs.
    %
    % Key difference from V1 GPU:
    %   V1: for ei=1:256 loop — 256 kernel-launch bursts, GPU idle between them
    %   V2: 3-phase batch execution — all 256 lines processed in large tensor ops
    %       Phase 1: DAS for ALL Nl lines at once      (no loop)
    %       Phase 2: CF/GCF for ALL Nl lines at once   (no loop)
    %       Phase 3: FCF/FGCF STFT in chunks of STFT_BATCH lines
    %
    % GPU memory budget (Na=2048, C=256, Nl=256):
    %   Cached params:  ~4.3 GB (transferred once, held persistently)
    %   Phase 1-2 peak: ~4 GB  (aligned_all + GCF intermediates)
    %   Phase 3 peak:   ~6 GB  (STFT batch tensors, STFT_BATCH=16)
    %   Total peak:     ~10-12 GB of 24 GB (P6000)
    %
    % To clear GPU cache: clear bf_fgcf_fast_execute_gpu

    persistent G

    Na    = params.Na;
    Nl    = params.Nl;
    C     = params.ele;
    total_lines = Nl * ul;
    fs_up = fs * ua;

    win_len  = 64;
    half_len = floor(win_len/2) + 1;   % 33

    % ---- Build / validate persistent GPU cache (uploaded once) ---------------
    sig = local_sig(params, Na, Nl, C, ul, win_len);
    if isempty(G) || ~isequal(G.sig, sig)
        G = local_build_cache(params, Na, Nl, C, ul, win_len, half_len, sig);
    end

    % ---- Spectral passband indices -------------------------------------------
    freqs    = (0:win_len-1) * (fs_up / win_len);
    f_low = 25e6; f_high = 40e6;
    idx_pass = find((freqs(1:half_len) >= f_low) & (freqs(1:half_len) <= f_high));
    has_pass = ~isempty(idx_pass);
    idx_pass_g = gpuArray(idx_pass(:));

    e    = eps;
    BATCH = G.stft_batch;   % STFT chunk size (default 16, configurable in cache)
    proto = gpuArray(single(0));

    % ---- 1. Interpolate input on GPU -----------------------------------------
    data_g = gpuArray(single(data));
    if G.gpu_interp
        dataup = interp2(G.Xi, G.Zi, data_g, G.XQ, G.ZQ, 'cubic');
    else
        F      = griddedInterpolant({G.zg, G.xg}, double(data), 'cubic', 'none');
        dataup = gpuArray(single(F(params.ZQ, params.XQ)));
    end
    dataup(isnan(dataup)) = 0;
    clear data_g

    % ==========================================================================
    % Phase 1: DAS for ALL Nl lines at once — one large gather + row-sums
    %   delay_indices: [Na x C x Nl x ul]  (int32, on GPU)
    %   raw_all:       [Na x C x Nl]
    %   aligned_all:   [Na x C x Nl]
    % ==========================================================================
    raw_all     = dataup(G.delay_indices(:,:,:,1));    % [Na x C x Nl] gather
    aligned_all = raw_all .* G.b_apod;                 % [Na x C x Nl]

    ps_data  = squeeze(sum(aligned_all,                2));  % [Na x Nl]
    dclbf    = squeeze(sum(raw_all .* G.apod(:,:,:,1), 2));
    dcrbf    = squeeze(sum(raw_all .* G.apod(:,:,:,2), 2));
    zmlbf    = squeeze(sum(raw_all .* G.apod(:,:,:,3), 2));
    dclbf01  = squeeze(sum(raw_all .* G.apod01(:,:,:,1), 2));
    dcrbf01  = squeeze(sum(raw_all .* G.apod01(:,:,:,2), 2));
    zmlbf01  = squeeze(sum(raw_all .* G.apod01(:,:,:,3), 2));
    clear raw_all

    % ==========================================================================
    % Phase 2: CF & GCF for ALL Nl lines — vectorized over [Na x C x Nl]
    % ==========================================================================
    A        = single(abs(aligned_all) > 0);           % [Na x C x Nl]
    Nrow_3d  = sum(A, 2);                              % [Na x 1 x Nl]
    valid_3d = single(Nrow_3d >= 2);                   % [Na x 1 x Nl]
    sum_sig  = sum(aligned_all, 2);                    % [Na x 1 x Nl]
    sum_sig2 = sum(aligned_all.^2, 2);                 % [Na x 1 x Nl]

    cf = (sum_sig.^2) ./ (Nrow_3d .* sum_sig2 + e);
    cf_weighted_data = squeeze((cf .* sum_sig) .* valid_3d);   % [Na x Nl]
    clear cf

    % GCF via conjugate-symmetry on compacted signal
    Nsafe_3d = reshape(max(Nrow_3d, 1), [Na, 1, Nl]);  % safe divisor [Na x 1 x Nl]
    posIdx   = cumsum(A, 2);                            % [Na x C x Nl]
    ph1      = (2*pi) * (posIdx - 1) ./ Nsafe_3d;      % [Na x C x Nl]
    clear posIdx A Nsafe_3d

    X1 = squeeze(sum(aligned_all .* exp(-1j * ph1),     2));   % [Na x Nl]
    X2 = squeeze(sum(aligned_all .* exp(-1j * 2 * ph1), 2));   % [Na x Nl]
    clear ph1

    Nrow  = squeeze(Nrow_3d);    % [Na x Nl]
    valid = squeeze(valid_3d);   % [Na x Nl]
    ss    = squeeze(sum_sig);    % [Na x Nl]  (= ps_data)
    ss2   = squeeze(sum_sig2);   % [Na x Nl]
    clear Nrow_3d valid_3d sum_sig sum_sig2

    gnum = ss.^2 + 2*abs(X1).^2 .* single(Nrow>=4) + 2*abs(X2).^2 .* single(Nrow>=6);
    gcf_weighted_data = (gnum ./ (Nrow .* ss2 + e) .* ss) .* valid;
    clear X1 X2 gnum ss2

    % ==========================================================================
    % Phase 3: Batched STFT for spectral FCF & FGCF
    %   Process BATCH lateral lines per iteration (BATCH=16 → 16 iterations vs 256)
    %   STFT tensor: [win_len x Na x C*BATCH]  (real → complex via fft)
    % ==========================================================================
    spectral_cf_data          = zeros(Na, Nl, 'like', proto);
    spectral_cf_weighted_data = zeros(Na, Nl, 'like', proto);
    spectral_gcf_data         = zeros(Na, Nl, 'like', proto);
    spectral_gcf_weighted_data= zeros(Na, Nl, 'like', proto);

    for bi = 1:ceil(Nl/BATCH)
        li = (bi-1)*BATCH + 1 : min(bi*BATCH, Nl);
        B  = numel(li);

        % Extract batch: [Na x C x B] → flatten channels: [Na x C*B]
        ab2d = reshape(aligned_all(:,:,li), [Na, C*B]);

        % Build all sliding windows: SRlin [win_len*Na x 1] indexes depth rows
        W  = reshape(ab2d(G.SRlin, :), [win_len, Na, C*B]);   % [win x Na x C*B]
        W  = W .* G.winValidS;     % zero-pad boundary windows (broadcast over C*B)
        clear ab2d

        % Batch FFT (cuFFT: win_len*Na*C*B transforms in one call)
        Wf   = fft(W, win_len, 1);                % [win_len x Na x C*B] complex
        clear W
        spec_3d = Wf(1:half_len, :, :);           % [half_len x Na x C*B]
        clear Wf

        % Separate C and B dims: [half_len x Na x C x B]
        spec_4d = reshape(spec_3d, [half_len, Na, C, B]);
        clear spec_3d

        % --- Spectral FCF: coherence across channels (dim 3) per frequency ---
        sum_spec   = sum(spec_4d, 3);             % [half_len x Na x 1 x B]
        power_spec = sum(abs(spec_4d).^2, 3);     % [half_len x Na x 1 x B]
        sum_spec   = reshape(sum_spec,   [half_len, Na, B]);  % [half_len x Na x B]
        power_spec = reshape(power_spec, [half_len, Na, B]);

        cf_per_freq = abs(sum_spec).^2 ./ (C * power_spec + e);   % [half_len x Na x B]

        if has_pass
            fcf_b = squeeze(mean(cf_per_freq(idx_pass_g, :, :), 1));  % [Na x B]
            if B == 1, fcf_b = reshape(fcf_b, [Na, 1]); end
            spectral_cf_data(:, li)          = fcf_b .* valid(:, li);
            spectral_cf_weighted_data(:, li) = (fcf_b .* ss(:, li)) .* valid(:, li);
        end
        clear cf_per_freq

        % --- Spectral FGCF: spatial coherence via 4-bin matmul ---
        % Permute [half_len x Na x C x B] → [half_len x Na x B x C]
        % Reshape  → [half_len*Na*B x C]   (big GEMM on GPU)
        Sr   = reshape(permute(spec_4d, [1,2,4,3]), [half_len*Na*B, C]);
        clear spec_4d
        Bk   = Sr * G.Ebins;                      % [half_len*Na*B x 4]  GEMM
        clear Sr
        Bk4  = reshape(Bk, [half_len, Na, B, 4]);
        clear Bk

        P_total = C * power_spec;                  % [half_len x Na x B]
        pB0  = abs(sum_spec).^2;
        pB1  = abs(Bk4(:,:,:,1)).^2;
        pB2  = abs(Bk4(:,:,:,2)).^2;
        pBm2 = abs(Bk4(:,:,:,3)).^2;
        pBm1 = abs(Bk4(:,:,:,4)).^2;
        clear Bk4 sum_spec

        Nrow_b = Nrow(:, li);                      % [Na x B]
        add2   = reshape(single(Nrow_b >= 4), [1, Na, B]);   % broadcast over half_len
        add3   = reshape(single(Nrow_b >= 6), [1, Na, B]);
        P_main = pB0 + (pB1 + pBm1) .* add2 + (pB2 + pBm2) .* add3;
        clear pB0 pB1 pB2 pBm1 pBm2 add2 add3 Nrow_b

        gcf_per_freq = P_main ./ (P_total + e);    % [half_len x Na x B]
        clear P_main P_total

        if has_pass
            fgcf_b = squeeze(mean(gcf_per_freq(idx_pass_g, :, :), 1));  % [Na x B]
            if B == 1, fgcf_b = reshape(fgcf_b, [Na, 1]); end
            spectral_gcf_data(:, li)          = fgcf_b .* valid(:, li);
            spectral_gcf_weighted_data(:, li) = (fgcf_b .* ss(:, li)) .* valid(:, li);
        end
        clear gcf_per_freq fgcf_b
    end

    % ---- Gather all outputs back to CPU (13 x ~2 MB = ~26 MB) ---------------
    ps_data                    = gather(ps_data);
    dclbf                      = gather(dclbf);
    dcrbf                      = gather(dcrbf);
    zmlbf                      = gather(zmlbf);
    spectral_cf_weighted_data  = gather(spectral_cf_weighted_data);
    cf_weighted_data           = gather(cf_weighted_data);
    gcf_weighted_data          = gather(gcf_weighted_data);
    spectral_gcf_weighted_data = gather(spectral_gcf_weighted_data);
    spectral_cf_data           = gather(spectral_cf_data);
    spectral_gcf_data          = gather(spectral_gcf_data);
    dclbf01                    = gather(dclbf01);
    dcrbf01                    = gather(dcrbf01);
    zmlbf01                    = gather(zmlbf01);
end

% ==========================================================================
function s = local_sig(params, Na, Nl, C, ul, win_len)
    di = params.delay_indices;
    s  = [Na, Nl, C, ul, win_len, numel(di), ...
          double(di(1)), double(di(end)), ...
          double(params.b_apod(1)), double(params.apod(end)), ...
          double(params.apod01(end))];
end

% ==========================================================================
function G = local_build_cache(params, Na, Nl, C, ul, win_len, half_len, sig)
    fprintf('Building GPU cache...\n');
    G.sig        = sig;
    G.stft_batch = 16;   % STFT chunk size — increase if VRAM allows, decrease if OOM

    % Large param tensors — uploaded once, reused across all 1200 calls
    G.delay_indices = gpuArray(int32(params.delay_indices));   % [Na x C x Nl x ul] int32
    G.b_apod        = gpuArray(single(params.b_apod));
    G.apod          = gpuArray(single(params.apod));
    G.apod01        = gpuArray(single(params.apod01));

    % Interpolation grids
    G.Xi = gpuArray(single(params.Xi));
    G.Zi = gpuArray(single(params.Zi));
    G.XQ = gpuArray(single(params.XQ));
    G.ZQ = gpuArray(single(params.ZQ));
    G.zg = double(params.Zi(:,1));
    G.xg = double(params.Xi(1,:)); G.xg = G.xg(:);

    % Probe GPU interp2 support
    try
        tst = interp2(G.Xi, G.Zi, gpuArray(single(zeros(size(params.Xi)))), ...
                      G.XQ, G.ZQ, 'cubic'); %#ok<NASGU>
        G.gpu_interp = true;
    catch
        G.gpu_interp = false;
    end

    % STFT source-row index matrix (depends only on Na, win_len)
    ai_vec   = 1:Na;
    start_ai = max(1, ai_vec - floor(win_len/2));
    end_ai   = min(Na, ai_vec + floor(win_len/2) - 1 + mod(win_len,2));
    len_ai   = end_ai - start_ai + 1;
    kcol     = (1:win_len).';
    SR       = start_ai + (kcol - 1);
    winValid = kcol <= len_ai;
    SR(~winValid) = 1;
    G.SRlin     = gpuArray(int32(SR(:)));
    G.winValidS = gpuArray(single(winValid));

    % FGCF 4-bin spatial DFT basis [C x 4]
    cc  = single((0:C-1).');
    w0  = 2*pi/C;
    G.Ebins = gpuArray(complex([exp(-1j*w0*cc),   exp(-1j*w0*2*cc), ...
                                exp(-1j*w0*(C-2)*cc), exp(-1j*w0*(C-1)*cc)]));

    mem_gb = (numel(params.delay_indices)*4 + numel(params.b_apod)*4 + ...
              numel(params.apod)*4 + numel(params.apod01)*4) / 1e9;
    fprintf('GPU cache ready: %.1f GB on device\n', mem_gb);
end
