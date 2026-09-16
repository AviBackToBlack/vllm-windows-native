[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PythonArchivePath,
    [Parameter(Mandatory)][string]$UvArchivePath,
    [string]$ScratchRoot=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
$goodLock=Join-Path $PSScriptRoot 'fixtures\runtime-dependencies-colorama.lock.txt'
$canonicalDependencyManifest=Join-Path $repoRoot 'manifests\runtime\dependencies-v0.27.1-windows-x86_64.json'
$canonicalFinalManifest=Join-Path $repoRoot 'manifests\runtime\vllm-runtime-v0.27.1-windows-x86_64.json'
foreach($p in @($PythonArchivePath,$UvArchivePath,$goodLock,$canonicalDependencyManifest,$canonicalFinalManifest)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Installer fixture prerequisite missing: $p"}}
function Test-ExpectedFailure{param([scriptblock]$Action,[string]$Name,[string]$ExpectedMessage);try{& $Action;throw "Expected failure did not occur: $Name"}catch{$m=$_.Exception.Message;if($m-eq"Expected failure did not occur: $Name"){throw};if($m.IndexOf($ExpectedMessage,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Expected '$Name' to contain '$ExpectedMessage', got: $m"};Write-Host "REJECT $Name :: $m"}}
function Add-ZipText{param($Zip,[string]$Name,[string]$Text);$e=$Zip.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal);$w=[IO.StreamWriter]::new($e.Open(),[Text.UTF8Encoding]::new($false));try{$w.Write($Text)}finally{$w.Dispose()}}
function Write-TestWheel{
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if(Test-Path $Path){Remove-Item $Path -Force}
    $z=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        Add-ZipText $z 'vllm/__init__.py' "__version__ = '0.0.1'`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/METADATA' "Metadata-Version: 2.1`nName: vllm`nVersion: 0.0.1`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/WHEEL' "Wheel-Version: 1.0`nGenerator: installer-test`nRoot-Is-Purelib: true`nTag: py3-none-any`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/RECORD' "vllm/__init__.py,,`nvllm-0.0.1.dist-info/METADATA,,`nvllm-0.0.1.dist-info/WHEEL,,`nvllm-0.0.1.dist-info/RECORD,,`n"
    }finally{$z.Dispose()}
}
function Write-Utf8Json{param([string]$Path,$Value);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))}
function Copy-RepoFile{param([string]$SourceRelative,[string]$SourceRoot);$src=Join-Path $repoRoot $SourceRelative;$dst=Join-Path $SourceRoot $SourceRelative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst));Copy-Item -LiteralPath $src -Destination $dst}
function Invoke-MiniReleaseFixtureCreation{
    param([string]$SourceRoot,[string]$WheelPath)
    $copied=@(
        'install.ps1','update.ps1','uninstall.ps1','start.ps1',
        'bootstrap-python.ps1','bootstrap-uv.ps1','bootstrap-venv.ps1','bootstrap-dependencies.ps1','bootstrap-vllm.ps1',
        'scripts/common.ps1','scripts/lifecycle.ps1','scripts/env.ps1','config.example.psd1','LICENSE','THIRD_PARTY_NOTICES.md',
        'manifests/bootstrap/cpython-3.13.15-windows-x86_64.json','manifests/bootstrap/uv-0.12.13-windows-x86_64.json','manifests/bootstrap/venv-v0.27.1-windows-x86_64.json'
    )
    foreach($rel in $copied){Copy-RepoFile -SourceRelative $rel -SourceRoot $SourceRoot}
    $runtimeIn=Join-Path $SourceRoot 'requirements\runtime-v0.27.1.in';$runtimeLock=Join-Path $SourceRoot 'requirements\runtime-v0.27.1.lock.txt'
    $finalIn=Join-Path $SourceRoot 'requirements\vllm-runtime-v0.27.1.in';$finalLock=Join-Path $SourceRoot 'requirements\vllm-runtime-v0.27.1.lock.txt'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runtimeIn))
    [IO.File]::WriteAllText($runtimeIn,"colorama==0.4.6`n",[Text.UTF8Encoding]::new($false));Copy-Item $goodLock $runtimeLock
    [IO.File]::WriteAllText($finalIn,"colorama==0.4.6`n",[Text.UTF8Encoding]::new($false));Copy-Item $goodLock $finalLock
    $packageMap=Join-Path $SourceRoot 'manifests\runtime\vllm-runtime-packages-v0.27.1-windows-x86_64.json'
    Write-Utf8Json -Path $packageMap -Value ([ordered]@{colorama='0.4.6'})
    $depPath=Join-Path $SourceRoot 'manifests\runtime\dependencies-v0.27.1-windows-x86_64.json'
    $dep=Get-Content $canonicalDependencyManifest -Raw|ConvertFrom-Json
    $dep.accepted_packages=[pscustomobject][ordered]@{colorama='0.4.6'};$dep.allowed_extra_distributions=@('vllm');$dep.accepted_binary_artifacts=[pscustomobject]@{}
    $li=Get-Item $runtimeLock;$dep.lock.path='requirements/runtime-v0.27.1.lock.txt';$dep.lock.size_bytes=$li.Length;$dep.lock.sha256=(Get-FileHash $runtimeLock -Algorithm SHA256).Hash;$dep.lock.package_count=1
    Write-Utf8Json -Path $depPath -Value $dep
    $finalPath=Join-Path $SourceRoot 'manifests\runtime\vllm-runtime-v0.27.1-windows-x86_64.json'
    $final=Get-Content $canonicalFinalManifest -Raw|ConvertFrom-Json
    $final.predecessor.manifest='manifests/runtime/dependencies-v0.27.1-windows-x86_64.json';$final.predecessor.required_package_count=1
    $fi=Get-Item $finalIn;$final.input.path='requirements/vllm-runtime-v0.27.1.in';$final.input.size_bytes=$fi.Length;$final.input.sha256=(Get-FileHash $finalIn -Algorithm SHA256).Hash
    $fl=Get-Item $finalLock;$final.lock.path='requirements/vllm-runtime-v0.27.1.lock.txt';$final.lock.size_bytes=$fl.Length;$final.lock.sha256=(Get-FileHash $finalLock -Algorithm SHA256).Hash;$final.lock.package_count=1
    $pm=Get-Item $packageMap;$final.accepted_packages.path='manifests/runtime/vllm-runtime-packages-v0.27.1-windows-x86_64.json';$final.accepted_packages.size_bytes=$pm.Length;$final.accepted_packages.sha256=(Get-FileHash $packageMap -Algorithm SHA256).Hash;$final.accepted_packages.package_count=1
    $wi=Get-Item $WheelPath;$final.project_wheel.distribution='vllm';$final.project_wheel.version='0.0.1';$final.project_wheel.filename=$wi.Name;$final.project_wheel.size_bytes=$wi.Length;$final.project_wheel.sha256=(Get-FileHash $WheelPath -Algorithm SHA256).Hash;$final.project_wheel.python_tag='py3';$final.project_wheel.abi_tag='none';$final.project_wheel.platform_tag='any';$final.project_wheel.native_extension_count=0;$final.project_wheel.native_extensions=@();$final.materialization.final_package_count=2
    Write-Utf8Json -Path $finalPath -Value $final
    $generated=@(
        'manifests/runtime/dependencies-v0.27.1-windows-x86_64.json','manifests/runtime/vllm-runtime-packages-v0.27.1-windows-x86_64.json','manifests/runtime/vllm-runtime-v0.27.1-windows-x86_64.json',
        'requirements/runtime-v0.27.1.in','requirements/runtime-v0.27.1.lock.txt','requirements/vllm-runtime-v0.27.1.in','requirements/vllm-runtime-v0.27.1.lock.txt'
    )
    $files=New-Object System.Collections.Generic.List[object]
    foreach($rel in @($copied+$generated)|Sort-Object){$f=Get-Item (Join-Path $SourceRoot $rel);$files.Add([pscustomobject][ordered]@{path=$rel.Replace('\','/');size_bytes=[int64]$f.Length;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash})}
    $release=[ordered]@{
        schema_version=1;component='runtime-release';release='test-v0.27.1';platform='windows-x86_64';self_path='manifests/release/v0.27.1-windows-x86_64.json'
        upstream=[ordered]@{repository='https://github.com/vllm-project/vllm.git';tag='v0.27.1';commit='6e448d0ea9bf3d88d898b65449ca6dc2aec170ac'}
        windows_patchset=[ordered]@{implementation_commit='fixture';tree='115fa3e10d4b5a45c3e647cb343680a1fc743d18';patch_sha256='08416EBB43632A0AC485839644A98E875A4AD9EBC49BE193DA25AB804AE6A272'}
        wheel=[ordered]@{filename=$wi.Name;version='0.0.1';size_bytes=[int64]$wi.Length;sha256=(Get-FileHash $WheelPath -Algorithm SHA256).Hash}
        orchestration=[ordered]@{
            python_manifest='manifests/bootstrap/cpython-3.13.15-windows-x86_64.json';uv_manifest='manifests/bootstrap/uv-0.12.13-windows-x86_64.json';venv_manifest='manifests/bootstrap/venv-v0.27.1-windows-x86_64.json'
            dependency_manifest='manifests/runtime/dependencies-v0.27.1-windows-x86_64.json';runtime_manifest='manifests/runtime/vllm-runtime-v0.27.1-windows-x86_64.json'
            python_receipt='forensic/python-bootstrap-3.13.15.json';uv_receipt='forensic/uv-bootstrap-0.12.13.json';venv_receipt='forensic/venv-bootstrap-v0.27.1.json';dependency_receipt='forensic/runtime-dependencies-v0.27.1.json';runtime_receipt='forensic/runtime-vllm-v0.27.1.json';runtime_root='runtime/venv'
        }
        managed_paths=@('python/managed/cpython-3.13.15-windows-x86_64-none','tools/uv/0.12.13','runtime/venv','cache/uv','forensic/python-bootstrap-3.13.15.json','forensic/uv-bootstrap-0.12.13.json','forensic/venv-bootstrap-v0.27.1.json','forensic/runtime-dependencies-v0.27.1.json','forensic/runtime-vllm-v0.27.1.json','state/install-state.json','state/install-orchestrator.lock','.vllm-operation.lock')
        files=$files.ToArray()
    }
    $releasePath=Join-Path $SourceRoot 'manifests\release\v0.27.1-windows-x86_64.json';Write-Utf8Json -Path $releasePath -Value $release
    return $releasePath
}
function Assert-FinalReady{param([string]$Root);$py=Join-Path $Root 'runtime\venv\Scripts\python.exe';$rows=@(& $py -I -c "import importlib.metadata as m; print('\n'.join(sorted((d.metadata['Name'].lower().replace('_','-')+'=='+d.version) for d in m.distributions() if d.metadata.get('Name'))))");if($LASTEXITCODE-ne0-or$rows.Count-ne2-or$rows[0]-ne'colorama==0.4.6'-or$rows[1]-ne'vllm==0.0.1'){throw "Unexpected installed distributions: $($rows -join ', ')"}}
$outer=@{};foreach($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$outer[[string]$e.Key]=[string]$e.Value}
if([string]::IsNullOrWhiteSpace($ScratchRoot)){$scratch=[IO.Path]::GetTempPath()}else{$scratch=[IO.Path]::GetFullPath($ScratchRoot);[void][IO.Directory]::CreateDirectory($scratch)}
$base=Join-Path $scratch ('vllm-install-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($base)
    $source=Join-Path $base 'source';$root=Join-Path $base 'installed';$wheelDir=Join-Path $base 'wheel';[void][IO.Directory]::CreateDirectory($wheelDir)
    $wheel=Join-Path $wheelDir 'vllm-0.0.1-py3-none-any.whl';Write-TestWheel $wheel;[void](Invoke-MiniReleaseFixtureCreation -SourceRoot $source -WheelPath $wheel)
    $installer=Join-Path $source 'install.ps1'
    $before=@{};foreach($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$before[[string]$e.Key]=[string]$e.Value}
    $r=(& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json)|ConvertFrom-Json
    $after=@{};foreach($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$after[[string]$e.Key]=[string]$e.Value}
    $keys=@($before.Keys+$after.Keys|Sort-Object -Unique);$envDiff=@($keys|Where-Object{(-not$before.ContainsKey($_))-or(-not$after.ContainsKey($_))-or$before[$_] -ne $after[$_]});if($envDiff.Count){throw "Installer changed caller environment: $($envDiff -join ', ')"}
    if(-not$r.ready-or$r.idempotent-or$r.package_count-ne2-or$r.vllm_version-ne'0.0.1'){throw 'Fresh installer result mismatch.'}
    $statePath=Join-Path $root 'state\install-state.json';if(-not(Test-Path $statePath -PathType Leaf)){throw 'Install state missing.'};$stateRaw=Get-Content $statePath -Raw;$state=$stateRaw|ConvertFrom-Json
    if(-not(Test-Path -LiteralPath (Join-Path $root 'models') -PathType Container)){throw 'Default models directory missing.'}
    if(Test-Path -LiteralPath (Join-Path $root 'work\install-distribution-staging')){throw 'Distribution staging survived successful install.'}
    Assert-FinalReady -Root $root
    foreach($receipt in 'python-bootstrap-3.13.15.json','uv-bootstrap-0.12.13.json','venv-bootstrap-v0.27.1.json','runtime-dependencies-v0.27.1.json','runtime-vllm-v0.27.1.json'){$rp=Join-Path $root ('forensic\'+$receipt);$j=Get-Content $rp -Raw|ConvertFrom-Json;if(-not([string]$j.manifest).StartsWith((Get-VllmNormalizedPath $root),[StringComparison]::OrdinalIgnoreCase)){throw "Receipt points outside installed distribution: $receipt -> $($j.manifest)"}}
    Write-Host 'INSTALL_FRESH_SELF_CONTAINED_OK'
    $marker=Join-Path $root 'runtime\venv\installer-idempotence.marker';[IO.File]::WriteAllText($marker,'KEEP',[Text.Encoding]::ASCII);$finalReceipt=Join-Path $root 'forensic\runtime-vllm-v0.27.1.json';$finalRaw=Get-Content $finalReceipt -Raw
    $idem=(& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json)|ConvertFrom-Json
    if(-not$idem.idempotent-or(Get-Content $marker -Raw).Trim()-ne'KEEP'-or(Get-Content $statePath -Raw)-ne$stateRaw-or(Get-Content $finalReceipt -Raw)-ne$finalRaw){throw 'Installer idempotence changed committed state/runtime.'}
    Write-Host 'INSTALL_IDEMPOTENCE_OK'
    $guardStateRaw=Get-Content $statePath -Raw
    $guardMarkerRaw=Get-Content $marker -Raw
    $guardStaging=Join-Path $root 'work\install-distribution-staging'
    [void][IO.Directory]::CreateDirectory($guardStaging)
    $guardSentinel=Join-Path $guardStaging 'pending-update-sentinel.txt'
    [IO.File]::WriteAllText($guardSentinel,'KEEP',[Text.Encoding]::ASCII)
    $updateJournal=Join-Path $root 'state\update-transaction.json'
    [IO.File]::WriteAllText($updateJournal,'{ malformed',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'installer-pending-update-journal' -ExpectedMessage 'Pending update maintenance state exists'
    if((Get-Content $statePath -Raw)-ne$guardStateRaw-or(Get-Content $marker -Raw)-ne$guardMarkerRaw-or-not(Test-Path $guardSentinel -PathType Leaf)-or(Get-Content $guardSentinel -Raw).Trim()-ne'KEEP'){throw 'Installer pending-update journal refusal mutated committed/staging state.'}
    Remove-Item $updateJournal -Force
    Write-Host 'INSTALL_PENDING_UPDATE_JOURNAL_GUARD_OK'
    $updateWorkspace=Join-Path $root 'work\update-transaction'
    [void][IO.Directory]::CreateDirectory($updateWorkspace)
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'installer-pending-update-workspace' -ExpectedMessage 'Pending update maintenance state exists'
    if((Get-Content $statePath -Raw)-ne$guardStateRaw-or(Get-Content $marker -Raw)-ne$guardMarkerRaw-or-not(Test-Path $guardSentinel -PathType Leaf)){throw 'Installer pending-update workspace refusal mutated committed/staging state.'}
    Remove-Item $updateWorkspace -Recurse -Force
    Remove-Item $guardStaging -Recurse -Force
    Write-Host 'INSTALL_PENDING_UPDATE_WORKSPACE_GUARD_OK'
    $tampered=$stateRaw|ConvertFrom-Json;$tampered.wheel.sha256='BAD';Write-Utf8Json -Path $statePath -Value $tampered
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'install-state-tamper' -ExpectedMessage 'malformed or contradictory'
    [IO.File]::WriteAllText($statePath,$stateRaw,[Text.UTF8Encoding]::new($false));Write-Host 'INSTALL_STATE_TAMPER_REJECTED'
    $installedStart=Join-Path $root 'start.ps1';$startRaw=Get-Content $installedStart -Raw;[IO.File]::AppendAllText($installedStart,"# drift`n",[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'distribution-drift' -ExpectedMessage 'malformed or contradictory'
    [IO.File]::WriteAllText($installedStart,$startRaw,[Text.UTF8Encoding]::new($false));Write-Host 'INSTALL_DISTRIBUTION_DRIFT_REJECTED'
    $lockPath=Join-Path $root 'state\install-orchestrator.lock';$held=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    try{Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'installer-lock-contention' -ExpectedMessage 'Another top-level install operation'}finally{$held.Dispose()}
    Write-Host 'INSTALL_LOCK_CONTENTION_OK'
    $oldGeneration=[string]$state.generation_id;Remove-Item $statePath -Force
    $pythonReceiptPath=Join-Path $root 'forensic\python-bootstrap-3.13.15.json';$pythonReceiptRaw=Get-Content $pythonReceiptPath -Raw;$pythonReceipt=$pythonReceiptRaw|ConvertFrom-Json;$pythonReceipt.archive_sha256='BAD';Write-Utf8Json -Path $pythonReceiptPath -Value $pythonReceipt
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'downstream-python-provenance-drift' -ExpectedMessage 'archive digest mismatch'
    [IO.File]::WriteAllText($pythonReceiptPath,$pythonReceiptRaw,[Text.UTF8Encoding]::new($false));Write-Host 'INSTALL_DOWNSTREAM_PROVENANCE_DRIFT_REJECTED'
    $recovered=(& $installer -InstallationRoot $root -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json)|ConvertFrom-Json
    if(-not$recovered.ready-or$recovered.idempotent){throw 'Install-state reconstruction did not report a new top-level commit.'}
    if((Get-Content $marker -Raw).Trim()-ne'KEEP'-or(Get-Content $finalReceipt -Raw)-ne$finalRaw){throw 'Install-state reconstruction rebuilt or mutated final runtime.'}
    $newState=Get-Content $statePath -Raw|ConvertFrom-Json;if([string]$newState.generation_id-eq$oldGeneration){throw 'Reconstructed install state reused the previous generation ID.'}
    Write-Host 'INSTALL_POST_RUNTIME_POWERLOSS_RECOVERY_OK'
    $sourceDrift=Join-Path $base 'source-drift';Copy-Item $source $sourceDrift -Recurse;[IO.File]::AppendAllText((Join-Path $sourceDrift 'start.ps1'),'# source drift',[Text.Encoding]::ASCII);$driftRoot=Join-Path $base 'drift-target'
    Test-ExpectedFailure -Action {& (Join-Path $sourceDrift 'install.ps1') -InstallationRoot $driftRoot -WheelPath $wheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'source-payload-drift' -ExpectedMessage 'source does not match manifest'
    if(Test-Path $driftRoot){throw 'Source-payload drift mutated a fresh target before rejection.'};Write-Host 'INSTALL_SOURCE_DRIFT_REJECTED_PRE_MUTATION'
    $badWheelDir=Join-Path $base 'bad-wheel';[void][IO.Directory]::CreateDirectory($badWheelDir);$badWheel=Join-Path $badWheelDir (Split-Path $wheel -Leaf);Copy-Item $wheel $badWheel;[IO.File]::AppendAllText($badWheel,'X',[Text.Encoding]::ASCII);$badRoot=Join-Path $base 'bad-wheel-target'
    Test-ExpectedFailure -Action {& $installer -InstallationRoot $badRoot -WheelPath $badWheel -PythonArchivePath $PythonArchivePath -UvArchivePath $UvArchivePath -Json|Out-Null} -Name 'bad-wheel' -ExpectedMessage 'wheel size mismatch'
    if(Test-Path $badRoot){throw 'Bad wheel mutated a fresh target before rejection.'};Write-Host 'INSTALL_BAD_WHEEL_REJECTED_PRE_MUTATION'
    Write-Host 'INSTALL_ORCHESTRATION_REGRESSION_OK'
}finally{
    try{Restore-VllmProcessEnvironment -Snapshot $outer}catch{Write-Warning "Failed to restore outer installer-test environment: $($_.Exception.Message)"}
    if(Test-Path $base){Remove-Item $base -Recurse -Force}
}
