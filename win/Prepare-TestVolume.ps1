<#
.SYNOPSIS
    Prepare three NTFS test volumes inside a Proxmox Windows VM, matching
    SQL Server best-practice layout for data / log / tempdb on dedicated
    spindles.

.DESCRIPTION
    Idempotent. Operates only on raw (un-partitioned) data disks no larger
    than $MaxDiskGiB so the OS disk and any existing partitioned disks are
    never touched. Picks the first three matching disks by Disk Number and
    formats them as NTFS with 64 KiB allocation unit (Microsoft's documented
    SQL Server best practice), assigning drive letters E:, F:, G:.

    Also applies four host-level adjustments that real production SQL Server
    installs always apply:
      1. High-performance power plan (clocks won't drop under load).
      2. Disable NTFS last-access-time (avoids a write per read).
      3. Add Windows Defender real-time exclusions for the three test paths
         (every SQL Server install guide tells you to exclude data/log/tempdb
         paths from AV scanning).
      4. Suspend automatic Windows Update checks during testing.

    The original state of all four adjustments is captured to
    C:\fio-test\saved-state.json so Reset-TestVolume.ps1 (or a manual revert)
    can restore the host afterwards.

.PARAMETER MaxDiskGiB
    Only candidate disks at or below this size are considered. Defaults to
    150 GiB so the 100 GiB virtio-SCSI test disks qualify but the 200 GiB
    OS disk never does.

.PARAMETER Force
    Skip the safety prompt before formatting.
#>
[CmdletBinding()]
param(
    [int]$MaxDiskGiB = 150,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step($msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" -ForegroundColor Cyan }
function Write-Skip($msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] (skip) $msg" -ForegroundColor DarkGray }

# --- 0. Sanity checks ---------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) {
    throw 'Must be run as Administrator.'
}

# --- 1. Identify candidate disks ---------------------------------------
$maxBytes = $MaxDiskGiB * 1GB
$candidates = Get-Disk |
    Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Size -le $maxBytes } |
    Sort-Object Number

if ($candidates.Count -lt 3) {
    Write-Warning 'Found fewer than 3 RAW data disks. Already-prepared disks are skipped automatically.'
    Write-Host 'Existing disks:'
    Get-Disk | Format-Table Number,FriendlyName,Size,PartitionStyle -AutoSize
}

# Map roles to drive letters in SQL Server convention
$layout = @(
    @{ Role='data';   Drive='E'; Label='SQL-Data'  }
    @{ Role='log';    Drive='F'; Label='SQL-Log'   }
    @{ Role='tempdb'; Drive='G'; Label='SQL-Tempdb' }
)

# --- 2. Capture original state for later revert ------------------------
$stateDir = 'C:\fio-test'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$stateFile = Join-Path $stateDir 'saved-state.json'

if (-not (Test-Path $stateFile)) {
    Write-Step "Capturing original host state -> $stateFile"
    $orig = [ordered]@{
        timestamp = (Get-Date -Format o)
        powerScheme = (powercfg /getactivescheme | Out-String).Trim()
        disableLastAccess = (fsutil behavior query DisableLastAccess | Out-String).Trim()
        defenderExclusionsBefore = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath)
        windowsUpdateService = (Get-Service wuauserv | Select-Object Name,StartType,Status)
    }
    $orig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
} else {
    Write-Skip "$stateFile already exists; preserving original captured state."
}

# --- 3. Prepare each volume --------------------------------------------
$assigned = 0
foreach ($entry in $layout) {
    $drive = $entry.Drive
    $rolePath = "${drive}:\fio-test"

    $existingVol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
    if ($existingVol -and $existingVol.FileSystem -eq 'NTFS') {
        Write-Skip "${drive}: already exists as NTFS volume ($($existingVol.FileSystemLabel))"
        New-Item -ItemType Directory -Force -Path $rolePath | Out-Null
        $assigned++
        continue
    }

    if ($candidates.Count -eq 0) {
        throw "No remaining RAW disks to assign to role '$($entry.Role)' (${drive}:)"
    }
    $disk = $candidates[0]
    $candidates = $candidates | Select-Object -Skip 1

    if (-not $Force) {
        $answer = Read-Host "Format disk #$($disk.Number) ($($disk.Size/1GB) GiB) as NTFS, assign ${drive}: for role '$($entry.Role)'? [y/N]"
        if ($answer -notmatch '^[Yy]$') { throw "Aborted by user at disk $($disk.Number)" }
    }

    Write-Step "Initialize disk $($disk.Number) (GPT)"
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null

    Write-Step "Create partition + assign ${drive}:"
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $drive | Out-Null

    Write-Step "Format ${drive}: as NTFS, 64 KiB allocation unit, label '$($entry.Label)'"
    Format-Volume -DriveLetter $drive -FileSystem NTFS `
        -AllocationUnitSize 65536 -NewFileSystemLabel $entry.Label `
        -Confirm:$false -Force | Out-Null

    New-Item -ItemType Directory -Force -Path $rolePath | Out-Null
    $assigned++
}

if ($assigned -lt 3) {
    throw "Only $assigned of 3 required volumes are present. Cannot proceed."
}

# --- 4. Host-level adjustments ----------------------------------------
Write-Step 'Activate High Performance power plan'
# 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c is the well-known GUID for High performance
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

Write-Step 'Disable NTFS last-access-time updates'
fsutil behavior set DisableLastAccess 1 | Out-Null

Write-Step 'Add Defender real-time exclusions for the three test paths'
foreach ($entry in $layout) {
    $p = "$($entry.Drive):\fio-test"
    Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
}

Write-Step 'Suspend Windows Update service for the duration of testing'
try { Stop-Service wuauserv -Force -ErrorAction Stop } catch { Write-Warning "Could not stop wuauserv: $_" }
try { Set-Service wuauserv -StartupType Disabled -ErrorAction Stop } catch { Write-Warning "Could not disable wuauserv startup: $_" }

# --- 5. Summary --------------------------------------------------------
Write-Host ''
Write-Host '=== Volumes ready ===' -ForegroundColor Green
Get-Volume -DriveLetter E,F,G -ErrorAction SilentlyContinue |
    Format-Table DriveLetter,FileSystem,FileSystemLabel,@{n='AllocUnit';e={(Get-CimInstance Win32_Volume -Filter "DriveLetter='$($_.DriveLetter):'").BlockSize}},Size,SizeRemaining -AutoSize

Write-Host '=== Saved state ===' -ForegroundColor Green
Write-Host "  $stateFile (use Reset-TestVolume.ps1 to revert host adjustments)"

Write-Host ''
Write-Host 'Ready: E:\fio-test (data), F:\fio-test (log), G:\fio-test (tempdb)' -ForegroundColor Green
