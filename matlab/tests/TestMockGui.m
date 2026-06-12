classdef TestMockGui < matlab.unittest.TestCase
% TestMockGui  Automated tests for the hardware-free TESTING mode of
%   ScanControlPanel / StageJogPanel / MockStageController / SetUpMock.
%
%   Run with:
%       results = runtests('matlab/tests/TestMockGui.m');

    properties
        CreatedFiles = {}
    end

    methods (TestClassSetup)
        function addMotionToPath(testCase)
            motionDir = fullfile(fileparts(mfilename('fullpath')), '..', 'motion');
            acqDir    = fullfile(fileparts(mfilename('fullpath')), '..', 'acquisition');
            addpath(motionDir, acqDir);
            testCase.addTeardown(@() rmpath(motionDir, acqDir));
        end
    end

    methods (TestMethodSetup)
        function resetMockStage(testCase)
            % Reset the shared mock position before every test
            MockStageController.sharedPosition(struct('x',0,'y',0,'z',0));
            testCase.CreatedFiles = {};
        end
    end

    methods (TestMethodTeardown)
        function cleanup(testCase)
            % Close any leftover GUI figures
            delete(findall(groot, 'Type', 'figure', 'Tag', 'ScanControlPanel'));
            delete(findall(groot, 'Type', 'figure', 'Tag', 'StageJogPanel'));

            % Remove any RF/workspace files written by SetUpMock during the test
            for k = 1:numel(testCase.CreatedFiles)
                f = testCase.CreatedFiles{k};
                if exist(f, 'file')
                    delete(f);
                end
            end

            % Clear shared base-workspace variables between tests
            evalin('base', ...
                'clear stage sweepLateralY_mm sweepInProgress guiLog RcvData');
        end
    end

    %% ── MockStageController ──────────────────────────────────────────
    methods (Test)

        function testInitialPositionIsZero(testCase)
            stage = MockStageController();
            stage.connect();
            pos = stage.getPosition();
            testCase.verifyEqual(pos.x, 0);
            testCase.verifyEqual(pos.y, 0);
            testCase.verifyEqual(pos.z, 0);
        end

        function testMoveUpdatesPosition(testCase)
            stage = MockStageController();
            stage.connect();

            stage.moveX(-5);
            stage.moveY(2.5);
            stage.moveZ(0.1);

            pos = stage.getPosition();
            testCase.verifyEqual(pos.x, -5,  'AbsTol', 1e-9);
            testCase.verifyEqual(pos.y,  2.5,'AbsTol', 1e-9);
            testCase.verifyEqual(pos.z,  0.1,'AbsTol', 1e-9);
        end

        function testPositionPersistsAcrossInstances(testCase)
            % Mirrors the real stage: a new MockStageController() created
            % on the next "Launch VSX" still sees the previous position.
            stage1 = MockStageController();
            stage1.connect();
            stage1.moveX(10);

            stage2 = MockStageController();
            stage2.connect();
            pos = stage2.getPosition();
            testCase.verifyEqual(pos.x, 10, 'AbsTol', 1e-9);
        end

        function testMoveBeforeConnectErrors(testCase)
            stage = MockStageController();
            testCase.verifyError(@() stage.moveX(1), ...
                'MockStageController:notConnected');
        end

    end

    %% ── ScanControlPanel (TESTING mode) ──────────────────────────────
    methods (Test)

        function testFullSixLaneCycle(testCase)
            % Drive ScanControlPanel(true) through Launch -> Reposition
            % six times and verify progress, sweep count, and the
            % per-sweep lateral-distance tag passed to saveRF_dbz_txt.

            fig = ScanControlPanel(true);
            testCase.addTeardown(@() delete(fig));

            hLaunch = findobj(fig, 'Text', 'Launch VSX');
            hRepos  = findobj(fig, 'Text', 'Reposition Probe → next lane');
            hProgress = findall(fig, 'Type', 'uilabel', ...
                'Position', [145 475 170 22]);

            testCase.verifyEqual(hProgress.Text, '0 / 6');

            for lane = 1:6
                % ── Launch VSX (runs SetUpMock.m synchronously) ──────
                hLaunch.ButtonPushedFcn(hLaunch, []);

                lateralY = evalin('base', 'sweepLateralY_mm');
                testCase.verifyEqual(lateralY, (lane-1) * 6.9, 'AbsTol', 1e-9);

                % Track the file SetUpMock/saveRF_dbz_txt wrote, for cleanup
                files = dir(sprintf( ...
                    'E:\\issac\\chip_point_simu_txt_save%s\\*%.1fmm*', ...
                    datestr(now,'dd-mmmm-yyyy'), lateralY));
                for f = 1:numel(files)
                    testCase.CreatedFiles{end+1} = ...
                        fullfile(files(f).folder, files(f).name);
                end

                if lane < 6
                    hRepos.ButtonPushedFcn(hRepos, []);
                    testCase.verifyEqual(hProgress.Text, ...
                        sprintf('%d / 6', lane));
                    % Launch should re-enable for the next lane without
                    % needing the Reset button (regression check).
                    testCase.verifyEqual(char(hLaunch.Enable), 'on');
                end
            end

            % Final reposition completes the 6th lane
            hRepos.ButtonPushedFcn(hRepos, []);
            testCase.verifyEqual(hProgress.Text, '6 / 6');

            % Stage moved 6 lanes worth of Y (0, 6.9, ..., 5*6.9) plus the
            % 6th reposition's +6.9mm = 6 * 6.9mm total
            stage = evalin('base', 'stage');
            pos = stage.getPosition();
            testCase.verifyEqual(pos.y, 6 * 6.9, 'AbsTol', 1e-6);
        end

        function testResetDoesNotZeroSweepCountMidSession(testCase)
            fig = ScanControlPanel(true);
            testCase.addTeardown(@() delete(fig));

            hLaunch = findobj(fig, 'Text', 'Launch VSX');
            hRepos  = findobj(fig, 'Text', 'Reposition Probe → next lane');
            hReset  = findobj(fig, 'Text', 'Reset / Relaunch VSX');
            hProgress = findall(fig, 'Type', 'uilabel', ...
                'Position', [145 475 170 22]);

            % Lane 1
            hLaunch.ButtonPushedFcn(hLaunch, []);
            files = dir(sprintf( ...
                'E:\\issac\\chip_point_simu_txt_save%s\\*0.0mm*', ...
                datestr(now,'dd-mmmm-yyyy')));
            for f = 1:numel(files)
                testCase.CreatedFiles{end+1} = fullfile(files(f).folder, files(f).name);
            end

            hRepos.ButtonPushedFcn(hRepos, []);
            testCase.verifyEqual(hProgress.Text, '1 / 6');

            % Press Reset/Relaunch mid-session — progress must stay at 1/6
            hReset.ButtonPushedFcn(hReset, []);
            testCase.verifyEqual(hProgress.Text, '1 / 6');
            testCase.verifyEqual(char(hLaunch.Enable), 'on');

            % Next launch should use the lane-2 lateral tag, not 0.0mm
            hLaunch.ButtonPushedFcn(hLaunch, []);
            lateralY = evalin('base', 'sweepLateralY_mm');
            testCase.verifyEqual(lateralY, 6.9, 'AbsTol', 1e-9);

            files = dir(sprintf( ...
                'E:\\issac\\chip_point_simu_txt_save%s\\*6.9mm*', ...
                datestr(now,'dd-mmmm-yyyy')));
            for f = 1:numel(files)
                testCase.CreatedFiles{end+1} = fullfile(files(f).folder, files(f).name);
            end
        end

        function testNoDuplicatePanelOnRelaunch(testCase)
            fig1 = ScanControlPanel(true);
            fig2 = ScanControlPanel(true);
            testCase.addTeardown(@() delete(fig2));

            testCase.verifyFalse(isvalid(fig1), ...
                'Relaunching ScanControlPanel should close the previous window.');
            panels = findall(groot, 'Type', 'figure', 'Tag', 'ScanControlPanel');
            testCase.verifyEqual(numel(panels), 1);
        end

    end

    %% ── StageJogPanel + ScanControlPanel sharing / busy-lock ─────────
    methods (Test)

        function testJogPanelSharesStageAndRespectsBusyFlag(testCase)
            scFig = ScanControlPanel(true);
            testCase.addTeardown(@() delete(scFig));

            jogFig = StageJogPanel();
            testCase.addTeardown(@() delete(jogFig));

            % Same stage object shared via base workspace
            stage = evalin('base', 'stage');
            testCase.verifyClass(stage, 'MockStageController');

            hUp = findobj(jogFig, 'Text', char(9650)); % -X
            hStepEdit = findall(jogFig, 'Type', 'uieditfield');

            hStepEdit.Value = 5;

            % Not busy: jog should move the stage
            hUp.ButtonPushedFcn(hUp, []);
            pos = stage.getPosition();
            testCase.verifyEqual(pos.x, -5, 'AbsTol', 1e-9);

            % Simulate VSX sweep in progress
            assignin('base', 'sweepInProgress', true);
            hUp.ButtonPushedFcn(hUp, []);
            pos = stage.getPosition();
            testCase.verifyEqual(pos.x, -5, 'AbsTol', 1e-9, ...
                'Jog must be ignored while sweepInProgress is true.');

            assignin('base', 'sweepInProgress', false);
        end

    end

end
