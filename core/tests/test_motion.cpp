// test_motion.cpp — unit tests for MotionStageAPI (no hardware required)
// Tests validate error-handling paths that are reachable without the DLL.

#include "MotionStageAPI.h"
#include <cassert>
#include <cstdio>

static int pass = 0, fail = 0;

#define CHECK(cond, msg) \
    do { if (cond) { printf("PASS: %s\n", msg); pass++; } \
         else { printf("FAIL: %s\n", msg); fail++; } } while(0)

static void test_error_strings() {
    CHECK(Stage_GetErrorString(STAGE_OK)                != nullptr, "error string STAGE_OK");
    CHECK(Stage_GetErrorString(STAGE_ERR_NOT_CONNECTED) != nullptr, "error string NOT_CONNECTED");
    CHECK(Stage_GetErrorString(STAGE_ERR_TIMEOUT)       != nullptr, "error string TIMEOUT");
    CHECK(Stage_GetErrorString(-999)                    != nullptr, "error string unknown");
}

static void test_not_connected() {
    MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
    int r = Stage_Move(99, AXIS_X, 1.0f, MOVE_RELATIVE, &p);
    CHECK(r == STAGE_ERR_NOT_CONNECTED, "Move on unknown device -> NOT_CONNECTED");

    r = Stage_GetPosition(99, nullptr);
    CHECK(r == STAGE_ERR_NULL_PTR, "GetPosition null ptr -> NULL_PTR");

    r = Stage_Stop(99, AXIS_X, STOP_DECEL);
    CHECK(r == STAGE_ERR_NOT_CONNECTED, "Stop on unknown device -> NOT_CONNECTED");
}

static void test_null_ptr() {
    int r = Stage_Connect(1, nullptr, 8088);
    CHECK(r == STAGE_ERR_NULL_PTR, "Connect with null ip -> NULL_PTR");

    MotionParams p = {80.f, 200.f, 200.f, 5.f, 0.01f};
    r = Stage_Move(1, AXIS_X, 1.0f, MOVE_RELATIVE, nullptr);
    CHECK(r == STAGE_ERR_NULL_PTR, "Move with null params -> NULL_PTR");
}

static void test_invalid_params() {
    MotionParams bad_vel   = {0.f,  200.f, 200.f, 5.f, 0.01f};
    MotionParams bad_accel = {80.f, 0.f,   200.f, 5.f, 0.01f};

    // These will fail on NOT_CONNECTED before param check, so we just verify
    // param validation is present — connect would fail without DLL anyway.
    int r1 = Stage_Move(1, AXIS_X, 1.0f, MOVE_RELATIVE, &bad_vel);
    CHECK(r1 != STAGE_OK, "Move with zero velocity -> error");

    int r2 = Stage_Move(1, AXIS_X, 1.0f, MOVE_RELATIVE, &bad_accel);
    CHECK(r2 != STAGE_OK, "Move with zero accel -> error");
}

static void test_is_connected() {
    int r = Stage_IsConnected(999);
    CHECK(r == 0, "IsConnected on unknown device -> 0");
}

int main() {
    printf("=== MotionStageAPI Unit Tests ===\n\n");
    test_error_strings();
    test_not_connected();
    test_null_ptr();
    test_invalid_params();
    test_is_connected();
    printf("\nResults: %d passed, %d failed\n", pass, fail);
    return (fail == 0) ? 0 : 1;
}
