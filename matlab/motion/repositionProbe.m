function repositionProbe(stage)
% repositionProbe  Move probe to start of next sweep lane (snake pattern).
%
%   Advances Y by 6.9 mm only — no X return required because the snake
%   pattern alternates sweep direction, so the probe is already at the
%   correct X position (0 or 60 mm) for the next lane.
%
%   Called by ScanControlPanel during multi-sweep sessions.
%   Requires an already-connected StageController object.

fprintf('\nRepositioning probe (lateral step only)...\n');

% Advance Y by -6.9 mm in a single move.
fprintf('Advancing Y-axis: -6.9 mm\n');
stage.moveY(-6.9);
stage.printPosition();

fprintf('Reposition complete.\n');
end
