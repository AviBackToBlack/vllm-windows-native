Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\release-bundle.ps1')
. (Join-Path $repoRoot 'scripts\release-verification.ps1')
. (Join-Path $repoRoot 'scripts\release-publication.ps1')
. (Join-Path $repoRoot 'scripts\release-acceptance.ps1')
. (Join-Path $repoRoot 'scripts\release-acquisition.ps1')
. (Join-Path $repoRoot 'scripts\release-handoff.ps1')
. (Join-Path $repoRoot 'scripts\release-acquisition-acceptance.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $message=$null
    try{& $Action}catch{$message=$_.Exception.Message}
    if($null-eq$message){throw "Expected failure containing: $Contains"}
    if($message.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure: $message"}
}

$identity=Get-VllmSm20eIdentity
if(-not([string]$identity.release).Equals('sm20e-acceptance-20260927-01',[StringComparison]::Ordinal)){throw 'SM-20E release identity drifted.'}
if(-not([string]$identity.tag).Equals('release/sm20e-acceptance-20260927-01',[StringComparison]::Ordinal)){throw 'SM-20E exact tag identity drifted.'}
if(([string]$identity.release).IndexOf('v1.0',[StringComparison]::OrdinalIgnoreCase)-ge0){throw 'SM-20E fixture must never use a GA-looking release identity.'}
if([int64]$identity.wheel_size-ne815-or-not([string]$identity.wheel_sha256).Equals('908E763E762A2A6CE392B0E9DB04FA0F5AFD614F16A15AB805DE61D3BD6E8481',[StringComparison]::Ordinal)){throw 'SM-20E reviewed wheel identity drifted.'}

$commit=(Invoke-Git -Repository $repoRoot -Arguments @('rev-parse','HEAD') -Capture).Trim().ToLowerInvariant()
$snapshot=Get-VllmReleaseGitSnapshot -Repository $repoRoot -Commit $commit
try{
    $context=Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $script:VllmSm20eReleaseManifestPath
    if(-not([string]$context.Release.release).Equals($script:VllmSm20eRelease,[StringComparison]::Ordinal)-or-not([string]$context.Tag).Equals($script:VllmSm20eTag,[StringComparison]::Ordinal)){throw 'SM-20E reviewed manifest identity mismatch.'}
    if(@($context.Members).Count-ne30){throw "SM-20E fixture bundle member count drifted: $(@($context.Members).Count)"}
    if(@($context.NativeExtensions).Count-ne1-or-not([string](@($context.NativeExtensions)[0])).Equals('vllm/_sm20e_fixture.pyd',[StringComparison]::Ordinal)){throw 'SM-20E synthetic native extension identity mismatch.'}
}finally{Close-VllmReleaseGitSnapshot -Snapshot $snapshot}
Write-Host 'SM20E_MANIFEST_CONTRACT_OK'

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm20e-contract-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $wheel1=New-VllmSm20eSyntheticWheel -Path (Join-Path (Join-Path $root 'wheel1') $script:VllmSm20eWheelName)
    $wheel2=New-VllmSm20eSyntheticWheel -Path (Join-Path (Join-Path $root 'wheel2') $script:VllmSm20eWheelName)
    if($wheel1.Size-ne$wheel2.Size-or-not([string]$wheel1.Sha256).Equals([string]$wheel2.Sha256,[StringComparison]::Ordinal)){throw 'SM-20E synthetic wheel generation is not deterministic.'}
    Assert-Fails { New-VllmSm20eSyntheticWheel -Path (Join-Path $root 'wrong.whl') } 'must end with'
    Write-Host 'SM20E_WHEEL_DETERMINISM_OK'

    $artifacts=Join-Path $root 'artifacts'
    $offline=Write-VllmOfflineRelease -Repository $repoRoot -ProjectCommit $commit -ReleaseManifestPath $script:VllmSm20eReleaseManifestPath -WheelPath $wheel1.Path -ArtifactsDirectory $artifacts
    if(-not([string]$offline.release).Equals($script:VllmSm20eRelease,[StringComparison]::Ordinal)-or-not([string]$offline.tag).Equals($script:VllmSm20eTag,[StringComparison]::Ordinal)){throw 'SM-20E offline release identity mismatch.'}
    $plan=@(Get-VllmReleasePublicationAssetPlan -ArtifactsDirectory $artifacts -OfflineVerification $offline)
    if($plan.Count-ne4){throw "SM-20E offline fixture did not produce exactly four assets: $($plan.Count)"}
    $expected=Get-VllmReleaseOrdinalStrings -Values @(
        $script:VllmSm20eWheelName,
        ('vllm-windows-native-'+$script:VllmSm20eRelease+'.zip'),
        'release-index.json',
        'SHA256SUMS'
    )
    $actual=Get-VllmReleaseOrdinalStrings -Values @($plan|ForEach-Object{$_.name})
    Assert-VllmReleaseOrdinalSequence -Actual $actual -Expected $expected -Label 'SM-20E canonical asset set'
    Write-Host 'SM20E_OFFLINE_RELEASE_OK'

    $workspace=Join-Path $root 'workspace'
    [void][IO.Directory]::CreateDirectory($workspace)
    $state=[pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-sm20e-acceptance'
        repository=$script:VllmSm20eRepositorySlug
        release=$script:VllmSm20eRelease
        tag=$script:VllmSm20eTag
        project_commit=$commit
        tag_object=('a'*40)
        principal=$script:VllmSm20ePrincipal
        key_fingerprint='SHA256:source-only-fixture'
        release_manifest_path=$script:VllmSm20eReleaseManifestPath
        assets=@($plan|ForEach-Object{[pscustomobject][ordered]@{name=$_.name;size=[int64]$_.size;sha256=[string]$_.sha256}})
        published=$false
        release_id=$null
        release_url=$null
        created_utc='2026-09-27T00:00:00.0000000Z'
        published_utc=$null
    }
    $statePath=Write-VllmSm20eState -Workspace $workspace -State $state
    $loaded=Read-VllmSm20eState -Workspace $workspace
    if(-not([string]$loaded.project_commit).Equals($commit,[StringComparison]::OrdinalIgnoreCase)-or[bool]$loaded.published){throw 'SM-20E atomic state roundtrip mismatch.'}
    $bad=($state|ConvertTo-Json -Depth 12|ConvertFrom-Json)
    $bad.published=$true
    Assert-Fails { Assert-VllmSm20eStateObject -State $bad } 'published state is incomplete'
    $bad=($state|ConvertTo-Json -Depth 12|ConvertFrom-Json)
    $bad.tag='release/v1.0.0'
    Assert-Fails { Assert-VllmSm20eStateObject -State $bad } 'fixed identity mismatch'
    if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){throw 'SM-20E state writer did not create state file.'}
    Write-Host 'SM20E_STATE_CONTRACT_OK'

    $recovery=Join-Path $root 'recovery-cache'
    $untrusted=New-VllmSm20eUntrustedRecoveryState -CacheRoot $recovery -Confirm:$false
    if(-not(Test-Path -LiteralPath $untrusted.staging -PathType Container)-or-not(Test-Path -LiteralPath (Join-Path $untrusted.staging 'partial.bin') -PathType Leaf)-or-not(Test-Path -LiteralPath (Join-Path $untrusted.garbage 'acquisition-receipt.json') -PathType Leaf)){throw 'SM-20E untrusted recovery state fixture is incomplete.'}
    Write-Host 'SM20E_RECOVERY_FIXTURE_OK'

    $exerciseWorkspace=Join-Path $root 'exercise-workspace'
    [void][IO.Directory]::CreateDirectory($exerciseWorkspace)
    $exerciseState=($state|ConvertTo-Json -Depth 12|ConvertFrom-Json)
    $exerciseState.tag_object=('b'*40)
    $firstExercise=Enter-VllmSm20eExerciseRoot -Workspace $exerciseWorkspace -State $exerciseState -Confirm:$false
    if([bool]$firstExercise.retry-or-not(Test-Path -LiteralPath $firstExercise.owner -PathType Leaf)){throw 'SM-20E first exercise entry did not create an owned root.'}
    $retryExercise=Enter-VllmSm20eExerciseRoot -Workspace $exerciseWorkspace -State $exerciseState -Confirm:$false
    if(-not[bool]$retryExercise.retry-or-not([string]$retryExercise.root).Equals([string]$firstExercise.root,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E incomplete exercise did not resume from its owned root.'}
    [IO.File]::WriteAllText([string]$firstExercise.proof,'{}',[Text.UTF8Encoding]::new($false))
    Assert-Fails { Enter-VllmSm20eExerciseRoot -Workspace $exerciseWorkspace -State $exerciseState -Confirm:$false | Out-Null } 'already completed'
    Remove-Item -LiteralPath [string]$firstExercise.proof -Force

    $foreignWorkspace=Join-Path $root 'foreign-exercise-workspace'
    [void][IO.Directory]::CreateDirectory((Join-Path $foreignWorkspace 'exercise'))
    Assert-Fails { Enter-VllmSm20eExerciseRoot -Workspace $foreignWorkspace -State $exerciseState -Confirm:$false | Out-Null } 'not owned'
    $wrongOwner=Get-Content -LiteralPath $firstExercise.owner -Raw|ConvertFrom-Json
    $wrongOwner.tag_object=('c'*40)
    $wrongOwnerPath=Join-Path $foreignWorkspace 'exercise\sm20e-exercise-owner.json'
    $null=Write-VllmAtomicJsonFile -Path $wrongOwnerPath -Value $wrongOwner -Depth 6
    Assert-Fails { Enter-VllmSm20eExerciseRoot -Workspace $foreignWorkspace -State $exerciseState -Confirm:$false | Out-Null } 'does not match'
    Write-Host 'SM20E_EXERCISE_RETRY_CONTRACT_OK'

    $top=Get-Content -LiteralPath (Join-Path $repoRoot 'release-acquisition-acceptance.ps1') -Raw
    if($top.IndexOf("ValidateSet('Prepare','Publish','Verify','Exercise')",[StringComparison]::Ordinal)-lt0){throw 'SM-20E top-level mode surface drifted.'}
    $exerciseStart=$top.IndexOf("    'Exercise' {",[StringComparison]::Ordinal)
    if($exerciseStart-lt0){throw 'SM-20E Exercise mode is missing.'}
    $exerciseBlock=$top.Substring($exerciseStart)
    if($exerciseBlock.IndexOf('-GitSourceUrl',[StringComparison]::OrdinalIgnoreCase)-ge0){throw 'SM-20E trusted Exercise must not override canonical Git transport.'}
    if($exerciseBlock.IndexOf('Invoke-VllmReleaseAcquisition',[StringComparison]::Ordinal)-lt0-or$exerciseBlock.IndexOf('Invoke-VllmSm20eHandoffProof',[StringComparison]::Ordinal)-lt0){throw 'SM-20E Exercise mode does not compose the production acquisition/handoff path.'}
    Write-Host 'SM20E_OPERATOR_SURFACE_OK'

    Write-Host 'RELEASE_ACQUISITION_ACCEPTANCE_CONTRACT_OK'
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
