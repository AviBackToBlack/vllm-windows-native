[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\lifecycle.ps1')
. (Join-Path $repoRoot 'scripts\update-planner.ps1')
function Test-ExpectedFailure{param([scriptblock]$Action,[string]$Name,[string]$Expected);try{& $Action;throw "Expected failure did not occur: $Name"}catch{$m=$_.Exception.Message;if($m-eq"Expected failure did not occur: $Name"){throw};if($m.IndexOf($Expected,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Expected '$Name' to contain '$Expected', got: $m"};Write-Host "REJECT $Name :: $m"}}
function Get-TestRelease{param([string]$Name);[pscustomobject]@{release=$Name;platform='windows-x86_64';upstream=[pscustomobject]@{repository='repo';tag='tag';commit='commit'};windows_patchset=[pscustomobject]@{implementation_commit='impl';tree='tree';patch_sha256=('C'*64)};wheel=[pscustomobject]@{filename='vllm.whl';version='1';size_bytes=1;sha256=('D'*64)}}}
function Get-TestDistribution{param([string]$Path,[string]$Hash,[int64]$Size=1);[pscustomobject]@{RelativePath=$Path;Size=$Size;Sha256=$Hash}}
function Get-TestContract{param([string]$Path,[string]$Role,[string]$Contract);[pscustomobject]@{RelativePath=$Path;Role=$Role;Contract=$Contract}}
function Get-TestMap{param([object[]]$Values);$m=@{};foreach($v in $Values){$m[(Get-VllmUpdateRelativeKey ([string]$v.RelativePath))]=$v};$m}
function Copy-TestReleaseFiles{
    param([Parameter(Mandatory)]$Release,[Parameter(Mandatory)][string]$Root)
    foreach($entry in @($Release.files)){
        $src=Join-Path $repoRoot ([string]$entry.path)
        $dst=Join-Path $Root ([string]$entry.path)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst))
        Copy-Item -LiteralPath $src -Destination $dst
    }
}
function Write-TestReleaseManifest{
    param([Parameter(Mandatory)]$Release,[Parameter(Mandatory)][string]$Root)
    $path=Join-Path $Root ([string]$Release.self_path)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $json=$Release|ConvertTo-Json -Depth 20
    $json=$json.Replace([Environment]::NewLine,[string][char]10)+[string][char]10
    [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))
    return $path
}
$base=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-planner-'+[guid]::NewGuid().ToString('N'))
try{
    [void][IO.Directory]::CreateDirectory($base)
    $models=Join-Path $base 'models';[void][IO.Directory]::CreateDirectory($models)
    $canonical=Get-VllmUpdateReleaseContext -ReleaseManifestPath (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner
    if($canonical.DistributionMap.Count-ne30-or$canonical.ManagedMap.Count-ne14-or$canonical.ManagedContractsMap.Count-ne9){throw 'Canonical target release context shape mismatch.'}
    if(-not$canonical.DistributionMap.ContainsKey((Get-VllmUpdateRelativeKey 'scripts\update-integration.ps1'))){throw 'Canonical target does not own update integration helper.'}
    Write-Host 'UPDATE_TARGET_REFERENCE_GRAPH_OK'

    $missingIntegrationRoot=Join-Path $base 'missing-update-integration'
    $missingIntegrationRelease=Get-Content (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
    $missingIntegrationRelease.files=@($missingIntegrationRelease.files|Where-Object{
        ([string]$_.path).Replace('\','/') -ne 'scripts/update-integration.ps1'
    })
    Copy-TestReleaseFiles -Release $missingIntegrationRelease -Root $missingIntegrationRoot
    $missingIntegrationManifest=Write-TestReleaseManifest -Release $missingIntegrationRelease -Root $missingIntegrationRoot
    Test-ExpectedFailure -Action {
        Get-VllmUpdateReleaseContext -ReleaseManifestPath $missingIntegrationManifest -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null
    } -Name 'missing-update-integration-helper' -Expected 'Required lifecycle distribution file'
    Write-Host 'UPDATE_INTEGRATION_HELPER_REQUIRED_OK'

    $legacyRoot=Join-Path $base 'legacy-source-without-update-reservations'
    $legacyRelease=Get-Content (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
    $legacyRelease.managed_paths=@($legacyRelease.managed_paths|Where-Object{
        ([string]$_).Replace('\','/') -notin @('state/update-transaction.json','work/update-transaction')
    })
    Copy-TestReleaseFiles -Release $legacyRelease -Root $legacyRoot
    $legacyManifest=Write-TestReleaseManifest -Release $legacyRelease -Root $legacyRoot
    $legacyContext=Get-VllmUpdateReleaseContext -ReleaseManifestPath $legacyManifest -InstallationRoot $base -ModelsRoot $models
    if($legacyContext.ManagedMap.Count-ne12){throw 'Legacy source compatibility fixture unexpectedly changed managed ownership shape.'}
    Test-ExpectedFailure -Action {
        Get-VllmUpdateReleaseContext -ReleaseManifestPath $legacyManifest -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null
    } -Name 'legacy-source-not-valid-as-updater-target' -Expected 'missing required lifecycle-owned path'
    Write-Host 'UPDATE_LEGACY_SOURCE_COMPATIBILITY_OK'
    function Test-ReservedDistributionRejection {
        param([string]$RelativePath,[string]$Name)
        $fixtureRoot=Join-Path $base ('reserved-'+$Name)
        $release=Get-Content (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
        $malicious=[pscustomobject][ordered]@{path=$RelativePath;size_bytes=0;sha256=('0'*64)}
        $release.files=@($malicious)+@($release.files)
        $manifestPath=Join-Path $fixtureRoot ([string]$release.self_path)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath))
        $json=$release|ConvertTo-Json -Depth 20
        $json=$json.Replace([Environment]::NewLine,[string][char]10)+[string][char]10
        [IO.File]::WriteAllText($manifestPath,$json,[Text.UTF8Encoding]::new($false))
        Test-ExpectedFailure -Action {Get-VllmUpdateReleaseContext -ReleaseManifestPath $manifestPath -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null} -Name $Name -Expected 'lifecycle-owned control metadata'
    }
    Test-ReservedDistributionRejection -RelativePath 'state\update-transaction.json' -Name 'reserved-update-journal-distribution'
    Test-ReservedDistributionRejection -RelativePath 'work\update-transaction' -Name 'reserved-update-workspace-distribution'
    Test-ReservedDistributionRejection -RelativePath 'work\update-transaction\payload.bin' -Name 'reserved-update-workspace-descendant'
    Test-ExpectedFailure -Action {Assert-VllmUpdateNoProtectedOverlap -InstallationRoot $base -ModelsRoot $models -RelativePath 'config.psd1\child' -Label 'Synthetic distribution path'} -Name 'config-subtree-overlap' -Expected 'config.psd1'
    Write-Host 'UPDATE_LIFECYCLE_DISTRIBUTION_GUARDS_OK'

    $selfRoot=Join-Path $base 'reserved-self-path'
    $selfRelease=Get-Content (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
    Copy-TestReleaseFiles -Release $selfRelease -Root $selfRoot
    $selfRelease.self_path='state\update-transaction.json'
    $selfManifest=Write-TestReleaseManifest -Release $selfRelease -Root $selfRoot
    Test-ExpectedFailure -Action {Get-VllmUpdateReleaseContext -ReleaseManifestPath $selfManifest -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null} -Name 'reserved-self-path-journal' -Expected 'self_path overlaps lifecycle-owned'
    Write-Host 'UPDATE_SELF_PATH_LIFECYCLE_GUARD_OK'

    function Test-ReservedContractRejection {
        param([string]$Field,[string]$RelativePath,[string]$Name)
        $fixtureRoot=Join-Path $base ('reserved-contract-'+$Name)
        $release=Get-Content (Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json') -Raw|ConvertFrom-Json
        Copy-TestReleaseFiles -Release $release -Root $fixtureRoot
        $old=[string]$release.orchestration.$Field
        $release.orchestration.$Field=$RelativePath
        $release.managed_paths=@($release.managed_paths|ForEach-Object{if([string]$_ -eq $old){$RelativePath}else{[string]$_}})
        $manifest=Write-TestReleaseManifest -Release $release -Root $fixtureRoot
        Test-ExpectedFailure -Action {Get-VllmUpdateReleaseContext -ReleaseManifestPath $manifest -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null} -Name $Name -Expected 'managed path overlaps lifecycle-owned'
    }
    Test-ReservedContractRejection -Field 'python_receipt' -RelativePath 'state\update-transaction.json' -Name 'reserved-contract-journal'
    Test-ReservedContractRejection -Field 'uv_receipt' -RelativePath 'work\update-transaction\receipt.json' -Name 'reserved-contract-workspace-descendant'
    Write-Host 'UPDATE_MANAGED_CONTRACT_LIFECYCLE_GUARDS_OK'
    $contradictoryRoot=Join-Path $base 'contradictory-target'
    $canonicalManifestPath=Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json'
    $contradictoryRelease=Get-Content $canonicalManifestPath -Raw|ConvertFrom-Json
    foreach($entry in @($contradictoryRelease.files)){
        $src=Join-Path $repoRoot ([string]$entry.path);$dst=Join-Path $contradictoryRoot ([string]$entry.path)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $dst));Copy-Item -LiteralPath $src -Destination $dst
    }
    $venvRelative=[string]$contradictoryRelease.orchestration.venv_manifest;$venvPath=Join-Path $contradictoryRoot $venvRelative
    $badVenv=Get-Content $venvPath -Raw|ConvertFrom-Json;$badVenv.python.version='9.9.9';[IO.File]::WriteAllText($venvPath,(($badVenv|ConvertTo-Json -Depth 20)-replace"`r`n","`n")+"`n",[Text.UTF8Encoding]::new($false))
    $venvEntry=@($contradictoryRelease.files|Where-Object{$_.path.Replace('\','/') -eq $venvRelative.Replace('\','/')})
    if($venvEntry.Count-ne1){throw 'Contradictory fixture could not identify venv distribution entry.'};$venvEntry[0].size_bytes=(Get-Item $venvPath).Length;$venvEntry[0].sha256=(Get-FileHash $venvPath -Algorithm SHA256).Hash
    $contradictoryManifest=Join-Path $contradictoryRoot ([string]$contradictoryRelease.self_path);[void][IO.Directory]::CreateDirectory((Split-Path -Parent $contradictoryManifest));[IO.File]::WriteAllText($contradictoryManifest,(($contradictoryRelease|ConvertTo-Json -Depth 20)-replace"`r`n","`n")+"`n",[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {Get-VllmUpdateReleaseContext -ReleaseManifestPath $contradictoryManifest -InstallationRoot $base -ModelsRoot $models -RequireUpdaterPlanner|Out-Null} -Name 'contradictory-python-version' -Expected 'Python version identity is inconsistent'
    Write-Host 'UPDATE_TARGET_SEMANTIC_CROSSLINK_REJECTED'
    $same='1'*64;$old='2'*64;$new='3'*64;$retire='4'*64;$add='5'*64
    $sourceDist=Get-TestMap @((Get-TestDistribution 'config.example.psd1' $same 10),(Get-TestDistribution 'reuse.txt' $same),(Get-TestDistribution 'replace.txt' $old),(Get-TestDistribution 'retire.txt' $retire))
    $targetDist=Get-TestMap @((Get-TestDistribution 'config.example.psd1' $same 10),(Get-TestDistribution 'reuse.txt' $same),(Get-TestDistribution 'replace.txt' $new),(Get-TestDistribution 'add.txt' $add))
    $sourceManaged=Get-TestMap @((Get-TestContract 'runtime/venv' 'runtime' 'runtime-v1'),(Get-TestContract 'python/managed/python' 'python' 'python-v1'),(Get-TestContract 'forensic/old.json' 'old-receipt' 'old-v1'))
    $targetManaged=Get-TestMap @((Get-TestContract 'runtime/venv' 'runtime' 'runtime-v2'),(Get-TestContract 'python/managed/python' 'python' 'python-v1'),(Get-TestContract 'forensic/new.json' 'new-receipt' 'new-v1'))
    $sourceRelease=Get-TestRelease 'synthetic-v1';$targetRelease=Get-TestRelease 'synthetic-v2'
    $source=[pscustomobject]@{Committed=[pscustomobject]@{Root=$base;GenerationId=[guid]::NewGuid().ToString()};ModelsRoot=$models;ReleaseContext=[pscustomobject]@{Release=$sourceRelease;ReleaseManifestSha256=('A'*64);DistributionMap=$sourceDist;ManagedContractsMap=$sourceManaged}}
    $target=[pscustomobject]@{Release=$targetRelease;ReleaseManifestSha256=('B'*64);DistributionMap=$targetDist;ManagedContractsMap=$targetManaged}
    $plan=Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $target
    if($plan.idempotent-or$plan.counts.distribution_reuse-ne2-or$plan.counts.distribution_replace-ne1-or$plan.counts.distribution_add-ne1-or$plan.counts.distribution_retire-ne1-or$plan.counts.managed_reuse-ne1-or$plan.counts.managed_replace-ne1-or$plan.counts.managed_add-ne1-or$plan.counts.managed_retire-ne1){throw 'Synthetic transition classification mismatch.'}
    $json1=$plan|ConvertTo-Json -Depth 12;$json2=(Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $target)|ConvertTo-Json -Depth 12;if($json1-ne$json2){throw 'Transition plan is not deterministic.'}
    Write-Host 'UPDATE_PLAN_CLASSIFICATION_OK'
    $sameTarget=[pscustomobject]@{Release=$sourceRelease;ReleaseManifestSha256=('A'*64);DistributionMap=$sourceDist;ManagedContractsMap=$sourceManaged}
    $noop=Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $sameTarget
    if(-not$noop.idempotent-or@($noop.distribution|Where-Object Class -ne 'reuse').Count-or@($noop.managed|Where-Object Class -ne 'reuse').Count){throw 'Exact same-release plan is not idempotent.'}
    Write-Host 'UPDATE_PLAN_NOOP_OK'
    $sameNameDifferent=[pscustomobject]@{Release=$sourceRelease;ReleaseManifestSha256=('B'*64);DistributionMap=$sourceDist;ManagedContractsMap=$sourceManaged}
    Test-ExpectedFailure -Action {Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $sameNameDifferent|Out-Null} -Name 'same-name-different-digest' -Expected 'reuses source release identifier'
    $badConfig=Get-TestMap @((Get-TestDistribution 'config.example.psd1' ('9'*64) 10),(Get-TestDistribution 'reuse.txt' $same),(Get-TestDistribution 'replace.txt' $new),(Get-TestDistribution 'add.txt' $add))
    $badConfigTarget=[pscustomobject]@{Release=$targetRelease;ReleaseManifestSha256=('B'*64);DistributionMap=$badConfig;ManagedContractsMap=$targetManaged}
    Test-ExpectedFailure -Action {Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $badConfigTarget|Out-Null} -Name 'config-contract-change' -Expected 'config migration'
    $collision=Join-Path $base 'add.txt';[IO.File]::WriteAllText($collision,'unowned',[Text.Encoding]::ASCII)
    Test-ExpectedFailure -Action {Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $target|Out-Null} -Name 'unowned-add-collision' -Expected 'unowned live path'
    Remove-Item $collision -Force
    $roleTarget=Get-TestMap @((Get-TestContract 'runtime/venv' 'python' 'runtime-v2'),(Get-TestContract 'python/managed/python' 'python' 'python-v1'),(Get-TestContract 'forensic/new.json' 'new-receipt' 'new-v1'))
    $badRoleTarget=[pscustomobject]@{Release=$targetRelease;ReleaseManifestSha256=('B'*64);DistributionMap=$targetDist;ManagedContractsMap=$roleTarget}
    Test-ExpectedFailure -Action {Get-VllmUpdateTransitionPlan -SourceContext $source -TargetContext $badRoleTarget|Out-Null} -Name 'managed-role-change' -Expected 'semantic role'
    Write-Host 'UPDATE_PLANNER_ADVERSARIAL_OK'
    Write-Host 'UPDATE_PLANNER_TEST_OK'
}finally{if(Test-Path $base){Remove-Item $base -Recurse -Force}}
