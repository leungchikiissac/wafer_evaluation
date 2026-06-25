%% scan_animation.m
% Animates the probe movement pattern for a 6-lane wafer scan.
%
% Motion parameters (from ScanControlPanel + SetUp script):
%   X sweep : 60 mm per lane, 0.05 mm steps (1200 positions)
%   Y step  : 6.9 mm between lanes
%   Lanes   : 6  →  total Y coverage = 41.4 mm

N_LANES    = 6;
SWEEP_MM   = 60;
Y_STEP_MM  = 6.9;

SWEEP_ANIM_STEPS = 200;   % animation frames per sweep (coarsened from 1200)
REPOS_STEPS      = 40;    % frames for X-return + Y-advance

%% ── Figure setup ─────────────────────────────────────────────────────────
fig = figure(700); clf;
fig.Position = [100 100 820 520];

ax = axes('Parent', fig);
hold(ax, 'on');
grid(ax, 'on');
box(ax, 'on');
ax.XLim = [-6 68];
ax.YLim = [-3 (N_LANES - 1) * Y_STEP_MM + 3];
xlabel(ax, 'X  (mm) — sweep direction');
ylabel(ax, 'Y  (mm) — lateral (lane spacing 6.9 mm)');
title(ax, 'Probe Movement  —  6-lane wafer scan');
ax.FontSize = 11;

lane_colors = cool(N_LANES);

% Lane start markers and labels
for k = 1:N_LANES
    y = (k - 1) * Y_STEP_MM;
    plot(ax, 0, y, 's', 'Color', lane_colors(k,:), ...
         'MarkerFaceColor', lane_colors(k,:), 'MarkerSize', 7);
    text(ax, -5.5, y, sprintf('Lane %d', k), ...
         'FontSize', 9, 'HorizontalAlignment', 'right', ...
         'Color', lane_colors(k,:));
end

% Scan area outline
rectangle(ax, 'Position', [0, 0, SWEEP_MM, (N_LANES-1)*Y_STEP_MM], ...
          'EdgeColor', [0.7 0.7 0.7], 'LineStyle', '--');

% Probe marker (drawn last so it's on top)
hProbe = plot(ax, 0, 0, 'o', ...
              'MarkerSize', 13, 'LineWidth', 2, ...
              'MarkerFaceColor', [1 0.3 0.1], ...
              'MarkerEdgeColor', [0.6 0 0]);

% Info text
hInfo = text(ax, 34, (N_LANES - 0.3) * Y_STEP_MM, '', ...
             'FontSize', 10, 'HorizontalAlignment', 'center', ...
             'BackgroundColor', [0.97 0.97 0.97], ...
             'EdgeColor', [0.7 0.7 0.7]);

drawnow;

%% ── Animation ────────────────────────────────────────────────────────────
x_sweep = linspace(0, SWEEP_MM, SWEEP_ANIM_STEPS);

for lane = 1:N_LANES
    y_cur  = (lane - 1) * Y_STEP_MM;
    color  = lane_colors(lane, :);
    hInfo.String = sprintf('Lane %d / %d  —  sweeping X', lane, N_LANES);

    % ── Forward sweep ────────────────────────────────────────────────────
    trail_h = plot(ax, x_sweep(1), y_cur, '-', ...
                   'Color', color, 'LineWidth', 2.5);
    for i = 1:SWEEP_ANIM_STEPS
        trail_h.XData = x_sweep(1:i);
        trail_h.YData = y_cur * ones(1, i);
        hProbe.XData  = x_sweep(i);
        hProbe.YData  = y_cur;
        drawnow limitrate;
    end

    % Solidify completed lane
    delete(trail_h);
    plot(ax, [0 SWEEP_MM], [y_cur y_cur], '-', ...
         'Color', color, 'LineWidth', 2.5);
    % End-of-lane marker
    plot(ax, SWEEP_MM, y_cur, 'd', ...
         'Color', color, 'MarkerFaceColor', color, 'MarkerSize', 7);

    if lane == N_LANES
        break;
    end

    % ── Reposition: return X ─────────────────────────────────────────────
    hInfo.String = sprintf('Lane %d done  —  returning X (60 mm)', lane);
    x_return = linspace(SWEEP_MM, 0, REPOS_STEPS);
    for i = 1:REPOS_STEPS
        hProbe.XData = x_return(i);
        hProbe.YData = y_cur;
        drawnow limitrate;
    end

    % ── Reposition: advance Y ────────────────────────────────────────────
    y_next = lane * Y_STEP_MM;
    hInfo.String = sprintf('Lane %d done  —  advancing Y (+%.1f mm)', lane, Y_STEP_MM);
    % Draw reposition path
    hRepos = plot(ax, 0, y_cur, '--', 'Color', [0.55 0.55 0.55], 'LineWidth', 1.2);
    y_travel = linspace(y_cur, y_next, REPOS_STEPS);
    for i = 1:REPOS_STEPS
        hRepos.YData = [y_cur y_travel(i)];
        hProbe.XData = 0;
        hProbe.YData = y_travel(i);
        drawnow limitrate;
    end
    % Keep a small arrow stub visible
    plot(ax, [0 0], [y_cur y_next], '--', 'Color', [0.55 0.55 0.55], 'LineWidth', 1.2);
    delete(hRepos);
end

hInfo.String = sprintf('Scan complete  —  %d lanes  |  X=%.0f mm  Y=%.1f mm', ...
                       N_LANES, SWEEP_MM, (N_LANES-1)*Y_STEP_MM);
hProbe.MarkerFaceColor = [0.2 0.7 0.2];   % turn green when done
hProbe.MarkerEdgeColor = [0 0.4 0];
