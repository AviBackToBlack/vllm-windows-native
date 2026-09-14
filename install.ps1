[CmdletBinding()]
param(
    [string] $ReleaseManifestPath = 'manifests/release/v0.27.1-windows-x86_64.json',
    [string] $InstallationRoot = '',
    [string] $ModelsRoot = '',
    [Parameter(Mandatory)][string] $WheelPath,
    [string] $PythonArchivePath = '',
    [string] $UvArchivePath = '',
    [switch] $Offline,
    [switch] $Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem){throw 'install.ps1 supports native Windows x64 only.'}
$sourceRoot=Get-ProjectRoot
$releaseManifestSource=Resolve-ProjectPath -Path $ReleaseManifestPath -BasePath $sourceRoot
if(-not(Test-Path -LiteralPath $releaseManifestSource -PathType Leaf)){throw "Release manifest not found: $releaseManifestSource"}
$release=Get-Content -LiteralPath $releaseManifestSource -Raw|ConvertFrom-Json
if([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64'){throw "Unsupported release manifest: component=$($release.component), platform=$($release.platform)"}
if([string]::IsNullOrWhiteSpace($InstallationRoot)){$InstallationRoot='D:\AI\vLLM';$v=[IO.Path]::GetPathRoot($InstallationRoot);if(-not(Test-Path -LiteralPath $v -PathType Container)){throw "Default installation root '$InstallationRoot' is unavailable because volume '$v' does not exist. Pass -InstallationRoot with an existing local path."}}
$InstallationRoot=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
if([string]::IsNullOrWhiteSpace($ModelsRoot)){$ModelsRoot=Join-Path $InstallationRoot 'models'}
$ModelsRoot=Assert-VllmSafeModelsRoot -InstallationRoot $InstallationRoot -ModelsRoot $ModelsRoot
function Get-FileIdentity{param([string]$Path);$i=Get-Item -LiteralPath $Path -ErrorAction Stop;if($i.PSIsContainer){throw "Expected file, got directory: $Path"};[ordered]@{size_bytes=[int64]$i.Length;sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}}
function Read-JsonFile{param([string]$Path);if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null};try{Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{return $null}}
function Test-PathEqual{param([string]$A,[string]$B);(Get-VllmNormalizedPath $A).Equals((Get-VllmNormalizedPath $B),[StringComparison]::OrdinalIgnoreCase)}
function Test-ReceiptTimestamp{param($Value);if($Value -is [DateTime] -or $Value -is [DateTimeOffset]){return $true};$d=[DateTimeOffset]::MinValue;[DateTimeOffset]::TryParseExact([string]$Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$d)}
function Assert-SourceReleasePayload{
    $seen=@{}
    foreach($entry in @($release.files)){
        $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release distribution path'
        $key=$relative.ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate release distribution path: $relative"};$seen[$key]=$true
        $source=Join-Path $sourceRoot $relative
        if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Release distribution source is missing: $source"}
        $id=Get-FileIdentity $source
        if($id.size_bytes -ne [int64]$entry.size_bytes -or $id.sha256 -ne [string]$entry.sha256){throw "Release distribution source does not match manifest: $relative"}
    }
}
function Assert-CanonicalWheel{
    $resolved=[IO.Path]::GetFullPath($WheelPath)
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "vLLM wheel not found: $resolved"}
    $e=$release.wheel;$i=Get-Item -LiteralPath $resolved
    if($i.Name -ne [string]$e.filename){throw "vLLM wheel filename mismatch. Expected $($e.filename), got $($i.Name)."}
    if($i.Length -ne [int64]$e.size_bytes){throw "vLLM wheel size mismatch. Expected $($e.size_bytes), got $($i.Length)."}
    $h=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    if($h -ne [string]$e.sha256){throw "vLLM wheel SHA-256 mismatch. Expected $($e.sha256), got $h."}
    $resolved
}
function Assert-BootstrapReceipt{
    param([string]$Path,[string]$Component,[string]$Version,[string]$Target,[string]$Exe,[string]$Manifest,[string]$ManifestSha)
    $r=Read-JsonFile $Path;if($null -eq $r){return $false}
    if([int]$r.schema_version -ne 1 -or [string]$r.component -ne $Component -or [string]$r.version -ne $Version -or [string]$r.platform -ne 'windows-x86_64' -or -not[bool]$r.ready){return $false}
    $actualExe=if($Component -eq 'cpython'){[string]$r.python}else{[string]$r.uv}
    if(-not(Test-PathEqual ([string]$r.root) $Target) -or -not(Test-PathEqual $actualExe $Exe)){return $false}
    if(-not(Test-PathEqual ([string]$r.manifest) $Manifest) -or [string]$r.manifest_sha256 -ne $ManifestSha){return $false}
    if(-not(Test-ReceiptTimestamp $r.activated_at)){return $false}
    return $true
}
Assert-SourceReleasePayload
$WheelPath=Assert-CanonicalWheel
$releaseRelative=Assert-VllmSafeRelativePath -RelativePath ([string]$release.self_path) -Label 'Release manifest path'
if(-not(Test-PathEqual $releaseManifestSource (Join-Path $sourceRoot $releaseRelative))){throw "Release manifest path does not match self_path '$releaseRelative'."}
$releaseManifestIdentity=Get-FileIdentity $releaseManifestSource
$stateDir=Join-Path $InstallationRoot 'state';$stateRelative='state'
$statePath=Join-Path $stateDir 'install-state.json';$statePathRelative='state\install-state.json'
$stagingRoot=Join-Path $InstallationRoot 'work\install-distribution-staging';$stagingRelative='work\install-distribution-staging'
[void][IO.Directory]::CreateDirectory($InstallationRoot)
foreach($pair in @(@($stateDir,$stateRelative),@($statePath,$statePathRelative),@($stagingRoot,$stagingRelative))){[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $pair[0] -RelativePath $pair[1])}
[void][IO.Directory]::CreateDirectory($stateDir)
$orchestratorLockPath=Join-Path $stateDir 'install-orchestrator.lock';$orchestratorLockRelative='state\install-orchestrator.lock'
[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $orchestratorLockPath -RelativePath $orchestratorLockRelative)
$orchestratorLock=$null
function Enter-InstallerLock{
    try{$script:orchestratorLock=[IO.File]::Open($orchestratorLockPath,'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{throw "Another top-level install operation is active for '$InstallationRoot'."}
    $rootPhysical=Get-VllmPhysicalCandidatePath -Path $InstallationRoot -Format Guid
    $expected=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootPhysical,$orchestratorLockRelative))
    $actual=Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($script:orchestratorLock.SafeFileHandle))
    if(-not$actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){$script:orchestratorLock.Dispose();$script:orchestratorLock=$null;throw "Install orchestrator lock resolves outside expected location: $actual"}
}
function Exit-InstallerLock{if($null-ne$script:orchestratorLock){$script:orchestratorLock.Dispose();$script:orchestratorLock=$null}}
function Invoke-DistributionStagingCleanup{if(Test-Path -LiteralPath $stagingRoot){if(-not(Test-Path -LiteralPath $stagingRoot -PathType Container)){throw "Distribution staging path is not a directory: $stagingRoot"};[void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $stagingRoot -RelativePath $stagingRelative);Remove-Item -LiteralPath $stagingRoot -Recurse -Force}}
function Get-PayloadEntries{
    $list=New-Object System.Collections.Generic.List[object]
    foreach($e in @($release.files)){$list.Add([pscustomobject]@{path=[string]$e.path;size_bytes=[int64]$e.size_bytes;sha256=[string]$e.sha256;source=(Join-Path $sourceRoot ([string]$e.path))})}
    $list.Add([pscustomobject]@{path=$releaseRelative;size_bytes=[int64]$releaseManifestIdentity.size_bytes;sha256=[string]$releaseManifestIdentity.sha256;source=$releaseManifestSource})
    $list.ToArray()
}
function Install-DistributionPayload{
    Invoke-DistributionStagingCleanup
    [void][IO.Directory]::CreateDirectory($stagingRoot)
    $entries=Get-PayloadEntries
    foreach($e in $entries){
        $rel=Assert-VllmSafeRelativePath -RelativePath $e.path -Label 'Distribution path'
        $stage=Join-Path $stagingRoot $rel;$parent=Split-Path -Parent $stage;[void][IO.Directory]::CreateDirectory($parent)
        Copy-Item -LiteralPath $e.source -Destination $stage
        $id=Get-FileIdentity $stage
        if($id.size_bytes-ne$e.size_bytes-or$id.sha256-ne$e.sha256){throw "Staged distribution file failed verification: $rel"}
    }
    foreach($e in $entries){
        $rel=Assert-VllmSafeRelativePath -RelativePath $e.path -Label 'Distribution path';$dest=Join-Path $InstallationRoot $rel
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $dest -RelativePath $rel)
        if(Test-Path -LiteralPath $dest){
            if(-not(Test-Path -LiteralPath $dest -PathType Leaf)){throw "Distribution target is not a file: $dest"}
            $id=Get-FileIdentity $dest
            if($id.size_bytes-ne$e.size_bytes-or$id.sha256-ne$e.sha256){throw "Distribution target drift exists without a valid install state: $rel"}
        }else{
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));Move-Item -LiteralPath (Join-Path $stagingRoot $rel) -Destination $dest
        }
    }
    Invoke-DistributionStagingCleanup
}
function Write-AtomicJson{
    param([string]$Path,$Value)
    $tmp=$Path+'.partial.'+[guid]::NewGuid().ToString('N')
    try{[IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));$check=Get-Content $tmp -Raw|ConvertFrom-Json;if($null-eq$check){throw 'Atomic JSON validation returned null.'};if(-not(Test-InstallState -State $check)){throw 'Atomic install-state candidate failed semantic validation.'};Move-Item -LiteralPath $tmp -Destination $Path -Force}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
}
function Get-InstalledPath{param([string]$Relative);$rel=Assert-VllmSafeRelativePath -RelativePath $Relative -Label 'Installed release path';Join-Path $InstallationRoot $rel}
$orch=$release.orchestration
$pythonManifestPath=Get-InstalledPath ([string]$orch.python_manifest)
$uvManifestPath=Get-InstalledPath ([string]$orch.uv_manifest)
$venvManifestPath=Get-InstalledPath ([string]$orch.venv_manifest)
$dependencyManifestPath=Get-InstalledPath ([string]$orch.dependency_manifest)
$runtimeManifestPath=Get-InstalledPath ([string]$orch.runtime_manifest)
$pythonReceiptPath=Get-InstalledPath ([string]$orch.python_receipt)
$uvReceiptPath=Get-InstalledPath ([string]$orch.uv_receipt)
$venvReceiptPath=Get-InstalledPath ([string]$orch.venv_receipt)
$dependencyReceiptPath=Get-InstalledPath ([string]$orch.dependency_receipt)
$runtimeReceiptPath=Get-InstalledPath ([string]$orch.runtime_receipt)
$runtimeRoot=Get-InstalledPath ([string]$orch.runtime_root)
function Test-PythonLayer{
    $m=Get-Content $pythonManifestPath -Raw|ConvertFrom-Json;$target=Join-Path $InstallationRoot ([string]$m.install.managed_relative_path);$exe=Join-Path $target ([string]$m.install.python_executable)
    $targetExists=Test-Path -LiteralPath $target -PathType Container;$receiptExists=Test-Path -LiteralPath $pythonReceiptPath -PathType Leaf
    if(-not$targetExists -and -not$receiptExists){return $false};if($targetExists -ne $receiptExists){throw 'Managed Python target/receipt state is contradictory.'}
    $manifestSha=(Get-FileHash $pythonManifestPath -Algorithm SHA256).Hash
    if(-not(Assert-BootstrapReceipt -Path $pythonReceiptPath -Component 'cpython' -Version ([string]$m.version) -Target $target -Exe $exe -Manifest $pythonManifestPath -ManifestSha $manifestSha)){throw 'Managed Python receipt is invalid.'}
    $r=Read-JsonFile $pythonReceiptPath;if([string]$r.archive_sha256 -ne [string]$m.archive.sha256){throw 'Managed Python receipt archive digest mismatch.'}
    $probe=& $exe -I -c "import platform,sys; print(platform.python_version()); print(8*__import__('struct').calcsize('P'))";if($LASTEXITCODE-ne0-or@($probe).Count-ne2-or[string]$probe[0]-ne[string]$m.acceptance.expected_version-or[int]$probe[1]-ne[int]$m.acceptance.expected_pointer_bits){throw 'Managed Python runtime identity is invalid.'}
    return $true
}
function Test-UvLayer{
    $m=Get-Content $uvManifestPath -Raw|ConvertFrom-Json;$target=Join-Path $InstallationRoot ([string]$m.install.managed_relative_path);$exe=Join-Path $target ([string]$m.install.uv_executable)
    $targetExists=Test-Path -LiteralPath $target -PathType Container;$receiptExists=Test-Path -LiteralPath $uvReceiptPath -PathType Leaf
    if(-not$targetExists -and -not$receiptExists){return $false};if($targetExists -ne $receiptExists){throw 'Managed uv target/receipt state is contradictory.'}
    $manifestSha=(Get-FileHash $uvManifestPath -Algorithm SHA256).Hash
    if(-not(Assert-BootstrapReceipt -Path $uvReceiptPath -Component 'uv' -Version ([string]$m.version) -Target $target -Exe $exe -Manifest $uvManifestPath -ManifestSha $manifestSha)){throw 'Managed uv receipt is invalid.'}
    $r=Read-JsonFile $uvReceiptPath;if([string]$r.archive_sha256 -ne [string]$m.archive.sha256){throw 'Managed uv receipt archive digest mismatch.'}
    $v=(& $exe --version 2>&1|Out-String).Trim();if($LASTEXITCODE-ne0-or-not$v.StartsWith("uv $($m.acceptance.expected_version) ($($m.acceptance.expected_commit_prefix)",[StringComparison]::OrdinalIgnoreCase)){throw "Managed uv runtime identity is invalid: $v"}
    return $true
}
function Get-ExpectedDistributionState{
    $items=New-Object System.Collections.Generic.List[object]
    foreach($e in Get-PayloadEntries){$items.Add([pscustomobject][ordered]@{path=[string]$e.path;size_bytes=[int64]$e.size_bytes;sha256=[string]$e.sha256})}
    @($items|Sort-Object path)
}
function Test-InstallState{
    param($State)
    if($null-eq$State){return $false}
    $expectedProps=@('schema_version','component','release','platform','ready','generation_id','install_root','models_root','release_manifest','release_manifest_sha256','upstream','windows_patchset','wheel','python','uv','runtime','distribution_files','managed_paths','installed_at','updated_at')
    if((Compare-Object ($expectedProps|Sort-Object) (@($State.PSObject.Properties.Name)|Sort-Object))){return $false}
    if([int]$State.schema_version-ne1-or[string]$State.component-ne'install-state'-or-not[bool]$State.ready){return $false}
    if([string]$State.release-ne[string]$release.release-or[string]$State.platform-ne[string]$release.platform){return $false}
    if([string]::IsNullOrWhiteSpace([string]$State.generation_id)){return $false}
    if(-not(Test-PathEqual ([string]$State.install_root) $InstallationRoot)-or-not(Test-PathEqual ([string]$State.models_root) $ModelsRoot)){return $false}
    $installedReleaseManifest=Join-Path $InstallationRoot $releaseRelative
    if(-not(Test-PathEqual ([string]$State.release_manifest) $installedReleaseManifest)){return $false}
    if(-not(Test-Path -LiteralPath $installedReleaseManifest -PathType Leaf)){return $false}
    if([string]$State.release_manifest_sha256-ne(Get-FileHash $installedReleaseManifest -Algorithm SHA256).Hash){return $false}
    if([string]$State.upstream.repository-ne[string]$release.upstream.repository-or[string]$State.upstream.tag-ne[string]$release.upstream.tag-or[string]$State.upstream.commit-ne[string]$release.upstream.commit){return $false}
    if([string]$State.windows_patchset.tree-ne[string]$release.windows_patchset.tree-or[string]$State.windows_patchset.patch_sha256-ne[string]$release.windows_patchset.patch_sha256){return $false}
    if([string]$State.wheel.filename-ne[string]$release.wheel.filename-or[string]$State.wheel.sha256-ne[string]$release.wheel.sha256-or[int64]$State.wheel.size_bytes-ne[int64]$release.wheel.size_bytes){return $false}
    $expectedFiles=@(Get-ExpectedDistributionState);$actualFiles=@($State.distribution_files)
    if($expectedFiles.Count-ne$actualFiles.Count){return $false}
    foreach($e in $expectedFiles){$a=@($actualFiles|Where-Object{[string]$_.path-eq[string]$e.path});if($a.Count-ne1-or[int64]$a[0].size_bytes-ne[int64]$e.size_bytes-or[string]$a[0].sha256-ne[string]$e.sha256){return $false};$dest=Join-Path $InstallationRoot ([string]$e.path);if(-not(Test-Path -LiteralPath $dest -PathType Leaf)){return $false};$id=Get-FileIdentity $dest;if($id.size_bytes-ne[int64]$e.size_bytes-or$id.sha256-ne[string]$e.sha256){return $false}}
    $expectedManaged=@($release.managed_paths|ForEach-Object{[string]$_}|Sort-Object);$actualManaged=@($State.managed_paths|ForEach-Object{[string]$_}|Sort-Object)
    if(Compare-Object $expectedManaged $actualManaged){return $false}
    foreach($p in @($pythonReceiptPath,$uvReceiptPath,$venvReceiptPath,$dependencyReceiptPath,$runtimeReceiptPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $false}}
    $pythonReceipt=Read-JsonFile $pythonReceiptPath;$uvReceipt=Read-JsonFile $uvReceiptPath;$runtimeReceipt=Read-JsonFile $runtimeReceiptPath
    if($null-eq$pythonReceipt-or$null-eq$uvReceipt-or$null-eq$runtimeReceipt){return $false}
    if([string]$State.python.version-ne[string]$pythonReceipt.version-or-not(Test-PathEqual ([string]$State.python.root) ([string]$pythonReceipt.root))-or-not(Test-PathEqual ([string]$State.python.python) ([string]$pythonReceipt.python))-or-not(Test-PathEqual ([string]$State.python.receipt) $pythonReceiptPath)){return $false}
    if([string]$State.python.receipt_sha256-ne(Get-FileHash $pythonReceiptPath -Algorithm SHA256).Hash-or[string]$State.python.archive_sha256-ne[string]$pythonReceipt.archive_sha256){return $false}
    if([string]$State.uv.version-ne[string]$uvReceipt.version-or-not(Test-PathEqual ([string]$State.uv.root) ([string]$uvReceipt.root))-or-not(Test-PathEqual ([string]$State.uv.uv) ([string]$uvReceipt.uv))-or-not(Test-PathEqual ([string]$State.uv.receipt) $uvReceiptPath)){return $false}
    if([string]$State.uv.receipt_sha256-ne(Get-FileHash $uvReceiptPath -Algorithm SHA256).Hash-or[string]$State.uv.archive_sha256-ne[string]$uvReceipt.archive_sha256){return $false}
    if(-not(Test-PathEqual ([string]$State.runtime.root) $runtimeRoot)-or-not(Test-PathEqual ([string]$State.runtime.final_receipt) $runtimeReceiptPath)-or-not(Test-PathEqual ([string]$State.runtime.dependency_receipt) $dependencyReceiptPath)){return $false}
    if([string]$State.runtime.final_receipt_sha256-ne(Get-FileHash $runtimeReceiptPath -Algorithm SHA256).Hash-or[string]$State.runtime.dependency_receipt_sha256-ne(Get-FileHash $dependencyReceiptPath -Algorithm SHA256).Hash){return $false}
    if([int]$State.runtime.package_count-ne[int]$runtimeReceipt.package_count-or[string]$State.runtime.vllm_version-ne[string]$runtimeReceipt.vllm_version-or[string]$State.runtime.wheel_sha256-ne[string]$runtimeReceipt.wheel_sha256-or[string]$State.runtime.lock_sha256-ne[string]$runtimeReceipt.lock_sha256){return $false}
    if(-not(Test-ReceiptTimestamp $State.installed_at)-or-not(Test-ReceiptTimestamp $State.updated_at)){return $false}
    return $true
}
function Invoke-InstalledLayer{
    param([string]$Script,[hashtable]$Parameters)
    if(-not(Test-Path -LiteralPath $Script -PathType Leaf)){throw "Installed lifecycle script is missing: $Script"}
    $raw=@(& $Script @Parameters)
    $text=($raw -join [Environment]::NewLine).Trim()
    if([string]::IsNullOrWhiteSpace($text)){throw "Installed lifecycle script returned no JSON: $Script"}
    try{$value=$text|ConvertFrom-Json}catch{throw "Installed lifecycle script returned invalid JSON: $Script :: $text"}
    if($null-eq$value-or-not[bool]$value.ready){throw "Installed lifecycle script did not report ready: $Script"}
    return $value
}
function Invoke-FinalRuntimeValidation{
    $params=@{ManifestPath=$runtimeManifestPath;InstallationRoot=$InstallationRoot;WheelPath=$WheelPath;Json=$true}
    if($Offline){$params.Offline=$true}
    Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-vllm.ps1') -Parameters $params
}
function Get-InstallStateValue{
    param($FinalResult)
    $pythonReceipt=Read-JsonFile $pythonReceiptPath;$uvReceipt=Read-JsonFile $uvReceiptPath;$runtimeReceipt=Read-JsonFile $runtimeReceiptPath
    if($null-eq$pythonReceipt-or$null-eq$uvReceipt-or$null-eq$runtimeReceipt){throw 'Cannot commit install state because one or more required receipts are missing.'}
    $now=(Get-Date).ToString('o')
    [ordered]@{
        schema_version=1;component='install-state';release=[string]$release.release;platform=[string]$release.platform;ready=$true;generation_id=[guid]::NewGuid().ToString('D')
        install_root=$InstallationRoot;models_root=$ModelsRoot;release_manifest=(Join-Path $InstallationRoot $releaseRelative);release_manifest_sha256=[string]$releaseManifestIdentity.sha256
        upstream=[ordered]@{repository=[string]$release.upstream.repository;tag=[string]$release.upstream.tag;commit=[string]$release.upstream.commit}
        windows_patchset=[ordered]@{implementation_commit=[string]$release.windows_patchset.implementation_commit;tree=[string]$release.windows_patchset.tree;patch_sha256=[string]$release.windows_patchset.patch_sha256}
        wheel=[ordered]@{filename=[string]$release.wheel.filename;version=[string]$release.wheel.version;size_bytes=[int64]$release.wheel.size_bytes;sha256=[string]$release.wheel.sha256}
        python=[ordered]@{version=[string]$pythonReceipt.version;root=[string]$pythonReceipt.root;python=[string]$pythonReceipt.python;archive_sha256=[string]$pythonReceipt.archive_sha256;receipt=$pythonReceiptPath;receipt_sha256=(Get-FileHash $pythonReceiptPath -Algorithm SHA256).Hash}
        uv=[ordered]@{version=[string]$uvReceipt.version;root=[string]$uvReceipt.root;uv=[string]$uvReceipt.uv;archive_sha256=[string]$uvReceipt.archive_sha256;receipt=$uvReceiptPath;receipt_sha256=(Get-FileHash $uvReceiptPath -Algorithm SHA256).Hash}
        runtime=[ordered]@{root=$runtimeRoot;python=[string]$FinalResult.python;package_count=[int]$FinalResult.package_count;vllm_version=[string]$FinalResult.vllm_version;dependency_receipt=$dependencyReceiptPath;dependency_receipt_sha256=(Get-FileHash $dependencyReceiptPath -Algorithm SHA256).Hash;final_receipt=$runtimeReceiptPath;final_receipt_sha256=(Get-FileHash $runtimeReceiptPath -Algorithm SHA256).Hash;lock_sha256=[string]$FinalResult.lock_sha256;wheel_sha256=[string]$FinalResult.wheel_sha256}
        distribution_files=@(Get-ExpectedDistributionState);managed_paths=@($release.managed_paths);installed_at=$now;updated_at=$now
    }
}
$result=$null
Enter-InstallerLock
try{
    $existingState=Read-JsonFile $statePath
    if(Test-Path -LiteralPath $statePath){
        if($null-eq$existingState-or-not(Test-InstallState -State $existingState)){throw "Install state exists but is malformed or contradictory: $statePath"}
        $final=Invoke-FinalRuntimeValidation
        $result=[ordered]@{schema_version=1;component='install';release=[string]$release.release;ready=$true;idempotent=$true;generation_id=[string]$existingState.generation_id;install_root=$InstallationRoot;models_root=$ModelsRoot;runtime_root=[string]$final.root;vllm_version=[string]$final.vllm_version;package_count=[int]$final.package_count;install_state=$statePath}
    }else{
        Install-DistributionPayload
        if(Test-Path -LiteralPath $statePath){throw "Install state appeared unexpectedly during distribution materialization: $statePath"}
        $defaultModels=Get-VllmNormalizedPath (Join-Path $InstallationRoot 'models')
        if((Get-VllmNormalizedPath $ModelsRoot).Equals($defaultModels,[StringComparison]::OrdinalIgnoreCase)){
            [void][IO.Directory]::CreateDirectory($ModelsRoot)
            $ModelsRoot=Assert-VllmSafeModelsRoot -InstallationRoot $InstallationRoot -ModelsRoot $ModelsRoot
        }
        $runtimeReceiptExists=Test-Path -LiteralPath $runtimeReceiptPath -PathType Leaf
        $dependencyReceiptExists=Test-Path -LiteralPath $dependencyReceiptPath -PathType Leaf
        $venvReceiptExists=Test-Path -LiteralPath $venvReceiptPath -PathType Leaf
        $pythonReady=Test-PythonLayer
        $uvReady=Test-UvLayer
        if(($runtimeReceiptExists-or$dependencyReceiptExists-or$venvReceiptExists)-and(-not$pythonReady-or-not$uvReady)){throw 'Downstream runtime receipts exist but managed Python/uv provenance is missing or invalid.'}
        if($runtimeReceiptExists){
            $final=Invoke-FinalRuntimeValidation
        }elseif($dependencyReceiptExists){
            $final=Invoke-FinalRuntimeValidation
        }elseif($venvReceiptExists){
            $depParams=@{ManifestPath=$dependencyManifestPath;InstallationRoot=$InstallationRoot;Json=$true}
            if($Offline){$depParams.Offline=$true}
            [void](Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-dependencies.ps1') -Parameters $depParams)
            $final=Invoke-FinalRuntimeValidation
        }else{
            if(Test-Path -LiteralPath $runtimeRoot){throw 'Managed runtime venv exists without a venv bootstrap receipt. Refusing to infer ownership or overwrite it.'}
            if(-not$pythonReady){
                if($Offline-and[string]::IsNullOrWhiteSpace($PythonArchivePath)){throw 'Offline install requires -PythonArchivePath when managed Python is not already present.'}
                $pp=@{ManifestPath=$pythonManifestPath;InstallationRoot=$InstallationRoot;Json=$true}
                if(-not[string]::IsNullOrWhiteSpace($PythonArchivePath)){$pp.ArchivePath=$PythonArchivePath}
                [void](Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-python.ps1') -Parameters $pp)
            }
            if(-not$uvReady){
                if($Offline-and[string]::IsNullOrWhiteSpace($UvArchivePath)){throw 'Offline install requires -UvArchivePath when managed uv is not already present.'}
                $up=@{ManifestPath=$uvManifestPath;InstallationRoot=$InstallationRoot;Json=$true}
                if(-not[string]::IsNullOrWhiteSpace($UvArchivePath)){$up.ArchivePath=$UvArchivePath}
                [void](Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-uv.ps1') -Parameters $up)
            }
            [void](Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-venv.ps1') -Parameters @{ManifestPath=$venvManifestPath;InstallationRoot=$InstallationRoot;Json=$true})
            $depParams=@{ManifestPath=$dependencyManifestPath;InstallationRoot=$InstallationRoot;Json=$true}
            if($Offline){$depParams.Offline=$true}
            [void](Invoke-InstalledLayer -Script (Join-Path $InstallationRoot 'bootstrap-dependencies.ps1') -Parameters $depParams)
            $final=Invoke-FinalRuntimeValidation
        }
        if($null-eq$final-or-not[bool]$final.ready){throw 'Final vLLM runtime validation did not complete.'}
        $stateValue=Get-InstallStateValue -FinalResult $final
        Write-AtomicJson -Path $statePath -Value $stateValue
        $committed=Read-JsonFile $statePath
        if(-not(Test-InstallState -State $committed)){throw 'Committed install state failed validation.'}
        $result=[ordered]@{schema_version=1;component='install';release=[string]$release.release;ready=$true;idempotent=$false;generation_id=[string]$committed.generation_id;install_root=$InstallationRoot;models_root=$ModelsRoot;runtime_root=[string]$final.root;vllm_version=[string]$final.vllm_version;package_count=[int]$final.package_count;install_state=$statePath}
    }
}finally{
    try{Invoke-DistributionStagingCleanup}catch{Write-Warning "Failed to clean installer staging safely: $($_.Exception.Message)"}
    Exit-InstallerLock
}
if($null-eq$result-or-not[bool]$result.ready){throw 'Top-level installation did not complete.'}
if($Json){[pscustomobject]$result|ConvertTo-Json -Depth 8}else{Write-Host "vLLM Windows Native installed: $($result.install_root)";Write-Host "Runtime: $($result.runtime_root)";Write-Host "Version: $($result.vllm_version)";Write-Host "State:   $($result.install_state)";Write-Host 'INSTALL_READY'}
