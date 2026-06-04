function setupLog(msg)
% setupLog  Log a message to Command Window and GUI log if available.
%   Called from SetUp script. If ScanControlPanel put a guiLog callback
%   in the base workspace, forwards the message there too.
fprintf('[SetUp] %s\n', msg);
try
    cb = evalin('base', 'guiLog');
    cb(msg);
catch
end
end
