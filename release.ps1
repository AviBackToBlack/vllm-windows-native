[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('ValidateRepository','Prepare','Verify','VerifySignedTag','VerifyPublished','StageDraft','PublishDraft','ResetDraft')][string]$Mode = 'ValidateRepository',
    [string]$ProjectCommit = 'HEAD',
    [string]$ReleaseManifestPath = 'manifests/release/v0.27.1-windows-x86_64.json',
    [string]$WheelPath = '',
    [string]$ArtifactsDirectory = 'artifacts/release',
    [string]$Tag = '',
    [string]$AllowedSignersPath = '',
    [string]$GhExecutable = 'gh',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-bundle.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-verification.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-publication.ps1')

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

function Assert-ReleasePublicationWorkingTree {
    $head=Resolve-VllmReleaseCommit -Repository $repository -Commit 'HEAD'
    if(-not$head.Equals($resolvedCommit,[StringComparison]::OrdinalIgnoreCase)){throw 'Release publication requires -ProjectCommit to resolve to checked-out HEAD.'}
    $branch=(Invoke-Git -Repository $repository -Arguments @('symbolic-ref','--quiet','--short','HEAD') -Capture).Trim()
    if(-not$branch.Equals('main',[StringComparison]::Ordinal)){throw "Release publication requires checked-out branch main, got '$branch'."}
    $status=Invoke-Git -Repository $repository -Arguments @('status','--porcelain=v1','--untracked-files=all') -Capture
    if(-not[string]::IsNullOrWhiteSpace($status)){throw 'Release publication requires a clean project worktree.'}
}

function Get-ReleasePublicationInputs {
    param([switch]$WithoutArtifacts)
    if(-not$WithoutArtifacts){Assert-ReleasePublicationWorkingTree}
    if([string]::IsNullOrWhiteSpace($AllowedSignersPath)){throw 'Release publication requires an explicitly supplied -AllowedSignersPath.'}
    $trustRoot=Resolve-ReleaseCliPath -Path $AllowedSignersPath
    if($WithoutArtifacts){
        $snapshot=Get-VllmReleaseGitSnapshot -Repository $repository -Commit $resolvedCommit
        try{$context=Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $ReleaseManifestPath}
        finally{Close-VllmReleaseGitSnapshot -Snapshot $snapshot}
        $releaseId=[string]$context.Release.release
        $expectedTag=[string]$context.Tag
        $offline=$null
        $assets=$null
    }else{
        $output=Resolve-ReleaseCliPath -Path $ArtifactsDirectory
        $offline=Assert-VllmOfflineRelease -Repository $repository -ProjectCommit $resolvedCommit -ReleaseManifestPath $ReleaseManifestPath -ArtifactsDirectory $output
        $releaseId=[string]$offline.release
        $expectedTag=[string]$offline.tag
        $assets=Get-VllmReleasePublicationAssetPlan -ArtifactsDirectory $output -OfflineVerification $offline
    }
    $effectiveTag=if([string]::IsNullOrWhiteSpace($Tag)){$expectedTag}else{$Tag}
    if(-not$effectiveTag.Equals($expectedTag,[StringComparison]::Ordinal)){throw 'Requested release tag does not match the canonical release identity.'}
    $signed=Assert-VllmReleaseSignedTag -Repository $repository -Tag $effectiveTag -ExpectedCommit $resolvedCommit -AllowedSignersPath $trustRoot
    [pscustomobject][ordered]@{
        release=$releaseId;tag=$effectiveTag;trust_root=$trustRoot;signed_tag=$signed
        offline=$offline;assets=$assets
        artifacts_directory=if($WithoutArtifacts){$null}else{$output}
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
    'VerifySignedTag' {
        if ([string]::IsNullOrWhiteSpace($Tag)) { throw 'VerifySignedTag mode requires -Tag.' }
        if ([string]::IsNullOrWhiteSpace($AllowedSignersPath)) { throw 'VerifySignedTag mode requires an explicitly supplied -AllowedSignersPath.' }
        $trustRoot = Resolve-ReleaseCliPath -Path $AllowedSignersPath
        $result = Assert-VllmReleaseSignedTag -Repository $repository -Tag $Tag -ExpectedCommit $resolvedCommit -AllowedSignersPath $trustRoot
        if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "RELEASE_SIGNED_TAG_OK tag=$($result.tag) commit=$($result.project_commit) principal=$($result.principal)" }
    }
    'VerifyPublished' {
        if ([string]::IsNullOrWhiteSpace($AllowedSignersPath)) { throw 'VerifyPublished mode requires an explicitly supplied -AllowedSignersPath.' }
        $output = Resolve-ReleaseCliPath -Path $ArtifactsDirectory
        $offline = Assert-VllmOfflineRelease -Repository $repository -ProjectCommit $resolvedCommit -ReleaseManifestPath $ReleaseManifestPath -ArtifactsDirectory $output
        $effectiveTag = if ([string]::IsNullOrWhiteSpace($Tag)) { [string]$offline.tag } else { $Tag }
        if (-not $effectiveTag.Equals([string]$offline.tag,[StringComparison]::Ordinal)) { throw 'Requested release tag does not match the verified release index.' }
        $trustRoot = Resolve-ReleaseCliPath -Path $AllowedSignersPath
        $tagVerification = Assert-VllmReleaseSignedTag -Repository $repository -Tag $effectiveTag -ExpectedCommit $resolvedCommit -AllowedSignersPath $trustRoot
        $assets = Get-VllmReleaseExpectedAssets -ArtifactsDirectory $output -OfflineVerification $offline
        $attestation = Invoke-VllmGitHubReleaseVerification -RepositorySlug $script:VllmReleaseRepository -Tag $effectiveTag -ExpectedTagObject $tagVerification.tag_object -ArtifactsDirectory $output -ExpectedAssets $assets -GhExecutable $GhExecutable
        $result = [pscustomobject][ordered]@{
            schema_version=1
            component='vllm-windows-native-published-release-verification'
            release=[string]$offline.release
            tag=$effectiveTag
            project_commit=[string]$offline.project_commit
            offline=$offline
            signed_tag=$tagVerification
            github_release=$attestation
        }
        Write-ReleaseCliResult -Result $result -Marker 'RELEASE_PUBLISHED_VERIFY_OK' -AsJson:$Json
    }
    'StageDraft' {
        $inputs=Get-ReleasePublicationInputs
        $target="$($script:VllmReleaseRepository) $($inputs.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Create/resume guarded draft prerelease and upload exact canonical assets')){return}
        $result=Invoke-VllmStageGitHubRelease -RepositorySlug $script:VllmReleaseRepository -Release $inputs.release -Tag $inputs.tag -ProjectCommit $resolvedCommit -TagObject $inputs.signed_tag.tag_object -AssetPlan $inputs.assets -GhExecutable $GhExecutable
        if($Json){$result|ConvertTo-Json -Depth 10}else{Write-Host "RELEASE_DRAFT_STAGE_OK state=$($result.state) release=$($inputs.release) tag=$($inputs.tag) assets=$($result.asset_count)"}
    }
    'PublishDraft' {
        $inputs=Get-ReleasePublicationInputs
        $target="$($script:VllmReleaseRepository) $($inputs.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Publish exact guarded draft as immutable prerelease')){return}
        $published=Invoke-VllmPublishGitHubRelease -RepositorySlug $script:VllmReleaseRepository -Release $inputs.release -Tag $inputs.tag -ProjectCommit $resolvedCommit -TagObject $inputs.signed_tag.tag_object -AssetPlan $inputs.assets -GhExecutable $GhExecutable
        $attestationAssets=Get-VllmReleaseExpectedAssets -ArtifactsDirectory $inputs.artifacts_directory -OfflineVerification $inputs.offline
        $attestation=Invoke-VllmGitHubReleaseVerification -RepositorySlug $script:VllmReleaseRepository -Tag $inputs.tag -ExpectedTagObject $inputs.signed_tag.tag_object -ArtifactsDirectory $inputs.artifacts_directory -ExpectedAssets $attestationAssets -GhExecutable $GhExecutable
        $result=[pscustomobject][ordered]@{
            schema_version=1;component='vllm-windows-native-release-publish-and-verify'
            release=$inputs.release;tag=$inputs.tag;project_commit=$resolvedCommit
            publication=$published;github_release=$attestation
        }
        if($Json){$result|ConvertTo-Json -Depth 12}else{Write-Host "RELEASE_PUBLISH_OK release=$($inputs.release) tag=$($inputs.tag) commit=$resolvedCommit"}
    }
    'ResetDraft' {
        $inputs=Get-ReleasePublicationInputs -WithoutArtifacts
        $target="$($script:VllmReleaseRepository) $($inputs.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Delete exact owned failed draft release')){return}
        $result=Invoke-VllmResetOwnedDraftRelease -RepositorySlug $script:VllmReleaseRepository -Release $inputs.release -Tag $inputs.tag -ProjectCommit $resolvedCommit -GhExecutable $GhExecutable
        if($Json){$result|ConvertTo-Json -Depth 10}else{Write-Host "RELEASE_DRAFT_RESET_OK state=$($result.state) release=$($inputs.release) tag=$($inputs.tag)"}
    }
}
