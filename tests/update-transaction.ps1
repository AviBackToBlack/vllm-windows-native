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
. (Join-Path $repoRoot 'scripts\update-integration.ps1')

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

        $stalePartial=Join-Path $base ('.state.json.partial.'+[guid]::NewGuid().ToString('N'))
        $unrelatedPartial=Join-Path $base '.state.json.partial.not-a-guid'
        [IO.File]::WriteAllText($stalePartial,'crash-residue',[Text.Encoding]::ASCII)
        [IO.File]::WriteAllText($unrelatedPartial,'keep',[Text.Encoding]::ASCII)
        [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='swept'}) -Validate $validator)
        if(Test-Path -LiteralPath $stalePartial){throw 'Exact stale atomic partial was not swept before the next write.'}
        if(-not(Test-Path -LiteralPath $unrelatedPartial -PathType Leaf)){throw 'Atomic partial cleanup removed an unrelated sibling.'}
        Write-Host 'ATOMIC_JSON_STALE_PARTIAL_SWEEP_OK'

        $unsafePartial=Join-Path $base ('.state.json.partial.'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($unsafePartial)
        Test-ExpectedFailure -Action {
            [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='unsafe'}) -Validate $validator)
        } -Name 'atomic-partial-directory-refused' -Expected 'stale partial path is unsafe'
        Remove-Item -LiteralPath $unsafePartial -Force
        Write-Host 'ATOMIC_JSON_UNSAFE_PARTIAL_REFUSED_OK'

        try{
            [void](Write-VllmAtomicJsonFile -Path $path -Value ([ordered]@{schema_version=1;marker='two'}) -Validate $validator -FaultPoint BeforePublish)
            throw 'Expected BeforePublish fault did not occur.'
        }catch{
            if($_.Exception.Message-ne'FAULT_INJECTED:BeforePublish'){throw}
        }
        if([string](Get-Content $path -Raw|ConvertFrom-Json).marker-ne'swept'){throw 'BeforePublish changed the committed destination.'}

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

function Convert-TestTreeIdentity {
    param([Parameter(Mandatory)]$Identity)
    [pscustomobject][ordered]@{
        entry_count=[int]$Identity.EntryCount
        file_count=[int]$Identity.FileCount
        tree_sha256=([string]$Identity.TreeSha256).ToUpperInvariant()
    }
}

Invoke-TestScenario -Name 'managed-tree-replace-retire' -Body {
    param($scenario)
    $managedRelative='runtime\managed-tree'
    $retireRelative='obsolete.txt'
    $managedLive=Join-Path $scenario.Root $managedRelative
    [void][IO.Directory]::CreateDirectory($managedLive)
    [IO.File]::WriteAllText((Join-Path $managedLive 'payload.txt'),'managed-source',[Text.UTF8Encoding]::new($false))
    $retireLive=Join-Path $scenario.Root $retireRelative
    [IO.File]::WriteAllText($retireLive,'obsolete-source',[Text.UTF8Encoding]::new($false))

    $sourceTree=Convert-TestTreeIdentity -Identity (Get-VllmUpdateTreeIdentity -Root $managedLive)
    $retireFile=Get-TestIdentity -Path $retireLive
    $retireIdentity=[pscustomobject][ordered]@{size_bytes=[int64]$retireFile.Size;sha256=([string]$retireFile.Sha256).ToUpperInvariant()}

    $txid=[guid]::NewGuid().ToString('D')
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $scenario.Root -TransactionId $txid
    $stageRelative=[string]$paths.ManagedRelative+'\'+$managedRelative
    $backupRelative=[string]$paths.BackupManagedRelative+'\'+$managedRelative

    $targetSource=Join-Path $scenario.Base 'managed-target-source'
    [void][IO.Directory]::CreateDirectory($targetSource)
    [IO.File]::WriteAllText((Join-Path $targetSource 'payload.txt'),'managed-target',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $targetSource 'added.txt'),'new-content',[Text.UTF8Encoding]::new($false))
    $targetTree=Convert-TestTreeIdentity -Identity (Get-VllmUpdateTreeIdentity -Root $targetSource)

    $activation=@(
        [pscustomobject][ordered]@{
            class='replace';kind='tree';role='runtime';relative_path=$managedRelative
            source=$sourceTree;target=$targetTree;stage_relative=$stageRelative;backup_relative=$backupRelative
        },
        [pscustomobject][ordered]@{
            class='retire';kind='file';role='distribution';relative_path=$retireRelative
            source=$retireIdentity;target=$null;stage_relative=$null;backup_relative=$null
        }
    )

    [void](Open-VllmUpdateTransaction -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -SourceIdentity $scenario.SourceIdentity -TargetIdentity $scenario.TargetIdentity -ActivationPlan $activation -TransactionId $txid)
    $stagePath=Join-Path $scenario.Root $stageRelative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $stagePath))
    Copy-Item -LiteralPath $targetSource -Destination $stagePath -Recurse
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $scenario.Root)

    $targetState=[pscustomobject][ordered]@{generation_id=$scenario.TargetGeneration;marker='target'}
    $validateState={param($state,$path);if([string]$state.marker-ne'target'){throw "tree target state mismatch: $path"}}
    $result=Invoke-VllmUpdateTransactionActivation -InstallationRoot $scenario.Root -TargetInstallState $targetState -ValidateTargetState $validateState
    if(-not$result.committed){throw 'Managed-tree transaction did not commit.'}
    if((Get-VllmUpdateTransactionObjectState -Kind tree -Path $managedLive -TargetIdentity $targetTree)-ne'target'){throw 'Managed tree did not activate.'}
    if(Test-Path -LiteralPath $retireLive){throw 'Post-commit retire path remains live.'}
    if(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json')){throw 'Managed-tree transaction journal residue remains.'}
    if(Test-Path -LiteralPath (Join-Path $scenario.Root 'work\update-transaction')){throw 'Managed-tree transaction workspace residue remains.'}
}
Write-Host 'UPDATE_MANAGED_TREE_RETIRE_OK'

Invoke-TestScenario -Name 'retire-precommit-drift-refusal' -Body {
    param($scenario)
    $relative='obsolete-drift.txt'
    $live=Join-Path $scenario.Root $relative
    [IO.File]::WriteAllText($live,'source-retire',[Text.UTF8Encoding]::new($false))
    $sourceFile=Get-TestIdentity -Path $live
    $sourceIdentity=[pscustomobject][ordered]@{
        size_bytes=[int64]$sourceFile.Size
        sha256=([string]$sourceFile.Sha256).ToUpperInvariant()
    }
    $txid=[guid]::NewGuid().ToString('D')
    $activation=@(
        [pscustomobject][ordered]@{
            class='retire';kind='file';role='distribution';relative_path=$relative
            source=$sourceIdentity;target=$null;stage_relative=$null;backup_relative=$null
        }
    )
    [void](Open-VllmUpdateTransaction -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -SourceIdentity $scenario.SourceIdentity -TargetIdentity $scenario.TargetIdentity -ActivationPlan $activation -TransactionId $txid)
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $scenario.Root)

    [IO.File]::WriteAllText($live,'DRIFTED-RETIRE-CONTENT',[Text.UTF8Encoding]::new($false))
    $targetState=[pscustomobject][ordered]@{generation_id=$scenario.TargetGeneration;marker='target'}
    Test-ExpectedFailure -Action {
        [void](Invoke-VllmUpdateTransactionActivation -InstallationRoot $scenario.Root -TargetInstallState $targetState)
    } -Name 'retire-precommit-drift' -Expected 'Retire source drifted immediately before commit'

    $state=Get-Content -LiteralPath (Join-Path $scenario.Root 'state\install-state.json') -Raw|ConvertFrom-Json
    if([string]$state.generation_id-ne[string]$scenario.SourceGeneration){
        throw 'Retire drift failure committed the target install-state.'
    }
}
Write-Host 'UPDATE_RETIRE_PRECOMMIT_DRIFT_REFUSAL_OK'

Invoke-TestScenario -Name 'retire-missing-source-recovery' -Body {
    param($scenario)
    $retireRelative='obsolete-recovery.txt'
    $retireLive=Join-Path $scenario.Root $retireRelative
    [IO.File]::WriteAllText($retireLive,'source-retire',[Text.UTF8Encoding]::new($false))
    $retireFile=Get-TestIdentity -Path $retireLive
    $distribution=@(
        [pscustomobject]@{Class='replace';RelativePath='payload\a.txt';Source=$scenario.SourceA;Target=$scenario.NewA},
        [pscustomobject]@{Class='retire';RelativePath=$retireRelative;Source=$retireFile;Target=$null}
    )
    $txid=[guid]::NewGuid().ToString('D')
    $activation=Get-VllmUpdateActivationPlan -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -TransactionId $txid -DistributionPlan $distribution
    [void](Open-VllmUpdateTransaction -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -SourceIdentity $scenario.SourceIdentity -TargetIdentity $scenario.TargetIdentity -ActivationPlan $activation -TransactionId $txid)
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $scenario.Root -TransactionId $txid
    $plan=[pscustomobject]@{distribution=$distribution}
    [void](Copy-VllmUpdateDistributionStage -Layout $layout -Plan $plan -TargetContext $scenario.TargetContext)
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $scenario.Root)
    Remove-Item -LiteralPath $retireLive -Force
    $callbacks=Get-TestCallbacks -Scenario $scenario
    Test-ExpectedFailure -Action {
        [void](Invoke-VllmUpdateTransactionActivation -InstallationRoot $scenario.Root -TargetInstallState $scenario.TargetState -ValidateTargetState $callbacks.ValidateState -FaultPoint AfterTargetActivation)
    } -Name 'retire-missing-source-recovery-activation' -Expected 'FAULT_INJECTED:AfterTargetActivation'
    $recovery=Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root -ValidateGeneration $callbacks.ValidateGeneration
    if(-not[bool]$recovery.recovered-or[string]$recovery.generation-ne'source'){throw 'Missing retire object blocked source-generation recovery.'}
    Assert-ScenarioSource -Scenario $scenario
    if(Test-Path -LiteralPath $retireLive){throw 'Missing retire object was unexpectedly recreated during source recovery.'}
    Assert-TransactionEvidenceAbsent -Scenario $scenario
}
Write-Host 'UPDATE_RETIRE_MISSING_SOURCE_RECOVERY_OK'

Invoke-TestScenario -Name 'retire-recovery-drift-refusal' -Body {
    param($scenario)
    $retireRelative='obsolete-recovery-drift.txt'
    $retireLive=Join-Path $scenario.Root $retireRelative
    [IO.File]::WriteAllText($retireLive,'source-retire',[Text.UTF8Encoding]::new($false))
    $retireFile=Get-TestIdentity -Path $retireLive
    $distribution=@([pscustomobject]@{Class='retire';RelativePath=$retireRelative;Source=$retireFile;Target=$null})
    $txid=[guid]::NewGuid().ToString('D')
    $activation=Get-VllmUpdateActivationPlan -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -TransactionId $txid -DistributionPlan $distribution
    [void](Open-VllmUpdateTransaction -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -SourceIdentity $scenario.SourceIdentity -TargetIdentity $scenario.TargetIdentity -ActivationPlan $activation -TransactionId $txid)
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $scenario.Root)
    [IO.File]::WriteAllText($retireLive,'DRIFTED-RETIRE-CONTENT',[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure -Action {
        [void](Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root)
    } -Name 'retire-recovery-drift' -Expected "Cannot restore retire '$retireRelative': live state is unknown."
    $state=Read-VllmUpdateInstallStateForRecovery -InstallationRoot $scenario.Root
    if(-not([string]$state.GenerationId).Equals([string]$scenario.SourceGeneration,[StringComparison]::OrdinalIgnoreCase)){throw 'Retire recovery drift failure changed the authoritative generation.'}
    if(-not(Test-Path -LiteralPath (Join-Path $scenario.Root 'state\update-transaction.json') -PathType Leaf)){throw 'Retire recovery drift failure did not preserve transaction evidence.'}
}
Write-Host 'UPDATE_RETIRE_RECOVERY_DRIFT_REFUSAL_OK'

Invoke-TestScenario -Name 'engine-whatif-defense' -Body {
    param($scenario)
    [void](Open-TestScenario -Scenario $scenario)
    Stage-TestScenario -Scenario $scenario
    $oldWhatIf=$WhatIfPreference
    try{
        $WhatIfPreference=$true
        Test-ExpectedFailure -Action {
            Invoke-VllmUpdateTransactionRecovery -InstallationRoot $scenario.Root|Out-Null
        } -Name 'engine-recovery-whatif-defense' -Expected 'refuses to mutate under -WhatIf'
        Test-ExpectedFailure -Action {
            Invoke-VllmUpdateTransactionActivation -InstallationRoot $scenario.Root -TargetInstallState $scenario.TargetState|Out-Null
        } -Name 'engine-activation-whatif-defense' -Expected 'refuses to mutate under -WhatIf'
    }finally{
        $WhatIfPreference=$oldWhatIf
    }
    $journal=Read-VllmUpdateTransactionJournal -InstallationRoot $scenario.Root
    if([string]$journal.phase-ne'prepared'){throw 'Internal WhatIf defense changed transaction phase.'}
}
Write-Host 'UPDATE_TRANSACTION_INTERNAL_WHATIF_DEFENSE_OK'

Invoke-TestScenario -Name 'provisional-materialization-finalization' -Body {
    param($scenario)
    $relative='runtime\provisional-tree'
    $live=Join-Path $scenario.Root $relative
    [void][IO.Directory]::CreateDirectory($live)
    [IO.File]::WriteAllText((Join-Path $live 'payload.txt'),'source',[Text.UTF8Encoding]::new($false))
    $sourceIdentity=Convert-TestTreeIdentity -Identity (Get-VllmUpdateTreeIdentity -Root $live)

    $targetSource=Join-Path $scenario.Base 'provisional-target'
    [void][IO.Directory]::CreateDirectory($targetSource)
    [IO.File]::WriteAllText((Join-Path $targetSource 'payload.txt'),'target',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $targetSource 'new.txt'),'new',[Text.UTF8Encoding]::new($false))
    $targetIdentity=Convert-TestTreeIdentity -Identity (Get-VllmUpdateTreeIdentity -Root $targetSource)

    $txid=[guid]::NewGuid().ToString('D')
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $scenario.Root -TransactionId $txid
    $contract='runtime-contract-v2'
    $entry=[pscustomobject][ordered]@{
        class='replace';kind='tree';role='runtime';relative_path=$relative
        source=$sourceIdentity;target=$null;target_contract=$contract
        stage_relative=([string]$paths.ManagedRelative+'\'+$relative)
        backup_relative=([string]$paths.BackupManagedRelative+'\'+$relative)
    }
    [void](Open-VllmUpdateTransaction -InstallationRoot $scenario.Root -ModelsRoot $scenario.ModelsRoot -SourceIdentity $scenario.SourceIdentity -TargetIdentity $scenario.TargetIdentity -ActivationPlan @($entry) -TransactionId $txid)

    Test-ExpectedFailure -Action {
        [void](Invoke-VllmUpdateTransactionPhaseTransition -InstallationRoot $scenario.Root -Phase prepared)
    } -Name 'provisional-prepared-refused' -Expected 'Replace activation identities are incomplete'

    Test-ExpectedFailure -Action {
        [void](Complete-VllmUpdateTransactionMaterializedTargets -InstallationRoot $scenario.Root -MaterializedTargets @(
            [pscustomobject][ordered]@{relative_path=$relative;target_contract='wrong-contract';identity=$targetIdentity}
        ))
    } -Name 'provisional-contract-mismatch-refused' -Expected 'does not match the journal'

    $journal=Complete-VllmUpdateTransactionMaterializedTargets -InstallationRoot $scenario.Root -MaterializedTargets @(
        [pscustomobject][ordered]@{relative_path=$relative;target_contract=$contract;identity=$targetIdentity}
    )
    if($null-eq$journal.activation_plan[0].target){throw 'Materialized target identity was not persisted.'}

    $stage=Join-Path $scenario.Root ([string]$entry.stage_relative)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $stage))
    Copy-Item -LiteralPath $targetSource -Destination $stage -Recurse
    [void](Complete-VllmUpdateTransactionPreparation -InstallationRoot $scenario.Root)

    $targetState=[pscustomobject][ordered]@{generation_id=$scenario.TargetGeneration;marker='target'}
    [void](Invoke-VllmUpdateTransactionActivation -InstallationRoot $scenario.Root -TargetInstallState $targetState)
    if((Get-VllmUpdateTransactionObjectState -Kind tree -Path $live -TargetIdentity $targetIdentity)-ne'target'){
        throw 'Finalized provisional target did not activate.'
    }
}
Write-Host 'UPDATE_PROVISIONAL_MATERIALIZATION_FINALIZATION_OK'

$lockA=[pscustomobject][ordered]@{
    path='requirements\runtime.lock.txt';size_bytes=10;sha256=('A'*64);package_count=2;hashes_required=$true;eol='lf'
}
$lockB=[pscustomobject][ordered]@{
    path='requirements\runtime.lock.txt';size_bytes=11;sha256=('B'*64);package_count=3;hashes_required=$true;eol='lf'
}
$offlineSource=[pscustomobject]@{
    ReleaseContext=[pscustomobject]@{DependencyManifest=[pscustomobject]@{lock=$lockA}}
}
$offlineTargetSame=[pscustomobject]@{DependencyManifest=[pscustomobject]@{lock=$lockA}}
$offlineTargetChanged=[pscustomobject]@{DependencyManifest=[pscustomobject]@{lock=$lockB}}
Assert-VllmUpdateOfflineDependencyLockCompatible -SourceContext $offlineSource -TargetContext $offlineTargetSame
Test-ExpectedFailure -Action {
    Assert-VllmUpdateOfflineDependencyLockCompatible -SourceContext $offlineSource -TargetContext $offlineTargetChanged
} -Name 'offline-dependency-lock-change' -Expected 'changed dependency lock'
Write-Host 'UPDATE_OFFLINE_DEPENDENCY_LOCK_GUARD_OK'

$literalBase=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-literal-[root]-'+[guid]::NewGuid().ToString('N'))
try{
    $literalRuntime=Join-Path $literalBase 'runtime[tree]'
    $literalScripts=Join-Path $literalRuntime 'Scripts'
    $literalFinalPython=Join-Path $literalBase 'python[final]'
    [void][IO.Directory]::CreateDirectory($literalScripts)
    [void][IO.Directory]::CreateDirectory($literalFinalPython)
    $lf=[string][char]10
    [IO.File]::WriteAllText((Join-Path $literalRuntime 'pyvenv.cfg'),('home = C:\old\python'+$lf+'relocatable = true'+$lf),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $literalScripts 'activate.ps1'),'Write-Host literal',[Text.UTF8Encoding]::new($false))
    Invoke-VllmUpdateIntegrationVenvRebase -RuntimeRoot $literalRuntime -FinalPythonRoot $literalFinalPython -MaterializationRoot (Join-Path $literalBase 'materialization')
    $cfg=Get-Content -LiteralPath (Join-Path $literalRuntime 'pyvenv.cfg')
    if($cfg -notcontains ('home = '+(Get-VllmNormalizedPath $literalFinalPython))){throw 'Literal-path venv rebase did not update pyvenv.cfg.'}
}finally{
    if(Test-Path -LiteralPath $literalBase){Remove-Item -LiteralPath $literalBase -Recurse -Force}
}
Write-Host 'UPDATE_LITERAL_PATH_REBASE_OK'

$budgetBase=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-budget-'+[guid]::NewGuid().ToString('N'))
try{
    $budgetRoot=Join-Path $budgetBase 'i'
    $pythonRoot=Join-Path $budgetRoot 'python\managed\python'
    $uvRoot=Join-Path $budgetRoot 'uv\managed\uv'
    $cacheRoot=Join-Path $budgetRoot 'cache\uv'
    $runtimeRoot=Join-Path $budgetRoot 'runtime\venv'
    foreach($dir in @($pythonRoot,$uvRoot,$cacheRoot,$runtimeRoot)){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText((Join-Path $pythonRoot 'python.exe'),'x',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $uvRoot 'uv.exe'),'x',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $cacheRoot 'cache.bin'),'x',[Text.Encoding]::ASCII)

    $txid=[guid]::NewGuid().ToString('D')
    $layout=Get-VllmUpdateStagingLayout -InstallationRoot $budgetRoot -TransactionId $txid
    $stageRuntimeRoot=Join-Path $layout.ManagedRoot 'runtime\venv'
    $wanted=[Math]::Max(35,261-$stageRuntimeRoot.Length)
    $segments=New-Object System.Collections.Generic.List[string]
    $relative=''
    $n=0
    while($relative.Length-lt$wanted){
        $segment=('seg{0:D2}abcdefghijkl' -f $n)
        $segments.Add($segment)
        $relative=($segments.ToArray()-join'\')+'\payload.bin'
        $n++
    }
    $liveDeep=Join-Path $runtimeRoot $relative
    if($liveDeep.Length-ge260){throw "Path-budget fixture live path is unexpectedly too long: $($liveDeep.Length)"}
    if((Join-Path $stageRuntimeRoot $relative).Length-lt260){throw 'Path-budget fixture did not reach the transaction staging limit.'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $liveDeep))
    [IO.File]::WriteAllText($liveDeep,'deep',[Text.Encoding]::ASCII)

    $wheel=Join-Path $budgetBase 'probe.whl'
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip=[IO.Compression.ZipFile]::Open($wheel,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $entry=$zip.CreateEntry('vllm/__init__.py')
        $stream=$entry.Open()
        try{
            $bytes=[Text.Encoding]::UTF8.GetBytes('x')
            $stream.Write($bytes,0,$bytes.Length)
        }finally{$stream.Dispose()}
    }finally{$zip.Dispose()}

    $sourceContext=[pscustomobject]@{
        Committed=[pscustomobject]@{
            State=[pscustomobject]@{
                python=[pscustomobject]@{root=$pythonRoot}
                uv=[pscustomobject]@{root=$uvRoot}
                runtime=[pscustomobject]@{root=$runtimeRoot}
            }
        }
    }
    $targetContext=[pscustomobject]@{
        PythonManifest=[pscustomobject]@{install=[pscustomobject]@{managed_relative_path='python\managed\python';python_executable='python.exe'}}
        UvManifest=[pscustomobject]@{install=[pscustomobject]@{managed_relative_path='uv\managed\uv';uv_executable='uv.exe'}}
        Release=[pscustomobject]@{orchestration=[pscustomobject]@{runtime_root='runtime\venv'}}
        DependencyManifest=[pscustomobject]@{materialization=[pscustomobject]@{cache_relative_path='cache\uv';staging_relative_path='work\dependency-stage'}}
        RuntimeManifest=[pscustomobject]@{materialization=[pscustomobject]@{staging_relative_path='work\runtime-stage'}}
    }
    Test-ExpectedFailure -Action {
        Assert-VllmUpdateRuntimeMaterializationPathBudget -InstallationRoot $budgetRoot -TransactionId $txid -SourceContext $sourceContext -TargetContext $targetContext -WheelPath $wheel
    } -Name 'deep-transaction-staging-path' -Expected 'materialization tree path exceeds'
}finally{
    if(Test-Path -LiteralPath $budgetBase){Remove-Item -LiteralPath $budgetBase -Recurse -Force}
}
Write-Host 'UPDATE_DEEP_TREE_PATH_BUDGET_OK'

Invoke-TestScenario -Name 'empty-activation-plan-refusal' -Body {
    param($scenario)
    $txid=[guid]::NewGuid().ToString('D')
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $scenario.Root -TransactionId $txid
    Test-ExpectedFailure -Action {
        Assert-VllmUpdateTransactionActivationPlan -Plan @() -Paths $paths -ModelsRoot $scenario.ModelsRoot -Phase materializing
    } -Name 'empty-activation-plan' -Expected 'must not be empty'
}
Write-Host 'UPDATE_EMPTY_ACTIVATION_PLAN_REFUSAL_OK'

$copyGuardBase=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-copy-guard-'+[guid]::NewGuid().ToString('N'))
try{
    $installRoot=Join-Path $copyGuardBase 'install'
    $sourceRoot=Join-Path $copyGuardBase 'source'
    $outside=Join-Path $copyGuardBase 'outside'
    [void][IO.Directory]::CreateDirectory($installRoot)
    [void][IO.Directory]::CreateDirectory($sourceRoot)
    [void][IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'payload.txt'),'source',[Text.UTF8Encoding]::new($false))
    $sentinel=Join-Path $outside 'KEEP.txt'
    [IO.File]::WriteAllText($sentinel,'DO-NOT-TOUCH',[Text.UTF8Encoding]::new($false))
    $managed=Join-Path $installRoot 'work'
    [void][IO.Directory]::CreateDirectory($managed)
    $pivot=Join-Path $managed 'pivot'
    New-Item -ItemType Junction -Path $pivot -Target $outside | Out-Null
    Test-ExpectedFailure -Action {
        Copy-VllmUpdateIntegrationTree -InstallationRoot $installRoot -Source $sourceRoot -Destination (Join-Path $pivot 'copied')
    } -Name 'integration-destination-junction' -Expected 'filesystem alias outside expected location'
    if((Get-Content -LiteralPath $sentinel -Raw).Trim()-ne'DO-NOT-TOUCH'){throw 'Integration destination junction modified outside sentinel.'}
    if(Test-Path -LiteralPath (Join-Path $outside 'copied')){throw 'Integration destination junction copied content outside installation root.'}
}finally{
    if(Test-Path -LiteralPath $copyGuardBase){Remove-Item -LiteralPath $copyGuardBase -Recurse -Force}
}
Write-Host 'UPDATE_INTEGRATION_DESTINATION_REPARSE_REFUSAL_OK'

$wheelCacheBase=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-wheel-cache-'+[guid]::NewGuid().ToString('N'))
try{
    $installRoot=Join-Path $wheelCacheBase 'i'
    $pythonRoot=Join-Path $installRoot 'python\managed\python'
    $uvRoot=Join-Path $installRoot 'uv\managed\uv'
    $cacheRoot=Join-Path $installRoot 'cache\uv'
    $runtimeRoot=Join-Path $installRoot 'runtime\venv'
    foreach($dir in @($pythonRoot,$uvRoot,$cacheRoot,$runtimeRoot)){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText((Join-Path $pythonRoot 'python.exe'),'x',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $uvRoot 'uv.exe'),'x',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $cacheRoot 'cache.bin'),'x',[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'runtime.bin'),'x',[Text.Encoding]::ASCII)

    $txid=[guid]::NewGuid().ToString('D')
    $paths=Get-VllmUpdateTransactionPaths -InstallationRoot $installRoot -TransactionId $txid
    $isolatedRoot=Join-Path $paths.MaterializationRoot 'r'
    $runtimePrefix=(Join-Path (Join-Path $isolatedRoot 'runtime\venv') 'Lib\site-packages')
    $cachePrefix=Join-Path (Join-Path $isolatedRoot 'cache\uv') (Join-Path 'archive-v0' ('x'.PadRight(64,[char]'x')))
    $minInternal=[Math]::Max(12,260-($cachePrefix.Length+1))
    if(($runtimePrefix.Length+1+$minInternal)-ge260){throw 'Wheel-cache path-budget fixture cannot isolate cache projection from runtime projection.'}
    $internal='vllm/'+('d'.PadRight($minInternal-8,[char]'d'))+'.py'

    $wheel=Join-Path $wheelCacheBase 'probe.whl'
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip=[IO.Compression.ZipFile]::Open($wheel,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $entry=$zip.CreateEntry($internal)
        $stream=$entry.Open()
        try{
            $bytes=[Text.Encoding]::UTF8.GetBytes('x')
            $stream.Write($bytes,0,$bytes.Length)
        }finally{$stream.Dispose()}
    }finally{$zip.Dispose()}

    $sourceContext=[pscustomobject]@{
        Committed=[pscustomobject]@{
            State=[pscustomobject]@{
                python=[pscustomobject]@{root=$pythonRoot}
                uv=[pscustomobject]@{root=$uvRoot}
                runtime=[pscustomobject]@{root=$runtimeRoot}
            }
        }
    }
    $targetContext=[pscustomobject]@{
        PythonManifest=[pscustomobject]@{install=[pscustomobject]@{managed_relative_path='python\managed\python';python_executable='python.exe'}}
        UvManifest=[pscustomobject]@{install=[pscustomobject]@{managed_relative_path='uv\managed\uv';uv_executable='uv.exe'}}
        Release=[pscustomobject]@{orchestration=[pscustomobject]@{runtime_root='runtime\venv'}}
        DependencyManifest=[pscustomobject]@{materialization=[pscustomobject]@{cache_relative_path='cache\uv';staging_relative_path='work\dependency-stage'}}
        RuntimeManifest=[pscustomobject]@{materialization=[pscustomobject]@{staging_relative_path='work\runtime-stage'}}
    }
    Test-ExpectedFailure -Action {
        Assert-VllmUpdateRuntimeMaterializationPathBudget -InstallationRoot $installRoot -TransactionId $txid -SourceContext $sourceContext -TargetContext $targetContext -WheelPath $wheel
    } -Name 'incoming-wheel-cache-path' -Expected 'isolated uv cache tree'
}finally{
    if(Test-Path -LiteralPath $wheelCacheBase){Remove-Item -LiteralPath $wheelCacheBase -Recurse -Force}
}
Write-Host 'UPDATE_INCOMING_WHEEL_CACHE_PATH_BUDGET_OK'
$liveGuardBase=Join-Path ([IO.Path]::GetTempPath()) ('vllm-update-live-guard-'+[guid]::NewGuid().ToString('N'))
try{
    $installRoot=Join-Path $liveGuardBase 'install'
    $runtimeRoot=Join-Path $installRoot 'runtime\venv'
    $scripts=Join-Path $runtimeRoot 'Scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    $targetContext=[pscustomobject]@{
        Release=[pscustomobject]@{
            orchestration=[pscustomobject]@{
                runtime_root='runtime\venv'
            }
        }
    }

    Test-ExpectedFailure -Action {
        Assert-VllmUpdateTargetLiveRuntime -InstallationRoot $installRoot -TargetContext $targetContext|Out-Null
    } -Name 'missing-target-vllm-launcher' -Expected 'launcher is missing before commit'

    [IO.File]::WriteAllText((Join-Path $scripts 'vllm.exe'),'launcher',[Text.Encoding]::ASCII)
    $proof=Assert-VllmUpdateTargetLiveRuntime -InstallationRoot $installRoot -TargetContext $targetContext
    if(-not(Test-Path -LiteralPath ([string]$proof.VllmExe) -PathType Leaf)){throw 'Target live launcher proof did not return the validated launcher.'}
}finally{
    if(Test-Path -LiteralPath $liveGuardBase){Remove-Item -LiteralPath $liveGuardBase -Recurse -Force}
}
Write-Host 'UPDATE_TARGET_LIVE_LAUNCHER_PRECOMMIT_GUARD_OK'
$cancellationPlan=[pscustomobject][ordered]@{
    source=[pscustomobject][ordered]@{
        release='cancel-source'
        manifest_sha256=('A'*64)
        generation_id='11111111-1111-1111-1111-111111111111'
    }
    target=[pscustomobject][ordered]@{
        release='cancel-target'
        manifest_sha256=('B'*64)
        wheel_sha256=('C'*64)
    }
    models_root='D:\Models'
    counts=[pscustomobject][ordered]@{
        distribution_reuse=1
        distribution_replace=2
        distribution_add=3
        distribution_retire=4
        managed_reuse=5
        managed_replace=6
        managed_add=7
        managed_retire=8
    }
}
$cancellation=Get-VllmUpdateCancellationResult -Plan $cancellationPlan -InstallationRoot 'D:\AI\vLLM'
$cancellationRoundTrip=($cancellation|ConvertTo-Json -Depth 12|ConvertFrom-Json)
if(-not$cancellationRoundTrip.ready-or$cancellationRoundTrip.committed-or-not$cancellationRoundTrip.cancelled-or$cancellationRoundTrip.what_if){
    throw 'Update cancellation JSON status flags are incorrect.'
}
if([string]$cancellationRoundTrip.release-ne'cancel-target'-or
   [string]$cancellationRoundTrip.generation_id-ne'11111111-1111-1111-1111-111111111111'-or
   [string]$cancellationRoundTrip.source.release-ne'cancel-source'-or
   [string]$cancellationRoundTrip.target.release-ne'cancel-target'-or
   [int]$cancellationRoundTrip.counts.managed_replace-ne6){
    throw 'Update cancellation JSON plan identity is incorrect.'
}
Write-Host 'UPDATE_CANCELLATION_JSON_CONTRACT_OK'
