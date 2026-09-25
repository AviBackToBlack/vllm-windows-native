Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-verification.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-publication.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-acceptance.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $caught=$null
    try{& $Action}catch{$caught=$_.Exception.Message}
    if($null-eq$caught){throw "Expected failure containing: $Contains"}
    if($caught.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure: $caught"}
}

Assert-Fails { Assert-VllmSm19dAcceptanceId -AcceptanceId 'BAD' } 'acceptance id'
Assert-Fails { Assert-VllmSm19dAcceptanceId -AcceptanceId 'abc..def' } 'acceptance id'
Assert-Fails { Assert-VllmSm19dAcceptanceId -AcceptanceId 'ABCDEF' } 'acceptance id'
Assert-Fails { Assert-VllmSm19dAcceptanceId -AcceptanceId 'abcdef.' } 'acceptance id'
Assert-Fails { Assert-VllmSm19dAcceptanceId -AcceptanceId 'abcdef.lock' } 'acceptance id'
Assert-Fails { Invoke-VllmSm19dSshKeygen -PrivateKeyPath (Join-Path ([IO.Path]::GetTempPath()) '%TEMP%\sm19d-key') } 'must not contain percent'

$id='20260925-bb4231f021f2-test'
$identity=Get-VllmSm19dAcceptanceIdentity -AcceptanceId $id
if(-not$identity.tag.Equals(('acceptance/sm19d/'+$id),[StringComparison]::Ordinal)){throw 'SM-19D tag derivation mismatch.'}
if(-not$identity.release.Equals(('sm19d-acceptance-'+$id),[StringComparison]::Ordinal)){throw 'SM-19D release derivation mismatch.'}

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm19d-contract-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$repo=Join-Path $root 'repo'
[IO.Directory]::CreateDirectory($workspace)|Out-Null
[IO.Directory]::CreateDirectory($repo)|Out-Null

try{
    & git init -q -b main $repo
    if($LASTEXITCODE-ne0){throw 'Unable to initialize SM-19D test repository.'}
    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'fixture',[Text.UTF8Encoding]::new($false))
    Invoke-Git -Repository $repo -Arguments @('add','fixture.txt')
    Invoke-Git -Repository $repo -Arguments @('-c','user.name=SM19D Test','-c','user.email=sm19d-test@invalid.local','-c','commit.gpgsign=false','commit','-q','-m','fixture')
    $commit=(Invoke-Git -Repository $repo -Arguments @('rev-parse','HEAD') -Capture).Trim().ToLowerInvariant()

    $canonicalPush=Get-VllmSm19dCanonicalPushUrl -Repository $repo -RepositorySlug $script:VllmSm19dRepositorySlug
    if(-not$canonicalPush.Equals('https://github.com/AviBackToBlack/vllm-windows-native.git',[StringComparison]::Ordinal)){throw 'SM-19D canonical push URL mismatch.'}
    Invoke-Git -Repository $repo -Arguments @('config','url.https://example.invalid/fork.git.insteadOf',$canonicalPush)
    Assert-Fails { Get-VllmSm19dCanonicalPushUrl -Repository $repo -RepositorySlug $script:VllmSm19dRepositorySlug } 'canonical push URL is rewritten'
    Invoke-Git -Repository $repo -Arguments @('config','--unset','url.https://example.invalid/fork.git.insteadOf')
    Invoke-Git -Repository $repo -Arguments @('config','url.https://example.invalid/fork.git.pushInsteadOf',$canonicalPush)
    Assert-Fails { Get-VllmSm19dCanonicalPushUrl -Repository $repo -RepositorySlug $script:VllmSm19dRepositorySlug } 'pushInsteadOf'
    Invoke-Git -Repository $repo -Arguments @('config','--unset','url.https://example.invalid/fork.git.pushInsteadOf')

    $assets=@(New-VllmSm19dFixtureAssets -Workspace $workspace -AcceptanceId $id -Tag $identity.tag -ProjectCommit $commit)
    if($assets.Count-ne4){throw 'SM-19D fixture builder did not create exactly four assets.'}
    $expectedNames=@(Get-VllmSm19dExpectedAssetNames)
    foreach($name in $expectedNames){
        if(@($assets|Where-Object{$_.name-eq$name}).Count-ne1){throw "SM-19D fixture asset missing: $name"}
    }
    $signing=New-VllmSm19dSigningMaterial -Workspace $workspace
    if(-not[IO.File]::Exists($signing.private_key)){throw 'SM-19D signing material did not create private key.'}
    New-VllmSm19dSignedTag -Repository $repo -Tag $identity.tag -ProjectCommit $commit -PrivateKeyPath $signing.private_key -AcceptanceId $id
    $verified=Assert-VllmReleaseSignedTag -Repository $repo -Tag $identity.tag -ExpectedCommit $commit -AllowedSignersPath $signing.allowed_signers -ExpectedPrincipal $signing.principal -ExpectedFingerprint $signing.fingerprint
    if(-not$verified.project_commit.Equals($commit,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-19D signed tag commit mismatch.'}

    Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $signing.private_key
    if([IO.File]::Exists($signing.private_key)){throw 'SM-19D ephemeral private key survived removal.'}
    [IO.File]::WriteAllText($signing.private_key,'residual-secret',[Text.UTF8Encoding]::new($false))
    $cleaned=Clear-VllmSm19dResidualPrivateKey -Workspace $workspace
    if(-not$cleaned -or [IO.File]::Exists($signing.private_key)){throw 'SM-19D residual private key sanitization failed.'}
    $verifiedAgain=Assert-VllmReleaseSignedTag -Repository $repo -Tag $identity.tag -ExpectedCommit $commit -AllowedSignersPath $signing.allowed_signers -ExpectedPrincipal $signing.principal -ExpectedFingerprint $signing.fingerprint
    if(-not$verifiedAgain.tag_object.Equals($verified.tag_object,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-19D signed tag changed after private-key removal.'}

    $state=[pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-sm19d-acceptance'
        acceptance_id=$id
        repository=$script:VllmSm19dRepositorySlug
        release=$identity.release
        tag=$identity.tag
        project_commit=$commit
        tag_object=$verified.tag_object
        principal=$signing.principal
        key_fingerprint=$signing.fingerprint
        assets=@($assets|ForEach-Object{[pscustomobject][ordered]@{name=$_.name;size=$_.size;sha256=$_.sha256}})
        draft_round_trip_completed=$false
        remote_tag_pushed=$false
        published=$false
        release_id=$null
        release_url=$null
        created_utc='2026-09-25T00:00:00.0000000Z'
    }
    $statePath=Write-VllmSm19dState -Workspace $workspace -State $state
    if(-not[IO.File]::Exists($statePath)){throw 'SM-19D state writer did not create state file.'}
    $loaded=Read-VllmSm19dState -Workspace $workspace
    $faultState=($state|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    $faultState.remote_tag_pushed=$true
    Assert-Fails { Write-VllmSm19dState -Workspace $workspace -State $faultState -FaultPoint BeforePublish } 'FAULT_INJECTED:BeforePublish'
    $preserved=Read-VllmSm19dState -Workspace $workspace
    if([bool]$preserved.remote_tag_pushed){throw 'SM-19D atomic state fault destroyed the previous valid state.'}

    $invalidState=($state|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    $invalidState.draft_round_trip_completed=$true
    Assert-Fails { Assert-VllmSm19dStateObject -State $invalidState } 'without the remote tag'
    $invalidState.remote_tag_pushed=$true
    $invalidState.published=$true
    Assert-Fails { Assert-VllmSm19dStateObject -State $invalidState } 'release id and URL'

    $recoveryWorkspace=Join-Path $root 'recovery'
    [IO.Directory]::CreateDirectory($recoveryWorkspace)|Out-Null
    $recoveryState=($state|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    $recoveryState.draft_round_trip_completed=$true
    $recoveryState.remote_tag_pushed=$true
    $null=Write-VllmSm19dState -Workspace $recoveryWorkspace -State $recoveryState
    $verifiedRelease=[pscustomobject][ordered]@{draft=$false;immutable=$true;id=12345;html_url='https://github.com/AviBackToBlack/vllm-windows-native/releases/tag/acceptance/test';published_at='2026-09-25T13:31:51Z'}
    $recovered=Set-VllmSm19dVerifiedPublishedState -Workspace $recoveryWorkspace -State $recoveryState -ReleaseObject $verifiedRelease
    if(-not[bool]$recovered.published -or [int64]$recovered.release_id-ne12345 -or -not([string]$recovered.release_url).Equals([string]$verifiedRelease.html_url,[StringComparison]::Ordinal)){throw 'SM-19D published-state recovery failed.'}
    $recoveryJson=[IO.File]::ReadAllText((Join-Path $recoveryWorkspace 'acceptance-state.json'))
    if(-not$recoveryJson.Contains('2026-09-25T13:31:51.0000000Z')){throw 'SM-19D published-state recovery timestamp was not persisted as invariant UTC.'}
    $recoveryBytesBeforeSecond=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $recoveryWorkspace 'acceptance-state.json')))
    $recoveredAgain=Set-VllmSm19dVerifiedPublishedState -Workspace $recoveryWorkspace -State $recovered -ReleaseObject $verifiedRelease
    $recoveryBytesAfterSecond=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $recoveryWorkspace 'acceptance-state.json')))
    if(-not$recoveryBytesBeforeSecond.Equals($recoveryBytesAfterSecond,[StringComparison]::Ordinal)){throw 'Idempotent published-state recovery rewrote canonical state bytes.'}
    if([int64]$recoveredAgain.release_id-ne12345){throw 'SM-19D published-state recovery was not idempotent.'}
    $wrongRelease=[pscustomobject][ordered]@{draft=$false;immutable=$true;id=12346;html_url='https://github.com/AviBackToBlack/vllm-windows-native/releases/tag/acceptance/other';published_at='2026-09-25T13:31:51Z'}
    Assert-Fails { Set-VllmSm19dVerifiedPublishedState -Workspace $recoveryWorkspace -State $recoveredAgain -ReleaseObject $wrongRelease } 'persisted published release identity mismatch'
    $context=Assert-VllmSm19dStateFiles -Workspace $workspace -State $loaded
    if(@($context.asset_plan).Count-ne4){throw 'SM-19D state file verification lost assets.'}

    $tamperPath=Join-Path $context.assets_directory 'release-index.json'
    [IO.File]::AppendAllText($tamperPath,'tamper',[Text.UTF8Encoding]::new($false))
    Assert-Fails { Assert-VllmSm19dStateFiles -Workspace $workspace -State $loaded } 'changed after preparation'

    $script:FakeRemoteTagObject=$null
    $script:FakeRemoteRelease=$null
    $script:FakeRemoteMain=$commit

    function Invoke-VllmPublicationGhCommand {
        param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$FailureLabel,[string]$Executable='gh')
        $null=$FailureLabel
        $null=$Executable
        if($Arguments[0]-ne'api'){throw "Unexpected SM-19D fake gh command: $($Arguments -join ' ')"}
        $joined=$Arguments -join ' '
        if($joined.Contains('/immutable-releases')){
            return (@{enabled=$true;enforced_by_owner=$false}|ConvertTo-Json -Compress)
        }
        if($joined.Contains('/git/ref/heads/main')){
            return (@{ref='refs/heads/main';object=@{type='commit';sha=$script:FakeRemoteMain}}|ConvertTo-Json -Depth 4 -Compress)
        }
        if($joined.Contains('/git/ref/tags/')){
            if($null-eq$script:FakeRemoteTagObject){throw 'Unable to inspect SM-19D remote tag: gh: Not Found (HTTP 404)'}
            return (@{ref=('refs/tags/'+$identity.tag);object=@{type='tag';sha=$script:FakeRemoteTagObject}}|ConvertTo-Json -Depth 4 -Compress)
        }
        if($joined -match 'repos/.+/releases\?per_page=100'){
            if($null-eq$script:FakeRemoteRelease){return '[[]]'}
            return '[['+($script:FakeRemoteRelease|ConvertTo-Json -Depth 8 -Compress)+']]'
        }
        if($joined -match 'repos/.+$' -and -not$joined.Contains('/releases/')){
            return (@{default_branch='main'}|ConvertTo-Json -Compress)
        }
        throw "Unhandled SM-19D fake gh api command: $joined"
    }

    $absentTag=Get-VllmSm19dRemoteTagObject -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag
    if($null-ne$absentTag){throw 'SM-19D remote-tag absence probe did not return null.'}
    Assert-VllmSm19dRemoteIdentityAbsent -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag

    $script:FakeRemoteTagObject=$verified.tag_object
    Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag -ExpectedTagObject $verified.tag_object
    Assert-Fails {
        Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag -ExpectedTagObject ('0'*40)
    } 'tag object mismatch'

    $operatorCommit=Assert-VllmSm19dOperatorRepositoryState -Repository $repo -RepositorySlug $script:VllmSm19dRepositorySlug -ExpectedCommit $commit
    if(-not$operatorCommit.Equals($commit,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-19D operator repository preflight returned wrong commit.'}

    Invoke-Git -Repository $repo -Arguments @('checkout','-q','-b','feature-test')
    Assert-Fails {
        Assert-VllmSm19dOperatorRepositoryState -Repository $repo -RepositorySlug $script:VllmSm19dRepositorySlug -ExpectedCommit $commit
    } 'requires checked-out branch main'
    Invoke-Git -Repository $repo -Arguments @('checkout','-q','main')

    $script:FakeRemoteRelease=[pscustomobject][ordered]@{tag_name=$identity.tag}
    Assert-Fails {
        Assert-VllmSm19dRemoteReleaseAbsent -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag
    } 'release already exists'

    $verifiedBody=Get-VllmReleaseDraftBody -RepositorySlug $script:VllmSm19dRepositorySlug -Release $identity.release -Tag $identity.tag -ProjectCommit $commit
    $script:FakeRemoteRelease=[pscustomobject][ordered]@{
        id=12345;html_url=$verifiedRelease.html_url;tag_name=$identity.tag;body=$verifiedBody;draft=$false;prerelease=$true;immutable=$true;published_at=$verifiedRelease.published_at
        assets=@($context.asset_plan|ForEach-Object{[pscustomobject][ordered]@{name=$_.name;size=$_.size;digest=('sha256:'+([string]$_.sha256).ToLowerInvariant());state='uploaded'}})
    }
    function Invoke-VllmGitHubReleaseVerification {
        param([string]$RepositorySlug,[string]$Tag,[string]$ExpectedTagObject,[string]$ArtifactsDirectory,[System.Collections.IDictionary]$ExpectedAssets,[string]$GhExecutable='gh')
        $null=$RepositorySlug;$null=$Tag;$null=$ExpectedTagObject;$null=$ArtifactsDirectory;$null=$ExpectedAssets;$null=$GhExecutable
        [pscustomobject][ordered]@{asset_count=4}
    }
    $stateFile=Join-Path $workspace 'acceptance-state.json'
    $stateBefore=[IO.File]::ReadAllBytes($stateFile)
    [IO.File]::SetAttributes($stateFile,([IO.File]::GetAttributes($stateFile)-bor[IO.FileAttributes]::ReadOnly))
    try{
        $proof=Get-VllmSm19dPublishedVerification -State $loaded -AssetPlan ([object[]]$context.asset_plan) -ArtifactsDirectory $context.assets_directory
        if([int]$proof.attestation.asset_count-ne4){throw 'Read-only published verification returned wrong asset count.'}
    }finally{
        [IO.File]::SetAttributes($stateFile,([IO.File]::GetAttributes($stateFile)-band(-bnot[IO.FileAttributes]::ReadOnly)))
    }
    $stateAfter=[IO.File]::ReadAllBytes($stateFile)
    if(-not[Convert]::ToBase64String($stateBefore).Equals([Convert]::ToBase64String($stateAfter),[StringComparison]::Ordinal)){throw 'Read-only published verification mutated acceptance state.'}

    $topLevel=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\release-acceptance.ps1'))
    $verifyStart=$topLevel.IndexOf("    'Verify' {",[StringComparison]::Ordinal)
    $recoverStart=$topLevel.IndexOf("    'RecoverPublishedState' {",[StringComparison]::Ordinal)
    if($verifyStart-lt0-or$recoverStart-le$verifyStart){throw 'Top-level Verify/RecoverPublishedState mode layout is invalid.'}
    $verifyBlock=$topLevel.Substring($verifyStart,$recoverStart-$verifyStart)
    if($verifyBlock.Contains('Set-VllmSm19dVerifiedPublishedState')){throw 'Top-level Verify must not reconcile or write acceptance state.'}

    $whatIfWorkspace=Join-Path $root 'whatif'
    [IO.Directory]::CreateDirectory($whatIfWorkspace)|Out-Null
    $whatIfState=($state|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    $whatIfState.draft_round_trip_completed=$true
    $whatIfState.remote_tag_pushed=$true
    $null=Write-VllmSm19dState -Workspace $whatIfWorkspace -State $whatIfState
    $objectBefore=$whatIfState|ConvertTo-Json -Depth 10 -Compress
    $fileBefore=[IO.File]::ReadAllText((Join-Path $whatIfWorkspace 'acceptance-state.json'))
    $null=Set-VllmSm19dVerifiedPublishedState -Workspace $whatIfWorkspace -State $whatIfState -ReleaseObject $verifiedRelease -WhatIf
    $objectAfter=$whatIfState|ConvertTo-Json -Depth 10 -Compress
    $fileAfter=[IO.File]::ReadAllText((Join-Path $whatIfWorkspace 'acceptance-state.json'))
    if(-not$objectBefore.Equals($objectAfter,[StringComparison]::Ordinal)){throw 'Published-state WhatIf mutated the in-memory state object.'}
    if(-not$fileBefore.Equals($fileAfter,[StringComparison]::Ordinal)){throw 'Published-state WhatIf mutated the state file.'}

    Write-Host 'RELEASE_ACCEPTANCE_CONTRACT_OK'
}finally{
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
