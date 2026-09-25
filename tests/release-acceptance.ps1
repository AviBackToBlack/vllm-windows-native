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

    Write-Host 'RELEASE_ACCEPTANCE_CONTRACT_OK'
}finally{
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
