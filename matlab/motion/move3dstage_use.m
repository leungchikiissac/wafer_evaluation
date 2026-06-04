% move3dstage_use.m  — standalone usage example for the motion stage
%
% Demonstrates loading the FMC4030 DLL, creating StageController,
% performing moves, and cleaning up.
%
% This script is for manual testing outside of the Verasonics VSX engine.
clear all

% make sure library is unload for safety reason
if libisloaded('FMC40300x2DDll')
    unloadlibrary('FMC40300x2DDll')
end

addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'motion'))

%% 1. Load DLL
dll_path = 'FMC4030-Dll.dll';
hdr_path = 'FMC4030-DLL.h';

if ~libisloaded('FMC40300x2DDll')
    loadlibrary(dll_path, hdr_path)
end

if ~libisloaded('FMC40300x2DDll')
    error('Failed to load FMC4030 DLL');
end

%% 2. Connect via StageController
stage = StageController();
stage.connect();

%% 3. Print initial position
stage.printPosition();

%% 4 & 5. Reposition probe to next sweep lane
repositionProbe(stage);


%% 6. Cleanup
stage.disconnect();
calllib('FMC40300x2DDll', 'FMC4030_Close_Device', stage.DEVICE_INDEX)
unloadlibrary('FMC40300x2DDll')
fprintf('Done.\n');
