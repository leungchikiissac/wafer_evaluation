# wafer_evaluation

System Architecture
```
┌─────────────────────────────────────────────────────────────────┐
│                    Physical Hardware                             │
│   Verasonics Vantage NXT          FMC4030 Motion Stage          │
│   (ultrasound acquisition)        (XYZ positioning)             │
└──────────────┬──────────────────────────────┬───────────────────┘
               │ PCIe / DLL                   │ Ethernet / DLL
               ▼                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                     Core Layer (C/C++)                           │
│                                                                  │
│   MotionStageAPI (C++)          VantageInterface (C++)           │
│   └── wraps FMC4030 DLL         └── wraps Vantage NXT DLL/SDK   │
│   └── polling, error handling   └── trigger, sync, data         │
│   └── exposes clean C API       └── exposes clean C API         │
│                                                                  │
│   Compiled to:  libMotionStage.dll / .so                        │
│                 libVantageInterface.dll / .so                    │
└───────────────┬──────────────────────────────────────────────────┘
                │ shared library (ctypes / mex)
       ┌────────┴────────┐
       ▼                 ▼
┌─────────────┐   ┌──────────────────────────────────────────────┐
│   Python    │   │                  MATLAB                       │
│             │   │                                               │
│ StageCtrl   │   │  SetUp scripts    move3dstage.m               │
│ .py         │   │  Callbacks        MEX wrapper                 │
│ (ctypes)    │   │  Processing       (calls C library)           │
└─────────────┘   └──────────────────────────────────────────────┘
       │                         │
       └──────────┬──────────────┘
                  ▼
         Orchestration Layer
         (Python or MATLAB)
         coordinates both systems
```

Repository Structure
```
wafer_evaluation_/
  │
  ├── README.md
  ├── CHANGELOG.md
  ├── config/
  │   └── scan_params.json          ← single source of truth
  │
  ├── core/                         ← C/C++ core layer
  │   ├── CMakeLists.txt
  │   ├── include/
  │   │   ├── MotionStageAPI.h      ← public C header (used by Python + MATLAB)
  │   │   └── VantageInterface.h    ← public C header
  │   ├── src/
  │   │   ├── MotionStageAPI.cpp
  │   │   └── VantageInterface.cpp
  │   ├── tests/
  │   │   ├── test_motion.cpp
  │   │   ├── test_vantage.cpp
  │   │   └── test_acqsdk_smoke.cpp ← no-hardware smoke test for Verasonics Acquisition SDK
  │   └── build/                    ← gitignored build output
  │
  ├── python/
  │   ├── requirements.txt
  │   ├── stage/
  │   │   ├── __init__.py
  │   │   └── StageController.py    ← wraps core via ctypes
  │   ├── vantage/
  │   │   ├── __init__.py
  │   │   └── VantageClient.py      ← wraps core via ctypes
  │   ├── orchestration/
  │   │   └── ScanOrchestrator.py   ← coordinates stage + vantage
  │   └── tests/
  │       ├── test_stage.py
  │       └── test_orchestrator.py
  │
  ├── matlab/
  │   ├── acquisition/
  │   │   ├── SetUpL38_22v_...m
  │   │   └── saveRF_dbz_txt.m
  │   ├── motion/
  │   │   ├── move3dstage.m         ← calls MEX or Python
  │   │   └── move3dstage_use.m
  │   ├── mex/
  │   │   ├── mex_motion_stage.cpp  ← MEX wrapper around core C API
  │   │   └── build_mex.m           ← script to compile MEX
  │   ├── callbacks/
  │   │   └── MoveBatchSaveCallback.m
  │   └── processing/
  │       └── reconstructImage.m
  │
  ├── docs/
  │   ├── Lab_Protocol_Formatted.docx
  │   ├── architecture.md
  │   └── api/
  │       ├── MotionStageAPI.md
  │       ├── VantageInterface.md
  │       └── wafer_eval_api.md     ← high-level WaferEvalAPI spec (Python)
  │
  └── vendor/
      ├── FMC4030/
      │   ├── FMC4030-Dll.dll       ← git-lfs
      │   └── FMC4030-Dll.h
      └── Vantage/
          ├── license.enc           ← required at this path for the Acquisition SDK
          ├── System/                ← shared runtime DLLs (Common, Hal, libwinpthread)
          └── vsacqsdk/              ← Verasonics Acquisition SDK (includes/, libs/, examples/, docs/)
```

## Acquisition SDK (Verasonics) Integration

The Verasonics Acquisition SDK lives under `vendor/Vantage/vsacqsdk/`. It depends on
shared runtime DLLs in `vendor/Vantage/System/` (`libVerasonicsCommon.dll`,
`libVerasonicsHal.dll`, `libwinpthread-1.dll`) and a license file at
`vendor/Vantage/license.enc`.

`core/tests/test_acqsdk_smoke.cpp` (CMake target `test_acqsdk_smoke`, test
`AcqSdkSmoke`) is a no-hardware smoke test that checks the SDK loads and
reports version/product info correctly. The build automatically copies the
required runtime DLLs and `license.enc` next to the test executable.

## WaferEvalAPI

A high-level Python API for wafer evaluation scans (connect, move probe,
B-mode preview, scan a region, disconnect) is specified in
[`docs/api/wafer_eval_api.md`](docs/api/wafer_eval_api.md). It builds on
`StageController`, `VantageClient`, and `ScanOrchestrator`. Implementation is
not yet started.

Core C++ Layer Design
MotionStageAPI.h — Public C Header
The header exposes a pure C interface (not C++) so that both Python ctypes and MATLAB MEX can call it without C++ ABI complications:
```c
/* MotionStageAPI.h
 * Pure C interface to the FMC4030 motion stage.
 * Compiled as C++ internally but exported as C symbols.
 *
 * All functions return:
 *   STAGE_OK  (0)  on success
 *   negative value on error (see StageErrorCode enum)
 */

#ifndef MOTION_STAGE_API_H
#define MOTION_STAGE_API_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define STAGE_API __declspec(dllexport)
#else
  #define STAGE_API __attribute__((visibility("default")))
#endif

/* ── Error codes ──────────────────────────────────────────── */
typedef enum {
    STAGE_OK                =  0,
    STAGE_ERR_NOT_CONNECTED = -1,
    STAGE_ERR_MOVE_FAILED   = -2,
    STAGE_ERR_TIMEOUT       = -3,
    STAGE_ERR_POSITION      = -4,
    STAGE_ERR_API           = -5,   /* FMC4030 DLL returned error   */
    STAGE_ERR_NULL_PTR      = -6,
    STAGE_ERR_INVALID_AXIS  = -7,
    STAGE_ERR_INVALID_PARAM = -8,
} StageErrorCode;

/* ── Axis identifiers ─────────────────────────────────────── */
typedef enum { AXIS_X = 0, AXIS_Y = 1, AXIS_Z = 2 } StageAxis;

/* ── Move mode ────────────────────────────────────────────── */
typedef enum { MOVE_RELATIVE = 1, MOVE_ABSOLUTE = 2 } MoveMode;

/* ── Stop mode ────────────────────────────────────────────── */
typedef enum { STOP_DECEL = 1, STOP_IMMEDIATE = 2 } StopMode;

/* ── Position struct ──────────────────────────────────────── */
typedef struct {
    float x;
    float y;
    float z;
} StagePosition;

/* ── Motion parameters ────────────────────────────────────── */
typedef struct {
    float vel_mm_s;         /* velocity        mm/s  */
    float accel_mm_s2;      /* acceleration    mm/s² */
    float decel_mm_s2;      /* deceleration    mm/s² */
    float timeout_s;        /* movement timeout  s   */
    float tolerance_mm;     /* position tolerance mm */
} MotionParams;

/* ── Connection ───────────────────────────────────────────── */
STAGE_API int Stage_Connect(int device_id, const char* ip, int port);
STAGE_API int Stage_Disconnect(int device_id);
STAGE_API int Stage_IsConnected(int device_id);

/* ── Single-axis movement ─────────────────────────────────── */
STAGE_API int Stage_Move(int device_id,
                         StageAxis axis,
                         float distance_mm,
                         MoveMode mode,
                         const MotionParams* params);

/* ── Convenience wrappers ─────────────────────────────────── */
STAGE_API int Stage_MoveX(int device_id, float distance_mm,
                           const MotionParams* params);
STAGE_API int Stage_MoveY(int device_id, float distance_mm,
                           const MotionParams* params);
STAGE_API int Stage_MoveZ(int device_id, float distance_mm,
                           const MotionParams* params);

/* ── Position query ───────────────────────────────────────── */
STAGE_API int Stage_GetPosition(int device_id, StagePosition* pos_out);
STAGE_API int Stage_GetAxisPosition(int device_id,
                                    StageAxis axis,
                                    float* pos_out);

/* ── Axis status ──────────────────────────────────────────── */
STAGE_API int Stage_IsAxisStopped(int device_id, StageAxis axis);
STAGE_API int Stage_Stop(int device_id, StageAxis axis, StopMode mode);
STAGE_API int Stage_Home(int device_id, StageAxis axis,
                          float speed, float accel,
                          float fall_step_mm, int direction);

/* ── Error string ─────────────────────────────────────────── */
STAGE_API const char* Stage_GetErrorString(int error_code);

#ifdef __cplusplus
}
#endif

#endif /* MOTION_STAGE_API_H */
```

MotionStageAPI.cpp — Implementation
```cpp
// MotionStageAPI.cpp
// C++ implementation of the public C stage API.
// Wraps FMC4030 DLL calls with polling, verification, error handling.

#include "MotionStageAPI.h"
#include <windows.h>       // for WinDLL loading
#include <unordered_map>
#include <string>
#include <chrono>
#include <thread>
#include <cmath>
#include <cstdio>

// ── FMC4030 DLL function pointer types ────────────────────────────────────
typedef int (*Fn_Open)     (int, const char*, int);
typedef int (*Fn_Close)    (int);
typedef int (*Fn_Jog)      (int, int, float, float, float, float, int);
typedef int (*Fn_IsStop)   (int, int);
typedef int (*Fn_GetPos)   (int, int, float*);
typedef int (*Fn_Stop)     (int, int, int);
typedef int (*Fn_Home)     (int, int, float, float, float, int);

struct FMC4030Dll {
    HMODULE     handle  = nullptr;
    Fn_Open     open    = nullptr;
    Fn_Close    close   = nullptr;
    Fn_Jog      jog     = nullptr;
    Fn_IsStop   isStop  = nullptr;
    Fn_GetPos   getPos  = nullptr;
    Fn_Stop     stop    = nullptr;
    Fn_Home     home    = nullptr;

    bool loaded() const { return handle != nullptr; }
};

// ── Per-device state ───────────────────────────────────────────────────────
struct DeviceState {
    bool        connected = false;
    FMC4030Dll  dll;
};

static std::unordered_map<int, DeviceState> g_devices;
static const char* DLL_PATH = "FMC4030-Dll.dll";   // configurable

// ── DLL loader ────────────────────────────────────────────────────────────
static int loadDll(FMC4030Dll& dll) {
    dll.handle = LoadLibraryA(DLL_PATH);
    if (!dll.handle) return STAGE_ERR_API;

    #define LOAD(name, type) \
        dll.name = (type)GetProcAddress(dll.handle, "FMC4030_" #name); \
        if (!dll.name) { FreeLibrary(dll.handle); dll.handle=nullptr; return STAGE_ERR_API; }

    LOAD(Open_Device,         Fn_Open)
    LOAD(Close_Device,        Fn_Close)
    LOAD(Jog_Single_Axis,     Fn_Jog)
    LOAD(Check_Axis_Is_Stop,  Fn_IsStop)
    LOAD(Get_Axis_Current_Pos,Fn_GetPos)
    LOAD(Stop_Single_Axis,    Fn_Stop)
    LOAD(Home_Single_Axis,    Fn_Home)
    #undef LOAD

    return STAGE_OK;
}

// ── Return value checker ──────────────────────────────────────────────────
static int checkDllStatus(int status, const char* context) {
    if (status != 0) {
        fprintf(stderr, "[StageAPI] FMC4030 error in [%s]: code %d\n",
                context, status);
        return STAGE_ERR_API;
    }
    return STAGE_OK;
}

// ── Polling helper ────────────────────────────────────────────────────────
static int waitForStop(DeviceState& dev, int device_id, StageAxis axis,
                       float timeout_s, float* final_pos_out) {
    using clock = std::chrono::steady_clock;
    auto t_start = clock::now();

    while (true) {
        auto elapsed = std::chrono::duration<float>(
            clock::now() - t_start).count();

        if (elapsed >= timeout_s) {
            // Read last known position before returning timeout
            if (final_pos_out)
                dev.dll.getPos(device_id, (int)axis, final_pos_out);
            fprintf(stderr,
                "[StageAPI] Axis %d movement timed out after %.1f s. "
                "Last pos: %.4f mm\n",
                (int)axis, timeout_s,
                final_pos_out ? *final_pos_out : -999.f);
            return STAGE_ERR_TIMEOUT;
        }

        // Hardware-native stop check
        int stopped = dev.dll.isStop(device_id, (int)axis);
        if (stopped == 1) {
            // Axis confirmed stopped — read final position
            if (final_pos_out) {
                int s = dev.dll.getPos(device_id, (int)axis, final_pos_out);
                if (s != 0) return STAGE_ERR_API;
            }
            return STAGE_OK;
        }

        std::this_thread::sleep_for(
            std::chrono::milliseconds(20));  // 20 ms poll interval
    }
}

// ── Public API implementation ─────────────────────────────────────────────

extern "C" {

STAGE_API int Stage_Connect(int device_id, const char* ip, int port) {
    if (!ip) return STAGE_ERR_NULL_PTR;

    auto& dev = g_devices[device_id];
    if (dev.connected) return STAGE_OK;  // already connected

    // Load DLL if needed
    if (!dev.dll.loaded()) {
        int r = loadDll(dev.dll);
        if (r != STAGE_OK) return r;
    }

    int status = dev.dll.open(device_id, ip, port);
    int r = checkDllStatus(status, "FMC4030_Open_Device");
    if (r == STAGE_OK) {
        dev.connected = true;
        printf("[StageAPI] Connected to device %d at %s:%d\n",
               device_id, ip, port);
    }
    return r;
}

STAGE_API int Stage_Disconnect(int device_id) {
    auto it = g_devices.find(device_id);
    if (it == g_devices.end()) return STAGE_OK;

    auto& dev = it->second;
    if (!dev.connected) return STAGE_OK;

    // Must call Close_Device before exit — per API documentation
    int status = dev.dll.close(device_id);
    dev.connected = false;
    printf("[StageAPI] Disconnected device %d\n", device_id);
    return checkDllStatus(status, "FMC4030_Close_Device");
}

STAGE_API int Stage_IsConnected(int device_id) {
    auto it = g_devices.find(device_id);
    return (it != g_devices.end() && it->second.connected) ? 1 : 0;
}

STAGE_API int Stage_Move(int device_id,
                          StageAxis axis,
                          float distance_mm,
                          MoveMode mode,
                          const MotionParams* params) {

    if (!params) return STAGE_ERR_NULL_PTR;
    if (axis < AXIS_X || axis > AXIS_Z) return STAGE_ERR_INVALID_AXIS;
    if (params->vel_mm_s   <= 0) return STAGE_ERR_INVALID_PARAM;
    if (params->accel_mm_s2 <= 0) return STAGE_ERR_INVALID_PARAM;

    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    auto& dev = it->second;

    // ── 1. Send jog command ───────────────────────────────────
    int status = dev.dll.jog(
        device_id,
        (int)axis,
        distance_mm,
        params->vel_mm_s,
        params->accel_mm_s2,
        params->decel_mm_s2,
        (int)mode
    );
    int r = checkDllStatus(status, "FMC4030_Jog_Single_Axis");
    if (r != STAGE_OK) return r;

    // ── 2. Startup delay ──────────────────────────────────────
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // ── 3. Wait until stopped ─────────────────────────────────
    float final_pos = 0.f;
    r = waitForStop(dev, device_id, axis,
                    params->timeout_s, &final_pos);
    if (r != STAGE_OK) return r;

    // ── 4. Position verification (absolute moves only) ────────
    if (mode == MOVE_ABSOLUTE) {
        float error = fabsf(final_pos - distance_mm);
        if (error > params->tolerance_mm) {
            fprintf(stderr,
                "[StageAPI] Position error %.4f mm on axis %d "
                "(target=%.4f, actual=%.4f, tolerance=%.4f)\n",
                error, (int)axis,
                distance_mm, final_pos, params->tolerance_mm);
            return STAGE_ERR_POSITION;
        }
    }

    printf("[StageAPI] Axis %d move complete | pos=%.4f mm\n",
           (int)axis, final_pos);
    return STAGE_OK;
}

STAGE_API int Stage_MoveX(int device_id, float d, const MotionParams* p) {
    return Stage_Move(device_id, AXIS_X, d, MOVE_RELATIVE, p);
}
STAGE_API int Stage_MoveY(int device_id, float d, const MotionParams* p) {
    return Stage_Move(device_id, AXIS_Y, d, MOVE_RELATIVE, p);
}
STAGE_API int Stage_MoveZ(int device_id, float d, const MotionParams* p) {
    return Stage_Move(device_id, AXIS_Z, d, MOVE_RELATIVE, p);
}

STAGE_API int Stage_GetPosition(int device_id, StagePosition* pos_out) {
    if (!pos_out) return STAGE_ERR_NULL_PTR;
    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    auto& dev = it->second;

    int r = 0;
    r |= checkDllStatus(dev.dll.getPos(device_id, AXIS_X, &pos_out->x),
                         "GetPos X");
    r |= checkDllStatus(dev.dll.getPos(device_id, AXIS_Y, &pos_out->y),
                         "GetPos Y");
    r |= checkDllStatus(dev.dll.getPos(device_id, AXIS_Z, &pos_out->z),
                         "GetPos Z");
    return (r == 0) ? STAGE_OK : STAGE_ERR_API;
}

STAGE_API int Stage_GetAxisPosition(int device_id,
                                     StageAxis axis, float* pos_out) {
    if (!pos_out) return STAGE_ERR_NULL_PTR;
    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    return checkDllStatus(
        it->second.dll.getPos(device_id, (int)axis, pos_out),
        "FMC4030_Get_Axis_Current_Pos");
}

STAGE_API int Stage_IsAxisStopped(int device_id, StageAxis axis) {
    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected) return 0;
    return it->second.dll.isStop(device_id, (int)axis);
}

STAGE_API int Stage_Stop(int device_id, StageAxis axis, StopMode mode) {
    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    return checkDllStatus(
        it->second.dll.stop(device_id, (int)axis, (int)mode),
        "FMC4030_Stop_Single_Axis");
}

STAGE_API int Stage_Home(int device_id, StageAxis axis,
                          float speed, float accel,
                          float fall_step_mm, int direction) {
    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    auto& dev = it->second;

    int status = dev.dll.home(device_id, (int)axis,
                               speed, accel, fall_step_mm, direction);
    int r = checkDllStatus(status, "FMC4030_Home_Single_Axis");
    if (r != STAGE_OK) return r;

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    float final_pos = 0.f;
    return waitForStop(dev, device_id, axis, 30.0f, &final_pos);
}

STAGE_API const char* Stage_GetErrorString(int error_code) {
    switch (error_code) {
        case  STAGE_OK:                return "Success";
        case  STAGE_ERR_NOT_CONNECTED: return "Not connected";
        case  STAGE_ERR_MOVE_FAILED:   return "Move command failed";
        case  STAGE_ERR_TIMEOUT:       return "Movement timed out";
        case  STAGE_ERR_POSITION:      return "Position tolerance exceeded";
        case  STAGE_ERR_API:           return "FMC4030 DLL returned error";
        case  STAGE_ERR_NULL_PTR:      return "Null pointer argument";
        case  STAGE_ERR_INVALID_AXIS:  return "Invalid axis identifier";
        case  STAGE_ERR_INVALID_PARAM: return "Invalid parameter value";
        default:                       return "Unknown error";
    }
}

} // extern "C"
```

How Each Language Connects to the Core
Python — via ctypes
```python
# python/stage/StageController.py (revised)
# Now wraps the C core library instead of FMC4030 DLL directly

from ctypes import CDLL, WinDLL, Structure, c_int, c_float, byref
import platform, json, pathlib

class StagePosition(Structure):
    _fields_ = [("x", c_float), ("y", c_float), ("z", c_float)]

class MotionParams(Structure):
    _fields_ = [
        ("vel_mm_s",    c_float),
        ("accel_mm_s2", c_float),
        ("decel_mm_s2", c_float),
        ("timeout_s",   c_float),
        ("tolerance_mm",c_float),
    ]

class StageController:
    def __init__(self, lib_path: str, device_id=1,
                 ip="192.168.0.30", port=8088, config_path=None):

        # Load compiled core library
        if platform.system() == "Windows":
            self._lib = WinDLL(lib_path)
        else:
            self._lib = CDLL(lib_path)

        self._id = device_id

        # Load params from config if provided
        if config_path:
            cfg = json.loads(pathlib.Path(config_path).read_text())
            s = cfg["stage"]
            self._params = MotionParams(
                s["velocity_mm_s"], s["accel_mm_s2"],
                s["decel_mm_s2"],   s["timeout_s"],
                s["tolerance_mm"]
            )
        else:
            self._params = MotionParams(80, 200, 200, 5.0, 0.01)

        self._lib.Stage_Connect(self._id,
                                ip.encode("ascii"), port)

    def move_x(self, dist_mm: float):
        r = self._lib.Stage_MoveX(self._id, c_float(dist_mm),
                                   byref(self._params))
        if r != 0:
            raise RuntimeError(
                self._lib.Stage_GetErrorString(r).decode())

    def get_position(self) -> StagePosition:
        pos = StagePosition()
        r   = self._lib.Stage_GetPosition(self._id, byref(pos))
        if r != 0:
            raise RuntimeError(
                self._lib.Stage_GetErrorString(r).decode())
        return pos

    def disconnect(self):
        self._lib.Stage_Disconnect(self._id)

    def __enter__(self):  return self
    def __exit__(self, *_): self.disconnect()
```

MATLAB — via MEX
```cpp
// matlab/mex/mex_motion_stage.cpp
// MEX wrapper: exposes Stage_Move etc. to MATLAB scripts.
// Build with: mex mex_motion_stage.cpp -L../../core/build -lMotionStage

#include "mex.h"
#include "MotionStageAPI.h"
#include <string.h>

void mexFunction(int nlhs, mxArray* plhs[],
                 int nrhs, const mxArray* prhs[]) {

    if (nrhs < 1 || !mxIsChar(prhs[0]))
        mexErrMsgIdAndTxt("StageAPI:input",
                          "First argument must be command string");

    char cmd[64];
    mxGetString(prhs[0], cmd, sizeof(cmd));

    // ── stage_mex('connect', device_id, ip, port) ─────────────
    if (strcmp(cmd, "connect") == 0) {
        int    id   = (int)mxGetScalar(prhs[1]);
        char   ip[32];
        int    port = (int)mxGetScalar(prhs[3]);
        mxGetString(prhs[2], ip, sizeof(ip));
        int r = Stage_Connect(id, ip, port);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:connect",
                              Stage_GetErrorString(r));
    }
    // ── stage_mex('move_x', device_id, dist_mm) ───────────────
    else if (strcmp(cmd, "move_x") == 0) {
        int   id   = (int)mxGetScalar(prhs[1]);
        float dist = (float)mxGetScalar(prhs[2]);
        MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
        int r = Stage_MoveX(id, dist, &p);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:move",
                              Stage_GetErrorString(r));
    }
    // ── stage_mex('get_position', device_id) ──────────────────
    else if (strcmp(cmd, "get_position") == 0) {
        int id = (int)mxGetScalar(prhs[1]);
        StagePosition pos;
        int r = Stage_GetPosition(id, &pos);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:getpos",
                              Stage_GetErrorString(r));
        // Return as [x, y, z] row vector
        plhs[0] = mxCreateDoubleMatrix(1, 3, mxREAL);
        double* out = mxGetPr(plhs[0]);
        out[0] = pos.x; out[1] = pos.y; out[2] = pos.z;
    }
    // ── stage_mex('disconnect', device_id) ────────────────────
    else if (strcmp(cmd, "disconnect") == 0) {
        int id = (int)mxGetScalar(prhs[1]);
        Stage_Disconnect(id);
    }
    else {
        mexErrMsgIdAndTxt("StageAPI:cmd",
                          "Unknown command: %s", cmd);
    }
}
```

Updated move3dstage.m becomes very simple:
```matlab
function move3dstage()
persistent counter
if isempty(counter), counter = 0; end

d_ele = 0.05;   % mm

% Call MEX wrapper (which calls C core, which calls FMC4030 DLL)
stage_mex('move_x', 1, d_ele);

pos = stage_mex('get_position', 1);
fprintf('Step %d | x=%.3f y=%.3f z=%.3f mm\n', ...
        counter+1, pos(1), pos(2), pos(3));

counter = counter + 1;
end
```

Build System — CMakeLists.txt
```cmake
cmake_minimum_required(VERSION 3.16)
project(MotionStageAPI VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

# ── Shared library (used by Python ctypes + MATLAB MEX) ──────
add_library(MotionStage SHARED
    src/MotionStageAPI.cpp
)
target_include_directories(MotionStage PUBLIC include)
target_compile_definitions(MotionStage PRIVATE MOTION_STAGE_EXPORTS)

# ── Static library (for tests and embedding) ─────────────────
add_library(MotionStage_static STATIC
    src/MotionStageAPI.cpp
)
target_include_directories(MotionStage_static PUBLIC include)

# ── Unit tests ────────────────────────────────────────────────
enable_testing()
add_executable(test_motion tests/test_motion.cpp)
target_link_libraries(test_motion MotionStage_static)
add_test(NAME MotionTests COMMAND test_motion)

# Install
install(TARGETS MotionStage DESTINATION lib)
install(FILES include/MotionStageAPI.h DESTINATION include)
```

.gitignore for the Full Monorepo
```gitignore
# ── C/C++ build ──────────────────────────────────────────────
core/build/
*.o
*.obj
*.a
*.lib
*.exp
*.pdb

# ── Python ───────────────────────────────────────────────────
__pycache__/
*.pyc
.venv/
*.egg-info/
.pytest_cache/

# ── MATLAB ───────────────────────────────────────────────────
*.asv
*.mex*
matlab/mex/*.dll
matlab/mex/*.so

# ── Data files (use git-lfs) ─────────────────────────────────
*.mat
*.bin
*.h5

# ── Vendor binaries (git-lfs) ────────────────────────────────
vendor/**/*.dll
vendor/**/*.so

# ── OS ───────────────────────────────────────────────────────
.DS_Store
Thumbs.db
```

Summary
```
Architecture:
  C/C++ core layer  →  wraps FMC4030 DLL
                        polling, error handling, position verification
                        compiled to shared library (.dll / .so)

  Python wrapper    →  ctypes calls to C core
                        high-level StageController class
                        reads config/scan_params.json

  MATLAB wrapper    →  MEX calls to C core
                        simple stage_mex() interface
                        move3dstage.m becomes 5 lines

  config/           →  single source of truth for all parameters
                        all three languages read same JSON

Repo structure:     MONOREPO
  core/             C++ source + CMakeLists.txt
  python/           Python wrappers + tests
  matlab/           MATLAB scripts + MEX wrappers
  docs/             Protocol + API docs
  vendor/           FMC4030 DLL (git-lfs)
  config/           scan_params.json

Key benefit:
  FMC4030 DLL called in ONE place only (C++ core)
  Bug fixed once → Python and MATLAB both benefit
  Parameters changed once → all languages see it
  New language added → just wrap the C header
```