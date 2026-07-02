function [ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, spectral_cf_data, spectral_gcf_data, dclbf01, dcrbf01, zmlbf01] = bf_fgcf_fast_execute(data, params, fs, ul, ua)
    % 高速波束合成及相干因子计算执行器
    
    fs_up = fs * ua;
    Na = params.Na;
    Nl = params.Nl;
    num_channels = params.ele;
    
    % 1. 执行插值 (基于预先算好的网格)
    dataup = interp2(params.Xi, params.Zi, data, params.XQ, params.ZQ, 'cubic');
    dataup(isnan(dataup)) = 0;
    
    % 预分配输出
    total_lines = Nl * ul;
    ps_data = zeros(Na, total_lines);
    dclbf = zeros(Na, total_lines); dcrbf = zeros(Na, total_lines); zmlbf = zeros(Na, total_lines);
    dclbf01 = zeros(Na, total_lines); dcrbf01 = zeros(Na, total_lines); zmlbf01 = zeros(Na, total_lines);
    cf_data = zeros(Na, total_lines); cf_weighted_data = zeros(Na, total_lines);
    gcf_weighted_data = zeros(Na, total_lines);
    spectral_cf_data = zeros(Na, total_lines); spectral_cf_weighted_data = zeros(Na, total_lines);
    spectral_gcf_data = zeros(Na, total_lines); spectral_gcf_weighted_data = zeros(Na, total_lines);
    
    % 频谱参数常量设定
    win_len = 64;
    half_len = floor(win_len/2) + 1;
    freqs = (0:win_len-1) * (fs_up / win_len);
    f_low = 25e6; f_high = 40e6;
    idx_pass = find( (freqs(1:half_len) >= f_low) & (freqs(1:half_len) <= f_high) );
    
    for ei = 1:Nl
        for upsample = 1:ul
            cur_line = (ei-1)*ul + upsample;
            
            % --- 直接利用预计算的索引提取数据 ---
            % 这一步消除了内部重新计算 tau 和 sample_delay 的开销
            idx_map = params.delay_indices(:,:,ei,upsample);
            %params.delay_indices{ei, upsample};

            raw_data_get_mat = dataup(idx_map);
            
            % --- 矩阵点乘求和 (DAS 及 NSI) ---
            b_apod_cur = squeeze(params.b_apod(:,:,ei));
            ps_data(:, cur_line) = sum(raw_data_get_mat .* b_apod_cur, 2);
            dclbf(:, cur_line)   = sum(raw_data_get_mat .* squeeze(params.apod(:,:,ei,1)), 2);
            dcrbf(:, cur_line)   = sum(raw_data_get_mat .* squeeze(params.apod(:,:,ei,2)), 2);
            zmlbf(:, cur_line)   = sum(raw_data_get_mat .* squeeze(params.apod(:,:,ei,3)), 2);
            
            dclbf01(:, cur_line) = sum(raw_data_get_mat .* squeeze(params.apod01(:,:,ei,1)), 2);
            dcrbf01(:, cur_line) = sum(raw_data_get_mat .* squeeze(params.apod01(:,:,ei,2)), 2);
            zmlbf01(:, cur_line) = sum(raw_data_get_mat .* squeeze(params.apod01(:,:,ei,3)), 2);
            
            %% CF & GCF 计算
            aligned_signals_apod = raw_data_get_mat .* b_apod_cur;
            
            for ai = 1:Na
                sig_vec = aligned_signals_apod(ai, :);
                active_idx = abs(sig_vec) > 0;
                sig_active = sig_vec(active_idx);
                N_active = sum(active_idx);
                
                if N_active >= 2
                    sum_sig = sum(sig_active);
                    sum_sig2 = sum(sig_active.^2);
                    
                    % 1. CF
                    cf = (sum_sig^2) / (N_active * sum_sig2 + eps);
                    cf_data(ai, cur_line) = cf;
                    das_value = sum_sig;
                    cf_weighted_data(ai, cur_line) = cf * das_value;
                    
                    % 2. GCF
                    max_bins = floor(N_active / 2);
                    mainlobe_bins = min(3, max_bins);
                    X_gcf = fft(sig_active(:), N_active);
                    P_gcf = abs(X_gcf).^2;
                    idx_mainlobe = [1:mainlobe_bins, N_active-mainlobe_bins+2:N_active];
                    gcf_value = sum(P_gcf(idx_mainlobe)) / (sum(P_gcf) + eps);
                    gcf_weighted_data(ai, cur_line) = gcf_value * das_value;
                    
                    % 3. Spectral FCF & FGCF (极致向量化优化版)
                    half_win = floor(win_len/2);
                    start_idx = max(1, ai - half_win);
                    end_idx = min(Na, ai + half_win - 1 + mod(win_len,2));
                    
                    window_data = zeros(win_len, num_channels);
                    window_data(1:(end_idx - start_idx + 1), :) = aligned_signals_apod(start_idx:end_idx, :);
                    
                    window_fft = fft(window_data, win_len, 1); 
                    
                    % 提取需要计算的半频段矩阵 [half_len x num_channels]
                    spec_mat = window_fft(1:half_len, :);
                    
                    % ==== FCF 向量化计算 (替代原 for 循环) ====
                    sum_spec = sum(spec_mat, 2); % 沿通道求和
                    power_spec = sum(abs(spec_mat).^2, 2);
                    cf_per_freq = (abs(sum_spec).^2) ./ (num_channels * power_spec + eps);
                    
                    if ~isempty(idx_pass)
                        spectral_cf = mean(cf_per_freq(idx_pass));
                    else
                        spectral_cf = 0;
                    end
                    spectral_cf_data(ai, cur_line) = spectral_cf;
                    spectral_cf_weighted_data(ai, cur_line) = spectral_cf * das_value;
                    
                    % ==== FGCF 向量化计算 (替代原 for 循环) ====
                    % 对各频率分量同时执行空间 FFT (参数2表示沿列操作)
                    spatial_fft = fft(spec_mat, num_channels, 2); 
                    spatial_power = abs(spatial_fft).^2;
                    
                    % 固定通道数(num_channels)计算空间主瓣
                    idx_mainlobe_space = [1:mainlobe_bins, num_channels-mainlobe_bins+2:num_channels];
                    
                    P_mainlobe_f = sum(spatial_power(:, idx_mainlobe_space), 2);
                    P_total_f = sum(spatial_power, 2);
                    gcf_per_freq = P_mainlobe_f ./ (P_total_f + eps);
                    
                    if ~isempty(idx_pass)
                        spectral_gcf = mean(gcf_per_freq(idx_pass));
                    else
                        spectral_gcf = 0;
                    end
                    spectral_gcf_data(ai, cur_line) = spectral_gcf;
                    spectral_gcf_weighted_data(ai, cur_line) = spectral_gcf * das_value;
                end
            end
        end
    end
end