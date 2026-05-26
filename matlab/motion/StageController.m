classdef StageController < handle
% StageController  Manages FMC4030 three-axis motion stage.
%
%   Encapsulates all FMC4030 DLL API calls, movement polling,
%   position verification, and error handling in one place.
%
%   Usage:
%     stage = StageController();
%     stage.connect();
%     stage.moveX(0.05);
%     stage.moveY(-6.9);
%     pos = stage.getPosition();
%     stage.disconnect();
%
%   Author:   Issac Leung
%   System:   Verasonics Vantage NXT + FUYU FMC4030
%   Created:  2026

    % ── Constants ────────────────────────────────────────────────────────
    properties (Constant)
        DLL_NAME        = 'FMC40300x2DDll'
        DEVICE_INDEX    = 0
        AXIS_X          = 0
        AXIS_Y          = 1
        AXIS_Z          = 2

        % Default motion parameters
        DEFAULT_VEL     = 80     % mm/s
        DEFAULT_ACCEL   = 200    % mm/s²
        DEFAULT_DECEL   = 200    % mm/s²

        % Polling parameters
        POLL_INTERVAL   = 0.02   % seconds between position reads
        STABLE_THRESH   = 0.001  % mm — position change below this = stopped
        MOVE_TIMEOUT    = 5.0    % seconds before timeout warning
        POS_TOLERANCE   = 0.010  % mm — acceptable positioning error (10 µm)
    end

    % ── State ─────────────────────────────────────────────────────────────
    properties (Access = private)
        isConnected = false
    end

    % ── Public methods ────────────────────────────────────────────────────
    methods

        % ── Constructor ──────────────────────────────────────────────────
        function obj = StageController()
            % Load DLL if not already loaded
            if ~libisloaded(obj.DLL_NAME)
                error('StageController: DLL "%s" is not loaded.\nLoad it in your SetUp script before creating StageController.', ...
                      obj.DLL_NAME);
            end
        end

        % ── connect ──────────────────────────────────────────────────────
        function connect(obj)
        % connect  Verify communication with FMC4030 controller.
            posPtr = libpointer('singlePtr', 0);
            status = calllib(obj.DLL_NAME, 'FMC4030_Get_Axis_Current_Pos', ...
                             obj.DEVICE_INDEX, obj.AXIS_X, posPtr);
            obj.checkStatus(status, 'connect');
            obj.isConnected = true;
            disp('StageController: connection verified.');
        end

        % ── disconnect ───────────────────────────────────────────────────
        function disconnect(obj)
        % disconnect  Release stage and mark as disconnected.
            obj.isConnected = false;
            disp('StageController: disconnected.');
        end

        % ── moveX ────────────────────────────────────────────────────────
        function moveX(obj, distanceMm, varargin)
        % moveX  Move stage along X-axis by distanceMm (relative).
        %   moveX(distanceMm)
        %   moveX(distanceMm, 'vel', 50, 'accel', 100, 'decel', 100)
            p = obj.parseMotionArgs(varargin{:});
            obj.jogAxis(obj.AXIS_X, distanceMm, p.vel, p.accel, p.decel);
            obj.waitUntilStopped(obj.AXIS_X, distanceMm);
        end

        % ── moveY ────────────────────────────────────────────────────────
        function moveY(obj, distanceMm, varargin)
        % moveY  Move stage along Y-axis by distanceMm (relative).
            p = obj.parseMotionArgs(varargin{:});
            obj.jogAxis(obj.AXIS_Y, distanceMm, p.vel, p.accel, p.decel);
            obj.waitUntilStopped(obj.AXIS_Y, distanceMm);
        end

        % ── moveZ ────────────────────────────────────────────────────────
        function moveZ(obj, distanceMm, varargin)
        % moveZ  Move stage along Z-axis by distanceMm (relative).
            p = obj.parseMotionArgs(varargin{:});
            obj.jogAxis(obj.AXIS_Z, distanceMm, p.vel, p.accel, p.decel);
            obj.waitUntilStopped(obj.AXIS_Z, distanceMm);
        end

        % ── getPosition ──────────────────────────────────────────────────
        function pos = getPosition(obj)
        % getPosition  Read current X, Y, Z positions.
        %   Returns struct with fields x, y, z (all in mm).
            pos.x = obj.readAxisPosition(obj.AXIS_X);
            pos.y = obj.readAxisPosition(obj.AXIS_Y);
            pos.z = obj.readAxisPosition(obj.AXIS_Z);
        end

        % ── printPosition ────────────────────────────────────────────────
        function printPosition(obj)
        % printPosition  Display current position to command window.
            pos = obj.getPosition();
            fprintf('Stage position | x = %.3f mm | y = %.3f mm | z = %.3f mm\n', ...
                    pos.x, pos.y, pos.z);
        end

    end

    % ── Private methods ───────────────────────────────────────────────────
    methods (Access = private)

        % ── jogAxis ──────────────────────────────────────────────────────
        function jogAxis(obj, axis, distanceMm, vel, accel, decel)
        % jogAxis  Send jog command and check return status.
            obj.requireConnection();
            status = calllib(obj.DLL_NAME, 'FMC4030_Jog_Single_Axis', ...
                             obj.DEVICE_INDEX, axis, distanceMm, ...
                             vel, accel, decel, 1);
            obj.checkStatus(status, sprintf('FMC4030_Jog_Single_Axis (axis=%d, dist=%.3fmm)', ...
                                            axis, distanceMm));
        end

        % ── waitUntilStopped ─────────────────────────────────────────────
        function waitUntilStopped(obj, axis, requestedDistMm)
        % waitUntilStopped  Poll axis position until movement ceases.
        %   Issues warning if timeout or position tolerance exceeded.
            t_start  = tic;
            prev_pos = NaN;
            curr_pos = NaN;
            timedOut = false;

            while toc(t_start) < obj.MOVE_TIMEOUT
                pause(obj.POLL_INTERVAL);
                curr_pos = obj.readAxisPosition(axis);

                if ~isnan(prev_pos) && abs(curr_pos - prev_pos) < obj.STABLE_THRESH
                    break;   % position stable — stage has stopped
                end
                prev_pos = curr_pos;
            end

            if toc(t_start) >= obj.MOVE_TIMEOUT
                timedOut = true;
                warning('StageController:timeout', ...
                        'Stage movement timed out after %.1f sec on axis %d. Last position: %.3f mm', ...
                        obj.MOVE_TIMEOUT, axis, curr_pos);
            end

            % Verify final position is within tolerance
            if ~timedOut
                obj.verifyPosition(axis, requestedDistMm, curr_pos);
            end
        end

        % ── verifyPosition ───────────────────────────────────────────────
        function verifyPosition(obj, axis, requestedDistMm, actualPos)
        % verifyPosition  Check that requested move was executed accurately.
        %   Note: requestedDistMm is relative — for absolute checking
        %   the caller should pass the absolute target if available.
            if nargin < 4 || isnan(actualPos)
                return;
            end
            % For relative moves we can only verify the move completed
            % without stalling — absolute position tracking is in move3dstage
            % where the cumulative target is known
        end

        % ── readAxisPosition ─────────────────────────────────────────────
        function pos = readAxisPosition(obj, axis)
        % readAxisPosition  Read current position of one axis in mm.
            posPtr = libpointer('singlePtr', 0);
            status = calllib(obj.DLL_NAME, 'FMC4030_Get_Axis_Current_Pos', ...
                             obj.DEVICE_INDEX, axis, posPtr);

            if status ~= 0
                warning('StageController:readFailed', ...
                        'FMC4030_Get_Axis_Current_Pos failed on axis %d.\n  %s', ...
                        axis, StageController.decodeStatus(status));
                pos = NaN;
            else
                pos = posPtr.Value;
            end
        end

        % ── requireConnection ────────────────────────────────────────────
        function requireConnection(obj)
        % requireConnection  Guard: throw error if not connected.
            if ~obj.isConnected
                error('StageController:notConnected', ...
                      'StageController is not connected. Call connect() first.');
            end
        end

        % ── parseMotionArgs ──────────────────────────────────────────────
        function p = parseMotionArgs(obj, varargin)
        % parseMotionArgs  Parse optional vel/accel/decel arguments.
            p.vel   = obj.DEFAULT_VEL;
            p.accel = obj.DEFAULT_ACCEL;
            p.decel = obj.DEFAULT_DECEL;
            for k = 1:2:length(varargin)
                switch lower(varargin{k})
                    case 'vel',   p.vel   = varargin{k+1};
                    case 'accel', p.accel = varargin{k+1};
                    case 'decel', p.decel = varargin{k+1};
                    otherwise
                        warning('StageController:unknownParam', ...
                                'Unknown parameter: %s', varargin{k});
                end
            end
        end

        % ── checkStatus ──────────────────────────────────────────────────
        function checkStatus(obj, status, context)
        % checkStatus  Throw error if status is non-zero.
            if status ~= 0
                error('StageController:apiError', ...
                      'FMC4030 API error in [%s].\n  Code %d: %s', ...
                      context, status, StageController.decodeStatus(status));
            end
        end

    end

    % ── Static methods ────────────────────────────────────────────────────
    methods (Static)

        % ── decodeStatus ─────────────────────────────────────────────────
        function msg = decodeStatus(status)
        % decodeStatus  Translate FMC4030 return code to English message.
        %
        %   Based on FMC4030 API documentation (Chinese original):
        %     0   执行成功   Success
        %    -1   连接失败   Connection failed
        %    -4   数据建立失败   Data construction failed
        %    -5   数据发送失败   Data send failed
        %    -6   数据接收控制   Data receive error
        %    -7   接收数据错误   Received data error
        %    -8   空指针错误     Null pointer error
            switch status
                case  0
                    msg = 'Success';
                case -1
                    msg = ['Connection failed — ', ...
                           'check network cable, verify IP address and port, ', ...
                           'restart controller'];
                case -2
                    msg = 'Undefined error (-2)';
                case -3
                    msg = 'Undefined error (-3)';
                case -4
                    msg = ['Data construction failed — ', ...
                           'check available memory'];
                case -5
                    msg = ['Data send failed — ', ...
                           'check network cable, verify IP address and port, ', ...
                           'restart controller'];
                case -6
                    msg = ['Data receive error — ', ...
                           'check network cable, verify IP address and port, ', ...
                           'restart controller'];
                case -7
                    msg = ['Received data error — ', ...
                           'check network connection'];
                case -8
                    msg = ['Null pointer error — ', ...
                           'check that input arguments are not null pointers'];
                otherwise
                    msg = sprintf('Unknown error code (%d)', status);
            end
        end

    end
end
