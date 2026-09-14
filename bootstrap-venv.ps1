[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/bootstrap/venv-v0.27.1-windows-x86_64.json',
    [string] $InstallationRoot = '',
    [switch] $Force,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
    throw 'bootstrap-venv.ps1 supports native Windows x64 only.'
}

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) {
    throw "Runtime venv manifest not found: $manifestResolved"
}
$manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json
if ([string]$manifest.component -ne 'runtime-venv' -or [string]$manifest.platform -ne 'windows-x86_64') {
    throw "Unsupported venv manifest: component=$($manifest.component), platform=$($manifest.platform)"
}

if ([string]::IsNullOrWhiteSpace($InstallationRoot)) {
    $InstallationRoot = 'D:\AI\vLLM'
    $defaultVolume = [IO.Path]::GetPathRoot($InstallationRoot)
    if (-not (Test-Path -LiteralPath $defaultVolume -PathType Container)) {
        throw "Default installation root '$InstallationRoot' is unavailable because volume '$defaultVolume' does not exist. Pass -InstallationRoot with an existing local path."
    }
}
$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot

$managedRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.install.managed_relative_path) -Label 'Managed venv path'
$requiredFiles = @($manifest.install.required_files | ForEach-Object { Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Required venv file path' })
$expectedCreationFileCount = [int]$manifest.install.expected_creation_file_count
$expectedPythonVersion = [string]$manifest.acceptance.expected_python_version
$expectedPointerBits = [int]$manifest.acceptance.expected_pointer_bits
$expectedUvVersion = [string]$manifest.uv.version
$expectedUvCommit = [string]$manifest.uv.commit

$pythonManifestPath = Resolve-ProjectPath -Path ([string]$manifest.python.bootstrap_manifest) -BasePath $projectRoot
$uvManifestPath = Resolve-ProjectPath -Path ([string]$manifest.uv.bootstrap_manifest) -BasePath $projectRoot
foreach ($dependencyManifest in @($pythonManifestPath,$uvManifestPath)) {
    if (-not (Test-Path -LiteralPath $dependencyManifest -PathType Leaf)) { throw "Bootstrap dependency manifest not found: $dependencyManifest" }
}
$pythonManifest = Get-Content -LiteralPath $pythonManifestPath -Raw | ConvertFrom-Json
$uvManifest = Get-Content -LiteralPath $uvManifestPath -Raw | ConvertFrom-Json
if ([string]$pythonManifest.version -ne $expectedPythonVersion) { throw 'Runtime venv Python pin disagrees with the portable Python bootstrap manifest.' }
if ([string]$uvManifest.version -ne $expectedUvVersion) { throw 'Runtime venv uv pin disagrees with the portable uv bootstrap manifest.' }
if ([string]$uvManifest.release.commit -ne $expectedUvCommit) { throw 'Runtime venv uv commit pin disagrees with the portable uv bootstrap manifest.' }
$expectedUvCommitPrefix = [string]$uvManifest.acceptance.expected_commit_prefix

$pythonManagedRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.managed_relative_path) -Label 'Managed Python path'
$pythonExeRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.python_executable) -Label 'Python executable path'
$uvManagedRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.managed_relative_path) -Label 'Managed uv path'
$uvExeRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.uv_executable) -Label 'uv executable path'
function Get-ProcessEnvironmentSnapshot {
    $snapshot = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $snapshot[[string]$entry.Key] = [string]$entry.Value
    }
    return $snapshot
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory)][hashtable]$Snapshot)
    $current = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($current.Keys)) {
        $name = [string]$key
        if (-not $Snapshot.ContainsKey($name)) { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue }
    }
    foreach ($name in $Snapshot.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name,[string]$Snapshot[$name],'Process')
    }
}

function Test-ManagedPython {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Exe)
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $false }
    try {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $pythonManagedRelative)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Exe -RelativePath ($pythonManagedRelative + '\' + $pythonExeRelative))
    } catch { return $false }
    $probe = (& $Exe -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}')" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($probe -eq ($expectedPythonVersion + '|' + $expectedPointerBits))
}

function Test-ManagedUv {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Exe)
    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $false }
    try {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $uvManagedRelative)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Exe -RelativePath ($uvManagedRelative + '\' + $uvExeRelative))
    } catch { return $false }
    $probe = (& $Exe --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($probe.StartsWith("uv $expectedUvVersion ($expectedUvCommitPrefix",[StringComparison]::Ordinal))
}
function Test-VenvRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $managedRelative) } catch { return $false }
    foreach ($relative in $requiredFiles) {
        $candidate = Join-Path $Root $relative
        try { [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $candidate -RelativePath ($managedRelative + '\' + $relative)) } catch { return $false }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $false }
    }
    if (@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force).Count -ne $expectedCreationFileCount) { return $false }
    $sitePackages = Join-Path $Root 'Lib\site-packages'
    if ([bool]$manifest.acceptance.pip_must_be_absent) {
        if (Test-Path -LiteralPath (Join-Path $sitePackages 'pip') -PathType Container) { return $false }
        if (@(Get-ChildItem -LiteralPath $sitePackages -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^pip(?:-|\.)' }).Count -gt 0) { return $false }
    }
    $python = Join-Path $Root 'Scripts\python.exe'
    $probe = (& $python -I -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}|{sys.prefix}|{sys.base_prefix}')" 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    $parts = $probe.Split('|')
    if ($parts.Count -ne 4 -or $parts[0] -ne $expectedPythonVersion -or [int]$parts[1] -ne $expectedPointerBits) { return $false }
    if ((Get-VllmNormalizedPath $parts[2]) -ne (Get-VllmNormalizedPath $Root)) { return $false }
    if ((Get-VllmNormalizedPath $parts[3]) -ne (Get-VllmNormalizedPath $PythonRoot)) { return $false }
    $cfgLines = @(Get-Content -LiteralPath (Join-Path $Root 'pyvenv.cfg'))
    if ($cfgLines -notcontains ('uv = ' + $expectedUvVersion)) { return $false }
    if ($cfgLines -notcontains ('version_info = ' + $expectedPythonVersion)) { return $false }
    if ($cfgLines -notcontains 'include-system-site-packages = false') { return $false }
    $homeLine = @($cfgLines | Where-Object { $_ -like 'home = *' })
    if ($homeLine.Count -ne 1) { return $false }
    $homePath = $homeLine[0].Substring(7)
    if ((Get-VllmNormalizedPath $homePath) -ne (Get-VllmNormalizedPath $PythonRoot)) { return $false }
    $activation = Get-Content -LiteralPath (Join-Path $Root 'Scripts\activate.bat') -Raw
    if ($activation.IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    return $true
}
$lock = $null
$backupRoot = $null
$environmentSnapshot = $null
$result = $null
try {
    $lock = Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-venv'
    $InstallationRoot = $lock.Root
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)

    $pythonRoot = Join-Path $InstallationRoot $pythonManagedRelative
    $pythonExe = Join-Path $pythonRoot $pythonExeRelative
    $uvRoot = Join-Path $InstallationRoot $uvManagedRelative
    $uvExe = Join-Path $uvRoot $uvExeRelative
    if (-not (Test-ManagedPython -Root $pythonRoot -Exe $pythonExe)) {
        throw "Pinned managed Python is missing or invalid. Run .\bootstrap-python.ps1 -InstallationRoot '$InstallationRoot' first."
    }
    if (-not (Test-ManagedUv -Root $uvRoot -Exe $uvExe)) {
        throw "Pinned managed uv is missing or invalid. Run .\bootstrap-uv.ps1 -InstallationRoot '$InstallationRoot' first."
    }

    $runtimeParent = Join-Path $InstallationRoot 'runtime'
    $cacheDir = Join-Path $InstallationRoot 'cache\uv'
    $forensicDir = Join-Path $InstallationRoot 'forensic'
    $targetRoot = Join-Path $InstallationRoot $managedRelative
    foreach ($pathInfo in @(
        @{Path=$runtimeParent; Relative='runtime'},
        @{Path=$cacheDir; Relative='cache\uv'},
        @{Path=$forensicDir; Relative='forensic'},
        @{Path=$targetRoot; Relative=$managedRelative}
    )) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pathInfo.Path -RelativePath $pathInfo.Relative)
    }
    foreach ($directory in @($runtimeParent,$cacheDir,$forensicDir)) { [void][IO.Directory]::CreateDirectory($directory) }
    foreach ($pathInfo in @(
        @{Path=$runtimeParent; Relative='runtime'},
        @{Path=$cacheDir; Relative='cache\uv'},
        @{Path=$forensicDir; Relative='forensic'}
    )) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pathInfo.Path -RelativePath $pathInfo.Relative)
    }

    $receiptName = 'venv-bootstrap-v0.27.1.json'
    $receiptPath = Join-Path $forensicDir $receiptName
    $receiptRelative = 'forensic\' + $receiptName
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
    if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw "Reserved venv receipt path exists but is not a file: $receiptPath"
    }

    if (Test-Path -LiteralPath $targetRoot) {
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw "Managed venv target exists but is not a directory: $targetRoot" }
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not $Force) { throw "Managed venv target already exists: $targetRoot. Re-run with -Force only when replacement is intended." }
        $backupName = '.venv-backup-' + [guid]::NewGuid().ToString('N')
        $backupRoot = Join-Path $runtimeParent $backupName
        $backupRelative = 'runtime\' + $backupName
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot
    }
    try {
        try {
            $environmentSnapshot = Get-ProcessEnvironmentSnapshot
            foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
                $name = [string]$key
                if ($name.StartsWith('UV_',[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue }
            }
            foreach ($name in @('PYTHONHOME','PYTHONPATH','VIRTUAL_ENV','VIRTUAL_ENV_PROMPT','CONDA_PREFIX')) {
                Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue
            }
            [Environment]::SetEnvironmentVariable('UV_CACHE_DIR',$cacheDir,'Process')
            [Environment]::SetEnvironmentVariable('UV_NO_MANAGED_PYTHON','1','Process')
            [Environment]::SetEnvironmentVariable('UV_PYTHON_DOWNLOADS','never','Process')
            [Environment]::SetEnvironmentVariable('UV_NO_CONFIG','1','Process')
            [Environment]::SetEnvironmentVariable('UV_NO_PROJECT','1','Process')
            [Environment]::SetEnvironmentVariable('UV_OFFLINE','1','Process')
            [Environment]::SetEnvironmentVariable('PYTHONNOUSERSITE','1','Process')
            & $uvExe venv $targetRoot --python $pythonExe --no-managed-python --no-python-downloads --offline --no-project --no-config
            if ($LASTEXITCODE -ne 0) { throw "uv venv failed with exit code $LASTEXITCODE." }
        }
        finally {
            if ($null -ne $environmentSnapshot) {
                Restore-ProcessEnvironment -Snapshot $environmentSnapshot
                $environmentSnapshot = $null
            }
        }

        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
        if (-not (Test-VenvRoot -Root $targetRoot -PythonRoot $pythonRoot)) { throw 'Activated runtime venv failed final validation.' }
    }
    catch {
        $activationError = $_
        if (Test-Path -LiteralPath $targetRoot) {
            try {
                [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
                Remove-Item -LiteralPath $targetRoot -Recurse -Force
            }
            catch {
                if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
                    throw "Venv activation failed and rollback cannot safely remove the failed target. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "Venv activation failed and cleanup cannot safely remove the failed target. Original: $($activationError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "Venv activation failed and rollback could not restore the prior environment. Backup preserved at '$backupRoot'. Original: $($activationError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $activationError
    }
    try {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
        if ((Test-Path -LiteralPath $receiptPath) -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw "Reserved venv receipt path changed into a non-file before commit: $receiptPath"
        }
        $venvPython = Join-Path $targetRoot 'Scripts\python.exe'
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $venvPython -RelativePath ($managedRelative + '\Scripts\python.exe'))
        $result = [ordered]@{
            schema_version = 1
            component = 'runtime-venv'
            milestone = [string]$manifest.milestone
            platform = [string]$manifest.platform
            ready = $true
            root = $targetRoot
            python = $venvPython
            base_python = $pythonExe
            uv = $uvExe
            python_version = $expectedPythonVersion
            uv_version = $expectedUvVersion
            uv_commit = $expectedUvCommit
            seeded = $false
            file_count = @(Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Force).Count
            python_bootstrap_manifest = $pythonManifestPath
            uv_bootstrap_manifest = $uvManifestPath
            manifest = $manifestResolved
            created_at = (Get-Date).ToString('o')
        }
        $receiptTemp = $receiptPath + '.partial.' + [guid]::NewGuid().ToString('N')
        try {
            [IO.File]::WriteAllText($receiptTemp,($result | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $receiptTemp -Destination $receiptPath -Force
        }
        finally {
            Remove-Item -LiteralPath $receiptTemp -Force -ErrorAction SilentlyContinue
        }
        $result.receipt = $receiptPath
    }
    catch {
        $receiptError = $_
        if (Test-Path -LiteralPath $targetRoot) {
            try {
                [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $managedRelative)
                Remove-Item -LiteralPath $targetRoot -Recurse -Force
            }
            catch {
                if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
                    throw "Venv receipt commit failed and rollback cannot safely remove the new environment. Prior environment backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw "Venv receipt commit failed and cleanup cannot safely remove the new environment. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
        }
        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Move-Item -LiteralPath $backupRoot -Destination $targetRoot
                $backupRoot = $null
            }
            catch {
                throw "Venv receipt commit failed and rollback could not restore the prior environment. Backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $receiptError
    }

    if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
        $backupRelative = 'runtime\' + [IO.Path]::GetFileName($backupRoot)
        try {
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
            $backupRoot = $null
        }
        catch {
            Write-Warning "Runtime venv committed successfully, but the prior environment backup could not be removed and was preserved at '$backupRoot': $($_.Exception.Message)"
        }
    }
}
finally {
    if ($null -ne $environmentSnapshot) {
        try { Restore-ProcessEnvironment -Snapshot $environmentSnapshot } catch { Write-Warning "Failed to restore caller environment exactly: $($_.Exception.Message)" }
    }
    if ($null -ne $lock) { Exit-VllmOperationLock -Lock $lock }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8
}
else {
    Write-Host "Runtime venv: $($result.root)"
    Write-Host "Python:       $($result.python)"
    Write-Host "Base Python:  $($result.base_python)"
    Write-Host "uv:           $($result.uv)"
    Write-Host 'BOOTSTRAP_VENV_READY'
}
