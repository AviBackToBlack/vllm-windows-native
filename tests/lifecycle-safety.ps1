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

    $danglingRootTarget = Join-Path $base 'dangling-root-target'
    New-Item -ItemType Directory -Path $danglingRootTarget | Out-Null
    $danglingRoot = Join-Path $base 'dangling-root'
    New-Item -ItemType Junction -Path $danglingRoot -Target $danglingRootTarget | Out-Null
    Remove-Item -LiteralPath $danglingRootTarget -Recurse -Force
    Test-ExpectedFailure { Assert-VllmSafeInstallationRoot $danglingRoot } 'dangling-install-root'
    Remove-Item -LiteralPath $danglingRoot -Force

    New-Item -ItemType Directory -Path $root | Out-Null
    [void](Assert-VllmSafeInstallationRoot $root)
    [void](Assert-VllmManagedChildPhysicalLocation $root (Join-Path $root 'cache') 'cache')
    $normalizedDotDot = Get-VllmNormalizedPath (Join-Path $root 'cache\..\logs')
    if (-not $normalizedDotDot.Equals((Join-Path $root 'logs'), [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Dot-dot normalization mismatch.' }
    [void](Assert-VllmManagedChildPhysicalLocation $root (Join-Path $root 'logs') 'cache\..\logs')
    Test-ExpectedFailure { Assert-VllmManagedChildPhysicalLocation $root (Join-Path $base 'escape') '..\escape' } 'managed-relative-escape'

    $outside = Join-Path $base 'outside-cache'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $cacheLink = Join-Path $root 'cache'
    New-Item -ItemType Junction -Path $cacheLink -Target $outside | Out-Null
    Test-ExpectedFailure { Assert-VllmManagedChildPhysicalLocation $root (Join-Path $cacheLink 'future') 'cache\future' } 'managed-child-junction'
    Remove-Item -LiteralPath $cacheLink -Force

    $danglingTarget = Join-Path $base 'dangling-target'
    New-Item -ItemType Directory -Path $danglingTarget | Out-Null
    $danglingManaged = Join-Path $root 'tmp'
    New-Item -ItemType Junction -Path $danglingManaged -Target $danglingTarget | Out-Null
    Remove-Item -LiteralPath $danglingTarget -Recurse -Force
    Test-ExpectedFailure { Assert-VllmExistingManagedTopLevelLocations $root } 'dangling-managed-junction'
    Remove-Item -LiteralPath $danglingManaged -Force

    $reservedFile = Join-Path $root 'state'
    Set-Content -LiteralPath $reservedFile -Value 'user-file' -Encoding ascii
    Test-ExpectedFailure { Assert-VllmExistingManagedTopLevelLocations $root } 'managed-top-level-file'
    Remove-Item -LiteralPath $reservedFile -Force

    $defaultModels = Join-Path $root 'models'
    [void](Assert-VllmSafeModelsRoot $root $defaultModels)
    $modelsFile = Join-Path $base 'models-file.bin'
    Set-Content -LiteralPath $modelsFile -Value 'not-a-directory' -Encoding ascii
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root $modelsFile } 'models-root-file'
    $externalModels = Join-Path $base 'external-models'
    [void](Assert-VllmSafeModelsRoot $root $externalModels)
    $danglingModelsTarget = Join-Path $base 'dangling-models-target'
    New-Item -ItemType Directory -Path $danglingModelsTarget | Out-Null
    $danglingModels = Join-Path $base 'dangling-models'
    New-Item -ItemType Junction -Path $danglingModels -Target $danglingModelsTarget | Out-Null
    Remove-Item -LiteralPath $danglingModelsTarget -Recurse -Force
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root $danglingModels } 'dangling-models-root'
    Remove-Item -LiteralPath $danglingModels -Force
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root (Join-Path $root 'other-models') } 'models-inside-install'

    New-Item -ItemType Directory -Path $defaultModels | Out-Null
    $externalAlias = Join-Path $base 'external-alias'
    New-Item -ItemType Junction -Path $externalAlias -Target $defaultModels | Out-Null
    Test-ExpectedFailure { Assert-VllmSafeModelsRoot $root $externalAlias } 'external-model-alias-into-install'

    $shellExe = (Get-Process -Id $PID).Path
    $childScript = Join-Path $PSScriptRoot 'lifecycle-lock-child.ps1'
    $literalLockRoot = Join-Path $base 'install-[literal]'
    $literalLock = Enter-VllmOperationLock -InstallationRoot $literalLockRoot -Operation 'literal-root'
    Exit-VllmOperationLock $literalLock
    if (-not (Test-Path -LiteralPath $literalLockRoot -PathType Container)) { throw 'Literal bracket installation root was not created exactly.' }
    Write-Host 'LITERAL_LOCK_ROOT_OK'

    $lockRoot = Join-Path $base "lock'root"
    $lock = Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'test-one'
    Test-ExpectedFailure { Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'test-two' } 'operation-lock-contention'
    & $shellExe -NoLogo -NoProfile -File $childScript -RepoRoot $repoRoot -InstallRoot $lockRoot
    $childBlockedExit = $LASTEXITCODE
    if ($childBlockedExit -ne 23) { throw "Cross-process lock contention returned unexpected exit $childBlockedExit." }
    Write-Host 'EXPECTED_REJECTION cross-process-operation-lock-contention'
    Exit-VllmOperationLock $lock
    & $shellExe -NoLogo -NoProfile -File $childScript -RepoRoot $repoRoot -InstallRoot $lockRoot
    $childAllowedExit = $LASTEXITCODE
    if ($childAllowedExit -ne 0) { throw "Child could not acquire lock after release; exit $childAllowedExit." }
    $lockPath = Join-Path $lockRoot '.vllm-operation.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw 'Released operation lock should remain as stale coordination metadata.' }
    Remove-Item -LiteralPath $lockPath -Force

    $sentinel = Join-Path $base 'outside-sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    New-Item -ItemType HardLink -Path $lockPath -Target $sentinel | Out-Null
    Test-ExpectedFailure { Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'hardlink-recovery' } 'hardlink-operation-lock'
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'Hardlink rejection modified external sentinel content.' }
    Write-Host 'HARDLINK_SENTINEL_PRESERVED'
    Remove-Item -LiteralPath $lockPath -Force

    Set-Content -LiteralPath $lockPath -Value 'stale=true' -Encoding ascii
    $stale = Enter-VllmOperationLock -InstallationRoot $lockRoot -Operation 'stale-recovery'
    Exit-VllmOperationLock $stale
    Write-Host 'LIFECYCLE_SAFETY_TEST_OK'
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
