function fig = ScanControlPanel(testing)
% ScanControlPanel  Multi-sweep orchestration GUI.
%
%   Workflow (manual):
%     1. Press "Launch VSX"  — runs SetUp script, opens Verasonics VSX window
%     2. Press "Move Batch"  — in the VSX window (sweeps X 60 mm, saves RF)
%     3. Press "Reposition"  — moves X back 60 mm + Y forward 6.9 mm
%     4. Repeat steps 2-3 for each of the 6 sweep lanes
%
%   Workflow (automated):
%     1. Press "Auto Scan"   — launches VSX for each lane automatically,
%        runs C-scan after each SaveRF, repositions between lanes.
%        VSX auto-starts the batch sequence; user only needs to press
%        SaveRF then close VSX per lane. Press "Stop" to abort between lanes.
%
%   The stage object is shared with VSX via the base workspace ('stage').
%
%   ScanControlPanel(testing) — pass true to force TESTING mode
%   (MockStageController + SetUpMock.m, no hardware), overriding the
%   TESTING constant below. Used by automated tests. Returns the figure
%   handle.

% Set TESTING = true to run the GUI workflow with no hardware attached:
% uses MockStageController and SetUpMock.m (instant moves, ~1s fake
% acquisition) instead of the real stage DLL and ~50s VSX sequence.
TESTING = false;
if nargin > 0
    TESTING = testing;
end

% Set DEBUG_SAVERF = true to use the DEBUG SetUp script (1 mm sweep,
% mock stage, real VDAS acquisition) without changing any GUI controls.
DEBUG_SAVERF = false;

TOTAL_SWEEPS  = 6;
X_STEPS       = 600;   % steps to return X to start (600 x -0.1 mm = -60 mm)
Y_STEPS       =  69;   % steps to advance to next lane (69 x 0.1 mm = 6.9 mm)

% ── Find SetUp scripts relative to this file ─────────────────────────────
here = fileparts(mfilename('fullpath'));
if TESTING
    setup_script = fullfile(here, '..', 'acquisition', 'SetUpMock.m');
elseif DEBUG_SAVERF
    setup_script = fullfile(here, '..', 'acquisition', ...
        'SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120_DEBUG.m');
else
    setup_script = fullfile(here, '..', 'acquisition', ...
        'SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m');
end
assert(isfile(setup_script), 'SetUp script not found: %s', setup_script);

% ── DeepSonix palette (MATLAB [R G B] equivalents of hex tokens) ─────────
C.bg_win   = [0.039 0.094 0.188];   % #0a1830  main background
C.bg_panel = [0.067 0.125 0.251];   % #112040  panel / button fill
C.bg_input = [0.059 0.118 0.220];   % #0f1e38  input fields
C.toolbar  = [0.027 0.067 0.122];   % #07111f  log area
C.cyan     = [0.000 0.784 0.941];   % #00c8f0  brand accent
C.amber    = [0.961 0.612 0.102];   % #f59c1a  headings / section titles
C.green    = [0.122 0.749 0.459];   % #1fbf75  start / success
C.red      = [0.898 0.282 0.302];   % #e5484d  stop / error
C.text     = [1.000 1.000 1.000];   % #ffffff  primary text
C.muted    = [0.624 0.698 0.800];   % #9fb2cc  secondary text / labels
C.border   = [0.133 0.216 0.361];   % #22375c  dividers

% Dark tinted fills behind coloured buttons (same role as Python panel)
BG_GREEN  = [0.020 0.110 0.055];   % dark green fill
BG_RED    = [0.180 0.050 0.050];   % dark red fill
BG_AMBER  = [0.150 0.100 0.020];   % dark amber fill

% ── Build figure ──────────────────────────────────────────────────────────
old = findall(groot, 'Type', 'figure', 'Tag', 'ScanControlPanel');
if ~isempty(old)
    delete(old);
end

fig = uifigure('Name', 'DeepSonix — Scan Control Panel', ...
               'Position', [100 100 620 650], ...
               'Tag', 'ScanControlPanel', ...
               'Color', C.bg_win, ...
               'Resize', 'off');

% Title
uilabel(fig, 'Text', 'Scan Control Panel', ...
        'Position', [10 605 320 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'FontColor', C.amber, ...
        'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

% ── Sweep progress ────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Sweep progress:', ...
        'Position', [20 565 120 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hProgress = uilabel(fig, 'Text', sprintf('0 / %d', TOTAL_SWEEPS), ...
        'Position', [145 565 170 22], ...
        'FontSize', 13, 'FontColor', C.cyan, ...
        'BackgroundColor', C.bg_win);

% ── Position display ──────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Stage position:', ...
        'Position', [20 530 120 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 508 300 22], 'FontSize', 11, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_win);

% ── Status ────────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Status:', ...
        'Position', [20 475 60 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hStatus = uilabel(fig, 'Text', 'Not started', ...
        'Position', [85 475 235 22], ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_win);

% Divider
uipanel(fig, 'Position', [15 465 310 2], ...
        'BackgroundColor', C.border, 'BorderType', 'none');

% ── Scan mode selector ────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Scan mode:', ...
        'Position', [20 443 80 18], 'FontSize', 10, 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hScanMode = uidropdown(fig, ...
        'Items', {'Raster  (return X, same direction)', 'Snake  (alternate direction, Y step only)'}, ...
        'Position', [103 440 217 22], ...
        'Value', 'Raster  (return X, same direction)', ...
        'FontSize', 10, ...
        'BackgroundColor', C.bg_input, ...
        'FontColor', C.text);

% ── Auto Scan button ──────────────────────────────────────────────────────
hAuto = uibutton(fig, 'Text', 'Auto Scan (all lanes)', ...
        'Position', [20 390 218 40], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_AMBER, 'FontColor', C.amber, ...
        'ButtonPushedFcn', @(~,~) onAutoScan());

% ── Stop Auto Scan button ─────────────────────────────────────────────────
hStop = uibutton(fig, 'Text', 'Stop', ...
        'Position', [243 390 77 40], ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_RED, 'FontColor', C.red, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onStop());

% ── Launch VSX button ─────────────────────────────────────────────────────
hLaunch = uibutton(fig, 'Text', 'Launch VSX', ...
        'Position', [20 330 300 40], ...
        'FontSize', 14, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_GREEN, 'FontColor', C.green, ...
        'ButtonPushedFcn', @(~,~) onLaunchVSX());

% ── Reposition button ─────────────────────────────────────────────────────
hRepos = uibutton(fig, 'Text', 'Reposition Probe → next lane', ...
        'Position', [20 270 300 40], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.cyan, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onReposition());

% ── Hint label ───────────────────────────────────────────────────────────
uilabel(fig, ...
        'Text', '← Close VSX first, then Reposition, then relaunch VSX', ...
        'Position', [20 248 300 22], 'FontSize', 10, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_win);

% ── Finish / reset button ─────────────────────────────────────────────────
hFinish = uibutton(fig, 'Text', 'Reset / Relaunch VSX', ...
        'Position', [20 200 140 35], ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.muted, ...
        'Enable', 'on', ...
        'ButtonPushedFcn', @(~,~) onReset());

hDisconnect = uibutton(fig, 'Text', 'Disconnect Stage', ...
        'Position', [180 200 140 35], ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.red, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onDisconnect());

% ── Debug log ─────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Log:', ...
        'Position', [20 178 60 18], 'FontWeight', 'bold', 'FontSize', 10, ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hLog = uitextarea(fig, ...
        'Position', [20 20 300 155], ...
        'Editable', 'off', ...
        'FontSize', 9, ...
        'BackgroundColor', C.toolbar, ...
        'FontColor', C.muted, ...
        'Value', {''});

% ── Stage Jog Panel (right column) ─────────────────────────────────────────
uilabel(fig, 'Text', 'Stage Jog', ...
        'Position', [360 575 240 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'FontColor', C.amber, ...
        'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

uilabel(fig, 'Text', 'Step (mm):', ...
        'Position', [360 535 80 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hStep = uieditfield(fig, 'numeric', ...
        'Position', [445 535 80 22], ...
        'Value', 1, ...
        'Limits', [0 100], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f', ...
        'BackgroundColor', C.bg_input, ...
        'FontColor', C.text);

jogBtnSize = 50;
jcx = 470; jcy = 380;

hJogUp = uibutton(fig, 'Text', char(9650), ...   % ▲  -X
        'Position', [jcx-jogBtnSize/2, jcy+jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hJogDown = uibutton(fig, 'Text', char(9660), ... % ▼  +X
        'Position', [jcx-jogBtnSize/2, jcy-jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hJogLeft = uibutton(fig, 'Text', char(9664), ... % ◄  -Y
        'Position', [jcx-jogBtnSize-jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hJogRight = uibutton(fig, 'Text', char(9654), ... % ►  +Y
        'Position', [jcx+jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

jogButtons = [hJogUp hJogDown hJogLeft hJogRight];

hJogStatus = uilabel(fig, 'Text', 'Jog disabled until stage is initialized (Launch VSX).', ...
        'Position', [360 290 240 22], ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

% ── State ─────────────────────────────────────────────────────────────────
sweepsDone = 0;

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onLaunchVSX()
        lockAll();
        if DEBUG_SAVERF
            addLog('--- Launch VSX pressed [DEBUG SaveRF mode] ---');
            setStatus('[DEBUG] VSX running — GUI unlocks when you close VSX.', C.amber);
        else
            addLog('--- Launch VSX pressed ---');
            setStatus('VSX running — GUI unlocks when you close VSX.', C.amber);
        end
        drawnow;

        try
            runOneSweep(false);

            if ~isvalid(fig); return; end
            updatePosition();
            sweepsDone = sweepsDone + 1;
            hProgress.Text = sprintf('%d / %d', sweepsDone, TOTAL_SWEEPS);
            addLog(sprintf('Sweep %d / %d acquired.', sweepsDone, TOTAL_SWEEPS));

            if sweepsDone >= TOTAL_SWEEPS
                setStatus('All sweeps acquired! Disconnect stage when finished.', C.green);
                hRepos.Enable      = 'off';
                hLaunch.Enable     = 'off';
                hFinish.Enable     = 'on';
                hDisconnect.Enable = 'on';
            else
                setStatus(sprintf('Sweep %d done. Reposition for next lane.', ...
                          sweepsDone), C.green);
                hRepos.Enable      = 'on';
                hFinish.Enable     = 'on';
                hDisconnect.Enable = 'on';
            end

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                setStatus(['Launch failed: ' ex.message], C.red);
                hLaunch.Enable = 'on';
                hAuto.Enable   = 'on';
                hFinish.Enable = 'on';
            end
        end
    end

    function onReposition()
        lockAll();
        setStatus('Moving stage — please wait...', C.amber);
        drawnow;

        try
            doReposition();
            setStatus(sprintf('Repositioned. Press Launch VSX for sweep %d.', ...
                      sweepsDone + 1), C.green);
            hRepos.Enable  = 'off';
            hLaunch.Enable = 'on';
            hAuto.Enable   = 'on';
            hFinish.Enable = 'on';

        catch ex
            setStatus(['Reposition failed: ' ex.message], C.red);
            hRepos.Enable = 'on';
            hAuto.Enable  = 'on';
        end
    end

    function onAutoScan()
        assignin('base', 'autoScanAbort', false);
        lockAll();
        hStop.Enable = 'on';
        setStatus(sprintf('Auto Scan: lane %d/%d — launching VSX...', ...
                  sweepsDone + 1, TOTAL_SWEEPS), C.cyan);
        addLog('=== Auto Scan started ===');
        drawnow;

        aborted = false;
        try
            for lane = (sweepsDone + 1) : TOTAL_SWEEPS
                if ~isvalid(fig); return; end

                try; aborted = evalin('base', 'autoScanAbort'); catch; aborted = false; end
                if aborted; break; end

                addLog(sprintf('--- Auto Scan: lane %d/%d ---', lane, TOTAL_SWEEPS));
                setStatus(sprintf('Auto Scan: lane %d/%d — VSX running...', ...
                          lane, TOTAL_SWEEPS), C.cyan);
                drawnow;

                runOneSweep(true);

                if ~isvalid(fig); return; end
                updatePosition();
                sweepsDone = sweepsDone + 1;
                hProgress.Text = sprintf('%d / %d', sweepsDone, TOTAL_SWEEPS);
                addLog(sprintf('Lane %d acquired.', sweepsDone));

                try
                    lastRF = evalin('base', 'lastRFfilename');
                catch
                    lastRF = '';
                end
                if ~isempty(lastRF)
                    [fp, fn, ~] = fileparts(lastRF);
                    setStatus(sprintf('Auto Scan: lane %d/%d — C-scan...', ...
                              lane, TOTAL_SWEEPS), C.cyan);
                    addLog(sprintf('C-scan: %s', fn));
                    drawnow;
                    try
                        cscan_surface_guided_fn(fp, [fn '_size.mat'], [fn '.txt']);
                        addLog('C-scan done.');
                    catch cex
                        addLog(['C-scan failed: ' cex.message]);
                    end
                else
                    addLog('No RF saved this session — skipping C-scan.');
                end

                try; aborted = evalin('base', 'autoScanAbort'); catch; aborted = false; end
                if aborted; break; end

                if sweepsDone < TOTAL_SWEEPS
                    setStatus(sprintf('Auto Scan: lane %d/%d — repositioning...', ...
                              lane, TOTAL_SWEEPS), C.cyan);
                    addLog('Repositioning for next lane...');
                    drawnow;
                    try
                        doReposition();
                        addLog('Repositioned.');
                    catch rex
                        setStatus(['Reposition failed: ' rex.message], C.red);
                        addLog(['Reposition failed: ' rex.message]);
                        aborted = true;
                        break;
                    end
                end
            end

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                setStatus(['Auto Scan failed: ' ex.message], C.red);
                addLog(['Auto Scan error: ' ex.message]);
            end
            hStop.Enable   = 'off';
            hAuto.Enable   = 'on';
            hFinish.Enable = 'on';
            return;
        end

        if ~isvalid(fig); return; end

        hStop.Enable   = 'off';
        hAuto.Enable   = 'on';
        hFinish.Enable = 'on';
        assignin('base', 'sweepInProgress', false);

        if aborted
            setStatus(sprintf('Auto Scan stopped at lane %d/%d. ' + ...
                      'Reposition or Launch manually to continue.', ...
                      sweepsDone, TOTAL_SWEEPS), C.amber);
            addLog('=== Auto Scan stopped by user ===');
            if sweepsDone < TOTAL_SWEEPS
                hRepos.Enable  = 'on';
                hLaunch.Enable = 'on';
            else
                hDisconnect.Enable = 'on';
            end
        elseif sweepsDone >= TOTAL_SWEEPS
            setStatus('All sweeps acquired! Disconnect stage when finished.', C.green);
            addLog('=== Auto Scan complete ===');
            hRepos.Enable      = 'off';
            hLaunch.Enable     = 'off';
            hDisconnect.Enable = 'on';
        end
    end

    function onStop()
        assignin('base', 'autoScanAbort', true);
        hStop.Enable = 'off';
        addLog('Stop requested — aborting after current VSX session closes.');
    end

    function onReset()
        if sweepsDone >= TOTAL_SWEEPS
            sweepsDone     = 0;
            hProgress.Text = sprintf('0 / %d', TOTAL_SWEEPS);
            hPos.Text      = 'x=-.--- y=-.--- z=-.--- mm';
            hRepos.Enable  = 'off';
        end
        hFinish.Enable = 'off';
        hLaunch.Enable = 'on';
        hAuto.Enable   = 'on';
        setStatus('Ready. Press Launch VSX or Auto Scan to continue.', C.muted);
    end

    function onDisconnect()
        try
            stage = evalin('base', 'stage');
            stage.disconnect();
            setStatus('Stage disconnected.', C.muted);
        catch
        end
        hDisconnect.Enable = 'off';
        hRepos.Enable      = 'off';
    end

    function onJog(axisName, sign)
        try
            busy = evalin('base', ...
                'exist(''sweepInProgress'',''var'') && sweepInProgress');
        catch
            busy = false;
        end
        if busy
            setJogStatus('Sweep in progress — jog disabled.', C.red);
            return
        end

        step = hStep.Value;
        if isnan(step) || step <= 0 || step > 100
            setJogStatus('Step must be > 0 and <= 100 mm.', C.red);
            return
        end
        if abs(step - round(step, 3)) > eps(step) * 10
            setJogStatus('Step must have at most 3 decimal places.', C.red);
            return
        end

        distance = sign * step;

        [jogButtons.Enable] = deal('off');
        setJogStatus(sprintf('Moving %s by %.3f mm...', axisName, distance), C.amber);
        drawnow;

        try
            stage = getOrConnectStage();
            switch axisName
                case 'X'
                    stage.moveX(distance, 'vel', 40, 'accel', 100, 'decel', 100);
                case 'Y'
                    stage.moveY(distance, 'vel', 40, 'accel', 100, 'decel', 100);
            end
            assignin('base', 'stage', stage);
            updatePosition();
            setJogStatus('Jog ready.', C.green);
        catch ex
            setJogStatus(['Move failed: ' ex.message], C.red);
        end

        [jogButtons.Enable] = deal('on');
    end

    % ── Shared helpers ─────────────────────────────────────────────────────

    function runOneSweep(autoMode)
        if DEBUG_SAVERF
            addLog('Running SetUp script [DEBUG SaveRF mode]...');
        else
            addLog('Running SetUp script...');
        end

        snakeMode = startsWith(hScanMode.Value, 'Snake');
        assignin('base', 'guiLog',           @addLog);
        assignin('base', 'sweepLateralY_mm', sweepsDone * Y_STEPS * 0.1);
        assignin('base', 'sweepInProgress',  true);
        assignin('base', 'autoScanMode',     autoMode);
        if snakeMode
            sweepDir = 1 - 2 * mod(sweepsDone, 2);
        else
            sweepDir = 1;
        end
        assignin('base', 'sweepDir', sweepDir);

        script = setup_script;
        evalin('base', sprintf("run('%s')", strrep(script, '\', '/')));
        addLog('SetUp script returned.');
        assignin('base', 'sweepInProgress', false);
    end

    function doReposition()
        snakeMode = startsWith(hScanMode.Value, 'Snake');
        if snakeMode
            setStatus('Advancing Y (snake step)...', C.amber);
        else
            setStatus('Returning X and advancing Y...', C.amber);
        end
        drawnow;
        stage = evalin('base', 'stage');
        repositionProbe(stage, snakeMode);
        assignin('base', 'stage', stage);
        updatePosition();
    end

    function stage = getOrConnectStage()
        if evalin('base', 'exist(''stage'',''var'')')
            stage = evalin('base', 'stage');
        else
            if TESTING
                stage = MockStageController();
            else
                stage = StageController();
            end
            stage.connect();
            assignin('base', 'stage', stage);
        end
    end

    % ── GUI helpers ────────────────────────────────────────────────────────

    function lockAll()
        hLaunch.Enable     = 'off';
        hRepos.Enable      = 'off';
        hFinish.Enable     = 'off';
        hDisconnect.Enable = 'off';
        hAuto.Enable       = 'off';
    end

    function setJogStatus(msg, color)
        hJogStatus.Text      = msg;
        hJogStatus.FontColor = color;
    end

    function setStatus(msg, color)
        hStatus.Text      = msg;
        hStatus.FontColor = color;
    end

    function updatePosition()
        try
            stage = evalin('base', 'stage');
            pos   = stage.getPosition();
            hPos.Text = sprintf('x=%.3f  y=%.3f  z=%.3f mm', ...
                                pos.x, pos.y, pos.z);
        catch
            hPos.Text = 'position unavailable';
        end
    end

    function addLog(msg)
        timestamp = datestr(now, 'HH:MM:SS');
        line = sprintf('[%s] %s', timestamp, msg);
        fprintf('%s\n', line);
        current = hLog.Value;
        if isempty(current) || (numel(current)==1 && isempty(current{1}))
            hLog.Value = {line};
        else
            hLog.Value = [current; {line}];
        end

        if contains(msg, 'Calling VSX')
            [jogButtons.Enable] = deal('on');
            setJogStatus('Jog ready.', C.green);
        end
        scroll(hLog, 'bottom');
        drawnow;
    end

end
