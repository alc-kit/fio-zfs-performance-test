<#
.SYNOPSIS
    Snapshot the host state of a Windows Server VM that influences fio
    benchmark results. Mirrors bin/collect-env.sh on the Linux host side.

.PARAMETER OutDir
    Output directory. Each file written here describes one aspect of state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutDir
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Section($file, $title, $sb) {
    Add-Content -LiteralPath (Join-Path $OutDir $file) -Value "=== $title ==="
    & $sb 2>&1 | Out-String | Add-Content -LiteralPath (Join-Path $OutDir $file)
    Add-Content -LiteralPath (Join-Path $OutDir $file) -Value ''
}

# system.txt - host identity
Section 'system.txt' 'date' { Get-Date -Format o }
Section 'system.txt' 'hostname' { hostname }
Section 'system.txt' 'os version' { Get-CimInstance Win32_OperatingSystem | Format-List Caption,Version,BuildNumber,OSArchitecture,InstallDate,LastBootUpTime }
Section 'system.txt' 'computer info' { Get-ComputerInfo | Format-List CsName,CsManufacturer,CsModel,CsNumberOfProcessors,CsNumberOfLogicalProcessors,CsTotalPhysicalMemory,OsName,OsVersion,WindowsVersion,WindowsBuildLabEx }
Section 'system.txt' 'cpu' { Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores,NumberOfLogicalProcessors,CurrentClockSpeed,MaxClockSpeed }
Section 'system.txt' 'memory total' { Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum | ForEach-Object { '{0:N2} GiB' -f ($_.Sum / 1GB) } }
Section 'system.txt' 'BIOS / firmware' { Get-CimInstance Win32_BIOS | Format-List Manufacturer,Version,SMBIOSBIOSVersion,ReleaseDate }
Section 'system.txt' 'compute system (VM hint)' { Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer,Model,HypervisorPresent,DomainRole,TotalPhysicalMemory }

# storage.txt - disk + volume layout
Section 'storage.txt' 'physical disks' { Get-PhysicalDisk | Format-Table FriendlyName,SerialNumber,MediaType,BusType,Size,HealthStatus -AutoSize }
Section 'storage.txt' 'disks' { Get-Disk | Format-Table Number,FriendlyName,Size,PartitionStyle,OperationalStatus,HealthStatus -AutoSize }
Section 'storage.txt' 'partitions' { Get-Partition | Format-Table DiskNumber,PartitionNumber,DriveLetter,Size,Type -AutoSize }
Section 'storage.txt' 'volumes' { Get-Volume | Format-Table DriveLetter,FileSystemLabel,FileSystem,DriveType,SizeRemaining,Size -AutoSize }
Section 'storage.txt' 'NTFS allocation unit per volume' {
    Get-CimInstance Win32_Volume |
        Where-Object { $_.DriveLetter } |
        Select-Object DriveLetter,Label,FileSystem,@{n='AllocUnit';e={$_.BlockSize}},@{n='Capacity';e={'{0:N1}G' -f ($_.Capacity/1GB)}} |
        Format-Table -AutoSize
}
Section 'storage.txt' 'storage controllers' { Get-CimInstance Win32_SCSIController | Format-Table Name,Manufacturer,DriverName -AutoSize }

# fio.txt - fio version + engine availability
Section 'fio.txt' 'fio --version' { fio --version }
Section 'fio.txt' 'fio engines available' { fio --enghelp 2>&1 | Select-Object -First 60 }

# defender.txt - antivirus state (matters because RT-scan can dominate I/O latency)
Section 'defender.txt' 'Get-MpComputerStatus' { Get-MpComputerStatus | Format-List AMServiceEnabled,AntispywareEnabled,RealTimeProtectionEnabled,IoavProtectionEnabled,OnAccessProtectionEnabled,AntivirusSignatureLastUpdated }
Section 'defender.txt' 'Get-MpPreference exclusions' { Get-MpPreference | Select-Object -ExpandProperty ExclusionPath }
Section 'defender.txt' 'Get-MpPreference scan throttling' { Get-MpPreference | Format-List ScanAvgCPULoadFactor,DisableCpuThrottleOnIdleScans,EnableLowCpuPriority }

# power.txt - clock cap behaviour
Section 'power.txt' 'powercfg list' { powercfg /list }
Section 'power.txt' 'powercfg active scheme' { powercfg /getactivescheme }

# services.txt - anything that can interfere
Section 'services.txt' 'wuauserv (Windows Update)' { Get-Service wuauserv | Format-List Name,DisplayName,Status,StartType }
Section 'services.txt' 'WSearch (indexer)' { Get-Service WSearch -ErrorAction SilentlyContinue | Format-List Name,DisplayName,Status,StartType }
Section 'services.txt' 'SQL Server (info only)' { Get-Service MSSQL* -ErrorAction SilentlyContinue | Format-Table Name,Status,StartType -AutoSize }

# tool-availability.txt - what could and could not be measured at run time
$toolFile = Join-Path $OutDir 'tool-availability.txt'
'# Required: Run-Suite.ps1 aborts if any of these is missing.' |
    Set-Content -LiteralPath $toolFile
'fio.exe','typeperf.exe','powershell.exe','powercfg.exe','fsutil.exe' | ForEach-Object {
    $cmd = Get-Command $_ -ErrorAction SilentlyContinue
    if ($cmd) { "  REQUIRED  OK       $_ -> $($cmd.Source)" } else { "  REQUIRED  MISSING  $_" }
} | Add-Content -LiteralPath $toolFile
'','# Optional: enriches analysis but the run proceeds without these.' |
    Add-Content -LiteralPath $toolFile
'logman.exe','wpr.exe','perfmon.exe' | ForEach-Object {
    $cmd = Get-Command $_ -ErrorAction SilentlyContinue
    if ($cmd) { "  OPTIONAL  OK       $_ -> $($cmd.Source)" } else { "  OPTIONAL  MISSING  $_" }
} | Add-Content -LiteralPath $toolFile

Write-Host "[$(Get-Date -Format HH:mm:ss)] env snapshot: $OutDir"
