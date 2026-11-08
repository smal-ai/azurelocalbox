# Observe only the exact prior image inspection and its two known ISO attachments.
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ne 'LocalBox-Client') { throw 'Unexpected target' }
$encoded = '__GUEST_INSPECTION_ENCODED__'
if (-not $encoded -or $encoded -like '__*') { throw 'Exact inspection selector missing' }
$rows = @(Get-CimInstance Win32_Process -Filter ("Name='powershell.exe' AND CommandLine LIKE '%" + $encoded + "%'") | Select-Object ProcessId, ParentProcessId, CreationDate)
$paths = @('C:\ProgramData\AzureLocalBox\Artifacts\2610\AzureLocal24H2.26100.32230.LCM.12.2610.0.3098.x64.en-us.iso', 'C:\ProgramData\AzureLocalBox\Bootstrap\eval-media-20261028-01\WindowsServer2025Evaluation.26100.32230.x64.en-us.iso')
$media = @($paths | ForEach-Object { $image = Get-DiskImage -ImagePath $_; @{ path = $_; attached = $image.Attached; volumes = $(if ($image.Attached) { @($image | Get-Volume | Select-Object DriveLetter, FileSystemLabel) } else { @() }) } })
@{ atUtc = (Get-Date).ToUniversalTime().ToString('o'); exactInspectionProcesses = $rows; dismProcesses = @(Get-Process -Name dism,dismhost -ErrorAction SilentlyContinue | Select-Object Id, CPU, StartTime); media = $media; stoppedProcesses = $false; dismountedImages = $false; clusterBootstrapComplete = $false } | ConvertTo-Json -Depth 6 -Compress
