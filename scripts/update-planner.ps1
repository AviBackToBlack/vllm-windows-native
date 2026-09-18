Set-StrictMode -Version Latest

function Get-VllmUpdateFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Expected a file, got a directory: $Path" }
    [pscustomobject][ordered]@{
        Size = [int64]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Get-VllmUpdateRelativeKey {
    param([Parameter(Mandatory)][string]$Path)
    return (Assert-VllmSafeRelativePath -RelativePath $Path -Label 'Update-owned relative path').Replace('\','/').ToLowerInvariant()
}

function Test-VllmUpdatePathEqual {
    param([Parameter(Mandatory)][string]$A,[Parameter(Mandatory)][string]$B)
    return (Get-VllmNormalizedPath $A).Equals((Get-VllmNormalizedPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Test-VllmUpdateRelativePathEqual {
    param([Parameter(Mandatory)][string]$A,[Parameter(Mandatory)][string]$B)
    try { return (Get-VllmUpdateRelativeKey $A) -eq (Get-VllmUpdateRelativeKey $B) }
    catch { return $false }
}

function Get-VllmUpdatePayloadRoot {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$SelfPath
    )
    $manifest = Get-VllmNormalizedPath $ManifestPath
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Release manifest is missing: $manifest" }
    $manifestEntry = Get-VllmPathEntryInfo -Path $manifest
    if ($manifestEntry.IsReparsePoint) { throw "Release manifest must not be a reparse point: $manifest" }
    $manifestPhysical = Get-VllmCanonicalExistingPath -Path $manifest -Format Dos
    if (-not $manifestPhysical.Equals($manifest, [StringComparison]::OrdinalIgnoreCase)) { throw "Release manifest resolves through a filesystem alias: $manifest -> $manifestPhysical" }
    $relative = Assert-VllmSafeRelativePath -RelativePath $SelfPath -Label 'Release manifest self_path'
    $parts = @($relative.Split([char]92))
    $cursor = Split-Path -Parent $manifest
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { throw "Cannot derive payload root from release self_path '$relative'." }
        $cursor = $parent.FullName
    }
    $root = Get-VllmNormalizedPath $cursor
    $expected = Get-VllmNormalizedPath (Join-Path $root $relative)
    if (-not $expected.Equals($manifest, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release manifest path does not match self_path '$relative'."
    }
    $physical = Get-VllmCanonicalExistingPath -Path $root -Format Dos
    if (-not $physical.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release payload root resolves through a filesystem alias: $root -> $physical"
    }
    return $root
}

function Get-VllmUpdatePayloadFile {
    param(
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][int64]$Size,
        [Parameter(Mandatory)][string]$Sha256,
        [string]$Label = 'Release payload file'
    )
    $relative = Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label "$Label path"
    if ($Size -lt 0 -or $Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "$Label has an invalid identity: $relative" }
    $path = Get-VllmNormalizedPath (Join-Path $PayloadRoot $relative)
    if (-not (Test-VllmPathInsideOrEqual -Path $path -Parent $PayloadRoot)) { throw "$Label escapes payload root: $relative" }
    $entry = Get-VllmPathEntryInfo -Path $path
    if (-not $entry.Exists -or $entry.IsDirectory) { throw "$Label is missing or is not a file: $path" }
    if ($entry.IsReparsePoint) { throw "$Label is a reparse point and is not accepted: $path" }
    $physical = Get-VllmCanonicalExistingPath -Path $path -Format Dos
    if (-not $physical.Equals($path, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label resolves through a filesystem alias: $path -> $physical" }
    $identity = Get-VllmUpdateFileIdentity -Path $path
    $expectedHash = $Sha256.ToUpperInvariant()
    if ($identity.Size -ne $Size -or $identity.Sha256 -ne $expectedHash) { throw "$Label identity mismatch: $relative" }
    return [pscustomobject][ordered]@{
        RelativePath = $relative
        Path = $path
        Size = $identity.Size
        Sha256 = $identity.Sha256
    }
}

function Get-VllmUpdateDistributionEntry {
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $relative = Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label "$Label path"
    $key = Get-VllmUpdateRelativeKey $relative
    if (-not $Map.ContainsKey($key)) { throw "$Label is not owned by the release payload: $relative" }
    return $Map[$key]
}

function Read-VllmUpdateOwnedJson {
    param(
        [Parameter(Mandatory)][hashtable]$Distribution,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $entry = Get-VllmUpdateDistributionEntry -Map $Distribution -RelativePath $RelativePath -Label $Label
    try { $value = Get-Content -LiteralPath $entry.Path -Raw | ConvertFrom-Json }
    catch { throw "$Label is malformed JSON: $($entry.RelativePath)" }
    return [pscustomobject]@{ Entry=$entry; Value=$value }
}

function Assert-VllmUpdatePinnedReference {
    param(
        [Parameter(Mandatory)]$Descriptor,
        [Parameter(Mandatory)][hashtable]$Distribution,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($required in @('path','size_bytes','sha256')) {
        if ($Descriptor.PSObject.Properties.Name -notcontains $required) { throw "$Label is missing '$required'." }
    }
    $entry = Get-VllmUpdateDistributionEntry -Map $Distribution -RelativePath ([string]$Descriptor.path) -Label $Label
    if ([int64]$Descriptor.size_bytes -ne $entry.Size -or ([string]$Descriptor.sha256).ToUpperInvariant() -ne $entry.Sha256) {
        throw "$Label identity does not match its release distribution entry: $($entry.RelativePath)"
    }
    return $entry
}

function Test-VllmUpdateRecordedReleaseIdentityEqual {
    param([Parameter(Mandatory)]$A,[Parameter(Mandatory)]$B)
    foreach ($name in @('release','platform')) { if ([string]$A.$name -ne [string]$B.$name) { return $false } }
    foreach ($name in @('repository','tag','commit')) { if ([string]$A.upstream.$name -ne [string]$B.upstream.$name) { return $false } }
    foreach ($name in @('implementation_commit','tree','patch_sha256')) { if ([string]$A.windows_patchset.$name -ne [string]$B.windows_patchset.$name) { return $false } }
    foreach ($name in @('filename','version','size_bytes','sha256')) { if ([string]$A.wheel.$name -ne [string]$B.wheel.$name) { return $false } }
    return $true
}

function Assert-VllmUpdateNoProtectedOverlap {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $relative = Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label "$Label path"
    $path = Join-Path $InstallationRoot $relative
    $config = Join-Path $InstallationRoot 'config.psd1'
    if ((Test-VllmPathInsideOrEqual -Path $path -Parent $config) -or
        (Test-VllmPathInsideOrEqual -Path $config -Parent $path)) {
        throw "$Label must not own or contain protected config.psd1."
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $relative)
    if ((Test-VllmPathInsideOrEqual -Path $path -Parent $ModelsRoot) -or
        (Test-VllmPathInsideOrEqual -Path $ModelsRoot -Parent $path) -or
        (Test-VllmPathInsideOrEqual -Path $path -Parent $ModelsRoot -Physical) -or
        (Test-VllmPathInsideOrEqual -Path $ModelsRoot -Parent $path -Physical)) {
        throw "$Label overlaps protected ModelsRoot: $relative"
    }
}

function Assert-VllmUpdateOrdinaryPathNotLifecycleOwned {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Label = 'Ordinary update path'
    )
    $relative = Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label "$Label path"
    $path = Join-Path $InstallationRoot $relative
    foreach ($reserved in @(
        'state\install-state.json',
        'state\install-orchestrator.lock',
        '.vllm-operation.lock',
        'state\update-transaction.json',
        'work\update-transaction'
    )) {
        $reservedPath = Join-Path $InstallationRoot $reserved
        if ((Test-VllmPathInsideOrEqual -Path $path -Parent $reservedPath) -or
            (Test-VllmPathInsideOrEqual -Path $reservedPath -Parent $path)) {
            throw "$Label overlaps lifecycle-owned control metadata: $relative"
        }
    }
}

function Assert-VllmUpdateManagedTreeNoReparsePoints {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $rootEntry = Get-VllmPathEntryInfo -Path $Path
    if (-not $rootEntry.Exists -or -not $rootEntry.IsDirectory) { throw "$Label is missing or is not a directory: $Path" }
    if ($rootEntry.IsReparsePoint) { throw "$Label is a reparse point: $Path" }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($rootEntry.Path)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($child in Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) {
            $entry = Get-VllmPathEntryInfo -Path $child.FullName
            if (-not $entry.Exists) { throw "$Label entry disappeared during validation: $($child.FullName)" }
            if ($entry.IsReparsePoint) { throw "$Label contains a reparse point: $($child.FullName)" }
            if ($entry.IsDirectory) { $pending.Push($entry.Path) }
        }
    }
}

function Get-VllmUpdateReleaseContext {
    param(
        [Parameter(Mandatory)][string]$ReleaseManifestPath,
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [string]$WheelPath = '',
        [switch]$RequireUpdaterPlanner
    )
    $manifestPath = Get-VllmNormalizedPath $ReleaseManifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Release manifest is missing: $manifestPath" }
    try { $release = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "Release manifest is malformed JSON: $manifestPath" }

    Assert-VllmLifecycleExactProperties -Value $release -Expected @(
        'schema_version','component','release','platform','self_path','upstream','windows_patchset','wheel',
        'orchestration','managed_paths','files'
    ) -Label 'Release manifest'
    Assert-VllmLifecycleExactProperties -Value $release.upstream -Expected @('repository','tag','commit') -Label 'Release upstream identity'
    Assert-VllmLifecycleExactProperties -Value $release.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Release Windows patchset identity'
    Assert-VllmLifecycleExactProperties -Value $release.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Release wheel identity'
    $orchestrationProps = @(
        'python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest',
        'python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root'
    )
    Assert-VllmLifecycleExactProperties -Value $release.orchestration -Expected $orchestrationProps -Label 'Release orchestration'

    if ([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64') {
        throw 'Release manifest has unsupported schema/component/platform.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$release.release)) { throw 'Release identifier must not be empty.' }
    if ([int64]$release.wheel.size_bytes -lt 0 -or [string]$release.wheel.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Release wheel identity is invalid.' }
    $wheelName = [string]$release.wheel.filename
    if ([IO.Path]::GetFileName($wheelName) -ne $wheelName -or [string]::IsNullOrWhiteSpace($wheelName)) { throw 'Release wheel filename must be a simple filename.' }

    $payloadRoot = Get-VllmUpdatePayloadRoot -ManifestPath $manifestPath -SelfPath ([string]$release.self_path)
    $manifestIdentity = Get-VllmUpdateFileIdentity -Path $manifestPath
    $distribution = @{}
    foreach ($entry in @($release.files)) {
        Assert-VllmLifecycleExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Release distribution entry'
        $entryRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release distribution path'
        Assert-VllmUpdateOrdinaryPathNotLifecycleOwned -InstallationRoot $InstallationRoot -RelativePath $entryRelative -Label 'Release distribution path'
        $owned = Get-VllmUpdatePayloadFile -PayloadRoot $payloadRoot -RelativePath $entryRelative -Size ([int64]$entry.size_bytes) -Sha256 ([string]$entry.sha256)
        $key = Get-VllmUpdateRelativeKey $owned.RelativePath
        if ($distribution.ContainsKey($key)) { throw "Release manifest contains duplicate distribution path: $($owned.RelativePath)" }
        $distribution[$key] = $owned
    }
    $selfRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.self_path) -Label 'Release manifest self_path'
    Assert-VllmUpdateOrdinaryPathNotLifecycleOwned -InstallationRoot $InstallationRoot -RelativePath $selfRelative -Label 'Release manifest self_path'
    $selfKey = Get-VllmUpdateRelativeKey $selfRelative
    if ($distribution.ContainsKey($selfKey)) { throw 'Release manifest self_path is duplicated in release files.' }
    $distribution[$selfKey] = [pscustomobject][ordered]@{
        RelativePath=$selfRelative; Path=$manifestPath; Size=$manifestIdentity.Size; Sha256=$manifestIdentity.Sha256
    }

    $requiredLifecycleFiles = @('install.ps1','start.ps1','update.ps1','uninstall.ps1','scripts/common.ps1','scripts/lifecycle.ps1','scripts/env.ps1','config.example.psd1','LICENSE','THIRD_PARTY_NOTICES.md')
    if ($RequireUpdaterPlanner) { $requiredLifecycleFiles += @('scripts/update-planner.ps1','scripts/update-staging.ps1','scripts/update-transaction.ps1') }
    foreach ($required in $requiredLifecycleFiles) {
        [void](Get-VllmUpdateDistributionEntry -Map $distribution -RelativePath $required -Label 'Required lifecycle distribution file')
    }

    $pythonOwned = Read-VllmUpdateOwnedJson -Distribution $distribution -RelativePath ([string]$release.orchestration.python_manifest) -Label 'Python bootstrap manifest'
    $uvOwned = Read-VllmUpdateOwnedJson -Distribution $distribution -RelativePath ([string]$release.orchestration.uv_manifest) -Label 'uv bootstrap manifest'
    $venvOwned = Read-VllmUpdateOwnedJson -Distribution $distribution -RelativePath ([string]$release.orchestration.venv_manifest) -Label 'venv manifest'
    $dependencyOwned = Read-VllmUpdateOwnedJson -Distribution $distribution -RelativePath ([string]$release.orchestration.dependency_manifest) -Label 'dependency manifest'
    $runtimeOwned = Read-VllmUpdateOwnedJson -Distribution $distribution -RelativePath ([string]$release.orchestration.runtime_manifest) -Label 'runtime manifest'
    $pythonManifest=$pythonOwned.Value; $uvManifest=$uvOwned.Value; $venvManifest=$venvOwned.Value; $dependencyManifest=$dependencyOwned.Value; $runtimeManifest=$runtimeOwned.Value

    if ([int]$pythonManifest.schema_version -ne 1 -or [string]$pythonManifest.component -ne 'cpython' -or [string]$pythonManifest.platform -ne 'windows-x86_64') { throw 'Python bootstrap manifest identity is unsupported.' }
    if ([int]$uvManifest.schema_version -ne 1 -or [string]$uvManifest.component -ne 'uv' -or [string]$uvManifest.platform -ne 'windows-x86_64') { throw 'uv bootstrap manifest identity is unsupported.' }
    if ([int]$venvManifest.schema_version -ne 1 -or [string]$venvManifest.component -ne 'runtime-venv' -or [string]$venvManifest.platform -ne 'windows-x86_64') { throw 'venv manifest identity is unsupported.' }
    if ([int]$dependencyManifest.schema_version -ne 1 -or [string]$dependencyManifest.component -ne 'runtime-dependencies' -or [string]$dependencyManifest.platform -ne 'windows-x86_64') { throw 'dependency manifest identity is unsupported.' }
    if ([int]$runtimeManifest.schema_version -ne 1 -or [string]$runtimeManifest.component -ne 'vllm-runtime' -or [string]$runtimeManifest.platform -ne 'windows-x86_64') { throw 'runtime manifest identity is unsupported.' }
    foreach ($manifest in @($venvManifest,$dependencyManifest,$runtimeManifest)) {
        if ([string]$manifest.milestone -ne [string]$release.release) { throw 'Target orchestration milestone does not match release identifier.' }
    }
    if ([string]$venvManifest.python.version -ne [string]$pythonManifest.version -or
        [string]$dependencyManifest.python_version -ne [string]$pythonManifest.version -or
        [string]$runtimeManifest.python_version -ne [string]$pythonManifest.version) {
        throw 'Python version identity is inconsistent across target orchestration manifests.'
    }
    $uvVersion = [string]$uvManifest.version
    $uvCommit = [string]$uvManifest.release.commit
    if ([string]$venvManifest.uv.version -ne $uvVersion -or [string]$venvManifest.uv.commit -ne $uvCommit -or
        [string]$dependencyManifest.generator.version -ne $uvVersion -or [string]$dependencyManifest.generator.commit -ne $uvCommit -or
        [string]$runtimeManifest.generator.version -ne $uvVersion -or [string]$runtimeManifest.generator.commit -ne $uvCommit) {
        throw 'uv version/commit identity is inconsistent across target orchestration manifests.'
    }
    if ([int]$runtimeManifest.predecessor.required_package_count -ne [int]$dependencyManifest.lock.package_count) {
        throw 'Runtime predecessor package count does not match the dependency lock contract.'
    }

    $pythonRef = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.python_manifest) -Label 'Python manifest reference'
    $uvRef = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.uv_manifest) -Label 'uv manifest reference'
    $venvRef = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.venv_manifest) -Label 'venv manifest reference'
    $dependencyRef = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.dependency_manifest) -Label 'dependency manifest reference'
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$venvManifest.python.bootstrap_manifest) $pythonRef) -or -not (Test-VllmUpdateRelativePathEqual ([string]$venvManifest.uv.bootstrap_manifest) $uvRef)) { throw 'venv manifest bootstrap references do not match release orchestration.' }
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$dependencyManifest.materialization.base_venv_manifest) $venvRef)) { throw 'dependency manifest base venv reference does not match release orchestration.' }
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$runtimeManifest.predecessor.manifest) $dependencyRef) -or -not (Test-VllmUpdateRelativePathEqual ([string]$runtimeManifest.materialization.predecessor_manifest) $dependencyRef)) { throw 'runtime predecessor reference does not match release orchestration.' }

    [void](Assert-VllmUpdatePinnedReference -Descriptor $dependencyManifest.input -Distribution $distribution -Label 'Dependency input')
    [void](Assert-VllmUpdatePinnedReference -Descriptor $dependencyManifest.lock -Distribution $distribution -Label 'Dependency lock')
    [void](Assert-VllmUpdatePinnedReference -Descriptor $runtimeManifest.input -Distribution $distribution -Label 'Runtime input')
    [void](Assert-VllmUpdatePinnedReference -Descriptor $runtimeManifest.lock -Distribution $distribution -Label 'Runtime lock')
    [void](Assert-VllmUpdatePinnedReference -Descriptor $runtimeManifest.accepted_packages -Distribution $distribution -Label 'Runtime accepted-package map')

    foreach ($name in @('filename','version','size_bytes','sha256')) {
        if ([string]$runtimeManifest.project_wheel.$name -ne [string]$release.wheel.$name) { throw 'Runtime manifest project wheel does not match release wheel identity.' }
    }

    $runtimeRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.runtime_root) -Label 'Runtime root'
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$venvManifest.install.managed_relative_path) $runtimeRelative) -or
        -not (Test-VllmUpdateRelativePathEqual ([string]$dependencyManifest.materialization.target_relative_path) $runtimeRelative) -or
        -not (Test-VllmUpdateRelativePathEqual ([string]$runtimeManifest.materialization.target_relative_path) $runtimeRelative)) {
        throw 'Runtime managed path is inconsistent across release manifests.'
    }
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$dependencyManifest.materialization.receipt_relative_path) ([string]$release.orchestration.dependency_receipt)) -or
        -not (Test-VllmUpdateRelativePathEqual ([string]$runtimeManifest.materialization.receipt_relative_path) ([string]$release.orchestration.runtime_receipt)) -or
        -not (Test-VllmUpdateRelativePathEqual ([string]$runtimeManifest.predecessor.receipt_relative_path) ([string]$release.orchestration.dependency_receipt))) {
        throw 'Runtime receipt references do not match release orchestration.'
    }
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$dependencyManifest.materialization.base_venv_receipt_relative_path) ([string]$release.orchestration.venv_receipt))) {
        throw 'Dependency base-venv receipt reference does not match release orchestration.'
    }
    if (-not (Test-VllmUpdateRelativePathEqual ([string]$dependencyManifest.materialization.cache_relative_path) ([string]$runtimeManifest.materialization.cache_relative_path))) {
        throw 'Dependency/runtime cache paths disagree.'
    }

    if (-not [string]::IsNullOrWhiteSpace($WheelPath)) {
        $wheel = Get-VllmNormalizedPath $WheelPath
        if (-not (Test-Path -LiteralPath $wheel -PathType Leaf)) { throw "Target wheel is missing: $wheel" }
        $wheelEntry = Get-VllmPathEntryInfo -Path $wheel
        if ($wheelEntry.IsReparsePoint) { throw "Target wheel must not be a reparse point: $wheel" }
        $wheelPhysical = Get-VllmCanonicalExistingPath -Path $wheel -Format Dos
        if (-not $wheelPhysical.Equals($wheel, [StringComparison]::OrdinalIgnoreCase)) { throw "Target wheel resolves through a filesystem alias: $wheel -> $wheelPhysical" }
        $wheelIdentity = Get-VllmUpdateFileIdentity -Path $wheel
        if ([IO.Path]::GetFileName($wheel) -ne $wheelName -or $wheelIdentity.Size -ne [int64]$release.wheel.size_bytes -or $wheelIdentity.Sha256 -ne ([string]$release.wheel.sha256).ToUpperInvariant()) {
            throw 'Target wheel does not match release manifest identity.'
        }
    } else {
        $wheel = $null
        $wheelIdentity = $null
    }

    $contracts = @{}
    $addContract = {
        param([string]$Relative,[string]$Role,[string]$Contract)
        $safe = Assert-VllmSafeRelativePath -RelativePath $Relative -Label "$Role managed path"
        Assert-VllmUpdateOrdinaryPathNotLifecycleOwned -InstallationRoot $InstallationRoot -RelativePath $safe -Label "$Role managed path"
        $key = Get-VllmUpdateRelativeKey $safe
        if ($contracts.ContainsKey($key)) { throw "Managed contract paths overlap by identity: $safe" }
        $contracts[$key] = [pscustomobject][ordered]@{ RelativePath=$safe; Role=$Role; Contract=$Contract }
    }
    & $addContract ([string]$pythonManifest.install.managed_relative_path) 'python' $pythonOwned.Entry.Sha256
    & $addContract ([string]$uvManifest.install.managed_relative_path) 'uv' $uvOwned.Entry.Sha256
    $runtimeContract = ((@($venvOwned.Entry.Sha256,$dependencyOwned.Entry.Sha256,$runtimeOwned.Entry.Sha256,([string]$release.wheel.sha256).ToUpperInvariant())) -join ':')
    & $addContract $runtimeRelative 'runtime' $runtimeContract
    & $addContract ([string]$dependencyManifest.materialization.cache_relative_path) 'cache' 'cache-v1'
    & $addContract ([string]$release.orchestration.python_receipt) 'python-receipt' $pythonOwned.Entry.Sha256
    & $addContract ([string]$release.orchestration.uv_receipt) 'uv-receipt' $uvOwned.Entry.Sha256
    & $addContract ([string]$release.orchestration.venv_receipt) 'venv-receipt' $venvOwned.Entry.Sha256
    & $addContract ([string]$release.orchestration.dependency_receipt) 'dependency-receipt' $dependencyOwned.Entry.Sha256
    & $addContract ([string]$release.orchestration.runtime_receipt) 'runtime-receipt' $runtimeOwned.Entry.Sha256

    $lifecycle = @{}
    foreach ($relative in @('state\install-state.json','state\install-orchestrator.lock','.vllm-operation.lock','state\update-transaction.json','work\update-transaction')) {
        $safe = Assert-VllmSafeRelativePath -RelativePath $relative -Label 'Lifecycle-control path'
        $lifecycle[(Get-VllmUpdateRelativeKey $safe)] = $safe
    }
    $managed = @{}
    foreach ($value in @($release.managed_paths)) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$value) -Label 'Release managed path'
        $key = Get-VllmUpdateRelativeKey $relative
        if ($managed.ContainsKey($key)) { throw "Release manifest contains duplicate managed path: $relative" }
        $managed[$key] = $relative
    }
    $requiredLifecycleManaged = @('state\install-state.json','state\install-orchestrator.lock','.vllm-operation.lock')
    if ($RequireUpdaterPlanner) {
        $requiredLifecycleManaged += @('state\update-transaction.json','work\update-transaction')
    }
    foreach ($required in $requiredLifecycleManaged) {
        if (-not $managed.ContainsKey((Get-VllmUpdateRelativeKey $required))) { throw "Release manifest is missing required lifecycle-owned path: $required" }
    }
    foreach ($key in $contracts.Keys) {
        if (-not $managed.ContainsKey($key)) { throw "Release manifest is missing contract-managed path: $($contracts[$key].RelativePath)" }
    }
    foreach ($key in $managed.Keys) {
        if (-not $contracts.ContainsKey($key) -and -not $lifecycle.ContainsKey($key)) { throw "Release manifest contains a managed path with no supported update contract: $($managed[$key])" }
    }

    $allManagedKeys = @($managed.Keys | Sort-Object)
    for ($i=0; $i -lt $allManagedKeys.Count; $i++) {
        $left = Join-Path $InstallationRoot $managed[$allManagedKeys[$i]]
        Assert-VllmUpdateNoProtectedOverlap -InstallationRoot $InstallationRoot -ModelsRoot $ModelsRoot -RelativePath $managed[$allManagedKeys[$i]] -Label 'Managed path'
        for ($j=$i+1; $j -lt $allManagedKeys.Count; $j++) {
            $right = Join-Path $InstallationRoot $managed[$allManagedKeys[$j]]
            if ((Test-VllmPathInsideOrEqual -Path $left -Parent $right) -or (Test-VllmPathInsideOrEqual -Path $right -Parent $left)) {
                throw "Managed paths overlap and update ownership is ambiguous: '$($managed[$allManagedKeys[$i]])' / '$($managed[$allManagedKeys[$j]])'"
            }
        }
    }
    foreach ($entry in $distribution.Values) {
        Assert-VllmUpdateNoProtectedOverlap -InstallationRoot $InstallationRoot -ModelsRoot $ModelsRoot -RelativePath $entry.RelativePath -Label 'Distribution path'
        $live = Join-Path $InstallationRoot $entry.RelativePath
        foreach ($key in $allManagedKeys) {
            $managedLive = Join-Path $InstallationRoot $managed[$key]
            if (Test-VllmPathInsideOrEqual -Path $live -Parent $managedLive) {
                throw "Managed path contains a separately identity-tracked distribution file: $($managed[$key])"
            }
        }
    }

    return [pscustomobject][ordered]@{
        ReleaseManifestPath = $manifestPath
        ReleaseManifestSha256 = $manifestIdentity.Sha256
        PayloadRoot = $payloadRoot
        Release = $release
        DistributionMap = $distribution
        ManagedMap = $managed
        ManagedContractsMap = $contracts
        LifecycleMap = $lifecycle
        WheelPath = $wheel
        WheelIdentity = $wheelIdentity
        PythonManifest = $pythonManifest
        UvManifest = $uvManifest
        VenvManifest = $venvManifest
        DependencyManifest = $dependencyManifest
        RuntimeManifest = $runtimeManifest
    }
}

function Assert-VllmUpdateSourceManagedState {
    param([Parameter(Mandatory)]$Committed,[Parameter(Mandatory)]$ReleaseContext)
    $state = $Committed.State
    $root = $Committed.Root
    $contracts = $ReleaseContext.ManagedContractsMap

    $pythonKey = Get-VllmUpdateRelativeKey ([string]$ReleaseContext.PythonManifest.install.managed_relative_path)
    $uvKey = Get-VllmUpdateRelativeKey ([string]$ReleaseContext.UvManifest.install.managed_relative_path)
    $runtimeKey = Get-VllmUpdateRelativeKey ([string]$ReleaseContext.Release.orchestration.runtime_root)
    $pythonRoot = Join-Path $root $contracts[$pythonKey].RelativePath
    $uvRoot = Join-Path $root $contracts[$uvKey].RelativePath
    $runtimeRoot = Join-Path $root $contracts[$runtimeKey].RelativePath
    if (-not (Test-VllmUpdatePathEqual -A ([string]$state.python.root) -B $pythonRoot) -or
        -not (Test-VllmUpdatePathEqual -A ([string]$state.uv.root) -B $uvRoot) -or
        -not (Test-VllmUpdatePathEqual -A ([string]$state.runtime.root) -B $runtimeRoot)) {
        throw 'Install-state managed roots do not match release contracts.'
    }
    foreach ($item in @(
        @{Path=$pythonRoot;Label='Managed Python'},
        @{Path=$uvRoot;Label='Managed uv'},
        @{Path=$runtimeRoot;Label='Managed runtime'}
    )) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Container)) { throw "$($item.Label) root is missing: $($item.Path)" }
        Assert-VllmUpdateManagedTreeNoReparsePoints -Path $item.Path -Label $item.Label
    }
    $pythonExe = Join-Path $pythonRoot ([string]$ReleaseContext.PythonManifest.install.python_executable)
    $uvExe = Join-Path $uvRoot ([string]$ReleaseContext.UvManifest.install.uv_executable)
    if (-not (Test-VllmUpdatePathEqual -A ([string]$state.python.python) -B $pythonExe) -or -not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) { throw 'Install-state Python executable does not match the managed Python contract.' }
    if (-not (Test-VllmUpdatePathEqual -A ([string]$state.uv.uv) -B $uvExe) -or -not (Test-Path -LiteralPath $uvExe -PathType Leaf)) { throw 'Install-state uv executable does not match the managed uv contract.' }
    if ([string]$state.python.version -ne [string]$ReleaseContext.PythonManifest.version -or
        [string]$state.python.archive_sha256 -ne [string]$ReleaseContext.PythonManifest.archive.sha256) { throw 'Install-state Python provenance does not match the release contract.' }
    if ([string]$state.uv.version -ne [string]$ReleaseContext.UvManifest.version -or
        [string]$state.uv.archive_sha256 -ne [string]$ReleaseContext.UvManifest.archive.sha256) { throw 'Install-state uv provenance does not match the release contract.' }
    if ([string]$state.runtime.vllm_version -ne [string]$ReleaseContext.RuntimeManifest.project_wheel.version -or
        [string]$state.runtime.wheel_sha256 -ne [string]$ReleaseContext.RuntimeManifest.project_wheel.sha256 -or
        [string]$state.runtime.lock_sha256 -ne [string]$ReleaseContext.RuntimeManifest.lock.sha256 -or
        [int]$state.runtime.package_count -ne [int]$ReleaseContext.RuntimeManifest.materialization.final_package_count) {
        throw 'Install-state runtime provenance does not match the release contract.'
    }

    foreach ($contract in $contracts.Values) {
        $path = Join-Path $root $contract.RelativePath
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath $contract.RelativePath)
        $entry = Get-VllmPathEntryInfo -Path $path
        if ($contract.Role -eq 'cache') {
            if ($entry.Exists -and -not $entry.IsDirectory) { throw "Managed cache path is not a directory: $path" }
            if ($entry.Exists) { Assert-VllmUpdateManagedTreeNoReparsePoints -Path $path -Label 'Managed cache' }
        } elseif ($contract.Role -match 'receipt$') {
            if (-not $entry.Exists -or $entry.IsDirectory -or $entry.IsReparsePoint) { throw "Managed receipt path is missing or unsafe: $path" }
        }
    }
}

function Assert-VllmUpdateNoManagedProcesses {
    param([Parameter(Mandatory)]$SourceContext)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($contract in $SourceContext.ReleaseContext.ManagedContractsMap.Values) {
        if ($contract.Role -in @('python','uv','runtime')) {
            $path = Join-Path $SourceContext.Committed.Root $contract.RelativePath
            if (Test-Path -LiteralPath $path -PathType Container) { $roots.Add((Get-VllmNormalizedPath $path)) }
        }
    }
    $runtimeRoot = Get-VllmNormalizedPath ([string]$SourceContext.Committed.RuntimeRoot)
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    catch { throw "Cannot enumerate Windows processes safely before update planning: $($_.Exception.Message)" }
    $processMatches = New-Object System.Collections.Generic.List[object]
    foreach ($process in $processes) {
        $managed = $false
        $executable = [string]$process.ExecutablePath
        if (-not [string]::IsNullOrWhiteSpace($executable)) {
            try {
                $normalized = Get-VllmNormalizedPath $executable
                foreach ($managedRoot in $roots) {
                    if (Test-VllmPathInsideOrEqual -Path $normalized -Parent $managedRoot) { $managed=$true; break }
                }
            } catch { $managed=$false }
        }
        if (-not $managed -and -not [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
            $managed = ([string]$process.CommandLine).Replace('/','\').IndexOf($runtimeRoot,[StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        if ($managed) { $processMatches.Add([pscustomobject]@{ ProcessId=[uint32]$process.ProcessId; Name=[string]$process.Name }) }
    }
    if ($processMatches.Count -gt 0) {
        $summary = (($processMatches.ToArray() | ForEach-Object { "PID=$($_.ProcessId) name=$($_.Name)" }) -join '; ')
        throw "Managed runtime process is still running outside lifecycle serialization; stop it before update: $summary"
    }
}

function Get-VllmUpdateSourceContext {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $committed = Get-VllmCommittedInstallationContext -InstallationRoot $InstallationRoot
    $modelsRoot = Assert-VllmSafeModelsRoot -InstallationRoot $committed.Root -ModelsRoot ([string]$committed.State.models_root)
    $releaseContext = Get-VllmUpdateReleaseContext -ReleaseManifestPath ([string]$committed.State.release_manifest) -InstallationRoot $committed.Root -ModelsRoot $modelsRoot
    if ($releaseContext.ReleaseManifestSha256 -ne ([string]$committed.State.release_manifest_sha256).ToUpperInvariant()) { throw 'Source release manifest digest changed during update validation.' }
    if (-not (Test-VllmUpdateRecordedReleaseIdentityEqual -A $committed.Release -B $releaseContext.Release)) { throw 'Source release identity changed during update validation.' }
    Assert-VllmUpdateSourceManagedState -Committed $committed -ReleaseContext $releaseContext
    $source = [pscustomobject][ordered]@{ Committed=$committed; ReleaseContext=$releaseContext; ModelsRoot=$modelsRoot }
    Assert-VllmUpdateNoManagedProcesses -SourceContext $source
    return $source
}

function Get-VllmUpdateTransitionPlan {
    param(
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext
    )
    $sourceRelease = $SourceContext.ReleaseContext.Release
    $targetRelease = $TargetContext.Release
    if ([string]$sourceRelease.platform -ne [string]$targetRelease.platform) { throw 'Cross-platform update transitions are not supported.' }

    $sameIdentity = Test-VllmUpdateRecordedReleaseIdentityEqual -A $sourceRelease -B $targetRelease
    $sameManifest = $SourceContext.ReleaseContext.ReleaseManifestSha256 -eq $TargetContext.ReleaseManifestSha256
    if ([string]$sourceRelease.release -eq [string]$targetRelease.release -and (-not $sameIdentity -or -not $sameManifest)) {
        throw "Target reuses source release identifier '$($sourceRelease.release)' with different recorded identity or manifest content."
    }
    if ($sameIdentity -ne $sameManifest) { throw 'Release manifest digest and recorded release identity disagree about transition identity.' }

    $sourceConfigExample = Get-VllmUpdateDistributionEntry -Map $SourceContext.ReleaseContext.DistributionMap -RelativePath 'config.example.psd1' -Label 'Source config contract'
    $targetConfigExample = Get-VllmUpdateDistributionEntry -Map $TargetContext.DistributionMap -RelativePath 'config.example.psd1' -Label 'Target config contract'
    if ($sourceConfigExample.Size -ne $targetConfigExample.Size -or $sourceConfigExample.Sha256 -ne $targetConfigExample.Sha256) {
        throw 'Target changes the v1 config contract; explicit versioned config migration is required before this transition is supported.'
    }

    $distributionPlan = New-Object System.Collections.Generic.List[object]
    $sourceDistribution = $SourceContext.ReleaseContext.DistributionMap
    $targetDistribution = $TargetContext.DistributionMap
    $keys = @($sourceDistribution.Keys + $targetDistribution.Keys | Sort-Object -Unique)
    foreach ($key in $keys) {
        $source = if ($sourceDistribution.ContainsKey($key)) { $sourceDistribution[$key] } else { $null }
        $target = if ($targetDistribution.ContainsKey($key)) { $targetDistribution[$key] } else { $null }
        if ($null -ne $source -and $null -ne $target) {
            $class = if ($source.Size -eq $target.Size -and $source.Sha256 -eq $target.Sha256) { 'reuse' } else { 'replace' }
            $relative = $target.RelativePath
        } elseif ($null -ne $target) {
            $class='add'; $relative=$target.RelativePath
            $live = Join-Path $SourceContext.Committed.Root $relative
            if ((Get-VllmPathEntryInfo -Path $live).Exists) { throw "Target distribution add collides with an unowned live path: $relative" }
        } else {
            $class='retire'; $relative=$source.RelativePath
        }
        $distributionPlan.Add([pscustomobject][ordered]@{
            Class=$class; RelativePath=$relative
            Source=$(if($null -eq $source){$null}else{[pscustomobject]@{Size=$source.Size;Sha256=$source.Sha256}})
            Target=$(if($null -eq $target){$null}else{[pscustomobject]@{Size=$target.Size;Sha256=$target.Sha256}})
        })
    }

    $managedPlan = New-Object System.Collections.Generic.List[object]
    $sourceManaged = $SourceContext.ReleaseContext.ManagedContractsMap
    $targetManaged = $TargetContext.ManagedContractsMap
    $managedKeys = @($sourceManaged.Keys + $targetManaged.Keys | Sort-Object -Unique)
    foreach ($key in $managedKeys) {
        $source = if ($sourceManaged.ContainsKey($key)) { $sourceManaged[$key] } else { $null }
        $target = if ($targetManaged.ContainsKey($key)) { $targetManaged[$key] } else { $null }
        if ($null -ne $source -and $null -ne $target) {
            if ($source.Role -ne $target.Role) { throw "Managed path changes semantic role across transition: $($target.RelativePath)" }
            $class = if ([string]$source.Contract -eq [string]$target.Contract) { 'reuse' } else { 'replace' }
            $relative=$target.RelativePath; $role=$target.Role
        } elseif ($null -ne $target) {
            $class='add'; $relative=$target.RelativePath; $role=$target.Role
            $live = Join-Path $SourceContext.Committed.Root $relative
            if ((Get-VllmPathEntryInfo -Path $live).Exists) { throw "Target managed add collides with an unowned live path: $relative" }
        } else {
            $class='retire'; $relative=$source.RelativePath; $role=$source.Role
        }
        $managedPlan.Add([pscustomobject][ordered]@{
            Class=$class; RelativePath=$relative; Role=$role
            SourceContract=$(if($null -eq $source){$null}else{[string]$source.Contract})
            TargetContract=$(if($null -eq $target){$null}else{[string]$target.Contract})
        })
    }

    $changes = @($distributionPlan.ToArray() + $managedPlan.ToArray() | Where-Object { $_.Class -ne 'reuse' }).Count
    $idempotent = $sameIdentity -and $sameManifest -and $changes -eq 0
    if (($sameIdentity -and $sameManifest) -and -not $idempotent) { throw 'Exact same-release target unexpectedly produced a mutating transition plan.' }

    $counts = [ordered]@{}
    foreach ($class in @('reuse','replace','add','retire')) {
        $counts["distribution_$class"] = @($distributionPlan | Where-Object { $_.Class -eq $class }).Count
        $counts["managed_$class"] = @($managedPlan | Where-Object { $_.Class -eq $class }).Count
    }

    return [pscustomobject][ordered]@{
        schema_version=1
        component='update-plan'
        ready=$true
        planning_only=$true
        idempotent=$idempotent
        source=[pscustomobject][ordered]@{
            release=[string]$sourceRelease.release
            manifest_sha256=[string]$SourceContext.ReleaseContext.ReleaseManifestSha256
            generation_id=[string]$SourceContext.Committed.GenerationId
        }
        target=[pscustomobject][ordered]@{
            release=[string]$targetRelease.release
            manifest_sha256=[string]$TargetContext.ReleaseManifestSha256
            wheel_sha256=[string]$targetRelease.wheel.sha256
        }
        models_root=[string]$SourceContext.ModelsRoot
        counts=[pscustomobject]$counts
        distribution=$distributionPlan.ToArray()
        managed=$managedPlan.ToArray()
    }
}
