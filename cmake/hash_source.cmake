# cmake/hash_source.cmake
# Invoked at BUILD time via add_custom_command whenever vector_benchmark.cpp
# changes.  Computes the MD5 of SRC and writes a C header to OUT containing
# a single macro BENCHMARK_SOURCE_HASH so the binary can embed the hash into
# the Google Benchmark context block at runtime.
#
# Variables expected on the command line (-D):
#   SRC  — absolute path to the source file to hash
#   OUT  — absolute path of the header to (re)generate

file(MD5 "${SRC}" HASH)
file(WRITE "${OUT}"
    "#pragma once\n"
    "// Auto-generated at build time -- do not edit.\n"
    "// MD5 of ${SRC}\n"
    "#define BENCHMARK_SOURCE_HASH \"${HASH}\"\n"
)
message(STATUS "source_hash.h: ${HASH}")
