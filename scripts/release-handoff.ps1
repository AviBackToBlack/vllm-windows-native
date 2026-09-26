Set-StrictMode -Version Latest

function Test-VllmAcquisitionHandoffPathEqual {
    param([Parameter(Mandatory)][string]$A,[Parameter(Mandatory)][string]$B)
    (Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetFullPath($A))).Equals((Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetFullPath($B))),[StringComparison]::OrdinalIgnoreCase)
}

function Get-VllmAcquisitionHandoffCacheRoot {
    param([Parameter(Mandatory)][string]$CacheEntry,[Parameter(Mandatory)]$Receipt)
    $entry=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetFullPath($CacheEntry))
    if(-not([IO.Path]::GetFileName($entry)).Equals([string]$Receipt.release.tag_object,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Acquisition cache entry leaf does not match the authenticated tag object.'
    }
    $repositoryRoot=[IO.Path]::GetDirectoryName($entry)
    if(-not([IO.Path]::GetFileName($repositoryRoot)).Equals([string]$Receipt.repository.id,[StringComparison]::Ordinal)){
        throw 'Acquisition cache entry repository-id parent is inconsistent.'
    }
    $verifiedRoot=[IO.Path]::GetDirectoryName($repositoryRoot)
    if(-not([IO.Path]::GetFileName($verifiedRoot)).Equals('verified',[StringComparison]::Ordinal)){
        throw 'Acquisition cache entry is not below the canonical verified cache root.'
    }
    [IO.Path]::GetDirectoryName($verifiedRoot)
}

function Enter-VllmAcquisitionHandoffSource {
    param([Parameter(Mandatory)]$Acquisition)
    Assert-VllmReleaseExactProperties -Value $Acquisition -Expected @(
        'schema_version','component','repository','release','tag','tag_object','project_commit',
        'cache_entry','artifacts_directory','wheel_path','bundle_path','release_index_path',
        'checksums_path','receipt_path','release_manifest_path','release_manifest_sha256',
        'runtime_manifest_sha256','signing_principal','signing_key_fingerprint','wheel_sha256',
        'bundle_sha256','release_index_sha256','checksums_sha256'
    ) -Label 'Acquisition handoff input'
    if([int]$Acquisition.schema_version-ne1-or-not([string]$Acquisition.component).Equals('vllm-windows-native-acquisition',[StringComparison]::Ordinal)){
        throw 'Acquisition handoff input schema/component is unsupported.'
    }
    if(-not([string]$Acquisition.repository).Equals($script:VllmAcquisitionRepository,[StringComparison]::Ordinal)){
        throw 'Acquisition handoff input repository is unsupported.'
    }
    $cacheEntry=Assert-VllmAcquisitionDirectory -Path ([string]$Acquisition.cache_entry) -Label 'Acquisition handoff cache entry'
    $receiptPath=Join-Path $cacheEntry 'acquisition-receipt.json'
    if(-not(Test-VllmAcquisitionHandoffPathEqual -A ([string]$Acquisition.receipt_path) -B $receiptPath)){
        throw 'Acquisition handoff receipt path is inconsistent with cache entry.'
    }
    $rootEntries=Get-VllmReleaseOrdinalStrings -Values @((Get-ChildItem -LiteralPath $cacheEntry -Force)|ForEach-Object{$_.Name})
    $rootExpected=Get-VllmReleaseOrdinalStrings -Values @('acquisition-receipt.json','artifacts')
    Assert-VllmReleaseOrdinalSequence -Actual $rootEntries -Expected $rootExpected -Label 'Acquisition handoff cache-entry member set'
    $receipt=Read-VllmAcquisitionReceipt -Path $receiptPath
    foreach($pair in @(
        @([string]$Acquisition.release,[string]$receipt.release.release,'release'),
        @([string]$Acquisition.tag,[string]$receipt.release.tag,'tag'),
        @([string]$Acquisition.release_manifest_path,[string]$receipt.release.release_manifest_path,'release manifest path')
    )){
        if(-not([string]$pair[0]).Equals([string]$pair[1],[StringComparison]::Ordinal)){
            throw "Acquisition handoff $($pair[2]) does not match the verified receipt."
        }
    }
    foreach($pair in @(
        @([string]$Acquisition.tag_object,[string]$receipt.release.tag_object,'tag object'),
        @([string]$Acquisition.project_commit,[string]$receipt.release.project_commit,'project commit')
    )){
        if(-not([string]$pair[0]).Equals([string]$pair[1],[StringComparison]::OrdinalIgnoreCase)){
            throw "Acquisition handoff $($pair[2]) does not match the verified receipt."
        }
    }
    foreach($pair in @(
        @([string]$Acquisition.release_manifest_sha256,[string]$receipt.release.release_manifest_sha256,'release manifest SHA-256'),
        @([string]$Acquisition.runtime_manifest_sha256,[string]$receipt.release.runtime_manifest_sha256,'runtime manifest SHA-256'),
        @([string]$Acquisition.wheel_sha256,[string]$receipt.artifacts.wheel.sha256,'wheel SHA-256'),
        @([string]$Acquisition.bundle_sha256,[string]$receipt.artifacts.bundle.sha256,'bundle SHA-256'),
        @([string]$Acquisition.release_index_sha256,[string]$receipt.artifacts.index.sha256,'release index SHA-256'),
        @([string]$Acquisition.checksums_sha256,[string]$receipt.artifacts.checksums.sha256,'checksums SHA-256')
    )){
        if(-not([string]$pair[0]).Equals([string]$pair[1],[StringComparison]::OrdinalIgnoreCase)){
            throw "Acquisition handoff $($pair[2]) does not match the verified acquisition result."
        }
    }
    if(-not([string]$Acquisition.signing_principal).Equals([string]$receipt.signing.principal,[StringComparison]::Ordinal)-or-not([string]$Acquisition.signing_key_fingerprint).Equals([string]$receipt.signing.key_fingerprint,[StringComparison]::Ordinal)){
        throw 'Acquisition handoff signer identity does not match the verified acquisition result.'
    }
    $cacheRoot=Get-VllmAcquisitionHandoffCacheRoot -CacheEntry $cacheEntry -Receipt $receipt
    $artifacts=Assert-VllmAcquisitionDirectory -Path (Join-Path $cacheEntry 'artifacts') -Label 'Acquisition handoff artifacts'
    if(-not(Test-VllmAcquisitionHandoffPathEqual -A ([string]$Acquisition.artifacts_directory) -B $artifacts)){
        throw 'Acquisition handoff artifacts path is inconsistent with cache entry.'
    }
    $expected=[ordered]@{
        ([string]$receipt.artifacts.wheel.filename)=$receipt.artifacts.wheel
        ([string]$receipt.artifacts.bundle.filename)=$receipt.artifacts.bundle
        ([string]$receipt.artifacts.index.filename)=$receipt.artifacts.index
        ([string]$receipt.artifacts.checksums.filename)=$receipt.artifacts.checksums
    }
    if($expected.Count-ne4){throw 'Acquisition handoff receipt does not describe four distinct artifacts.'}
    $expectedNames=Get-VllmReleaseOrdinalStrings -Values @($expected.Keys)
    $actualEntries=@(Get-ChildItem -LiteralPath $artifacts -Force)
    if(@($actualEntries|Where-Object{$_.PSIsContainer-or$_.Attributes-band[IO.FileAttributes]::ReparsePoint}).Count-ne0){
        throw 'Acquisition handoff artifacts contain a directory or reparse point.'
    }
    $actualNames=Get-VllmReleaseOrdinalStrings -Values @($actualEntries|ForEach-Object{$_.Name})
    Assert-VllmReleaseOrdinalSequence -Actual $actualNames -Expected $expectedNames -Label 'Acquisition handoff artifact filename set'
    $guards=Enter-VllmReleaseArtifactGuards -Root $artifacts -Names ([string[]]$expectedNames)
    try{
        foreach($name in $expectedNames){
            $record=$expected[$name]
            $path=Join-Path $artifacts $name
            $identity=Get-VllmReleaseFileIdentity -Path $path
            if($identity.Size-ne[int64]$record.size_bytes-or-not([string]$identity.Sha256).Equals([string]$record.sha256,[StringComparison]::OrdinalIgnoreCase)){
                throw "Acquisition handoff artifact identity mismatch: $name"
            }
        }
        $wheel=Join-Path $artifacts ([string]$receipt.artifacts.wheel.filename)
        $bundle=Join-Path $artifacts ([string]$receipt.artifacts.bundle.filename)
        $index=Join-Path $artifacts ([string]$receipt.artifacts.index.filename)
        $checksums=Join-Path $artifacts ([string]$receipt.artifacts.checksums.filename)
        foreach($pair in @(
            @([string]$Acquisition.wheel_path,$wheel,'wheel'),
            @([string]$Acquisition.bundle_path,$bundle,'bundle'),
            @([string]$Acquisition.release_index_path,$index,'release index'),
            @([string]$Acquisition.checksums_path,$checksums,'checksums')
        )){
            if(-not(Test-VllmAcquisitionHandoffPathEqual -A ([string]$pair[0]) -B ([string]$pair[1]))){throw "Acquisition handoff $($pair[2]) path is inconsistent with verified cache."}
        }
        $result=[pscustomobject][ordered]@{
            CacheEntry=$cacheEntry
            CacheRoot=$cacheRoot
            Receipt=$receipt
            Artifacts=$artifacts
            ArtifactGuards=$guards
            WheelPath=$wheel
            BundlePath=$bundle
        }
        $guards=$null
        return $result
    }finally{
        if($null-ne$guards){Exit-VllmReleaseArtifactGuards -Guards $guards}
    }
}

function Exit-VllmAcquisitionHandoffSource {
    param([AllowNull()]$Source)
    if($null-ne$Source-and$null-ne$Source.ArtifactGuards){Exit-VllmReleaseArtifactGuards -Guards $Source.ArtifactGuards}
}

function Get-VllmAcquisitionBundleContract {
    param([Parameter(Mandatory)]$Source)
    $receipt=$Source.Receipt
    $zip=[IO.Compression.ZipFile]::OpenRead([string]$Source.BundlePath)
    try{
        $entryByKey=@{}
        foreach($entry in @($zip.Entries)){
            $name=Assert-VllmReleaseCanonicalPath -RelativePath ([string]$entry.FullName) -Label 'Acquisition handoff bundle member'
            if([string]::IsNullOrWhiteSpace([string]$entry.Name)){throw "Acquisition handoff bundle contains a directory entry: $name"}
            $key=$name.ToLowerInvariant()
            if($entryByKey.ContainsKey($key)){throw "Acquisition handoff bundle contains duplicate/case-colliding member: $name"}
            $entryByKey[$key]=$entry
        }
        $manifestRelative=Assert-VllmReleaseCanonicalPath -RelativePath ([string]$receipt.release.release_manifest_path) -Label 'Acquisition handoff release manifest path'
        $manifestKey=$manifestRelative.ToLowerInvariant()
        if(-not$entryByKey.ContainsKey($manifestKey)){throw 'Acquisition handoff bundle is missing the authenticated release manifest.'}
        $manifestEntry=$entryByKey[$manifestKey]
        $manifestInput=$manifestEntry.Open()
        $manifestStream=New-Object IO.MemoryStream
        try{
            $manifestInput.CopyTo($manifestStream)
            $manifestStream.Position=0
            $manifestIdentity=Get-VllmReleaseStreamIdentity -Stream $manifestStream
            if(-not([string]$manifestIdentity.Sha256).Equals([string]$receipt.release.release_manifest_sha256,[StringComparison]::OrdinalIgnoreCase)){
                throw 'Acquisition handoff release manifest digest does not match the authenticated receipt.'
            }
            $manifestStream.Position=0
            $manifestText=Read-VllmReleaseUtf8NoBomStream -Stream $manifestStream -Label 'Acquisition handoff release manifest'
        }finally{$manifestInput.Dispose();$manifestStream.Dispose()}
        try{$release=$manifestText|ConvertFrom-Json}catch{throw 'Acquisition handoff release manifest JSON is invalid.'}
        Assert-VllmReleaseExactProperties -Value $release -Expected @('schema_version','component','release','platform','self_path','upstream','windows_patchset','wheel','orchestration','managed_paths','files') -Label 'Acquisition handoff release manifest'
        Assert-VllmReleaseExactProperties -Value $release.upstream -Expected @('repository','tag','commit') -Label 'Acquisition handoff upstream identity'
        Assert-VllmReleaseExactProperties -Value $release.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Acquisition handoff Windows patchset'
        Assert-VllmReleaseExactProperties -Value $release.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Acquisition handoff wheel identity'
        Assert-VllmReleaseExactProperties -Value $release.orchestration -Expected @('python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest','python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root') -Label 'Acquisition handoff orchestration'
        if([int]$release.schema_version-ne1-or-not([string]$release.component).Equals('runtime-release',[StringComparison]::Ordinal)-or-not([string]$release.platform).Equals('windows-x86_64',[StringComparison]::Ordinal)){
            throw 'Acquisition handoff release manifest schema/component/platform is unsupported.'
        }
        Assert-VllmReleasePublicProvenance -Upstream $release.upstream -WindowsPatchset $release.windows_patchset
        if(-not([IO.Path]::GetFileName([string]$release.wheel.filename)).Equals([string]$release.wheel.filename,[StringComparison]::Ordinal)-or-not([string]$release.wheel.filename).EndsWith('.whl',[StringComparison]::Ordinal)){
            throw 'Acquisition handoff wheel filename must be a simple .whl filename.'
        }
        if(-not([string]$release.release).Equals([string]$receipt.release.release,[StringComparison]::Ordinal)-or-not('release/'+[string]$release.release).Equals([string]$receipt.release.tag,[StringComparison]::Ordinal)){
            throw 'Acquisition handoff release identity does not match the authenticated receipt.'
        }
        if(-not([string]$release.self_path).Equals($manifestRelative,[StringComparison]::Ordinal)){throw 'Acquisition handoff release manifest self_path mismatch.'}
        if(-not([string]$release.wheel.filename).Equals([string]$receipt.artifacts.wheel.filename,[StringComparison]::Ordinal)-or[int64]$release.wheel.size_bytes-ne[int64]$receipt.artifacts.wheel.size_bytes-or-not([string]$release.wheel.sha256).Equals([string]$receipt.artifacts.wheel.sha256,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Acquisition handoff release manifest wheel identity does not match the verified wheel.'
        }
        $expectedByKey=@{}
        $expectedMembers=New-Object System.Collections.Generic.List[object]
        foreach($item in @($release.files)){
            Assert-VllmReleaseExactProperties -Value $item -Expected @('path','size_bytes','sha256') -Label 'Acquisition handoff distribution entry'
            $relative=Assert-VllmReleaseCanonicalPath -RelativePath ([string]$item.path) -Label 'Acquisition handoff distribution path'
            if($relative.Equals($manifestRelative,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition handoff release manifest is duplicated in release files.'}
            if($relative.Equals([string]$release.wheel.filename,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition handoff bundle must not contain the wheel asset.'}
            if([int64]$item.size_bytes-lt0-or[string]$item.sha256-notmatch'^[0-9A-Fa-f]{64}$'){throw "Acquisition handoff distribution identity is invalid: $relative"}
            $key=$relative.ToLowerInvariant()
            if($expectedByKey.ContainsKey($key)){throw "Acquisition handoff distribution paths collide by Windows identity: $relative"}
            $record=[pscustomobject][ordered]@{RelativePath=$relative;Size=[int64]$item.size_bytes;Sha256=([string]$item.sha256).ToUpperInvariant()}
            $expectedByKey[$key]=$record
            $expectedMembers.Add($record)
        }
        $manifestRecord=[pscustomobject][ordered]@{RelativePath=$manifestRelative;Size=[int64]$manifestIdentity.Size;Sha256=([string]$manifestIdentity.Sha256).ToUpperInvariant()}
        $expectedByKey[$manifestKey]=$manifestRecord
        $expectedMembers.Add($manifestRecord)
        $runtimeRelative=Assert-VllmReleaseCanonicalPath -RelativePath ([string]$release.orchestration.runtime_manifest) -Label 'Acquisition handoff runtime manifest path'
        $runtimeKey=$runtimeRelative.ToLowerInvariant()
        if(-not$expectedByKey.ContainsKey($runtimeKey)){throw 'Acquisition handoff runtime manifest is not release-owned.'}
        if(-not([string]$expectedByKey[$runtimeKey].Sha256).Equals([string]$receipt.release.runtime_manifest_sha256,[StringComparison]::OrdinalIgnoreCase)){
            throw 'Acquisition handoff runtime manifest digest does not match the authenticated receipt.'
        }
        $expectedNames=Get-VllmReleaseOrdinalStrings -Values @($expectedMembers|ForEach-Object{$_.RelativePath})
        $actualNames=@($zip.Entries|ForEach-Object{[string]$_.FullName})
        Assert-VllmReleaseOrdinalSequence -Actual $actualNames -Expected $expectedNames -Label 'Acquisition handoff canonical bundle member order'
        for($i=0;$i-lt$zip.Entries.Count;$i++){
            $entry=$zip.Entries[$i]
            $name=[string]$entry.FullName
            $expected=$expectedByKey[$name.ToLowerInvariant()]
            if($null-eq$expected){throw "Acquisition handoff bundle contains unexpected member: $name"}
            if($entry.ExternalAttributes-ne0){throw "Acquisition handoff bundle member external attributes are not canonical: $name"}
            if([int64]$entry.Length-ne[int64]$expected.Size-or[int64]$entry.CompressedLength-ne[int64]$entry.Length){throw "Acquisition handoff bundle member size/profile mismatch: $name"}
            $stream=$entry.Open()
            try{$hash=Get-VllmReleaseStreamSha256 -Stream $stream}finally{$stream.Dispose()}
            if(-not([string]$hash).Equals([string]$expected.Sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Acquisition handoff bundle member SHA-256 mismatch: $name"}
        }
        if(-not$expectedByKey.ContainsKey('install.ps1')-or-not$expectedByKey.ContainsKey('update.ps1')){throw 'Acquisition handoff bundle must contain release-owned install.ps1 and update.ps1 entrypoints.'}
        [pscustomobject][ordered]@{
            Release=$release
            Members=$expectedMembers.ToArray()
            ReleaseManifestRelative=$manifestRelative
            InstallRelative='install.ps1'
            UpdateRelative='update.ps1'
        }
    }finally{$zip.Dispose()}
}

function Get-VllmAcquisitionHandoffDirectoryRecord {
    param([Parameter(Mandatory)][hashtable]$Directories,[Parameter(Mandatory)][AllowEmptyString()][string]$RelativeDirectory)
    $normalized=if([string]::IsNullOrWhiteSpace($RelativeDirectory)){''}else{(Assert-VllmSafeRelativePath -RelativePath $RelativeDirectory -Label 'Acquisition handoff directory').Replace('\','/')}
    if($Directories.ContainsKey($normalized.ToLowerInvariant())){return $Directories[$normalized.ToLowerInvariant()]}
    $segments=@($normalized -split '/')
    $current=''
    foreach($segment in $segments){
        if([string]::IsNullOrWhiteSpace($segment)){continue}
        $parentKey=$current.ToLowerInvariant()
        if(-not$Directories.ContainsKey($parentKey)){throw "Acquisition handoff parent directory guard is missing: $current"}
        $parent=$Directories[$parentKey]
        $next=if([string]::IsNullOrEmpty($current)){$segment}else{$current+'/'+$segment}
        $key=$next.ToLowerInvariant()
        if(-not$Directories.ContainsKey($key)){
            $created=Invoke-VllmReleasePinnedDirectoryCreation -ParentGuard $parent.Handle -ParentPath $parent.Path -ParentGuid $parent.Guid -Leaf $segment -Label 'Acquisition handoff directory'
            $Directories[$key]=$created
        }
        $current=$next
    }
    $Directories[$normalized.ToLowerInvariant()]
}

function Initialize-VllmAcquisitionHandoffMaterialization {
    param(
        [Parameter(Mandatory)]$Acquisition,
        [ValidateSet('None','AfterMaterializedWriteBeforeVerify')][string]$FaultPoint='None'
    )
    $source=$null;$parentGuard=$null;$generation=$null
    $directories=@{};$fileStreams=New-Object System.Collections.Generic.List[object]
    try{
        $source=Enter-VllmAcquisitionHandoffSource -Acquisition $Acquisition
        $contract=Get-VllmAcquisitionBundleContract -Source $source
        $handoffParent=Assert-VllmAcquisitionDirectory -Path (Join-Path ([string]$source.CacheRoot) '.handoff') -Label 'Acquisition handoff root' -Create
        $parentExpectedGuid=Get-VllmPathWithoutTrailingSeparator (Get-VllmPhysicalCandidatePath -Path $handoffParent -Format Guid)
        $parentGuard=[VllmWindowsNative.ReleaseDirectoryGuard]::Open($handoffParent)
        $parentEntry=Get-VllmPathEntryInfo -Path $handoffParent
        if(-not$parentEntry.Exists-or-not$parentEntry.IsDirectory-or$parentEntry.IsReparsePoint){throw 'Acquisition handoff root changed type or became a reparse point while opening its guard.'}
        $parentGuid=Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($parentGuard))
        if(-not$parentGuid.Equals($parentExpectedGuid,[StringComparison]::OrdinalIgnoreCase)){throw 'Acquisition handoff root handle resolves outside the validated cache-local path.'}
        $generation=Invoke-VllmReleasePinnedDirectoryCreation -ParentGuard $parentGuard -ParentPath $handoffParent -ParentGuid $parentGuid -Leaf ([guid]::NewGuid().ToString('N')) -Label 'Acquisition handoff generation'
        $distribution=Invoke-VllmReleasePinnedDirectoryCreation -ParentGuard $generation.Handle -ParentPath $generation.Path -ParentGuid $generation.Guid -Leaf 'distribution' -Label 'Acquisition handoff distribution root'
        $directories['']=$distribution
        $zip=[IO.Compression.ZipFile]::OpenRead([string]$source.BundlePath)
        try{
            $entryMap=@{};foreach($entry in @($zip.Entries)){$entryMap[[string]$entry.FullName]=$entry}
            foreach($member in @($contract.Members)){
                $relative=[string]$member.RelativePath
                $parentRelative=[IO.Path]::GetDirectoryName($relative.Replace('/','\'))
                if($null-eq$parentRelative){$parentRelative=''}
                $parentRecord=Get-VllmAcquisitionHandoffDirectoryRecord -Directories $directories -RelativeDirectory $parentRelative
                $leaf=[IO.Path]::GetFileName($relative)
                $destination=Join-Path $parentRecord.Path $leaf
                $entry=$entryMap[$relative]
                if($null-eq$entry){throw "Acquisition handoff extraction source disappeared: $relative"}
                $writer=$null
                $sourceStream=$entry.Open()
                try{
                    $writer=Write-VllmReleasePinnedFile -Path $destination -ExpectedParentGuid $parentRecord.Guid -WriteAction {param($output)$sourceStream.CopyTo($output)}
                }finally{$sourceStream.Dispose()}
                try{
                    if($FaultPoint-eq'AfterMaterializedWriteBeforeVerify'){throw 'FAULT_INJECTED:AfterMaterializedWriteBeforeVerify'}
                    $writer.Position=0
                    $identity=Get-VllmReleaseStreamIdentity -Stream $writer
                    if($identity.Size-ne[int64]$member.Size-or-not([string]$identity.Sha256).Equals([string]$member.Sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Acquisition handoff materialized file identity mismatch: $relative"}
                }finally{
                    if($null-ne$writer){$writer.Dispose();$writer=$null}
                }
                $readHandle=$null;$readStream=$null
                try{
                    $readHandle=[VllmWindowsNative.ReleaseDirectoryGuard]::OpenRead($destination)
                    $entryInfo=Get-VllmPathEntryInfo -Path $destination
                    if(-not$entryInfo.Exists-or$entryInfo.IsDirectory-or$entryInfo.IsReparsePoint){throw "Acquisition handoff pinned file changed type: $relative"}
                    if([VllmWindowsNative.NativePath]::GetLinkCount($readHandle)-ne1){throw "Acquisition handoff pinned file has unexpected hard-link count: $relative"}
                    $expectedGuid=Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($parentRecord.Guid,$leaf))
                    $actualGuid=Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($readHandle))
                    if(-not$actualGuid.Equals($expectedGuid,[StringComparison]::OrdinalIgnoreCase)){throw "Acquisition handoff pinned file resolves outside expected parent: $relative"}
                    $readStream=New-Object IO.FileStream($readHandle,[IO.FileAccess]::Read,65536,$false)
                    $readHandle=$null
                    $guardedIdentity=Get-VllmReleaseStreamIdentity -Stream $readStream
                    if($guardedIdentity.Size-ne[int64]$member.Size-or-not([string]$guardedIdentity.Sha256).Equals([string]$member.Sha256,[StringComparison]::OrdinalIgnoreCase)){throw "Acquisition handoff pinned file identity mismatch after reopen: $relative"}
                    $readStream.Position=0
                    $fileStreams.Add($readStream)
                    $readStream=$null
                }finally{
                    if($null-ne$readStream){$readStream.Dispose()}
                    if($null-ne$readHandle){$readHandle.Dispose()}
                }
            }
        }finally{$zip.Dispose()}
        $actualFiles=Get-VllmReleaseOrdinalStrings -Values @(
            Get-ChildItem -LiteralPath $distribution.Path -File -Recurse -Force|ForEach-Object{
                $_.FullName.Substring($distribution.Path.Length+1).Replace('\','/')
            }
        )
        $expectedFiles=Get-VllmReleaseOrdinalStrings -Values @($contract.Members|ForEach-Object{$_.RelativePath})
        Assert-VllmReleaseOrdinalSequence -Actual $actualFiles -Expected $expectedFiles -Label 'Acquisition handoff materialized file set'
        $manifest=Join-Path $distribution.Path ([string]$contract.ReleaseManifestRelative).Replace('/','\')
        $install=Join-Path $distribution.Path 'install.ps1'
        $update=Join-Path $distribution.Path 'update.ps1'
        foreach($path in @($manifest,$install,$update)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Acquisition handoff required materialized file is missing: $path"}}
        $result=[pscustomobject][ordered]@{
            Source=$source
            ParentGuard=$parentGuard
            Generation=$generation
            Directories=$directories
            FileStreams=$fileStreams
            DistributionRoot=$distribution.Path
            ReleaseManifestPath=$manifest
            WheelPath=$source.WheelPath
            InstallScriptPath=$install
            UpdateScriptPath=$update
        }
        $source=$null;$parentGuard=$null;$generation=$null;$directories=$null;$fileStreams=$null
        return $result
    }catch{
        if($null-ne$fileStreams){foreach($stream in $fileStreams.ToArray()){if($null-ne$stream){$stream.Dispose()}}}
        if($null-ne$directories){foreach($record in @($directories.Values)){if($null-ne$record.Handle){$record.Handle.Dispose()}}}
        if($null-ne$generation){
            try{Invoke-VllmReleaseOwnedTempCleanup -Path $generation.Path -ExpectedPhysical (Get-VllmCanonicalExistingPath -Path $generation.Path -Format Dos) -ExpectedIdentity $generation.Identity -ExistingRootGuard $generation.Handle}catch{Write-Verbose ('Best-effort failed handoff cleanup could not remove generation: '+$_.Exception.Message)}
            $generation.Handle.Dispose()
        }
        if($null-ne$parentGuard){$parentGuard.Dispose()}
        if($null-ne$source){Exit-VllmAcquisitionHandoffSource -Source $source}
        throw
    }
}

function Exit-VllmAcquisitionHandoffMaterialization {
    param([AllowNull()]$Materialization)
    if($null-eq$Materialization){return}
    foreach($stream in $Materialization.FileStreams.ToArray()){if($null-ne$stream){$stream.Dispose()}}
    foreach($record in @($Materialization.Directories.Values)){if($null-ne$record.Handle){$record.Handle.Dispose()}}
    $generation=$Materialization.Generation
    try{
        if(Test-Path -LiteralPath $generation.Path){
            $physical=Get-VllmCanonicalExistingPath -Path $generation.Path -Format Dos
            Invoke-VllmReleaseOwnedTempCleanup -Path $generation.Path -ExpectedPhysical $physical -ExpectedIdentity $generation.Identity -ExistingRootGuard $generation.Handle
        }
    }finally{
        if($null-ne$generation.Handle){$generation.Handle.Dispose()}
        if($null-ne$Materialization.ParentGuard){$Materialization.ParentGuard.Dispose()}
        Exit-VllmAcquisitionHandoffSource -Source $Materialization.Source
    }
}

function Invoke-VllmAcquisitionInstallHandoff {
    param(
        [Parameter(Mandatory)]$Acquisition,
        [string]$InstallationRoot='',
        [string]$ModelsRoot='',
        [string]$PythonArchivePath='',
        [string]$UvArchivePath='',
        [switch]$Offline,
        [switch]$Json,
        [AllowNull()][scriptblock]$LifecycleInvoker=$null
    )
    $materialization=$null
    try{
        $materialization=Initialize-VllmAcquisitionHandoffMaterialization -Acquisition $Acquisition
        $parameters=[ordered]@{
            ReleaseManifestPath=$materialization.ReleaseManifestPath
            WheelPath=$materialization.WheelPath
        }
        if(-not[string]::IsNullOrWhiteSpace($InstallationRoot)){$parameters.InstallationRoot=$InstallationRoot}
        if(-not[string]::IsNullOrWhiteSpace($ModelsRoot)){$parameters.ModelsRoot=$ModelsRoot}
        if(-not[string]::IsNullOrWhiteSpace($PythonArchivePath)){$parameters.PythonArchivePath=$PythonArchivePath}
        if(-not[string]::IsNullOrWhiteSpace($UvArchivePath)){$parameters.UvArchivePath=$UvArchivePath}
        if($Offline){$parameters.Offline=$true}
        if($Json){$parameters.Json=$true}
        if($null-ne$LifecycleInvoker){return & $LifecycleInvoker 'install' $materialization.InstallScriptPath $parameters}
        return & $materialization.InstallScriptPath @parameters
    }finally{Exit-VllmAcquisitionHandoffMaterialization -Materialization $materialization}
}

function Invoke-VllmAcquisitionUpdateHandoff {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Acquisition,
        [string]$InstallationRoot='',
        [switch]$Json,
        [AllowNull()][scriptblock]$LifecycleInvoker=$null
    )
    $materialization=$null
    try{
        $materialization=Initialize-VllmAcquisitionHandoffMaterialization -Acquisition $Acquisition
        $parameters=[ordered]@{
            ReleaseManifestPath=$materialization.ReleaseManifestPath
            WheelPath=$materialization.WheelPath
        }
        if(-not[string]::IsNullOrWhiteSpace($InstallationRoot)){$parameters.InstallationRoot=$InstallationRoot}
        if($WhatIfPreference){$parameters.WhatIf=$true}
        if($PSBoundParameters.ContainsKey('Confirm')){$parameters.Confirm=[bool]$PSBoundParameters['Confirm']}
        if($Json){$parameters.Json=$true}
        if($null-ne$LifecycleInvoker){return & $LifecycleInvoker 'update' $materialization.UpdateScriptPath $parameters}
        return & $materialization.UpdateScriptPath @parameters
    }finally{Exit-VllmAcquisitionHandoffMaterialization -Materialization $materialization}
}
