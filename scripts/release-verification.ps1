Set-StrictMode -Version Latest

$script:VllmReleasePrincipal = 'vllm-windows-native-release'
$script:VllmReleaseKeyFingerprint = 'SHA256:ga7J6BbUAgsSVju3a6RZU4Vw4/7wvn2xL/MTLWy77ng'
$script:VllmReleaseRepository = 'AviBackToBlack/vllm-windows-native'

function Read-VllmReleaseVerificationUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $bytes=[IO.File]::ReadAllBytes($Path)
    if($bytes.Length -ge 3 -and $bytes[0]-eq 0xEF -and $bytes[1]-eq 0xBB -and $bytes[2]-eq 0xBF){throw "$Label must not contain a UTF-8 BOM."}
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    try{$utf8.GetString($bytes)}catch{throw "$Label is not valid UTF-8."}
}

function Get-VllmReleaseSigningKeyFingerprint {
    param([Parameter(Mandatory)][string]$Path)
    $output = & ssh-keygen -lf $Path -E sha256 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect release signing key: $($output -join ' ')" }
    $line = ($output -join [char]10).Trim()
    if ($line -notmatch 'SHA256:[A-Za-z0-9+/]+') { throw 'Release signing key fingerprint output is invalid.' }
    [string]$Matches[0]
}

function Assert-VllmReleaseAllowedSigners {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedPrincipal = $script:VllmReleasePrincipal,
        [string]$ExpectedFingerprint = $script:VllmReleaseKeyFingerprint
    )
    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($full)) { throw "Release trust root does not exist: $full" }
    $text = Read-VllmReleaseVerificationUtf8 -Path $full -Label 'release allowed signers'
    if ($text.Contains([char]13) -or -not $text.EndsWith([string][char]10,[StringComparison]::Ordinal)) { throw 'Release trust root must be LF-terminated UTF-8 text.' }
    $lines = @($text.TrimEnd([char]10) -split [char]10)
    if ($lines.Count -ne 1) { throw 'Release trust root must contain exactly one signer entry in v1.' }
    $fields = @($lines[0] -split ' ')
    if ($fields.Count -ne 3) { throw 'Release trust root entry must contain exactly principal, key type, and key data.' }
    if (-not $fields[0].Equals($ExpectedPrincipal,[StringComparison]::Ordinal)) { throw "Release trust root principal mismatch: $($fields[0])" }
    $fingerprint = Get-VllmReleaseSigningKeyFingerprint -Path $full
    if (-not $fingerprint.Equals($ExpectedFingerprint,[StringComparison]::Ordinal)) { throw "Release trust root key fingerprint mismatch: $fingerprint" }
    [pscustomobject][ordered]@{ principal=$ExpectedPrincipal; fingerprint=$fingerprint; path=$full }
}

function Assert-VllmReleaseSignedTag {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$AllowedSignersPath,
        [string]$ExpectedPrincipal = $script:VllmReleasePrincipal,
        [string]$ExpectedFingerprint = $script:VllmReleaseKeyFingerprint
    )
    $trust = Assert-VllmReleaseAllowedSigners -Path $AllowedSignersPath -ExpectedPrincipal $ExpectedPrincipal -ExpectedFingerprint $ExpectedFingerprint
    $type = (Invoke-Git -Repository $Repository -Arguments @('cat-file','-t',"refs/tags/$Tag") -Capture).Trim()
    if (-not $type.Equals('tag',[StringComparison]::Ordinal)) { throw "Release tag must be an annotated tag object: $Tag" }
    $resolved = (Invoke-Git -Repository $Repository -Arguments @('rev-parse',"$Tag^{commit}") -Capture).Trim()
    $signature = (Invoke-Git -Repository $Repository -Arguments @('for-each-ref','--format=%(contents:signature)',"refs/tags/$Tag") -Capture).Trim()
    if (-not $signature.StartsWith('-----BEGIN SSH SIGNATURE-----',[StringComparison]::Ordinal) -or
        -not $signature.EndsWith('-----END SSH SIGNATURE-----',[StringComparison]::Ordinal)) {
        throw 'Release tag must contain an SSH signature; OpenPGP, X.509, unsigned, or unknown signature formats are not authorized.'
    }
    if (-not $resolved.Equals($ExpectedCommit,[StringComparison]::OrdinalIgnoreCase)) { throw "Release tag commit mismatch: expected $ExpectedCommit, got $resolved" }
    $oldNoSystem=$env:GIT_CONFIG_NOSYSTEM
    $oldGlobal=$env:GIT_CONFIG_GLOBAL
    $oldErrorActionPreference=$ErrorActionPreference
    $nullConfig=if($env:OS -eq 'Windows_NT'){'NUL'}else{'/dev/null'}
    $revocationPath=[IO.Path]::GetTempFileName()
    try {
        $env:GIT_CONFIG_NOSYSTEM='1'
        $env:GIT_CONFIG_GLOBAL=$nullConfig
        $ErrorActionPreference='Continue'
        $gitArgs=@(
            '-C',$Repository,
            '-c','gpg.format=ssh',
            '-c','gpg.ssh.program=ssh-keygen',
            '-c',('gpg.ssh.allowedSignersFile='+$trust.path),
            '-c',('gpg.ssh.revocationFile='+$revocationPath),
            '-c','gpg.minTrustLevel=fully',
            'verify-tag',$Tag
        )
        $verify=& git @gitArgs 2>&1
        $verifyExit=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$oldErrorActionPreference
        $env:GIT_CONFIG_NOSYSTEM=$oldNoSystem
        $env:GIT_CONFIG_GLOBAL=$oldGlobal
        Remove-Item -LiteralPath $revocationPath -Force -ErrorAction SilentlyContinue
    }
    if ($verifyExit -ne 0) { throw "Release tag signature verification failed: $($verify -join ' ')" }    [pscustomobject][ordered]@{ schema_version=1; component='vllm-windows-native-signed-tag-verification'; tag=$Tag; project_commit=$resolved.ToLowerInvariant(); principal=$trust.principal; key_fingerprint=$trust.fingerprint }
}

function Get-VllmReleaseExpectedAssets {
    param([Parameter(Mandatory)][string]$ArtifactsDirectory,[Parameter(Mandatory)]$OfflineVerification)
    $indexText = Read-VllmReleaseVerificationUtf8 -Path (Join-Path ([IO.Path]::GetFullPath($ArtifactsDirectory)) 'release-index.json') -Label 'release-index.json'
    try { $index = $indexText | ConvertFrom-Json } catch { throw 'release-index.json is invalid JSON.' }
    $assets = [ordered]@{}
    $assets[[string]$index.wheel.filename] = [string]$OfflineVerification.wheel_sha256
    $assets[[string]$index.bundle.filename] = [string]$OfflineVerification.bundle_sha256
    $assets['release-index.json'] = [string]$OfflineVerification.index_sha256
    $assets['SHA256SUMS'] = [string]$OfflineVerification.checksums_sha256
    $assets
}

function Assert-VllmReleaseAttestationJson {
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedAssets
    )
    try { $doc = $Json | ConvertFrom-Json } catch { throw 'GitHub release verification output is invalid JSON.' }
    $s = $doc.verificationResult.statement
    if ($null -eq $s) { throw 'GitHub release verification output is missing the verified statement.' }
    if (-not ([string]$s._type).Equals('https://in-toto.io/Statement/v1',[StringComparison]::Ordinal)) { throw 'GitHub release attestation statement type is unsupported.' }
    if (-not ([string]$s.predicateType).Equals('https://in-toto.io/attestation/release/v0.2',[StringComparison]::Ordinal)) { throw 'GitHub release attestation predicate type is unsupported.' }
    if (-not ([string]$s.predicate.repository).Equals($RepositorySlug,[StringComparison]::Ordinal) -or -not ([string]$s.predicate.tag).Equals($Tag,[StringComparison]::Ordinal)) { throw 'GitHub release attestation repository/tag identity mismatch.' }

   $subjects = @($s.subject)
    $pkg = @($subjects | Where-Object { $_.PSObject.Properties.Name -contains 'uri' })
    $assets = @($subjects | Where-Object { $_.PSObject.Properties.Name -contains 'name' })
    if ($pkg.Count -ne 1) { throw 'GitHub release attestation must contain exactly one package subject.' }
    if ($assets.Count -ne $ExpectedAssets.Count -or $subjects.Count -ne ($ExpectedAssets.Count + 1)) { throw 'GitHub release attestation asset count mismatch.' }

    if (-not ([string]$pkg[0].uri).Equals("pkg:github/$RepositorySlug@$Tag",[StringComparison]::Ordinal)) { throw 'GitHub release attestation package URI mismatch.' }
    if (-not ([string]$pkg[0].digest.sha1).Equals($ExpectedCommit,[StringComparison]::OrdinalIgnoreCase)) { throw 'GitHub release attestation commit mismatch.' }

    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($subject in $assets) {
        $name=[string]$subject.name
        $expectedNameMatches=@($ExpectedAssets.Keys | Where-Object { ([string]$_).Equals($name,[StringComparison]::Ordinal) })
        if($expectedNameMatches.Count-ne1){throw "GitHub release attestation contains unexpected asset: $name"}
        if(-not$seen.Add($name)){throw "GitHub release attestation duplicates asset: $name"}
        if(-not ([string]$subject.digest.sha256).Equals([string]$ExpectedAssets[$expectedNameMatches[0]],[StringComparison]::OrdinalIgnoreCase)){throw "GitHub release attestation digest mismatch for $name"}
    }

    [pscustomobject][ordered]@{ repository=$RepositorySlug; tag=$Tag; project_commit=$ExpectedCommit.ToLowerInvariant(); asset_count=$ExpectedAssets.Count }
}

function Invoke-VllmGitHubReleaseVerification {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [Parameter(Mandatory)][string]$ArtifactsDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedAssets
    )
    $releaseJson=& gh release verify $Tag --repo $RepositorySlug --format json 2>&1
    if($LASTEXITCODE -ne 0){throw "GitHub release attestation verification failed: $($releaseJson -join ' ')"}
    $result=Assert-VllmReleaseAttestationJson -Json ($releaseJson -join [char]10) -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedCommit $ExpectedCommit -ExpectedAssets $ExpectedAssets
    foreach($name in $ExpectedAssets.Keys){
        $path=Join-Path ([IO.Path]::GetFullPath($ArtifactsDirectory)) ([string]$name)
        $assetJson=& gh release verify-asset $Tag $path --repo $RepositorySlug --format json 2>&1
        if($LASTEXITCODE -ne 0){throw "GitHub release asset verification failed for $name"}
        $null=Assert-VllmReleaseAttestationJson -Json ($assetJson -join [char]10) -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedCommit $ExpectedCommit -ExpectedAssets $ExpectedAssets
    }
    [pscustomobject][ordered]@{ schema_version=1; component='vllm-windows-native-github-release-verification'; repository=$result.repository; tag=$result.tag; project_commit=$result.project_commit; asset_count=$result.asset_count }
}
