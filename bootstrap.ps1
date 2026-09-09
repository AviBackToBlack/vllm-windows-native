[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/bootstrap/cusolver-12.0.4.66-windows-x86_64.json',
    [string] $CacheDir = '',
    [string] $DependenciesDir = '',
    [switch] $Refresh,
    [switch] $Force,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'bootstrap.ps1 currently supports native Windows x64 only.'
}

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) {
    throw "Bootstrap manifest not found: $manifestResolved"
}
$dependency = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json

if ([string]$dependency.component -ne 'libcusolver' -or [string]$dependency.platform -ne 'windows-x86_64') {
    throw "Unsupported bootstrap manifest: component=$($dependency.component), platform=$($dependency.platform)"
}

if ([string]::IsNullOrWhiteSpace($CacheDir)) {
    $CacheDir = Join-Path $projectRoot 'cache\downloads\nvidia'
}
if ([string]::IsNullOrWhiteSpace($DependenciesDir)) {
    $DependenciesDir = Resolve-ProjectPath -Path ([string]$dependency.install.managed_parent) -BasePath $projectRoot
}
$CacheDir = [IO.Path]::GetFullPath($CacheDir)
$DependenciesDir = [IO.Path]::GetFullPath($DependenciesDir)
New-Item -ItemType Directory -Force -Path $CacheDir,$DependenciesDir | Out-Null

$archiveName = [IO.Path]::GetFileName([string]$dependency.archive.relative_path)
$archivePath = Join-Path $CacheDir $archiveName
$expectedSize = [int64]$dependency.archive.size_bytes
$expectedSha = ([string]$dependency.archive.sha256).ToUpperInvariant()
$targetRoot = Join-Path $DependenciesDir ([string]$dependency.archive.extraction_root)
$requiredFiles = @($dependency.archive.required_files | ForEach-Object { ([string]$_).Replace('/','\') })

function Test-DependencyRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { return $false }
    }
    return $true
}

function Test-CachedArchive {
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $archivePath
    if ($item.Length -ne $expectedSize) { return $false }
    return ((Get-FileSha256 -Path $archivePath) -eq $expectedSha)
}

$downloaded = $false
$reusedCache = $false
$reusedInstall = $false
$targetValid = Test-DependencyRoot -Root $targetRoot

if ($targetValid -and -not $Force -and -not $Refresh) {
    $reusedInstall = $true
} else {
    if ((Test-Path -LiteralPath $targetRoot) -and -not $targetValid -and -not $Force -and -not $Refresh) {
        throw "Managed cuSOLVER root exists but is incomplete: $targetRoot. Re-run with -Force to replace it."
    }

    $cacheValid = (Test-CachedArchive)
    if ($Refresh -or -not $cacheValid) {
        $partial = "$archivePath.partial.$([guid]::NewGuid().ToString('N'))"
        try {
            Invoke-WebRequest -Uri ([string]$dependency.archive.url) -OutFile $partial -MaximumRetryCount 3 -RetryIntervalSec 2
            $item = Get-Item -LiteralPath $partial
            if ($item.Length -ne $expectedSize) {
                throw "Downloaded cuSOLVER archive size mismatch. Expected $expectedSize, got $($item.Length)."
            }
            $actualSha = Get-FileSha256 -Path $partial
            if ($actualSha -ne $expectedSha) {
                throw "Downloaded cuSOLVER SHA-256 mismatch. Expected $expectedSha, got $actualSha."
            }
            Move-Item -LiteralPath $partial -Destination $archivePath -Force
            $downloaded = $true
        }
        finally {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    } else {
        $reusedCache = $true
    }

    $archiveItem = Get-Item -LiteralPath $archivePath
    if ($archiveItem.Length -ne $expectedSize) { throw 'Cached cuSOLVER archive size changed after validation.' }
    Assert-FileSha256 -Path $archivePath -ExpectedSha256 $expectedSha | Out-Null

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw 'tar.exe is required to extract the NVIDIA cuSOLVER archive.' }
    $tempRoot = Join-Path $DependenciesDir ('.extract-' + [guid]::NewGuid().ToString('N'))
    $backupRoot = $null
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        & $tar.Source -xf $archivePath -C $tempRoot
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)." }
        $materialized = Join-Path $tempRoot ([string]$dependency.archive.extraction_root)
        if (-not (Test-DependencyRoot -Root $materialized)) {
            throw "Extracted cuSOLVER archive is missing required files under $materialized"
        }

        if (Test-Path -LiteralPath $targetRoot) {
            $backupRoot = Join-Path $DependenciesDir ('.backup-' + [string]$dependency.archive.extraction_root + '-' + [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $targetRoot -Destination $backupRoot
        }
        try {
            Move-Item -LiteralPath $materialized -Destination $targetRoot
        }
        catch {
            if ($backupRoot -and (Test-Path -LiteralPath $backupRoot) -and -not (Test-Path -LiteralPath $targetRoot)) {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
            }
            throw
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-DependencyRoot -Root $targetRoot)) {
    throw "cuSOLVER bootstrap did not produce a valid dependency root: $targetRoot"
}

$result = [ordered]@{
    schema_version = 1
    component = [string]$dependency.component
    version = [string]$dependency.version
    ready = $true
    root = $targetRoot
    archive = $archivePath
    sha256 = $expectedSha
    size_bytes = $expectedSize
    downloaded = $downloaded
    reused_cache = $reusedCache
    reused_install = $reusedInstall
    manifest = $manifestResolved
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Host "cuSOLVER $($dependency.version) ready"
    Write-Host "Root:    $targetRoot"
    Write-Host "Archive: $archivePath"
    Write-Host "SHA256:  $expectedSha"
    Write-Host "Use:     `$env:VLLM_CUSOLVER_ROOT='$targetRoot'"
    Write-Host 'BOOTSTRAP_CUSOLVER_READY'
}