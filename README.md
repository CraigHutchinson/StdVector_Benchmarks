# StdVector\_Benchmarks

A cross-compiler C++23 microbenchmark comparing `std::vector` initialisation
strategies against raw C-style heap allocation baselines, measured under MSVC,
GCC, and Clang on Windows.

## Quick start

```powershell
.\build.ps1; .\report.ps1 -Open
```

Configures, builds, and runs all three compiler variants (with a 30 s thermal
cooldown between each), then opens an interactive HTML report in your browser.

## Benchmarks

Each benchmark allocates N = 500 000 `MyStruct { int x, y; }` elements — a
4 MB working set that lives in L3 cache — and measures the wall-clock time to
fill it. 20 repetitions with random interleaving are used per run.

---

### `BM_CBaseline` — placement `new` (lower bound)

```cpp
MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
for (size_t i = 0; i < N; ++i)
    ::new (static_cast<void*>(vec+i)) MyStruct(i, i);
delete[] vec;
```

Raw heap allocation with in-place construction. No vector overhead.
Generates 2 direct DWORD stores per element on all compilers — the
theoretical lower bound for this workload.

---

### `BM_CBaseline2` — assignment (exposes MSVC store-forward stall)

```cpp
MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
for (size_t i = 0; i < N; ++i)
    vec[i] = MyStruct(i, i);
delete[] vec;
```

Looks identical to `BM_CBaseline` but uses assignment. C++ requires the
prvalue `MyStruct(i,i)` to be materialised as a stack temporary before
assignment — two 4-byte stores feed a single 8-byte load, hitting Intel's
**store-forward stall** (~4–5 cycles/iter). GCC and Clang eliminate the
temporary via SRoA; MSVC does not, making this ~3× slower on MSVC.

---

### `BM_CBaseline3` — `std::construct_at` (C++20)

```cpp
MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
for (size_t i = 0; i < N; ++i)
    std::construct_at(vec + i, static_cast<int>(i), static_cast<int>(i));
delete[] vec;
```

`std::construct_at` is implemented as `::new(static_cast<void*>(p)) T(args...)`
inside `<memory>`, so it generates byte-for-byte identical code to
`BM_CBaseline` on all three compilers — no stack temporary, no stall.

---

### `BM_EmplaceBack` — `vector::reserve` + `emplace_back`

```cpp
std::vector<MyStruct> vec;
vec.reserve(N);
for (size_t i = 0; i < N; ++i)
    vec.emplace_back(i, i);
```

The idiomatic modern C++ approach. `emplace_back` constructs in-place after
`reserve`, so no reallocations occur. GCC/Clang match `BM_CBaseline` closely;
MSVC shows a modest overhead.

---

### `BM_PushBack` — `vector::reserve` + `push_back` (copy)

```cpp
std::vector<MyStruct> vec;
vec.reserve(N);
for (size_t i = 0; i < N; ++i) {
    MyStruct obj(i, i);
    vec.push_back(obj);
}
```

Explicit copy: constructs a named object then copies it into the vector. The
named object is not an rvalue, so the compiler cannot elide the copy.

---

### `BM_FromRange` — C++23 range constructor

```cpp
std::vector<MyStruct> vec( std::from_range,
    std::views::iota(0uz, N) |
    std::views::transform([](size_t i){ return MyStruct(i, i); }) );
```

Uses the C++23 `std::from_range_t` constructor tag. Requires
`__cpp_lib_containers_ranges`; guarded with `#ifdef` for compilers that lack it.

---

### `BM_FromRangeIterators` — iterator-pair constructor

```cpp
auto range = std::views::iota(0uz, N) |
             std::views::transform([](size_t i){ return MyStruct(i, i); });
std::vector<MyStruct> vec( std::begin(range), std::end(range) );
```

The classic two-iterator form — compatible back to C++11 but applied here to a
C++20 transform view. The vector cannot know the size up front from a transform
view's iterators alone, so some implementations may over-allocate.

---

## Latest results

Pre-built JSON results from the most recent run are included in the repository:

| Compiler | Raw JSON |
|---|---|
| MSVC 19 | [results/msvc.json](results/msvc.json) |
| GCC 15.2 | [results/gcc.json](results/gcc.json) |
| Clang 21.1 | [results/clang.json](results/clang.json) |

## Prerequisites

| Tool | How to get |
|---|---|
| MSVC (VS 2022) | Visual Studio installer — "Desktop development with C++" workload |
| GCC 15.2 | `choco install mingw` (auto-installed by `build.ps1`) |
| Clang 21.1 | `choco install llvm` (auto-installed by `build.ps1`) |
| CMake ≥ 3.25 | Bundled with Visual Studio, or `choco install cmake` |
| Chocolatey | `winget install Chocolatey.Chocolatey` |

## Build script options

```powershell
# Full rebuild + run, open report
.\build.ps1; .\report.ps1 -Open

# Re-run only (skip compile), no cooldown — for quick iteration
.\build.ps1 -NoBuild -CooldownSec 0

# Single compiler
.\build.ps1 -Preset gcc

# Single compiler, single benchmark, no rebuild
.\build.ps1 -Preset msvc -Benchmark BM_CBaseline2 -NoBuild

# Clean rebuild of all compilers
.\build.ps1 -Clean
```

## Report output

`report.ps1` generates a self-contained `results/report.html` with:

- **Plotly box/whisker plots** — distribution of wall-clock time per benchmark
  (box = mean ± 0.675σ, whiskers = mean ± 2.5σ, centre = median)
- **Summary table** with two independent highlighting axes:
  - **Green background** — result is within this compiler's own σ of its
    personal best across all benchmarks
  - **★ stars** — gold/silver/bronze for fastest/2nd/3rd per benchmark
    (ties within own σ share the same medal)

## Compiler flags

All three compilers target the **x86-64-v3** ISA baseline (AVX2 + BMI2 + FMA),
supported by every x86-64 CPU made since ~2015.

| Compiler | Key flags |
|---|---|
| MSVC | `/O2 /Ob3 /Oi /arch:AVX2 /GL /LTCG` |
| GCC | `-O3 -march=x86-64-v3` |
| Clang | `-O3 -march=x86-64-v3` |

## Key findings

- **Placement `new` and `std::construct_at`** produce byte-for-byte identical
  machine code (2 direct DWORD stores per element). Both match on all three
  compilers.
- **`BM_CBaseline2` (assignment) is ~3× slower on MSVC** — the compiler
  cannot eliminate the stack temporary required by C++ assignment semantics,
  causing an Intel store-forward stall. GCC and Clang eliminate it via SRoA.
  No optimisation flag resolves this; it is a genuine compiler quality
  difference.
- **`emplace_back` is close to the raw baseline** on GCC and Clang after
  `reserve`. MSVC shows a small but consistent overhead.
