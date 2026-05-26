function move3dstage()
% move3dstage  Verasonics external-process callback: advance stage one step.
%
%   Called by the Verasonics VSX engine as Process(2).method.
%   Moves the X-axis one step forward using StageController, then
%   prints current position to the command window.
%
%   The StageController object must already exist in the base workspace
%   under the name 'stage' (created by the SetUp script).

persistent counter
if isempty(counter)
    counter = 0;
end

d_ele = 0.05;   % mm per step

% Retrieve pre-connected StageController from base workspace
stage = evalin('base', 'stage');

% Move one step along X
stage.moveX(d_ele);

% Report position
pos = stage.getPosition();
fprintf('Step %d | x=%.3f mm | y=%.3f mm | z=%.3f mm\n', ...
        counter + 1, pos.x, pos.y, pos.z);

counter = counter + 1;
end
