[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/runtime/v0.27.1-rtx5090-sm120.json',
    [Parameter(Mandatory)] [string] $SourceDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
$manifest = Read-RuntimeManifest -ManifestPath $manifestResolved
$source = [System.IO.Path]::GetFullPath($SourceDir)
$patch = Resolve-ProjectPath -Path $manifest.accepted_delta.patch -BasePath $projectRoot

Write-Host "Manifest: $manifestResolved"
Write-Host "Source:   $source"
Write-Host "Upstream: $($manifest.upstream.commit) ($($manifest.upstream.tag))"

if (-not (Test-Path -LiteralPath $patch -PathType Leaf)) {
    throw "Patch not found: $patch"
}

$patchInfo = Get-Item -LiteralPath $patch
if ($patchInfo.Length -ne [int64]$manifest.accepted_delta.patch_size_bytes) {
    throw "Patch size mismatch. Expected $($manifest.accepted_delta.patch_size_bytes), got $($patchInfo.Length)."
}
$patchSha = Assert-FileSha256 -Path $patch -ExpectedSha256 $manifest.accepted_delta.patch_sha256
Write-Host "Patch:    $patchSha ($($patchInfo.Length) bytes)"

if (-not (Test-Path -LiteralPath $source)) {
    $parent = Split-Path -Parent $source
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Host "Cloning authoritative upstream..."
    & git -c core.longpaths=true -c core.autocrlf=false -c core.eol=lf clone --branch $manifest.upstream.tag --single-branch $manifest.upstream.repository $source
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }
}

if (-not (Test-Path -LiteralPath (Join-Path $source '.git'))) {
    throw "Source directory is not a Git working tree: $source"
}

# Artifact bytes must not depend on the caller's Windows Git line-ending policy.
# Keep tracked source files in Git-canonical LF form for every prepared build tree.
Invoke-Git -Repository $source -Arguments @('config','core.autocrlf','false') | Out-Null
Invoke-Git -Repository $source -Arguments @('config','core.eol','lf') | Out-Null

$status = Invoke-Git -Repository $source -Arguments @('status','--porcelain=v1') -Capture
$head = Invoke-Git -Repository $source -Arguments @('rev-parse','HEAD') -Capture
$headTree = Invoke-Git -Repository $source -Arguments @('rev-parse','HEAD^{tree}') -Capture
$acceptedTree = [string]$manifest.accepted_delta.tree
$upstreamCommit = [string]$manifest.upstream.commit

if (-not [string]::IsNullOrWhiteSpace($status)) {
    $indexTree = Invoke-Git -Repository $source -Arguments @('write-tree') -Capture
    if ($indexTree -eq $acceptedTree) {
        Materialize-GitTree -Repository $source -Tree $acceptedTree
        Write-Host "Source already contains the accepted staged tree: $acceptedTree"
        Write-Host 'PREPARE_SOURCE_OK'
        return
    }
    throw "Source working tree is not clean and does not match the accepted staged tree. Refusing to modify it.`n$status"
}

if ($headTree -eq $acceptedTree) {
    Materialize-GitTree -Repository $source -Tree $acceptedTree
    Write-Host "Source HEAD already has the accepted tree: $acceptedTree"
    Write-Host 'PREPARE_SOURCE_OK'
    return
}

if ($head -ne $upstreamCommit) {
    Write-Host "Fetching exact upstream commit $upstreamCommit..."
    & git -C $source -c core.longpaths=true fetch origin $upstreamCommit
    if ($LASTEXITCODE -ne 0) { throw "git fetch of upstream commit failed (exit $LASTEXITCODE)." }

    $status = Invoke-Git -Repository $source -Arguments @('status','--porcelain=v1') -Capture
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Source became dirty before checkout; refusing to continue.'
    }
    Invoke-Git -Repository $source -Arguments @('checkout','--detach',$upstreamCommit)
    $head = Invoke-Git -Repository $source -Arguments @('rev-parse','HEAD') -Capture
}

if ($head -ne $upstreamCommit) {
    throw "Source HEAD is not the required upstream commit. Expected $upstreamCommit, got $head."
}

# At this point the source is a verified-clean upstream checkout. Rewrite only
# tracked index entries using the canonical LF policy before applying the patch.
$upstreamTree = Invoke-Git -Repository $source -Arguments @('rev-parse',($upstreamCommit + '^{tree}')) -Capture
Materialize-GitTree -Repository $source -Tree $upstreamTree

Write-Host 'Checking patch applicability...'
& git -C $source -c core.longpaths=true apply --check --whitespace=nowarn $patch
if ($LASTEXITCODE -ne 0) { throw "Patch does not apply cleanly to upstream commit $upstreamCommit." }

Write-Host 'Applying accepted Windows patchset to index and worktree...'
& git -C $source -c core.longpaths=true apply --index --whitespace=nowarn $patch
if ($LASTEXITCODE -ne 0) { throw "git apply failed (exit $LASTEXITCODE)." }

$actualTree = Invoke-Git -Repository $source -Arguments @('write-tree') -Capture
if ($actualTree -ne $acceptedTree) {
    throw "Applied source tree mismatch. Expected $acceptedTree, got $actualTree."
}

Materialize-GitTree -Repository $source -Tree $actualTree
Write-Host "Accepted tree verified: $actualTree"
Write-Host 'PREPARE_SOURCE_OK'
