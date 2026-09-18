Set-StrictMode -Version Latest

function Get-VllmUpdateStagingLayout {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $tx=[guid]::Empty
    if(-not[guid]::TryParse($TransactionId,[ref]$tx)-or$tx-eq[guid]::Empty){throw 'Update staging transaction_id must be a non-empty GUID.'}
    $id=$tx.ToString('D').ToLowerInvariant()
    $workspaceRelative='work\update-transaction'
    $transactionRelative=$workspaceRelative+'\'+$id
    $stagingRelative=$transactionRelative+'\staging'
    $distributionRelative=$stagingRelative+'\distribution'
    $managedRelative=$stagingRelative+'\managed'
    return [pscustomobject][ordered]@{
        TransactionId=$id;InstallationRoot=$root
        WorkspaceRelative=$workspaceRelative;WorkspaceRoot=(Join-Path $root $workspaceRelative)
        TransactionRelative=$transactionRelative;TransactionRoot=(Join-Path $root $transactionRelative)
        StagingRelative=$stagingRelative;StagingRoot=(Join-Path $root $stagingRelative)
        DistributionRelative=$distributionRelative;DistributionRoot=(Join-Path $root $distributionRelative)
        ManagedRelative=$managedRelative;ManagedRoot=(Join-Path $root $managedRelative)
    }
}

function Assert-VllmUpdateStagingWorkspace {
    param([Parameter(Mandatory)]$Layout)
    foreach($pair in @(
        @([string]$Layout.WorkspaceRoot,[string]$Layout.WorkspaceRelative),
        @([string]$Layout.TransactionRoot,[string]$Layout.TransactionRelative)
    )){
        $path=[string]$pair[0];$relative=[string]$pair[1]
        $entry=Get-VllmPathEntryInfo -Path $path
        if(-not$entry.Exists-or-not$entry.IsDirectory){throw "Update transaction workspace is missing: $path"}
        if($entry.IsReparsePoint){throw "Update transaction workspace must not be a reparse point: $path"}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $path -RelativePath $relative)
    }

    return $Layout
}

function Initialize-VllmUpdateStagingDirectories {
    param([Parameter(Mandatory)]$Layout)
    [void](Assert-VllmUpdateStagingWorkspace -Layout $Layout)
    if((Get-VllmPathEntryInfo -Path $Layout.StagingRoot).Exists){throw "Update staging root already exists; preserve it as transaction evidence: $($Layout.StagingRoot)"}
    foreach($pair in @(
        @([string]$Layout.StagingRoot,[string]$Layout.StagingRelative),
        @([string]$Layout.DistributionRoot,[string]$Layout.DistributionRelative),
        @([string]$Layout.ManagedRoot,[string]$Layout.ManagedRelative)
    )){
        [void][IO.Directory]::CreateDirectory([string]$pair[0])
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path ([string]$pair[0]) -RelativePath ([string]$pair[1]))
        if((Get-VllmPathEntryInfo -Path ([string]$pair[0])).IsReparsePoint){throw "Update staging directory unexpectedly became a reparse point: $($pair[0])"}
    }
    return $Layout
}

function Get-VllmUpdateDistributionStagePath {
    param([Parameter(Mandatory)]$Layout,[Parameter(Mandatory)][string]$RelativePath)
    $relative=Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label 'Staged distribution path'
    $stageRelative=[string]$Layout.DistributionRelative+'\'+$relative
    $stagePath=Join-Path ([string]$Layout.DistributionRoot) $relative
    return [pscustomobject][ordered]@{RelativePath=$relative;StageRelative=$stageRelative;StagePath=$stagePath}
}

function Copy-VllmUpdateDistributionStage {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$TargetContext
    )
    [void](Assert-VllmUpdateStagingWorkspace -Layout $Layout)
    if(-not(Test-Path -LiteralPath $Layout.DistributionRoot -PathType Container)){throw "Distribution staging root is missing: $($Layout.DistributionRoot)"}
    $results=New-Object System.Collections.Generic.List[object]
    foreach($item in @($Plan.distribution|Where-Object{$_.Class-in@('replace','add')}|Sort-Object RelativePath)){
        $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$item.RelativePath) -Label 'Distribution staging plan path'
        $key=Get-VllmUpdateRelativeKey $relative
        if(-not$TargetContext.DistributionMap.ContainsKey($key)){throw "Target context is missing staged distribution entry: $relative"}
        $target=$TargetContext.DistributionMap[$key]
        if($null-eq$item.Target-or[int64]$item.Target.Size-ne[int64]$target.Size-or[string]$item.Target.Sha256-ne[string]$target.Sha256){throw "Distribution staging plan identity disagrees with target context: $relative"}
        $stage=Get-VllmUpdateDistributionStagePath -Layout $Layout -RelativePath $relative
        if((Get-VllmPathEntryInfo -Path $stage.StagePath).Exists){throw "Staged distribution destination already exists: $($stage.StagePath)"}
        $parent=Split-Path -Parent $stage.StagePath
        [void][IO.Directory]::CreateDirectory($parent)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $parent -RelativePath (Split-Path -Parent $stage.StageRelative))
        Copy-Item -LiteralPath ([string]$target.Path) -Destination $stage.StagePath
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $stage.StagePath -RelativePath $stage.StageRelative)
        $entry=Get-VllmPathEntryInfo -Path $stage.StagePath
        if(-not$entry.Exists-or-not(Test-Path -LiteralPath $stage.StagePath -PathType Leaf)-or$entry.IsReparsePoint){throw "Staged distribution file is not a regular file: $($stage.StagePath)"}
        $size=[int64](Get-Item -LiteralPath $stage.StagePath).Length
        $sha=(Get-FileHash -LiteralPath $stage.StagePath -Algorithm SHA256).Hash
        if($size-ne[int64]$target.Size-or$sha-ne[string]$target.Sha256){throw "Staged distribution identity mismatch: $relative"}
        $results.Add([pscustomobject][ordered]@{
            Class=[string]$item.Class;RelativePath=$relative;StagePath=$stage.StagePath
            FinalPath=(Join-Path $Layout.InstallationRoot $relative);Size=$size;Sha256=$sha
        })
    }
    return $results.ToArray()
}

function Get-VllmUpdateManagedStagePath {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$FinalRelativePath
    )
    $relative=Assert-VllmSafeRelativePath -RelativePath $FinalRelativePath -Label 'Managed staging final path'
    $stageRelative=[string]$Layout.ManagedRelative+'\'+$relative
    $stagePath=Join-Path ([string]$Layout.ManagedRoot) $relative
    return [pscustomobject][ordered]@{
        RelativePath=$relative
        StageRelative=$stageRelative
        StagePath=$stagePath
        FinalPath=(Join-Path ([string]$Layout.InstallationRoot) $relative)
    }
}

function Copy-VllmUpdateManagedTreeStage {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$FinalRelativePath,
        [Parameter(Mandatory)][ValidateSet('python','uv','runtime')][string]$Role,
        [string]$ExpectedPythonVersion,
        [string]$ExpectedUvVersion,
        [string]$ExpectedUvCommitPrefix,
        [string]$ExpectedBasePythonRoot,
        [int]$ExpectedPointerBits
    )
    [void](Assert-VllmUpdateStagingWorkspace -Layout $Layout)
    if(-not(Test-Path -LiteralPath $Layout.ManagedRoot -PathType Container)){throw "Managed staging root is missing: $($Layout.ManagedRoot)"}
    $source=Get-VllmNormalizedPath $SourceRoot
    $sourceIdentity=Get-VllmUpdateTreeIdentity -Root $source
    $stage=Get-VllmUpdateManagedStagePath -Layout $Layout -FinalRelativePath $FinalRelativePath
    if((Get-VllmPathEntryInfo -Path $stage.StagePath).Exists){throw "Managed staged destination already exists: $($stage.StagePath)"}
    $parent=Split-Path -Parent $stage.StagePath
    [void][IO.Directory]::CreateDirectory($parent)
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $parent -RelativePath (Split-Path -Parent $stage.StageRelative))
    Copy-Item -LiteralPath $source -Destination $stage.StagePath -Recurse
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $Layout.InstallationRoot -Path $stage.StagePath -RelativePath $stage.StageRelative)
    $stageIdentity=Get-VllmUpdateTreeIdentity -Root $stage.StagePath
    if(-not(Test-VllmUpdateTreeIdentityEqual -A $sourceIdentity -B $stageIdentity)){throw "Managed staged tree identity differs from materialized source: $FinalRelativePath"}

    switch($Role){
        'python' {
            if([string]::IsNullOrWhiteSpace($ExpectedPythonVersion)){throw 'Python staging validation requires ExpectedPythonVersion.'}
            if(-not(Test-VllmUpdatePortablePythonTree -Root $stage.StagePath -ExpectedVersion $ExpectedPythonVersion)){throw 'Staged portable Python failed semantic validation.'}
        }
        'uv' {
            if([string]::IsNullOrWhiteSpace($ExpectedUvVersion)-or[string]::IsNullOrWhiteSpace($ExpectedUvCommitPrefix)){throw 'uv staging validation requires version and commit prefix.'}
            if(-not(Test-VllmUpdatePortableUvTree -Root $stage.StagePath -ExpectedVersion $ExpectedUvVersion -ExpectedCommitPrefix $ExpectedUvCommitPrefix)){throw 'Staged portable uv failed semantic validation.'}
        }
        'runtime' {
            if([string]::IsNullOrWhiteSpace($ExpectedPythonVersion)-or[string]::IsNullOrWhiteSpace($ExpectedBasePythonRoot)-or$ExpectedPointerBits-le0){throw 'Runtime staging validation requires Python version, pointer width, and final base Python root.'}
            if(-not(Test-VllmUpdateRelocatableVenvTree -Root $stage.StagePath -ExpectedPythonVersion $ExpectedPythonVersion -ExpectedPointerBits $ExpectedPointerBits -ExpectedBasePythonRoot $ExpectedBasePythonRoot)){throw 'Staged runtime venv failed semantic validation.'}
        }
    }

    return [pscustomobject][ordered]@{
        Role=$Role
        RelativePath=$stage.RelativePath
        StagePath=$stage.StagePath
        FinalPath=$stage.FinalPath
        TreeIdentity=$stageIdentity
    }
}

function Get-VllmUpdateTreeIdentity {
    param([Parameter(Mandatory)][string]$Root)
    $root=Get-VllmNormalizedPath $Root
    $rootEntry=Get-VllmPathEntryInfo -Path $root
    if(-not$rootEntry.Exists-or-not$rootEntry.IsDirectory-or$rootEntry.IsReparsePoint){throw "Managed staging tree root is missing, not a directory, or is a reparse point: $root"}
    $rows=New-Object System.Collections.Generic.List[string]
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force|Sort-Object FullName)){
        $info=Get-VllmPathEntryInfo -Path $item.FullName
        if($info.IsReparsePoint){throw "Managed staging tree contains a reparse point: $($item.FullName)"}
        $relative=$item.FullName.Substring($root.Length).TrimStart('\')
        if([string]::IsNullOrWhiteSpace($relative)){continue}
        if($item.PSIsContainer){
            $rows.Add('D|'+$relative)
            $entries.Add([pscustomobject][ordered]@{Kind='directory';RelativePath=$relative;Size=$null;Sha256=$null})
        }else{
            $size=[int64]$item.Length
            $sha=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $rows.Add('F|'+$relative+'|'+$size+'|'+$sha)
            $entries.Add([pscustomobject][ordered]@{Kind='file';RelativePath=$relative;Size=$size;Sha256=$sha})
        }
    }
    $rowArray=$rows.ToArray()
    [Array]::Sort($rowArray,[StringComparer]::Ordinal)
    $lf=[string][char]10
    $text=($rowArray-join$lf)+$lf
    $bytes=[Text.Encoding]::UTF8.GetBytes($text)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-','')}finally{$hasher.Dispose()}
    return [pscustomobject][ordered]@{
        Root=$root;EntryCount=$entries.Count;FileCount=@($entries|Where-Object{$_.Kind-eq'file'}).Count
        TreeSha256=$digest
    }
}

function Test-VllmUpdateTreeIdentityEqual {
    param([Parameter(Mandatory)]$A,[Parameter(Mandatory)]$B)
    return([int]$A.EntryCount-eq[int]$B.EntryCount-and[int]$A.FileCount-eq[int]$B.FileCount-and[string]$A.TreeSha256-eq[string]$B.TreeSha256)
}

function Get-VllmUpdateManagedStagingPlan {
    param([Parameter(Mandatory)]$Plan)
    $pythonChange=@($Plan.managed|Where-Object{$_.Role-eq'python'-and$_.Class-ne'reuse'})
    $runtimeChange=@($Plan.managed|Where-Object{$_.Role-eq'runtime'-and$_.Class-ne'reuse'})
    if($pythonChange.Count-gt0-and$runtimeChange.Count-gt0){
        throw 'Simultaneous Python/runtime managed changes are not supported by the SM-18C relocation proof; the target runtime must reference an already-stable final Python root.'
    }
    $retiredPython=@($Plan.managed|Where-Object{$_.Role-eq'python'-and$_.Class-eq'retire'})
    $reusedRuntime=@($Plan.managed|Where-Object{$_.Role-eq'runtime'-and$_.Class-eq'reuse'})
    if($retiredPython.Count-gt0-and$reusedRuntime.Count-gt0){
        throw 'A reused runtime cannot outlive a retired Python base; keep the source Python managed path owned by the target. Python managed-path relocation is not supported by the SM-18C staging contract.'
    }
    $result=New-Object System.Collections.Generic.List[object]
    foreach($item in @($Plan.managed|Sort-Object RelativePath)){
        $role=[string]$item.Role
        $class=[string]$item.Class
        if($class-eq'reuse'){$mode='reuse-live'}
        elseif($class-eq'retire'){$mode='retire-post-commit'}
        elseif($role-in@('python','uv','runtime')){$mode='relocate-tree'}
        elseif($role-in@('python-receipt','uv-receipt','venv-receipt','dependency-receipt','runtime-receipt')){$mode='regenerate-final'}
        elseif($role-eq'cache'){throw 'A target that changes the managed cache contract is not supported by the SM-18C staging contract.'}
        else{throw "No SM-18C staging policy exists for managed role '$role'."}
        $result.Add([pscustomobject][ordered]@{
            Class=$class;RelativePath=[string]$item.RelativePath;Role=$role;Mode=$mode
            SourceContract=$item.SourceContract;TargetContract=$item.TargetContract
        })
    }
    return $result.ToArray()
}

function Test-VllmUpdatePortablePythonTree {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ExpectedVersion)
    try{
        $root=Get-VllmNormalizedPath $Root
        $exe=Join-Path $root 'python.exe'
        if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){return $false}
        $probe=(& $exe -I -S -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}|{sys.executable}')" 2>&1|Out-String).Trim()
        if($LASTEXITCODE-ne0){return $false}
        $parts=$probe.Split('|')
        if($parts.Count-ne3-or$parts[0]-ne$ExpectedVersion-or[int]$parts[1]-ne64){return $false}
        return((Get-VllmNormalizedPath $parts[2])-eq(Get-VllmNormalizedPath $exe))
    }catch{return $false}
}

function Test-VllmUpdatePortableUvTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ExpectedCommitPrefix
    )
    try{
        $exe=Join-Path (Get-VllmNormalizedPath $Root) 'uv.exe'
        if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){return $false}
        $probe=(& $exe --version 2>&1|Out-String).Trim()
        return($LASTEXITCODE-eq0-and$probe.StartsWith("uv $ExpectedVersion ($ExpectedCommitPrefix",[StringComparison]::Ordinal))
    }catch{return $false}
}

function Test-VllmUpdateRelocatableVenvTree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedPythonVersion,
        [Parameter(Mandatory)][int]$ExpectedPointerBits,
        [Parameter(Mandatory)][string]$ExpectedBasePythonRoot
    )
    try{
        $root=Get-VllmNormalizedPath $Root
        $cfg=Join-Path $root 'pyvenv.cfg'
        $python=Join-Path $root 'Scripts\python.exe'
        if(-not(Test-Path -LiteralPath $cfg -PathType Leaf)-or-not(Test-Path -LiteralPath $python -PathType Leaf)){return $false}
        $lines=@(Get-Content -LiteralPath $cfg)
        if($lines-notcontains'relocatable = true'){return $false}
        if(Test-Path -LiteralPath (Join-Path $root 'Scripts\activate.csh') -PathType Leaf){return $false}
        $probe=(& $python -I -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}|{64 if sys.maxsize > 2**32 else 32}|{sys.prefix}|{sys.base_prefix}')" 2>&1|Out-String).Trim()
        if($LASTEXITCODE-ne0){return $false}
        $parts=$probe.Split('|')
        if($parts.Count-ne4-or$parts[0]-ne$ExpectedPythonVersion-or[int]$parts[1]-ne$ExpectedPointerBits){return $false}
        if((Get-VllmNormalizedPath $parts[2]) -ne $root){return $false}
        return((Get-VllmNormalizedPath $parts[3])-eq(Get-VllmNormalizedPath $ExpectedBasePythonRoot))
    }catch{return $false}
}
