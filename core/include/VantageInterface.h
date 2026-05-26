/* VantageInterface.h
 * Pure C interface to the Verasonics Vantage NXT ultrasound system.
 * Compiled as C++ internally but exported as C symbols.
 *
 * All functions return:
 *   VANTAGE_OK  (0)  on success
 *   negative value on error (see VantageErrorCode enum)
 */

#ifndef VANTAGE_INTERFACE_H
#define VANTAGE_INTERFACE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define VANTAGE_API __declspec(dllexport)
#else
  #define VANTAGE_API __attribute__((visibility("default")))
#endif

/* ── Error codes ──────────────────────────────────────────── */
typedef enum {
    VANTAGE_OK                  =  0,
    VANTAGE_ERR_NOT_INITIALIZED = -1,
    VANTAGE_ERR_ACQUIRE_FAILED  = -2,
    VANTAGE_ERR_TIMEOUT         = -3,
    VANTAGE_ERR_BUFFER          = -4,
    VANTAGE_ERR_API             = -5,
    VANTAGE_ERR_NULL_PTR        = -6,
    VANTAGE_ERR_INVALID_PARAM   = -7,
} VantageErrorCode;

/* ── Acquisition parameters ───────────────────────────────── */
typedef struct {
    int    num_angles;         /* number of plane wave angles     */
    int    num_channels;       /* number of receive channels      */
    int    samples_per_acq;    /* samples per acquisition         */
    float  start_depth_wvl;   /* start depth in wavelengths      */
    float  end_depth_wvl;     /* end depth in wavelengths        */
    float  speed_of_sound;    /* m/s                             */
    int    num_frames;         /* frames to acquire per trigger   */
} VantageAcqParams;

/* ── Receive buffer info ──────────────────────────────────── */
typedef struct {
    int16_t* data;             /* pointer to raw int16 RF data    */
    int      rows;             /* rows per frame                  */
    int      cols;             /* columns (channels)              */
    int      num_frames;       /* number of frames in buffer      */
    int      frame_index;      /* index of last written frame     */
} VantageRcvBuffer;

/* ── Initialization / shutdown ────────────────────────────── */
VANTAGE_API int Vantage_Initialize(const VantageAcqParams* params);
VANTAGE_API int Vantage_Shutdown(void);
VANTAGE_API int Vantage_IsInitialized(void);

/* ── Trigger and acquisition ──────────────────────────────── */
VANTAGE_API int Vantage_SoftTrigger(void);
VANTAGE_API int Vantage_WaitForAcquisition(float timeout_s);
VANTAGE_API int Vantage_CopyBuffers(void);

/* ── Data retrieval ───────────────────────────────────────── */
VANTAGE_API int Vantage_GetRcvBuffer(int buf_index, VantageRcvBuffer* buf_out);
VANTAGE_API int Vantage_GetFrameData(int buf_index, int frame_num,
                                      int16_t* dst, int dst_size);

/* ── Status ───────────────────────────────────────────────── */
VANTAGE_API int Vantage_IsFrozen(void);
VANTAGE_API int Vantage_GetFrameCount(int buf_index, int* count_out);

/* ── Error string ─────────────────────────────────────────── */
VANTAGE_API const char* Vantage_GetErrorString(int error_code);

#ifdef __cplusplus
}
#endif

#endif /* VANTAGE_INTERFACE_H */
