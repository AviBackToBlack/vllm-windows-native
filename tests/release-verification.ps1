Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
. (Join-Path $PSScriptRoot '..\scripts\release-verification.ps1')

function Assert-Fails {
    param([Parameter(Mandatory)][scriptblock]$Action,[Parameter(Mandatory)][string]$Contains)
    try { & $Action; throw "Expected failure containing: $Contains" }
    catch {
        if ($_.Exception.Message.IndexOf($Contains,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Unexpected failure: $($_.Exception.Message)" }
    }
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
    & git -C $repo commit -q -m one
    $commit1=(& git -C $repo rev-parse HEAD).Trim()

    $key=Join-Path $root 'fixture-key'
    Get-FixtureSshKey -Path $key
    $pub=([IO.File]::ReadAllText($key+'.pub')).Trim()
    $pubFields=@($pub -split ' ')
    $allowed=Join-Path $root 'allowed_signers'
    [IO.File]::WriteAllText($allowed,"fixture-release $($pubFields[0]) $($pubFields[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    $fingerprint=Get-VllmReleaseSigningKeyFingerprint -Path $allowed

    & git -C $repo -c 'gpg.format=ssh' -c "user.signingkey=$key" tag -s -a release/fixture -m fixture $commit1
    if($LASTEXITCODE-ne0){throw 'fixture signed tag creation failed.'}
    $ok=Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint
    if($ok.project_commit-ne$commit1){throw 'signed tag verifier returned wrong commit.'}

    $wrongPrincipal=Join-Path $root 'wrong-principal'
    [IO.File]::WriteAllText($wrongPrincipal,"wrong-release $($pubFields[0]) $($pubFields[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $wrongPrincipal -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'principal mismatch'

    $key2=Join-Path $root 'wrong-key'
    Get-FixtureSshKey -Path $key2
    $pub2=([IO.File]::ReadAllText($key2+'.pub')).Trim() -split ' '
    $wrongKey=Join-Path $root 'wrong-key-signers'
    [IO.File]::WriteAllText($wrongKey,"fixture-release $($pub2[0]) $($pub2[1])"+[char]10,[Text.UTF8Encoding]::new($false))
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit1 -AllowedSignersPath $wrongKey -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'fingerprint mismatch'

    & git -C $repo tag unsigned $commit1
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag unsigned -ExpectedCommit $commit1 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'annotated tag'

    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'two',[Text.UTF8Encoding]::new($false))
    & git -C $repo add fixture.txt
    & git -C $repo commit -q -m two
    $commit2=(& git -C $repo rev-parse HEAD).Trim()
    Assert-Fails { Assert-VllmReleaseSignedTag -Repository $repo -Tag 'release/fixture' -ExpectedCommit $commit2 -AllowedSignersPath $allowed -ExpectedPrincipal 'fixture-release' -ExpectedFingerprint $fingerprint } 'commit mismatch'

    $assets=[ordered]@{
        'wheel.whl'=('A'*64)
        'bundle.zip'=('B'*64)
        'release-index.json'=('C'*64)
        'SHA256SUMS'=('D'*64)
    }
    function Get-FixtureAttestation {
        param([string]$Repository='AviBackToBlack/vllm-windows-native',[string]$Tag='release/test',[string]$Commit=$commit1,[System.Collections.IDictionary]$AssetMap=$assets)
        $subjects=New-Object System.Collections.Generic.List[object]
        $subjects.Add([ordered]@{uri="pkg:github/$Repository@$Tag";digest=[ordered]@{sha1=$Commit}})
        foreach($name in $AssetMap.Keys){$subjects.Add([ordered]@{name=[string]$name;digest=[ordered]@{sha256=[string]$AssetMap[$name]}})}
        [ordered]@{verificationResult=[ordered]@{statement=[ordered]@{
            _type='https://in-toto.io/Statement/v1'
            subject=$subjects.ToArray()
            predicateType='https://in-toto.io/attestation/release/v0.2'
            predicate=[ordered]@{repository=$Repository;tag=$Tag}
        }}}|ConvertTo-Json -Depth 10 -Compress
    }

    $json=Get-FixtureAttestation
    $a=Assert-VllmReleaseAttestationJson -Json $json -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets
    if($a.asset_count-ne4){throw 'attestation verifier returned wrong asset count.'}

    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -Repository 'Other/repo') -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'repository/tag'
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -Tag 'release/other') -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'repository/tag'
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -Commit ('0'*40)) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'commit mismatch'

    $caseAsset=[ordered]@{}; foreach($k in $assets.Keys){$caseAsset[$k]=$assets[$k]}
    $caseJson=(Get-FixtureAttestation -AssetMap $caseAsset).Replace('"wheel.whl"','"WHEEL.WHL"')
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json $caseJson -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'unexpected asset'

    $wrong=[ordered]@{}; foreach($k in $assets.Keys){$wrong[$k]=$assets[$k]}; $wrong['wheel.whl']='E'*64
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $wrong) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'digest mismatch'

    $missing=[ordered]@{}; foreach($k in $assets.Keys|Where-Object{$_-ne'SHA256SUMS'}){$missing[$k]=$assets[$k]}
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $missing) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'asset count mismatch'

    $extra=[ordered]@{}; foreach($k in $assets.Keys){$extra[$k]=$assets[$k]}; $extra['extra.bin']='F'*64
    Assert-Fails { Assert-VllmReleaseAttestationJson -Json (Get-FixtureAttestation -AssetMap $extra) -RepositorySlug 'AviBackToBlack/vllm-windows-native' -Tag 'release/test' -ExpectedCommit $commit1 -ExpectedAssets $assets } 'asset count mismatch'

    Write-Host 'RELEASE_VERIFICATION_CONTRACT_OK'
}
finally {
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
