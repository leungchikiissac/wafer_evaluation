classdef MockStageController < handle
% MockStageController  Drop-in replacement for StageController with no
%   hardware/DLL dependency, for fast GUI/workflow testing.
%
%   Same public interface as StageController (connect, disconnect,
%   moveX/Y/Z, getPosition, printPosition). Moves are instantaneous and
%   position is tracked in memory.
%
%   Position is stored in a persistent variable so it survives across
%   multiple MockStageController() instances within the same MATLAB
%   session (mirrors how the real FMC4030 retains absolute position
%   across SetUp script re-launches).

    properties
        moveDelay = 0   % seconds to pause after each move (0 = instant)
    end

    properties (Access = private)
        isConnected = false
    end

    methods
        function obj = MockStageController()
        end

        function connect(obj)
            obj.isConnected = true;
            disp('MockStageController: connected (no hardware).');
        end

        function disconnect(obj)
            obj.isConnected = false;
            disp('MockStageController: disconnected.');
        end

        function moveX(obj, distanceMm, varargin)
            obj.requireConnection();
            obj.movePosition('x', distanceMm);
            if obj.moveDelay > 0, pause(obj.moveDelay); end
        end

        function moveY(obj, distanceMm, varargin)
            obj.requireConnection();
            obj.movePosition('y', distanceMm);
            if obj.moveDelay > 0, pause(obj.moveDelay); end
        end

        function moveZ(obj, distanceMm, varargin)
            obj.requireConnection();
            obj.movePosition('z', distanceMm);
            if obj.moveDelay > 0, pause(obj.moveDelay); end
        end

        function pos = getPosition(obj)
            pos = MockStageController.sharedPosition();
        end

        function printPosition(obj)
            pos = obj.getPosition();
            fprintf('MockStage position | x = %.3f mm | y = %.3f mm | z = %.3f mm\n', ...
                    pos.x, pos.y, pos.z);
        end
    end

    methods (Access = private)
        function requireConnection(obj)
            if ~obj.isConnected
                error('MockStageController:notConnected', ...
                      'MockStageController is not connected. Call connect() first.');
            end
        end

        function movePosition(obj, axisName, distanceMm)
            pos = MockStageController.sharedPosition();
            pos.(axisName) = pos.(axisName) + distanceMm;
            MockStageController.sharedPosition(pos);
        end
    end

    methods (Static)
        function pos = sharedPosition(newPos)
        % sharedPosition  Get/set the in-memory stage position.
        %   pos = MockStageController.sharedPosition()       — get
        %   MockStageController.sharedPosition(newPos)       — set
            persistent currentPos
            if isempty(currentPos)
                currentPos = struct('x', 0, 'y', 0, 'z', 0);
            end
            if nargin > 0
                currentPos = newPos;
            end
            pos = currentPos;
        end
    end
end
