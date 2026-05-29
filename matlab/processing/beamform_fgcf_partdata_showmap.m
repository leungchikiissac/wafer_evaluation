%%
figure();imagesc(fcf_ds(:,:,50))
for i = 3100:3200
 figure(4);imagesc(squeeze(abs(hilbert(ps_data_ds(i,32:226,:))))'); title(i);pause(0.1);
end

%%

f0 = 29.411764705882350e6;
fs = 117.6470588235294e6;
fs_up = fs;

depth = 1472;
f0 = 29.411764705882350e6;
%7.14285714285714e6;
t= (1:depth)'/(fs_up);
ua = 1;

down_shift = exp(-1i*2*pi*f0*t);


for elei = 1:200
    elei
for ei = 1:256
    dclbf_iq(:,ei,elei) = dclbf_ds(1:ua:end,ei,elei).*down_shift;
    dcrbf_iq(:,ei,elei) = dcrbf_ds(1:ua:end,ei,elei).*down_shift;
    zmlbf_iq(:,ei,elei) = zmlbf_ds(1:ua:end,ei,elei).*down_shift;
    ps_iq(:,ei,elei) = ps_data_ds(1:ua:end,ei,elei).*down_shift;
    %dmas_iq(:,ei) = dmas_data(:,ei).*down_shift;
    
    cf_iq(:,ei,elei) = cf_ds(1:ua:end,ei,elei).*down_shift;
    gcf_iq(:,ei,elei) = gcf_ds(1:ua:end,ei,elei).*down_shift;
    %scf_iq(:,ei) = scf_weighted_data(:,ei).*down_shift;

    fcf_iq(:,ei,elei) = fcf_ds(1:ua:end,ei,elei).*down_shift;
    fgcf_iq(:,ei,elei) = fgcf_ds(1:ua:end,ei,elei).*down_shift;

    %fcf_weight_ds(:,ei,elei) = fcf_weight_ds(1:ua:end,ei,elei).*down_shift;
    %fgcf_weight_ds(:,ei,elei) = fgcf_weight_ds(1:ua:end,ei,elei).*down_shift;

end
end
%nsi_summed_ls = abs(0.5*(abs(dclbf_iq)+abs(dcrbf_iq))-abs(zmlbf_iq));
% figure();imagesc(log10(nsi_summed_ls(1:end,:))); colormap gray;


%%
rf_lp_filt= designfilt('lowpassfir', ...        % Response type
       'FilterOrder',100, ...            % Filter order
       'PassbandFrequency',5e6, ...     % Frequency constraints
       'StopbandFrequency',10e6, ...
       'SampleRate',fs_up);               % Sample rate
%fvtool(rf_lp_filt)

for elei = 1:200
    elei
dclbf_iqlp(:,:,elei) = filter(rf_lp_filt,dclbf_iq(:,:,elei));
dcrbf_iqlp(:,:,elei) = filter(rf_lp_filt,dcrbf_iq(:,:,elei));
zmlbf_iqlp(:,:,elei) = filter(rf_lp_filt,zmlbf_iq(:,:,elei));
ps_iqlp(:,:,elei) = filter(rf_lp_filt,ps_iq(:,:,elei));
cf_iqlp(:,:,elei) = filter(rf_lp_filt,cf_iq(:,:,elei));
fcf_iqlp(:,:,elei) = filter(rf_lp_filt,fcf_iq(:,:,elei));
gcf_iqlp(:,:,elei) = filter(rf_lp_filt,gcf_iq(:,:,elei));
fgcf_iqlp(:,:,elei) = filter(rf_lp_filt,fgcf_iq(:,:,elei));

%fcf_weight_ds(:,:,elei) = filter(rf_lp_filt,fcf_weight_ds(:,:,elei));
%fgcf_weight_ds(:,:,elei) = filter(rf_lp_filt,fgcf_weight_ds(:,:,elei));

end
% dclbf_iqlp = dclbf_iq;
% dcrbf_iqlp = dcrbf_iq;
% zmlbf_iqlp = zmlbf_iq;
%%
for elei = 1:200
    elei
upper_cut = 100;
nsi_summed_lp(:,:,elei) = abs(0.5*(abs(dclbf_iqlp(:,:,elei))+abs(dcrbf_iqlp(:,:,elei)))-abs(zmlbf_iqlp(:,:,elei)));
nsi_summed_lp_show(:,:,elei) = nsi_summed_lp(upper_cut:end-500,:,elei);
nsi_summed_lp_show_norm(:,:,elei) = nsi_summed_lp_show(:,:,elei)./max(nsi_summed_lp_show(:,:,elei));
 %show
figure(547); 
subplot(121);
imagesc(20*log10(nsi_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('nsi iq lowpass');
% 
%ps_iq;
%filter(rf_lp_filt,ps_iq);
ps_env_lp(:,:,elei) = abs(ps_iqlp(:,:,elei));

ps_iq_summed_lp_show(:,:,elei) = ps_env_lp(upper_cut:end-500,:,elei);
ps_iq_summed_lp_show_norm(:,:,elei) = ps_iq_summed_lp_show(:,:,elei)./max(ps_iq_summed_lp_show(:,:,elei));
subplot(122);
imagesc(20*log10(ps_iq_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('normal bmode iq lowpass');

%

cf_env_lp(:,:,elei) = abs(cf_iqlp(:,:,elei));
cf_iq_summed_lp_show(:,:,elei) = cf_env_lp(upper_cut:end-500,:,elei);
cf_iq_summed_lp_show_norm(:,:,elei) = cf_iq_summed_lp_show(:,:,elei)./max(cf_iq_summed_lp_show(:,:,elei));


fcf_env_lp(:,:,elei) = abs(fcf_iqlp(:,:,elei));
fcf_iq_summed_lp_show(:,:,elei) = fcf_env_lp(upper_cut:end-500,:,elei);
fcf_iq_summed_lp_show_norm(:,:,elei) = fcf_iq_summed_lp_show(:,:,elei)./max(fcf_iq_summed_lp_show(:,:,elei));



gcf_env_lp(:,:,elei) = abs(gcf_iqlp(:,:,elei));
gcf_iq_summed_lp_show(:,:,elei) = gcf_env_lp(upper_cut:end-500,:,elei);
gcf_iq_summed_lp_show_norm(:,:,elei) = gcf_iq_summed_lp_show(:,:,elei)./max(gcf_iq_summed_lp_show(:,:,elei));



fgcf_env_lp(:,:,elei) = abs(fgcf_iqlp(:,:,elei));
fgcf_iq_summed_lp_show(:,:,elei) = fgcf_env_lp(upper_cut:end-500,:,elei);
fgcf_iq_summed_lp_show_norm(:,:,elei) = fgcf_iq_summed_lp_show(:,:,elei)./max(fgcf_iq_summed_lp_show(:,:,elei));

nsi_summed_lp_fcf(:,:,elei) = nsi_summed_lp(:,:,elei).*(fcf_weight_ds(:,:,elei));
nsi_summed_lp_fgcf(:,:,elei) = nsi_summed_lp(:,:,elei).*(fgcf_weight_ds(:,:,elei));

figure(558);subplot(121);imagesc(nsi_summed_lp_fcf(:,:,elei));
subplot(122);imagesc(nsi_summed_lp_fgcf(:,:,elei));


figure(548); 
subplot(221);
imagesc(20*log10(cf_iq_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('cf iq lowpass');
% 
subplot(222);
imagesc(20*log10(fcf_iq_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('fcf iq lowpass');

subplot(223);
imagesc(20*log10(gcf_iq_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('gcf iq lowpass');
% 

subplot(224);
imagesc(20*log10(fgcf_iq_summed_lp_show_norm(:,:,elei))); 
colormap gray; caxis([-50 0]);
title('fgcf bmode iq lowpass');





end


%%

file_path = 'E:\issac\chip_point_simu_txt_save29-May-2026';
mat_file_name = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg_size.mat';
txt_file_name = 'RFbatch_5angle_PI_single_step0.05mm_x41.4mm29-May-2026rotated90deg.txt';

txt_file_path = fullfile(file_path, txt_file_name); % Specify your file name;

filename_size = fullfile(file_path, mat_file_name); % Specify your file name;

load(filename_size);

fid = fopen(txt_file_path,'r');
RF_tmp = int16(fread(fid,'double'));

RF_Dim = rf_size;
RFdata= reshape(RF_tmp,RF_Dim);


figure();imagesc(ps_env_lp(:,:,50));

ax_range = 820:850;
%780:840;
ax_len = 1;
max_lower = 10000;

max_ax_loc = [20];

axi = 1;
for buff_depth = 16:1:16
buff_depth
for ei = 1:200
    maxi = 0;
    for elei = 2:256
        max_amp = max(ps_env_lp(ax_range,elei,ei));
        if max_amp > max_lower
            maxi = maxi+1;
            %max_ax_loc(maxi) = find(ps_env_lp(ax_range,elei,ei) == max_amp);
            max_ax_loc(elei) = find(ps_env_lp(ax_range,elei,ei) == max_amp);
        else 
            max_ax_loc(elei) = max_ax_loc(elei-1);
        end
    end
    %if length(max_ax_loc)==1

    %max_ax_loc_mean(ei) = round(mean(max_ax_loc))+min(ax_range);
    max_ax_loc_mean(ei,:) = max_ax_loc+min(ax_range);
    
   %ps_sum(ei,:,axi) = sum(ps_env(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    ps_sum(ei,:,axi) = sum(ps_env_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    nsi01_sum(ei,:,axi) = sum(nsi_summed_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    cf_sum(ei,:,axi) = sum(cf_env_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    gcf_sum(ei,:,axi) = sum(gcf_env_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    fcf_sum(ei,:,axi) = sum(fcf_env_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);
%    fgcf_sum(ei,:,axi) = sum(fgcf_env_lp(max_ax_loc_mean(ei)+buff_depth:max_ax_loc_mean(ei)+buff_depth+ax_len,:,ei),1);

   ps_sum(ei,:,axi) = sum(ps_env_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   nsi01_sum(ei,:,axi) = sum(nsi_summed_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   cf_sum(ei,:,axi) = sum(cf_env_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   gcf_sum(ei,:,axi) = sum(gcf_env_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   fcf_sum(ei,:,axi) = sum(fcf_env_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   fgcf_sum(ei,:,axi) = sum(fgcf_env_lp(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);

   nsi01_fcf_sum(ei,:,axi) = sum(nsi_summed_lp_fcf(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);
   nsi01_fgcf_sum(ei,:,axi) = sum(nsi_summed_lp_fgcf(max_ax_loc_mean(ei,:)+buff_depth:max_ax_loc_mean(ei,:)+buff_depth+ax_len,:,ei),1);


end
lat_range = 25:256-24;
%32:256-31;
%25:256-24;
figure(5);subplot(241);imagesc((ps_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title(buff_depth);%caxis([65 100]);
subplot(242);imagesc((nsi01_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi01');
subplot(243);imagesc((cf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('cf');
subplot(244);imagesc((gcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('gcf');
subplot(245);imagesc((fcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('fcf');

%subplot(246);imagesc(20*log10(fgcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('fgcf');caxis([45 80]);
 subplot(246);imagesc((fgcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('fgcf');

%subplot(247);imagesc(20*log10(nsi01_fcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi fcf');caxis([45 80]);%caxis([20 50]);%caxis([10 3000]);
subplot(247);imagesc((nsi01_fcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi fcf');%caxis([15 50]);%caxis([10 3000]);

%nsi01_fgcf_sum(87:90,143+25:147+25,axi) = 0.6*nsi01_fgcf_sum(87:90,143+25:147+25,axi);
% subplot(248);imagesc(20*log10(nsi01_fgcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi fgcf'); %caxis([45 80]);
%subplot(248);imagesc(20*log10(nsi01_fgcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi fgcf'); caxis([45 80]);
subplot(248);imagesc((nsi01_fgcf_sum(:,lat_range,axi)));colormap gray;title(buff_depth);title('nsi fgcf'); %caxis([45 80]);

%figure(56);imagesc(nsi01_sum(:,lat_range,axi).*cf_sum(:,lat_range,axi));colormap gray;title('nsi01+cf');
pause(0.1);
axi = axi+1;
end


%%

save_map_name = ['E:\dbz\chip_scan\chip_2inch_water_txt_save19-November-2025\beamform'...
     '\RFBFbatch_0angle_fgcf_average_map_0424.mat'];

save(save_map_name,'ps_sum','nsi01_sum','cf_sum','gcf_sum','fcf_sum','fgcf_sum','nsi01_fcf_sum','nsi01_fgcf_sum');


%% cal SNR/CNR

figure();plot(ps_sum(80,lat_range,axi)./max(ps_sum(80,lat_range,axi)));hold on;
plot(nsi01_sum(80,lat_range,axi)./max(nsi01_sum(80,lat_range,axi)));hold on;
plot(cf_sum(80,lat_range,axi)./max(cf_sum(80,lat_range,axi)));hold on;
plot(gcf_sum(80,lat_range,axi)./max(gcf_sum(80,lat_range,axi)));hold on;
plot(fcf_sum(80,lat_range,axi)./max(fcf_sum(80,lat_range,axi)));hold on;
plot(fgcf_sum(80,lat_range,axi)./max(fgcf_sum(80,lat_range,axi)));hold on;
legend('ps','nsi','cf','gcf','fcf','fgcf');

nois_lat = 101:200;
nois_ele = 1:50;

for depth_i = 1:32
ps_sum_snr(depth_i) = max(ps_sum(:,:,depth_i),[],"all")/mean(ps_sum(nois_ele,nois_lat,depth_i),"all");
nsi01_sum_snr(depth_i) = max(nsi01_sum(:,:,depth_i),[],"all")/mean(nsi01_sum(nois_ele,nois_lat,depth_i),"all");
cf_sum_snr(depth_i) = max(cf_sum(:,:,depth_i),[],"all")/mean(cf_sum(nois_ele,nois_lat,depth_i),"all");
gcf_sum_snr(depth_i) = max(gcf_sum(:,:,depth_i),[],"all")/mean(gcf_sum(nois_ele,nois_lat,depth_i),"all");
fcf_sum_snr(depth_i) = max(fcf_sum(:,:,depth_i),[],"all")/mean(fcf_sum(nois_ele,nois_lat,depth_i),"all");
fgcf_sum_snr(depth_i) = max(fgcf_sum(:,:,depth_i),[],"all")/mean(fgcf_sum(nois_ele,nois_lat,depth_i),"all");

end
figure();plot(ps_sum_snr);hold on;
plot(nsi01_sum_snr);hold on;
plot(cf_sum_snr);hold on;
plot(gcf_sum_snr);hold on;
plot(fcf_sum_snr);hold on;
plot(fgcf_sum_snr);hold on;
legend('ps','nsi','cf','gcf','fcf','fgcf');


%%

% ps_iq_ds = vertical_ds_4_average(ps_iq);
% zmlbf_iq_ds = vertical_ds_4_average(zmlbf_iq);
% dcrbf_iq_ds = vertical_ds_4_average(dcrbf_iq);
% dclbf_iq_ds = vertical_ds_4_average(dclbf_iq);

% ps_iq_ds = ps_iq(1:4:end,:,:,:);
% zmlbf_iq_ds = zmlbf_iq(1:4:end,:,:,:);
% dcrbf_iq_ds = dcrbf_iq(1:4:end,:,:,:);
% dclbf_iq_ds = dclbf_iq(1:4:end,:,:,:);

% save_name = ['E:\dbz\chip_scan\chip_s2_water_txt_save19-November-2025'...
%     '\RFBFbatch_5angle_cdw_single_step0.05mm_x41.4mm19-November-2025_ax4lat2_degree',num2str(angle),'_fnum3_ds.mat'];
% 
%% comapre raw rf
 ei = 805;
 %790;
 %805;
 defect_rf = RFdata(3*(ai-1)*frame_length+1:3*(ai-1)*frame_length+frame_length,:,ei);
ei = 800;
%810;
defect_no_rf = RFdata(3*(ai-1)*frame_length+1:3*(ai-1)*frame_length+frame_length,:,ei);
rf_diff = defect_rf- defect_no_rf;
figure();subplot(131);imagesc(defect_rf);subplot(132);imagesc(defect_no_rf);subplot(133);imagesc(rf_diff);

figure(532);subplot(131);imagesc(abs(fftshift(fft2(defect_rf(201:1224,:)))));
subplot(132);imagesc(abs(fftshift(fft2(defect_no_rf(201:1224,:)))));
subplot(133);imagesc(abs(fftshift(fft2(rf_diff(201:1224,:)))));