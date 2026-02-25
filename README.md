# VectorInitBench

A cross-compiler C++23 microbenchmark comparing `std::vector` initialisation
strategies against raw C-style heap allocation baselines, measured under MSVC,
GCC, and Clang on Windows.

## [View latest report →](https://craighutchinson.github.io/StdVector_Benchmarks/report.html)

Interactive Plotly box/whisker plots + summary table with per-compiler and
cross-compiler highlighting. Each benchmark row expands to show the exact C++
code being measured. Automatically redeployed to GitHub Pages on every push.

---

## Key findings

- **Placement `new` and `std::construct_at`** generate identical machine code
  (2 direct DWORD stores per element) on all three compilers — the theoretical
  lower bound for this workload.
- **`BM_CBaseline2` (assignment) is ~3× slower on MSVC** — the compiler
  materialises `MyStruct(i,i)` as a stack temporary before assignment, causing
  two 4-byte stores to feed a single 8-byte load (Intel store-forward stall,
  ~4–5 cycles/iter). GCC and Clang eliminate the temporary via SRoA.
- **`emplace_back` after `reserve`** is close to the raw baseline on GCC and
  Clang; MSVC shows a consistent overhead.

## Quick start

```powershell
.\build.ps1; .\report.ps1 -Open
```

Configures, builds, and runs all three compiler variants (30 s thermal cooldown
between each), then opens the HTML report locally.

## What is benchmarked

N = 500 000 `MyStruct { int x, y; }` elements (4 MB working set, L3-bound),
20 repetitions with random interleaving to average out intra-run thermal drift.

| Benchmark | Description |
|---|---|
| `BM_CBaseline` | Raw heap + placement `new` — theoretical lower bound |
| `BM_CBaseline2` | Raw heap + assignment — exposes MSVC store-forward stall |
| `BM_CBaseline3` | Raw heap + `std::construct_at` — C++20 equivalent to placement `new` |
| `BM_EmplaceBack` | `vector::reserve` + `emplace_back` |
| `BM_PushBack` | `vector::reserve` + `push_back` (named-object copy) |
| `BM_FromRange` | C++23 `std::from_range` constructor from `views::iota` |
| `BM_FromRangeIterators` | Two-iterator constructor from a transform view |

## Build script options

```powershell
.\build.ps1 -NoBuild -CooldownSec 0   # re-run only, skip compile & cooldown
.\build.ps1 -Preset gcc               # single compiler
.\build.ps1 -Preset msvc -Benchmark BM_CBaseline2 -NoBuild  # single benchmark
.\build.ps1 -Clean                    # wipe build dirs and rebuild all
```

## Compiler flags

All compilers target the **x86-64-v3** ISA baseline (AVX2 + BMI2 + FMA) —
supported by every x86-64 CPU made since ~2015.

| Compiler | Key flags |
|---|---|
| MSVC | `/O2 /Ob3 /Oi /arch:AVX2 /GL /LTCG` |
| GCC | `-O3 -march=x86-64-v3` |
| Clang | `-O3 -march=x86-64-v3` |

## Prerequisites

| Tool | How to get |
|---|---|
| MSVC (VS 2022) | Visual Studio installer — "Desktop development with C++" workload |
| GCC 15.2 | `choco install mingw` (auto-installed by `build.ps1`) |
| Clang 21.1 | `choco install llvm` (auto-installed by `build.ps1`) |
| CMake ≥ 3.25 | Bundled with Visual Studio, or `choco install cmake` |
| Chocolatey | `winget install Chocolatey.Chocolatey` |
