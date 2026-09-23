[CmdletBinding()]
param(
    [ValidateSet('ValidateRepository','Prepare','Verify')][string]$Mode = 'ValidateRepository',
    [string]$ProjectCommit = 'HEAD',
    [string]$ReleaseManifestPath = 'manifests/release/v0.27.1-windows-x86_64.json',
    [string]$WheelPath = '',
    [string]$ArtifactsDirectory = 'artifacts/release',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-bundle.ps1')

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'release.ps1 supports native Windows x64 only.'
}

$repository = [IO.Path]::GetFullPath($PSScriptRoot)
$resolvedCommit = Resolve-VllmReleaseCommit -Repository $repository -Commit $ProjectCommit

function Resolve-ReleaseCliPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repository $Path))
}

function Write-ReleaseCliResult {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Marker,[switch]$AsJson)
    if ($AsJson) {
        $Result | ConvertTo-Json -Depth 10
    } else {
        Write-Host "$Marker release=$($Result.release) commit=$($Result.project_commit)"
        if ($Result.PSObject.Properties.Name -contains 'member_count') { Write-Host "Members: $($Result.member_count)" }
        if ($Result.PSObject.Properties.Name -contains 'bundle_sha256') { Write-Host "Bundle SHA-256: $($Result.bundle_sha256)" }
        if ($Result.PSObject.Properties.Name -contains 'index_sha256') { Write-Host "Index SHA-256:  $($Result.index_sha256)" }
    }
}

switch ($Mode) {
    'ValidateRepository' {
        $snapshot = Get-VllmReleaseGitSnapshot -Repository $repository -Commit $resolvedCommit
        try {
            $context = Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $ReleaseManifestPath
            $result = [pscustomobject][ordered]@{
                schema_version=1
                component='vllm-windows-native-release-repository-validation'
                release=[string]$context.Release.release
                tag=[string]$context.Tag
                project_commit=[string]$snapshot.Commit
                release_manifest_sha256=[string]$context.ReleaseManifest.Sha256
                runtime_manifest_sha256=[string]$context.RuntimeManifest.Sha256
                member_count=@($context.Members).Count
            }
        } finally { Close-VllmReleaseGitSnapshot -Snapshot $snapshot }
        Write-ReleaseCliResult -Result $result -Marker 'RELEASE_REPOSITORY_OK' -AsJson:$Json
    }
    'Prepare' {
        if ([string]::IsNullOrWhiteSpace($WheelPath)) { throw 'Prepare mode requires -WheelPath.' }
        $checkedOutHead = Resolve-VllmReleaseCommit -Repository $repository -Commit 'HEAD'
        if ($resolvedCommit -ne $checkedOutHead) { throw 'Prepare mode requires -ProjectCommit to resolve to the checked-out HEAD so preparation-tool provenance is truthful.' }
        $status = Invoke-Git -Repository $repository -Arguments @('status','--porcelain=v1','--untracked-files=all') -Capture
        if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'Prepare mode requires a clean project worktree.' }
        $wheel = Resolve-ReleaseCliPath -Path $WheelPath
        $output = Resolve-ReleaseCliPath -Path $ArtifactsDirectory
        $result = Write-VllmOfflineRelease -Repository $repository -ProjectCommit $resolvedCommit -ReleaseManifestPath $ReleaseManifestPath -WheelPath $wheel -ArtifactsDirectory $output
        Write-ReleaseCliResult -Result $result -Marker 'RELEASE_PREPARE_OK' -AsJson:$Json
    }
    'Verify' {
        $output = Resolve-ReleaseCliPath -Path $ArtifactsDirectory
        $result = Assert-VllmOfflineRelease -Repository $repository -ProjectCommit $resolvedCommit -ReleaseManifestPath $ReleaseManifestPath -ArtifactsDirectory $output
        Write-ReleaseCliResult -Result $result -Marker 'RELEASE_VERIFY_OK' -AsJson:$Json
    }
}
