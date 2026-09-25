Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-verification.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    $failed=$false
    try { & $Action }
    catch {
        $failed=$true
        if ($_.Exception.Message.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Unexpected failure: $($_.Exception.Message)" }
    }
    if(-not$failed){throw "Expected failure containing: $Contains"}
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

$productionTrust=Join-Path $PSScriptRoot '..\config\release-allowed-signers'
$policy=Assert-VllmReleaseAllowedSigners -Path $productionTrust
if(-not$policy.principal.Equals('vllm-windows-native-release',[StringComparison]::Ordinal)){throw 'Production release principal mismatch.'}
if(-not$policy.fingerprint.Equals('SHA256:ga7J6BbUAgsSVju3a6RZU4Vw4/7wvn2xL/MTLWy77ng',[StringComparison]::Ordinal)){throw 'Production release fingerprint mismatch.'}
Write-Host 'PRODUCTION_TRUST_ROOT_OK'

$root=Join-Path ([IO.Path]::GetTempPath()) ('vllm-sm19b-'+[guid]::NewGuid().ToString('N'))

[IO.Directory]::CreateDirectory($root)|Out-Null
try {
    $repo=Join-Path $root 'repo'
    [IO.Directory]::CreateDirectory($repo)|Out-Null
    & git -C $repo init -q
    & git -C $repo config user.name 'SM19B Fixture'
    & git -C $repo config user.email 'sm19b@example.invalid'
    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'one',[Text.UTF8Encoding]::new($false))
    & git -C $repo add fixture.txt
    & git -C $repo -c commit.gpgsign=false commit -q -m one
    $commit1=(& git -C $repo rev-parse HEAD).Trim()

    $key=Join-Path $root 'fixture-key'
    Get-FixtureSshKey -Path $key
    $pub=([IO.File]::ReadAllText($key+'.pub')).Trim()
    $pubFields=@($pub -split ' ')
    $allowed=Join-Path $root 'allowed_signers'
    [IO.File]::WriteAllText($allowed,"fixture-release $($pubFields[0]) $($pubFields[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    $fingerprint=Get-VllmReleaseSigningKeyFingerprint -KeyType $pubFields[0] -KeyData $pubFields[1]

    & git -C $repo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a release/fixture -m fixture $commit1
    if($LASTEXITCODE-ne0){throw 'fixture signed tag creation failed.'}
    $tagObjectId=(& git -C $repo rev-parse 'refs/tags/release/fixture').Trim()
    if($tagObjectId.Equals($commit1,[StringComparison]::OrdinalIgnoreCase)){throw 'annotated tag object must differ from its peeled commit in the fixture.'}
    $ok=Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint
    if($ok.project_commit-ne$commit1){throw 'signed tag verifier returned wrong commit.'}
    if($ok.tag_object-ne$tagObjectId){throw 'signed tag verifier returned wrong tag object.'}

    $oldCount=$env:GIT_CONFIG_COUNT
    $oldKey0=$env:GIT_CONFIG_KEY_0
    $oldValue0=$env:GIT_CONFIG_VALUE_0
    $oldGitDir=$env:GIT_DIR
    try {
        $env:GIT_CONFIG_COUNT='1'
        $env:GIT_CONFIG_KEY_0='gpg.ssh.program'
        $env:GIT_CONFIG_VALUE_0='definitely-not-a-real-ssh-program'
        $env:GIT_DIR=Join-Path $root 'ambient-not-target.git'
        $isolated=Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint
        if($isolated.tag_object-ne$tagObjectId){throw 'GIT_CONFIG isolation changed tag identity.'}
        if($env:GIT_CONFIG_COUNT-ne'1' -or $env:GIT_CONFIG_KEY_0-ne'gpg.ssh.program' -or $env:GIT_CONFIG_VALUE_0-ne'definitely-not-a-real-ssh-program'){throw 'GIT_CONFIG isolation did not restore caller environment.'}
        if(-not$env:GIT_DIR.Equals((Join-Path $root 'ambient-not-target.git'),[StringComparison]::OrdinalIgnoreCase)){throw 'GIT_DIR isolation did not restore caller environment.'}
    } finally {
        if($null-eq$oldCount){Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue}else{$env:GIT_CONFIG_COUNT=$oldCount}
        if($null-eq$oldKey0){Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue}else{$env:GIT_CONFIG_KEY_0=$oldKey0}
        if($null-eq$oldValue0){Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue}else{$env:GIT_CONFIG_VALUE_0=$oldValue0}
        if($null-eq$oldGitDir){Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue}else{$env:GIT_DIR=$oldGitDir}
    }

    $wrongPrincipal=Join-Path $root 'wrong-principal'
    [IO.File]::WriteAllText($wrongPrincipal,"wrong-release $($pubFields[0]) $($pubFields[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $wrongPrincipal -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'principal mismatch'

    $key2=Join-Path $root 'wrong-key'
    Get-FixtureSshKey -Path $key2
    $pub2=([IO.File]::ReadAllText($key2+'.pub')).Trim() -split ' '
    $wrongKey=Join-Path $root 'wrong-key-signers'
    [IO.File]::WriteAllText($wrongKey,"fixture-release $($pub2[0]) $($pub2[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $wrongKey -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'fingerprint mismatch'
    $foreignFingerprint=Get-VllmReleaseSigningKeyFingerprint -KeyType $pub2[0] -KeyData $pub2[1]
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $wrongKey -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $foreignFingerprint } 'signature verification failed'

    $tagObject=(& git -C $repo cat-file tag 'refs/tags/release/fixture') -join [char]10
    $fakePgp=$tagObject.Replace('-----BEGIN SSH SIGNATURE-----','-----BEGIN PGP SIGNATURE-----').Replace('-----END SSH SIGNATURE-----','-----END PGP SIGNATURE-----')
    $fakePgpPath=Join-Path $root 'fake-pgp-tag.txt'
    [IO.File]::WriteAllText($fakePgpPath,$fakePgp+[char]10,[Text.UTF8Encoding]::new($false))
    $fakePgpOid=(& git -C $repo hash-object -t tag -w $fakePgpPath).Trim()
    if($LASTEXITCODE-ne0){throw 'fake PGP tag object creation failed.'}
    & git -C $repo update-ref 'refs/tags/release/fake-pgp' $fakePgpOid
    if($LASTEXITCODE-ne0){throw 'fake PGP tag ref creation failed.'}
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fake-pgp' -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'must contain an SSH signature'

    & git -C $repo -c tag.gpgSign=false tag unsigned $commit1
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag unsigned -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'annotated tag'

    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'two',[Text.UTF8Encoding]::new($false))
    & git -C $repo add fixture.txt
    & git -C $repo -c commit.gpgsign=false commit -q -m two
    $commit2=(& git -C $repo rev-parse HEAD).Trim()
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit2 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'commit mismatch'

    & git -C $repo -c tag.gpgSign=false -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a FETCH_HEAD -m pseudo-ref-collision $commit2
    if($LASTEXITCODE-ne0){throw 'pseudo-ref collision tag creation failed.'}
    [IO.File]::WriteAllText((Join-Path $repo '.git\FETCH_HEAD'),$commit1+[char]10,[Text.UTF8Encoding]::new($false))
    $qualifiedTag=Assert-VllmReleaseSignedTag -Repository $repo -Tag 'FETCH_HEAD' -ExpectedCommit $commit2 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint
    if(-not$qualifiedTag.project_commit.Equals($commit2,[StringComparison]::OrdinalIgnoreCase)){throw 'qualified tag verification resolved the pseudo-ref instead of refs/tags/FETCH_HEAD.'}
    $assets=[ordered]@{
        'wheel.whl'=('A'*64)
        'bundle.zip'=('B'*64)
        'release-index.json'=('C'*64)
        'SHA256SUMS'=('D'*64)
    }
    function Get-FixtureAttestation {
        param([string]$Repository='AviBackToBlack/vllm-windows-native',[string]$Tag='release/test',[string]$TagObject=$tagObjectId,[System.Collections.IDictionary]$AssetMap=$assets)
        $subjects=New-Object System.Collections.Generic.List[object]
        $subjects.Add([ordered]@{uri="pkg:github/$Repository@$Tag";digest=[ordered]@{sha1=$TagObject}})
        foreach($name in $AssetMap.Keys){$subjects.Add([ordered]@{name=[string]$name;digest=[ordered]@{sha256=[string]$AssetMap[$name]}})}
        [ordered]@{verificationResult=[ordered]@{statement=[ordered]@{
            _type='https://in-toto.io/Statement/v1'
            subject=$subjects.ToArray()
            predicateType='https://in-toto.io/attestation/release/v0.2'
            predicate=[ordered]@{repository=$Repository;tag=$Tag}
        }}}|ConvertTo-Json -Depth 10 -Compress
    }

    $json=Get-FixtureAttestation
    $a=Assert-VllmReleaseAttestationJson -Json $json -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets
    if($a.asset_count-ne4){throw 'attestation verifier returned wrong asset count.'}

    $lowercaseRepoJson=Get-FixtureAttestation -Repository 'avibacktoblack/vllm-windows-native'
    $lowercaseRepo=Assert-VllmReleaseAttestationJson -Json $lowercaseRepoJson -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets
    if($lowercaseRepo.asset_count-ne4){throw 'case-insensitive repository binding returned wrong asset count.'}

    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -Repository 'Other/repo') -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'repository/tag'
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -Tag 'release/other') -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'repository/tag'
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -TagObject ('0'*40)) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'tag-object mismatch'

    $caseAsset=[ordered]@{}; foreach($k in $assets.Keys){$caseAsset[$k]=$assets[$k]}
    $caseJson=(Get-FixtureAttestation -AssetMap $caseAsset).Replace('"wheel.whl"','"WHEEL.WHL"')
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json $caseJson -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'unexpected asset'

    $wrong=[ordered]@{}; foreach($k in $assets.Keys){$wrong[$k]=$assets[$k]}; $wrong['wheel.whl']='E'*64
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $wrong) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'digest mismatch'

    $missing=[ordered]@{}; foreach($k in $assets.Keys|Where-Object{$_-ne'SHA256SUMS'}){$missing[$k]=$assets[$k]}
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $missing) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'subject count mismatch'

    $extra=[ordered]@{}; foreach($k in $assets.Keys){$extra[$k]=$assets[$k]}; $extra['extra.bin']='F'*64
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $extra) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'subject count mismatch'

    $overlapDoc=(Get-FixtureAttestation | ConvertFrom-Json)
    $overlapDoc.verificationResult.statement.subject[0] | Add-Member -NotePropertyName name -NotePropertyValue 'wheel.whl'
    $overlapDoc.verificationResult.statement.subject[0].digest | Add-Member -NotePropertyName sha256 -NotePropertyValue ('A'*64)
    $overlapDoc.verificationResult.statement.subject[4]=[pscustomobject]@{other='ignored-before-fix'}
    $overlapJson=$overlapDoc|ConvertTo-Json -Depth 10 -Compress
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json $overlapJson -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'subject schema'

    $badDigestDoc=(Get-FixtureAttestation | ConvertFrom-Json)
    $badDigestDoc.verificationResult.statement.subject[1].digest | Add-Member -NotePropertyName sha1 -NotePropertyValue ('0'*40)
    $badDigestJson=$badDigestDoc|ConvertTo-Json -Depth 10 -Compress
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json $badDigestJson -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedTagObject $tagObjectId -ExpectedAssets $assets } 'asset digest schema'

    Assert-Fails { Invoke-VllmGhJsonCommand -Arguments @('ignored') -FailureLabel 'missing gh' -Executable 'definitely-not-a-vllm-gh-command' } 'executable not found'

    $fakeGh=Join-Path $root 'fake-gh-success.cmd'
    [IO.File]::WriteAllLines($fakeGh,@('@echo off','echo {"ok":true}','echo gh update notice 1>&2','exit /b 0'),[Text.Encoding]::ASCII)
    $capturedJson=Invoke-VllmGhJsonCommand -Arguments @('ignored') -FailureLabel 'fake gh failed' -Executable $fakeGh
    if(-not$capturedJson.Equals('{"ok":true}',[StringComparison]::Ordinal)){throw "stdout/stderr separation failed: $capturedJson"}

    $fakeGhFail=Join-Path $root 'fake-gh-fail.cmd'
    [IO.File]::WriteAllLines($fakeGhFail,@('@echo off','echo bad gh diagnostic 1>&2','exit /b 7'),[Text.Encoding]::ASCII)
    Assert-Fails { Invoke-VllmGhJsonCommand -Arguments @('ignored') -FailureLabel 'fake gh failed' -Executable $fakeGhFail } 'bad gh diagnostic'

    $retryState=[pscustomobject]@{Count=0}
    $retryResult=Invoke-VllmBoundedRetry -Attempts 3 -DelayMilliseconds 0 -Action {
        $retryState.Count++
        if($retryState.Count-lt3){throw "transient attestation failure $($retryState.Count)"}
        'retry-ok'
    }
    if(-not([string]$retryResult).Equals('retry-ok',[StringComparison]::Ordinal)-or$retryState.Count-ne3){
        throw 'Bounded retry did not retry transient verification failures exactly as configured.'
    }

    $exhaustState=[pscustomobject]@{Count=0}
    $exhaustMessage=$null
    try {
        Invoke-VllmBoundedRetry -Attempts 2 -DelayMilliseconds 0 -Action {
            $exhaustState.Count++
            throw 'permanent attestation failure'
        }
    } catch {
        $exhaustMessage=$_.Exception.Message
    }
    if($null-eq$exhaustMessage-or$exhaustMessage.IndexOf('after 2 attempts',[StringComparison]::OrdinalIgnoreCase)-lt0-or$exhaustMessage.IndexOf('permanent attestation failure',[StringComparison]::OrdinalIgnoreCase)-lt0){
        throw "Bounded retry exhaustion diagnostic is incomplete: $exhaustMessage"
    }
    if($exhaustState.Count-ne2){throw 'Bounded retry did not stop at the configured attempt limit.'}

    Write-Host 'RELEASE_VERIFICATION_CONTRACT_OK'
}
finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
