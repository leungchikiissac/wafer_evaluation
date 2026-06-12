function fig = ScanControlPanel(testing)
% ScanControlPanel  Multi-sweep orchestration GUI.
%
%   Workflow:
%     1. Press "Launch VSX"  — runs SetUp script, opens Verasonics VSX window
%     2. Press "Move Batch"  — in the VSX window (sweeps X 60 mm, saves RF)
%     3. Press "Reposition"  — moves X back 60 mm + Y forward 6.9 mm
%     4. Repeat steps 2-3 for each of the 6 sweep lanes
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

TOTAL_SWEEPS  = 6;
X_STEPS       = 600;   % steps to return X to start (600 x -0.1 mm = -60 mm)
Y_STEPS       =  69;   % steps to advance to next lane (69 x 0.1 mm = 6.9 mm)

% ── Find SetUp script relative to this file ──────────────────────────────
here = fileparts(mfilename('fullpath'));
if TESTING
    setup_script = fullfile(here, '..', 'acquisition', 'SetUpMock.m');
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
               'Position', [100 100 620 560], ...
               'Tag', 'ScanControlPanel', ...
               'Resize', 'off');

% Title
uilabel(fig, 'Text', 'Scan Control Panel', ...
        'Position', [10 515 320 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

% ── Sweep progress ────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Sweep progress:', ...
        'Position', [20 475 120 22], 'FontWeight', 'bold');
hProgress = uilabel(fig, 'Text', sprintf('0 / %d', TOTAL_SWEEPS), ...
        'Position', [145 475 170 22], ...
        'FontSize', 13, 'FontColor', [0.2 0.5 0.2]);

% ── Position display ──────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Stage position:', ...
        'Position', [20 440 120 22], 'FontWeight', 'bold');
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 418 300 22], 'FontSize', 11);

% ── Status ────────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Status:', ...
        'Position', [20 385 60 22], 'FontWeight', 'bold');
hStatus = uilabel(fig, 'Text', 'Not started', ...
        'Position', [85 385 235 22], 'FontColor', [0.5 0.5 0.5]);

% Divider
uipanel(fig, 'Position', [15 375 310 2], 'BackgroundColor', [0.7 0.7 0.7]);

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
        'Position', [360 515 240 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

uilabel(fig, 'Text', 'Step (mm):', ...
        'Position', [360 475 80 22], 'FontWeight', 'bold');
hStep = uieditfield(fig, 'numeric', ...
        'Position', [445 475 80 22], ...
        'Value', 1, ...
        'Limits', [0 100], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f');

jogBtnSize = 50;
jcx = 470; jcy = 380;

hJogUp = uibutton(fig, 'Text', char(9650), ...   % ▲  -X
        'Position', [jcx-jogBtnSize/2, jcy+jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hJogDown = uibutton(fig, 'Text', char(9660), ... % ▼  +X
        'Position', [jcx-jogBtnSize/2, jcy-jogBtnSize, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hJogLeft = uibutton(fig, 'Text', char(9664), ... % ◄  -Y
        'Position', [jcx-jogBtnSize-jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hJogRight = uibutton(fig, 'Text', char(9654), ... % ►  +Y
        'Position', [jcx+jogBtnSize/2, jcy, jogBtnSize, jogBtnSize], ...
        'FontSize', 16, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

jogButtons = [hJogUp hJogDown hJogLeft hJogRight];

hJogStatus = uilabel(fig, 'Text', 'Jog ready.', ...
        'Position', [360 290 240 22], 'FontColor', [0.5 0.5 0.5], ...
        'HorizontalAlignment', 'center');

% ── State ─────────────────────────────────────────────────────────────────
sweepsDone = 0;

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onLaunchVSX()
        lockAll();
        addLog('--- Launch VSX pressed ---');
        setStatus('VSX running — GUI unlocks when you close VSX.', [0.6 0.4 0]);
        drawnow;

        % Write log callback into base workspace so SetUp script can call it
        assignin('base', 'guiLog', @addLog);

        % Lateral (Y) distance of this sweep's start from the scan origin,
        % used by saveRF_dbz_txt to tag the RF data filename.
        assignin('base', 'sweepLateralY_mm', sweepsDone * Y_STEPS * 0.1);

        % Tell StageJogPanel (if open) that the stage is busy with VSX —
        % it must not send jog commands until this is cleared.
        assignin('base', 'sweepInProgress', true);

        try
            addLog('Running SetUp script...');
            % evalin base executes the script in base workspace — fully blocking
            evalin('base', sprintf("run('%s')", strrep(setup_script,'\','/')));
            addLog('SetUp script returned.');

            assignin('base', 'sweepInProgress', false);

            if ~isvalid(fig)
                return
            end

            % VSX closed — SetUp script has finished
            updatePosition();
            setStatus('VSX closed. Ready to reposition.', [0.2 0.5 0.2]);
            hRepos.Enable      = 'on';
            hFinish.Enable     = 'on';
            hDisconnect.Enable = 'on';

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                setStatus(['Launch failed: ' ex.message], [0.8 0 0]);
                hLaunch.Enable = 'on';
            end
        end
    end

    function onReposition()
        if sweepsDone >= TOTAL_SWEEPS
            setStatus('All sweeps complete. Press Reset to start over.', ...
                      [0.2 0.5 0.2]);
            return
        end


        lockAll();
        setStatus('Moving stage — please wait...', [0.6 0.4 0]);
        drawnow;

        try
            stage = evalin('base', 'stage');
            setStatus('Returning X (600 steps)...', [0.6 0.4 0]);
            drawnow;
            repositionProbe(stage);

            sweepsDone = sweepsDone + 1;
            assignin('base', 'stage', stage);

            updatePosition();
            hProgress.Text = sprintf('%d / %d', sweepsDone, TOTAL_SWEEPS);

            if sweepsDone >= TOTAL_SWEEPS
                setStatus('All sweeps done! Disconnect stage when finished.', ...
                          [0.2 0.5 0.2]);
                hRepos.Enable   = 'off';
                hFinish.Enable  = 'on';
                hDisconnect.Enable = 'on';
            else
                setStatus(sprintf('Lane %d done. Press Launch VSX for next lane.', ...
                          sweepsDone), [0.2 0.5 0.2]);
                hRepos.Enable  = 'off';
                hLaunch.Enable = 'on';
                hFinish.Enable = 'on';
            end

        catch ex
            setStatus(['Reposition failed: ' ex.message], [0.8 0 0]);
            hRepos.Enable = 'on';
        end
    end

    function onReset()
        % Re-enable Launch VSX without disturbing the sweep count —
        % "Reset" here just unlocks the GUI, it does not start a new session.
        if sweepsDone >= TOTAL_SWEEPS
            sweepsDone     = 0;
            hProgress.Text = sprintf('0 / %d', TOTAL_SWEEPS);
            hPos.Text      = 'x=-.--- y=-.--- z=-.--- mm';
            hRepos.Enable  = 'off';
        end
        hFinish.Enable = 'off';
        hLaunch.Enable = 'on';   % allow re-launching VSX
        setStatus('Ready. Press Launch VSX to continue.', ...
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

    function setJogStatus(msg, color)
        hJogStatus.Text      = msg;
        hJogStatus.FontColor = color;
    end

    % ── Helpers ───────────────────────────────────────────────────────────

    function lockAll()
        hLaunch.Enable    = 'off';
        hRepos.Enable     = 'off';
        hFinish.Enable    = 'off';
        hDisconnect.Enable = 'off';
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
        fprintf('%s\n', line);  % also print to Command Window
        current = hLog.Value;
        if isempty(current) || (numel(current)==1 && isempty(current{1}))
            hLog.Value = {line};
        else
            hLog.Value = [current; {line}];
        end
        % Auto-scroll to bottom
        scroll(hLog, 'bottom');
        drawnow;
    end

end
