// MotionStageAPI.cpp
// C++ implementation of the public C stage API.
// Wraps FMC4030 DLL calls with polling, verification, error handling.

#include "MotionStageAPI.h"
#include <windows.h>
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

struct DeviceState {
    bool        connected = false;
    FMC4030Dll  dll;
};

static std::unordered_map<int, DeviceState> g_devices;
static const char* DLL_PATH = "FMC4030-Dll.dll";

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

static int checkDllStatus(int status, const char* context) {
    if (status != 0) {
        fprintf(stderr, "[StageAPI] FMC4030 error in [%s]: code %d\n",
                context, status);
        return STAGE_ERR_API;
    }
    return STAGE_OK;
}

static int waitForStop(DeviceState& dev, int device_id, StageAxis axis,
                       float timeout_s, float* final_pos_out) {
    using clock = std::chrono::steady_clock;
    auto t_start = clock::now();

    while (true) {
        auto elapsed = std::chrono::duration<float>(
            clock::now() - t_start).count();

        if (elapsed >= timeout_s) {
            if (final_pos_out)
                dev.dll.getPos(device_id, (int)axis, final_pos_out);
            fprintf(stderr,
                "[StageAPI] Axis %d movement timed out after %.1f s. "
                "Last pos: %.4f mm\n",
                (int)axis, timeout_s,
                final_pos_out ? *final_pos_out : -999.f);
            return STAGE_ERR_TIMEOUT;
        }

        int stopped = dev.dll.isStop(device_id, (int)axis);
        if (stopped == 1) {
            if (final_pos_out) {
                int s = dev.dll.getPos(device_id, (int)axis, final_pos_out);
                if (s != 0) return STAGE_ERR_API;
            }
            return STAGE_OK;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

// ── Public API implementation ─────────────────────────────────────────────

extern "C" {

STAGE_API int Stage_Connect(int device_id, const char* ip, int port) {
    if (!ip) return STAGE_ERR_NULL_PTR;

    auto& dev = g_devices[device_id];
    if (dev.connected) return STAGE_OK;

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
    if (params->vel_mm_s    <= 0) return STAGE_ERR_INVALID_PARAM;
    if (params->accel_mm_s2 <= 0) return STAGE_ERR_INVALID_PARAM;

    auto it = g_devices.find(device_id);
    if (it == g_devices.end() || !it->second.connected)
        return STAGE_ERR_NOT_CONNECTED;
    auto& dev = it->second;

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

    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    float final_pos = 0.f;
    r = waitForStop(dev, device_id, axis,
                    params->timeout_s, &final_pos);
    if (r != STAGE_OK) return r;

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
