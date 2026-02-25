// Language: C++
// A Google Benchmark for std::vector push_back vs emplace_back

#include <benchmark/benchmark.h>
#include <vector>
#include <cstddef>   // std::byte
#include <memory>    // std::construct_at
#include <ranges>
#include <algorithm>

// Simple struct with constructor overhead
struct MyStruct {
    int x, y;
    MyStruct(int a, int b) : x(a), y(b) {}
};

// Benchmark baseline
static void BM_CBaseline(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
        for (size_t i = 0; i < N; ++i) {
            ::new (static_cast<void*>(vec+i)) MyStruct(i, i);
        }

        delete[] vec;
        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

// Benchmark emplace_back
static void BM_EmplaceBack(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        std::vector<MyStruct> vec;
        vec.reserve(N);
        for (size_t i = 0; i < N; ++i) {
            vec.emplace_back(i, i);
        }
        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

// Benchmark push_back
static void BM_PushBack(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        std::vector<MyStruct> vec;
        vec.reserve(N);
        for (size_t i = 0; i < N; ++i) {
            MyStruct obj(i, i);
            vec.push_back(obj);
        }
        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

static void BM_FromRange(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        std::vector<MyStruct> vec( std::from_range, 
            std::views::iota(0uz,N) |
            std::views::transform(
                [](size_t i){ 
                    return MyStruct(i,i); 
                }) );

        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

static void BM_FromRangeIterators(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        auto range = std::views::iota(0uz,N) |
                std::views::transform(
                    [](size_t i){ 
                        return MyStruct(i,i); 
                    });
                    
        std::vector<MyStruct> vec( std::begin(range), std::end(range) );

        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

// Second baseline using assignment instead of placement new.
// GCC/Clang apply SRoA (Scalar Replacement of Aggregates) and produce the same
// 2-store-per-element code as BM_CBaseline (~1000 us).
// MSVC materialises MyStruct(i,i) as a stack temporary (C++ requires this for
// assignment, unlike initialisation which allows mandatory copy elision), then
// merges two 4-byte stores into a single 8-byte stack load — hitting Intel's
// store-forward stall (~4-5 cycle latency/iter). Result: ~3x slower on MSVC.
// This is a genuine compiler quality difference, not a missing optimisation flag.
static void BM_CBaseline2(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
        for (size_t i = 0; i < N; ++i) {
            vec[i] = MyStruct(i,i);
        }
        delete[] vec;
        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}

// BM_CBaseline3: std::construct_at — C++20 named alternative to placement new.
// ASM analysis shows this generates byte-for-byte identical code to BM_CBaseline
// (2 direct DWORD stores, no stack temporary) because construct_at is implemented
// as ::new(static_cast<void*>(p)) T(args...) inside <memory>.
// Unlike BM_CBaseline2 (assignment), no temporary is materialised on the stack,
// so there is no store-forward stall. Expected to match BM_CBaseline on all compilers.
static void BM_CBaseline3(benchmark::State& state) {
    size_t N = state.range(0);
    for (auto _ : state) {
        MyStruct* vec = (MyStruct*)new std::byte[ sizeof(MyStruct) * N ];
        for (size_t i = 0; i < N; ++i)
            std::construct_at(vec + i, static_cast<int>(i), static_cast<int>(i));
        delete[] vec;
        benchmark::DoNotOptimize(vec);
    }
    state.SetItemsProcessed(state.iterations() * N);
}


// Individual runs + aggregates are both written to JSON.
// Console display is kept compact via --benchmark_report_aggregates_only=true
// passed on the command line from build.ps1.

BENCHMARK(BM_FromRange)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_FromRangeIterators)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_EmplaceBack)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_PushBack)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_CBaseline)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_CBaseline2)->Arg(500000)->Repetitions(20);
BENCHMARK(BM_CBaseline3)->Arg(500000)->Repetitions(20);

BENCHMARK_MAIN();
