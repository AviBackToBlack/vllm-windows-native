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

if ([string]::IsNullOrWhiteSpace($InstallationRoot)) {
    $InstallationRoot = 'D:\AI\vLLM'
    $defaultVolume = [IO.Path]::GetPathRoot($InstallationRoot)
    if (-not (Test-Path -LiteralPath $defaultVolume -PathType Container)) {
        throw "Default installation root '$InstallationRoot' is unavailable because volume '$defaultVolume' does not exist. Pass -InstallationRoot with an existing local path."
    }
}
$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot

$archiveName = [string]$manifest.archive.name
if ([IO.Path]::GetFileName($archiveName) -ne $archiveName) { throw "Archive name must be a file name: $archiveName" }
$expectedSize = [int64]$manifest.archive.size_bytes
$expectedSha = ([string]$manifest.archive.sha256).ToUpperInvariant()
$expectedEntryCount = [int]$manifest.archive.entry_count
$archiveRoot = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.archive.extraction_root) -Label 'Python archive extraction root'
$managedRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.install.managed_relative_path) -Label 'Managed Python path'
$pythonRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.install.python_executable) -Label 'Python executable path'
$expectedVersion = [string]$manifest.acceptance.expected_version
$expectedPointerBits = [int]$manifest.acceptance.expected_pointer_bits
$requiredFiles = @($manifest.archive.required_files | ForEach-Object { Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Required Python file path' })

function Test-PythonArchive {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $expectedSize) { return $false }
    return ((Get-FileSha256 -Path $Path) -eq $expectedSha)
}


function Test-PythonRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($relative in $requiredFiles) {
        $candidate = Join-Path $Root $relative
        try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $candidate -RelativePath $relative) } catch { return $false }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }
    }
    $python = Join-Path $Root $pythonRelative
    try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $python -RelativePath $pythonRelative) } catch { return $false }
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
$result = $null
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
    [void](Assert-VllmSafeArchiveLayout -Path $archiveSource -TarCommand $tar -ExpectedRoot $archiveRoot -ExpectedEntryCount $expectedEntryCount -EntryPolicy 'RegularFilesOnly' -Label 'Python archive')

    $receiptName = 'python-bootstrap-' + [string]$manifest.version + '.json'
    $receiptPath = Join-Path $forensicDir $receiptName
    $receiptRelative = 'forensic\' + $receiptName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
    if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Reserved Python receipt path exists but is not a file: $receiptPath"
    }

    if (Test-Path -LiteralPath $targetRoot) {
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Managed Python target exists but is not a directory: $targetRoot" }
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
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Managed Python target changed into a non-directory before replacement: $targetRoot" }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
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
                    throw "Activation failed and rollback cannot safely remove the failed target. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "Activation failed and cleanup cannot safely remove the failed target. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "Activation failed and rollback could not restore the prior runtime. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $activationError
    }

    $receiptName = 'python-bootstrap-' + [string]$manifest.version + '.json'
    $receiptPath = Join-Path $forensicDir $receiptName
    $receiptRelative = 'forensic\' + $receiptName
    try {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
        if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw "Reserved Python receipt path changed into a non-file before commit: $receiptPath"
        }
        $resultPython = Join-Path $targetRoot $pythonRelative
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $targetRoot -Path $resultPython -RelativePath $pythonRelative)
        $result = [ordered]@{
            schema_version = 1
            component = 'cpython'
            version = [string]$manifest.version
            platform = [string]$manifest.platform
            ready = $true
            root = $targetRoot
            python = $resultPython
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
                    throw "Receipt commit failed and rollback cannot safely remove the new runtime. Prior runtime backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "Receipt commit failed and cleanup cannot safely remove the new runtime. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "Receipt commit failed and rollback could not restore the prior runtime. Backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $receiptError
    }
    if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
        $backupRelative = 'python\managed\' + [IO.Path]::GetFileName($backupRoot)
        try {
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
            $backupRoot = $null
        }
        catch {
            Write-Warning "Portable Python committed successfully, but the prior runtime backup could not be removed and was preserved at '$backupRoot': $($_.Exception.Message)"
        }
    }
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
