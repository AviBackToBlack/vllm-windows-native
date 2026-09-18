Set-StrictMode -Version Latest

function Get-VllmUpdateTransactionPaths {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$TransactionId
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $guid=[guid]::Empty
    if(-not[guid]::TryParse($TransactionId,[ref]$guid)-or$guid-eq[guid]::Empty){
        throw 'Update transaction_id must be a non-empty GUID.'
    }
    $id=$guid.ToString('D').ToLowerInvariant()
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $root -TransactionId $id
    $backupRelative=[string]$layout.TransactionRelative+'\backup'
    $backupDistributionRelative=$backupRelative+'\distribution'
    [pscustomobject][ordered]@{
        TransactionId=$id
        InstallationRoot=$root
        JournalRelative='state\update-transaction.json'
        JournalPath=(Join-Path $root 'state\update-transaction.json')
        WorkspaceRelative=[string]$layout.WorkspaceRelative
        WorkspaceRoot=[string]$layout.WorkspaceRoot
        TransactionRelative=[string]$layout.TransactionRelative
        TransactionRoot=[string]$layout.TransactionRoot
        StagingRelative=[string]$layout.StagingRelative
        StagingRoot=[string]$layout.StagingRoot
        DistributionRelative=[string]$layout.DistributionRelative
        DistributionRoot=[string]$layout.DistributionRoot
        ManagedRelative=[string]$layout.ManagedRelative
        ManagedRoot=[string]$layout.ManagedRoot
        BackupRelative=$backupRelative
        BackupRoot=(Join-Path $root $backupRelative)
        BackupDistributionRelative=$backupDistributionRelative
        BackupDistributionRoot=(Join-Path $root $backupDistributionRelative)
    }
}

function Assert-VllmUpdateTransactionGenerationIdentity {
    param([Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$Label)
    Assert-VllmLifecycleExactProperties -Value $Identity -Expected @('release','manifest_sha256','generation_id') -Label $Label
    if([string]::IsNullOrWhiteSpace([string]$Identity.release)){throw "$Label release is empty."}
    if(([string]$Identity.manifest_sha256)-notmatch'^[0-9A-Fa-f]{64}$'){throw "$Label manifest_sha256 is invalid."}
    $generation=[guid]::Empty
    if(-not[guid]::TryParse([string]$Identity.generation_id,[ref]$generation)-or$generation-eq[guid]::Empty){
        throw "$Label generation_id is invalid."
    }
}

function Assert-VllmUpdateTransactionFileIdentity {
    param([Parameter(Mandatory)]$Identity,[Parameter(Mandatory)][string]$Label)
    Assert-VllmLifecycleExactProperties -Value $Identity -Expected @('size_bytes','sha256') -Label $Label
    if([int64]$Identity.size_bytes-lt0){throw "$Label size_bytes is invalid."}
    if(([string]$Identity.sha256)-notmatch'^[0-9A-Fa-f]{64}$'){throw "$Label sha256 is invalid."}
}

function Get-VllmUpdateActivationPlan {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$TransactionId,
        [Parameter(Mandatory)][object[]]$DistributionPlan
    )
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $InstallationRoot -TransactionId $TransactionId
    $models=Assert-VllmSafeModelsRoot -InstallationRoot $paths.InstallationRoot -ModelsRoot $ModelsRoot
    $result=New-Object System.Collections.Generic.List[object]
    $seen=@{}
    foreach($item in @($DistributionPlan|Where-Object{$_.Class-in@('replace','add')}|Sort-Object RelativePath)){
        $class=[string]$item.Class
        $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$item.RelativePath) -Label 'Update activation path'
        Assert-VllmUpdateOrdinaryPathNotLifecycleOwned -InstallationRoot $paths.InstallationRoot -RelativePath $relative -Label 'Update activation path'
        Assert-VllmUpdateNoProtectedOverlap -InstallationRoot $paths.InstallationRoot -ModelsRoot $models -RelativePath $relative -Label 'Update activation path'
        $key=Get-VllmUpdateRelativeKey $relative
        if($seen.ContainsKey($key)){throw "Duplicate update activation path: $relative"}
        $seen[$key]=$true

        if($null-eq$item.Target){throw "Activation target identity is missing: $relative"}
        $target=[pscustomobject][ordered]@{
            size_bytes=[int64]$item.Target.Size
            sha256=([string]$item.Target.Sha256).ToUpperInvariant()
        }
        Assert-VllmUpdateTransactionFileIdentity -Identity $target -Label "Activation target '$relative'"

        $source=$null
        $backupRelative=$null
        if($class-eq'replace'){
            if($null-eq$item.Source){throw "Activation source identity is missing: $relative"}
            $source=[pscustomobject][ordered]@{
                size_bytes=[int64]$item.Source.Size
                sha256=([string]$item.Source.Sha256).ToUpperInvariant()
            }
            Assert-VllmUpdateTransactionFileIdentity -Identity $source -Label "Activation source '$relative'"
            $backupRelative=[string]$paths.BackupDistributionRelative+'\'+$relative
        }elseif($null-ne$item.Source){
            throw "Activation add unexpectedly has a source identity: $relative"
        }

        $result.Add([pscustomobject][ordered]@{
            class=$class
            relative_path=$relative
            source=$source
            target=$target
            stage_relative=([string]$paths.DistributionRelative+'\'+$relative)
            backup_relative=$backupRelative
        })
    }
    $result.ToArray()
}

function Assert-VllmUpdateTransactionActivationPlan {
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ModelsRoot
    )
    if(@($Plan).Count-eq0){throw 'Update transaction activation_plan is empty.'}
    $seen=@{}
    foreach($item in @($Plan)){
        Assert-VllmLifecycleExactProperties -Value $item -Expected @(
            'class','relative_path','source','target','stage_relative','backup_relative'
        ) -Label 'Update transaction activation entry'
        $class=[string]$item.class
        if($class-notin@('replace','add')){throw "Unsupported activation class: $class"}
        $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$item.relative_path) -Label 'Update transaction activation path'
        Assert-VllmUpdateOrdinaryPathNotLifecycleOwned -InstallationRoot $Paths.InstallationRoot -RelativePath $relative -Label 'Update transaction activation path'
        Assert-VllmUpdateNoProtectedOverlap -InstallationRoot $Paths.InstallationRoot -ModelsRoot $ModelsRoot -RelativePath $relative -Label 'Update transaction activation path'
        $key=Get-VllmUpdateRelativeKey $relative
        if($seen.ContainsKey($key)){throw "Duplicate update transaction activation path: $relative"}
        $seen[$key]=$true

        Assert-VllmUpdateTransactionFileIdentity -Identity $item.target -Label "Activation target '$relative'"
        if([string]$item.target.sha256-ne([string]$item.target.sha256).ToUpperInvariant()){
            throw "Activation target SHA-256 is not canonical uppercase: $relative"
        }
        $expectedStage=[string]$Paths.DistributionRelative+'\'+$relative
        if(-not(Test-VllmUpdateRelativePathEqual -A ([string]$item.stage_relative) -B $expectedStage)){
            throw "Activation stage path is inconsistent with transaction layout: $relative"
        }

        if($class-eq'replace'){
            if($null-eq$item.source){throw "Replace activation source identity is missing: $relative"}
            Assert-VllmUpdateTransactionFileIdentity -Identity $item.source -Label "Activation source '$relative'"
            if([string]$item.source.sha256-ne([string]$item.source.sha256).ToUpperInvariant()){
                throw "Activation source SHA-256 is not canonical uppercase: $relative"
            }
            $expectedBackup=[string]$Paths.BackupDistributionRelative+'\'+$relative
            if(-not(Test-VllmUpdateRelativePathEqual -A ([string]$item.backup_relative) -B $expectedBackup)){
                throw "Activation backup path is inconsistent with transaction layout: $relative"
            }
        }else{
            if($null-ne$item.source){throw "Add activation unexpectedly records a source identity: $relative"}
            if($null-ne$item.backup_relative){throw "Add activation unexpectedly records a backup path: $relative"}
        }
    }
}

function Assert-VllmUpdateTransactionJournal {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$InstallationRoot
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    Assert-VllmLifecycleExactProperties -Value $Journal -Expected @(
        'schema_version','component','platform','transaction_id','phase',
        'installation_root','models_root','source','target','workspace',
        'activation_plan','created_at','updated_at'
    ) -Label 'Update transaction'
    if([int]$Journal.schema_version-ne1-or[string]$Journal.component-ne'update-transaction'-or[string]$Journal.platform-ne'windows-x86_64'){
        throw 'Update transaction has unsupported schema/component/platform.'
    }
    if([string]$Journal.phase-notin@('materializing','prepared','activating','committed','cleanup')){
        throw "Update transaction phase is invalid: $($Journal.phase)"
    }

    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $root -TransactionId ([string]$Journal.transaction_id)
    if(-not(Test-VllmUpdatePathEqual -A ([string]$Journal.installation_root) -B $root)){
        throw 'Update transaction installation_root does not match the active installation.'
    }
    $models=Assert-VllmSafeModelsRoot -InstallationRoot $root -ModelsRoot ([string]$Journal.models_root)

    Assert-VllmUpdateTransactionGenerationIdentity -Identity $Journal.source -Label 'Update transaction source'
    Assert-VllmUpdateTransactionGenerationIdentity -Identity $Journal.target -Label 'Update transaction target'
    if(([string]$Journal.source.generation_id).Equals([string]$Journal.target.generation_id,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Update transaction source and target generation_id must differ.'
    }

    Assert-VllmLifecycleExactProperties -Value $Journal.workspace -Expected @(
        'workspace_root','workspace_relative','transaction_root','transaction_relative',
        'staging_root','staging_relative','backup_root','backup_relative'
    ) -Label 'Update transaction workspace'

    foreach($row in @(
        @([string]$Journal.workspace.workspace_root,[string]$paths.WorkspaceRoot,'workspace_root'),
        @([string]$Journal.workspace.transaction_root,[string]$paths.TransactionRoot,'transaction_root'),
        @([string]$Journal.workspace.staging_root,[string]$paths.StagingRoot,'staging_root'),
        @([string]$Journal.workspace.backup_root,[string]$paths.BackupRoot,'backup_root')
    )){
        if(-not(Test-VllmUpdatePathEqual -A $row[0] -B $row[1])){
            throw "Update transaction $($row[2]) is inconsistent with transaction_id."
        }
    }
    foreach($row in @(
        @([string]$Journal.workspace.workspace_relative,[string]$paths.WorkspaceRelative,'workspace_relative'),
        @([string]$Journal.workspace.transaction_relative,[string]$paths.TransactionRelative,'transaction_relative'),
        @([string]$Journal.workspace.staging_relative,[string]$paths.StagingRelative,'staging_relative'),
        @([string]$Journal.workspace.backup_relative,[string]$paths.BackupRelative,'backup_relative')
    )){
        if(-not(Test-VllmUpdateRelativePathEqual -A $row[0] -B $row[1])){
            throw "Update transaction $($row[2]) is inconsistent with transaction_id."
        }
    }

    if(-not(Test-VllmLifecycleTimestamp $Journal.created_at)-or-not(Test-VllmLifecycleTimestamp $Journal.updated_at)){
        throw 'Update transaction timestamps are invalid.'
    }
    $created=[DateTimeOffset]::MinValue
    $updated=[DateTimeOffset]::MinValue
    [void][DateTimeOffset]::TryParse([string]$Journal.created_at,[ref]$created)
    [void][DateTimeOffset]::TryParse([string]$Journal.updated_at,[ref]$updated)
    if($updated-lt$created){throw 'Update transaction updated_at precedes created_at.'}

    Assert-VllmUpdateTransactionActivationPlan -Plan @($Journal.activation_plan) -Paths $paths -ModelsRoot $models
    return $Journal
}

function Read-VllmUpdateTransactionJournal {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $path=Join-Path $root 'state\update-transaction.json'
    $entry=Get-VllmPathEntryInfo -Path $path
    if(-not$entry.Exists){return $null}
    if($entry.IsDirectory-or$entry.IsReparsePoint){throw "Update transaction journal is not a safe regular file: $path"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath 'state\update-transaction.json')
    try{$journal=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}
    catch{throw "Update transaction journal is malformed: $path :: $($_.Exception.Message)"}
    if($null-eq$journal){throw "Update transaction journal parsed to null: $path"}
    [void](Assert-VllmUpdateTransactionJournal -Journal $journal -InstallationRoot $root)
    return $journal
}

function Write-VllmUpdateTransactionJournal {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$Journal,
        [ValidateSet('None','BeforePublish','AfterPublish')][string]$FaultPoint='None'
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $stateDir=Join-Path $root 'state'
    if(-not(Test-Path -LiteralPath $stateDir -PathType Container)){throw "Update state directory is missing: $stateDir"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $stateDir -RelativePath 'state')
    $path=Join-Path $stateDir 'update-transaction.json'
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath 'state\update-transaction.json')
    [void](Assert-VllmUpdateTransactionJournal -Journal $Journal -InstallationRoot $root)
    $validator={
        param($value,$candidatePath)
        [void]$candidatePath
        [void](Assert-VllmUpdateTransactionJournal -Journal $value -InstallationRoot $root)
    }
    Write-VllmAtomicJsonFile -Path $path -Value $Journal -Depth 20 -Validate $validator -FaultPoint $FaultPoint
}

function Open-VllmUpdateTransaction {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)]$SourceIdentity,
        [Parameter(Mandatory)]$TargetIdentity,
        [Parameter(Mandatory)][object[]]$ActivationPlan,
        [string]$TransactionId=([guid]::NewGuid().ToString('D')),
        [ValidateSet('None','BeforePublish','AfterPublish')][string]$JournalFaultPoint='None',
        [switch]$FaultBeforeWorkspace
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $models=Assert-VllmSafeModelsRoot -InstallationRoot $root -ModelsRoot $ModelsRoot
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $root -TransactionId $TransactionId
    if((Get-VllmPathEntryInfo -Path $paths.JournalPath).Exists){throw "Update transaction journal already exists: $($paths.JournalPath)"}
    if((Get-VllmPathEntryInfo -Path $paths.WorkspaceRoot).Exists){throw "Reserved update transaction workspace already exists: $($paths.WorkspaceRoot)"}

    Assert-VllmUpdateTransactionGenerationIdentity -Identity $SourceIdentity -Label 'New transaction source'
    Assert-VllmUpdateTransactionGenerationIdentity -Identity $TargetIdentity -Label 'New transaction target'
    Assert-VllmUpdateTransactionActivationPlan -Plan $ActivationPlan -Paths $paths -ModelsRoot $models

    $now=(Get-Date).ToUniversalTime().ToString('o')
    $journal=[pscustomobject][ordered]@{
        schema_version=1
        component='update-transaction'
        platform='windows-x86_64'
        transaction_id=[string]$paths.TransactionId
        phase='materializing'
        installation_root=$root
        models_root=$models
        source=[pscustomobject][ordered]@{
            release=[string]$SourceIdentity.release
            manifest_sha256=([string]$SourceIdentity.manifest_sha256).ToUpperInvariant()
            generation_id=([guid]([string]$SourceIdentity.generation_id)).ToString('D').ToLowerInvariant()
        }
        target=[pscustomobject][ordered]@{
            release=[string]$TargetIdentity.release
            manifest_sha256=([string]$TargetIdentity.manifest_sha256).ToUpperInvariant()
            generation_id=([guid]([string]$TargetIdentity.generation_id)).ToString('D').ToLowerInvariant()
        }
        workspace=[pscustomobject][ordered]@{
            workspace_root=[string]$paths.WorkspaceRoot
            workspace_relative=[string]$paths.WorkspaceRelative
            transaction_root=[string]$paths.TransactionRoot
            transaction_relative=[string]$paths.TransactionRelative
            staging_root=[string]$paths.StagingRoot
            staging_relative=[string]$paths.StagingRelative
            backup_root=[string]$paths.BackupRoot
            backup_relative=[string]$paths.BackupRelative
        }
        activation_plan=@($ActivationPlan)
        created_at=$now
        updated_at=$now
    }

    $journal=Write-VllmUpdateTransactionJournal -InstallationRoot $root -Journal $journal -FaultPoint $JournalFaultPoint
    if($FaultBeforeWorkspace){throw 'FAULT_INJECTED:BeforeFirstStagingWrite'}

    [void][IO.Directory]::CreateDirectory($paths.WorkspaceRoot)
    [void][IO.Directory]::CreateDirectory($paths.TransactionRoot)
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $root -TransactionId $paths.TransactionId
    [void](Initialize-VllmUpdateStagingDirectories -Layout $layout)
    [void][IO.Directory]::CreateDirectory($paths.BackupDistributionRoot)

    foreach($pair in @(
        @($paths.WorkspaceRoot,$paths.WorkspaceRelative),
        @($paths.TransactionRoot,$paths.TransactionRelative),
        @($paths.BackupRoot,$paths.BackupRelative),
        @($paths.BackupDistributionRoot,$paths.BackupDistributionRelative)
    )){
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $pair[0] -RelativePath $pair[1])
        if((Get-VllmPathEntryInfo -Path $pair[0]).IsReparsePoint){throw "Update transaction workspace path is a reparse point: $($pair[0])"}
    }

    [pscustomobject][ordered]@{Journal=$journal;Paths=$paths}
}

function Invoke-VllmUpdateTransactionPhaseTransition {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][ValidateSet('prepared','activating','committed','cleanup')][string]$Phase,
        [ValidateSet('None','BeforePublish','AfterPublish')][string]$FaultPoint='None'
    )
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $InstallationRoot
    if($null-eq$journal){throw 'Cannot advance update transaction phase because the journal is absent.'}
    $allowed=@{
        materializing='prepared'
        prepared='activating'
        activating='committed'
        committed='cleanup'
    }
    $current=[string]$journal.phase
    if(-not$allowed.ContainsKey($current)-or[string]$allowed[$current]-ne$Phase){
        throw "Invalid update transaction phase transition: $current -> $Phase"
    }
    $journal.phase=$Phase
    $journal.updated_at=(Get-Date).ToUniversalTime().ToString('o')
    Write-VllmUpdateTransactionJournal -InstallationRoot $InstallationRoot -Journal $journal -FaultPoint $FaultPoint
}

function Get-VllmUpdateTransactionFileState {
    param(
        [Parameter(Mandatory)][string]$Path,
        $SourceIdentity,
        $TargetIdentity
    )
    $entry=Get-VllmPathEntryInfo -Path $Path
    if(-not$entry.Exists){return 'missing'}
    if($entry.IsDirectory-or$entry.IsReparsePoint){return 'unknown'}
    try{
        $item=Get-Item -LiteralPath $Path -ErrorAction Stop
        $size=[int64]$item.Length
        $sha=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }catch{return 'unknown'}

    if($null-ne$SourceIdentity-and$size-eq[int64]$SourceIdentity.size_bytes-and$sha-eq[string]$SourceIdentity.sha256){
        return 'source'
    }
    if($null-ne$TargetIdentity-and$size-eq[int64]$TargetIdentity.size_bytes-and$sha-eq[string]$TargetIdentity.sha256){
        return 'target'
    }
    return 'unknown'
}

function Assert-VllmUpdateTransactionExactFile {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$Label
    )
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath)
    $state=Get-VllmUpdateTransactionFileState -Path $Path -TargetIdentity $Identity
    if($state-ne'target'){throw "$Label identity mismatch: $Path"}
}

function Complete-VllmUpdateTransactionPreparation {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $root
    if($null-eq$journal-or[string]$journal.phase-ne'materializing'){
        throw 'Update transaction must be in materializing phase before preparation can complete.'
    }
    foreach($item in @($journal.activation_plan)){
        $stage=Join-Path $root ([string]$item.stage_relative)
        Assert-VllmUpdateTransactionExactFile -InstallationRoot $root -Path $stage -RelativePath ([string]$item.stage_relative) -Identity $item.target -Label "Staged target '$($item.relative_path)'"
        if([string]$item.class-eq'replace'){
            $backup=Join-Path $root ([string]$item.backup_relative)
            if((Get-VllmPathEntryInfo -Path $backup).Exists){throw "Backup path exists before activation: $backup"}
        }
    }
    Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase prepared
}

function Read-VllmUpdateInstallStateForRecovery {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $path=Join-Path $root 'state\install-state.json'
    $entry=Get-VllmPathEntryInfo -Path $path
    if(-not$entry.Exists){return $null}
    if($entry.IsDirectory-or$entry.IsReparsePoint){throw "Install state is not a safe regular file during recovery: $path"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath 'state\install-state.json')
    try{$state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}
    catch{throw "Install state is malformed during recovery: $path :: $($_.Exception.Message)"}
    if($null-eq$state){throw 'Install state parsed to null during recovery.'}
    $generation=[guid]::Empty
    if(-not[guid]::TryParse([string]$state.generation_id,[ref]$generation)-or$generation-eq[guid]::Empty){
        throw 'Install state generation_id is invalid during recovery.'
    }
    [pscustomobject][ordered]@{Path=$path;State=$state;GenerationId=$generation.ToString('D').ToLowerInvariant()}
}

function Publish-VllmUpdateInstallState {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ExpectedGenerationId,
        [scriptblock]$ValidateState,
        [ValidateSet('None','BeforePublish','AfterPublish')][string]$FaultPoint='None'
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $generation=[guid]::Empty
    if(-not[guid]::TryParse($ExpectedGenerationId,[ref]$generation)-or$generation-eq[guid]::Empty){
        throw 'Expected install-state generation_id is invalid.'
    }
    if(-not([string]$State.generation_id).Equals($generation.ToString('D'),[StringComparison]::OrdinalIgnoreCase)){
        throw 'Target install-state generation_id does not match the preallocated target generation.'
    }
    $path=Join-Path $root 'state\install-state.json'
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath 'state\install-state.json')
    $stateValidator=$ValidateState
    $validator={
        param($value,$candidatePath)
        if(-not([string]$value.generation_id).Equals($generation.ToString('D'),[StringComparison]::OrdinalIgnoreCase)){
            throw 'Published install-state generation_id does not match the expected target generation.'
        }
        if($null-ne$stateValidator){& $stateValidator $value $candidatePath}
    }
    Write-VllmAtomicJsonFile -Path $path -Value $State -Depth 24 -Validate $validator -FaultPoint $FaultPoint
}

function Invoke-VllmUpdateKnownFileRemoval {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$Label
    )
    $entry=Get-VllmPathEntryInfo -Path $Path
    if(-not$entry.Exists){return}
    Assert-VllmUpdateTransactionExactFile -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath -Identity $Identity -Label $Label
    Remove-Item -LiteralPath $Path -Force
}

function Invoke-VllmUpdateEmptyDirectoryRemoval {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $entry=Get-VllmPathEntryInfo -Path $Path
    if(-not$entry.Exists){return}
    if(-not$entry.IsDirectory-or$entry.IsReparsePoint){throw "Transaction cleanup path is not a safe directory: $Path"}
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $InstallationRoot -Path $Path -RelativePath $RelativePath)
    if(@(Get-ChildItem -LiteralPath $Path -Force).Count-ne0){throw "Transaction cleanup directory contains unexplained residue: $Path"}
    [IO.Directory]::Delete($Path,$false)
}

function Get-VllmUpdateCleanupDirectorySet {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)]$Paths
    )
    $set=@{}
    $addParents={
        param([string]$Relative,[string]$StopRelative)
        if([string]::IsNullOrWhiteSpace($Relative)){return}
        $cursor=Split-Path -Parent $Relative
        while(-not[string]::IsNullOrWhiteSpace($cursor)){
            $key=Get-VllmUpdateRelativeKey $cursor
            $set[$key]=$cursor
            if(Test-VllmUpdateRelativePathEqual -A $cursor -B $StopRelative){break}
            $cursor=Split-Path -Parent $cursor
        }
    }
    foreach($item in @($Journal.activation_plan)){
        & $addParents ([string]$item.stage_relative) ([string]$Paths.StagingRelative)
        if($null-ne$item.backup_relative){
            & $addParents ([string]$item.backup_relative) ([string]$Paths.BackupRelative)
        }
    }
    foreach($relative in @(
        $Paths.ManagedRelative,
        $Paths.DistributionRelative,
        $Paths.StagingRelative,
        $Paths.BackupDistributionRelative,
        $Paths.BackupRelative,
        $Paths.TransactionRelative,
        $Paths.WorkspaceRelative
    )){
        $set[(Get-VllmUpdateRelativeKey ([string]$relative))]=[string]$relative
    }
    @($set.Values|Sort-Object {($_ -split '[\\/]').Count} -Descending)
}

function Invoke-VllmUpdateTransactionEvidenceCleanup {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][ValidateSet('source','target')][string]$CommittedGeneration
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    [void](Assert-VllmUpdateTransactionJournal -Journal $Journal -InstallationRoot $root)
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $root -TransactionId ([string]$Journal.transaction_id)

    foreach($item in @($Journal.activation_plan)){
        $stage=Join-Path $root ([string]$item.stage_relative)
        Invoke-VllmUpdateKnownFileRemoval -InstallationRoot $root -Path $stage -RelativePath ([string]$item.stage_relative) -Identity $item.target -Label "Staged target '$($item.relative_path)'"

        if([string]$item.class-eq'replace'){
            $backup=Join-Path $root ([string]$item.backup_relative)
            if($CommittedGeneration-eq'target'){
                Invoke-VllmUpdateKnownFileRemoval -InstallationRoot $root -Path $backup -RelativePath ([string]$item.backup_relative) -Identity $item.source -Label "Committed source backup '$($item.relative_path)'"
            }elseif((Get-VllmPathEntryInfo -Path $backup).Exists){
                throw "Source rollback cleanup found an unexpected remaining backup: $backup"
            }
        }
    }

    foreach($relative in @(Get-VllmUpdateCleanupDirectorySet -Journal $Journal -Paths $paths)){
        $path=Join-Path $root $relative
        Invoke-VllmUpdateEmptyDirectoryRemoval -InstallationRoot $root -Path $path -RelativePath $relative
    }

    $journalPath=$paths.JournalPath
    $entry=Get-VllmPathEntryInfo -Path $journalPath
    if($entry.Exists){
        if($entry.IsDirectory-or$entry.IsReparsePoint){throw "Update journal became unsafe during cleanup: $journalPath"}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $journalPath -RelativePath $paths.JournalRelative)
        Remove-Item -LiteralPath $journalPath -Force
    }
}

function Restore-VllmUpdateSourceGeneration {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$Journal
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    [void](Assert-VllmUpdateTransactionJournal -Journal $Journal -InstallationRoot $root)
    $plan=@($Journal.activation_plan)
    [array]::Reverse($plan)
    foreach($item in $plan){
        $relative=[string]$item.relative_path
        $live=Join-Path $root $relative
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $live -RelativePath $relative)

        if([string]$item.class-eq'add'){
            $liveState=Get-VllmUpdateTransactionFileState -Path $live -TargetIdentity $item.target
            if($liveState-eq'target'){
                Invoke-VllmUpdateKnownFileRemoval -InstallationRoot $root -Path $live -RelativePath $relative -Identity $item.target -Label "Rollback add '$relative'"
            }elseif($liveState-ne'missing'){
                throw "Cannot roll back add '$relative': live state is $liveState."
            }
            continue
        }

        $backupRelative=[string]$item.backup_relative
        $backup=Join-Path $root $backupRelative
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $backup -RelativePath $backupRelative)
        $liveState=Get-VllmUpdateTransactionFileState -Path $live -SourceIdentity $item.source -TargetIdentity $item.target
        $backupState=Get-VllmUpdateTransactionFileState -Path $backup -SourceIdentity $item.source

        if($backupState-eq'source'){
            if($liveState-eq'target'){
                Invoke-VllmUpdateKnownFileRemoval -InstallationRoot $root -Path $live -RelativePath $relative -Identity $item.target -Label "Rollback activated target '$relative'"
            }elseif($liveState-ne'missing'){
                throw "Cannot restore replace '$relative': live=$liveState backup=source."
            }
            [IO.File]::Move($backup,$live)
        }elseif($backupState-eq'missing'){
            if($liveState-ne'source'){
                throw "Cannot restore replace '$relative': live=$liveState and source backup is missing."
            }
        }else{
            throw "Cannot restore replace '$relative': backup state is $backupState."
        }

        Assert-VllmUpdateTransactionExactFile -InstallationRoot $root -Path $live -RelativePath $relative -Identity $item.source -Label "Restored source '$relative'"
    }
}

function Invoke-VllmUpdateTransactionRecovery {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [scriptblock]$ValidateGeneration
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $journalPath=Join-Path $root 'state\update-transaction.json'
    $workspaceRoot=Join-Path $root 'work\update-transaction'
    $journalExists=(Get-VllmPathEntryInfo -Path $journalPath).Exists
    $workspaceExists=(Get-VllmPathEntryInfo -Path $workspaceRoot).Exists

    if(-not$journalExists){
        if($workspaceExists){throw "Reserved update workspace exists without a transaction journal: $workspaceRoot"}
        return [pscustomobject][ordered]@{recovered=$false;generation=$null}
    }

    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $root
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $root -TransactionId ([string]$journal.transaction_id)
    if($workspaceExists){
        $entry=Get-VllmPathEntryInfo -Path $paths.WorkspaceRoot
        if(-not$entry.IsDirectory-or$entry.IsReparsePoint){throw "Reserved update workspace is unsafe: $($paths.WorkspaceRoot)"}
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $paths.WorkspaceRoot -RelativePath $paths.WorkspaceRelative)
    }

    $installed=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $root
    if($null-eq$installed){throw 'Install state is absent while a valid update transaction exists; preserving all evidence.'}
    $generation=[string]$installed.GenerationId
    $sourceGeneration=([guid]([string]$journal.source.generation_id)).ToString('D').ToLowerInvariant()
    $targetGeneration=([guid]([string]$journal.target.generation_id)).ToString('D').ToLowerInvariant()

    if($generation-eq$sourceGeneration){
        if([string]$journal.phase-in@('committed','cleanup')){
            throw "Transaction phase '$($journal.phase)' contradicts the committed source generation."
        }
        Restore-VllmUpdateSourceGeneration -InstallationRoot $root -Journal $journal
        if($null-ne$ValidateGeneration){& $ValidateGeneration 'source' $sourceGeneration $journal}
        Invoke-VllmUpdateTransactionEvidenceCleanup -InstallationRoot $root -Journal $journal -CommittedGeneration source
        return [pscustomobject][ordered]@{recovered=$true;generation='source'}
    }

    if($generation-eq$targetGeneration){
        if([string]$journal.phase-in@('materializing','prepared')){
            throw "Transaction phase '$($journal.phase)' contradicts the committed target generation."
        }
        if($null-ne$ValidateGeneration){& $ValidateGeneration 'target' $targetGeneration $journal}
        if([string]$journal.phase-eq'activating'){
            $journal=Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase committed
        }
        if([string]$journal.phase-eq'committed'){
            $journal=Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase cleanup
        }
        $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $root
        Invoke-VllmUpdateTransactionEvidenceCleanup -InstallationRoot $root -Journal $journal -CommittedGeneration target
        return [pscustomobject][ordered]@{recovered=$true;generation='target'}
    }

    throw "Install-state generation '$generation' matches neither the transaction source nor target generation; preserving all evidence."
}

function Invoke-VllmUpdateActivationRenames {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$Journal,
        [ValidateSet('None','BeforeFirstRename','AfterSourceBackup','AfterTargetActivation')][string]$FaultPoint='None'
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    if([string]$Journal.phase-ne'activating'){throw 'Activation renames require activating transaction phase.'}
    if($FaultPoint-eq'BeforeFirstRename'){throw 'FAULT_INJECTED:BeforeFirstRename'}

    foreach($item in @($Journal.activation_plan)){
        $relative=[string]$item.relative_path
        $live=Join-Path $root $relative
        $stage=Join-Path $root ([string]$item.stage_relative)
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $live -RelativePath $relative)
        Assert-VllmUpdateTransactionExactFile -InstallationRoot $root -Path $stage -RelativePath ([string]$item.stage_relative) -Identity $item.target -Label "Activation staged target '$relative'"

        $liveParent=Split-Path -Parent $live
        if(-not(Test-Path -LiteralPath $liveParent -PathType Container)){
            throw "Activation live parent directory is missing; SM-18D does not create unrecorded live directories: $liveParent"
        }

        if([string]$item.class-eq'replace'){
            $liveState=Get-VllmUpdateTransactionFileState -Path $live -SourceIdentity $item.source -TargetIdentity $item.target
            if($liveState-ne'source'){throw "Replace source drifted immediately before activation: $relative ($liveState)"}

            $backupRelative=[string]$item.backup_relative
            $backup=Join-Path $root $backupRelative
            if((Get-VllmPathEntryInfo -Path $backup).Exists){throw "Replace backup path already exists: $backup"}
            $backupParent=Split-Path -Parent $backup
            [void][IO.Directory]::CreateDirectory($backupParent)
            $backupParentRelative=Split-Path -Parent $backupRelative
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $backupParent -RelativePath $backupParentRelative)
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $backup -RelativePath $backupRelative)

            [IO.File]::Move($live,$backup)
            Assert-VllmUpdateTransactionExactFile -InstallationRoot $root -Path $backup -RelativePath $backupRelative -Identity $item.source -Label "Activation source backup '$relative'"
            if($FaultPoint-eq'AfterSourceBackup'){throw 'FAULT_INJECTED:AfterSourceBackup'}
        }else{
            $liveState=Get-VllmUpdateTransactionFileState -Path $live -TargetIdentity $item.target
            if($liveState-ne'missing'){throw "Add target is no longer absent immediately before activation: $relative ($liveState)"}
        }

        if((Get-VllmPathEntryInfo -Path $live).Exists){throw "Activation live target unexpectedly exists before staged rename: $relative"}
        [IO.File]::Move($stage,$live)
        Assert-VllmUpdateTransactionExactFile -InstallationRoot $root -Path $live -RelativePath $relative -Identity $item.target -Label "Activated target '$relative'"
        if($FaultPoint-eq'AfterTargetActivation'){throw 'FAULT_INJECTED:AfterTargetActivation'}
    }
}

function Invoke-VllmUpdateTransactionActivation {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)]$TargetInstallState,
        [scriptblock]$ValidateTargetState,
        [scriptblock]$ValidateGeneration,
        [scriptblock]$ValidateTargetLive,
        [ValidateSet(
            'None','BeforeFirstRename','AfterSourceBackup','AfterTargetActivation',
            'BeforeStateCommit','AfterStateCommit','DuringCleanup'
        )][string]$FaultPoint='None'
    )
    $root=Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $root
    if($null-eq$journal-or[string]$journal.phase-ne'prepared'){
        throw 'Update transaction must be prepared before activation.'
    }

    $committed=$false
    try{
        $journal=Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase activating
        $renameFault=if($FaultPoint-in@('BeforeFirstRename','AfterSourceBackup','AfterTargetActivation')){$FaultPoint}else{'None'}
        Invoke-VllmUpdateActivationRenames -InstallationRoot $root -Journal $journal -FaultPoint $renameFault

        if($null-ne$ValidateTargetLive){& $ValidateTargetLive $journal}
        if($FaultPoint-eq'BeforeStateCommit'){throw 'FAULT_INJECTED:BeforeStateCommit'}

        [void](Publish-VllmUpdateInstallState -InstallationRoot $root -State $TargetInstallState -ExpectedGenerationId ([string]$journal.target.generation_id) -ValidateState $ValidateTargetState)
        $committed=$true
        if($FaultPoint-eq'AfterStateCommit'){throw 'FAULT_INJECTED:AfterStateCommit'}

        $journal=Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase committed
        if($null-ne$ValidateGeneration){& $ValidateGeneration 'target' ([string]$journal.target.generation_id) $journal}
        $journal=Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $root -Phase cleanup
        if($FaultPoint-eq'DuringCleanup'){throw 'FAULT_INJECTED:DuringCleanup'}

        Invoke-VllmUpdateTransactionEvidenceCleanup -InstallationRoot $root -Journal $journal -CommittedGeneration target
        return [pscustomobject][ordered]@{
            ready=$true
            committed=$true
            generation_id=[string]$journal.target.generation_id
        }
    }catch{
        $failure=$_
        $injected=$failure.Exception.Message.StartsWith('FAULT_INJECTED:',[StringComparison]::Ordinal)
        if(-not$committed-and-not$injected){
            try{
                [void](Invoke-VllmUpdateTransactionRecovery -InstallationRoot $root -ValidateGeneration $ValidateGeneration)
            }catch{
                throw "Update activation failed: $($failure.Exception.Message) Automatic rollback also failed: $($_.Exception.Message)"
            }
        }
        throw $failure
    }
}
