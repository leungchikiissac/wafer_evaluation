% SetUpMock.m
% Hardware-free stand-in for SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m,
% used by ScanControlPanel when TESTING = true.
%
% Skips Vantage/VDAS init and the FMC4030 DLL entirely. Connects (or
% reuses) a MockStageController, fabricates a small RcvData{2} array, and
% calls saveRF_wafer_txt so the filename/workspace-saving logic gets
% exercised exactly as in a real run — but in seconds instead of ~50s.

% Preserve variables set by ScanControlPanel before this script runs
% (sweepLateralY_mm is used by saveRF_wafer_txt.m to tag the RF filename).
clearvars -except sweepLateralY_mm guiLog stage

if exist('guiLog', 'var')
    guiLog('SetUpMock: starting (no hardware)...');
end

% ── Stage: reuse if already connected, else mock-connect ────────────────
if ~exist('stage', 'var') || isempty(stage)
    stage = MockStageController();
    stage.connect();
end

% ── Simulate acquisition time ────────────────────────────────────────────
pause(1);

% ── Fabricate RF data of a plausible (small) shape ───────────────────────
RcvData = cell(1, 2);
RcvData{2} = int16(randi([-1000 1000], 1024, 64));

if exist('guiLog', 'var')
    guiLog('SetUpMock: RcvData generated, saving...');
end

% ── Save RF data + workspace, with lateral-position filename tag ────────
saveRF_wafer_txt();

if exist('guiLog', 'var')
    guiLog('SetUpMock: done.');
end
