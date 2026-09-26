Set-StrictMode -Version Latest

$script:VllmAcquisitionRepository = 'AviBackToBlack/vllm-windows-native'
$script:VllmAcquisitionRepositoryId = 1361670545
$script:VllmAcquisitionRepositoryNodeId = 'R_kgDOUSlxkQ'
$script:VllmAcquisitionCanonicalGitUrl = 'https://github.com/AviBackToBlack/vllm-windows-native.git'
$script:VllmAcquisitionApiVersion = '2026-03-10'
$script:VllmAcquisitionReceiptComponent = 'vllm-windows-native-acquisition-receipt'

function Assert-VllmAcquisitionRepository {
    param([Parameter(Mandatory)][string]$RepositorySlug)
    if(-not$RepositorySlug.Equals($script:VllmAcquisitionRepository,[StringComparison]::Ordinal)){
        throw "Unsupported acquisition repository: $RepositorySlug"
    }
}

function Assert-VllmAcquisitionTag {
    param([Parameter(Mandatory)][string]$Tag)
    if($Tag-notmatch'^release/[A-Za-z0-9][A-Za-z0-9._+-]*$'){
        throw "Acquisition tag must be an exact release/<release-id> tag: $Tag"
    }
}

function Assert-VllmAcquisitionDirectory {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label,[switch]$Create)
    $full=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetFullPath($Path))
    $root=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetPathRoot($full))
    if($full.Equals($root,[StringComparison]::OrdinalIgnoreCase)){throw "$Label must not be a volume root: $full"}
    if($Create-and-not(Test-Path -LiteralPath $full)){[void][IO.Directory]::CreateDirectory($full)}
    $entry=Get-VllmPathEntryInfo -Path $full
    if(-not$entry.Exists-or-not$entry.IsDirectory-or$entry.IsReparsePoint){throw "$Label must be a regular non-reparse directory: $full"}
    $physical=Get-VllmCanonicalExistingPath -Path $full -Format Dos
    if(-not$physical.Equals($full,[StringComparison]::OrdinalIgnoreCase)){throw "$Label resolves through a filesystem alias: $full -> $physical"}
    $full
}

function Get-VllmAcquisitionGitHubToken {
    param([string]$GhExecutable='gh')
    if(-not[string]::IsNullOrWhiteSpace($env:GH_TOKEN)){return [string]$env:GH_TOKEN}
    if($null-eq(Get-Command $GhExecutable -ErrorAction SilentlyContinue)){throw "GitHub credential bootstrap executable not found: $GhExecutable"}
    $stderr=[IO.Path]::GetTempFileName()
    $old=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        $output=@(& $GhExecutable auth token --hostname github.com 2> $stderr)
        $exit=$LASTEXITCODE
        $detail=if([IO.File]::Exists($stderr)){[IO.File]::ReadAllText($stderr).Trim()}else{''}
    }finally{
        $ErrorActionPreference=$old
        Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    }
    if($exit-ne0-or$output.Count-ne1-or[string]::IsNullOrWhiteSpace([string]$output[0])){
        if([string]::IsNullOrWhiteSpace($detail)){$detail='no GitHub.com token was available'}
        throw "Unable to obtain GitHub.com read credential: $detail"
    }
    ([string]$output[0]).Trim()
}

function Invoke-VllmAcquisitionGhCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$Executable='gh',
        [AllowNull()][scriptblock]$CommandInvoker=$null
    )
    if($null-ne$CommandInvoker){
        $result=& $CommandInvoker $Arguments $FailureLabel
        if($null-eq$result){return ''}
        return [string]$result
    }
    if($null-eq(Get-Command $Executable -ErrorAction SilentlyContinue)){throw ($FailureLabel+': executable not found: '+$Executable)}
    if([string]::IsNullOrWhiteSpace($GitHubToken)){throw ($FailureLabel+': GitHub.com token is empty.')}
    $config=Assert-VllmAcquisitionDirectory -Path $GhConfigDirectory -Label 'GitHub CLI isolation directory' -Create
    $saved=[ordered]@{}
    $names=@(Get-ChildItem Env:|Where-Object{
        $_.Name.StartsWith('GH_',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GITHUB_TOKEN',[StringComparison]::OrdinalIgnoreCase) -or
        $_.Name.Equals('GITHUB_ENTERPRISE_TOKEN',[StringComparison]::OrdinalIgnoreCase)
    }|Select-Object -ExpandProperty Name)
    foreach($name in $names){$saved[$name]=(Get-Item -LiteralPath "Env:$name").Value}
    $stderr=[IO.Path]::GetTempFileName()
    $old=$ErrorActionPreference
    try{
        foreach($name in $names){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
        $env:GH_HOST='github.com'
        $env:GH_PROMPT_DISABLED='1'
        $env:GH_CONFIG_DIR=$config
        $env:GH_TOKEN=$GitHubToken
        $ErrorActionPreference='Continue'
        $stdout=@(& $Executable @Arguments 2> $stderr)
        $exit=$LASTEXITCODE
        $err=if([IO.File]::Exists($stderr)){[IO.File]::ReadAllText($stderr).Trim()}else{''}
    }finally{
        $ErrorActionPreference=$old
        foreach($name in @(Get-ChildItem Env:|Where-Object{
            $_.Name.StartsWith('GH_',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GITHUB_TOKEN',[StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.Equals('GITHUB_ENTERPRISE_TOKEN',[StringComparison]::OrdinalIgnoreCase)
        }|Select-Object -ExpandProperty Name)){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
        foreach($name in $saved.Keys){Set-Item -LiteralPath "Env:$name" -Value $saved[$name]}
        Remove-Item -LiteralPath $stderr -Force -ErrorAction SilentlyContinue
    }
    if($exit-ne0){
        $detail=if([string]::IsNullOrWhiteSpace($err)){('exit '+$exit)}else{$err}
        throw ($FailureLabel+': '+$detail)
    }
    $stdout -join [char]10
}

function Invoke-VllmAcquisitionGhJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$Executable='gh',
        [AllowNull()][scriptblock]$CommandInvoker=$null
    )
    $json=Invoke-VllmAcquisitionGhCommand -Arguments $Arguments -FailureLabel $FailureLabel -GhConfigDirectory $GhConfigDirectory -GitHubToken $GitHubToken -Executable $Executable -CommandInvoker $CommandInvoker
    try{$json|ConvertFrom-Json}catch{throw "$FailureLabel returned invalid JSON."}
}

function Get-VllmAcquisitionApiArguments {
    param([Parameter(Mandatory)][string]$Endpoint)
    @('api','--hostname','github.com','-H','Accept: application/vnd.github+json','-H',('X-GitHub-Api-Version: '+$script:VllmAcquisitionApiVersion),$Endpoint)
}

function Assert-VllmAcquisitionRepositoryIdentity {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$GhExecutable='gh',
        [AllowNull()][scriptblock]$GhCommandInvoker=$null
    )
    Assert-VllmAcquisitionRepository -RepositorySlug $RepositorySlug
    $repo=Invoke-VllmAcquisitionGhJson -Arguments (Get-VllmAcquisitionApiArguments -Endpoint "repos/$RepositorySlug") -FailureLabel 'Unable to authenticate GitHub repository identity' -GhConfigDirectory $GhConfigDirectory -GitHubToken $GitHubToken -Executable $GhExecutable -CommandInvoker $GhCommandInvoker
    if([int64]$repo.id-ne[int64]$script:VllmAcquisitionRepositoryId){throw "GitHub repository id mismatch: $($repo.id)"}
    if(-not([string]$repo.node_id).Equals($script:VllmAcquisitionRepositoryNodeId,[StringComparison]::Ordinal)){throw "GitHub repository node id mismatch: $($repo.node_id)"}
    if(-not([string]$repo.full_name).Equals($script:VllmAcquisitionRepository,[StringComparison]::Ordinal)){throw "GitHub repository slug mismatch: $($repo.full_name)"}
    [pscustomobject][ordered]@{
        slug=$script:VllmAcquisitionRepository
        id=[int64]$script:VllmAcquisitionRepositoryId
        node_id=$script:VllmAcquisitionRepositoryNodeId
        canonical_https_url=$script:VllmAcquisitionCanonicalGitUrl
    }
}

function Get-VllmAcquisitionRemoteTagObject {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$GhExecutable='gh',
        [AllowNull()][scriptblock]$GhCommandInvoker=$null
    )
    Assert-VllmAcquisitionTag -Tag $Tag
    $escaped=[Uri]::EscapeDataString($Tag)
    $ref=Invoke-VllmAcquisitionGhJson -Arguments (Get-VllmAcquisitionApiArguments -Endpoint "repos/$RepositorySlug/git/ref/tags/$escaped") -FailureLabel 'Unable to authenticate GitHub release tag ref' -GhConfigDirectory $GhConfigDirectory -GitHubToken $GitHubToken -Executable $GhExecutable -CommandInvoker $GhCommandInvoker
    if(-not([string]$ref.object.type).Equals('tag',[StringComparison]::Ordinal)){throw 'GitHub release tag must reference an annotated tag object.'}
    $sha=[string]$ref.object.sha
    if($sha-notmatch'^[0-9a-fA-F]{40}$'){throw "GitHub release tag object id is invalid: $sha"}
    $sha.ToLowerInvariant()
}

function Test-VllmAcquisitionGitEnvironmentName {
    param([Parameter(Mandatory)][string]$Name)
    $Name.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase) -or
    $Name.Equals('SSH_ASKPASS',[StringComparison]::OrdinalIgnoreCase) -or
    $Name.Equals('SSH_ASKPASS_REQUIRE',[StringComparison]::OrdinalIgnoreCase) -or
    $Name.StartsWith('GCM_',[StringComparison]::OrdinalIgnoreCase)
}

function Invoke-VllmAcquisitionGitIsolation {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $saved=[ordered]@{}
    $names=@(Get-ChildItem Env:|Where-Object{Test-VllmAcquisitionGitEnvironmentName -Name $_.Name}|Select-Object -ExpandProperty Name)
    foreach($name in $names){$saved[$name]=(Get-Item -LiteralPath "Env:$name").Value}
    try{
        foreach($name in $names){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}
        $env:GIT_CONFIG_NOSYSTEM='1'
        $env:GIT_CONFIG_GLOBAL='NUL'
        $env:GIT_TERMINAL_PROMPT='0'
        $env:GIT_NO_REPLACE_OBJECTS='1'
        $env:GCM_INTERACTIVE='Never'
        & $Action
    }finally{
        foreach($name in @(Get-ChildItem Env:|Where-Object{Test-VllmAcquisitionGitEnvironmentName -Name $_.Name}|Select-Object -ExpandProperty Name)){
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        foreach($name in $saved.Keys){Set-Item -LiteralPath "Env:$name" -Value $saved[$name]}
    }
}

function Invoke-VllmAcquisitionGitCommand {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureLabel,
        [string]$Repository=''
    )
    if($null-eq(Get-Command git -ErrorAction SilentlyContinue)){throw ($FailureLabel+': git executable not found.')}
    $repositoryValue=$Repository
    $argumentsValue=$Arguments
    $failureLabelValue=$FailureLabel
    Invoke-VllmAcquisitionGitIsolation -Action {
        $old=$ErrorActionPreference
        try{
            $ErrorActionPreference='Continue'
            $gitArguments=New-Object System.Collections.Generic.List[string]
            if(-not[string]::IsNullOrWhiteSpace($repositoryValue)){$gitArguments.Add('-C');$gitArguments.Add([IO.Path]::GetFullPath($repositoryValue))}
            $gitArguments.Add('-c');$gitArguments.Add('core.longpaths=true')
            $gitArguments.Add('-c');$gitArguments.Add('core.hooksPath=NUL')
            $gitArguments.Add('-c');$gitArguments.Add('credential.helper=')
            $gitArguments.Add('-c');$gitArguments.Add('http.sslVerify=true')
            foreach($arg in $argumentsValue){$gitArguments.Add($arg)}
            $output=@(& git @($gitArguments.ToArray()) 2>&1)
            $exit=$LASTEXITCODE
        }finally{
            $ErrorActionPreference=$old
        }
        if($exit-ne0){throw ($failureLabelValue+': '+($output -join ' '))}
        $output -join [char]10
    }
}

function Initialize-VllmAcquisitionGitRepository {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$GitSourceUrl
    )
    Assert-VllmAcquisitionTag -Tag $Tag
    $repo=[IO.Path]::GetFullPath($Path)
    if(Test-Path -LiteralPath $repo){throw "Acquisition Git repository path already exists: $repo"}
    $null=Invoke-VllmAcquisitionGitCommand -Arguments @('init','--bare',$repo) -FailureLabel 'Unable to initialize isolated acquisition Git repository'
    $refspec='refs/tags/'+$Tag+':refs/tags/'+$Tag
    $null=Invoke-VllmAcquisitionGitCommand -Repository $repo -Arguments @('fetch','--no-tags','--no-write-fetch-head','--force',$GitSourceUrl,$refspec) -FailureLabel 'Unable to fetch exact release tag'
    $tagObject=(Invoke-VllmAcquisitionGitCommand -Repository $repo -Arguments @('rev-parse',"refs/tags/$Tag") -FailureLabel 'Unable to resolve fetched release tag').Trim()
    if($tagObject-notmatch'^[0-9a-fA-F]{40}$'){throw "Fetched release tag object id is invalid: $tagObject"}
    [pscustomobject][ordered]@{path=$repo;tag_object=$tagObject.ToLowerInvariant()}
}

function Resolve-VllmAcquisitionReleaseContext {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$Tag
    )
    $tree=Invoke-VllmAcquisitionGitCommand -Repository $Repository -Arguments @('ls-tree','-r','--name-only',$ProjectCommit,'--','manifests/release') -FailureLabel 'Unable to enumerate authenticated release manifests'
    $paths=@($tree -split [char]10|ForEach-Object{$_.Trim()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)-and$_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)})
    $snapshot=Get-VllmReleaseGitSnapshot -Repository $Repository -Commit $ProjectCommit
    try{
        $releaseMatches=New-Object System.Collections.Generic.List[object]
        foreach($path in $paths){
            try{
                $file=Get-VllmReleaseSnapshotFile -Snapshot $snapshot -RelativePath $path
                $json=Read-VllmReleaseUtf8NoBomStream -Stream $file.Stream -Label "Release manifest candidate $path"
                $candidate=$json|ConvertFrom-Json
            }catch{continue}
            if($null-eq$candidate.PSObject.Properties['schema_version']-or[int]$candidate.schema_version-ne1){continue}
            if($null-eq$candidate.PSObject.Properties['component']-or-not([string]$candidate.component).Equals('runtime-release',[StringComparison]::Ordinal)){continue}
            if($null-eq$candidate.PSObject.Properties['platform']-or-not([string]$candidate.platform).Equals('windows-x86_64',[StringComparison]::Ordinal)){continue}
            if($null-eq$candidate.PSObject.Properties['release']){continue}
            if(-not("release/"+[string]$candidate.release).Equals($Tag,[StringComparison]::Ordinal)){continue}
            if($null-eq$candidate.PSObject.Properties['self_path']-or-not([string]$candidate.self_path).Equals($path,[StringComparison]::Ordinal)){continue}
            $context=Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $path
            $releaseMatches.Add([pscustomobject][ordered]@{
                release=[string]$context.Release.release
                tag=[string]$context.Tag
                project_commit=[string]$snapshot.Commit
                release_manifest_path=$path
                release_manifest_sha256=[string]$context.ReleaseManifest.Sha256
                runtime_manifest_sha256=[string]$context.RuntimeManifest.Sha256
                wheel_filename=[string]$context.Release.wheel.filename
                wheel_size=[int64]$context.Release.wheel.size_bytes
                wheel_sha256=([string]$context.Release.wheel.sha256).ToUpperInvariant()
                bundle_filename=[string]$context.BundleFilename
            })
        }
        if($releaseMatches.Count-ne1){throw "Authenticated tag must resolve to exactly one matching release manifest; found $($releaseMatches.Count)."}
        $releaseMatches[0]
    }finally{
        Close-VllmReleaseGitSnapshot -Snapshot $snapshot
    }
}

function Get-VllmAcquisitionExpectedAssetNames {
    param([Parameter(Mandatory)]$ReleaseContext)
    @([string]$ReleaseContext.wheel_filename,[string]$ReleaseContext.bundle_filename,'release-index.json','SHA256SUMS')
}

function Get-VllmAcquisitionRemoteRelease {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$GhExecutable='gh',
        [AllowNull()][scriptblock]$GhCommandInvoker=$null
    )
    $escaped=[Uri]::EscapeDataString($Tag)
    $release=Invoke-VllmAcquisitionGhJson -Arguments (Get-VllmAcquisitionApiArguments -Endpoint "repos/$RepositorySlug/releases/tags/$escaped") -FailureLabel 'Unable to inspect immutable GitHub release' -GhConfigDirectory $GhConfigDirectory -GitHubToken $GitHubToken -Executable $GhExecutable -CommandInvoker $GhCommandInvoker
    if(-not([string]$release.tag_name).Equals($Tag,[StringComparison]::Ordinal)){throw 'GitHub release tag identity mismatch.'}
    if($release.draft-eq$true){throw 'Acquisition refuses a draft GitHub release.'}
    if($release.immutable-ne$true){throw 'Acquisition requires an immutable GitHub release.'}
    $expected=[string[]](Get-VllmAcquisitionExpectedAssetNames -ReleaseContext $ReleaseContext)
    $remote=@($release.assets)
    if($remote.Count-ne4){throw "Immutable GitHub release must contain exactly four assets, got $($remote.Count)."}
    $seenExact=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenWindows=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $plan=New-Object System.Collections.Generic.List[object]
    foreach($asset in $remote){
        $name=[string]$asset.name
        if([string]::IsNullOrWhiteSpace($name)-or-not([IO.Path]::GetFileName($name)).Equals($name,[StringComparison]::Ordinal)-or$name.IndexOfAny([char[]]'*?[]')-ge0){throw "GitHub release asset name is unsafe: $name"}
        if(-not$seenExact.Add($name)-or-not$seenWindows.Add($name)){throw "GitHub release contains a duplicate or case-colliding asset: $name"}
        $assetMatches=@($expected|Where-Object{([string]$_).Equals($name,[StringComparison]::Ordinal)})
        if($assetMatches.Count-ne1){throw "GitHub release contains an unexpected asset: $name"}
        if(-not([string]$asset.state).Equals('uploaded',[StringComparison]::Ordinal)){throw "GitHub release asset is not fully uploaded: $name"}
        $digest=[string]$asset.digest
        if($digest-notmatch'^sha256:[0-9A-Fa-f]{64}$'){throw "GitHub release asset digest is invalid: $name"}
        if([int64]$asset.size-lt0){throw "GitHub release asset size is invalid: $name"}
        $plan.Add([pscustomobject][ordered]@{name=$name;size=[int64]$asset.size;sha256=$digest.Substring(7).ToUpperInvariant()})
    }
    foreach($name in $expected){if(-not$seenExact.Contains($name)){throw "GitHub release asset set is incomplete: $name"}}
    $wheel=@($plan|Where-Object{$_.name.Equals([string]$ReleaseContext.wheel_filename,[StringComparison]::Ordinal)})[0]
    if($wheel.size-ne[int64]$ReleaseContext.wheel_size-or-not([string]$wheel.sha256).Equals([string]$ReleaseContext.wheel_sha256,[StringComparison]::OrdinalIgnoreCase)){throw 'GitHub release wheel metadata does not match the authenticated release manifest.'}
    [pscustomobject][ordered]@{release=$release;assets=$plan.ToArray()}
}

function Invoke-VllmAcquisitionDownloadAssets {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$ArtifactsDirectory,
        [Parameter(Mandatory)][string]$GhConfigDirectory,
        [Parameter(Mandatory)][string]$GitHubToken,
        [string]$GhExecutable='gh',
        [AllowNull()][scriptblock]$GhCommandInvoker=$null
    )
    $root=Assert-VllmAcquisitionDirectory -Path $ArtifactsDirectory -Label 'Acquisition artifact staging directory' -Create
    if(@(Get-ChildItem -LiteralPath $root -Force).Count-ne0){throw 'Acquisition artifact staging directory must start empty.'}
    foreach($name in $ExpectedNames){
        $null=Invoke-VllmAcquisitionGhCommand -Arguments @('release','download',$Tag,'--repo',$RepositorySlug,'--pattern',$name,'--dir',$root) -FailureLabel "Unable to download GitHub release asset $name" -GhConfigDirectory $GhConfigDirectory -GitHubToken $GitHubToken -Executable $GhExecutable -CommandInvoker $GhCommandInvoker
        $path=Join-Path $root $name
        $entry=Get-VllmPathEntryInfo -Path $path
        if(-not$entry.Exists-or$entry.IsDirectory-or$entry.IsReparsePoint){throw "Downloaded release asset is not a regular file: $name"}
    }
    $actual=Get-VllmReleaseOrdinalStrings -Values @((Get-ChildItem -LiteralPath $root -Force)|ForEach-Object{$_.Name})
    $expected=Get-VllmReleaseOrdinalStrings -Values $ExpectedNames
    Assert-VllmReleaseOrdinalSequence -Actual $actual -Expected $expected -Label 'Downloaded release asset filename set'
    $root
}

function Get-VllmAcquisitionLocalAssetPlan {
    param([Parameter(Mandatory)][string]$ArtifactsDirectory,[Parameter(Mandatory)]$OfflineVerification)
    $digests=Get-VllmReleaseExpectedAssets -ArtifactsDirectory $ArtifactsDirectory -OfflineVerification $OfflineVerification
    $plan=New-Object System.Collections.Generic.List[object]
    foreach($name in $digests.Keys){
        $path=Join-Path ([IO.Path]::GetFullPath($ArtifactsDirectory)) ([string]$name)
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer-or$item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Verified local release asset is not a regular file: $name"}
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if(-not$actual.Equals([string]$digests[$name],[StringComparison]::OrdinalIgnoreCase)){throw "Verified local release asset changed after offline verification: $name"}
        $plan.Add([pscustomobject][ordered]@{name=[string]$name;path=$item.FullName;size=[int64]$item.Length;sha256=$actual.ToUpperInvariant()})
    }
    if($plan.Count-ne4){throw "Verified local release requires exactly four assets, got $($plan.Count)."}
    return $plan.ToArray()
}

function Assert-VllmAcquisitionRemoteAssetsMatchLocal {
    param([Parameter(Mandatory)][object[]]$RemoteAssets,[Parameter(Mandatory)][object[]]$LocalAssets)
    if($RemoteAssets.Count-ne4-or$LocalAssets.Count-ne4){throw 'Remote/local acquisition asset count mismatch.'}
    foreach($local in $LocalAssets){
        $remoteMatches=@($RemoteAssets|Where-Object{([string]$_.name).Equals([string]$local.name,[StringComparison]::Ordinal)})
        if($remoteMatches.Count-ne1){throw "Remote release metadata is missing verified local asset: $($local.name)"}
        $remote=$remoteMatches[0]
        if([int64]$remote.size-ne[int64]$local.size){throw "Remote release asset size mismatch after download: $($local.name)"}
        if(-not([string]$remote.sha256).Equals([string]$local.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Remote release asset digest mismatch after download: $($local.name)"}
    }
    $true
}

function ConvertTo-VllmAcquisitionReceiptArtifact {
    param([Parameter(Mandatory)]$Asset)
    [ordered]@{filename=[string]$Asset.name;size_bytes=[int64]$Asset.size;sha256=([string]$Asset.sha256).ToUpperInvariant()}
}

function Get-VllmAcquisitionReceipt {
    param(
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)]$SignedTag,
        [Parameter(Mandatory)][object[]]$LocalAssets,
        [Parameter(Mandatory)]$GitHubVerification
    )
    $byName=@{};foreach($asset in $LocalAssets){$byName[[string]$asset.name]=$asset}
    [ordered]@{
        schema_version=1
        component=$script:VllmAcquisitionReceiptComponent
        verified_utc=[DateTimeOffset]::UtcNow.ToString('o')
        repository=[ordered]@{
            slug=[string]$RepositoryIdentity.slug
            id=[int64]$RepositoryIdentity.id
            node_id=[string]$RepositoryIdentity.node_id
            canonical_https_url=[string]$RepositoryIdentity.canonical_https_url
        }
        release=[ordered]@{
            release=[string]$ReleaseContext.release
            tag=[string]$ReleaseContext.tag
            tag_object=([string]$SignedTag.tag_object).ToLowerInvariant()
            project_commit=([string]$SignedTag.project_commit).ToLowerInvariant()
            release_manifest_path=[string]$ReleaseContext.release_manifest_path
            release_manifest_sha256=([string]$ReleaseContext.release_manifest_sha256).ToUpperInvariant()
            runtime_manifest_sha256=([string]$ReleaseContext.runtime_manifest_sha256).ToUpperInvariant()
        }
        signing=[ordered]@{principal=[string]$SignedTag.principal;key_fingerprint=[string]$SignedTag.key_fingerprint}
        artifacts=[ordered]@{
            wheel=ConvertTo-VllmAcquisitionReceiptArtifact -Asset $byName[[string]$ReleaseContext.wheel_filename]
            bundle=ConvertTo-VllmAcquisitionReceiptArtifact -Asset $byName[[string]$ReleaseContext.bundle_filename]
            index=ConvertTo-VllmAcquisitionReceiptArtifact -Asset $byName['release-index.json']
            checksums=ConvertTo-VllmAcquisitionReceiptArtifact -Asset $byName['SHA256SUMS']
        }
        verification=[ordered]@{
            offline_release_schema=1
            github_release_attestation_schema=[int]$GitHubVerification.schema_version
            per_asset_attestation_count=[int]$GitHubVerification.asset_count
        }
    }
}

function Assert-VllmAcquisitionReceiptSchema {
    param([Parameter(Mandatory)]$Receipt)
    Assert-VllmReleaseExactProperties -Value $Receipt -Expected @('schema_version','component','verified_utc','repository','release','signing','artifacts','verification') -Label 'Acquisition receipt'
    Assert-VllmReleaseExactProperties -Value $Receipt.repository -Expected @('slug','id','node_id','canonical_https_url') -Label 'Acquisition receipt repository'
    Assert-VllmReleaseExactProperties -Value $Receipt.release -Expected @('release','tag','tag_object','project_commit','release_manifest_path','release_manifest_sha256','runtime_manifest_sha256') -Label 'Acquisition receipt release'
    Assert-VllmReleaseExactProperties -Value $Receipt.signing -Expected @('principal','key_fingerprint') -Label 'Acquisition receipt signing'
    Assert-VllmReleaseExactProperties -Value $Receipt.artifacts -Expected @('wheel','bundle','index','checksums') -Label 'Acquisition receipt artifacts'
    foreach($name in @('wheel','bundle','index','checksums')){Assert-VllmReleaseExactProperties -Value $Receipt.artifacts.$name -Expected @('filename','size_bytes','sha256') -Label "Acquisition receipt artifact $name"}
    Assert-VllmReleaseExactProperties -Value $Receipt.verification -Expected @('offline_release_schema','github_release_attestation_schema','per_asset_attestation_count') -Label 'Acquisition receipt verification'
    if([int]$Receipt.schema_version-ne1-or-not([string]$Receipt.component).Equals($script:VllmAcquisitionReceiptComponent,[StringComparison]::Ordinal)){throw 'Acquisition receipt schema/component is unsupported.'}
    if([string]::IsNullOrWhiteSpace([string]$Receipt.verified_utc)){throw 'Acquisition receipt verified_utc is missing.'}
    if([int64]$Receipt.repository.id-ne[int64]$script:VllmAcquisitionRepositoryId-or-not([string]$Receipt.repository.slug).Equals($script:VllmAcquisitionRepository,[StringComparison]::Ordinal)-or-not([string]$Receipt.repository.node_id).Equals($script:VllmAcquisitionRepositoryNodeId,[StringComparison]::Ordinal)-or-not([string]$Receipt.repository.canonical_https_url).Equals($script:VllmAcquisitionCanonicalGitUrl,[StringComparison]::Ordinal)){throw 'Acquisition receipt repository identity mismatch.'}
    Assert-VllmAcquisitionTag -Tag ([string]$Receipt.release.tag)
    if([string]$Receipt.release.tag_object-notmatch'^[0-9a-fA-F]{40}$'-or[string]$Receipt.release.project_commit-notmatch'^[0-9a-fA-F]{40}$'){throw 'Acquisition receipt Git identity is invalid.'}
    foreach($digest in @([string]$Receipt.release.release_manifest_sha256,[string]$Receipt.release.runtime_manifest_sha256)){if($digest-notmatch'^[0-9A-Fa-f]{64}$'){throw 'Acquisition receipt manifest digest is invalid.'}}
    foreach($name in @('wheel','bundle','index','checksums')){
        $a=$Receipt.artifacts.$name
        $filename=[string]$a.filename
        if([string]::IsNullOrWhiteSpace($filename)-or-not([IO.Path]::GetFileName($filename)).Equals($filename,[StringComparison]::Ordinal)){throw "Acquisition receipt artifact filename is unsafe: $filename"}
        if([int64]$a.size_bytes-lt0-or[string]$a.sha256-notmatch'^[0-9A-Fa-f]{64}$'){throw "Acquisition receipt artifact identity is invalid: $filename"}
    }
    if([int]$Receipt.verification.offline_release_schema-ne1-or[int]$Receipt.verification.github_release_attestation_schema-ne1-or[int]$Receipt.verification.per_asset_attestation_count-ne4){throw 'Acquisition receipt verification summary is invalid.'}
    $true
}

function Read-VllmAcquisitionReceipt {
    param([Parameter(Mandatory)][string]$Path)
    $entry=Get-VllmPathEntryInfo -Path $Path
    if(-not$entry.Exists-or$entry.IsDirectory-or$entry.IsReparsePoint){throw "Acquisition receipt is missing or unsafe: $Path"}
    try{$receipt=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}catch{throw "Acquisition receipt is invalid JSON: $Path"}
    $null=Assert-VllmAcquisitionReceiptSchema -Receipt $receipt
    $receipt
}

function Enter-VllmAcquisitionCacheLock {
    param([Parameter(Mandatory)][string]$RepositoryCacheRoot,[Parameter(Mandatory)][string]$Operation)
    $root=Assert-VllmAcquisitionDirectory -Path $RepositoryCacheRoot -Label 'Acquisition repository cache' -Create
    $path=Join-Path $root '.acquisition.lock'
    try{$stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{throw "Another release acquisition cache commit is active for repository $($script:VllmAcquisitionRepositoryId)."}
    try{
        $entry=Get-VllmPathEntryInfo -Path $path
        if(-not$entry.Exists-or$entry.IsDirectory-or$entry.IsReparsePoint){throw "Acquisition lock path is unsafe: $path"}
        $rootGuid=Get-VllmPathWithoutTrailingSeparator (Get-VllmPhysicalCandidatePath -Path $root -Format Guid)
        $expected=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootGuid,'.acquisition.lock'))
        $actual=Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if(-not$actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw "Acquisition lock handle resolves outside expected path: $actual"}
        if([VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)-ne1){throw 'Acquisition lock has an unexpected hard-link count.'}
        $stream.SetLength(0)
        $writer=New-Object IO.StreamWriter($stream,[Text.UTF8Encoding]::new($false),1024,$true)
        try{$writer.WriteLine("operation=$Operation");$writer.WriteLine("pid=$PID");$writer.Flush();$stream.Flush()}finally{$writer.Dispose()}
        [pscustomobject][ordered]@{stream=$stream;path=$path;root=$root}
    }catch{$stream.Dispose();throw}
}

function Exit-VllmAcquisitionCacheLock {
    param([AllowNull()]$Lock)
    if($null-ne$Lock-and$null-ne$Lock.stream){$Lock.stream.Dispose()}
}

function Assert-VllmAcquisitionNoSameTagConflict {
    param([Parameter(Mandatory)][string]$RepositoryCacheRoot,[Parameter(Mandatory)][string]$Tag,[Parameter(Mandatory)][string]$TagObject)
    foreach($dir in @(Get-ChildItem -LiteralPath $RepositoryCacheRoot -Force -Directory)){
        if($dir.Name-notmatch'^[0-9a-fA-F]{40}$'){continue}
        $receiptPath=Join-Path $dir.FullName 'acquisition-receipt.json'
        $entry=Get-VllmPathEntryInfo -Path $receiptPath
        if(-not$entry.Exists-or$entry.IsDirectory-or$entry.IsReparsePoint){continue}
        try{$receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json;$null=Assert-VllmAcquisitionReceiptSchema -Receipt $receipt}catch{continue}
        if(([string]$receipt.release.tag).Equals($Tag,[StringComparison]::Ordinal)-and-not([string]$receipt.release.tag_object).Equals($TagObject,[StringComparison]::OrdinalIgnoreCase)){
            throw "Verified acquisition cache contains the same tag bound to a different tag object: $Tag"
        }
    }
    $true
}

function Get-VllmAcquisitionReceiptAssetMap {
    param([Parameter(Mandatory)]$Receipt)
    [ordered]@{
        ([string]$Receipt.artifacts.wheel.filename)=$Receipt.artifacts.wheel
        ([string]$Receipt.artifacts.bundle.filename)=$Receipt.artifacts.bundle
        ([string]$Receipt.artifacts.index.filename)=$Receipt.artifacts.index
        ([string]$Receipt.artifacts.checksums.filename)=$Receipt.artifacts.checksums
    }
}

function Assert-VllmAcquisitionCacheEntry {
    param(
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$ReleaseContext,
        [Parameter(Mandatory)]$SignedTag,
        [Parameter(Mandatory)][object[]]$RemoteAssets
    )
    $root=Assert-VllmAcquisitionDirectory -Path $EntryPath -Label 'Verified acquisition cache entry'
    $receipt=Read-VllmAcquisitionReceipt -Path (Join-Path $root 'acquisition-receipt.json')
    if(-not([string]$receipt.release.tag).Equals([string]$ReleaseContext.tag,[StringComparison]::Ordinal)-or-not([string]$receipt.release.tag_object).Equals([string]$SignedTag.tag_object,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$receipt.release.project_commit).Equals([string]$SignedTag.project_commit,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition cache receipt release identity mismatch.'}
    if(-not([string]$receipt.release.release).Equals([string]$ReleaseContext.release,[StringComparison]::Ordinal)-or-not([string]$receipt.release.release_manifest_path).Equals([string]$ReleaseContext.release_manifest_path,[StringComparison]::Ordinal)-or-not([string]$receipt.release.release_manifest_sha256).Equals([string]$ReleaseContext.release_manifest_sha256,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$receipt.release.runtime_manifest_sha256).Equals([string]$ReleaseContext.runtime_manifest_sha256,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition cache receipt manifest identity mismatch.'}
    if(-not([string]$receipt.signing.principal).Equals([string]$SignedTag.principal,[StringComparison]::Ordinal)-or-not([string]$receipt.signing.key_fingerprint).Equals([string]$SignedTag.key_fingerprint,[StringComparison]::Ordinal)){throw 'Acquisition cache receipt signer identity mismatch.'}
    $artifacts=Assert-VllmAcquisitionDirectory -Path (Join-Path $root 'artifacts') -Label 'Verified acquisition artifact directory'
    $expectedNames=[string[]](Get-VllmAcquisitionExpectedAssetNames -ReleaseContext $ReleaseContext)
    $actual=Get-VllmReleaseOrdinalStrings -Values @((Get-ChildItem -LiteralPath $artifacts -Force)|ForEach-Object{$_.Name})
    $expected=Get-VllmReleaseOrdinalStrings -Values $expectedNames
    Assert-VllmReleaseOrdinalSequence -Actual $actual -Expected $expected -Label 'Verified acquisition cache asset filename set'
    $offline=Invoke-VllmAcquisitionGitIsolation -Action { Assert-VllmOfflineRelease -Repository $Repository -ProjectCommit ([string]$SignedTag.project_commit) -ReleaseManifestPath ([string]$ReleaseContext.release_manifest_path) -ArtifactsDirectory $artifacts }
    $assetMap=Get-VllmAcquisitionReceiptAssetMap -Receipt $receipt
    $local=New-Object System.Collections.Generic.List[object]
    foreach($name in $expectedNames){
        if(-not$assetMap.Contains($name)){throw "Acquisition receipt does not describe expected asset: $name"}
        $path=Join-Path $artifacts $name
        $item=Get-Item -LiteralPath $path -Force
        if($item.PSIsContainer-or$item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Cached acquisition asset is unsafe: $name"}
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $record=$assetMap[$name]
        if([int64]$item.Length-ne[int64]$record.size_bytes-or-not$hash.Equals([string]$record.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Cached acquisition asset identity mismatch: $name"}
        $local.Add([pscustomobject][ordered]@{name=$name;path=$path;size=[int64]$item.Length;sha256=$hash.ToUpperInvariant()})
    }
    $null=Assert-VllmAcquisitionRemoteAssetsMatchLocal -RemoteAssets $RemoteAssets -LocalAssets $local.ToArray()
    if(-not([string]$offline.wheel_sha256).Equals([string]$receipt.artifacts.wheel.sha256,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$offline.bundle_sha256).Equals([string]$receipt.artifacts.bundle.sha256,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$offline.index_sha256).Equals([string]$receipt.artifacts.index.sha256,[StringComparison]::OrdinalIgnoreCase)-or-not([string]$offline.checksums_sha256).Equals([string]$receipt.artifacts.checksums.sha256,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition cache receipt disagrees with complete offline verification.'}
    [pscustomobject][ordered]@{
        schema_version=1
        component='vllm-windows-native-acquisition'
        repository=$script:VllmAcquisitionRepository
        release=[string]$ReleaseContext.release
        tag=[string]$ReleaseContext.tag
        tag_object=([string]$SignedTag.tag_object).ToLowerInvariant()
        project_commit=([string]$SignedTag.project_commit).ToLowerInvariant()
        cache_entry=$root
        artifacts_directory=$artifacts
        wheel_path=(Join-Path $artifacts ([string]$ReleaseContext.wheel_filename))
        bundle_path=(Join-Path $artifacts ([string]$ReleaseContext.bundle_filename))
        release_index_path=(Join-Path $artifacts 'release-index.json')
        checksums_path=(Join-Path $artifacts 'SHA256SUMS')
        receipt_path=(Join-Path $root 'acquisition-receipt.json')
        release_manifest_path=[string]$ReleaseContext.release_manifest_path
    }
}

function Write-VllmAcquisitionReceipt {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Receipt)
    $validator={param($candidate,$candidatePath)$null=$candidatePath;$null=Assert-VllmAcquisitionReceiptSchema -Receipt $candidate}
    Write-VllmAtomicJsonFile -Path $Path -Value $Receipt -Depth 16 -Validate $validator
}

function Invoke-VllmReleaseAcquisition {
    param(
        [Parameter(Mandatory)][string]$RepositorySlug,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$AllowedSignersPath,
        [Parameter(Mandatory)][string]$CacheRoot,
        [string]$GhExecutable='gh',
        [string]$GitHubToken='',
        [string]$GitSourceUrl=$script:VllmAcquisitionCanonicalGitUrl,
        [string]$ExpectedPrincipal=$script:VllmReleasePrincipal,
        [string]$ExpectedFingerprint=$script:VllmReleaseKeyFingerprint,
        [AllowNull()][scriptblock]$GhCommandInvoker=$null,
        [ValidateSet('None','AfterDownload','BeforeCachePublish','AfterCachePublish')][string]$FaultPoint='None'
    )
    Assert-VllmAcquisitionRepository -RepositorySlug $RepositorySlug
    Assert-VllmAcquisitionTag -Tag $Tag
    $trustPath=[IO.Path]::GetFullPath($AllowedSignersPath)
    $null=Assert-VllmReleaseAllowedSigners -Path $trustPath -ExpectedPrincipal $ExpectedPrincipal -ExpectedFingerprint $ExpectedFingerprint
    $cache=Assert-VllmAcquisitionDirectory -Path $CacheRoot -Label 'Acquisition cache root' -Create
    $stagingParent=Assert-VllmAcquisitionDirectory -Path (Join-Path $cache '.staging') -Label 'Acquisition staging root' -Create
    $verifiedRoot=Assert-VllmAcquisitionDirectory -Path (Join-Path $cache 'verified') -Label 'Acquisition verified root' -Create
    $repoCache=Assert-VllmAcquisitionDirectory -Path (Join-Path $verifiedRoot ([string]$script:VllmAcquisitionRepositoryId)) -Label 'Acquisition repository cache' -Create
    if([string]::IsNullOrWhiteSpace($GitHubToken)){$GitHubToken=Get-VllmAcquisitionGitHubToken -GhExecutable $GhExecutable}
    $generation=Join-Path $stagingParent ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($generation)
    $generation=Assert-VllmAcquisitionDirectory -Path $generation -Label 'Acquisition generation'
    $gitRepo=Join-Path $generation 'git'
    $ghConfig=Assert-VllmAcquisitionDirectory -Path (Join-Path $generation 'gh-config') -Label 'GitHub CLI isolation directory' -Create
    $candidate=Assert-VllmAcquisitionDirectory -Path (Join-Path $generation 'candidate') -Label 'Acquisition candidate directory' -Create
    $artifacts=Assert-VllmAcquisitionDirectory -Path (Join-Path $candidate 'artifacts') -Label 'Acquisition candidate artifacts' -Create
    try{
        $repoIdentity=Assert-VllmAcquisitionRepositoryIdentity -RepositorySlug $RepositorySlug -GhConfigDirectory $ghConfig -GitHubToken $GitHubToken -GhExecutable $GhExecutable -GhCommandInvoker $GhCommandInvoker
        $remoteTagObject=Get-VllmAcquisitionRemoteTagObject -RepositorySlug $RepositorySlug -Tag $Tag -GhConfigDirectory $ghConfig -GitHubToken $GitHubToken -GhExecutable $GhExecutable -GhCommandInvoker $GhCommandInvoker
        $git=Initialize-VllmAcquisitionGitRepository -Path $gitRepo -Tag $Tag -GitSourceUrl $GitSourceUrl
        if(-not([string]$git.tag_object).Equals($remoteTagObject,[StringComparison]::OrdinalIgnoreCase)){throw "Fetched tag object does not match authenticated GitHub tag object: fetched=$($git.tag_object), remote=$remoteTagObject"}
        $commitRef="refs/tags/$Tag"+'^{commit}'
        $peeled=(Invoke-VllmAcquisitionGitCommand -Repository $gitRepo -Arguments @('rev-parse',$commitRef) -FailureLabel 'Unable to peel authenticated release tag').Trim().ToLowerInvariant()
        $signed=Assert-VllmReleaseSignedTag -Repository $gitRepo -Tag $Tag -ExpectedCommit $peeled -AllowedSignersPath $trustPath -ExpectedPrincipal $ExpectedPrincipal -ExpectedFingerprint $ExpectedFingerprint
        if(-not([string]$signed.tag_object).Equals($remoteTagObject,[StringComparison]::OrdinalIgnoreCase)){throw 'Signed-tag verification returned a different tag object than authenticated GitHub.'}
        $context=Invoke-VllmAcquisitionGitIsolation -Action { Resolve-VllmAcquisitionReleaseContext -Repository $gitRepo -ProjectCommit ([string]$signed.project_commit) -Tag $Tag }
        $remote=Get-VllmAcquisitionRemoteRelease -RepositorySlug $RepositorySlug -Tag $Tag -ReleaseContext $context -GhConfigDirectory $ghConfig -GitHubToken $GitHubToken -GhExecutable $GhExecutable -GhCommandInvoker $GhCommandInvoker
        $destination=Join-Path $repoCache $remoteTagObject
        $lock=$null
        try{
            $lock=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $repoCache -Operation 'cache-check'
            $null=Assert-VllmAcquisitionNoSameTagConflict -RepositoryCacheRoot $repoCache -Tag $Tag -TagObject $remoteTagObject
            if(Test-Path -LiteralPath $destination){
                return Assert-VllmAcquisitionCacheEntry -EntryPath $destination -Repository $gitRepo -ReleaseContext $context -SignedTag $signed -RemoteAssets $remote.assets
            }
        }finally{Exit-VllmAcquisitionCacheLock -Lock $lock}
        $expectedNames=[string[]](Get-VllmAcquisitionExpectedAssetNames -ReleaseContext $context)
        $null=Invoke-VllmAcquisitionDownloadAssets -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedNames $expectedNames -ArtifactsDirectory $artifacts -GhConfigDirectory $ghConfig -GitHubToken $GitHubToken -GhExecutable $GhExecutable -GhCommandInvoker $GhCommandInvoker
        if($FaultPoint-eq'AfterDownload'){throw 'FAULT_INJECTED:AfterDownload'}
        $offline=Invoke-VllmAcquisitionGitIsolation -Action { Assert-VllmOfflineRelease -Repository $gitRepo -ProjectCommit ([string]$signed.project_commit) -ReleaseManifestPath ([string]$context.release_manifest_path) -ArtifactsDirectory $artifacts }
        $localAssets=[object[]](Get-VllmAcquisitionLocalAssetPlan -ArtifactsDirectory $artifacts -OfflineVerification $offline)
        $null=Assert-VllmAcquisitionRemoteAssetsMatchLocal -RemoteAssets $remote.assets -LocalAssets $localAssets
        $ghInvoker={
            param($arguments,$failureLabel)
            Invoke-VllmAcquisitionGhCommand -Arguments ([string[]]$arguments) -FailureLabel ([string]$failureLabel) -GhConfigDirectory $ghConfig -GitHubToken $GitHubToken -Executable $GhExecutable -CommandInvoker $GhCommandInvoker
        }
        $expectedAssets=Get-VllmReleaseExpectedAssets -ArtifactsDirectory $artifacts -OfflineVerification $offline
        $githubVerification=Invoke-VllmGitHubReleaseVerification -RepositorySlug $RepositorySlug -Tag $Tag -ExpectedTagObject $remoteTagObject -ArtifactsDirectory $artifacts -ExpectedAssets $expectedAssets -GhExecutable $GhExecutable -GhJsonInvoker $ghInvoker
        $receipt=Get-VllmAcquisitionReceipt -RepositoryIdentity $repoIdentity -ReleaseContext $context -SignedTag $signed -LocalAssets $localAssets -GitHubVerification $githubVerification
        $null=Write-VllmAcquisitionReceipt -Path (Join-Path $candidate 'acquisition-receipt.json') -Receipt $receipt
        if($FaultPoint-eq'BeforeCachePublish'){throw 'FAULT_INJECTED:BeforeCachePublish'}
        $lock=$null
        try{
            $lock=Enter-VllmAcquisitionCacheLock -RepositoryCacheRoot $repoCache -Operation 'cache-publish'
            $null=Assert-VllmAcquisitionNoSameTagConflict -RepositoryCacheRoot $repoCache -Tag $Tag -TagObject $remoteTagObject
            if(Test-Path -LiteralPath $destination){
                return Assert-VllmAcquisitionCacheEntry -EntryPath $destination -Repository $gitRepo -ReleaseContext $context -SignedTag $signed -RemoteAssets $remote.assets
            }
            [IO.Directory]::Move($candidate,$destination)
            if($FaultPoint-eq'AfterCachePublish'){throw 'FAULT_INJECTED:AfterCachePublish'}
            return Assert-VllmAcquisitionCacheEntry -EntryPath $destination -Repository $gitRepo -ReleaseContext $context -SignedTag $signed -RemoteAssets $remote.assets
        }finally{Exit-VllmAcquisitionCacheLock -Lock $lock}
    }finally{
        if(Test-Path -LiteralPath $generation){Remove-Item -LiteralPath $generation -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
