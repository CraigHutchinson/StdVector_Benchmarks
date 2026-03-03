# Generate a self-contained HTML benchmark report with Plotly.js box plots.
#
# Box plots are built from the reported mean / median / stddev statistics:
#   median      -> centre line
#   Q1 / Q3     -> mean +/- 0.675*sigma  (normal-dist 25th/75th percentile)
#   low / high  -> mean +/- 2.5*sigma    (whisker fences)
#   mean dot    -> shown via boxmean:'sd'
#
# Usage:
#   .\report.ps1            # reads results\*.json, writes results\report.html
#   .\report.ps1 -Open      # also opens in the default browser

param([switch]$Open)

$ErrorActionPreference = "Stop"
$ResultsDir = "results"
$OutFile    = "$ResultsDir\report.html"

# ── Benchmark source-code snippet extraction ───────────────────────────────────
# Reads vector_benchmark.cpp and extracts the body of each benchmark's
# "for (auto _ : state) { ... }" loop for display in the HTML report.
$srcLines = [string[]](Get-Content "vector_benchmark.cpp" -ErrorAction SilentlyContinue)

function Get-StateLoopBody([string]$BenchName) {
    if (-not $script:srcLines) { return $null }
    $lines = $script:srcLines

    # Locate the function definition
    $fIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "void\s+$BenchName\s*\(") { $fIdx = $i; break }
    }
    if ($fIdx -lt 0) { return $null }

    # Locate "for (auto _ : state)" within the function (search up to 25 lines)
    $lIdx = -1
    for ($i = $fIdx; $i -lt [math]::Min($fIdx + 25, $lines.Count); $i++) {
        if ($lines[$i] -match 'for\s*\(auto\s+_\s*:\s*state\)') { $lIdx = $i; break }
    }
    if ($lIdx -lt 0) { return $null }

    # Brace-count to find the loop body extent
    $depth = 0; $bodyStart = -1; $bodyEnd = -1
    for ($i = $lIdx; $i -lt $lines.Count; $i++) {
        foreach ($c in [char[]]$lines[$i]) {
            if     ($c -eq '{') { if ($depth -eq 0) { $bodyStart = $i }; $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { $bodyEnd = $i; break } }
        }
        if ($bodyEnd -ge 0) { break }
    }
    if ($bodyStart -lt 0 -or $bodyEnd -le $bodyStart) { return $null }

    $body = if ($bodyEnd -gt $bodyStart + 1) { $lines[($bodyStart+1)..($bodyEnd-1)] } else { @() }

    # Strip common leading whitespace
    $nonEmpty = @($body | Where-Object { $_ -match '\S' })
    if ($nonEmpty.Count -gt 0) {
        $minInd = ($nonEmpty | ForEach-Object {
            if ($_ -match '^( +)') { $Matches[1].Length } else { 0 }
        } | Measure-Object -Minimum).Minimum
        if ($minInd -gt 0) {
            $body = $body | ForEach-Object { if ($_.Length -ge $minInd) { $_.Substring($minInd) } else { $_ } }
        }
    }
    return ($body -join "`n").TrimEnd()
}

function ConvertTo-HtmlText([string]$s) {
    $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

# ── Discover result JSON files (newest per preset) ────────────────────────────
# Files are named {preset}-{major}.json (e.g. gcc-15.json) or {preset}.json.
# The preset key is extracted by stripping a trailing -{digits} suffix.
# When multiple files share the same preset key the most recently written wins.
$preferredOrder = @("msvc","msvc26","gcc","clang")   # preferred display order

$byPreset = [ordered]@{}
foreach ($file in (Get-ChildItem "$ResultsDir\*.json" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)) {
    $key = $file.BaseName -replace '-\d+$',''        # "gcc-15" -> "gcc"
    if (-not $byPreset.Contains($key)) { $byPreset[$key] = $file.FullName }
}
if ($byPreset.Count -eq 0) { throw "No result JSON files found in $ResultsDir\" }

# Sort: preferred compilers first in defined order, then any unknown ones A-Z
$orderedKeys = @(
    $preferredOrder | Where-Object { $byPreset.Contains($_) }
    $byPreset.Keys  | Where-Object { $_ -notin $preferredOrder } | Sort-Object
)

# ── Load JSON and extract display labels ──────────────────────────────────────
# The label comes from context.compiler (injected by build.ps1) so it always
# reflects the actual compiler that produced the results.
$loaded = [ordered]@{}
foreach ($key in $orderedKeys) {
    $data  = Get-Content $byPreset[$key] | ConvertFrom-Json
    $label = if ($data.context.compiler) { $data.context.compiler } else { $key }
    $loaded[$label] = $data
}

# ── Source hash validation ────────────────────────────────────────────────────
# build.ps1 embeds context.source_hash (MD5 of vector_benchmark.cpp computed by
# CMake at build time).  Abort here if any JSON was produced from a different
# revision of the source so the report never silently mixes incompatible data.
$srcFile = "vector_benchmark.cpp"
if (Test-Path $srcFile) {
    $currentHash = (Get-FileHash $srcFile -Algorithm MD5).Hash.ToLower()
    $stale      = [System.Collections.Generic.List[string]]::new()
    $unverified = [System.Collections.Generic.List[string]]::new()
    foreach ($label in $loaded.Keys) {
        $h = $loaded[$label].context.source_hash
        if     (-not $h)             { $unverified.Add($label) }
        elseif ($h -ne $currentHash) { $stale.Add($label) }
    }
    if ($stale.Count -gt 0) {
        throw (
            "Stale results detected - the following were benchmarked against a " +
            "different version of vector_benchmark.cpp:`n  $($stale -join ', ')`n" +
            "Delete the stale JSON files and re-run .\build.ps1 to regenerate.")
    }
    if ($unverified.Count -gt 0) {
        Write-Warning (
            "Cannot verify source version for: $($unverified -join ', ') " +
            "(no source_hash in context - regenerate with the latest build.ps1).")
    }
}

# ── Parse statistics: $stats[$bench][$compiler][$agg] = ns (float) ────────────
# Used for the summary table (mean, median, stddev columns).
$stats = [ordered]@{}

# ── Raw per-repetition times: $rawTimes[$bench][$compiler] = [double[]] ────────
# Populated when benchmark_report_aggregates_only is NOT set (individual
# run_type="iteration" rows present).  Falls back to aggregate approximation.
$rawTimes = [ordered]@{}

foreach ($label in $loaded.Keys) {
    foreach ($b in $loaded[$label].benchmarks) {
        # Strip /500000/repeats:20 (or any /Arg/repeats:N suffix) -> BM_EmplaceBack
        $name = $b.run_name -replace '/\d+(/repeats:\d+)?$',''

        if ($b.run_type -eq "aggregate") {
            if ($b.aggregate_name -notin @("mean","median","stddev")) { continue }
            if (-not $stats.Contains($name))        { $stats[$name]        = [ordered]@{} }
            if (-not $stats[$name].Contains($label)){ $stats[$name][$label] = @{} }
            $stats[$name][$label][$b.aggregate_name] = [double]$b.real_time
        } elseif ($b.run_type -eq "iteration") {
            if (-not $rawTimes.Contains($name))          { $rawTimes[$name]          = [ordered]@{} }
            if (-not $rawTimes[$name].Contains($label))  { $rawTimes[$name][$label]  = [System.Collections.Generic.List[double]]::new() }
            $rawTimes[$name][$label].Add([double]$b.real_time)
        }
    }
}

$benchNames = [string[]]($stats.Keys | Sort-Object)
$compLabels = [string[]]$loaded.Keys

# ── Compiler versions from embedded context (injected by build.ps1) ────────────
$compilerVersions = [ordered]@{}
foreach ($label in $loaded.Keys) {
    $ver = $loaded[$label].context.compiler_version
    $compilerVersions[$label] = if ($ver) { $ver } else { "" }
}

# ── Colours ───────────────────────────────────────────────────────────────────
# Each compiler family gets its own hue pool; multiple versions of the same
# family step through it.  Unknown families fall back to a grey sequence.
$familyColors = @{
    "MSVC"  = @("#4C72B0","#9B59B6","#2980B9")
    "GCC"   = @("#DD8452","#E67E22","#D35400")
    "Clang" = @("#55A868","#27AE60","#1ABC9C")
}
$familyIdx = @{}
$palette   = [ordered]@{}
$fallback  = @("#7F8C8D","#95A5A6","#BDC3C7")
$fallbackIdx = 0

foreach ($label in $loaded.Keys) {
    $family = ($label -split ' ')[0]          # "MSVC", "GCC", "Clang", ...
    if ($familyColors.ContainsKey($family)) {
        $pool = $familyColors[$family]
        $idx  = if ($familyIdx.ContainsKey($family)) { $familyIdx[$family] } else { 0 }
        $palette[$label]      = $pool[$idx % $pool.Count]
        $familyIdx[$family]   = $idx + 1
    } else {
        $palette[$label] = $fallback[$fallbackIdx % $fallback.Count]
        $fallbackIdx++
    }
}

# ── Build Plotly box traces ────────────────────────────────────────────────────
# If raw per-repetition data is available (benchmark_report_aggregates_only not
# set) we feed real y-values so Plotly computes true quartiles.
# Otherwise we fall back to precomputed boxes from mean/stddev aggregates.
$hasRawData = ($rawTimes.Count -gt 0)

$traces = foreach ($label in $compLabels) {
    $col = $palette[$label]

    if ($hasRawData) {
        # Real measurements: x = repeated bench names, y = timing values
        $xVals = [System.Collections.Generic.List[string]]::new()
        $yVals = [System.Collections.Generic.List[string]]::new()

        foreach ($bench in $benchNames) {
            if (-not ($rawTimes.Contains($bench) -and $rawTimes[$bench].Contains($label))) { continue }
            foreach ($t in $rawTimes[$bench][$label]) {
                $xVals.Add($bench)
                $yVals.Add($t.ToString("F2"))
            }
        }

        $xJ = ($xVals | ForEach-Object { """$_""" }) -join ","
        $yJ = $yVals -join ","

        @"
    {
      type: 'box', name: '$label',
      x:         [$xJ],
      y:         [$yJ],
      boxmean:   'sd',
      boxpoints: 'outliers',
      marker: { color: '$col', size: 3, opacity: 0.5 },
      line:   { color: '$col' }
    }
"@
    } else {
        # Fallback: precomputed boxes approximated from mean / stddev aggregates
        $xArr  = [System.Collections.Generic.List[string]]::new()
        $q1Arr = [System.Collections.Generic.List[string]]::new()
        $medArr= [System.Collections.Generic.List[string]]::new()
        $q3Arr = [System.Collections.Generic.List[string]]::new()
        $meanA = [System.Collections.Generic.List[string]]::new()
        $loArr = [System.Collections.Generic.List[string]]::new()
        $hiArr = [System.Collections.Generic.List[string]]::new()

        foreach ($bench in $benchNames) {
            if (-not ($stats[$bench].Contains($label))) { continue }
            $s   = $stats[$bench][$label]
            $mu  = [double]$s["mean"]
            $med = [double]$s["median"]
            $sig = [double]$s["stddev"]

            $xArr.Add($bench)
            $q1Arr.Add( ([math]::Max(0, $mu - 0.675*$sig)).ToString("F0") )
            $medArr.Add( $med.ToString("F0") )
            $q3Arr.Add( ($mu + 0.675*$sig).ToString("F0") )
            $meanA.Add( $mu.ToString("F0") )
            $loArr.Add( ([math]::Max(0, $mu - 2.5*$sig)).ToString("F0") )
            $hiArr.Add( ($mu + 2.5*$sig).ToString("F0") )
        }

        $xJ = ($xArr | ForEach-Object { """$_""" }) -join ","

        @"
    {
      type: 'box', name: '$label',
      x:           [$xJ],
      q1:          [$($q1Arr  -join ',')],
      median:      [$($medArr -join ',')],
      q3:          [$($q3Arr  -join ',')],
      mean:        [$($meanA  -join ',')],
      lowerfence:  [$($loArr  -join ',')],
      upperfence:  [$($hiArr  -join ',')],
      boxpoints: false,
      marker: { color: '$col' },
      line:   { color: '$col' }
    }
"@
    }
}

$tracesJs = $traces -join ",`n"

# ── Summary table ─────────────────────────────────────────────────────────────
# Two independent axes:
#
#   GREEN BACKGROUND (per-compiler column):
#     For each compiler, find its minimum mean across all benchmarks.
#     A cell is green when: (cell_mean - compiler_min) <= cell_own_stddev
#     i.e. the result is within its own measurement noise of that compiler's best.
#
#   STAR ★ (per-benchmark row, cross-compiler):
#     For each benchmark, find the minimum mean across all compilers.
#     A cell earns ★ when: (cell_mean - row_min) <= cell_own_stddev
#     i.e. it is statistically indistinguishable from the best compiler for this benchmark.
#
# The two axes are fully independent — a ★ can appear without a green background
# (compiler is best for this benchmark but it is not one of its better benchmarks)
# and green can appear without ★ (compiler is at its best but another compiler is faster).

$headerCells = ($compLabels | ForEach-Object {
    $ver = $compilerVersions[$_]
    if ($ver) { "<th>$_<br><span class='ver'>$ver</span></th>" }
    else       { "<th>$_</th>" }
}) -join ""

# Pre-compute each compiler's minimum mean across all benchmarks.
$compilerMin = [ordered]@{}
foreach ($label in $compLabels) {
    $minVal = [double]::MaxValue
    foreach ($bench in $benchNames) {
        if ($stats[$bench].Contains($label)) {
            $m = [double]$stats[$bench][$label]["mean"]
            if ($m -lt $minVal) { $minVal = $m }
        }
    }
    $compilerMin[$label] = if ($minVal -lt [double]::MaxValue) { $minVal } else { $null }
}

$tableRows = foreach ($bench in $benchNames) {
    $meanMap   = [ordered]@{}
    $stddevMap = [ordered]@{}
    foreach ($label in $compLabels) {
        if ($stats[$bench].Contains($label)) {
            $meanMap[$label]   = [double]$stats[$bench][$label]["mean"]
            $stddevMap[$label] = [double]$stats[$bench][$label]["stddev"]
        }
    }

    $validMeans = $meanMap.Values | Where-Object { $_ -gt 0 }
    if (-not $validMeans) { continue }

    # Rank compilers by mean for this benchmark (ascending). Ties within own stddev
    # share the same medal — e.g. two compilers both within noise of the minimum both get gold.
    $sortedLabels = $meanMap.Keys | Sort-Object { $meanMap[$_] }
    $medalClass   = @('gold', 'silver', 'bronze')

    # Assign medal: start at rank 0; a compiler keeps the same rank as the previous
    # one if it is within its own stddev of that previous compiler's mean.
    $rankMap = [ordered]@{}
    $currentRank = 0
    $prevMean    = $null
    foreach ($lbl in $sortedLabels) {
        if ($null -ne $prevMean) {
            $gap = $meanMap[$lbl] - $prevMean
            # Only advance the rank if the gap exceeds this compiler's own stddev
            if ($gap -gt $stddevMap[$lbl]) { $currentRank++ }
        }
        $rankMap[$lbl] = [math]::Min($currentRank, 2)   # cap at bronze
        $prevMean = $meanMap[$lbl]
    }

    $tds = foreach ($label in $compLabels) {
        if (-not $meanMap.Contains($label)) {
            "<td class='na'>n/a</td>"
        } else {
            $mu   = $meanMap[$label]
            $sig  = $stddevMap[$label]
            $us   = ($mu / 1000.0).ToString("F1")
            $sdUs = ($sig / 1000.0).ToString("F1")

            # GREEN: within the compiler's own noise of its personal best across benchmarks?
            $cMin    = $compilerMin[$label]
            $isGreen = ($null -ne $cMin) -and (($mu - $cMin) -le $sig)

            $rank   = $rankMap[$label]
            $medal  = $medalClass[$rank]
            $isGold = ($rank -eq 0)

            $classes = @()
            if ($isGreen) { $classes += 'best' }
            if ($isGold)  { $classes += 'starred' }   # bold only for gold
            $cls  = if ($classes) { " class='$($classes -join ' ')'" } else { "" }

            "<td$cls>${us} <span class='sd'>&plusmn;${sdUs}</span> <span class='star $medal'>&#9733;</span></td>"
        }
    }
    $snippet  = Get-StateLoopBody $bench
    $codeHtml = if ($snippet) {
        $esc = ConvertTo-HtmlText $snippet
        "<details><summary class='bname'>$bench</summary><pre class='snippet'>$esc</pre></details>"
    } else { "<span class='bname'>$bench</span>" }
    "<tr><td>$codeHtml</td>$($tds -join '')</tr>"
}

# ── Context metadata ──────────────────────────────────────────────────────────
$ctx     = $loaded[$compLabels[0]].context
$runDate = $ctx.date
$host_   = $ctx.host_name
$cpus    = $ctx.num_cpus
$mhz     = $ctx.mhz_per_cpu

# ── Render HTML ───────────────────────────────────────────────────────────────
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VectorInitBench &mdash; Report</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js" charset="utf-8"></script>
<style>
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
       background:#f4f5f8;color:#1a1a2e;padding:2rem 2.5rem}
  h1  {font-size:1.55rem;font-weight:700;letter-spacing:-.5px}
  h1 a{color:inherit;text-decoration:none}
  h1 a:hover{text-decoration:underline}
  h2  {font-size:.95rem;font-weight:600;color:#555;margin:1.8rem 0 .7rem;
       text-transform:uppercase;letter-spacing:.06em}
  .meta{font-size:.78rem;color:#888;margin:.4rem 0 2rem;display:flex;gap:1.4rem;flex-wrap:wrap}
  .chip{background:#fff;border:1px solid #e2e4ea;border-radius:99px;
        padding:.15rem .7rem;font-size:.75rem}
  .card{background:#fff;border-radius:12px;padding:1.6rem;
        box-shadow:0 1px 6px rgba(0,0,0,.07);margin-bottom:1.6rem}
  #box-chart{width:100%;height:500px}
  .note{font-size:.72rem;color:#aaa;margin-top:.5rem}
  table{width:100%;border-collapse:collapse;font-size:.855rem}
  thead th{background:#f0f1f6;padding:.55rem 1rem;text-align:left;
            font-weight:600;border-bottom:2px solid #dde}
  td{padding:.48rem 1rem;border-bottom:1px solid #eef;white-space:nowrap}
  tr:last-child td{border-bottom:none}
  .bname {font-family:"Cascadia Code","Consolas",monospace;font-size:.8rem;color:#333}
  details summary.bname{cursor:pointer;list-style:disclosure-closed inside;padding:.1rem 0}
  details[open] summary.bname{list-style-type:disclosure-open}
  pre.snippet{font-family:"Cascadia Code","Consolas",monospace;font-size:.72rem;
              background:#f0f4f8;color:#1e293b;border-left:3px solid #c7d2fe;
              padding:.45rem .75rem;margin:.3rem 0 .1rem;border-radius:0 6px 6px 0;
              overflow-x:auto;white-space:pre;line-height:1.45}
  .best        {color:#14532d;background:#bbf7d0}
  .starred     {font-weight:700}
  .sd          {font-weight:400;font-size:.75rem;color:#6b9;opacity:.85}
  .star        {font-size:.75rem;margin-left:.1rem}
  .star.gold   {color:#16a34a}
  .star.silver {color:#d97706}
  .star.bronze {color:#dc2626}
  .na     {color:#bbb}
  .ver    {font-size:.7rem;font-weight:400;opacity:.65}
  .legend {font-size:.75rem;color:#666;margin-top:.75rem;display:flex;gap:1.5rem;flex-wrap:wrap}
  .leg-dot{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:middle}
  footer{font-size:.72rem;color:#bbb;margin-top:2rem;text-align:center}
</style>
</head>
<body>

<h1><a href="https://github.com/CraigHutchinson/StdVector_Benchmarks">VectorInitBench</a> &mdash; Compiler Comparison</h1>
<div class="meta">
  <span class="chip">$runDate</span>
  <span class="chip">$host_</span>
  <span class="chip">${cpus}&times; CPU @ ${mhz} MHz</span>
  <span class="chip">N = 500&thinsp;000 &middot; 20 repetitions</span>
</div>

<div class="card">
  <h2>Distribution of wall-clock times per benchmark</h2>
  <div id="box-chart"></div>
  <p class="note">
$(if ($hasRawData) {
    "    True box plot from $($rawTimes[$benchNames[0]][$compLabels[0]].Count) raw repetitions per benchmark &nbsp;&middot;&nbsp; box = IQR &nbsp;&middot;&nbsp; whiskers = 1.5&times;IQR &nbsp;&middot;&nbsp; &times; = mean"
} else {
    "    Box = mean &plusmn; 0.675&sigma; &nbsp;(normal 25th/75th percentile approx.)&nbsp;&middot;&nbsp; Whiskers = mean &plusmn; 2.5&sigma; &nbsp;&middot;&nbsp; Centre line = median &nbsp;&middot;&nbsp; &times; = mean"
})
  </p>
</div>

<div class="card">
  <h2>Mean time summary &mdash; fastest highlighted</h2>
  <table>
    <thead><tr><th>Benchmark</th>$headerCells</tr></thead>
    <tbody>
$($tableRows -join "`n")
    </tbody>
  </table>
  <div class="legend">
    <span><span class="leg-dot" style="background:#bbf7d0;outline:1px solid #15803d"></span> <strong>Green</strong> &mdash; within this compiler&rsquo;s own &sigma; of its personal best</span>
    <span><strong style="color:#16a34a">&#9733;</strong> Fastest &middot; <strong style="color:#d97706">&#9733;</strong> 2nd &middot; <strong style="color:#dc2626">&#9733;</strong> Slowest &mdash; rank per benchmark (ties share when gap &le; own &sigma;)</span>
    <span><strong>Bold</strong> = gold rank &middot; &plusmn;&sigma; = std dev across the 20 repetitions</span>
  </div>
</div>

<footer>Generated by report.ps1 &nbsp;&middot;&nbsp; google/benchmark $($ctx.library_version)</footer>

<script>
// htmlpreview.github.io loads <script src> asynchronously via its own loadJS
// helper, so Plotly may not be defined yet when this inline block runs.
// Poll until the library is available before calling newPlot.
(function waitForPlotly() {
  if (typeof Plotly === 'undefined') { setTimeout(waitForPlotly, 50); return; }
  Plotly.newPlot('box-chart', [
$tracesJs
  ], {
    boxmode: 'group',
    yaxis:  { title: 'wall-clock time (ns)', zeroline: false, gridcolor: '#f0f1f6' },
    xaxis:  { tickangle: -20 },
    legend: { orientation: 'h', y: 1.10, x: 0 },
    margin: { t: 10, b: 130, l: 75, r: 20 },
    paper_bgcolor: 'white',
    plot_bgcolor:  '#fafbfc',
    font: { family: '-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif', size: 12 }
  }, { responsive: true, displayModeBar: false });
})();
</script>
</body>
</html>
"@

New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$html | Out-File -FilePath $OutFile -Encoding utf8
$kb = [math]::Round((Get-Item $OutFile).Length / 1KB, 1)
Write-Host "Report written: $OutFile  ($kb KB)" -ForegroundColor Green

if ($Open) { Start-Process $OutFile }
