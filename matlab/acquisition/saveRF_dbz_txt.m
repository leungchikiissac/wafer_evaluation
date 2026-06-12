% function saveRF_dbz(varargin)
function saveRF_dbz_txt(varargin)
tic
% Copyright 2001-2017 Verasonics, Inc.  All world-wide rights and remedies under all intellectual property laws and industrial property laws are reserved.  Verasonics Registered U.S. Patent and Trademark Office.
%
% Notice:
%   This file is provided by Verasonics to end users as a programming
%   tool for the Verasonics Vantage Research Ultrasound System.
%   Verasonics makes no claims as to the functionality or intended
%   application of this program and the user assumes all responsibility
%   for its use
%
% File name: saveRF.m - A tool to save RF
%
%linear_dis = evalin('base','linear_dis');
if ~isempty(findobj('tag','UI')) % running VSX
    if evalin('base','freeze')==0   % no action if not in freeze
        msgbox('Please freeze VSX');
        return
    else
        Control.Command = 'copyBuffers';
        runAcq(Control); % NOTE:  If runAcq() has an error, it reports it then exits MATLAB.
        RcvData = evalin('base','RcvData');
    end
else % not running VSX
    if evalin('base','exist(''RcvData'',''var'');')
        RcvData = evalin('base','RcvData');
    else
        disp('RcvData does not exist!');
        return
    end
end
%% change name here
% Sweep start lateral distance (mm), set by ScanControlPanel before each
% VSX launch. Defaults to 0.0 if not present (e.g. running standalone).
try
    sweepLateralY_mm = evalin('base','sweepLateralY_mm');
catch
    sweepLateralY_mm = 0.0;
end
lateralTag = sprintf('%.1fmm', sweepLateralY_mm);

%RFfilename = ['RF_',datestr(now,'dd-mmmm-yyyy_HH-MM-SS')];
filepath = ['E:\issac\chip_point_simu_txt_save',datestr(now,'dd-mmmm-yyyy'),'\'];
if ~isfolder(filepath)
    mkdir(filepath);
end
RFfilename = [filepath,'RFbatch_5angle_PI_single_step0.05mm_x41.4mm_',lateralTag,'_',datestr(now,'dd-mmmm-yyyy'), 'rotated90deg'];
%RFfilename = [filepath,'RFbatch_5angle_cdw_single_simupoints',datestr(now,'dd-mmmm-yyyy')];
%multiangle
save_RFfilename = [RFfilename,'.txt'];

fid = fopen(save_RFfilename,'w');
if fid == -1
    error('saveRF_dbz_txt:openFailed', 'Could not open file for writing: %s', save_RFfilename);
end
fwrite(fid,RcvData{2},'double');
fclose(fid);

rf_size = size(RcvData{2});
save_RFfilename_size = [RFfilename,'_size.mat'];
save(save_RFfilename_size,'rf_size');

% Save all base workspace variables (sequence params, stage position, etc.)
save_workspace_filename = [RFfilename,'_workspace.mat'];
evalin('base', sprintf("save('%s')", strrep(save_workspace_filename,'\','/')));

fprintf('Saved RF data, size file, and workspace to:\n  %s\n', filepath);
fprintf('  (base name: %s)\n', RFfilename);

toc
end
