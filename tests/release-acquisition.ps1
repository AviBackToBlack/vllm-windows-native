Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
. (Join-Path $repoRoot 'scripts\release-bundle.ps1')
. (Join-Path $repoRoot 'scripts\release-verification.ps1')
. (Join-Path $repoRoot 'scripts\release-acquisition.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $message=$null
    try{& $Action}catch{$message=$_.Exception.Message}
    if($null-eq$message){throw "Expected failure containing: $Contains"}
    if($message.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase)-lt0){throw "Unexpected failure: $message"}
}

function Write-TestBytes {
    param([string]$Path,[string]$Text)
    $parent=Split-Path -Parent $Path
    if($parent){[void][IO.Directory]::CreateDirectory($parent)}
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Write-TestWheel {
    param([string]$Path)
    $source=$Path+'.source'
    [void][IO.Directory]::CreateDirectory($source)
    try{
        $entries=[ordered]@{
            'vllm/__init__.py'="__version__ = '1.2.3'"+[char]10
            'vllm/_test.pyd'='synthetic-native-bytes'
            'vllm-1.2.3.dist-info/METADATA'=("Metadata-Version: 2.1"+[char]10+"Name: vllm"+[char]10+"Version: 1.2.3"+[char]10)
            'vllm-1.2.3.dist-info/WHEEL'=("Wheel-Version: 1.0"+[char]10+"Generator: sm20-test"+[char]10+"Root-Is-Purelib: false"+[char]10+"Tag: cp313-cp313-win_amd64"+[char]10)
        }
        $members=New-Object System.Collections.Generic.List[object]
        foreach($name in (Get-VllmReleaseOrdinalStrings -Values @($entries.Keys))){
            $file=Join-Path $source $name.Replace('/','\')
            Write-TestBytes -Path $file -Text ([string]$entries[$name])
            $id=Get-VllmReleaseFileIdentity -Path $file
            $members.Add([pscustomobject][ordered]@{RelativePath=$name;Path=$file;Size=[int64]$id.Size;Sha256=[string]$id.Sha256})
        }
        Write-VllmReleaseStoredZip -Context ([pscustomobject]@{Members=$members.ToArray()}) -Path $Path
    }finally{
        Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-FixtureRepo {
    param([string]$Root,[string]$WheelPath)
    [void][IO.Directory]::CreateDirectory($Root)
    & git -C $Root init --initial-branch=main | Out-Null
    if($LASTEXITCODE-ne0){throw 'fixture git init failed'}
    & git -C $Root config user.name 'SM20 Fixture'
    & git -C $Root config user.email 'sm20@example.invalid'
    & git -C $Root config core.autocrlf false
    Write-TestBytes -Path (Join-Path $Root 'payload\a.txt') -Text ('alpha'+[char]10)
    Write-TestBytes -Path (Join-Path $Root 'payload\B.txt') -Text ('bravo'+[char]10)
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
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $runtimePath))
    Write-VllmReleaseCanonicalJson -Value $runtime -Path $runtimePath
    $files=New-Object System.Collections.Generic.List[object]
    foreach($relative in @('manifests/runtime/runtime.json','payload/B.txt','payload/a.txt')){
        $path=Join-Path $Root $relative.Replace('/','\')
        $id=Get-VllmReleaseFileIdentity -Path $path
        $files.Add([ordered]@{path=$relative;size_bytes=[int64]$id.Size;sha256=[string]$id.Sha256})
    }
    $release=[ordered]@{
        schema_version=1
        component='runtime-release'
        release='test-release'
        platform='windows-x86_64'
        self_path='manifests/release/release.json'
        upstream=[ordered]@{repository='https://github.com/example/upstream.git';tag='v1.2.3';commit='1111111111111111111111111111111111111111'}
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
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $releasePath))
    Write-VllmReleaseCanonicalJson -Value $release -Path $releasePath
    & git -C $Root add .
    & git -C $Root -c commit.gpgsign=false commit -q -m fixture
    if($LASTEXITCODE-ne0){throw 'fixture git commit failed'}
    (& git -C $Root rev-parse HEAD).Trim()
}

function Get-FixtureSshKey {
    param([Parameter(Mandatory)][string]$Path)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName='ssh-keygen'
    $psi.Arguments='-q -t ed25519 -N "" -f "'+$Path+'"'
    $psi.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    if($process.ExitCode-ne0){throw "ssh-keygen fixture creation failed with exit $($process.ExitCode)."}
}

function Get-FixtureAttestationJson {
    param([string]$TagObject,[System.Collections.IDictionary]$Assets,[switch]$BadDigest)
    $subjects=New-Object System.Collections.Generic.List[object]
    $tag='release/test-release'
    $repo='AviBackToBlack/vllm-windows-native'
    $encoded=[Uri]::EscapeDataString($tag)
    $subjects.Add([ordered]@{uri="pkg:github/$repo@$encoded";digest=[ordered]@{sha1=$TagObject}})
    $index=0
    foreach($name in $Assets.Keys){
        $digest=[string]$Assets[$name]
        if($BadDigest-and$index-eq0){$digest='0'*64}
        $subjects.Add([ordered]@{name=[string]$name;digest=[ordered]@{sha256=$digest}})
        $index++
    }
    [ordered]@{verificationResult=[ordered]@{statement=[ordered]@{
        _type='https://in-toto.io/Statement/v1'
        subject=$subjects.ToArray()
        predicateType='https://in-toto.io/attestation/release/v0.2'
        predicate=[ordered]@{repository=$repo;tag=$tag;purl="pkg:github/$repo@$encoded"}
    }}}|ConvertTo-Json -Depth 10 -Compress
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm20-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    Assert-Fails { Assert-VllmAcquisitionRepository -RepositorySlug 'Other/repo' } 'Unsupported acquisition repository'
    Assert-Fails { Assert-VllmAcquisitionTag -Tag 'latest' } 'exact release'

    $probeConfig=Join-Path $root 'probe-config'
    [void][IO.Directory]::CreateDirectory($probeConfig)
    $probe=Join-Path $root 'gh-env-probe.cmd'
    [IO.File]::WriteAllLines($probe,@('@echo off','echo %GH_HOST%^|%GH_PROMPT_DISABLED%^|%GITHUB_TOKEN%^|%GH_FOO%'),[Text.Encoding]::ASCII)
    $oldHost=$env:GH_HOST;$oldGithubToken=$env:GITHUB_TOKEN;$oldFoo=$env:GH_FOO
    try{
        $env:GH_HOST='evil.invalid';$env:GITHUB_TOKEN='evil-token';$env:GH_FOO='evil-value'
        $probeOut=Invoke-VllmAcquisitionGhCommand -Arguments @('ignored') -FailureLabel 'gh isolation probe' -GhConfigDirectory $probeConfig -GitHubToken 'fixture-token' -Executable $probe
        if(-not$probeOut.Equals('github.com|1||',[StringComparison]::Ordinal)){throw "GitHub CLI isolation probe leaked ambient state: $probeOut"}
        if($env:GH_HOST-ne'evil.invalid'-or$env:GITHUB_TOKEN-ne'evil-token'-or$env:GH_FOO-ne'evil-value'){throw 'GitHub CLI isolation did not restore caller environment.'}
    }finally{
        if($null-eq$oldHost){Remove-Item Env:GH_HOST -ErrorAction SilentlyContinue}else{$env:GH_HOST=$oldHost}
        if($null-eq$oldGithubToken){Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue}else{$env:GITHUB_TOKEN=$oldGithubToken}
        if($null-eq$oldFoo){Remove-Item Env:GH_FOO -ErrorAction SilentlyContinue}else{$env:GH_FOO=$oldFoo}
    }
    Write-Host 'ACQUISITION_GH_ISOLATION_OK'

    $gitIsolationSaved=[ordered]@{}
    foreach($name in @('GIT_DIR','GIT_OBJECT_DIRECTORY','GIT_SSL_NO_VERIFY','GIT_ASKPASS','SSH_ASKPASS','GCM_INTERACTIVE')){
        $item=Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        if($null-ne$item){$gitIsolationSaved[$name]=$item.Value}
    }
    try{
        $env:GIT_DIR='C:\ambient-evil-git-dir'
        $env:GIT_OBJECT_DIRECTORY='C:\ambient-evil-object-dir'
        $env:GIT_SSL_NO_VERIFY='1'
        $env:GIT_ASKPASS='C:\ambient-evil-askpass.exe'
        $env:SSH_ASKPASS='C:\ambient-evil-ssh-askpass.exe'
        $env:GCM_INTERACTIVE='Always'
        Invoke-VllmAcquisitionGitIsolation -Action {
            foreach($name in @('GIT_DIR','GIT_OBJECT_DIRECTORY','GIT_SSL_NO_VERIFY','GIT_ASKPASS','SSH_ASKPASS')){
                if(Test-Path -LiteralPath "Env:$name"){throw "Acquisition Git isolation leaked environment variable: $name"}
            }
            if($env:GIT_CONFIG_NOSYSTEM-ne'1'-or$env:GIT_CONFIG_GLOBAL-ne'NUL'-or$env:GIT_TERMINAL_PROMPT-ne'0'-or$env:GIT_NO_REPLACE_OBJECTS-ne'1'-or$env:GCM_INTERACTIVE-ne'Never'){
                throw 'Acquisition Git isolation did not install the required deterministic environment.'
            }
        }
        if($env:GIT_DIR-ne'C:\ambient-evil-git-dir'-or$env:GIT_OBJECT_DIRECTORY-ne'C:\ambient-evil-object-dir'-or$env:GIT_SSL_NO_VERIFY-ne'1'-or$env:GIT_ASKPASS-ne'C:\ambient-evil-askpass.exe'-or$env:SSH_ASKPASS-ne'C:\ambient-evil-ssh-askpass.exe'-or$env:GCM_INTERACTIVE-ne'Always'){
            throw 'Acquisition Git isolation did not restore caller environment.'
        }
    }finally{
        foreach($name in @('GIT_DIR','GIT_OBJECT_DIRECTORY','GIT_SSL_NO_VERIFY','GIT_ASKPASS','SSH_ASKPASS','GCM_INTERACTIVE')){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
        foreach($name in $gitIsolationSaved.Keys){Set-Item -LiteralPath "Env:$name" -Value $gitIsolationSaved[$name]}
    }
    Write-Host 'ACQUISITION_GIT_ISOLATION_SCOPE_OK'

    $wheel=Join-Path $root 'vllm-1.2.3-cp313-cp313-win_amd64.whl'
    Write-TestWheel -Path $wheel
    $fixtureRepo=Join-Path $root 'source-repo'
    $commit=Initialize-FixtureRepo -Root $fixtureRepo -WheelPath $wheel

    $key=Join-Path $root 'fixture-key'
    Get-FixtureSshKey -Path $key
    $pub=([IO.File]::ReadAllText($key+'.pub')).Trim() -split ' '
    $allowed=Join-Path $root 'allowed_signers'
    [IO.File]::WriteAllText($allowed,"fixture-release $($pub[0]) $($pub[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    $fingerprint=Get-VllmReleaseSigningKeyFingerprint -KeyType $pub[0] -KeyData $pub[1]

    $bootstrapCache=Join-Path $root 'credential-bootstrap-failure'
    $oldBootstrapToken=$env:GH_TOKEN
    try{
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        Assert-Fails {
            Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $bootstrapCache -GhExecutable 'definitely-not-a-vllm-gh-command' -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint
        } 'bootstrap executable not found'
    }finally{
        if($null-eq$oldBootstrapToken){Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue}else{$env:GH_TOKEN=$oldBootstrapToken}
    }
    $bootstrapStaging=Join-Path $bootstrapCache '.staging'
    if((Test-Path -LiteralPath $bootstrapStaging)-and@(Get-ChildItem -LiteralPath $bootstrapStaging -Force -Directory).Count-ne0){throw 'Credential bootstrap failure leaked an acquisition generation.'}
    Write-Host 'ACQUISITION_CREDENTIAL_BOOTSTRAP_CLEAN_OK'

    & git -C $fixtureRepo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a release/test-release -m fixture $commit
    if($LASTEXITCODE-ne0){throw 'fixture signed tag creation failed'}
    $script:RemoteTagObject=(& git -C $fixtureRepo rev-parse refs/tags/release/test-release).Trim().ToLowerInvariant()

    $published=Join-Path $root 'published'
    $null=Write-VllmOfflineRelease -Repository $fixtureRepo -ProjectCommit $commit -ReleaseManifestPath 'manifests/release/release.json' -WheelPath $wheel -ArtifactsDirectory $published
    $assetMap=[ordered]@{}
    $script:RemoteAssets=New-Object System.Collections.Generic.List[object]
    foreach($file in @(Get-ChildItem -LiteralPath $published -File|Sort-Object Name)){
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $assetMap[$file.Name]=$hash
        $script:RemoteAssets.Add([ordered]@{name=$file.Name;size=[int64]$file.Length;digest=('sha256:'+$hash.ToLowerInvariant());state='uploaded'})
    }
    $script:PublishedDirectory=$published
    $script:DownloadCount=0
    $script:FakeBadAttestation=$false
    $script:FakeRepositoryId=[int64]$script:VllmAcquisitionRepositoryId
    $script:FakeTagType='tag'
    $script:FailDownloadName=''
    $script:TamperDownloadName=''

    $fakeGh={
        param($Arguments,$FailureLabel)
        $null=$FailureLabel
        $commandArguments=[string[]]$Arguments
        if($commandArguments[0]-eq'api'){
            $endpoint=[string]$commandArguments[$commandArguments.Length-1]
            if($endpoint-eq'repos/AviBackToBlack/vllm-windows-native'){
                return ([ordered]@{id=$script:FakeRepositoryId;node_id=$script:VllmAcquisitionRepositoryNodeId;full_name=$script:VllmAcquisitionRepository}|ConvertTo-Json -Compress)
            }
            if($endpoint.Contains('/git/ref/tags/')){
                return ([ordered]@{object=[ordered]@{type=$script:FakeTagType;sha=$script:RemoteTagObject}}|ConvertTo-Json -Depth 4 -Compress)
            }
            if($endpoint.Contains('/releases/tags/')){
                return ([ordered]@{tag_name='release/test-release';draft=$false;immutable=$true;assets=$script:RemoteAssets.ToArray()}|ConvertTo-Json -Depth 6 -Compress)
            }
            throw "Unhandled fake gh api endpoint: $endpoint"
        }
        if($commandArguments[0]-eq'release'-and$commandArguments[1]-eq'download'){
            $patternIndex=[Array]::IndexOf($commandArguments,'--pattern')
            $dirIndex=[Array]::IndexOf($commandArguments,'--dir')
            $name=$commandArguments[$patternIndex+1];$dir=$commandArguments[$dirIndex+1]
            if(-not[string]::IsNullOrWhiteSpace($script:FailDownloadName)-and$name.Equals($script:FailDownloadName,[StringComparison]::Ordinal)){throw "Injected download failure: $name"}
            $destination=Join-Path $dir $name
            Copy-Item -LiteralPath (Join-Path $script:PublishedDirectory $name) -Destination $destination
            if(-not[string]::IsNullOrWhiteSpace($script:TamperDownloadName)-and$name.Equals($script:TamperDownloadName,[StringComparison]::Ordinal)){[IO.File]::AppendAllText($destination,'tamper',[Text.UTF8Encoding]::new($false))}
            $script:DownloadCount++
            return ''
        }
        if($commandArguments[0]-eq'release'-and($commandArguments[1]-eq'verify'-or$commandArguments[1]-eq'verify-asset')){
            return Get-FixtureAttestationJson -TagObject $script:RemoteTagObject -Assets $assetMap -BadDigest:$script:FakeBadAttestation
        }
        throw "Unhandled fake gh command: $($commandArguments -join ' ')"
    }

    $originalSignedTagObject=$script:RemoteTagObject

    $unsignedRepo=Join-Path $root 'unsigned-tag-repo'
    & git clone -q $fixtureRepo $unsignedRepo
    if($LASTEXITCODE-ne0){throw 'unsigned-tag fixture clone failed'}
    & git -C $unsignedRepo config user.name 'SM20 Fixture'
    & git -C $unsignedRepo config user.email 'sm20@example.invalid'
    & git -C $unsignedRepo tag -d release/test-release | Out-Null
    & git -C $unsignedRepo -c tag.gpgSign=false tag -a release/test-release -m unsigned $commit
    if($LASTEXITCODE-ne0){throw 'unsigned annotated tag fixture creation failed'}
    $script:RemoteTagObject=(& git -C $unsignedRepo rev-parse refs/tags/release/test-release).Trim().ToLowerInvariant()
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot (Join-Path $root 'unsigned-tag-cache') -GitHubToken 'fixture-token' -GitSourceUrl $unsignedRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'must contain an SSH signature'

    $wrongKey=Join-Path $root 'wrong-signing-key'
    Get-FixtureSshKey -Path $wrongKey
    $badSignerRepo=Join-Path $root 'bad-signer-repo'
    & git clone -q $fixtureRepo $badSignerRepo
    if($LASTEXITCODE-ne0){throw 'bad-signer fixture clone failed'}
    & git -C $badSignerRepo config user.name 'SM20 Fixture'
    & git -C $badSignerRepo config user.email 'sm20@example.invalid'
    & git -C $badSignerRepo tag -d release/test-release | Out-Null
    & git -C $badSignerRepo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$wrongKey" tag -s -a release/test-release -m bad-signer $commit
    if($LASTEXITCODE-ne0){throw 'bad-signer annotated tag fixture creation failed'}
    $script:RemoteTagObject=(& git -C $badSignerRepo rev-parse refs/tags/release/test-release).Trim().ToLowerInvariant()
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot (Join-Path $root 'bad-signer-cache') -GitHubToken 'fixture-token' -GitSourceUrl $badSignerRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'signature verification failed'
    Write-Host 'ACQUISITION_TAG_SIGNATURE_FAIL_CLOSED_OK'

    $mismatchRepo=Join-Path $root 'project-commit-mismatch-repo'
    & git clone -q $fixtureRepo $mismatchRepo
    if($LASTEXITCODE-ne0){throw 'project-commit mismatch fixture clone failed'}
    & git -C $mismatchRepo config user.name 'SM20 Fixture'
    & git -C $mismatchRepo config user.email 'sm20@example.invalid'
    Write-TestBytes -Path (Join-Path $mismatchRepo 'unowned-extra.txt') -Text 'different project commit'
    & git -C $mismatchRepo add unowned-extra.txt
    & git -C $mismatchRepo -c commit.gpgsign=false commit -q -m 'different project commit'
    $mismatchCommit=(& git -C $mismatchRepo rev-parse HEAD).Trim()
    & git -C $mismatchRepo tag -d release/test-release | Out-Null
    & git -C $mismatchRepo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a release/test-release -m project-mismatch $mismatchCommit
    if($LASTEXITCODE-ne0){throw 'project-commit mismatch tag creation failed'}
    $script:RemoteTagObject=(& git -C $mismatchRepo rev-parse refs/tags/release/test-release).Trim().ToLowerInvariant()
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot (Join-Path $root 'project-commit-mismatch-cache') -GitHubToken 'fixture-token' -GitSourceUrl $mismatchRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'release-index.json'
    Write-Host 'ACQUISITION_PROJECT_COMMIT_MISMATCH_FAIL_CLOSED_OK'

    $script:RemoteTagObject=$originalSignedTagObject

    $context=Resolve-VllmAcquisitionReleaseContext -Repository $fixtureRepo -ProjectCommit $commit -Tag 'release/test-release'
    Assert-Fails { Resolve-VllmAcquisitionReleaseContext -Repository $fixtureRepo -ProjectCommit $commit -Tag 'release/no-such-release' } 'exactly one matching release manifest'

    $multiRepo=Join-Path $root 'multi-manifest-repo'
    & git clone -q $fixtureRepo $multiRepo
    if($LASTEXITCODE-ne0){throw 'multi-manifest fixture clone failed'}
    & git -C $multiRepo config user.name 'SM20 Fixture'
    & git -C $multiRepo config user.email 'sm20@example.invalid'
    & git -C $multiRepo config core.autocrlf false
    $second=(Get-Content -LiteralPath (Join-Path $multiRepo 'manifests\release\release.json') -Raw|ConvertFrom-Json)
    $second.self_path='manifests/release/release-two.json'
    Write-VllmReleaseCanonicalJson -Value $second -Path (Join-Path $multiRepo 'manifests\release\release-two.json')
    & git -C $multiRepo add manifests/release/release-two.json
    & git -C $multiRepo -c commit.gpgsign=false commit -q -m 'second release manifest'
    $multiCommit=(& git -C $multiRepo rev-parse HEAD).Trim()
    Assert-Fails { Resolve-VllmAcquisitionReleaseContext -Repository $multiRepo -ProjectCommit $multiCommit -Tag 'release/test-release' } 'found 2'
    Write-Host 'ACQUISITION_MANIFEST_SELECTION_FAIL_CLOSED_OK'

    $originalRemoteAssets=@($script:RemoteAssets.ToArray())
    $script:RemoteAssets.Add([ordered]@{name='extra.bin';size=1;digest=('sha256:'+('A'*64));state='uploaded'})
    Assert-Fails {
        Get-VllmAcquisitionRemoteRelease -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -ReleaseContext $context -GhConfigDirectory (Join-Path $root 'asset-probe-extra') -GitHubToken 'fixture-token' -GhCommandInvoker $fakeGh
    } 'exactly four assets'
    $script:RemoteAssets=New-Object System.Collections.Generic.List[object]
    foreach($asset in $originalRemoteAssets|Select-Object -First 3){$script:RemoteAssets.Add($asset)}
    Assert-Fails {
        Get-VllmAcquisitionRemoteRelease -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -ReleaseContext $context -GhConfigDirectory (Join-Path $root 'asset-probe-missing') -GitHubToken 'fixture-token' -GhCommandInvoker $fakeGh
    } 'exactly four assets'
    $script:RemoteAssets=New-Object System.Collections.Generic.List[object]
    foreach($asset in $originalRemoteAssets){$script:RemoteAssets.Add($asset)}

    $caseCollision=New-Object System.Collections.Generic.List[object]
    foreach($asset in $originalRemoteAssets){
        $caseCollision.Add([ordered]@{name=[string]$asset.name;size=[int64]$asset.size;digest=[string]$asset.digest;state=[string]$asset.state})
    }
    $collisionVictim=@($caseCollision|Where-Object{([string]$_.name).Equals([string]$context.bundle_filename,[StringComparison]::Ordinal)})[0]
    $collisionVictim['name']='sha256sums'
    $script:RemoteAssets=$caseCollision
    Assert-Fails {
        Get-VllmAcquisitionRemoteRelease -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -ReleaseContext $context -GhConfigDirectory (Join-Path $root 'asset-probe-case-collision') -GitHubToken 'fixture-token' -GhCommandInvoker $fakeGh
    } 'duplicate or case-colliding asset'
    $script:RemoteAssets=New-Object System.Collections.Generic.List[object]
    foreach($asset in $originalRemoteAssets){$script:RemoteAssets.Add($asset)}
    Write-Host 'ACQUISITION_REMOTE_ASSET_SET_FAIL_CLOSED_OK'

    $partialCache=Join-Path $root 'partial-final-cache'
    $partialDestination=Join-Path (Join-Path (Join-Path $partialCache 'verified') ([string]$script:VllmAcquisitionRepositoryId)) $script:RemoteTagObject
    [void][IO.Directory]::CreateDirectory((Join-Path $partialDestination 'artifacts'))
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $partialCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'receipt is missing'
    Write-Host 'ACQUISITION_PARTIAL_FINAL_CACHE_FAIL_CLOSED_OK'

    $script:DownloadCount=0
    $cache=Join-Path $root 'cache'
    $ambientGitNames=@('GIT_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_SSL_NO_VERIFY','GIT_TEMPLATE_DIR','GIT_ASKPASS','SSH_ASKPASS','GCM_INTERACTIVE','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0')
    $ambientGitSaved=[ordered]@{}
    foreach($name in $ambientGitNames){$item=Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue;if($null-ne$item){$ambientGitSaved[$name]=$item.Value}}
    try{
        $env:GIT_DIR='C:\ambient-wrong-repository'
        $env:GIT_OBJECT_DIRECTORY='C:\ambient-wrong-objects'
        $env:GIT_ALTERNATE_OBJECT_DIRECTORIES='C:\ambient-alternate-objects'
        $env:GIT_SSL_NO_VERIFY='1'
        $env:GIT_TEMPLATE_DIR='C:\ambient-template'
        $env:GIT_ASKPASS='C:\ambient-askpass.exe'
        $env:SSH_ASKPASS='C:\ambient-ssh-askpass.exe'
        $env:GCM_INTERACTIVE='Always'
        $env:GIT_CONFIG_COUNT='1'
        $env:GIT_CONFIG_KEY_0='core.repositoryformatversion'
        $env:GIT_CONFIG_VALUE_0='999'
        $r1=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $cache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
        foreach($name in $ambientGitNames){
            $value=(Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue).Value
            $expectedValue=switch($name){
                'GIT_DIR'{'C:\ambient-wrong-repository'}
                'GIT_OBJECT_DIRECTORY'{'C:\ambient-wrong-objects'}
                'GIT_ALTERNATE_OBJECT_DIRECTORIES'{'C:\ambient-alternate-objects'}
                'GIT_SSL_NO_VERIFY'{'1'}
                'GIT_TEMPLATE_DIR'{'C:\ambient-template'}
                'GIT_ASKPASS'{'C:\ambient-askpass.exe'}
                'SSH_ASKPASS'{'C:\ambient-ssh-askpass.exe'}
                'GCM_INTERACTIVE'{'Always'}
                'GIT_CONFIG_COUNT'{'1'}
                'GIT_CONFIG_KEY_0'{'core.repositoryformatversion'}
                'GIT_CONFIG_VALUE_0'{'999'}
            }
            if($value-ne$expectedValue){throw "Acquisition did not restore ambient Git environment variable: $name"}
        }
    }finally{
        foreach($name in $ambientGitNames){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
        foreach($name in $ambientGitSaved.Keys){Set-Item -LiteralPath "Env:$name" -Value $ambientGitSaved[$name]}
    }
    Write-Host 'ACQUISITION_AMBIENT_GIT_READ_ISOLATION_OK'
    if($script:DownloadCount-ne4){throw "Initial acquisition downloaded unexpected asset count: $($script:DownloadCount)"}
    if(-not(Test-Path -LiteralPath $r1.receipt_path -PathType Leaf)-or-not(Test-Path -LiteralPath $r1.wheel_path -PathType Leaf)){throw 'Initial acquisition did not commit the verified cache entry.'}
    $receipt=Read-VllmAcquisitionReceipt -Path $r1.receipt_path
    if(-not([string]$receipt.release.tag_object).Equals($script:RemoteTagObject,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition receipt tag object mismatch.'}
    Write-Host 'ACQUISITION_EXACT_TAG_OK'

    $stale=Join-Path $cache '.staging\stale-generation'
    [void][IO.Directory]::CreateDirectory($stale)
    Write-TestBytes -Path (Join-Path $stale 'partial.bin') -Text 'partial'
    $r2=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $cache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    if($script:DownloadCount-ne4){throw 'Exact cache hit unexpectedly re-downloaded assets.'}
    if(-not$r2.cache_entry.Equals($r1.cache_entry,[StringComparison]::OrdinalIgnoreCase)){throw 'Exact cache hit returned a different entry.'}
    if(-not(Test-Path -LiteralPath $stale -PathType Container)){throw 'Acquisition incorrectly adopted or removed an unrelated stale staging generation.'}
    Write-Host 'ACQUISITION_CACHE_HIT_OK'

    $repoCache=Join-Path (Join-Path $cache 'verified') ([string]$script:VllmAcquisitionRepositoryId)
    $held=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $repoCache -Operation 'test-holder'
    try{Assert-Fails { Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $repoCache -Operation 'test-contender' } 'Another release acquisition cache commit'}finally{Exit-VllmAcquisitionCacheLock -Lock $held}
    $reclaimed=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $repoCache -Operation 'test-reclaimed'
    Exit-VllmAcquisitionCacheLock -Lock $reclaimed

    $concurrencyRoot=Join-Path $root 'concurrent-retag-cache'
    $concurrencyRepo=Assert-VllmAcquisitionDirectory -Path (Join-Path (Join-Path $concurrencyRoot 'verified') ([string]$script:VllmAcquisitionRepositoryId)) -Label 'Concurrent retag repository cache' -Create
    $oldDestination=Join-Path $concurrencyRepo $originalSignedTagObject
    $first=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $concurrencyRepo -Operation 'old-tag-scan-publish'
    try{
        $null=Assert-VllmAcquisitionNoSameTagConflict -RepositoryCacheRoot $concurrencyRepo -Tag 'release/test-release' -TagObject $originalSignedTagObject
        Assert-Fails { Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $concurrencyRepo -Operation 'new-tag-racing-scan' } 'Another release acquisition cache commit'
        Copy-Item -LiteralPath $r1.cache_entry -Destination $oldDestination -Recurse
    }finally{Exit-VllmAcquisitionCacheLock -Lock $first}
    $newTagObject='f'*40
    if($newTagObject.Equals($originalSignedTagObject,[StringComparison]::OrdinalIgnoreCase)){$newTagObject='e'*40}
    $second=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $concurrencyRepo -Operation 'new-tag-after-old-publish'
    try{
        Assert-Fails { Assert-VllmAcquisitionNoSameTagConflict -RepositoryCacheRoot $concurrencyRepo -Tag 'release/test-release' -TagObject $newTagObject } 'same tag bound to a different tag object'
    }finally{Exit-VllmAcquisitionCacheLock -Lock $second}
    Write-Host 'ACQUISITION_CONCURRENT_RETAG_SERIALIZATION_OK'
    Write-Host 'ACQUISITION_CACHE_LOCK_OK'

    $faultCache=Join-Path $root 'fault-before-cache'
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $faultCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh -FaultPoint BeforeCachePublish
    } 'FAULT_INJECTED:BeforeCachePublish'
    $faultFinal=Join-Path (Join-Path (Join-Path $faultCache 'verified') ([string]$script:VllmAcquisitionRepositoryId)) $script:RemoteTagObject
    if(Test-Path -LiteralPath $faultFinal){throw 'Pre-publish acquisition fault exposed a final cache entry.'}
    Write-Host 'ACQUISITION_PREPUBLISH_FAULT_OK'

    $afterCache=Join-Path $root 'fault-after-cache'
    $downloadsBefore=$script:DownloadCount
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $afterCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh -FaultPoint AfterCachePublish
    } 'FAULT_INJECTED:AfterCachePublish'
    $downloadsAfterFault=$script:DownloadCount
    if($downloadsAfterFault-ne($downloadsBefore+4)){throw 'After-cache fault did not complete exactly one four-asset download.'}
    $recovered=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $afterCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    if($script:DownloadCount-ne$downloadsAfterFault){throw 'Retry after post-publish interruption re-downloaded an already committed exact cache entry.'}
    if(-not(Test-Path -LiteralPath $recovered.receipt_path -PathType Leaf)){throw 'Retry after post-publish interruption did not recover the cache entry.'}
    Write-Host 'ACQUISITION_POSTPUBLISH_RECOVERY_OK'

    $interruptedDownloadCache=Join-Path $root 'interrupted-download'
    $script:FailDownloadName='release-index.json'
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $interruptedDownloadCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'Injected download failure'
    $script:FailDownloadName=''
    $interruptedFinal=Join-Path (Join-Path (Join-Path $interruptedDownloadCache 'verified') ([string]$script:VllmAcquisitionRepositoryId)) $script:RemoteTagObject
    if(Test-Path -LiteralPath $interruptedFinal){throw 'Interrupted download exposed a final cache entry.'}
    Write-Host 'ACQUISITION_INTERRUPTED_DOWNLOAD_FAIL_CLOSED_OK'

    $tamperedDownloadCache=Join-Path $root 'tampered-download'
    $script:TamperDownloadName='release-index.json'
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $tamperedDownloadCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'release-index.json'
    $script:TamperDownloadName=''
    Write-Host 'ACQUISITION_TAMPERED_DOWNLOAD_FAIL_CLOSED_OK'

    $remoteDigestCache=Join-Path $root 'remote-digest-mismatch'
    $bundleRemote=@($script:RemoteAssets|Where-Object{([string]$_.name).EndsWith('.zip',[StringComparison]::Ordinal)})[0]
    $goodBundleDigest=[string]$bundleRemote.digest
    $bundleRemote.digest='sha256:'+('B'*64)
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $remoteDigestCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'digest mismatch after download'
    $bundleRemote.digest=$goodBundleDigest
    Write-Host 'ACQUISITION_REMOTE_DIGEST_FAIL_CLOSED_OK'

    $badAttestationCache=Join-Path $root 'bad-attestation'
    $script:FakeBadAttestation=$true
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $badAttestationCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'digest mismatch'
    $script:FakeBadAttestation=$false
    $badFinal=Join-Path (Join-Path (Join-Path $badAttestationCache 'verified') ([string]$script:VllmAcquisitionRepositoryId)) $script:RemoteTagObject
    if(Test-Path -LiteralPath $badFinal){throw 'Attestation failure exposed a verified cache entry.'}
    Write-Host 'ACQUISITION_ATTESTATION_FAIL_CLOSED_OK'

    $poisonCache=Join-Path $root 'poison-cache'
    $poison=Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $poisonCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    [IO.File]::AppendAllText($poison.wheel_path,'tamper',[Text.UTF8Encoding]::new($false))
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $poisonCache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'size/SHA-256 mismatch'
    Write-Host 'ACQUISITION_POISONED_CACHE_FAIL_CLOSED_OK'

    $originalTagObject=$script:RemoteTagObject
    Write-TestBytes -Path (Join-Path $fixtureRepo 'unowned-extra.txt') -Text 'new commit'
    & git -C $fixtureRepo add unowned-extra.txt
    & git -C $fixtureRepo -c commit.gpgsign=false commit -q -m retag
    $commit2=(& git -C $fixtureRepo rev-parse HEAD).Trim()
    & git -C $fixtureRepo tag -d release/test-release | Out-Null
    & git -C $fixtureRepo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a release/test-release -m retag $commit2
    if($LASTEXITCODE-ne0){throw 'fixture retag creation failed'}
    $script:RemoteTagObject=(& git -C $fixtureRepo rev-parse refs/tags/release/test-release).Trim().ToLowerInvariant()
    if($script:RemoteTagObject.Equals($originalTagObject,[StringComparison]::OrdinalIgnoreCase)){throw 'Retag fixture did not change the annotated tag object.'}
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot $cache -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'same tag bound to a different tag object'
    Write-Host 'ACQUISITION_RETAG_CONFLICT_OK'

    $script:RemoteTagObject=$originalTagObject
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot (Join-Path $root 'tag-object-mismatch') -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'does not match authenticated GitHub tag object'
    Write-Host 'ACQUISITION_FETCHED_TAG_OBJECT_MISMATCH_FAIL_CLOSED_OK'

    $script:FakeRepositoryId=123
    Assert-Fails {
        Invoke-VllmReleaseAcquisition -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -AllowedSignersPath $allowed -CacheRoot (Join-Path $root 'wrong-repo') -GitHubToken 'fixture-token' -GitSourceUrl $fixtureRepo -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint -GhCommandInvoker $fakeGh
    } 'repository id mismatch'
    $script:FakeRepositoryId=[int64]$script:VllmAcquisitionRepositoryId

    $script:FakeTagType='commit'
    $tagProbe=Join-Path $root 'tag-probe-config'
    [void][IO.Directory]::CreateDirectory($tagProbe)
    Assert-Fails {
        Get-VllmAcquisitionRemoteTagObject -RepositorySlug $script:VllmAcquisitionRepository -Tag 'release/test-release' -GhConfigDirectory $tagProbe -GitHubToken 'fixture-token' -GhCommandInvoker $fakeGh
    } 'annotated tag object'
    $script:FakeTagType='tag'
    Write-Host 'ACQUISITION_IDENTITY_FAIL_CLOSED_OK'

    Write-Host 'RELEASE_ACQUISITION_CONTRACT_OK'
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
