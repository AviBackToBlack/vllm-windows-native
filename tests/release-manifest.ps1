[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
$manifestPath=Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json'
$runtimePath=Join-Path $repoRoot 'manifests\runtime\vllm-runtime-v0.27.1-windows-x86_64.json'
$acceptedPath=Join-Path $repoRoot 'manifests\runtime\v0.27.1-rtx5090-sm120.json'
foreach($p in @($manifestPath,$runtimePath,$acceptedPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required manifest missing: $p"}}
$release=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$runtime=Get-Content -LiteralPath $runtimePath -Raw|ConvertFrom-Json
$accepted=Get-Content -LiteralPath $acceptedPath -Raw|ConvertFrom-Json
if([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64'){throw 'Unsupported release manifest identity.'}
if([string]$release.self_path -ne 'manifests/release/v0.27.1-windows-x86_64.json'){throw 'Unexpected release manifest self_path.'}
if(@($release.files).Count -ne 27){throw "Expected 27 owned distribution files, got $(@($release.files).Count)."}
$seen=@{}
foreach($entry in @($release.files)){
    $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release file path'
    $key=$relative.Replace('\','/').ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate release file: $relative"};$seen[$key]=$true
    $props=@($entry.PSObject.Properties.Name|Sort-Object);if(Compare-Object @('path','sha256','size_bytes') $props){throw "Unexpected release file schema: $relative"}
    $file=Join-Path $repoRoot $relative;if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Release file missing: $relative"}
    $item=Get-Item -LiteralPath $file;$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if($item.Length -ne [int64]$entry.size_bytes -or $hash -ne [string]$entry.sha256){throw "Release file identity mismatch: $relative"}
}foreach($required in @('install.ps1','start.ps1','update.ps1','uninstall.ps1','scripts/common.ps1','scripts/lifecycle.ps1','scripts/update-planner.ps1','scripts/update-staging.ps1','scripts/env.ps1','config.example.psd1','LICENSE','THIRD_PARTY_NOTICES.md')){if(-not$seen.ContainsKey($required.ToLowerInvariant())){throw "Required distribution file missing from release manifest: $required"}}
if([string]$release.upstream.repository -ne [string]$accepted.upstream.repository -or [string]$release.upstream.tag -ne [string]$accepted.upstream.tag -or [string]$release.upstream.commit -ne [string]$accepted.upstream.commit){throw 'Release upstream identity does not match accepted runtime provenance.'}
if([string]$release.windows_patchset.implementation_commit -ne [string]$accepted.accepted_delta.implementation_commit -or [string]$release.windows_patchset.tree -ne [string]$accepted.accepted_delta.tree -or [string]$release.windows_patchset.patch_sha256 -ne [string]$accepted.accepted_delta.patch_sha256){throw 'Release Windows patchset identity does not match accepted runtime provenance.'}
if([string]$release.wheel.filename -ne [string]$runtime.project_wheel.filename -or [string]$release.wheel.version -ne [string]$runtime.project_wheel.version -or [int64]$release.wheel.size_bytes -ne [int64]$runtime.project_wheel.size_bytes -or [string]$release.wheel.sha256 -ne [string]$runtime.project_wheel.sha256){throw 'Release wheel identity does not match managed runtime contract.'}
$expectedManaged=@('.vllm-operation.lock','cache/uv','forensic/python-bootstrap-3.13.15.json','forensic/runtime-dependencies-v0.27.1.json','forensic/runtime-vllm-v0.27.1.json','forensic/uv-bootstrap-0.12.13.json','forensic/venv-bootstrap-v0.27.1.json','python/managed/cpython-3.13.15-windows-x86_64-none','runtime/venv','state/install-orchestrator.lock','state/install-state.json','tools/uv/0.12.13')|Sort-Object
$actualManaged=@($release.managed_paths|ForEach-Object{(Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Managed path').Replace('\','/')}|Sort-Object)
if(Compare-Object $expectedManaged $actualManaged){throw 'Release managed_paths set does not match the accepted installer ownership contract.'}
$requiredOrchestration=@('python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest','python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root')
if(Compare-Object ($requiredOrchestration|Sort-Object) (@($release.orchestration.PSObject.Properties.Name)|Sort-Object)){throw 'Release orchestration schema is incomplete or contains unexpected fields.'}
Write-Host "RELEASE_MANIFEST_OK files=$(@($release.files).Count) sha256=$((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash)"
