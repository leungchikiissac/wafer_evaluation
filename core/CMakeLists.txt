cmake_minimum_required(VERSION 3.16)
project(WaferEvaluationCore VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)

# ── Shared library (used by Python ctypes + MATLAB MEX) ──────
add_library(MotionStage SHARED
    src/MotionStageAPI.cpp
)
target_include_directories(MotionStage PUBLIC include)
target_compile_definitions(MotionStage PRIVATE MOTION_STAGE_EXPORTS)

add_library(VantageInterface SHARED
    src/VantageInterface.cpp
)
target_include_directories(VantageInterface PUBLIC include)

# ── Static libraries (for tests and embedding) ───────────────
add_library(MotionStage_static STATIC
    src/MotionStageAPI.cpp
)
target_include_directories(MotionStage_static PUBLIC include)

add_library(VantageInterface_static STATIC
    src/VantageInterface.cpp
)
target_include_directories(VantageInterface_static PUBLIC include)

# ── Unit tests ────────────────────────────────────────────────
enable_testing()

add_executable(test_motion tests/test_motion.cpp)
target_link_libraries(test_motion MotionStage_static)
add_test(NAME MotionTests COMMAND test_motion)

add_executable(test_vantage tests/test_vantage.cpp)
target_link_libraries(test_vantage VantageInterface_static)
add_test(NAME VantageTests COMMAND test_vantage)

# ── Acquisition executables ───────────────────────────────────
set(ACQSDK_ROOT "${CMAKE_SOURCE_DIR}/../vendor/Vantage/vsacqsdk")
set(VANTAGE_ROOT "${CMAKE_SOURCE_DIR}/../vendor/Vantage")
if(EXISTS "${ACQSDK_ROOT}/includes/VK_AcqSdk.h")
    add_executable(simple_flash src/acquisition/simple_flash.cpp)
    target_include_directories(simple_flash PRIVATE "${ACQSDK_ROOT}/includes")
    target_link_directories(simple_flash PRIVATE "${ACQSDK_ROOT}/libs")
    target_link_libraries(simple_flash VerasonicsAcqSDK)
    message(STATUS "simple_flash acquisition target enabled")

    foreach(dep IN ITEMS
            "${ACQSDK_ROOT}/libs/libVerasonicsAcqSDK.dll"
            "${VANTAGE_ROOT}/System/libVerasonicsCommon.dll"
            "${VANTAGE_ROOT}/System/libVerasonicsHal.dll"
            "${VANTAGE_ROOT}/System/libwinpthread-1.dll"
            "${VANTAGE_ROOT}/license.enc")
        if(EXISTS "${dep}")
            add_custom_command(TARGET simple_flash POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different "${dep}" "$<TARGET_FILE_DIR:simple_flash>")
        endif()
    endforeach()
else()
    message(STATUS "AcqSDK not found — simple_flash skipped")
endif()

# ── Acquisition SDK smoke test (no hardware required) ────────
set(ACQSDK_ROOT "${CMAKE_SOURCE_DIR}/../vendor/Vantage/vsacqsdk")
set(VANTAGE_ROOT "${CMAKE_SOURCE_DIR}/../vendor/Vantage")
if(EXISTS "${ACQSDK_ROOT}/includes/VK_AcqSdk.h")
    add_executable(test_acqsdk_smoke tests/test_acqsdk_smoke.cpp)
    target_include_directories(test_acqsdk_smoke PRIVATE "${ACQSDK_ROOT}/includes")
    target_link_directories(test_acqsdk_smoke PRIVATE "${ACQSDK_ROOT}/libs")
    target_link_libraries(test_acqsdk_smoke VerasonicsAcqSDK)
    add_test(NAME AcqSdkSmoke COMMAND test_acqsdk_smoke)
    message(STATUS "AcqSDK found — test_acqsdk_smoke enabled")

    # Runtime deps (libVerasonicsAcqSDK.dll needs Common/Hal/winpthread + license.enc)
    foreach(dep IN ITEMS
            "${ACQSDK_ROOT}/libs/libVerasonicsAcqSDK.dll"
            "${VANTAGE_ROOT}/System/libVerasonicsCommon.dll"
            "${VANTAGE_ROOT}/System/libVerasonicsHal.dll"
            "${VANTAGE_ROOT}/System/libwinpthread-1.dll"
            "${VANTAGE_ROOT}/license.enc")
        if(EXISTS "${dep}")
            add_custom_command(TARGET test_acqsdk_smoke POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different "${dep}" "$<TARGET_FILE_DIR:test_acqsdk_smoke>")
        endif()
    endforeach()
else()
    message(STATUS "AcqSDK not found at ${ACQSDK_ROOT} — test_acqsdk_smoke skipped")
endif()

# ── Install ───────────────────────────────────────────────────
install(TARGETS MotionStage VantageInterface DESTINATION lib)
install(FILES
    include/MotionStageAPI.h
    include/VantageInterface.h
    DESTINATION include
)
