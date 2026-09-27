Set-StrictMode -Version Latest

$script:VllmSm20eRepositorySlug='AviBackToBlack/vllm-windows-native'
$script:VllmSm20eRelease='sm20e-acceptance-20260927-01'
$script:VllmSm20eTag='release/'+$script:VllmSm20eRelease
$script:VllmSm20ePrincipal='vllm-windows-native-sm20e-acceptance'
$script:VllmSm20eReleaseManifestPath='manifests/release/'+$script:VllmSm20eRelease+'.json'
$script:VllmSm20eRuntimeManifestPath='manifests/runtime/'+$script:VllmSm20eRelease+'.json'
$script:VllmSm20eWheelVersion='0.0.0+sm20e.20260927'
$script:VllmSm20eWheelName='vllm-'+$script:VllmSm20eWheelVersion+'-cp313-cp313-win_amd64.whl'
$script:VllmSm20eWheelSize=[int64]815
$script:VllmSm20eWheelSha256='908E763E762A2A6CE392B0E9DB04FA0F5AFD614F16A15AB805DE61D3BD6E8481'
$script:VllmSm20eStateFile='sm20e-acceptance-state.json'

function Get-VllmSm20eIdentity {
    [pscustomobject][ordered]@{
        repository=$script:VllmSm20eRepositorySlug
        release=$script:VllmSm20eRelease
        tag=$script:VllmSm20eTag
        principal=$script:VllmSm20ePrincipal
        release_manifest_path=$script:VllmSm20eReleaseManifestPath
        runtime_manifest_path=$script:VllmSm20eRuntimeManifestPath
        wheel_filename=$script:VllmSm20eWheelName
        wheel_size=[int64]$script:VllmSm20eWheelSize
        wheel_sha256=$script:VllmSm20eWheelSha256
    }
}

function New-VllmSm20eSyntheticWheel {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$Path)
    $resolved=[IO.Path]::GetFullPath($Path)
    if(-not([IO.Path]::GetFileName($resolved)).Equals($script:VllmSm20eWheelName,[StringComparison]::Ordinal)){
        throw "SM-20E wheel path must end with $($script:VllmSm20eWheelName)."
    }
    if(Test-Path -LiteralPath $resolved){throw "SM-20E synthetic wheel destination already exists: $resolved"}
    if(-not$PSCmdlet.ShouldProcess($resolved,'Create deterministic non-production SM-20E wheel')){return}
    $parent=Split-Path -Parent $resolved
    if(-not(Test-Path -LiteralPath $parent)){[void][IO.Directory]::CreateDirectory($parent)}
    $source=Join-Path $parent ('.wheel-source-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($source)
    try{
        $entries=[ordered]@{}
        $entries['vllm/__init__.py']="__version__ = '$($script:VllmSm20eWheelVersion)'"+[char]10
        $entries['vllm/_sm20e_fixture.pyd']='SM20E-NON-PRODUCTION-NATIVE-FIXTURE'
        $entries['vllm-'+$script:VllmSm20eWheelVersion+'.dist-info/METADATA']='Metadata-Version: 2.1'+[char]10+'Name: vllm'+[char]10+'Version: '+$script:VllmSm20eWheelVersion+[char]10
        $entries['vllm-'+$script:VllmSm20eWheelVersion+'.dist-info/WHEEL']='Wheel-Version: 1.0'+[char]10+'Generator: vllm-windows-native-sm20e'+[char]10+'Root-Is-Purelib: false'+[char]10+'Tag: cp313-cp313-win_amd64'+[char]10
        $members=New-Object System.Collections.Generic.List[object]
        foreach($name in (Get-VllmReleaseOrdinalStrings -Values @($entries.Keys))){
            $file=Join-Path $source $name.Replace('/','\')
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $file))
            [IO.File]::WriteAllText($file,[string]$entries[$name],[Text.UTF8Encoding]::new($false))
            $id=Get-VllmReleaseFileIdentity -Path $file
            $members.Add([pscustomobject][ordered]@{RelativePath=$name;Path=$file;Size=[int64]$id.Size;Sha256=[string]$id.Sha256})
        }
        Write-VllmReleaseStoredZip -Context ([pscustomobject]@{Members=$members.ToArray()}) -Path $resolved
        $identity=Get-VllmReleaseFileIdentity -Path $resolved
        if($identity.Size-ne$script:VllmSm20eWheelSize-or-not$identity.Sha256.Equals($script:VllmSm20eWheelSha256,[StringComparison]::OrdinalIgnoreCase)){
            throw "SM-20E synthetic wheel identity drifted: size=$($identity.Size) sha256=$($identity.Sha256)"
        }
        [pscustomobject][ordered]@{path=$resolved;filename=$script:VllmSm20eWheelName;size=[int64]$identity.Size;sha256=[string]$identity.Sha256}
    }finally{
        Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-VllmSm20eSigningMaterial {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$Workspace)
    $signing=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'signing'
    if(Test-Path -LiteralPath $signing){throw "SM-20E signing directory already exists: $signing"}
    if(-not$PSCmdlet.ShouldProcess($signing,'Create ephemeral SM-20E signing material')){return}
    [void][IO.Directory]::CreateDirectory($signing)
    $private=Join-Path $signing 'acceptance-ed25519'
    Invoke-VllmSm19dSshKeygen -PrivateKeyPath $private
    $public=$private+'.pub'
    $fields=@(([IO.File]::ReadAllText($public).Trim()) -split ' ')
    if($fields.Count-lt2){throw 'SM-20E generated public key is malformed.'}
    $fingerprint=Get-VllmReleaseSigningKeyFingerprint -KeyType $fields[0] -KeyData $fields[1]
    $allowed=Join-Path $signing 'allowed-signers'
    [IO.File]::WriteAllText($allowed,$script:VllmSm20ePrincipal+' '+$fields[0]+' '+$fields[1]+[char]10,[Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{
        principal=$script:VllmSm20ePrincipal
        fingerprint=$fingerprint
        private_key=$private
        public_key=$public
        allowed_signers=$allowed
    }
}

function New-VllmSm20eSignedTag {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$PrivateKeyPath
    )
    $existing=Invoke-Git -Repository $Repository -Arguments @('tag','--list',$script:VllmSm20eTag) -Capture
    if(-not[string]::IsNullOrWhiteSpace($existing)){throw "Local SM-20E tag already exists: $($script:VllmSm20eTag)"}
    if(-not$PSCmdlet.ShouldProcess($script:VllmSm20eTag,'Create annotated SSH-signed SM-20E acceptance tag')){return}
    Invoke-Git -Repository $Repository -Arguments @(
        '-c','user.name=vLLM Windows Native SM-20E',
        '-c','user.email=sm20e-acceptance@invalid.local',
        '-c','gpg.format=ssh',
        '-c',('user.signingkey='+[IO.Path]::GetFullPath($PrivateKeyPath)),
        '-c','gpg.ssh.program=ssh-keygen',
        'tag','-s','-a',$script:VllmSm20eTag,
        '-m',('SM-20E non-production acceptance '+$script:VllmSm20eRelease),
        $ProjectCommit
    )
}

function Assert-VllmSm20eStateObject {
    param([Parameter(Mandatory)]$State)
    Assert-VllmReleaseExactProperties -Value $State -Expected @(
        'schema_version','component','repository','release','tag','project_commit','tag_object',
        'principal','key_fingerprint','release_manifest_path','assets','published','release_id',
        'release_url','created_utc','published_utc'
    ) -Label 'SM-20E acceptance state'
    if([int]$State.schema_version-ne1-or-not([string]$State.component).Equals('vllm-windows-native-sm20e-acceptance',[StringComparison]::Ordinal)){throw 'SM-20E state schema/component mismatch.'}
    if(-not([string]$State.repository).Equals($script:VllmSm20eRepositorySlug,[StringComparison]::Ordinal)-or
       -not([string]$State.release).Equals($script:VllmSm20eRelease,[StringComparison]::Ordinal)-or
       -not([string]$State.tag).Equals($script:VllmSm20eTag,[StringComparison]::Ordinal)-or
       -not([string]$State.principal).Equals($script:VllmSm20ePrincipal,[StringComparison]::Ordinal)-or
       -not([string]$State.release_manifest_path).Equals($script:VllmSm20eReleaseManifestPath,[StringComparison]::Ordinal)){
        throw 'SM-20E state fixed identity mismatch.'
    }
    if([string]$State.project_commit-cnotmatch'^[0-9a-f]{40}$'-or[string]$State.tag_object-cnotmatch'^[0-9a-f]{40}$'-or[string]::IsNullOrWhiteSpace([string]$State.key_fingerprint)){throw 'SM-20E state Git/signing identity is invalid.'}
    $assets=@($State.assets)
    if($assets.Count-ne4){throw 'SM-20E state must record exactly four assets.'}
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($asset in $assets){
        Assert-VllmReleaseExactProperties -Value $asset -Expected @('name','size','sha256') -Label 'SM-20E state asset'
        if(-not$names.Add([string]$asset.name)-or[int64]$asset.size-lt0-or[string]$asset.sha256-notmatch'^[0-9A-Fa-f]{64}$'){throw 'SM-20E state asset identity is invalid.'}
    }
    if(-not($State.published-is[bool])){throw 'SM-20E published state must be boolean.'}
    if([bool]$State.published){
        if($null-eq$State.release_id-or[int64]$State.release_id-le0-or[string]::IsNullOrWhiteSpace([string]$State.release_url)-or[string]::IsNullOrWhiteSpace([string]$State.published_utc)){throw 'SM-20E published state is incomplete.'}
    }else{
        if($null-ne$State.release_id-or$null-ne$State.release_url-or$null-ne$State.published_utc){throw 'SM-20E unpublished state must not contain publication identity.'}
    }
    $State
}

function Write-VllmSm20eState {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)]$State)
    $path=Join-Path ([IO.Path]::GetFullPath($Workspace)) $script:VllmSm20eStateFile
    $null=Assert-VllmSm20eStateObject -State $State
    $validator={param($candidate,$candidatePath)$null=$candidatePath;$null=Assert-VllmSm20eStateObject -State $candidate}
    $null=Write-VllmAtomicJsonFile -Path $path -Value $State -Depth 12 -Validate $validator
    $path
}

function Read-VllmSm20eState {
    param([Parameter(Mandatory)][string]$Workspace)
    $path=Join-Path ([IO.Path]::GetFullPath($Workspace)) $script:VllmSm20eStateFile
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "SM-20E state file is missing: $path"}
    try{$state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{throw 'SM-20E state file is invalid JSON.'}
    $null=Assert-VllmSm20eStateObject -State $state
    $state
}

function Get-VllmSm20eVerifiedLocalContext {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)]$State)
    $allowed=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'signing\allowed-signers'
    $trust=Assert-VllmReleaseAllowedSigners -Path $allowed -ExpectedPrincipal ([string]$State.principal) -ExpectedFingerprint ([string]$State.key_fingerprint)
    $tag=Assert-VllmReleaseSignedTag -Repository $Repository -Tag ([string]$State.tag) -ExpectedCommit ([string]$State.project_commit) -AllowedSignersPath ([string]$trust.path) -ExpectedPrincipal ([string]$State.principal) -ExpectedFingerprint ([string]$State.key_fingerprint
)
    if(-not([string]$tag.tag_object).Equals([string]$State.tag_object,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E local signed tag object no longer matches state.'}
    $artifacts=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'artifacts'
    $offline=Assert-VllmOfflineRelease -Repository $Repository -ProjectCommit ([string]$State.project_commit) -ReleaseManifestPath ([string]$State.release_manifest_path) -ArtifactsDirectory $artifacts
    $plan=@(Get-VllmReleasePublicationAssetPlan -ArtifactsDirectory $artifacts -OfflineVerification $offline)
    foreach($asset in $plan){
        $match=@($State.assets|Where-Object{([string]$_.name).Equals([string]$asset.name,[StringComparison]::Ordinal)})
        if($match.Count-ne1-or[int64]$match[0].size-ne[int64]$asset.size-or-not([string]$match[0].sha256).Equals([string]$asset.sha256,[StringComparison]::OrdinalIgnoreCase)){throw "SM-20E local asset changed after preparation: $($asset.name)"}
    }
    [pscustomobject][ordered]@{allowed_signers=$allowed;trust=$trust;tag=$tag;offline=$offline;asset_plan=[object[]]$plan;artifacts=$artifacts}
}

function Get-VllmSm20ePublishedVerification {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$LocalContext,
        [string]$GhExecutable='gh'
    )
    Assert-VllmSm19dRemoteTagExact -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$State.tag) -ExpectedTagObject ([string]$State.tag_object) -GhExecutable $GhExecutable
    $remote=Get-VllmGitHubReleaseByTagAnyState -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$State.tag) -GhExecutable $GhExecutable
    if($null-eq$remote){throw 'SM-20E immutable acceptance release is missing.'}
    $null=Assert-VllmReleaseOwnership -ReleaseObject $remote -RepositorySlug $script:VllmSm20eRepositorySlug -Release ([string]$State.release) -Tag ([string]$State.tag) -ProjectCommit ([string]$State.project_commit)
    if($remote.draft-eq$true-or$remote.immutable-ne$true-or$remote.prerelease-ne$true){throw 'SM-20E acceptance release must be an immutable published prerelease.'}
    $null=Assert-VllmRemoteReleaseAssets -ReleaseObject $remote -AssetPlan ([object[]]$LocalContext.asset_plan)
    $expected=Get-VllmReleaseExpectedAssets -ArtifactsDirectory ([string]$LocalContext.artifacts) -OfflineVerification $LocalContext.offline
    $attestation=Invoke-VllmGitHubReleaseVerification -RepositorySlug $script:VllmSm20eRepositorySlug -Tag ([string]$State.tag) -ExpectedTagObject ([string]$State.tag_object) -ArtifactsDirectory ([string]$LocalContext.artifacts) -ExpectedAssets $expected -GhExecutable $GhExecutable
    [pscustomobject][ordered]@{remote=$remote;attestation=$attestation}
}

function Test-VllmSm20ePrivateKeyAbsent {
    param([Parameter(Mandatory)][string]$Workspace)
    $private=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'signing\acceptance-ed25519'
    $entry=Get-VllmPathEntryInfo -Path $private
    if($entry.Exists){throw 'SM-20E workspace still contains private signing material.'}
    $true
}

function New-VllmSm20eUntrustedRecoveryState {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Low')]
    param([Parameter(Mandatory)][string]$CacheRoot)
    $root=[IO.Path]::GetFullPath($CacheRoot)
    if(-not$PSCmdlet.ShouldProcess($root,'Create deliberately stale/partial/untrusted SM-20E recovery cache state')){return}
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.staging\abandoned-generation'))
    [IO.File]::WriteAllText((Join-Path $root '.staging\abandoned-generation\partial.bin'),'partial',[Text.UTF8Encoding]::new($false))
    $garbage=Join-Path (Join-Path (Join-Path $root 'verified') ([string]$script:VllmAcquisitionRepositoryId)) ('1'*40)
    [void][IO.Directory]::CreateDirectory($garbage)
    [IO.File]::WriteAllText((Join-Path $garbage 'acquisition-receipt.json'),'{not-json',[Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{staging=(Join-Path $root '.staging\abandoned-generation');garbage=$garbage}
}

function Invoke-VllmSm20eHandoffProof {
    param([Parameter(Mandatory)]$Acquisition)
    $invoker={
        param($Mode,$ScriptPath,$Parameters)
        [pscustomobject][ordered]@{
            mode=$Mode
            script_path=[IO.Path]::GetFullPath($ScriptPath)
            release_manifest_path=[IO.Path]::GetFullPath([string]$Parameters.ReleaseManifestPath)
            wheel_path=[IO.Path]::GetFullPath([string]$Parameters.WheelPath)
        }
    }
    $install=Invoke-VllmAcquisitionInstallHandoff -Acquisition $Acquisition -LifecycleInvoker $invoker
    $update=Invoke-VllmAcquisitionUpdateHandoff -Acquisition $Acquisition -WhatIf -LifecycleInvoker $invoker
    foreach($proof in @($install,$update)){
        if(([string]$proof.script_path).IndexOf('.handoff',[StringComparison]::OrdinalIgnoreCase)-lt0){throw 'SM-20E lifecycle script was not handed off from the verified materialized distribution.'}
        $distribution=Split-Path -Parent ([string]$proof.script_path)
        if(-not([string]$proof.release_manifest_path).StartsWith($distribution,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E release manifest handoff is outside the materialized distribution.'}
        if(-not([string]$proof.wheel_path).Equals([string]$Acquisition.wheel_path,[StringComparison]::OrdinalIgnoreCase)){throw 'SM-20E wheel handoff path changed.'}
    }
    if(-not([string]$install.mode).Equals('install',[StringComparison]::Ordinal)-or-not([string]$update.mode).Equals('update',[StringComparison]::Ordinal)){throw 'SM-20E lifecycle handoff modes are incorrect.'}
    [pscustomobject][ordered]@{install=$install;update=$update}
}
