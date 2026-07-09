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

% ── DeepSonix palette (MATLAB [R G B]) ────────────────────────────────────
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

old = findall(groot, 'Type', 'figure', 'Tag', 'StageJogPanel');
if ~isempty(old)
    delete(old);
end

fig = uifigure('Name', 'DeepSonix — Stage Jog Panel', ...
               'Position', [480 100 260 320], ...
               'Tag', 'StageJogPanel', ...
               'Color', C.bg_win, ...
               'Resize', 'off', ...
               'CloseRequestFcn', @(~,~) onClose());

uilabel(fig, 'Text', 'Stage Jog Panel', ...
        'Position', [10 280 240 30], ...
        'FontSize', 16, 'FontWeight', 'bold', ...
        'FontColor', C.amber, ...
        'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

% ── Step size entry ──────────────────────────────────────────────────────
uilabel(fig, 'Text', 'Step (mm):', ...
        'Position', [20 235 80 22], 'FontWeight', 'bold', ...
        'FontColor', C.amber, 'BackgroundColor', C.bg_win);
hStep = uieditfield(fig, 'numeric', ...
        'Position', [105 235 80 22], ...
        'Value', 1, ...
        'Limits', [STEP_MIN STEP_MAX], ...
        'LowerLimitInclusive', 'off', ...
        'ValueDisplayFormat', '%.3f', ...
        'BackgroundColor', C.bg_input, ...
        'FontColor', C.text);

% ── Direction buttons (D-pad) ─────────────────────────────────────────────
btnSize = 60;
cx = 130; cy = 140;

hUp = uibutton(fig, 'Text', char(9650), ...   % ▲  -X
        'Position', [cx-btnSize/2, cy+btnSize, btnSize, btnSize], ...
        'FontSize', 18, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'ButtonPushedFcn', @(~,~) onJog('X', -1));

hDown = uibutton(fig, 'Text', char(9660), ... % ▼  +X
        'Position', [cx-btnSize/2, cy-btnSize, btnSize, btnSize], ...
        'FontSize', 18, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'ButtonPushedFcn', @(~,~) onJog('X', +1));

hLeft = uibutton(fig, 'Text', char(9664), ... % ◄  -Y
        'Position', [cx-btnSize-btnSize/2, cy, btnSize, btnSize], ...
        'FontSize', 18, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', -1));

hRight = uibutton(fig, 'Text', char(9654), ... % ►  +Y
        'Position', [cx+btnSize/2, cy, btnSize, btnSize], ...
        'FontSize', 18, ...
        'BackgroundColor', C.bg_panel, 'FontColor', C.text, ...
        'ButtonPushedFcn', @(~,~) onJog('Y', +1));

allButtons = [hUp hDown hLeft hRight];

% ── Position display ──────────────────────────────────────────────────────
hPos = uilabel(fig, 'Text', 'x=-.--- y=-.--- z=-.--- mm', ...
        'Position', [20 50 220 22], 'FontSize', 11, ...
        'FontColor', C.cyan, ...
        'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

% ── Status ────────────────────────────────────────────────────────────────
hStatus = uilabel(fig, 'Text', 'Connecting to stage...', ...
        'Position', [20 20 220 22], ...
        'FontColor', C.muted, ...
        'BackgroundColor', C.bg_win, ...
        'HorizontalAlignment', 'center');

% ── Connect to stage ──────────────────────────────────────────────────────
stage = [];
ownsConnection = false;
try
    if evalin('base', 'exist(''stage'',''var'')')
        stage = evalin('base', 'stage');
        setStatus('Connected (shared with ScanControlPanel).', C.green);
    else
        if TESTING
            stage = MockStageController();
        else
            stage = StageController();
        end
        stage.connect();
        ownsConnection = true;
        assignin('base', 'stage', stage);
        setStatus('Connected.', C.green);
    end
    updatePosition();
catch ex
    setStatus(['Connect failed: ' ex.message], C.red);
    [allButtons.Enable] = deal('off');
end

% ── Callbacks ─────────────────────────────────────────────────────────────

    function onJog(axisName, sign)
        try
            busy = evalin('base', ...
                'exist(''sweepInProgress'',''var'') && sweepInProgress');
        catch
            busy = false;
        end
        if busy
            setStatus('Sweep in progress — jog disabled.', C.red);
            return
        end

        step = hStep.Value;

        if isnan(step) || step <= STEP_MIN || step > STEP_MAX
            setStatus(sprintf('Step must be > %g and <= %g mm.', ...
                      STEP_MIN, STEP_MAX), C.red);
            return
        end
        if abs(step - round(step, 3)) > eps(step) * 10
            setStatus('Step must have at most 3 decimal places.', C.red);
            return
        end

        distance = sign * step;

        [allButtons.Enable] = deal('off');
        setStatus(sprintf('Moving %s by %.3f mm...', axisName, distance), C.amber);
        drawnow;

        try
            switch axisName
                case 'X'
                    stage.moveX(distance);
                case 'Y'
                    stage.moveY(distance);
            end
            updatePosition();
            setStatus('Ready.', C.green);
        catch ex
            setStatus(['Move failed: ' ex.message], C.red);
        end

        [allButtons.Enable] = deal('on');
    end

    function onClose()
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
