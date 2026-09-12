[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/bootstrap/cpython-3.13.15-windows-x86_64.json',
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
    throw 'bootstrap-python.ps1 supports native Windows x64 only.'
}

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) {
    throw "Portable Python manifest not found: $manifestResolved"
}
$manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json
if ([string]$manifest.component -ne 'cpython' -or [string]$manifest.platform -ne 'windows-x86_64') {
    throw "Unsupported Python manifest: component=$($manifest.component), platform=$($manifest.platform)"
}
if ([string]$manifest.distribution -ne 'python-build-standalone') {
    throw "Unsupported Python distribution: $($manifest.distribution)"
}

if ([string]::IsNullOrWhiteSpace($InstallationRoot)) { $InstallationRoot = $projectRoot }
$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot

$archiveName = [string]$manifest.archive.name
if ([IO.Path]::GetFileName($archiveName) -ne $archiveName) { throw "Archive name must be a file name: $archiveName" }
$expectedSize = [int64]$manifest.archive.size_bytes
$expectedSha = ([string]$manifest.archive.sha256).ToUpperInvariant()
$expectedEntryCount = [int]$manifest.archive.entry_count
$archiveRoot = ([string]$manifest.archive.extraction_root).Trim('/','\')
$managedRelative = ([string]$manifest.install.managed_relative_path).Replace('/','\')
$pythonRelative = ([string]$manifest.install.python_executable).Replace('/','\')
$expectedVersion = [string]$manifest.acceptance.expected_version
$expectedPointerBits = [int]$manifest.acceptance.expected_pointer_bits
$requiredFiles = @($manifest.archive.required_files | ForEach-Object { ([string]$_).Replace('/','\') })

function Test-PythonArchive {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $expectedSize) { return $false }
    return ((Get-FileSha256 -Path $Path) -eq $expectedSha)
}

function Assert-PythonArchiveLayout {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$TarCommand
    )
    $entries = @(& $TarCommand.Source -tzf $Path)
    if ($LASTEXITCODE -ne 0) { throw "tar listing failed (exit $LASTEXITCODE)." }
    if ($entries.Count -ne $expectedEntryCount) {
        throw "Python archive entry count mismatch. Expected $expectedEntryCount, got $($entries.Count)."
    }
    $prefix = $archiveRoot + '/'
    $seen = @{}
    foreach ($entryRaw in $entries) {
        $entry = ([string]$entryRaw).Replace('\','/')
        if ([string]::IsNullOrWhiteSpace($entry) -or -not $entry.StartsWith($prefix, [StringComparison]::Ordinal)) {
            throw "Python archive entry escapes expected root '$archiveRoot': $entry"
        }
        $relative = $entry.Substring($prefix.Length)
        $parts = @($relative.Split('/'))
        if ([string]::IsNullOrWhiteSpace($relative) -or $parts -contains '..' -or $parts -contains '.' -or $parts -contains '') {
            throw "Python archive contains unsafe relative path: $entry"
        }
        foreach ($part in $parts) {
            if ($part.Contains(':')) { throw "Python archive entry contains unsupported colon/ADS syntax: $entry" }
            if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "Python archive entry has Windows-ambiguous trailing dot/space: $entry" }
            if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { throw "Python archive entry uses a reserved Windows device name: $entry" }
        }
        if ($seen.ContainsKey($entry)) { throw "Python archive contains duplicate entry: $entry" }
        $seen[$entry] = $true
    }

    if ([bool]$manifest.archive.regular_files_only) {
        $verbose = @(& $TarCommand.Source -tvzf $Path)
        if ($LASTEXITCODE -ne 0) { throw "tar verbose listing failed (exit $LASTEXITCODE)." }
        if ($verbose.Count -ne $expectedEntryCount) { throw 'Python archive verbose entry count differs from normal listing.' }
        foreach ($line in $verbose) {
            if ([string]::IsNullOrEmpty([string]$line) -or ([string]$line)[0] -ne '-') {
                throw "Python archive contains a non-regular-file entry: $line"
            }
        }
    }
    return $entries
}

function Test-PythonRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { return $false }
    }
    $python = Join-Path $Root $pythonRelative
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { return $false }
    $probe = (& $python -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}')" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($probe -eq ($expectedVersion + '|' + $expectedPointerBits))
}

$lock = $null
$stageRoot = $null
$backupRoot = $null
$downloaded = $false
$reusedCache = $false
$sourceKind = ''
try {
    $lock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-python'
    $InstallationRoot = $lock.Root
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)

    $downloadDir = Join-Path $InstallationRoot 'downloads\python'
    $managedParent = Join-Path $InstallationRoot 'python\managed'
    $workParent = Join-Path $InstallationRoot 'work\python-bootstrap'
    $forensicDir = Join-Path $InstallationRoot 'forensic'
    $targetRoot = Join-Path $InstallationRoot $managedRelative
    foreach ($pathInfo in @(
        @{Path=$downloadDir; Relative='downloads\python'},
        @{Path=$managedParent; Relative='python\managed'},
        @{Path=$workParent; Relative='work\python-bootstrap'},
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
    if (-not $tar) { throw 'tar.exe is required to materialize portable CPython.' }

    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $archiveSource = Resolve-ProjectPath -Path $ArchivePath -BasePath $projectRoot
        if (-not (Test-PythonArchive -Path $archiveSource)) {
            throw "Provided Python archive does not match the pinned size/SHA-256: $archiveSource"
        }
        $sourceKind = 'provided'
    } else {
        $archiveSource = Join-Path $downloadDir $archiveName
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $archiveSource -RelativePath ('downloads\python\' + $archiveName))
        $cacheValid = Test-PythonArchive -Path $archiveSource
        if ($Refresh -or -not $cacheValid) {
            $partial = $archiveSource + '.partial.' + [guid]::NewGuid().ToString('N')
            try {
                $lastError = $null
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    try {
                        Invoke-WebRequest -Uri ([string]$manifest.archive.url) -OutFile $partial -UseBasicParsing
                        $lastError = $null
                        break
                    } catch {
                        $lastError = $_
                        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                    }
                }
                if ($null -ne $lastError) { throw $lastError }
                if (-not (Test-PythonArchive -Path $partial)) {
                    throw 'Downloaded Python archive does not match the pinned size/SHA-256.'
                }
                Move-Item -LiteralPath $partial -Destination $archiveSource -Force
                $downloaded = $true
            } finally {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
        } else {
            $reusedCache = $true
        }
        $sourceKind = if ($downloaded) { 'downloaded' } else { 'cache' }
    }

    if (-not (Test-PythonArchive -Path $archiveSource)) { throw 'Python archive changed after validation.' }
    [void](Assert-PythonArchiveLayout -Path $archiveSource -TarCommand $tar)

    if (Test-Path -LiteralPath $targetRoot) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not $Force) {
            throw "Managed Python target already exists: $targetRoot. Re-run with -Force only when replacement is intended."
        }
    }

    $stageName = 'stage-' + [guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $workParent $stageName
    $stageRelative = 'work\python-bootstrap\' + $stageName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)
    [void][IO.Directory]::CreateDirectory($stageRoot)
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)

    & $tar.Source -xzf $archiveSource --strip-components 1 -C $stageRoot
    if ($LASTEXITCODE -ne 0) { throw "Python tar extraction failed (exit $LASTEXITCODE)." }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $stageRelative)
    $stageFiles = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Force)
    if ($stageFiles.Count -ne $expectedEntryCount) {
        throw "Extracted Python file count mismatch. Expected $expectedEntryCount, got $($stageFiles.Count)."
    }
    $reparse = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparse.Count -gt 0) { throw "Extracted Python tree contains reparse points: $($reparse[0].FullName)" }
    if (-not (Test-PythonRoot -Root $stageRoot)) { throw 'Extracted Python runtime failed version/architecture validation.' }

    if (Test-Path -LiteralPath $targetRoot) {
        $backupName = '.backup-' + [string]$manifest.version + '-' + [guid]::NewGuid().ToString('N')
        $backupRoot = Join-Path $managedParent $backupName
        $backupRelative = 'python\managed\' + $backupName
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot
    }
    try {
        Move-Item -LiteralPath $stageRoot -Destination $targetRoot
        $stageRoot = $null
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not (Test-PythonRoot -Root $targetRoot)) { throw 'Activated Python runtime failed final validation.' }
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
                    throw "Activation failed and rollback cannot safely remove the failed target. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Rollback: $($_.Exception.Message)"
                }
                throw
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $targetRoot
            $backupRoot = $null
        }
        throw $activationError
    }

    if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
        $backupRelative = 'python\managed\' + [IO.Path]::GetFileName($backupRoot)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
        $backupRoot = $null
    }

    $receiptName = 'python-bootstrap-' + [string]$manifest.version + '.json'
    $receiptPath = Join-Path $forensicDir $receiptName
    $receiptRelative = 'forensic\' + $receiptName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
    $result = [ordered]@{
        schema_version = 1
        component = 'cpython'
        version = [string]$manifest.version
        platform = [string]$manifest.platform
        ready = $true
        root = $targetRoot
        python = Join-Path $targetRoot $pythonRelative
        archive = $archiveSource
        archive_source = $sourceKind
        archive_sha256 = $expectedSha
        archive_size_bytes = $expectedSize
        manifest = $manifestResolved
        manifest_sha256 = Get-FileSha256 -Path $manifestResolved
        release_tag = [string]$manifest.release.tag
        release_commit = [string]$manifest.release.commit
        github_attestation_verified = [bool]$manifest.acceptance.github_attestation_verified
        downloaded = $downloaded
        reused_cache = $reusedCache
        activated_at = (Get-Date).ToString('o')
    }
    $receiptTemp = $receiptPath + '.partial.' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($receiptTemp, ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $receiptTemp -Destination $receiptPath -Force
    } finally {
        Remove-Item -LiteralPath $receiptTemp -Force -ErrorAction SilentlyContinue
    }
    $result.receipt = $receiptPath
}
finally {
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        try {
            $relative = 'work\python-bootstrap\' + [IO.Path]::GetFileName($stageRoot)
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stageRoot -RelativePath $relative)
            Remove-Item -LiteralPath $stageRoot -Recurse -Force
        } catch {
            Write-Warning "Preserving Python staging directory after cleanup validation failure: $stageRoot"
        }
    }
    if ($null -ne $lock) { Exit-VllmOperationLock -Lock $lock }
}

if ($null -eq $result -or -not [bool]$result.ready) { throw 'Portable Python bootstrap did not complete.' }
if ($Json) {
    [pscustomobject]$result | ConvertTo-Json -Depth 8
} else {
    Write-Host "CPython $($result.version) ready"
    Write-Host "Root:    $($result.root)"
    Write-Host "Python:  $($result.python)"
    Write-Host "Archive: $($result.archive)"
    Write-Host "SHA256:  $($result.archive_sha256)"
    Write-Host 'BOOTSTRAP_PYTHON_READY'
}
