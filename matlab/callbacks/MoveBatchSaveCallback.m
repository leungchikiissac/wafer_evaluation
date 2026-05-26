% MoveBatchSaveCallback
% Verasonics UI callback — starts the batch move-and-acquire sequence.
%
% Embedded in SetUpL38_22v_... via text2cell.
% Jumps VSX execution to the batch-scan event block.

nStart2 = evalin('base', 'nstart_move');
Control = evalin('base', 'Control');
if isempty(Control(1).Command)
    n = 1;
else
    n = length(Control) + 1;
end
Control(n).Command    = 'set&Run';
Control(n).Parameters = {'Parameters', 1, 'startEvent', nStart2};
evalin('base', ['Resource.Parameters.startEvent = ', num2str(nStart2), ';']);
assignin('base', 'Control', Control);
assignin('base', 'freeze', 1);
return
