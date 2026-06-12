function repositionProbe(stage)
% repositionProbe  Move probe to start of next sweep lane.
%
%   Moves X back 60 mm (600 steps x -0.1 mm) then
%   advances Y by 6.9 mm (69 steps x 0.1 mm).
%
%   Called by ScanControlPanel during multi-sweep sessions.
%   Requires an already-connected StageController object.

fprintf('\nRepositioning probe...\n');

% Return X by 60 mm in a single move. Issuing 600 separate 0.1 mm jogs
% back-to-back lets small per-jog shortfalls accumulate (observed ~0.8 mm
% drift over 600 steps), so move the full distance in one command instead.
fprintf('Returning X-axis: -60 mm\n');
stage.moveX(-60);
stage.printPosition();

% Advance Y by -6.9 mm in a single move (same reasoning as X above).
fprintf('Advancing Y-axis: -6.9 mm\n');
stage.moveY(-6.9);
stage.printPosition();

fprintf('Reposition complete.\n');
end
