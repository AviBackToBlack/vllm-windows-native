[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ReleaseManifestPath = 'manifests/release/v0.27.1-windows-x86_64.json',
    [string] $InstallationRoot = 'D:\AI\vLLM',
    [Parameter(Mandatory)][string] $WheelPath,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\lifecycle.ps1')
. (Join-Path $PSScriptRoot 'scripts\update-planner.ps1')
. (Join-Path $PSScriptRoot 'scripts\update-staging.ps1')
. (Join-Path $PSScriptRoot 'scripts\update-transaction.ps1')
. (Join-Path $PSScriptRoot 'scripts\update-integration.ps1')

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'update.ps1 supports native Windows x64 only.'
}

$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
if (-not (Test-Path -LiteralPath $InstallationRoot -PathType Container)) {
    throw "Installation root does not exist: $InstallationRoot"
}
$targetManifestPath = Resolve-ProjectPath -Path $ReleaseManifestPath -BasePath $PSScriptRoot
$targetWheelPath = [IO.Path]::GetFullPath($WheelPath)

function Enter-VllmUpdateOrchestratorLock {
    param([Parameter(Mandatory)][string]$Root)
    $stateDir = Join-Path $Root 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw "Install state directory is missing: $stateDir"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $stateDir -RelativePath 'state')
    $lockPath = Join-Path $stateDir 'install-orchestrator.lock'
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Root -Path $lockPath -RelativePath 'state\install-orchestrator.lock')
    try {
        $stream = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw "Another top-level install/update/uninstall operation is active for '$Root'."
    } catch [UnauthorizedAccessException] {
        throw "Install orchestrator lock cannot be acquired safely: $lockPath"
    }
    try {
        $rootPhysical = Get-VllmPhysicalCandidatePath -Path $Root -Format Guid
        $expected = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootPhysical, 'state\install-orchestrator.lock'))
        $actual = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Install orchestrator lock resolves outside expected location: $actual"
        }
        $linkCount = [VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)
        if ($linkCount -ne 1) {
            throw "Install orchestrator lock has unexpected hard-link count $linkCount; refusing update."
        }
        return [pscustomobject]@{ Stream=$stream; Path=$lockPath }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Exit-VllmUpdateOrchestratorLock {
    param([Parameter(Mandatory)]$Lock)
    if ($null -ne $Lock.Stream) { $Lock.Stream.Dispose() }
}

function Assert-VllmUpdateWhatIfRecoveryAbsent {
    param([Parameter(Mandatory)][string]$Root)
    foreach($relative in @('state\update-transaction.json','work\update-transaction')){
        $path=Join-Path $Root $relative
        if((Get-VllmPathEntryInfo -Path $path).Exists){
            throw "Pending update transaction requires recovery at '$path'; -WhatIf preserves recovery evidence and refuses to mutate it."
        }
    }
}

function Assert-VllmRecoveredGeneration {
    param(
        [Parameter(Mandatory)][ValidateSet('source','target')][string]$Mode,
        [Parameter(Mandatory)][string]$ExpectedGenerationId,
        [Parameter(Mandatory)]$Journal
    )
    $context = Get-VllmUpdateSourceContext -InstallationRoot $InstallationRoot
    $identity = if ($Mode -eq 'source') { $Journal.source } else { $Journal.target }

    if (-not ([string]$context.Committed.State.generation_id).Equals($ExpectedGenerationId,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovered $Mode generation_id does not match the transaction identity."
    }
    if ([string]$context.Committed.State.release -ne [string]$identity.release) {
        throw "Recovered $Mode release does not match the transaction identity."
    }
    if (-not ([string]$context.Committed.State.release_manifest_sha256).Equals(([string]$identity.manifest_sha256),[StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovered $Mode release manifest digest does not match the transaction identity."
    }
    if (-not (Test-VllmUpdatePathEqual -A ([string]$context.ModelsRoot) -B ([string]$Journal.models_root))) {
        throw "Recovered $Mode models root does not match the transaction identity."
    }
}

$orchestratorLock = $null
$operationLock = $null
try {
    $orchestratorLock = Enter-VllmUpdateOrchestratorLock -Root $InstallationRoot
    $operationLock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'update-plan'

    if ($WhatIfPreference) {
        Assert-VllmUpdateWhatIfRecoveryAbsent -Root $InstallationRoot
    } else {
        $recoveryValidator = (Get-Item Function:\Assert-VllmRecoveredGeneration).ScriptBlock
        $recovery = Invoke-VllmUpdateTransactionRecovery -InstallationRoot $InstallationRoot -ValidateGeneration $recoveryValidator
        if ($recovery.recovered) { Write-Verbose "Recovered pending update transaction to '$($recovery.generation)' generation before planning." }
    }
    $source = Get-VllmUpdateSourceContext -InstallationRoot $InstallationRoot
    $target = Get-VllmUpdateReleaseContext -ReleaseManifestPath $targetManifestPath -InstallationRoot $InstallationRoot -ModelsRoot $source.ModelsRoot -WheelPath $targetWheelPath -RequireUpdaterPlanner
    $plan = Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $target
    $managedPlan = @(Get-VllmUpdateIntegrationManagedPlan -Plan $plan)

    if ($plan.idempotent) {
        if ($Json) {
            $plan | ConvertTo-Json -Depth 12
        } else {
            Write-Host "Source: $($plan.source.release) [$($plan.source.generation_id)]"
            Write-Host "Target: $($plan.target.release)"
            Write-Host 'UPDATE_NOOP'
        }
        return
    }

    $action = "Activate release '$($plan.target.release)' from '$($plan.source.release)'"
    if ($WhatIfPreference) {
        [void]$PSCmdlet.ShouldProcess($InstallationRoot,$action)
        if ($Json) {
            $plan | ConvertTo-Json -Depth 12
        } else {
            Write-Host "Source: $($plan.source.release) [$($plan.source.generation_id)]"
            Write-Host "Target: $($plan.target.release)"
            Write-Host "Plan:   distribution reuse=$($plan.counts.distribution_reuse) replace=$($plan.counts.distribution_replace) add=$($plan.counts.distribution_add) retire=$($plan.counts.distribution_retire)"
            Write-Host "        managed      reuse=$($plan.counts.managed_reuse) replace=$($plan.counts.managed_replace) add=$($plan.counts.managed_add) retire=$($plan.counts.managed_retire)"
            Write-Host 'UPDATE_PLAN_READY'
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($InstallationRoot,$action)) {
        if (-not $Json) { Write-Host 'UPDATE_CANCELLED' }
        return
    }

    $prepared=Invoke-VllmUpdateProductionTransactionPreparation -InstallationRoot $InstallationRoot -SourceContext $source -TargetContext $target -Plan $plan -ManagedPlan $managedPlan -WheelPath $targetWheelPath
    $recoveryValidator=(Get-Item Function:\Assert-VllmRecoveredGeneration).ScriptBlock
    $result=Complete-VllmUpdateProductionTransaction -InstallationRoot $InstallationRoot -SourceContext $source -TargetContext $target -Prepared $prepared -ValidateGeneration $recoveryValidator
    if($Json){
        $result|ConvertTo-Json -Depth 8
    }else{
        Write-Host "Updated: $($plan.source.release) -> $($plan.target.release)"
        Write-Host "Generation: $($result.generation_id)"
        Write-Host 'UPDATE_READY'
    }
} finally {
    if ($null -ne $operationLock) { Exit-VllmOperationLock -Lock $operationLock; $operationLock=$null }
    if ($null -ne $orchestratorLock) { Exit-VllmUpdateOrchestratorLock -Lock $orchestratorLock; $orchestratorLock=$null }
}
