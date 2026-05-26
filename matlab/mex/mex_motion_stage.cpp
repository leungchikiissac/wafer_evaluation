// matlab/mex/mex_motion_stage.cpp
// MEX wrapper: exposes MotionStageAPI to MATLAB scripts.
// Build with: mex mex_motion_stage.cpp -L../../core/build -lMotionStage
//             -I../../core/include

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
        if (nrhs < 4)
            mexErrMsgIdAndTxt("StageAPI:input",
                              "connect requires: device_id, ip, port");
        int  id   = (int)mxGetScalar(prhs[1]);
        char ip[32];
        int  port = (int)mxGetScalar(prhs[3]);
        mxGetString(prhs[2], ip, sizeof(ip));
        int r = Stage_Connect(id, ip, port);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:connect", Stage_GetErrorString(r));
    }
    // ── stage_mex('disconnect', device_id) ────────────────────
    else if (strcmp(cmd, "disconnect") == 0) {
        if (nrhs < 2)
            mexErrMsgIdAndTxt("StageAPI:input", "disconnect requires: device_id");
        int id = (int)mxGetScalar(prhs[1]);
        Stage_Disconnect(id);
    }
    // ── stage_mex('move', device_id, axis, dist_mm) ───────────
    else if (strcmp(cmd, "move") == 0) {
        if (nrhs < 4)
            mexErrMsgIdAndTxt("StageAPI:input", "move requires: device_id, axis, dist_mm");
        int        id   = (int)mxGetScalar(prhs[1]);
        StageAxis  ax   = (StageAxis)(int)mxGetScalar(prhs[2]);
        float      dist = (float)mxGetScalar(prhs[3]);
        MotionParams p  = {80.f, 200.f, 200.f, 5.f, 0.01f};
        int r = Stage_Move(id, ax, dist, MOVE_RELATIVE, &p);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:move", Stage_GetErrorString(r));
    }
    // ── stage_mex('move_x', device_id, dist_mm) ───────────────
    else if (strcmp(cmd, "move_x") == 0) {
        if (nrhs < 3)
            mexErrMsgIdAndTxt("StageAPI:input", "move_x requires: device_id, dist_mm");
        int   id   = (int)mxGetScalar(prhs[1]);
        float dist = (float)mxGetScalar(prhs[2]);
        MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
        int r = Stage_MoveX(id, dist, &p);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:move", Stage_GetErrorString(r));
    }
    // ── stage_mex('move_y', device_id, dist_mm) ───────────────
    else if (strcmp(cmd, "move_y") == 0) {
        if (nrhs < 3)
            mexErrMsgIdAndTxt("StageAPI:input", "move_y requires: device_id, dist_mm");
        int   id   = (int)mxGetScalar(prhs[1]);
        float dist = (float)mxGetScalar(prhs[2]);
        MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
        int r = Stage_MoveY(id, dist, &p);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:move", Stage_GetErrorString(r));
    }
    // ── stage_mex('move_z', device_id, dist_mm) ───────────────
    else if (strcmp(cmd, "move_z") == 0) {
        if (nrhs < 3)
            mexErrMsgIdAndTxt("StageAPI:input", "move_z requires: device_id, dist_mm");
        int   id   = (int)mxGetScalar(prhs[1]);
        float dist = (float)mxGetScalar(prhs[2]);
        MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
        int r = Stage_MoveZ(id, dist, &p);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:move", Stage_GetErrorString(r));
    }
    // ── stage_mex('get_position', device_id) → [x y z] ────────
    else if (strcmp(cmd, "get_position") == 0) {
        if (nrhs < 2)
            mexErrMsgIdAndTxt("StageAPI:input", "get_position requires: device_id");
        int id = (int)mxGetScalar(prhs[1]);
        StagePosition pos;
        int r = Stage_GetPosition(id, &pos);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:getpos", Stage_GetErrorString(r));
        plhs[0] = mxCreateDoubleMatrix(1, 3, mxREAL);
        double* out = mxGetPr(plhs[0]);
        out[0] = pos.x; out[1] = pos.y; out[2] = pos.z;
    }
    // ── stage_mex('stop', device_id, axis) ────────────────────
    else if (strcmp(cmd, "stop") == 0) {
        if (nrhs < 3)
            mexErrMsgIdAndTxt("StageAPI:input", "stop requires: device_id, axis");
        int id = (int)mxGetScalar(prhs[1]);
        StageAxis ax = (StageAxis)(int)mxGetScalar(prhs[2]);
        int r = Stage_Stop(id, ax, STOP_DECEL);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:stop", Stage_GetErrorString(r));
    }
    // ── stage_mex('home', device_id, axis) ────────────────────
    else if (strcmp(cmd, "home") == 0) {
        if (nrhs < 3)
            mexErrMsgIdAndTxt("StageAPI:input", "home requires: device_id, axis");
        int id = (int)mxGetScalar(prhs[1]);
        StageAxis ax = (StageAxis)(int)mxGetScalar(prhs[2]);
        int r = Stage_Home(id, ax, 10.f, 100.f, 1.f, 2);
        if (r != 0)
            mexErrMsgIdAndTxt("StageAPI:home", Stage_GetErrorString(r));
    }
    else {
        mexErrMsgIdAndTxt("StageAPI:cmd", "Unknown command: %s", cmd);
    }
}
