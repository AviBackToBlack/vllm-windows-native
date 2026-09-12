[CmdletBinding()]
param(
    [string] $ManifestPath = 'manifests/runtime/v0.27.1-rtx5090-sm120.json',
    [string] $SourceDir = '',
    [string] $PythonExe = $env:VLLM_BUILD_PYTHON,
    [string] $CudaHome = $env:CUDA_HOME,
    [string] $CuSolverRoot = $env:VLLM_CUSOLVER_ROOT,
    [string] $CuSolverManifestPath = 'manifests/bootstrap/cusolver-12.0.4.66-windows-x86_64.json',
    [string] $VcVars64 = '',
    [string] $OutputDir = '',
    [string] $ContainmentRoot = $env:VLLM_BUILD_CONTAINMENT_ROOT,
    [switch] $ValidateOnly,
    [switch] $SkipPrepare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\env.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'This build driver currently supports native Windows only.'
}

$projectRoot = Get-ProjectRoot
if ([string]::IsNullOrWhiteSpace($ContainmentRoot)) {
    $ContainmentRoot = Join-Path $projectRoot 'work\build-containment'
}
$containment = Set-VllmContainedEnvironment -Root $ContainmentRoot
$ContainmentRoot = $containment.Root

$manifestResolved = Resolve-ProjectPath -Path $ManifestPath -BasePath $projectRoot
$manifest = Read-RuntimeManifest -ManifestPath $manifestResolved

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = Join-Path $projectRoot ('work\source-' + $manifest.upstream.tag)
}
$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $projectRoot ('artifacts\' + $manifest.milestone)
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

if (-not $SkipPrepare) {
    & (Join-Path $projectRoot 'scripts\prepare-source.ps1') -ManifestPath $manifestResolved -SourceDir $SourceDir
    if ($LASTEXITCODE -ne 0) { throw "Source preparation failed (exit $LASTEXITCODE)." }
}

if (-not (Test-Path -LiteralPath (Join-Path $SourceDir '.git'))) {
    throw "Prepared source is not a Git working tree: $SourceDir"
}
$sourceTree = Invoke-Git -Repository $SourceDir -Arguments @('write-tree') -Capture
if ($sourceTree -ne [string]$manifest.accepted_delta.tree) {
    throw "Source tree is not the accepted tree. Expected $($manifest.accepted_delta.tree), got $sourceTree."
}

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    throw 'Build Python is required. Pass -PythonExe or set VLLM_BUILD_PYTHON.'
}
$PythonExe = [System.IO.Path]::GetFullPath($PythonExe)
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
    throw "Build Python not found: $PythonExe"
}

if ([string]::IsNullOrWhiteSpace($CudaHome)) {
    $cudaParts = ([string]$manifest.build.cuda_toolkit -split '\.')
    $cudaMajorMinor = ($cudaParts[0..1] -join '.')
    $candidate = Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA\v$cudaMajorMinor"
    if (Test-Path -LiteralPath $candidate) { $CudaHome = $candidate }
}
if ([string]::IsNullOrWhiteSpace($CudaHome)) {
    throw 'CUDA toolkit root is required. Pass -CudaHome or set CUDA_HOME.'
}
$CudaHome = [System.IO.Path]::GetFullPath($CudaHome)
$nvcc = Join-Path $CudaHome 'bin\nvcc.exe'
if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) {
    throw "nvcc.exe not found under CUDA root: $CudaHome"
}

if ([string]::IsNullOrWhiteSpace($CuSolverRoot)) {
    $csManifestResolved = Resolve-ProjectPath -Path $CuSolverManifestPath -BasePath $projectRoot
    if (Test-Path -LiteralPath $csManifestResolved -PathType Leaf) {
        $csManifest = Get-Content -LiteralPath $csManifestResolved -Raw | ConvertFrom-Json
        $managedParent = Resolve-ProjectPath -Path ([string]$csManifest.install.managed_parent) -BasePath $projectRoot
        $candidate = Join-Path $managedParent ([string]$csManifest.archive.extraction_root)
        if (Test-Path -LiteralPath $candidate -PathType Container) { $CuSolverRoot = $candidate }
    }
}
if ([string]::IsNullOrWhiteSpace($CuSolverRoot)) {
    throw 'External cuSOLVER headers are required. Run .\bootstrap.ps1, pass -CuSolverRoot, or set VLLM_CUSOLVER_ROOT.'
}
$CuSolverRoot = [System.IO.Path]::GetFullPath($CuSolverRoot)
if (-not (Test-Path -LiteralPath (Join-Path $CuSolverRoot 'include\cusolverDn.h') -PathType Leaf)) {
    throw "cuSOLVER root does not contain include\cusolverDn.h: $CuSolverRoot"
}

if ([string]::IsNullOrWhiteSpace($VcVars64)) {
    $knownVcVars = @(
        'C:\BuildTools\VS2022\VC\Auxiliary\Build\vcvars64.bat',
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat')
    )
    $VcVars64 = $knownVcVars | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($VcVars64) -or -not (Test-Path -LiteralPath $VcVars64 -PathType Leaf)) {
    throw 'Visual Studio vcvars64.bat not found. Pass -VcVars64 explicitly.'
}
$VcVars64 = [System.IO.Path]::GetFullPath($VcVars64)

# Import the VS developer environment into this PowerShell process only.
$envDump = & cmd.exe /d /s /c ('""{0}" >nul && set"' -f $VcVars64)
if ($LASTEXITCODE -ne 0) { throw "vcvars64.bat failed (exit $LASTEXITCODE)." }
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}

$pythonScripts = Split-Path -Parent $PythonExe
$env:CUDA_HOME = $CudaHome
$env:CUDA_PATH = $CudaHome
$env:PATH = "$pythonScripts;$(Join-Path $CudaHome 'bin');$env:PATH"
$env:VLLM_CUSOLVER_ROOT = $CuSolverRoot
$env:VLLM_TARGET_DEVICE = 'cuda'
$env:TORCH_CUDA_ARCH_LIST = [string]$manifest.build.target_cuda_arch
$env:MAX_JOBS = [string]$manifest.build.max_jobs
$env:NVCC_THREADS = [string]$manifest.build.nvcc_threads
$env:VLLM_FA_CMAKE_GPU_ARCHES = ([string]$manifest.build.target_cuda_arch).Replace('.', '')
$env:VLLM_FLASH_ATTN_VERSION = [string]$manifest.build.flash_attn_version
$env:VLLM_TEST_USE_PRECOMPILED_NIGHTLY_WHEEL = '0'
$env:TORCH_NIGHTLY = '0'
$env:PYTHONNOUSERSITE = '1'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'

$probeCode = @'
import importlib.metadata as md
import json
import platform
import torch
import torchvision
import torchaudio
print(json.dumps({
    "python": platform.python_version(),
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "torchaudio": torchaudio.__version__,
    "torch_cuda": torch.version.cuda,
    "triton_windows": md.version("triton-windows"),
    "build": md.version("build"),
}))
'@
$probeRaw = $probeCode | & $PythonExe -
if ($LASTEXITCODE -ne 0) { throw 'Python build-environment probe failed.' }
$probe = ($probeRaw | Select-Object -Last 1) | ConvertFrom-Json

$expectedCuda = [string]$manifest.build.cuda_toolkit
$expectedTorchCuda = (($expectedCuda -split '\.')[0..1] -join '.')
$expected = @{
    python = [string]$manifest.build.python
    torch = [string]$manifest.build.torch
    torchvision = [string]$manifest.build.torchvision
    torchaudio = [string]$manifest.build.torchaudio
    torch_cuda = $expectedTorchCuda
    triton_windows = [string]$manifest.build.triton_windows
}
foreach ($name in $expected.Keys) {
    if ([string]$probe.$name -ne [string]$expected[$name]) {
        throw "Build environment mismatch for $name. Expected '$($expected[$name])', got '$($probe.$name)'."
    }
}

$nvccText = (& $nvcc --version 2>&1) -join "`n"
if ($nvccText -notmatch ('V' + [regex]::Escape([string]$manifest.build.cuda_toolkit))) {
    throw "CUDA compiler mismatch. Expected V$($manifest.build.cuda_toolkit)."
}

$clText = (& cl.exe 2>&1) -join "`n"
if ($clText -notmatch ('Version\s+' + [regex]::Escape([string]$manifest.build.msvc))) {
    throw "MSVC mismatch. Expected $($manifest.build.msvc)."
}

$cmakeText = (& cmake.exe --version 2>&1) -join "`n"
if ($cmakeText -notmatch ('cmake version\s+' + [regex]::Escape([string]$manifest.build.cmake))) {
    throw "CMake mismatch. Expected $($manifest.build.cmake)."
}
$ninjaVersion = ((& ninja.exe --version 2>&1) | Select-Object -First 1).Trim()
if ($ninjaVersion -ne [string]$manifest.build.ninja) {
    throw "Ninja mismatch. Expected '$($manifest.build.ninja)', got '$ninjaVersion'."
}

Write-Host 'BUILD_ENVIRONMENT_OK'
Write-Host "Source tree: $sourceTree"
Write-Host "Python:      $($probe.python)"
Write-Host "Torch:       $($probe.torch) / CUDA $($probe.torch_cuda)"
Write-Host "Triton:      $($probe.triton_windows)"
Write-Host "CUDA:        $($manifest.build.cuda_toolkit)"
Write-Host "MSVC:        $($manifest.build.msvc)"
Write-Host "CMake:       $($manifest.build.cmake)"
Write-Host "Ninja:       $ninjaVersion"
Write-Host "cuSOLVER:    $CuSolverRoot"

if ($ValidateOnly) {
    Write-Host 'BUILD_VALIDATE_ONLY_OK'
    return
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$buildStart = Get-Date
Set-Location $SourceDir
& $PythonExe -m build --wheel --no-isolation -C ("cmake.build-type=" + [string]$manifest.build.build_type)
if ($LASTEXITCODE -ne 0) { throw "Wheel build failed (exit $LASTEXITCODE)." }

$wheel = Get-ChildItem -LiteralPath (Join-Path $SourceDir 'dist') -Filter '*.whl' -File |
    Where-Object { $_.LastWriteTime -ge $buildStart.AddSeconds(-5) } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $wheel) { throw 'Build succeeded but no newly produced wheel was found.' }

$wheelSha = Get-FileSha256 -Path $wheel.FullName
$verifyCode = @'
import json, sys, zipfile
wheel = sys.argv[1]
with zipfile.ZipFile(wheel) as z:
    bad = z.testzip()
    pyd = sorted(n for n in z.namelist() if n.lower().endswith(".pyd"))
print(json.dumps({"bad": bad, "pyd": pyd}))
'@
$verifyRaw = $verifyCode | & $PythonExe - $wheel.FullName
if ($LASTEXITCODE -ne 0) { throw 'Wheel archive verification failed.' }
$wheelCheck = ($verifyRaw | Select-Object -Last 1) | ConvertFrom-Json
if ($null -ne $wheelCheck.bad) { throw "Wheel ZIP integrity failure at member '$($wheelCheck.bad)'." }

$expectedPyd = @($manifest.artifact.native_extensions | Sort-Object)
$actualPyd = @($wheelCheck.pyd | Sort-Object)
if (($expectedPyd -join "`n") -ne ($actualPyd -join "`n")) {
    throw "Native extension set mismatch.`nExpected:`n$($expectedPyd -join "`n")`nActual:`n$($actualPyd -join "`n")"
}

$destWheel = Join-Path $OutputDir $wheel.Name
Copy-Item -LiteralPath $wheel.FullName -Destination $destWheel -Force
$projectCommit = Invoke-Git -Repository $projectRoot -Arguments @('rev-parse','HEAD') -Capture
$projectStatus = Invoke-Git -Repository $projectRoot -Arguments @('status','--porcelain=v1') -Capture
$buildDriverSha = Get-FileSha256 -Path $PSCommandPath
$prepareSourcePath = Join-Path $projectRoot 'scripts\prepare-source.ps1'
$prepareSourceSha = Get-FileSha256 -Path $prepareSourcePath
$result = [ordered]@{
    schema_version = 1
    built_at = (Get-Date).ToString('o')
    project_commit = $projectCommit
    project_worktree_clean = [string]::IsNullOrWhiteSpace($projectStatus)
    build_driver_sha256 = $buildDriverSha
    prepare_source_sha256 = $prepareSourceSha
    upstream_commit = [string]$manifest.upstream.commit
    source_tree = $sourceTree
    source_path = $SourceDir
    source_materialization = 'verified-git-tree-raw-blobs'
    wheel = $wheel.Name
    wheel_size_bytes = $wheel.Length
    wheel_sha256 = $wheelSha
    accepted_wheel_sha256 = [string]$manifest.artifact.sha256
    accepted_wheel_hash_match = ($wheelSha -eq ([string]$manifest.artifact.sha256).ToUpperInvariant())
    zip_test = 'pass'
    native_extension_count = $actualPyd.Count
    native_extensions = $actualPyd
    output_path = $destWheel
}
$resultPath = Join-Path $OutputDir 'build-result.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8

Write-Host "Wheel:       $destWheel"
Write-Host "SHA-256:     $wheelSha"
Write-Host "Accepted SHA match: $($result.accepted_wheel_hash_match)"
Write-Host "Result:      $resultPath"
Write-Host 'BUILD_OK'
