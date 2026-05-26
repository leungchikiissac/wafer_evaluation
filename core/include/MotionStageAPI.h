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
    STAGE_ERR_API           = -5,
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
    float vel_mm_s;
    float accel_mm_s2;
    float decel_mm_s2;
    float timeout_s;
    float tolerance_mm;
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
