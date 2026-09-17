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
. (Join-Path $PSScriptRoot 'scripts\lifecycle.ps1')
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
$baseExpectedCreationFileCount=[int]$baseVenvManifest.install.expected_creation_file_count
$baseIncludeSystemSitePackages=[bool]$baseVenvManifest.acceptance.include_system_site_packages
$basePipMustBeAbsent=[bool]$baseVenvManifest.acceptance.pip_must_be_absent
$stagingRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.staging_relative_path) -Label 'Dependency staging path'
$backupRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.backup_relative_path) -Label 'Dependency backup path'
$transactionRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.transaction_receipt_relative_path) -Label 'Dependency transaction receipt path'
$receiptSchemaVersion=[int]$manifest.materialization.receipt_schema_version
if($stagingRelative -ne 'runtime\.venv-dependencies-staging'){throw "Dependency staging path must remain runtime\.venv-dependencies-staging: $stagingRelative"}
if($backupRelative -ne 'runtime\.venv-dependencies-backup'){throw "Dependency backup path must remain runtime\.venv-dependencies-backup: $backupRelative"}
if($transactionRelative -ne 'forensic\runtime-dependencies-transaction-v0.27.1.json'){throw "Unexpected dependency transaction receipt path: $transactionRelative"}
if($receiptSchemaVersion -ne 2){throw "Unsupported dependency receipt schema: $receiptSchemaVersion"}
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
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot,[Parameter(Mandatory)][string]$RelativePath,[switch]$Relocatable)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)){return $false}
    try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $RelativePath)}catch{return $false}
    $required=@($baseRequiredFiles)
    if($Relocatable){$required=@($required|Where-Object{$_ -ne 'Scripts\activate.csh'})}
    foreach($relative in $required){
        $candidate=Join-Path $Root $relative
        try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $candidate -RelativePath ($RelativePath+'\'+$relative))}catch{return $false}
        if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){return $false}
    }
    $cfgLines=@(Get-Content -LiteralPath (Join-Path $Root 'pyvenv.cfg'))
    if($Relocatable){
        if($cfgLines -notcontains 'relocatable = true'){return $false}
        if(Test-Path -LiteralPath (Join-Path $Root 'Scripts\activate.csh') -PathType Leaf){return $false}
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
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot,[Parameter(Mandatory)][string]$BaseReceiptPath)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot -RelativePath $targetRelative)){return $false}
    $baseReceipt=Read-JsonReceipt -Path $BaseReceiptPath
    if($null -eq $baseReceipt){return $false}
    if(@(Get-ChildItem -LiteralPath $Root -Recurse -File -Force).Count -ne [int]$baseReceipt.file_count){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    if($map.Count -ne 0){return $false}
    $site=Join-Path $Root 'Lib\site-packages'
    if($basePipMustBeAbsent){
        if(Test-Path -LiteralPath (Join-Path $site 'pip') -PathType Container){return $false}
        if(@(Get-ChildItem -LiteralPath $site -Force -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^pip(?:-|\.)'}).Count){return $false}
    }
    $cfgLines=@(Get-Content -LiteralPath (Join-Path $Root 'pyvenv.cfg'))
    if($cfgLines -notcontains ('uv = '+$expectedUvVersion)){return $false}
    if($cfgLines -notcontains ('version_info = '+$expectedPythonVersion)){return $false}
    $includeLine='include-system-site-packages = '+$baseIncludeSystemSitePackages.ToString().ToLowerInvariant()
    if($cfgLines -notcontains $includeLine){return $false}
    $homeLine=@($cfgLines|Where-Object{$_ -like 'home = *'})
    if($homeLine.Count -ne 1 -or (Get-VllmNormalizedPath $homeLine[0].Substring(7)) -ne (Get-VllmNormalizedPath $PythonRoot)){return $false}
    $activation=Get-Content -LiteralPath (Join-Path $Root 'Scripts\activate.bat') -Raw
    if($activation.IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -lt 0){return $false}
    return $true
}
function Test-DependencyReadyRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PythonRoot,[Parameter(Mandatory)][string]$RelativePath)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot -RelativePath $RelativePath -Relocatable)){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    foreach($name in $accepted.Keys){if(-not $map.ContainsKey($name)-or $map[$name] -ne $accepted[$name]){return $false}}
    foreach($name in $map.Keys){if(-not $accepted.ContainsKey($name)-and-not $allowedExtras.ContainsKey($name)){return $false}}
    return $true
}
function Test-ExactPropertySet {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string[]]$Expected)
    $actual=@($Object.PSObject.Properties.Name|Sort-Object)
    $wanted=@($Expected|Sort-Object)
    return (@(Compare-Object -ReferenceObject $wanted -DifferenceObject $actual).Count -eq 0)
}
function Read-JsonReceipt {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{return $null}
}
function Test-ReceiptTimestamp {
    param([Parameter(Mandatory)]$Value)
    if($Value -is [DateTime] -or $Value -is [DateTimeOffset]){return $true}
    $parsed=[DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact([string]$Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
function Test-BaseVenvReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$PythonExe,[Parameter(Mandatory)][string]$UvExe)
    $r=Read-JsonReceipt -Path $Path
    if($null -eq $r){return $false}
    try{
        $expected=@('schema_version','component','milestone','platform','ready','root','python','base_python','uv','python_version','uv_version','uv_commit','seeded','file_count','python_bootstrap_manifest','uv_bootstrap_manifest','manifest','created_at')
        if(-not(Test-ExactPropertySet -Object $r -Expected $expected)){return $false}
        if([int]$r.schema_version -ne 1 -or [string]$r.component -ne 'runtime-venv' -or -not [bool]$r.ready -or [bool]$r.seeded){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.python)) -ne (Get-VllmNormalizedPath (Join-Path $Target 'Scripts\python.exe'))){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_python)) -ne (Get-VllmNormalizedPath $PythonExe)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.uv)) -ne (Get-VllmNormalizedPath $UvExe)){return $false}
        if([string]$r.python_version -ne $expectedPythonVersion -or [string]$r.uv_version -ne $expectedUvVersion -or [string]$r.uv_commit -ne $expectedUvCommit){return $false}
        if([int]$r.file_count -lt $baseExpectedCreationFileCount){return $false}
        if((Get-VllmNormalizedPath ([string]$r.python_bootstrap_manifest)) -ne (Get-VllmNormalizedPath $pythonManifestPath)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.uv_bootstrap_manifest)) -ne (Get-VllmNormalizedPath $uvManifestPath)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.manifest)) -ne (Get-VllmNormalizedPath $baseVenvManifestPath)){return $false}
        if(-not(Test-ReceiptTimestamp -Value $r.created_at)){return $false}
        return $true
    }catch{return $false}
}
function Test-DependencyReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$BaseReceiptPath)
    $r=Read-JsonReceipt -Path $Path
    if($null -eq $r){return $false}
    try{
        $expected=@('schema_version','component','milestone','platform','ready','idempotent','transaction_id','root','python','base_python','uv','python_version','uv_version','uv_commit','package_count','lock','lock_sha256','lock_size_bytes','require_hashes','only_binary','strict','link_mode','offline','cache','base_venv_manifest','base_venv_receipt','base_venv_receipt_sha256','base_venv_receipt_semantics','manifest','created_at')
        if(-not(Test-ExactPropertySet -Object $r -Expected $expected)){return $false}
        if([int]$r.schema_version -ne $receiptSchemaVersion -or [string]$r.component -ne 'runtime-dependencies' -or -not [bool]$r.ready -or [bool]$r.idempotent){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        $tx=[guid]::Empty
        if(-not [guid]::TryParse([string]$r.transaction_id,[ref]$tx) -or $tx -eq [guid]::Empty){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.python)) -ne (Get-VllmNormalizedPath (Join-Path $Target 'Scripts\python.exe'))){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_python)) -ne (Get-VllmNormalizedPath $pythonExe)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.uv)) -ne (Get-VllmNormalizedPath $uvExe)){return $false}
        if([string]$r.python_version -ne $expectedPythonVersion -or [string]$r.uv_version -ne $expectedUvVersion -or [string]$r.uv_commit -ne $expectedUvCommit){return $false}
        if([int]$r.package_count -ne [int]$manifest.lock.package_count -or [string]$r.lock_sha256 -ne [string]$manifest.lock.sha256 -or [int64]$r.lock_size_bytes -ne [int64]$manifest.lock.size_bytes){return $false}
        if((Get-VllmNormalizedPath ([string]$r.lock)) -ne (Get-VllmNormalizedPath $lockPath)){return $false}
        if(-not [bool]$r.require_hashes -or -not [bool]$r.only_binary -or -not [bool]$r.strict -or [string]$r.link_mode -ne 'copy'){return $false}
        if($r.offline -isnot [bool]){return $false}
        if((Get-VllmNormalizedPath ([string]$r.cache)) -ne (Get-VllmNormalizedPath $cacheDir)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_venv_manifest)) -ne (Get-VllmNormalizedPath $baseVenvManifestPath)){return $false}
        if((Get-VllmNormalizedPath ([string]$r.base_venv_receipt)) -ne (Get-VllmNormalizedPath $BaseReceiptPath)){return $false}
        $baseReceiptHash=(Get-FileHash -LiteralPath $BaseReceiptPath -Algorithm SHA256).Hash
        if([string]$r.base_venv_receipt_sha256 -ne $baseReceiptHash){return $false}
        if([string]$r.base_venv_receipt_semantics -ne [string]$manifest.materialization.base_venv_receipt_semantics){return $false}
        if((Get-VllmNormalizedPath ([string]$r.manifest)) -ne (Get-VllmNormalizedPath $manifestResolved)){return $false}
        if(-not(Test-ReceiptTimestamp -Value $r.created_at)){return $false}
        return $true
    }catch{return $false}
}
function Write-AtomicJsonFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value,[int]$Depth=10)
    $temp=$Path+'.partial.'+[guid]::NewGuid().ToString('N')
    try{
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth $Depth),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
function Test-TransactionState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$Staging,[Parameter(Mandatory)][string]$Backup,[Parameter(Mandatory)][string]$TransactionPath,[Parameter(Mandatory)][string]$BaseReceiptPath,[Parameter(Mandatory)][string]$DependencyReceiptPath)
    try{
        $expected=@('schema_version','component','milestone','platform','transaction_id','phase','target','staging','backup','transaction_receipt','dependency_receipt','base_venv_receipt','manifest','lock_sha256')
        if(-not(Test-ExactPropertySet -Object $State -Expected $expected)){return $false}
        if([int]$State.schema_version -ne 1 -or [string]$State.component -ne 'runtime-dependencies-transaction'){return $false}
        if([string]$State.milestone -ne [string]$manifest.milestone -or [string]$State.platform -ne [string]$manifest.platform){return $false}
        $tx=[guid]::Empty
        if(-not [guid]::TryParse([string]$State.transaction_id,[ref]$tx) -or $tx -eq [guid]::Empty){return $false}
        if(@('materializing','prepared') -notcontains [string]$State.phase){return $false}
        foreach($pair in @(@([string]$State.target,$Target),@([string]$State.staging,$Staging),@([string]$State.backup,$Backup),@([string]$State.transaction_receipt,$TransactionPath),@([string]$State.dependency_receipt,$DependencyReceiptPath),@([string]$State.base_venv_receipt,$BaseReceiptPath),@([string]$State.manifest,$manifestResolved))){
            if((Get-VllmNormalizedPath $pair[0]) -ne (Get-VllmNormalizedPath $pair[1])){return $false}
        }
        if([string]$State.lock_sha256 -ne [string]$manifest.lock.sha256){return $false}
        return $true
    }catch{return $false}
}
function Write-TransactionState {
    param([Parameter(Mandatory)][string]$TransactionId,[Parameter(Mandatory)][ValidateSet('materializing','prepared')][string]$Phase)
    $state=[ordered]@{
        schema_version=1; component='runtime-dependencies-transaction'; milestone=[string]$manifest.milestone; platform=[string]$manifest.platform
        transaction_id=$TransactionId; phase=$Phase; target=$targetRoot; staging=$stagingRoot; backup=$backupRoot
        transaction_receipt=$transactionPath; dependency_receipt=$receiptPath; base_venv_receipt=$baseReceiptPath; manifest=$manifestResolved; lock_sha256=[string]$manifest.lock.sha256
    }
    Write-AtomicJsonFile -Path $transactionPath -Value $state -Depth 6
}
function Invoke-ManagedDirectoryRemoval {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$RelativePath)
    if(Test-Path -LiteralPath $Path){
        if(-not(Test-Path -LiteralPath $Path -PathType Container)){throw "Reserved managed directory path is not a directory: $Path"}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath)
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}
function Invoke-TransactionReceiptRemoval {
    if(Test-Path -LiteralPath $transactionPath){
        if(-not(Test-Path -LiteralPath $transactionPath -PathType Leaf)){throw "Reserved transaction receipt path is not a file: $transactionPath"}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $transactionPath -RelativePath $transactionRelative)
        Remove-Item -LiteralPath $transactionPath -Force
    }
}
function Invoke-InterruptedTransactionRecovery {
    if(-not(Test-Path -LiteralPath $transactionPath)){
        if(Test-Path -LiteralPath $stagingRoot){throw "Reserved dependency staging path exists without a valid transaction receipt: $stagingRoot"}
        if(Test-Path -LiteralPath $backupRoot){throw "Reserved dependency backup path exists without a valid transaction receipt: $backupRoot"}
        return 'none'
    }
    if(-not(Test-Path -LiteralPath $transactionPath -PathType Leaf)){throw "Reserved transaction receipt path is not a file: $transactionPath"}
    $state=Read-JsonReceipt -Path $transactionPath
    if($null -eq $state -or -not(Test-TransactionState -State $state -Target $targetRoot -Staging $stagingRoot -Backup $backupRoot -TransactionPath $transactionPath -BaseReceiptPath $baseReceiptPath -DependencyReceiptPath $receiptPath)){throw "Dependency transaction receipt is malformed or contradictory: $transactionPath"}
    $targetExists=Test-Path -LiteralPath $targetRoot -PathType Container
    $backupExists=Test-Path -LiteralPath $backupRoot -PathType Container
    $stagingExists=Test-Path -LiteralPath $stagingRoot -PathType Container
    $committed=$false
    if($targetExists -and (Test-DependencyReadyRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative) -and (Test-DependencyReceipt -Path $receiptPath -Target $targetRoot -BaseReceiptPath $baseReceiptPath)){
        $dependencyReceipt=Read-JsonReceipt -Path $receiptPath
        $committed=([string]$dependencyReceipt.transaction_id -eq [string]$state.transaction_id)
    }
    if($committed){
        if($stagingExists){Invoke-ManagedDirectoryRemoval -Path $stagingRoot -RelativePath $stagingRelative}
        if($backupExists){Invoke-ManagedDirectoryRemoval -Path $backupRoot -RelativePath $backupRelative}
        Invoke-TransactionReceiptRemoval
        return 'committed-cleanup'
    }
    if($backupExists){
        if($targetExists){Invoke-ManagedDirectoryRemoval -Path $targetRoot -RelativePath $targetRelative}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $backupRoot -RelativePath $backupRelative)
        Move-Item -LiteralPath $backupRoot -Destination $targetRoot
        $targetExists=$true
    }
    elseif(-not $targetExists){
        throw "Interrupted dependency transaction cannot be recovered automatically because both the live target and prior backup are missing. Transaction evidence preserved at '$transactionPath'."
    }
    if($stagingExists){Invoke-ManagedDirectoryRemoval -Path $stagingRoot -RelativePath $stagingRelative}
    Invoke-TransactionReceiptRemoval
    return 'rolled-back'
}
$lock=$null
$environmentSnapshot=$null
$result=$null
try{
    $lock=Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-dependencies'
    $InstallationRoot=$lock.Root
    Assert-VllmUpdateMaintenanceAbsent -InstallationRoot $InstallationRoot
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
    $stagingRoot=Join-Path $InstallationRoot $stagingRelative
    $backupRoot=Join-Path $InstallationRoot $backupRelative
    $baseReceiptPath=Join-Path $InstallationRoot $baseReceiptRelative
    $receiptPath=Join-Path $InstallationRoot $receiptRelative
    $transactionPath=Join-Path $InstallationRoot $transactionRelative
    foreach($pathInfo in @(
        @{Path=$runtimeParent;Relative='runtime'},@{Path=$cacheDir;Relative=$cacheRelative},@{Path=$forensicDir;Relative='forensic'},
        @{Path=$targetRoot;Relative=$targetRelative},@{Path=$stagingRoot;Relative=$stagingRelative},@{Path=$backupRoot;Relative=$backupRelative},
        @{Path=$baseReceiptPath;Relative=$baseReceiptRelative},@{Path=$receiptPath;Relative=$receiptRelative},@{Path=$transactionPath;Relative=$transactionRelative}
    )){[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pathInfo.Path -RelativePath $pathInfo.Relative)}
    foreach($directory in @($runtimeParent,$cacheDir,$forensicDir)){[void][IO.Directory]::CreateDirectory($directory)}
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)
    foreach($reservedFile in @($receiptPath,$baseReceiptPath,$transactionPath)){if((Test-Path -LiteralPath $reservedFile)-and-not(Test-Path -LiteralPath $reservedFile -PathType Leaf)){throw "Reserved receipt path exists but is not a file: $reservedFile"}}
    foreach($reservedDirectory in @($stagingRoot,$backupRoot)){if((Test-Path -LiteralPath $reservedDirectory)-and-not(Test-Path -LiteralPath $reservedDirectory -PathType Container)){throw "Reserved dependency transaction path exists but is not a directory: $reservedDirectory"}}
    $recovery=Invoke-InterruptedTransactionRecovery
    if(-not(Test-Path -LiteralPath $targetRoot)){throw "Managed runtime venv is missing: $targetRoot. Run .\bootstrap-venv.ps1 -InstallationRoot '$InstallationRoot' first."}
    if(-not(Test-Path -LiteralPath $targetRoot -PathType Container)){throw "Managed runtime venv target exists but is not a directory: $targetRoot"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $targetRoot -RelativePath $targetRelative)
    if(-not(Test-BaseVenvReceipt -Path $baseReceiptPath -Target $targetRoot -PythonExe $pythonExe -UvExe $uvExe)){throw "Base runtime venv receipt is missing or invalid: $baseReceiptPath"}
    $ready=Test-DependencyReadyRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative
    $receiptReady=Test-DependencyReceipt -Path $receiptPath -Target $targetRoot -BaseReceiptPath $baseReceiptPath
    if($ready -and $receiptReady -and -not $Force){
        $storedReceipt=Read-JsonReceipt -Path $receiptPath
        $venvPython=Join-Path $targetRoot 'Scripts\python.exe'
        $result=[ordered]@{
            schema_version=$receiptSchemaVersion; component='runtime-dependencies'; milestone=[string]$manifest.milestone; platform=[string]$manifest.platform
            ready=$true; idempotent=$true; transaction_id=[string]$storedReceipt.transaction_id; root=$targetRoot; python=$venvPython; base_python=$pythonExe; uv=$uvExe
            python_version=$expectedPythonVersion; uv_version=$expectedUvVersion; uv_commit=$expectedUvCommit
            package_count=[int]$manifest.lock.package_count; lock=$lockPath; lock_sha256=[string]$manifest.lock.sha256; lock_size_bytes=[int64]$manifest.lock.size_bytes
            require_hashes=$true; only_binary=$true; strict=$true; link_mode='copy'; offline=[bool]$storedReceipt.offline; cache=$cacheDir
            base_venv_manifest=$baseVenvManifestPath; base_venv_receipt=$baseReceiptPath; base_venv_receipt_sha256=[string]$storedReceipt.base_venv_receipt_sha256
            base_venv_receipt_semantics=[string]$manifest.materialization.base_venv_receipt_semantics; manifest=$manifestResolved; receipt=$receiptPath; recovery=$recovery
        }
    }
    else {
        if(-not $Force){
            if($receiptReady -or (Test-Path -LiteralPath $receiptPath)){throw 'Runtime dependency receipt exists but the managed venv does not match the committed dependency state. Re-run with -Force only when full replacement is intended.'}
            if(-not(Test-UnseededVenvRoot -Root $targetRoot -PythonRoot $pythonRoot -BaseReceiptPath $baseReceiptPath)){throw 'Managed runtime venv is neither the exact unseeded bootstrap state nor a receipt-backed dependency-ready state. Re-run with -Force only when full replacement is intended.'}
        }
        $transactionId=[guid]::NewGuid().ToString('D')
        $materializationError=$null
        try{
            Write-TransactionState -TransactionId $transactionId -Phase 'materializing'
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
                if($Offline){[VllmWindowsNative.NativeEnvironment]::SetProcessVariable('UV_OFFLINE','1')}
                & $uvExe venv $stagingRoot --python $pythonExe --relocatable --no-managed-python --no-python-downloads --offline --no-project --no-config
                if($LASTEXITCODE -ne 0){throw "uv venv failed with exit code $LASTEXITCODE."}
                $stagingPython=Join-Path $stagingRoot 'Scripts\python.exe'
                $syncArgs=@('pip','sync',$lockPath,'--python',$stagingPython,'--require-hashes','--only-binary',':all:','--link-mode','copy','--strict','--cache-dir',$cacheDir,'--no-python-downloads','--no-config','--default-index',$defaultIndex)
                if($Offline){$syncArgs+='--offline'}
                & $uvExe @syncArgs
                if($LASTEXITCODE -ne 0){throw "uv pip sync failed with exit code $LASTEXITCODE."}
                & $uvExe pip check --python $stagingPython --no-python-downloads --no-config
                if($LASTEXITCODE -ne 0){throw "uv pip check failed with exit code $LASTEXITCODE."}
            }
            finally{
                if($null -ne $environmentSnapshot){Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot;$environmentSnapshot=$null}
            }
            if(-not(Test-DependencyReadyRoot -Root $stagingRoot -PythonRoot $pythonRoot -RelativePath $stagingRelative)){throw 'Staged runtime dependency environment failed exact validation.'}
            Write-TransactionState -TransactionId $transactionId -Phase 'prepared'
            Move-Item -LiteralPath $targetRoot -Destination $backupRoot
            Move-Item -LiteralPath $stagingRoot -Destination $targetRoot
            if(-not(Test-DependencyReadyRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative)){throw 'Activated runtime dependency environment failed exact final validation.'}
            $venvPython=Join-Path $targetRoot 'Scripts\python.exe'
            $baseReceiptSha=(Get-FileHash -LiteralPath $baseReceiptPath -Algorithm SHA256).Hash
            $receiptValue=[ordered]@{
                schema_version=$receiptSchemaVersion; component='runtime-dependencies'; milestone=[string]$manifest.milestone; platform=[string]$manifest.platform
                ready=$true; idempotent=$false; transaction_id=$transactionId; root=$targetRoot; python=$venvPython; base_python=$pythonExe; uv=$uvExe
                python_version=$expectedPythonVersion; uv_version=$expectedUvVersion; uv_commit=$expectedUvCommit
                package_count=[int]$manifest.lock.package_count; lock=$lockPath; lock_sha256=[string]$manifest.lock.sha256; lock_size_bytes=[int64]$manifest.lock.size_bytes
                require_hashes=$true; only_binary=$true; strict=$true; link_mode='copy'; offline=[bool]$Offline; cache=$cacheDir
                base_venv_manifest=$baseVenvManifestPath; base_venv_receipt=$baseReceiptPath; base_venv_receipt_sha256=$baseReceiptSha
                base_venv_receipt_semantics=[string]$manifest.materialization.base_venv_receipt_semantics; manifest=$manifestResolved; created_at=(Get-Date).ToString('o')
            }
            Write-AtomicJsonFile -Path $receiptPath -Value $receiptValue -Depth 10
            $result=[ordered]@{}+$receiptValue
            $result.receipt=$receiptPath
            $result.recovery=$recovery
        }
        catch{
            $materializationError=$_
            try{[void](Invoke-InterruptedTransactionRecovery)}
            catch{throw "Dependency materialization failed and automatic recovery also failed. Transaction evidence is preserved at '$transactionPath'. Original: $($materializationError.Exception.Message) Recovery: $($_.Exception.Message)"}
            throw $materializationError
        }
        [void](Invoke-InterruptedTransactionRecovery)
    }
}
finally{
    if($null -ne $environmentSnapshot){try{Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot}catch{Write-Warning "Failed to restore caller environment exactly: $($_.Exception.Message)"}}
    if($null -ne $lock){Exit-VllmOperationLock -Lock $lock}
}
if($Json){$result|ConvertTo-Json -Depth 10}else{$result}
