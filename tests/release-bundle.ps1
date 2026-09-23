[CmdletBinding()]
param([string]$SummaryPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\release-bundle.ps1')

function Write-TestBytes {
    param([string]$Path,[string]$Text)
    $parent=Split-Path -Parent $Path
    if($parent){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Get-TestIdentity {
    param([string]$Path)
    $i=Get-VllmReleaseFileIdentity -Path $Path
    return [ordered]@{path=$null;size_bytes=[int64]$i.Size;sha256=[string]$i.Sha256}
}

function Test-ExpectedFailure {
    param([scriptblock]$Action,[string]$Label)
    $expected=@{
        'wheel-filename-case'='Provided release wheel filename mismatch.'
        'wheel-native-extension-case'='Provided release wheel native extension set mismatch'
        'wheel-extra-native-extension-case'='Provided release wheel native extension count does not match runtime manifest.'
        'wheel-unsafe-member'='Provided release wheel member contains an unsafe path segment'
        'wheel-metadata-name-line'='Provided release wheel distribution name is not vllm.'
        'wheel-metadata-version-line'='Provided release wheel version does not match runtime manifest.'
        'wheel-tag-substring'='Provided release wheel compatibility tag is missing'
        'nonempty-output-refusal'='Release artifacts directory is not empty'
        'prepare-concurrent-lock'='Another offline release preparation is active'
        'prepare-fault-during-wheel'='FAULT_INJECTED:DuringWheelCopy'
        'prepare-fault-after-wheel'='FAULT_INJECTED:AfterWheelCopy'
        'prepare-fault-after-bundle'='FAULT_INJECTED:AfterBundle'
        'wheel-tamper'='Provided release wheel size/SHA-256 mismatch.'
        'index-tamper'='release-index.json does not exactly match the canonical index'
        'index-identity-case'='release-index.json does not exactly match the canonical index'
        'index-noncanonical-json'='release-index.json does not exactly match the canonical index'
        'index-property-order'='release-index.json does not exactly match the canonical index'
        'index-bom'='release-index.json must be UTF-8 without BOM.'
        'checksums-tamper'='Invalid SHA256SUMS line'
        'checksums-noncanonical-order'='SHA256SUMS entries are not in canonical ordinal order.'
        'checksums-bom'='SHA256SUMS must be UTF-8 without BOM.'
        'unexpected-fifth-asset'='Release artifact filename set count mismatch.'
        'zip-extra-member'='Release ZIP bytes are not the exact canonical tagged-commit bundle.'
        'zip-missing-member'='Release ZIP bytes are not the exact canonical tagged-commit bundle.'
        'zip-non-store-method'='Release ZIP bytes are not the exact canonical tagged-commit bundle.'
        'zip-local-header-name'='Release ZIP bytes are not the exact canonical tagged-commit bundle.'
        'manifest-blob-drift'='Tagged-commit blob does not match release manifest identity'
        'unsafe-release-path'='Release distribution path contains an unsafe path segment'
        'case-colliding-release-path'='Release distribution paths collide by Windows identity'
    }
    if(-not$expected.ContainsKey($Label)){throw "Expected failure reason is not configured: $Label"}
    try { & $Action; throw "Expected failure did not occur: $Label" }
    catch {
        if($_.Exception.Message -eq "Expected failure did not occur: $Label"){throw}
        if($_.Exception.Message.IndexOf([string]$expected[$Label],[StringComparison]::Ordinal)-lt0){
            throw "Expected failure '$Label' occurred for the wrong reason. Expected substring '$($expected[$Label])'; got '$($_.Exception.Message)'."
        }
        Write-Host "EXPECTED_FAILURE_OK $Label"
    }
}
function Write-TestArtifactChecksums {
    param([Parameter(Mandatory)][string]$ArtifactsDirectory)
    $wheel=Get-ChildItem -LiteralPath $ArtifactsDirectory -Filter '*.whl' -File
    if(@($wheel).Count-ne1){throw 'Synthetic release must contain exactly one wheel for checksum rewrite.'}
    $bundle=Get-ChildItem -LiteralPath $ArtifactsDirectory -Filter 'vllm-windows-native-*.zip' -File
    if(@($bundle).Count-ne1){throw 'Synthetic release must contain exactly one bundle for checksum rewrite.'}
    $ids=@{}
    foreach($file in @($wheel[0],$bundle[0],(Get-Item -LiteralPath (Join-Path $ArtifactsDirectory 'release-index.json')))){
        $ids[$file.Name]=(Get-VllmReleaseFileIdentity -Path $file.FullName).Sha256
    }
    Write-VllmReleaseChecksums -Identities $ids -Path (Join-Path $ArtifactsDirectory 'SHA256SUMS')
}

function Write-TestWheel {
    param(
        [string]$Path,
        [string]$NativePath = 'vllm/_test.pyd',
        [hashtable]$ExtraEntries = @{},
        [string]$MetadataText = '',
        [string]$WheelMetadataText = ''
    )
    $parent=Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $sourceRoot=$Path+'.source'
    if(Test-Path -LiteralPath $sourceRoot){Remove-Item -LiteralPath $sourceRoot -Recurse -Force}
    New-Item -ItemType Directory -Path $sourceRoot -Force|Out-Null
    try{
        $entries=[ordered]@{}
        $entries['vllm/__init__.py']="__version__ = '1.2.3'"+[char]10
        $entries[$NativePath]='synthetic-native-bytes'
        if([string]::IsNullOrEmpty($MetadataText)){$MetadataText="Metadata-Version: 2.1"+[char]10+"Name: vllm"+[char]10+"Version: 1.2.3"+[char]10}
        if([string]::IsNullOrEmpty($WheelMetadataText)){$WheelMetadataText="Wheel-Version: 1.0"+[char]10+"Generator: sm19a-test"+[char]10+"Root-Is-Purelib: false"+[char]10+"Tag: cp313-cp313-win_amd64"+[char]10}
        $entries['vllm-1.2.3.dist-info/METADATA']=$MetadataText
        $entries['vllm-1.2.3.dist-info/WHEEL']=$WheelMetadataText
        foreach($name in @($ExtraEntries.Keys)){
            if($entries.Contains($name)){throw "Duplicate synthetic wheel entry: $name"}
            $entries[$name]=[string]$ExtraEntries[$name]
        }
        $members=New-Object System.Collections.Generic.List[object]
        foreach($name in (Get-VllmReleaseOrdinalStrings -Values @($entries.Keys))){
            $file=Join-Path $sourceRoot $name.Replace('/','\')
            Write-TestBytes -Path $file -Text ([string]$entries[$name])
            $id=Get-VllmReleaseFileIdentity -Path $file
            $members.Add([pscustomobject][ordered]@{RelativePath=$name;Path=$file;Size=[int64]$id.Size;Sha256=[string]$id.Sha256})
        }
        Write-VllmReleaseStoredZip -Context ([pscustomobject]@{Members=$members.ToArray()}) -Path $Path
    }finally{
        Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Initialize-FixtureRepo {
    param([string]$Root,[string]$WheelPath)
    New-Item -ItemType Directory -Path $Root -Force|Out-Null
    & git -C $Root init --initial-branch=main | Out-Null
    if($LASTEXITCODE-ne0){throw 'fixture git init failed'}
    & git -C $Root config user.name 'SM19A Fixture'
    & git -C $Root config user.email 'sm19a@example.invalid'
    & git -C $Root config core.autocrlf false
    Write-TestBytes -Path (Join-Path $Root 'payload\a.txt') -Text "alpha`n"
    Write-TestBytes -Path (Join-Path $Root 'payload\B.txt') -Text "bravo`n"

    $wheel=Get-VllmReleaseFileIdentity -Path $WheelPath
    $runtime=[ordered]@{
        schema_version=1
        component='vllm-runtime'
        milestone='test-release'
        platform='windows-x86_64'
        project_wheel=[ordered]@{
            distribution='vllm'
            version='1.2.3'
            filename='vllm-1.2.3-cp313-cp313-win_amd64.whl'
            size_bytes=[int64]$wheel.Size
            sha256=[string]$wheel.Sha256
            python_tag='cp313'
            abi_tag='cp313'
            platform_tag='win_amd64'
            acquisition='provided-only'
            dependency_install='no-deps-no-index'
            native_extension_count=1
            native_extensions=@('vllm\_test.pyd')
        }
    }
    $runtimePath=Join-Path $Root 'manifests\runtime\runtime.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $runtimePath) -Force|Out-Null
    Write-VllmReleaseCanonicalJson -Value $runtime -Path $runtimePath

    $files=New-Object System.Collections.Generic.List[object]
    foreach($relative in @('manifests/runtime/runtime.json','payload/B.txt','payload/a.txt')){
        $path=Join-Path $Root ($relative.Replace('/','\'))
        $id=Get-VllmReleaseFileIdentity -Path $path
        $files.Add([ordered]@{path=$relative;size_bytes=[int64]$id.Size;sha256=[string]$id.Sha256})
    }
    $release=[ordered]@{
        schema_version=1
        component='runtime-release'
        release='test-release'
        platform='windows-x86_64'
        self_path='manifests/release/release.json'
        upstream=[ordered]@{repository='https://example.invalid/upstream.git';tag='v1.2.3';commit='1111111111111111111111111111111111111111'}
        windows_patchset=[ordered]@{implementation_commit='2222222222222222222222222222222222222222';tree='3333333333333333333333333333333333333333';patch_sha256=('44'*32)}
        wheel=[ordered]@{filename='vllm-1.2.3-cp313-cp313-win_amd64.whl';version='1.2.3';size_bytes=[int64]$wheel.Size;sha256=[string]$wheel.Sha256}
        orchestration=[ordered]@{
            python_manifest='manifests/bootstrap/python.json'
            uv_manifest='manifests/bootstrap/uv.json'
            venv_manifest='manifests/bootstrap/venv.json'
            dependency_manifest='manifests/runtime/deps.json'
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
    $releasePath=Join-Path $Root 'manifests\release\release.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $releasePath) -Force|Out-Null
    Write-VllmReleaseCanonicalJson -Value $release -Path $releasePath

    & git -C $Root add .
    if($LASTEXITCODE-ne0){throw 'fixture git add failed'}
    $oldAuthor=$env:GIT_AUTHOR_DATE;$oldCommitter=$env:GIT_COMMITTER_DATE
    try{
        $env:GIT_AUTHOR_DATE='2026-01-01T00:00:00Z'
        $env:GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
        & git -C $Root commit -m 'fixture' | Out-Null
        if($LASTEXITCODE-ne0){throw 'fixture git commit failed'}
    }finally{$env:GIT_AUTHOR_DATE=$oldAuthor;$env:GIT_COMMITTER_DATE=$oldCommitter}
    return (Invoke-Git -Repository $Root -Arguments @('rev-parse','HEAD') -Capture)
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('sm19a-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
try {
    $wheelPath=Join-Path $root 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestWheel -Path $wheelPath
    $fixture=Join-Path $root 'repo'
    $commit=Initialize-FixtureRepo -Root $fixture -WheelPath $wheelPath

    $out1=Join-Path $root 'out1'
    $out2=Join-Path $root 'out2'
    $r1=Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $out1
    [void](Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $out2)
    foreach($name in @('vllm-1.2.3-cp313-cp313-win_amd64.whl','vllm-windows-native-test-release.zip','release-index.json','SHA256SUMS')){
        $a=(Get-VllmReleaseFileIdentity -Path (Join-Path $out1 $name)).Sha256
        $b=(Get-VllmReleaseFileIdentity -Path (Join-Path $out2 $name)).Sha256
        if($a-ne$b){throw "Repeated release preparation is not deterministic: $name"}
    }
    Write-Host 'RELEASE_DETERMINISM_OK'

    $snapshot=Get-VllmReleaseGitSnapshot -Repository $fixture -Commit $commit
    try{
        $context=Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath 'manifests/release/release.json'
        $wheelTemp=Join-Path $root 'wheel-case-temp.whl'
        $caseWheelPath=Join-Path $root 'VLLM-1.2.3-cp313-cp313-win_amd64.whl'
        Move-Item -LiteralPath $wheelPath -Destination $wheelTemp
        Move-Item -LiteralPath $wheelTemp -Destination $caseWheelPath
        try{
            Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $caseWheelPath -Context $context|Out-Null} 'wheel-filename-case'
        }finally{
            Move-Item -LiteralPath $caseWheelPath -Destination $wheelTemp
            Move-Item -LiteralPath $wheelTemp -Destination $wheelPath
        }
    }finally{Close-VllmReleaseGitSnapshot -Snapshot $snapshot}

    $caseNativeRoot=Join-Path $root 'case-native'
    $caseNativeWheel=Join-Path $caseNativeRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestWheel -Path $caseNativeWheel -NativePath 'vllm/_TEST.pyd'
    $caseNativeRepo=Join-Path $caseNativeRoot 'repo'
    $caseNativeCommit=Initialize-FixtureRepo -Root $caseNativeRepo -WheelPath $caseNativeWheel
    $caseNativeSnapshot=Get-VllmReleaseGitSnapshot -Repository $caseNativeRepo -Commit $caseNativeCommit
    try{
        $caseNativeContext=Get-VllmReleaseContext -Snapshot $caseNativeSnapshot -ReleaseManifestPath 'manifests/release/release.json'
        Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $caseNativeWheel -Context $caseNativeContext|Out-Null} 'wheel-native-extension-case'
    }finally{Close-VllmReleaseGitSnapshot -Snapshot $caseNativeSnapshot}
    $extraNativeRoot=Join-Path $root 'extra-native-case'
    $extraNativeWheel=Join-Path $extraNativeRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestWheel -Path $extraNativeWheel -ExtraEntries @{'vllm/evil.PYD'='extra-native-bytes'}
    $extraNativeRepo=Join-Path $extraNativeRoot 'repo';$extraNativeCommit=Initialize-FixtureRepo -Root $extraNativeRepo -WheelPath $extraNativeWheel
    $extraNativeSnapshot=Get-VllmReleaseGitSnapshot -Repository $extraNativeRepo -Commit $extraNativeCommit
    try{$extraNativeContext=Get-VllmReleaseContext -Snapshot $extraNativeSnapshot -ReleaseManifestPath 'manifests/release/release.json';Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $extraNativeWheel -Context $extraNativeContext|Out-Null} 'wheel-extra-native-extension-case'}finally{Close-VllmReleaseGitSnapshot -Snapshot $extraNativeSnapshot}

    $unsafeWheelRoot=Join-Path $root 'unsafe-wheel'
    $unsafeWheel=Join-Path $unsafeWheelRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestWheel -Path $unsafeWheel
    $unsafeZip=[IO.Compression.ZipFile]::Open($unsafeWheel,[IO.Compression.ZipArchiveMode]::Update)
    try{
        $unsafeEntry=$unsafeZip.CreateEntry('../escape.txt',[IO.Compression.CompressionLevel]::NoCompression)
        $unsafeEntry.LastWriteTime=$script:VllmReleaseZipTimestamp
        $unsafeEntry.ExternalAttributes=0
        $writer=New-Object IO.StreamWriter($unsafeEntry.Open())
        try{$writer.Write('escape')}finally{$writer.Dispose()}
    }finally{$unsafeZip.Dispose()}
    $unsafeWheelRepo=Join-Path $unsafeWheelRoot 'repo'
    $unsafeWheelCommit=Initialize-FixtureRepo -Root $unsafeWheelRepo -WheelPath $unsafeWheel
    $unsafeWheelSnapshot=Get-VllmReleaseGitSnapshot -Repository $unsafeWheelRepo -Commit $unsafeWheelCommit
    try{
        $unsafeWheelContext=Get-VllmReleaseContext -Snapshot $unsafeWheelSnapshot -ReleaseManifestPath 'manifests/release/release.json'
        Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $unsafeWheel -Context $unsafeWheelContext|Out-Null} 'wheel-unsafe-member'
    }finally{Close-VllmReleaseGitSnapshot -Snapshot $unsafeWheelSnapshot}
    $badNameRoot=Join-Path $root 'bad-name-metadata'
    $badNameWheel=Join-Path $badNameRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    $badNameText="Metadata-Version: 2.1"+[char]10+"Name:"+[char]10+" vllm"+[char]10+"Version: 1.2.3"+[char]10
    Write-TestWheel -Path $badNameWheel -MetadataText $badNameText
    $badNameRepo=Join-Path $badNameRoot 'repo';$badNameCommit=Initialize-FixtureRepo -Root $badNameRepo -WheelPath $badNameWheel
    $badNameSnapshot=Get-VllmReleaseGitSnapshot -Repository $badNameRepo -Commit $badNameCommit
    try{$badNameContext=Get-VllmReleaseContext -Snapshot $badNameSnapshot -ReleaseManifestPath 'manifests/release/release.json';Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $badNameWheel -Context $badNameContext|Out-Null} 'wheel-metadata-name-line'}finally{Close-VllmReleaseGitSnapshot -Snapshot $badNameSnapshot}

    $badVersionRoot=Join-Path $root 'bad-version-metadata'
    $badVersionWheel=Join-Path $badVersionRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    $badVersionText="Metadata-Version: 2.1"+[char]10+"Name: vllm"+[char]10+"Version:"+[char]10+" 1.2.3"+[char]10
    Write-TestWheel -Path $badVersionWheel -MetadataText $badVersionText
    $badVersionRepo=Join-Path $badVersionRoot 'repo';$badVersionCommit=Initialize-FixtureRepo -Root $badVersionRepo -WheelPath $badVersionWheel
    $badVersionSnapshot=Get-VllmReleaseGitSnapshot -Repository $badVersionRepo -Commit $badVersionCommit
    try{$badVersionContext=Get-VllmReleaseContext -Snapshot $badVersionSnapshot -ReleaseManifestPath 'manifests/release/release.json';Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $badVersionWheel -Context $badVersionContext|Out-Null} 'wheel-metadata-version-line'}finally{Close-VllmReleaseGitSnapshot -Snapshot $badVersionSnapshot}

    $badTagRoot=Join-Path $root 'bad-tag-metadata'
    $badTagWheel=Join-Path $badTagRoot 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    $badTagText="Wheel-Version: 1.0"+[char]10+"Generator: sm19a-test"+[char]10+"Root-Is-Purelib: false"+[char]10+"NotTag: cp313-cp313-win_amd64"+[char]10
    Write-TestWheel -Path $badTagWheel -WheelMetadataText $badTagText
    $badTagRepo=Join-Path $badTagRoot 'repo';$badTagCommit=Initialize-FixtureRepo -Root $badTagRepo -WheelPath $badTagWheel
    $badTagSnapshot=Get-VllmReleaseGitSnapshot -Repository $badTagRepo -Commit $badTagCommit
    try{$badTagContext=Get-VllmReleaseContext -Snapshot $badTagSnapshot -ReleaseManifestPath 'manifests/release/release.json';Test-ExpectedFailure {Assert-VllmReleaseWheel -WheelPath $badTagWheel -Context $badTagContext|Out-Null} 'wheel-tag-substring'}finally{Close-VllmReleaseGitSnapshot -Snapshot $badTagSnapshot}
    Test-ExpectedFailure { Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $out1 | Out-Null } 'nonempty-output-refusal'
    $concurrentOut=Join-Path $root 'concurrent-output'
    $heldPrepareLock=Enter-VllmReleasePreparationLock -ArtifactsDirectory $concurrentOut
    $heldLockPath=[string]$heldPrepareLock.Path
    try{
        Test-ExpectedFailure {Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $concurrentOut|Out-Null} 'prepare-concurrent-lock'
        if((Test-Path -LiteralPath $concurrentOut) -and @(Get-ChildItem -LiteralPath $concurrentOut -Force).Count-ne0){throw 'Losing concurrent preparation mutated the release artifacts directory.'}
    }finally{Exit-VllmReleasePreparationLock -Lock $heldPrepareLock}
    $concurrentRetry=Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $concurrentOut
    if($concurrentRetry.bundle_sha256-ne$r1.bundle_sha256){throw 'Serialized preparation retry produced a different bundle identity.'}
    if(@(Get-ChildItem -LiteralPath $concurrentOut -Force).Count-ne4){throw 'Serialized preparation output does not contain exactly four assets.'}
    if(-not(Test-Path -LiteralPath $heldLockPath -PathType Leaf)){throw 'Release preparation coordination sidecar was not retained for safe reuse.'}
    Write-Host 'RELEASE_PREPARE_SERIALIZATION_OK'
    $faultOut=Join-Path $root 'fault-output'
    Test-ExpectedFailure {Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $faultOut -FaultPoint DuringWheelCopy|Out-Null} 'prepare-fault-during-wheel'
    if(@(Get-ChildItem -LiteralPath $faultOut -Force).Count-ne0){throw 'DuringWheelCopy failure left a partial wheel in release artifacts.'}
    Test-ExpectedFailure {Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $faultOut -FaultPoint AfterWheelCopy|Out-Null} 'prepare-fault-after-wheel'
    if(@(Get-ChildItem -LiteralPath $faultOut -Force).Count-ne0){throw 'AfterWheelCopy failure left partial release artifacts.'}
    Test-ExpectedFailure {Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $faultOut -FaultPoint AfterBundle|Out-Null} 'prepare-fault-after-bundle'
    if(@(Get-ChildItem -LiteralPath $faultOut -Force).Count-ne0){throw 'AfterBundle failure left partial release artifacts.'}
    $faultRetry=Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $faultOut
    if($faultRetry.bundle_sha256-ne$r1.bundle_sha256){throw 'Retry after injected preparation failure produced a different bundle identity.'}
    Remove-Item -LiteralPath $faultOut -Recurse -Force
    Write-Host 'RELEASE_PREPARE_FAILURE_CLEANUP_OK'

    [IO.File]::WriteAllText((Join-Path $fixture 'payload\a.txt'),"worktree drift`n",[Text.UTF8Encoding]::new($false))
    $out3=Join-Path $root 'out3'
    $r3=Write-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheelPath -ArtifactsDirectory $out3
    if($r3.bundle_sha256-ne$r1.bundle_sha256){throw 'Worktree drift changed a Git-object release bundle.'}
    Write-Host 'RELEASE_GIT_OBJECT_SOURCE_OK'

    $verified=Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $out1
    if($verified.bundle_sha256-ne$r1.bundle_sha256){throw 'Offline verifier returned a different bundle identity.'}
    Write-Host 'RELEASE_OFFLINE_VERIFY_OK'

    $tamperWheel=Join-Path $root 'tamper-wheel'
    Copy-Item -LiteralPath $out1 -Destination $tamperWheel -Recurse
    [IO.File]::AppendAllText((Join-Path $tamperWheel 'vllm-1.2.3-cp313-cp313-win_amd64.whl'),'x',[Text.Encoding]::ASCII)
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperWheel|Out-Null} 'wheel-tamper'

    $tamperIndex=Join-Path $root 'tamper-index'
    Copy-Item -LiteralPath $out1 -Destination $tamperIndex -Recurse
    $indexPath=Join-Path $tamperIndex 'release-index.json'
    $idx=Get-Content $indexPath -Raw|ConvertFrom-Json
    $idx.project_commit=('f'*40)
    [IO.File]::WriteAllText($indexPath,($idx|ConvertTo-Json -Depth 12 -Compress)+[char]10,[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperIndex|Out-Null} 'index-tamper'
    $caseIndex=Join-Path $root 'case-index'
    Copy-Item -LiteralPath $out1 -Destination $caseIndex -Recurse
    $caseIndexPath=Join-Path $caseIndex 'release-index.json'
    $caseIndexValue=Get-Content $caseIndexPath -Raw|ConvertFrom-Json
    $caseIndexValue.platform=([string]$caseIndexValue.platform).ToUpperInvariant()
    Write-VllmReleaseCanonicalJson -Value $caseIndexValue -Path $caseIndexPath
    Write-TestArtifactChecksums -ArtifactsDirectory $caseIndex
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $caseIndex|Out-Null} 'index-identity-case'

    $noncanonicalIndex=Join-Path $root 'noncanonical-index'
    Copy-Item -LiteralPath $out1 -Destination $noncanonicalIndex -Recurse
    $noncanonicalIndexPath=Join-Path $noncanonicalIndex 'release-index.json'
    $sameIndex=Get-Content $noncanonicalIndexPath -Raw|ConvertFrom-Json
    [IO.File]::WriteAllText($noncanonicalIndexPath,($sameIndex|ConvertTo-Json -Depth 12)+[char]10,[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $noncanonicalIndex|Out-Null} 'index-noncanonical-json'

    $reorderedIndex=Join-Path $root 'reordered-index'
    Copy-Item -LiteralPath $out1 -Destination $reorderedIndex -Recurse
    $reorderedIndexPath=Join-Path $reorderedIndex 'release-index.json'
    $originalIndex=Get-Content $reorderedIndexPath -Raw|ConvertFrom-Json
    $reordered=[ordered]@{}
    $names=@($originalIndex.PSObject.Properties.Name)
    $reordered[$names[1]]=$originalIndex.($names[1])
    $reordered[$names[0]]=$originalIndex.($names[0])
    foreach($name in $names[2..($names.Count-1)]){$reordered[$name]=$originalIndex.$name}
    Write-VllmReleaseCanonicalJson -Value $reordered -Path $reorderedIndexPath
    Write-TestArtifactChecksums -ArtifactsDirectory $reorderedIndex
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $reorderedIndex|Out-Null} 'index-property-order'
    $bomIndex=Join-Path $root 'bom-index'
    Copy-Item -LiteralPath $out1 -Destination $bomIndex -Recurse
    $bomIndexPath=Join-Path $bomIndex 'release-index.json'
    $indexBytes=[IO.File]::ReadAllBytes($bomIndexPath)
    $bomBytes=New-Object byte[] ($indexBytes.Length+3)
    $bomBytes[0]=0xEF;$bomBytes[1]=0xBB;$bomBytes[2]=0xBF
    [Array]::Copy($indexBytes,0,$bomBytes,3,$indexBytes.Length)
    [IO.File]::WriteAllBytes($bomIndexPath,$bomBytes)
    Write-TestArtifactChecksums -ArtifactsDirectory $bomIndex
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $bomIndex|Out-Null} 'index-bom'

    $tamperSums=Join-Path $root 'tamper-sums'
    Copy-Item -LiteralPath $out1 -Destination $tamperSums -Recurse
    [IO.File]::AppendAllText((Join-Path $tamperSums 'SHA256SUMS'),"BAD`n",[Text.Encoding]::ASCII)
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperSums|Out-Null} 'checksums-tamper'

    $reorderedSums=Join-Path $root 'reordered-sums'
    Copy-Item -LiteralPath $out1 -Destination $reorderedSums -Recurse
    $sumPath=Join-Path $reorderedSums 'SHA256SUMS'
    $sumLines=@([IO.File]::ReadAllLines($sumPath,[Text.Encoding]::UTF8))
    [Array]::Reverse($sumLines)
    [IO.File]::WriteAllText($sumPath,($sumLines -join [char]10)+[char]10,[Text.UTF8Encoding]::new($false))
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $reorderedSums|Out-Null} 'checksums-noncanonical-order'
    $bomSums=Join-Path $root 'bom-sums'
    Copy-Item -LiteralPath $out1 -Destination $bomSums -Recurse
    $bomSumsPath=Join-Path $bomSums 'SHA256SUMS'
    $sumBytes=[IO.File]::ReadAllBytes($bomSumsPath)
    $sumBomBytes=New-Object byte[] ($sumBytes.Length+3)
    $sumBomBytes[0]=0xEF;$sumBomBytes[1]=0xBB;$sumBomBytes[2]=0xBF
    [Array]::Copy($sumBytes,0,$sumBomBytes,3,$sumBytes.Length)
    [IO.File]::WriteAllBytes($bomSumsPath,$sumBomBytes)
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $bomSums|Out-Null} 'checksums-bom'

    $extraAsset=Join-Path $root 'extra-asset'
    Copy-Item -LiteralPath $out1 -Destination $extraAsset -Recurse
    [IO.File]::WriteAllText((Join-Path $extraAsset 'unexpected.txt'),'x',[Text.Encoding]::ASCII)
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $extraAsset|Out-Null} 'unexpected-fifth-asset'

    $tamperZip=Join-Path $root 'tamper-zip'
    Copy-Item -LiteralPath $out1 -Destination $tamperZip -Recurse
    $zipPath=Join-Path $tamperZip 'vllm-windows-native-test-release.zip'
    $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Update)
    try{$e=$zip.CreateEntry('extra.txt',[IO.Compression.CompressionLevel]::NoCompression);$e.LastWriteTime=$script:VllmReleaseZipTimestamp;$e.ExternalAttributes=0;$w=New-Object IO.StreamWriter($e.Open());try{$w.Write('extra')}finally{$w.Dispose()}}finally{$zip.Dispose()}
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperZip|Out-Null} 'zip-extra-member'

    $tamperMissing=Join-Path $root 'tamper-missing'
    Copy-Item -LiteralPath $out1 -Destination $tamperMissing -Recurse
    $missingZip=Join-Path $tamperMissing 'vllm-windows-native-test-release.zip'
    $zip=[IO.Compression.ZipFile]::Open($missingZip,[IO.Compression.ZipArchiveMode]::Update)
    try{$zip.Entries[0].Delete()}finally{$zip.Dispose()}
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperMissing|Out-Null} 'zip-missing-member'

    $tamperMethod=Join-Path $root 'tamper-method'
    Copy-Item -LiteralPath $out1 -Destination $tamperMethod -Recurse
    $methodZip=Join-Path $tamperMethod 'vllm-windows-native-test-release.zip'
    $zipBytes=[IO.File]::ReadAllBytes($methodZip)
    $central=-1
    for($i=0;$i-le$zipBytes.Length-4;$i++){if($zipBytes[$i]-eq0x50-and$zipBytes[$i+1]-eq0x4B-and$zipBytes[$i+2]-eq0x01-and$zipBytes[$i+3]-eq0x02){$central=$i;break}}
    if($central-lt0){throw 'Synthetic ZIP central directory not found.'}
    $zipBytes[$central+10]=8;$zipBytes[$central+11]=0
    [IO.File]::WriteAllBytes($methodZip,$zipBytes)
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperMethod|Out-Null} 'zip-non-store-method'

    $tamperLocalName=Join-Path $root 'tamper-local-name'
    Copy-Item -LiteralPath $out1 -Destination $tamperLocalName -Recurse
    $localNameZip=Join-Path $tamperLocalName 'vllm-windows-native-test-release.zip'
    $localBytes=[IO.File]::ReadAllBytes($localNameZip)
    if([BitConverter]::ToUInt32($localBytes,0)-ne[uint32]0x04034b50){throw 'Synthetic ZIP does not start with a local header.'}
    $localBytes[30]=[byte]([int]$localBytes[30]+1)
    [IO.File]::WriteAllBytes($localNameZip,$localBytes)
    $localIndexPath=Join-Path $tamperLocalName 'release-index.json'
    $localIndex=Get-Content $localIndexPath -Raw|ConvertFrom-Json
    $localBundleIdentity=Get-VllmReleaseFileIdentity -Path $localNameZip
    $localIndex.bundle.size_bytes=[int64]$localBundleIdentity.Size
    $localIndex.bundle.sha256=[string]$localBundleIdentity.Sha256
    Write-VllmReleaseCanonicalJson -Value $localIndex -Path $localIndexPath
    Write-TestArtifactChecksums -ArtifactsDirectory $tamperLocalName
    Test-ExpectedFailure {Assert-VllmOfflineRelease -Repository $fixture -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -ArtifactsDirectory $tamperLocalName|Out-Null} 'zip-local-header-name'

    & git -C $fixture checkout -- .
    [IO.File]::WriteAllText((Join-Path $fixture 'payload\a.txt'),"committed drift`n",[Text.UTF8Encoding]::new($false))
    & git -C $fixture add payload/a.txt
    $env:GIT_AUTHOR_DATE='2026-01-02T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-02T00:00:00Z'
    & git -C $fixture commit -m 'drift' | Out-Null
    $env:GIT_AUTHOR_DATE=$null;$env:GIT_COMMITTER_DATE=$null
    $driftCommit=Invoke-Git -Repository $fixture -Arguments @('rev-parse','HEAD') -Capture
    Test-ExpectedFailure {$s=Get-VllmReleaseGitSnapshot -Repository $fixture -Commit $driftCommit;try{Get-VllmReleaseContext -Snapshot $s -ReleaseManifestPath 'manifests/release/release.json'|Out-Null}finally{Close-VllmReleaseGitSnapshot -Snapshot $s}} 'manifest-blob-drift'

    & git -C $fixture checkout $commit -- .
    $relPath=Join-Path $fixture 'manifests\release\release.json'
    $rel=Get-Content $relPath -Raw|ConvertFrom-Json
    $rel.files[0].path='../escape'
    [IO.File]::WriteAllText($relPath,($rel|ConvertTo-Json -Depth 12 -Compress)+[char]10,[Text.UTF8Encoding]::new($false))
    & git -C $fixture add .
    $env:GIT_AUTHOR_DATE='2026-01-03T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-03T00:00:00Z'
    & git -C $fixture commit -m 'unsafe' | Out-Null
    $env:GIT_AUTHOR_DATE=$null;$env:GIT_COMMITTER_DATE=$null
    $unsafeCommit=Invoke-Git -Repository $fixture -Arguments @('rev-parse','HEAD') -Capture
    Test-ExpectedFailure {$s=Get-VllmReleaseGitSnapshot -Repository $fixture -Commit $unsafeCommit;try{Get-VllmReleaseContext -Snapshot $s -ReleaseManifestPath 'manifests/release/release.json'|Out-Null}finally{Close-VllmReleaseGitSnapshot -Snapshot $s}} 'unsafe-release-path'

    & git -C $fixture checkout $commit -- .
    $rel=Get-Content $relPath -Raw|ConvertFrom-Json
    $rel.files[1].path=([string]$rel.files[0].path).ToUpperInvariant()
    [IO.File]::WriteAllText($relPath,($rel|ConvertTo-Json -Depth 12 -Compress)+[char]10,[Text.UTF8Encoding]::new($false))
    & git -C $fixture add .
    $env:GIT_AUTHOR_DATE='2026-01-04T00:00:00Z';$env:GIT_COMMITTER_DATE='2026-01-04T00:00:00Z'
    & git -C $fixture commit -m 'collision' | Out-Null
    $env:GIT_AUTHOR_DATE=$null;$env:GIT_COMMITTER_DATE=$null
    $collisionCommit=Invoke-Git -Repository $fixture -Arguments @('rev-parse','HEAD') -Capture
    Test-ExpectedFailure {$s=Get-VllmReleaseGitSnapshot -Repository $fixture -Commit $collisionCommit;try{Get-VllmReleaseContext -Snapshot $s -ReleaseManifestPath 'manifests/release/release.json'|Out-Null}finally{Close-VllmReleaseGitSnapshot -Snapshot $s}} 'case-colliding-release-path'

    $summary=@(
        'commit='+$commit
        'wheel='+$r1.wheel_sha256
        'bundle='+$r1.bundle_sha256
        'index='+$r1.index_sha256
        'checksums='+$r1.checksums_sha256
    ) -join [char]10
    $summary += [char]10
    if(-not[string]::IsNullOrWhiteSpace($SummaryPath)){[IO.File]::WriteAllText([IO.Path]::GetFullPath($SummaryPath),$summary,[Text.UTF8Encoding]::new($false))}
    Write-Host 'RELEASE_BUNDLE_REGRESSION_OK'
    Write-Output $summary
} finally {
    $env:GIT_AUTHOR_DATE=$null
    $env:GIT_COMMITTER_DATE=$null
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
