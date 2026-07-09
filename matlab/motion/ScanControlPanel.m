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

TESTING = false;
if nargin > 0
    TESTING = testing;
end

DEBUG_SAVERF = false;

TOTAL_SWEEPS  = 6;
X_STEPS       = 600;
Y_STEPS       =  69;

% ── Find SetUp scripts ────────────────────────────────────────────────────
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

% ── Session log ───────────────────────────────────────────────────────────
% One file per session: <project_root>/logs/scan_YYYY-MM-DD_HHmmss.log
% Open/append/close per entry — no held fid, so disk state is always current.
logDir  = fullfile(here, '..', '..', 'logs');
logPath = '';
try
    if ~exist(logDir, 'dir'); mkdir(logDir); end
    stamp   = char(datetime('now', 'Format', 'yyyy-MM-dd_HHmmss'));
    logPath = fullfile(logDir, ['scan_' stamp '.log']);
catch
    logPath = '';   % log dir unavailable — GUI continues without file log
end
% Share the write callback so StageJogPanel can write to the same file.
assignin('base', 'scanLogFcn', @logToFile);

% ── DeepSonix palette ─────────────────────────────────────────────────────
C.bg_win   = [0.039 0.094 0.188];
C.bg_panel = [0.067 0.125 0.251];
C.bg_input = [0.059 0.118 0.220];
C.toolbar  = [0.027 0.067 0.122];
C.cyan     = [0.000 0.784 0.941];
C.amber    = [0.961 0.612 0.102];
C.green    = [0.122 0.749 0.459];
C.red      = [0.898 0.282 0.302];
C.text     = [1.000 1.000 1.000];
C.muted    = [0.624 0.698 0.800];
C.border   = [0.133 0.216 0.361];

BG_GREEN  = [0.020 0.110 0.055];
BG_RED    = [0.180 0.050 0.050];
BG_AMBER  = [0.150 0.100 0.020];

% ── Build figure ──────────────────────────────────────────────────────────
% Delete any prior panel — this auto-disconnects the old session's stage via
% its CloseRequestFcn/DeleteFcn cleanup before we build the new one.
old = findall(groot, 'Type', 'figure', 'Tag', 'ScanControlPanel');
if ~isempty(old)
    delete(old);
end

fig = uifigure('Name', 'DeepSonix — Scan Control Panel', ...
               'Position', [100 100 620 430], ...
               'Tag', 'ScanControlPanel', ...
               'Color', C.bg_win, ...
               'Resize', 'off', ...
               'CloseRequestFcn', @(~,~) cleanupPanel(), ...
               'DeleteFcn', @(~,~) cleanupPanel());

% ══ Info bar (full width) ══════════════════════════════════════════════════
infoPanel = uipanel(fig, 'Position', [12 334 596 84], ...
        'BackgroundColor', C.bg_panel, 'BorderType', 'none');

uilabel(infoPanel, 'Text', 'SWEEP', ...
        'Position', [16 62 70 14], 'FontSize', 9, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_panel);
hProgress = uilabel(infoPanel, 'Text', sprintf('0 / %d', TOTAL_SWEEPS), ...
        'Position', [16 30 90 28], ...
        'FontSize', 20, 'FontWeight', 'bold', 'FontColor', C.cyan, ...
        'BackgroundColor', C.bg_panel);

uipanel(infoPanel, 'Position', [118 10 1 62], ...
        'BackgroundColor', C.border, 'BorderType', 'none');

uilabel(infoPanel, 'Text', 'POSITION (mm)', ...
        'Position', [130 62 160 14], 'FontSize', 9, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_panel);
hPos = uilabel(infoPanel, 'Text', 'x=-.---  y=-.---  z=-.---', ...
        'Position', [130 32 440 22], 'FontSize', 13, ...
        'FontName', 'Consolas', ...
        'FontColor', C.text, 'BackgroundColor', C.bg_panel);

hStatus = uilabel(infoPanel, 'Text', '●  Not started', ...
        'Position', [16 8 566 18], 'FontSize', 12, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_panel);

% ══ Scan Control (left column) ═════════════════════════════════════════════
scanPanel = uipanel(fig, 'Position', [12 12 360 310], ...
        'BackgroundColor', C.bg_panel, 'BorderType', 'none');

uilabel(scanPanel, 'Text', 'SCAN CONTROL', ...
        'Position', [14 284 200 18], 'FontSize', 11, 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_panel);

uilabel(scanPanel, 'Text', 'Scan mode:', ...
        'Position', [14 254 76 22], 'FontSize', 10, 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_panel);
hScanMode = uidropdown(scanPanel, ...
        'Items', {'Raster (return X)', 'Snake (alternate X)'}, ...
        'Position', [96 254 250 24], ...
        'Value', 'Raster (return X)', ...
        'FontSize', 10, ...
        'BackgroundColor', C.bg_input, ...
        'FontColor', C.text);

hAuto = uibutton(scanPanel, 'Text', 'Auto Scan', ...
        'Position', [14 198 244 44], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_AMBER, 'FontColor', C.amber, ...
        'ButtonPushedFcn', @(~,~) onAutoScan());

hStop = uibutton(scanPanel, 'Text', 'Stop', ...
        'Position', [266 198 80 44], ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_RED, 'FontColor', C.red, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onStop());

hLaunch = uibutton(scanPanel, 'Text', 'Launch VSX', ...
        'Position', [14 146 332 44], ...
        'FontSize', 14, 'FontWeight', 'bold', ...
        'BackgroundColor', BG_GREEN, 'FontColor', C.green, ...
        'ButtonPushedFcn', @(~,~) onLaunchVSX());

hRepos = uibutton(scanPanel, 'Text', 'Reposition', ...
        'Position', [14 102 332 34], ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', C.bg_input, 'FontColor', C.cyan, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onReposition());

uilabel(scanPanel, 'Text', 'Close VSX → Reposition → Launch VSX', ...
        'Position', [14 82 332 16], 'FontSize', 9, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_panel);

hFinish = uibutton(scanPanel, 'Text', 'Reset', ...
        'Position', [14 14 150 28], 'FontSize', 10, ...
        'BackgroundColor', C.bg_input, 'FontColor', C.muted, ...
        'Enable', 'on', ...
        'ButtonPushedFcn', @(~,~) onReset());

% ══ Stage Jog (right column) ═══════════════════════════════════════════════
jogPanel = uipanel(fig, 'Position', [384 12 224 310], ...
        'BackgroundColor', C.bg_panel, 'BorderType', 'none');

uilabel(jogPanel, 'Text', 'STAGE JOG', ...
        'Position', [0 284 224 18], 'FontSize', 11, 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_panel, ...
        'HorizontalAlignment', 'center');

uilabel(jogPanel, 'Text', 'Step (mm):', ...
        'Position', [24 250 70 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_panel);
hStep = uieditfield(jogPanel, 'numeric', ...
        'Position', [100 250 96 24], ...
        'Value', 1, ...
        'Limits', [0 100], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f', ...
        'BackgroundColor', C.bg_input, ...
        'FontColor', C.text);

hJogUp = uibutton(jogPanel, 'Text', char(9650), ...
        'Position', [87 160 50 50], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_input, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hJogDown = uibutton(jogPanel, 'Text', char(9660), ...
        'Position', [87 60 50 50], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_input, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hJogLeft = uibutton(jogPanel, 'Text', char(9664), ...
        'Position', [37 110 50 50], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_input, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hJogRight = uibutton(jogPanel, 'Text', char(9654), ...
        'Position', [137 110 50 50], ...
        'FontSize', 16, ...
        'BackgroundColor', C.bg_input, 'FontColor', C.text, ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

jogButtons = [hJogUp hJogDown hJogLeft hJogRight];

hJogStatus = uilabel(jogPanel, 'Text', 'Jog disabled until stage is initialized (Launch VSX).', ...
        'Position', [10 14 204 34], 'FontSize', 10, ...
        'FontColor', C.muted, 'BackgroundColor', C.bg_panel, ...
        'HorizontalAlignment', 'center', 'WordWrap', 'on');

% ── State ─────────────────────────────────────────────────────────────────
sweepsDone = 0;
cleanedUp  = false;

% Write session-start marker now that figure exists.
addLog('=== ScanControlPanel session started ===');
if ~isempty(logPath)
    addLog(['Log file: ' logPath]);
end
if ~isempty(logPath)
    setStatus(['Ready — log: ' logPath], C.muted);
else
    setStatus('Ready.', C.muted);
end

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
                setStatus('All sweeps acquired. Stage disconnects when you close this window.', C.green);
                hRepos.Enable      = 'off';
                hLaunch.Enable     = 'off';
                hFinish.Enable     = 'on';
            else
                setStatus(sprintf('Sweep %d done. Reposition for next lane.', ...
                          sweepsDone), C.green);
                hRepos.Enable      = 'on';
                hFinish.Enable     = 'on';
            end

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                logError(['Launch VSX failed: ' ex.message]);
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
            logError(['Reposition failed: ' ex.message]);
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
                        logError(['C-scan failed: ' cex.message]);
                    end
                else
                    logWarn('No RF saved this session — skipping C-scan.');
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
                        logError(['Reposition failed: ' rex.message]);
                        setStatus(['Reposition failed: ' rex.message], C.red);
                        aborted = true;
                        break;
                    end
                end
            end

        catch ex
            assignin('base', 'sweepInProgress', false);
            if isvalid(fig)
                logError(['Auto Scan failed: ' ex.message]);
                setStatus(['Auto Scan failed: ' ex.message], C.red);
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
            logWarn(sprintf('Auto Scan stopped at lane %d/%d.', sweepsDone, TOTAL_SWEEPS));
            setStatus(sprintf('Auto Scan stopped at lane %d/%d. ' + ...
                      'Reposition or Launch manually to continue.', ...
                      sweepsDone, TOTAL_SWEEPS), C.amber);
            addLog('=== Auto Scan stopped by user ===');
            if sweepsDone < TOTAL_SWEEPS
                hRepos.Enable  = 'on';
                hLaunch.Enable = 'on';
            end
        elseif sweepsDone >= TOTAL_SWEEPS
            setStatus('All sweeps acquired. Stage disconnects when you close this window.', C.green);
            addLog('=== Auto Scan complete ===');
            hRepos.Enable      = 'off';
            hLaunch.Enable     = 'off';
        end
    end

    function onStop()
        assignin('base', 'autoScanAbort', true);
        hStop.Enable = 'off';
        addLog('Stop requested — will abort after current VSX session closes.');
    end

    function onReset()
        if sweepsDone >= TOTAL_SWEEPS
            sweepsDone     = 0;
            hProgress.Text = sprintf('0 / %d', TOTAL_SWEEPS);
            hPos.Text      = 'x=-.---  y=-.---  z=-.---';
            hRepos.Enable  = 'off';
        end
        hFinish.Enable = 'off';
        hLaunch.Enable = 'on';
        hAuto.Enable   = 'on';
        addLog('Panel reset.');
        setStatus('Ready. Press Launch VSX or Auto Scan to continue.', C.muted);
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
            logToFile('WARN', sprintf('Jog rejected: invalid step %.3f mm', step));
            return
        end
        if abs(step - round(step, 3)) > eps(step) * 10
            setJogStatus('Step must have at most 3 decimal places.', C.red);
            logToFile('WARN', 'Jog rejected: step exceeds 3 decimal places');
            return
        end

        distance = sign * step;

        [jogButtons.Enable] = deal('off');
        setJogStatus(sprintf('Moving %s by %.3f mm...', axisName, distance), C.amber);
        logToFile('INFO', sprintf('Jog %s by %.3f mm', axisName, distance));
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
            logToFile('INFO', ['Jog done. Position: ' hPos.Text]);
        catch ex
            logError(['Jog failed: ' ex.message]);
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
        addLog(['Position after reposition: ' hPos.Text]);
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
        hAuto.Enable       = 'off';
    end

    function setJogStatus(msg, color)
        hJogStatus.Text      = msg;
        hJogStatus.FontColor = color;
        logToFile(statusLevel(color), ['jog: ' msg]);
    end

    function setStatus(msg, color)
        hStatus.Text      = ['●  ' msg];
        hStatus.FontColor = color;
        logToFile(statusLevel(color), ['status: ' msg]);
    end

    function level = statusLevel(color)
        if     isequal(color, C.red);   level = 'ERROR';
        elseif isequal(color, C.amber); level = 'WARN';
        else;                           level = 'INFO';
        end
    end

    function updatePosition()
        try
            stage = evalin('base', 'stage');
            pos   = stage.getPosition();
            hPos.Text = sprintf('x=%.3f  y=%.3f  z=%.3f', ...
                                pos.x, pos.y, pos.z);
        catch
            hPos.Text = 'position unavailable';
        end
    end

    % ── Logging helpers ────────────────────────────────────────────────────

    function addLog(msg, level)
        % Route every GUI log line to the file as INFO (default) or given level.
        if nargin < 2 || isempty(level); level = 'INFO'; end
        timestamp = datestr(now, 'HH:MM:SS');
        if strcmp(level, 'INFO')
            line = sprintf('[%s] %s', timestamp, msg);
        else
            line = sprintf('[%s] [%s] %s', timestamp, level, msg);
        end
        fprintf('%s\n', line);
        logToFile(level, msg);

        if contains(msg, 'Calling VSX')
            [jogButtons.Enable] = deal('on');
            setJogStatus('Jog ready.', C.green);
        end
    end

    function logWarn(msg),  addLog(msg, 'WARN');  end
    function logError(msg), addLog(msg, 'ERROR'); end

    function logToFile(level, msg)
        % Core file-write: open → append → close on every call.
        % Closing after each write is the only pure-MATLAB way to guarantee
        % entries survive a MATLAB crash (no fflush in base MATLAB).
        if isempty(logPath); return; end
        try
            fid = fopen(logPath, 'at', 'n', 'UTF-8');
            if fid < 0; return; end
            fprintf(fid, '[%s] [%s] %s\r\n', datestr(now, 'HH:MM:SS'), level, char(msg));
            fclose(fid);
        catch
        end
    end

    function closeLog()
        logToFile('INFO', '=== ScanControlPanel session ended ===');
        try; evalin('base', 'clear scanLogFcn'); catch; end
        logPath = '';   % neutralise any stale callbacks after figure is gone
    end

    function cleanupPanel()
        if cleanedUp; return; end   % guard against CloseRequestFcn→delete(fig)→DeleteFcn double-fire
        cleanedUp = true;
        try
            s = evalin('base','stage');
            s.disconnect();
            logToFile('INFO','Stage disconnected on panel close.');
        catch; end
        try; evalin('base','clear stage'); catch; end
        logToFile('INFO','=== ScanControlPanel session ended ===');
        try; evalin('base','clear scanLogFcn'); catch; end
        logPath = '';
        try; delete(fig); catch; end
    end

end
