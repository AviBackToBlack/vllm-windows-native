Set-StrictMode -Version Latest

$script:VllmReleaseApiVersion = '2026-03-10'

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
    $state=Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug/immutable-releases") -FailureLabel 'Unable to read GitHub immutable-release state' -Executable $GhExecutable
    if ($null -eq $state.PSObject.Properties['enabled'] -or $state.enabled -ne $true) { throw 'Repository immutable releases must be enabled before any release mutation.' }
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
function Assert-VllmRemoteReleaseAssets {
    param(
        [Parameter(Mandatory)]$ReleaseObject,
        [Parameter(Mandatory)][object[]]$AssetPlan,
        [switch]$AllowMissing
    )
    $remote=@($ReleaseObject.assets)
    $seen=@{}
    foreach($asset in $remote){
        $name=[string]$asset.name
        $expected=@($AssetPlan|Where-Object{([string]$_.name).Equals($name,[StringComparison]::Ordinal)})
        if($expected.Count-ne1){throw "GitHub release contains an unexpected asset: $name"}
        if($seen.ContainsKey($name)){throw "GitHub release contains a duplicate asset: $name"}
        $seen[$name]=$true
        $want=$expected[0]
        if(-not([string]$asset.state).Equals('uploaded',[StringComparison]::Ordinal)){throw "GitHub release asset is not fully uploaded: $name"}
        if([int64]$asset.size-ne[int64]$want.size){throw "GitHub release asset size mismatch: $name"}
        $digest=[string]$asset.digest
        $expectedDigest='sha256:'+([string]$want.sha256).ToLowerInvariant()
        if(-not$digest.Equals($expectedDigest,[StringComparison]::OrdinalIgnoreCase)){throw "GitHub release asset digest mismatch: $name"}
    }
    $missing=@($AssetPlan|Where-Object{-not$seen.ContainsKey([string]$_.name)}|ForEach-Object{[string]$_.name})
    if(-not$AllowMissing-and$missing.Count-ne0){throw 'GitHub release asset set is incomplete.'}
    $missing
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
        $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
        if($null-eq$remote){throw 'Created GitHub release draft could not be rediscovered.'}
    }
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){
        $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan
        if($remote.immutable-ne$true){throw 'Published exact-match release is not immutable.'}
        return [pscustomobject][ordered]@{
            schema_version=1;component='vllm-windows-native-release-stage';state='published'
            release_id=[int64]$remote.id;url=[string]$remote.html_url;asset_count=@($remote.assets).Count
        }
    }
    if($remote.immutable-eq$true){throw 'Draft release unexpectedly reports immutable state.'}
    if($remote.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
    $missing=@(Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan -AllowMissing)
    foreach($name in $missing){
        $asset=@($AssetPlan|Where-Object{([string]$_.name).Equals($name,[StringComparison]::Ordinal)})[0]
        Assert-VllmReleasePublicationAssetStable -Asset $asset
        $null=Invoke-VllmPublicationGhCommand -Arguments @('release','upload',$Tag,[string]$asset.path,'--repo',$RepositorySlug) -FailureLabel "Unable to upload GitHub release asset $name" -Executable $GhExecutable
        $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
        $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
        if($remote.draft-ne$true){throw 'GitHub release left draft state during asset upload.'}
        if($remote.prerelease-ne$true){throw 'GitHub release left prerelease state during asset upload.'}
        $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan -AllowMissing
    }
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan
    if($remote.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
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
    $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan
    if($remote.draft-ne$true){
        if($remote.immutable-ne$true){throw 'Published exact-match release is not immutable.'}
        return [pscustomobject][ordered]@{
            schema_version=1;component='vllm-windows-native-release-publication';state='published'
            release_id=[int64]$remote.id;url=[string]$remote.html_url;asset_count=@($remote.assets).Count
        }
    }
    if($remote.prerelease-ne$true){throw 'Owned draft must remain a prerelease before publication.'}
    foreach($asset in $AssetPlan){Assert-VllmReleasePublicationAssetStable -Asset $asset}

    # Re-prove GitHub state immediately before the irreversible draft -> published boundary.
    Assert-VllmPublicationRemotePrerequisites -RepositorySlug $RepositorySlug -ProjectCommit $ProjectCommit -Tag $Tag -TagObject $TagObject -GhExecutable $GhExecutable
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$remote){throw 'GitHub release draft disappeared before publication.'}
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){throw 'GitHub release left draft state before publication.'}
    if($remote.prerelease-ne$true){throw 'GitHub release left prerelease state before publication.'}
    $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan $AssetPlan

    $null=Invoke-VllmPublicationGhCommand -Arguments @(
        'release','edit',$Tag,'--repo',$RepositorySlug,'--draft=false','--prerelease','--latest=false','--verify-tag'
    ) -FailureLabel 'Unable to publish guarded GitHub release draft' -Executable $GhExecutable
    $published=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$published){throw 'Published GitHub release could not be rediscovered.'}
    $null=Assert-VllmReleaseOwnership -ReleaseObject $published -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($published.draft-eq$true){throw 'GitHub release remained a draft after publication.'}
    if($published.prerelease-ne$true){throw 'Initial GitHub publication did not remain a prerelease.'}
    if($published.immutable-ne$true){throw 'Published GitHub release is not immutable.'}
    $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $published -AssetPlan $AssetPlan
    [pscustomobject][ordered]@{
        schema_version=1;component='vllm-windows-native-release-publication';state='published'
        release_id=[int64]$published.id;url=[string]$published.html_url;asset_count=@($published.assets).Count
    }
}

function Invoke-VllmResetOwnedDraftRelease {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Release,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [string]$GhExecutable='gh'
    )
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-eq$remote){
        return [pscustomobject][ordered]@{schema_version=1;component='vllm-windows-native-release-reset';state='absent'}
    }
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $RepositorySlug -Release $Release -Tag $Tag -ProjectCommit $ProjectCommit
    if($remote.draft-ne$true){throw 'Published releases are never reset or repaired by the release tooling.'}
    if($remote.prerelease-ne$true){throw 'Only an owned prerelease draft may be reset.'}
    $id=[int64]$remote.id
    $apiArguments=@('api','-X','DELETE','-H','Accept: application/vnd.github+json','-H',('X-GitHub-Api-Version: '+$script:VllmReleaseApiVersion),"repos/$RepositorySlug/releases/$id")
    $null=Invoke-VllmPublicationGhCommand -Arguments $apiArguments -FailureLabel 'Unable to delete owned failed GitHub release draft' -Executable $GhExecutable
    $after=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if($null-ne$after){throw 'Owned GitHub release draft still exists after reset.'}
    [pscustomobject][ordered]@{schema_version=1;component='vllm-windows-native-release-reset';state='reset';release_id=$id}
}
