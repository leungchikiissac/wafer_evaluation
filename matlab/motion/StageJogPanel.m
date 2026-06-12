function fig = StageJogPanel()
% StageJogPanel  Manual jog GUI for the FMC4030 stage.
%
%   Enter a step size (mm) and press an arrow button to move the stage
%   by that distance along the corresponding axis/direction:
%     ▲  -X      ▼  +X
%     ◄  -Y      ►  +Y
%
%   Step size must be a positive number, 0 < step <= 100 mm,
%   with at most 3 decimal places (0.001 mm resolution).
%
%   Connects its own StageController on launch and disconnects when
%   the window is closed.

% Set TESTING = true to jog a MockStageController (no hardware) instead
% of the real FMC4030 stage. Keep this in sync with ScanControlPanel's
% TESTING flag when using both panels together.
TESTING = false;

STEP_MIN = 0;
STEP_MAX = 100;

% Close any leftover panel from a previous run
old = findall(groot, 'Type', 'figure', 'Tag', 'StageJogPanel');
if ~isempty(old)
    delete(old);
end

fig = uifigure('Name', 'Stage Jog Panel', ...
               'Position', [480 100 260 320], ...
               'Tag', 'StageJogPanel', ...
               'Resize', 'off', ...
               'CloseRequestFcn', @(~,~) onClose());

uilabel(fig, 'Text', 'Stage Jog Panel', ...
        'Position', [10 280 240 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center');

% ── Step size entry ─────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Step (mm):', ...
        'Position', [20 235 80 22], 'FontWeight', 'bold');
hStep = uieditfield(fig, 'numeric', ...
        'Position', [105 235 80 22], ...
        'Value', 1, ...
        'Limits', [STEP_MIN STEP_MAX], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f');

% ── Direction buttons (arranged like a D-pad) ───────────────────────────
btnSize = 60;
cx = 130; cy = 140;  % center of the D-pad

hUp = uibutton(fig, 'Text', char(9650), ...   % ▲  -X
        'Position', [cx-btnSize/2, cy+btnSize, btnSize, btnSize], ...
        'FontSize', 18, ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hDown = uibutton(fig, 'Text', char(9660), ... % ▼  +X
        'Position', [cx-btnSize/2, cy-btnSize, btnSize, btnSize], ...
        'FontSize', 18, ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hLeft = uibutton(fig, 'Text', char(9664), ... % ◄  -Y
        'Position', [cx-btnSize-btnSize/2, cy, btnSize, btnSize], ...
        'FontSize', 18, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hRight = uibutton(fig, 'Text', char(9654), ... % ►  +Y
        'Position', [cx+btnSize/2, cy, btnSize, btnSize], ...
        'FontSize', 18, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

allButtons = [hUp hDown hLeft hRight];

% ── Position display ─────────────────────────────────────────────────────
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 50 220 22], 'FontSize', 11, ...
        'HorizontalAlignment', 'center');

% ── Status ────────────────────────────────────────────────────────────────
hStatus = uilabel(fig, 'Text', 'Connecting to stage...', ...
        'Position', [20 20 220 22], 'FontColor', [0.5 0.5 0.5], ...
        'HorizontalAlignment', 'center');

% ── Connect to stage ──────────────────────────────────────────────────────
% Reuse the shared 'stage' object from the base workspace if one already
% exists (e.g. created by ScanControlPanel) so both panels drive the same
% connection instead of opening the device twice.
stage = [];
ownsConnection = false;
try
    if evalin('base', 'exist(''stage'',''var'')')
        stage = evalin('base', 'stage');
        setStatus('Connected (shared with ScanControlPanel).', [0.2 0.5 0.2]);
    else
        if TESTING
            stage = MockStageController();
        else
            stage = StageController();
        end
        stage.connect();
        ownsConnection = true;
        assignin('base', 'stage', stage);
        setStatus('Connected.', [0.2 0.5 0.2]);
    end
    updatePosition();
catch ex
    setStatus(['Connect failed: ' ex.message], [0.8 0 0]);
    [allButtons.Enable] = deal('off');
end

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onJog(axisName, sign)
        % ── Refuse to move while VSX is running a sweep ────────────────
        try
            busy = evalin('base', ...
                'exist(''sweepInProgress'',''var'') && sweepInProgress');
        catch
            busy = false;
        end
        if busy
            setStatus('Sweep in progress — jog disabled.', [0.8 0 0]);
            return
        end

        step = hStep.Value;

        % ── Validate step size ───────────────────────────────────────
        if isnan(step) || step <= STEP_MIN || step > STEP_MAX
            setStatus(sprintf('Step must be > %g and <= %g mm.', ...
                      STEP_MIN, STEP_MAX), [0.8 0 0]);
            return
        end
        if abs(step - round(step, 3)) > eps(step) * 10
            setStatus('Step must have at most 3 decimal places.', [0.8 0 0]);
            return
        end

        distance = sign * step;

        [allButtons.Enable] = deal('off');
        setStatus(sprintf('Moving %s by %.3f mm...', axisName, distance), ...
                  [0.6 0.4 0]);
        drawnow;

        try
            switch axisName
                case 'X'
                    stage.moveX(distance);
                case 'Y'
                    stage.moveY(distance);
            end
            updatePosition();
            setStatus('Ready.', [0.2 0.5 0.2]);
        catch ex
            setStatus(['Move failed: ' ex.message], [0.8 0 0]);
        end

        [allButtons.Enable] = deal('on');
    end

    function onClose()
        % Only disconnect/clear the stage if this panel created the
        % connection itself — if shared with ScanControlPanel, leave it.
        if ownsConnection && ~isempty(stage)
            try
                stage.disconnect();
                evalin('base', 'clear stage');
            catch
            end
        end
        delete(fig);
    end

    % ── Helpers ───────────────────────────────────────────────────────────

    function setStatus(msg, color)
        hStatus.Text      = msg;
        hStatus.FontColor = color;
    end

    function updatePosition()
        try
            pos = stage.getPosition();
            hPos.Text = sprintf('x=%.3f  y=%.3f  z=%.3f mm', ...
                                pos.x, pos.y, pos.z);
        catch
            hPos.Text = 'position unavailable';
        end
    end

end
