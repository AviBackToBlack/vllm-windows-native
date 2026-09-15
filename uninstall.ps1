[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $InstallationRoot = 'D:\AI\vLLM',
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')

if ($env:OS -ne 'Windows_NT') { throw 'Uninstall currently supports native Windows only.' }
$InstallationRoot = Get-VllmNormalizedPath $InstallationRoot
[void](Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot)

function Get-FileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Expected file, got directory: $Path" }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
    [pscustomobject]@{ Size = [int64]$item.Length; Sha256 = $hash }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-PathEqual {
    param([string]$A,[string]$B)
    (Get-VllmNormalizedPath $A).Equals((Get-VllmNormalizedPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Test-TimestampValue {
    param($Value)
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $true }
    $parsed = [DateTimeOffset]::MinValue
    [DateTimeOffset]::TryParseExact([string]$Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
}

function Test-IdentityFields {
    param($Actual,$Expected,[string[]]$Names)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    foreach ($name in $Names) {
        if ([string]$Actual.$name -ne [string]$Expected.$name) { return $false }
    }
    return $true
}

function Get-NormalizedRelativeKey {
    param([Parameter(Mandatory)][string]$Path)
    (Assert-VllmSafeRelativePath -RelativePath $Path -Label 'Owned relative path').Replace('\','/').ToLowerInvariant()
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    if ($null -eq $Value) { throw "$Label is missing." }
    $actual = @($Value.PSObject.Properties.Name)
    if (Compare-Object ($Expected | Sort-Object) ($actual | Sort-Object)) {
        throw "$Label schema is incomplete or contains unexpected fields."
    }
}

function Assert-ManagedTreeNoReparsePoints {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push((Get-VllmNormalizedPath $Path))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentEntry = Get-VllmPathEntryInfo -Path $current
        if (-not $currentEntry.Exists) { throw "Managed directory disappeared while validating recursive ownership: $RelativePath" }
        if (-not $currentEntry.IsDirectory) { throw "Managed directory changed type while validating recursive ownership: $RelativePath" }
        if ($currentEntry.IsReparsePoint) { throw "Managed directory tree contains a reparse point; recursive ownership is ambiguous: $current" }
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            $childEntry = Get-VllmPathEntryInfo -Path $child.FullName
            if (-not $childEntry.Exists) { throw "Managed tree entry disappeared while validating recursive ownership: $($child.FullName)" }
            if ($childEntry.IsReparsePoint) { throw "Managed directory tree contains a reparse point; recursive ownership is ambiguous: $($child.FullName)" }
            if ($childEntry.IsDirectory) { $pending.Push($childEntry.Path) }
        }
    }
}

function Get-UninstallPlan {
    $statePath = Join-Path $InstallationRoot 'state\install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "Install state is missing: $statePath" }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $statePath -RelativePath 'state\install-state.json')
    $state = Read-JsonFile -Path $statePath
    if ($null -eq $state) { throw "Install state is malformed: $statePath" }
    $stateIdentity = Get-FileIdentity -Path $statePath

    $expectedStateProps = @('schema_version','component','release','platform','ready','generation_id','install_root','models_root','release_manifest','release_manifest_sha256','upstream','windows_patchset','wheel','python','uv','runtime','distribution_files','managed_paths','installed_at','updated_at')
    Assert-ExactProperties -Value $state -Expected $expectedStateProps -Label 'Install-state'
    Assert-ExactProperties -Value $state.upstream -Expected @('repository','tag','commit') -Label 'Install-state upstream identity'
    Assert-ExactProperties -Value $state.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Install-state Windows patchset identity'
    Assert-ExactProperties -Value $state.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Install-state wheel identity'
    Assert-ExactProperties -Value $state.python -Expected @('version','root','python','archive_sha256','receipt','receipt_sha256') -Label 'Install-state Python identity'
    Assert-ExactProperties -Value $state.uv -Expected @('version','root','uv','archive_sha256','receipt','receipt_sha256') -Label 'Install-state uv identity'
    Assert-ExactProperties -Value $state.runtime -Expected @('root','python','package_count','vllm_version','dependency_receipt','dependency_receipt_sha256','final_receipt','final_receipt_sha256','lock_sha256','wheel_sha256') -Label 'Install-state runtime identity'
    if ([int]$state.schema_version -ne 1 -or [string]$state.component -ne 'install-state' -or -not [bool]$state.ready) { throw 'Install state does not describe a ready schema-v1 installation.' }
    if (-not (Test-PathEqual ([string]$state.install_root) $InstallationRoot)) { throw 'Install-state root does not match requested InstallationRoot.' }
    $generation = [guid]::Empty
    if (-not [guid]::TryParse([string]$state.generation_id, [ref]$generation)) { throw 'Install-state generation_id is invalid.' }
    if (-not (Test-TimestampValue $state.installed_at) -or -not (Test-TimestampValue $state.updated_at)) { throw 'Install-state timestamps are invalid.' }

    $modelsRoot = Assert-VllmSafeModelsRoot -InstallationRoot $InstallationRoot -ModelsRoot ([string]$state.models_root)

    $releasePath = Get-VllmNormalizedPath ([string]$state.release_manifest)
    if (-not (Test-VllmPathInsideOrEqual -Path $releasePath -Parent $InstallationRoot)) { throw 'Release manifest is outside InstallationRoot.' }
    if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) { throw "Installed release manifest is missing: $releasePath" }
    $releaseId = Get-FileIdentity -Path $releasePath
    if ($releaseId.Sha256 -ne [string]$state.release_manifest_sha256) { throw 'Installed release manifest digest does not match install state.' }
    $release = Read-JsonFile -Path $releasePath
    if ($null -eq $release) { throw 'Installed release manifest is malformed.' }

    Assert-ExactProperties -Value $release -Expected @('schema_version','component','release','platform','self_path','upstream','windows_patchset','wheel','orchestration','managed_paths','files') -Label 'Release manifest'
    Assert-ExactProperties -Value $release.upstream -Expected @('repository','tag','commit') -Label 'Release upstream identity'
    Assert-ExactProperties -Value $release.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Release Windows patchset identity'
    Assert-ExactProperties -Value $release.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Release wheel identity'
    $orchestrationProps = @('python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest','python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root')
    Assert-ExactProperties -Value $release.orchestration -Expected $orchestrationProps -Label 'Release orchestration'
    if ([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64') { throw 'Installed release manifest has unsupported schema/component/platform.' }
    if ([string]$state.release -ne [string]$release.release -or [string]$state.platform -ne [string]$release.platform) { throw 'Install state and release manifest disagree on release/platform.' }
    if (-not (Test-IdentityFields $state.upstream $release.upstream @('repository','tag','commit'))) { throw 'Install state and release manifest disagree on upstream identity.' }
    if (-not (Test-IdentityFields $state.windows_patchset $release.windows_patchset @('implementation_commit','tree','patch_sha256'))) { throw 'Install state and release manifest disagree on Windows patchset identity.' }
    if (-not (Test-IdentityFields $state.wheel $release.wheel @('filename','version','size_bytes','sha256'))) { throw 'Install state and release manifest disagree on wheel identity.' }

    $releaseRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.self_path) -Label 'Release manifest self_path'
    $expectedReleasePath = Join-Path $InstallationRoot $releaseRelative
    if (-not (Test-PathEqual $releasePath $expectedReleasePath)) { throw 'Installed release manifest path does not match release self_path.' }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $releasePath -RelativePath $releaseRelative)

    $orchestrationPaths = @{}
    foreach ($name in $orchestrationProps) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.$name) -Label "Release orchestration path '$name'"
        $orchestrationPaths[$name] = Join-Path $InstallationRoot $relative
    }
    $runtimeRoot = Get-VllmNormalizedPath $orchestrationPaths.runtime_root
    if (-not (Test-PathEqual ([string]$state.runtime.root) $runtimeRoot)) { throw 'Install-state runtime root does not match release orchestration.' }
    if (-not (Test-PathEqual ([string]$state.python.receipt) $orchestrationPaths.python_receipt)) { throw 'Install-state Python receipt path does not match release orchestration.' }
    if (-not (Test-PathEqual ([string]$state.uv.receipt) $orchestrationPaths.uv_receipt)) { throw 'Install-state uv receipt path does not match release orchestration.' }
    if (-not (Test-PathEqual ([string]$state.runtime.dependency_receipt) $orchestrationPaths.dependency_receipt) -or
        -not (Test-PathEqual ([string]$state.runtime.final_receipt) $orchestrationPaths.runtime_receipt)) {
        throw 'Install-state runtime receipt paths do not match release orchestration.'
    }

    $expectedDistribution = @{}
    foreach ($entry in @($release.files)) {
        Assert-ExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Release distribution entry'
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release distribution path'
        $key = Get-NormalizedRelativeKey $relative
        if ($expectedDistribution.ContainsKey($key)) { throw "Release manifest contains duplicate distribution path: $relative" }
        if ([int64]$entry.size_bytes -lt 0 -or [string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Release distribution identity is invalid: $relative" }
        $expectedDistribution[$key] = [pscustomobject]@{ RelativePath=$relative; Size=[int64]$entry.size_bytes; Sha256=[string]$entry.sha256 }
    }
    $releaseKey = Get-NormalizedRelativeKey $releaseRelative
    if ($expectedDistribution.ContainsKey($releaseKey)) { throw 'Release manifest self_path is duplicated in release files.' }
    $expectedDistribution[$releaseKey] = [pscustomobject]@{ RelativePath=$releaseRelative; Size=[int64]$releaseId.Size; Sha256=[string]$releaseId.Sha256 }

    $actualDistribution = @{}
    foreach ($entry in @($state.distribution_files)) {
        Assert-ExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Install-state distribution entry'
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Install-state distribution path'
        $key = Get-NormalizedRelativeKey $relative
        if ($actualDistribution.ContainsKey($key)) { throw "Install state contains duplicate distribution path: $relative" }
        if ([int64]$entry.size_bytes -lt 0 -or [string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Install-state distribution identity is invalid: $relative" }
        $actualDistribution[$key] = [pscustomobject]@{ RelativePath=$relative; Size=[int64]$entry.size_bytes; Sha256=[string]$entry.sha256 }
    }
    if ($actualDistribution.Count -ne $expectedDistribution.Count) { throw 'Install state and release manifest disagree on distribution file count.' }

    $distributionPlan = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($expectedDistribution.Keys | Sort-Object)) {
        if (-not $actualDistribution.ContainsKey($key)) { throw "Install state is missing release-owned distribution path: $($expectedDistribution[$key].RelativePath)" }
        $expected = $expectedDistribution[$key]
        $actual = $actualDistribution[$key]
        if ($expected.Size -ne $actual.Size -or $expected.Sha256 -ne $actual.Sha256) { throw "Install state and release manifest disagree on distribution identity: $($expected.RelativePath)" }
        $path = Join-Path $InstallationRoot $expected.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Owned distribution file is missing: $path" }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $expected.RelativePath)
        $identity = Get-FileIdentity $path
        if ($identity.Size -ne $expected.Size -or $identity.Sha256 -ne $expected.Sha256) { throw "Owned distribution file has drifted: $($expected.RelativePath)" }
        $distributionPlan.Add([pscustomobject]@{ RelativePath=$expected.RelativePath; Path=$path; Size=$expected.Size; Sha256=$expected.Sha256 })
    }

    $releaseManaged = @{}
    foreach ($value in @($release.managed_paths)) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$value) -Label 'Release managed path'
        $key = Get-NormalizedRelativeKey $relative
        if ($releaseManaged.ContainsKey($key)) { throw "Release manifest contains duplicate managed path: $relative" }
        $releaseManaged[$key] = $relative
    }
    $stateManaged = @{}
    foreach ($value in @($state.managed_paths)) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$value) -Label 'Install-state managed path'
        $key = Get-NormalizedRelativeKey $relative
        if ($stateManaged.ContainsKey($key)) { throw "Install state contains duplicate managed path: $relative" }
        $stateManaged[$key] = $relative
    }
    if ($releaseManaged.Count -ne $stateManaged.Count) { throw 'Install state and release manifest disagree on managed path count.' }
    foreach ($key in $releaseManaged.Keys) {
        if (-not $stateManaged.ContainsKey($key)) { throw "Install state is missing release-owned managed path: $($releaseManaged[$key])" }
    }

    $stateKey = Get-NormalizedRelativeKey 'state\install-state.json'
    $orchestratorLockKey = Get-NormalizedRelativeKey 'state\install-orchestrator.lock'
    $operationLockKey = Get-NormalizedRelativeKey '.vllm-operation.lock'
    foreach ($requiredKey in @($stateKey,$orchestratorLockKey,$operationLockKey)) {
        if (-not $releaseManaged.ContainsKey($requiredKey)) { throw "Release manifest is missing required lifecycle-owned path: $requiredKey" }
    }

    $managedPlan = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($releaseManaged.Keys | Sort-Object)) {
        $relative = $releaseManaged[$key]
        $path = Join-Path $InstallationRoot $relative
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $relative)

        $protectedConfig = Join-Path $InstallationRoot 'config.psd1'
        if ((Test-VllmPathInsideOrEqual -Path $path -Parent $modelsRoot) -or
            (Test-VllmPathInsideOrEqual -Path $modelsRoot -Parent $path)) {
            throw "Managed path overlaps ModelsRoot and cannot be uninstalled safely: $relative"
        }
        if ((Test-VllmPathInsideOrEqual -Path $path -Parent $modelsRoot -Physical) -or
            (Test-VllmPathInsideOrEqual -Path $modelsRoot -Parent $path -Physical)) {
            throw "Managed path physically overlaps ModelsRoot and cannot be uninstalled safely: $relative"
        }
        if (Test-PathEqual $path $protectedConfig) { throw 'config.psd1 must never be release-managed by uninstall.' }

        $role = if ($key -eq $stateKey) { 'state' } elseif ($key -eq $orchestratorLockKey) { 'orchestrator-lock' } elseif ($key -eq $operationLockKey) { 'operation-lock' } else { 'managed' }
        $entry = Get-VllmPathEntryInfo -Path $path
        if ($role -eq 'managed' -and $entry.Exists -and $entry.IsDirectory) {
            Assert-ManagedTreeNoReparsePoints -Path $path -RelativePath $relative
        }
        $managedPlan.Add([pscustomobject]@{ RelativePath=$relative; Path=$path; Exists=[bool]$entry.Exists; IsDirectory=[bool]$entry.IsDirectory; Role=$role })
    }

    foreach ($item in $distributionPlan) {
        $path = [string]$item.Path
        $relative = [string]$item.RelativePath
        $protectedConfig = Join-Path $InstallationRoot 'config.psd1'
        if ((Test-VllmPathInsideOrEqual -Path $path -Parent $modelsRoot) -or
            (Test-VllmPathInsideOrEqual -Path $modelsRoot -Parent $path)) {
            throw "Distribution path overlaps ModelsRoot and cannot be uninstalled safely: $relative"
        }
        if ((Test-VllmPathInsideOrEqual -Path $path -Parent $modelsRoot -Physical) -or
            (Test-VllmPathInsideOrEqual -Path $modelsRoot -Parent $path -Physical)) {
            throw "Distribution path physically overlaps ModelsRoot and cannot be uninstalled safely: $relative"
        }
        if (Test-PathEqual $path $protectedConfig) { throw 'config.psd1 must never be release-owned by uninstall.' }
    }


    $managedKeys = @($releaseManaged.Keys)
    for ($i = 0; $i -lt $managedKeys.Count; $i++) {
        $left = Join-Path $InstallationRoot $releaseManaged[$managedKeys[$i]]
        for ($j = $i + 1; $j -lt $managedKeys.Count; $j++) {
            $right = Join-Path $InstallationRoot $releaseManaged[$managedKeys[$j]]
            if ((Test-VllmPathInsideOrEqual -Path $left -Parent $right) -or
                (Test-VllmPathInsideOrEqual -Path $right -Parent $left)) {
                throw "Managed paths overlap and ownership is ambiguous: '$($releaseManaged[$managedKeys[$i]])' / '$($releaseManaged[$managedKeys[$j]])'"
            }
        }
        foreach ($distribution in $distributionPlan) {
            if (Test-VllmPathInsideOrEqual -Path ([string]$distribution.Path) -Parent $left) {
                throw "Managed path contains a separately identity-tracked distribution file: $($releaseManaged[$managedKeys[$i]])"
            }
        }
    }

    [pscustomobject][ordered]@{
        State = $state
        Release = $release
        GenerationId = [string]$state.generation_id
        StatePath = $statePath
        StateSize = [int64]$stateIdentity.Size
        StateSha256 = [string]$stateIdentity.Sha256
        ReleasePath = $releasePath
        ModelsRoot = $modelsRoot
        RuntimeRoot = $runtimeRoot
        OrchestratorLockPath = (Join-Path $InstallationRoot 'state\install-orchestrator.lock')
        OperationLockPath = (Join-Path $InstallationRoot '.vllm-operation.lock')
        DistributionFiles = $distributionPlan.ToArray()
        ManagedPaths = $managedPlan.ToArray()
    }
}


function Enter-UninstallOrchestratorLock {
    $stateDir = Join-Path $InstallationRoot 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw "Install state directory is missing: $stateDir"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stateDir -RelativePath 'state')
    $lockPath = Join-Path $stateDir 'install-orchestrator.lock'
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $lockPath -RelativePath 'state\install-orchestrator.lock')
    try {
        $stream = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw "Another top-level install/uninstall operation is active for '$InstallationRoot'."
    } catch [UnauthorizedAccessException] {
        throw "Install orchestrator lock cannot be acquired safely: $lockPath"
    }
    try {
        $rootPhysical = Get-VllmPhysicalCandidatePath -Path $InstallationRoot -Format Guid
        $expected = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootPhysical, 'state\install-orchestrator.lock'))
        $actual = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Install orchestrator lock resolves outside expected location: $actual"
        }
        $linkCount = [VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)
        if ($linkCount -ne 1) {
            throw "Install orchestrator lock has unexpected hard-link count $linkCount; refusing uninstall."
        }
        [pscustomobject]@{ Stream=$stream; Path=$lockPath }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Exit-UninstallOrchestratorLock {
    param([Parameter(Mandatory)]$Lock)
    if ($null -ne $Lock.Stream) { $Lock.Stream.Dispose() }
}

function Assert-NoManagedRuntimeProcesses {
    param([Parameter(Mandatory)]$Plan)
    $runtimeRoot = Get-VllmNormalizedPath ([string]$Plan.RuntimeRoot)
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        throw "Cannot enumerate Windows processes safely before uninstall: $($_.Exception.Message)"
    }

    $processMatches = New-Object System.Collections.Generic.List[object]
    foreach ($process in $processes) {
        $executable = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        $managed = $false
        if (-not [string]::IsNullOrWhiteSpace($executable)) {
            try {
                $managed = Test-VllmPathInsideOrEqual -Path (Get-VllmNormalizedPath $executable) -Parent $runtimeRoot
            } catch {
                $managed = $false
            }
        }
        if (-not $managed -and -not [string]::IsNullOrWhiteSpace($commandLine)) {
            $normalizedCommand = $commandLine.Replace('/','\')
            $managed = $normalizedCommand.IndexOf($runtimeRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if ($managed) {
            $processMatches.Add([pscustomobject]@{
                ProcessId = [uint32]$process.ProcessId
                Name = [string]$process.Name
                ExecutablePath = $executable
                CommandLine = $commandLine
            })
        }
    }
    if ($processMatches.Count -gt 0) {
        $summary = (($processMatches.ToArray() | ForEach-Object { "PID=$($_.ProcessId) name=$($_.Name)" }) -join '; ')
        throw "Managed runtime process is still running; stop it before uninstall: $summary"
    }
}

function Add-UninstallParentCandidates {
    param(
        [Parameter(Mandatory)][hashtable]$Candidates,
        [Parameter(Mandatory)][string]$Path
    )
    $root = Get-VllmNormalizedPath $InstallationRoot
    $parent = Split-Path -Parent (Get-VllmNormalizedPath $Path)
    while (-not [string]::IsNullOrWhiteSpace($parent) -and
           -not $parent.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
           (Test-VllmPathInsideOrEqual -Path $parent -Parent $root)) {
        $Candidates[$parent.ToLowerInvariant()] = $parent
        $next = Split-Path -Parent $parent
        if ([string]::IsNullOrWhiteSpace($next) -or $next.Equals($parent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = $next
    }
}

function Assert-DistributionRemovalTarget {
    param([Parameter(Mandatory)]$Item)
    $path = [string]$Item.Path
    $relative = [string]$Item.RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Owned distribution file disappeared after planning: $relative"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $relative)
    $identity = Get-FileIdentity -Path $path
    if ($identity.Size -ne [int64]$Item.Size -or $identity.Sha256 -ne [string]$Item.Sha256) {
        throw "Owned distribution file changed after planning: $relative"
    }
}

function Test-ManagedRemovalTargetStable {
    param([Parameter(Mandatory)]$Item)
    $path = [string]$Item.Path
    $relative = [string]$Item.RelativePath
    $entry = Get-VllmPathEntryInfo -Path $path
    if (-not [bool]$Item.Exists) {
        if ($entry.Exists) { throw "Managed path appeared after planning; refusing to delete it: $relative" }
        return $false
    }
    if (-not $entry.Exists) { throw "Managed path disappeared after planning: $relative" }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $relative)
    if ([bool]$entry.IsDirectory -ne [bool]$Item.IsDirectory) {
        throw "Managed path type changed after planning: $relative"
    }
    if ($entry.IsDirectory) {
        Assert-ManagedTreeNoReparsePoints -Path $path -RelativePath $relative
    }
    return $true
}

function Invoke-UninstallLockCleanup {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Lifecycle lock file disappeared before safe cleanup: $Path"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $rootPhysical = Get-VllmPhysicalCandidatePath -Path $InstallationRoot -Format Guid
        $expected = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootPhysical, $RelativePath))
        $actual = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Lifecycle lock resolves outside expected location: $actual"
        }
        $linkCount = [VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)
        if ($linkCount -ne 1) { throw "Lifecycle lock has unexpected hard-link count $linkCount; refusing cleanup: $Path" }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    Remove-Item -LiteralPath $Path -Force
}

function Invoke-EmptyUninstallParentCleanup {
    param([Parameter(Mandatory)][hashtable]$Candidates)
    $root = Get-VllmNormalizedPath $InstallationRoot
    $rootPrefix = if ($root.EndsWith('\')) { $root } else { $root + '\' }
    foreach ($path in @($Candidates.Values | Sort-Object { $_.Length } -Descending)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $entry = Get-VllmPathEntryInfo -Path $path
        if (-not $entry.Exists -or -not $entry.IsDirectory) { continue }
        if (-not (Test-VllmPathInsideOrEqual -Path $path -Parent $root) -or $path.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $path.Substring($rootPrefix.Length)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath $relative)
        $children = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Select-Object -First 1)
        if ($children.Count -eq 0) { Remove-Item -LiteralPath $path -Force }
    }
}

$orchestratorLock = $null
$operationLock = $null
$plan = $null
$result = $null
$parentCandidates = @{}
$stateCommitted = $false
try {
    # WhatIf still acquires both lifecycle locks so validation observes a serialized snapshot.
    # The operation-lock file is coordination metadata and may be refreshed; owned payload/state is not mutated.
    $orchestratorLock = Enter-UninstallOrchestratorLock
    $operationLock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'uninstall'
    $plan = Get-UninstallPlan
    Assert-NoManagedRuntimeProcesses -Plan $plan

    $action = "Remove only release-owned vLLM Windows Native files and managed trees; preserve ModelsRoot, config.psd1, unknown paths, and machine-wide prerequisites"
    $approved = $PSCmdlet.ShouldProcess($InstallationRoot, $action)
    if (-not $approved) {
        $result = [ordered]@{
            schema_version = 1
            component = 'uninstall'
            ready = $true
            removed = $false
            what_if = [bool]$WhatIfPreference
            generation_id = [string]$plan.GenerationId
            install_root = $InstallationRoot
            models_root = [string]$plan.ModelsRoot
            distribution_files = [int]$plan.DistributionFiles.Count
            managed_paths = [int]$plan.ManagedPaths.Count
        }
    } else {
        foreach ($item in @($plan.ManagedPaths | Where-Object { $_.Role -eq 'managed' })) {
            if (-not (Test-ManagedRemovalTargetStable -Item $item)) { continue }
            Add-UninstallParentCandidates -Candidates $parentCandidates -Path ([string]$item.Path)
            if ([bool]$item.IsDirectory) {
                Remove-Item -LiteralPath ([string]$item.Path) -Recurse -Force
            } else {
                Remove-Item -LiteralPath ([string]$item.Path) -Force
            }
        }

        foreach ($item in $plan.DistributionFiles) {
            Assert-DistributionRemovalTarget -Item $item
            Add-UninstallParentCandidates -Candidates $parentCandidates -Path ([string]$item.Path)
            Remove-Item -LiteralPath ([string]$item.Path) -Force
        }

        Exit-VllmOperationLock -Lock $operationLock
        $operationLock = $null
        Invoke-UninstallLockCleanup -Path ([string]$plan.OperationLockPath) -RelativePath '.vllm-operation.lock'
        Add-UninstallParentCandidates -Candidates $parentCandidates -Path ([string]$plan.OperationLockPath)

        if (-not (Test-Path -LiteralPath $plan.StatePath -PathType Leaf)) { throw 'Install state disappeared before commit-marker removal.' }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $plan.StatePath -RelativePath 'state\install-state.json')
        $currentStateIdentity = Get-FileIdentity -Path $plan.StatePath
        if ($currentStateIdentity.Size -ne [int64]$plan.StateSize -or $currentStateIdentity.Sha256 -ne [string]$plan.StateSha256) {
            throw 'Install state changed after uninstall planning; refusing to remove the commit marker.'
        }
        Add-UninstallParentCandidates -Candidates $parentCandidates -Path ([string]$plan.StatePath)
        Remove-Item -LiteralPath $plan.StatePath -Force
        $stateCommitted = $true

        Exit-UninstallOrchestratorLock -Lock $orchestratorLock
        $orchestratorLock = $null
        try {
            Invoke-UninstallLockCleanup -Path ([string]$plan.OrchestratorLockPath) -RelativePath 'state\install-orchestrator.lock'
            Add-UninstallParentCandidates -Candidates $parentCandidates -Path ([string]$plan.OrchestratorLockPath)
        } catch {
            Write-Warning "Uninstall committed, but orchestrator lock cleanup was not completed safely: $($_.Exception.Message)"
        }
        try {
            Invoke-EmptyUninstallParentCleanup -Candidates $parentCandidates
        } catch {
            Write-Warning "Uninstall committed, but empty-directory cleanup was not completed safely: $($_.Exception.Message)"
        }

        $result = [ordered]@{
            schema_version = 1
            component = 'uninstall'
            ready = $true
            removed = $true
            what_if = $false
            generation_id = [string]$plan.GenerationId
            install_root = $InstallationRoot
            models_root = [string]$plan.ModelsRoot
            preserved_config = (Join-Path $InstallationRoot 'config.psd1')
        }
    }
} finally {
    if ($null -ne $operationLock) { Exit-VllmOperationLock -Lock $operationLock }
    if ($null -ne $orchestratorLock) { Exit-UninstallOrchestratorLock -Lock $orchestratorLock }
}

if ($null -eq $result) {
    if ($stateCommitted) { throw 'Uninstall commit completed without a result object.' }
    throw 'Uninstall did not complete.'
}
if ($Json) {
    [pscustomobject]$result | ConvertTo-Json -Depth 8
} elseif ([bool]$result.removed) {
    Write-Host "vLLM Windows Native uninstalled from: $InstallationRoot"
    Write-Host "Models preserved: $($result.models_root)"
    Write-Host 'UNINSTALL_READY'
} elseif ([bool]$result.what_if) {
    Write-Host 'UNINSTALL_WHATIF_READY'
} else {
    Write-Host 'UNINSTALL_CANCELLED'
}
