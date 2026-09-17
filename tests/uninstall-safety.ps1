$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-TestSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-TestFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    [pscustomobject]@{ path=$Path; size_bytes=[int64]$item.Length; sha256=(Get-TestSha256 -Path $Path) }
}

function Invoke-UninstallFixtureSetup {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ExternalModelsRoot = ''
    )
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    [void][IO.Directory]::CreateDirectory($Root)

    $distributionContent = [ordered]@{
        'start.ps1' = "Write-Host 'synthetic start'`n"
        'config.example.psd1' = "@{ Synthetic = `$true }`n"
        'scripts/common-test.ps1' = "# synthetic common`n"
        'manifests/bootstrap/python.json' = '{"component":"python"}'
        'manifests/bootstrap/uv.json' = '{"component":"uv"}'
        'manifests/bootstrap/venv.json' = '{"component":"venv"}'
        'manifests/runtime/dependencies.json' = '{"component":"dependencies"}'
        'manifests/runtime/runtime.json' = '{"component":"runtime"}'
    }
    $releaseFiles = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $distributionContent.Keys) {
        $path = Join-Path $Root $relative
        Write-Utf8NoBom -Path $path -Text ([string]$distributionContent[$relative])
        $identity = Get-TestFileIdentity -Path $path
        $releaseFiles.Add([pscustomobject][ordered]@{
            path = $relative.Replace('\','/')
            size_bytes = [int64]$identity.size_bytes
            sha256 = [string]$identity.sha256
        })
    }

    $managedPaths = @(
        'python/managed/test-python',
        'tools/uv/test-uv',
        'runtime/venv',
        'cache/uv',
        'forensic/python.json',
        'forensic/uv.json',
        'forensic/venv.json',
        'forensic/dependencies.json',
        'forensic/runtime.json',
        'state/install-state.json',
        'state/install-orchestrator.lock',
        '.vllm-operation.lock'
    )
    $release = [ordered]@{
        schema_version = 1
        component = 'runtime-release'
        release = 'synthetic-uninstall-test'
        platform = 'windows-x86_64'
        self_path = 'manifests/release/test.json'
        upstream = [ordered]@{
            repository = 'https://example.invalid/upstream.git'
            tag = 'v0-test'
            commit = '1111111111111111111111111111111111111111'
        }
        windows_patchset = [ordered]@{
            implementation_commit = '2222222222222222222222222222222222222222'
            tree = '3333333333333333333333333333333333333333'
            patch_sha256 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        }
        wheel = [ordered]@{
            filename = 'vllm-synthetic.whl'
            version = '0.test'
            size_bytes = 123
            sha256 = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        }
        orchestration = [ordered]@{
            python_manifest = 'manifests/bootstrap/python.json'
            uv_manifest = 'manifests/bootstrap/uv.json'
            venv_manifest = 'manifests/bootstrap/venv.json'
            dependency_manifest = 'manifests/runtime/dependencies.json'
            runtime_manifest = 'manifests/runtime/runtime.json'
            python_receipt = 'forensic/python.json'
            uv_receipt = 'forensic/uv.json'
            venv_receipt = 'forensic/venv.json'
            dependency_receipt = 'forensic/dependencies.json'
            runtime_receipt = 'forensic/runtime.json'
            runtime_root = 'runtime/venv'
        }
        managed_paths = $managedPaths
        files = $releaseFiles.ToArray()
    }
    $releasePath = Join-Path $Root 'manifests/release/test.json'
    Write-Utf8NoBom -Path $releasePath -Text ($release | ConvertTo-Json -Depth 12)
    $releaseIdentity = Get-TestFileIdentity -Path $releasePath

    foreach ($relative in $managedPaths) {
        $normalized = $relative.Replace('/','\')
        if ($normalized -in @('state\install-state.json','state\install-orchestrator.lock','.vllm-operation.lock')) { continue }
        $path = Join-Path $Root $normalized
        if ([IO.Path]::GetExtension($path) -eq '.json') {
            Write-Utf8NoBom -Path $path -Text '{"owned":true}'
        } else {
            [void][IO.Directory]::CreateDirectory($path)
            Write-Utf8NoBom -Path (Join-Path $path 'OWNED.tmp') -Text 'DELETE-ME'
        }
    }

    $modelsRoot = if ([string]::IsNullOrWhiteSpace($ExternalModelsRoot)) { Join-Path $Root 'models' } else { [IO.Path]::GetFullPath($ExternalModelsRoot) }
    [void][IO.Directory]::CreateDirectory($modelsRoot)
    Write-Utf8NoBom -Path (Join-Path $modelsRoot 'KEEP.txt') -Text 'MODEL-KEEP'
    Write-Utf8NoBom -Path (Join-Path $Root 'config.psd1') -Text "@{ Keep = `$true }"
    Write-Utf8NoBom -Path (Join-Path $Root 'unknown.txt') -Text 'UNKNOWN-KEEP'

    $distributionState = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $release.files) {
        $distributionState.Add([pscustomobject][ordered]@{
            path = [string]$entry.path
            size_bytes = [int64]$entry.size_bytes
            sha256 = [string]$entry.sha256
        })
    }
    $distributionState.Add([pscustomobject][ordered]@{
        path = [string]$release.self_path
        size_bytes = [int64]$releaseIdentity.size_bytes
        sha256 = [string]$releaseIdentity.sha256
    })

    $now = (Get-Date).ToString('o')
    $statePath = Join-Path $Root 'state/install-state.json'
    $state = [ordered]@{
        schema_version = 1
        component = 'install-state'
        release = [string]$release.release
        platform = [string]$release.platform
        ready = $true
        generation_id = [guid]::NewGuid().ToString('D')
        install_root = [IO.Path]::GetFullPath($Root)
        models_root = $modelsRoot
        release_manifest = $releasePath
        release_manifest_sha256 = [string]$releaseIdentity.sha256
        upstream = $release.upstream
        windows_patchset = $release.windows_patchset
        wheel = $release.wheel
        python = [ordered]@{
            version = '3.13.test'
            root = (Join-Path $Root 'python/managed/test-python')
            python = (Join-Path $Root 'python/managed/test-python/python.exe')
            archive_sha256 = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
            receipt = (Join-Path $Root 'forensic/python.json')
            receipt_sha256 = 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD'
        }
        uv = [ordered]@{
            version = '0.test'
            root = (Join-Path $Root 'tools/uv/test-uv')
            uv = (Join-Path $Root 'tools/uv/test-uv/uv.exe')
            archive_sha256 = 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE'
            receipt = (Join-Path $Root 'forensic/uv.json')
            receipt_sha256 = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'
        }
        runtime = [ordered]@{
            root = (Join-Path $Root 'runtime/venv')
            python = (Join-Path $Root 'runtime/venv/Scripts/python.exe')
            package_count = 1
            vllm_version = '0.test'
            dependency_receipt = (Join-Path $Root 'forensic/dependencies.json')
            dependency_receipt_sha256 = '1010101010101010101010101010101010101010101010101010101010101010'
            final_receipt = (Join-Path $Root 'forensic/runtime.json')
            final_receipt_sha256 = '2020202020202020202020202020202020202020202020202020202020202020'
            lock_sha256 = '3030303030303030303030303030303030303030303030303030303030303030'
            wheel_sha256 = [string]$release.wheel.sha256
        }
        distribution_files = @($distributionState.ToArray() | Sort-Object path)
        managed_paths = $managedPaths
        installed_at = $now
        updated_at = $now
    }
    Write-Utf8NoBom -Path $statePath -Text ($state | ConvertTo-Json -Depth 12)
    Write-Utf8NoBom -Path (Join-Path $Root 'state/install-orchestrator.lock') -Text 'stale=true'
    Write-Utf8NoBom -Path (Join-Path $Root '.vllm-operation.lock') -Text 'stale=true'

    [pscustomobject]@{
        Root = [IO.Path]::GetFullPath($Root)
        ModelsRoot = $modelsRoot
        StatePath = $statePath
        ReleasePath = $releasePath
        DistributionFiles = $distributionState.ToArray()
        ManagedPaths = $managedPaths
    }
}

function Invoke-UninstallJson {
    param([Parameter(Mandatory)][string]$Root,[switch]$Preview)
    $parameters = @{ InstallationRoot=$Root; Json=$true; Confirm=$false }
    if ($Preview) { $parameters.WhatIf = $true }
    $raw = @(& $uninstallScript @parameters)
    $text = ($raw -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Uninstaller returned no JSON.' }
    try { return ($text | ConvertFrom-Json) } catch { throw "Uninstaller returned invalid JSON: $text" }
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Name,[string]$Pattern='')
    try { & $Action } catch {
        if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $_.Exception.Message -notlike $Pattern) {
            throw "Expected '$Name' failure matching '$Pattern', got: $($_.Exception.Message)"
        }
        Write-Host "EXPECTED_REJECTION $Name"
        return
    }
    throw "Expected rejection did not occur: $Name"
}

function Assert-ProtectedPaths {
    param([Parameter(Mandatory)]$Fixture)
    foreach ($path in @(
        (Join-Path $Fixture.ModelsRoot 'KEEP.txt'),
        (Join-Path $Fixture.Root 'config.psd1'),
        (Join-Path $Fixture.Root 'unknown.txt')
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Protected path was removed: $path" }
    }
}

function Assert-OwnedPathsRemoved {
    param([Parameter(Mandatory)]$Fixture)
    foreach ($entry in $Fixture.DistributionFiles) {
        if (Test-Path -LiteralPath (Join-Path $Fixture.Root ([string]$entry.path))) {
            throw "Distribution file survived uninstall: $($entry.path)"
        }
    }
    foreach ($relative in $Fixture.ManagedPaths) {
        if (Test-Path -LiteralPath (Join-Path $Fixture.Root ([string]$relative))) {
            throw "Managed path survived uninstall: $relative"
        }
    }
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('vllm-uninstall-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
try {
    $root = Join-Path $base 'default-models'
    $fixture = Invoke-UninstallFixtureSetup -Root $root

    $stateHashBefore = (Get-TestSha256 -Path $fixture.StatePath)
    $startHashBefore = (Get-TestSha256 -Path (Join-Path $root 'start.ps1'))
    $preview = Invoke-UninstallJson -Root $root -Preview
    if (-not [bool]$preview.ready -or [bool]$preview.removed -or -not [bool]$preview.what_if) { throw 'WhatIf result contract is invalid.' }
    if ((Get-TestSha256 -Path $fixture.StatePath) -ne $stateHashBefore) { throw 'WhatIf changed install state.' }
    if ((Get-TestSha256 -Path (Join-Path $root 'start.ps1')) -ne $startHashBefore) { throw 'WhatIf changed distribution content.' }
    Assert-ProtectedPaths -Fixture $fixture
    Write-Host 'UNINSTALL_WHATIF_OK'

    $orchestratorPath = Join-Path $root 'state/install-orchestrator.lock'
    $held = [IO.File]::Open($orchestratorPath, 'Open', 'ReadWrite', 'None')
    try {
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'orchestrator-lock-contention' '*top-level install/uninstall operation is active*'
    } finally { $held.Dispose() }

    $operationPath = Join-Path $root '.vllm-operation.lock'
    $held = [IO.File]::Open($operationPath, 'Open', 'ReadWrite', 'None')
    try {
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'operation-lock-contention' '*lifecycle operation is active*'
    } finally { $held.Dispose() }
    $probe = [IO.File]::Open($orchestratorPath, 'Open', 'ReadWrite', 'None')
    $probe.Dispose()
    Write-Host 'UNINSTALL_LOCK_ORDER_OK'

    $managedCmd = Join-Path $root 'runtime/venv/managed-cmd.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/cmd.exe') -Destination $managedCmd -Force
    $process = $null
    try {
        $process = Start-Process -FilePath $managedCmd -ArgumentList @('/d','/c','ping -n 60 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 750
        if ($process.HasExited) { throw 'Managed process test executable exited early.' }
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'managed-runtime-process' '*Managed runtime process is still running*'
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            try { $process.WaitForExit() } catch { Write-Verbose "Managed process wait failed during cleanup: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $managedCmd -Force -ErrorAction SilentlyContinue
    }
    [void](Invoke-UninstallJson -Root $root -Preview)

    $managedPythonCmd = Join-Path $root 'python/managed/test-python/managed-python-cmd.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/cmd.exe') -Destination $managedPythonCmd -Force
    $pythonProcess = $null
    try {
        $pythonProcess = Start-Process -FilePath $managedPythonCmd -ArgumentList @('/d','/c','ping -n 60 127.0.0.1 >nul') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 750
        if ($pythonProcess.HasExited) { throw 'Managed Python-root process test executable exited early.' }
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'managed-python-process' '*Managed runtime process is still running*'
    } finally {
        if ($null -ne $pythonProcess -and -not $pythonProcess.HasExited) {
            Stop-Process -Id $pythonProcess.Id -Force -ErrorAction SilentlyContinue
            try { $pythonProcess.WaitForExit() } catch { Write-Verbose "Managed Python-root process wait failed during cleanup: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $managedPythonCmd -Force -ErrorAction SilentlyContinue
    }
    [void](Invoke-UninstallJson -Root $root -Preview)
    Write-Host 'UNINSTALL_PROCESS_REFUSAL_OK'

    $driftPath = Join-Path $root 'start.ps1'
    $driftOriginal = [IO.File]::ReadAllText($driftPath)
    try {
        [IO.File]::AppendAllText($driftPath, "`n# drift", [Text.UTF8Encoding]::new($false))
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'distribution-drift' '*Owned distribution file has drifted*'
    } finally {
        Write-Utf8NoBom -Path $driftPath -Text $driftOriginal
    }

    $outside = Join-Path $base 'outside'
    [void][IO.Directory]::CreateDirectory($outside)
    Write-Utf8NoBom -Path (Join-Path $outside 'KEEP.txt') -Text 'DO-NOT-TOUCH'
    $cacheUv = Join-Path $root 'cache/uv'
    Remove-Item -LiteralPath $cacheUv -Recurse -Force
    New-Item -ItemType Junction -Path $cacheUv -Target $outside | Out-Null
    try {
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'managed-junction' '*filesystem alias outside expected location*'
        if ((Get-Content -LiteralPath (Join-Path $outside 'KEEP.txt') -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'External junction sentinel changed.' }
    } finally {
        if (Test-Path -LiteralPath $cacheUv) { [IO.Directory]::Delete($cacheUv) }
        [void][IO.Directory]::CreateDirectory($cacheUv)
        Write-Utf8NoBom -Path (Join-Path $cacheUv 'OWNED.tmp') -Text 'DELETE-ME'
    }
    Write-Host 'UNINSTALL_ADVERSARIAL_PATHS_OK'

    $nestedParent = Join-Path $root 'runtime/venv/nested-reparse-test'
    [void][IO.Directory]::CreateDirectory($nestedParent)
    $nestedJunction = Join-Path $nestedParent 'pivot'
    New-Item -ItemType Junction -Path $nestedJunction -Target $outside | Out-Null
    try {
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root) } 'managed-nested-junction' '*Managed directory tree contains a reparse point*'
        if ((Get-Content -LiteralPath (Join-Path $outside 'KEEP.txt') -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'External nested-junction sentinel changed.' }
    } finally {
        if (Test-Path -LiteralPath $nestedJunction) { [IO.Directory]::Delete($nestedJunction) }
        if (Test-Path -LiteralPath $nestedParent) { Remove-Item -LiteralPath $nestedParent -Recurse -Force }
    }
    Write-Host 'UNINSTALL_NESTED_REPARSE_OK'

    $stateOriginalBytes = [IO.File]::ReadAllBytes($fixture.StatePath)
    try {
        Write-Utf8NoBom -Path $fixture.StatePath -Text '{not-json'
        Test-ExpectedFailure { [void](Invoke-UninstallJson -Root $root -Preview) } 'malformed-install-state' '*Install state is malformed*'
    } finally {
        [IO.File]::WriteAllBytes($fixture.StatePath, $stateOriginalBytes)
    }
    Write-Host 'UNINSTALL_MALFORMED_STATE_OK'

    $uninstallText=[IO.File]::ReadAllText($uninstallScript)
    $stateCommitIndex=$uninstallText.IndexOf('Remove-Item -LiteralPath $plan.StatePath -Force',[StringComparison]::Ordinal)
    $operationExitIndex=$uninstallText.IndexOf('Exit-VllmOperationLock -Lock $operationLock',[StringComparison]::Ordinal)
    $operationCleanupIndex=$uninstallText.IndexOf('Invoke-UninstallLockCleanup -Path ([string]$plan.OperationLockPath) -RelativePath ''.vllm-operation.lock''',[StringComparison]::Ordinal)
    $operationCleanupWarningIndex=$uninstallText.IndexOf('Uninstall committed, but operation lock cleanup was not completed safely',[StringComparison]::Ordinal)
    if($stateCommitIndex -lt 0 -or $operationExitIndex -le $stateCommitIndex -or $operationCleanupIndex -le $operationExitIndex -or $operationCleanupWarningIndex -le $operationCleanupIndex){
        throw 'Uninstall commit ordering must remain state commit -> operation-lock release -> post-commit lock cleanup.'
    }
    Write-Host 'UNINSTALL_COMMIT_LOCK_ORDER_OK'
    $removed = Invoke-UninstallJson -Root $root
    if (-not [bool]$removed.ready -or -not [bool]$removed.removed -or [bool]$removed.what_if) { throw 'Destructive uninstall result contract is invalid.' }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Uninstall removed InstallationRoot.' }
    Assert-ProtectedPaths -Fixture $fixture
    Assert-OwnedPathsRemoved -Fixture $fixture
    Write-Host 'UNINSTALL_DEFAULT_MODELS_PRESERVED_OK'

    $externalModels = Join-Path $base 'external-models'
    $externalRoot = Join-Path $base 'external-models-install'
    $externalFixture = Invoke-UninstallFixtureSetup -Root $externalRoot -ExternalModelsRoot $externalModels
    $externalResult = Invoke-UninstallJson -Root $externalRoot
    if (-not [bool]$externalResult.removed) { throw 'External-model fixture uninstall did not complete.' }
    Assert-ProtectedPaths -Fixture $externalFixture
    Assert-OwnedPathsRemoved -Fixture $externalFixture
    if (-not (Test-Path -LiteralPath (Join-Path $externalModels 'KEEP.txt') -PathType Leaf)) { throw 'External ModelsRoot content was removed.' }
    Write-Host 'UNINSTALL_EXTERNAL_MODELS_PRESERVED_OK'

    Write-Host 'UNINSTALL_SAFETY_TEST_OK'
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
