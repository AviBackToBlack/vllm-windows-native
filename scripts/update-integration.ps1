Set-StrictMode -Version Latest

function Get-VllmUpdateIntegrationManagedPlan {
    param([Parameter(Mandatory)]$Plan)
    $staging=@(Get-VllmUpdateManagedStagingPlan -Plan $Plan)
    foreach($item in $staging){
        if($item.Role-in@('python','uv','cache') -and $item.Mode-ne'reuse-live'){
            throw "SM-18E v1 requires managed $($item.Role) to be reused live; target contract changes for this role are not supported."
        }
        if($item.Role-in@('python-receipt','uv-receipt') -and $item.Mode-ne'reuse-live'){
            throw "SM-18E v1 requires $($item.Role) to remain reusable with the live Python/uv toolchain."
        }
        if($item.Role-eq'runtime' -and $item.Mode-notin@('reuse-live','relocate-tree')){
            throw "SM-18E v1 does not support runtime staging mode '$($item.Mode)'."
        }
    }

    $runtime=@($staging|Where-Object{$_.Role-eq'runtime'})
    if($runtime.Count-ne1){throw 'SM-18E requires exactly one runtime managed contract.'}
    foreach($role in @('venv-receipt','dependency-receipt','runtime-receipt')){
        $targets=@($staging|Where-Object{$_.Role-eq$role-and$_.Class-ne'retire'})
        if($targets.Count-ne1){throw "SM-18E requires exactly one target managed entry for $role."}
        if($runtime[0].Mode-eq'reuse-live'){
            if($targets[0].Mode-ne'reuse-live'){throw "A reused runtime requires reused $role."}
        }else{
            if($role-eq'runtime-receipt'){
                if($targets[0].Mode-ne'regenerate-final'){throw 'A changed runtime requires a regenerated runtime-receipt.'}
            }elseif($targets[0].Mode-notin@('reuse-live','regenerate-final')){
                throw "A changed runtime does not support $role staging mode '$($targets[0].Mode)'."
            }
        }
    }
    return $staging
}
function Get-VllmUpdatePersistedTreeIdentity {
    param([Parameter(Mandatory)][string]$Root)
    $identity=Get-VllmUpdateTreeIdentity -Root $Root
    [pscustomobject][ordered]@{
        entry_count=[int]$identity.EntryCount
        file_count=[int]$identity.FileCount
        tree_sha256=([string]$identity.TreeSha256).ToUpperInvariant()
    }
}

function Get-VllmUpdatePersistedFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    [pscustomobject][ordered]@{
        size_bytes=[int64]$item.Length
        sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Copy-VllmUpdateIntegrationTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $sourceIdentity=Get-VllmUpdateTreeIdentity -Root $Source
    if(Test-Path -LiteralPath $Destination){throw "Integration destination already exists: $Destination"}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    $targetIdentity=Get-VllmUpdateTreeIdentity -Root $Destination
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $sourceIdentity -B $targetIdentity)){
        throw "Integration tree copy identity mismatch: $Destination"
    }
}

function Copy-VllmUpdateIntegrationPayload {
    param(
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    [void][IO.Directory]::CreateDirectory($DestinationRoot)
    foreach($entry in @($TargetContext.DistributionMap.Values|Sort-Object RelativePath)){
        $destination=Join-Path $DestinationRoot ([string]$entry.RelativePath)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath ([string]$entry.Path) -Destination $destination
        $item=Get-Item -LiteralPath $destination
        $sha=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if([int64]$item.Length-ne[int64]$entry.Size-or$sha-ne[string]$entry.Sha256){
            throw "Materialization payload identity mismatch: $($entry.RelativePath)"
        }
    }
}

function Invoke-VllmUpdateIntegrationScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$Parameters
    )
    if(-not(Test-Path -LiteralPath $Script -PathType Leaf)){throw "Target bootstrap script is missing: $Script"}
    $raw=@(& $Script @Parameters)
    $text=($raw-join[Environment]::NewLine).Trim()
    if([string]::IsNullOrWhiteSpace($text)){throw "Target bootstrap script returned no JSON: $Script"}
    try{$value=$text|ConvertFrom-Json}catch{throw "Target bootstrap script returned invalid JSON: $Script :: $text"}
    if($null-eq$value-or-not[bool]$value.ready){throw "Target bootstrap script did not report ready: $Script"}
    return $value
}

function Invoke-VllmUpdateIntegrationVenvRebase {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$FinalPythonRoot,
        [Parameter(Mandatory)][string]$MaterializationRoot
    )
    $cfg=Join-Path $RuntimeRoot 'pyvenv.cfg'
    if(-not(Test-Path -LiteralPath $cfg -PathType Leaf)){throw "Materialized runtime pyvenv.cfg is missing: $cfg"}
    $lines=@(Get-Content -LiteralPath $cfg)
    $homeEntries=@($lines|Where-Object{$_ -like 'home = *'})
    if($homeEntries.Count-ne1){throw 'Materialized runtime pyvenv.cfg must contain exactly one home entry.'}
    $updated=New-Object System.Collections.Generic.List[string]
    foreach($line in $lines){
        if($line -like 'home = *'){$updated.Add('home = '+(Get-VllmNormalizedPath $FinalPythonRoot))}
        else{$updated.Add([string]$line)}
    }
    if($updated -notcontains 'relocatable = true'){throw 'Materialized runtime is not marked relocatable.'}
    $text=($updated.ToArray()-join([string][char]10))+[string][char]10
    [IO.File]::WriteAllText($cfg,$text,[Text.UTF8Encoding]::new($false))

    $materialized=Get-VllmNormalizedPath $MaterializationRoot
    foreach($file in @(Get-ChildItem (Join-Path $RuntimeRoot 'Scripts') -File -ErrorAction Stop)){
        if($file.Extension-in@('.exe','.dll','.pyd')){continue}
        $content=[IO.File]::ReadAllText($file.FullName)
        if($content.IndexOf($materialized,[StringComparison]::OrdinalIgnoreCase)-ge0){
            throw "Materialized runtime text launcher leaks the materialization root: $($file.FullName)"
        }
    }
}

function Write-VllmUpdateIntegrationJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $parent=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($parent)
    $json=$Value|ConvertTo-Json -Depth 24
    $json=$json.Replace([Environment]::NewLine,[string][char]10)+[string][char]10
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
    try{$parsed=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "Staged update JSON failed semantic re-read: $Path"}
    if($null-eq$parsed){throw "Staged update JSON parsed to null: $Path"}
    return Get-VllmUpdatePersistedFileIdentity -Path $Path
}

function Get-VllmUpdateIntegrationFinalPaths {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$TargetContext
    )
    $release=$TargetContext.Release
    $pythonRelative=[string]$TargetContext.PythonManifest.install.managed_relative_path
    $pythonExeRelative=[string]$TargetContext.PythonManifest.install.python_executable
    $uvRelative=[string]$TargetContext.UvManifest.install.managed_relative_path
    $uvExeRelative=[string]$TargetContext.UvManifest.install.uv_executable
    $runtimeRelative=[string]$release.orchestration.runtime_root
    [pscustomobject][ordered]@{
        PythonRoot=(Join-Path $InstallationRoot $pythonRelative)
        Python=(Join-Path (Join-Path $InstallationRoot $pythonRelative) $pythonExeRelative)
        UvRoot=(Join-Path $InstallationRoot $uvRelative)
        Uv=(Join-Path (Join-Path $InstallationRoot $uvRelative) $uvExeRelative)
        RuntimeRoot=(Join-Path $InstallationRoot $runtimeRelative)
        RuntimePython=(Join-Path (Join-Path $InstallationRoot $runtimeRelative) 'Scripts\python.exe')
        Cache=(Join-Path $InstallationRoot ([string]$TargetContext.DependencyManifest.materialization.cache_relative_path))
        VenvManifest=(Join-Path $InstallationRoot ([string]$release.orchestration.venv_manifest))
        DependencyManifest=(Join-Path $InstallationRoot ([string]$release.orchestration.dependency_manifest))
        RuntimeManifest=(Join-Path $InstallationRoot ([string]$release.orchestration.runtime_manifest))
        PythonManifest=(Join-Path $InstallationRoot ([string]$release.orchestration.python_manifest))
        UvManifest=(Join-Path $InstallationRoot ([string]$release.orchestration.uv_manifest))
        VenvReceipt=(Join-Path $InstallationRoot ([string]$release.orchestration.venv_receipt))
        DependencyReceipt=(Join-Path $InstallationRoot ([string]$release.orchestration.dependency_receipt))
        RuntimeReceipt=(Join-Path $InstallationRoot ([string]$release.orchestration.runtime_receipt))
        DependencyLock=(Join-Path $InstallationRoot ([string]$TargetContext.DependencyManifest.lock.path))
        RuntimeLock=(Join-Path $InstallationRoot ([string]$TargetContext.RuntimeManifest.lock.path))
        PackageMap=(Join-Path $InstallationRoot ([string]$TargetContext.RuntimeManifest.accepted_packages.path))
    }
}

function Initialize-VllmUpdateRuntimeMaterialization {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext
    )
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    if((Get-VllmPathEntryInfo -Path $paths.MaterializationRoot).Exists){throw "Update materialization root already exists: $($paths.MaterializationRoot)"}
    [void][IO.Directory]::CreateDirectory($paths.MaterializationRoot)
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $paths.InstallationRoot -Path $paths.MaterializationRoot -RelativePath $paths.MaterializationRelative)

    $payloadRoot=Join-Path $paths.MaterializationRoot 'p'
    $isolatedRoot=Join-Path $paths.MaterializationRoot 'r'
    [void][IO.Directory]::CreateDirectory($isolatedRoot)
    Copy-VllmUpdateIntegrationPayload -TargetContext $TargetContext -DestinationRoot $payloadRoot

    $pythonRelative=[string]$TargetContext.PythonManifest.install.managed_relative_path
    $uvRelative=[string]$TargetContext.UvManifest.install.managed_relative_path
    $cacheRelative=[string]$TargetContext.DependencyManifest.materialization.cache_relative_path
    $sourcePython=[string]$SourceContext.Committed.State.python.root
    $sourceUv=[string]$SourceContext.Committed.State.uv.root
    $sourceCache=Join-Path $paths.InstallationRoot $cacheRelative

    Copy-VllmUpdateIntegrationTree -Source $sourcePython -Destination (Join-Path $isolatedRoot $pythonRelative)
    Copy-VllmUpdateIntegrationTree -Source $sourceUv -Destination (Join-Path $isolatedRoot $uvRelative)
    if(-not(Test-Path -LiteralPath $sourceCache -PathType Container)){throw "Reused uv cache is missing: $sourceCache"}
    Assert-VllmUpdateManagedTreeNoReparsePoints -Path $sourceCache -Label 'Reused uv cache'
    $isolatedCache=Join-Path $isolatedRoot $cacheRelative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $isolatedCache))
    Copy-Item -LiteralPath $sourceCache -Destination $isolatedCache -Recurse

    [pscustomobject][ordered]@{
        Paths=$paths
        PayloadRoot=$payloadRoot
        IsolatedRoot=$isolatedRoot
        FinalPaths=(Get-VllmUpdateIntegrationFinalPaths -InstallationRoot $paths.InstallationRoot -TargetContext $TargetContext)
    }
}

function Invoke-VllmUpdateRuntimeMaterialization {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$WheelPath
    )
    $materialization=Initialize-VllmUpdateRuntimeMaterialization -InstallationRoot $InstallationRoot -TransactionId $TransactionId -SourceContext $SourceContext -TargetContext $TargetContext
    $release=$TargetContext.Release
    $payloadRoot=$materialization.PayloadRoot
    $isolatedRoot=$materialization.IsolatedRoot

    [void](Invoke-VllmUpdateIntegrationScript -Script (Join-Path $payloadRoot 'bootstrap-venv.ps1') -Parameters @{
        ManifestPath=(Join-Path $payloadRoot ([string]$release.orchestration.venv_manifest));InstallationRoot=$isolatedRoot;Json=$true
    })
    [void](Invoke-VllmUpdateIntegrationScript -Script (Join-Path $payloadRoot 'bootstrap-dependencies.ps1') -Parameters @{
        ManifestPath=(Join-Path $payloadRoot ([string]$release.orchestration.dependency_manifest));InstallationRoot=$isolatedRoot;Offline=$true;Json=$true
    })
    $final=Invoke-VllmUpdateIntegrationScript -Script (Join-Path $payloadRoot 'bootstrap-vllm.ps1') -Parameters @{
        ManifestPath=(Join-Path $payloadRoot ([string]$release.orchestration.runtime_manifest));InstallationRoot=$isolatedRoot;WheelPath=$WheelPath;Offline=$true;Json=$true
    }

    $runtimeRelative=[string]$release.orchestration.runtime_root
    $isolatedRuntime=Join-Path $isolatedRoot $runtimeRelative
    $finalPaths=$materialization.FinalPaths
    Invoke-VllmUpdateIntegrationVenvRebase -RuntimeRoot $isolatedRuntime -FinalPythonRoot $finalPaths.PythonRoot -MaterializationRoot $materialization.Paths.MaterializationRoot

    $expectedVersion=[string]$TargetContext.PythonManifest.version
    $expectedBits=[int]$TargetContext.VenvManifest.acceptance.expected_pointer_bits
    if(-not(Test-VllmUpdateRelocatableVenvTree -Root $isolatedRuntime -ExpectedPythonVersion $expectedVersion -ExpectedPointerBits $expectedBits -ExpectedBasePythonRoot $finalPaths.PythonRoot)){
        throw 'Materialized target runtime failed final-path relocation validation.'
    }

    $receiptOutput=Join-Path $materialization.Paths.MaterializationRoot 'f'
    $receipts=Write-VllmUpdateIntegrationRuntimeReceipts -InstallationRoot $materialization.Paths.InstallationRoot -OutputRoot $receiptOutput -TargetContext $TargetContext -ManagedPlan $ManagedPlan -MaterializedRoot $isolatedRoot

    [pscustomobject][ordered]@{
        Paths=$materialization.Paths
        FinalResult=$final
        RuntimeRelative=$runtimeRelative
        RuntimeSource=$isolatedRuntime
        RuntimeIdentity=(Get-VllmUpdatePersistedTreeIdentity -Root $isolatedRuntime)
        Receipts=$receipts
        FinalPaths=$finalPaths
        ExpectedPythonVersion=$expectedVersion
        ExpectedPointerBits=$expectedBits
    }
}
function Get-VllmUpdateTargetDistributionState {
    param([Parameter(Mandatory)]$TargetContext)
    @($TargetContext.DistributionMap.Values|Sort-Object RelativePath|ForEach-Object{
        [pscustomobject][ordered]@{
            path=[string]$_.RelativePath
            size_bytes=[int64]$_.Size
            sha256=([string]$_.Sha256).ToUpperInvariant()
        }
    })
}

function Get-VllmUpdateTargetRuntimeState {
    param(
        [Parameter(Mandatory)]$SourceState,
        [Parameter(Mandatory)]$FinalPaths,
        $Materialization
    )
    if($null-eq$Materialization){
        return [pscustomobject][ordered]@{
            root=[string]$SourceState.runtime.root
            python=[string]$SourceState.runtime.python
            package_count=[int]$SourceState.runtime.package_count
            vllm_version=[string]$SourceState.runtime.vllm_version
            dependency_receipt=[string]$SourceState.runtime.dependency_receipt
            dependency_receipt_sha256=[string]$SourceState.runtime.dependency_receipt_sha256
            final_receipt=[string]$SourceState.runtime.final_receipt
            final_receipt_sha256=[string]$SourceState.runtime.final_receipt_sha256
            lock_sha256=[string]$SourceState.runtime.lock_sha256
            wheel_sha256=[string]$SourceState.runtime.wheel_sha256
        }
    }
    $runtimeReceipt=$Materialization.Receipts.Runtime.Value
    [pscustomobject][ordered]@{
        root=$FinalPaths.RuntimeRoot
        python=$FinalPaths.RuntimePython
        package_count=[int]$runtimeReceipt.package_count
        vllm_version=[string]$runtimeReceipt.vllm_version
        dependency_receipt=$FinalPaths.DependencyReceipt
        dependency_receipt_sha256=[string]$Materialization.Receipts.Dependency.Identity.sha256
        final_receipt=$FinalPaths.RuntimeReceipt
        final_receipt_sha256=[string]$Materialization.Receipts.Runtime.Identity.sha256
        lock_sha256=[string]$runtimeReceipt.lock_sha256
        wheel_sha256=[string]$runtimeReceipt.wheel_sha256
    }
}

function ConvertTo-VllmUpdateCanonicalTimestamp {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Label
    )
    if($Value -is [DateTimeOffset]){
        return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')
    }
    if($Value -is [DateTime]){
        return ([DateTime]$Value).ToUniversalTime().ToString('o')
    }
    $parsed=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AllowWhiteSpaces,[ref]$parsed)){
        throw "$Label timestamp is invalid."
    }
    return $parsed.ToUniversalTime().ToString('o')
}

function Get-VllmUpdateTargetInstallState {
    param(
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][string]$GenerationId,
        $Materialization
    )
    $root=[string]$SourceContext.Committed.Root
    $sourceState=$SourceContext.Committed.State
    $release=$TargetContext.Release
    $final=Get-VllmUpdateIntegrationFinalPaths -InstallationRoot $root -TargetContext $TargetContext

    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.python.root) -B $final.PythonRoot)){throw 'Reused Python root does not match target final path.'}
    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.python.python) -B $final.Python)){throw 'Reused Python executable does not match target final path.'}
    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.uv.root) -B $final.UvRoot)){throw 'Reused uv root does not match target final path.'}
    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.uv.uv) -B $final.Uv)){throw 'Reused uv executable does not match target final path.'}

    $pythonReceipt=Join-Path $root ([string]$release.orchestration.python_receipt)
    $uvReceipt=Join-Path $root ([string]$release.orchestration.uv_receipt)
    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.python.receipt) -B $pythonReceipt)){throw 'Reused Python receipt path changed in target release.'}
    if(-not(Test-VllmUpdatePathEqual -A ([string]$sourceState.uv.receipt) -B $uvReceipt)){throw 'Reused uv receipt path changed in target release.'}

    $runtime=Get-VllmUpdateTargetRuntimeState -SourceState $sourceState -FinalPaths $final -Materialization $Materialization
    $now=(Get-Date).ToUniversalTime().ToString('o')
    [pscustomobject][ordered]@{
        schema_version=1;component='install-state';release=[string]$release.release;platform=[string]$release.platform;ready=$true
        generation_id=([guid]$GenerationId).ToString('D').ToLowerInvariant()
        install_root=$root;models_root=[string]$SourceContext.ModelsRoot
        release_manifest=(Join-Path $root ([string]$release.self_path))
        release_manifest_sha256=([string]$TargetContext.ReleaseManifestSha256).ToUpperInvariant()
        upstream=[pscustomobject][ordered]@{repository=[string]$release.upstream.repository;tag=[string]$release.upstream.tag;commit=[string]$release.upstream.commit}
        windows_patchset=[pscustomobject][ordered]@{implementation_commit=[string]$release.windows_patchset.implementation_commit;tree=[string]$release.windows_patchset.tree;patch_sha256=[string]$release.windows_patchset.patch_sha256}
        wheel=[pscustomobject][ordered]@{filename=[string]$release.wheel.filename;version=[string]$release.wheel.version;size_bytes=[int64]$release.wheel.size_bytes;sha256=([string]$release.wheel.sha256).ToUpperInvariant()}
        python=[pscustomobject][ordered]@{version=[string]$sourceState.python.version;root=$final.PythonRoot;python=$final.Python;archive_sha256=[string]$sourceState.python.archive_sha256;receipt=$pythonReceipt;receipt_sha256=[string]$sourceState.python.receipt_sha256}
        uv=[pscustomobject][ordered]@{version=[string]$sourceState.uv.version;root=$final.UvRoot;uv=$final.Uv;archive_sha256=[string]$sourceState.uv.archive_sha256;receipt=$uvReceipt;receipt_sha256=[string]$sourceState.uv.receipt_sha256}
        runtime=$runtime
        distribution_files=@(Get-VllmUpdateTargetDistributionState -TargetContext $TargetContext)
        managed_paths=@($release.managed_paths)
        installed_at=(ConvertTo-VllmUpdateCanonicalTimestamp -Value $sourceState.installed_at -Label 'Source installed_at')
        updated_at=$now
    }
}

function Get-VllmUpdateProvisionalManagedActivationPlan {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][object[]]$ManagedPlan
    )
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    $result=New-Object System.Collections.Generic.List[object]
    foreach($item in @($ManagedPlan|Where-Object{$_.Class-ne'reuse'}|Sort-Object RelativePath)){
        $class=[string]$item.Class
        $role=[string]$item.Role
        $relative=[string]$item.RelativePath
        $kind=if($role-eq'runtime'){'tree'}else{'file'}
        $live=Join-Path $paths.InstallationRoot $relative

        $source=$null
        if($class-in@('replace','retire')){
            if($kind-eq'tree'){$source=Get-VllmUpdatePersistedTreeIdentity -Root $live}
            else{$source=Get-VllmUpdatePersistedFileIdentity -Path $live}
        }

        if($class-eq'retire'){
            $result.Add([pscustomobject][ordered]@{
                class=$class;kind=$kind;role=$role;relative_path=$relative
                source=$source;target=$null;stage_relative=$null;backup_relative=$null
            })
            continue
        }

        if([string]::IsNullOrWhiteSpace([string]$item.TargetContract)){throw "Managed target contract is empty: $relative"}
        $stageRelative=[string]$paths.ManagedRelative+'\'+$relative
        $backupRelative=if($class-eq'replace'){[string]$paths.BackupManagedRelative+'\'+$relative}else{$null}
        $result.Add([pscustomobject][ordered]@{
            class=$class;kind=$kind;role=$role;relative_path=$relative
            source=$source;target=$null;target_contract=[string]$item.TargetContract
            stage_relative=$stageRelative;backup_relative=$backupRelative
        })
    }
    $result.ToArray()
}

function Get-VllmUpdateProvisionalActivationPlan {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][object[]]$ManagedPlan
    )
    $items=New-Object System.Collections.Generic.List[object]
    foreach($item in @(Get-VllmUpdateActivationPlan -InstallationRoot $InstallationRoot -ModelsRoot $ModelsRoot -TransactionId $TransactionId -DistributionPlan @($Plan.distribution))){$items.Add($item)}
    foreach($item in @(Get-VllmUpdateProvisionalManagedActivationPlan -InstallationRoot $InstallationRoot -TransactionId $TransactionId -ManagedPlan $ManagedPlan)){$items.Add($item)}
    $items.ToArray()
}

function Get-VllmUpdateIntegrationManagedTargetEntry {
    param([Parameter(Mandatory)][object[]]$ManagedPlan,[Parameter(Mandatory)][string]$Role)
    $entry=@($ManagedPlan|Where-Object{$_.Role-eq$Role-and$_.Class-ne'retire'})
    if($entry.Count-ne1){throw "Expected exactly one target managed entry for role '$Role'."}
    return $entry[0]
}

function Write-VllmUpdateIntegrationMaterializedReceipt {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$Value
    )
    $relative=Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label 'Materialized receipt path'
    $path=Join-Path $OutputRoot $relative
    if(Test-Path -LiteralPath $path){throw "Materialized receipt output already exists: $path"}
    $identity=Write-VllmUpdateIntegrationJson -Path $path -Value $Value
    [pscustomobject][ordered]@{
        Mode='regenerate-final';RelativePath=$relative;MaterializedPath=$path
        Identity=$identity;Value=$Value
    }
}

function Get-VllmUpdateIntegrationReusedReceipt {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $relative=Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label 'Reused receipt path'
    $path=Join-Path $InstallationRoot $relative
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Reused receipt is missing: $path"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $path -RelativePath $relative)
    [pscustomobject][ordered]@{
        Mode='reuse-live';RelativePath=$relative;FinalPath=$path
        Identity=(Get-VllmUpdatePersistedFileIdentity -Path $path)
        Value=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)
    }
}

function Get-VllmUpdateIntegrationVenvReceiptTarget {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$MaterializedRoot,
        [Parameter(Mandatory)]$FinalPaths
    )
    $entry=Get-VllmUpdateIntegrationManagedTargetEntry -ManagedPlan $ManagedPlan -Role 'venv-receipt'
    if($entry.Mode-eq'reuse-live'){
        return Get-VllmUpdateIntegrationReusedReceipt -InstallationRoot $InstallationRoot -RelativePath ([string]$entry.RelativePath)
    }
    $source=Join-Path $MaterializedRoot ([string]$TargetContext.Release.orchestration.venv_receipt)
    $value=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
    if([string]$value.component-ne'runtime-venv'){throw 'Materialized venv receipt has unexpected component.'}
    $value.root=$FinalPaths.RuntimeRoot
    $value.python=$FinalPaths.RuntimePython
    $value.base_python=$FinalPaths.Python
    $value.uv=$FinalPaths.Uv
    $value.python_bootstrap_manifest=$FinalPaths.PythonManifest
    $value.uv_bootstrap_manifest=$FinalPaths.UvManifest
    $value.manifest=$FinalPaths.VenvManifest
    return Write-VllmUpdateIntegrationMaterializedReceipt -OutputRoot $OutputRoot -RelativePath ([string]$entry.RelativePath) -Value $value
}

function Get-VllmUpdateIntegrationDependencyReceiptTarget {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$MaterializedRoot,
        [Parameter(Mandatory)]$FinalPaths,
        [Parameter(Mandatory)]$VenvReceipt
    )
    $entry=Get-VllmUpdateIntegrationManagedTargetEntry -ManagedPlan $ManagedPlan -Role 'dependency-receipt'
    if($entry.Mode-eq'reuse-live'){
        $result=Get-VllmUpdateIntegrationReusedReceipt -InstallationRoot $InstallationRoot -RelativePath ([string]$entry.RelativePath)
        if([string]$result.Value.base_venv_receipt_sha256-ne[string]$VenvReceipt.Identity.sha256){
            throw 'Reused dependency receipt does not chain to the final venv receipt identity.'
        }
        return $result
    }
    $source=Join-Path $MaterializedRoot ([string]$TargetContext.Release.orchestration.dependency_receipt)
    $value=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
    if([string]$value.component-ne'runtime-dependencies'){throw 'Materialized dependency receipt has unexpected component.'}
    $value.root=$FinalPaths.RuntimeRoot
    $value.python=$FinalPaths.RuntimePython
    $value.base_python=$FinalPaths.Python
    $value.uv=$FinalPaths.Uv
    $value.lock=$FinalPaths.DependencyLock
    $value.cache=$FinalPaths.Cache
    $value.base_venv_manifest=$FinalPaths.VenvManifest
    $value.base_venv_receipt=$FinalPaths.VenvReceipt
    $value.base_venv_receipt_sha256=[string]$VenvReceipt.Identity.sha256
    $value.manifest=$FinalPaths.DependencyManifest
    return Write-VllmUpdateIntegrationMaterializedReceipt -OutputRoot $OutputRoot -RelativePath ([string]$entry.RelativePath) -Value $value
}

function Get-VllmUpdateIntegrationRuntimeReceiptTarget {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$MaterializedRoot,
        [Parameter(Mandatory)]$FinalPaths,
        [Parameter(Mandatory)]$DependencyReceipt
    )
    $entry=Get-VllmUpdateIntegrationManagedTargetEntry -ManagedPlan $ManagedPlan -Role 'runtime-receipt'
    if($entry.Mode-ne'regenerate-final'){throw 'Changed runtime must regenerate its final runtime receipt.'}
    $source=Join-Path $MaterializedRoot ([string]$TargetContext.Release.orchestration.runtime_receipt)
    $value=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
    if([string]$value.component-ne'vllm-runtime'){throw 'Materialized vLLM receipt has unexpected component.'}
    $value.root=$FinalPaths.RuntimeRoot
    $value.python=$FinalPaths.RuntimePython
    $value.base_python=$FinalPaths.Python
    $value.uv=$FinalPaths.Uv
    $value.lock=$FinalPaths.RuntimeLock
    $value.package_map=$FinalPaths.PackageMap
    $value.predecessor_manifest=$FinalPaths.DependencyManifest
    $value.predecessor_receipt=$FinalPaths.DependencyReceipt
    $value.predecessor_receipt_sha256=[string]$DependencyReceipt.Identity.sha256
    $value.manifest=$FinalPaths.RuntimeManifest
    $value.cache=$FinalPaths.Cache
    return Write-VllmUpdateIntegrationMaterializedReceipt -OutputRoot $OutputRoot -RelativePath ([string]$entry.RelativePath) -Value $value
}

function Write-VllmUpdateIntegrationRuntimeReceipts {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$MaterializedRoot
    )
    $final=Get-VllmUpdateIntegrationFinalPaths -InstallationRoot $InstallationRoot -TargetContext $TargetContext
    [void][IO.Directory]::CreateDirectory($OutputRoot)
    $venv=Get-VllmUpdateIntegrationVenvReceiptTarget -InstallationRoot $InstallationRoot -OutputRoot $OutputRoot -TargetContext $TargetContext -ManagedPlan $ManagedPlan -MaterializedRoot $MaterializedRoot -FinalPaths $final
    $dependency=Get-VllmUpdateIntegrationDependencyReceiptTarget -InstallationRoot $InstallationRoot -OutputRoot $OutputRoot -TargetContext $TargetContext -ManagedPlan $ManagedPlan -MaterializedRoot $MaterializedRoot -FinalPaths $final -VenvReceipt $venv
    $runtime=Get-VllmUpdateIntegrationRuntimeReceiptTarget -OutputRoot $OutputRoot -TargetContext $TargetContext -ManagedPlan $ManagedPlan -MaterializedRoot $MaterializedRoot -FinalPaths $final -DependencyReceipt $dependency
    [pscustomobject][ordered]@{Venv=$venv;Dependency=$dependency;Runtime=$runtime}
}

function Get-VllmUpdateMaterializedTargetEvidence {
    param(
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)]$Materialization
    )
    $result=New-Object System.Collections.Generic.List[object]
    foreach($item in @($ManagedPlan|Where-Object{$_.Class-in@('replace','add')}|Sort-Object RelativePath)){
        $role=[string]$item.Role
        $identity=$null
        if($role-eq'runtime'){
            $identity=$Materialization.RuntimeIdentity
        }else{
            $receipt=switch($role){
                'venv-receipt'{$Materialization.Receipts.Venv}
                'dependency-receipt'{$Materialization.Receipts.Dependency}
                'runtime-receipt'{$Materialization.Receipts.Runtime}
                default{throw "No SM-18E materialized target evidence exists for managed role '$role'."}
            }
            if([string]$receipt.Mode-ne'regenerate-final'){throw "Managed role '$role' changed but has no regenerated final receipt evidence."}
            $identity=$receipt.Identity
        }
        $result.Add([pscustomobject][ordered]@{
            relative_path=[string]$item.RelativePath
            target_contract=[string]$item.TargetContract
            identity=$identity
        })
    }
    $result.ToArray()
}

function Copy-VllmUpdateManagedFileStage {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FinalRelativePath,
        [Parameter(Mandatory)]$ExpectedIdentity
    )
    [void](Assert-VllmUpdateStagingWorkspace -Layout $Layout)
    $source=Get-VllmNormalizedPath $SourcePath
    if(-not(Test-VllmPathInsideOrEqual -Path $source -Parent $Layout.InstallationRoot)){throw "Managed stage source is outside the installation root: $source"}
    $sourceRelative=$source.Substring(([string]$Layout.InstallationRoot).Length).TrimStart('\')
    $sourceRelative=Assert-VllmSafeRelativePath -RelativePath $sourceRelative -Label 'Managed stage source path'
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $source -RelativePath $sourceRelative)
    $sourceIdentity=Get-VllmUpdatePersistedFileIdentity -Path $source
    if([int64]$sourceIdentity.size_bytes-ne[int64]$ExpectedIdentity.size_bytes-or[string]$sourceIdentity.sha256-ne[string]$ExpectedIdentity.sha256){
        throw "Managed stage source identity drifted: $source"
    }

    $stage=Get-VllmUpdateManagedStagePath -Layout $Layout -FinalRelativePath $FinalRelativePath
    if((Get-VllmPathEntryInfo -Path $stage.StagePath).Exists){throw "Managed staged destination already exists: $($stage.StagePath)"}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $stage.StagePath))
    Copy-Item -LiteralPath $source -Destination $stage.StagePath
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $stage.StagePath -RelativePath $stage.StageRelative)
    $staged=Get-VllmUpdatePersistedFileIdentity -Path $stage.StagePath
    if([int64]$staged.size_bytes-ne[int64]$ExpectedIdentity.size_bytes-or[string]$staged.sha256-ne[string]$ExpectedIdentity.sha256){
        throw "Managed staged file identity differs from materialized source: $FinalRelativePath"
    }
    return $stage
}

function Publish-VllmUpdateMaterializedTargetsToStage {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)]$Materialization
    )
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $InstallationRoot
    if($null-eq$journal-or[string]$journal.phase-ne'materializing'){throw 'Managed staging publication requires a materializing transaction.'}
    foreach($entry in @($journal.activation_plan)){
        if($entry.PSObject.Properties.Name -contains 'target_contract'){
            if([string]$entry.class-in@('replace','add')-and$null-eq$entry.target){
                throw "Managed staging publication refuses unresolved journal target: $($entry.relative_path)"
            }
        }
    }

    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    $runtimeEntry=@($ManagedPlan|Where-Object{$_.Role-eq'runtime'-and$_.Class-in@('replace','add')})
    if($runtimeEntry.Count-ne1){throw 'Changed runtime must have exactly one staged target entry.'}
    $runtimeStage=Copy-VllmUpdateManagedTreeStage -Layout $layout -SourceRoot $Materialization.RuntimeSource -FinalRelativePath ([string]$runtimeEntry[0].RelativePath) -Role runtime -ExpectedPythonVersion ([string]$Materialization.ExpectedPythonVersion) -ExpectedPointerBits ([int]$Materialization.ExpectedPointerBits) -ExpectedBasePythonRoot ([string]$Materialization.FinalPaths.PythonRoot)

    $receiptStages=New-Object System.Collections.Generic.List[object]
    foreach($item in @($ManagedPlan|Where-Object{$_.Role-in@('venv-receipt','dependency-receipt','runtime-receipt')-and$_.Class-in@('replace','add')}|Sort-Object RelativePath)){
        $receipt=switch([string]$item.Role){
            'venv-receipt'{$Materialization.Receipts.Venv}
            'dependency-receipt'{$Materialization.Receipts.Dependency}
            'runtime-receipt'{$Materialization.Receipts.Runtime}
        }
        if([string]$receipt.Mode-ne'regenerate-final'){throw "Changed receipt role '$($item.Role)' has no regenerated materialized file."}
        $stage=Copy-VllmUpdateManagedFileStage -Layout $layout -SourcePath ([string]$receipt.MaterializedPath) -FinalRelativePath ([string]$item.RelativePath) -ExpectedIdentity $receipt.Identity
        $receiptStages.Add([pscustomobject][ordered]@{Role=[string]$item.Role;Stage=$stage;Identity=$receipt.Identity})
    }

    [pscustomobject][ordered]@{Layout=$layout;Runtime=$runtimeStage;Receipts=$receiptStages.ToArray()}
}

function Invoke-VllmUpdateProductionTransactionPreparation {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][object[]]$ManagedPlan,
        [Parameter(Mandatory)][string]$WheelPath
    )
    $targetGeneration=[guid]::NewGuid().ToString('D').ToLowerInvariant()
    $targetIdentity=[pscustomobject][ordered]@{
        release=[string]$Plan.target.release
        manifest_sha256=([string]$Plan.target.manifest_sha256).ToUpperInvariant()
        generation_id=$targetGeneration
    }
    $transactionId=[guid]::NewGuid().ToString('D').ToLowerInvariant()
    $runtimeTarget=@($ManagedPlan|Where-Object{$_.Role-eq'runtime'-and$_.Class-in@('replace','add')})
    if($runtimeTarget.Count-gt1){throw 'Update plan contains multiple changed runtime targets.'}
    if($runtimeTarget.Count-eq1){
        Assert-VllmUpdateRuntimeMaterializationPathBudget -InstallationRoot $InstallationRoot -TransactionId $transactionId -TargetContext $TargetContext
    }elseif(@($ManagedPlan|Where-Object{$_.Class-ne'reuse'}).Count-ne0){
        throw 'SM-18E v1 does not support managed mutations without a changed runtime target.'
    }
    $activationPlan=@(Get-VllmUpdateProvisionalActivationPlan -InstallationRoot $InstallationRoot -ModelsRoot $SourceContext.ModelsRoot -TransactionId $transactionId -Plan $Plan -ManagedPlan $ManagedPlan)
    [void](Open-VllmUpdateTransaction -InstallationRoot $InstallationRoot -ModelsRoot $SourceContext.ModelsRoot -SourceIdentity $Plan.source -TargetIdentity $targetIdentity -ActivationPlan $activationPlan -TransactionId $transactionId)

    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $InstallationRoot -TransactionId $transactionId
    [void](Copy-VllmUpdateDistributionStage -Layout $layout -Plan $Plan -TargetContext $TargetContext)

    $materialization=$null
    if($runtimeTarget.Count-eq1){
        $materialization=Invoke-VllmUpdateRuntimeMaterialization -InstallationRoot $InstallationRoot -TransactionId $transactionId -SourceContext $SourceContext -TargetContext $TargetContext -ManagedPlan $ManagedPlan -WheelPath $WheelPath
        $evidence=@(Get-VllmUpdateMaterializedTargetEvidence -ManagedPlan $ManagedPlan -Materialization $materialization)
        [void](Complete-VllmUpdateTransactionMaterializedTargets -InstallationRoot $InstallationRoot -MaterializedTargets $evidence)
        [void](Publish-VllmUpdateMaterializedTargetsToStage -InstallationRoot $InstallationRoot -TransactionId $transactionId -ManagedPlan $ManagedPlan -Materialization $materialization)
    }

    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $InstallationRoot)
    [pscustomobject][ordered]@{
        TransactionId=$transactionId
        TargetGeneration=$targetGeneration
        Materialization=$materialization
    }
}

function Complete-VllmUpdateProductionTransaction {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$SourceContext,
        [Parameter(Mandatory)]$TargetContext,
        [Parameter(Mandatory)]$Prepared,
        [scriptblock]$ValidateGeneration
    )
    $targetState=Get-VllmUpdateTargetInstallState -SourceContext $SourceContext -TargetContext $TargetContext -GenerationId ([string]$Prepared.TargetGeneration) -Materialization $Prepared.Materialization
    $expectedStateJson=((($targetState|ConvertTo-Json -Depth 24)|ConvertFrom-Json)|ConvertTo-Json -Depth 24 -Compress)
    $validateTargetState={
        param($value,$candidatePath)
        [void]$candidatePath
        $actual=((($value|ConvertTo-Json -Depth 24)|ConvertFrom-Json)|ConvertTo-Json -Depth 24 -Compress)
        if($actual-ne$expectedStateJson){throw 'Published target install-state differs from the prevalidated target state.'}
    }.GetNewClosure()

    $activation=Invoke-VllmUpdateTransactionActivation -InstallationRoot $InstallationRoot -TargetInstallState $targetState -ValidateTargetState $validateTargetState -ValidateGeneration $ValidateGeneration
    if(-not$activation.committed){throw 'Update transaction did not commit the target generation.'}
    [pscustomobject][ordered]@{
        schema_version=1
        component='update'
        ready=$true
        committed=$true
        release=[string]$TargetContext.Release.release
        generation_id=[string]$activation.generation_id
        install_root=$InstallationRoot
        models_root=[string]$SourceContext.ModelsRoot
        transaction_id=[string]$Prepared.TransactionId
    }
}

function Assert-VllmUpdateRuntimeMaterializationPathBudget {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)]$TargetContext
    )
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    $isolatedRoot=Join-Path $paths.MaterializationRoot 'r'
    $pythonRelative=[string]$TargetContext.PythonManifest.install.managed_relative_path
    $pythonExeRelative=[string]$TargetContext.PythonManifest.install.python_executable
    $uvRelative=[string]$TargetContext.UvManifest.install.managed_relative_path
    $uvExeRelative=[string]$TargetContext.UvManifest.install.uv_executable
    $runtimeRelative=[string]$TargetContext.Release.orchestration.runtime_root
    $dependencyStageRelative=[string]$TargetContext.DependencyManifest.materialization.staging_relative_path
    $runtimeStageRelative=[string]$TargetContext.RuntimeManifest.materialization.staging_relative_path

    $candidates=@(
        [pscustomobject]@{Label='isolated Python';Path=(Join-Path (Join-Path $isolatedRoot $pythonRelative) $pythonExeRelative)},
        [pscustomobject]@{Label='isolated uv';Path=(Join-Path (Join-Path $isolatedRoot $uvRelative) $uvExeRelative)},
        [pscustomobject]@{Label='isolated runtime Python';Path=(Join-Path (Join-Path $isolatedRoot $runtimeRelative) 'Scripts\python.exe')},
        [pscustomobject]@{Label='dependency staging Python';Path=(Join-Path (Join-Path $isolatedRoot $dependencyStageRelative) 'Scripts\python.exe')},
        [pscustomobject]@{Label='vLLM staging Python';Path=(Join-Path (Join-Path $isolatedRoot $runtimeStageRelative) 'Scripts\python.exe')},
        [pscustomobject]@{Label='transaction managed-stage Python';Path=(Join-Path (Join-Path $layout.ManagedRoot $runtimeRelative) 'Scripts\python.exe')}
    )
    foreach($candidate in $candidates){
        $full=[IO.Path]::GetFullPath([string]$candidate.Path)
        if($full.Length-ge260){
            throw "SM-18E materialization executable path exceeds the supported Win32 process-launch budget ($($full.Length) >= 260): $($candidate.Label) :: $full. Use a shorter installation root."
        }
    }
}
