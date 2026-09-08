[CmdletBinding()]
param(
    [string]$VMName = 'Z-VM-WINDOWS',
    [string]$DriverRepositoryDirectory = 'nvmdsi.inf_amd64_0e1506ba4a3e59af'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Step([string]$Text) {
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===')
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Get-FileVersionSafe([string]$Path) {
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    [version]::new(
        [math]::Max(0,$v.FileMajorPart),
        [math]::Max(0,$v.FileMinorPart),
        [math]::Max(0,$v.FileBuildPart),
        [math]::Max(0,$v.FilePrivatePart)
    )
}

function Test-SourceNewer([string]$Source,[string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { return $true }

    $ext = [IO.Path]::GetExtension($Destination).ToLowerInvariant()
    if ($ext -in @('.dll','.exe')) {
        $sv = Get-FileVersionSafe $Source
        $dv = Get-FileVersionSafe $Destination
        if ($sv -gt $dv) { return $true }
        if ($sv -lt $dv) { return $false }
    }

    (Get-Item -LiteralPath $Source).LastWriteTimeUtc -gt
        (Get-Item -LiteralPath $Destination).LastWriteTimeUtc
}

function Backup-File([string]$Path,[string]$BackupDirectory) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    $backup = Join-Path $BackupDirectory (Split-Path -Leaf $Path)
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Host "BACKUP $Path -> $backup"
}

function Copy-WhenNewer(
    [string]$Source,
    [string]$Destination,
    [string]$BackupDirectory
) {
    Assert-File $Source
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null

    if (-not (Test-SourceNewer $Source $Destination)) {
        Write-Host "SKIP   $Source -> $Destination (destination same/newer)"
        return
    }

    Backup-File $Destination $BackupDirectory
    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    if ((Get-FileHash $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash $Destination -Algorithm SHA256).Hash) {
        throw "SHA256 mismatch after copy: $Source -> $Destination"
    }
    Write-Host "OK     $Source -> $Destination"
}

function Copy-Exact(
    [string]$Source,
    [string]$Destination,
    [string]$BackupDirectory
) {
    Assert-File $Source
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Backup-File $Destination $BackupDirectory
    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    if ((Get-FileHash $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash $Destination -Algorithm SHA256).Hash) {
        throw "SHA256 mismatch after copy: $Source -> $Destination"
    }
    Write-Host "OK     $Source -> $Destination"
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne 'Off') {
    throw "VM '$VMName' must be Off. Current state: $($vm.State)"
}

$gpuAdapters = @(Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop)
if ($gpuAdapters.Count -ne 1) {
    throw "Expected exactly one GPU partition adapter; found $($gpuAdapters.Count)."
}

$sourceRepo = Join-Path "$env:windir\System32\DriverStore\FileRepository" $DriverRepositoryDirectory
if (-not (Test-Path -LiteralPath $sourceRepo -PathType Container)) {
    throw "NVIDIA repository not found: $sourceRepo"
}
Assert-File (Join-Path $sourceRepo 'nvlddmkm.sys')
Assert-File (Join-Path $sourceRepo 'nvidia-smi.exe')

Write-Host "Source NVIDIA repository: $sourceRepo"
Write-Host ('nvlddmkm.sys version:    ' + (Get-Item (Join-Path $sourceRepo 'nvlddmkm.sys')).VersionInfo.FileVersion)

$allowedExtensions = @('.vhd','.vhdx','.avhd','.avhdx')
$allVmDisks = @(Get-VMHardDiskDrive -VMName $VMName)
$vmDisks = @($allVmDisks | Where-Object {
    $_.Path -and ([IO.Path]::GetExtension([string]$_.Path).ToLowerInvariant() -in $allowedExtensions)
})

if ($vmDisks.Count -ne 1) {
    Write-Host 'Attached VM hard disks:'
    $allVmDisks | Select-Object ControllerType,ControllerNumber,ControllerLocation,Path |
        Format-Table -AutoSize | Out-String | Write-Host
    throw "Expected exactly one VHD/VHDX/AVHDX attached to '$VMName'; found $($vmDisks.Count)."
}

$vhdPath = [string]$vmDisks[0].Path
Write-Host "Attached guest disk:      $vhdPath"

Step 'Checkpoint inventory'
$snapshots = @(Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue)
if ($snapshots.Count -eq 0) {
    Write-Host 'No Hyper-V checkpoints reported.'
} else {
    $snapshots | Select-Object Name,SnapshotType,CreationTime,Id |
        Format-Table -AutoSize | Out-String | Write-Host
}

Step 'Validate VHD differencing chain'
$chain = @()
$cursor = $vhdPath
$seen = @{}
while ($cursor) {
    if ($seen.ContainsKey($cursor)) { throw "Loop detected in VHD parent chain at: $cursor" }
    $seen[$cursor] = $true

    if (-not (Test-Path -LiteralPath $cursor -PathType Leaf)) {
        throw "VHD chain member missing: $cursor"
    }

    $info = Get-VHD -Path $cursor -ErrorAction Stop
    $chain += $info
    Write-Host ("{0} | Type={1} | Parent={2}" -f $info.Path,$info.VhdType,$info.ParentPath)
    $cursor = if ($info.ParentPath) { [string]$info.ParentPath } else { $null }
}

if ($chain.Count -gt 1) {
    Write-Host 'Using the attached leaf differencing disk. Writes will land in the current checkpoint layer; parent disks remain unchanged.'
}

$system32Mappings = @(
    @('nvcudadebugger.dll','nvcudadebugger.dll'),
    @('nvcuda_loader64.dll','nvcuda.dll'),
    @('nvcuvid64.dll','nvcuvid.dll'),
    @('nvEncodeAPI64.dll','nvEncodeAPI64.dll'),
    @('nvapi64.dll','nvapi64.dll'),
    @('nvml_loader.dll','nvml.dll'),
    @('OpenCL64.dll','OpenCL.dll'),
    @('vulkan-1-x64.dll','vulkan-1.dll')
)
$wow64Mappings = @(
    @('nvcuda_loader32.dll','nvcuda.dll'),
    @('nvcuvid32.dll','nvcuvid.dll'),
    @('nvEncodeAPI.dll','nvEncodeAPI.dll'),
    @('nvapi.dll','nvapi.dll'),
    @('OpenCL32.dll','OpenCL.dll'),
    @('vulkan-1-x86.dll','vulkan-1.dll')
)

$mounted = $false
$diskNumber = $null
$tempAccessPath = $null

try {
    Step 'Mount attached guest disk'
    $mountedVhd = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true

    $diskNumber = $mountedVhd.DiskNumber
    if ($null -eq $diskNumber) {
        $diskNumber = (Get-DiskImage -ImagePath $vhdPath | Get-Disk).Number
    }
    Write-Host "Mounted disk number: $diskNumber"

    $parts = @(Get-Partition -DiskNumber $diskNumber |
        Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 10GB } |
        Sort-Object Size -Descending)
    if ($parts.Count -lt 1) { throw "No likely Windows OS partition found on disk $diskNumber." }
    $osPart = $parts[0]

    if ($osPart.DriveLetter) {
        $guestRoot = "$($osPart.DriveLetter):\"
    } else {
        $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })
        $letter = @('Z','Y','X','W','V','U','T') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $letter) { throw 'No free temporary drive letter available.' }
        $tempAccessPath = "$letter`:\"
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $osPart.PartitionNumber -AccessPath $tempAccessPath
        $guestRoot = $tempAccessPath
    }

    if (-not (Test-Path -LiteralPath (Join-Path $guestRoot 'Windows\System32\config\SYSTEM') -PathType Leaf)) {
        throw "Selected partition is not a Windows OS volume: $guestRoot"
    }
    Write-Host "Guest Windows root: $guestRoot"

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $guestRoot "ProgramData\vllm-windows-native\gpup-driver-backup\$stamp"
    $backupSystem32 = Join-Path $backupRoot 'System32'
    $backupWow64 = Join-Path $backupRoot 'SysWOW64'

    Step 'Stage full NVIDIA repository into HostDriverStore'
    $guestRepo = Join-Path $guestRoot "Windows\System32\HostDriverStore\FileRepository\$DriverRepositoryDirectory"
    New-Item -ItemType Directory -Path $guestRepo -Force | Out-Null
    & robocopy.exe $sourceRepo $guestRepo /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    $rc = $LASTEXITCODE
    if ($rc -gt 7) { throw "Robocopy failed with exit code $rc." }

    $srcCount = @(Get-ChildItem $sourceRepo -File -Recurse).Count
    $dstCount = @(Get-ChildItem $guestRepo -File -Recurse).Count
    Write-Host "Robocopy exit: $rc; source files: $srcCount; guest files: $dstCount"
    if ($srcCount -ne $dstCount) { throw 'Driver repository file-count mismatch.' }

    $system32 = Join-Path $guestRoot 'Windows\System32'
    $syswow64 = Join-Path $guestRoot 'Windows\SysWOW64'

    Step 'Apply NVIDIA CopyToVmWhenNewer mappings (64-bit)'
    foreach ($m in $system32Mappings) {
        Copy-WhenNewer (Join-Path $sourceRepo $m[0]) (Join-Path $system32 $m[1]) $backupSystem32
    }

    Step 'Apply NVIDIA CopyToVmWhenNewerWow64 mappings (32-bit)'
    foreach ($m in $wow64Mappings) {
        Copy-WhenNewer (Join-Path $sourceRepo $m[0]) (Join-Path $syswow64 $m[1]) $backupWow64
    }

    Step 'Stage nvidia-smi diagnostic executable'
    Copy-Exact (Join-Path $sourceRepo 'nvidia-smi.exe') (Join-Path $system32 'nvidia-smi.exe') $backupSystem32

    Step 'Verify critical guest payload'
    $verify = @(
        (Join-Path $guestRepo 'nvlddmkm.sys'),
        (Join-Path $guestRepo 'nvcuda64.dll'),
        (Join-Path $guestRepo 'nvml.dll'),
        (Join-Path $system32 'nvcuda.dll'),
        (Join-Path $system32 'nvml.dll'),
        (Join-Path $system32 'nvidia-smi.exe'),
        (Join-Path $syswow64 'nvcuda.dll')
    )
    foreach ($p in $verify) { Assert-File $p; Write-Host "OK     $p" }

    Write-Host ''
    Write-Host 'GPU-P driver staging completed successfully.'
    if (Test-Path -LiteralPath $backupRoot) { Write-Host "Backup root: $backupRoot" }
}
finally {
    if ($tempAccessPath -and $null -ne $diskNumber) {
        try {
            $part = Get-Partition -DiskNumber $diskNumber | Where-Object { $_.AccessPaths -contains $tempAccessPath } | Select-Object -First 1
            if ($part) {
                Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber -AccessPath $tempAccessPath -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    if ($mounted) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
}
