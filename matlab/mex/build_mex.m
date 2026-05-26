% build_mex.m  — compile mex_motion_stage MEX wrapper
%
% Run this script once after building core/ with CMake.
% Prerequisites:
%   1. CMake build complete:  cd core && cmake -B build && cmake --build build
%   2. MATLAB mex compiler configured:  mex -setup C++

% Paths relative to this script
script_dir  = fileparts(mfilename('fullpath'));
repo_root   = fullfile(script_dir, '..', '..');
core_build  = fullfile(repo_root, 'core', 'build');
core_inc    = fullfile(repo_root, 'core', 'include');
mex_src     = fullfile(script_dir, 'mex_motion_stage.cpp');

% Verify directories exist
assert(isfolder(core_build), 'core/build not found — run CMake first');
assert(isfolder(core_inc),   'core/include not found');
assert(isfile(mex_src),      'mex_motion_stage.cpp not found');

fprintf('Building mex_motion_stage...\n');
fprintf('  Source:   %s\n', mex_src);
fprintf('  Includes: %s\n', core_inc);
fprintf('  Libs:     %s\n', core_build);

mex(mex_src, ...
    ['-I', core_inc], ...
    ['-L', core_build], ...
    '-lMotionStage', ...
    '-outdir', script_dir);

fprintf('Build successful: %s\n', fullfile(script_dir, ['mex_motion_stage.', mexext()]));
