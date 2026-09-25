Set-StrictMode -Version Latest

$script:VllmSm19dRepositorySlug = 'AviBackToBlack/vllm-windows-native'
$script:VllmSm19dPrincipal = 'vllm-windows-native-sm19d-acceptance'
$script:VllmSm19dStateFile = 'acceptance-state.json'

function Assert-VllmSm19dAcceptanceId {
    param([Parameter(Mandatory)][string]$AcceptanceId)
    if ($AcceptanceId -cnotmatch '^[a-z0-9][a-z0-9.-]{5,63}$' -or
        $AcceptanceId.Contains('..') -or
        $AcceptanceId.EndsWith('.',[StringComparison]::Ordinal) -or
        $AcceptanceId.EndsWith('.lock',[StringComparison]::Ordinal)) {
        throw 'SM-19D acceptance id must be 6-64 lowercase ASCII letters, digits, dot, or hyphen; it must not contain consecutive dots or end with dot or .lock.'
    }
}

function Get-VllmSm19dAcceptanceIdentity {
    param([Parameter(Mandatory)][string]$AcceptanceId)
    Assert-VllmSm19dAcceptanceId -AcceptanceId $AcceptanceId
    [pscustomobject][ordered]@{
        acceptance_id = $AcceptanceId
        release = 'sm19d-acceptance-' + $AcceptanceId
        tag = 'acceptance/sm19d/' + $AcceptanceId
        principal = $script:VllmSm19dPrincipal
    }
}

function Get-VllmSm19dExpectedAssetNames {
    @(
        'sm19d-non-production-fixture.whl',
        'vllm-windows-native-sm19d-non-production-fixture.zip',
        'release-index.json',
        'SHA256SUMS'
    )
}

function Get-VllmSm19dAssetPlanFromDirectory {
    param([Parameter(Mandatory)][string]$AssetsDirectory)
    $root = [IO.Path]::GetFullPath($AssetsDirectory)
    if (-not [IO.Directory]::Exists($root)) { throw "SM-19D asset directory does not exist: $root" }
    $actual = @(Get-ChildItem -LiteralPath $root -Force)
    $expectedNames = @(Get-VllmSm19dExpectedAssetNames)
    if ($actual.Count -ne 4) { throw "SM-19D fixture must contain exactly four assets, got $($actual.Count)." }

    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($name in $expectedNames) {
        $nameMatches = @($actual | Where-Object { $_.Name.Equals($name,[StringComparison]::Ordinal) })
        if ($nameMatches.Count -ne 1) { throw "SM-19D fixture asset set mismatch: $name" }
        $item = $nameMatches[0]
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "SM-19D fixture asset must be a regular non-reparse file: $name"
        }
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        $plan.Add([pscustomobject][ordered]@{
            name = $name
            path = $item.FullName
            size = [int64]$item.Length
            sha256 = $hash
        })
    }
    [object[]]$plan
}

function Get-VllmSm19dAssetDigestMap {
    param([Parameter(Mandatory)][object[]]$AssetPlan)
    if ($AssetPlan.Count -ne 4) { throw 'SM-19D acceptance requires exactly four assets.' }
    $result = [ordered]@{}
    foreach ($asset in $AssetPlan) {
        $name = [string]$asset.name
        if ($result.Contains($name)) { throw "Duplicate SM-19D fixture asset: $name" }
        $result[$name] = [string]$asset.sha256
    }
    $result
}

function New-VllmSm19dFixtureAssets {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$AcceptanceId,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit
    )
    $assets = Join-Path ([IO.Path]::GetFullPath($Workspace)) 'assets'
    if(-not$PSCmdlet.ShouldProcess($assets,'Create synthetic SM-19D fixture assets')){return}
    if ([IO.Directory]::Exists($assets) -or [IO.File]::Exists($assets)) { throw "SM-19D asset path already exists: $assets" }
    [IO.Directory]::CreateDirectory($assets) | Out-Null

    $utf8 = [Text.UTF8Encoding]::new($false)
    $wheelName = 'sm19d-non-production-fixture.whl'
    $bundleName = 'vllm-windows-native-sm19d-non-production-fixture.zip'
    $indexName = 'release-index.json'
    $sumName = 'SHA256SUMS'
    $lf = [string][char]10

    $wheelText = 'NON-PRODUCTION SM-19D FIXTURE' + $lf + 'acceptance=' + $AcceptanceId + $lf + 'tag=' + $Tag + $lf + 'commit=' + $ProjectCommit + $lf
    [IO.File]::WriteAllText((Join-Path $assets $wheelName),$wheelText,$utf8)
    $bundleText = 'NON-PRODUCTION SM-19D OPAQUE BUNDLE FIXTURE' + $lf + 'acceptance=' + $AcceptanceId + $lf + 'tag=' + $Tag + $lf + 'commit=' + $ProjectCommit + $lf
    [IO.File]::WriteAllText((Join-Path $assets $bundleName),$bundleText,$utf8)

    $index = [ordered]@{
        schema_version = 1
        component = 'vllm-windows-native-sm19d-non-production-fixture'
        non_production = $true
        acceptance_id = $AcceptanceId
        repository = $script:VllmSm19dRepositorySlug
        tag = $Tag
        project_commit = $ProjectCommit.ToLowerInvariant()
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText((Join-Path $assets $indexName),$index + $lf,$utf8)

    $sumLines = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($wheelName,$bundleName,$indexName)) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $assets $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        $sumLines.Add($hash + '  ' + $name)
    }
    [IO.File]::WriteAllText((Join-Path $assets $sumName),($sumLines -join $lf) + $lf,$utf8)
    Get-VllmSm19dAssetPlanFromDirectory -AssetsDirectory $assets
}

function Invoke-VllmSm19dSshKeygen {
    param([Parameter(Mandatory)][string]$PrivateKeyPath)
    if($PrivateKeyPath.Contains('%')){throw 'SM-19D private-key path must not contain percent characters because cmd.exe expands percent-delimited environment variables.'}
    if ($env:OS -ne 'Windows_NT') { throw 'SM-19D trusted acceptance key generation is Windows-only.' }
    $ssh = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($null -eq $ssh) { throw 'SM-19D acceptance requires ssh-keygen.exe.' }
    if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { throw 'SM-19D acceptance requires ComSpec for cross-PowerShell ssh-keygen invocation.' }
    $command = '""' + $ssh.Source + '" -q -t ed25519 -N "" -C sm19d-acceptance -f "' + $PrivateKeyPath + '""'
    & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) { throw "SM-19D ssh-keygen failed with exit $LASTEXITCODE." }
}

function New-VllmSm19dSigningMaterial {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$Workspace)
    $root = [IO.Path]::GetFullPath($Workspace)
    $signing = Join-Path $root 'signing'
    if(-not$PSCmdlet.ShouldProcess($signing,'Create ephemeral SM-19D signing material')){return}
    if ([IO.Directory]::Exists($signing) -or [IO.File]::Exists($signing)) { throw "SM-19D signing path already exists: $signing" }
    [IO.Directory]::CreateDirectory($signing) | Out-Null

    $privateKey = Join-Path $signing 'acceptance-ed25519'
    Invoke-VllmSm19dSshKeygen -PrivateKeyPath $privateKey
    $publicKey = $privateKey + '.pub'
    if (-not [IO.File]::Exists($privateKey) -or -not [IO.File]::Exists($publicKey)) { throw 'SM-19D ssh-keygen did not create the expected key pair.' }

    $publicText = [IO.File]::ReadAllText($publicKey).Trim()
    $fields = @($publicText -split ' ')
    if ($fields.Count -lt 2) { throw 'SM-19D generated public key is malformed.' }
    $keyType = $fields[0]
    $keyData = $fields[1]
    $fingerprint = Get-VllmReleaseSigningKeyFingerprint -KeyType $keyType -KeyData $keyData
    $allowed = Join-Path $signing 'allowed-signers'
    [IO.File]::WriteAllText(
        $allowed,
        $script:VllmSm19dPrincipal + ' ' + $keyType + ' ' + $keyData + [char]10,
        [Text.UTF8Encoding]::new($false)
    )
    [pscustomobject][ordered]@{
        principal = $script:VllmSm19dPrincipal
        fingerprint = $fingerprint
        private_key = $privateKey
        public_key = $publicKey
        allowed_signers = $allowed
    }
}

function New-VllmSm19dSignedTag {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$AcceptanceId
    )
    $existing = Invoke-Git -Repository $Repository -Arguments @('tag','--list',$Tag) -Capture
    if (-not [string]::IsNullOrWhiteSpace($existing)) { throw "Local SM-19D acceptance tag already exists: $Tag" }
    if(-not$PSCmdlet.ShouldProcess($Tag,'Create local annotated SSH-signed SM-19D acceptance tag')){return}
    Invoke-Git -Repository $Repository -Arguments @(
        '-c','user.name=vLLM Windows Native SM-19D',
        '-c','user.email=sm19d-acceptance@invalid.local',
        '-c','gpg.format=ssh',
        '-c',('user.signingkey=' + [IO.Path]::GetFullPath($PrivateKeyPath)),
        '-c','gpg.ssh.program=ssh-keygen',
        'tag','-s','-a',$Tag,
        '-m',("SM-19D non-production acceptance $AcceptanceId"),
        $ProjectCommit
    )
}

function Remove-VllmSm19dPrivateSigningKey {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$PrivateKeyPath)
    if(-not$PSCmdlet.ShouldProcess($PrivateKeyPath,'Delete ephemeral SM-19D private signing key')){return}
    $entry=Get-VllmPathEntryInfo -Path $PrivateKeyPath
    if($entry.Exists -and ($entry.IsDirectory -or $entry.IsReparsePoint)){
        throw 'SM-19D private-key path is not a safe regular file.'
    }
    if ([IO.File]::Exists($PrivateKeyPath)) {
        Remove-Item -LiteralPath $PrivateKeyPath -Force
    }
    if ([IO.File]::Exists($PrivateKeyPath)) { throw 'SM-19D ephemeral private key still exists after removal.' }
}

function Assert-VllmSm19dStateObject {
    param([Parameter(Mandatory)]$State)
    if ([int]$State.schema_version -ne 1 -or -not ([string]$State.component).Equals('vllm-windows-native-sm19d-acceptance',[StringComparison]::Ordinal)) {
        throw 'SM-19D acceptance state schema/component mismatch.'
    }
    $identity = Get-VllmSm19dAcceptanceIdentity -AcceptanceId ([string]$State.acceptance_id)
    if (-not ([string]$State.repository).Equals($script:VllmSm19dRepositorySlug,[StringComparison]::Ordinal) -or
        -not ([string]$State.release).Equals($identity.release,[StringComparison]::Ordinal) -or
        -not ([string]$State.tag).Equals($identity.tag,[StringComparison]::Ordinal) -or
        -not ([string]$State.principal).Equals($script:VllmSm19dPrincipal,[StringComparison]::Ordinal) -or
        [string]$State.project_commit -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$State.tag_object -cnotmatch '^[0-9a-f]{40}$' -or
        [string]::IsNullOrWhiteSpace([string]$State.key_fingerprint)) {
        throw 'SM-19D acceptance state identity mismatch.'
    }
    foreach($name in @('draft_round_trip_completed','remote_tag_pushed','published')){
        $property=$State.PSObject.Properties[$name]
        if($null-eq$property -or -not($property.Value -is [bool])){throw "SM-19D acceptance state boolean is invalid: $name"}
    }
    if([bool]$State.draft_round_trip_completed -and -not[bool]$State.remote_tag_pushed){
        throw 'SM-19D acceptance state cannot record draft completion without the remote tag.'
    }
    if([bool]$State.published -and -not[bool]$State.draft_round_trip_completed){
        throw 'SM-19D acceptance state cannot record publication before draft-round-trip completion.'
    }
    if([bool]$State.published){
        if($null-eq$State.release_id -or [int64]$State.release_id -le 0 -or [string]::IsNullOrWhiteSpace([string]$State.release_url)){
            throw 'SM-19D published state must contain release id and URL.'
        }
    }elseif($null-ne$State.release_id -or $null-ne$State.release_url){
        throw 'SM-19D unpublished state must not contain published release identity.'
    }
    $State
}

function Clear-VllmSm19dResidualPrivateKey {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$Workspace)
    $path=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'signing\acceptance-ed25519'
    $entry=Get-VllmPathEntryInfo -Path $path
    if(-not$entry.Exists){return $false}
    if($entry.IsDirectory -or $entry.IsReparsePoint){throw 'SM-19D residual private-key path is not a safe regular file.'}
    if(-not$PSCmdlet.ShouldProcess($path,'Delete residual SM-19D ephemeral private signing key')){return $false}
    Remove-VllmSm19dPrivateSigningKey -PrivateKeyPath $path -Confirm:$false
    $true
}

function Write-VllmSm19dState {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)]$State,
        [ValidateSet('None','BeforePublish','AfterPublish')][string]$FaultPoint='None'
    )
    $path = Join-Path ([IO.Path]::GetFullPath($Workspace)) $script:VllmSm19dStateFile
    $null=Assert-VllmSm19dStateObject -State $State
    $validator={
        param($candidate,$candidatePath)
        $null=$candidatePath
        $null=Assert-VllmSm19dStateObject -State $candidate
    }
    $null=Write-VllmAtomicJsonFile -Path $path -Value $State -Depth 10 -Validate $validator -FaultPoint $FaultPoint
    $path
}

function Read-VllmSm19dState {
    param([Parameter(Mandatory)][string]$Workspace)
    $root = [IO.Path]::GetFullPath($Workspace)
    $path = Join-Path $root $script:VllmSm19dStateFile
    if (-not [IO.File]::Exists($path)) { throw "SM-19D acceptance state does not exist: $path" }
    try { $state = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw 'SM-19D acceptance state is invalid JSON.' }
    $null=Assert-VllmSm19dStateObject -State $state
    $state
}

function Assert-VllmSm19dStateFiles {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)]$State)
    $root = [IO.Path]::GetFullPath($Workspace)
    $allowed = Join-Path $root 'signing\allowed-signers'
    $assets = Join-Path $root 'assets'
    $trust = Assert-VllmReleaseAllowedSigners -Path $allowed -ExpectedPrincipal ([string]$State.principal) -ExpectedFingerprint ([string]$State.key_fingerprint)
    $plan = @(Get-VllmSm19dAssetPlanFromDirectory -AssetsDirectory $assets)
    $stored = @($State.assets)
    if ($stored.Count -ne 4) { throw 'SM-19D state must record exactly four assets.' }
    foreach ($asset in $plan) {
        $match = @($stored | Where-Object { ([string]$_.name).Equals([string]$asset.name,[StringComparison]::Ordinal) })
        if ($match.Count -ne 1 -or [int64]$match[0].size -ne [int64]$asset.size -or
            -not ([string]$match[0].sha256).Equals([string]$asset.sha256,[StringComparison]::OrdinalIgnoreCase)) {
            throw "SM-19D acceptance asset changed after preparation: $($asset.name)"
        }
    }
    [pscustomobject][ordered]@{
        trust = $trust
        asset_plan = [object[]]$plan
        assets_directory = $assets
    }
}

function Assert-VllmSm19dOperatorRepositoryState {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$RepositorySlug,
        [string]$ExpectedCommit,
        [string]$GhExecutable = 'gh'
    )
    $root = [IO.Path]::GetFullPath($Repository)
    $branch = (Invoke-Git -Repository $root -Arguments @('rev-parse','--abbrev-ref','HEAD') -Capture).Trim()
    if (-not $branch.Equals('main',[StringComparison]::Ordinal)) { throw "SM-19D trusted acceptance requires checked-out branch main, got '$branch'." }
    $status = Invoke-Git -Repository $root -Arguments @('status','--porcelain=v1','--untracked-files=all') -Capture
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'SM-19D trusted acceptance requires a clean project worktree.' }
    $head = (Invoke-Git -Repository $root -Arguments @('rev-parse','HEAD') -Capture).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit) -and -not $head.Equals($ExpectedCommit,[StringComparison]::OrdinalIgnoreCase)) {
        throw "SM-19D local main does not match prepared acceptance commit: $head"
    }
    $null = Assert-VllmGitHubReleaseImmutability -RepositorySlug $RepositorySlug -GhExecutable $GhExecutable
    Assert-VllmGitHubMainCommit -RepositorySlug $RepositorySlug -ProjectCommit $head -GhExecutable $GhExecutable
    $head
}

function Get-VllmSm19dRemoteTagObject {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$Tag,[string]$GhExecutable='gh')
    $escaped = [Uri]::EscapeDataString($Tag)
    try {
        $ref = Invoke-VllmPublicationGhJson -Arguments (Get-VllmPublicationApiArguments -Endpoint "repos/$RepositorySlug/git/ref/tags/$escaped") -FailureLabel 'Unable to inspect SM-19D remote tag' -Executable $GhExecutable
    } catch {
        if ($_.Exception.Message -match '(?i)HTTP 404') { return $null }
        throw
    }
    if (-not ([string]$ref.object.type).Equals('tag',[StringComparison]::Ordinal)) { throw 'SM-19D remote tag does not reference an annotated tag object.' }
    ([string]$ref.object.sha).ToLowerInvariant()
}

function Assert-VllmSm19dRemoteReleaseAbsent {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$Tag,[string]$GhExecutable='gh')
    $release = Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if ($null -ne $release) { throw "SM-19D acceptance release already exists for tag: $Tag" }
}

function Assert-VllmSm19dRemoteIdentityAbsent {
    param([Parameter(Mandatory)][string]$RepositorySlug,[Parameter(Mandatory)][string]$Tag,[string]$GhExecutable='gh')
    Assert-VllmSm19dRemoteReleaseAbsent -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    $tagObject = Get-VllmSm19dRemoteTagObject -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if ($null -ne $tagObject) { throw "SM-19D acceptance remote tag already exists: $Tag" }
}

function Assert-VllmSm19dRemoteTagExact {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedTagObject,
        [string]$GhExecutable='gh'
    )
    $actual = Get-VllmSm19dRemoteTagObject -RepositorySlug $RepositorySlug -Tag $Tag -GhExecutable $GhExecutable
    if ($null -eq $actual) { throw "SM-19D acceptance remote tag is missing: $Tag" }
    if (-not $actual.Equals($ExpectedTagObject,[StringComparison]::OrdinalIgnoreCase)) {
        throw "SM-19D acceptance remote tag object mismatch: expected $ExpectedTagObject, got $actual"
    }
}

function Get-VllmSm19dCanonicalPushUrl {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$RepositorySlug)
    if(-not$RepositorySlug.Equals($script:VllmSm19dRepositorySlug,[StringComparison]::Ordinal)){
        throw "SM-19D push repository slug mismatch: $RepositorySlug"
    }
    $canonical='https://github.com/'+$RepositorySlug+'.git'
    $effective=(Invoke-Git -Repository $Repository -Arguments @('ls-remote','--get-url',$canonical) -Capture).Trim()
    if(-not$effective.Equals($canonical,[StringComparison]::Ordinal)){
        throw "SM-19D canonical push URL is rewritten: expected $canonical, got $effective"
    }

    $oldErrorActionPreference=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        $rewriteOutput=@(& git -C $Repository -c core.longpaths=true config --get-regexp '^url[.].*[.]pushinsteadof$' 2>&1)
        $rewriteExit=$LASTEXITCODE
    }finally{
        $ErrorActionPreference=$oldErrorActionPreference
    }
    if($rewriteExit-ne0-and$rewriteExit-ne1){throw "Unable to inspect git pushInsteadOf configuration (exit $rewriteExit)." }
    if($rewriteExit-eq0-and@($rewriteOutput|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}).Count-ne0){
        throw 'SM-19D refuses canonical tag push while any url.*.pushInsteadOf rewrite is configured.'
    }
    $canonical
}

function Push-VllmSm19dAcceptanceTag {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag
    )
    $canonical=Get-VllmSm19dCanonicalPushUrl -Repository $Repository -RepositorySlug $RepositorySlug
    Invoke-Git -Repository $Repository -Arguments @('push',$canonical,('refs/tags/'+$Tag+':refs/tags/'+$Tag))
}
