function ScanControlPanel()
% ScanControlPanel  Multi-sweep orchestration GUI.
%
%   Workflow:
%     1. Press "Launch VSX"  — runs SetUp script, opens Verasonics VSX window
%     2. Press "Move Batch"  — in the VSX window (sweeps X 60 mm, saves RF)
%     3. Press "Reposition"  — moves X back 60 mm + Y forward 6.9 mm
%     4. Repeat steps 2-3 for each of the 6 sweep lanes
%
%   The stage object is shared with VSX via the base workspace ('stage').

TOTAL_SWEEPS  = 6;
X_RETURN_MM   = -60.0;   % move X back to start
Y_STEP_MM     =   6.9;   % advance to next lane

% ── Find SetUp script relative to this file ──────────────────────────────
here      = fileparts(mfilename('fullpath'));
setup_script = fullfile(here, '..', 'acquisition', ...
    'SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m');
assert(isfile(setup_script), 'SetUp script not found: %s', setup_script);

% ── Build figure ──────────────────────────────────────────────────────────
fig = uifigure('Name', 'Scan Control Panel', ...
               'Position', [100 100 340 380], ...
               'Resize', 'off');

% Title
uilabel(fig, 'Text', 'Scan Control Panel', ...
        'Position', [10 335 320 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

% ── Sweep progress ────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Sweep progress:', ...
        'Position', [20 295 120 22], 'FontWeight', 'bold');
hProgress = uilabel(fig, 'Text', sprintf('0 / %d', TOTAL_SWEEPS), ...
        'Position', [145 295 170 22], ...
        'FontSize', 13, 'FontColor', [0.2 0.5 0.2]);

% ── Position display ──────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Stage position:', ...
        'Position', [20 260 120 22], 'FontWeight', 'bold');
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 238 300 22], 'FontSize', 11);

% ── Status ────────────────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Status:', ...
        'Position', [20 205 60 22], 'FontWeight', 'bold');
hStatus = uilabel(fig, 'Text', 'Not started', ...
        'Position', [85 205 235 22], 'FontColor', [0.5 0.5 0.5]);

% Divider
uipanel(fig, 'Position', [15 195 310 2], 'BackgroundColor', [0.7 0.7 0.7]);

% ── Launch VSX button ─────────────────────────────────────────────────────
hLaunch = uibutton(fig, 'Text', 'Launch VSX', ...
        'Position', [20 150 300 40], ...
        'FontSize', 14, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'white', ...
        'ButtonPushedFcn', @(~,~) onLaunchVSX());

% ── Reposition button ─────────────────────────────────────────────────────
hRepos = uibutton(fig, 'Text', 'Reposition Probe → next lane', ...
        'Position', [20 90 300 40], ...
        'FontSize', 13, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.2 0.4 0.8], 'FontColor', 'white', ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onReposition());

% ── Hint label ───────────────────────────────────────────────────────────
uilabel(fig, ...
        'Text', '← After repositioning, press "Move Batch" in VSX window', ...
        'Position', [20 65 300 22], 'FontSize', 10, ...
        'FontColor', [0.4 0.4 0.4]);

% ── Finish / reset button ─────────────────────────────────────────────────
hFinish = uibutton(fig, 'Text', 'Reset', ...
        'Position', [20 20 140 35], ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onReset());

hDisconnect = uibutton(fig, 'Text', 'Disconnect Stage', ...
        'Position', [180 20 140 35], ...
        'FontColor', [0.7 0 0], ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @(~,~) onDisconnect());

% ── State ─────────────────────────────────────────────────────────────────
sweepsDone = 0;

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onLaunchVSX()
        setStatus('Launching VSX...', [0.6 0.4 0]);
        lockAll();
        drawnow;
        try
            run(setup_script);
            updatePosition();
            setStatus('VSX launched. Run "Move Batch" in VSX, then Reposition.', ...
                      [0.2 0.5 0.2]);
            hRepos.Enable   = 'on';
            hLaunch.Enable  = 'off';   % prevent re-launch while VSX is open
            hDisconnect.Enable = 'on';
        catch ex
            setStatus(['Launch failed: ' ex.message], [0.8 0 0]);
            hLaunch.Enable = 'on';
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

            % Single large move — much faster than many small steps
            setStatus('Returning X to start...', [0.6 0.4 0]);
            drawnow;
            stage.moveX(X_RETURN_MM);

            setStatus('Advancing Y to next lane...', [0.6 0.4 0]);
            drawnow;
            stage.moveY(Y_STEP_MM);

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
                setStatus(sprintf('Lane %d done. Run "Move Batch" in VSX, then Reposition.', ...
                          sweepsDone), [0.2 0.5 0.2]);
                hRepos.Enable  = 'on';
                hFinish.Enable = 'on';
            end

        catch ex
            setStatus(['Reposition failed: ' ex.message], [0.8 0 0]);
            hRepos.Enable = 'on';
        end
    end

    function onReset()
        sweepsDone     = 0;
        hProgress.Text = sprintf('0 / %d', TOTAL_SWEEPS);
        hPos.Text      = 'x=-.--- y=-.--- z=-.--- mm';
        hRepos.Enable  = 'on';
        hFinish.Enable = 'off';
        setStatus('Reset. Run "Move Batch" in VSX, then Reposition.', ...
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

end
