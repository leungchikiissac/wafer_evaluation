% function saveRF_dbz(varargin)
function saveRF_issac_txt(varargin)
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
disp('saveRF_issac_txt: start');
runningVSX = ~isempty(findobj('tag','UI'));
fprintf('saveRF_issac_txt: runningVSX = %d\n', runningVSX);
if runningVSX % running VSX
    freezeVal = evalin('base','freeze');
    fprintf('saveRF_issac_txt: freeze = %d\n', freezeVal);
    if freezeVal==0   % no action if not in freeze
        disp('saveRF_issac_txt: VSX not frozen — aborting. Press Freeze first.');
        msgbox('Please freeze VSX');
        return
    else
        disp('saveRF_issac_txt: calling copyBuffers...');
        Control.Command = 'copyBuffers';
        runAcq(Control); % NOTE:  If runAcq() has an error, it reports it then exits MATLAB.
        disp('saveRF_issac_txt: copyBuffers done, fetching RcvData from base...');
        % copyBuffers/runAcq may need an event-queue flush before RcvData
        % lands in base — retry briefly instead of failing immediately.
        RcvData = [];
        for attempt = 1:20
            if evalin('base','exist(''RcvData'',''var'')')
                RcvData = evalin('base','RcvData');
                break
            end
            fprintf('saveRF_issac_txt: RcvData not ready yet (attempt %d), waiting...\n', attempt);
            drawnow;
            pause(0.25);
        end
        if isempty(RcvData)
            disp('saveRF_issac_txt: RcvData never appeared in base — aborting.');
            return
        end
    end
else % not running VSX
    disp('saveRF_issac_txt: not running VSX, checking for RcvData in base...');
    if evalin('base','exist(''RcvData'',''var'');')
        RcvData = evalin('base','RcvData');
    else
        disp('saveRF_issac_txt: RcvData does not exist! Aborting.');
        return
    end
end
fprintf('saveRF_issac_txt: RcvData{2} class=%s size=%s\n', ...
        class(RcvData{2}), mat2str(size(RcvData{2})));
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
fprintf('saveRF_issac_txt: target folder = %s (exists=%d)\n', filepath, isfolder(filepath));
if ~isfolder(filepath)
    mkdir(filepath);
end
RFfilename = [filepath,'RFbatch_5angle_PI_single_step0.05mm_x41.4mm_',lateralTag,'_',datestr(now,'dd-mmmm-yyyy'), 'rotated90deg'];
%RFfilename = [filepath,'RFbatch_5angle_cdw_single_simupoints',datestr(now,'dd-mmmm-yyyy')];
%multiangle
save_RFfilename = [RFfilename,'.txt'];
fprintf('saveRF_issac_txt: writing RF data to %s\n', save_RFfilename);

fid = fopen(save_RFfilename,'w');
if fid == -1
    error('saveRF_issac_txt:openFailed', 'Could not open file for writing: %s', save_RFfilename);
end
nWritten = fwrite(fid,RcvData{2},'double');
fclose(fid);
fprintf('saveRF_issac_txt: wrote %d elements to %s\n', nWritten, save_RFfilename);

rf_size = size(RcvData{2});
save_RFfilename_size = [RFfilename,'_size.mat'];
fprintf('saveRF_issac_txt: writing size file to %s\n', save_RFfilename_size);
save(save_RFfilename_size,'rf_size');

% Save all base workspace variables (sequence params, stage position, etc.)
save_workspace_filename = [RFfilename,'_workspace.mat'];
fprintf('saveRF_issac_txt: writing workspace file to %s\n', save_workspace_filename);
evalin('base', sprintf("save('%s')", strrep(save_workspace_filename,'\','/')));

fprintf('saveRF_issac_txt: done. Saved RF data, size file, and workspace to:\n  %s\n', filepath);
fprintf('saveRF_issac_txt: base name: %s\n', RFfilename);

toc
end
