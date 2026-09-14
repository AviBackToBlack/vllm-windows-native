[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $repoRoot 'bootstrap-uv.ps1'
. (Join-Path $repoRoot 'scripts\common.ps1')
$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Test archive not found: $archive" }

function Test-ExpectedFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )
    try {
        & $Action
        throw "Expected failure did not occur: $Name"
    }
    catch {
        $message = $_.Exception.Message
        if ($message -eq "Expected failure did not occur: $Name") { throw }
        if ($message.IndexOf($ExpectedMessage, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Expected failure '$Name' to contain '$ExpectedMessage', got: $message"
        }
        Write-Host "REJECT $Name :: $message"
    }
}

function Invoke-TestBootstrap {
    param([Parameter(Mandatory)][string]$Root,[switch]$Force)
    $parameters = @{ InstallationRoot=$Root; ArchivePath=$archive; Json=$true }
    if ($Force) { $parameters.Force = $true }
    return ((& $bootstrap @parameters) | ConvertFrom-Json)
}

function Write-FixtureManifest {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$EntryCount,
        [Parameter(Mandatory)][string]$ManagedRelativePath,
        [string]$UvExecutable = 'uv.exe',
        [string[]]$RequiredFiles = @('uv.exe')
    )
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'manifests\bootstrap\uv-0.12.13-windows-x86_64.json') -Raw | ConvertFrom-Json
    $manifest.archive.name = [IO.Path]::GetFileName($Archive)
    $manifest.archive.url = 'https://invalid.example.test/not-used'
    $manifest.archive.sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    $manifest.archive.size_bytes = (Get-Item -LiteralPath $Archive).Length
    $manifest.archive.entry_count = $EntryCount
    $manifest.archive.required_files = @($RequiredFiles)
    $manifest.install.managed_relative_path = $ManagedRelativePath.Replace('\','/')
    $manifest.install.uv_executable = $UvExecutable.Replace('\','/')
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function Write-TestZipFixture {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Entries)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $zip.CreateEntry([string]$name)
                $writer = New-Object IO.StreamWriter($entry.Open(),[Text.UTF8Encoding]::new($false))
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }
    finally { $stream.Dispose() }
}
$base = Join-Path $env:TEMP ('vllm-portable-uv-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
try {
    $root = Join-Path $base 'valid'
    $result = Invoke-TestBootstrap -Root $root
    if (-not $result.ready) { throw 'Valid uv bootstrap did not report ready.' }
    if (-not (Test-Path -LiteralPath $result.uv -PathType Leaf)) { throw 'Materialized uv.exe is missing.' }
    if (@(Get-ChildItem -LiteralPath $result.root -Force -File).Count -ne 3) { throw 'Materialized uv file count mismatch.' }
    if (@(Get-ChildItem -LiteralPath $result.root -Force -Directory).Count -ne 0) { throw 'Materialized uv root contains unexpected directories.' }
    if (-not (Test-Path -LiteralPath $result.receipt -PathType Leaf)) { throw 'uv forensic receipt is missing.' }
    Write-Host 'VALID_UV_BOOTSTRAP_OK'

    $badUvManifest = Join-Path $base 'bad-uv-relative-manifest.json'
    [void](Write-FixtureManifest -Archive $archive -Path $badUvManifest -EntryCount 3 -ManagedRelativePath 'tools\uv\bad-relative' -UvExecutable '..\..\evil.exe' -RequiredFiles @('uv.exe','uvw.exe','uvx.exe'))
    Test-ExpectedFailure -Action { & $bootstrap -ManifestPath $badUvManifest -InstallationRoot (Join-Path $base 'bad-uv-relative-root') -ArchivePath $archive -Json | Out-Null } -Name 'uv-executable-traversal' -ExpectedMessage 'uv executable path contains an unsafe path segment'
    Write-Host 'UV_MANIFEST_RELATIVE_PATH_REJECTION_OK'

    $managedLeaf = [IO.Path]::GetFileName($result.root)
    $fileTargetRoot = Join-Path $base 'file-target-root'
    $fileTargetParent = Join-Path $fileTargetRoot 'tools\uv'
    [void][IO.Directory]::CreateDirectory($fileTargetParent)
    $fileTarget = Join-Path $fileTargetParent $managedLeaf
    Set-Content -LiteralPath $fileTarget -Value 'DO-NOT-DELETE' -Encoding ascii
    Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $fileTargetRoot -ArchivePath $archive -Force -Json | Out-Null } -Name 'managed-target-file' -ExpectedMessage 'exists but is not a directory'
    if ((Get-Content -LiteralPath $fileTarget -Raw).Trim() -ne 'DO-NOT-DELETE') { throw 'Managed uv target file changed.' }
    Write-Host 'UV_TARGET_FILE_PRESERVED'
    $receiptDirectoryRoot = Join-Path $base 'receipt-directory-root'
    $receiptDirectory = Join-Path $receiptDirectoryRoot ('forensic\' + [IO.Path]::GetFileName($result.receipt))
    [void][IO.Directory]::CreateDirectory($receiptDirectory)
    $receiptSentinel = Join-Path $receiptDirectory 'sentinel.txt'
    Set-Content -LiteralPath $receiptSentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $receiptDirectoryRoot -ArchivePath $archive -Json | Out-Null } -Name 'receipt-path-directory' -ExpectedMessage 'exists but is not a file'
    if ((Get-Content -LiteralPath $receiptSentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'uv receipt-directory rejection modified sentinel.' }
    Write-Host 'UV_RECEIPT_DIRECTORY_PRESERVED'

    $lockRoot = Join-Path $base 'lock-contention'
    $heldLock = Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'portable-uv-test-holder'
    try {
        Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $lockRoot -ArchivePath $archive -Json | Out-Null } -Name 'bootstrap-operation-lock-contention' -ExpectedMessage 'Another vLLM Windows Native lifecycle operation is active'
        if (Test-Path -LiteralPath (Join-Path $lockRoot 'tools\uv')) { throw 'Contended uv bootstrap created managed uv state.' }
    }
    finally { Exit-VllmOperationLock -Lock $heldLock }
    Write-Host 'UV_BOOTSTRAP_LOCK_CONTENTION_OK'

    Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $root -ArchivePath $archive -Json | Out-Null } -Name 'existing-target-without-force' -ExpectedMessage 'Managed uv target already exists'
    $marker = Join-Path $result.root 'replace-me.marker'
    Set-Content -LiteralPath $marker -Value 'old' -Encoding ascii
    $forced = Invoke-TestBootstrap -Root $root -Force
    if (Test-Path -LiteralPath $marker) { throw 'uv force replacement preserved stale target content.' }
    Write-Host 'UV_FORCE_REPLACEMENT_OK'

    $rollbackMarker = Join-Path $forced.root 'rollback-old.marker'
    Set-Content -LiteralPath $rollbackMarker -Value 'OLD-UV' -Encoding ascii
    $receiptBefore = Get-Content -LiteralPath $forced.receipt -Raw
    $receiptHandle = [IO.File]::Open($forced.receipt,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $root -ArchivePath $archive -Force -Json | Out-Null } -Name 'receipt-commit-rollback' -ExpectedMessage 'Cannot create a file'
    }
    finally { $receiptHandle.Dispose() }
    if (-not (Test-Path -LiteralPath $rollbackMarker -PathType Leaf)) { throw 'uv receipt failure did not restore the prior runtime.' }
    if ((Get-Content -LiteralPath $rollbackMarker -Raw).Trim() -ne 'OLD-UV') { throw 'uv receipt rollback restored wrong content.' }
    if ((Get-Content -LiteralPath $forced.receipt -Raw) -ne $receiptBefore) { throw 'uv receipt failure modified prior receipt.' }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $forced.root) -Directory -Filter '.backup-*' -Force).Count -ne 0) { throw 'uv receipt rollback left backup behind.' }
    Write-Host 'UV_RECEIPT_FAILURE_ROLLBACK_OK'
    $activationSource = Join-Path $base 'activation-source'
    [void][IO.Directory]::CreateDirectory($activationSource)
    $activationUv = Join-Path $activationSource 'uv.cmd'
    $activationBody = "@echo off`r`necho %~dp0 | findstr /I `"work\\uv-bootstrap\\stage-`" >nul`r`nif errorlevel 1 (`r`n  echo uv BROKEN`r`n) else (`r`n  echo uv 0.12.13 ^(0ebbd9274 fixture^)`r`n)`r`nexit /b 0`r`n"
    [IO.File]::WriteAllText($activationUv,$activationBody,[Text.ASCIIEncoding]::new())
    $activationArchive = Join-Path $base 'activation-failure.zip'
    & tar.exe -acf $activationArchive -C $activationSource 'uv.cmd'
    if ($LASTEXITCODE -ne 0) { throw "Failed to create uv activation fixture archive: $LASTEXITCODE" }
    $activationManifest = Join-Path $base 'activation-failure-manifest.json'
    [void](Write-FixtureManifest -Archive $activationArchive -Path $activationManifest -EntryCount 1 -ManagedRelativePath 'tools\uv\activation-fixture' -UvExecutable 'uv.cmd' -RequiredFiles @('uv.cmd'))
    $activationRoot = Join-Path $base 'activation-failure-root'
    $activationOldRoot = Join-Path $activationRoot 'tools\uv\activation-fixture'
    [void][IO.Directory]::CreateDirectory($activationOldRoot)
    $activationMarker = Join-Path $activationOldRoot 'old-runtime.marker'
    Set-Content -LiteralPath $activationMarker -Value 'OLD-ACTIVE-UV' -Encoding ascii
    Test-ExpectedFailure -Action { & $bootstrap -ManifestPath $activationManifest -InstallationRoot $activationRoot -ArchivePath $activationArchive -Force -Json | Out-Null } -Name 'activation-final-validation-rollback' -ExpectedMessage 'Activated uv runtime failed final validation'
    if ((Get-Content -LiteralPath $activationMarker -Raw).Trim() -ne 'OLD-ACTIVE-UV') { throw 'uv activation rollback did not restore prior runtime.' }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $activationOldRoot) -Directory -Filter '.backup-*' -Force).Count -ne 0) { throw 'uv activation rollback left backup behind.' }
    Write-Host 'UV_ACTIVATION_FAILURE_ROLLBACK_OK'

    $traversalZip = Join-Path $base 'malicious-traversal.zip'
    Write-TestZipFixture -Path $traversalZip -Entries @{ '../evil.exe'='x' }
    $traversalManifest = Join-Path $base 'malicious-traversal-manifest.json'
    [void](Write-FixtureManifest -Archive $traversalZip -Path $traversalManifest -EntryCount 1 -ManagedRelativePath 'tools\uv\malicious-traversal' -UvExecutable 'uv.exe' -RequiredFiles @('uv.exe'))
    Test-ExpectedFailure -Action { & $bootstrap -ManifestPath $traversalManifest -InstallationRoot (Join-Path $base 'malicious-traversal-root') -ArchivePath $traversalZip -Json | Out-Null } -Name 'archive-layout-traversal' -ExpectedMessage 'uv archive member contains an unsafe path segment'

    $unexpectedZip = Join-Path $base 'malicious-unexpected.zip'
    Write-TestZipFixture -Path $unexpectedZip -Entries @{ 'evil.exe'='x' }
    $unexpectedManifest = Join-Path $base 'malicious-unexpected-manifest.json'
    [void](Write-FixtureManifest -Archive $unexpectedZip -Path $unexpectedManifest -EntryCount 1 -ManagedRelativePath 'tools\uv\malicious-unexpected' -UvExecutable 'uv.exe' -RequiredFiles @('uv.exe'))
    Test-ExpectedFailure -Action { & $bootstrap -ManifestPath $unexpectedManifest -InstallationRoot (Join-Path $base 'malicious-unexpected-root') -ArchivePath $unexpectedZip -Json | Out-Null } -Name 'archive-layout-unexpected-member' -ExpectedMessage 'uv archive contains unexpected entry'
    Write-Host 'UV_ARCHIVE_LAYOUT_ADVERSARIAL_REJECTIONS_OK'
    $badArchive = Join-Path $base 'corrupt.zip'
    [IO.File]::WriteAllBytes($badArchive,[byte[]](1,2,3,4,5))
    Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot (Join-Path $base 'corrupt-root') -ArchivePath $badArchive -Json | Out-Null } -Name 'corrupt-archive' -ExpectedMessage 'does not match the pinned size/SHA-256'
    Write-Host 'UV_CORRUPT_ARCHIVE_REJECTED'

    $junctionRoot = Join-Path $base 'junction-root'
    $toolsRoot = Join-Path $junctionRoot 'tools'
    $outside = Join-Path $base 'outside-uv'
    [void][IO.Directory]::CreateDirectory($toolsRoot)
    [void][IO.Directory]::CreateDirectory($outside)
    $sentinel = Join-Path $outside 'sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    New-Item -ItemType Junction -Path (Join-Path $toolsRoot 'uv') -Target $outside | Out-Null
    Test-ExpectedFailure -Action { & $bootstrap -InstallationRoot $junctionRoot -ArchivePath $archive -Json | Out-Null } -Name 'managed-uv-junction' -ExpectedMessage 'resolves through a filesystem alias outside expected location'
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'uv junction rejection modified outside sentinel.' }
    Write-Host 'UV_JUNCTION_SENTINEL_PRESERVED'

    Write-Host 'PORTABLE_UV_BOOTSTRAP_REGRESSION_OK'
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}