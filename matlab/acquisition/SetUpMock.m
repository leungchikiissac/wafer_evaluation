% SetUpMock.m
% Hardware-free stand-in for SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m,
% used by ScanControlPanel when TESTING = true.
%
% Skips Vantage/VDAS init and the FMC4030 DLL entirely. Connects (or
% reuses) a MockStageController, fabricates a small RcvData{2} array, and
% calls saveRF_wafer_txt so the filename/workspace-saving logic gets
% exercised exactly as in a real run — but in seconds instead of ~50s.

% Preserve variables set by ScanControlPanel before this script runs.
% autoScanMode is set by onAutoScan; sweepLateralY_mm/guiLog/stage by all callers.
clearvars -except sweepLateralY_mm guiLog stage autoScanMode

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

% ── Fabricate 3D RF data: [n_samples x n_elem x n_acq] ──────────────────
% Shape matches real data so cscan_surface_guided_fn can process it.
% Surface reflection added at sample ~100 so find_surface_rfdata detects it.
n_samples = 256; n_elem = 16; n_acq = 5;
mockRF = int16(randi([-100 100], n_samples, n_elem, n_acq));
surf_win = 95:105;
surf_pulse = int16(1500 * sin(linspace(0, pi, numel(surf_win)))');
mockRF(surf_win, :, :) = repmat(surf_pulse, 1, n_elem, n_acq);
RcvData = cell(1, 2);
RcvData{2} = mockRF;

if exist('guiLog', 'var')
    guiLog('SetUpMock: RcvData generated, saving...');
end

% ── Save RF data + workspace, with lateral-position filename tag ────────
saveRF_wafer_txt();

if exist('guiLog', 'var')
    guiLog('SetUpMock: done.');
end
