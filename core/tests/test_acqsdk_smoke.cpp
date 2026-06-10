// test_acqsdk_smoke.cpp — no-hardware smoke test for the Verasonics Acquisition SDK
//
// Verifies the DLL loads and that version/info query functions respond correctly.
// No hardware or license required for these calls.

#include "VK_AcqSdk.h"
#include <cstdio>
#include <cstring>

static int pass = 0, fail = 0;

#define CHECK(cond, msg) \
    do { if (cond) { printf("PASS: %s\n", msg); pass++; } \
         else      { printf("FAIL: %s\n", msg); fail++; } } while(0)

int main()
{
    printf("=== Acquisition SDK no-hardware smoke test ===\n\n");

    // ── 1. API version (compile-time macros vs runtime) ───────────────────────
    int maj = -1, min = -1;
    VkResult r = VK_GetAPIVersion(&maj, &min);
    CHECK(r == VkResult_Success,                    "VK_GetAPIVersion returns success");
    CHECK(maj == VKACQSDK_API_VERSION_MAJOR,        "API major version matches header macro");
    CHECK(min == VKACQSDK_API_VERSION_MINOR,        "API minor version matches header macro");
    printf("      API version: %d.%d\n", maj, min);

    // ── 2. Release version ────────────────────────────────────────────────────
    int rmaj = -1, rmin = -1, rmic = -1;
    r = VK_GetReleaseVersion(&rmaj, &rmin, &rmic);
    CHECK(r == VkResult_Success,   "VK_GetReleaseVersion returns success");
    CHECK(rmaj >= 0,               "Release major >= 0");
    CHECK(rmin >= 0,               "Release minor >= 0");
    CHECK(rmic >= 0,               "Release micro >= 0");
    printf("      Release version: %d.%d.%d\n", rmaj, rmin, rmic);

    // ── 3. Product name ───────────────────────────────────────────────────────
    // First call with null buffer to query required length.
    int needed = 0;
    r = VK_GetProductName(0, nullptr, &needed);
    CHECK(r == VkResult_Success,   "VK_GetProductName length query returns success");
    CHECK(needed > 0,              "Product name length > 0");

    char buf[256] = {};
    r = VK_GetProductName(sizeof(buf), buf, &needed);
    CHECK(r == VkResult_Success,        "VK_GetProductName with buffer returns success");
    CHECK(strlen(buf) > 0,              "Product name string is non-empty");
    printf("      Product name: \"%s\"\n", buf);

    // ── 4. Null argument handling ─────────────────────────────────────────────
    r = VK_GetAPIVersion(nullptr, nullptr);
    CHECK(r != VkResult_Success,   "VK_GetAPIVersion(null,null) returns error");

    r = VK_GetReleaseVersion(nullptr, nullptr, nullptr);
    CHECK(r != VkResult_Success,   "VK_GetReleaseVersion(null,null,null) returns error");

    // ── 5. Enum-to-string helpers (no hardware needed) ───────────────────────
    const char* s = VK_SequenceControlCommandToString(VkCmd_Jump);
    CHECK(s != nullptr && strlen(s) > 0,   "VK_SequenceControlCommandToString(Jump) non-empty");

    s = VK_SequenceControlConditionToString(VkCond_Counter);
    CHECK(s != nullptr && strlen(s) > 0,   "VK_SequenceControlConditionToString(Counter) non-empty");

    // ── Results ───────────────────────────────────────────────────────────────
    printf("\nResults: %d passed, %d failed\n", pass, fail);
    return (fail == 0) ? 0 : 1;
}
