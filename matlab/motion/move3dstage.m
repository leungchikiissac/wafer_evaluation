function move3dstage()
% move3dstage  Verasonics external-process callback: advance stage one step.
%
%   Called by the Verasonics VSX engine as Process(2).method.
%   Moves the X-axis one step using StageController, direction determined
%   by sweepDir in the base workspace (+1 = forward, -1 = reverse).
%
%   The StageController object must already exist in the base workspace
%   under the name 'stage' (created by the SetUp script).

d_ele = 0.05;   % mm per step magnitude

% Retrieve pre-connected StageController from base workspace
stage = evalin('base', 'stage');

% Read sweep direction: +1 = forward (0→60mm), -1 = reverse (60→0mm)
try
    sweepDir = evalin('base', 'sweepDir');
catch
    sweepDir = 1;   % default forward for manual / legacy launches
end

% Move one step along X in the current sweep direction
stage.moveX(sweepDir * d_ele);

% Report position (derive step number from absolute X position)
pos      = stage.getPosition();
step_num = round(abs(pos.x - (sweepDir < 0) * 60) / d_ele);
fprintf('Step %d | dir=%+d | x=%.3f mm | y=%.3f mm | z=%.3f mm\n', ...
        step_num, sweepDir, pos.x, pos.y, pos.z);

end
