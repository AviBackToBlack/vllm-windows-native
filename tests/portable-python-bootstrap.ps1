[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $repoRoot 'bootstrap-python.ps1'
. (Join-Path $repoRoot 'scripts\common.ps1')
$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Test archive not found: $archive" }

function Test-ExpectedFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        & $Action
        throw "Expected failure did not occur: $Name"
    } catch {
        if ($_.Exception.Message -eq "Expected failure did not occur: $Name") { throw }
        Write-Host "REJECT $Name :: $($_.Exception.Message)"
    }
}

function Invoke-TestBootstrap {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Force
    )
    $parameters = @{ InstallationRoot=$Root; ArchivePath=$archive; Json=$true }
    if ($Force) { $parameters.Force = $true }
    $json = & $bootstrap @parameters
    return ($json | ConvertFrom-Json)
}

function Write-FixtureManifest {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$EntryCount,
        [Parameter(Mandatory)][string]$ManagedRelativePath,
        [string]$PythonExecutable = 'python.exe',
        [string[]]$RequiredFiles = @('python.exe')
    )
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'manifests\bootstrap\cpython-3.13.15-windows-x86_64.json') -Raw | ConvertFrom-Json
    $manifest.archive.name = [IO.Path]::GetFileName($Archive)
    $manifest.archive.url = 'https://invalid.example.test/not-used'
    $manifest.archive.sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    $manifest.archive.size_bytes = (Get-Item -LiteralPath $Archive).Length
    $manifest.archive.entry_count = $EntryCount
    $manifest.archive.extraction_root = 'python'
    $manifest.archive.regular_files_only = $true
    $manifest.archive.required_files = @($RequiredFiles)
    $manifest.install.managed_relative_path = $ManagedRelativePath.Replace('\','/')
    $manifest.install.python_executable = $PythonExecutable.Replace('\','/')
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    return $Path
}

$base = Join-Path $env:TEMP ('vllm-portable-python-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
try {
    $root = Join-Path $base 'valid'
    $result = Invoke-TestBootstrap -Root $root
    if (-not $result.ready) { throw 'Valid bootstrap did not report ready.' }
    if (-not (Test-Path -LiteralPath $result.python -PathType Leaf)) { throw 'Materialized python.exe is missing.' }
    $files = @(Get-ChildItem -LiteralPath $result.root -Recurse -File)
    if ($files.Count -ne 3303) { throw "Materialized file count mismatch: $($files.Count)" }
    if (-not (Test-Path -LiteralPath $result.receipt -PathType Leaf)) { throw 'Forensic receipt is missing.' }
    Write-Host 'VALID_BOOTSTRAP_OK'

    $managedLeaf = [IO.Path]::GetFileName($result.root)
    $fileTargetRoot = Join-Path $base 'file-target-root'
    $fileTargetParent = Join-Path $fileTargetRoot 'python\managed'
    [void][IO.Directory]::CreateDirectory($fileTargetParent)
    $fileTarget = Join-Path $fileTargetParent $managedLeaf
    Set-Content -LiteralPath $fileTarget -Value 'DO-NOT-DELETE' -Encoding ascii
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $fileTargetRoot -ArchivePath $archive -Force -Json | Out-Null } 'managed-target-file'
    if (-not (Test-Path -LiteralPath $fileTarget -PathType Leaf)) { throw 'Managed target file was removed by forced bootstrap.' }
    if ((Get-Content -LiteralPath $fileTarget -Raw).Trim() -ne 'DO-NOT-DELETE') { throw 'Managed target file content changed.' }
    Write-Host 'MANAGED_TARGET_FILE_PRESERVED'

    $receiptDirectoryRoot = Join-Path $base 'receipt-directory-root'
    $receiptDirectory = Join-Path $receiptDirectoryRoot ('forensic\' + [IO.Path]::GetFileName($result.receipt))
    [void][IO.Directory]::CreateDirectory($receiptDirectory)
    $receiptDirectorySentinel = Join-Path $receiptDirectory 'sentinel.txt'
    Set-Content -LiteralPath $receiptDirectorySentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $receiptDirectoryRoot -ArchivePath $archive -Json | Out-Null } 'receipt-path-directory'
    if ((Get-Content -LiteralPath $receiptDirectorySentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'Receipt directory rejection modified its sentinel.' }
    $unexpectedTarget = Join-Path $receiptDirectoryRoot ('python\managed\' + $managedLeaf)
    if (Test-Path -LiteralPath $unexpectedTarget) { throw 'Receipt-directory rejection activated a Python target.' }
    Write-Host 'RECEIPT_DIRECTORY_PRESERVED'

    $lockRoot = Join-Path $base 'lock-contention'
    $heldLock = Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'portable-python-test-holder'
    try {
        Test-ExpectedFailure { & $bootstrap -InstallationRoot $lockRoot -ArchivePath $archive -Json | Out-Null } 'bootstrap-operation-lock-contention'
        if (Test-Path -LiteralPath (Join-Path $lockRoot 'python')) { throw 'Contended bootstrap created managed Python state before acquiring the operation lock.' }
    }
    finally {
        Exit-VllmOperationLock -Lock $heldLock
    }
    Write-Host 'BOOTSTRAP_LOCK_CONTENTION_OK'

    Test-ExpectedFailure { & $bootstrap -InstallationRoot $root -ArchivePath $archive -Json | Out-Null } 'existing-target-without-force'
    if (-not (Test-Path -LiteralPath $result.python -PathType Leaf)) { throw 'Existing target was modified after fail-closed rerun.' }

    $marker = Join-Path $result.root 'replace-me.marker'
    Set-Content -LiteralPath $marker -Value 'old' -Encoding ascii
    $forced = Invoke-TestBootstrap -Root $root -Force
    if (Test-Path -LiteralPath $marker) { throw 'Force replacement preserved stale target content.' }
    if (@(Get-ChildItem -LiteralPath $forced.root -Recurse -File).Count -ne 3303) { throw 'Force replacement produced unexpected file count.' }
    Write-Host 'FORCE_REPLACEMENT_OK'

    $rollbackMarker = Join-Path $forced.root 'rollback-old.marker'
    Set-Content -LiteralPath $rollbackMarker -Value 'OLD-RUNTIME' -Encoding ascii
    $receiptBefore = Get-Content -LiteralPath $forced.receipt -Raw
    $receiptHandle = [IO.File]::Open($forced.receipt,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        Test-ExpectedFailure { & $bootstrap -InstallationRoot $root -ArchivePath $archive -Force -Json | Out-Null } 'receipt-commit-rollback'
    }
    finally {
        $receiptHandle.Dispose()
    }
    if (-not (Test-Path -LiteralPath $rollbackMarker -PathType Leaf)) { throw 'Receipt failure did not restore the prior runtime.' }
    if ((Get-Content -LiteralPath $rollbackMarker -Raw).Trim() -ne 'OLD-RUNTIME') { throw 'Restored runtime marker changed during receipt rollback.' }
    if ((Get-Content -LiteralPath $forced.receipt -Raw) -ne $receiptBefore) { throw 'Receipt failure modified the prior forensic receipt.' }
    $managedParent = Split-Path -Parent $forced.root
    if (@(Get-ChildItem -LiteralPath $managedParent -Directory -Filter '.backup-*' -Force).Count -ne 0) { throw 'Receipt rollback left a managed runtime backup behind.' }
    Write-Host 'RECEIPT_FAILURE_ROLLBACK_OK'

    $activationSource = Join-Path $base 'activation-source'
    $activationPythonDir = Join-Path $activationSource 'python'
    [void][IO.Directory]::CreateDirectory($activationPythonDir)
    $activationProbe = Join-Path $activationPythonDir 'probe.cmd'
    $activationProbeBody = "@echo off`r`necho %~dp0 | findstr /I `"work\\python-bootstrap\\stage-`" >nul`r`nif errorlevel 1 (`r`n  echo ACTIVATED-BROKEN`r`n) else (`r`n  echo 3.13.15^|64`r`n)`r`nexit /b 0`r`n"
    [IO.File]::WriteAllText($activationProbe,$activationProbeBody,[Text.ASCIIEncoding]::new())
    $activationArchive = Join-Path $base 'activation-failure.tar.gz'
    & tar.exe -czf $activationArchive -C $activationSource 'python/probe.cmd'
    if ($LASTEXITCODE -ne 0) { throw "Failed to create activation-failure fixture archive: $LASTEXITCODE" }
    $activationManifest = Join-Path $base 'activation-failure-manifest.json'
    [void](Write-FixtureManifest -Archive $activationArchive -Path $activationManifest -EntryCount 1 -ManagedRelativePath 'python\managed\activation-fixture' -PythonExecutable 'probe.cmd' -RequiredFiles @('probe.cmd'))
    $activationRoot = Join-Path $base 'activation-failure-root'
    $activationOldRoot = Join-Path $activationRoot 'python\managed\activation-fixture'
    [void][IO.Directory]::CreateDirectory($activationOldRoot)
    $activationMarker = Join-Path $activationOldRoot 'old-runtime.marker'
    Set-Content -LiteralPath $activationMarker -Value 'OLD-ACTIVE-RUNTIME' -Encoding ascii
    Test-ExpectedFailure { & $bootstrap -ManifestPath $activationManifest -InstallationRoot $activationRoot -ArchivePath $activationArchive -Force -Json | Out-Null } 'activation-final-validation-rollback'
    if (-not (Test-Path -LiteralPath $activationMarker -PathType Leaf)) { throw 'Activation failure did not restore the prior runtime.' }
    if ((Get-Content -LiteralPath $activationMarker -Raw).Trim() -ne 'OLD-ACTIVE-RUNTIME') { throw 'Activation rollback restored the wrong prior runtime content.' }
    $activationManagedParent = Split-Path -Parent $activationOldRoot
    if (@(Get-ChildItem -LiteralPath $activationManagedParent -Directory -Filter '.backup-*' -Force).Count -ne 0) { throw 'Activation rollback left a backup directory behind.' }
    Write-Host 'ACTIVATION_FAILURE_ROLLBACK_OK'

    $tarGenerator = Join-Path $base 'make-malicious-tar.py'
    $tarGeneratorBody = @"
import io
import sys
import tarfile

out_path, case = sys.argv[1], sys.argv[2]

def add_file(tf, name, payload=b"x"):
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    tf.addfile(info, io.BytesIO(payload))

with tarfile.open(out_path, "w:gz") as tf:
    if case == "root-escape":
        add_file(tf, "evil.txt")
    elif case == "traversal":
        add_file(tf, "python/../escape.txt")
    elif case == "trailing-dot":
        add_file(tf, "python/bad./file.txt")
    elif case == "reserved-name":
        add_file(tf, "python/CON.txt")
    elif case == "duplicate":
        add_file(tf, "python/dup.txt", b"one")
        add_file(tf, "python/dup.txt", b"two")
    elif case == "symlink":
        info = tarfile.TarInfo("python/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "target"
        tf.addfile(info)
    else:
        raise SystemExit("unknown case: " + case)
"@
    [IO.File]::WriteAllText($tarGenerator,$tarGeneratorBody,[Text.UTF8Encoding]::new($false))
    $archiveCases = @(
        [pscustomobject]@{ Name='root-escape'; EntryCount=1 },
        [pscustomobject]@{ Name='traversal'; EntryCount=1 },
        [pscustomobject]@{ Name='trailing-dot'; EntryCount=1 },
        [pscustomobject]@{ Name='reserved-name'; EntryCount=1 },
        [pscustomobject]@{ Name='duplicate'; EntryCount=2 },
        [pscustomobject]@{ Name='symlink'; EntryCount=1 }
    )
    foreach ($archiveCase in $archiveCases) {
        $fixtureArchive = Join-Path $base ("malicious-$($archiveCase.Name).tar.gz")
        & $result.python -I -S $tarGenerator $fixtureArchive $archiveCase.Name
        if ($LASTEXITCODE -ne 0) { throw "Failed to generate malicious tar fixture '$($archiveCase.Name)': $LASTEXITCODE" }
        $fixtureManifest = Join-Path $base ("malicious-$($archiveCase.Name)-manifest.json")
        [void](Write-FixtureManifest -Archive $fixtureArchive -Path $fixtureManifest -EntryCount $archiveCase.EntryCount -ManagedRelativePath ("python\managed\malicious-$($archiveCase.Name)"))
        $fixtureRoot = Join-Path $base ("malicious-$($archiveCase.Name)-root")
        Test-ExpectedFailure { & $bootstrap -ManifestPath $fixtureManifest -InstallationRoot $fixtureRoot -ArchivePath $fixtureArchive -Json | Out-Null } ("archive-layout-$($archiveCase.Name)")
        $fixtureTarget = Join-Path $fixtureRoot ("python\managed\malicious-$($archiveCase.Name)")
        if (Test-Path -LiteralPath $fixtureTarget) { throw "Unsafe archive '$($archiveCase.Name)' reached target activation." }
    }
    Write-Host 'ARCHIVE_LAYOUT_ADVERSARIAL_REJECTIONS_OK'

    $badArchive = Join-Path $base 'corrupt.tar.gz'
    [IO.File]::WriteAllBytes($badArchive, [byte[]](1,2,3,4,5))
    $badRoot = Join-Path $base 'corrupt-root'
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $badRoot -ArchivePath $badArchive -Json | Out-Null } 'corrupt-archive'
    Write-Host 'CORRUPT_ARCHIVE_REJECTED'

    $junctionRoot = Join-Path $base 'junction-root'
    $outside = Join-Path $base 'outside-python'
    [void][IO.Directory]::CreateDirectory($junctionRoot)
    [void][IO.Directory]::CreateDirectory($outside)
    $sentinel = Join-Path $outside 'sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'python') -Target $outside | Out-Null
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $junctionRoot -ArchivePath $archive -Json | Out-Null } 'managed-python-junction'
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'Junction rejection modified outside sentinel.' }
    Write-Host 'JUNCTION_SENTINEL_PRESERVED'

    Write-Host 'PORTABLE_PYTHON_BOOTSTRAP_REGRESSION_OK'
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
