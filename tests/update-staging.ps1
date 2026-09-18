[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\lifecycle.ps1')
. (Join-Path $repoRoot 'scripts\update-planner.ps1')
. (Join-Path $repoRoot 'scripts\update-staging.ps1')

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Expected)
    try{& $Action;throw "Expected failure did not occur: $Name"}
    catch{
        $message=$_.Exception.Message
        if($message -eq "Expected failure did not occur: $Name"){throw}
        if($message.IndexOf($Expected,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure for $($Name): $message"}
        Write-Host "REJECT $Name :: $message"
    }
}

function Get-TestFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{
        Size=[int64](Get-Item -LiteralPath $Path).Length
        Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

$base=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-staging-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($base)
    $installation=Join-Path $base 'installed'
    [void][IO.Directory]::CreateDirectory($installation)
    $tx=[guid]::NewGuid().ToString('D')
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $installation -TransactionId $tx
    Test-ExpectedFailure -Action {Initialize-VllmUpdateStagingDirectories -Layout $layout|Out-Null} -Name 'missing-transaction-workspace' -Expected 'workspace is missing'

    [void][IO.Directory]::CreateDirectory($layout.TransactionRoot)
    [void](Initialize-VllmUpdateStagingDirectories -Layout $layout)
    if(-not(Test-Path -LiteralPath $layout.DistributionRoot -PathType Container)-or-not(Test-Path -LiteralPath $layout.ManagedRoot -PathType Container)){
        throw 'Staging layout was not initialized.'
    }
    Test-ExpectedFailure -Action {Initialize-VllmUpdateStagingDirectories -Layout $layout|Out-Null} -Name 'existing-staging-evidence' -Expected 'already exists'
    Write-Host 'UPDATE_STAGING_LAYOUT_OK'

    $payload=Join-Path $base 'payload'
    [void][IO.Directory]::CreateDirectory($payload)
    $replaceSource=Join-Path $payload 'replace.txt'
    $addSource=Join-Path $payload 'nested\add.txt'
    $reuseSource=Join-Path $payload 'reuse.txt'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $addSource))
    [IO.File]::WriteAllText($replaceSource,'target-replace',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($addSource,'target-add',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($reuseSource,'same',[Text.UTF8Encoding]::new($false))
    $replaceIdentity=Get-TestFileIdentity -Path $replaceSource
    $addIdentity=Get-TestFileIdentity -Path $addSource
    $reuseIdentity=Get-TestFileIdentity -Path $reuseSource

    $distributionMap=@{}
    foreach($row in @(
        @('replace.txt',$replaceSource,$replaceIdentity),
        @('nested\add.txt',$addSource,$addIdentity),
        @('reuse.txt',$reuseSource,$reuseIdentity)
    )){
        $distributionMap[(Get-VllmUpdateRelativeKey $row[0])]=[pscustomobject]@{
            RelativePath=$row[0];Path=$row[1];Size=$row[2].Size;Sha256=$row[2].Sha256
        }
    }
    $plan=[pscustomobject]@{
        distribution=@(
            [pscustomobject]@{Class='replace';RelativePath='replace.txt';Target=[pscustomobject]@{Size=$replaceIdentity.Size;Sha256=$replaceIdentity.Sha256}},
            [pscustomobject]@{Class='add';RelativePath='nested\add.txt';Target=[pscustomobject]@{Size=$addIdentity.Size;Sha256=$addIdentity.Sha256}},
            [pscustomobject]@{Class='reuse';RelativePath='reuse.txt';Target=[pscustomobject]@{Size=$reuseIdentity.Size;Sha256=$reuseIdentity.Sha256}},
            [pscustomobject]@{Class='retire';RelativePath='retire.txt';Target=$null}
        )
        managed=@(
            [pscustomobject]@{Class='replace';RelativePath='runtime\venv';Role='runtime';SourceContract='old-runtime';TargetContract='new-runtime'},
            [pscustomobject]@{Class='reuse';RelativePath='python\managed\current';Role='python';SourceContract='python-v1';TargetContract='python-v1'},
            [pscustomobject]@{Class='reuse';RelativePath='tools\uv\1';Role='uv';SourceContract='uv-v1';TargetContract='uv-v1'},
            [pscustomobject]@{Class='reuse';RelativePath='cache\uv';Role='cache';SourceContract='cache-v1';TargetContract='cache-v1'},
            [pscustomobject]@{Class='replace';RelativePath='forensic\runtime-vllm.json';Role='runtime-receipt';SourceContract='old';TargetContract='new'},
            [pscustomobject]@{Class='add';RelativePath='forensic\runtime-dependencies.json';Role='dependency-receipt';SourceContract=$null;TargetContract='new'},
            [pscustomobject]@{Class='retire';RelativePath='forensic\old-venv.json';Role='venv-receipt';SourceContract='old';TargetContract=$null}
        )
    }
    $target=[pscustomobject]@{DistributionMap=$distributionMap}
    $staged=@(Copy-VllmUpdateDistributionStage -Layout $layout -Plan $plan -TargetContext $target)
    if($staged.Count-ne2){throw "Expected exactly two staged distribution files, got $($staged.Count)."}
    foreach($entry in $staged){
        if(-not(Test-Path -LiteralPath $entry.StagePath -PathType Leaf)){throw "Staged file missing: $($entry.RelativePath)"}
        $actual=Get-TestFileIdentity -Path $entry.StagePath
        if($actual.Size-ne$entry.Size-or$actual.Sha256-ne$entry.Sha256){throw "Staged identity mismatch: $($entry.RelativePath)"}
    }
    if(Test-Path -LiteralPath (Join-Path $layout.DistributionRoot 'reuse.txt')){throw 'Reuse distribution file was unnecessarily staged.'}
    if(Test-Path -LiteralPath (Join-Path $layout.DistributionRoot 'retire.txt')){throw 'Retire distribution file entered staging.'}
    Write-Host 'UPDATE_DISTRIBUTION_STAGING_OK'

    $managedPolicy=@(Get-VllmUpdateManagedStagingPlan -Plan $plan)
    $mode=@{};foreach($entry in $managedPolicy){$mode[$entry.RelativePath]=[string]$entry.Mode}
    if($mode['runtime\venv']-ne'relocate-tree'-or$mode['python\managed\current']-ne'reuse-live'){throw 'Relocatable managed tree policy mismatch.'}
    $pythonOnlyPlan=[pscustomobject]@{managed=@([pscustomobject]@{
        Class='replace';RelativePath='python\managed\new';Role='python';SourceContract='python-v1';TargetContract='python-v2'
    })}
    $pythonOnlyPolicy=@(Get-VllmUpdateManagedStagingPlan -Plan $pythonOnlyPlan)
    if($pythonOnlyPolicy.Count-ne1-or$pythonOnlyPolicy[0].Mode-ne'relocate-tree'){throw 'Python-only relocation policy mismatch.'}
    $combinedPlan=[pscustomobject]@{managed=@(
        [pscustomobject]@{Class='replace';RelativePath='python\managed\new';Role='python';SourceContract='python-v1';TargetContract='python-v2'},
        [pscustomobject]@{Class='replace';RelativePath='runtime\venv';Role='runtime';SourceContract='runtime-v1';TargetContract='runtime-v2'}
    )}
    Test-ExpectedFailure -Action {Get-VllmUpdateManagedStagingPlan -Plan $combinedPlan|Out-Null} -Name 'combined-python-runtime-change' -Expected 'Simultaneous Python/runtime'

    $relocatedPythonWithReusedRuntime=[pscustomobject]@{managed=@(
        [pscustomobject]@{Class='retire';RelativePath='python\managed\old';Role='python';SourceContract='python-v1';TargetContract=$null},
        [pscustomobject]@{Class='add';RelativePath='python\managed\new';Role='python';SourceContract=$null;TargetContract='python-v1'},
        [pscustomobject]@{Class='reuse';RelativePath='runtime\venv';Role='runtime';SourceContract='runtime-v1';TargetContract='runtime-v1'}
    )}
    Test-ExpectedFailure -Action {Get-VllmUpdateManagedStagingPlan -Plan $relocatedPythonWithReusedRuntime|Out-Null} -Name 'reused-runtime-retired-python-base' -Expected 'reused runtime'

    $samePathPythonReplaceWithReusedRuntime=[pscustomobject]@{managed=@(
        [pscustomobject]@{Class='replace';RelativePath='python\managed\current';Role='python';SourceContract='python-v1';TargetContract='python-v1-repacked'},
        [pscustomobject]@{Class='reuse';RelativePath='runtime\venv';Role='runtime';SourceContract='runtime-v1';TargetContract='runtime-v1'}
    )}
    $samePathPolicy=@(Get-VllmUpdateManagedStagingPlan -Plan $samePathPythonReplaceWithReusedRuntime)
    $samePathMode=@{};foreach($entry in $samePathPolicy){$samePathMode[$entry.RelativePath]=[string]$entry.Mode}
    if($samePathPolicy.Count-ne2-or$samePathMode['python\managed\current']-ne'relocate-tree'-or$samePathMode['runtime\venv']-ne'reuse-live'){
        throw 'Same-path Python replacement with reused runtime should remain classifiable without retiring the runtime base path.'
    }

    if($mode['forensic\runtime-vllm.json']-ne'regenerate-final'-or$mode['forensic\runtime-dependencies.json']-ne'regenerate-final'){throw 'Receipt regeneration policy mismatch.'}
    if($mode['tools\uv\1']-ne'reuse-live'-or$mode['cache\uv']-ne'reuse-live'){throw 'Reuse managed policy mismatch.'}
    if($mode['forensic\old-venv.json']-ne'retire-post-commit'){throw 'Retire managed policy mismatch.'}
    $badCache=[pscustomobject]@{managed=@([pscustomobject]@{
        Class='replace';RelativePath='cache\uv';Role='cache';SourceContract='a';TargetContract='b'
    })}
    Test-ExpectedFailure -Action {Get-VllmUpdateManagedStagingPlan -Plan $badCache|Out-Null} -Name 'cache-contract-change' -Expected 'cache contract'
    Write-Host 'UPDATE_MANAGED_STAGING_POLICY_OK'

    $tree=Join-Path $layout.ManagedRoot 'runtime-tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $tree 'Scripts'))
    [IO.File]::WriteAllText((Join-Path $tree 'pyvenv.cfg'),('relocatable = true'+[string][char]10),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $tree 'Scripts\payload.txt'),'payload',[Text.UTF8Encoding]::new($false))
    $before=Get-VllmUpdateTreeIdentity -Root $tree
    $probe=Join-Path $layout.TransactionRoot 'relocation-probe'
    Move-Item -LiteralPath $tree -Destination $probe
    $after=Get-VllmUpdateTreeIdentity -Root $probe
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $before -B $after)){throw 'Same-volume relocation changed managed tree identity.'}
    [IO.File]::AppendAllText((Join-Path $probe 'Scripts\payload.txt'),'drift',[Text.UTF8Encoding]::new($false))
    $drift=Get-VllmUpdateTreeIdentity -Root $probe
    if(Test-VllmUpdateTreeIdentityEqual -A $before -B $drift){throw 'Tree identity failed to detect post-relocation drift.'}
    Write-Host 'UPDATE_TREE_RELOCATION_IDENTITY_OK'

    if(Test-VllmUpdatePortablePythonTree -Root $probe -ExpectedVersion '0.0.0'){throw 'Synthetic tree unexpectedly passed portable Python semantics.'}
    if(Test-VllmUpdatePortableUvTree -Root $probe -ExpectedVersion '0.0.0' -ExpectedCommitPrefix 'deadbeef'){throw 'Synthetic tree unexpectedly passed portable uv semantics.'}
    if(Test-VllmUpdateRelocatableVenvTree -Root $probe -ExpectedPythonVersion '0.0.0' -ExpectedBasePythonRoot $installation){throw 'Synthetic tree unexpectedly passed relocatable venv semantics.'}
    Write-Host 'UPDATE_ROLE_VALIDATOR_NEGATIVE_OK'
    Write-Host 'UPDATE_STAGING_TEST_OK'
}
finally{
    if(Test-Path $base){Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue}
}
