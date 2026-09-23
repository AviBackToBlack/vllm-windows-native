Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:VllmReleaseZipTimestamp = New-Object DateTimeOffset(1980,1,1,0,0,0,[TimeSpan]::Zero)
$script:VllmReleaseCrc32Table = $null

function Get-VllmReleaseFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Release file is missing: $Path" }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        Size = [int64]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Get-VllmReleaseStreamSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Stream)
        return ([BitConverter]::ToString($hash)).Replace('-','')
    } finally { $sha.Dispose() }
}

function Assert-VllmReleaseCanonicalPath {
    param([Parameter(Mandatory)][string]$RelativePath,[string]$Label='Release path')
    $safe = Assert-VllmSafeRelativePath -RelativePath $RelativePath -Label $Label
    $canonical = $safe.Replace('\','/')
    if ($canonical -ne $RelativePath) { throw "$Label must use canonical forward-slash separators: $RelativePath" }
    return $canonical
}

function Assert-VllmReleaseExactProperties {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string[]]$Expected,[Parameter(Mandatory)][string]$Label)
    if ($null -eq $Value) { throw "$Label is missing." }
    $actual = Get-VllmReleaseOrdinalStrings -Values @($Value.PSObject.Properties.Name)
    $wanted = Get-VllmReleaseOrdinalStrings -Values @($Expected)
    Assert-VllmReleaseOrdinalSequence -Actual $actual -Expected $wanted -Label "$Label property set"
}

function Get-VllmReleaseOrdinalStrings {
    param([Parameter(Mandatory)][object[]]$Values)
    $copy = New-Object string[] $Values.Count
    for ($i=0; $i -lt $Values.Count; $i++) { $copy[$i] = [string]$Values[$i] }
    [Array]::Sort($copy,[StringComparer]::Ordinal)
    return $copy
}

function Test-VllmReleaseOrdinalEqual {
    param([AllowNull()][string]$Actual,[AllowNull()][string]$Expected)
    return [string]::Equals($Actual,$Expected,[StringComparison]::Ordinal)
}

function Assert-VllmReleaseOrdinalSequence {
    param([Parameter(Mandatory)][object[]]$Actual,[Parameter(Mandatory)][object[]]$Expected,[Parameter(Mandatory)][string]$Label)
    if ($Actual.Count -ne $Expected.Count) { throw "$Label count mismatch." }
    for ($i=0; $i -lt $Actual.Count; $i++) {
        if (-not (Test-VllmReleaseOrdinalEqual -Actual ([string]$Actual[$i]) -Expected ([string]$Expected[$i]))) {
            throw "$Label mismatch at index $i."
        }
    }
}

function Resolve-VllmReleaseCommit {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Commit)
    $resolved = Invoke-Git -Repository $Repository -Arguments @('rev-parse','--verify',("$Commit^{commit}")) -Capture
    if ([string]$resolved -notmatch '^[0-9a-fA-F]{40,64}$') { throw "Resolved project commit is invalid: $resolved" }
    return ([string]$resolved).ToLowerInvariant()
}

function Get-VllmReleaseGitSnapshot {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Commit)
    $resolved = Resolve-VllmReleaseCommit -Repository $Repository -Commit $Commit
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw 'tar.exe is required for canonical Git snapshot materialization.' }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('vllm-release-' + [guid]::NewGuid().ToString('N'))
    $snapshotRoot = Join-Path $tempRoot 'snapshot'
    $archivePath = Join-Path $tempRoot 'snapshot.tar'
    New-Item -ItemType Directory -Path $snapshotRoot -Force | Out-Null
    try {
        & git -C $Repository -c core.longpaths=true archive --format=tar --output=$archivePath $resolved
        if ($LASTEXITCODE -ne 0) { throw "git archive failed for project commit $resolved." }
        & $tar.Source -xf $archivePath -C $snapshotRoot
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for project commit $resolved." }
        Remove-Item -LiteralPath $archivePath -Force
        return [pscustomobject][ordered]@{
            Repository=[IO.Path]::GetFullPath($Repository)
            Commit=$resolved
            Root=$snapshotRoot
            TempRoot=$tempRoot
        }
    } catch {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Close-VllmReleaseGitSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    if ($Snapshot.TempRoot -and (Test-Path -LiteralPath ([string]$Snapshot.TempRoot))) {
        Remove-Item -LiteralPath ([string]$Snapshot.TempRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-VllmReleaseGitRegularBlob {
    param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Commit,[Parameter(Mandatory)][string]$RelativePath)
    $relative = Assert-VllmReleaseCanonicalPath -RelativePath $RelativePath -Label 'Git release member'
    $line = Invoke-Git -Repository $Repository -Arguments @('ls-tree',$Commit,'--',$relative) -Capture
    if ([string]::IsNullOrWhiteSpace($line)) { throw ("Git release member is missing at {0}: {1}" -f $Commit,$relative) }
    $rows = @($line -split [char]10)
    if ($rows.Count -ne 1 -or $rows[0] -notmatch '^(100644|100755) blob ([0-9a-fA-F]{40,64})\t(.+)$') {
        throw "Git release member is not one regular blob: $relative"
    }
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Matches[3]) $relative)) { throw "Git release member path mismatch. Expected '$relative', got '$($Matches[3])'." }
    return [pscustomobject][ordered]@{Mode=$Matches[1];ObjectId=$Matches[2].ToLowerInvariant();Path=$relative}
}

function Get-VllmReleaseSnapshotFile {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RelativePath)
    $relative = Assert-VllmReleaseCanonicalPath -RelativePath $RelativePath -Label 'Snapshot release member'
    $blob=Assert-VllmReleaseGitRegularBlob -Repository $Snapshot.Repository -Commit $Snapshot.Commit -RelativePath $relative
    $path = Join-Path $Snapshot.Root ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Snapshot release member is missing after git archive: $relative" }
    $materializedObject=Invoke-Git -Repository $Snapshot.Repository -Arguments @('hash-object','--no-filters',$path) -Capture
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$materializedObject) ([string]$blob.ObjectId))) { throw "Materialized release member bytes differ from the tagged Git blob: $relative" }
    $entry = Get-VllmPathEntryInfo -Path $path
    if ($entry.IsDirectory -or $entry.IsReparsePoint) { throw "Snapshot release member is not a regular non-reparse file: $relative" }
    return [pscustomobject][ordered]@{
        RelativePath=$relative
        Path=$path
        Identity=(Get-VllmReleaseFileIdentity -Path $path)
    }
}

function Get-VllmReleaseContext {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$ReleaseManifestPath)

    $releaseRelative = Assert-VllmReleaseCanonicalPath -RelativePath $ReleaseManifestPath -Label 'Release manifest path'
    $releaseFile = Get-VllmReleaseSnapshotFile -Snapshot $Snapshot -RelativePath $releaseRelative
    try { $release = Get-Content -LiteralPath $releaseFile.Path -Raw | ConvertFrom-Json }
    catch { throw "Release manifest JSON is invalid: $releaseRelative" }

    Assert-VllmReleaseExactProperties -Value $release -Expected @('schema_version','component','release','platform','self_path','upstream','windows_patchset','wheel','orchestration','managed_paths','files') -Label 'Release manifest'
    Assert-VllmReleaseExactProperties -Value $release.upstream -Expected @('repository','tag','commit') -Label 'Release upstream identity'
    Assert-VllmReleaseExactProperties -Value $release.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Release Windows patchset'
    Assert-VllmReleaseExactProperties -Value $release.wheel -Expected @('filename','version','size_bytes','sha256') -Label 'Release wheel identity'
    Assert-VllmReleaseExactProperties -Value $release.orchestration -Expected @('python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest','python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root') -Label 'Release orchestration'

    if ([int]$release.schema_version -ne 1 -or -not (Test-VllmReleaseOrdinalEqual ([string]$release.component) 'runtime-release') -or -not (Test-VllmReleaseOrdinalEqual ([string]$release.platform) 'windows-x86_64')) {
        throw 'Release manifest has unsupported schema/component/platform.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$release.release) -or [string]$release.release -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw 'Release identifier is invalid for publication.'
    }
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$release.self_path) $releaseRelative)) { throw 'Release manifest self_path does not match the selected manifest path.' }
    if (-not (Test-VllmReleaseOrdinalEqual ([IO.Path]::GetFileName([string]$release.wheel.filename)) ([string]$release.wheel.filename)) -or -not ([string]$release.wheel.filename).EndsWith('.whl',[StringComparison]::Ordinal)) {
        throw 'Release wheel filename must be a simple .whl filename.'
    }
    if ([int64]$release.wheel.size_bytes -lt 0 -or [string]$release.wheel.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Release wheel size/SHA-256 identity is invalid.'
    }

    $membersByKey = @{}
    $members = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($release.files)) {
        Assert-VllmReleaseExactProperties -Value $entry -Expected @('path','size_bytes','sha256') -Label 'Release distribution entry'
        $relative = Assert-VllmReleaseCanonicalPath -RelativePath ([string]$entry.path) -Label 'Release distribution path'
        if ($relative.Equals($releaseRelative,[StringComparison]::OrdinalIgnoreCase)) { throw 'Release manifest self_path must not also appear in release files.' }
        $key = $relative.ToLowerInvariant()
        if ($membersByKey.ContainsKey($key)) { throw "Release distribution paths collide by Windows identity: $relative" }
        if ([int64]$entry.size_bytes -lt 0 -or [string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Release distribution identity is invalid: $relative" }
        $file = Get-VllmReleaseSnapshotFile -Snapshot $Snapshot -RelativePath $relative
        if ($file.Identity.Size -ne [int64]$entry.size_bytes -or $file.Identity.Sha256 -ne ([string]$entry.sha256).ToUpperInvariant()) {
            throw "Tagged-commit blob does not match release manifest identity: $relative"
        }
        $member = [pscustomobject][ordered]@{RelativePath=$relative;Path=$file.Path;Size=$file.Identity.Size;Sha256=$file.Identity.Sha256}
        $membersByKey[$key] = $member
        $members.Add($member)
    }

    $selfKey = $releaseRelative.ToLowerInvariant()
    if ($membersByKey.ContainsKey($selfKey)) { throw 'Release manifest self path collides with a distribution path.' }
    $selfMember = [pscustomobject][ordered]@{RelativePath=$releaseRelative;Path=$releaseFile.Path;Size=$releaseFile.Identity.Size;Sha256=$releaseFile.Identity.Sha256}
    $membersByKey[$selfKey] = $selfMember
    $members.Add($selfMember)

    $runtimeRelative = Assert-VllmReleaseCanonicalPath -RelativePath ([string]$release.orchestration.runtime_manifest) -Label 'Runtime manifest path'
    $runtimeKey = $runtimeRelative.ToLowerInvariant()
    if (-not $membersByKey.ContainsKey($runtimeKey)) { throw 'Runtime manifest is not release-owned.' }
    try { $runtime = Get-Content -LiteralPath $membersByKey[$runtimeKey].Path -Raw | ConvertFrom-Json }
    catch { throw "Runtime manifest JSON is invalid: $runtimeRelative" }
    if ([int]$runtime.schema_version -ne 1 -or -not (Test-VllmReleaseOrdinalEqual ([string]$runtime.component) 'vllm-runtime') -or -not (Test-VllmReleaseOrdinalEqual ([string]$runtime.platform) ([string]$release.platform)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$runtime.milestone) ([string]$release.release))) {
        throw 'Runtime manifest identity does not match the release.'
    }

    Assert-VllmReleaseExactProperties -Value $runtime.project_wheel -Expected @('distribution','version','filename','size_bytes','sha256','python_tag','abi_tag','platform_tag','acquisition','dependency_install','native_extension_count','native_extensions') -Label 'Runtime project wheel'
    foreach ($name in @('filename','version','size_bytes','sha256')) {
        if (-not (Test-VllmReleaseOrdinalEqual ([string]$runtime.project_wheel.$name) ([string]$release.wheel.$name))) { throw 'Runtime and release manifests disagree on project wheel identity.' }
    }
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$runtime.project_wheel.distribution) 'vllm')) { throw 'Runtime project wheel distribution must be vllm.' }
    if ([int]$runtime.project_wheel.native_extension_count -ne @($runtime.project_wheel.native_extensions).Count) {
        throw 'Runtime project wheel native extension count is inconsistent.'
    }

    $nativeSeen = @{}
    $native = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($runtime.project_wheel.native_extensions)) {
        $canonical = (Assert-VllmSafeRelativePath -RelativePath ([string]$item) -Label 'Runtime native extension').Replace('\','/')
        $key = $canonical.ToLowerInvariant()
        if ($nativeSeen.ContainsKey($key)) { throw "Runtime native extension paths collide: $canonical" }
        $nativeSeen[$key] = $true
        $native.Add($canonical)
    }
    $nativeSorted = Get-VllmReleaseOrdinalStrings -Values $native.ToArray()

    $memberPaths = Get-VllmReleaseOrdinalStrings -Values @($members | ForEach-Object { $_.RelativePath })
    $sortedMembers = New-Object System.Collections.Generic.List[object]
    foreach ($path in $memberPaths) { $sortedMembers.Add($membersByKey[$path.ToLowerInvariant()]) }

    return [pscustomobject][ordered]@{
        Snapshot=$Snapshot
        Release=$release
        Runtime=$runtime
        ReleaseManifest=$selfMember
        RuntimeManifest=$membersByKey[$runtimeKey]
        Members=$sortedMembers.ToArray()
        NativeExtensions=$nativeSorted
        Tag=('release/' + [string]$release.release)
        BundleFilename=('vllm-windows-native-' + [string]$release.release + '.zip')
    }
}

function Get-VllmReleaseMetadataFieldValues {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Field)
    $prefix=$Field+':'
    $values=New-Object System.Collections.Generic.List[string]
    foreach($line in @($Text -split '\r?\n')){
        if(([string]$line).StartsWith($prefix,[StringComparison]::Ordinal)){
            $raw=([string]$line).Substring($prefix.Length)
            $values.Add($raw.Trim([char[]]@([char]32,[char]9)))
        }
    }
    return $values.ToArray()
}

function Assert-VllmReleaseWheel {
    param([Parameter(Mandatory)][string]$WheelPath,[Parameter(Mandatory)]$Context)

    $resolved = [IO.Path]::GetFullPath($WheelPath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Provided release wheel is missing: $resolved" }
    $entry = Get-VllmPathEntryInfo -Path $resolved
    if ($entry.IsReparsePoint -or $entry.IsDirectory) { throw "Provided release wheel must be a regular non-reparse file: $resolved" }
    $physical=Get-VllmCanonicalExistingPath -Path $resolved -Format Dos
    if (-not $physical.Equals($resolved,[StringComparison]::OrdinalIgnoreCase)) { throw "Provided release wheel resolves through a filesystem alias: $resolved -> $physical" }

    $runtimeWheel = $Context.Runtime.project_wheel
    $identity = Get-VllmReleaseFileIdentity -Path $resolved
    if (-not (Test-VllmReleaseOrdinalEqual -Actual ([IO.Path]::GetFileName($resolved)) -Expected ([string]$runtimeWheel.filename))) { throw 'Provided release wheel filename mismatch.' }
    if ($identity.Size -ne [int64]$runtimeWheel.size_bytes -or $identity.Sha256 -ne ([string]$runtimeWheel.sha256).ToUpperInvariant()) {
        throw 'Provided release wheel size/SHA-256 mismatch.'
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($resolved)
    try {
        $seen = @{}
        foreach ($z in @($zip.Entries)) {
            $name = Assert-VllmReleaseCanonicalPath -RelativePath ([string]$z.FullName) -Label 'Provided release wheel member'
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "Provided release wheel contains duplicate/case-colliding member: $name" }
            $seen[$key] = $true
        }

        $distInfoPrefix = 'vllm-' + [string]$runtimeWheel.version + '.dist-info/'
        $metadataName = $distInfoPrefix + 'METADATA'
        $wheelName = $distInfoPrefix + 'WHEEL'
        $metadataEntries = @($zip.Entries | Where-Object { [string]::Equals([string]$_.FullName,$metadataName,[StringComparison]::Ordinal) })
        $wheelEntries = @($zip.Entries | Where-Object { [string]::Equals([string]$_.FullName,$wheelName,[StringComparison]::Ordinal) })
        if ($metadataEntries.Count -ne 1 -or $wheelEntries.Count -ne 1) { throw 'Provided release wheel must contain the exact canonical METADATA and WHEEL entries.' }

        $metadataReader = New-Object IO.StreamReader($metadataEntries[0].Open())
        try { $metadata = $metadataReader.ReadToEnd() } finally { $metadataReader.Dispose() }
        $wheelReader = New-Object IO.StreamReader($wheelEntries[0].Open())
        try { $wheelMetadata = $wheelReader.ReadToEnd() } finally { $wheelReader.Dispose() }

        $nameValues=@(Get-VllmReleaseMetadataFieldValues -Text $metadata -Field 'Name')
        if($nameValues.Count-ne1-or-not(Test-VllmReleaseOrdinalEqual $nameValues[0] 'vllm')){throw 'Provided release wheel distribution name is not vllm.'}
        $versionValues=@(Get-VllmReleaseMetadataFieldValues -Text $metadata -Field 'Version')
        if($versionValues.Count-ne1-or-not(Test-VllmReleaseOrdinalEqual $versionValues[0] ([string]$runtimeWheel.version))){throw 'Provided release wheel version does not match runtime manifest.'}
        $expectedTag=[string]$runtimeWheel.python_tag+'-'+[string]$runtimeWheel.abi_tag+'-'+[string]$runtimeWheel.platform_tag
        $tagValues=@(Get-VllmReleaseMetadataFieldValues -Text $wheelMetadata -Field 'Tag')
        $tagFound=$false
        foreach($value in $tagValues){if(Test-VllmReleaseOrdinalEqual ([string]$value) $expectedTag){$tagFound=$true;break}}
        if(-not$tagFound){throw "Provided release wheel compatibility tag is missing: Tag: $expectedTag"}

        $actualNative = @($zip.Entries | Where-Object { ([string]$_.FullName).EndsWith('.pyd',[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [string]$_.FullName })
        $actualNative = Get-VllmReleaseOrdinalStrings -Values $actualNative
        if (@($actualNative).Count -ne [int]$runtimeWheel.native_extension_count) { throw 'Provided release wheel native extension count does not match runtime manifest.' }
        Assert-VllmReleaseOrdinalSequence -Actual @($actualNative) -Expected @($Context.NativeExtensions) -Label 'Provided release wheel native extension set'

        foreach ($z in @($zip.Entries)) {
            $stream = $z.Open()
            try {
                $buffer = New-Object byte[] 65536
                while ($stream.Read($buffer,0,$buffer.Length) -gt 0) {}
            } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }

    return [pscustomobject][ordered]@{Path=$resolved;Filename=[IO.Path]::GetFileName($resolved);Size=$identity.Size;Sha256=$identity.Sha256}
}

function ConvertTo-VllmReleaseJsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -eq 34) { [void]$builder.Append('\"') }
        elseif ($code -eq 92) { [void]$builder.Append('\\') }
        elseif ($code -eq 8) { [void]$builder.Append('\b') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 12) { [void]$builder.Append('\f') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32) { [void]$builder.Append(('\u{0:X4}' -f $code)) }
        else { [void]$builder.Append($ch) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}


function ConvertTo-VllmReleaseCanonicalJsonValue {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-VllmReleaseJsonString -Value $Value }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]) {
        return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in $Value.Keys) {
            $parts.Add((ConvertTo-VllmReleaseJsonString -Value ([string]$key)) + ':' + (ConvertTo-VllmReleaseCanonicalJsonValue -Value $Value[$key]))
        }
        return '{' + ($parts.ToArray() -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable] -and -not ($Value -is [string])) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) { $parts.Add((ConvertTo-VllmReleaseCanonicalJsonValue -Value $item)) }
        return '[' + ($parts.ToArray() -join ',') + ']'
    }
    if ($Value -is [psobject]) {
        $ordered = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) { $ordered[$prop.Name] = $prop.Value }
        return ConvertTo-VllmReleaseCanonicalJsonValue -Value $ordered
    }
    throw "Unsupported canonical JSON value type: $($Value.GetType().FullName)"
}

function Write-VllmReleaseCanonicalJson {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path)
    $json = (ConvertTo-VllmReleaseCanonicalJsonValue -Value $Value) + [char]10
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}

function Get-VllmReleaseCrc32Table {
    if ($null -ne $script:VllmReleaseCrc32Table) { return $script:VllmReleaseCrc32Table }
    $poly = [Convert]::ToUInt32('EDB88320',16)
    $table = New-Object 'UInt32[]' 256
    for ($i=0; $i -lt 256; $i++) {
        [uint32]$c = $i
        for ($j=0; $j -lt 8; $j++) {
            if (($c -band 1) -ne 0) { $c = [uint32](($c -shr 1) -bxor $poly) }
            else { $c = [uint32]($c -shr 1) }
        }
        $table[$i] = $c
    }
    $script:VllmReleaseCrc32Table = $table
    return $table
}

function Get-VllmReleaseFileCrc32 {
    param([Parameter(Mandatory)][string]$Path)
    $table = Get-VllmReleaseCrc32Table
    [uint32]$crc = [uint32]::MaxValue
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 65536
        while (($read = $stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            for ($i=0; $i -lt $read; $i++) {
                $index = [int](($crc -bxor [uint32]$buffer[$i]) -band [uint32]255)
                $crc = [uint32]($table[$index] -bxor ($crc -shr 8))
            }
        }
    } finally { $stream.Dispose() }
    return [uint32](-bnot $crc)
}

function Write-VllmReleaseStoredZip {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { throw "Release ZIP already exists: $Path" }
    if (@($Context.Members).Count -gt [uint16]::MaxValue) { throw 'Release ZIP has too many members for canonical ZIP v1.' }

    $utf8 = New-Object Text.UTF8Encoding($false)
    $records = New-Object System.Collections.Generic.List[object]
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream,$utf8,$true)
    try {
        foreach ($member in @($Context.Members)) {
            $nameBytes = $utf8.GetBytes([string]$member.RelativePath)
            if ($nameBytes.Length -gt [uint16]::MaxValue) { throw "Release ZIP member name is too long: $($member.RelativePath)" }
            if ([int64]$member.Size -gt [uint32]::MaxValue) { throw "Release ZIP member is too large for canonical ZIP v1: $($member.RelativePath)" }
            if ($stream.Position -gt [uint32]::MaxValue) { throw 'Release ZIP exceeds canonical ZIP v1 offset limit.' }
            [uint32]$crc = Get-VllmReleaseFileCrc32 -Path ([string]$member.Path)
            [uint32]$size = [uint32][int64]$member.Size
            [uint32]$offset = [uint32]$stream.Position

            $writer.Write([uint32]0x04034b50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]33)
            $writer.Write([uint32]$crc)
            $writer.Write([uint32]$size)
            $writer.Write([uint32]$size)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write($nameBytes)

            $source = [IO.File]::OpenRead([string]$member.Path)
            try { $source.CopyTo($stream) } finally { $source.Dispose() }

            $records.Add([pscustomobject][ordered]@{
                NameBytes=$nameBytes
                Crc32=$crc
                Size=$size
                Offset=$offset
            })
        }

        if ($stream.Position -gt [uint32]::MaxValue) { throw 'Release ZIP exceeds canonical ZIP v1 central-directory offset limit.' }
        [uint32]$centralOffset = [uint32]$stream.Position
        foreach ($record in $records) {
            $writer.Write([uint32]0x02014b50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]33)
            $writer.Write([uint32]$record.Crc32)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.Offset)
            $writer.Write([byte[]]$record.NameBytes)
        }
        $centralLength = $stream.Position - [int64]$centralOffset
        if ($centralLength -gt [uint32]::MaxValue) { throw 'Release ZIP central directory exceeds canonical ZIP v1 limit.' }

        $writer.Write([uint32]0x06054b50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint32]$centralLength)
        $writer.Write([uint32]$centralOffset)
        $writer.Write([uint16]0)
        $writer.Flush()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Write-VllmReleaseCanonicalZip {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Path)
    Write-VllmReleaseStoredZip -Context $Context -Path $Path
    Assert-VllmReleaseCanonicalZip -Context $Context -Path $Path
    return Get-VllmReleaseFileIdentity -Path $Path
}

function Assert-VllmReleaseRawZipProfile {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Path)
    $b=[IO.File]::ReadAllBytes($Path);if($b.Length-lt22){throw 'Release ZIP is too short.'}
    $e=-1;for($i=$b.Length-22;$i-ge[Math]::Max(0,$b.Length-65557);$i--){if([BitConverter]::ToUInt32($b,$i)-eq[uint32]0x06054b50){$e=$i;break}}
    if($e-lt0){throw 'Release ZIP EOCD is missing.'}
    $count=[int][BitConverter]::ToUInt16($b,$e+10);$co=[int64][BitConverter]::ToUInt32($b,$e+16);$cl=[int64][BitConverter]::ToUInt32($b,$e+12)
    if([BitConverter]::ToUInt16($b,$e+4)-ne0-or[BitConverter]::ToUInt16($b,$e+6)-ne0-or[BitConverter]::ToUInt16($b,$e+8)-ne$count-or$count-ne@($Context.Members).Count){throw 'Release ZIP EOCD profile is not canonical.'}
    if([BitConverter]::ToUInt16($b,$e+20)-ne0-or$e+22-ne$b.Length-or$co+$cl-ne$e){throw 'Release ZIP archive comment/trailing extent is not canonical.'}
    $u=New-Object Text.UTF8Encoding($false,$true);$p=[int64]$co;$expectedLocalOffset=[int64]0
    for($n=0;$n-lt$count;$n++){
        if($p+46-gt$e-or[BitConverter]::ToUInt32($b,[int]$p)-ne[uint32]0x02014b50){throw "Release ZIP central record invalid at index $n."}
        $made=[BitConverter]::ToUInt16($b,[int]$p+4);$needed=[BitConverter]::ToUInt16($b,[int]$p+6);$flags=[BitConverter]::ToUInt16($b,[int]$p+8);$method=[BitConverter]::ToUInt16($b,[int]$p+10);$time=[BitConverter]::ToUInt16($b,[int]$p+12);$date=[BitConverter]::ToUInt16($b,[int]$p+14);$crc=[BitConverter]::ToUInt32($b,[int]$p+16);$compressed=[BitConverter]::ToUInt32($b,[int]$p+20);$size=[BitConverter]::ToUInt32($b,[int]$p+24)
        $nl=[int][BitConverter]::ToUInt16($b,[int]$p+28);$xl=[int][BitConverter]::ToUInt16($b,[int]$p+30);$ml=[int][BitConverter]::ToUInt16($b,[int]$p+32);$disk=[BitConverter]::ToUInt16($b,[int]$p+34);$internal=[BitConverter]::ToUInt16($b,[int]$p+36);$ext=[BitConverter]::ToUInt32($b,[int]$p+38);$lo=[int64][BitConverter]::ToUInt32($b,[int]$p+42)
        $member=$Context.Members[$n];$expectedCrc=[uint32](Get-VllmReleaseFileCrc32 -Path ([string]$member.Path))
        if($made-ne20-or$needed-ne20-or$flags-ne0x0800-or$method-ne0-or$time-ne0-or$date-ne33-or$crc-ne$expectedCrc-or$compressed-ne$size-or[uint64]$size-ne[uint64][int64]$member.Size-or$xl-ne0-or$ml-ne0-or$disk-ne0-or$internal-ne0-or$ext-ne0){throw "Release ZIP central profile is not canonical at index $n."}
        $name=$u.GetString($b,[int]$p+46,$nl);if(-not(Test-VllmReleaseOrdinalEqual $name ([string]$member.RelativePath))){throw "Release ZIP raw member mismatch at index $n."}
        if($lo-ne$expectedLocalOffset-or$lo+30-gt$co-or[BitConverter]::ToUInt32($b,[int]$lo)-ne[uint32]0x04034b50-or[BitConverter]::ToUInt16($b,[int]$lo+4)-ne20-or[BitConverter]::ToUInt16($b,[int]$lo+6)-ne0x0800-or[BitConverter]::ToUInt16($b,[int]$lo+8)-ne0-or[BitConverter]::ToUInt16($b,[int]$lo+10)-ne0-or[BitConverter]::ToUInt16($b,[int]$lo+12)-ne33-or[BitConverter]::ToUInt32($b,[int]$lo+14)-ne$crc-or[BitConverter]::ToUInt32($b,[int]$lo+18)-ne$size-or[BitConverter]::ToUInt32($b,[int]$lo+22)-ne$size-or[BitConverter]::ToUInt16($b,[int]$lo+26)-ne$nl-or[BitConverter]::ToUInt16($b,[int]$lo+28)-ne0){throw "Release ZIP local profile is not canonical: $name"}
        if(-not(Test-VllmReleaseOrdinalEqual ($u.GetString($b,[int]$lo+30,$nl)) $name)){throw "Release ZIP local/central names disagree: $name"}
        $expectedLocalOffset=$lo+30+$nl+[int64]$size
        if($expectedLocalOffset-gt$co){throw "Release ZIP local data extent overlaps the central directory: $name"}
        $p+=46+$nl
    }
    if($p-ne$e-or$expectedLocalOffset-ne$co){throw 'Release ZIP parsed extents are not canonical.'}
}
function Assert-VllmReleaseCanonicalZip {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Path)
    $canonicalTemp=Join-Path ([IO.Path]::GetTempPath()) ('vllm-release-canonical-'+[guid]::NewGuid().ToString('N')+'.zip')
    try {
        Write-VllmReleaseStoredZip -Context $Context -Path $canonicalTemp
        $expectedIdentity=Get-VllmReleaseFileIdentity -Path $canonicalTemp
        $actualIdentity=Get-VllmReleaseFileIdentity -Path $Path
        if ($actualIdentity.Size -ne $expectedIdentity.Size -or $actualIdentity.Sha256 -ne $expectedIdentity.Sha256) { throw 'Release ZIP bytes are not the exact canonical tagged-commit bundle.' }
    } finally { Remove-Item -LiteralPath $canonicalTemp -Force -ErrorAction SilentlyContinue }
    Assert-VllmReleaseRawZipProfile -Context $Context -Path $Path
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $actualNames = @($zip.Entries | ForEach-Object { $_.FullName })
        $expectedNames = @($Context.Members | ForEach-Object { $_.RelativePath })
        if ($actualNames.Count -ne $expectedNames.Count) { throw 'Release ZIP member count mismatch.' }
        for ($i=0; $i -lt $expectedNames.Count; $i++) {
            if (-not (Test-VllmReleaseOrdinalEqual ([string]$actualNames[$i]) ([string]$expectedNames[$i]))) { throw "Release ZIP ordering/member mismatch at index $i." }
        }
        $seen = @{}
        for ($i=0; $i -lt $zip.Entries.Count; $i++) {
            $entry = $zip.Entries[$i]
            $name = Assert-VllmReleaseCanonicalPath -RelativePath ([string]$entry.FullName) -Label 'Release ZIP member'
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "Release ZIP contains duplicate/case-colliding member: $name" }
            $seen[$key] = $true

            if ($entry.ExternalAttributes -ne 0) { throw "Release ZIP member external attributes are not canonical: $name" }
            $expected = $Context.Members[$i]
            if ([int64]$entry.Length -ne [int64]$expected.Size) { throw "Release ZIP member size mismatch: $name" }
            if ([int64]$entry.CompressedLength -ne [int64]$entry.Length) { throw "Release ZIP member is not stored without compression: $name" }
            $stream = $entry.Open()
            try { $hash = Get-VllmReleaseStreamSha256 -Stream $stream } finally { $stream.Dispose() }
            if ($hash -ne [string]$expected.Sha256) { throw "Release ZIP member SHA-256 mismatch: $name" }
        }
    } finally { $zip.Dispose() }
}

function Get-VllmReleaseIndex {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Wheel,[Parameter(Mandatory)]$Bundle)

    $native = @($Context.NativeExtensions)
    return [ordered]@{
        schema_version=1
        component='vllm-windows-native-release-index'
        platform=[string]$Context.Release.platform
        release=[string]$Context.Release.release
        tag=[string]$Context.Tag
        project_commit=[string]$Context.Snapshot.Commit
        release_manifest=[ordered]@{
            path=[string]$Context.ReleaseManifest.RelativePath
            size_bytes=[int64]$Context.ReleaseManifest.Size
            sha256=[string]$Context.ReleaseManifest.Sha256
        }
        runtime_manifest=[ordered]@{
            path=[string]$Context.RuntimeManifest.RelativePath
            size_bytes=[int64]$Context.RuntimeManifest.Size
            sha256=[string]$Context.RuntimeManifest.Sha256
        }
        upstream=[ordered]@{
            repository=[string]$Context.Release.upstream.repository
            tag=[string]$Context.Release.upstream.tag
            commit=[string]$Context.Release.upstream.commit
        }
        windows_patchset=[ordered]@{
            implementation_commit=[string]$Context.Release.windows_patchset.implementation_commit
            tree=[string]$Context.Release.windows_patchset.tree
            patch_sha256=([string]$Context.Release.windows_patchset.patch_sha256).ToUpperInvariant()
        }
        wheel=[ordered]@{
            filename=[string]$Wheel.Filename
            version=[string]$Context.Runtime.project_wheel.version
            size_bytes=[int64]$Wheel.Size
            sha256=[string]$Wheel.Sha256
            python_tag=[string]$Context.Runtime.project_wheel.python_tag
            abi_tag=[string]$Context.Runtime.project_wheel.abi_tag
            platform_tag=[string]$Context.Runtime.project_wheel.platform_tag
            native_extension_count=[int]$Context.Runtime.project_wheel.native_extension_count
            native_extensions=$native
        }
        bundle=[ordered]@{
            filename=[string]$Context.BundleFilename
            size_bytes=[int64]$Bundle.Size
            sha256=[string]$Bundle.Sha256
        }
        checksums=[ordered]@{
            filename='SHA256SUMS'
            algorithm='SHA256'
            format='sha256-two-space-v1'
        }
        preparation=[ordered]@{
            source_commit=[string]$Context.Snapshot.Commit
            tool_path='release.ps1'
        }
    }
}

function Read-VllmReleaseUtf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "$Label must be UTF-8 without BOM." }
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    try { return $utf8.GetString($bytes) } catch { throw "$Label is not valid UTF-8." }
}

function Write-VllmReleaseChecksums {
    param(
        [Parameter(Mandatory)][hashtable]$Identities,
        [Parameter(Mandatory)][string]$Path
    )
    $names = Get-VllmReleaseOrdinalStrings -Values @($Identities.Keys)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        if ([IO.Path]::GetFileName([string]$name) -ne [string]$name) { throw "Checksum member must be a simple filename: $name" }
        $sha = [string]$Identities[$name]
        if ($sha -notmatch '^[0-9A-F]{64}$') { throw "Checksum SHA-256 is invalid for $name." }
        $lines.Add($sha + '  ' + [string]$name)
    }
    [IO.File]::WriteAllText($Path,($lines.ToArray() -join [char]10) + [char]10,[Text.UTF8Encoding]::new($false))
}

function Read-VllmReleaseChecksums {
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-VllmReleaseUtf8NoBom -Path $Path -Label 'SHA256SUMS'
    if ($text.Contains([char]13) -or -not $text.EndsWith([string][char]10,[StringComparison]::Ordinal)) { throw 'SHA256SUMS must be LF-terminated UTF-8 text.' }
    $map = @{}
    $inputNames = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($text.TrimEnd([char]10) -split [char]10)) {
        if ($line -notmatch '^([0-9A-F]{64})  ([^/\\]+)$') { throw "Invalid SHA256SUMS line: $line" }
        $name = $Matches[2]
        $inputNames.Add($name)
        $key = $name.ToLowerInvariant()
        if ($map.ContainsKey($key)) { throw "Duplicate/case-colliding SHA256SUMS member: $name" }
        $map[$key] = [pscustomobject][ordered]@{Filename=$name;Sha256=$Matches[1]}
    }
    $sortedNames = Get-VllmReleaseOrdinalStrings -Values $inputNames.ToArray()
    if ($sortedNames.Count -ne $inputNames.Count) { throw 'SHA256SUMS ordering check failed.' }
    for ($i=0; $i -lt $sortedNames.Count; $i++) {
        if (-not (Test-VllmReleaseOrdinalEqual ([string]$sortedNames[$i]) ([string]$inputNames[$i]))) { throw 'SHA256SUMS entries are not in canonical ordinal order.' }
    }
    return $map
}

function Assert-VllmReleaseIndex {
    param([Parameter(Mandatory)]$Index,[Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Wheel,[Parameter(Mandatory)]$Bundle)

    Assert-VllmReleaseExactProperties -Value $Index -Expected @('schema_version','component','platform','release','tag','project_commit','release_manifest','runtime_manifest','upstream','windows_patchset','wheel','bundle','checksums','preparation') -Label 'Release index'
    if ([int]$Index.schema_version -ne 1 -or -not (Test-VllmReleaseOrdinalEqual -Actual ([string]$Index.component) -Expected 'vllm-windows-native-release-index')) { throw 'Release index identity is unsupported.' }
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.platform) ([string]$Context.Release.platform)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.release) ([string]$Context.Release.release)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.tag) ([string]$Context.Tag)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.project_commit) ([string]$Context.Snapshot.Commit))) {
        throw 'Release index project/release identity mismatch.'
    }

    foreach ($pair in @(
        @($Index.release_manifest,$Context.ReleaseManifest,'release manifest'),
        @($Index.runtime_manifest,$Context.RuntimeManifest,'runtime manifest')
    )) {
        $value=$pair[0];$expected=$pair[1];$label=[string]$pair[2]
        Assert-VllmReleaseExactProperties -Value $value -Expected @('path','size_bytes','sha256') -Label "Release index $label"
        if (-not (Test-VllmReleaseOrdinalEqual ([string]$value.path) ([string]$expected.RelativePath)) -or [int64]$value.size_bytes -ne [int64]$expected.Size -or -not (Test-VllmReleaseOrdinalEqual ([string]$value.sha256) ([string]$expected.Sha256))) { throw "Release index $label identity mismatch." }
    }

    Assert-VllmReleaseExactProperties -Value $Index.wheel -Expected @('filename','version','size_bytes','sha256','python_tag','abi_tag','platform_tag','native_extension_count','native_extensions') -Label 'Release index wheel'
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.filename) ([string]$Wheel.Filename)) -or [int64]$Index.wheel.size_bytes -ne [int64]$Wheel.Size -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.sha256) ([string]$Wheel.Sha256))) { throw 'Release index wheel file identity mismatch.' }
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.version) ([string]$Context.Runtime.project_wheel.version)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.python_tag) ([string]$Context.Runtime.project_wheel.python_tag)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.abi_tag) ([string]$Context.Runtime.project_wheel.abi_tag)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.wheel.platform_tag) ([string]$Context.Runtime.project_wheel.platform_tag))) { throw 'Release index wheel metadata mismatch.' }
    $indexNative = @($Index.wheel.native_extensions)
    if ([int]$Index.wheel.native_extension_count -ne @($Context.NativeExtensions).Count) { throw 'Release index native extension count mismatch.' }
    Assert-VllmReleaseOrdinalSequence -Actual $indexNative -Expected @($Context.NativeExtensions) -Label 'Release index native extension set'

    Assert-VllmReleaseExactProperties -Value $Index.bundle -Expected @('filename','size_bytes','sha256') -Label 'Release index bundle'
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.bundle.filename) ([string]$Context.BundleFilename)) -or [int64]$Index.bundle.size_bytes -ne [int64]$Bundle.Size -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.bundle.sha256) ([string]$Bundle.Sha256))) { throw 'Release index bundle identity mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.checksums -Expected @('filename','algorithm','format') -Label 'Release index checksums'
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.checksums.filename) 'SHA256SUMS') -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.checksums.algorithm) 'SHA256') -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.checksums.format) 'sha256-two-space-v1')) { throw 'Release index checksum contract mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.preparation -Expected @('source_commit','tool_path') -Label 'Release index preparation'
    if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.preparation.source_commit) ([string]$Context.Snapshot.Commit)) -or -not (Test-VllmReleaseOrdinalEqual ([string]$Index.preparation.tool_path) 'release.ps1')) { throw 'Release index preparation identity mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.upstream -Expected @('repository','tag','commit') -Label 'Release index upstream'
    Assert-VllmReleaseExactProperties -Value $Index.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Release index Windows patchset'
    foreach ($name in @('repository','tag','commit')) { if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.upstream.$name) ([string]$Context.Release.upstream.$name))) { throw 'Release index upstream identity mismatch.' } }
    foreach ($name in @('implementation_commit','tree','patch_sha256')) {
        $expectedPatchValue = if ($name -eq 'patch_sha256') { ([string]$Context.Release.windows_patchset.$name).ToUpperInvariant() } else { [string]$Context.Release.windows_patchset.$name }
        if (-not (Test-VllmReleaseOrdinalEqual ([string]$Index.windows_patchset.$name) $expectedPatchValue)) { throw 'Release index Windows patchset identity mismatch.' }
    }
}

function Assert-VllmOfflineRelease {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$ReleaseManifestPath,
        [Parameter(Mandatory)][string]$ArtifactsDirectory
    )
    $snapshot = Get-VllmReleaseGitSnapshot -Repository $Repository -Commit $ProjectCommit
    try {
        $context = Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $ReleaseManifestPath
        $root = [IO.Path]::GetFullPath($ArtifactsDirectory)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Release artifacts directory is missing: $root" }
        $rootEntry=Get-VllmPathEntryInfo -Path $root
        if ($rootEntry.IsReparsePoint) { throw "Release artifacts directory must not be a reparse point: $root" }
        $rootPhysical=Get-VllmCanonicalExistingPath -Path $root -Format Dos
        if (-not $rootPhysical.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { throw "Release artifacts directory resolves through a filesystem alias: $root -> $rootPhysical" }

        $expectedNames = @([string]$context.Release.wheel.filename,[string]$context.BundleFilename,'release-index.json','SHA256SUMS')
        $expectedNames = Get-VllmReleaseOrdinalStrings -Values $expectedNames
        $actualFiles = @(Get-ChildItem -LiteralPath $root -Force)
        if (@($actualFiles | Where-Object { $_.PSIsContainer -or $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) { throw 'Release artifacts directory contains a directory or reparse point.' }
        $actualNames = Get-VllmReleaseOrdinalStrings -Values @($actualFiles | ForEach-Object { $_.Name })
        Assert-VllmReleaseOrdinalSequence -Actual $actualNames -Expected $expectedNames -Label 'Release artifact filename set'

        $wheel = Assert-VllmReleaseWheel -WheelPath (Join-Path $root ([string]$context.Release.wheel.filename)) -Context $context
        $bundlePath = Join-Path $root ([string]$context.BundleFilename)
        Assert-VllmReleaseCanonicalZip -Context $context -Path $bundlePath
        $bundle = Get-VllmReleaseFileIdentity -Path $bundlePath

        $indexPath = Join-Path $root 'release-index.json'
        $indexText=Read-VllmReleaseUtf8NoBom -Path $indexPath -Label 'release-index.json'
        $expectedIndex=Get-VllmReleaseIndex -Context $context -Wheel $wheel -Bundle $bundle
        $canonicalIndexText=(ConvertTo-VllmReleaseCanonicalJsonValue -Value $expectedIndex)+[char]10
        if (-not $indexText.Equals($canonicalIndexText,[StringComparison]::Ordinal)) { throw 'release-index.json does not exactly match the canonical index for these verified inputs.' }
        try { $index = $indexText | ConvertFrom-Json } catch { throw 'release-index.json is invalid JSON.' }
        Assert-VllmReleaseIndex -Index $index -Context $context -Wheel $wheel -Bundle $bundle

        $checksums = Read-VllmReleaseChecksums -Path (Join-Path $root 'SHA256SUMS')
        $expectedChecksumNames = @([string]$wheel.Filename,[string]$context.BundleFilename,'release-index.json')
        if ($checksums.Count -ne 3) { throw 'SHA256SUMS must contain exactly three payload entries.' }
        foreach ($name in $expectedChecksumNames) {
            $key = $name.ToLowerInvariant()
            if (-not $checksums.ContainsKey($key)) { throw "SHA256SUMS is missing asset: $name" }
            $actual = Get-VllmReleaseFileIdentity -Path (Join-Path $root $name)
            if (-not (Test-VllmReleaseOrdinalEqual ([string]$checksums[$key].Filename) $name) -or -not (Test-VllmReleaseOrdinalEqual ([string]$checksums[$key].Sha256) ([string]$actual.Sha256))) { throw "SHA256SUMS identity mismatch: $name" }
        }

        return [pscustomobject][ordered]@{
            schema_version=1
            component='vllm-windows-native-offline-verification'
            release=[string]$context.Release.release
            tag=[string]$context.Tag
            project_commit=[string]$snapshot.Commit
            wheel_sha256=[string]$wheel.Sha256
            bundle_sha256=[string]$bundle.Sha256
            index_sha256=(Get-VllmReleaseFileIdentity -Path $indexPath).Sha256
            checksums_sha256=(Get-VllmReleaseFileIdentity -Path (Join-Path $root 'SHA256SUMS')).Sha256
            member_count=@($context.Members).Count
        }
    } finally { Close-VllmReleaseGitSnapshot -Snapshot $snapshot }
}

function Enter-VllmReleasePreparationLock {
    param([Parameter(Mandatory)][string]$ArtifactsDirectory)

    $root = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::GetFullPath($ArtifactsDirectory))
    $parent = [IO.Path]::GetDirectoryName($root)
    $leaf = [IO.Path]::GetFileName($root)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf)) {
        throw "Release artifacts directory must have a parent and leaf name: $root"
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Release artifacts parent directory is missing: $parent"
    }

    $lockName = '.' + $leaf + '.vllm-release-prepare.lock'
    $lockPath = [IO.Path]::Combine($parent,$lockName)
    try {
        $stream = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
        throw "Another offline release preparation is active for '$root'."
    } catch [UnauthorizedAccessException] {
        throw "Release preparation lock cannot be acquired safely: $lockPath"
    }

    try {
        $parentPhysical = Get-VllmPhysicalCandidatePath -Path $parent -Format Guid
        $expectedPhysical = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($parentPhysical,$lockName))
        $actualPhysical = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if (-not $actualPhysical.Equals($expectedPhysical,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Release preparation lock resolves outside expected location '$lockPath': $actualPhysical"
        }
        $linkCount = [VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)
        if ($linkCount -ne 1) {
            throw "Release preparation lock has unexpected hard-link count $linkCount; refusing to use it: $lockPath"
        }

        $stream.SetLength(0)
        $writer = New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)),1024,$true)
        try {
            $writer.WriteLine('operation=release-prepare')
            $writer.WriteLine("root=$root")
            $writer.WriteLine("pid=$PID")
            $writer.WriteLine("started=$((Get-Date).ToString('o'))")
            $writer.Flush()
            $stream.Flush()
        } finally { $writer.Dispose() }

        return [pscustomobject][ordered]@{
            Stream=$stream
            Path=$lockPath
            Root=$root
        }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Exit-VllmReleasePreparationLock {
    param([Parameter(Mandatory)]$Lock)
    if ($null -ne $Lock.Stream) { $Lock.Stream.Dispose() }
    # Deliberately retain the sidecar coordination file. Reusing one stable path
    # avoids a close/delete/recreate race while keeping it outside release assets.
}

function Write-VllmOfflineRelease {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$ReleaseManifestPath,
        [Parameter(Mandatory)][string]$WheelPath,
        [Parameter(Mandatory)][string]$ArtifactsDirectory,
        [ValidateSet('None','DuringWheelCopy','AfterWheelCopy','AfterBundle')][string]$FaultPoint='None'
    )
    $root = [IO.Path]::GetFullPath($ArtifactsDirectory)
    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Release artifacts path is not a directory: $root" }
        $rootEntry=Get-VllmPathEntryInfo -Path $root
        if ($rootEntry.IsReparsePoint) { throw "Release artifacts directory must not be a reparse point: $root" }
    } else { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $rootPhysical=Get-VllmCanonicalExistingPath -Path $root -Format Dos
    if (-not $rootPhysical.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { throw "Release artifacts directory resolves through a filesystem alias: $root -> $rootPhysical" }

    $prepareLock=Enter-VllmReleasePreparationLock -ArtifactsDirectory $root
    try {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Release artifacts directory disappeared while acquiring preparation lock: $root" }
        $rootEntry=Get-VllmPathEntryInfo -Path $root
        if ($rootEntry.IsReparsePoint) { throw "Release artifacts directory became a reparse point: $root" }
        $rootPhysical=Get-VllmCanonicalExistingPath -Path $root -Format Dos
        if (-not $rootPhysical.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { throw "Release artifacts directory changed filesystem identity while acquiring preparation lock: $root -> $rootPhysical" }
        $entries=@(Get-ChildItem -LiteralPath $root -Force)
        if ($entries.Count -gt 0) { throw "Release artifacts directory is not empty: $root" }

    $createdPaths=New-Object System.Collections.Generic.List[string]
    $snapshot = Get-VllmReleaseGitSnapshot -Repository $Repository -Commit $ProjectCommit
    try {
        $context = Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $ReleaseManifestPath
        $wheel = Assert-VllmReleaseWheel -WheelPath $WheelPath -Context $context

        $destWheel = Join-Path $root ([string]$wheel.Filename)
        if ([IO.Path]::GetFullPath($wheel.Path).Equals([IO.Path]::GetFullPath($destWheel),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Source wheel must be outside the release artifacts directory during preparation.'
        }
        $createdPaths.Add($destWheel)
        if($FaultPoint-eq'DuringWheelCopy'){
            [IO.File]::WriteAllBytes($destWheel,[byte[]](1,2,3,4))
            throw 'FAULT_INJECTED:DuringWheelCopy'
        }
        Copy-Item -LiteralPath $wheel.Path -Destination $destWheel
        $copiedWheel = Assert-VllmReleaseWheel -WheelPath $destWheel -Context $context
        if($FaultPoint-eq'AfterWheelCopy'){throw 'FAULT_INJECTED:AfterWheelCopy'}

        $bundlePath = Join-Path $root ([string]$context.BundleFilename)
        $createdPaths.Add($bundlePath)
        $bundle = Write-VllmReleaseCanonicalZip -Context $context -Path $bundlePath
        if($FaultPoint-eq'AfterBundle'){throw 'FAULT_INJECTED:AfterBundle'}

        $index = Get-VllmReleaseIndex -Context $context -Wheel $copiedWheel -Bundle $bundle
        $indexPath = Join-Path $root 'release-index.json'
        $createdPaths.Add($indexPath)
        Write-VllmReleaseCanonicalJson -Value $index -Path $indexPath
        $indexIdentity = Get-VllmReleaseFileIdentity -Path $indexPath

        $sumPath = Join-Path $root 'SHA256SUMS'
        $createdPaths.Add($sumPath)
        $identities = @{
            ([string]$copiedWheel.Filename)=[string]$copiedWheel.Sha256
            ([string]$context.BundleFilename)=[string]$bundle.Sha256
            'release-index.json'=[string]$indexIdentity.Sha256
        }
        Write-VllmReleaseChecksums -Identities $identities -Path $sumPath

        return Assert-VllmOfflineRelease -Repository $Repository -ProjectCommit $snapshot.Commit -ReleaseManifestPath $ReleaseManifestPath -ArtifactsDirectory $root
    } catch {
        for($i=$createdPaths.Count-1;$i-ge0;$i--){if(Test-Path -LiteralPath $createdPaths[$i] -PathType Leaf){Remove-Item -LiteralPath $createdPaths[$i] -Force -ErrorAction SilentlyContinue}}
        throw
    } finally { Close-VllmReleaseGitSnapshot -Snapshot $snapshot }
    } finally { Exit-VllmReleasePreparationLock -Lock $prepareLock }
}
