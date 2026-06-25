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

% ── Build figure ──────────────────────────────────────────────────────────
% Close any existing panel left open from a previous run
old = findall(groot, 'Type', 'figure', 'Tag', 'ScanControlPanel');
if ~isempty(old)
    delete(old);
end

fig = uifigure('Name', 'Scan Control Panel', ...
               'Position', [100 100 620 620], ...
               'Tag', 'ScanControlPanel', ...
               'Resize', 'off');

% Title
uilabel(fig, 'Text', 'Scan Control Panel', ...
        'Position', [10 575 320 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

% ── Sweep progress ────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Sweep progress:', ...
        'Position', [20 535 120 22], 'FontWeight', 'bold');
hProgress = uilabel(fig, 'Text', sprintf('0 / %d', TOTAL_SWEEPS), ...
        'Position', [145 535 170 22], ...
        'FontSize', 13, 'FontColor', [0.2 0.5 0.2]);

% ── Position display ──────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Stage position:', ...
        'Position', [20 500 120 22], 'FontWeight', 'bold');
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 478 300 22], 'FontSize', 11);

% ── Status ────────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Status:', ...
        'Position', [20 445 60 22], 'FontWeight', 'bold');
hStatus = uilabel(fig, 'Text', 'Not started', ...
        'Position', [85 445 235 22], 'FontColor', [0.5 0.5 0.5]);

% Divider
uipanel(fig, 'Position', [15 435 310 2], 'BackgroundColor', [0.7 0.7 0.7]);

% ── Auto Scan button ──────────────────────────────────────────────────────
hAuto = uibutton(fig, 'Text', 'Auto Scan (all lanes)', ...
        'Position', [20 390 218 40], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.45 0.1 0.65], 'FontColor', 'white', ...
        'ButtonPushedFcn', @(~,~) onAutoScan());

% ── Stop Auto Scan button ─────────────────────────────────────────────────
hStop = uibutton(fig, 'Text', 'Stop', ...
        'Position', [243 390 77 40], ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.8 0.15 0.15], 'FontColor', 'white', ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onStop());

% ── Launch VSX button ─────────────────────────────────────────────────────
hLaunch = uibutton(fig, 'Text', 'Launch VSX', ...
        'Position', [20 330 300 40], ...
        'FontSize', 14, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'white', ...
        'ButtonPushedFcn', @(~,~) onLaunchVSX());

% ── Reposition button ─────────────────────────────────────────────────────
hRepos = uibutton(fig, 'Text', 'Reposition Probe → next lane', ...
        'Position', [20 270 300 40], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.4 0.8], 'FontColor', 'white', ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onReposition());

% ── Hint label ───────────────────────────────────────────────────────────
uilabel(fig, ...
        'Text', '← Close VSX first, then Reposition, then relaunch VSX', ...
        'Position', [20 248 300 22], 'FontSize', 10, ...
        'FontColor', [0.4 0.4 0.4]);

% ── Finish / reset button ─────────────────────────────────────────────────
hFinish = uibutton(fig, 'Text', 'Reset / Relaunch VSX', ...
        'Position', [20 200 140 35], ...
        'Enable', 'on', ...
        'ButtonPushedFcn', @(~,~) onReset());

hDisconnect = uibutton(fig, 'Text', 'Disconnect Stage', ...
        'Position', [180 200 140 35], ...
        'FontColor', [0.7 0 0], ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onDisconnect());

% ── Debug log ─────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Log:', ...
        'Position', [20 178 60 18], 'FontWeight', 'bold', 'FontSize', 10);
hLog = uitextarea(fig, ...
        'Position', [20 20 300 155], ...
        'Editable', 'off', ...
        'FontSize', 9, ...
        'Value', {''});

% ── Stage Jog Panel (right column) ─────────────────────────────────────────
uilabel(fig, 'Text', 'Stage Jog', ...
        'Position', [360 575 240 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

uilabel(fig, 'Text', 'Step (mm):', ...
        'Position', [360 535 80 22], 'FontWeight', 'bold');
hStep = uieditfield(fig, 'numeric', ...
        'Position', [445 535 80 22], ...
        'Value', 1, ...
        'Limits', [0 100], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f');

jogBtnSize = 50;
jcx = 470; jcy = 380;

hJogUp = uibutton(fig, 'Text', char(9650), ...   % ▲  -X
        'Position', [jcx-jogBtnSize/2, jcy+jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hJogDown = uibutton(fig, 'Text', char(9660), ... % ▼  +X
        'Position', [jcx-jogBtnSize/2, jcy-jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hJogLeft = uibutton(fig, 'Text', char(9664), ... % ◄  -Y
        'Position', [jcx-jogBtnSize-jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hJogRight = uibutton(fig, 'Text', char(9654), ... % ►  +Y
        'Position', [jcx+jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

jogButtons = [hJogUp hJogDown hJogLeft hJogRight];

hJogStatus = uilabel(fig, 'Text', 'Jog disabled until stage is initialized (Launch VSX).', ...
        'Position', [360 290 240 22], 'FontColor', [0.5 0.5 0.5], ...
        'HorizontalAlignment', 'center');

% ── State ─────────────────────────────────────────────────────────────────
sweepsDone = 0;

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onLaunchVSX()
        lockAll();
        if DEBUG_SAVERF
            addLog('--- Launch VSX pressed [DEBUG SaveRF mode] ---');
            setStatus('[DEBUG] VSX running — GUI unlocks when you close VSX.', [0.6 0.4 0]);
        else
            addLog('--- Launch VSX pressed ---');
            setStatus('VSX running — GUI unlocks when you close VSX.', [0.6 0.4 0]);
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
                setStatus('All sweeps acquired! Disconnect stage when finished.', ...
                          [0.2 0.5 0.2]);
                hRepos.Enable      = 'off';
                hLaunch.Enable     = 'off';
                hFinish.Enable     = 'on';
                hDisconnect.Enable = 'on';
            else
                setStatus(sprintf('Sweep %d done. Reposition for next lane.', ...
                          sweepsDone), [0.2 0.5 0.2]);
                hRepos.Enable      = 'on';
                hFinish.Enable     = 'on';
                hDisconnect.Enable = 'on';
            end

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                setStatus(['Launch failed: ' ex.message], [0.8 0 0]);
                hLaunch.Enable = 'on';
                hAuto.Enable   = 'on';
                hFinish.Enable = 'on';
            end
        end
    end

    function onReposition()
        lockAll();
        setStatus('Moving stage — please wait...', [0.6 0.4 0]);
        drawnow;

        try
            doReposition();
            setStatus(sprintf('Repositioned. Press Launch VSX for sweep %d.', ...
                      sweepsDone + 1), [0.2 0.5 0.2]);
            hRepos.Enable  = 'off';
            hLaunch.Enable = 'on';
            hAuto.Enable   = 'on';
            hFinish.Enable = 'on';

        catch ex
            setStatus(['Reposition failed: ' ex.message], [0.8 0 0]);
            hRepos.Enable = 'on';
            hAuto.Enable  = 'on';
        end
    end

    function onAutoScan()
        assignin('base', 'autoScanAbort', false);
        lockAll();
        hStop.Enable = 'on';
        setStatus(sprintf('Auto Scan: lane %d/%d — launching VSX...', ...
                  sweepsDone + 1, TOTAL_SWEEPS), [0.45 0.1 0.65]);
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
                          lane, TOTAL_SWEEPS), [0.45 0.1 0.65]);
                drawnow;

                % Launch VSX (blocking — returns after user closes VSX)
                runOneSweep(true);

                if ~isvalid(fig); return; end
                updatePosition();
                sweepsDone = sweepsDone + 1;
                hProgress.Text = sprintf('%d / %d', sweepsDone, TOTAL_SWEEPS);
                addLog(sprintf('Lane %d acquired.', sweepsDone));

                % C-scan if RF was saved during this VSX session
                try
                    lastRF = evalin('base', 'lastRFfilename');
                catch
                    lastRF = '';
                end
                if ~isempty(lastRF)
                    [fp, fn, ~] = fileparts(lastRF);
                    setStatus(sprintf('Auto Scan: lane %d/%d — C-scan...', ...
                              lane, TOTAL_SWEEPS), [0.45 0.1 0.65]);
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

                % Reposition unless this was the last lane
                if sweepsDone < TOTAL_SWEEPS
                    setStatus(sprintf('Auto Scan: lane %d/%d — repositioning...', ...
                              lane, TOTAL_SWEEPS), [0.45 0.1 0.65]);
                    addLog('Repositioning for next lane...');
                    drawnow;
                    try
                        doReposition();
                        addLog('Repositioned.');
                    catch rex
                        setStatus(['Reposition failed: ' rex.message], [0.8 0 0]);
                        addLog(['Reposition failed: ' rex.message]);
                        aborted = true;
                        break;
                    end
                end
            end  % for lane

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                setStatus(['Auto Scan failed: ' ex.message], [0.8 0 0]);
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
                      sweepsDone, TOTAL_SWEEPS), [0.8 0.4 0]);
            addLog('=== Auto Scan stopped by user ===');
            if sweepsDone < TOTAL_SWEEPS
                hRepos.Enable  = 'on';
                hLaunch.Enable = 'on';
            else
                hDisconnect.Enable = 'on';
            end
        elseif sweepsDone >= TOTAL_SWEEPS
            setStatus('All sweeps acquired! Disconnect stage when finished.', [0.2 0.5 0.2]);
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
        setStatus('Ready. Press Launch VSX or Auto Scan to continue.', ...
                  [0.4 0.4 0.4]);
    end

    function onDisconnect()
        try
            stage = evalin('base', 'stage');
            stage.disconnect();
            setStatus('Stage disconnected.', [0.4 0.4 0.4]);
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
            setJogStatus('Sweep in progress — jog disabled.', [0.8 0 0]);
            return
        end

        step = hStep.Value;
        if isnan(step) || step <= 0 || step > 100
            setJogStatus('Step must be > 0 and <= 100 mm.', [0.8 0 0]);
            return
        end
        if abs(step - round(step, 3)) > eps(step) * 10
            setJogStatus('Step must have at most 3 decimal places.', [0.8 0 0]);
            return
        end

        distance = sign * step;

        [jogButtons.Enable] = deal('off');
        setJogStatus(sprintf('Moving %s by %.3f mm...', axisName, distance), ...
                  [0.6 0.4 0]);
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
            setJogStatus('Jog ready.', [0.2 0.5 0.2]);
        catch ex
            setJogStatus(['Move failed: ' ex.message], [0.8 0 0]);
        end

        [jogButtons.Enable] = deal('on');
    end

    % ── Shared helpers used by both manual buttons and onAutoScan ─────────

    function runOneSweep(autoMode)
        % Execute the SetUp script (blocking until VSX closes).
        % autoMode=true sets autoScanMode in base so VSX pre-starts the batch.
        if DEBUG_SAVERF
            addLog('Running SetUp script [DEBUG SaveRF mode]...');
        else
            addLog('Running SetUp script...');
        end

        assignin('base', 'guiLog',           @addLog);
        assignin('base', 'sweepLateralY_mm', sweepsDone * Y_STEPS * 0.1);
        assignin('base', 'sweepInProgress',  true);
        assignin('base', 'autoScanMode',     autoMode);

        script = setup_script;
        evalin('base', sprintf("run('%s')", strrep(script, '\', '/')));
        addLog('SetUp script returned.');
        assignin('base', 'sweepInProgress', false);
    end

    function doReposition()
        % Move stage: return X + advance Y to next lane.
        setStatus('Returning X and advancing Y...', [0.6 0.4 0]);
        drawnow;
        stage = evalin('base', 'stage');
        repositionProbe(stage);
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

    % ── GUI helpers ───────────────────────────────────────────────────────

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

        % Stage is connected by the time the SetUp script logs "Calling VSX"
        if contains(msg, 'Calling VSX')
            [jogButtons.Enable] = deal('on');
            setJogStatus('Jog ready.', [0.2 0.5 0.2]);
        end
        scroll(hLog, 'bottom');
        drawnow;
    end

end
