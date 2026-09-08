Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$VMName = 'Z-VM-WINDOWS'

function Section([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host $Title
    Write-Host ('=' * 78)
}

function KV([string]$Key, [object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { $Value = '<not found>' }
    Write-Host ('{0,-30}: {1}' -f $Key, $Value)
}

Write-Host 'vLLM Windows Native - Hyper-V lab attestation'
Write-Host ('Timestamp (UTC): ' + [DateTime]::UtcNow.ToString('o'))
Write-Host 'Mode: READ-ONLY. No VM configuration is changed.'

Section 'Host OS / identity'
KV 'Host computer' $env:COMPUTERNAME
KV 'User' ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    KV 'ProductName' $cv.ProductName
    KV 'DisplayVersion' $cv.DisplayVersion
    KV 'CurrentBuild' $cv.CurrentBuild
    KV 'UBR' $cv.UBR
}
catch {}

Section 'Host NVIDIA state'
$nvsmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nvsmi) { $nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($nvsmi) {
    KV 'nvidia-smi path' $nvsmi.Source
    & $nvsmi.Source --query-gpu=index,name,driver_version,pci.bus_id,memory.total,compute_cap --format=csv,noheader 2>&1 | ForEach-Object { Write-Host $_ }
} else {
    KV 'nvidia-smi' '<not found>'
}

try {
    Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Select-Object Status, FriendlyName, InstanceId |
        Format-Table -AutoSize | Out-String | Write-Host
}
catch {}

Section 'Partitionable GPUs exposed by Hyper-V'
try {
    $pgpus = @(Get-VMHostPartitionableGpu -ErrorAction Stop)
    KV 'Partitionable GPU count' $pgpus.Count
    foreach ($gpu in $pgpus) {
        Write-Host ''
        $gpu | Format-List * | Out-String | Write-Host
    }
}
catch {
    KV 'Get-VMHostPartitionableGpu' ('<failed: ' + $_.Exception.Message + '>')
}

Section 'VM core configuration'
try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $vm | Select-Object Name, State, Generation, Version, ProcessorCount, MemoryStartup, DynamicMemoryEnabled, AutomaticStartAction, AutomaticStopAction |
        Format-List | Out-String | Write-Host
} catch {
    Write-Host ('VM lookup failed: ' + $_.Exception.Message)
    exit 1
}

Section 'Existing VM GPU partition adapter'
try {
    $adapters = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)
    KV 'GPU partition adapter count' $adapters.Count
    foreach ($adapter in $adapters) {
        $adapter | Format-List * | Out-String | Write-Host
    }
}
catch {
    KV 'Get-VMGpuPartitionAdapter' ('<failed: ' + $_.Exception.Message + '>')
}

Section 'VM firmware / security'
try {
    Get-VMFirmware -VMName $VMName | Format-List * | Out-String | Write-Host
}
catch {}

Section 'VM disks'
try {
    Write-Host 'Hard disks:'
    Get-VMHardDiskDrive -VMName $VMName |
        Select-Object ControllerType, ControllerNumber, ControllerLocation, Path |
        Format-Table -AutoSize | Out-String | Write-Host
} catch {}

try {
    Write-Host 'DVD drives:'
    Get-VMDvdDrive -VMName $VMName |
        Select-Object ControllerNumber, ControllerLocation, Path |
        Format-Table -AutoSize | Out-String | Write-Host
} catch {}

Section 'Host volumes relevant to VM storage'
try {
    Get-Volume | Sort-Object DriveLetter |
        Select-Object DriveLetter, FileSystemLabel, FileSystem, DriveType, HealthStatus, SizeRemaining, Size |
        Format-Table -AutoSize | Out-String | Write-Host
} catch {}

Section 'VM network adapters'
try {
    Get-VMNetworkAdapter -VMName $VMName |
        Select-Object Name, SwitchName, Status, MacAddress, DynamicMacAddressEnabled, IPAddresses |
        Format-List | Out-String | Write-Host
} catch {}

Section 'Hyper-V host capability summary'
try {
    Get-VMHost | Select-Object LogicalProcessorCount, VirtualMachineMigrationEnabled, VirtualMachinePath, VirtualHardDiskPath |
        Format-List | Out-String | Write-Host
} catch {}

Section 'Attestation complete'
Write-Host 'No Hyper-V or VM configuration was modified.'
