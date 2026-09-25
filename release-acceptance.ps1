[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','ExerciseDraft','Publish','Verify','RecoverPublishedState','ResetDraft')][string]$Mode,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$AcceptanceId,
    [string]$GhExecutable = 'gh',
    [switch]$Json
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$jsonOutput=[bool]$Json

$repository = [IO.Path]::GetFullPath($PSScriptRoot)
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\release-verification.ps1')
. (Join-Path $repository 'scripts\release-publication.ps1')
. (Join-Path $repository 'scripts\release-acceptance.ps1')

function Write-Sm19dResult {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Marker)
    if($jsonOutput){$Result|ConvertTo-Json -Depth 12}else{Write-Host ($Marker+' '+(($Result.PSObject.Properties|ForEach-Object{$_.Name+'='+[string]$_.Value}) -join ' '))}
}

function Get-Sm19dVerifiedTagContext {
    param([Parameter(Mandatory)]$State)
    $allowed=Join-Path $workspaceFull 'signing\allowed-signers'
    $trust=Assert-VllmReleaseAllowedSigners -Path $allowed -ExpectedPrincipal ([string]$State.principal) -ExpectedFingerprint ([string]$State.key_fingerprint)
    $tagVerification=Assert-VllmReleaseSignedTag -Repository $repository -Tag ([string]$State.tag) -ExpectedCommit ([string]$State.project_commit) -AllowedSignersPath ([string]$trust.path) -ExpectedPrincipal ([string]$State.principal) -ExpectedFingerprint ([string]$State.key_fingerprint)
    if(-not([string]$tagVerification.tag_object).Equals([string]$State.tag_object,[StringComparison]::OrdinalIgnoreCase)){
        throw 'SM-19D local signed tag object no longer matches acceptance state.'
    }
    [pscustomobject][ordered]@{trust=$trust;tag_verification=$tagVerification}
}

function Get-Sm19dVerifiedStateContext {
    param([Parameter(Mandatory)]$State)
    $tagContext=Get-Sm19dVerifiedTagContext -State $State
    $files=Assert-VllmSm19dStateFiles -Workspace $workspaceFull -State $State
    [pscustomobject][ordered]@{
        state=$State
        files=$files
        tag_verification=$tagContext.tag_verification
    }
}

$workspaceFull=[IO.Path]::GetFullPath($Workspace)
$repoPrefix=$repository.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if($workspaceFull.Equals($repository,[StringComparison]::OrdinalIgnoreCase)-or$workspaceFull.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)){
    throw 'SM-19D acceptance workspace must be outside the project repository.'
}
if([IO.Directory]::Exists($workspaceFull)-and-not$Mode.Equals('Verify',[StringComparison]::OrdinalIgnoreCase)){
    $null=Clear-VllmSm19dResidualPrivateKey -Workspace $workspaceFull
}


switch($Mode){
    'Prepare' {
        if([string]::IsNullOrWhiteSpace($AcceptanceId)){throw 'Prepare mode requires -AcceptanceId.'}
        $identity=Get-VllmSm19dAcceptanceIdentity -AcceptanceId $AcceptanceId
        if([IO.Directory]::Exists($workspaceFull)-or[IO.File]::Exists($workspaceFull)){throw "SM-19D acceptance workspace must be absent before preparation: $workspaceFull"}
        $commit=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm19dRepositorySlug -GhExecutable $GhExecutable
        Assert-VllmSm19dRemoteIdentityAbsent -RepositorySlug $script:VllmSm19dRepositorySlug -Tag $identity.tag -GhExecutable $GhExecutable
        $target="$workspaceFull tag=$($identity.tag) commit=$commit"
        if(-not$PSCmdlet.ShouldProcess($target,'Prepare non-production SM-19D fixture, ephemeral signer, and local signed tag')){return}

        $tagCreated=$false
        $privateKeyPath=Join-Path $workspaceFull 'signing\acceptance-ed25519'
        try{
            [IO.Directory]::CreateDirectory($workspaceFull)|Out-Null
            $assets=@(New-VllmSm19dFixtureAssets -Workspace $workspaceFull -AcceptanceId $identity.acceptance_id -Tag $identity.tag -ProjectCommit $commit)
            $signing=New-VllmSm19dSigningMaterial -Workspace $workspaceFull
            New-VllmSm19dSignedTag -Repository $repository -Tag $identity.tag -ProjectCommit $commit -PrivateKeyPath $privateKeyPath -AcceptanceId $identity.acceptance_id
            $tagCreated=$true
            $tagVerification=Assert-VllmReleaseSignedTag -Repository $repository -Tag $identity.tag -ExpectedCommit $commit -AllowedSignersPath $signing.allowed_signers -ExpectedPrincipal $signing.principal -ExpectedFingerprint $signing.fingerprint
            Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $privateKeyPath

            $state=[pscustomobject][ordered]@{
                schema_version=1
                component='vllm-windows-native-sm19d-acceptance'
                acceptance_id=$identity.acceptance_id
                repository=$script:VllmSm19dRepositorySlug
                release=$identity.release
                tag=$identity.tag
                project_commit=$commit
                tag_object=[string]$tagVerification.tag_object
                principal=$signing.principal
                key_fingerprint=$signing.fingerprint
                assets=@($assets|ForEach-Object{[pscustomobject][ordered]@{name=$_.name;size=$_.size;sha256=$_.sha256}})
                draft_round_trip_completed=$false
                remote_tag_pushed=$false
                published=$false
                release_id=$null
                release_url=$null
                created_utc=(Get-Date).ToUniversalTime().ToString('o')
            }
            $statePath=Write-VllmSm19dState -Workspace $workspaceFull -State $state
            $result=[pscustomobject][ordered]@{
                state='prepared'
                acceptance_id=$identity.acceptance_id
                tag=$identity.tag
                project_commit=$commit
                tag_object=$tagVerification.tag_object
                asset_count=$assets.Count
                workspace=$workspaceFull
                state_file=$statePath
            }
            Write-Sm19dResult -Result $result -Marker 'SM19D_PREPARE_OK'
        }catch{
            if($tagCreated){
                try{Invoke-Git -Repository $repository -Arguments @('tag','-d',$identity.tag)}catch{Write-Verbose ('Unable to remove failed local SM-19D tag: '+$_.Exception.Message)}
            }
            if([IO.File]::Exists($privateKeyPath)){
                try{Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $privateKeyPath -Confirm:$false}catch{Write-Verbose ('Unable to remove failed SM-19D private key: '+$_.Exception.Message)}
            }
            throw
        }
    }
    'ExerciseDraft' {
        $state=Read-VllmSm19dState -Workspace $workspaceFull
        if([bool]$state.published){throw 'SM-19D draft exercise cannot run after publication.'}
        $commit=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm19dRepositorySlug -ExpectedCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        $context=Get-Sm19dVerifiedStateContext -State $state
        Assert-VllmSm19dRemoteReleaseAbsent -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag) -GhExecutable $GhExecutable
        $remoteTag=Get-VllmSm19dRemoteTagObject -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag) -GhExecutable $GhExecutable

        if([bool]$state.draft_round_trip_completed){
            if($null-eq$remoteTag-or-not$remoteTag.Equals([string]$state.tag_object,[StringComparison]::OrdinalIgnoreCase)){
                throw 'Completed SM-19D draft exercise no longer has the exact remote acceptance tag.'
            }
            Write-Sm19dResult -Result ([pscustomobject][ordered]@{state='draft-round-trip-complete';tag=$state.tag;project_commit=$commit}) -Marker 'SM19D_DRAFT_OK'
            return
        }

        if($null-ne$remoteTag-and-not$remoteTag.Equals([string]$state.tag_object,[StringComparison]::OrdinalIgnoreCase)){
            throw 'SM-19D remote acceptance tag exists with the wrong tag object.'
        }

        $target="$($script:VllmSm19dRepositorySlug) tag=$($state.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Push exact acceptance tag, stage twice, then reset exact owned draft')){return}

        if($null-eq$remoteTag){
            Push-VllmSm19dAcceptanceTag -Repository $repository -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag)
        }
        Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag) -ExpectedTagObject ([string]$state.tag_object) -GhExecutable $GhExecutable

        $stage1=Invoke-VllmStageGitHubRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.files.asset_plan) -GhExecutable $GhExecutable
        if(-not([string]$stage1.state).Equals('draft',[StringComparison]::Ordinal)){throw 'SM-19D first stage did not end in draft state.'}
        $stage2=Invoke-VllmStageGitHubRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.files.asset_plan) -GhExecutable $GhExecutable
        if(-not([string]$stage2.state).Equals('draft',[StringComparison]::Ordinal)){throw 'SM-19D idempotent stage retry did not remain a draft.'}

        $reset=Invoke-VllmResetOwnedDraftRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -GhExecutable $GhExecutable
        if(-not([string]$reset.state).Equals('reset',[StringComparison]::Ordinal)){throw 'SM-19D owned draft reset did not report reset state.'}
        Assert-VllmSm19dRemoteReleaseAbsent -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag) -GhExecutable $GhExecutable

        $state.draft_round_trip_completed=$true
        $state.remote_tag_pushed=$true
        $null=Write-VllmSm19dState -Workspace $workspaceFull -State $state
        Write-Sm19dResult -Result ([pscustomobject][ordered]@{state='draft-round-trip-complete';tag=$state.tag;project_commit=$commit;asset_count=4}) -Marker 'SM19D_DRAFT_OK'
    }
    'Publish' {
        $state=Read-VllmSm19dState -Workspace $workspaceFull
        if(-not[bool]$state.draft_round_trip_completed){throw 'SM-19D publication requires a completed real draft round trip first.'}
        $commit=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm19dRepositorySlug -ExpectedCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        $context=Get-Sm19dVerifiedStateContext -State $state
        Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm19dRepositorySlug -Tag ([string]$state.tag) -ExpectedTagObject ([string]$state.tag_object) -GhExecutable $GhExecutable

        $target="$($script:VllmSm19dRepositorySlug) tag=$($state.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Stage exact fixture and publish immutable non-production SM-19D prerelease')){return}

        $stage=Invoke-VllmStageGitHubRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.files.asset_plan) -GhExecutable $GhExecutable
        if(([string]$stage.state).Equals('draft',[StringComparison]::Ordinal)-or([string]$stage.state).Equals('published',[StringComparison]::Ordinal)){
            $null=Invoke-VllmPublishGitHubRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.files.asset_plan) -GhExecutable $GhExecutable
        }else{
            throw "SM-19D stage returned unsupported state: $($stage.state)"
        }

        $verification=Invoke-VllmBoundedRetry -Attempts 5 -DelayMilliseconds 1500 -Action {
            Get-VllmSm19dPublishedVerification -State $state -AssetPlan ([object[]]$context.files.asset_plan) -ArtifactsDirectory ([string]$context.files.assets_directory) -GhExecutable $GhExecutable
        }
        $state=Set-VllmSm19dVerifiedPublishedState -Workspace $workspaceFull -State $state -ReleaseObject $verification.remote -Confirm:$false
        Write-Sm19dResult -Result ([pscustomobject][ordered]@{
            state='published'
            release=$state.release
            tag=$state.tag
            project_commit=$commit
            release_id=[int64]$state.release_id
            release_url=[string]$state.release_url
            asset_count=$verification.attestation.asset_count
        }) -Marker 'SM19D_PUBLISH_OK'
    }
    'Verify' {
        $verifyPrivateKey=Join-Path $workspaceFull 'signing\acceptance-ed25519'
        $verifyPrivateKeyEntry=Get-VllmPathEntryInfo -Path $verifyPrivateKey
        if($verifyPrivateKeyEntry.Exists){throw 'SM-19D read-only Verify refuses a workspace containing residual private signing material.'}
        $state=Read-VllmSm19dState -Workspace $workspaceFull
        $context=Get-Sm19dVerifiedStateContext -State $state
        $verification=Get-VllmSm19dPublishedVerification -State $state -AssetPlan ([object[]]$context.files.asset_plan) -ArtifactsDirectory ([string]$context.files.assets_directory) -GhExecutable $GhExecutable
        Write-Sm19dResult -Result ([pscustomobject][ordered]@{
            state='verified'
            release=$state.release
            tag=$state.tag
            project_commit=$state.project_commit
            release_id=[int64]$verification.remote.id
            release_url=[string]$verification.remote.html_url
            asset_count=$verification.attestation.asset_count
        }) -Marker 'SM19D_VERIFY_OK'
    }

    'RecoverPublishedState' {
        $state=Read-VllmSm19dState -Workspace $workspaceFull
        $context=Get-Sm19dVerifiedStateContext -State $state
        $verification=Get-VllmSm19dPublishedVerification -State $state -AssetPlan ([object[]]$context.files.asset_plan) -ArtifactsDirectory ([string]$context.files.assets_directory) -GhExecutable $GhExecutable
        $target=(Join-Path $workspaceFull 'acceptance-state.json')
        if(-not$PSCmdlet.ShouldProcess($target,'Reconcile verified immutable publication into SM-19D local state')){return}
        $state=Set-VllmSm19dVerifiedPublishedState -Workspace $workspaceFull -State $state -ReleaseObject $verification.remote -Confirm:$false
        Write-Sm19dResult -Result ([pscustomobject][ordered]@{
            state='published-state-recovered'
            release=$state.release
            tag=$state.tag
            project_commit=$state.project_commit
            release_id=[int64]$state.release_id
            release_url=[string]$state.release_url
            asset_count=$verification.attestation.asset_count
        }) -Marker 'SM19D_RECOVER_OK'
    }

    'ResetDraft' {
        $state=Read-VllmSm19dState -Workspace $workspaceFull
        $null=Get-Sm19dVerifiedTagContext -State $state
        $target="$($script:VllmSm19dRepositorySlug) tag=$($state.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Reset exact marker-owned SM-19D draft only')){return}
        $reset=Invoke-VllmResetOwnedDraftRelease -RepositorySlug $script:VllmSm19dRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        Write-Sm19dResult -Result ([pscustomobject][ordered]@{state=$reset.state;tag=$state.tag;release=$state.release}) -Marker 'SM19D_RESET_OK'
    }
}
