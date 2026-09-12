$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Name)
    try { & $Action } catch { Write-Host "EXPECTED_REJECTION $Name"; return }
    throw "Expected rejection did not occur: $Name"
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('vllm-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
try {
    $root = Join-Path $base 'install'
    [void](Assert-VllmSafeInstallationRoot $root)
    Test-ExpectedFailure { Assert-VllmSafeInstallationRoot 'C:\' } 'volume-root'
    Test-ExpectedFailure { Assert-VllmSafeInstallationRoot '.\relative' } 'relative-install-root'

    $realParent = Join-Path $base 'real-parent'
    New-Item -ItemType Directory -Path $realParent | Out-Null
    $aliasParent = Join-Path $base 'alias-parent'
    New-Item -ItemType Junction -Path $aliasParent -Target $realParent | Out-Null
    Test-ExpectedFailure { Assert-VllmSafeInstallationRoot (Join-Path $aliasParent 'future-install') } 'root-under-junction'

    New-Item -ItemType Directory -Path $root | Out-Null
    [void](Assert-VllmSafeInstallationRoot $root)
    [void](Assert-VllmManagedChildPhysicalLocation $root (Join-Path $root 'cache') 'cache')
    $normalizedDotDot = Get-VllmNormalizedPath (Join-Path $root 'cache\..\logs')
    if (-not $normalizedDotDot.Equals((Join-Path $root 'logs'), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Dot-dot normalization mismatch.' }
    Test-ExpectedFailure { Assert-VllmManagedChildPhysicalLocation $root (Join-Path $base 'escape') '..\escape' } 'managed-relative-escape'

    $outside = Join-Path $base 'outside-cache'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $cacheLink = Join-Path $root 'cache'
    New-Item -ItemType Junction -Path $cacheLink -Target $outside | Out-Null
    Test-ExpectedFailure { Assert-VllmManagedChildPhysicalLocation $root (Join-Path $cacheLink 'future') 'cache\future' } 'managed-child-junction'
    Remove-Item -LiteralPath $cacheLink -Force

    $defaultModels = Join-Path $root 'models'
    [void](Assert-VllmSafeModelsRoot $root $defaultModels)
    $externalModels = Join-Path $base 'external-models'
    [void](Assert-VllmSafeModelsRoot $root $externalModels)
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root (Join-Path $root 'other-models') } 'models-inside-install'

    New-Item -ItemType Directory -Path $defaultModels | Out-Null
    $externalAlias = Join-Path $base 'external-alias'
    New-Item -ItemType Junction -Path $externalAlias -Target $defaultModels | Out-Null
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root $externalAlias } 'external-model-alias-into-install'

    $shellExe = (Get-Process -Id $PID).Path
    $childCommand = ". '$repoRoot\scripts\common.ps1'; try { `$childLock = Enter-VllmOperationLock -InstallationRoot '$root' -Operation 'child'; Exit-VllmOperationLock `$childLock; exit 0 } catch { exit 23 }"
    $lock = Enter-VllmOperationLock -InstallationRoot $root -Operation 'test-one'
    Test-ExpectedFailure { Enter-VllmOperationLock -InstallationRoot $root -Operation 'test-two' } 'operation-lock-contention'
    & $shellExe -NoLogo -NoProfile -Command $childCommand
    $childBlockedExit = $LASTEXITCODE
    if ($childBlockedExit -ne 23) { throw "Cross-process lock contention returned unexpected exit $childBlockedExit." }
    Write-Host 'EXPECTED_REJECTION cross-process-operation-lock-contention'
    Exit-VllmOperationLock $lock
    & $shellExe -NoLogo -NoProfile -Command $childCommand
    $childAllowedExit = $LASTEXITCODE
    if ($childAllowedExit -ne 0) { throw "Child could not acquire lock after release; exit $childAllowedExit." }
    $lockPath = Join-Path $root '.vllm-operation.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'Released operation lock should remain as stale coordination metadata.' }
    Remove-Item -LiteralPath $lockPath -Force

    $sentinel = Join-Path $base 'outside-sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    New-Item -ItemType HardLink -Path $lockPath -Target $sentinel | Out-Null
    $hardLinkRecovery = Enter-VllmOperationLock -InstallationRoot $root -Operation 'hardlink-recovery'
    Exit-VllmOperationLock $hardLinkRecovery
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'Hardlink recovery modified external sentinel content.' }
    Write-Host 'HARDLINK_SENTINEL_PRESERVED'

    Set-Content -LiteralPath (Join-Path $root '.vllm-operation.lock') -Value 'stale=true' -Encoding ascii
    $stale = Enter-VllmOperationLock -InstallationRoot $root -Operation 'stale-recovery'
    Exit-VllmOperationLock $stale
    Write-Host 'LIFECYCLE_SAFETY_TEST_OK'
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
