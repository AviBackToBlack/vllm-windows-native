[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/runtime/dependencies-v0.27.1-windows-x86_64.json',
    [string] $InstallationRoot = '',
    [switch] $Force,
    [switch] $Offline,
    [switch] $Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) { throw 'bootstrap-dependencies.ps1 supports native Windows x64 only.' }
$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if (-not (Test-Path -LiteralPath $manifestResolved -PathType Leaf)) { throw "Runtime dependency manifest not found: $manifestResolved" }
$manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json
if ([string]$manifest.component -ne 'runtime-dependencies' -or [string]$manifest.platform -ne 'windows-x86_64') { throw "Unsupported dependency manifest: component=$($manifest.component), platform=$($manifest.platform)" }
if ($null -eq $manifest.materialization) { throw 'Dependency manifest has no materialization contract.' }
if ([string]::IsNullOrWhiteSpace($InstallationRoot)) {
    $InstallationRoot = 'D:\AI\vLLM'
    $defaultVolume = [IO.Path]::GetPathRoot($InstallationRoot)
    if (-not (Test-Path -LiteralPath $defaultVolume -PathType Container)) { throw "Default installation root '$InstallationRoot' is unavailable because volume '$defaultVolume' does not exist. Pass -InstallationRoot with an existing local path." }
}
$InstallationRoot = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
function Assert-DependencyPinnedFile {
    param([Parameter(Mandatory)]$Descriptor,[Parameter(Mandatory)][string]$Label)
    $path = Resolve-ProjectPath -Path ([string]$Descriptor.path) -BasePath $projectRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label not found: $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$Descriptor.size_bytes) { throw "$Label size mismatch. Expected $($Descriptor.size_bytes), got $($item.Length): $path" }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne [string]$Descriptor.sha256) { throw "$Label SHA-256 mismatch. Expected $($Descriptor.sha256), got ${hash}: $path" }
    if (($Descriptor.PSObject.Properties.Name -contains 'eol') -and [string]$Descriptor.eol -eq 'lf') {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ([Array]::IndexOf($bytes,[byte]13) -ge 0) { throw "$Label must use canonical LF line endings: $path" }
    }
    return $path
}
function Get-ManifestPackageMap {
    param([Parameter(Mandatory)]$Object)
    $map=@{}
    foreach($property in $Object.PSObject.Properties){
        $name=([string]$property.Name).ToLowerInvariant().Replace('_','-')
        if($map.ContainsKey($name)){throw "Duplicate normalized package name in manifest: $name"}
        $map[$name]=[string]$property.Value
    }
    return $map
}
$accepted = Get-ManifestPackageMap -Object $manifest.accepted_packages
$allowedExtras=@{}
foreach($item in @($manifest.allowed_extra_distributions)){
    $name=([string]$item).ToLowerInvariant().Replace('_','-')
    if([string]::IsNullOrWhiteSpace($name)){throw 'Allowed extra distribution name may not be empty.'}
    if($accepted.ContainsKey($name)){throw "Allowed extra distribution duplicates accepted dependency: $name"}
    if($allowedExtras.ContainsKey($name)){throw "Duplicate allowed extra distribution: $name"}
    $allowedExtras[$name]=$true
}
$lockPath = Assert-DependencyPinnedFile -Descriptor $manifest.lock -Label 'Runtime dependency lock'
$lockLines = @(Get-Content -LiteralPath $lockPath)
$locked=@{}; $blocks=@{}; $currentName=$null; $current=@()
function Save-DependencyLockBlock {
    if($null -eq $script:currentName){return}
    if($script:blocks.ContainsKey($script:currentName)){throw "Duplicate lock package: $script:currentName"}
    $script:blocks[$script:currentName]=@($script:current)
}
foreach($line in $lockLines){
    if($line -match '^([A-Za-z0-9_.-]+)==([^ \\]+)\s*\\?$'){
        Save-DependencyLockBlock; $currentName=$matches[1].ToLowerInvariant().Replace('_','-'); $current=@($line); $locked[$currentName]=$matches[2]; continue
    }
    if($line -match '^([A-Za-z0-9_.-]+)\s+@\s+(\S+)\s*\\?$'){
        Save-DependencyLockBlock; $currentName=$matches[1].ToLowerInvariant().Replace('_','-'); $current=@($line)
        if(-not $accepted.ContainsKey($currentName)){throw "Direct URL package is not in accepted set: $currentName"}
        $locked[$currentName]=$accepted[$currentName]; continue
    }
    if($null -ne $currentName){$current+=,$line}
}
Save-DependencyLockBlock
if($locked.Count -ne [int]$manifest.lock.package_count){throw "Locked package count mismatch. Expected $($manifest.lock.package_count), got $($locked.Count)."}
foreach($name in $locked.Keys){if(@($blocks[$name]|Where-Object{$_ -match '--hash=sha256:[0-9a-fA-F]{64}'}).Count -eq 0){throw "Locked package has no SHA-256 hash: $name"}}
if($accepted.Count -ne $locked.Count){throw "Accepted package count $($accepted.Count) does not match lock count $($locked.Count)."}
foreach($name in @($accepted.Keys+$locked.Keys|Sort-Object -Unique)){if(-not $accepted.ContainsKey($name)-or-not $locked.ContainsKey($name)-or $accepted[$name] -ne $locked[$name]){throw "Dependency lock disagrees with accepted package set at '$name'."}}
$targetRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.target_relative_path) -Label 'Dependency target path'
$cacheRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.cache_relative_path) -Label 'Dependency cache path'
$baseReceiptRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.base_venv_receipt_relative_path) -Label 'Base venv receipt path'
$receiptRelative = Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.receipt_relative_path) -Label 'Dependency receipt path'
if($targetRelative -ne 'runtime\venv'){throw "Dependency target must remain runtime\venv: $targetRelative"}
if([string]$manifest.materialization.installer -ne 'uv pip sync'){throw 'Unsupported dependency installer contract.'}
if(-not [bool]$manifest.materialization.require_hashes -or -not [bool]$manifest.materialization.only_binary -or -not [bool]$manifest.materialization.strict){throw 'Dependency materialization must require hashes, wheels only, and strict validation.'}
if([string]$manifest.materialization.link_mode -ne 'copy'){throw 'Dependency materialization link mode must be copy.'}
$defaultIndex=[string]$manifest.materialization.default_index
if([string]::IsNullOrWhiteSpace($defaultIndex)){throw 'Dependency materialization default index must not be empty.'}
$baseVenvManifestPath = Resolve-ProjectPath -Path ([string]$manifest.materialization.base_venv_manifest) -BasePath $projectRoot
if(-not(Test-Path -LiteralPath $baseVenvManifestPath -PathType Leaf)){throw "Base venv manifest not found: $baseVenvManifestPath"}
$baseVenvManifest = Get-Content -LiteralPath $baseVenvManifestPath -Raw|ConvertFrom-Json
if([string]$baseVenvManifest.component -ne 'runtime-venv' -or [string]$baseVenvManifest.platform -ne [string]$manifest.platform -or [string]$baseVenvManifest.milestone -ne [string]$manifest.milestone){throw 'Dependency manifest disagrees with the base runtime venv contract.'}
if([string]$baseVenvManifest.python.version -ne [string]$manifest.python_version){throw 'Dependency Python pin disagrees with the base runtime venv contract.'}
$pythonManifestPath=Resolve-ProjectPath -Path ([string]$baseVenvManifest.python.bootstrap_manifest) -BasePath $projectRoot
$uvManifestPath=Resolve-ProjectPath -Path ([string]$baseVenvManifest.uv.bootstrap_manifest) -BasePath $projectRoot
foreach($dependencyManifest in @($pythonManifestPath,$uvManifestPath)){if(-not(Test-Path -LiteralPath $dependencyManifest -PathType Leaf)){throw "Bootstrap dependency manifest not found: $dependencyManifest"}}
$pythonManifest=Get-Content -LiteralPath $pythonManifestPath -Raw|ConvertFrom-Json
$uvManifest=Get-Content -LiteralPath $uvManifestPath -Raw|ConvertFrom-Json
if([string]$pythonManifest.version -ne [string]$manifest.python_version){throw 'Dependency Python pin disagrees with the portable Python manifest.'}
if([string]$uvManifest.version -ne [string]$manifest.generator.version -or [string]$uvManifest.release.commit -ne [string]$manifest.generator.commit){throw 'Dependency uv pin disagrees with the portable uv manifest.'}
$pythonManagedRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.managed_relative_path) -Label 'Managed Python path'
$pythonExeRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.python_executable) -Label 'Python executable path'
$uvManagedRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.managed_relative_path) -Label 'Managed uv path'
$uvExeRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.uv_executable) -Label 'uv executable path'
$expectedPythonVersion=[string]$manifest.python_version
$expectedPointerBits=[int]$baseVenvManifest.acceptance.expected_pointer_bits
$expectedUvVersion=[string]$manifest.generator.version
$expectedUvCommit=[string]$manifest.generator.commit
$expectedUvCommitPrefix=[string]$uvManifest.acceptance.expected_commit_prefix
$baseRequiredFiles=@($baseVenvManifest.install.required_files|ForEach-Object{Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Base venv required file'})
function Test-ManagedPython {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Exe)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)-or-not(Test-Path -LiteralPath $Exe -PathType Leaf)){return $false}
    try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $pythonManagedRelative);[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Exe -RelativePath ($pythonManagedRelative+'\'+$pythonExeRelative))}catch{return $false}
    $probe=(& $Exe -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}')" 2>&1|Out-String).Trim()
    return ($LASTEXITCODE -eq 0 -and $probe -eq ($expectedPythonVersion+'|'+$expectedPointerBits))
}
function Test-ManagedUv {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Exe)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)-or-not(Test-Path -LiteralPath $Exe -PathType Leaf)){return $false}
    try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $uvManagedRelative);[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Exe -RelativePath ($uvManagedRelative+'\'+$uvExeRelative))}catch{return $false}
    $probe=(& $Exe --version 2>&1|Out-String).Trim()
    return ($LASTEXITCODE -eq 0 -and $probe.StartsWith("uv $expectedUvVersion ($expectedUvCommitPrefix",[StringComparison]::Ordinal))
}
function Test-VenvIdentity {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)){return $false}
    try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $targetRelative)}catch{return $false}
    foreach($relative in $baseRequiredFiles){
        $candidate=Join-Path $Root $relative
        try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $candidate -RelativePath ($targetRelative+'\'+$relative))}catch{return $false}
        if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){return $false}
    }
    $python=Join-Path $Root 'Scripts\python.exe'
    $probe=(& $python -I -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}|{sys.prefix}|{sys.base_prefix}')" 2>&1|Out-String).Trim()
    if($LASTEXITCODE -ne 0){return $false}
    $parts=$probe.Split('|')
    if($parts.Count -ne 4 -or $parts[0] -ne $expectedPythonVersion -or [int]$parts[1] -ne $expectedPointerBits){return $false}
    if((Get-VllmNormalizedPath $parts[2]) -ne (Get-VllmNormalizedPath $Root)){return $false}
    if((Get-VllmNormalizedPath $parts[3]) -ne (Get-VllmNormalizedPath $PythonRoot)){return $false}
    return $true
}
function Get-VenvDistributionMap {
    param([Parameter(Mandatory)][string]$Root)
    $python=Join-Path $Root 'Scripts\python.exe'
    $rows=@(& $python -I -c "import importlib.metadata as m; print('\n'.join(sorted((d.metadata['Name'].lower().replace('_','-')+'=='+d.version) for d in m.distributions() if d.metadata.get('Name'))))")
    if($LASTEXITCODE -ne 0){throw "Installed distribution probe failed with exit code $LASTEXITCODE."}
    $map=@{}
    foreach($row in $rows){
        if([string]::IsNullOrWhiteSpace($row)){continue}
        $parts=$row.Split(@('=='),2,[StringSplitOptions]::None)
        if($parts.Count -ne 2){throw "Unexpected installed distribution row: $row"}
        if($map.ContainsKey($parts[0])){throw "Duplicate installed distribution: $($parts[0])"}
        $map[$parts[0]]=$parts[1]
    }
    return $map
}
function Test-UnseededVenvRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot)){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    if($map.Count -ne 0){return $false}
    $site=Join-Path $Root 'Lib\site-packages'
    if(Test-Path -LiteralPath (Join-Path $site 'pip') -PathType Container){return $false}
    if(@(Get-ChildItem -LiteralPath $site -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^pip(?:-|\.)'}).Count){return $false}
    return $true
}
function Test-DependencyReadyRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot)){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    foreach($name in $accepted.Keys){if(-not $map.ContainsKey($name)-or $map[$name] -ne $accepted[$name]){return $false}}
    foreach($name in $map.Keys){if(-not $accepted.ContainsKey($name)-and-not $allowedExtras.ContainsKey($name)){return $false}}
    return $true
}
function Read-JsonReceipt {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{return $null}
}
function Test-BaseVenvReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$PythonExe,[Parameter(Mandatory)][string]$UvExe)
    $r=Read-JsonReceipt -Path $Path
    if($null -eq $r){return $false}
    try{
        if([string]$r.component -ne 'runtime-venv' -or -not [bool]$r.ready -or [bool]$r.seeded){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_python)) -ne (Get-VllmNormalizedPath $PythonExe)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.uv)) -ne (Get-VllmNormalizedPath $UvExe)){return $false}
        if([string]$r.python_version -ne $expectedPythonVersion -or [string]$r.uv_version -ne $expectedUvVersion -or [string]$r.uv_commit -ne $expectedUvCommit){return $false}
        return $true
    }catch{return $false}
}
function Test-DependencyReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$BaseReceiptPath)
    $r=Read-JsonReceipt -Path $Path
    if($null -eq $r){return $false}
    try{
        if([string]$r.component -ne 'runtime-dependencies' -or -not [bool]$r.ready){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if([string]$r.lock_sha256 -ne [string]$manifest.lock.sha256 -or [int64]$r.lock_size_bytes -ne [int64]$manifest.lock.size_bytes -or [int]$r.package_count -ne [int]$manifest.lock.package_count){return $false}
        if([string]$r.uv_version -ne $expectedUvVersion -or [string]$r.uv_commit -ne $expectedUvCommit){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_venv_receipt)) -ne (Get-VllmNormalizedPath $BaseReceiptPath)){return $false}
        $baseReceiptHash=(Get-FileHash -LiteralPath $BaseReceiptPath -Algorithm SHA256).Hash
        if([string]$r.base_venv_receipt_sha256 -ne $baseReceiptHash){return $false}
        if(-not [bool]$r.require_hashes -or -not [bool]$r.only_binary -or -not [bool]$r.strict -or [string]$r.link_mode -ne 'copy'){return $false}
        return $true
    }catch{return $false}
}
$lock=$null
$backupRoot=$null
$environmentSnapshot=$null
$result=$null
try{
    $lock=Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-dependencies'
    $InstallationRoot=$lock.Root
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)
    $pythonRoot=Join-Path $InstallationRoot $pythonManagedRelative
    $pythonExe=Join-Path $pythonRoot $pythonExeRelative
    $uvRoot=Join-Path $InstallationRoot $uvManagedRelative
    $uvExe=Join-Path $uvRoot $uvExeRelative
    if(-not(Test-ManagedPython -Root $pythonRoot -Exe $pythonExe)){throw "Pinned managed Python is missing or invalid. Run .\bootstrap-python.ps1 -InstallationRoot '$InstallationRoot' first."}
    if(-not(Test-ManagedUv -Root $uvRoot -Exe $uvExe)){throw "Pinned managed uv is missing or invalid. Run .\bootstrap-uv.ps1 -InstallationRoot '$InstallationRoot' first."}
    $runtimeParent=Join-Path $InstallationRoot 'runtime'
    $cacheDir=Join-Path $InstallationRoot $cacheRelative
    $forensicDir=Join-Path $InstallationRoot 'forensic'
    $targetRoot=Join-Path $InstallationRoot $targetRelative
    $baseReceiptPath=Join-Path $InstallationRoot $baseReceiptRelative
    $receiptPath=Join-Path $InstallationRoot $receiptRelative
    foreach($pathInfo in @(
        @{Path=$runtimeParent;Relative='runtime'},@{Path=$cacheDir;Relative=$cacheRelative},@{Path=$forensicDir;Relative='forensic'},
        @{Path=$targetRoot;Relative=$targetRelative},@{Path=$baseReceiptPath;Relative=$baseReceiptRelative},@{Path=$receiptPath;Relative=$receiptRelative}
    )){[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pathInfo.Path -RelativePath $pathInfo.Relative)}
    foreach($directory in @($runtimeParent,$cacheDir,$forensicDir)){[void][IO.Directory]::CreateDirectory($directory)}
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)
    if((Test-Path -LiteralPath $receiptPath)-and-not(Test-Path -LiteralPath $receiptPath -PathType Leaf)){throw "Reserved dependency receipt path exists but is not a file: $receiptPath"}
    if((Test-Path -LiteralPath $baseReceiptPath)-and-not(Test-Path -LiteralPath $baseReceiptPath -PathType Leaf)){throw "Base venv receipt path exists but is not a file: $baseReceiptPath"}
    if(-not(Test-Path -LiteralPath $targetRoot)){throw "Managed runtime venv is missing: $targetRoot. Run .\bootstrap-venv.ps1 -InstallationRoot '$InstallationRoot' first."}
    if(-not(Test-Path -LiteralPath $targetRoot -PathType Container)){throw "Managed runtime venv target exists but is not a directory: $targetRoot"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $targetRelative)
    if(-not(Test-BaseVenvReceipt -Path $baseReceiptPath -Target $targetRoot -PythonExe $pythonExe -UvExe $uvExe)){throw "Base runtime venv receipt is missing or invalid: $baseReceiptPath"}
    $ready=Test-DependencyReadyRoot -Root $targetRoot -PythonRoot $pythonRoot
    $receiptReady=Test-DependencyReceipt -Path $receiptPath -Target $targetRoot -BaseReceiptPath $baseReceiptPath
    if($ready -and $receiptReady -and -not $Force){
        $venvPython=Join-Path $targetRoot 'Scripts\python.exe'
        $result=[ordered]@{
            schema_version=1; component='runtime-dependencies'; milestone=[string]$manifest.milestone; platform=[string]$manifest.platform
            ready=$true; idempotent=$true; root=$targetRoot; python=$venvPython; base_python=$pythonExe; uv=$uvExe
            python_version=$expectedPythonVersion; uv_version=$expectedUvVersion; uv_commit=$expectedUvCommit
            package_count=[int]$manifest.lock.package_count; lock=$lockPath; lock_sha256=[string]$manifest.lock.sha256; lock_size_bytes=[int64]$manifest.lock.size_bytes
            require_hashes=$true; only_binary=$true; strict=$true; link_mode='copy'; offline=[bool]$Offline; cache=$cacheDir
            base_venv_receipt=$baseReceiptPath; receipt=$receiptPath
        }
    }
    else {
        if(-not $Force){
            if($receiptReady -or (Test-Path -LiteralPath $receiptPath)){throw 'Runtime dependency receipt exists but the managed venv does not match the committed dependency state. Re-run with -Force only when full replacement is intended.'}
            if(-not(Test-UnseededVenvRoot -Root $targetRoot -PythonRoot $pythonRoot)){throw 'Managed runtime venv is neither the exact unseeded bootstrap state nor a receipt-backed dependency-ready state. Re-run with -Force only when full replacement is intended.'}
        }
        $backupName='.venv-dependencies-backup-'+[guid]::NewGuid().ToString('N')
        $backupRoot=Join-Path $runtimeParent $backupName
        $backupRelative='runtime\'+$backupName
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Move-Item -LiteralPath $targetRoot -Destination $backupRoot
        try{
            try{
                $environmentSnapshot=Get-VllmProcessEnvironmentSnapshot
                foreach($key in @([Environment]::GetEnvironmentVariables('Process').Keys)){
                    $name=[string]$key
                    if($name.StartsWith('UV_',[StringComparison]::OrdinalIgnoreCase)){[VllmWindowsNative.NativeEnvironment]::DeleteProcessVariable($name)}
                }
                foreach($name in @('PYTHONHOME','PYTHONPATH','VIRTUAL_ENV','VIRTUAL_ENV_PROMPT','CONDA_PREFIX')){[VllmWindowsNative.NativeEnvironment]::DeleteProcessVariable($name)}
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_CACHE_DIR',$cacheDir)
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_NO_MANAGED_PYTHON','1')
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_PYTHON_DOWNLOADS','never')
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_NO_CONFIG','1')
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_NO_PROJECT','1')
                [VllmWindowsNative.NativeEnvironment]::SetProcessVariable('PYTHONNOUSERSITE','1')
                if($Offline){[VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_OFFLINE','1')}                & $uvExe venv $targetRoot --python $pythonExe --no-managed-python --no-python-downloads --offline --no-project --no-config
                if($LASTEXITCODE -ne 0){throw "uv venv failed with exit code $LASTEXITCODE."}
                $venvPython=Join-Path $targetRoot 'Scripts\python.exe'
                $syncArgs=@(
                    'pip','sync',$lockPath,'--python',$venvPython,'--require-hashes','--only-binary',':all:',
                    '--link-mode','copy','--strict','--cache-dir',$cacheDir,'--no-python-downloads','--no-config','--default-index',$defaultIndex
                )
                if($Offline){$syncArgs+='--offline'}
                & $uvExe @syncArgs
                if($LASTEXITCODE -ne 0){throw "uv pip sync failed with exit code $LASTEXITCODE."}
                & $uvExe pip check --python $venvPython --no-python-downloads --no-config
                if($LASTEXITCODE -ne 0){throw "uv pip check failed with exit code $LASTEXITCODE."}
            }
            finally{
                if($null -ne $environmentSnapshot){Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot;$environmentSnapshot=$null}
            }
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $targetRelative)
            if(-not(Test-DependencyReadyRoot -Root $targetRoot -PythonRoot $pythonRoot)){throw 'Materialized runtime dependency environment failed exact final validation.'}
        }
        catch{
            $materializationError=$_
            if(Test-Path -LiteralPath $targetRoot){
                try{
                    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $targetRelative)
                    Remove-Item -LiteralPath $targetRoot -Recurse -Force
                }
                catch{throw "Dependency materialization failed and rollback cannot safely remove the failed target. Backup preserved at '$backupRoot'. Original: $($materializationError.Exception.Message) Cleanup: $($_.Exception.Message)"}
            }
            if($backupRoot -and(Test-Path -LiteralPath $backupRoot)){
                try{Move-Item -LiteralPath $backupRoot -Destination $targetRoot;$backupRoot=$null}
                catch{throw "Dependency materialization failed and rollback could not restore the prior environment. Backup preserved at '$backupRoot'. Original: $($materializationError.Exception.Message) Rollback: $($_.Exception.Message)"}
            }
            throw $materializationError
        }
        try{
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $receiptPath -RelativePath $receiptRelative)
            if((Test-Path -LiteralPath $receiptPath)-and-not(Test-Path -LiteralPath $receiptPath -PathType Leaf)){throw "Reserved dependency receipt path changed into a non-file before commit: $receiptPath"}
            $venvPython=Join-Path $targetRoot 'Scripts\python.exe'
            $baseReceiptSha=(Get-FileHash -LiteralPath $baseReceiptPath -Algorithm SHA256).Hash
            $result=[ordered]@{
                schema_version=1; component='runtime-dependencies'; milestone=[string]$manifest.milestone; platform=[string]$manifest.platform
                ready=$true; idempotent=$false; root=$targetRoot; python=$venvPython; base_python=$pythonExe; uv=$uvExe
                python_version=$expectedPythonVersion; uv_version=$expectedUvVersion; uv_commit=$expectedUvCommit
                package_count=[int]$manifest.lock.package_count; lock=$lockPath; lock_sha256=[string]$manifest.lock.sha256; lock_size_bytes=[int64]$manifest.lock.size_bytes
                require_hashes=$true; only_binary=$true; strict=$true; link_mode='copy'; offline=[bool]$Offline; cache=$cacheDir
                base_venv_manifest=$baseVenvManifestPath; base_venv_receipt=$baseReceiptPath; base_venv_receipt_sha256=$baseReceiptSha
                base_venv_receipt_semantics='historical-after-materialization'; manifest=$manifestResolved; created_at=(Get-Date).ToString('o')
            }
            $receiptTemp=$receiptPath+'.partial.'+[guid]::NewGuid().ToString('N')
            try{
                [IO.File]::WriteAllText($receiptTemp,($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $receiptTemp -Destination $receiptPath -Force
            }
            finally{Remove-Item -LiteralPath $receiptTemp -Force -ErrorAction SilentlyContinue}
            $result.receipt=$receiptPath
        }
        catch{
            $receiptError=$_
            if(Test-Path -LiteralPath $targetRoot){
                try{
                    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $targetRelative)
                    Remove-Item -LiteralPath $targetRoot -Recurse -Force
                }
                catch{throw "Dependency receipt commit failed and rollback cannot safely remove the new environment. Prior environment backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Cleanup: $($_.Exception.Message)"}
            }
            if($backupRoot -and(Test-Path -LiteralPath $backupRoot)){
                try{Move-Item -LiteralPath $backupRoot -Destination $targetRoot;$backupRoot=$null}
                catch{throw "Dependency receipt commit failed and rollback could not restore the prior environment. Backup preserved at '$backupRoot'. Original: $($receiptError.Exception.Message) Rollback: $($_.Exception.Message)"}
            }
            throw $receiptError
        }
        if($backupRoot -and(Test-Path -LiteralPath $backupRoot)){
            $backupRelative='runtime\'+[IO.Path]::GetFileName($backupRoot)
            try{
                [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
                Remove-Item -LiteralPath $backupRoot -Recurse -Force
                $backupRoot=$null
            }
            catch{Write-Warning "Runtime dependencies committed successfully, but the prior venv backup could not be removed and was preserved at '$backupRoot': $($_.Exception.Message)"}
        }
    }
}
finally{
    if($null -ne $environmentSnapshot){try{Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot}catch{Write-Warning "Failed to restore caller environment exactly: $($_.Exception.Message)"}}
    if($null -ne $lock){Exit-VllmOperationLock -Lock $lock}
}
if($Json){$result|ConvertTo-Json -Depth 10}else{$result}
