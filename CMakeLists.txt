cmake_minimum_required(VERSION 3.25)
project(VectorInitBench CXX)

# ── CPM source cache (survives clean builds, avoids re-downloading) ────────────
set(CPM_SOURCE_CACHE "$ENV{LOCALAPPDATA}/cpm-cache" CACHE PATH "CPM source cache")

# ── CPM bootstrap ─────────────────────────────────────────────────────────────
set(CPM_VERSION 0.40.2)
set(CPM_FILE "${CMAKE_BINARY_DIR}/cmake/CPM_${CPM_VERSION}.cmake")

if(NOT EXISTS "${CPM_FILE}")
    message(STATUS "Downloading CPM.cmake v${CPM_VERSION}")
    file(DOWNLOAD
        "https://github.com/cpm-cmake/CPM.cmake/releases/download/v${CPM_VERSION}/CPM.cmake"
        "${CPM_FILE}"
        EXPECTED_HASH SHA256=c8cdc32c03816538ce22781ed72964dc864b2a34a310d3b7104812a5ca2d835d
    )
endif()

include("${CPM_FILE}")

# ── Dependencies ───────────────────────────────────────────────────────────────
CPMAddPackage(
    NAME benchmark
    GITHUB_REPOSITORY google/benchmark
    VERSION 1.9.1
    OPTIONS
        "BENCHMARK_ENABLE_TESTING OFF"
        "BENCHMARK_ENABLE_INSTALL OFF"
        "BENCHMARK_ENABLE_GTEST_TESTS OFF"
        "BENCHMARK_ENABLE_WERROR OFF"
)

# ── Target ─────────────────────────────────────────────────────────────────────
add_executable(vector_benchmark vector_benchmark.cpp)

target_compile_features(vector_benchmark PRIVATE cxx_std_23)

target_link_libraries(vector_benchmark PRIVATE benchmark::benchmark)

# ── Optimisation flags ─────────────────────────────────────────────────────────
# All three compilers target the x86-64-v3 baseline (AVX2 + BMI2 + FMA + POPCNT):
#   - runs on essentially every x86-64 CPU made since ~2015
#   - GCC/Clang use -march=x86-64-v3 (defined in GCC 11 / Clang 12)
#     which also avoids the -mtune=native scheduling advantage that -march=native
#     would give them, keeping the comparison with MSVC fair
#   - MSVC uses /arch:AVX2 (its equivalent; BMI2/FMA/POPCNT are implied on x64)
#
# Note: CMAKE_CXX_FLAGS already provides /EHsc (MSVC global).
#       CMAKE_CXX_FLAGS_RELEASE already provides /O2 /Ob2 /DNDEBUG.
#       We only add what those defaults omit.
#
# Note on BM_CBaseline2: MSVC materialises the MyStruct(i,i) prvalue as a
# stack temporary (C++ required for assignment). Two 4-byte stores feed a single
# 8-byte load, hitting Intel's store-forward stall (~4-5 cycles/iter, ~3x slower
# than BM_CBaseline). GCC/Clang eliminate this via SRoA. No flag fixes it; the
# gap captures a genuine compiler quality difference.

if(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    # /arch:AVX2  – AVX2 + FMA + BMI2 (x86-64-v3 equivalent for MSVC)
    # /GL         – whole-program optimisation (compile side of LTCG)
    # /Oi         – force intrinsic functions
    # /Ob3        – more aggressive inlining than the /O2 default of /Ob2
    target_compile_options(vector_benchmark PRIVATE /arch:AVX2 /GL /Oi /Ob3)
    # /LTCG       – link-time code generation (pairs with /GL above)
    target_link_options   (vector_benchmark PRIVATE $<$<CONFIG:Release>:/LTCG>)

# Clang-CL (clang frontend, MSVC-compatible flags)
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND CMAKE_CXX_SIMULATE_ID STREQUAL "MSVC")
    target_compile_options(vector_benchmark PRIVATE -O3 -march=x86-64-v3)

# Standalone Clang (clang++) or GCC
else()
    target_compile_options(vector_benchmark PRIVATE -O3 -march=x86-64-v3)
endif()

message(STATUS "Compiler: ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "Compiler path: ${CMAKE_CXX_COMPILER}")
