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
    param(
        [Parameter(Mandatory)][string]$KeyType,
        [Parameter(Mandatory)][string]$KeyData
    )
    $keyPath=[IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($keyPath,$KeyType+' '+$KeyData+[char]10,[Text.UTF8Encoding]::new($false))
        $output = & ssh-keygen -lf $keyPath -E sha256 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect release signing key: $($output -join ' ')" }
        $line = ($output -join [char]10).Trim()
        if ($line -notmatch 'SHA256:[A-Za-z0-9+/]+') { throw 'Release signing key fingerprint output is invalid.' }
        [string]$Matches[0]
    } finally {
        Remove-Item -LiteralPath $keyPath -Force -ErrorAction SilentlyContinue
    }
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
    $fingerprint = Get-VllmReleaseSigningKeyFingerprint -KeyType $fields[1] -KeyData $fields[2]
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
    $gitEnvironment = @{}
    $gitEnvironmentNames = @(Get-ChildItem Env: | Where-Object {
        $_.Name.Equals('GIT_CONFIG',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.StartsWith('GIT_CONFIG_',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_DIR',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_WORK_TREE',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_COMMON_DIR',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_OBJECT_DIRECTORY',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_ALTERNATE_OBJECT_DIRECTORIES',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GIT_NAMESPACE',[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -ExpandProperty Name)
    foreach ($name in $gitEnvironmentNames) {
        $gitEnvironment[$name] = (Get-Item -LiteralPath "Env:$name").Value
        Remove-Item -LiteralPath "Env:$name"
    }
    $oldErrorActionPreference=$ErrorActionPreference
    $nullConfig=if($env:OS -eq 'Windows_NT'){'NUL'}else{'/dev/null'}
    $revocationPath=[IO.Path]::GetTempFileName()
    try {
        $env:GIT_CONFIG_NOSYSTEM='1'
        $env:GIT_CONFIG_GLOBAL=$nullConfig
        $tagRef = "refs/tags/$Tag"
        $type = (Invoke-Git -Repository $Repository -Arguments @('cat-file','-t',$tagRef) -Capture).Trim()
        if (-not $type.Equals('tag',[StringComparison]::Ordinal)) { throw "Release tag must be an annotated tag object: $Tag" }
        $tagObject = (Invoke-Git -Repository $Repository -Arguments @('rev-parse',$tagRef) -Capture).Trim()
        $resolved = (Invoke-Git -Repository $Repository -Arguments @('rev-parse',"$tagObject^{commit}") -Capture).Trim()
        $signature = (Invoke-Git -Repository $Repository -Arguments @('for-each-ref','--format=%(contents:signature)',$tagRef) -Capture).Trim()
        if (-not $signature.StartsWith('-----BEGIN SSH SIGNATURE-----',[StringComparison]::Ordinal) -or
            -not $signature.EndsWith('-----END SSH SIGNATURE-----',[StringComparison]::Ordinal)) {
            throw 'Release tag must contain an SSH signature; OpenPGP, X.509, unsigned, or unknown signature formats are not authorized.'
        }
        if (-not $resolved.Equals($ExpectedCommit,[StringComparison]::OrdinalIgnoreCase)) { throw "Release tag commit mismatch: expected $ExpectedCommit, got $resolved" }

        $ErrorActionPreference='Continue'
        $gitArgs=@(
            '-C',$Repository,
            '-c','gpg.format=ssh',
            '-c','gpg.ssh.program=ssh-keygen',
            '-c',('gpg.ssh.allowedSignersFile='+$trust.path),
            '-c',('gpg.ssh.revocationFile='+$revocationPath),
            '-c','gpg.minTrustLevel=fully',
            'verify-tag',$tagRef
        )
        $verify=& git @gitArgs 2>&1
        $verifyExit=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$oldErrorActionPreference
        @(Get-ChildItem Env: | Where-Object {
            $_.Name.Equals('GIT_CONFIG',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('GIT_CONFIG_',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_DIR',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_WORK_TREE',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_COMMON_DIR',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_OBJECT_DIRECTORY',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_ALTERNATE_OBJECT_DIRECTORIES',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GIT_NAMESPACE',[StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -ExpandProperty Name) | ForEach-Object {
            Remove-Item -LiteralPath "Env:$_"
        }
        foreach ($name in $gitEnvironment.Keys) {
            Set-Item -LiteralPath "Env:$name" -Value $gitEnvironment[$name]
        }
        Remove-Item -LiteralPath $revocationPath -Force -ErrorAction SilentlyContinue
    }
    if ($verifyExit -ne 0) { throw "Release tag signature verification failed: $($verify -join ' ')" }
    $verifyLines=@($verify | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $goodLines=@($verifyLines | Where-Object { $_.StartsWith('Good "git" signature for ',[StringComparison]::Ordinal) })
    if($goodLines.Count-ne1){throw 'Release tag verification did not report exactly one good SSH signature.'}
    $expectedPrefix='Good "git" signature for '+$trust.principal+' with '
    $expectedSuffix=' key '+$trust.fingerprint
    if(-not$goodLines[0].StartsWith($expectedPrefix,[StringComparison]::Ordinal) -or
       -not$goodLines[0].EndsWith($expectedSuffix,[StringComparison]::Ordinal)){
        throw "Release tag signer identity mismatch: $($goodLines[0])"
    }

    [pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-signed-tag-verification'
        tag=$Tag
        tag_object=$tagObject.ToLowerInvariant()
        project_commit=$resolved.ToLowerInvariant()
        principal=$trust.principal
        key_fingerprint=$trust.fingerprint
    }
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
        [Parameter(Mandatory)][string]$ExpectedTagObject,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedAssets
    )
    try { $doc = $Json | ConvertFrom-Json } catch { throw 'GitHub release verification output is invalid JSON.' }
    $s = $doc.verificationResult.statement
    if ($null -eq $s) { throw 'GitHub release verification output is missing the verified statement.' }
    if (-not ([string]$s._type).Equals('https://in-toto.io/Statement/v1',[StringComparison]::Ordinal)) { throw 'GitHub release attestation statement type is unsupported.' }
    if (-not ([string]$s.predicateType).Equals('https://in-toto.io/attestation/release/v0.2',[StringComparison]::Ordinal)) { throw 'GitHub release attestation predicate type is unsupported.' }
    if (-not ([string]$s.predicate.repository).Equals($RepositorySlug,[StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$s.predicate.tag).Equals($Tag,[StringComparison]::Ordinal)) {
        throw 'GitHub release attestation repository/tag identity mismatch.'
    }

    $subjects = @($s.subject)
    if($subjects.Count-ne($ExpectedAssets.Count+1)){throw 'GitHub release attestation subject count mismatch.'}
    $pkg=New-Object System.Collections.Generic.List[object]
    $assets=New-Object System.Collections.Generic.List[object]
    foreach($subject in $subjects){
        $properties=@($subject.PSObject.Properties.Name)
        $hasUri=$properties -contains 'uri'
        $hasName=$properties -contains 'name'
        if($properties.Count-ne2 -or -not($properties -contains 'digest') -or $hasUri -eq $hasName){
            throw 'GitHub release attestation subject schema is not exact.'
        }
        $digestProperties=@($subject.digest.PSObject.Properties.Name)
        if($hasUri){
            if($digestProperties.Count-ne1 -or -not($digestProperties -contains 'sha1')){throw 'GitHub release attestation package digest schema is not exact.'}
            $pkg.Add($subject)
        }else{
            if($digestProperties.Count-ne1 -or -not($digestProperties -contains 'sha256')){throw 'GitHub release attestation asset digest schema is not exact.'}
            $assets.Add($subject)
        }
    }
    if($pkg.Count-ne1){throw 'GitHub release attestation must contain exactly one package subject.'}
    if($assets.Count-ne$ExpectedAssets.Count){throw 'GitHub release attestation asset count mismatch.'}
    $packageUri=[string]$pkg[0].uri
    $packagePrefix='pkg:github/'
    $separator=$packageUri.LastIndexOf('@')
    if(-not$packageUri.StartsWith($packagePrefix,[StringComparison]::Ordinal) -or $separator-le$packagePrefix.Length){
        throw 'GitHub release attestation package URI mismatch.'
    }
    $packageRepository=$packageUri.Substring($packagePrefix.Length,$separator-$packagePrefix.Length)
    $packageTag=$packageUri.Substring($separator+1)
    if(-not$packageRepository.Equals($RepositorySlug,[StringComparison]::OrdinalIgnoreCase) -or
       -not$packageTag.Equals($Tag,[StringComparison]::Ordinal)){
        throw 'GitHub release attestation package URI mismatch.'
    }
    if (-not ([string]$pkg[0].digest.sha1).Equals($ExpectedTagObject,[StringComparison]::OrdinalIgnoreCase)) { throw 'GitHub release attestation tag-object mismatch.' }

    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($subject in $assets) {
        $name=[string]$subject.name
        $expectedNameMatches=@($ExpectedAssets.Keys | Where-Object { ([string]$_).Equals($name,[StringComparison]::Ordinal) })
        if($expectedNameMatches.Count-ne1){throw "GitHub release attestation contains unexpected asset: $name"}
        if(-not$seen.Add($name)){throw "GitHub release attestation duplicates asset: $name"}
        if(-not ([string]$subject.digest.sha256).Equals([string]$ExpectedAssets[$expectedNameMatches[0]],[StringComparison]::OrdinalIgnoreCase)){throw "GitHub release attestation digest mismatch for $name"}
    }

    [pscustomobject][ordered]@{
        repository=$RepositorySlug
        tag=$Tag
        tag_object=$ExpectedTagObject.ToLowerInvariant()
        asset_count=$ExpectedAssets.Count
    }
}

function Invoke-VllmGhJsonCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [string]$Executable = 'gh'
    )
    $stderrPath=[IO.Path]::GetTempFileName()
    $oldErrorActionPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $stdout=@(& $Executable @Arguments 2> $stderrPath)
        $exitCode=$LASTEXITCODE
        $stderr=if([IO.File]::Exists($stderrPath)){[IO.File]::ReadAllText($stderrPath).Trim()}else{''}
    } finally {
        $ErrorActionPreference=$oldErrorActionPreference
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    if($exitCode-ne0){
        $detail=if([string]::IsNullOrWhiteSpace($stderr)){('exit '+$exitCode)}else{$stderr}
        throw ($FailureLabel+': '+$detail)
    }
    $stdout -join [char]10
}

function Invoke-VllmGitHubReleaseVerification {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedTagObject,
        [Parameter(Mandatory)][string]$ArtifactsDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedAssets
    )
    $releaseJson=Invoke-VllmGhJsonCommand -Arguments @('release','verify',$Tag,'--repo',$RepositorySlug,'--format','json') -FailureLabel 'GitHub release attestation verification failed'
    $result=Assert-VllmReleaseAttestationJson -Json $releaseJson -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedTagObject $ExpectedTagObject -ExpectedAssets $ExpectedAssets
    foreach($name in $ExpectedAssets.Keys){
        $path=Join-Path ([IO.Path]::GetFullPath($ArtifactsDirectory)) ([string]$name)
        $assetJson=Invoke-VllmGhJsonCommand -Arguments @('release','verify-asset',$Tag,$path,'--repo',$RepositorySlug,'--format','json') -FailureLabel "GitHub release asset verification failed for $name"
        $null=Assert-VllmReleaseAttestationJson -Json $assetJson -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedTagObject $ExpectedTagObject -ExpectedAssets $ExpectedAssets
    }
    [pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-github-release-verification'
        repository=$result.repository
        tag=$result.tag
        tag_object=$result.tag_object
        asset_count=$result.asset_count
    }
}
