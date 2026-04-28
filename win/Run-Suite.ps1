<#
.SYNOPSIS
    Run a Windows-side fio test suite (or single .fio file) inside a
    Proxmox Windows VM. PowerShell counterpart of bin/run-suite.sh.

.DESCRIPTION
    Mirrors the Linux orchestrator: per-job timestamped result directory,
    env snapshot via Collect-Env.ps1, background performance counters via
    Monitor.ps1, fio invocation with json+normal output split into a clean
    fio.json + a human fio.summary.txt + an fio.log of stdout/stderr.

    The same design rule used on the host applies: do not introduce
    Windows tunings beyond what a stock SQL Server install would itself
    apply. Power plan, NTFS last-access-time and Defender exclusions
    were already set by Prepare-TestVolume.ps1; we do not touch anything
    further at run time.

.PARAMETER Path
    Either a directory under win/jobs/ (suite name) or a path to one .fio file.

.PARAMETER All
    Run every suite under win/jobs/.

.PARAMETER ResultsDir
    Output root. Defaults to <repo>/results/win.
#>
[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(ParameterSetName='Path', Position=0)][string]$Path,
    [Parameter(ParameterSetName='All')][switch]$All,
    [string]$ResultsDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $scriptDir
if (-not $ResultsDir) { $ResultsDir = Join-Path $repoRoot 'results\win' }

# Defaults — overridable via environment so a single run can be retargeted
if (-not $env:FIO_IOENGINE) { $env:FIO_IOENGINE = 'windowsaio' }
if (-not $env:FIO_RUNTIME)  { $env:FIO_RUNTIME  = '120' }
if (-not $env:FIO_RAMP_TIME){ $env:FIO_RAMP_TIME = '10' }
if (-not $env:FIO_NUMJOBS)  { $env:FIO_NUMJOBS  = '8' }
if (-not $env:FIO_IODEPTH)  { $env:FIO_IODEPTH  = '32' }
if (-not $env:FIO_SIZE)     { $env:FIO_SIZE     = '50G' }   # smaller default than Linux side; per-disk caps in VM

function Log($msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" }
function Die($msg) { Write-Error $msg; exit 1 }

if (-not (Get-Command fio.exe -ErrorAction SilentlyContinue)) {
    Die 'fio.exe not on PATH'
}

# Validate test volumes are prepared
foreach ($d in 'F','G','H') {
    if (-not (Get-Volume -DriveLetter $d -ErrorAction SilentlyContinue)) {
        Die "Volume ${d}: not present. Run Prepare-TestVolume.ps1 first."
    }
}

function Stop-Monitors($pidFile) {
    if (-not (Test-Path $pidFile)) { return }
    Get-Content $pidFile | ForEach-Object {
        if ($_ -match '^(\d+):') {
            $procId = [int]$matches[1]
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
    }
    Log 'monitors stopped'
}

function Split-FioOut($outFile, $jsonFile, $txtFile) {
    if (-not (Test-Path $outFile)) { return }
    $buf = Get-Content -Raw -LiteralPath $outFile
    # Find first '{' at the start of a line (json+ output begins this way)
    $lines = $buf -split "`r?`n"
    $startLine = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('{')) { $startLine = $i; break }
    }
    if ($startLine -lt 0) {
        Set-Content -LiteralPath $txtFile -Value $buf
        Set-Content -LiteralPath $jsonFile -Value ''
        return
    }
    # Compute character offset of start of that line in $buf
    $start = 0
    for ($i=0; $i -lt $startLine; $i++) {
        $start += $lines[$i].Length + 2   # +2 covers the CRLF (close enough; both halves are text)
    }
    # Brace counting from $start
    $depth = 0; $end = -1
    for ($i = $start; $i -lt $buf.Length; $i++) {
        $c = $buf[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { $end = $i + 1; break }
        }
    }
    if ($end -lt 0) {
        Log 'warn: unbalanced JSON braces in fio.out — saving raw output only'
        Set-Content -LiteralPath $txtFile -Value $buf
        return
    }
    # Extract using Substring on the original buffer (more accurate than line math
    # for the JSON portion). We re-locate $start by searching for the opening '{'.
    $openIdx = $buf.IndexOf('{')
    while ($openIdx -ge 0 -and $openIdx -lt $buf.Length) {
        if ($openIdx -eq 0 -or $buf[$openIdx-1] -eq "`n") { break }
        $openIdx = $buf.IndexOf('{', $openIdx + 1)
    }
    if ($openIdx -lt 0) { return }
    $depth = 0; $jsonEnd = -1
    for ($i = $openIdx; $i -lt $buf.Length; $i++) {
        $c = $buf[$i]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { $jsonEnd = $i + 1; break }
        }
    }
    if ($jsonEnd -lt 0) { return }
    Set-Content -LiteralPath $txtFile -Value ($buf.Substring(0, $openIdx).TrimEnd())
    Set-Content -LiteralPath $jsonFile -Value $buf.Substring($openIdx, $jsonEnd - $openIdx)
}

function Run-OneJob($job, $suite) {
    $jobName = [IO.Path]::GetFileNameWithoutExtension($job)
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $ResultsDir "$ts-$suite-$jobName"
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    Log '=============================================================='
    Log "job    : $job"
    Log "suite  : $suite"
    Log "output : $out"
    Log "engine : $env:FIO_IOENGINE  runtime=$env:FIO_RUNTIME  size=$env:FIO_SIZE"
    Log '=============================================================='

    & (Join-Path $scriptDir 'Collect-Env.ps1') -OutDir (Join-Path $out 'env')

    $monDir = Join-Path $out 'monitor'
    & (Join-Path $scriptDir 'Monitor.ps1') -OutDir $monDir
    $pidFile = Join-Path $monDir 'monitors.pid'

    # Volume free-space snapshot before/after
    $volSnap = { Get-Volume -DriveLetter F,G,H | Format-Table DriveLetter,FileSystemLabel,SizeRemaining,Size -AutoSize | Out-String }
    & $volSnap | Set-Content -LiteralPath (Join-Path $out 'volumes-before.txt')

    # Build effective.fio: global prelude + selected job
    $effective = Join-Path $out 'effective.fio'
    $globalFio = Join-Path $scriptDir 'jobs\_global-win.fio'
    Get-Content -LiteralPath $globalFio  | Set-Content -LiteralPath $effective
    Add-Content -LiteralPath $effective -Value ''
    Get-Content -LiteralPath $job        | Add-Content -LiteralPath $effective

    Push-Location $out
    try {
        $fioOut = Join-Path $out 'fio.out'
        $fioLog = Join-Path $out 'fio.log'
        $rc = 0
        & fio.exe `
            --output-format=json+,normal `
            --output=$fioOut `
            --eta=always --eta-newline=10 `
            $effective *> $fioLog
        $rc = $LASTEXITCODE
        Split-FioOut -outFile $fioOut -jsonFile (Join-Path $out 'fio.json') -txtFile (Join-Path $out 'fio.summary.txt')
        if ($rc -ne 0) { Log "FIO EXIT $rc — see $fioLog" } else { Log "done: $out" }
    } finally {
        Pop-Location
        Stop-Monitors $pidFile
        & $volSnap | Set-Content -LiteralPath (Join-Path $out 'volumes-after.txt')
    }
    return $rc
}

function Collect-Jobs($arg) {
    if (Test-Path $arg -PathType Leaf) { return ,(Resolve-Path $arg).Path }
    $candidate = Join-Path (Join-Path $scriptDir 'jobs') $arg
    if (Test-Path $candidate -PathType Container) {
        return Get-ChildItem -LiteralPath $candidate -Filter '*.fio' | Sort-Object Name | ForEach-Object { $_.FullName }
    }
    Die "no such suite or file: $arg"
}

$overallRc = 0
if ($All) {
    Get-ChildItem (Join-Path $scriptDir 'jobs') -Directory | ForEach-Object {
        $suite = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Filter '*.fio' | Sort-Object Name | ForEach-Object {
            $rc = Run-OneJob $_.FullName $suite
            if ($rc -ne 0) { $overallRc = $rc }
        }
    }
} elseif ($Path) {
    if (Test-Path $Path -PathType Leaf) {
        $suite = Split-Path -Leaf (Split-Path -Parent (Resolve-Path $Path))
        $rc = Run-OneJob (Resolve-Path $Path).Path $suite
        if ($rc -ne 0) { $overallRc = $rc }
    } else {
        foreach ($job in (Collect-Jobs $Path)) {
            $rc = Run-OneJob $job $Path
            if ($rc -ne 0) { $overallRc = $rc }
        }
    }
} else {
    Die 'usage: Run-Suite.ps1 <suite|path-to-job.fio>  |  Run-Suite.ps1 -All'
}

exit $overallRc
