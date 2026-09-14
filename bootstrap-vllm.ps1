[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/runtime/vllm-runtime-v0.27.1-windows-x86_64.json',
    [string] $InstallationRoot = '',
    [Parameter(Mandatory)][string] $WheelPath,
    [switch] $Force,
    [switch] $Offline,
    [switch] $Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem){throw 'bootstrap-vllm.ps1 supports native Windows x64 only.'}
$projectRoot=Get-ProjectRoot
$manifestResolved=Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
if(-not(Test-Path -LiteralPath $manifestResolved -PathType Leaf)){throw "vLLM runtime manifest not found: $manifestResolved"}
$manifest=Get-Content -LiteralPath $manifestResolved -Raw|ConvertFrom-Json
if([string]$manifest.component -ne 'vllm-runtime' -or [string]$manifest.platform -ne 'windows-x86_64'){throw "Unsupported vLLM runtime manifest: component=$($manifest.component), platform=$($manifest.platform)"}
if($null -eq $manifest.materialization){throw 'vLLM runtime manifest has no materialization contract.'}
if([string]::IsNullOrWhiteSpace($InstallationRoot)){
    $InstallationRoot='D:\AI\vLLM'
    $defaultVolume=[IO.Path]::GetPathRoot($InstallationRoot)
    if(-not(Test-Path -LiteralPath $defaultVolume -PathType Container)){throw "Default installation root '$InstallationRoot' is unavailable because volume '$defaultVolume' does not exist. Pass -InstallationRoot with an existing local path."}
}
$InstallationRoot=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
function Assert-PinnedFile {
    param([Parameter(Mandatory)]$Descriptor,[Parameter(Mandatory)][string]$Label)
    $p=Resolve-ProjectPath -Path ([string]$Descriptor.path) -BasePath $projectRoot
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "$Label not found: $p"}
    $i=Get-Item -LiteralPath $p
    if($i.Length -ne [int64]$Descriptor.size_bytes){throw "$Label size mismatch. Expected $($Descriptor.size_bytes), got $($i.Length): $p"}
    $h=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
    if($h -ne [string]$Descriptor.sha256){throw "$Label SHA-256 mismatch. Expected $($Descriptor.sha256), got ${h}: $p"}
    if(($Descriptor.PSObject.Properties.Name -contains 'eol') -and [string]$Descriptor.eol -eq 'lf'){
        if([Array]::IndexOf([IO.File]::ReadAllBytes($p),[byte]13) -ge 0){throw "$Label must use canonical LF line endings: $p"}
    }
    return $p
}
function Get-JsonPackageMap {
    param([Parameter(Mandatory)][string]$Path)
    $o=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
    $map=@{}
    foreach($prop in $o.PSObject.Properties){
        $name=([string]$prop.Name).ToLowerInvariant().Replace('_','-')
        if($map.ContainsKey($name)){throw "Duplicate normalized package name: $name"}
        $map[$name]=[string]$prop.Value
    }
    return $map
}
$null=Assert-PinnedFile -Descriptor $manifest.input -Label 'vLLM runtime input'
$lockPath=Assert-PinnedFile -Descriptor $manifest.lock -Label 'vLLM runtime lock'
$packageMapPath=Assert-PinnedFile -Descriptor $manifest.accepted_packages -Label 'vLLM runtime package map'
$accepted=Get-JsonPackageMap -Path $packageMapPath
if($accepted.Count -ne [int]$manifest.accepted_packages.package_count){throw "Accepted package map count mismatch. Expected $($manifest.accepted_packages.package_count), got $($accepted.Count)."}
$lockLines=@(Get-Content -LiteralPath $lockPath)
$locked=@{};$blocks=@{};$currentName=$null;$current=@()
function Save-LockBlock {
    if($null -eq $script:currentName){return}
    if($script:blocks.ContainsKey($script:currentName)){throw "Duplicate lock package: $script:currentName"}
    $script:blocks[$script:currentName]=@($script:current)
}
foreach($line in $lockLines){
    if($line -match '^([A-Za-z0-9_.-]+)==([^ \\]+)\s*\\?$'){Save-LockBlock;$currentName=$matches[1].ToLowerInvariant().Replace('_','-');$current=@($line);$locked[$currentName]=$matches[2];continue}
    if($line -match '^([A-Za-z0-9_.-]+)\s+@\s+(\S+)\s*\\?$'){Save-LockBlock;$currentName=$matches[1].ToLowerInvariant().Replace('_','-');$current=@($line);if(-not $accepted.ContainsKey($currentName)){throw "Direct URL package is not accepted: $currentName"};$locked[$currentName]=$accepted[$currentName];continue}
    if($null -ne $currentName){$current+=,$line}
}
Save-LockBlock
if($locked.Count -ne [int]$manifest.lock.package_count){throw "Lock count mismatch. Expected $($manifest.lock.package_count), got $($locked.Count)."}
foreach($name in $locked.Keys){if(@($blocks[$name]|Where-Object{$_ -match '--hash=sha256:[0-9a-fA-F]{64}'}).Count -eq 0){throw "Locked package has no SHA-256 hash: $name"}}
if($accepted.Count -ne $locked.Count){throw 'Accepted package map and lock have different counts.'}
foreach($name in @($accepted.Keys+$locked.Keys|Sort-Object -Unique)){if(-not $accepted.ContainsKey($name)-or-not $locked.ContainsKey($name)-or $accepted[$name] -ne $locked[$name]){throw "Lock disagrees with accepted package map at '$name'."}}
$wheelResolved=Resolve-ProjectPath -Path $WheelPath -BasePath $projectRoot
if(-not(Test-Path -LiteralPath $wheelResolved -PathType Leaf)){throw "Provided vLLM wheel not found: $wheelResolved"}
$wheelItem=Get-Item -LiteralPath $wheelResolved
if($wheelItem.Name -ne [string]$manifest.project_wheel.filename){throw "Provided wheel filename mismatch. Expected $($manifest.project_wheel.filename), got $($wheelItem.Name)."}
if($wheelItem.Length -ne [int64]$manifest.project_wheel.size_bytes){throw "Provided wheel size mismatch. Expected $($manifest.project_wheel.size_bytes), got $($wheelItem.Length)."}
$wheelSha=(Get-FileHash -LiteralPath $wheelResolved -Algorithm SHA256).Hash
if($wheelSha -ne [string]$manifest.project_wheel.sha256){throw "Provided wheel SHA-256 mismatch. Expected $($manifest.project_wheel.sha256), got $wheelSha."}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($wheelResolved)
try{
    $pyd=@($zip.Entries|Where-Object{$_.FullName -like '*.pyd'}|ForEach-Object{$_.FullName.Replace('/','\')}|Sort-Object)
    $expectedPyd=@($manifest.project_wheel.native_extensions|ForEach-Object{([string]$_).Replace('/','\')}|Sort-Object)
    if($pyd.Count -ne [int]$manifest.project_wheel.native_extension_count -or @(Compare-Object $expectedPyd $pyd).Count){throw 'Provided wheel native extension set does not match the pinned manifest.'}
    $metadataEntry=$zip.Entries|Where-Object{$_.FullName -match '\.dist-info/METADATA$'}|Select-Object -First 1
    $wheelEntry=$zip.Entries|Where-Object{$_.FullName -match '\.dist-info/WHEEL$'}|Select-Object -First 1
    if($null -eq $metadataEntry -or $null -eq $wheelEntry){throw 'Provided wheel is missing METADATA or WHEEL metadata.'}
    $sr=[IO.StreamReader]::new($metadataEntry.Open());try{$metadata=$sr.ReadToEnd()}finally{$sr.Dispose()}
    $sr=[IO.StreamReader]::new($wheelEntry.Open());try{$wheelMeta=$sr.ReadToEnd()}finally{$sr.Dispose()}
    if($metadata -notmatch '(?m)^Name:\s*vllm\s*$'){throw 'Provided wheel distribution name is not vllm.'}
    if($metadata -notmatch ('(?m)^Version:\s*'+[regex]::Escape([string]$manifest.project_wheel.version)+'\s*$')){throw 'Provided wheel version does not match the pinned manifest.'}
    $tag='Tag: '+[string]$manifest.project_wheel.python_tag+'-'+[string]$manifest.project_wheel.abi_tag+'-'+[string]$manifest.project_wheel.platform_tag
    if($wheelMeta.IndexOf($tag,[StringComparison]::Ordinal) -lt 0){throw "Provided wheel compatibility tag is missing: $tag"}
}finally{$zip.Dispose()}
$predManifestPath=Resolve-ProjectPath -Path ([string]$manifest.predecessor.manifest) -BasePath $projectRoot
if(-not(Test-Path -LiteralPath $predManifestPath -PathType Leaf)){throw "Predecessor dependency manifest not found: $predManifestPath"}
$predManifest=Get-Content -LiteralPath $predManifestPath -Raw|ConvertFrom-Json
if([string]$predManifest.component -ne 'runtime-dependencies' -or [string]$predManifest.milestone -ne [string]$manifest.milestone -or [string]$predManifest.platform -ne [string]$manifest.platform){throw 'vLLM runtime manifest disagrees with predecessor dependency contract.'}
$baseVenvManifestPath=Resolve-ProjectPath -Path ([string]$predManifest.materialization.base_venv_manifest) -BasePath $projectRoot
$baseVenvManifest=Get-Content -LiteralPath $baseVenvManifestPath -Raw|ConvertFrom-Json
$pythonManifestPath=Resolve-ProjectPath -Path ([string]$baseVenvManifest.python.bootstrap_manifest) -BasePath $projectRoot
$uvManifestPath=Resolve-ProjectPath -Path ([string]$baseVenvManifest.uv.bootstrap_manifest) -BasePath $projectRoot
$pythonManifest=Get-Content -LiteralPath $pythonManifestPath -Raw|ConvertFrom-Json
$uvManifest=Get-Content -LiteralPath $uvManifestPath -Raw|ConvertFrom-Json
$pythonManagedRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.managed_relative_path) -Label 'Managed Python path'
$pythonExeRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$pythonManifest.install.python_executable) -Label 'Python executable path'
$uvManagedRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.managed_relative_path) -Label 'Managed uv path'
$uvExeRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$uvManifest.install.uv_executable) -Label 'uv executable path'
$targetRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.target_relative_path) -Label 'vLLM target path'
$stagingRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.staging_relative_path) -Label 'vLLM staging path'
$backupRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.backup_relative_path) -Label 'vLLM backup path'
$cacheRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.cache_relative_path) -Label 'vLLM cache path'
$predReceiptRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.predecessor_receipt_relative_path) -Label 'Predecessor receipt path'
$receiptRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.receipt_relative_path) -Label 'vLLM receipt path'
$transactionRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$manifest.materialization.transaction_receipt_relative_path) -Label 'vLLM transaction receipt path'
if($targetRelative -ne 'runtime\venv'){throw "vLLM target must remain runtime\venv: $targetRelative"}
if([int]$manifest.materialization.final_package_count -ne ($accepted.Count+1)){throw 'vLLM final package count must equal accepted dependency count plus the project distribution.'}
$expectedPythonVersion=[string]$manifest.python_version
$expectedPointerBits=[int]$baseVenvManifest.acceptance.expected_pointer_bits
$expectedUvVersion=[string]$manifest.generator.version
$expectedUvCommit=[string]$manifest.generator.commit
$expectedUvCommitPrefix=[string]$uvManifest.acceptance.expected_commit_prefix
function Test-ManagedPython {
    param([string]$Root,[string]$Exe)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)-or-not(Test-Path -LiteralPath $Exe -PathType Leaf)){return $false}
    $probe=(& $Exe -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}')" 2>&1|Out-String).Trim()
    return ($LASTEXITCODE -eq 0 -and $probe -eq ($expectedPythonVersion+'|'+$expectedPointerBits))
}
function Test-ManagedUv {
    param([string]$Root,[string]$Exe)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)-or-not(Test-Path -LiteralPath $Exe -PathType Leaf)){return $false}
    $probe=(& $Exe --version 2>&1|Out-String).Trim()
    return ($LASTEXITCODE -eq 0 -and $probe.StartsWith("uv $expectedUvVersion ($expectedUvCommitPrefix",[StringComparison]::Ordinal))
}
function Test-VenvIdentity {
    param([string]$Root,[string]$PythonRoot,[string]$RelativePath)
    if(-not(Test-Path -LiteralPath $Root -PathType Container)){return $false}
    try{[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Root -RelativePath $RelativePath)}catch{return $false}
    $cfg=Join-Path $Root 'pyvenv.cfg'; $python=Join-Path $Root 'Scripts\python.exe'
    if(-not(Test-Path -LiteralPath $cfg -PathType Leaf)-or-not(Test-Path -LiteralPath $python -PathType Leaf)){return $false}
    $lines=@(Get-Content -LiteralPath $cfg)
    if($lines -notcontains 'relocatable = true'){return $false}
    $probe=(& $python -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}|{sys.base_prefix}')" 2>&1|Out-String).Trim()
    if($LASTEXITCODE -ne 0){return $false}
    $parts=$probe.Split('|'); if($parts.Count -ne 3){return $false}
    return ($parts[0] -eq $expectedPythonVersion -and [int]$parts[1] -eq $expectedPointerBits -and (Get-VllmNormalizedPath $parts[2]) -eq (Get-VllmNormalizedPath $PythonRoot))
}
function Get-VenvDistributionMap {
    param([string]$Root)
    $python=Join-Path $Root 'Scripts\python.exe'
    $rows=@(& $python -I -c "import importlib.metadata as m; print('\n'.join(sorted((d.metadata['Name'].lower().replace('_','-')+'=='+d.version) for d in m.distributions() if d.metadata.get('Name'))))")
    if($LASTEXITCODE -ne 0){throw "Installed distribution probe failed with exit code $LASTEXITCODE."}
    $map=@{};foreach($row in $rows){if([string]::IsNullOrWhiteSpace($row)){continue};$separator=$row.IndexOf('==',[StringComparison]::Ordinal);if($separator -le 0 -or $separator+2 -ge $row.Length){throw "Invalid installed distribution row: $row"};$name=$row.Substring(0,$separator);$version=$row.Substring($separator+2);if($map.ContainsKey($name)){throw "Duplicate installed distribution row: $row"};$map[$name]=$version};return $map
}
$predAccepted=@{}
foreach($prop in $predManifest.accepted_packages.PSObject.Properties){$predAccepted[([string]$prop.Name).ToLowerInvariant().Replace('_','-')]=[string]$prop.Value}
function Test-PredecessorRoot {
    param([string]$Root,[string]$PythonRoot,[string]$RelativePath)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot -RelativePath $RelativePath)){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    if($map.Count -ne $predAccepted.Count){return $false}
    foreach($name in $predAccepted.Keys){if(-not $map.ContainsKey($name)-or $map[$name] -ne $predAccepted[$name]){return $false}}
    return $true
}
function Test-FinalRuntimeRoot {
    param([string]$Root,[string]$PythonRoot,[string]$RelativePath)
    if(-not(Test-VenvIdentity -Root $Root -PythonRoot $PythonRoot -RelativePath $RelativePath)){return $false}
    try{$map=Get-VenvDistributionMap -Root $Root}catch{return $false}
    if($map.Count -ne [int]$manifest.materialization.final_package_count){return $false}
    foreach($name in $accepted.Keys){if(-not $map.ContainsKey($name)-or $map[$name] -ne $accepted[$name]){return $false}}
    if(-not $map.ContainsKey('vllm') -or $map['vllm'] -ne [string]$manifest.project_wheel.version){return $false}
    foreach($name in $map.Keys){if($name -ne 'vllm' -and -not $accepted.ContainsKey($name)){return $false}}
    return $true
}
function Read-JsonReceipt {
    param([string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    try{return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{return $null}
}
function Test-ReceiptTimestamp {
    param($Value)
    if($Value -is [DateTime] -or $Value -is [DateTimeOffset]){return $true}
    $parsed=[DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact([string]$Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
}
function Write-AtomicJsonFile {
    param([string]$Path,$Value,[int]$Depth=10)
    $temp=$Path+'.partial.'+[guid]::NewGuid().ToString('N')
    try{[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth $Depth),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $Path -Force}finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
function Test-PredecessorReceipt {
    param([string]$Path,[string]$Target)
    $r=Read-JsonReceipt -Path $Path;if($null -eq $r){return $false}
    try{
        if([int]$r.schema_version -ne [int]$predManifest.materialization.receipt_schema_version -or [string]$r.component -ne 'runtime-dependencies' -or -not [bool]$r.ready){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if([int]$r.package_count -ne [int]$manifest.predecessor.required_package_count){return $false}
        if([string]$r.lock_sha256 -ne [string]$predManifest.lock.sha256 -or [int64]$r.lock_size_bytes -ne [int64]$predManifest.lock.size_bytes){return $false}
        if((Get-VllmNormalizedPath ([string]$r.manifest)) -ne (Get-VllmNormalizedPath $predManifestPath)){return $false}
        $tx=[guid]::Empty;if(-not[guid]::TryParse([string]$r.transaction_id,[ref]$tx)-or$tx -eq [guid]::Empty){return $false}
        if(-not(Test-ReceiptTimestamp -Value $r.created_at)){return $false}
        return $true
    }catch{return $false}
}
function Test-FinalReceipt {
    param([string]$Path,[string]$Target,[string]$PredecessorReceipt)
    $r=Read-JsonReceipt -Path $Path;if($null -eq $r){return $false}
    try{
        if([int]$r.schema_version -ne [int]$manifest.materialization.receipt_schema_version -or [string]$r.component -ne 'vllm-runtime' -or -not [bool]$r.ready){return $false}
        if([string]$r.milestone -ne [string]$manifest.milestone -or [string]$r.platform -ne [string]$manifest.platform){return $false}
        if((Get-VllmNormalizedPath ([string]$r.root)) -ne (Get-VllmNormalizedPath $Target)){return $false}
        if([int]$r.package_count -ne [int]$manifest.materialization.final_package_count){return $false}
        if([string]$r.lock_sha256 -ne [string]$manifest.lock.sha256 -or [string]$r.package_map_sha256 -ne [string]$manifest.accepted_packages.sha256){return $false}
        if([string]$r.wheel_sha256 -ne [string]$manifest.project_wheel.sha256 -or [int64]$r.wheel_size_bytes -ne [int64]$manifest.project_wheel.size_bytes -or [string]$r.vllm_version -ne [string]$manifest.project_wheel.version){return $false}
        if((Get-VllmNormalizedPath ([string]$r.predecessor_receipt)) -ne (Get-VllmNormalizedPath $PredecessorReceipt)){return $false}
        $predSha=(Get-FileHash -LiteralPath $PredecessorReceipt -Algorithm SHA256).Hash;if([string]$r.predecessor_receipt_sha256 -ne $predSha){return $false}
        if((Get-VllmNormalizedPath ([string]$r.manifest)) -ne (Get-VllmNormalizedPath $manifestResolved)){return $false}
        $tx=[guid]::Empty;if(-not[guid]::TryParse([string]$r.transaction_id,[ref]$tx)-or$tx -eq [guid]::Empty){return $false}
        if(-not(Test-ReceiptTimestamp -Value $r.created_at)){return $false}
        return $true
    }catch{return $false}
}
function Write-TransactionState {
    param([string]$TransactionId,[ValidateSet('materializing','prepared')][string]$Phase)
    $state=[ordered]@{schema_version=1;component='vllm-runtime-transaction';milestone=[string]$manifest.milestone;platform=[string]$manifest.platform;transaction_id=$TransactionId;phase=$Phase;target=$targetRoot;staging=$stagingRoot;backup=$backupRoot;transaction_receipt=$transactionPath;final_receipt=$receiptPath;predecessor_receipt=$predReceiptPath;manifest=$manifestResolved;lock_sha256=[string]$manifest.lock.sha256;wheel_sha256=[string]$manifest.project_wheel.sha256}
    Write-AtomicJsonFile -Path $transactionPath -Value $state -Depth 6
}
function Test-TransactionState {
    param($State)
    try{
        if([int]$State.schema_version -ne 1 -or [string]$State.component -ne 'vllm-runtime-transaction'){return $false}
        if([string]$State.milestone -ne [string]$manifest.milestone -or [string]$State.platform -ne [string]$manifest.platform){return $false}
        if(@('materializing','prepared') -notcontains [string]$State.phase){return $false}
        $tx=[guid]::Empty;if(-not[guid]::TryParse([string]$State.transaction_id,[ref]$tx)-or$tx -eq [guid]::Empty){return $false}
        foreach($pair in @(@([string]$State.target,$targetRoot),@([string]$State.staging,$stagingRoot),@([string]$State.backup,$backupRoot),@([string]$State.transaction_receipt,$transactionPath),@([string]$State.final_receipt,$receiptPath),@([string]$State.predecessor_receipt,$predReceiptPath),@([string]$State.manifest,$manifestResolved))){if((Get-VllmNormalizedPath $pair[0]) -ne (Get-VllmNormalizedPath $pair[1])){return $false}}
        if([string]$State.lock_sha256 -ne [string]$manifest.lock.sha256 -or [string]$State.wheel_sha256 -ne [string]$manifest.project_wheel.sha256){return $false}
        return $true
    }catch{return $false}
}
function Invoke-ManagedDirectoryRemoval {
    param([string]$Path,[string]$RelativePath)
    if(Test-Path -LiteralPath $Path){if(-not(Test-Path -LiteralPath $Path -PathType Container)){throw "Reserved managed directory path is not a directory: $Path"};[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath);Remove-Item -LiteralPath $Path -Recurse -Force}
}
function Invoke-TransactionReceiptRemoval {
    if(Test-Path -LiteralPath $transactionPath){if(-not(Test-Path -LiteralPath $transactionPath -PathType Leaf)){throw "Reserved transaction receipt path is not a file: $transactionPath"};[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $transactionPath -RelativePath $transactionRelative);Remove-Item -LiteralPath $transactionPath -Force}
}
function Invoke-InterruptedTransactionRecovery {
    if(-not(Test-Path -LiteralPath $transactionPath)){
        if(Test-Path -LiteralPath $stagingRoot){throw "Reserved vLLM staging path exists without a valid transaction receipt: $stagingRoot"}
        if(Test-Path -LiteralPath $backupRoot){throw "Reserved vLLM backup path exists without a valid transaction receipt: $backupRoot"}
        return 'none'
    }
    if(-not(Test-Path -LiteralPath $transactionPath -PathType Leaf)){throw "Reserved vLLM transaction receipt path is not a file: $transactionPath"}
    $state=Read-JsonReceipt -Path $transactionPath
    if($null -eq $state -or -not(Test-TransactionState -State $state)){throw "vLLM transaction receipt is malformed or contradictory: $transactionPath"}
    $targetExists=Test-Path -LiteralPath $targetRoot -PathType Container
    $backupExists=Test-Path -LiteralPath $backupRoot -PathType Container
    $stagingExists=Test-Path -LiteralPath $stagingRoot -PathType Container
    $committed=$false
    if($targetExists -and (Test-FinalRuntimeRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative) -and (Test-FinalReceipt -Path $receiptPath -Target $targetRoot -PredecessorReceipt $predReceiptPath)){
        $finalReceipt=Read-JsonReceipt -Path $receiptPath
        $committed=([string]$finalReceipt.transaction_id -eq [string]$state.transaction_id)
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
    } elseif(-not $targetExists){
        throw "Interrupted vLLM transaction cannot be recovered automatically because both live target and prior backup are missing. Transaction evidence preserved at '$transactionPath'."
    }
    if($stagingExists){Invoke-ManagedDirectoryRemoval -Path $stagingRoot -RelativePath $stagingRelative}
    Invoke-TransactionReceiptRemoval
    return 'rolled-back'
}
$operationLock=$null;$environmentSnapshot=$null;$result=$null
try{
    $operationLock=Enter-VllmOperationLock -InstallationRoot $InstallationRoot -Operation 'bootstrap-vllm'
    $InstallationRoot=$operationLock.Root
    [void](Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot)
    $pythonRoot=Join-Path $InstallationRoot $pythonManagedRelative;$pythonExe=Join-Path $pythonRoot $pythonExeRelative
    $uvRoot=Join-Path $InstallationRoot $uvManagedRelative;$uvExe=Join-Path $uvRoot $uvExeRelative
    if(-not(Test-ManagedPython -Root $pythonRoot -Exe $pythonExe)){throw "Pinned managed Python is missing or invalid. Run .\bootstrap-python.ps1 -InstallationRoot '$InstallationRoot' first."}
    if(-not(Test-ManagedUv -Root $uvRoot -Exe $uvExe)){throw "Pinned managed uv is missing or invalid. Run .\bootstrap-uv.ps1 -InstallationRoot '$InstallationRoot' first."}
    $runtimeParent=Join-Path $InstallationRoot 'runtime';$cacheDir=Join-Path $InstallationRoot $cacheRelative;$forensicDir=Join-Path $InstallationRoot 'forensic'
    $targetRoot=Join-Path $InstallationRoot $targetRelative;$stagingRoot=Join-Path $InstallationRoot $stagingRelative;$backupRoot=Join-Path $InstallationRoot $backupRelative
    $predReceiptPath=Join-Path $InstallationRoot $predReceiptRelative;$receiptPath=Join-Path $InstallationRoot $receiptRelative;$transactionPath=Join-Path $InstallationRoot $transactionRelative
    foreach($pi in @(@{Path=$runtimeParent;Relative='runtime'},@{Path=$cacheDir;Relative=$cacheRelative},@{Path=$forensicDir;Relative='forensic'},@{Path=$targetRoot;Relative=$targetRelative},@{Path=$stagingRoot;Relative=$stagingRelative},@{Path=$backupRoot;Relative=$backupRelative},@{Path=$predReceiptPath;Relative=$predReceiptRelative},@{Path=$receiptPath;Relative=$receiptRelative},@{Path=$transactionPath;Relative=$transactionRelative})){[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pi.Path -RelativePath $pi.Relative)}
    foreach($d in @($runtimeParent,$cacheDir,$forensicDir)){[void][IO.Directory]::CreateDirectory($d)}
    foreach($f in @($predReceiptPath,$receiptPath,$transactionPath)){if((Test-Path -LiteralPath $f)-and-not(Test-Path -LiteralPath $f -PathType Leaf)){throw "Reserved receipt path exists but is not a file: $f"}}
    foreach($d in @($stagingRoot,$backupRoot)){if((Test-Path -LiteralPath $d)-and-not(Test-Path -LiteralPath $d -PathType Container)){throw "Reserved vLLM transaction path exists but is not a directory: $d"}}
    $recovery=Invoke-InterruptedTransactionRecovery
    if(-not(Test-Path -LiteralPath $targetRoot -PathType Container)){throw "Managed runtime venv is missing: $targetRoot"}
    if(-not(Test-PredecessorReceipt -Path $predReceiptPath -Target $targetRoot)){throw "Predecessor dependency receipt is missing or invalid: $predReceiptPath"}
    $predecessorReady=Test-PredecessorRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative
    $finalReady=Test-FinalRuntimeRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative
    $finalReceiptReady=Test-FinalReceipt -Path $receiptPath -Target $targetRoot -PredecessorReceipt $predReceiptPath
    if($finalReady -and $finalReceiptReady -and -not $Force){
        $stored=Read-JsonReceipt -Path $receiptPath
        $result=[ordered]@{schema_version=[int]$manifest.materialization.receipt_schema_version;component='vllm-runtime';milestone=[string]$manifest.milestone;platform=[string]$manifest.platform;ready=$true;idempotent=$true;transaction_id=[string]$stored.transaction_id;root=$targetRoot;python=(Join-Path $targetRoot 'Scripts\python.exe');package_count=[int]$manifest.materialization.final_package_count;vllm_version=[string]$manifest.project_wheel.version;wheel_sha256=[string]$manifest.project_wheel.sha256;lock_sha256=[string]$manifest.lock.sha256;receipt=$receiptPath;recovery=$recovery}
    } else {
        if(-not $Force -and -not $predecessorReady){
            if(Test-Path -LiteralPath $receiptPath){throw 'Final vLLM receipt exists but runtime does not match the committed final state. Re-run with -Force only when full replacement is intended.'}
            throw 'Managed runtime venv is not the exact receipt-backed predecessor dependency state.'
        }
        if($Force -and -not $predecessorReady -and -not $finalReady){throw 'Refusing to replace an unknown runtime state even with -Force.'}
        $transactionId=[guid]::NewGuid().ToString('D')
        $materializationError=$null
        try{
            Write-TransactionState -TransactionId $transactionId -Phase 'materializing'
            try{
                $environmentSnapshot=Get-VllmProcessEnvironmentSnapshot
                foreach($key in @([Environment]::GetEnvironmentVariables('Process').Keys)){$name=[string]$key;if($name.StartsWith('UV_',[StringComparison]::OrdinalIgnoreCase)){[VllmWindowsNative.NativeEnvironment]::DeleteProcessVariable($name)}}
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
                $syncArgs=@('pip','sync',$lockPath,'--python',$stagingPython,'--require-hashes','--only-binary',':all:','--link-mode','copy','--strict','--cache-dir',$cacheDir,'--no-python-downloads','--no-config','--default-index',[string]$manifest.materialization.default_index)
                if($Offline){$syncArgs+='--offline'}
                & $uvExe @syncArgs
                if($LASTEXITCODE -ne 0){throw "uv pip sync failed with exit code $LASTEXITCODE."}
                & $uvExe pip install $wheelResolved --python $stagingPython --no-deps --no-index --link-mode copy --no-python-downloads --no-config
                if($LASTEXITCODE -ne 0){throw "vLLM wheel install failed with exit code $LASTEXITCODE."}
                & $uvExe pip check --python $stagingPython --no-python-downloads --no-config
                if($LASTEXITCODE -ne 0){throw "uv pip check failed with exit code $LASTEXITCODE."}
            } finally {
                if($null -ne $environmentSnapshot){Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot;$environmentSnapshot=$null}
            }
            if(-not(Test-FinalRuntimeRoot -Root $stagingRoot -PythonRoot $pythonRoot -RelativePath $stagingRelative)){throw 'Staged final vLLM runtime failed exact validation.'}
            Write-TransactionState -TransactionId $transactionId -Phase 'prepared'
            Move-Item -LiteralPath $targetRoot -Destination $backupRoot
            Move-Item -LiteralPath $stagingRoot -Destination $targetRoot
            if(-not(Test-FinalRuntimeRoot -Root $targetRoot -PythonRoot $pythonRoot -RelativePath $targetRelative)){throw 'Activated final vLLM runtime failed exact validation.'}
            $predReceiptSha=(Get-FileHash -LiteralPath $predReceiptPath -Algorithm SHA256).Hash
            $receiptValue=[ordered]@{
                schema_version=[int]$manifest.materialization.receipt_schema_version;component='vllm-runtime';milestone=[string]$manifest.milestone;platform=[string]$manifest.platform
                ready=$true;idempotent=$false;transaction_id=$transactionId;root=$targetRoot;python=(Join-Path $targetRoot 'Scripts\python.exe');base_python=$pythonExe;uv=$uvExe
                python_version=$expectedPythonVersion;uv_version=$expectedUvVersion;uv_commit=$expectedUvCommit;package_count=[int]$manifest.materialization.final_package_count
                vllm_version=[string]$manifest.project_wheel.version;wheel_filename=[string]$manifest.project_wheel.filename;wheel_sha256=[string]$manifest.project_wheel.sha256;wheel_size_bytes=[int64]$manifest.project_wheel.size_bytes
                lock=$lockPath;lock_sha256=[string]$manifest.lock.sha256;lock_size_bytes=[int64]$manifest.lock.size_bytes;package_map=$packageMapPath;package_map_sha256=[string]$manifest.accepted_packages.sha256;package_map_size_bytes=[int64]$manifest.accepted_packages.size_bytes
                predecessor_manifest=$predManifestPath;predecessor_receipt=$predReceiptPath;predecessor_receipt_sha256=$predReceiptSha;manifest=$manifestResolved;offline=[bool]$Offline;cache=$cacheDir;created_at=(Get-Date).ToString('o')
            }
            Write-AtomicJsonFile -Path $receiptPath -Value $receiptValue -Depth 10
            $result=[ordered]@{}+$receiptValue;$result.receipt=$receiptPath;$result.recovery=$recovery
        } catch {
            $materializationError=$_
            try{[void](Invoke-InterruptedTransactionRecovery)}catch{throw "vLLM materialization failed and automatic recovery also failed. Transaction evidence is preserved at '$transactionPath'. Original: $($materializationError.Exception.Message) Recovery: $($_.Exception.Message)"}
            throw $materializationError
        }
        [void](Invoke-InterruptedTransactionRecovery)
    }
} finally {
    if($null -ne $environmentSnapshot){try{Restore-VllmProcessEnvironment -Snapshot $environmentSnapshot}catch{Write-Warning "Failed to restore caller environment exactly: $($_.Exception.Message)"}}
    if($null -ne $operationLock){Exit-VllmOperationLock -Lock $operationLock}
}
if($Json){$result|ConvertTo-Json -Depth 10}else{$result}
