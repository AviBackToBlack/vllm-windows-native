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

function Assert-VllmUpdateRecoveryStateAbsent {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($relative in @('state\update-transaction.json','work\update-transaction')) {
        $path = Join-Path $Root $relative
        $entry = Get-VllmPathEntryInfo -Path $path
        if ($entry.Exists) {
            throw "Pending update transaction evidence exists at '$path'. SM-18C does not implement transaction recovery yet; preserve the evidence for the recovery slice."
        }
    }
}

$orchestratorLock = $null
$operationLock = $null
try {
    $orchestratorLock = Enter-VllmUpdateOrchestratorLock -Root $InstallationRoot
    $operationLock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'update-plan'

    Assert-VllmUpdateRecoveryStateAbsent -Root $InstallationRoot
    $source = Get-VllmUpdateSourceContext -InstallationRoot $InstallationRoot
    $target = Get-VllmUpdateReleaseContext -ReleaseManifestPath $targetManifestPath -InstallationRoot $InstallationRoot -ModelsRoot $source.ModelsRoot -WheelPath $targetWheelPath -RequireUpdaterPlanner
    $plan = Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $target
    [void](Get-VllmUpdateManagedStagingPlan -Plan $plan)

    if (-not $plan.idempotent -and -not $WhatIfPreference) {
        throw 'Update target requires activation. SM-18C implements validation/planning and staging-proof primitives only; live staging/activation is not enabled until the transaction journal exists. Use -WhatIf to inspect the exact plan.'
    }
    if (-not $plan.idempotent -and $WhatIfPreference) {
        [void]$PSCmdlet.ShouldProcess($InstallationRoot, "Activate release '$($plan.target.release)' from '$($plan.source.release)'")
    }

    if ($Json) {
        $plan | ConvertTo-Json -Depth 12
    } else {
        Write-Host "Source: $($plan.source.release) [$($plan.source.generation_id)]"
        Write-Host "Target: $($plan.target.release)"
        Write-Host "Plan:   distribution reuse=$($plan.counts.distribution_reuse) replace=$($plan.counts.distribution_replace) add=$($plan.counts.distribution_add) retire=$($plan.counts.distribution_retire)"
        Write-Host "        managed      reuse=$($plan.counts.managed_reuse) replace=$($plan.counts.managed_replace) add=$($plan.counts.managed_add) retire=$($plan.counts.managed_retire)"
        if ($plan.idempotent) { Write-Host 'UPDATE_NOOP' } else { Write-Host 'UPDATE_PLAN_READY' }
    }
} finally {
    if ($null -ne $operationLock) { Exit-VllmOperationLock -Lock $operationLock; $operationLock=$null }
    if ($null -ne $orchestratorLock) { Exit-VllmUpdateOrchestratorLock -Lock $orchestratorLock; $orchestratorLock=$null }
}
