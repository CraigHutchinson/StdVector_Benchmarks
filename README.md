# VectorInitBench

A cross-compiler C++23 microbenchmark comparing `std::vector` initialisation
strategies against raw C-style heap allocation baselines, measured under MSVC,
GCC, and Clang on Windows.

## What is benchmarked

| Benchmark | Description |
|---|---|
| `BM_CBaseline` | Raw `malloc` + placement `new` — theoretical lower bound |
| `BM_CBaseline2` | Raw `malloc` + assignment (`vec[i] = MyStruct(i,i)`) — exposes MSVC store-forward stall |
| `BM_CBaseline3` | Raw `malloc` + `std::construct_at` — C++20 named alternative to placement `new` |
| `BM_EmplaceBack` | `vector::reserve` + `emplace_back` |
| `BM_PushBack` | `vector::reserve` + `push_back` (copy) |
| `BM_FromRange` | `std::vector` range constructor from `std::views::iota` (C++23) |
| `BM_FromRangeIterators` | `std::vector(first, last)` from iota iterators |

N = 500 000 elements (4 MB working set, L3-bound), 20 repetitions with
random interleaving to average out intra-run thermal drift.

## Prerequisites

| Tool | How to get |
|---|---|
| MSVC (VS 2022) | Visual Studio installer — "Desktop development with C++" workload |
| GCC 15.2 | `choco install mingw` |
| Clang 21.1 | `choco install llvm` |
| CMake ≥ 3.25 | Bundled with Visual Studio, or `choco install cmake` |
| Chocolatey | `winget install Chocolatey.Chocolatey` |

GCC, Clang, and Ninja are installed automatically by `build.ps1` if absent.

## Quick start

```powershell
.\build.ps1; .\report.ps1 -Open
```

This will configure, build, and run all three compiler variants (with a 30 s
thermal cooldown between each), then open an HTML report in your browser.

## Build script options

```powershell
# Full rebuild + run, open report
.\build.ps1; .\report.ps1 -Open

# Re-run only (skip compile), no cooldown — useful for quick iteration
.\build.ps1 -NoBuild -CooldownSec 0

# Single compiler
.\build.ps1 -Preset gcc

# Single compiler, single benchmark, no rebuild
.\build.ps1 -Preset msvc -Benchmark BM_CBaseline2 -NoBuild

# Clean rebuild of all compilers
.\build.ps1 -Clean
```

## Output

- `results/{msvc,gcc,clang}.json` — raw Google Benchmark JSON (individual repetitions + aggregates)
- `results/report.html` — self-contained HTML with Plotly box/whisker plots and a summary table

**[View latest report](https://htmlpreview.github.io/?https://github.com/CraigHutchinson/StdVector_Benchmarks/blob/main/results/report.html)**

The report table highlights two independent axes:
- **Green background** — result is within this compiler's own σ of its personal best across all benchmarks
- **★ stars** — gold/silver/bronze for fastest/2nd/3rd per benchmark row (ties within own σ share the medal)

Each benchmark row is clickable to expand the exact C++ code being measured.

## Compiler flags

All three compilers target the **x86-64-v3** ISA baseline (AVX2 + BMI2 + FMA),
a portable production-safe target supported by every x86-64 CPU made since ~2015.

| Compiler | Key flags |
|---|---|
| MSVC | `/O2 /Ob3 /Oi /arch:AVX2 /GL /LTCG` |
| GCC | `-O3 -march=x86-64-v3` |
| Clang | `-O3 -march=x86-64-v3` |

## Key findings

- **Placement `new` and `std::construct_at`** generate identical machine code
  (2 direct DWORD stores). Both compilers and MSVC match on these.
- **`BM_CBaseline2` (assignment) is ~3× slower on MSVC** due to a store-forward
  stall: the compiler materialises a stack temporary, causing two 4-byte stores
  to feed a single 8-byte load. GCC and Clang eliminate this via SRoA.
- **`emplace_back` is close-ish to the raw baseline** on GCC and Clang; MSVC leaves
  a larger gap, making the overhead more visible.
