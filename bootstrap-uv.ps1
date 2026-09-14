[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/bootstrap/uv-0.12.13-windows-x86_64.json',
    [string] $InstallationRoot = '',
    [string] $ArchivePath = '',
    [switch] $Refresh,
    [switch] $Force,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'bootstrap-uv.ps1 supports native Windows x64 only.'
}

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) {
    throw "Portable uv manifest not found: $manifestResolved"
}
$manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json
if ([string]$manifest.component -ne 'uv' -or [string]$manifest.platform -ne 'windows-x86_64') {
    throw "Unsupported uv manifest: component=$($manifest.component), platform=$($manifest.platform)"
}

if ([string]::IsNullOrWhiteSpace($InstallationRoot)) {
    $InstallationRoot = 'D:\AI\vLLM'
    $defaultVolume = [IO.Path]::GetPathRoot($InstallationRoot)
    if (-not (Test-Path -LiteralPath $defaultVolume -PathType Container)) {
        throw "Default installation root '$InstallationRoot' is unavailable because volume '$defaultVolume' does not exist. Pass -InstallationRoot with an existing local path."
    }
}
$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot

$version = [string]$manifest.version
$archiveName = [string]$manifest.archive.name
if ([IO.Path]::GetFileName($archiveName) -ne $archiveName) { throw "uv archive name must be a file name: $archiveName" }
$expectedSize = [int64]$manifest.archive.size_bytes
$expectedSha = ([string]$manifest.archive.sha256).ToUpperInvariant()
$expectedEntryCount = [int]$manifest.archive.entry_count
$managedRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.install.managed_relative_path) -Label 'Managed uv path'
$uvRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.install.uv_executable) -Label 'uv executable path'
$requiredFiles = @($manifest.archive.required_files | ForEach-Object { Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Required uv file path' })
$expectedVersion = [string]$manifest.acceptance.expected_version
$expectedCommitPrefix = [string]$manifest.acceptance.expected_commit_prefix

function Test-UvArchive {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $expectedSize) { return $false }
    return ((Get-FileSha256 -Path $Path) -eq $expectedSha)
}
function Assert-UvArchiveLayout {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$TarCommand
    )
    $entries = @(& $TarCommand.Source -tf $Path)
    if ($LASTEXITCODE -ne 0) { throw "uv archive listing failed (exit $LASTEXITCODE)." }
    $verbose = @(& $TarCommand.Source -tvf $Path)
    if ($LASTEXITCODE -ne 0) { throw "uv archive verbose listing failed (exit $LASTEXITCODE)." }
    if ($entries.Count -ne $verbose.Count) { throw 'uv archive normal and verbose listings disagree on entry count.' }
    if ($entries.Count -ne $expectedEntryCount) {
        throw "uv archive entry count mismatch. Expected $expectedEntryCount, got $($entries.Count)."
    }

    $expected = @{}
    foreach ($relative in $requiredFiles) {
        $name = $relative.Replace('\','/')
        if ($name.Contains('/')) { throw "uv archive expected member must be top-level: $relative" }
        $expected[$name] = $true
    }
    $seen = @{}
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = ([string]$entries[$index]).Replace('\','/').TrimEnd('/')
        $line = [string]$verbose[$index]
        if ([string]::IsNullOrWhiteSpace($entry)) { throw 'uv archive contains an empty member name.' }
        [void](Assert-VllmSafeRelativePath -RelativePath $entry -Label 'uv archive member')
        if ($entry.Contains('/')) { throw "uv archive contains a non-top-level member: $entry" }
        if ([string]::IsNullOrEmpty($line) -or $line[0] -ne '-') { throw "uv archive contains a non-regular-file entry: $line" }
        if ($seen.ContainsKey($entry)) { throw "uv archive contains duplicate entry: $entry" }
        if (-not $expected.ContainsKey($entry)) { throw "uv archive contains unexpected entry: $entry" }
        $seen[$entry] = $true
    }
    foreach ($name in $expected.Keys) {
        if (-not $seen.ContainsKey($name)) { throw "uv archive is missing expected entry: $name" }
    }
    return $entries
}

function Test-UvRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $all = @(Get-ChildItem -LiteralPath $Root -Force)
    if ($all.Count -ne $expectedEntryCount) { return $false }
    if (@($all | Where-Object { $_.PSIsContainer }).Count -ne 0) { return $false }
    if (@($all | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { return $false }
    foreach ($relative in $requiredFiles) {
        $candidate = Join-Path $Root $relative
        try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $candidate -RelativePath $relative) } catch { return $false }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }
    }
    $uv = Join-Path $Root $uvRelative
    try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $uv -RelativePath $uvRelative) } catch { return $false }
    $probe = (& $uv --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    return $probe.StartsWith("uv $expectedVersion ($expectedCommitPrefix ", [StringComparison]::Ordinal)
}
$lock = $null
$stageRoot = $null
$backupRoot = $null
$downloaded = $false
$reusedCache = $false
$sourceKind = ''
$result = $null
try {
    $lock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-uv'
    $InstallationRoot = $lock.Root
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)

    $downloadDir = Join-Path $InstallationRoot ("downloads\uv\$version")
    $managedParent = Join-Path $InstallationRoot 'tools\uv'
    $workParent = Join-Path $InstallationRoot 'work\uv-bootstrap'
    $forensicDir = Join-Path $InstallationRoot 'forensic'
    $targetRoot = Join-Path $InstallationRoot $managedRelative
    foreach ($pathInfo in @(
        @{Path=$downloadDir; Relative=("downloads\uv\$version")},
        @{Path=$managedParent; Relative='tools\uv'},
        @{Path=$workParent; Relative='work\uv-bootstrap'},
        @{Path=$forensicDir; Relative='forensic'},
        @{Path=$targetRoot; Relative=$managedRelative}
    )) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pathInfo.Path -RelativePath $pathInfo.Relative)
    }
    foreach ($directory in @($downloadDir,$managedParent,$workParent,$forensicDir)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw 'tar.exe is required to materialize portable uv.' }

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $archiveSource = Resolve-ProjectPath -Path $ArchivePath -BasePath $projectRoot
        if (-not (Test-UvArchive -Path $archiveSource)) {
            throw "Provided uv archive does not match the pinned size/SHA-256: $archiveSource"
        }
        $sourceKind = 'provided'
    }
    else {
        $archiveSource = Join-Path $downloadDir $archiveName
        $archiveRelative = "downloads\uv\$version\$archiveName"
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $archiveSource -RelativePath $archiveRelative)
        $cacheValid = Test-UvArchive -Path $archiveSource
        if ($Refresh -or -not $cacheValid) {
            $partial = $archiveSource + '.partial.' + [guid]::NewGuid().ToString('N')
            try {
                $lastError = $null
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    try {
                        Invoke-WebRequest -Uri ([string]$manifest.archive.url) -OutFile $partial -UseBasicParsing
                        $lastError = $null
                        break
                    }
                    catch {
                        $lastError = $_
                        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                    }
                }
                if ($null -ne $lastError) { throw $lastError }
                if (-not (Test-UvArchive -Path $partial)) { throw 'Downloaded uv archive does not match the pinned size/SHA-256.' }
                Move-Item -LiteralPath $partial -Destination $archiveSource -Force
                $downloaded = $true
            }
            finally {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            $reusedCache = $true
        }
        $sourceKind = if ($downloaded) { 'downloaded' } else { 'cache' }
    }

    if (-not (Test-UvArchive -Path $archiveSource)) { throw 'uv archive changed after validation.' }
    [void](Assert-UvArchiveLayout -Path $archiveSource -TarCommand $tar)
    $receiptName = 'uv-bootstrap-' + $version + '.json'
    $receiptPath = Join-Path $forensicDir $receiptName
    $receiptRelative = 'forensic\' + $receiptName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
    if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Reserved uv receipt path exists but is not a file: $receiptPath"
    }

    if (Test-Path -LiteralPath $targetRoot) {
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Managed uv target exists but is not a directory: $targetRoot" }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not $Force) { throw "Managed uv target already exists: $targetRoot. Re-run with -Force only when replacement is intended." }
    }

    $stageName = 'stage-' + [guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $workParent $stageName
    $stageRelative = 'work\uv-bootstrap\' + $stageName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)
    [void][IO.Directory]::CreateDirectory($stageRoot)
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)

    & $tar.Source -xf $archiveSource -C $stageRoot
    if ($LASTEXITCODE -ne 0) { throw "uv archive extraction failed (exit $LASTEXITCODE)." }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)
    if (-not (Test-UvRoot -Root $stageRoot)) { throw 'Extracted uv runtime failed file/version validation.' }

    if (Test-Path -LiteralPath $targetRoot) {
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Managed uv target changed into a non-directory before replacement: $targetRoot" }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        $backupName = '.backup-' + $version + '-' + [guid]::NewGuid().ToString('N')
        $backupRoot = Join-Path $managedParent $backupName
        $backupRelative = 'tools\uv\' + $backupName
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot
    }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $targetRoot
        $stageRoot = $null
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not (Test-UvRoot -Root $targetRoot)) { throw 'Activated uv runtime failed final validation.' }
    }
    catch {
        $activationError = $_
        if (Test-Path -LiteralPath $targetRoot) {
            try {
                [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
                Remove-Item -LiteralPath $targetRoot -Recurse -Force
            }
            catch {
                if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
                    throw "uv activation failed and rollback cannot safely remove the failed target. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "uv activation failed and cleanup cannot safely remove the failed target. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "uv activation failed and rollback could not restore the prior runtime. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $activationError
    }
    try {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
        if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw "Reserved uv receipt path changed into a non-file before commit: $receiptPath"
        }
        $uvPath = Join-Path $targetRoot $uvRelative
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $targetRoot -Path $uvPath -RelativePath $uvRelative)
        $result = [ordered]@{
            schema_version = 1
            component = 'uv'
            version = $version
            platform = [string]$manifest.platform
            ready = $true
            root = $targetRoot
            uv = $uvPath
            archive = $archiveSource
            archive_source = $sourceKind
            archive_sha256 = $expectedSha
            archive_size_bytes = $expectedSize
            manifest = $manifestResolved
            manifest_sha256 = Get-FileSha256 -Path $manifestResolved
            release_tag = [string]$manifest.release.tag
            release_commit = [string]$manifest.release.commit
            github_attestation_verified = [bool]$manifest.acceptance.github_attestation_verified
            authenticode_verified = [bool]$manifest.acceptance.authenticode_verified
            downloaded = $downloaded
            reused_cache = $reusedCache
            activated_at = (Get-Date).ToString('o')
        }
        $receiptTemp = $receiptPath + '.partial.' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($receiptTemp, ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $receiptTemp -Destination $receiptPath -Force
        }
        finally {
            Remove-Item -LiteralPath $receiptTemp -Force -ErrorAction SilentlyContinue
        }
        $result.receipt = $receiptPath
    }
    catch {
        $receiptError = $_
        if (Test-Path -LiteralPath $targetRoot) {
            try {
                [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
                Remove-Item -LiteralPath $targetRoot -Recurse -Force
            }
            catch {
                if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
                    throw "uv receipt commit failed and rollback cannot safely remove the new runtime. Prior runtime backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "uv receipt commit failed and cleanup cannot safely remove the new runtime. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "uv receipt commit failed and rollback could not restore the prior runtime. Backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $receiptError
    }
    if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
        $backupRelative = 'tools\uv\' + [IO.Path]::GetFileName($backupRoot)
        try {
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
            $backupRoot = $null
        }
        catch {
            Write-Warning "Portable uv committed successfully, but the prior runtime backup could not be removed and was preserved at '$backupRoot': $($_.Exception.Message)"
        }
    }
}
finally {
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        try {
            $relative = 'work\uv-bootstrap\' + [IO.Path]::GetFileName($stageRoot)
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $relative)
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        }
        catch {
            Write-Warning "Preserving uv staging directory after cleanup validation failure: $stageRoot"
        }
    }
    if ($null -ne $lock) { Exit-VllmOperationLock -Lock $lock }
}

if ($null -eq $result -or -not [bool]$result.ready) { throw 'Portable uv bootstrap did not complete.' }
if ($Json) {
    [pscustomobject]$result | ConvertTo-Json -Depth 8
}
else {
    Write-Host "uv $($result.version) ready"
    Write-Host "Root:    $($result.root)"
    Write-Host "uv:      $($result.uv)"
    Write-Host "Archive: $($result.archive)"
    Write-Host "SHA256:  $($result.archive_sha256)"
    Write-Host 'BOOTSTRAP_UV_READY'
}