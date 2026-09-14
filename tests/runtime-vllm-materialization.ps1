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
$bootstrapPython=Join-Path $repoRoot 'bootstrap-python.ps1'
$bootstrapUv=Join-Path $repoRoot 'bootstrap-uv.ps1'
$bootstrapVenv=Join-Path $repoRoot 'bootstrap-venv.ps1'
$bootstrapDependencies=Join-Path $repoRoot 'bootstrap-dependencies.ps1'
$bootstrapVllm=Join-Path $repoRoot 'bootstrap-vllm.ps1'
$dependencyManifest=Join-Path $repoRoot 'manifests\runtime\dependencies-v0.27.1-windows-x86_64.json'
$finalManifest=Join-Path $repoRoot 'manifests\runtime\vllm-runtime-v0.27.1-windows-x86_64.json'
$goodLock=Join-Path $PSScriptRoot 'fixtures\runtime-dependencies-colorama.lock.txt'
foreach($p in @($PythonArchivePath,$UvArchivePath,$bootstrapVllm,$dependencyManifest,$finalManifest,$goodLock)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Fixture or prerequisite missing: $p"}}
function Test-ExpectedFailure {
    param([scriptblock]$Action,[string]$Name,[string]$ExpectedMessage)
    try{& $Action;throw "Expected failure did not occur: $Name"}catch{$m=$_.Exception.Message;if($m -eq "Expected failure did not occur: $Name"){throw};if($m.IndexOf($ExpectedMessage,[StringComparison]::OrdinalIgnoreCase)-lt 0){throw "Expected '$Name' to contain '$ExpectedMessage', got: $m"};Write-Host "REJECT $Name :: $m"}
}
function Get-TestEnvironmentSnapshot {$s=@{};foreach($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()){$s[[string]$e.Key]=[string]$e.Value};return $s}
function Assert-EnvironmentEqual {param([hashtable]$Before,[hashtable]$After);$keys=@($Before.Keys+$After.Keys|Sort-Object -Unique);$d=@($keys|Where-Object{(-not$Before.ContainsKey($_))-or(-not$After.ContainsKey($_))-or$Before[$_] -ne $After[$_]});if($d.Count){throw "Process environment changed: $($d -join ', ')"}}function Write-DependencyFixtureManifest {
    param([string]$Path)
    $m=Get-Content -LiteralPath $dependencyManifest -Raw|ConvertFrom-Json
    $m.accepted_packages=[pscustomobject][ordered]@{colorama='0.4.6'};$m.allowed_extra_distributions=@('vllm');$m.accepted_binary_artifacts=[pscustomobject]@{}
    $i=Get-Item -LiteralPath $goodLock;$m.lock.path=[IO.Path]::GetFullPath($goodLock);$m.lock.size_bytes=$i.Length;$m.lock.sha256=(Get-FileHash $goodLock -Algorithm SHA256).Hash;$m.lock.package_count=1;$m.note='Regression fixture: exact colorama predecessor state.'
    [IO.File]::WriteAllText($Path,($m|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Add-ZipText {param($Zip,[string]$Name,[string]$Text);$e=$Zip.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal);$w=[IO.StreamWriter]::new($e.Open(),[Text.UTF8Encoding]::new($false));try{$w.Write($Text)}finally{$w.Dispose()}}
function Write-TestWheel {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if(Test-Path $Path){Remove-Item $Path -Force}
    $z=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        Add-ZipText $z 'vllm/__init__.py' "__version__ = '0.0.1'`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/METADATA' "Metadata-Version: 2.1`nName: vllm`nVersion: 0.0.1`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/WHEEL' "Wheel-Version: 1.0`nGenerator: vllm-windows-native-test`nRoot-Is-Purelib: true`nTag: py3-none-any`n"
        Add-ZipText $z 'vllm-0.0.1.dist-info/RECORD' "vllm/__init__.py,,`nvllm-0.0.1.dist-info/METADATA,,`nvllm-0.0.1.dist-info/WHEEL,,`nvllm-0.0.1.dist-info/RECORD,,`n"
    }finally{$z.Dispose()}
}
function Write-FinalFixtureManifest {
    param([string]$Path,[string]$PredManifest,[string]$Wheel,[string]$PackageMap,[string]$InputFile)
    $m=Get-Content -LiteralPath $finalManifest -Raw|ConvertFrom-Json
    $m.predecessor.manifest=[IO.Path]::GetFullPath($PredManifest);$m.predecessor.required_package_count=1
    foreach($pair in @(@($m.input,$InputFile),@($m.lock,$goodLock),@($m.accepted_packages,$PackageMap))){$i=Get-Item $pair[1];$pair[0].path=[IO.Path]::GetFullPath($pair[1]);$pair[0].size_bytes=$i.Length;$pair[0].sha256=(Get-FileHash $pair[1] -Algorithm SHA256).Hash}
    $m.lock.package_count=1;$m.accepted_packages.package_count=1
    $wi=Get-Item $Wheel;$m.project_wheel.distribution='vllm';$m.project_wheel.version='0.0.1';$m.project_wheel.filename=$wi.Name;$m.project_wheel.size_bytes=$wi.Length;$m.project_wheel.sha256=(Get-FileHash $Wheel -Algorithm SHA256).Hash;$m.project_wheel.python_tag='py3';$m.project_wheel.abi_tag='none';$m.project_wheel.platform_tag='any';$m.project_wheel.native_extension_count=0;$m.project_wheel.native_extensions=@();$m.materialization.final_package_count=2
    [IO.File]::WriteAllText($Path,($m|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}function Assert-FinalReady {
    param([string]$Root)
    $py=Join-Path $Root 'Scripts\python.exe';$rows=@(& $py -I -c "import importlib.metadata as m; print('\n'.join(sorted((d.metadata['Name'].lower().replace('_','-')+'=='+d.version) for d in m.distributions() if d.metadata.get('Name'))))")
    if($LASTEXITCODE -ne 0 -or $rows.Count -ne 2 -or $rows[0] -ne 'colorama==0.4.6' -or $rows[1] -ne 'vllm==0.0.1'){throw "Unexpected final distributions: $($rows -join ', ')"}
    if(Test-Path -LiteralPath (Join-Path $Root 'Lib\site-packages\pip') -PathType Container){throw 'pip was unexpectedly installed.'}
}
function Assert-NoArtifacts {param([string]$Root);foreach($p in @('runtime\.venv-vllm-staging','runtime\.venv-vllm-backup','forensic\runtime-vllm-transaction-v0.27.1.json')){if(Test-Path -LiteralPath (Join-Path $Root $p)){throw "vLLM transaction artifact remained: $p"}}}
function Write-InterruptedState {
    param([string]$Root,[string]$ManifestPath,[string]$TransactionId,[ValidateSet('materializing','prepared')][string]$Phase)
    $m=Get-Content $ManifestPath -Raw|ConvertFrom-Json;$state=[ordered]@{schema_version=1;component='vllm-runtime-transaction';milestone=[string]$m.milestone;platform=[string]$m.platform;transaction_id=$TransactionId;phase=$Phase;target=Join-Path $Root 'runtime\venv';staging=Join-Path $Root 'runtime\.venv-vllm-staging';backup=Join-Path $Root 'runtime\.venv-vllm-backup';transaction_receipt=Join-Path $Root 'forensic\runtime-vllm-transaction-v0.27.1.json';final_receipt=Join-Path $Root 'forensic\runtime-vllm-v0.27.1.json';predecessor_receipt=Join-Path $Root 'forensic\runtime-dependencies-v0.27.1.json';manifest=[IO.Path]::GetFullPath($ManifestPath);lock_sha256=[string]$m.lock.sha256;wheel_sha256=[string]$m.project_wheel.sha256}
    [IO.File]::WriteAllText([string]$state.transaction_receipt,($state|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false));return [string]$state.transaction_receipt
}
$outer=Get-TestEnvironmentSnapshot
if([string]::IsNullOrWhiteSpace($ScratchRoot)){$scratch=[IO.Path]::GetTempPath()}else{$scratch=[IO.Path]::GetFullPath($ScratchRoot);[void][IO.Directory]::CreateDirectory($scratch)}
$base=Join-Path $scratch ('vllm-runtime-final-test-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($base);$root=Join-Path $base 'root';$pred=Join-Path $base 'pred.json';$final=Join-Path $base 'final.json';$inputFile=Join-Path $base 'runtime.in';$pkg=Join-Path $base 'packages.json';$wheelDir=Join-Path $base 'wheel';[void][IO.Directory]::CreateDirectory($wheelDir);$wheel=Join-Path $wheelDir 'vllm-0.0.1-py3-none-any.whl'
    [IO.File]::WriteAllText($inputFile,"colorama==0.4.6`n",[Text.UTF8Encoding]::new($false))
    $pkgJson=([ordered]@{colorama='0.4.6'}|ConvertTo-Json)
    [IO.File]::WriteAllText($pkg,($pkgJson+"`n"),[Text.UTF8Encoding]::new($false))
    Write-TestWheel -Path $wheel
    Write-DependencyFixtureManifest -Path $pred
    Write-FinalFixtureManifest -Path $final -PredManifest $pred -Wheel $wheel -PackageMap $pkg -InputFile $inputFile
    & $bootstrapPython -InstallationRoot $root -ArchivePath $PythonArchivePath -Json|Out-Null;& $bootstrapUv -InstallationRoot $root -ArchivePath $UvArchivePath -Json|Out-Null;& $bootstrapVenv -InstallationRoot $root -Json|Out-Null;& $bootstrapDependencies -ManifestPath $pred -InstallationRoot $root -Json|Out-Null
    Write-Host 'VLLM_PREDECESSOR_READY'
    $env:UV_INDEX_URL='https://invalid.example.test/simple';$env:UV_CACHE_DIR='C:\BAD-CACHE';$env:PYTHONPATH='C:\BAD-PYTHONPATH';$env:VIRTUAL_ENV='C:\OLD-VENV';$before=Get-TestEnvironmentSnapshot
    $r=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json;$after=Get-TestEnvironmentSnapshot;Assert-EnvironmentEqual -Before $before -After $after
    if(-not$r.ready -or $r.idempotent -or $r.package_count -ne 2 -or $r.vllm_version -ne '0.0.1'){throw 'Final happy-path receipt mismatch.'};$target=[string]$r.root;$receipt=[string]$r.receipt;Assert-FinalReady -Root $target;Assert-NoArtifacts -Root $root;Write-Host 'VLLM_HAPPY_PATH_AND_ENV_RESTORE_OK'
    $receiptRaw=Get-Content $receipt -Raw;$marker=Join-Path $target 'vllm-idempotence.marker';[IO.File]::WriteAllText($marker,'KEEP',[Text.Encoding]::ASCII)
    $idem=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json;if(-not$idem.idempotent){throw 'Final runtime rerun was not idempotent.'};if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Idempotence marker changed.'};if((Get-Content $receipt -Raw) -ne $receiptRaw){throw 'Idempotent rerun rewrote final receipt.'};Write-Host 'VLLM_IDEMPOTENCE_OK'
    $badDir=Join-Path $base 'bad-wheel';[void][IO.Directory]::CreateDirectory($badDir);$badWheel=Join-Path $badDir (Split-Path $wheel -Leaf);Copy-Item $wheel $badWheel;[IO.File]::AppendAllText($badWheel,'X',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action {& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $badWheel -Json|Out-Null} -Name 'wheel-hash-mismatch' -ExpectedMessage 'wheel size mismatch';if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Bad wheel validation mutated runtime.'};Write-Host 'VLLM_BAD_WHEEL_REJECTED_PRE_MUTATION'
    $o=$receiptRaw|ConvertFrom-Json;$o.vllm_version='9.9.9';[IO.File]::WriteAllText($receipt,($o|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));Test-ExpectedFailure -Action {& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json|Out-Null} -Name 'receipt-drift' -ExpectedMessage 'receipt exists but runtime does not match';[IO.File]::WriteAllText($receipt,$receiptRaw,[Text.UTF8Encoding]::new($false));Write-Host 'VLLM_RECEIPT_DRIFT_REJECTED'
    $fake=Join-Path $target 'Lib\site-packages\surprise_package-1.0.dist-info';[void][IO.Directory]::CreateDirectory($fake);[IO.File]::WriteAllText((Join-Path $fake 'METADATA'),"Metadata-Version: 2.1`nName: surprise-package`nVersion: 1.0`n",[Text.UTF8Encoding]::new($false));Test-ExpectedFailure -Action {& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json|Out-Null} -Name 'unexpected-final-distribution' -ExpectedMessage 'receipt exists but runtime does not match';Remove-Item $fake -Recurse -Force;Assert-FinalReady -Root $target;Write-Host 'VLLM_FAIL_CLOSED_DRIFT_OK'
    $staging=Join-Path $root 'runtime\.venv-vllm-staging'
    $backup=Join-Path $root 'runtime\.venv-vllm-backup'
    [void][IO.Directory]::CreateDirectory($staging)
    [IO.File]::WriteAllText((Join-Path $staging 'partial.marker'),'PARTIAL',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedState -Root $root -ManifestPath $final -TransactionId $tx -Phase 'materializing')
    $recovered=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Materializing-state recovery failed.'}
    if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Runtime marker changed during materializing recovery.'}
    Assert-NoArtifacts -Root $root
    Write-Host 'VLLM_INTERRUPTED_MATERIALIZING_RECOVERY_OK'

    Move-Item -LiteralPath $target -Destination $backup
    [void][IO.Directory]::CreateDirectory($staging)
    [IO.File]::WriteAllText((Join-Path $staging 'prepared.marker'),'PREPARED',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedState -Root $root -ManifestPath $final -TransactionId $tx -Phase 'prepared')
    $recovered=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Pre-activation recovery failed.'}
    if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Runtime marker changed during pre-activation recovery.'}
    Assert-NoArtifacts -Root $root
    Write-Host 'VLLM_INTERRUPTED_PRE_ACTIVATION_RECOVERY_OK'

    Move-Item -LiteralPath $target -Destination $backup
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'candidate.marker'),'CANDIDATE',[Text.Encoding]::ASCII)
    $tx=[guid]::NewGuid().ToString('D')
    [void](Write-InterruptedState -Root $root -ManifestPath $final -TransactionId $tx -Phase 'prepared')
    $recovered=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'rolled-back'){throw 'Post-activation recovery failed.'}
    if(Test-Path -LiteralPath (Join-Path $target 'candidate.marker')){throw 'Interrupted candidate survived rollback.'}
    if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Runtime marker changed during post-activation recovery.'}
    Assert-NoArtifacts -Root $root
    Write-Host 'VLLM_INTERRUPTED_POST_ACTIVATION_RECOVERY_OK'

    [void][IO.Directory]::CreateDirectory($backup)
    [IO.File]::WriteAllText((Join-Path $backup 'stale-backup.marker'),'STALE',[Text.Encoding]::ASCII)
    $committedTx=[string](($receiptRaw|ConvertFrom-Json).transaction_id)
    [void](Write-InterruptedState -Root $root -ManifestPath $final -TransactionId $committedTx -Phase 'prepared')
    $recovered=(& $bootstrapVllm -ManifestPath $final -InstallationRoot $root -WheelPath $wheel -Json)|ConvertFrom-Json
    if(-not $recovered.idempotent -or $recovered.recovery -ne 'committed-cleanup'){throw 'Committed-state cleanup recovery failed.'}
    if((Get-Content $marker -Raw).Trim() -ne 'KEEP'){throw 'Runtime marker changed during committed cleanup.'}
    Assert-NoArtifacts -Root $root
    Write-Host 'VLLM_INTERRUPTED_COMMITTED_CLEANUP_OK'

    Write-Host 'VLLM_RUNTIME_MATERIALIZATION_REGRESSION_OK'
} finally {
    try{Restore-VllmProcessEnvironment -Snapshot $outer}catch{Write-Warning "Failed to restore outer test environment: $($_.Exception.Message)"}
    if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}
}
