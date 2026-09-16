[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')

function Write-Utf8Json {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))
}

function Get-TestFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        size_bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Test-ExpectedFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )
    try {
        & $Action
        throw "Expected failure did not occur: $Name"
    } catch {
        $message = $_.Exception.Message
        if ($message -eq "Expected failure did not occur: $Name") { throw }
        if ($message.IndexOf($ExpectedMessage, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Expected '$Name' failure containing '$ExpectedMessage', got: $message"
        }
        Write-Host "EXPECTED_REJECTION $Name"
    }
}

function Initialize-TestManagedInstallation {
    param([Parameter(Mandatory)][string]$Root)

    [void][IO.Directory]::CreateDirectory($Root)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'runtime\venv\Scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'forensic'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'state'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'models'))

    $distribution = @('start.ps1','scripts/common.ps1','scripts/lifecycle.ps1','scripts/env.ps1')
    foreach ($relative in $distribution) {
        $source = Join-Path $repoRoot $relative
        $target = Join-Path $Root $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath $source -Destination $target
    }

    $vllmExe = Join-Path $Root 'runtime\venv\Scripts\vllm.exe'
    Copy-Item -LiteralPath $env:ComSpec -Destination $vllmExe

    $receiptRelatives = [ordered]@{
        python='forensic/python.json'
        uv='forensic/uv.json'
        venv='forensic/venv.json'
        dependency='forensic/dependency.json'
        runtime='forensic/runtime.json'
    }
    foreach ($name in $receiptRelatives.Keys) {
        $receiptPath = Join-Path $Root $receiptRelatives[$name]
        [IO.File]::WriteAllText($receiptPath, "fixture=$name`n", [Text.UTF8Encoding]::new($false))
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relative in $distribution) {
        $identity = Get-TestFileIdentity -Path (Join-Path $Root $relative)
        $files.Add([pscustomobject][ordered]@{
            path=$relative.Replace('\','/')
            size_bytes=[int64]$identity.size_bytes
            sha256=[string]$identity.sha256
        })
    }

    $fixedHash = ('A' * 64) -join ''
    $release = [ordered]@{
        schema_version=1
        component='runtime-release'
        release='sm18a-fixture'
        platform='windows-x86_64'
        self_path='manifests/release/sm18a-fixture.json'
        upstream=[ordered]@{
            repository='https://example.invalid/vllm.git'
            tag='fixture'
            commit='0123456789abcdef0123456789abcdef01234567'
        }
        windows_patchset=[ordered]@{
            implementation_commit='fixture'
            tree='89abcdef0123456789abcdef0123456789abcdef'
            patch_sha256=$fixedHash
        }
        wheel=[ordered]@{
            filename='vllm-fixture.whl'
            version='0.0.0'
            size_bytes=[int64]1
            sha256=$fixedHash
        }
        orchestration=[ordered]@{
            python_manifest='manifests/bootstrap/python.json'
            uv_manifest='manifests/bootstrap/uv.json'
            venv_manifest='manifests/bootstrap/venv.json'
            dependency_manifest='manifests/runtime/dependency.json'
            runtime_manifest='manifests/runtime/runtime.json'
            python_receipt=$receiptRelatives.python
            uv_receipt=$receiptRelatives.uv
            venv_receipt=$receiptRelatives.venv
            dependency_receipt=$receiptRelatives.dependency
            runtime_receipt=$receiptRelatives.runtime
            runtime_root='runtime/venv'
        }
        managed_paths=@(
            'runtime/venv',
            $receiptRelatives.python,
            $receiptRelatives.uv,
            $receiptRelatives.venv,
            $receiptRelatives.dependency,
            $receiptRelatives.runtime,
            'state/install-state.json',
            'state/install-orchestrator.lock',
            '.vllm-operation.lock'
        )
        files=$files.ToArray()
    }

    $releasePath = Join-Path $Root 'manifests\release\sm18a-fixture.json'
    Write-Utf8Json -Path $releasePath -Value $release
    $releaseIdentity = Get-TestFileIdentity -Path $releasePath

    $distributionState = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $files) {
        $distributionState.Add([pscustomobject][ordered]@{
            path=[string]$entry.path
            size_bytes=[int64]$entry.size_bytes
            sha256=[string]$entry.sha256
        })
    }
    $distributionState.Add([pscustomobject][ordered]@{
        path='manifests/release/sm18a-fixture.json'
        size_bytes=[int64]$releaseIdentity.size_bytes
        sha256=[string]$releaseIdentity.sha256
    })

    $pythonReceipt = Join-Path $Root $receiptRelatives.python
    $uvReceipt = Join-Path $Root $receiptRelatives.uv
    $dependencyReceipt = Join-Path $Root $receiptRelatives.dependency
    $runtimeReceipt = Join-Path $Root $receiptRelatives.runtime
    $runtimeRoot = Join-Path $Root 'runtime\venv'
    $now = (Get-Date).ToString('o')
    $state = [ordered]@{
        schema_version=1
        component='install-state'
        release='sm18a-fixture'
        platform='windows-x86_64'
        ready=$true
        generation_id=[guid]::NewGuid().ToString('D')
        install_root=(Get-VllmNormalizedPath $Root)
        models_root=(Get-VllmNormalizedPath (Join-Path $Root 'models'))
        release_manifest=(Get-VllmNormalizedPath $releasePath)
        release_manifest_sha256=[string]$releaseIdentity.sha256
        upstream=[ordered]@{
            repository=[string]$release.upstream.repository
            tag=[string]$release.upstream.tag
            commit=[string]$release.upstream.commit
        }
        windows_patchset=[ordered]@{
            implementation_commit=[string]$release.windows_patchset.implementation_commit
            tree=[string]$release.windows_patchset.tree
            patch_sha256=[string]$release.windows_patchset.patch_sha256
        }
        wheel=[ordered]@{
            filename=[string]$release.wheel.filename
            version=[string]$release.wheel.version
            size_bytes=[int64]$release.wheel.size_bytes
            sha256=[string]$release.wheel.sha256
        }
        python=[ordered]@{
            version='3.13.0'
            root=(Join-Path $Root 'python\managed\fixture')
            python=(Join-Path $Root 'python\managed\fixture\python.exe')
            archive_sha256=$fixedHash
            receipt=$pythonReceipt
            receipt_sha256=(Get-FileHash $pythonReceipt -Algorithm SHA256).Hash
        }
        uv=[ordered]@{
            version='0.0.0'
            root=(Join-Path $Root 'tools\uv\fixture')
            uv=(Join-Path $Root 'tools\uv\fixture\uv.exe')
            archive_sha256=$fixedHash
            receipt=$uvReceipt
            receipt_sha256=(Get-FileHash $uvReceipt -Algorithm SHA256).Hash
        }
        runtime=[ordered]@{
            root=$runtimeRoot
            python=(Join-Path $runtimeRoot 'Scripts\python.exe')
            package_count=1
            vllm_version='0.0.0'
            dependency_receipt=$dependencyReceipt
            dependency_receipt_sha256=(Get-FileHash $dependencyReceipt -Algorithm SHA256).Hash
            final_receipt=$runtimeReceipt
            final_receipt_sha256=(Get-FileHash $runtimeReceipt -Algorithm SHA256).Hash
            lock_sha256=$fixedHash
            wheel_sha256=$fixedHash
        }
        distribution_files=$distributionState.ToArray()
        managed_paths=@($release.managed_paths)
        installed_at=$now
        updated_at=$now
    }
    $statePath = Join-Path $Root 'state\install-state.json'
    Write-Utf8Json -Path $statePath -Value $state

    return [pscustomobject]@{
        Root=(Get-VllmNormalizedPath $Root)
        StatePath=$statePath
        VllmExe=$vllmExe
        ReleasePath=$releasePath
    }
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm18a-'+[guid]::NewGuid().ToString('N'))
$child = $null
try {
    [void][IO.Directory]::CreateDirectory($base)
    $start = Join-Path $repoRoot 'start.ps1'
    $repoLock = Join-Path $repoRoot '.vllm-operation.lock'
    $repoLockInitiallyExists = Test-Path -LiteralPath $repoLock
    $devContainment = Join-Path $base 'dev-containment'
    & $start fixture -VllmExe (Join-Path $env:SystemRoot 'System32\where.exe') -ContainmentRoot $devContainment -ValidateOnly
    if ((Test-Path -LiteralPath $repoLock) -and -not $repoLockInitiallyExists) {
        throw 'Development-mode start created an operation lock in the repository checkout.'
    }
    if (Test-Path -LiteralPath (Join-Path $devContainment '.vllm-operation.lock')) {
        throw 'Development-mode start created an operation lock in the containment root.'
    }
    Write-Host 'START_DEV_MODE_NO_LOCK_OK'

    $fixture = Initialize-TestManagedInstallation -Root (Join-Path $base 'managed')
    $managedContainment = Join-Path $base 'managed-containment'
    & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
    $lockPath = Join-Path $fixture.Root '.vllm-operation.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'Managed ValidateOnly did not materialize lifecycle coordination metadata.'
    }
    $probe = [IO.File]::Open($lockPath,'Open','ReadWrite','None')
    $probe.Dispose()
    if (Test-Path -LiteralPath (Join-Path $managedContainment '.vllm-operation.lock')) {
        throw 'Managed start locked the containment root instead of the committed installation root.'
    }
    Write-Host 'START_OVERRIDE_TARGET_MANAGED_LOCK_OK'

    $journal = Join-Path $fixture.Root 'state\update-transaction.json'
    [IO.File]::WriteAllText($journal, '{malformed', [Text.Encoding]::ASCII)
    Test-ExpectedFailure -Name 'malformed-update-journal' -ExpectedMessage 'Pending update maintenance state' -Action {
        & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
    }
    Remove-Item -LiteralPath $journal -Force
    Write-Host 'START_MALFORMED_JOURNAL_PRESENCE_REFUSAL_OK'

    $workspace = Join-Path $fixture.Root 'work\update-transaction'
    [void][IO.Directory]::CreateDirectory($workspace)
    Test-ExpectedFailure -Name 'reserved-update-workspace' -ExpectedMessage 'Pending update maintenance state' -Action {
        & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
    }
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'work') -Recurse -Force
    Write-Host 'START_RESERVED_WORKSPACE_PRESENCE_REFUSAL_OK'

    $stateRaw = [IO.File]::ReadAllText($fixture.StatePath)
    [IO.File]::WriteAllText($fixture.StatePath, '{bad-state', [Text.Encoding]::ASCII)
    Test-ExpectedFailure -Name 'malformed-install-state' -ExpectedMessage 'Install state is malformed' -Action {
        & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
    }
    [IO.File]::WriteAllText($fixture.StatePath, $stateRaw, [Text.UTF8Encoding]::new($false))
    Write-Host 'START_MALFORMED_STATE_FAILS_CLOSED_OK'

    $otherExe = Join-Path $fixture.Root 'runtime\venv\Scripts\other.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination $otherExe
    Test-ExpectedFailure -Name 'noncommitted-managed-exe' -ExpectedMessage 'not the committed managed launcher' -Action {
        & $start fixture -VllmExe $otherExe -ContainmentRoot $managedContainment -ValidateOnly
    }
    Remove-Item -LiteralPath $otherExe -Force
    Write-Host 'START_NONCOMMITTED_EXE_REJECTED_OK'

    $owner = Enter-VllmOperationLock -InstallationRoot $fixture.Root -Operation 'test-owner'
    try {
        Test-ExpectedFailure -Name 'managed-start-contention' -ExpectedMessage 'Another vLLM Windows Native lifecycle operation is active' -Action {
            & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
        }
    } finally {
        Exit-VllmOperationLock -Lock $owner
    }
    Write-Host 'START_FAIL_FAST_CONTENTION_OK'

    # Prove the normal foreground launcher holds the operation lock for the entire
    # managed server lifetime. cmd.exe copied as vllm.exe stays interactive because
    # the launcher does not pass /C; terminating it lets start.ps1 unwind.
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    $childScript = Join-Path $base 'managed-start-child.ps1'
    $escapedStart = $start.Replace("'","''")
    $escapedExe = $fixture.VllmExe.Replace("'","''")
    $escapedContainment = $managedContainment.Replace("'","''")
    $childBody = @"
`$ErrorActionPreference='Stop'
& '$escapedStart' fixture -VllmExe '$escapedExe' -ContainmentRoot '$escapedContainment'
"@
    [IO.File]::WriteAllText($childScript,$childBody,[Text.UTF8Encoding]::new($false))
    $childOut = Join-Path $base 'managed-start.out'
    $childErr = Join-Path $base 'managed-start.err'
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shellArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript)
    } else {
        $shell = (Get-Process -Id $PID).Path
        $shellArgs = @('-NoLogo','-NoProfile','-File',$childScript)
    }
    $child = Start-Process -FilePath $shell -ArgumentList $shellArgs -PassThru -RedirectStandardOutput $childOut -RedirectStandardError $childErr
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not $child.HasExited -and -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        Start-Sleep -Milliseconds 100
        $child.Refresh()
    }
    if ($child.HasExited) {
        $details = ((Get-Content $childOut -Raw -ErrorAction SilentlyContinue) + (Get-Content $childErr -Raw -ErrorAction SilentlyContinue))
        throw "Managed start child exited before taking the operation lock: $details"
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'Managed start child did not materialize the operation lock in time.'
    }
    $held = $false
    try {
        $probe = [IO.File]::Open($lockPath,'Open','ReadWrite','None')
        $probe.Dispose()
    } catch [IO.IOException] {
        $held = $true
    }
    if (-not $held) { throw 'Managed start did not hold the operation lock while its server was alive.' }

    Test-ExpectedFailure -Name 'second-start-during-server-lifetime' -ExpectedMessage 'Another vLLM Windows Native lifecycle operation is active' -Action {
        & $start fixture -VllmExe $fixture.VllmExe -ContainmentRoot $managedContainment -ValidateOnly
    }

    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $taskkill /PID ([string]$child.Id) /T /F *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not terminate isolated managed launcher process tree; taskkill exit $LASTEXITCODE."
    }
    if (-not $child.WaitForExit(10000)) {
        throw 'Managed start child did not exit after its process tree was terminated.'
    }
    $child = $null

    $probe = [IO.File]::Open($lockPath,'Open','ReadWrite','None')
    $probe.Dispose()
    Write-Host 'START_SERVER_LIFETIME_LOCK_OK'

    # Uninstall must refuse pending update state before it attempts ownership planning.
    [IO.File]::WriteAllText($journal, '{malformed', [Text.Encoding]::ASCII)
    Test-ExpectedFailure -Name 'uninstall-pending-update' -ExpectedMessage 'Pending update maintenance state' -Action {
        & (Join-Path $repoRoot 'uninstall.ps1') -InstallationRoot $fixture.Root -Confirm:$false -WhatIf
    }
    Remove-Item -LiteralPath $journal -Force
    Write-Host 'UNINSTALL_PENDING_UPDATE_GUARD_OK'

    # Source-level ordering assertion for install: orchestrator -> operation -> guard -> install-state work.
    $installText = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
    $operationIndex = $installText.IndexOf("Enter-VllmOperationLock -InstallationRoot `$InstallationRoot -Operation 'install'",[StringComparison]::Ordinal)
    $guardIndex = $installText.IndexOf('Assert-VllmUpdateMaintenanceAbsent -InstallationRoot $InstallationRoot',[StringComparison]::Ordinal)
    $stateIndex = $installText.IndexOf('$existingState=Read-JsonFile $statePath',[StringComparison]::Ordinal)
    if ($operationIndex -lt 0 -or $guardIndex -le $operationIndex -or $stateIndex -le $guardIndex) {
        throw 'install.ps1 lifecycle ordering is not operation-lock -> maintenance guard -> install-state work.'
    }
    Write-Host 'INSTALL_MAINTENANCE_GUARD_ORDER_OK'

    Write-Host 'START_MAINTENANCE_SERIALIZATION_TEST_OK'
}
finally {
    if ($null -ne $child -and -not $child.HasExited) {
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        & $taskkill /PID ([string]$child.Id) /T /F *> $null
    }
    if (Test-Path -LiteralPath $base) {
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
