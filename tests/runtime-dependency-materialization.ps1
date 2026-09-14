[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PythonArchivePath,
    [Parameter(Mandatory)][string]$UvArchivePath,
    [string]$ScratchRoot=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1')
$repoRoot=Split-Path -Parent $PSScriptRoot
$bootstrapPython=Join-Path $repoRoot 'bootstrap-python.ps1'
$bootstrapUv=Join-Path $repoRoot 'bootstrap-uv.ps1'
$bootstrapVenv=Join-Path $repoRoot 'bootstrap-venv.ps1'
$bootstrapDependencies=Join-Path $repoRoot 'bootstrap-dependencies.ps1'
$runtimeManifest=Join-Path $repoRoot 'manifests\runtime\dependencies-v0.27.1-windows-x86_64.json'
$goodLock=Join-Path $PSScriptRoot 'fixtures\runtime-dependencies-colorama.lock.txt'
$badHashLock=Join-Path $PSScriptRoot 'fixtures\runtime-dependencies-colorama-bad-hash.lock.txt'
foreach($path in @($PythonArchivePath,$UvArchivePath,$bootstrapDependencies,$runtimeManifest,$goodLock,$badHashLock)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Fixture or prerequisite missing: $path"}
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$ExpectedMessage)
    try { & $Action; throw "Expected failure did not occur: $Name" }
    catch {
        $message=$_.Exception.Message
        if($message -eq "Expected failure did not occur: $Name"){throw}
        if($message.IndexOf($ExpectedMessage,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "Expected '$Name' to contain '$ExpectedMessage', got: $message"}
        Write-Host "REJECT $Name :: $message"
    }
}
function Get-TestEnvironmentSnapshot {
    $snapshot=@{}
    foreach($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$snapshot[[string]$entry.Key]=[string]$entry.Value}
    return $snapshot
}
function Assert-EnvironmentEqual {
    param([Parameter(Mandatory)][hashtable]$Before,[Parameter(Mandatory)][hashtable]$After)
    $keys=@($Before.Keys+$After.Keys|Sort-Object -Unique)
    $delta=@($keys|Where-Object{(-not $Before.ContainsKey($_))-or(-not $After.ContainsKey($_))-or $Before[$_] -ne $After[$_]})
    if($delta.Count){throw "Process environment changed: $($delta -join ', ')"}
}function Write-MaterializationManifest {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$LockPath)
    $manifest=Get-Content -LiteralPath $runtimeManifest -Raw|ConvertFrom-Json
    $manifest.accepted_packages=[pscustomobject][ordered]@{colorama='0.4.6'}
    $manifest.allowed_extra_distributions=@('vllm')
    $manifest.accepted_binary_artifacts=[pscustomobject]@{}
    $lockItem=Get-Item -LiteralPath $LockPath
    $manifest.lock.path=[IO.Path]::GetFullPath($LockPath)
    $manifest.lock.size_bytes=[int64]$lockItem.Length
    $manifest.lock.sha256=(Get-FileHash -LiteralPath $LockPath -Algorithm SHA256).Hash
    $manifest.lock.package_count=1
    $manifest.note='Regression fixture: exact colorama dependency only.'
    [IO.File]::WriteAllText($Path,($manifest|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Write-InterruptedTransactionState {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][ValidateSet('materializing','prepared')][string]$Phase)
    $m=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
    $state=[ordered]@{
        schema_version=1
        component='runtime-dependencies-transaction'
        milestone=[string]$m.milestone
        platform=[string]$m.platform
        transaction_id=$TransactionId
        phase=$Phase
        target=Join-Path $Root 'runtime\venv'
        staging=Join-Path $Root 'runtime\.venv-dependencies-staging'
        backup=Join-Path $Root 'runtime\.venv-dependencies-backup'
        transaction_receipt=Join-Path $Root 'forensic\runtime-dependencies-transaction-v0.27.1.json'
        dependency_receipt=Join-Path $Root 'forensic\runtime-dependencies-v0.27.1.json'
        base_venv_receipt=Join-Path $Root 'forensic\venv-bootstrap-v0.27.1.json'
        manifest=[IO.Path]::GetFullPath($ManifestPath)
        lock_sha256=[string]$m.lock.sha256
    }
    [IO.File]::WriteAllText([string]$state.transaction_receipt,($state|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    return [string]$state.transaction_receipt
}
function Assert-ColoramaReady {
    param([Parameter(Mandatory)][string]$Root)
    $python=Join-Path $Root 'Scripts\python.exe'
    $rows=@(& $python -I -c "import importlib.metadata as m; print('\n'.join(sorted((d.metadata['Name'].lower().replace('_','-')+'=='+d.version) for d in m.distributions() if d.metadata.get('Name'))))")
    if($LASTEXITCODE -ne 0){throw 'Distribution probe failed.'}
    if($rows.Count -ne 1 -or $rows[0] -ne 'colorama==0.4.6'){throw "Unexpected materialized distributions: $($rows -join ', ')"}
    if(Test-Path -LiteralPath (Join-Path $Root 'Lib\site-packages\pip') -PathType Container){throw 'pip was unexpectedly installed.'}
}
function Assert-NoDependencyTransactionArtifacts {
    param([Parameter(Mandatory)][string]$Root)
    foreach($path in @(
        (Join-Path $Root 'runtime\.venv-dependencies-backup'),
        (Join-Path $Root 'runtime\.venv-dependencies-staging'),
        (Join-Path $Root 'forensic\runtime-dependencies-transaction-v0.27.1.json')
    )){if(Test-Path -LiteralPath $path){throw "Dependency transaction artifact was left behind: $path"}}
}
function Assert-Marker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Expected)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Marker missing: $Path"}
    if((Get-Content -LiteralPath $Path -Raw).Trim() -ne $Expected){throw "Marker changed: $Path"}
}
$outerEnvironment=Get-TestEnvironmentSnapshot
if([string]::IsNullOrWhiteSpace($ScratchRoot)){$scratch=[IO.Path]::GetTempPath()}else{$scratch=[IO.Path]::GetFullPath($ScratchRoot);[void][IO.Directory]::CreateDirectory($scratch)}
$base=Join-Path $scratch ('vllm-runtime-dependency-test-'+[guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($base)
    $root=Join-Path $base 'root'
    $goodManifest=Join-Path $base 'good-manifest.json'
    $badHashManifest=Join-Path $base 'bad-hash-manifest.json'
    Write-MaterializationManifest -Path $goodManifest -LockPath $goodLock
    Write-MaterializationManifest -Path $badHashManifest -LockPath $badHashLock

    & $bootstrapPython -InstallationRoot $root -ArchivePath $PythonArchivePath -Json | Out-Null
    & $bootstrapUv -InstallationRoot $root -ArchivePath $UvArchivePath -Json | Out-Null
    $venvReceipt=(& $bootstrapVenv -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $venvReceipt.ready -or $venvReceipt.seeded){throw 'Base venv bootstrap did not create the expected unseeded state.'}
    $target=[string]$venvReceipt.root
    $baseReceipt=[string]$venvReceipt.receipt
    $baseReceiptRaw=Get-Content -LiteralPath $baseReceipt -Raw
    $baseReceiptHash=(Get-FileHash -LiteralPath $baseReceipt -Algorithm SHA256).Hash
    Write-Host 'DEPENDENCY_BASE_VENV_READY'

    $baseDrift=Join-Path $target 'local.marker'
    [IO.File]::WriteAllText($baseDrift,'UNMANAGED',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json | Out-Null } -Name 'non-exact-unseeded-base' -ExpectedMessage 'neither the exact unseeded bootstrap state'
    Remove-Item -LiteralPath $baseDrift -Force
    Write-Host 'DEPENDENCY_EXACT_UNSEEDED_BASE_REJECTION_OK'

    $env:UV_INDEX_URL='https://invalid.example.test/simple'
    $env:UV_CACHE_DIR='C:\BAD-CACHE'
    $env:PYTHONPATH='C:\BAD-PYTHONPATH'
    $env:VIRTUAL_ENV='C:\OLD-VENV'
    $before=Get-TestEnvironmentSnapshot
    $result=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    $after=Get-TestEnvironmentSnapshot
    Assert-EnvironmentEqual -Before $before -After $after
    if(-not $result.ready -or $result.idempotent -or $result.package_count -ne 1){throw 'Happy-path materialization receipt mismatch.'}
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    if((Get-Content -LiteralPath $baseReceipt -Raw) -ne $baseReceiptRaw){throw 'Base venv receipt changed during materialization.'}
    if((Get-FileHash -LiteralPath $baseReceipt -Algorithm SHA256).Hash -ne $baseReceiptHash){throw 'Base venv receipt hash changed during materialization.'}
    Write-Host 'DEPENDENCY_HAPPY_PATH_AND_ENV_RESTORE_OK'
    $dependencyReceipt=[string]$result.receipt
    $dependencyReceiptRaw=Get-Content -LiteralPath $dependencyReceipt -Raw
    $marker=Join-Path $target 'idempotence.marker'
    [IO.File]::WriteAllText($marker,'KEEP',[Text.Encoding]::ASCII)
    $idem=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $idem.ready -or -not $idem.idempotent){throw 'Idempotent rerun did not report an unchanged ready environment.'}
    Assert-Marker -Path $marker -Expected 'KEEP'
    if((Get-Content -LiteralPath $dependencyReceipt -Raw) -ne $dependencyReceiptRaw){throw 'Idempotent rerun rewrote the dependency receipt.'}
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_IDEMPOTENCE_OK'

    $receiptObject=$dependencyReceiptRaw|ConvertFrom-Json
    $receiptObject.python_version='3.12.0'
    [IO.File]::WriteAllText($dependencyReceipt,($receiptObject|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json | Out-Null } -Name 'dependency-receipt-field-drift' -ExpectedMessage 'receipt exists but the managed venv does not match'
    [IO.File]::WriteAllText($dependencyReceipt,$dependencyReceiptRaw,[Text.UTF8Encoding]::new($false))
    if((Get-Content -LiteralPath $dependencyReceipt -Raw) -ne $dependencyReceiptRaw){throw 'Dependency receipt restore after deterministic-field drift failed.'}
    Write-Host 'DEPENDENCY_RECEIPT_EXACT_SCHEMA_REJECTION_OK'

    $stagingPath=Join-Path $root 'runtime\.venv-dependencies-staging'
    $backupPath=Join-Path $root 'runtime\.venv-dependencies-backup'
    [void][IO.Directory]::CreateDirectory($stagingPath)
    [IO.File]::WriteAllText((Join-Path $stagingPath 'partial.marker'),'PARTIAL',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedTransactionState -Root $root -ManifestPath $goodManifest -TransactionId $tx -Phase 'materializing')
    $recovered=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Materializing-state recovery did not report a rolled-back idempotent environment.'}
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_INTERRUPTED_MATERIALIZING_RECOVERY_OK'

    Move-Item -LiteralPath $target -Destination $backupPath
    [void][IO.Directory]::CreateDirectory($stagingPath)
    [IO.File]::WriteAllText((Join-Path $stagingPath 'prepared.marker'),'PREPARED',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedTransactionState -Root $root -ManifestPath $goodManifest -TransactionId $tx -Phase 'prepared')
    $recovered=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Pre-activation recovery did not restore the prior environment.'}
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_INTERRUPTED_PRE_ACTIVATION_RECOVERY_OK'

    Move-Item -LiteralPath $target -Destination $backupPath
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'candidate.marker'),'CANDIDATE',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedTransactionState -Root $root -ManifestPath $goodManifest -TransactionId $tx -Phase 'prepared')
    $recovered=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Post-activation/pre-commit recovery did not restore the prior environment.'}
    Assert-Marker -Path $marker -Expected 'KEEP'
    if(Test-Path -LiteralPath (Join-Path $target 'candidate.marker')){throw 'Interrupted candidate target survived rollback.'}
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_INTERRUPTED_POST_ACTIVATION_RECOVERY_OK'

    [void][IO.Directory]::CreateDirectory($backupPath)
    [IO.File]::WriteAllText((Join-Path $backupPath 'stale-backup.marker'),'STALE',[Text.Encoding]::ASCII)
    $committedTx=[string](($dependencyReceiptRaw|ConvertFrom-Json).transaction_id)
    [void](Write-InterruptedTransactionState -Root $root -ManifestPath $goodManifest -TransactionId $committedTx -Phase 'prepared')
    $recovered=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'committed-cleanup'){throw 'Committed-state recovery did not clean stale transaction artifacts.'}
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_INTERRUPTED_COMMITTED_CLEANUP_OK'

    [IO.File]::WriteAllText($baseReceipt,($baseReceiptRaw+"`n"),[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json | Out-Null } -Name 'base-receipt-byte-drift' -ExpectedMessage 'receipt exists but the managed venv does not match'
    [IO.File]::WriteAllText($baseReceipt,$baseReceiptRaw,[Text.UTF8Encoding]::new($false))
    if((Get-FileHash -LiteralPath $baseReceipt -Algorithm SHA256).Hash -ne $baseReceiptHash){throw 'Base receipt restore after byte-drift test failed.'}
    Write-Host 'DEPENDENCY_BASE_RECEIPT_HASH_BINDING_OK'

    $fakeDist=Join-Path $target 'Lib\site-packages\surprise_package-1.0.dist-info'
    [void][IO.Directory]::CreateDirectory($fakeDist)
    [IO.File]::WriteAllText((Join-Path $fakeDist 'METADATA'),"Metadata-Version: 2.1`nName: surprise-package`nVersion: 1.0`n",[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json | Out-Null } -Name 'unexpected-distribution-drift' -ExpectedMessage 'receipt exists but the managed venv does not match'
    Assert-Marker -Path $marker -Expected 'KEEP'
    if((Get-Content -LiteralPath $dependencyReceipt -Raw) -ne $dependencyReceiptRaw){throw 'Drift rejection changed the dependency receipt.'}
    Remove-Item -LiteralPath $fakeDist -Recurse -Force
    Assert-ColoramaReady -Root $target
    Write-Host 'DEPENDENCY_FAIL_CLOSED_DRIFT_OK'

    $held=Enter-VllmOperationLock -InstallationRoot $root -Operation 'dependency-test-holder'
    try {
        Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Json | Out-Null } -Name 'operation-lock-contention' -ExpectedMessage 'Another vLLM Windows Native lifecycle operation is active'
    }
    finally { Exit-VllmOperationLock -Lock $held }
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-ColoramaReady -Root $target
    Write-Host 'DEPENDENCY_LOCK_CONTENTION_OK'
    $beforeBadHash=Get-TestEnvironmentSnapshot
    Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $badHashManifest -InstallationRoot $root -Force -Json | Out-Null } -Name 'bad-hash-rollback' -ExpectedMessage 'uv pip sync failed with exit code'
    $afterBadHash=Get-TestEnvironmentSnapshot
    Assert-EnvironmentEqual -Before $beforeBadHash -After $afterBadHash
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    if((Get-Content -LiteralPath $dependencyReceipt -Raw) -ne $dependencyReceiptRaw){throw 'Bad-hash rollback changed the prior dependency receipt.'}
    Write-Host 'DEPENDENCY_BAD_HASH_ROLLBACK_OK'

    $receiptHandle=[IO.File]::Open($dependencyReceipt,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        Test-ExpectedFailure -Action { & $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Force -Json | Out-Null } -Name 'receipt-commit-rollback' -ExpectedMessage 'Cannot create a file'
    }
    finally { $receiptHandle.Dispose() }
    Assert-Marker -Path $marker -Expected 'KEEP'
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    if((Get-Content -LiteralPath $dependencyReceipt -Raw) -ne $dependencyReceiptRaw){throw 'Receipt commit rollback changed the prior dependency receipt.'}
    Write-Host 'DEPENDENCY_RECEIPT_COMMIT_ROLLBACK_OK'

    $forced=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Force -Json)|ConvertFrom-Json
    if(-not $forced.ready -or $forced.idempotent){throw 'Forced replacement did not report a freshly materialized ready environment.'}
    if(Test-Path -LiteralPath $marker){throw 'Forced replacement retained content from the prior venv.'}
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_FORCE_REPLACEMENT_OK'

    $offline=(& $bootstrapDependencies -ManifestPath $goodManifest -InstallationRoot $root -Force -Offline -Json)|ConvertFrom-Json
    if(-not $offline.ready -or $offline.idempotent -or -not $offline.offline){throw 'Offline forced replacement did not report a fresh offline-ready environment.'}
    Assert-ColoramaReady -Root $target
    Assert-NoDependencyTransactionArtifacts -Root $root
    Write-Host 'DEPENDENCY_OFFLINE_FORCE_REPLACEMENT_OK'
    Write-Host 'RUNTIME_DEPENDENCY_MATERIALIZATION_REGRESSION_OK'
}
finally {
    try { Restore-VllmProcessEnvironment -Snapshot $outerEnvironment } catch { Write-Warning "Failed to restore test caller environment exactly: $($_.Exception.Message)" }
    if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction Stop}
}
