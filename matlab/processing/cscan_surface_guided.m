%% cscan_surface_guided.m
%
% C-scan pipeline using surface_map from raw RF to guide subsurface
% extraction on beamformed data (ps, nsi, cf, gcf, fcf, fgcf).
%
% Replaces the manual max_ax_loc loop in beamform_fgcf_partdata_showmap.m
% with surface indices detected on the raw RF before beamforming.
%
% Prerequisites: run beamforming first so these variables exist in workspace:
%   RFdata, ps_env_lp, nsi_summed_lp, cf_env_lp, gcf_env_lp,
%   fcf_env_lp, fgcf_env_lp, nsi_summed_lp_fcf, nsi_summed_lp_fgcf

%% ── Parameters ───────────────────────────────────────────────────────────
buff_depth   = 16;      % samples below surface to extract
ax_len       = 1;       % extraction window thickness (samples)
search_range = [3800, 4200];   % sample window to search for surface echo
threshold    = 500;     % minimum envelope amplitude to count as surface
lat_range    = 25:256-24;      % lateral elements to show in C-scan

n_acq = size(ps_env_lp, 3);   % number of scan positions (200)

%% ── Step 1: Surface map from raw RF ─────────────────────────────────────
tic;
surface_map = find_surface_rfdata(RFdata, search_range, threshold);
fprintf('find_surface_rfdata: %.2f s  (size %dx%d)\n', toc, size(surface_map));
% surface_map: [n_elem × n_acq]

% Mean across elements → one surface depth per scan position
surface_idx = round(mean(surface_map, 1));   % [1 × n_acq]

%% ── Step 2: Extract C-scan slice for each beamformer ────────────────────
ps_sum      = zeros(n_acq, size(ps_env_lp, 2));
nsi01_sum   = zeros(n_acq, size(ps_env_lp, 2));
cf_sum      = zeros(n_acq, size(ps_env_lp, 2));
gcf_sum     = zeros(n_acq, size(ps_env_lp, 2));
fcf_sum     = zeros(n_acq, size(ps_env_lp, 2));
fgcf_sum    = zeros(n_acq, size(ps_env_lp, 2));
nsi_fcf_sum  = zeros(n_acq, size(ps_env_lp, 2));
nsi_fgcf_sum = zeros(n_acq, size(ps_env_lp, 2));

tic;
for ei = 1:n_acq
    s   = surface_idx(ei);
    r   = s + buff_depth : s + buff_depth + ax_len;

    ps_sum(ei,:)       = sum(ps_env_lp   (r, :, ei), 1);
    nsi01_sum(ei,:)    = sum(nsi_summed_lp(r, :, ei), 1);
    cf_sum(ei,:)       = sum(cf_env_lp    (r, :, ei), 1);
    gcf_sum(ei,:)      = sum(gcf_env_lp   (r, :, ei), 1);
    fcf_sum(ei,:)      = sum(fcf_env_lp   (r, :, ei), 1);
    fgcf_sum(ei,:)     = sum(fgcf_env_lp  (r, :, ei), 1);
    nsi_fcf_sum(ei,:)  = sum(nsi_summed_lp_fcf (r, :, ei), 1);
    nsi_fgcf_sum(ei,:) = sum(nsi_summed_lp_fgcf(r, :, ei), 1);
end
fprintf('C-scan extraction: %.2f s\n', toc);

%% ── Step 3: Display C-scan maps ─────────────────────────────────────────
figure(600);
subplot(241); imagesc(ps_sum(:, lat_range));       colormap gray; title('ps');
subplot(242); imagesc(nsi01_sum(:, lat_range));     colormap gray; title('nsi');
subplot(243); imagesc(cf_sum(:, lat_range));        colormap gray; title('cf');
subplot(244); imagesc(gcf_sum(:, lat_range));       colormap gray; title('gcf');
subplot(245); imagesc(fcf_sum(:, lat_range));       colormap gray; title('fcf');
subplot(246); imagesc(fgcf_sum(:, lat_range));      colormap gray; title('fgcf');
subplot(247); imagesc(nsi_fcf_sum(:, lat_range));   colormap gray; title('nsi-fcf');
subplot(248); imagesc(nsi_fgcf_sum(:, lat_range));  colormap gray; title('nsi-fgcf');
sgtitle(sprintf('C-scan  buff\\_depth=%d  ax\\_len=%d', buff_depth, ax_len));

%% ── Step 4: Surface depth QC plot ────────────────────────────────────────
figure(601);
imagesc(surface_map);
xlabel('scan position'); ylabel('element');
title('surface\_map: detected surface sample index per element');
colorbar;

figure(602);
plot(surface_idx);
xlabel('scan position'); ylabel('sample index');
title('mean surface depth across elements');
grid on;

%% ── Step 5: SNR per beamformer ───────────────────────────────────────────
nois_lat = 101:200;
nois_ele = 1:50;

methods   = {ps_sum, nsi01_sum, cf_sum, gcf_sum, fcf_sum, fgcf_sum};
names     = {'ps','nsi','cf','gcf','fcf','fgcf'};
snr_vals  = zeros(1, numel(methods));

for mi = 1:numel(methods)
    M = methods{mi};
    snr_vals(mi) = max(M(:)) / mean(M(nois_ele, nois_lat), 'all');
end

figure(603);
bar(snr_vals);
set(gca, 'XTickLabel', names);
ylabel('SNR (linear)');
title('C-scan SNR by beamformer');
grid on;

%% ── Optional: save maps ─────────────────────────────────────────────────
% save_map_name = 'E:\issac\...\cscan_surface_guided.mat';
% save(save_map_name, 'ps_sum','nsi01_sum','cf_sum','gcf_sum', ...
%      'fcf_sum','fgcf_sum','nsi_fcf_sum','nsi_fgcf_sum','surface_map','surface_idx');
