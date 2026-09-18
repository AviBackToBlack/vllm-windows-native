[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\lifecycle.ps1')
. (Join-Path $repoRoot 'scripts\update-planner.ps1')
. (Join-Path $repoRoot 'scripts\update-staging.ps1')
. (Join-Path $repoRoot 'scripts\update-transaction.ps1')

function Get-TestIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $item=Get-Item -LiteralPath $Path
    [pscustomobject]@{Size=[int64]$item.Length;Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
}

function Test-ExpectedFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Expected
    )
    try{& $Action;throw "Expected failure did not occur: $Name"}
    catch{
        $message=$_.Exception.Message
        if($message-eq"Expected failure did not occur: $Name"){throw}
        if($message.IndexOf($Expected,[StringComparison]::OrdinalIgnoreCase)-lt0){
            throw "Unexpected failure for $($Name): $message"
        }
        Write-Host "REJECT $Name :: $message"
    }
}

function Write-TestGenerationState {
    param([string]$Root,[string]$GenerationId,[string]$Marker)
    $path=Join-Path $Root 'state\install-state.json'
    $value=[ordered]@{generation_id=$GenerationId;marker=$Marker}
    [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}

function Get-TestScenario {
    param([Parameter(Mandatory)][string]$Base)
    $root=Join-Path $Base 'installed'
    $targetRoot=Join-Path $Base 'target'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'state'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'models'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'payload'))
    [void][IO.Directory]::CreateDirectory($targetRoot)

    $liveA=Join-Path $root 'payload\a.txt'
    $targetA=Join-Path $targetRoot 'a.txt'
    $targetB=Join-Path $targetRoot 'b.txt'
    [IO.File]::WriteAllText($liveA,'source-a',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($targetA,'target-a',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($targetB,'target-b',[Text.UTF8Encoding]::new($false))
    $sourceA=Get-TestIdentity -Path $liveA
    $newA=Get-TestIdentity -Path $targetA
    $newB=Get-TestIdentity -Path $targetB

    $sourceGen=[guid]::NewGuid().ToString('D')
    $targetGen=[guid]::NewGuid().ToString('D')
    Write-TestGenerationState -Root $root -GenerationId $sourceGen -Marker 'source'

    $distribution=@(
        [pscustomobject]@{Class='replace';RelativePath='payload\a.txt';Source=$sourceA;Target=$newA},
        [pscustomobject]@{Class='add';RelativePath='payload\b.txt';Source=$null;Target=$newB}
    )
    $map=@{}
    $map[(Get-VllmUpdateRelativeKey 'payload\a.txt')]=[pscustomobject]@{RelativePath='payload\a.txt';Path=$targetA;Size=$newA.Size;Sha256=$newA.Sha256}
    $map[(Get-VllmUpdateRelativeKey 'payload\b.txt')]=[pscustomobject]@{RelativePath='payload\b.txt';Path=$targetB;Size=$newB.Size;Sha256=$newB.Sha256}

    [pscustomobject][ordered]@{
        Base=$Base
        Root=$root
        ModelsRoot=(Join-Path $root 'models')
        LiveA=$liveA
        LiveB=(Join-Path $root 'payload\b.txt')
        TargetA=$targetA
        TargetB=$targetB
        SourceA=$sourceA
        NewA=$newA
        NewB=$newB
        SourceGeneration=$sourceGen
        TargetGeneration=$targetGen
        Distribution=$distribution
        Plan=[pscustomobject]@{distribution=$distribution}
        TargetContext=[pscustomobject]@{DistributionMap=$map}
        SourceIdentity=[pscustomobject]@{release='synthetic-source';manifest_sha256=('A'*64);generation_id=$sourceGen}
        TargetIdentity=[pscustomobject]@{release='synthetic-target';manifest_sha256=('B'*64);generation_id=$targetGen}
        TargetState=[pscustomobject][ordered]@{generation_id=$targetGen;marker='target'}
    }
}

function Open-TestScenario {
    param([Parameter(Mandatory)]$Scenario,[switch]$FaultBeforeWorkspace)
    $txid=[guid]::NewGuid().ToString('D')
    $activation=Get-VllmUpdateActivationPlan -InstallationRoot $Scenario.Root -ModelsRoot $Scenario.ModelsRoot -TransactionId $txid -DistributionPlan $Scenario.Distribution
    $Scenario|Add-Member -NotePropertyName TransactionId -NotePropertyValue $txid -Force
    $Scenario|Add-Member -NotePropertyName ActivationPlan -NotePropertyValue $activation -Force
    Open-VllmUpdateTransaction -InstallationRoot $Scenario.Root -ModelsRoot $Scenario.ModelsRoot -SourceIdentity $Scenario.SourceIdentity -TargetIdentity $Scenario.TargetIdentity -ActivationPlan $activation -TransactionId $txid -FaultBeforeWorkspace:$FaultBeforeWorkspace
}

function Stage-TestScenario {
    param([Parameter(Mandatory)]$Scenario)
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $Scenario.Root -TransactionId $Scenario.TransactionId
    [void](Copy-VllmUpdateDistributionStage -Layout $layout -Plan $Scenario.Plan -TargetContext $Scenario.TargetContext)
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $Scenario.Root)
}

function Assert-ScenarioSource {
    param([Parameter(Mandatory)]$Scenario)
    $state=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $Scenario.Root
    if($null-eq$state-or-not([string]$state.GenerationId).Equals([string]$Scenario.SourceGeneration,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Synthetic source generation is not committed.'
    }
    $sourceId=[pscustomobject]@{size_bytes=$Scenario.SourceA.Size;sha256=$Scenario.SourceA.Sha256}
    if((Get-VllmUpdateTransactionFileState -Path $Scenario.LiveA -SourceIdentity $sourceId)-ne'source'){
        throw 'Synthetic source replace file is not restored.'
    }
    $targetB=[pscustomobject]@{size_bytes=$Scenario.NewB.Size;sha256=$Scenario.NewB.Sha256}
    if((Get-VllmUpdateTransactionFileState -Path $Scenario.LiveB -TargetIdentity $targetB)-ne'missing'){
        throw 'Synthetic add target exists in source generation.'
    }
}

function Assert-ScenarioTarget {
    param([Parameter(Mandatory)]$Scenario)
    $state=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $Scenario.Root
    if($null-eq$state-or-not([string]$state.GenerationId).Equals([string]$Scenario.TargetGeneration,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Synthetic target generation is not committed.'
    }
    $targetA=[pscustomobject]@{size_bytes=$Scenario.NewA.Size;sha256=$Scenario.NewA.Sha256}
    $targetB=[pscustomobject]@{size_bytes=$Scenario.NewB.Size;sha256=$Scenario.NewB.Sha256}
    if((Get-VllmUpdateTransactionFileState -Path $Scenario.LiveA -TargetIdentity $targetA)-ne'target'){
        throw 'Synthetic target replace file is invalid.'
    }
    if((Get-VllmUpdateTransactionFileState -Path $Scenario.LiveB -TargetIdentity $targetB)-ne'target'){
        throw 'Synthetic target add file is invalid.'
    }
}

function Assert-TransactionEvidenceAbsent {
    param([Parameter(Mandatory)]$Scenario)
    if(Test-Path -LiteralPath (Join-Path $Scenario.Root 'state\update-transaction.json')){throw 'Update journal residue remains.'}
    if(Test-Path -LiteralPath (Join-Path $Scenario.Root 'work\update-transaction')){throw 'Update workspace residue remains.'}
}

function Get-TestCallbacks {
    param([Parameter(Mandatory)]$Scenario)
    $callbackScenario=$Scenario
    $validateState={
        param($state,$path)
        if([string]$state.marker-ne'target'){throw "Synthetic target state marker mismatch: $path"}
    }.GetNewClosure()
    $validateGeneration={
        param($mode,$expected,$journal)
        [void]$journal
        $state=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $callbackScenario.Root
        if($null-eq$state-or-not([string]$state.GenerationId).Equals([string]$expected,[StringComparison]::OrdinalIgnoreCase)){
            throw "Synthetic generation validator mismatch for $mode."
        }
        if($mode-eq'source'){
            Assert-ScenarioSource -Scenario $callbackScenario
        }else{
            Assert-ScenarioTarget -Scenario $callbackScenario
        }
    }.GetNewClosure()
    $validateTargetLive={
        param($journal)
        [void]$journal
        if((Get-Content -LiteralPath $callbackScenario.LiveA -Raw)-ne'target-a'){throw 'Synthetic target live A mismatch.'}
        if((Get-Content -LiteralPath $callbackScenario.LiveB -Raw)-ne'target-b'){throw 'Synthetic target live B mismatch.'}
    }.GetNewClosure()
    [pscustomobject]@{
        ValidateState=$validateState
        ValidateGeneration=$validateGeneration
        ValidateTargetLive=$validateTargetLive
    }
}

function Invoke-TestScenario {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $base=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-tx-'+[guid]::NewGuid().ToString('N'))
    try{
        [void][IO.Directory]::CreateDirectory($base)
        $scenario=Get-TestScenario -Base $base
        & $Body $scenario
        Write-Host "PASS $Name"
    }finally{
        if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

Invoke-TestScenario -Name 'happy-path' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Stage-TestScenario -Scenario $scenario
    $callbacks=Get-TestCallbacks -Scenario $scenario
    $activationParameters=@{
        InstallationRoot=$scenario.Root
        TargetInstallState=$scenario.TargetState
        ValidateTargetState=$callbacks.ValidateState
        ValidateGeneration=$callbacks.ValidateGeneration
        ValidateTargetLive=$callbacks.ValidateTargetLive
    }
    $result=Invoke-VllmUpdateTransactionActivation @activationParameters
    if(-not[bool]$result.committed){throw 'Synthetic transaction did not commit.'}
    Assert-ScenarioTarget -Scenario $scenario
    Assert-TransactionEvidenceAbsent -Scenario $scenario
}
Write-Host 'UPDATE_TRANSACTION_HAPPY_OK'

function Invoke-PreCommitFaultCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FaultPoint
    )
    $caseName=$Name
    $caseFaultPoint=$FaultPoint
    Invoke-TestScenario -Name $caseName -Body {
        param($scenario)
        [void](Open-TestScenario -Scenario $scenario)
        Stage-TestScenario -Scenario $scenario
        $callbacks=Get-TestCallbacks -Scenario $scenario
        $parameters=@{
            InstallationRoot=$scenario.Root
            TargetInstallState=$scenario.TargetState
            ValidateTargetState=$callbacks.ValidateState
            ValidateGeneration=$callbacks.ValidateGeneration
            ValidateTargetLive=$callbacks.ValidateTargetLive
            FaultPoint=$caseFaultPoint
        }
        Test-ExpectedFailure -Action {Invoke-VllmUpdateTransactionActivation @parameters|Out-Null} -Name $caseName -Expected "FAULT_INJECTED:$caseFaultPoint"
        $state=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $scenario.Root
        if(-not([string]$state.GenerationId).Equals([string]$scenario.SourceGeneration,[StringComparison]::OrdinalIgnoreCase)){
            throw "$caseName unexpectedly changed the authoritative generation before commit."
        }
        $recovery=Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration
        if(-not[bool]$recovery.recovered-or[string]$recovery.generation-ne'source'){throw "$caseName did not recover the source generation."}
        Assert-ScenarioSource -Scenario $scenario
        Assert-TransactionEvidenceAbsent -Scenario $scenario
    }.GetNewClosure()
}

foreach($fault in @('BeforeFirstRename','AfterSourceBackup','AfterTargetActivation','BeforeStateCommit')){
    Invoke-PreCommitFaultCase -Name ("precommit-"+$fault) -FaultPoint $fault
}
Write-Host 'UPDATE_TRANSACTION_PRECOMMIT_RECOVERY_OK'

Invoke-TestScenario -Name 'journal-before-workspace' -Body {
    param($scenario)
    Test-ExpectedFailure -Action {
        [void](Open-TestScenario -Scenario $scenario -FaultBeforeWorkspace)
    } -Name 'journal-before-workspace' -Expected 'FAULT_INJECTED:BeforeFirstStagingWrite'
    $journalPath=Join-Path $scenario.Root 'state\update-transaction.json'
    $workspace=Join-Path $scenario.Root 'work\update-transaction'
    if(-not(Test-Path -LiteralPath $journalPath -PathType Leaf)){throw 'Journal was not durable before first staging write.'}
    if(Test-Path -LiteralPath $workspace){throw 'Workspace exists despite pre-staging fault.'}
    $callbacks=Get-TestCallbacks -Scenario $scenario
    $recovery=Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration
    if(-not[bool]$recovery.recovered-or[string]$recovery.generation-ne'source'){throw 'Pre-staging crash did not recover source generation.'}
    Assert-ScenarioSource -Scenario $scenario
    Assert-TransactionEvidenceAbsent -Scenario $scenario
}
Write-Host 'UPDATE_JOURNAL_PRECEDES_STAGING_OK'

function Invoke-PostCommitFaultCase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$FaultPoint
    )
    $caseName=$Name
    $caseFaultPoint=$FaultPoint
    Invoke-TestScenario -Name $caseName -Body {
        param($scenario)
        [void](Open-TestScenario -Scenario $scenario)
        Stage-TestScenario -Scenario $scenario
        $callbacks=Get-TestCallbacks -Scenario $scenario
        $parameters=@{
            InstallationRoot=$scenario.Root
            TargetInstallState=$scenario.TargetState
            ValidateTargetState=$callbacks.ValidateState
            ValidateGeneration=$callbacks.ValidateGeneration
            ValidateTargetLive=$callbacks.ValidateTargetLive
            FaultPoint=$caseFaultPoint
        }
        Test-ExpectedFailure -Action {Invoke-VllmUpdateTransactionActivation @parameters|Out-Null} -Name $caseName -Expected "FAULT_INJECTED:$caseFaultPoint"
        Assert-ScenarioTarget -Scenario $scenario
        $recovery=Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration
        if(-not[bool]$recovery.recovered-or[string]$recovery.generation-ne'target'){throw "$caseName did not preserve the committed target generation."}
        Assert-ScenarioTarget -Scenario $scenario
        Assert-TransactionEvidenceAbsent -Scenario $scenario
    }.GetNewClosure()
}

foreach($fault in @('AfterStateCommit','DuringCleanup')){
    Invoke-PostCommitFaultCase -Name ("postcommit-"+$fault) -FaultPoint $fault
}
Write-Host 'UPDATE_TRANSACTION_POSTCOMMIT_RECOVERY_OK'

Invoke-TestScenario -Name 'orphan-workspace-refused' -Body {
    param($scenario)
    $orphan=Join-Path $scenario.Root 'work\update-transaction'
    [void][IO.Directory]::CreateDirectory($orphan)
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root|Out-Null
    } -Name 'orphan-workspace-refused' -Expected 'without a transaction journal'
    if(-not(Test-Path -LiteralPath $orphan -PathType Container)){throw 'Orphan workspace evidence was not preserved.'}
}

Invoke-TestScenario -Name 'malformed-journal-refused' -Body {
    param($scenario)
    $journal=Join-Path $scenario.Root 'state\update-transaction.json'
    [IO.File]::WriteAllText($journal,'{',[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root|Out-Null
    } -Name 'malformed-journal-refused' -Expected 'journal is malformed'
    if(-not(Test-Path -LiteralPath $journal -PathType Leaf)){throw 'Malformed journal evidence was not preserved.'}
}

Invoke-TestScenario -Name 'missing-install-state-refused' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Remove-Item -LiteralPath (Join-Path $scenario.Root 'state\install-state.json') -Force
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root|Out-Null
    } -Name 'missing-install-state-refused' -Expected 'Install state is absent'
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json'))){throw 'Journal evidence was not preserved.'}
}

Invoke-TestScenario -Name 'unknown-generation-refused' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Write-TestGenerationState -Root $scenario.Root -GenerationId ([guid]::NewGuid().ToString('D')) -Marker 'unknown'
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root|Out-Null
    } -Name 'unknown-generation-refused' -Expected 'matches neither'
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json'))){throw 'Journal evidence was not preserved.'}
}
Write-Host 'UPDATE_TRANSACTION_METADATA_REFUSAL_OK'

Invoke-TestScenario -Name 'missing-source-backup-refused' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Stage-TestScenario -Scenario $scenario
    $callbacks=Get-TestCallbacks -Scenario $scenario
    $parameters=@{
        InstallationRoot=$scenario.Root
        TargetInstallState=$scenario.TargetState
        ValidateTargetState=$callbacks.ValidateState
        ValidateGeneration=$callbacks.ValidateGeneration
        ValidateTargetLive=$callbacks.ValidateTargetLive
        FaultPoint='AfterSourceBackup'
    }
    Test-ExpectedFailure -Action {Invoke-VllmUpdateTransactionActivation @parameters|Out-Null} -Name 'missing-source-backup-fault' -Expected 'FAULT_INJECTED:AfterSourceBackup'
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $scenario.Root
    $replace=@($journal.activation_plan|Where-Object{$_.class-eq'replace'})[0]
    $backup=Join-Path $scenario.Root ([string]$replace.backup_relative)
    Remove-Item -LiteralPath $backup -Force
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration|Out-Null
    } -Name 'missing-source-backup-refused' -Expected 'source backup is missing'
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json'))){throw 'Journal evidence was not preserved.'}
}

Invoke-TestScenario -Name 'unknown-live-identity-refused' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Stage-TestScenario -Scenario $scenario
    $callbacks=Get-TestCallbacks -Scenario $scenario
    $parameters=@{
        InstallationRoot=$scenario.Root
        TargetInstallState=$scenario.TargetState
        ValidateTargetState=$callbacks.ValidateState
        ValidateGeneration=$callbacks.ValidateGeneration
        ValidateTargetLive=$callbacks.ValidateTargetLive
        FaultPoint='AfterTargetActivation'
    }
    Test-ExpectedFailure -Action {Invoke-VllmUpdateTransactionActivation @parameters|Out-Null} -Name 'unknown-live-fault' -Expected 'FAULT_INJECTED:AfterTargetActivation'
    [IO.File]::WriteAllText($scenario.LiveA,'tampered-unknown',[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration|Out-Null
    } -Name 'unknown-live-identity-refused' -Expected 'live=unknown'
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json'))){throw 'Journal evidence was not preserved.'}
}

Invoke-TestScenario -Name 'unknown-cleanup-residue-refused' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Stage-TestScenario -Scenario $scenario
    $callbacks=Get-TestCallbacks -Scenario $scenario
    $parameters=@{
        InstallationRoot=$scenario.Root
        TargetInstallState=$scenario.TargetState
        ValidateTargetState=$callbacks.ValidateState
        ValidateGeneration=$callbacks.ValidateGeneration
        ValidateTargetLive=$callbacks.ValidateTargetLive
        FaultPoint='AfterStateCommit'
    }
    Test-ExpectedFailure -Action {Invoke-VllmUpdateTransactionActivation @parameters|Out-Null} -Name 'unknown-cleanup-fault' -Expected 'FAULT_INJECTED:AfterStateCommit'
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $scenario.Root
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $scenario.Root -TransactionId ([string]$journal.transaction_id)
    [IO.File]::WriteAllText((Join-Path $paths.TransactionRoot 'mystery.bin'),'unknown',[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {
        Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration|Out-Null
    } -Name 'unknown-cleanup-residue-refused' -Expected 'unexplained residue'
    Assert-ScenarioTarget -Scenario $scenario
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json'))){throw 'Committed-cleanup journal evidence was not preserved.'}
}
Write-Host 'UPDATE_TRANSACTION_UNKNOWN_CONTENT_REFUSAL_OK'

function Test-AtomicJsonPublication {
    $base=Join-Path ([IO.Path]::GetTempPath()) ('vllm-atomic-json-'+[guid]::NewGuid().ToString('N'))
    $watcher=$null
    try{
        [void][IO.Directory]::CreateDirectory($base)
        $path=Join-Path $base 'state.json'
        $ready=Join-Path $base 'watcher.ready'
        $stop=Join-Path $base 'watcher.stop'
        $gap=Join-Path $base 'watcher.gap'
        $validator={
            param($value,$candidatePath)
            if([int]$value.schema_version-ne1-or[string]::IsNullOrWhiteSpace([string]$value.marker)){
                throw "Atomic JSON candidate is invalid: $candidatePath"
            }
        }

        [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='one'}) -Validate $validator)
        try{
            [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='two'}) -Validate $validator -FaultPoint BeforePublish)
            throw 'Expected BeforePublish fault did not occur.'
        }catch{
            if($_.Exception.Message-ne'FAULT_INJECTED:BeforePublish'){throw}
        }
        if([string](Get-Content $path -Raw|ConvertFrom-Json).marker-ne'one'){throw 'BeforePublish changed the committed destination.'}

        try{
            [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='three'}) -Validate $validator -FaultPoint AfterPublish)
            throw 'Expected AfterPublish fault did not occur.'
        }catch{
            if($_.Exception.Message-ne'FAULT_INJECTED:AfterPublish'){throw}
        }
        if([string](Get-Content $path -Raw|ConvertFrom-Json).marker-ne'three'){throw 'AfterPublish did not expose the new committed destination.'}

        $watcher=Start-Job -ScriptBlock {
            if(-not[IO.File]::Exists($using:path)){[IO.File]::WriteAllText($using:gap,'initial-missing');return}
            [IO.File]::WriteAllText($using:ready,'ready')
            while(-not[IO.File]::Exists($using:stop)){
                if(-not[IO.File]::Exists($using:path)){
                    [IO.File]::WriteAllText($using:gap,'destination-absent')
                    return
                }
            }
        }
        $deadline=(Get-Date).AddSeconds(10)
        while(-not(Test-Path -LiteralPath $ready)){
            if((Get-Date)-gt$deadline){throw 'Atomic publication watcher did not become ready.'}
            Start-Sleep -Milliseconds 25
        }
        foreach($i in 1..64){
            [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker="overwrite-$i"}) -Validate $validator)
        }
        [IO.File]::WriteAllText($stop,'stop')
        Wait-Job -Job $watcher -Timeout 10|Out-Null
        Receive-Job -Job $watcher -ErrorAction Stop|Out-Null
        if(Test-Path -LiteralPath $gap){throw "Atomic overwrite exposed an absent destination: $(Get-Content $gap -Raw)"}
        Write-Host 'ATOMIC_JSON_PUBLICATION_OK'
    }finally{
        if($null-ne$watcher){Remove-Job -Job $watcher -Force -ErrorAction SilentlyContinue}
        if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

Test-AtomicJsonPublication
Write-Host 'UPDATE_ATOMIC_PUBLICATION_NO_GAP_OK'
