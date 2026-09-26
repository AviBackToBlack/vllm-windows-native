Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-bundle.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-verification.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-publication.ps1')
$script:VllmReleaseReadAttempts=5
$script:VllmReleaseReadDelayMilliseconds=0
$script:VllmResetPresenceConfirmAttempts=4
$script:VllmResetPresenceConfirmDelayMilliseconds=0


function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $caught=$null
    try{& $Action}catch{$caught=$_.Exception.Message}
    if($null-eq$caught){throw "Expected failure containing: $Contains"}
    if($caught.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure: $caught"}
}

Assert-Fails {
    Invoke-VllmPublicationGhCommand -Arguments @('--version') -FailureLabel 'fake gh launch' -Executable 'definitely-not-a-vllm-gh-command'
} 'executable not found'

$missingGhMessage=$null
try {
    $null=Assert-VllmGitHubReleaseImmutability -RepositorySlug 'AviBackToBlack/vllm-windows-native' -GhExecutable 'definitely-not-a-vllm-gh-command'
} catch {
    $missingGhMessage=$_.Exception.Message
}
if($null-eq$missingGhMessage){throw 'Missing gh immutability preflight unexpectedly succeeded.'}
if($missingGhMessage.IndexOf('executable not found',[StringComparison]::OrdinalIgnoreCase)-lt0){
    throw "Missing gh immutability preflight lost the executable diagnostic: $missingGhMessage"
}
if($missingGhMessage.IndexOf('immutable releases are not enabled',[StringComparison]::OrdinalIgnoreCase)-ge0){
    throw "Missing gh immutability preflight was incorrectly remapped to repository configuration: $missingGhMessage"
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm19c-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $repoSlug='AviBackToBlack/vllm-windows-native'
    $releaseId='v0.27.1-native-windows-single-gpu-sm120-nvfp4'
    $tag='release/v0.27.1-native-windows-single-gpu-sm120-nvfp4'
    $commit='1111111111111111111111111111111111111111'
    $tagObject='2222222222222222222222222222222222222222'
    $script:FakeImmutableMode='404'
    $script:FakeMain=$commit
    $script:FakeTagObject=$tagObject
    $script:FakeMainReadCount=0
    $script:FakeChangeMainOnRead=0
    $script:FakeReleaseReadCount=0
    $script:FakePublishOnReleaseRead=0
    $script:FakeCreateVisibilityLagReads=0
    $script:FakeReleaseInvisibleReadsRemaining=0
    $script:FakePublishVisibilityLagReads=0
    $script:FakePublishVisibilityReadsRemaining=0
    $script:FakePendingPublish=$false
    $script:FakeDeleteVisibilityLagReads=0
    $script:FakeDeleteVisibilityReadsRemaining=0
    $script:FakeDeletedRelease=$null
    $script:FakeAssetFieldLagReads=0
    $script:FakeAssetFieldLagReadsRemaining=0
    $script:FakeAssetLagName=$null
    $script:FakePublishedAssetLagReads=0
    $script:FakePublishedAssetLagReadsRemaining=0
    $script:FakeRelease=$null
    $script:FakeNextReleaseId=7001
    $script:FakeCommands=New-Object System.Collections.Generic.List[string]

    $assetPlan=New-Object System.Collections.Generic.List[object]
    foreach($name in @('wheel.whl','vllm-windows-native-test.zip','release-index.json','SHA256SUMS')){
        $path=Join-Path $root $name
        [IO.File]::WriteAllText($path,('fixture-'+$name),[Text.UTF8Encoding]::new($false))
        $item=Get-Item -LiteralPath $path
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $assetPlan.Add([pscustomobject][ordered]@{name=$name;path=$path;size=[int64]$item.Length;sha256=$hash})
    }
    function Get-FakeReleaseObject {
        param([string]$Body,[bool]$Draft=$true)
        [pscustomobject][ordered]@{
            id=$script:FakeNextReleaseId
            html_url='https://example.invalid/release'
            tag_name=$tag
            body=$Body
            draft=$Draft
            prerelease=$true
            immutable=(!$Draft)
            assets=@()
        }
    }

    function Invoke-VllmPublicationGhCommand {
        param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$FailureLabel,[string]$Executable='gh')
        $null=$FailureLabel
        $null=$Executable
        $script:FakeCommands.Add(($Arguments -join ' '))
        if($Arguments[0]-eq'api'){
            $joined=$Arguments -join ' '
            if($joined.Contains("/immutable-releases")){
                if($script:FakeImmutableMode-eq'404'){throw 'Unable to read GitHub immutable-release state: gh: Not Found (HTTP 404)'}
                if($script:FakeImmutableMode-eq'false'){return (@{enabled=$false;enforced_by_owner=$false}|ConvertTo-Json -Compress)}
                return (@{enabled=$true;enforced_by_owner=$false}|ConvertTo-Json -Compress)
            }
            if($joined.Contains('/git/ref/heads/main')){
                $script:FakeMainReadCount++
                $mainSha=if($script:FakeChangeMainOnRead-gt0-and$script:FakeMainReadCount-ge$script:FakeChangeMainOnRead){'5555555555555555555555555555555555555555'}else{$script:FakeMain}
                return (@{ref='refs/heads/main';object=@{type='commit';sha=$mainSha}}|ConvertTo-Json -Depth 4 -Compress)
            }
            if($joined.Contains('/git/ref/tags/')){
                return (@{ref=('refs/tags/'+$tag);object=@{type='tag';sha=$script:FakeTagObject}}|ConvertTo-Json -Depth 4 -Compress)
            }
            if($joined -match 'repos/.+/releases\?per_page=100'){
                $script:FakeReleaseReadCount++
                if($null-eq$script:FakeRelease-and$null-ne$script:FakeDeletedRelease){
                    if($script:FakeDeleteVisibilityReadsRemaining-gt0){
                        $script:FakeDeleteVisibilityReadsRemaining--
                        return '[['+($script:FakeDeletedRelease|ConvertTo-Json -Depth 8 -Compress)+']]'
                    }
                    $script:FakeDeletedRelease=$null
                }
                if($null-ne$script:FakeRelease-and$script:FakeReleaseInvisibleReadsRemaining-gt0){
                    $script:FakeReleaseInvisibleReadsRemaining--
                    return '[[]]'
                }
                if($null-ne$script:FakeRelease-and$script:FakePendingPublish){
                    if($script:FakePublishVisibilityReadsRemaining-gt0){
                        $script:FakePublishVisibilityReadsRemaining--
                    }else{
                        $script:FakeRelease.draft=$false
                        $script:FakeRelease.prerelease=$true
                        $script:FakeRelease.immutable=$true
                        $script:FakePendingPublish=$false
                    }
                }
                if($null-ne$script:FakeRelease-and$script:FakePublishOnReleaseRead-gt0-and$script:FakeReleaseReadCount-ge$script:FakePublishOnReleaseRead){
                    $script:FakeRelease.draft=$false
                    $script:FakeRelease.immutable=$true
                }
                if($null-eq$script:FakeRelease){return '[[]]'}
                if($script:FakeAssetFieldLagReadsRemaining-gt0-and-not[string]::IsNullOrWhiteSpace([string]$script:FakeAssetLagName)){
                    $lagged=($script:FakeRelease|ConvertTo-Json -Depth 8|ConvertFrom-Json)
                    $laggedAsset=@($lagged.assets|Where-Object{$_.name-eq$script:FakeAssetLagName})
                    if($laggedAsset.Count-eq1){
                        $laggedAsset[0].state='starter'
                        $laggedAsset[0].size=0
                        $laggedAsset[0].digest=$null
                    }
                    $script:FakeAssetFieldLagReadsRemaining--
                    return '[['+($lagged|ConvertTo-Json -Depth 8 -Compress)+']]'
                }
                if($script:FakeRelease.draft-ne$true-and$script:FakePublishedAssetLagReadsRemaining-gt0){
                    $lagged=($script:FakeRelease|ConvertTo-Json -Depth 8|ConvertFrom-Json)
                    $allAssets=@($lagged.assets)
                    if($allAssets.Count-gt0){$lagged.assets=@($allAssets|Select-Object -First ($allAssets.Count-1))}
                    $script:FakePublishedAssetLagReadsRemaining--
                    return '[['+($lagged|ConvertTo-Json -Depth 8 -Compress)+']]'
                }
                return '[['+($script:FakeRelease|ConvertTo-Json -Depth 8 -Compress)+']]'
            }
            if($joined -match 'repos/.+$' -and -not$joined.Contains('/releases/')){
                return (@{default_branch='main'}|ConvertTo-Json -Compress)
            }
            if($joined.Contains(' -X DELETE ') -or ($Arguments -contains 'DELETE')){
                if($script:FakeDeleteVisibilityLagReads-gt0){
                    $script:FakeDeletedRelease=$script:FakeRelease
                    $script:FakeDeleteVisibilityReadsRemaining=$script:FakeDeleteVisibilityLagReads
                }else{
                    $script:FakeDeletedRelease=$null
                    $script:FakeDeleteVisibilityReadsRemaining=0
                }
                $script:FakeRelease=$null
                return ''
            }
            throw "Unhandled fake gh api command: $joined"
        }
        if($Arguments[0]-eq'release' -and $Arguments[1]-eq'create'){
            if($null-ne$script:FakeRelease){throw 'fake duplicate release'}
            $notesIndex=[Array]::IndexOf($Arguments,'--notes')
            if($notesIndex-lt0){throw 'fake create missing notes'}
            $script:FakeRelease=Get-FakeReleaseObject -Body $Arguments[$notesIndex+1] -Draft $true
            $script:FakeReleaseInvisibleReadsRemaining=$script:FakeCreateVisibilityLagReads
            $script:FakeNextReleaseId++
            return 'https://example.invalid/release'
        }
        if($Arguments[0]-eq'release' -and $Arguments[1]-eq'upload'){
            if($null-eq$script:FakeRelease -or $script:FakeRelease.draft-ne$true){throw 'fake upload requires draft'}
            $path=[string]$Arguments[3]
            $item=Get-Item -LiteralPath $path
            $name=$item.Name
            if(@($script:FakeRelease.assets|Where-Object{$_.name-eq$name}).Count){throw 'fake duplicate asset'}
            $digest='sha256:'+((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())
            $script:FakeRelease.assets=@($script:FakeRelease.assets)+[pscustomobject][ordered]@{
                name=$name;size=[int64]$item.Length;digest=$digest;state='uploaded'
            }
            $script:FakeAssetLagName=$name
            $script:FakeAssetFieldLagReadsRemaining=$script:FakeAssetFieldLagReads
            return ''
        }
        if($Arguments[0]-eq'release' -and $Arguments[1]-eq'edit'){
            $script:FakePublishedAssetLagReadsRemaining=$script:FakePublishedAssetLagReads
            if($null-eq$script:FakeRelease){throw 'fake edit missing release'}
            if($script:FakePublishVisibilityLagReads-gt0){
                $script:FakePendingPublish=$true
                $script:FakePublishVisibilityReadsRemaining=$script:FakePublishVisibilityLagReads
            }else{
                $script:FakeRelease.draft=$false
                $script:FakeRelease.prerelease=$true
                $script:FakeRelease.immutable=$true
            }
            return ''
        }
        throw "Unhandled fake gh command: $($Arguments -join ' ')"
    }
    $plan=[object[]]$assetPlan
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'immutable releases are not enabled'
    if(@($script:FakeCommands|Where-Object{$_ -like 'release create*'}).Count-ne0){throw 'Disabled immutability reached release creation.'}

    $script:FakeImmutableMode='false'
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'immutable releases are not enabled'
    if(@($script:FakeCommands|Where-Object{$_ -like 'release create*'}).Count-ne0){throw 'Explicit enabled=false reached release creation.'}

    $script:FakeImmutableMode='true'
    $script:FakeCommands.Clear()
    $script:FakeCreateVisibilityLagReads=2
    $script:FakeAssetFieldLagReads=2
    $stage=Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    $script:FakeAssetFieldLagReads=0
    $script:FakeCreateVisibilityLagReads=0
    if($stage.state-ne'draft' -or $stage.asset_count-ne4){throw 'Fresh draft staging did not produce exact four-asset draft.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release create*'}).Count-ne1){throw 'Fresh staging did not create exactly one draft.'}
    $createCommand=[string]@($script:FakeCommands|Where-Object{$_ -like 'release create*'})[0]
    foreach($flag in @('--draft','--prerelease','--latest=false','--verify-tag')){
        if($createCommand.IndexOf($flag,[StringComparison]::Ordinal)-lt0){throw "Fresh staging create command is missing required flag: $flag"}
    }
    if(@($script:FakeCommands|Where-Object{$_ -like 'release upload*'}).Count-ne4){throw 'Fresh staging did not upload exactly four assets.'}
    if(@($script:FakeCommands|Where-Object{$_ -like '*--clobber*'}).Count-ne0){throw 'Fresh staging unexpectedly used --clobber.'}
    $expectedMarker=Get-VllmReleaseOwnershipMarker -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit
    if(-not([string]$script:FakeRelease.body).StartsWith($expectedMarker,[StringComparison]::Ordinal)){throw 'Draft ownership marker mismatch.'}

    $script:FakeReleaseReadCount=0
    Assert-Fails {
        Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $repoSlug -Tag $tag -Validate { param($candidate) $null=$candidate; throw 'permanent convergence validation' }
    } 'permanent convergence validation'
    if($script:FakeReleaseReadCount-ne1){throw 'Permanent convergence validation was retried.'}

    $savedRelease=$script:FakeRelease
    $script:FakeRelease=$null
    $script:FakeReleaseReadCount=0
    Assert-Fails {
        $null=Invoke-VllmGitHubReleaseReadConvergence -RepositorySlug $repoSlug -Tag $tag
    } 'after 5 attempts'
    if($script:FakeReleaseReadCount-ne$script:VllmReleaseReadAttempts){throw 'Release convergence exhaustion did not consume exactly the configured attempt budget.'}
    $script:FakeRelease=$savedRelease



    $script:FakeCommands.Clear()
    $retry=Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    if($retry.state-ne'draft'){throw 'Exact draft retry changed state.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release create*' -or $_ -like 'release upload*'}).Count-ne0){throw 'Exact draft retry mutated remote state.'}

    $script:FakeReleaseReadCount=0
    $script:FakePublishOnReleaseRead=2
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'left draft state'
    $script:FakePublishOnReleaseRead=0
    $script:FakeReleaseReadCount=0
    $script:FakeRelease.draft=$true
    $script:FakeRelease.immutable=$false

    $savedAssets=@($script:FakeRelease.assets)
    $script:FakeRelease.assets=@($savedAssets|Select-Object -First 3)
    $script:FakeCommands.Clear()
    $resume=Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    if($resume.asset_count-ne4){throw 'Missing-asset resume did not restore exact asset set.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release upload*'}).Count-ne1){throw 'Missing-asset resume did not upload exactly one asset.'}

    $script:FakeRelease.assets=@($script:FakeRelease.assets)+[pscustomobject][ordered]@{
        name='unexpected.bin';size=1;digest=('sha256:'+('a'*64));state='uploaded'
    }
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'unexpected asset'
    $script:FakeRelease.assets=@($script:FakeRelease.assets|Where-Object{$_.name-ne'unexpected.bin'})
    $originalDigest=[string]$script:FakeRelease.assets[0].digest
    $script:FakeRelease.assets[0].digest='sha256:'+('0'*64)
    $script:FakeReleaseReadCount=0
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'digest mismatch'
    if($script:FakeReleaseReadCount-ne2){throw 'Permanent uploaded-asset digest mismatch was retried.'}
    $script:FakeRelease.assets[0].digest=$originalDigest

    $originalState=[string]$script:FakeRelease.assets[0].state
    $script:FakeRelease.assets[0].state='mystery'
    $script:FakeReleaseReadCount=0
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'unexpected state'
    if($script:FakeReleaseReadCount-ne2){throw 'Unknown release-asset state was retried.'}
    $script:FakeRelease.assets[0].state=$originalState

    $savedBody=[string]$script:FakeRelease.body
    $script:FakeRelease.body='foreign draft'
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'not owned'
    $script:FakeRelease.body=$savedBody

    $savedMain=$script:FakeMain
    $script:FakeMain='3333333333333333333333333333333333333333'
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'main ref does not match'
    $script:FakeMain=$savedMain

    $savedTag=$script:FakeTagObject
    $script:FakeTagObject='4444444444444444444444444444444444444444'
    Assert-Fails {
        Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'tag object mismatch'
    $script:FakeTagObject=$savedTag

    $script:FakeMainReadCount=0
    $script:FakeChangeMainOnRead=2
    $script:FakeCommands.Clear()
    Assert-Fails {
        Invoke-VllmPublishGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    } 'main ref does not match'
    if(@($script:FakeCommands|Where-Object{$_ -like 'release edit*'}).Count-ne0){throw 'Final pre-publication preflight allowed mutation after remote main changed.'}
    $script:FakeChangeMainOnRead=0
    $script:FakeMainReadCount=0

    $script:FakeCommands.Clear()
    $script:FakePublishVisibilityLagReads=2
    $script:FakePublishedAssetLagReads=2
    $published=Invoke-VllmPublishGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    $script:FakePublishedAssetLagReads=0
    $script:FakePublishVisibilityLagReads=0
    if($published.state-ne'published' -or $script:FakeRelease.draft-ne$false -or $script:FakeRelease.immutable-ne$true){throw 'Publication did not cross immutable boundary.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release edit*'}).Count-ne1){throw 'Publication did not perform exactly one release edit.'}
    $editCommand=[string]@($script:FakeCommands|Where-Object{$_ -like 'release edit*'})[0]
    foreach($flag in @('--draft=false','--prerelease','--latest=false','--verify-tag')){
        if($editCommand.IndexOf($flag,[StringComparison]::Ordinal)-lt0){throw "Publication edit command is missing required flag: $flag"}
    }

    $script:FakeCommands.Clear()
    $publishedRetry=Invoke-VllmPublishGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    if($publishedRetry.state-ne'published'){throw 'Published exact-match retry failed.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release edit*'}).Count-ne0){throw 'Published exact-match retry mutated release.'}

    Assert-Fails {
        Invoke-VllmResetOwnedDraftRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit
    } 'never reset'

    $script:FakeRelease.prerelease=$false
    $script:FakeCommands.Clear()
    $promotedStage=Invoke-VllmStageGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    $promotedPublish=Invoke-VllmPublishGitHubRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit -TagObject $tagObject -AssetPlan $plan
    if($promotedStage.state-ne'published' -or $promotedPublish.state-ne'published'){throw 'Promoted exact release was not treated as idempotently complete.'}
    if(@($script:FakeCommands|Where-Object{$_ -like 'release edit*' -or $_ -like 'release upload*' -or $_ -like 'release create*'}).Count-ne0){throw 'Promoted exact release retry mutated release.'}
    Assert-Fails {
        Invoke-VllmResetOwnedDraftRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit
    } 'never reset'

    $script:FakeRelease=Get-FakeReleaseObject -Body (Get-VllmReleaseDraftBody -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit) -Draft $true
    $script:FakeRelease.prerelease=$false
    $script:FakeReleaseInvisibleReadsRemaining=2
    $script:FakeDeleteVisibilityLagReads=2
    $reset=Invoke-VllmResetOwnedDraftRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit
    $script:FakeDeleteVisibilityLagReads=0
    if($null-ne$script:FakeDeletedRelease){throw 'Owned draft reset did not converge to remote absence.'}
    if($reset.state-ne'reset' -or $null-ne$script:FakeRelease){throw 'Owned draft reset failed.'}

    $script:FakeReleaseReadCount=0
    $null=Assert-VllmGitHubReleaseAbsentConvergence -RepositorySlug $repoSlug -Tag $tag
    if($script:FakeReleaseReadCount-ne$script:VllmReleaseAbsentConfirmReads){throw 'Post-delete absence did not require consecutive absent reads.'}

    $script:FakeReleaseReadCount=0
    $absent=Invoke-VllmResetOwnedDraftRelease -RepositorySlug $repoSlug -Release $releaseId -Tag $tag -ProjectCommit $commit
    if($absent.state-ne'absent'){throw 'Absent reset was not idempotent.'}
    if($script:FakeReleaseReadCount-ne$script:VllmResetPresenceConfirmAttempts){throw 'Absent reset did not perform the bounded presence-confirmation reads.'}

    Write-Host 'RELEASE_PUBLICATION_CONTRACT_OK'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
