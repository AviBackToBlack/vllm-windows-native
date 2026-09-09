[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/runtime/v0.27.1-rtx5090-sm120.json',
    [string] $PythonExe = $env:VLLM_BUILD_PYTHON,
    [string] $CudaHome = $env:CUDA_HOME,
    [string] $CuSolverRoot = $env:VLLM_CUSOLVER_ROOT,
    [string] $CuSolverManifestPath = 'manifests/bootstrap/cusolver-12.0.4.66-windows-x86_64.json',
    [string] $VcVars64 = '',
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\common.ps1')

$projectRoot = Get-ProjectRoot
$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
$manifest = Read-RuntimeManifest -ManifestPath $manifestResolved
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name,[ValidateSet('PASS','FAIL','WARN')][string]$Status,[string]$Expected='',[string]$Actual='',[string]$Hint='')
    $checks.Add([pscustomobject]@{name=$Name;status=$Status;expected=$Expected;actual=$Actual;hint=$Hint}) | Out-Null
}

function Resolve-Python {
    param([string]$Requested)
    $items = @()
    if ($Requested) { $items += $Requested }
    $items += (Join-Path $projectRoot '.venv\Scripts\python.exe')
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { $items += $cmd.Source }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($py) {
        try { $x = (& $py.Source -3.13 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1); if ($LASTEXITCODE -eq 0) { $items += $x } } catch {}
    }
    foreach ($x in ($items | Where-Object { $_ } | Select-Object -Unique)) {
        try { $p=[IO.Path]::GetFullPath($x); if(Test-Path -LiteralPath $p -PathType Leaf){return $p} } catch {}
    }
    return $null
}

function Resolve-Cuda {
    param([string]$Requested)
    $parts = ([string]$manifest.build.cuda_toolkit -split '\.')
    $items = @($Requested,$env:CUDA_PATH,(Join-Path $env:ProgramFiles ('NVIDIA GPU Computing Toolkit\CUDA\v'+($parts[0..1]-join '.'))))
    foreach($x in ($items | Where-Object {$_} | Select-Object -Unique)){
        try { $p=[IO.Path]::GetFullPath($x); if(Test-Path -LiteralPath (Join-Path $p 'bin\nvcc.exe') -PathType Leaf){return $p} } catch {}
    }
    return $null
}

function Resolve-VcVars {
    param([string]$Requested)
    $items=@($Requested,'C:\BuildTools\VS2022\VC\Auxiliary\Build\vcvars64.bat',(Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'))
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(Test-Path $vswhere){
        try { $root=(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1); if($root){$items += (Join-Path $root.Trim() 'VC\Auxiliary\Build\vcvars64.bat')} } catch {}
    }
    foreach($x in ($items | Where-Object {$_} | Select-Object -Unique)){if(Test-Path -LiteralPath $x -PathType Leaf){return [IO.Path]::GetFullPath($x)}}
    return $null
}

if($env:OS -eq 'Windows_NT' -and [Environment]::Is64BitOperatingSystem){Add-Check host PASS 'Windows x64' "$([Environment]::OSVersion.VersionString)"}else{Add-Check host FAIL 'Windows x64' "$env:OS" 'This milestone is native Windows only.'}

$git=Get-Command git.exe -ErrorAction SilentlyContinue
if($git){Add-Check git PASS 'Git for Windows' "$((& $git.Source --version | Select-Object -First 1).Trim()) @ $($git.Source)"}else{Add-Check git FAIL 'Git for Windows' 'missing' 'Install Git for Windows.'}
$tar=Get-Command tar.exe -ErrorAction SilentlyContinue
if($tar){Add-Check tar PASS 'tar.exe' $tar.Source}else{Add-Check tar FAIL 'tar.exe' 'missing' 'Windows tar.exe is required for canonical Git tree materialization.'}

$patch=Resolve-ProjectPath -Path ([string]$manifest.accepted_delta.patch) -BasePath $projectRoot
if(Test-Path -LiteralPath $patch -PathType Leaf){
    $pi=Get-Item $patch; $sha=Get-FileSha256 $patch
    if($pi.Length -eq [int64]$manifest.accepted_delta.patch_size_bytes -and $sha -eq ([string]$manifest.accepted_delta.patch_sha256).ToUpperInvariant()){Add-Check patchset PASS ([string]$manifest.accepted_delta.tree) "$sha; $($pi.Length) bytes"}else{Add-Check patchset FAIL ([string]$manifest.accepted_delta.patch_sha256) "$sha; $($pi.Length) bytes" 'Accepted patchset integrity mismatch.'}
}else{Add-Check patchset FAIL ([string]$manifest.accepted_delta.patch) 'missing' 'Restore the accepted patchset.'}

$resolvedPython=Resolve-Python $PythonExe
$probe=$null
if($resolvedPython){
    $scripts=Split-Path -Parent $resolvedPython; $env:PATH="$scripts;$env:PATH"
    $probeCode=@"
import importlib.metadata as md, json, platform
names=['build','cmake','ninja','torch','torchvision','torchaudio','triton-windows']
o={'python':platform.python_version(),'packages':{},'torch_cuda':None,'cuda_available':False,'gpu':None,'cc':None}
for n in names:
    try:o['packages'][n]=md.version(n)
    except md.PackageNotFoundError:o['packages'][n]=None
try:
    import torch
    o['torch_cuda']=torch.version.cuda
    o['cuda_available']=bool(torch.cuda.is_available())
    if o['cuda_available']:
        o['gpu']=torch.cuda.get_device_name(0)
        c=torch.cuda.get_device_capability(0);o['cc']=f'{c[0]}.{c[1]}'
except Exception as e:o['torch_error']=f'{type(e).__name__}: {e}'
print(json.dumps(o))
"@
    $raw=$probeCode | & $resolvedPython - 2>&1
    if($LASTEXITCODE -eq 0){
        $probe=($raw|Select-Object -Last 1)|ConvertFrom-Json
        $s=if([string]$probe.python -eq [string]$manifest.build.python){'PASS'}else{'FAIL'}
        Add-Check python $s ([string]$manifest.build.python) "$($probe.python) @ $resolvedPython" $(if($s -eq 'FAIL'){'Use the exact pinned Python version.'}else{''})
    }else{Add-Check python FAIL ([string]$manifest.build.python) ($raw -join ' ') 'Python environment probe failed.'}
}else{Add-Check python FAIL ([string]$manifest.build.python) 'not found' 'Pass -PythonExe or set VLLM_BUILD_PYTHON.'}

if($probe){
    $pkg=[ordered]@{'torch'=[string]$manifest.build.torch;'torchvision'=[string]$manifest.build.torchvision;'torchaudio'=[string]$manifest.build.torchaudio;'triton-windows'=[string]$manifest.build.triton_windows}
    foreach($n in $pkg.Keys){$a=$probe.packages.$n;$e=$pkg[$n];$s=if([string]$a -eq $e){'PASS'}else{'FAIL'};Add-Check $n $s $e $(if($null -eq $a){'missing'}else{[string]$a}) $(if($s -eq 'FAIL'){"Install exact pinned $n version."}else{''})}
    $b=$probe.packages.build;Add-Check python-build $(if($b){'PASS'}else{'FAIL'}) 'installed' $(if($b){[string]$b}else{'missing'}) $(if(-not $b){'Install the build package.'}else{''})
    $tc=((([string]$manifest.build.cuda_toolkit)-split '\.')[0..1]-join '.');$s=if([string]$probe.torch_cuda -eq $tc){'PASS'}else{'FAIL'};Add-Check torch-cuda $s $tc ([string]$probe.torch_cuda) $(if($s -eq 'FAIL'){'Torch CUDA must match the pinned toolkit major/minor.'}else{''})
    if($probe.cuda_available){$s=if([string]$probe.cc -eq [string]$manifest.build.target_cuda_arch){'PASS'}else{'WARN'};Add-Check gpu $s "SM$(([string]$manifest.build.target_cuda_arch).Replace('.',''))" "$($probe.gpu); CC $($probe.cc)" $(if($s -eq 'WARN'){'Outside the currently accepted SM120 target.'}else{''})}else{Add-Check gpu WARN "SM$(([string]$manifest.build.target_cuda_arch).Replace('.',''))" 'CUDA unavailable to Torch' 'Runtime acceptance is currently SM120-specific.'}
}

$resolvedCuda=Resolve-Cuda $CudaHome
if($resolvedCuda){$nvcc=Join-Path $resolvedCuda 'bin\nvcc.exe';$t=(& $nvcc --version 2>&1)-join "`n";$e=[string]$manifest.build.cuda_toolkit;$s=if($t -match ('V'+[regex]::Escape($e))){'PASS'}else{'FAIL'};$a=if($t -match 'V([0-9.]+)'){$matches[1]}else{$t};Add-Check cuda-toolkit $s $e "$a @ $resolvedCuda" $(if($s -eq 'FAIL'){'Install/pass the exact pinned CUDA toolkit.'}else{''})}else{Add-Check cuda-toolkit FAIL ([string]$manifest.build.cuda_toolkit) 'not found' 'Pass -CudaHome, set CUDA_HOME/CUDA_PATH, or install the pinned toolkit.'}

if (-not $CuSolverRoot) {
    $csManifestResolved = Resolve-ProjectPath -Path $CuSolverManifestPath -BasePath $projectRoot
    if (Test-Path -LiteralPath $csManifestResolved -PathType Leaf) {
        $csManifest = Get-Content -LiteralPath $csManifestResolved -Raw | ConvertFrom-Json
        $managedParent = Resolve-ProjectPath -Path ([string]$csManifest.install.managed_parent) -BasePath $projectRoot
        $candidate = Join-Path $managedParent ([string]$csManifest.archive.extraction_root)
        if (Test-Path -LiteralPath $candidate -PathType Container) { $CuSolverRoot = $candidate }
    }
}
if($CuSolverRoot){try{$CuSolverRoot=[IO.Path]::GetFullPath($CuSolverRoot)}catch{}}
$csOk=$CuSolverRoot -and (Test-Path (Join-Path $CuSolverRoot 'include\cusolverDn.h')) -and (Test-Path (Join-Path $CuSolverRoot 'lib\x64\cusolver.lib'))
if($csOk){Add-Check cusolver PASS 'headers + lib\x64\cusolver.lib' $CuSolverRoot}else{Add-Check cusolver FAIL 'external cuSOLVER root' $(if($CuSolverRoot){$CuSolverRoot}else{'not specified'}) 'Run .\bootstrap.ps1, or pass -CuSolverRoot / set VLLM_CUSOLVER_ROOT.'}

$resolvedVc=Resolve-VcVars $VcVars64
if($resolvedVc){
    $dump=& cmd.exe /d /s /c ('""{0}" >nul && set"' -f $resolvedVc);if($LASTEXITCODE -ne 0){throw 'vcvars64.bat failed'};foreach($line in $dump){if($line -match '^([^=]+)=(.*)$'){[Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process')}}
    $t=(& cl.exe 2>&1)-join "`n";$e=[string]$manifest.build.msvc;$s=if($t -match ('Version\s+'+[regex]::Escape($e))){'PASS'}else{'FAIL'};$a=if($t -match 'Version\s+([0-9.]+)'){$matches[1]}else{$t};Add-Check msvc $s $e "$a @ $resolvedVc" $(if($s -eq 'FAIL'){'Install/select the exact pinned MSVC toolset.'}else{''})
}else{Add-Check msvc FAIL ([string]$manifest.build.msvc) 'vcvars64.bat not found' 'Install VS Build Tools C++ x64 or pass -VcVars64.'}

$cm=Get-Command cmake.exe -ErrorAction SilentlyContinue
if($cm){$t=(& $cm.Source --version 2>&1)-join "`n";$a=if($t -match 'cmake version\s+([^\s]+)'){$matches[1]}else{$t};$e=[string]$manifest.build.cmake;$s=if($a -eq $e){'PASS'}else{'FAIL'};Add-Check cmake $s $e "$a @ $($cm.Source)" $(if($s -eq 'FAIL'){'Install exact pinned CMake.'}else{''})}else{Add-Check cmake FAIL ([string]$manifest.build.cmake) 'not found' 'Install CMake into the build environment.'}
$nj=Get-Command ninja.exe -ErrorAction SilentlyContinue
if($nj){$a=((& $nj.Source --version 2>&1)|Select-Object -First 1).Trim();$e=[string]$manifest.build.ninja;$s=if($a -eq $e){'PASS'}else{'FAIL'};Add-Check ninja $s $e "$a @ $($nj.Source)" $(if($s -eq 'FAIL'){'Install exact pinned Ninja.'}else{''})}else{Add-Check ninja FAIL ([string]$manifest.build.ninja) 'not found' 'Install Ninja into the build environment.'}

$fail=@($checks|Where-Object status -eq 'FAIL');$warn=@($checks|Where-Object status -eq 'WARN')
$result=[ordered]@{schema_version=1;manifest=$manifestResolved;milestone=[string]$manifest.milestone;build_ready=($fail.Count -eq 0);failure_count=$fail.Count;warning_count=$warn.Count;resolved=[ordered]@{python=$resolvedPython;cuda_home=$resolvedCuda;cusolver_root=$CuSolverRoot;vcvars64=$resolvedVc};checks=$checks}
if($Json){$result|ConvertTo-Json -Depth 8}else{Write-Host "vLLM Windows Native doctor -- $($manifest.milestone)";foreach($c in $checks){Write-Host ('[{0}] {1}' -f $c.status.PadRight(4),$c.name);if($c.actual){Write-Host ('       actual: '+$c.actual)};if($c.hint){Write-Host ('       hint:   '+$c.hint)}};Write-Host "Summary: $($fail.Count) failure(s), $($warn.Count) warning(s)";Write-Host $(if($fail.Count -eq 0){'DOCTOR_BUILD_READY'}else{'DOCTOR_NOT_READY'})}
if($fail.Count -gt 0){exit 1}