%load E:\dbz\chip_scan\chip_2inch_water_txt_save18-December-2025\matlab_workspace.mat
%E:\dbz\chip_scan\chip_s2_water_txt_save19-November-2025\matlab_workspace.mat
clearvars
addpath('E:\dbz\chip_scan\');
load E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026\matlab_workspace.mat
%E:\dbz\chip_scan\chip_2inch_water_txt_save19-November-2025\matlab_workspace.mat

%%
xloc = 0:6.9:41.4;
%0:6.9:48.3; 
%
%xloc = 41.4;
for xi = 3:1:7 %7:7 

    xi
tic
% filename_read = ['E:\dbz\chip_2inch_water_txt_save30-August-2025' ...
%     '\RFbatch_angle_0_step0.1mm_x',num2str(xloc(xi)),'mm30-August-2025.txt']; % Specify your file name
%matrix = readmatrix(filename_read);
% filename_read = ['E:\dbz\chip_scan\chip_2inch_water_txt_save19-November-2025' ...
%     '\RFbatch_5angle_cdw_single_step0.05mm_x',num2str(xloc(xi)),'mm19-November-2025.txt']; % Specify your file name
filename_read = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026' ...
    '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm15-May-2026.txt']; % Specify your file name



% filename_read = ['E:\dbz\chip_scan\chip_2inch_water_txt_save20-January-2026' ...
%    '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm20-January-2026.txt']; % Specify your file name

fid = fopen(filename_read,'r');
RF_tmp = int16(fread(fid,'double'));
% filename_size = ['E:\dbz\chip_2inch_water_txt_save30-August-2025' ...
%     '\RFbatch_angle_0_step0.1mm_x',num2str(xloc(xi)),'mm30-August-2025_size.mat']; % Specify your file name;

% filename_size = ['E:\dbz\chip_scan\chip_2inch_water_txt_save19-November-2025' ...
%     '\RFbatch_5angle_cdw_single_step0.05mm_x',num2str(xloc(xi)),'mm19-November-2025_size.mat'];

filename_size = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026' ...
    '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm15-May-2026_size.mat'];
% filename_size = ['E:\dbz\chip_scan\chip_2inch_water_txt_save20-January-2026' ...
%     '\RFbatch_5angle_PI_single_step0.05mm_x',num2str(xloc(xi)),'mm20-January-2026_size.mat']; % Specify your file name;


load(filename_size);
%D:\data\dbz\chip_H_txt_save06-May-2025\RFbatch_multiangle_-30_24.9_step0.1mm_chipx20mm06-May-2025_size.mat
RF_Dim = rf_size;
RFdata= reshape(RF_tmp,RF_Dim);
fclose(fid);
toc

ele_loc_num = RF_Dim(3);
%RFdata_frame = double(RFdata(:,:,60));
%%
frame_length = Receive.endSample;
f0 = 29.411764705882350e6;
fs = 117.6470588235294e6;
f_clock = 500e6;

angles = 0;
%-6:3:6;
for ai = 1:1

%ai = 3; % 0 degree
angle = angles(ai);
dc = 1; %dc - 0.1 for original, dc = 1 for fgcf
fNum = 3;
trans_pitch = Trans.spacingMm*1e-3;

%o_len = 18;
% beamform

depth = 2048;
ele = 128;
angle_val = 0;
ul = 1;
%ua = 4;
ua = 1;



%bf_params = precompute_bf_geometry(depth, ele, trans_pitch, fs, angle_val, dc, fNum, ul, ua);
bf_params = precompute_bf_geometry_hann(depth, ele*2, trans_pitch/2, fs, angle_val, dc, fNum, ul, ua);
%precompute_bf_geometry_gpu(depth, ele, trans_pitch, fs, angle_val, dc, fNum, ul, ua);

% for ei = 158:1200
for ei = 1:1200
    %601:800

    %1:ele_loc_num
    %                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               .
    xi
    ai
    ei
    rf_0angle(:,:) = RFdata(3*(ai-1)*frame_length+1:3*(ai-1)*frame_length+frame_length,:,ei);
    rf_0angle_cut = double(rf_0angle(1:depth,:));
%     [ps_iqlp(:,:,ai,ei), dclbf_iqlp(:,:,ai,ei),dcrbf_iqlp(:,:,ai,ei),zmlbf_iqlp(:,:,ai,ei)] = bf_nsi_interp_dbz_iq_tune_nxt_L38_22(double(rf_0angle(:,:,ei)),trans_pitch,fs, angle, dc,fNum);
%[ps_iq(:,:), dclbf_iq(:,:),dcrbf_iq(:,:),zmlbf_iq(:,:)] = bf_multi_interp_dbz_iq_nxt_L38_22(double(rf_0angle(:,:)),trans_pitch,fs, angle, dc,fNum);
%%
%[ps_iq, dclbf_iq,dcrbf_iq,zmlbf_iq,dmas_iq,cf_iq,gcf_iq,scf_iq]= bf_multi_interp_dbz_iq_nxt_L38_22(double(rf_0angle(:,:)),trans_pitch,fs, angle, 1,fNum);

%[~, dclbf_iq01,dcrbf_iq01,zmlbf_iq01,~,~,~,~]= bf_multi_interp_dbz_iq_nxt_L38_22(double(rf_0angle(:,:)),trans_pitch,fs, angle, 0.1,fNum);


%[ps_data, dclbf,dcrbf,zmlbf,fcf_data,cf_data,gcf_data, fgcf_data]= bf_fgcf_interp_nxt_L38_22_0329(double(rf_0angle_cut(:,:)),trans_pitch,fs, angle, 1,fNum);



%[ps_data, dclbf,dcrbf,zmlbf,fcf_data,cf_data,gcf_data, fgcf_data, fcf_weight, fgcf_weight,dclbf01,dcrbf01,zmlbf01]= bf_fgcf_interp_nxt_L38_22_0406(double(rf_0angle_cut(:,:)),trans_pitch,fs, angle, 1,fNum);
        
    [xo,yo] = meshgrid(1:128,1:depth);
    [xii,yii] = meshgrid(1:0.5:128.5,1:depth);

    rf_0angle_cut_interp = interp2(xo,yo,rf_0angle_cut,xii,yii);

    
    % 执行极速版波束合成
   tic
[ps_data, dclbf, dcrbf, zmlbf, spectral_cf_weighted_data, ...
     cf_weighted_data, gcf_weighted_data, spectral_gcf_weighted_data, ...
     spectral_cf_weight, spectral_gcf_weight, dclbf01, dcrbf01, zmlbf01] = ...
     bf_fgcf_fast_execute(rf_0angle_cut_interp, bf_params, fs, ul, ua);
%bf_fgcf_fast_execute_GPU(double(rf_0angle_cut(:,:)), bf_params, fs, ul, ua);
toc
%          bf_fgcf_fast_execute(double(rf_0angle_cut(:,:)), bf_params, fs, ul, ua);


%%
%bf_rf_latup_nsi_interp_dbz_iq_tune_nxt_L38_22_window_test(double(rf_0angle(1001:2000,:,ei)),trans_pitch,fs, angle, dc,fNum);

%bf_nsi_interp_dbz_iq_tune_nxt_L38_22(double(rf_0angle(:,:,ei)),trans_pitch,fs, angle, dc,fNum);
st_fm = 0;

downsample = 1;

if downsample == 1
ps_data_ds(:,:,ei-st_fm) = single(ps_data(1:ua:end,:));
zmlbf_ds(:,:,ei-st_fm) = single(zmlbf(1:ua:end,:));
dcrbf_ds(:,:,ei-st_fm) = single(dcrbf(1:ua:end,:));
dclbf_ds(:,:,ei-st_fm) = single(dclbf(1:ua:end,:));

zmlbf01_ds(:,:,ei-st_fm) = single(zmlbf01(1:ua:end,:));
dcrbf01_ds(:,:,ei-st_fm) = single(dcrbf01(1:ua:end,:));
dclbf01_ds(:,:,ei-st_fm) = single(dclbf01(1:ua:end,:));
%dmas_iq_ds(:,:,ei-st_fm) = dmas_iq(1:4:end,:);
fcf_ds(:,:,ei-st_fm) = single(spectral_cf_weighted_data(1:ua:end,:));
cf_ds(:,:,ei-st_fm) = single(cf_weighted_data(1:ua:end,:));
gcf_ds(:,:,ei-st_fm) = single(gcf_weighted_data(1:ua:end,:));
fgcf_ds(:,:,ei-st_fm) = single(spectral_gcf_weighted_data(1:ua:end,:));

fcf_weight_ds(:,:,ei-st_fm) = single(spectral_cf_weight(1:ua:end,:));
fgcf_weight_ds(:,:,ei-st_fm) = single(spectral_gcf_weight(1:ua:end,:));

elseif downsample ==0
    ps_data_ds(:,:,ei-st_fm) = ps_data(1:end,:);
zmlbf_ds(:,:,ei-st_fm) = zmlbf(1:end,:);
dcrbf_ds(:,:,ei-st_fm) = dcrbf(1:end,:);
dclbf_ds(:,:,ei-st_fm) = dclbf(1:end,:);
%dmas_iq_ds(:,:,ei-st_fm) = dmas_iq(1:4:end,:);
fcf_ds(:,:,ei-st_fm) = fcf_data(1:end,:);
cf_ds(:,:,ei-st_fm) = cf_data(1:end,:);
gcf_ds(:,:,ei-st_fm) = gcf_data(1:end,:);
fgcf_ds(:,:,ei-st_fm) = fgcf_data(1:end,:);
end


% ps_iq_ds(:,:,ei-st_fm) = ps_iq(1:4:end,:);
% zmlbf_iq_ds(:,:,ei-st_fm) = zmlbf_iq(1:4:end,:);
% dcrbf_iq_ds(:,:,ei-st_fm) = dcrbf_iq(1:4:end,:);
% dclbf_iq_ds(:,:,ei-st_fm) = dclbf_iq(1:4:end,:);
% %dmas_iq_ds(:,:,ei-st_fm) = dmas_iq(1:4:end,:);
% fcf_iq_ds(:,:,ei-st_fm) = fcf_iq(1:4:end,:);
% cf_iq_ds(:,:,ei-st_fm) = cf_iq(1:4:end,:);
% gcf_iq_ds(:,:,ei-st_fm) = gcf_iq(1:4:end,:);
% scf_iq_ds(:,:,ei-st_fm) = scf_iq(1:4:end,:);

% zmlbf01_iq_ds(:,:,ei-st_fm) = zmlbf_iq01(1:4:end,:);
% dcrbf01_iq_ds(:,:,ei-st_fm) = dcrbf_iq01(1:4:end,:);
% dclbf01_iq_ds(:,:,ei-st_fm) = dclbf_iq01(1:4:end,:);

% rf_0angle_pi1(:,:,ei) = RFdata(3*(ai-1)*frame_length+1+frame_length:3*(ai-1)*frame_length+2*frame_length,:,ei);
% rf_0angle_pi2(:,:,ei) = RFdata(3*(ai-1)*frame_length+1+2*frame_length:3*ai*frame_length,:,ei);
% %cdw_decode_rf = cdw_decode_dbz(rf_0angle_cdw1(:,:,ei)', rf_0angle_cdw2(:,:,ei)',o_len)';
% pi_decode_rf = rf_0angle_pi1(:,:,ei)+rf_0angle_pi2(:,:,ei);
% [ps_iq_pi(:,:), dclbf_iq_pi(:,:),dcrbf_iq_pi(:,:),zmlbf_iq_pi(:,:)] = bf_nsi_interp_dbz_iq_tune_nxt_L38_22(double(pi_decode_rf),trans_pitch,fs, angle, dc,fNum);
% 
% 
% ps_iq_pi_ds(:,:,ai,ei) = ps_iq_pi(1:4:end,:);
% zmlbf_iq_pi_ds(:,:,ai,ei) = zmlbf_iq_pi(1:4:end,:);
% dcrbf_iq_pi_ds(:,:,ai,ei) = dcrbf_iq_pi(1:4:end,:);
% dclbf_iq_pi_ds(:,:,ai,ei) = dclbf_iq_pi(1:4:end,:);
    %figure(34);imagesc(rf_0angle(1:end,:,ei));title(ei);
end

% save_name = ['E:\dbz\chip_scan\chip_s2_water_txt_save19-November-2025'...
%     '\RFBFbatch_5angle_cdw_single_step0.05mm_x41.4mm19-November-2025_ax4lat2_degree',num2str(angle),'_fnum3.mat'];
% 
% save(save_name,"ps_iq","zmlbf_iq","dcrbf_iq","dclbf_iq");

save_name = ['E:\dbz\chip_scan\chip_4inch_0angle_txt_save15-May-2026\beamform'...
    '\RFBFbatch_multi_fgcf_nsi_single_step0.05mm_x',num2str(xloc(xi)),'mm_angle',num2str(ai),'_0619_dc_both_ele_1_745_newinterp_lat2ax1_tukey.mat'];
%save(save_name,"ps_iq_ds","zmlbf_iq_ds","dcrbf_iq_ds","dclbf_iq_ds",'dmas_iq_ds','cf_iq_ds','gcf_iq_ds',"scf_iq_ds",'zmlbf01_iq_ds',"dcrbf01_iq_ds","dclbf01_iq_ds");
%save(save_name,"ps_iq_ds","zmlbf_iq_ds","dcrbf_iq_ds","dclbf_iq_ds", "ps_iq_pi_ds","zmlbf_iq_pi_ds","dcrbf_iq_pi_ds","dclbf_iq_pi_ds");
save(save_name,"ps_data_ds","zmlbf_ds","dcrbf_ds","dclbf_ds",'fcf_ds','cf_ds','gcf_ds',"fgcf_ds",'downsample','dc',"fcf_weight_ds","fgcf_weight_ds",'zmlbf01_ds','dclbf01_ds','dcrbf01_ds');


end
end