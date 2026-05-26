// test_vantage.cpp — unit tests for VantageInterface (no hardware required)

#include "VantageInterface.h"
#include <cassert>
#include <cstdio>

static int pass = 0, fail = 0;

#define CHECK(cond, msg) \
    do { if (cond) { printf("PASS: %s\n", msg); pass++; } \
         else { printf("FAIL: %s\n", msg); fail++; } } while(0)

static void test_error_strings() {
    CHECK(Vantage_GetErrorString(VANTAGE_OK)                  != nullptr, "error string OK");
    CHECK(Vantage_GetErrorString(VANTAGE_ERR_NOT_INITIALIZED) != nullptr, "error string NOT_INITIALIZED");
    CHECK(Vantage_GetErrorString(-999)                        != nullptr, "error string unknown");
}

static void test_not_initialized() {
    CHECK(Vantage_IsInitialized() == 0, "IsInitialized before init -> 0");
    CHECK(Vantage_SoftTrigger()   == VANTAGE_ERR_NOT_INITIALIZED, "SoftTrigger before init -> error");
    CHECK(Vantage_CopyBuffers()   == VANTAGE_ERR_NOT_INITIALIZED, "CopyBuffers before init -> error");
    CHECK(Vantage_IsFrozen()      == 0, "IsFrozen before init -> 0");

    VantageRcvBuffer buf;
    CHECK(Vantage_GetRcvBuffer(0, &buf) == VANTAGE_ERR_NOT_INITIALIZED, "GetRcvBuffer before init -> error");
}

static void test_null_ptr() {
    CHECK(Vantage_Initialize(nullptr) == VANTAGE_ERR_NULL_PTR, "Initialize with null params -> error");
}

static void test_invalid_params() {
    VantageAcqParams bad = {1, 0, 4096, 5.0f, 128.0f, 1540.0f, 10};
    CHECK(Vantage_Initialize(&bad) == VANTAGE_ERR_INVALID_PARAM, "Initialize with 0 channels -> error");
}

static void test_initialize_and_shutdown() {
    VantageAcqParams p = {
        .num_angles       = 1,
        .num_channels     = 128,
        .samples_per_acq  = 4096,
        .start_depth_wvl  = 5.0f,
        .end_depth_wvl    = 128.0f,
        .speed_of_sound   = 1540.0f,
        .num_frames       = 10,
    };
    int r = Vantage_Initialize(&p);
    CHECK(r == VANTAGE_OK, "Initialize with valid params -> OK");
    CHECK(Vantage_IsInitialized() == 1, "IsInitialized after init -> 1");

    VantageRcvBuffer buf;
    r = Vantage_GetRcvBuffer(0, &buf);
    CHECK(r == VANTAGE_OK, "GetRcvBuffer(0) after init -> OK");
    CHECK(buf.data != nullptr, "RcvBuffer(0) data pointer not null");
    CHECK(buf.cols == 128, "RcvBuffer(0) cols == 128");

    r = Vantage_WaitForAcquisition(1.0f);
    CHECK(r == VANTAGE_OK, "WaitForAcquisition in sim mode -> OK");

    r = Vantage_Shutdown();
    CHECK(r == VANTAGE_OK, "Shutdown -> OK");
    CHECK(Vantage_IsInitialized() == 0, "IsInitialized after shutdown -> 0");
}

int main() {
    printf("=== VantageInterface Unit Tests ===\n\n");
    test_error_strings();
    test_not_initialized();
    test_null_ptr();
    test_invalid_params();
    test_initialize_and_shutdown();
    printf("\nResults: %d passed, %d failed\n", pass, fail);
    return (fail == 0) ? 0 : 1;
}
