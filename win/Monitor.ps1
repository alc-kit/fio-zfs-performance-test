<#
.SYNOPSIS
    Background performance counter logging during a fio run inside a
    Windows VM. Mirrors bin/monitor.sh on the Linux host side.

.DESCRIPTION
    Spawns one typeperf process per counter group, sampling every 1 second
    into CSV files in $OutDir. PIDs are written to monitors.pid for the
    orchestrator (Run-Suite.ps1) to terminate. A MONITORS_SUMMARY.txt is
    produced so a future reader can see exactly which counters were captured.

    Two tiers, matching the Linux side:
      CRITICAL - disk + cpu counters; abort if typeperf is missing.
      OPTIONAL - extra signal that enriches analysis but is not load-bearing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$pidFile = Join-Path $OutDir 'monitors.pid'
$summary = Join-Path $OutDir 'MONITORS_SUMMARY.txt'
'' | Set-Content -LiteralPath $pidFile
@(
    "# Monitor.ps1 summary - $(Get-Date -Format o)"
    '# CRITICAL = required for the run; SKIPPED/FAILED here aborts the suite.'
    '# OPTIONAL = enriches analysis but the run proceeds without it.'
    ''
) | Set-Content -LiteralPath $summary

function Note($msg) {
    $ts = Get-Date -Format HH:mm:ss
    Add-Content -LiteralPath $summary -Value $msg
    Write-Host "[$ts] $msg"
}

# Confirm typeperf is on PATH
$typeperf = Get-Command typeperf.exe -ErrorAction SilentlyContinue
if (-not $typeperf) {
    Note 'FATAL    typeperf.exe not on PATH - cannot start any monitor'
    throw 'typeperf missing'
}

function Start-Counter($name, [string[]]$counters, [string]$kind = 'CRITICAL') {
    $csv = Join-Path $OutDir "$name.csv"
    $stdoutLog = Join-Path $OutDir "$name.stdout.log"
    $stderrLog = Join-Path $OutDir "$name.stderr.log"

    # Build a single quoted command line. -ArgumentList @() with PowerShell's
    # array form has known quoting bugs around counter strings containing parens
    # and slashes (e.g. '\PhysicalDisk(*)\Disk Reads/sec'). Building a single
    # pre-quoted string avoids that.
    $quotedCounters = $counters | ForEach-Object { '"' + $_ + '"' }
    $argLine = '-f CSV -o "{0}" -si 1 {1}' -f $csv, ($quotedCounters -join ' ')

    try {
        $proc = Start-Process -FilePath 'typeperf.exe' -ArgumentList $argLine -PassThru `
            -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
    } catch {
        Note "FAILED   [$kind] $name - Start-Process threw: $($_.Exception.Message)"
        Note "    | argline: $argLine"
        return
    }
    Start-Sleep -Milliseconds 1500
    if (-not $proc -or $proc.HasExited) {
        $exitCode = if ($proc) { $proc.ExitCode } else { 'n/a' }
        Note ("FAILED   [$kind] $name - process exited immediately (exit=$exitCode)")
        Note "    | argline: $argLine"
        if ((Test-Path $stdoutLog) -and (Get-Item $stdoutLog).Length -gt 0) {
            Note "    -- stdout (first 10 lines): --"
            Get-Content $stdoutLog -TotalCount 10 | ForEach-Object {
                Add-Content -LiteralPath $summary -Value "    | $_"
            }
        }
        if ((Test-Path $stderrLog) -and (Get-Item $stderrLog).Length -gt 0) {
            Note "    -- stderr (first 10 lines): --"
            Get-Content $stderrLog -TotalCount 10 | ForEach-Object {
                Add-Content -LiteralPath $summary -Value "    | $_"
            }
        }
        return
    }
    Add-Content -LiteralPath $pidFile -Value "$($proc.Id):$name"
    Note ("STARTED  [$kind] $name (pid=$($proc.Id)) -> $name.csv")
}

# --- CRITICAL ---------------------------------------------------------
Start-Counter 'physicaldisk' @(
    '\PhysicalDisk(*)\Disk Reads/sec'
    '\PhysicalDisk(*)\Disk Writes/sec'
    '\PhysicalDisk(*)\Disk Read Bytes/sec'
    '\PhysicalDisk(*)\Disk Write Bytes/sec'
    '\PhysicalDisk(*)\Avg. Disk sec/Read'
    '\PhysicalDisk(*)\Avg. Disk sec/Write'
    '\PhysicalDisk(*)\Current Disk Queue Length'
)

Start-Counter 'processor' @(
    '\Processor(*)\% Processor Time'
    '\Processor Information(*)\Processor Frequency'
)

Start-Counter 'system' @(
    '\System\Context Switches/sec'
    '\System\Processor Queue Length'
    '\System\System Calls/sec'
)

Start-Counter 'memory' @(
    '\Memory\Available Bytes'
    '\Memory\Cache Bytes'
    '\Memory\Pool Paged Bytes'
    '\Memory\Pool Nonpaged Bytes'
    '\Memory\Pages/sec'
    '\Memory\Page Faults/sec'
)

# --- OPTIONAL ---------------------------------------------------------
Start-Counter 'logicaldisk' @(
    '\LogicalDisk(*)\Disk Reads/sec'
    '\LogicalDisk(*)\Disk Writes/sec'
    '\LogicalDisk(*)\Free Megabytes'
    '\LogicalDisk(*)\% Free Space'
) 'OPTIONAL'

Note ''
Note "monitors running; pidfile=$pidFile"
