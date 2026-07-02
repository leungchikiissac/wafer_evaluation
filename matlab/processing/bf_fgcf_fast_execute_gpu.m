function [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, spectral_cf_data, spectral_gcf_data, dclbf01, dcrbf01, zmlbf01] = bf_fgcf_fast_execute_gpu(data, params, fs, ul, ua)
    % GPU-accelerated beamform + coherence factor calculator (V3, batched).
    % Drop-in replacement for bf_fgcf_fast_execute — identical signature/outputs.
    %
    % Architecture (vs V1 for-ei=1:256 loop):
    %   Phase 1 : One big [Na x C x Nl] gather → all DAS outputs, keep aligned_all
    %   Phase 2 : Single loop over STFT_BATCH chunks (16 lines each = 16 iters vs 256):
    %             CF/GCF on [Na x C x B] — fits in cache; no 1 GB exp() allocation
    %             STFT    on [win x Na x C*B] — large cuFFT batch
    %             FCF/FGCF via zero-copy reshape + pagemtimes (no permute copy)
    %
    % Peak GPU memory (Na=2048, C=256, Nl=256, B=16):
    %   Cache:         ~4.3 GB (params, uploaded once)
    %   aligned_all:   ~0.54 GB (kept across Phase 2)
    %   STFT peak:     ~6.4 GB (W real + Wf complex, B=16)
    %   Total peak:    ~11 GB of 24 GB (P6000)
    %
    % To clear GPU cache: clear bf_fgcf_fast_execute_gpu

    persistent G

    Na    = params.Na;
    Nl    = params.Nl;
    C     = params.ele;
    fs_up = fs * ua;
    win_len  = 64;
    half_len = floor(win_len/2) + 1;   % 33
    e = eps;

    % ---- Build / validate persistent GPU cache (uploaded once) ---------------
    sig = local_sig(params, Na, Nl, C, ul, win_len);
    if isempty(G) || ~isequal(G.sig, sig)
        G = local_build_cache(params, Na, Nl, C, ul, win_len, half_len, sig);
    end

    BATCH = G.stft_batch;
    proto = gpuArray(single(0));

    % ---- Spectral passband indices (recomputed each call, cheap) -------------
    freqs    = (0:win_len-1) * (fs_up / win_len);
    idx_pass = gpuArray(int32(find(freqs(1:half_len) >= 25e6 & freqs(1:half_len) <= 40e6)));
    has_pass = ~isempty(idx_pass);
    n_pass   = numel(idx_pass);

    % ---- Interpolate input on GPU --------------------------------------------
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
    % Phase 1: One big gather → DAS outputs + aligned_all
    %   delay_indices: [Na x C x Nl x ul] int32 on GPU
    %   raw_all / aligned_all: [Na x C x Nl] single
    % ==========================================================================
    raw_all     = dataup(G.delay_indices(:,:,:,1));   % [Na x C x Nl]
    aligned_all = raw_all .* G.b_apod;                % [Na x C x Nl]

    % DAS & NSI outputs: [Na x Nl] via column-sums (no loop)
    ps_data = squeeze(sum(aligned_all,                2));
    dclbf   = squeeze(sum(raw_all .* G.apod(:,:,:,1),   2));
    dcrbf   = squeeze(sum(raw_all .* G.apod(:,:,:,2),   2));
    zmlbf   = squeeze(sum(raw_all .* G.apod(:,:,:,3),   2));
    dclbf01 = squeeze(sum(raw_all .* G.apod01(:,:,:,1), 2));
    dcrbf01 = squeeze(sum(raw_all .* G.apod01(:,:,:,2), 2));
    zmlbf01 = squeeze(sum(raw_all .* G.apod01(:,:,:,3), 2));
    clear raw_all

    % Preallocate CF/FCF outputs
    cf_weighted_data           = zeros(Na, Nl, 'like', proto);
    gcf_weighted_data          = zeros(Na, Nl, 'like', proto);
    spectral_cf_data           = zeros(Na, Nl, 'like', proto);
    spectral_cf_weighted_data  = zeros(Na, Nl, 'like', proto);
    spectral_gcf_data          = zeros(Na, Nl, 'like', proto);
    spectral_gcf_weighted_data = zeros(Na, Nl, 'like', proto);

    % ==========================================================================
    % Phase 2: Batch loop over BATCH lateral lines
    %   Each iteration handles B lines simultaneously, keeping working tensors
    %   at [Na x C x B] = 134 MB (B=16) — fits in GPU L2 / texture cache.
    %
    %   KEY: the reshape [half_len x Na x C*B] → [half_len*Na x C x B] is
    %   ZERO-COPY because within the last dim C*B, channels vary faster than
    %   lines (layout built that way by reshape(ab,[Na,C*B]) above).
    % ==========================================================================
    for bi = 1:ceil(Nl/BATCH)
        li = (bi-1)*BATCH + 1 : min(bi*BATCH, Nl);
        B  = numel(li);

        ab = aligned_all(:,:,li);     % [Na x C x B]

        % ---- CF & GCF (work on [Na x C x B], not [Na x C x Nl]) ----
        A_b     = single(ab ~= 0);    % [Na x C x B]
        Nrow_b  = sum(A_b, 2);        % [Na x 1 x B]
        ss_b    = sum(ab, 2);         % [Na x 1 x B]
        ss2_b   = sum(ab.^2, 2);      % [Na x 1 x B]
        valid_b = single(Nrow_b >= 2);% [Na x 1 x B]

        % CF: reshape avoids squeeze ambiguity when B=1
        cf_b = (ss_b.^2) ./ (Nrow_b .* ss2_b + e) .* ss_b .* valid_b;
        cf_weighted_data(:, li) = reshape(cf_b, [Na, B]);

        % GCF via conjugate symmetry of packed active samples
        Nsafe  = reshape(max(Nrow_b, 1), [Na, 1, B]);
        posIdx = cumsum(A_b, 2);                   % [Na x C x B]
        ph1    = (2*pi) * (posIdx - 1) ./ Nsafe;  % [Na x C x B]
        clear posIdx A_b Nsafe

        X1 = reshape(sum(ab .* exp(-1j * ph1),     2), [Na, B]);  % [Na x B]
        X2 = reshape(sum(ab .* exp(-1j * 2 * ph1), 2), [Na, B]);
        clear ph1

        Nrow_2d  = reshape(Nrow_b,  [Na, B]);
        valid_2d = reshape(valid_b, [Na, B]);
        ss_2d    = reshape(ss_b,    [Na, B]);
        ss2_2d   = reshape(ss2_b,   [Na, B]);
        clear Nrow_b valid_b ss_b ss2_b

        gnum = ss_2d.^2 + 2*abs(X1).^2.*single(Nrow_2d>=4) + 2*abs(X2).^2.*single(Nrow_2d>=6);
        gcf_weighted_data(:, li) = (gnum ./ (Nrow_2d .* ss2_2d + e) .* ss_2d) .* valid_2d;
        clear X1 X2 gnum ss2_2d

        % ---- Batch STFT over all C*B columns at once ----
        ab2d = reshape(ab, [Na, C*B]);     % zero-copy: [Na,C,B] → [Na, C*B]
        W    = reshape(ab2d(G.SRlin, :), [win_len, Na, C*B]);  % [win x Na x C*B]
        W    = W .* G.winValidS;           % zero-pad (broadcast [win x Na] over C*B)
        clear ab2d ab

        Wf = fft(W, win_len, 1);           % [win_len x Na x C*B] complex (cuFFT)
        clear W

        % Zero-copy reshape: [half_len x Na x C*B] → [half_len*Na x C x B]
        % Correctness: within last dim C*B, index j = (c-1) + C*(b-1),
        % so c varies fastest → reshape [C, B] is memory-contiguous.
        spec_r = reshape(Wf(1:half_len, :, :), [half_len*Na, C, B]);
        clear Wf

        % ---- Spectral FCF: channel coherence per frequency ----
        sum_r   = sum(spec_r, 2);           % [half_len*Na x 1 x B]
        power_r = sum(abs(spec_r).^2, 2);   % [half_len*Na x 1 x B]
        sum_3d   = reshape(sum_r,   [half_len, Na, B]);
        power_3d = reshape(power_r, [half_len, Na, B]);

        if has_pass
            cf_pf = abs(sum_3d).^2 ./ (C * power_3d + e);    % [half_len x Na x B]
            fcf   = reshape(sum(cf_pf(idx_pass,:,:), 1), [Na, B]) / n_pass;
            spectral_cf_data(:, li)          = fcf .* valid_2d;
            spectral_cf_weighted_data(:, li) = (fcf .* ss_2d) .* valid_2d;
            clear cf_pf fcf
        end

        % ---- Spectral FGCF: spatial coherence per frequency, 4-bin matmul ----
        % pagemtimes: [half_len*Na x C x B] × [C x 4] → [half_len*Na x 4 x B]
        % No permute, no copy — just a batched GEMM.
        if G.use_pagemtimes
            Bk = pagemtimes(spec_r, G.Ebins);    % [half_len*Na x 4 x B]
        else
            Bk = zeros(half_len*Na, 4, B, 'like', spec_r);
            for b = 1:B
                Bk(:,:,b) = spec_r(:,:,b) * G.Ebins;
            end
        end
        clear spec_r

        Bk4  = reshape(Bk, [half_len, Na, B, 4]);
        clear Bk
        pB0  = abs(sum_3d).^2;                  % DC spatial bin
        pB1  = abs(Bk4(:,:,:,1)).^2;
        pB2  = abs(Bk4(:,:,:,2)).^2;
        pBm2 = abs(Bk4(:,:,:,3)).^2;
        pBm1 = abs(Bk4(:,:,:,4)).^2;
        clear Bk4

        P_tot  = C * power_3d;
        clear sum_r power_r sum_3d power_3d
        add2   = reshape(single(Nrow_2d >= 4), [1, Na, B]);
        add3   = reshape(single(Nrow_2d >= 6), [1, Na, B]);
        P_main = pB0 + (pB1 + pBm1).*add2 + (pB2 + pBm2).*add3;
        clear pB0 pB1 pB2 pBm1 pBm2 add2 add3

        if has_pass
            gcf_pf = P_main ./ (P_tot + e);      % [half_len x Na x B]
            fgcf   = reshape(sum(gcf_pf(idx_pass,:,:), 1), [Na, B]) / n_pass;
            spectral_gcf_data(:, li)          = fgcf .* valid_2d;
            spectral_gcf_weighted_data(:, li) = (fgcf .* ss_2d) .* valid_2d;
            clear gcf_pf fgcf
        end
        clear P_main P_tot Nrow_2d valid_2d ss_2d
    end

    % ---- Gather all outputs to CPU ------------------------------------------
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
    G.stft_batch = 16;   % Lines per STFT batch. Decrease to 8 if out-of-memory.

    % Large param arrays — uploaded once (~4.3 GB total)
    G.delay_indices = gpuArray(int32(params.delay_indices));
    G.b_apod        = gpuArray(single(params.b_apod));
    G.apod          = gpuArray(single(params.apod));
    G.apod01        = gpuArray(single(params.apod01));

    % Interpolation grids
    G.Xi = gpuArray(single(params.Xi));
    G.Zi = gpuArray(single(params.Zi));
    G.XQ = gpuArray(single(params.XQ));
    G.ZQ = gpuArray(single(params.ZQ));
    G.zg = double(params.Zi(:,1));
    G.xg = double(params.Xi(1,:));

    try
        tst = interp2(G.Xi, G.Zi, gpuArray(single(zeros(size(params.Xi)))), ...
                      G.XQ, G.ZQ, 'cubic'); %#ok<NASGU>
        G.gpu_interp = true;
    catch
        G.gpu_interp = false;
    end

    % STFT source-row index vector [win_len*Na x 1] and validity mask [win_len x Na]
    ai_vec   = 1:Na;
    start_ai = max(1,  ai_vec - floor(win_len/2));
    end_ai   = min(Na, ai_vec + floor(win_len/2) - 1 + mod(win_len,2));
    len_ai   = end_ai - start_ai + 1;
    kcol     = (1:win_len).';
    SR       = start_ai + (kcol - 1);
    winValid = kcol <= len_ai;
    SR(~winValid) = 1;
    G.SRlin     = gpuArray(int32(SR(:)));      % [win_len*Na x 1]
    G.winValidS = gpuArray(single(winValid));  % [win_len x Na]

    % FGCF 4-bin spatial DFT basis [C x 4]
    cc  = single((0:C-1).');
    w0  = 2*pi/C;
    G.Ebins = gpuArray(complex(single([ ...
        exp(-1j*w0*1*cc),   exp(-1j*w0*2*cc), ...
        exp(-1j*w0*(C-2)*cc), exp(-1j*w0*(C-1)*cc)])));

    % Check pagemtimes GPU support (R2020b+, gpuArray since ~R2022a)
    try
        tst2 = pagemtimes(gpuArray(complex(single(zeros(2,C,2)))), G.Ebins); %#ok<NASGU>
        G.use_pagemtimes = true;
        fprintf('GPU cache ready — pagemtimes available\n');
    catch
        G.use_pagemtimes = false;
        fprintf('GPU cache ready — pagemtimes not available, using per-page GEMM loop\n');
    end

    mem_gb = (numel(params.delay_indices)*4 + numel(params.b_apod)*4 + ...
              numel(params.apod)*4 + numel(params.apod01)*4) / 1e9;
    fprintf('  Cached params: %.1f GB on GPU\n', mem_gb);
end
