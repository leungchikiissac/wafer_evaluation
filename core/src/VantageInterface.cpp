// VantageInterface.cpp
// C++ implementation of the public C Vantage interface.
// Wraps Verasonics Vantage NXT SDK calls.
//
// The Vantage SDK is a MATLAB-based system; this C++ layer provides a
// minimal control interface for trigger/sync/data retrieval via the
// Vantage hardware DLL (VsHal.dll or equivalent).

#include "VantageInterface.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <thread>

// ── Stub SDK function pointer types ───────────────────────────────────────
// Replace with actual Vantage SDK function signatures when integrating.
typedef int  (*Fn_VsInit)     (void*);
typedef int  (*Fn_VsShutdown) (void);
typedef int  (*Fn_VsTrigger)  (void);
typedef int  (*Fn_VsWait)     (float);
typedef int  (*Fn_VsCopy)     (void);
typedef int  (*Fn_VsGetBuf)   (int, void*);
typedef int  (*Fn_VsIsFrozen) (void);

struct VantageSDK {
    HMODULE       handle     = nullptr;
    Fn_VsInit     init       = nullptr;
    Fn_VsShutdown shutdown   = nullptr;
    Fn_VsTrigger  trigger    = nullptr;
    Fn_VsWait     wait       = nullptr;
    Fn_VsCopy     copyBufs   = nullptr;
    Fn_VsGetBuf   getBuf     = nullptr;
    Fn_VsIsFrozen isFrozen   = nullptr;

    bool loaded() const { return handle != nullptr; }
};

static VantageSDK    g_sdk;
static bool          g_initialized = false;
static VantageAcqParams g_params   = {};

// Internal RcvBuffer storage (two buffers: realtime + batch)
static const int MAX_BUFFERS = 2;
struct InternalRcvBuf {
    int16_t* data       = nullptr;
    int      rows       = 0;
    int      cols       = 0;
    int      num_frames = 0;
    int      frame_idx  = 0;
};
static InternalRcvBuf g_rcv_bufs[MAX_BUFFERS];

// ── SDK loader ────────────────────────────────────────────────────────────
static int loadSdk() {
    // Vantage SDK DLL — path must be on system PATH or absolute
    g_sdk.handle = LoadLibraryA("VsHal.dll");
    if (!g_sdk.handle) {
        // When running without hardware, succeed silently (simulation mode)
        fprintf(stderr, "[VantageInterface] VsHal.dll not found — simulation mode\n");
        return VANTAGE_OK;
    }

    #define LOAD(field, sym, type) \
        g_sdk.field = (type)GetProcAddress(g_sdk.handle, sym); \
        if (!g_sdk.field) { \
            fprintf(stderr, "[VantageInterface] Missing symbol: %s\n", sym); \
            FreeLibrary(g_sdk.handle); g_sdk.handle = nullptr; \
            return VANTAGE_ERR_API; \
        }

    LOAD(init,     "VsHal_Initialize",  Fn_VsInit)
    LOAD(shutdown, "VsHal_Shutdown",    Fn_VsShutdown)
    LOAD(trigger,  "VsHal_SoftTrigger", Fn_VsTrigger)
    LOAD(wait,     "VsHal_WaitAcq",     Fn_VsWait)
    LOAD(copyBufs, "VsHal_CopyBuffers", Fn_VsCopy)
    LOAD(getBuf,   "VsHal_GetRcvBuf",   Fn_VsGetBuf)
    LOAD(isFrozen, "VsHal_IsFrozen",    Fn_VsIsFrozen)
    #undef LOAD

    return VANTAGE_OK;
}

static void freeRcvBufs() {
    for (int i = 0; i < MAX_BUFFERS; i++) {
        delete[] g_rcv_bufs[i].data;
        g_rcv_bufs[i] = InternalRcvBuf{};
    }
}

// ── Public API ────────────────────────────────────────────────────────────

extern "C" {

VANTAGE_API int Vantage_Initialize(const VantageAcqParams* params) {
    if (!params) return VANTAGE_ERR_NULL_PTR;
    if (params->num_channels <= 0 || params->samples_per_acq <= 0)
        return VANTAGE_ERR_INVALID_PARAM;

    if (g_initialized) return VANTAGE_OK;

    int r = loadSdk();
    if (r != VANTAGE_OK) return r;

    g_params = *params;

    // Allocate realtime buffer (buffer 0)
    g_rcv_bufs[0].rows       = params->samples_per_acq * params->num_angles;
    g_rcv_bufs[0].cols       = params->num_channels;
    g_rcv_bufs[0].num_frames = params->num_frames;
    g_rcv_bufs[0].data       = new int16_t[
        (size_t)g_rcv_bufs[0].rows * g_rcv_bufs[0].cols * g_rcv_bufs[0].num_frames
    ]();

    // Allocate batch buffer (buffer 1) — same geometry, larger frame count
    g_rcv_bufs[1].rows       = 3 * params->samples_per_acq * params->num_angles;
    g_rcv_bufs[1].cols       = params->num_channels;
    g_rcv_bufs[1].num_frames = params->num_frames;
    g_rcv_bufs[1].data       = new int16_t[
        (size_t)g_rcv_bufs[1].rows * g_rcv_bufs[1].cols * g_rcv_bufs[1].num_frames
    ]();

    if (g_sdk.loaded() && g_sdk.init) {
        r = g_sdk.init((void*)params);
        if (r != 0) {
            freeRcvBufs();
            return VANTAGE_ERR_API;
        }
    }

    g_initialized = true;
    printf("[VantageInterface] Initialized: %d ch x %d samples x %d frames\n",
           params->num_channels, params->samples_per_acq, params->num_frames);
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_Shutdown(void) {
    if (!g_initialized) return VANTAGE_OK;

    if (g_sdk.loaded() && g_sdk.shutdown)
        g_sdk.shutdown();

    freeRcvBufs();
    g_initialized = false;
    printf("[VantageInterface] Shutdown complete\n");
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_IsInitialized(void) {
    return g_initialized ? 1 : 0;
}

VANTAGE_API int Vantage_SoftTrigger(void) {
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (g_sdk.loaded() && g_sdk.trigger)
        return (g_sdk.trigger() == 0) ? VANTAGE_OK : VANTAGE_ERR_API;
    return VANTAGE_OK;  // simulation
}

VANTAGE_API int Vantage_WaitForAcquisition(float timeout_s) {
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (g_sdk.loaded() && g_sdk.wait) {
        int r = g_sdk.wait(timeout_s);
        if (r != 0) return VANTAGE_ERR_TIMEOUT;
    } else {
        // Simulation: fixed delay proportional to frame count
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_CopyBuffers(void) {
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (g_sdk.loaded() && g_sdk.copyBufs)
        return (g_sdk.copyBufs() == 0) ? VANTAGE_OK : VANTAGE_ERR_API;
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_GetRcvBuffer(int buf_index, VantageRcvBuffer* buf_out) {
    if (!buf_out) return VANTAGE_ERR_NULL_PTR;
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (buf_index < 0 || buf_index >= MAX_BUFFERS) return VANTAGE_ERR_INVALID_PARAM;

    const InternalRcvBuf& src = g_rcv_bufs[buf_index];
    buf_out->data        = src.data;
    buf_out->rows        = src.rows;
    buf_out->cols        = src.cols;
    buf_out->num_frames  = src.num_frames;
    buf_out->frame_index = src.frame_idx;
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_GetFrameData(int buf_index, int frame_num,
                                      int16_t* dst, int dst_size) {
    if (!dst) return VANTAGE_ERR_NULL_PTR;
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (buf_index < 0 || buf_index >= MAX_BUFFERS) return VANTAGE_ERR_INVALID_PARAM;

    const InternalRcvBuf& src = g_rcv_bufs[buf_index];
    if (frame_num < 0 || frame_num >= src.num_frames)
        return VANTAGE_ERR_INVALID_PARAM;

    int frame_samples = src.rows * src.cols;
    if (dst_size < frame_samples) return VANTAGE_ERR_BUFFER;

    memcpy(dst,
           src.data + (size_t)frame_num * frame_samples,
           (size_t)frame_samples * sizeof(int16_t));
    return VANTAGE_OK;
}

VANTAGE_API int Vantage_IsFrozen(void) {
    if (!g_initialized) return 0;
    if (g_sdk.loaded() && g_sdk.isFrozen)
        return g_sdk.isFrozen();
    return 0;
}

VANTAGE_API int Vantage_GetFrameCount(int buf_index, int* count_out) {
    if (!count_out) return VANTAGE_ERR_NULL_PTR;
    if (!g_initialized) return VANTAGE_ERR_NOT_INITIALIZED;
    if (buf_index < 0 || buf_index >= MAX_BUFFERS) return VANTAGE_ERR_INVALID_PARAM;
    *count_out = g_rcv_bufs[buf_index].frame_idx + 1;
    return VANTAGE_OK;
}

VANTAGE_API const char* Vantage_GetErrorString(int error_code) {
    switch (error_code) {
        case VANTAGE_OK:                  return "Success";
        case VANTAGE_ERR_NOT_INITIALIZED: return "Not initialized";
        case VANTAGE_ERR_ACQUIRE_FAILED:  return "Acquisition failed";
        case VANTAGE_ERR_TIMEOUT:         return "Acquisition timed out";
        case VANTAGE_ERR_BUFFER:          return "Buffer error";
        case VANTAGE_ERR_API:             return "Vantage SDK returned error";
        case VANTAGE_ERR_NULL_PTR:        return "Null pointer argument";
        case VANTAGE_ERR_INVALID_PARAM:   return "Invalid parameter";
        default:                          return "Unknown error";
    }
}

} // extern "C"
