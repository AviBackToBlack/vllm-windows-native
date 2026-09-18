[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstallationRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$InstallationRoot=[IO.Path]::GetFullPath($InstallationRoot)

function Assert-RelocationProbeLauncher {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )
    $root=Get-VllmNormalizedPath $Root
    $launcher=Join-Path $root 'Scripts\vllm-relocation-probe.exe'
    if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){throw "$Label console launcher is missing: $launcher"}
    $environment=Get-VllmProcessEnvironmentSnapshot
    try{
        [Environment]::SetEnvironmentVariable('PYTHONDONTWRITEBYTECODE','1','Process')
        $output=(& $launcher 2>&1|Out-String).Trim()
        if($LASTEXITCODE-ne0){throw "$Label console launcher failed with exit $LASTEXITCODE : $output"}
        if((Get-VllmNormalizedPath $output)-ne$root){throw "$Label console launcher resolved unexpected sys.prefix '$output'; expected '$root'."}
    }finally{
        Restore-VllmProcessEnvironment -Snapshot $environment
    }
}

function Assert-NoRuntimeRootLeakInTextScripts {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$ForbiddenRoots
    )
    $scripts=Join-Path (Get-VllmNormalizedPath $Root) 'Scripts'
    foreach($file in @(Get-ChildItem -LiteralPath $scripts -File)){
        if($file.Extension -in @('.exe','.dll','.pyd')){continue}
        $text=[IO.File]::ReadAllText($file.FullName)
        foreach($forbidden in $ForbiddenRoots){
            if([string]::IsNullOrWhiteSpace($forbidden)){continue}
            if($text.IndexOf((Get-VllmNormalizedPath $forbidden),[StringComparison]::OrdinalIgnoreCase)-ge0){
                throw "Relocatable runtime script '$($file.Name)' embeds forbidden absolute root '$forbidden'."
            }
        }
    }
}
$common=Join-Path $InstallationRoot 'scripts\common.ps1'
$stagingHelper=Join-Path $InstallationRoot 'scripts\update-staging.ps1'
foreach($required in @($common,$stagingHelper)){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Installed staging proof prerequisite is missing: $required"}
}
. $common
. $stagingHelper

$pythonManifest=Get-Content (Join-Path $InstallationRoot 'manifests\bootstrap\cpython-3.13.15-windows-x86_64.json') -Raw|ConvertFrom-Json
$uvManifest=Get-Content (Join-Path $InstallationRoot 'manifests\bootstrap\uv-0.12.13-windows-x86_64.json') -Raw|ConvertFrom-Json
$venvManifest=Get-Content (Join-Path $InstallationRoot 'manifests\bootstrap\venv-v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
$pythonRoot=Join-Path $InstallationRoot ([string]$pythonManifest.install.managed_relative_path)
$uvRoot=Join-Path $InstallationRoot ([string]$uvManifest.install.managed_relative_path)
$runtimeRoot=Join-Path $InstallationRoot 'runtime\venv'
$layout=Get-VllmUpdateStagingLayout -InstallationRoot $InstallationRoot -TransactionId ([guid]::NewGuid().ToString('D'))

try{
    [void][IO.Directory]::CreateDirectory($layout.TransactionRoot)
    [void](Initialize-VllmUpdateStagingDirectories -Layout $layout)
    $pythonStageResult=Copy-VllmUpdateManagedTreeStage -Layout $layout -SourceRoot $pythonRoot -FinalRelativePath ([string]$pythonManifest.install.managed_relative_path) -Role python -ExpectedPythonVersion ([string]$pythonManifest.version)
    $uvStageResult=Copy-VllmUpdateManagedTreeStage -Layout $layout -SourceRoot $uvRoot -FinalRelativePath ([string]$uvManifest.install.managed_relative_path) -Role uv -ExpectedUvVersion ([string]$uvManifest.version) -ExpectedUvCommitPrefix ([string]$uvManifest.acceptance.expected_commit_prefix)
    $runtimeStageResult=Copy-VllmUpdateManagedTreeStage -Layout $layout -SourceRoot $runtimeRoot -FinalRelativePath 'runtime\venv' -Role runtime -ExpectedPythonVersion ([string]$pythonManifest.version) -ExpectedPointerBits ([int]$venvManifest.acceptance.expected_pointer_bits) -ExpectedBasePythonRoot $pythonRoot

    $pythonStage=[string]$pythonStageResult.StagePath
    $uvStage=[string]$uvStageResult.StagePath
    $runtimeStage=[string]$runtimeStageResult.StagePath
    $pythonIdentity=$pythonStageResult.TreeIdentity
    $uvIdentity=$uvStageResult.TreeIdentity
    $runtimeIdentity=$runtimeStageResult.TreeIdentity
    if(Test-VllmUpdateRelocatableVenvTree -Root $runtimeStage -ExpectedPythonVersion ([string]$pythonManifest.version) -ExpectedPointerBits 32 -ExpectedBasePythonRoot $pythonRoot){
        throw 'Relocatable runtime validator accepted an incorrect pointer width.'
    }
    Write-Host 'UPDATE_POINTER_WIDTH_GUARD_OK'
    Assert-RelocationProbeLauncher -Root $runtimeStage -Label 'Staged runtime'
    Assert-NoRuntimeRootLeakInTextScripts -Root $runtimeStage -ForbiddenRoots @($runtimeRoot,$runtimeStage)
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $runtimeIdentity -B (Get-VllmUpdateTreeIdentity -Root $runtimeStage))){
        throw 'Staged console-launcher validation mutated the staged runtime tree.'
    }

    $probeRoot=Join-Path $layout.TransactionRoot 'relocation-probe'
    [void][IO.Directory]::CreateDirectory($probeRoot)
    $pythonProbe=Join-Path $probeRoot 'python'
    $uvProbe=Join-Path $probeRoot 'uv'
    $runtimeProbe=Join-Path $probeRoot 'runtime'
    Move-Item -LiteralPath $pythonStage -Destination $pythonProbe
    Move-Item -LiteralPath $uvStage -Destination $uvProbe
    Move-Item -LiteralPath $runtimeStage -Destination $runtimeProbe

    if(-not(Test-VllmUpdateTreeIdentityEqual -A $pythonIdentity -B (Get-VllmUpdateTreeIdentity -Root $pythonProbe))){throw 'Portable Python tree identity changed across relocation.'}
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $uvIdentity -B (Get-VllmUpdateTreeIdentity -Root $uvProbe))){throw 'Portable uv tree identity changed across relocation.'}
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $runtimeIdentity -B (Get-VllmUpdateTreeIdentity -Root $runtimeProbe))){throw 'Runtime venv tree identity changed across relocation.'}
    Assert-RelocationProbeLauncher -Root $runtimeProbe -Label 'Relocated runtime'
    Assert-NoRuntimeRootLeakInTextScripts -Root $runtimeProbe -ForbiddenRoots @($runtimeRoot,$runtimeStage)
    Write-Host 'UPDATE_CONSOLE_LAUNCHER_RELOCATION_OK'
    if(-not(Test-VllmUpdatePortablePythonTree -Root $pythonProbe -ExpectedVersion ([string]$pythonManifest.version))){throw 'Relocated portable Python failed final-location semantics.'}
    if(-not(Test-VllmUpdatePortableUvTree -Root $uvProbe -ExpectedVersion ([string]$uvManifest.version) -ExpectedCommitPrefix ([string]$uvManifest.acceptance.expected_commit_prefix))){throw 'Relocated portable uv failed final-location semantics.'}
    if(-not(Test-VllmUpdateRelocatableVenvTree -Root $runtimeProbe -ExpectedPythonVersion ([string]$pythonManifest.version) -ExpectedPointerBits ([int]$venvManifest.acceptance.expected_pointer_bits) -ExpectedBasePythonRoot $pythonRoot)){throw 'Relocated runtime venv failed final-location semantics.'}

    $dependencyReceipt=Get-Content (Join-Path $InstallationRoot 'forensic\runtime-dependencies-v0.27.1.json') -Raw|ConvertFrom-Json
    $runtimeReceipt=Get-Content (Join-Path $InstallationRoot 'forensic\runtime-vllm-v0.27.1.json') -Raw|ConvertFrom-Json
    if((Get-VllmNormalizedPath ([string]$dependencyReceipt.root))-ne(Get-VllmNormalizedPath $runtimeRoot)-or
       (Get-VllmNormalizedPath ([string]$runtimeReceipt.root))-ne(Get-VllmNormalizedPath $runtimeRoot)){
        throw 'Runtime receipts do not encode the committed final runtime root.'
    }
    if((Get-VllmNormalizedPath ([string]$dependencyReceipt.root))-eq(Get-VllmNormalizedPath $runtimeStage)-or
       (Get-VllmNormalizedPath ([string]$runtimeReceipt.root))-eq(Get-VllmNormalizedPath $runtimeStage)){
        throw 'Path-bearing receipts unexpectedly encode a staging root.'
    }
    Write-Host 'UPDATE_REAL_RELOCATION_PROOF_OK'
    Write-Host 'UPDATE_FINAL_PATH_RECEIPTS_OK'
}
finally{
    if(Test-Path -LiteralPath $layout.WorkspaceRoot){
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $layout.WorkspaceRoot -RelativePath $layout.WorkspaceRelative)
        Remove-Item -LiteralPath $layout.WorkspaceRoot -Recurse -Force
    }
}
if(Test-Path -LiteralPath (Join-Path $InstallationRoot 'work\update-transaction')){throw 'Relocation proof left update transaction residue.'}
Write-Host 'UPDATE_REAL_STAGING_TEST_OK'
