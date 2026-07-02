function [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, spectral_cf_data, spectral_gcf_data, dclbf01, dcrbf01, zmlbf01] = bf_fgcf_fast_execute_v2(data, params, fs, ul, ua)
    % 高速波束合成及相干因子计算执行器 (V2 - 向量化 / 单精度优化版)
    % Drop-in replacement for bf_fgcf_fast_execute — identical signature and outputs.
    % Algorithm unchanged; only computation is vectorized and single precision.
    %
    % Key changes vs V1:
    %   - All internal arrays use single precision (halves memory bandwidth)
    %   - griddedInterpolant replaces interp2 (faster for repeated use)
    %   - The for ai=1:Na loop is eliminated — CF/GCF/FCF/FGCF are vectorized
    %   - Sliding-window STFT is batched across all Na depths in one fft() call
    %   - apod slices pre-extracted outside inner loops (no squeeze allocation)

    fs_up = fs * ua;
    Na = params.Na;
    Nl = params.Nl;
    C  = params.ele;          % num_channels
    total_lines = Nl * ul;

    % ---- 1. Interpolation via griddedInterpolant (single precision) -----------
    % 'none' extrapolation returns NaN for out-of-domain, zeroed below — same
    % behaviour as original interp2(...,'cubic') + dataup(isnan)=0.
    data   = single(data);
    zg     = double(params.Zi(:,1));
    xg     = double(params.Xi(1,:));
    F      = griddedInterpolant({zg(:), xg(:)}, data, 'cubic', 'none');
    dataup = single(F(params.ZQ, params.XQ));
    dataup(isnan(dataup)) = 0;

    % ---- Preallocate outputs (single) ----------------------------------------
    ps_data  = zeros(Na, total_lines, 'single');
    dclbf    = zeros(Na, total_lines, 'single');  dcrbf   = zeros(Na, total_lines, 'single');  zmlbf   = zeros(Na, total_lines, 'single');
    dclbf01  = zeros(Na, total_lines, 'single');  dcrbf01 = zeros(Na, total_lines, 'single');  zmlbf01 = zeros(Na, total_lines, 'single');
    cf_weighted_data          = zeros(Na, total_lines, 'single');
    gcf_weighted_data         = zeros(Na, total_lines, 'single');
    spectral_cf_data          = zeros(Na, total_lines, 'single');
    spectral_cf_weighted_data = zeros(Na, total_lines, 'single');
    spectral_gcf_data         = zeros(Na, total_lines, 'single');
    spectral_gcf_weighted_data= zeros(Na, total_lines, 'single');

    % ---- Spectral constants --------------------------------------------------
    win_len  = 64;
    half_len = floor(win_len/2) + 1;                  % 33
    freqs    = (0:win_len-1) * (fs_up / win_len);
    f_low = 25e6; f_high = 40e6;
    idx_pass = find((freqs(1:half_len) >= f_low) & (freqs(1:half_len) <= f_high));
    has_pass = ~isempty(idx_pass);

    % ---- Batch STFT index matrix (computed once for all ei) ------------------
    % SR(k, ai) = source row for window sample k at depth ai.
    % Reproduces original: start=max(1,ai-32), end=min(Na,ai+31), top-aligned.
    ai_vec   = 1:Na;
    start_ai = max(1,  ai_vec - floor(win_len/2));     % [1 x Na]
    end_ai   = min(Na, ai_vec + floor(win_len/2) - 1 + mod(win_len,2));
    len_ai   = end_ai - start_ai + 1;
    kcol     = (1:win_len).';                          % [win_len x 1]
    SR       = start_ai + (kcol - 1);                 % [win_len x Na]
    winValid = kcol <= len_ai;                         % [win_len x Na] logical
    SR(~winValid) = 1;                                 % clamp to safe index
    SRlin    = SR(:);                                  % [win_len*Na x 1]
    winValidS = single(winValid);                      % for zero-padding

    % ---- FGCF spatial DFT basis (only the 4 non-DC mainlobe bins needed) -----
    % Avoids full length-C spatial FFT of the [half_len x Na x C] tensor.
    % Mainlobe: DC (=sum_spec, reused from FCF), bins +1,+2,-2,-1.
    cc  = single((0:C-1).');
    w0  = 2*pi/C;
    Ebins = complex([exp(-1j*w0*1*cc), exp(-1j*w0*2*cc), ...
                     exp(-1j*w0*(C-2)*cc), exp(-1j*w0*(C-1)*cc)]);  % [C x 4]

    % ---- Main loop (over lateral lines only — the ai loop is eliminated) ------
    for ei = 1:Nl

        % Pre-extract apodization slices (no squeeze, no repeated allocation)
        b_apod_cur = single(params.b_apod(:,:,ei));        % [Na x C]
        a_dcl   = single(params.apod(:,:,ei,1));
        a_dcr   = single(params.apod(:,:,ei,2));
        a_zml   = single(params.apod(:,:,ei,3));
        a01_dcl = single(params.apod01(:,:,ei,1));
        a01_dcr = single(params.apod01(:,:,ei,2));
        a01_zml = single(params.apod01(:,:,ei,3));

        for upsample = 1:ul
            cur_line = (ei-1)*ul + upsample;

            % --- Gather delayed samples via precomputed index map ---
            idx_map = params.delay_indices(:,:,ei,upsample);
            raw     = dataup(idx_map);                     % [Na x C]

            % --- DAS / NSI beamforming (matrix row-sums) ---
            aligned = raw .* b_apod_cur;
            ps_data(:, cur_line)  = sum(aligned,       2);
            dclbf(:, cur_line)    = sum(raw .* a_dcl,  2);
            dcrbf(:, cur_line)    = sum(raw .* a_dcr,  2);
            zmlbf(:, cur_line)    = sum(raw .* a_zml,  2);
            dclbf01(:, cur_line)  = sum(raw .* a01_dcl,2);
            dcrbf01(:, cur_line)  = sum(raw .* a01_dcr,2);
            zmlbf01(:, cur_line)  = sum(raw .* a01_zml,2);

            % ============ Vectorized CF & GCF (no for ai loop) ===============

            A        = abs(aligned) > 0;                   % active mask [Na x C]
            Nrow     = single(sum(A, 2));                  % N_active per depth [Na x 1]
            valid    = Nrow >= 2;                          % rows to compute
            sum_sig  = sum(aligned, 2);                    % DAS value = das_value
            sum_sig2 = sum(aligned.^2, 2);

            % CF: (sum_sig)^2 / (N * sum_sig2)
            cf = (sum_sig.^2) ./ (Nrow .* sum_sig2 + eps);
            cf_weighted_data(:, cur_line) = (cf .* sum_sig) .* valid;

            % GCF: mainlobe uses conjugate symmetry of real signal compacted to
            % N_active samples. DC = sum_sig; bins +-1 and +-2 estimated via
            % DFT phase on packed positions (only needed for Nrow>=4 / Nrow>=6).
            Nsafe   = max(Nrow, 1);
            posIdx  = cumsum(single(A), 2);                % packing position [Na x C]
            ph1     = (2*pi) * (posIdx - 1) ./ Nsafe;
            X1      = sum(aligned .* exp(-1j * ph1),     2);
            X2      = sum(aligned .* exp(-1j * 2 * ph1), 2);
            add4    = single(Nrow >= 4);
            add6    = single(Nrow >= 6);
            gnum    = sum_sig.^2 + 2*abs(X1).^2 .* add4 + 2*abs(X2).^2 .* add6;
            gcf     = gnum ./ (Nrow .* sum_sig2 + eps);
            gcf_weighted_data(:, cur_line) = (gcf .* sum_sig) .* valid;

            % ============ Batch STFT for spectral FCF & FGCF =================
            % Build all Na windows at once: W is [win_len x Na x C]
            W  = reshape(aligned(SRlin, :), [win_len, Na, C]);
            W  = W .* winValidS;                           % zero-pad (broadcast over C)
            Wf = fft(W, win_len, 1);                       % single batch FFT
            spec = Wf(1:half_len, :, :);                   % [half_len x Na x C]

            % --- Spectral FCF: channel coherence per frequency bin ---
            sum_spec   = sum(spec, 3);                     % [half_len x Na]  (= DC spatial bin, reused below)
            power_spec = sum(abs(spec).^2, 3);             % [half_len x Na]
            cf_per_freq = abs(sum_spec).^2 ./ (C * power_spec + eps);
            if has_pass
                spectral_cf = mean(cf_per_freq(idx_pass, :), 1).';   % [Na x 1]
            else
                spectral_cf = zeros(Na, 1, 'single');
            end
            spectral_cf_data(:, cur_line)          = spectral_cf .* valid;
            spectral_cf_weighted_data(:, cur_line) = (spectral_cf .* sum_sig) .* valid;

            % --- Spectral FGCF: spatial coherence per frequency bin ---
            % Total spatial power via Parseval: C * sum_c |spec|^2
            P_total = C * power_spec;                      % [half_len x Na]

            % Mainlobe spatial bins via small matmul — avoids full spatial FFT.
            % spec reshaped to [half_len*Na x C], multiply by Ebins [C x 4].
            Sr   = reshape(spec, [half_len*Na, C]);
            Bk   = Sr * Ebins;                            % [half_len*Na x 4]: bins +1,+2,-2,-1
            pB1  = reshape(abs(Bk(:,1)).^2, [half_len, Na]);
            pB2  = reshape(abs(Bk(:,2)).^2, [half_len, Na]);
            pBm2 = reshape(abs(Bk(:,3)).^2, [half_len, Na]);
            pBm1 = reshape(abs(Bk(:,4)).^2, [half_len, Na]);
            pB0  = abs(sum_spec).^2;                       % DC spatial bin (bin 0 = sum over channels)

            % Accumulate mainlobe: DC always; +-1 if Nrow>=4; +-2 if Nrow>=6
            add2_f = single(Nrow >= 4).';                  % [1 x Na] for broadcast
            add3_f = single(Nrow >= 6).';
            P_main = pB0 + (pB1 + pBm1) .* add2_f + (pB2 + pBm2) .* add3_f;

            gcf_per_freq = P_main ./ (P_total + eps);
            if has_pass
                spectral_gcf = mean(gcf_per_freq(idx_pass, :), 1).';  % [Na x 1]
            else
                spectral_gcf = zeros(Na, 1, 'single');
            end
            spectral_gcf_data(:, cur_line)          = spectral_gcf .* valid;
            spectral_gcf_weighted_data(:, cur_line) = (spectral_gcf .* sum_sig) .* valid;
        end
    end
end
