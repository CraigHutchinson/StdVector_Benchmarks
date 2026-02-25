# Configure, build, and run benchmarks for all (or one) compiler preset.
#
# Toolchain dependencies (installed automatically if absent):
#   choco install mingw   ->  GCC 15.2  @ C:\ProgramData\mingw64\mingw64\bin
#   choco install llvm    ->  LLVM 21.1 @ C:\Program Files\LLVM\bin
#   ninja standalone zip  ->  Ninja     @ C:\ProgramData\mingw64\mingw64\bin  (bundled w/ mingw)
#
# Usage:
#   .\build.ps1                                        # ensure tools, configure + build + run all
#   .\build.ps1 -Preset gcc                            # only gcc
#   .\build.ps1 -NoBuild                               # skip configure/build, re-run only
#   .\build.ps1 -Clean                                 # wipe build dirs for selected presets first
#   .\build.ps1 -Preset msvc -Benchmark BM_CBaseline2 # run one benchmark on one compiler
#   .\build.ps1 -Preset msvc -Benchmark BM_CBaseline2 -NoBuild  # re-run without rebuilding
#   .\build.ps1 -CooldownSec 0                         # disable inter-run thermal cooldown
#
# -Benchmark   accepts a regex passed verbatim to --benchmark_filter (google/benchmark).
# -CooldownSec seconds to sleep between compiler runs so the CPU returns to idle temperature.
#              Default 30 s. Set to 0 to skip (e.g. quick iteration on a single preset).

param(
    [ValidateSet("all","msvc","gcc","clang")]
    [string]$Preset      = "all",
    [string]$Benchmark   = "",   # regex filter; empty = run all benchmarks
    [int]   $CooldownSec = 30,   # inter-run thermal cooldown; 0 to disable
    [switch]$NoBuild,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# -- Thermal cooldown countdown ----------------------------------------------
function Wait-Cooldown([int]$Seconds, [string]$After) {
    if ($Seconds -le 0) { return }
    Write-Host ""
    Write-Host "  [cooldown] ${Seconds}s after $After - letting CPU thermals settle..." -ForegroundColor DarkYellow
    $barW = 40
    for ($i = $Seconds; $i -ge 0; $i--) {
        $done   = [int]([math]::Round($barW * ($Seconds - $i) / $Seconds))
        $remain = $barW - $done
        $arrow  = if ($remain -gt 0) { '>' } else { '=' }
        $bar    = '[' + ('=' * $done) + $arrow + (' ' * [math]::Max(0, $remain - 1)) + ']'
        $pct    = [int](100 * ($Seconds - $i) / $Seconds)
        Write-Host "`r  $bar $pct% (${i}s left)   " -NoNewline -ForegroundColor DarkYellow
        if ($i -gt 0) { Start-Sleep -Seconds 1 }
    }
    Write-Host "`r  [thermal cooldown complete]$(' ' * 35)" -ForegroundColor DarkGray
}

# -- Known install paths (choco defaults) ------------------------------------
$ChocolateyBin = "C:\ProgramData\chocolatey\bin\choco.exe"
$MinGWBin      = "C:\ProgramData\mingw64\mingw64\bin"
$LLVMBin       = "C:\Program Files\LLVM\bin"
$NinjaCache    = "$env:LOCALAPPDATA\VectorInitBench\ninja"    # user-writable

# -- Ensure toolchains are installed -----------------------------------------
function Install-ChocoPackage([string]$Id, [string]$ProbeExe) {
    if (Test-Path $ProbeExe) {
        Write-Host "  $Id already installed." -ForegroundColor DarkGray
        return
    }
    if (-not (Test-Path $ChocolateyBin)) {
        throw "Chocolatey not found at $ChocolateyBin. Run: winget install Chocolatey.Chocolatey"
    }
    Write-Host "  Installing $Id via choco (requires elevation)..." -ForegroundColor Cyan
    $log = "$env:TEMP\choco-$Id.log"
    Start-Process powershell `
        -ArgumentList "-NoProfile -Command `"choco install $Id --yes --no-progress 2>&1 | Tee-Object '$log'`"" `
        -Verb RunAs -Wait
    if (-not (Test-Path $ProbeExe)) {
        Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 20 | Write-Host
        throw "Installation of '$Id' failed - $ProbeExe not found."
    }
    Write-Host "  $Id installed successfully." -ForegroundColor Green
}

function Initialize-Toolchains {
    Write-Host "Checking toolchains..." -ForegroundColor Yellow
    Install-ChocoPackage "mingw" "$MinGWBin\g++.exe"
    Install-ChocoPackage "llvm"  "$LLVMBin\clang++.exe"

    # Ninja: download standalone to a user-writable cache (choco mingw doesn't bundle it)
    $ninjaExe = "$NinjaCache\ninja.exe"
    if (-not (Test-Path $ninjaExe)) {
        Write-Host "  Downloading Ninja standalone..." -ForegroundColor Cyan
        $ninjaRel = Invoke-RestMethod "https://api.github.com/repos/ninja-build/ninja/releases/latest" -UseBasicParsing
        $ninjaUrl = ($ninjaRel.assets | Where-Object { $_.name -eq "ninja-win.zip" }).browser_download_url
        $ninjaZip = "$env:TEMP\ninja-win.zip"
        Invoke-WebRequest $ninjaUrl -OutFile $ninjaZip -UseBasicParsing
        New-Item -ItemType Directory -Force -Path $NinjaCache | Out-Null
        Expand-Archive $ninjaZip -DestinationPath $NinjaCache -Force
    }

    # Expose as env vars consumed by CMakePresets.json
    $env:CHOCO_MINGW_BIN = $MinGWBin
    $env:CHOCO_LLVM_BIN  = $LLVMBin
    $env:VECTBENCH_NINJA = $ninjaExe

    # GCC runtime DLLs (libgcc_s, libstdc++, etc.) must be on PATH so that
    # both g++ itself and compiled test binaries can be loaded by CMake.
    if ($env:PATH -notlike "*$MinGWBin*") {
        $env:PATH = "$MinGWBin;$env:PATH"
    }

    $gccVer   = (& "$MinGWBin\g++.exe"    --version 2>&1 | Select-Object -First 1) -replace '^g\+\+\.exe \(','' -replace '\).*',''
    $clangVer = (& "$LLVMBin\clang++.exe" --version 2>&1 | Select-Object -First 1) -replace 'clang version ',''
    $ninjaVer = & $ninjaExe --version 2>&1
    Write-Host "  GCC:   $gccVer"   -ForegroundColor DarkGray
    Write-Host "  Clang: $clangVer" -ForegroundColor DarkGray
    Write-Host "  Ninja: $ninjaVer" -ForegroundColor DarkGray
}

# -- Preset metadata ----------------------------------------------------------
$AllPresets = [ordered]@{
    msvc  = "MSVC 19"
    gcc   = "GCC 15.2"
    clang = "Clang 21.1"
}

$Selected = if ($Preset -eq "all") { $AllPresets.Keys } else { @($Preset) }

# -- Ensure toolchains (skip for msvc-only runs) -----------------------------
$needsMinGW = $Selected | Where-Object { $_ -ne "msvc" }
if ($needsMinGW -and -not $NoBuild) { Initialize-Toolchains }
elseif ($needsMinGW) {
    $env:CHOCO_MINGW_BIN = $MinGWBin
    $env:CHOCO_LLVM_BIN  = $LLVMBin
    $env:VECTBENCH_NINJA = "$NinjaCache\ninja.exe"
    if ($env:PATH -notlike "*$MinGWBin*") { $env:PATH = "$MinGWBin;$env:PATH" }
}

# -- Clean -------------------------------------------------------------------
if ($Clean) {
    foreach ($p in $Selected) {
        $dir = "build_$p"
        if (Test-Path $dir) {
            Write-Host "Removing $dir ..." -ForegroundColor DarkGray
            Remove-Item -Recurse -Force $dir
        }
    }
}

# -- Configure + Build -------------------------------------------------------
if (-not $NoBuild) {
    foreach ($p in $Selected) {
        Write-Host ""
        Write-Host "=== $($AllPresets[$p]) ===" -ForegroundColor Yellow
        cmake --preset $p
        if ($LASTEXITCODE -ne 0) { throw "Configure failed for preset '$p'" }
        cmake --build --preset $p
        if ($LASTEXITCODE -ne 0) { throw "Build failed for preset '$p'" }
    }
}

# -- Run benchmarks ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path results | Out-Null
$allResults  = [ordered]@{}
$prevPreset  = $null   # used for cooldown labelling

foreach ($p in $Selected) {
    $exe = Get-ChildItem -Recurse -Path "build_$p" -Filter "vector_benchmark.exe" -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
    if (-not $exe) { Write-Warning "No binary in build_$p - skipping."; continue }

    # Pause between compiler runs so CPU thermals return to idle baseline.
    if ($null -ne $prevPreset) {
        Wait-Cooldown -Seconds $CooldownSec -After $AllPresets[$prevPreset]
    }

    $filterDesc = if ($Benchmark) { " [filter: $Benchmark]" } else { "" }
    Write-Host ""
    Write-Host "--- Running $($AllPresets[$p])$filterDesc ---" -ForegroundColor Green

    # --benchmark_report_aggregates_only=true keeps the console compact;
    # the JSON file receives all individual repetition timings for box plots.
    # --benchmark_enable_random_interleaving=true shuffles the order in which
    # repetitions of each benchmark run, averaging out intra-run thermal drift.
    $runArgs = @(
        "--benchmark_report_aggregates_only=true",
        "--benchmark_enable_random_interleaving=true",
        "--benchmark_format=json",
        "--benchmark_out=results\$p.json"
    )
    if ($Benchmark) { $runArgs += "--benchmark_filter=$Benchmark" }

    & $exe @runArgs
    if ($LASTEXITCODE -ne 0) { throw "Benchmark failed for '$p'" }
    $allResults[$AllPresets[$p]] = "results\$p.json"
    $prevPreset = $p
}

# -- Comparison table --------------------------------------------------------
if ($allResults.Count -lt 2) { exit 0 }

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host "  COMPARISON  --  mean wall time (ns)  --  lower is better" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan

$table  = [ordered]@{}
$labels = [string[]]$allResults.Keys

foreach ($label in $labels) {
    $data = Get-Content $allResults[$label] | ConvertFrom-Json
    foreach ($b in $data.benchmarks) {
        if ($b.aggregate_name -ne "mean") { continue }
        $name = $b.name -replace '/\d+/repeats:\d+_mean', ''
        if (-not $table.Contains($name)) { $table[$name] = [ordered]@{} }
        $table[$name][$label] = [long]$b.real_time
    }
}

$colW = 16
$hdr  = "{0,-30}" -f "Benchmark"
foreach ($l in $labels) { $hdr += "{0,$colW}" -f $l }
Write-Host $hdr -ForegroundColor White
Write-Host ("-" * $hdr.Length)

foreach ($name in $table.Keys) {
    $row  = $table[$name]
    $best = ($labels | ForEach-Object { $row[$_] } | Where-Object { $_ } | Measure-Object -Minimum).Minimum
    $line = "{0,-30}" -f $name
    foreach ($l in $labels) {
        $v    = $row[$l]
        $cell = if ($null -eq $v) { "n/a" } else { "$v ns" }
        if ($v -eq $best) {
            Write-Host $line -NoNewline
            Write-Host ("{0,$colW}" -f $cell) -NoNewline -ForegroundColor Green
            $line = ""
        } else {
            $line += "{0,$colW}" -f $cell
        }
    }
    Write-Host $line
}

Write-Host ""
Write-Host "Results saved to: results\" -ForegroundColor DarkGray
