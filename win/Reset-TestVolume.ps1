<#
.SYNOPSIS
    Revert the host-level adjustments made by Prepare-TestVolume.ps1.
    Does NOT delete the NTFS test volumes or their data — call cleanup
    manually if you also want the volumes gone.

.DESCRIPTION
    Reads C:\fio-test\saved-state.json and restores the original
    power plan, NTFS last-access setting, Defender exclusions, and
    Windows Update service state.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$stateFile = 'C:\fio-test\saved-state.json'
if (-not (Test-Path $stateFile)) {
    throw "No saved state at $stateFile. Nothing to revert."
}

function Step($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }

$saved = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json

Step 'Restore power plan'
# Saved string is e.g. "Power Scheme GUID: 8c5e7fda-... (High performance) *"
$guidMatch = [regex]::Match($saved.powerScheme, '([0-9a-f-]{36})')
if ($guidMatch.Success) { powercfg /setactive $guidMatch.Value }

Step 'Restore NTFS DisableLastAccess'
# Saved string is e.g. "DisableLastAccess = 1 (...)"
if ($saved.disableLastAccess -match '=\s*([012])\b') {
    fsutil behavior set DisableLastAccess $matches[1] | Out-Null
}

Step 'Reconcile Defender exclusions to original list'
$current = @(Get-MpPreference | Select-Object -ExpandProperty ExclusionPath)
$original = @($saved.defenderExclusionsBefore)
$toRemove = $current | Where-Object { $_ -notin $original }
foreach ($p in $toRemove) {
    Step "  removing exclusion $p"
    Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
}

Step 'Restore Windows Update service'
$wuStart = $saved.windowsUpdateService.StartType
$wuStatus = $saved.windowsUpdateService.Status
if ($wuStart) { Set-Service wuauserv -StartupType $wuStart }
if ($wuStatus -eq 'Running') { Start-Service wuauserv -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Host adjustments reverted.' -ForegroundColor Green
Write-Host 'Test volumes E:, F:, G: were left in place. Delete them manually if no longer needed.'
