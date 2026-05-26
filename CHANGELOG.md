# Changelog

## [Unreleased]

### Added
- `core/` C++ layer: `MotionStageAPI` and `VantageInterface` with full error handling
- `core/CMakeLists.txt` for building shared + static libraries
- `core/tests/` unit tests (no hardware required)
- `python/stage/StageController.py` — high-level Python wrapper for FMC4030
- `python/vantage/VantageClient.py` — Python wrapper for Vantage C core
- `python/orchestration/ScanOrchestrator.py` — step-and-shoot scan coordinator
- `python/tests/` pytest test suite
- `matlab/motion/StageController.m` — MATLAB class for FMC4030
- `matlab/motion/move3dstage.m` — Verasonics external-process callback (uses StageController)
- `matlab/motion/move3dstage_use.m` — standalone usage example
- `matlab/acquisition/SetUpL38_22v_flashangles_firsthalf_PI_3d_stage_260120.m`
- `matlab/acquisition/saveRF_dbz_txt.m`
- `matlab/mex/mex_motion_stage.cpp` — MEX wrapper around C core
- `matlab/mex/build_mex.m` — MEX build script
- `matlab/callbacks/MoveBatchSaveCallback.m`
- `matlab/processing/reconstructImage.m` — delay-and-sum reconstruction
- `vendor/FMC4030/FMC4030-Dll.h` — reconstructed vendor header
- `config/scan_params.json` — single source of truth for all parameters

## [0.1.0] — 2026-01-26

### Added
- Initial acquisition scripts and motion stage prototyping
