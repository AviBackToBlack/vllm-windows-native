[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PythonArchivePath,
    [Parameter(Mandatory)][string]$UvArchivePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\common.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrapPython = Join-Path $repoRoot 'bootstrap-python.ps1'
$bootstrapUv = Join-Path $repoRoot 'bootstrap-uv.ps1'
$bootstrapVenv = Join-Path $repoRoot 'bootstrap-venv.ps1'
$startScript = Join-Path $repoRoot 'start.ps1'
foreach($path in @($PythonArchivePath,$UvArchivePath)){ if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Fixture archive missing: $path"} }

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
    $s=@{}; foreach($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$s[[string]$e.Key]=[string]$e.Value}; return $s
}
function Assert-EnvironmentEqual {
    param([hashtable]$Before,[hashtable]$After)
    $keys=@($Before.Keys+$After.Keys|Sort-Object -Unique)
    $delta=@($keys|Where-Object{(-not $Before.ContainsKey($_))-or(-not $After.ContainsKey($_))-or $Before[$_] -ne $After[$_]})
    if($delta.Count){throw "Process environment changed: $($delta -join ', ')"}
}
function Write-VenvFixtureManifest {
    param([Parameter(Mandatory)][string]$Path,[int]$CreationFileCount=17,[string]$ManagedRelativePath='runtime/venv',[string]$UvBootstrapManifest='')
    $m=Get-Content (Join-Path $repoRoot 'manifests\bootstrap\venv-v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
    $m.install.expected_creation_file_count=$CreationFileCount
    $m.install.managed_relative_path=$ManagedRelativePath
    if(-not [string]::IsNullOrWhiteSpace($UvBootstrapManifest)){$m.uv.bootstrap_manifest=$UvBootstrapManifest}
    [IO.File]::WriteAllText($Path,($m|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}

$emptySentinel='VLLM_EMPTY_ENV_SENTINEL'
$extraEmptyProbe='VLLM_EXTRA_EMPTY_RESTORE_PROBE'
$base=Join-Path ([IO.Path]::GetTempPath()) ('vllm-runtime-venv-test-'+[guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($base)
    [VllmWindowsNative.NativeEnvironment]::SetProcessVariable($emptySentinel,'')
    $helperBefore=Get-TestEnvironmentSnapshot
    [Environment]::SetEnvironmentVariable($emptySentinel,'MUTATED','Process')
    [VllmWindowsNative.NativeEnvironment]::SetProcessVariable($extraEmptyProbe,'')
    Restore-VllmProcessEnvironment -Snapshot $helperBefore
    $helperAfter=Get-TestEnvironmentSnapshot
    Assert-EnvironmentEqual -Before $helperBefore -After $helperAfter
    if($helperAfter.ContainsKey($extraEmptyProbe)){throw 'Exact restore retained an extra empty environment variable.'}
    Write-Host 'EXACT_ENV_HELPER_EMPTY_ROUNDTRIP_OK'
    $root=Join-Path $base 'root'
    & $bootstrapPython -InstallationRoot $root -ArchivePath $PythonArchivePath -Json | Out-Null
    & $bootstrapUv -InstallationRoot $root -ArchivePath $UvArchivePath -Json | Out-Null
    $target=Join-Path $root 'runtime\venv'
    $runtime=Split-Path -Parent $target
    [void][IO.Directory]::CreateDirectory($runtime)
    [IO.File]::WriteAllText($target,'DO-NOT-DELETE',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action { & $bootstrapVenv -InstallationRoot $root -Force -Json | Out-Null } -Name 'managed-target-file' -ExpectedMessage 'exists but is not a directory'
    if((Get-Content $target -Raw).Trim() -ne 'DO-NOT-DELETE'){throw 'Managed target file changed.'}
    Remove-Item -LiteralPath $target -Force
    Write-Host 'VENV_TARGET_FILE_PRESERVED'

    $forensic=Join-Path $root 'forensic'; [void][IO.Directory]::CreateDirectory($forensic)
    $receipt=Join-Path $forensic 'venv-bootstrap-v0.27.1.json'; [void][IO.Directory]::CreateDirectory($receipt)
    $sentinel=Join-Path $receipt 'sentinel.txt'; [IO.File]::WriteAllText($sentinel,'DO-NOT-TOUCH',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action { & $bootstrapVenv -InstallationRoot $root -Json | Out-Null } -Name 'receipt-directory' -ExpectedMessage 'exists but is not a file'
    if((Get-Content $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH'){throw 'Receipt directory sentinel changed.'}
    Remove-Item -LiteralPath $receipt -Recurse -Force
    Write-Host 'VENV_RECEIPT_DIRECTORY_PRESERVED'
    $held=Enter-VllmOperationLock -InstallationRoot $root -Operation 'runtime-venv-test-holder'
    try {
        Test-ExpectedFailure -Action { & $bootstrapVenv -InstallationRoot $root -Json | Out-Null } -Name 'operation-lock-contention' -ExpectedMessage 'Another vLLM Windows Native lifecycle operation is active'
        if(Test-Path -LiteralPath $target){throw 'Contended bootstrap created runtime venv state.'}
    }
    finally { Exit-VllmOperationLock -Lock $held }
    Write-Host 'VENV_LOCK_CONTENTION_OK'

    [VllmWindowsNative.NativeEnvironment]::SetProcessVariable($emptySentinel,'')
    $env:UV_VENV_SEED='1'; $env:UV_PROJECT_ENVIRONMENT='C:\BAD'; $env:PYTHONPATH='C:\BAD'; $env:VIRTUAL_ENV='C:\OLD'
    $before=Get-TestEnvironmentSnapshot
    if(-not $before.ContainsKey($emptySentinel) -or $before[$emptySentinel] -ne ''){throw 'Empty environment sentinel precondition failed.'}
    $result=(& $bootstrapVenv -InstallationRoot $root -Json)|ConvertFrom-Json
    $after=Get-TestEnvironmentSnapshot
    Assert-EnvironmentEqual -Before $before -After $after
    if(-not $result.ready -or $result.seeded -or $result.python_version -ne '3.13.15' -or $result.uv_version -ne '0.12.13'){throw 'Happy-path venv receipt mismatch.'}
    if(Test-Path -LiteralPath (Join-Path $result.root 'Lib\site-packages\pip') -PathType Container){throw 'pip was unexpectedly seeded.'}
    Write-Host 'VENV_HAPPY_PATH_AND_ENV_RESTORE_OK'
    $beforeStart=Get-TestEnvironmentSnapshot
    $startContainment=Join-Path $root 'start-containment'
    & $startScript -Model 'fixture-model' -VllmExe (Join-Path $env:SystemRoot 'System32\where.exe') -ContainmentRoot $startContainment -ValidateOnly *> $null
    $afterStart=Get-TestEnvironmentSnapshot
    Assert-EnvironmentEqual -Before $beforeStart -After $afterStart
    Write-Host 'START_EXACT_ENV_RESTORE_OK'

    Test-ExpectedFailure -Action { & $bootstrapVenv -InstallationRoot $root -Json | Out-Null } -Name 'existing-target-without-force' -ExpectedMessage 'Managed venv target already exists'
    $marker=Join-Path $result.root 'replace-me.marker'; [IO.File]::WriteAllText($marker,'OLD',[Text.Encoding]::ASCII)
    $forced=(& $bootstrapVenv -InstallationRoot $root -Force -Json)|ConvertFrom-Json
    if(Test-Path -LiteralPath $marker){throw 'Forced replacement retained old marker.'}
    if(-not $forced.ready){throw 'Forced replacement did not report ready.'}
    Write-Host 'VENV_FORCE_REPLACEMENT_OK'

    $creationMarker=Join-Path $forced.root 'creation-failure.marker'; [IO.File]::WriteAllText($creationMarker,'OLD-CREATION-RUNTIME',[Text.Encoding]::ASCII)
    $uvManagedRoot=Split-Path -Parent $forced.uv
    $fakeUv=Join-Path $uvManagedRoot 'uv-fail.cmd'
    $fakeUvBody=@('@echo off','if "%~1"=="--version" goto version','if "%~1"=="venv" goto failvenv','exit /b 43',':version','echo uv 0.12.13 ^(0ebbd9274 2026-09-10 x86_64-pc-windows-msvc^)','exit /b 0',':failvenv','mkdir "%~2" >nul 2>nul','>"%~2\partial.txt" echo PARTIAL','exit /b 42')
    [IO.File]::WriteAllLines($fakeUv,$fakeUvBody,[Text.Encoding]::ASCII)
    $uvFixtureManifest=Join-Path $base 'uv-failure-manifest.json'
    $uvFixture=Get-Content (Join-Path $repoRoot 'manifests\bootstrap\uv-0.12.13-windows-x86_64.json') -Raw|ConvertFrom-Json
    $uvFixture.install.uv_executable='uv-fail.cmd'
    [IO.File]::WriteAllText($uvFixtureManifest,($uvFixture|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $creationFailureManifest=Join-Path $base 'creation-failure-manifest.json'; Write-VenvFixtureManifest -Path $creationFailureManifest -UvBootstrapManifest $uvFixtureManifest
    $beforeCreationFailure=Get-TestEnvironmentSnapshot
    Test-ExpectedFailure -Action { & $bootstrapVenv -ManifestPath $creationFailureManifest -InstallationRoot $root -Force -Json | Out-Null } -Name 'creation-failure-rollback' -ExpectedMessage 'uv venv failed with exit code 42'
    $afterCreationFailure=Get-TestEnvironmentSnapshot; Assert-EnvironmentEqual -Before $beforeCreationFailure -After $afterCreationFailure
    if(-not(Test-Path -LiteralPath $creationMarker -PathType Leaf)){throw 'Creation failure did not restore prior runtime.'}
    if((Get-Content -LiteralPath $creationMarker -Raw).Trim() -ne 'OLD-CREATION-RUNTIME'){throw 'Creation rollback restored wrong runtime.'}
    if(Test-Path -LiteralPath (Join-Path $forced.root 'partial.txt')){throw 'Creation rollback left partial target content.'}
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $forced.root) -Directory -Filter '.venv-backup-*' -ErrorAction SilentlyContinue).Count){throw 'Creation rollback left a backup directory behind.'}
    Write-Host 'VENV_CREATION_FAILURE_ROLLBACK_OK'
    $receiptBefore=Get-Content -LiteralPath $forced.receipt -Raw
    $rollbackMarker=Join-Path $forced.root 'rollback.marker'; [IO.File]::WriteAllText($rollbackMarker,'OLD-RUNTIME',[Text.Encoding]::ASCII)
    $receiptHandle=[IO.File]::Open($forced.receipt,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        Test-ExpectedFailure -Action { & $bootstrapVenv -InstallationRoot $root -Force -Json | Out-Null } -Name 'receipt-commit-rollback' -ExpectedMessage 'Cannot create a file'
    }
    finally { $receiptHandle.Dispose() }
    if(-not(Test-Path -LiteralPath $rollbackMarker -PathType Leaf)){throw 'Receipt failure did not restore prior runtime.'}
    if((Get-Content -LiteralPath $rollbackMarker -Raw).Trim() -ne 'OLD-RUNTIME'){throw 'Receipt rollback restored wrong runtime content.'}
    if((Get-Content -LiteralPath $forced.receipt -Raw) -ne $receiptBefore){throw 'Receipt rollback changed prior receipt.'}
    Write-Host 'VENV_RECEIPT_FAILURE_ROLLBACK_OK'

    $badManifest=Join-Path $base 'bad-count-manifest.json'; Write-VenvFixtureManifest -Path $badManifest -CreationFileCount 999
    $activationMarker=Join-Path $forced.root 'activation.marker'; [IO.File]::WriteAllText($activationMarker,'OLD-ACTIVE',[Text.Encoding]::ASCII)
    $beforeFailure=Get-TestEnvironmentSnapshot
    Test-ExpectedFailure -Action { & $bootstrapVenv -ManifestPath $badManifest -InstallationRoot $root -Force -Json | Out-Null } -Name 'final-validation-rollback' -ExpectedMessage 'Activated runtime venv failed final validation'
    $afterFailure=Get-TestEnvironmentSnapshot; Assert-EnvironmentEqual -Before $beforeFailure -After $afterFailure
    if(-not(Test-Path -LiteralPath $activationMarker -PathType Leaf)){throw 'Final-validation failure did not restore prior runtime.'}
    if((Get-Content -LiteralPath $activationMarker -Raw).Trim() -ne 'OLD-ACTIVE'){throw 'Activation rollback restored wrong runtime.'}
    Write-Host 'VENV_FINAL_VALIDATION_ROLLBACK_OK'

    $traversalManifest=Join-Path $base 'traversal-manifest.json'; Write-VenvFixtureManifest -Path $traversalManifest -ManagedRelativePath '..\escape'
    Test-ExpectedFailure -Action { & $bootstrapVenv -ManifestPath $traversalManifest -InstallationRoot $root -Force -Json | Out-Null } -Name 'manifest-traversal' -ExpectedMessage 'unsafe path segment'
    Write-Host 'VENV_MANIFEST_TRAVERSAL_REJECTED'
    Write-Host 'RUNTIME_VENV_BOOTSTRAP_REGRESSION_OK'
}
finally {
    [Environment]::SetEnvironmentVariable($emptySentinel,$null,'Process')
    [Environment]::SetEnvironmentVariable($extraEmptyProbe,$null,'Process')
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
