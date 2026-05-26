/*
 * FMC4030-Dll.h  —  Public header for the FUYU FMC4030 motion controller DLL.
 *
 * This is a reconstructed header based on the FMC4030 API documentation
 * (FMC4030二次开发库详解V1.0.pdf).  Place the actual vendor-supplied header
 * here when available.
 *
 * The DLL exports plain C functions; load with loadlibrary() in MATLAB
 * or ctypes in Python.
 */

#ifndef FMC4030_DLL_H
#define FMC4030_DLL_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
  #define FMC_API __declspec(dllimport)
#else
  #define FMC_API
#endif

/*
 * Return codes
 *   0  : success
 *  -1  : connection failed
 *  -4  : data construction failed
 *  -5  : data send failed
 *  -6  : data receive error
 *  -7  : received data error
 *  -8  : null pointer error
 */

/* ── Connection ─────────────────────────────────────────────── */
FMC_API int FMC4030_Open_Device (int id, const char* ip, int port);
FMC_API int FMC4030_Close_Device(int id);

/* ── Single-axis movement ───────────────────────────────────── */
/* mode: 1 = relative, 2 = absolute */
FMC_API int FMC4030_Jog_Single_Axis(int id, int axis,
                                     float distance, float vel,
                                     float accel,   float decel,
                                     int   mode);

/* ── Axis status ────────────────────────────────────────────── */
/* Returns 1 if stopped, 0 if moving */
FMC_API int FMC4030_Check_Axis_Is_Stop(int id, int axis);

/* ── Position ───────────────────────────────────────────────── */
FMC_API int FMC4030_Get_Axis_Current_Pos  (int id, int axis, float* pos);
FMC_API int FMC4030_Get_Axis_Current_Speed(int id, int axis, float* speed);

/* ── Stop ───────────────────────────────────────────────────── */
/* mode: 1 = decelerate, 2 = immediate */
FMC_API int FMC4030_Stop_Single_Axis(int id, int axis, int mode);

/* ── Homing ─────────────────────────────────────────────────── */
/* direction: 1 = positive limit, 2 = negative limit */
FMC_API int FMC4030_Home_Single_Axis(int id, int axis,
                                      float homeSpeed,
                                      float homeAccDec,
                                      float homeFallStep,
                                      int   homeDir);

/* ── Machine status ─────────────────────────────────────────── */
typedef struct {
    float        realPos[3];
    float        realSpeed[3];
    unsigned int inputStatus;
    unsigned int outputStatus;
    unsigned int limitNStatus;
    unsigned int limitPStatus;
    unsigned int machineRunStatus;
    unsigned int axisStatus[3];
    unsigned int homeStatus;
    char         file[20][30];
} FMC4030_MachineStatus;

FMC_API int FMC4030_Get_Machine_Status(int id, FMC4030_MachineStatus* status);

/* ── Digital I/O ────────────────────────────────────────────── */
FMC_API int FMC4030_Set_Output(int id, int channel, int level);
FMC_API int FMC4030_Get_Input (int id, int channel, int* state);

/* ── Linear interpolation ───────────────────────────────────── */
FMC_API int FMC4030_Line_2Axis(int id, int axisSel,
                                float endX, float endY,
                                float speed, float accel, float decel);
FMC_API int FMC4030_Stop_Run  (int id);

#ifdef __cplusplus
}
#endif

#endif /* FMC4030_DLL_H */
