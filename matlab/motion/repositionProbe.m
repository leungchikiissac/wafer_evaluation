function repositionProbe(stage, snakeMode)
% repositionProbe  Move probe to start of next sweep lane.
%
%   repositionProbe(stage)            — raster: return X to 0, then advance Y
%   repositionProbe(stage, snakeMode) — if snakeMode=true, Y step only
%
%   Called by ScanControlPanel during multi-sweep sessions.

if nargin < 2; snakeMode = false; end

fprintf('\nRepositioning probe...\n');

if snakeMode
    % Snake pattern: probe is already at correct X end; advance Y only.
    fprintf('Snake mode: advancing Y-axis: -6.9 mm\n');
    stage.moveY(-6.9);
else
    % Raster pattern: return X to 0, then advance Y.
    fprintf('Raster mode: returning X by -60 mm, then advancing Y: -6.9 mm\n');
    stage.moveX(-60);
    stage.moveY(-6.9);
end

stage.printPosition();
fprintf('Reposition complete.\n');
end
