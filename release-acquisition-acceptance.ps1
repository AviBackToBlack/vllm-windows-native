[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Publish','Verify','Exercise')][string]$Mode,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$GhExecutable='gh',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$jsonOutput=[bool]$Json

$repository=[IO.Path]::GetFullPath($PSScriptRoot)
. (Join-Path $repository 'scripts\common.ps1')
. (Join-Path $repository 'scripts\release-bundle.ps1')
. (Join-Path $repository 'scripts\release-verification.ps1')
. (Join-Path $repository 'scripts\release-publication.ps1')
. (Join-Path $repository 'scripts\release-acceptance.ps1')
. (Join-Path $repository 'scripts\release-acquisition.ps1')
. (Join-Path $repository 'scripts\release-handoff.ps1')
. (Join-Path $repository 'scripts\release-acquisition-acceptance.ps1')

if($env:OS-ne'Windows_NT'-or-not[Environment]::Is64BitOperatingSystem){throw 'SM-20E trusted acceptance requires native Windows x64.'}

function Write-Sm20eResult {
    param([Parameter(Mandatory)]$Result,[Parameter(Mandatory)][string]$Marker)
    if($jsonOutput){$Result|ConvertTo-Json -Depth 14}else{Write-Host ($Marker+' '+(($Result.PSObject.Properties|ForEach-Object{$_.Name+'='+[string]$_.Value}) -join ' '))}
}

function Assert-Sm20eWorkspaceOutsideRepository {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=$repository.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if($full.Equals($repository,[StringComparison]::OrdinalIgnoreCase)-or$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E workspace must be outside the project repository.'}
    $full
}

function Set-Sm20ePublishedState {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$WorkspacePath,[Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Remote)
    $statePath=Join-Path ([IO.Path]::GetFullPath($WorkspacePath)) $script:VllmSm20eStateFile
    if(-not$PSCmdlet.ShouldProcess($statePath,'Record verified immutable SM-20E publication state')){return $State}
    $State.published=$true
    $State.release_id=[int64]$Remote.id
    $State.release_url=[string]$Remote.html_url
    $State.published_utc=ConvertTo-VllmSm19dUtcTimestamp -Value $Remote.published_at -Label 'SM-20E release published_at'
    $null=Write-VllmSm20eState -Workspace $WorkspacePath -State $State
    Read-VllmSm20eState -Workspace $WorkspacePath
}

$workspaceFull=Assert-Sm20eWorkspaceOutsideRepository -Path $Workspace

switch($Mode){
    'Prepare' {
        if(Test-Path -LiteralPath $workspaceFull){throw "SM-20E workspace must be absent before preparation: $workspaceFull"}
        $commit=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm20eRepositorySlug -GhExecutable $GhExecutable
        Assert-VllmSm19dRemoteIdentityAbsent -RepositorySlug $script:VllmSm20eRepositorySlug -Tag $script:VllmSm20eTag -GhExecutable $GhExecutable
        $target="$workspaceFull tag=$($script:VllmSm20eTag) commit=$commit"
        if(-not$PSCmdlet.ShouldProcess($target,'Prepare reviewed non-production SM-20E fixture and local signed tag')){return}
        $tagCreated=$false
        $privateKey=Join-Path $workspaceFull 'signing\acceptance-ed25519'
        try{
            [void][IO.Directory]::CreateDirectory($workspaceFull)
            $wheelPath=Join-Path (Join-Path $workspaceFull 'input') $script:VllmSm20eWheelName
            $wheel=New-VllmSm20eSyntheticWheel -Path $wheelPath -Confirm:$false
            $artifacts=Join-Path $workspaceFull 'artifacts'
            $offline=Write-VllmOfflineRelease -Repository $repository -ProjectCommit $commit -ReleaseManifestPath $script:VllmSm20eReleaseManifestPath -WheelPath $wheel.path -ArtifactsDirectory $artifacts
            if(-not([string]$offline.release).Equals($script:VllmSm20eRelease,[StringComparison]::Ordinal)-or-not([string]$offline.tag).Equals($script:VllmSm20eTag,[StringComparison]::Ordinal)){throw 'SM-20E offline fixture identity mismatch.'}
            $signing=New-VllmSm20eSigningMaterial -Workspace $workspaceFull -Confirm:$false
            New-VllmSm20eSignedTag -Repository $repository -ProjectCommit $commit -PrivateKeyPath $signing.private_key -Confirm:$false
            $tagCreated=$true
            $tag=Assert-VllmReleaseSignedTag -Repository $repository -Tag $script:VllmSm20eTag -ExpectedCommit $commit -AllowedSignersPath $signing.allowed_signers -ExpectedPrincipal $signing.principal -ExpectedFingerprint $signing.fingerprint
            Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $privateKey -Confirm:$false
            $plan=@(Get-VllmReleasePublicationAssetPlan -ArtifactsDirectory $artifacts -OfflineVerification $offline)
            $state=[pscustomobject][ordered]@{
                schema_version=1
                component='vllm-windows-native-sm20e-acceptance'
                repository=$script:VllmSm20eRepositorySlug
                release=$script:VllmSm20eRelease
                tag=$script:VllmSm20eTag
                project_commit=$commit
                tag_object=[string]$tag.tag_object
                principal=$signing.principal
                key_fingerprint=$signing.fingerprint
                release_manifest_path=$script:VllmSm20eReleaseManifestPath
                assets=@($plan|ForEach-Object{[pscustomobject][ordered]@{name=$_.name;size=[int64]$_.size;sha256=[string]$_.sha256}})
                published=$false
                release_id=$null
                release_url=$null
                created_utc=(Get-Date).ToUniversalTime().ToString('o')
                published_utc=$null
            }
            $statePath=Write-VllmSm20eState -Workspace $workspaceFull -State $state
            Write-Sm20eResult -Result ([pscustomobject][ordered]@{
                state='prepared';release=$state.release;tag=$state.tag;project_commit=$commit;tag_object=$state.tag_object
                wheel_sha256=$script:VllmSm20eWheelSha256;asset_count=$plan.Count;state_file=$statePath
            }) -Marker 'SM20E_PREPARE_OK'
        }catch{
            if($tagCreated){try{Invoke-Git -Repository $repository -Arguments @('tag','-d',$script:VllmSm20eTag)}catch{Write-Verbose ('Unable to remove failed SM-20E local tag: '+$_.Exception.Message)}}
            if(Test-Path -LiteralPath $privateKey){try{Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $privateKey -Confirm:$false}catch{Write-Verbose ('Unable to remove failed SM-20E private key: '+$_.Exception.Message)}}
            throw
        }
    }

    'Publish' {
        $state=Read-VllmSm20eState -Workspace $workspaceFull
        $commit=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm20eRepositorySlug -ExpectedCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        $null=Test-VllmSm20ePrivateKeyAbsent -Workspace $workspaceFull
        $context=Get-VllmSm20eVerifiedLocalContext -Repository $repository -Workspace $workspaceFull -State $state
        $remoteTag=Get-VllmSm19dRemoteTagObject -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag) -GhExecutable $GhExecutable
        if($null-ne$remoteTag-and-not$remoteTag.Equals([string]$state.tag_object,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E remote tag exists with the wrong tag object.'}
        $target="$($script:VllmSm20eRepositorySlug) tag=$($state.tag)"
        if(-not$PSCmdlet.ShouldProcess($target,'Publish immutable non-production SM-20E prerelease fixture')){return}
        if($null-eq$remoteTag){Push-VllmSm19dAcceptanceTag -Repository $repository -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag)}
        Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag) -ExpectedTagObject ([string]$state.tag_object) -GhExecutable $GhExecutable
        $stage=Invoke-VllmStageGitHubRelease -RepositorySlug $script:VllmSm20eRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.asset_plan) -GhExecutable $GhExecutable
        if(([string]$stage.state).Equals('draft',[StringComparison]::Ordinal)-or([string]$stage.state).Equals('published',[StringComparison]::Ordinal)){
            $null=Invoke-VllmPublishGitHubRelease -RepositorySlug $script:VllmSm20eRepositorySlug -Release ([string]$state.release) -Tag ([string]$state.tag) -ProjectCommit $commit -TagObject ([string]$state.tag_object) -AssetPlan ([object[]]$context.asset_plan) -GhExecutable $GhExecutable
        }else{throw "SM-20E stage returned unsupported state: $($stage.state)"}
        $verification=Invoke-VllmBoundedRetry -Attempts 5 -DelayMilliseconds 1500 -Action {
            Get-VllmSm20ePublishedVerification -State $state -LocalContext $context -GhExecutable $GhExecutable
        }
        $state=Set-Sm20ePublishedState -WorkspacePath $workspaceFull -State $state -Remote $verification.remote -Confirm:$false
        Write-Sm20eResult -Result ([pscustomobject][ordered]@{
            state='published';release=$state.release;tag=$state.tag;project_commit=$commit;tag_object=$state.tag_object
            release_id=[int64]$state.release_id;release_url=[string]$state.release_url;asset_count=[int]$verification.attestation.asset_count
        }) -Marker 'SM20E_PUBLISH_OK'
    }

    'Verify' {
        $state=Read-VllmSm20eState -Workspace $workspaceFull
        $null=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm20eRepositorySlug -ExpectedCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        $null=Test-VllmSm20ePrivateKeyAbsent -Workspace $workspaceFull
        $context=Get-VllmSm20eVerifiedLocalContext -Repository $repository -Workspace $workspaceFull -State $state
        $verification=Get-VllmSm20ePublishedVerification -State $state -LocalContext $context -GhExecutable $GhExecutable
        Write-Sm20eResult -Result ([pscustomobject][ordered]@{
            state='verified';release=$state.release;tag=$state.tag;project_commit=$state.project_commit;tag_object=$state.tag_object
            release_id=[int64]$verification.remote.id;release_url=[string]$verification.remote.html_url;asset_count=[int]$verification.attestation.asset_count
        }) -Marker 'SM20E_VERIFY_OK'
    }

    'Exercise' {
        $state=Read-VllmSm20eState -Workspace $workspaceFull
        $null=Assert-VllmSm19dOperatorRepositoryState -Repository $repository -RepositorySlug $script:VllmSm20eRepositorySlug -ExpectedCommit ([string]$state.project_commit) -GhExecutable $GhExecutable
        $null=Test-VllmSm20ePrivateKeyAbsent -Workspace $workspaceFull
        $context=Get-VllmSm20eVerifiedLocalContext -Repository $repository -Workspace $workspaceFull -State $state
        $verification=Get-VllmSm20ePublishedVerification -State $state -LocalContext $context -GhExecutable $GhExecutable
        $exerciseRoot=Join-Path $workspaceFull 'exercise'
        if(-not$PSCmdlet.ShouldProcess($exerciseRoot,'Run or resume trusted network acquisition, recovery, exact reacquisition, and local handoff proof')){return}
        $exerciseSession=Enter-VllmSm20eExerciseRoot -Workspace $workspaceFull -State $state -Confirm:$false
        $exerciseRoot=[string]$exerciseSession.root
        $cleanCache=Join-Path $exerciseRoot 'clean-cache'
        $recoveryCache=Join-Path $exerciseRoot 'recovery-cache'
        $allowed=Join-Path $workspaceFull 'signing\allowed-signers'

        $clean=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag) -AllowedSignersPath $allowed -CacheRoot $cleanCache -GhExecutable $GhExecutable -ExpectedPrincipal ([string]$state.principal) -ExpectedFingerprint ([string]$state.key_fingerprint)
        if(-not([string]$clean.project_commit).Equals([string]$state.project_commit,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$clean.tag_object).Equals([string]$state.tag_object,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$clean.wheel_sha256).Equals($script:VllmSm20eWheelSha256,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E clean acquisition identity mismatch.'}
        $cleanHandoff=Invoke-VllmSm20eHandoffProof -Acquisition $clean

        $untrusted=New-VllmSm20eUntrustedRecoveryState -CacheRoot $recoveryCache -Confirm:$false
        $recovered=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag) -AllowedSignersPath $allowed -CacheRoot $recoveryCache -GhExecutable $GhExecutable -ExpectedPrincipal ([string]$state.principal) -ExpectedFingerprint ([string]$state.key_fingerprint)
        if(-not(Test-Path -LiteralPath $untrusted.staging -PathType Container)-or-not(Test-Path -LiteralPath $untrusted.garbage -PathType Container)){throw 'SM-20E recovery acquisition removed unknown untrusted state.'}
        $receiptBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes([string]$recovered.receipt_path))
        $reacquired=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$state.tag) -AllowedSignersPath $allowed -CacheRoot $recoveryCache -GhExecutable $GhExecutable -ExpectedPrincipal ([string]$state.principal) -ExpectedFingerprint ([string]$state.key_fingerprint)
        $receiptAfter=[Convert]::ToBase64String([IO.File]::ReadAllBytes([string]$reacquired.receipt_path))
        if(-not([string]$reacquired.cache_entry).Equals([string]$recovered.cache_entry,[StringComparison]::OrdinalIgnoreCase)-or-not$receiptBefore.Equals($receiptAfter,[StringComparison]::Ordinal)){throw 'SM-20E exact reacquisition was not idempotent.'}
        $recoveryHandoff=Invoke-VllmSm20eHandoffProof -Acquisition $reacquired

        foreach($cache in @($cleanCache,$recoveryCache)){
            $handoff=Join-Path $cache '.handoff'
            if((Test-Path -LiteralPath $handoff)-and@(Get-ChildItem -LiteralPath $handoff -Force).Count-ne0){throw "SM-20E handoff left residue: $handoff"}
        }
        $proof=[ordered]@{
            schema_version=1
            component='vllm-windows-native-sm20e-proof'
            release=[string]$state.release
            tag=[string]$state.tag
            project_commit=[string]$state.project_commit
            tag_object=[string]$state.tag_object
            release_id=[int64]$verification.remote.id
            clean_cache_entry=[string]$clean.cache_entry
            recovery_cache_entry=[string]$recovered.cache_entry
            clean_install_script=[string]$cleanHandoff.install.script_path
            clean_update_script=[string]$cleanHandoff.update.script_path
            recovery_install_script=[string]$recoveryHandoff.install.script_path
            recovery_update_script=[string]$recoveryHandoff.update.script_path
            completed_utc=(Get-Date).ToUniversalTime().ToString('o')
        }
        $proofPath=[string]$exerciseSession.proof
        $null=Write-VllmAtomicJsonFile -Path $proofPath -Value $proof -Depth 10
        Write-Sm20eResult -Result ([pscustomobject][ordered]@{
            state='accepted';release=$state.release;tag=$state.tag;project_commit=$state.project_commit;tag_object=$state.tag_object
            release_id=[int64]$verification.remote.id;clean_cache_entry=$clean.cache_entry;recovery_cache_entry=$recovered.cache_entry;proof_file=$proofPath
        }) -Marker 'SM20E_ACCEPTANCE_OK'
    }
}
