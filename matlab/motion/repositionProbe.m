function repositionProbe(stage)
% repositionProbe  Move probe to start of next sweep lane.
%
%   Moves X back 60 mm (600 steps x -0.1 mm) then
%   advances Y by 6.9 mm (69 steps x 0.1 mm).
%
%   Called by ScanControlPanel during multi-sweep sessions.
%   Requires an already-connected StageController object.

fprintf('\nRepositioning probe...\n');

% Return X: 600 steps x -0.1 mm = -60 mm
fprintf('Returning X-axis: 600 steps x -0.1 mm\n');
for i = 1:600
    stage.moveX(-0.1);
    stage.printPosition();
end

% Advance Y: 69 steps x 0.1 mm = 6.9 mm
fprintf('Advancing Y-axis: 69 steps x 0.1 mm\n');
for i = 1:69
    stage.moveY(0.1);
    stage.printPosition();
end

fprintf('Reposition complete.\n');
end
