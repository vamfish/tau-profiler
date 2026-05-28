# Build portable tau_profiler binaries for all supported platforms
# Uses x86_64-v3 (AVX2, no AVX-512) for best compatibility/performance balance
param(
    [switch]$MaxCompat  # Use baseline x86-64 instead of x86_64-v3
)

$cpu_level = if ($MaxCompat) { "baseline" } else { "x86_64_v3" }
$out_dir = "zig-out-portable"
New-Item -ItemType Directory -Force -Path $out_dir | Out-Null

Write-Host "=== Building tau_profiler portable binaries ==="
Write-Host "CPU target: $cpu_level"
Write-Host ""

$targets = @(
    @{Name="Windows"; Target="x86_64-windows"; Ext=".exe"},
    @{Name="Linux (GNU)"; Target="x86_64-linux-gnu"; Ext=""},
    @{Name="Linux (musl)"; Target="x86_64-linux-musl"; Ext=""},
    @{Name="macOS"; Target="x86_64-macos"; Ext=""}
)

foreach ($t in $targets) {
    Write-Host "  Building for $($t.Name)..." -NoNewline
    $out = & zig build "-Dtarget=$($t.Target)" "-Dcpu=$cpu_level" "-Doptimize=ReleaseFast" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $src = "zig-out\bin\tau_profiler$($t.Ext)"
        $dst = "$out_dir\tau_profiler-$($t.Target)$($t.Ext)"
        Copy-Item $src $dst -Force
        Write-Host " OK -> $dst" -ForegroundColor Green
    } else {
        Write-Host " FAILED (target may not be cross-compilable from this host)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Portable binaries saved to: $out_dir/"
Write-Host ""
Write-Host "CPU compatibility:"
if ($MaxCompat) {
    Write-Host "  baseline x86-64 (any x86-64 CPU, 2003+)"
} else {
    Write-Host "  x86_64-v3 (Intel Haswell 2013+ / AMD Excavator 2015+)"
}
