Set-StrictMode -Version Latest

function Read-VllmLifecycleJsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Test-VllmLifecyclePathEqual {
    param([Parameter(Mandatory)][string]$A,[Parameter(Mandatory)][string]$B)
    return (Get-VllmNormalizedPath $A).Equals((Get-VllmNormalizedPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-VllmLifecycleExactProperties {
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

function Test-VllmLifecycleTimestamp {
    param($Value)
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $true }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        [string]$Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
}

function Get-VllmLifecycleRelativeKey {
    param([Parameter(Mandatory)][string]$Path)
    return (Assert-VllmSafeRelativePath -RelativePath $Path -Label 'Lifecycle-owned relative path').Replace('\','/').ToLowerInvariant()
}

function Assert-VllmUpdateMaintenanceAbsent {
    param([Parameter(Mandatory)][string]$InstallationRoot)

    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $reserved = @(
        @{ Path=(Join-Path $root 'state\update-transaction.json'); Relative='state\update-transaction.json' },
        @{ Path=(Join-Path $root 'work\update-transaction'); Relative='work\update-transaction' }
    )
    foreach ($item in $reserved) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $item.Path -RelativePath $item.Relative)
        if ((Get-VllmPathEntryInfo -Path $item.Path).Exists) {
            throw "Pending update maintenance state exists at '$($item.Path)'. Refusing this lifecycle operation; run update.ps1 to recover or clean the update transaction."
        }
    }
}

function Find-VllmInstallationRootCandidate {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = Get-VllmNormalizedPath $Path
    $entry = Get-VllmPathEntryInfo -Path $normalized
    if ($entry.Exists -and -not $entry.IsDirectory) {
        $parent = [IO.Directory]::GetParent($normalized)
        if ($null -eq $parent) { return $null }
        $cursor = $parent.FullName
    } elseif (-not $entry.Exists -and [IO.Path]::HasExtension($normalized)) {
        $parent = [IO.Directory]::GetParent($normalized)
        if ($null -eq $parent) { return $null }
        $cursor = $parent.FullName
    } else {
        $cursor = $normalized
    }

    while ($true) {
        $statePath = Join-Path $cursor 'state\install-state.json'
        if ((Get-VllmPathEntryInfo -Path $statePath).Exists) {
            $root = Assert-VllmSafeInstallationRoot -InstallationRoot $cursor
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $statePath -RelativePath 'state\install-state.json')
            return $root
        }

        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent -or $parent.FullName.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $cursor = $parent.FullName
    }
}

function Resolve-VllmStartManagedRoot {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ContainmentRoot,
        [Parameter(Mandatory)][string]$VllmExe
    )

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($ProjectRoot, $ContainmentRoot, $VllmExe)) {
        $root = Find-VllmInstallationRootCandidate -Path $candidate
        if ($null -eq $root) { continue }
        if (-not (@($roots | Where-Object { $_.Equals($root, [StringComparison]::OrdinalIgnoreCase) }).Count)) {
            $roots.Add($root)
        }
    }

    if ($roots.Count -eq 0) { return $null }
    if ($roots.Count -ne 1) {
        throw "Start targets multiple committed installation roots; refusing ambiguous lifecycle ownership: $($roots -join ', ')"
    }
    return $roots[0]
}

function Get-VllmCommittedInstallationContext {
    param([Parameter(Mandatory)][string]$InstallationRoot)

    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $statePath = Join-Path $root 'state\install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Install state is missing or is not a file: $statePath"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $statePath -RelativePath 'state\install-state.json')
    $state = Read-VllmLifecycleJsonFile -Path $statePath
    if ($null -eq $state) { throw "Install state is malformed: $statePath" }

    $stateProps = @(
        'schema_version','component','release','platform','ready','generation_id','install_root','models_root',
        'release_manifest','release_manifest_sha256','upstream','windows_patchset','wheel','python','uv','runtime',
        'distribution_files','managed_paths','installed_at','updated_at'
    )
    Assert-VllmLifecycleExactProperties -Value $state -Expected $stateProps -Label 'Install-state'
    Assert-VllmLifecycleExactProperties -Value $state.upstream -Expected @('repository','tag','commit') -Label 'Install-state upstream identity'
    Assert-VllmLifecycleExactProperties -Value $state.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Install-state Windows patchset identity'
    Assert-VllmLifecycleExactProperties -Value $state.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Install-state wheel identity'
    Assert-VllmLifecycleExactProperties -Value $state.python -Expected @('version','root','python','archive_sha256','receipt','receipt_sha256') -Label 'Install-state Python identity'
    Assert-VllmLifecycleExactProperties -Value $state.uv -Expected @('version','root','uv','archive_sha256','receipt','receipt_sha256') -Label 'Install-state uv identity'
    Assert-VllmLifecycleExactProperties -Value $state.runtime -Expected @(
        'root','python','package_count','vllm_version','dependency_receipt','dependency_receipt_sha256',
        'final_receipt','final_receipt_sha256','lock_sha256','wheel_sha256'
    ) -Label 'Install-state runtime identity'

    if ([int]$state.schema_version -ne 1 -or [string]$state.component -ne 'install-state' -or -not [bool]$state.ready) {
        throw 'Install state does not describe a ready schema-v1 installation.'
    }
    if (-not (Test-VllmLifecyclePathEqual -A ([string]$state.install_root) -B $root)) {
        throw 'Install-state root does not match the discovered installation root.'
    }
    $generation = [guid]::Empty
    if (-not [guid]::TryParse([string]$state.generation_id, [ref]$generation)) {
        throw 'Install-state generation_id is invalid.'
    }
    if (-not (Test-VllmLifecycleTimestamp $state.installed_at) -or -not (Test-VllmLifecycleTimestamp $state.updated_at)) {
        throw 'Install-state timestamps are invalid.'
    }
    [void](Assert-VllmSafeModelsRoot -InstallationRoot $root -ModelsRoot ([string]$state.models_root))

    $releasePath = Get-VllmNormalizedPath ([string]$state.release_manifest)
    if (-not (Test-VllmPathInsideOrEqual -Path $releasePath -Parent $root)) {
        throw 'Installed release manifest is outside the installation root.'
    }
    if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
        throw "Installed release manifest is missing: $releasePath"
    }
    $releaseHash = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
    if ($releaseHash -ne [string]$state.release_manifest_sha256) {
        throw 'Installed release manifest digest does not match install state.'
    }
    $release = Read-VllmLifecycleJsonFile -Path $releasePath
    if ($null -eq $release) { throw 'Installed release manifest is malformed.' }

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
        throw 'Installed release manifest has unsupported schema/component/platform.'
    }
    if ([string]$state.release -ne [string]$release.release -or [string]$state.platform -ne [string]$release.platform) {
        throw 'Install state and release manifest disagree on release/platform.'
    }
    foreach ($name in @('repository','tag','commit')) {
        if ([string]$state.upstream.$name -ne [string]$release.upstream.$name) {
            throw 'Install state and release manifest disagree on upstream identity.'
        }
    }
    foreach ($name in @('implementation_commit','tree','patch_sha256')) {
        if ([string]$state.windows_patchset.$name -ne [string]$release.windows_patchset.$name) {
            throw 'Install state and release manifest disagree on Windows patchset identity.'
        }
    }
    foreach ($name in @('filename','version','size_bytes','sha256')) {
        if ([string]$state.wheel.$name -ne [string]$release.wheel.$name) {
            throw 'Install state and release manifest disagree on wheel identity.'
        }
    }

    $releaseRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.self_path) -Label 'Release manifest self_path'
    $expectedReleasePath = Join-Path $root $releaseRelative
    if (-not (Test-VllmLifecyclePathEqual -A $releasePath -B $expectedReleasePath)) {
        throw 'Installed release manifest path does not match release self_path.'
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $releasePath -RelativePath $releaseRelative)

    $runtimeRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.runtime_root) -Label 'Release runtime root'
    $runtimeRoot = Join-Path $root $runtimeRelative
    if (-not (Test-VllmLifecyclePathEqual -A ([string]$state.runtime.root) -B $runtimeRoot)) {
        throw 'Install-state runtime root does not match release orchestration.'
    }
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
        throw "Managed runtime root is missing: $runtimeRoot"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $runtimeRoot -RelativePath $runtimeRelative)

    $vllmRelative = ($runtimeRelative.TrimEnd('\') + '\Scripts\vllm.exe')
    $vllmExe = Join-Path $root $vllmRelative
    if (-not (Test-Path -LiteralPath $vllmExe -PathType Leaf)) {
        throw "Committed managed vLLM launcher is missing: $vllmExe"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $vllmExe -RelativePath $vllmRelative)

    $expectedManaged = @{}
    foreach ($value in @($release.managed_paths)) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$value) -Label 'Release managed path'
        $key = Get-VllmLifecycleRelativeKey $relative
        if ($expectedManaged.ContainsKey($key)) { throw "Release manifest contains duplicate managed path: $relative" }
        $expectedManaged[$key] = $relative
    }
    $actualManaged = @{}
    foreach ($value in @($state.managed_paths)) {
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$value) -Label 'Install-state managed path'
        $key = Get-VllmLifecycleRelativeKey $relative
        if ($actualManaged.ContainsKey($key)) { throw "Install state contains duplicate managed path: $relative" }
        $actualManaged[$key] = $relative
    }
    if ($expectedManaged.Count -ne $actualManaged.Count) {
        throw 'Install state and release manifest disagree on managed path count.'
    }
    foreach ($key in $expectedManaged.Keys) {
        if (-not $actualManaged.ContainsKey($key)) {
            throw "Install state is missing release-owned managed path: $($expectedManaged[$key])"
        }
    }
    foreach ($required in @('state\install-state.json','state\install-orchestrator.lock','.vllm-operation.lock')) {
        if (-not $expectedManaged.ContainsKey((Get-VllmLifecycleRelativeKey $required))) {
            throw "Release manifest is missing required lifecycle-owned path: $required"
        }
    }

    $expectedDistribution = @{}
    foreach ($entry in @($release.files)) {
        Assert-VllmLifecycleExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Release distribution entry'
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release distribution path'
        $key = Get-VllmLifecycleRelativeKey $relative
        if ($expectedDistribution.ContainsKey($key)) { throw "Release manifest contains duplicate distribution path: $relative" }
        if ([int64]$entry.size_bytes -lt 0 -or [string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "Release distribution identity is invalid: $relative"
        }
        $expectedDistribution[$key] = [pscustomobject]@{
            RelativePath=$relative
            Size=[int64]$entry.size_bytes
            Sha256=([string]$entry.sha256).ToUpperInvariant()
        }
    }
    $releaseKey = Get-VllmLifecycleRelativeKey $releaseRelative
    if ($expectedDistribution.ContainsKey($releaseKey)) {
        throw 'Release manifest self_path is duplicated in release files.'
    }
    $releaseItem = Get-Item -LiteralPath $releasePath
    $expectedDistribution[$releaseKey] = [pscustomobject]@{
        RelativePath=$releaseRelative
        Size=[int64]$releaseItem.Length
        Sha256=$releaseHash.ToUpperInvariant()
    }

    $actualDistribution = @{}
    foreach ($entry in @($state.distribution_files)) {
        Assert-VllmLifecycleExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Install-state distribution entry'
        $relative = Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Install-state distribution path'
        $key = Get-VllmLifecycleRelativeKey $relative
        if ($actualDistribution.ContainsKey($key)) { throw "Install state contains duplicate distribution path: $relative" }
        $actualDistribution[$key] = [pscustomobject]@{
            RelativePath=$relative
            Size=[int64]$entry.size_bytes
            Sha256=([string]$entry.sha256).ToUpperInvariant()
        }
    }
    if ($expectedDistribution.Count -ne $actualDistribution.Count) {
        throw 'Install state and release manifest disagree on distribution file count.'
    }
    foreach ($key in $expectedDistribution.Keys) {
        if (-not $actualDistribution.ContainsKey($key)) {
            throw "Install state is missing release-owned distribution path: $($expectedDistribution[$key].RelativePath)"
        }
        $expected = $expectedDistribution[$key]
        $actual = $actualDistribution[$key]
        if ($expected.Size -ne $actual.Size -or $expected.Sha256 -ne $actual.Sha256) {
            throw "Install state and release manifest disagree on distribution identity: $($expected.RelativePath)"
        }
        $path = Join-Path $root $expected.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Owned distribution file is missing: $path"
        }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath $expected.RelativePath)
        $item = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ([int64]$item.Length -ne $expected.Size -or $hash -ne $expected.Sha256) {
            throw "Owned distribution file has drifted: $($expected.RelativePath)"
        }
    }

    $receiptChecks = @(
        @{ Relative=[string]$release.orchestration.python_receipt; StatePath=[string]$state.python.receipt; Hash=[string]$state.python.receipt_sha256; Label='Python' },
        @{ Relative=[string]$release.orchestration.uv_receipt; StatePath=[string]$state.uv.receipt; Hash=[string]$state.uv.receipt_sha256; Label='uv' },
        @{ Relative=[string]$release.orchestration.dependency_receipt; StatePath=[string]$state.runtime.dependency_receipt; Hash=[string]$state.runtime.dependency_receipt_sha256; Label='dependency' },
        @{ Relative=[string]$release.orchestration.runtime_receipt; StatePath=[string]$state.runtime.final_receipt; Hash=[string]$state.runtime.final_receipt_sha256; Label='runtime' }
    )
    foreach ($check in $receiptChecks) {
        $relative = Assert-VllmSafeRelativePath -RelativePath $check.Relative -Label "$($check.Label) receipt path"
        $path = Join-Path $root $relative
        if (-not (Test-VllmLifecyclePathEqual -A $check.StatePath -B $path)) {
            throw "Install-state $($check.Label) receipt path does not match release orchestration."
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Managed $($check.Label) receipt is missing: $path"
        }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath $relative)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -ne $check.Hash) {
            throw "Managed $($check.Label) receipt digest does not match install state."
        }
    }
    $venvReceiptRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$release.orchestration.venv_receipt) -Label 'venv receipt path'
    $venvReceiptPath = Join-Path $root $venvReceiptRelative
    if (-not (Test-Path -LiteralPath $venvReceiptPath -PathType Leaf)) {
        throw "Managed venv receipt is missing: $venvReceiptPath"
    }
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $venvReceiptPath -RelativePath $venvReceiptRelative)

    return [pscustomobject]@{
        Root=$root
        State=$state
        GenerationId=[string]$state.generation_id
        Release=$release
        RuntimeRoot=$runtimeRoot
        VllmExe=$vllmExe
    }
}

function Assert-VllmStartMatchesCommittedContext {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VllmExe
    )
    $actual = Get-VllmNormalizedPath $VllmExe
    $expected = Get-VllmNormalizedPath ([string]$Context.VllmExe)
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Requested vLLM executable is not the committed managed launcher. Expected '$expected', got '$actual'."
    }
    $actualPhysical = Get-VllmCanonicalExistingPath -Path $actual -Format Guid
    $expectedPhysical = Get-VllmCanonicalExistingPath -Path $expected -Format Guid
    if (-not $actualPhysical.Equals($expectedPhysical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Requested vLLM executable does not resolve to the committed managed launcher.'
    }
}
