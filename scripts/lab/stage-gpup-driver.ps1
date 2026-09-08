[CmdletBinding()]
param(
    [string]$VMName = 'Z-VM-WINDOWS',
    [string]$DriverRepositoryDirectory = 'nvmdsi.inf_amd64_0e1506ba4a3e59af'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===')
}

function Assert-File {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Copy-MappedFile {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SourceRelativePath,
        [Parameter(Mandatory)][string]$DestinationDirectory,
        [Parameter(Mandatory)][string]$DestinationName
    )

    $source = Join-Path $SourceRoot $SourceRelativePath
    Assert-File $source

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    $destination = Join-Path $DestinationDirectory $DestinationName
    Copy-Item -LiteralPath $source -Destination $destination -Force

    $srcHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) {
        throw "SHA256 mismatch after copy: $SourceRelativePath -> $destination"
    }

    Write-Host ("OK  {0} -> {1}" -f $SourceRelativePath, $destination)
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Off') {
    throw "VM '$VMName' must be Off. Current state: $($vm.State)"
}

$gpuAdapter = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop)
if ($gpuAdapter.Count -ne 1) {
    throw "Expected exactly one GPU partition adapter on '$VMName'; found $($gpuAdapter.Count)."
}

$sourceRepo = Join-Path "$env:windir\System32\DriverStore\FileRepository" $DriverRepositoryDirectory
if (-not (Test-Path -LiteralPath $sourceRepo -PathType Container)) {
    throw "NVIDIA DriverStore repository not found: $sourceRepo"
}

$nvlddmkm = Join-Path $sourceRepo 'nvlddmkm.sys'
Assert-File $nvlddmkm
$driverVersion = (Get-Item -LiteralPath $nvlddmkm).VersionInfo.FileVersion
Write-Host "Source NVIDIA repository: $sourceRepo"
Write-Host "nvlddmkm.sys version:    $driverVersion"

# Exact mappings observed from NVIDIA 616.56 nvmdsi.inf / adapter registry.
$system32Mappings = @(
    @{ Source = 'nvcudadebugger.dll'; Destination = 'nvcudadebugger.dll' },
    @{ Source = 'nvcuda_loader64.dll'; Destination = 'nvcuda.dll' },
    @{ Source = 'nvcuvid64.dll';       Destination = 'nvcuvid.dll' },
    @{ Source = 'nvEncodeAPI64.dll';   Destination = 'nvEncodeAPI64.dll' },
    @{ Source = 'nvapi64.dll';         Destination = 'nvapi64.dll' },
    @{ Source = 'nvml_loader.dll';     Destination = 'nvml.dll' },
    @{ Source = 'OpenCL64.dll';        Destination = 'OpenCL.dll' },
    @{ Source = 'vulkan-1-x64.dll';    Destination = 'vulkan-1.dll' }
)

$syswow64Mappings = @(
    @{ Source = 'nvcuda_loader32.dll'; Destination = 'nvcuda.dll' },
    @{ Source = 'nvcuvid32.dll';       Destination = 'nvcuvid.dll' },
    @{ Source = 'nvEncodeAPI.dll';     Destination = 'nvEncodeAPI.dll' },
    @{ Source = 'nvapi.dll';           Destination = 'nvapi.dll' },
    @{ Source = 'OpenCL32.dll';        Destination = 'OpenCL.dll' },
    @{ Source = 'vulkan-1-x86.dll';    Destination = 'vulkan-1.dll' }
)

# nvidia-smi is not a CopyToVm registry entry, but NVIDIA installs it to System32
# and it is useful for validating NVML/CUDA visibility in the guest.
Assert-File (Join-Path $sourceRepo 'nvidia-smi.exe')

$vmDisks = @(Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -and $_.Path -match '\.vhdx?$' })
if ($vmDisks.Count -ne 1) {
    throw "Expected exactly one VHD/VHDX attached to '$VMName'; found $($vmDisks.Count)."
}

$vhdPath = $vmDisks[0].Path
Write-Host "Guest VHDX:             $vhdPath"

$mounted = $false
$temporaryAccessPath = $null
$diskNumber = $null

try {
    Write-Step 'Mount guest VHDX'
    $vhd = Mount-VHD -Path $vhdPath -Passthru
    $mounted = $true

    $diskNumber = $vhd.DiskNumber
    if ($null -eq $diskNumber) {
        $diskNumber = (Get-DiskImage -ImagePath $vhdPath | Get-Disk).Number
    }

    $partitions = @(Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB } | Sort-Object Size -Descending)
    if ($partitions.Count -lt 1) {
        throw "Could not identify a Basic OS partition on mounted disk $diskNumber."
    }

    $osPartition = $partitions[0]

    if ($osPartition.DriveLetter) {
        $guestRoot = "$($osPartition.DriveLetter):\"
    }
    else {
        $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })
        $candidate = ('Z','Y','X','W','V','U','T') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $candidate) {
            throw 'No free temporary drive letter available for mounted guest OS partition.'
        }

        $temporaryAccessPath = "$candidate`:\"
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $osPartition.PartitionNumber -AccessPath $temporaryAccessPath
        $guestRoot = $temporaryAccessPath
    }

    $guestSystemHive = Join-Path $guestRoot 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path -LiteralPath $guestSystemHive -PathType Leaf)) {
        throw "Selected partition does not look like a Windows OS volume: $guestRoot"
    }

    Write-Host "Guest Windows root:     $guestRoot"

    Write-Step 'Stage NVIDIA DriverStore payload into HostDriverStore'
    $guestHostDriverStore = Join-Path $guestRoot 'Windows\System32\HostDriverStore\FileRepository'
    $guestRepo = Join-Path $guestHostDriverStore $DriverRepositoryDirectory
    New-Item -ItemType Directory -Path $guestRepo -Force | Out-Null

    & robocopy.exe $sourceRepo $guestRepo /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -gt 7) {
        throw "Robocopy failed with exit code $robocopyExit."
    }
    Write-Host "OK  repository copied (robocopy exit $robocopyExit)"

    $sourceFileCount = @(Get-ChildItem -LiteralPath $sourceRepo -File -Recurse).Count
    $guestFileCount  = @(Get-ChildItem -LiteralPath $guestRepo -File -Recurse).Count
    Write-Host "Source file count: $sourceFileCount"
    Write-Host "Guest file count:  $guestFileCount"
    if ($sourceFileCount -ne $guestFileCount) {
        throw "File count mismatch after repository copy."
    }

    Write-Step 'Apply CopyToVmWhenNewer mappings to guest System32'
    $guestSystem32 = Join-Path $guestRoot 'Windows\System32'
    foreach ($mapping in $system32Mappings) {
        Copy-MappedFile -SourceRoot $sourceRepo -SourceRelativePath $mapping.Source -DestinationDirectory $guestSystem32 -DestinationName $mapping.Destination
    }

    Write-Step 'Apply CopyToVmWhenNewerWow64 mappings to guest SysWOW64'
    $guestSysWOW64 = Join-Path $guestRoot 'Windows\SysWOW64'
    foreach ($mapping in $syswow64Mappings) {
        Copy-MappedFile -SourceRoot $sourceRepo -SourceRelativePath $mapping.Source -DestinationDirectory $guestSysWOW64 -DestinationName $mapping.Destination
    }

    Write-Step 'Stage nvidia-smi diagnostic executable'
    Copy-MappedFile -SourceRoot $sourceRepo -SourceRelativePath 'nvidia-smi.exe' -DestinationDirectory $guestSystem32 -DestinationName 'nvidia-smi.exe'

    Write-Step 'Verify staged files'
    $verify = @(
        (Join-Path $guestRepo 'nvlddmkm.sys'),
        (Join-Path $guestRepo 'nvcuda64.dll'),
        (Join-Path $guestRepo 'nvml.dll'),
        (Join-Path $guestSystem32 'nvcuda.dll'),
        (Join-Path $guestSystem32 'nvml.dll'),
        (Join-Path $guestSystem32 'nvidia-smi.exe'),
        (Join-Path $guestSysWOW64 'nvcuda.dll')
    )
    foreach ($path in $verify) {
        Assert-File $path
        Write-Host "OK  $path"
    }

    Write-Host ''
    Write-Host 'GPU-P driver staging completed successfully.'
}
finally {
    if ($temporaryAccessPath -and $null -ne $diskNumber) {
        try {
            $part = Get-Partition -DiskNumber $diskNumber | Where-Object { $_.AccessPaths -contains $temporaryAccessPath } | Select-Object -First 1
            if ($part) {
                Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber -AccessPath $temporaryAccessPath -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    if ($mounted) {
        Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    }
}
