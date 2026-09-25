Set-StrictMode -Version Latest

$script:VllmReleaseApiVersion = '2026-03-10'
$script:VllmResetPresenceConfirmAttempts = 4
$script:VllmResetPresenceConfirmDelayMilliseconds = 1000
# GitHub release-list state is eventually consistent immediately after create/edit/delete mutations.
$script:VllmReleaseReadAttempts = 12
$script:VllmReleaseReadDelayMilliseconds = 2000
$script:VllmReleaseAbsentConfirmReads = 2

function Assert-VllmPublicationToken {
    param([Parameter(Mandatory)][string]$Value,[Parameter(Mandatory)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '\s') { throw "$Label must be a non-empty token without whitespace." }
}

function Get-VllmReleaseOwnershipMarker {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit
    )
    Assert-VllmPublicationToken -Value $RepositorySlug -Label 'Repository slug'
    Assert-VllmPublicationToken -Value $Release -Label 'Release id'
    Assert-VllmPublicationToken -Value $Tag -Label 'Release tag'
    if ($ProjectCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Project commit must be a full 40-hex commit id.' }
    "<!-- vllm-windows-native-release-owner schema=1 repository=$RepositorySlug release=$Release tag=$Tag project_commit=$($ProjectCommit.ToLowerInvariant()) -->"
}
function Get-VllmReleaseDraftBody {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit
    )
    $marker=Get-VllmReleaseOwnershipMarker -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    $marker+[char]10+[char]10+'Guarded vLLM Windows Native release draft. Asset identity is verified by release.ps1 before publication.'
}

function Invoke-VllmPublicationGhCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [string]$Executable='gh'
    )
    if ($null -eq (Get-Command $Executable -ErrorAction SilentlyContinue)) { throw ($FailureLabel+': executable not found: '+$Executable) }
    $stderrPath=[IO.Path]::GetTempFileName()
    $oldErrorActionPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $stdout=@(& $Executable @Arguments 2> $stderrPath)
        $exitCode=$LASTEXITCODE
        $stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath).Trim()}else{''}
    } finally {
        $ErrorActionPreference=$oldErrorActionPreference
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    if($exitCode-ne0){
        $detail=if([string]::IsNullOrWhiteSpace($stderr)){('exit '+$exitCode)}else{$stderr}
        throw ($FailureLabel+': '+$detail)
    }
    $stdout -join [char]10
}

function Invoke-VllmPublicationGhJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [string]$Executable='gh'
    )
    $json=Invoke-VllmPublicationGhCommand -Arguments $Arguments -FailureLabel $FailureLabel -Executable $Executable
    try { $json | ConvertFrom-Json } catch { throw "$FailureLabel returned invalid JSON." }
}

function Get-VllmPublicationApiArguments {
    param([Parameter(Mandatory)][string]$Endpoint)
    @('api','-H','Accept: application/vnd.github+json','-H',('X-GitHub-Api-Version: '+$script:VllmReleaseApiVersion),$Endpoint)
}
function Assert-VllmGitHubReleaseImmutability {
    param([Parameter(Mandatory)][string]$RepositorySlug,[string]$GhExecutable='gh')
    try {
        $state=Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug/immutable-releases") -FailureLabel 'Unable to read GitHub immutable-release state' -Executable $GhExecutable
    } catch {
        if ($_.Exception.Message -match '(?i)HTTP 404') {
            throw 'Repository immutable releases are not enabled.'
        }
        throw
    }
    # GitHub documents disabled state as 404, but tolerate an explicit enabled=false
    # response as the same fail-closed precondition in case API behavior varies.
    if ($null -eq $state.PSObject.Properties['enabled'] -or $state.enabled -ne $true) {
        throw 'Repository immutable releases are not enabled.'
    }
    [pscustomobject][ordered]@{enabled=$true;enforced_by_owner=($state.enforced_by_owner -eq $true)}
}

function Assert-VllmGitHubMainCommit {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$ProjectCommit,[string]$GhExecutable='gh')
    $repo=Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug") -FailureLabel 'Unable to inspect GitHub repository' -Executable $GhExecutable
    if (-not ([string]$repo.default_branch).Equals('main',[StringComparison]::Ordinal)) { throw "GitHub default branch must be main, got '$($repo.default_branch)'." }
    $ref=Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug/git/ref/heads/main") -FailureLabel 'Unable to inspect GitHub main ref' -Executable $GhExecutable
    if (-not ([string]$ref.object.type).Equals('commit',[StringComparison]::Ordinal)) { throw 'GitHub main ref does not resolve directly to a commit.' }
    if (-not ([string]$ref.object.sha).Equals($ProjectCommit,[StringComparison]::OrdinalIgnoreCase)) { throw "GitHub main ref does not match the release project commit: $($ref.object.sha)" }
}

function Assert-VllmGitHubReleaseTagObject {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$ExpectedTagObject,[string]$GhExecutable='gh')
    $escaped=[Uri]::EscapeDataString($Tag)
    $ref=Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug/git/ref/tags/$escaped") -FailureLabel 'Unable to inspect remote release tag' -Executable $GhExecutable
    if (-not ([string]$ref.object.type).Equals('tag',[StringComparison]::Ordinal)) { throw 'Remote release tag must reference an annotated tag object.' }
    if (-not ([string]$ref.object.sha).Equals($ExpectedTagObject,[StringComparison]::OrdinalIgnoreCase)) { throw "Remote release tag object mismatch: expected $ExpectedTagObject, got $($ref.object.sha)" }
}
function Get-VllmReleasePublicationAssetPlan {
    param([Parameter(Mandatory)][string]$ArtifactsDirectory,[Parameter(Mandatory)]$OfflineVerification)
    $root=[IO.Path]::GetFullPath($ArtifactsDirectory)
    $digests=Get-VllmReleaseExpectedAssets -ArtifactsDirectory $root -OfflineVerification $OfflineVerification
    $plan=New-Object System.Collections.Generic.List[object]
    foreach($name in $digests.Keys){
        $path=Join-Path $root ([string]$name)
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Release publication asset must be a regular non-reparse file: $name"}
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $expected=[string]$digests[$name]
        if(-not$actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw "Release publication asset changed after offline verification: $name"}
        $plan.Add([pscustomobject][ordered]@{
            name=[string]$name
            path=$item.FullName
            size=[int64]$item.Length
            sha256=$expected.ToUpperInvariant()
        })
    }
    if($plan.Count-ne4){throw "Release publication requires exactly four assets, got $($plan.Count)."}
    @($plan)
}

function Assert-VllmReleasePublicationAssetStable {
    param([Parameter(Mandatory)]$Asset)
    $item=Get-Item -LiteralPath ([string]$Asset.path) -Force
    if($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Release publication asset is no longer a regular file: $($Asset.name)"}
    if([int64]$item.Length-ne[int64]$Asset.size){throw "Release publication asset size changed: $($Asset.name)"}
    $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    if(-not$hash.Equals([string]$Asset.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Release publication asset digest changed: $($Asset.name)"}
}
function Get-VllmGitHubReleaseByTagAnyState {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$Tag,[string]$GhExecutable='gh')
    $apiArguments=@(
        'api','--paginate','--slurp',
        '-H','Accept: application/vnd.github+json',
        '-H',('X-GitHub-Api-Version: '+$script:VllmReleaseApiVersion),
        "repos/$RepositorySlug/releases?per_page=100"
    )
    $pages=Invoke-VllmPublicationGhJson -Arguments $apiArguments -FailureLabel 'Unable to list GitHub releases' -Executable $GhExecutable
    $releaseMatches=New-Object System.Collections.Generic.List[object]
    foreach($page in @($pages)){
        foreach($release in @($page)){
            if(([string]$release.tag_name).Equals($Tag,[StringComparison]::Ordinal)){$releaseMatches.Add($release)}
        }
    }
    if($releaseMatches.Count-gt1){throw "GitHub returned multiple releases for tag '$Tag'."}
    if($releaseMatches.Count-eq0){return $null}
    $releaseMatches[0]
}

function Invoke-VllmGitHubReleaseReadConvergence {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [scriptblock]$Validate,
        [scriptblock]$Ready,
        [string]$GhExecutable='gh'
    )
    $repositorySlugValue=$RepositorySlug
    $tagValue=$Tag
    $validateValue=$Validate
    $readyValue=$Ready
    $ghExecutableValue=$GhExecutable
    for($attempt=1;$attempt-le$script:VllmReleaseReadAttempts;$attempt++){
        $candidate=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $repositorySlugValue -Tag $tagValue -GhExecutable $ghExecutableValue
        if($null-ne$candidate){
            if($null-ne$validateValue){$null=& $validateValue $candidate}
            $isReady=$true
            if($null-ne$readyValue){$isReady=[bool](& $readyValue $candidate)}
            if($isReady){return $candidate}
        }
        if($attempt-ge$script:VllmReleaseReadAttempts){
            if($null-eq$candidate){throw "GitHub release for tag '$tagValue' was not visible after $attempt attempts."}
            throw "GitHub release for tag '$tagValue' did not converge after $attempt attempts."
        }
        if($script:VllmReleaseReadDelayMilliseconds-gt0){Start-Sleep -Milliseconds $script:VllmReleaseReadDelayMilliseconds}
    }
}

function Assert-VllmGitHubReleaseAbsentConvergence {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [string]$GhExecutable='gh'
    )
    $repositorySlugValue=$RepositorySlug
    $tagValue=$Tag
    $ghExecutableValue=$GhExecutable
    $consecutiveAbsent=0
    for($attempt=1;$attempt-le$script:VllmReleaseReadAttempts;$attempt++){
        $candidate=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $repositorySlugValue -Tag $tagValue -GhExecutable $ghExecutableValue
        if($null-eq$candidate){
            $consecutiveAbsent++
            if($consecutiveAbsent-ge$script:VllmReleaseAbsentConfirmReads){return $true}
        }else{
            $consecutiveAbsent=0
        }
        if($attempt-ge$script:VllmReleaseReadAttempts){throw "GitHub release for tag '$tagValue' did not reach $($script:VllmReleaseAbsentConfirmReads) consecutive absent reads after $attempt attempts."}
        if($script:VllmReleaseReadDelayMilliseconds-gt0){Start-Sleep -Milliseconds $script:VllmReleaseReadDelayMilliseconds}
    }
    $true
}

function Assert-VllmReleaseOwnership {
    param(
        [Parameter(Mandatory)]$ReleaseObject,
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit
    )
    if(-not([string]$ReleaseObject.tag_name).Equals($Tag,[StringComparison]::Ordinal)){throw 'GitHub release tag identity mismatch.'}
    $expected=Get-VllmReleaseOwnershipMarker -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    $body=[string]$ReleaseObject.body
    $firstLine=if($body.Contains([char]10)){$body.Substring(0,$body.IndexOf([char]10))}else{$body}
    $firstLine=$firstLine.TrimEnd([char]13)
    if(-not$firstLine.Equals($expected,[StringComparison]::Ordinal)){throw 'GitHub release is not owned by this exact release transaction.'}

    $true
}
function Get-VllmRemoteReleaseAssetStatus {
    param(
        [Parameter(Mandatory)]$ReleaseObject,
        [Parameter(Mandatory)][object[]]$AssetPlan
    )
    $remote=@($ReleaseObject.assets)
    $seen=@{}
    $pending=New-Object System.Collections.Generic.List[string]
    foreach($asset in $remote){
        $name=[string]$asset.name
        $expected=@($AssetPlan|Where-Object{([string]$_.name).Equals($name,[StringComparison]::Ordinal)})
        if($expected.Count-ne1){throw "GitHub release contains an unexpected asset: $name"}
        if($seen.ContainsKey($name)){throw "GitHub release contains a duplicate asset: $name"}
        $seen[$name]=$true
        $want=$expected[0]
        $state=[string]$asset.state
        if(-not$state.Equals('uploaded',[StringComparison]::Ordinal)){
            if($state.Equals('starter',[StringComparison]::Ordinal)){
                $pending.Add($name)
                continue
            }
            throw "GitHub release asset has unexpected state '$state': $name"
        }
        if([int64]$asset.size-ne[int64]$want.size){throw "GitHub release asset size mismatch: $name"}
        $digest=[string]$asset.digest
        $expectedDigest='sha256:'+([string]$want.sha256).ToLowerInvariant()
        if(-not$digest.Equals($expectedDigest,[StringComparison]::OrdinalIgnoreCase)){throw "GitHub release asset digest mismatch: $name"}
    }
    $missing=@($AssetPlan|Where-Object{-not$seen.ContainsKey([string]$_.name)}|ForEach-Object{[string]$_.name})
    [pscustomobject][ordered]@{
        missing=[string[]]$missing
        pending=[string[]]@($pending)
    }
}

function Assert-VllmRemoteReleaseAssets {
    param(
        [Parameter(Mandatory)]$ReleaseObject,
        [Parameter(Mandatory)][object[]]$AssetPlan,
        [switch]$AllowMissing
    )
    $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $ReleaseObject -AssetPlan $AssetPlan
    if(@($status.pending).Count-ne0){throw "GitHub release asset is not fully uploaded: $($status.pending[0])"}
    if(-not$AllowMissing-and@($status.missing).Count-ne0){throw 'GitHub release asset set is incomplete.'}
    [string[]]@($status.missing)
}

function Assert-VllmPublicationRemotePrerequisites {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$TagObject,
        [string]$GhExecutable='gh'
    )
    $null=Assert-VllmGitHubReleaseImmutability -RepositorySlug $RepositorySlug -GhExecutable $GhExecutable
    Assert-VllmGitHubMainCommit -RepositorySlug $RepositorySlug -ProjectCommit $ProjectCommit -GhExecutable $GhExecutable
    Assert-VllmGitHubReleaseTagObject -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedTagObject $TagObject -GhExecutable $GhExecutable
}

function Invoke-VllmOwnedDraftReleaseCreation {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [string]$GhExecutable='gh'
    )
    $title="vLLM Windows Native $Release"
    $body=Get-VllmReleaseDraftBody -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    $null=Invoke-VllmPublicationGhCommand -Arguments @(
        'release','create',$Tag,'--repo',$RepositorySlug,'--draft','--prerelease',
        '--latest=false','--verify-tag','--title',$title,'--notes',$body
    ) -FailureLabel 'Unable to create guarded GitHub release draft' -Executable $GhExecutable
}
function Invoke-VllmStageGitHubRelease {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$TagObject,
        [Parameter(Mandatory)][object[]]$AssetPlan,
        [string]$GhExecutable='gh'
    )
    Assert-VllmPublicationRemotePrerequisites -RepositorySlug $RepositorySlug -ProjectCommit $ProjectCommit -Tag $Tag -TagObject $TagObject -GhExecutable $GhExecutable
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$remote){
        Invoke-VllmOwnedDraftReleaseCreation -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit -GhExecutable $GhExecutable
        $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    }
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){
        if($remote.immutable-ne$true){throw 'Published exact-match release is not immutable.'}
        $stagePublishedValidate={
            param($candidate)
            $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
            $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            $true
        }
        $stagePublishedReady={
            param($candidate)
            $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            ($candidate.draft-ne$true)-and($candidate.immutable-eq$true)-and(@($status.missing).Count-eq0)-and(@($status.pending).Count-eq0)
        }
        $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $stagePublishedValidate -Ready $stagePublishedReady
        return [pscustomobject][ordered]@{
            schema_version=1;component='vllm-windows-native-release-stage';state='published'
            release_id=[int64]$remote.id;url=[string]$remote.html_url;asset_count=@($remote.assets).Count
        }
    }
    if($remote.immutable-eq$true){throw 'Draft release unexpectedly reports immutable state.'}
    if($remote.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
    $preUploadValidate={
        param($candidate)
        $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
        if($candidate.draft-ne$true){throw 'GitHub release left draft state before asset upload.'}
        if($candidate.immutable-eq$true){throw 'Draft release unexpectedly reports immutable state before asset upload.'}
        if($candidate.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
        $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        $true
    }
    $preUploadReady={
        param($candidate)
        $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        @($status.pending).Count-eq0
    }
    $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $preUploadValidate -Ready $preUploadReady
    $assetStatus=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $remote -AssetPlan $AssetPlan
    $missing=@($assetStatus.missing)
    foreach($name in $missing){
        $asset=@($AssetPlan|Where-Object{([string]$_.name).Equals($name,[StringComparison]::Ordinal)})[0]
        Assert-VllmReleasePublicationAssetStable -Asset $asset
        $null=Invoke-VllmPublicationGhCommand -Arguments @('release','upload',$Tag,[string]$asset.path,'--repo',$RepositorySlug) -FailureLabel "Unable to upload GitHub release asset $name" -Executable $GhExecutable
        $uploadValidate={
            param($candidate)
            $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
            if($candidate.draft-ne$true){throw 'GitHub release left draft state during asset upload.'}
            if($candidate.prerelease-ne$true){throw 'GitHub release left prerelease state during asset upload.'}
            $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            $true
        }
        $uploadReady={
            param($candidate)
            $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            (@($status.missing) -notcontains $name)-and(@($status.pending) -notcontains $name)
        }
        $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $uploadValidate -Ready $uploadReady
    }
    $stageValidate={
        param($candidate)
        $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
        if($candidate.draft-ne$true){throw 'GitHub release left draft state before final stage verification.'}
        if($candidate.immutable-eq$true){throw 'Draft release unexpectedly reports immutable state before final stage verification.'}
        if($candidate.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
        $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        $true
    }
    $stageReady={
        param($candidate)
        $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        (@($status.missing).Count-eq0)-and(@($status.pending).Count-eq0)
    }
    $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $stageValidate -Ready $stageReady
    [pscustomobject][ordered]@{
        schema_version=1;component='vllm-windows-native-release-stage';state='draft'
        release_id=[int64]$remote.id;url=[string]$remote.html_url;asset_count=@($remote.assets).Count
    }
}
function Invoke-VllmPublishGitHubRelease {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$TagObject,
        [Parameter(Mandatory)][object[]]$AssetPlan,
        [string]$GhExecutable='gh'
    )
    Assert-VllmPublicationRemotePrerequisites -RepositorySlug $RepositorySlug -ProjectCommit $ProjectCommit -Tag $Tag -TagObject $TagObject -GhExecutable $GhExecutable
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$remote){throw 'No GitHub release draft exists for publication.'}
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){
        if($remote.immutable-ne$true){throw 'Published exact-match release is not immutable.'}
        $publishExistingValidate={
            param($candidate)
            $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
            $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            $true
        }
        $publishExistingReady={
            param($candidate)
            $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
            ($candidate.draft-ne$true)-and($candidate.immutable-eq$true)-and(@($status.missing).Count-eq0)-and(@($status.pending).Count-eq0)
        }
        $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $publishExistingValidate -Ready $publishExistingReady
        return [pscustomobject][ordered]@{
            schema_version=1;component='vllm-windows-native-release-publication';state='published'
            release_id=[int64]$remote.id;url=[string]$remote.html_url;asset_count=@($remote.assets).Count
        }
    }
    if($remote.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
    $publishDraftValidate={
        param($candidate)
        $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
        if($candidate.draft-ne$true){throw 'GitHub release left draft state before publication.'}
        if($candidate.immutable-eq$true){throw 'Draft release unexpectedly reports immutable state before publication.'}
        if($candidate.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
        $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        $true
    }
    $publishDraftReady={
        param($candidate)
        $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        (@($status.missing).Count-eq0)-and(@($status.pending).Count-eq0)
    }
    $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $publishDraftValidate -Ready $publishDraftReady
    foreach($asset in $AssetPlan){Assert-VllmReleasePublicationAssetStable -Asset $asset}

    # Re-prove GitHub state immediately before the irreversible draft -> published boundary.
    Assert-VllmPublicationRemotePrerequisites -RepositorySlug $RepositorySlug -ProjectCommit $ProjectCommit -Tag $Tag -TagObject $TagObject -GhExecutable $GhExecutable
    $remote=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $publishDraftValidate -Ready $publishDraftReady

    $null=Invoke-VllmPublicationGhCommand -Arguments @(
        'release','edit',$Tag,'--repo',$RepositorySlug,'--draft=false','--prerelease','--latest=false','--verify-tag'
    ) -FailureLabel 'Unable to publish guarded GitHub release draft' -Executable $GhExecutable
    $publishedValidate={
        param($candidate)
        $null=Assert-VllmReleaseOwnership -ReleaseObject $candidate -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
        if($candidate.prerelease-ne$true){throw 'Initial GitHub publication did not remain a prerelease.'}
        $null=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        $true
    }
    $publishedReady={
        param($candidate)
        $status=Get-VllmRemoteReleaseAssetStatus -ReleaseObject $candidate -AssetPlan $AssetPlan
        ($candidate.draft-ne$true)-and($candidate.immutable-eq$true)-and(@($status.missing).Count-eq0)-and(@($status.pending).Count-eq0)
    }
    $published=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable -Validate $publishedValidate -Ready $publishedReady
    [pscustomobject][ordered]@{
        schema_version=1;component='vllm-windows-native-release-publication';state='published'
        release_id=[int64]$published.id;url=[string]$published.html_url;asset_count=@($published.assets).Count
    }
}

function Get-VllmGitHubReleaseForReset {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [string]$GhExecutable='gh'
    )
    for($attempt=1;$attempt-le$script:VllmResetPresenceConfirmAttempts;$attempt++){
        $candidate=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
        if($null-ne$candidate){return $candidate}
        if($attempt-lt$script:VllmResetPresenceConfirmAttempts -and $script:VllmResetPresenceConfirmDelayMilliseconds-gt0){
            Start-Sleep -Milliseconds $script:VllmResetPresenceConfirmDelayMilliseconds
        }
    }
    $null
}

function Invoke-VllmResetOwnedDraftRelease {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [string]$GhExecutable='gh'
    )
    $remote=Get-VllmGitHubReleaseForReset -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$remote){
        return [pscustomobject][ordered]@{schema_version=1;component='vllm-windows-native-release-reset';state='absent'}
    }
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){throw 'Published releases are never reset or repaired by the release tooling.'}

    $id=[int64]$remote.id
    $apiArguments=@('api','-X','DELETE','-H','Accept: application/vnd.github+json','-H',('X-GitHub-Api-Version: '+$script:VllmReleaseApiVersion),"repos/$RepositorySlug/releases/$id")
    $null=Invoke-VllmPublicationGhCommand -Arguments $apiArguments -FailureLabel 'Unable to delete owned failed GitHub release draft' -Executable $GhExecutable
    $null=Assert-VllmGitHubReleaseAbsentConvergence -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    [pscustomobject][ordered]@{schema_version=1;component='vllm-windows-native-release-reset';state='reset';release_id=$id}
}
