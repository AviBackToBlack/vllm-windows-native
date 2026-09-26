Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\release-bundle.ps1')
. (Join-Path $repoRoot 'scripts\release-verification.ps1')
. (Join-Path $repoRoot 'scripts\release-acquisition.ps1')
. (Join-Path $repoRoot 'scripts\release-handoff.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $message=$null
    try{& $Action}catch{$message=$_.Exception.Message}
    if($null-eq$message){throw "Expected failure containing: $Contains"}
    if($message.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure: $message"}
}

function Write-TestFile {
    param([string]$Path,[string]$Text)
    $parent=Split-Path -Parent $Path
    if($parent){[void][IO.Directory]::CreateDirectory($parent)}
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Get-TestIdentity {
    param([string]$Path)
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    [pscustomobject][ordered]@{Size=[int64]$item.Length;Sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()}
}

function Write-FakeLifecycleScripts {
    param([string]$Root)
    $install=@'
param(
    [string]$ReleaseManifestPath,
    [string]$InstallationRoot='',
    [string]$ModelsRoot='',
    [string]$WheelPath,
    [string]$PythonArchivePath='',
    [string]$UvArchivePath='',
    [switch]$Offline,
    [switch]$Json
)
$ErrorActionPreference='Stop'
$release=Get-Content -LiteralPath $ReleaseManifestPath -Raw|ConvertFrom-Json
$expectedManifest=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ([string]$release.self_path).Replace('/','\')))
if(-not([IO.Path]::GetFullPath($ReleaseManifestPath)).Equals($expectedManifest,[StringComparison]::OrdinalIgnoreCase)){throw 'fake install manifest is outside materialized distribution'}
foreach($entry in @($release.files)){
    $path=Join-Path $PSScriptRoot ([string]$entry.path).Replace('/','\')
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "fake install missing distribution file: $path"}
    $item=Get-Item -LiteralPath $path
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if($item.Length-ne[int64]$entry.size_bytes-or-not$hash.Equals([string]$entry.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "fake install distribution mismatch: $path"}
}
$wheel=Get-Item -LiteralPath $WheelPath
$wheelHash=(Get-FileHash -LiteralPath $WheelPath -Algorithm SHA256).Hash
if($wheel.Name-ne[string]$release.wheel.filename-or$wheel.Length-ne[int64]$release.wheel.size_bytes-or-not$wheelHash.Equals([string]$release.wheel.sha256,[StringComparison]::OrdinalIgnoreCase)){throw 'fake install wheel mismatch'}
[pscustomobject][ordered]@{
    action='install'
    script_root=$PSScriptRoot
    manifest=[IO.Path]::GetFullPath($ReleaseManifestPath)
    wheel=[IO.Path]::GetFullPath($WheelPath)
    installation_root=$InstallationRoot
    models_root=$ModelsRoot
    offline=[bool]$Offline
    json=[bool]$Json
}|ConvertTo-Json -Compress
'@
    $update=@'
param(
    [string]$ReleaseManifestPath,
    [string]$InstallationRoot='',
    [string]$WheelPath,
    [switch]$WhatIf,
    [switch]$Confirm,
    [switch]$Json
)
$ErrorActionPreference='Stop'
$release=Get-Content -LiteralPath $ReleaseManifestPath -Raw|ConvertFrom-Json
$expectedManifest=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ([string]$release.self_path).Replace('/','\')))
if(-not([IO.Path]::GetFullPath($ReleaseManifestPath)).Equals($expectedManifest,[StringComparison]::OrdinalIgnoreCase)){throw 'fake update manifest is outside materialized distribution'}
foreach($entry in @($release.files)){
    $path=Join-Path $PSScriptRoot ([string]$entry.path).Replace('/','\')
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "fake update missing distribution file: $path"}
    $item=Get-Item -LiteralPath $path
    $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if($item.Length-ne[int64]$entry.size_bytes-or-not$hash.Equals([string]$entry.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "fake update distribution mismatch: $path"}
}
$wheel=Get-Item -LiteralPath $WheelPath
$wheelHash=(Get-FileHash -LiteralPath $WheelPath -Algorithm SHA256).Hash
if($wheel.Name-ne[string]$release.wheel.filename-or$wheel.Length-ne[int64]$release.wheel.size_bytes-or-not$wheelHash.Equals([string]$release.wheel.sha256,[StringComparison]::OrdinalIgnoreCase)){throw 'fake update wheel mismatch'}
[pscustomobject][ordered]@{
    action='update'
    script_root=$PSScriptRoot
    manifest=[IO.Path]::GetFullPath($ReleaseManifestPath)
    wheel=[IO.Path]::GetFullPath($WheelPath)
    installation_root=$InstallationRoot
    what_if=[bool]$WhatIf
    confirm=[bool]$Confirm
    json=[bool]$Json
}|ConvertTo-Json -Compress
'@
    Write-TestFile -Path (Join-Path $Root 'install.ps1') -Text $install
    Write-TestFile -Path (Join-Path $Root 'update.ps1') -Text $update
}

function Initialize-HandoffFixture {
    param([string]$Root)
    $source=Join-Path $Root 'distribution-source'
    [void][IO.Directory]::CreateDirectory($source)
    Write-FakeLifecycleScripts -Root $source
    Write-TestFile -Path (Join-Path $source 'payload\marker.txt') -Text ('handoff-payload'+[char]10)
    $runtime=[ordered]@{
        schema_version=1
        component='vllm-runtime'
        milestone='handoff-test'
        platform='windows-x86_64'
        project_wheel=[ordered]@{
            distribution='vllm'
            version='1.2.3'
            filename='vllm-1.2.3-cp313-cp313-win_amd64.whl'
            size_bytes=0
            sha256=('0'*64)
            python_tag='cp313'
            abi_tag='cp313'
            platform_tag='win_amd64'
            acquisition='provided-only'
            dependency_install='no-deps-no-index'
            native_extension_count=0
            native_extensions=@()
        }
    }
    $runtimePath=Join-Path $source 'manifests\runtime\runtime.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runtimePath))
    Write-VllmReleaseCanonicalJson -Value $runtime -Path $runtimePath

    $wheel=Join-Path $Root 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestFile -Path $wheel -Text 'synthetic-wheel'
    $wheelId=Get-TestIdentity -Path $wheel
    $runtime.project_wheel.size_bytes=$wheelId.Size
    $runtime.project_wheel.sha256=$wheelId.Sha256
    Write-VllmReleaseCanonicalJson -Value $runtime -Path $runtimePath

    $relativeFiles=@('install.ps1','manifests/runtime/runtime.json','payload/marker.txt','update.ps1')
    $files=New-Object System.Collections.Generic.List[object]
    foreach($relative in $relativeFiles){
        $path=Join-Path $source $relative.Replace('/','\')
        $id=Get-TestIdentity -Path $path
        $files.Add([ordered]@{path=$relative;size_bytes=[int64]$id.Size;sha256=[string]$id.Sha256})
    }
    $release=[ordered]@{
        schema_version=1
        component='runtime-release'
        release='handoff-test'
        platform='windows-x86_64'
        self_path='manifests/release/handoff-test.json'
        upstream=[ordered]@{
            repository='https://github.com/vllm-project/vllm'
            tag='v0.27.1'
            commit=('1'*40)
        }
        windows_patchset=[ordered]@{
            implementation_commit=('2'*40)
            tree=('3'*40)
            patch_sha256=('4'*64)
        }
        wheel=[ordered]@{
            filename=[IO.Path]::GetFileName($wheel)
            version='1.2.3'
            size_bytes=[int64]$wheelId.Size
            sha256=[string]$wheelId.Sha256
        }
        orchestration=[ordered]@{
            python_manifest='manifests/runtime/runtime.json'
            uv_manifest='manifests/runtime/runtime.json'
            venv_manifest='manifests/runtime/runtime.json'
            dependency_manifest='manifests/runtime/runtime.json'
            runtime_manifest='manifests/runtime/runtime.json'
            python_receipt='forensic/python.json'
            uv_receipt='forensic/uv.json'
            venv_receipt='forensic/venv.json'
            dependency_receipt='forensic/deps.json'
            runtime_receipt='forensic/runtime.json'
            runtime_root='runtime/venv'
        }
        managed_paths=@('runtime/venv')
        files=$files.ToArray()
    }
    $releasePath=Join-Path $source 'manifests\release\handoff-test.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $releasePath))
    Write-VllmReleaseCanonicalJson -Value $release -Path $releasePath
    $releaseId=Get-TestIdentity -Path $releasePath
    $runtimeId=Get-TestIdentity -Path $runtimePath

    $memberMap=@{}
    foreach($relative in @($relativeFiles+'manifests/release/handoff-test.json')){
        $path=Join-Path $source $relative.Replace('/','\')
        $id=Get-TestIdentity -Path $path
        $memberMap[$relative]=[pscustomobject][ordered]@{
            RelativePath=$relative
            Path=$path
            Size=[int64]$id.Size
            Sha256=[string]$id.Sha256
        }
    }
    $sorted=Get-VllmReleaseOrdinalStrings -Values @($memberMap.Keys)
    $members=New-Object System.Collections.Generic.List[object]
    foreach($name in $sorted){$members.Add($memberMap[$name])}

    $tagObject='a'*40
    $projectCommit='b'*40
    $cacheRoot=Join-Path $Root 'cache'
    $entry=Join-Path (Join-Path (Join-Path $cacheRoot 'verified') ([string]$script:VllmAcquisitionRepositoryId)) $tagObject
    $artifacts=Join-Path $entry 'artifacts'
    [void][IO.Directory]::CreateDirectory($artifacts)
    Copy-Item -LiteralPath $wheel -Destination (Join-Path $artifacts ([IO.Path]::GetFileName($wheel))
    $bundle=Join-Path $artifacts 'vllm-windows-native-handoff-test.zip'
    Write-VllmReleaseStoredZip -Context ([pscustomobject]@{Members=$members.ToArray()}) -Path $bundle
    Write-TestFile -Path (Join-Path $artifacts 'release-index.json') -Text ('{}'+[char]10)
    Write-TestFile -Path (Join-Path $artifacts 'SHA256SUMS') -Text ('fixture'+[char]10)
    $wheelArtifact=Get-TestIdentity -Path (Join-Path $artifacts ([IO.Path]::GetFileName($wheel))
    $bundleArtifact=Get-TestIdentity -Path $bundle
    $indexArtifact=Get-TestIdentity -Path (Join-Path $artifacts 'release-index.json')
    $checksumsArtifact=Get-TestIdentity -Path (Join-Path $artifacts 'SHA256SUMS')

    $receipt=[ordered]@{
        schema_version=1
        component='vllm-windows-native-acquisition-receipt'
        verified_utc=[DateTimeOffset]::UtcNow.ToString('o')
        repository=[ordered]@{
            slug=$script:VllmAcquisitionRepository
            id=[int64]$script:VllmAcquisitionRepositoryId
            node_id=$script:VllmAcquisitionRepositoryNodeId
            canonical_https_url=$script:VllmAcquisitionCanonicalGitUrl
        }
        release=[ordered]@{
            release='handoff-test'
            tag='release/handoff-test'
            tag_object=$tagObject
            project_commit=$projectCommit
            release_manifest_path='manifests/release/handoff-test.json'
            release_manifest_sha256=$releaseId.Sha256
            runtime_manifest_sha256=$runtimeId.Sha256
        }
        signing=[ordered]@{
            principal='fixture-release'
            key_fingerprint='SHA256:fixture'
        }
        artifacts=[ordered]@{
            wheel=[ordered]@{filename=[IO.Path]::GetFileName($wheel);size_bytes=[int64]$wheelArtifact.Size;sha256=$wheelArtifact.Sha256}
            bundle=[ordered]@{filename=[IO.Path]::GetFileName($bundle);size_bytes=[int64]$bundleArtifact.Size;sha256=$bundleArtifact.Sha256}
            index=[ordered]@{filename='release-index.json';size_bytes=[int64]$indexArtifact.Size;sha256=$indexArtifact.Sha256}
            checksums=[ordered]@{filename='SHA256SUMS';size_bytes=[int64]$checksumsArtifact.Size;sha256=$checksumsArtifact.Sha256}
        }
        verification=[ordered]@{
            offline_release_schema=1
            github_release_attestation_schema=1
            per_asset_attestation_count=4
        }
    }
    $receiptPath=Join-Path $entry 'acquisition-receipt.json'
    Write-VllmReleaseCanonicalJson -Value $receipt -Path $receiptPath

    $acquisition=[pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-acquisition'
        repository=$script:VllmAcquisitionRepository
        release='handoff-test'
        tag='release/handoff-test'
        tag_object=$tagObject
        project_commit=$projectCommit
        cache_entry=$entry
        artifacts_directory=$artifacts
        wheel_path=(Join-Path $artifacts ([IO.Path]::GetFileName($wheel))
        bundle_path=$bundle
        release_index_path=(Join-Path $artifacts 'release-index.json')
        checksums_path=(Join-Path $artifacts 'SHA256SUMS')
        receipt_path=$receiptPath
        release_manifest_path='manifests/release/handoff-test.json'
        release_manifest_sha256=$releaseId.Sha256
        runtime_manifest_sha256=$runtimeId.Sha256
        signing_principal='fixture-release'
        signing_key_fingerprint='SHA256:fixture'
        wheel_sha256=$wheelArtifact.Sha256
        bundle_sha256=$bundleArtifact.Sha256
        release_index_sha256=$indexArtifact.Sha256
        checksums_sha256=$checksumsArtifact.Sha256
    }
    [pscustomobject][ordered]@{
        Acquisition=$acquisition
        CacheRoot=$cacheRoot
        Entry=$entry
        Artifacts=$artifacts
        Bundle=$bundle
        ReceiptPath=$receiptPath
        Receipt=$receipt
    }
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm20c-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $fixture=Initialize-HandoffFixture -Root $root
    $before=@{}
    foreach($file in @(Get-ChildItem -LiteralPath $fixture.Artifacts -File)){$before[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}

    $installJson=Invoke-VllmAcquisitionInstallHandoff -Acquisition $fixture.Acquisition -InstallationRoot 'C:\fixture-install' -ModelsRoot 'C:\fixture-models' -Offline -Json
    $install=$installJson|ConvertFrom-Json
    if([string]$install.action-ne'install'-or-not[bool]$install.offline-or-not[bool]$install.json){throw 'Install handoff did not preserve lifecycle switches.'}
    if(-not([string]$install.script_root).Contains('.handoff',[StringComparison]::OrdinalIgnoreCase)){throw 'Install handoff did not execute the materialized installer.'}
    if(-not([string]$install.manifest).StartsWith([string]$install.script_root,[StringComparison]::OrdinalIgnoreCase)){throw 'Install handoff manifest is outside materialized distribution.'}
    if(-not(Test-VllmAcquisitionHandoffPathEqual -A ([string]$install.wheel) -B ([string]$fixture.Acquisition.wheel_path)){throw 'Install handoff did not preserve the verified wheel path.'}
    Write-Host 'RELEASE_HANDOFF_INSTALL_OK'

    $updateJson=Invoke-VllmAcquisitionUpdateHandoff -Acquisition $fixture.Acquisition -InstallationRoot 'C:\fixture-update' -WhatIf -Confirm:$false -Json
    $update=$updateJson|ConvertFrom-Json
    if([string]$update.action-ne'update'-or-not[bool]$update.what_if-or[bool]$update.confirm-ne$false-or-not[bool]$update.json){throw 'Update handoff did not preserve lifecycle switches.'}
    if(-not([string]$update.script_root).Contains('.handoff',[StringComparison]::OrdinalIgnoreCase)){throw 'Update handoff did not execute the materialized updater.'}
    if(-not([string]$update.manifest).StartsWith([string]$update.script_root,[StringComparison]::OrdinalIgnoreCase)){throw 'Update handoff manifest is outside materialized distribution.'}
    Write-Host 'RELEASE_HANDOFF_UPDATE_OK'

    $handoffRoot=Join-Path $fixture.CacheRoot '.handoff'
    if((Test-Path -LiteralPath $handoffRoot)-and@(Get-ChildItem -LiteralPath $handoffRoot -Force).Count-ne0){throw 'Successful lifecycle handoff leaked a materialization generation.'}
    foreach($file in @(Get-ChildItem -LiteralPath $fixture.Artifacts -File)){
        $after=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if($after-ne$before[$file.Name]){throw "Lifecycle handoff mutated verified cache artifact: $($file.Name)"}
    }
    Write-Host 'RELEASE_HANDOFF_CACHE_IMMUTABLE_OK'

    $lockedObserved=$false
    $probe={
        param($Mode,$ScriptPath,$Parameters)
        $null=$Mode;$null=$ScriptPath
        try{
            $writer=[IO.File]::Open([string]$Parameters.WheelPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$writer.Dispose()}finally{}
        }catch [IO.IOException]{$script:lockedObserved=$true}
        if(-not$script:lockedObserved){throw 'Verified wheel was writable while lifecycle handoff was active.'}
        throw 'INJECTED_LIFECYCLE_FAILURE'
    }
    Assert-Fails {
        Invoke-VllmAcquisitionInstallHandoff -Acquisition $fixture.Acquisition -LifecycleInvoker $probe
    } 'INJECTED_LIFECYCLE_FAILURE'
    if(-not$lockedObserved){throw 'Lifecycle handoff did not pin verified source artifacts.'}
    if((Test-Path -LiteralPath $handoffRoot)-and@(Get-ChildItem -LiteralPath $handoffRoot -Force).Count-ne0){throw 'Failed lifecycle handoff leaked a materialization generation.'}
    Write-Host 'RELEASE_HANDOFF_FAILURE_CLEANUP_OK'

    $originalReceiptRaw=Get-Content -LiteralPath $fixture.ReceiptPath -Raw
    $receipt=$originalReceiptRaw|ConvertFrom-Json
    $receipt.release.release_manifest_sha256='F'*64
    Write-VllmReleaseCanonicalJson -Value $receipt -Path $fixture.ReceiptPath
    Assert-Fails {
        Invoke-VllmAcquisitionInstallHandoff -Acquisition $fixture.Acquisition -LifecycleInvoker {throw 'should not run'}
    } 'release manifest SHA-256 does not match the verified acquisition result'
    [IO.File]::WriteAllText($fixture.ReceiptPath,$originalReceiptRaw,[Text.UTF8Encoding]::new($false))
    Write-Host 'RELEASE_HANDOFF_RECEIPT_REBIND_FAIL_CLOSED_OK'

    $wheelPath=[string]$fixture.Acquisition.wheel_path
    $wheelRaw=[IO.File]::ReadAllBytes($wheelPath)
    [IO.File]::AppendAllText($wheelPath,'tamper',[Text.UTF8Encoding]::new($false))
    Assert-Fails {
        Invoke-VllmAcquisitionUpdateHandoff -Acquisition $fixture.Acquisition -LifecycleInvoker {throw 'should not run'}
    } 'artifact identity mismatch'
    [IO.File]::WriteAllBytes($wheelPath,$wheelRaw)
    Write-Host 'RELEASE_HANDOFF_WHEEL_TAMPER_FAIL_CLOSED_OK'

    $bundleRaw=[IO.File]::ReadAllBytes($fixture.Bundle)
    $malicious=Join-Path $root 'malicious.zip'
    $zip=[IO.Compression.ZipFile]::Open($malicious,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $entry=$zip.CreateEntry('../evil.txt',[IO.Compression.CompressionLevel]::NoCompression)
        $stream=$entry.Open()
        try{
            $bytes=[Text.Encoding]::UTF8.GetBytes('evil')
            $stream.Write($bytes,0,$bytes.Length)
        }finally{$stream.Dispose()}
    }finally{$zip.Dispose()}
    Copy-Item -LiteralPath $malicious -Destination $fixture.Bundle -Force
    $maliciousId=Get-TestIdentity -Path $fixture.Bundle
    $receipt=Get-Content -LiteralPath $fixture.ReceiptPath -Raw|ConvertFrom-Json
    $receipt.artifacts.bundle.size_bytes=[int64]$maliciousId.Size
    $receipt.artifacts.bundle.sha256=[string]$maliciousId.Sha256
    Write-VllmReleaseCanonicalJson -Value $receipt -Path $fixture.ReceiptPath
    $fixture.Acquisition.bundle_sha256=[string]$maliciousId.Sha256
    Assert-Fails {
        Invoke-VllmAcquisitionInstallHandoff -Acquisition $fixture.Acquisition -LifecycleInvoker {throw 'should not run'}
    } 'unsafe path segment'
    Write-Host 'RELEASE_HANDOFF_ARCHIVE_TRAVERSAL_FAIL_CLOSED_OK'

    Write-Host 'RELEASE_HANDOFF_CONTRACT_OK'
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
