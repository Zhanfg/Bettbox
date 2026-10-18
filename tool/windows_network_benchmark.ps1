# Read-only Windows TUN/System-Proxy benchmark.
# Run once with TUN on, and again with System Proxy on. This script never
# changes the network, routes, DNS, proxy settings, or service privileges.
# This is a lightweight CPU/RAM baseline, NOT a packet benchmark/power meter.
param(
    [ValidateSet('tun','system-proxy','both')]
    [string]$Mode = 'tun',
    [ValidateRange(10,3600)]
    [int]$Seconds = 60,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    throw 'This benchmark must run on Windows.'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $env:LOCALAPPDATA 'Bettbox/Benchmarks'
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null

$names = @('Bettbox', 'BettboxCore', 'BettboxHelperService')
$initial = @{}
$maxPrivate = @{}
$maxWorking = @{}
$seen = @{}

function Read-Processes {
    $table = @{}
    foreach ($name in $names) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $key = "$($p.ProcessName):$($p.Id)"
            try {
                $table[$key] = [pscustomobject]@{
                    Name = $p.ProcessName
                    Pid = $p.Id
                    CpuSeconds = [double]$p.CPU
                    PrivateBytes = [int64]$p.PrivateMemorySize64
                    WorkingBytes = [int64]$p.WorkingSet64
                }
            } catch { }
        }
    }
    return $table
}

$start = [DateTime]::UtcNow
$initial = Read-Processes
if ($initial.Count -eq 0) {
    throw 'No Bettbox processes detected. Start the Windows client first.'
}
$endTime = $start.AddSeconds($Seconds)
while ([DateTime]::UtcNow -lt $endTime) {
    $points = Read-Processes
    foreach ($key in $points.Keys) {
        $v = $points[$key]
        $seen[$key] = $v
        $maxPrivate[$key] = [Math]::Max([int64]($maxPrivate[$key]), $v.PrivateBytes)
        $maxWorking[$key] = [Math]::Max([int64]($maxWorking[$key]), $v.WorkingBytes)
    }
    Start-Sleep -Milliseconds 2000
}
$finish = [DateTime]::UtcNow
$last = Read-Processes
$elapsed = [Math]::Max(1.0, ($finish - $start).TotalSeconds)
$threads = [Math]::Max(1, [Environment]::ProcessorCount)

$entries = @()
foreach ($key in $initial.Keys) {
    $from = $initial[$key]
    $to = $last[$key]
    if ($null -eq $to) { continue }
    $delta = [Math]::Max(0.0, $to.CpuSeconds - $from.CpuSeconds)
    $entries += [pscustomobject]@{
        Process = $from.Name
        CpuSecondsDelta = [Math]::Round($delta,3)
        AverageTotalCpuPercent = [Math]::Round(100*$delta/$elapsed/$threads,3)
        PeakPrivateMiB = [Math]::Round(($maxPrivate[$key] / 1MB),2)
        PeakWorkingSetMiB = [Math]::Round(($maxWorking[$key] / 1MB),2)
    }
}
$report = [pscustomobject]@{
    Schema = 1
    ModeLabel = $Mode
    ModeVerified = $false
    Description = 'User-supplied mode label; check actual Bettbox UI. Read-only sampling.'
    StartedUtc = $start.ToString('o')
    ElapsedSeconds = [Math]::Round($elapsed,3)
    LogicalProcessors = $threads
    Processes = $entries
    Limitations = @(
        'Not a latency, packet loss, power, TUN route, or DNS leak test.',
        'Only processes alive for the full interval are compared.',
        'Sampling adds minimal but nonzero overhead.',
        'Run the same workload and sample duration for both modes.'
    )
}
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$target = Join-Path $OutputDirectory "Bettbox-Network-$Mode-$stamp.json"
$report | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $target -Encoding utf8
Write-Host "Saved network-mode baseline: $target"
$entries | Format-Table -AutoSize
