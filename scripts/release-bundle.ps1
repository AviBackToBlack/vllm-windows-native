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
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (@(Compare-Object -ReferenceObject $wanted -DifferenceObject $actual).Count -ne 0) {
        throw "$Label schema is unexpected. Expected [$($wanted -join ', ')], got [$($actual -join ', ')]."
    }
}

function Get-VllmReleaseOrdinalStrings {
    param([Parameter(Mandatory)][object[]]$Values)
    $copy = New-Object string[] $Values.Count
    for ($i=0; $i -lt $Values.Count; $i++) { $copy[$i] = [string]$Values[$i] }
    [Array]::Sort($copy,[StringComparer]::Ordinal)
    return $copy
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
    if ([string]$Matches[3] -ne $relative) { throw "Git release member path mismatch. Expected '$relative', got '$($Matches[3])'." }
    return [pscustomobject][ordered]@{Mode=$Matches[1];ObjectId=$Matches[2].ToLowerInvariant();Path=$relative}
}

function Get-VllmReleaseSnapshotFile {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RelativePath)
    $relative = Assert-VllmReleaseCanonicalPath -RelativePath $RelativePath -Label 'Snapshot release member'
    [void](Assert-VllmReleaseGitRegularBlob -Repository $Snapshot.Repository -Commit $Snapshot.Commit -RelativePath $relative)
    $path = Join-Path $Snapshot.Root ($relative.Replace('/','\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Snapshot release member is missing after git archive: $relative" }
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

    if ([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64') {
        throw 'Release manifest has unsupported schema/component/platform.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$release.release) -or [string]$release.release -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw 'Release identifier is invalid for publication.'
    }
    if ([string]$release.self_path -ne $releaseRelative) { throw 'Release manifest self_path does not match the selected manifest path.' }
    if ([IO.Path]::GetFileName([string]$release.wheel.filename) -ne [string]$release.wheel.filename -or [string]$release.wheel.filename -notlike '*.whl') {
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
    if ([int]$runtime.schema_version -ne 1 -or [string]$runtime.component -ne 'vllm-runtime' -or [string]$runtime.platform -ne [string]$release.platform -or [string]$runtime.milestone -ne [string]$release.release) {
        throw 'Runtime manifest identity does not match the release.'
    }

    Assert-VllmReleaseExactProperties -Value $runtime.project_wheel -Expected @('distribution','version','filename','size_bytes','sha256','python_tag','abi_tag','platform_tag','acquisition','dependency_install','native_extension_count','native_extensions') -Label 'Runtime project wheel'
    foreach ($name in @('filename','version','size_bytes','sha256')) {
        if ([string]$runtime.project_wheel.$name -ne [string]$release.wheel.$name) { throw 'Runtime and release manifests disagree on project wheel identity.' }
    }
    if ([string]$runtime.project_wheel.distribution -ne 'vllm') { throw 'Runtime project wheel distribution must be vllm.' }
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
    if ([IO.Path]::GetFileName($resolved) -ne [string]$runtimeWheel.filename) { throw 'Provided release wheel filename mismatch.' }
    if ($identity.Size -ne [int64]$runtimeWheel.size_bytes -or $identity.Sha256 -ne ([string]$runtimeWheel.sha256).ToUpperInvariant()) {
        throw 'Provided release wheel size/SHA-256 mismatch.'
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($resolved)
    try {
        $metadataEntries = @($zip.Entries | Where-Object { $_.FullName -match '\.dist-info/METADATA$' })
        $wheelEntries = @($zip.Entries | Where-Object { $_.FullName -match '\.dist-info/WHEEL$' })
        if ($metadataEntries.Count -ne 1 -or $wheelEntries.Count -ne 1) { throw 'Provided release wheel must contain exactly one METADATA and one WHEEL entry.' }

        $metadataReader = New-Object IO.StreamReader($metadataEntries[0].Open())
        try { $metadata = $metadataReader.ReadToEnd() } finally { $metadataReader.Dispose() }
        $wheelReader = New-Object IO.StreamReader($wheelEntries[0].Open())
        try { $wheelMetadata = $wheelReader.ReadToEnd() } finally { $wheelReader.Dispose() }

        if ($metadata -notmatch '(?m)^Name:\s*vllm\s*$') { throw 'Provided release wheel distribution name is not vllm.' }
        if ($metadata -notmatch ('(?m)^Version:\s*' + [regex]::Escape([string]$runtimeWheel.version) + '\s*$')) { throw 'Provided release wheel version does not match runtime manifest.' }
        $tag = 'Tag: ' + [string]$runtimeWheel.python_tag + '-' + [string]$runtimeWheel.abi_tag + '-' + [string]$runtimeWheel.platform_tag
        if ($wheelMetadata.IndexOf($tag,[StringComparison]::Ordinal) -lt 0) { throw "Provided release wheel compatibility tag is missing: $tag" }

        $actualNative = @($zip.Entries | Where-Object { $_.FullName -like '*.pyd' } | ForEach-Object { $_.FullName.Replace('\','/') })
        $actualNative = Get-VllmReleaseOrdinalStrings -Values $actualNative
        if (@($actualNative).Count -ne [int]$runtimeWheel.native_extension_count -or @(Compare-Object -ReferenceObject @($Context.NativeExtensions) -DifferenceObject @($actualNative)).Count -ne 0) {
            throw 'Provided release wheel native extension set does not match runtime manifest.'
        }

        $seen = @{}
        foreach ($z in @($zip.Entries)) {
            if ([string]::IsNullOrWhiteSpace($z.FullName)) { throw 'Provided release wheel contains an empty member name.' }
            $key = $z.FullName.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "Provided release wheel contains duplicate/case-colliding member: $($z.FullName)" }
            $seen[$key] = $true
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
    $u=New-Object Text.UTF8Encoding($false,$true);$p=[int64]$co
    for($n=0;$n-lt$count;$n++){
        if($p+46-gt$e-or[BitConverter]::ToUInt32($b,[int]$p)-ne[uint32]0x02014b50){throw "Release ZIP central record invalid at index $n."}
        $flags=[BitConverter]::ToUInt16($b,[int]$p+8);$method=[BitConverter]::ToUInt16($b,[int]$p+10);$time=[BitConverter]::ToUInt16($b,[int]$p+12);$date=[BitConverter]::ToUInt16($b,[int]$p+14)
        $nl=[int][BitConverter]::ToUInt16($b,[int]$p+28);$xl=[int][BitConverter]::ToUInt16($b,[int]$p+30);$ml=[int][BitConverter]::ToUInt16($b,[int]$p+32);$ext=[BitConverter]::ToUInt32($b,[int]$p+38);$lo=[int64][BitConverter]::ToUInt32($b,[int]$p+42)
        if($flags-ne0x0800-or$method-ne0-or$time-ne0-or$date-ne33-or$xl-ne0-or$ml-ne0-or$ext-ne0){throw "Release ZIP central profile is not canonical at index $n."}
        $name=$u.GetString($b,[int]$p+46,$nl);if($name-ne[string]$Context.Members[$n].RelativePath){throw "Release ZIP raw member mismatch at index $n."}
        if($lo+30-gt$co-or[BitConverter]::ToUInt32($b,[int]$lo)-ne[uint32]0x04034b50-or[BitConverter]::ToUInt16($b,[int]$lo+6)-ne0x0800-or[BitConverter]::ToUInt16($b,[int]$lo+8)-ne0-or[BitConverter]::ToUInt16($b,[int]$lo+10)-ne0-or[BitConverter]::ToUInt16($b,[int]$lo+12)-ne33-or[BitConverter]::ToUInt16($b,[int]$lo+28)-ne0){throw "Release ZIP local profile is not canonical: $name"}
        $p+=46+$nl
    }
    if($p-ne$e){throw 'Release ZIP parsed central-directory length mismatch.'}
}
function Assert-VllmReleaseCanonicalZip {
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$Path)
    Assert-VllmReleaseRawZipProfile -Context $Context -Path $Path
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $actualNames = @($zip.Entries | ForEach-Object { $_.FullName })
        $expectedNames = @($Context.Members | ForEach-Object { $_.RelativePath })
        if ($actualNames.Count -ne $expectedNames.Count) { throw 'Release ZIP member count mismatch.' }
        for ($i=0; $i -lt $expectedNames.Count; $i++) {
            if ([string]$actualNames[$i] -ne [string]$expectedNames[$i]) { throw "Release ZIP ordering/member mismatch at index $i." }
        }
        $seen = @{}
        for ($i=0; $i -lt $zip.Entries.Count; $i++) {
            $entry = $zip.Entries[$i]
            $name = Assert-VllmReleaseCanonicalPath -RelativePath ([string]$entry.FullName) -Label 'Release ZIP member'
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "Release ZIP contains duplicate/case-colliding member: $name" }
            $seen[$key] = $true
            if ($entry.LastWriteTime.UtcDateTime -ne $script:VllmReleaseZipTimestamp.UtcDateTime) { throw "Release ZIP member timestamp is not canonical: $name" }
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "SHA256SUMS is missing: $Path" }
    $text = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
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
        if ([string]$sortedNames[$i] -ne [string]$inputNames[$i]) { throw 'SHA256SUMS entries are not in canonical ordinal order.' }
    }
    return $map
}

function Assert-VllmReleaseIndex {
    param([Parameter(Mandatory)]$Index,[Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Wheel,[Parameter(Mandatory)]$Bundle)

    Assert-VllmReleaseExactProperties -Value $Index -Expected @('schema_version','component','platform','release','tag','project_commit','release_manifest','runtime_manifest','upstream','windows_patchset','wheel','bundle','checksums','preparation') -Label 'Release index'
    if ([int]$Index.schema_version -ne 1 -or [string]$Index.component -ne 'vllm-windows-native-release-index') { throw 'Release index identity is unsupported.' }
    if ([string]$Index.platform -ne [string]$Context.Release.platform -or [string]$Index.release -ne [string]$Context.Release.release -or [string]$Index.tag -ne [string]$Context.Tag -or [string]$Index.project_commit -ne [string]$Context.Snapshot.Commit) {
        throw 'Release index project/release identity mismatch.'
    }

    foreach ($pair in @(
        @($Index.release_manifest,$Context.ReleaseManifest,'release manifest'),
        @($Index.runtime_manifest,$Context.RuntimeManifest,'runtime manifest')
    )) {
        $value=$pair[0];$expected=$pair[1];$label=[string]$pair[2]
        Assert-VllmReleaseExactProperties -Value $value -Expected @('path','size_bytes','sha256') -Label "Release index $label"
        if ([string]$value.path -ne [string]$expected.RelativePath -or [int64]$value.size_bytes -ne [int64]$expected.Size -or [string]$value.sha256 -ne [string]$expected.Sha256) { throw "Release index $label identity mismatch." }
    }

    Assert-VllmReleaseExactProperties -Value $Index.wheel -Expected @('filename','version','size_bytes','sha256','python_tag','abi_tag','platform_tag','native_extension_count','native_extensions') -Label 'Release index wheel'
    if ([string]$Index.wheel.filename -ne [string]$Wheel.Filename -or [int64]$Index.wheel.size_bytes -ne [int64]$Wheel.Size -or [string]$Index.wheel.sha256 -ne [string]$Wheel.Sha256) { throw 'Release index wheel file identity mismatch.' }
    if ([string]$Index.wheel.version -ne [string]$Context.Runtime.project_wheel.version -or [string]$Index.wheel.python_tag -ne [string]$Context.Runtime.project_wheel.python_tag -or [string]$Index.wheel.abi_tag -ne [string]$Context.Runtime.project_wheel.abi_tag -or [string]$Index.wheel.platform_tag -ne [string]$Context.Runtime.project_wheel.platform_tag) { throw 'Release index wheel metadata mismatch.' }
    $indexNative = Get-VllmReleaseOrdinalStrings -Values @($Index.wheel.native_extensions)
    if ([int]$Index.wheel.native_extension_count -ne @($Context.NativeExtensions).Count -or @(Compare-Object -ReferenceObject @($Context.NativeExtensions) -DifferenceObject @($indexNative)).Count -ne 0) { throw 'Release index native extension set mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.bundle -Expected @('filename','size_bytes','sha256') -Label 'Release index bundle'
    if ([string]$Index.bundle.filename -ne [string]$Context.BundleFilename -or [int64]$Index.bundle.size_bytes -ne [int64]$Bundle.Size -or [string]$Index.bundle.sha256 -ne [string]$Bundle.Sha256) { throw 'Release index bundle identity mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.checksums -Expected @('filename','algorithm','format') -Label 'Release index checksums'
    if ([string]$Index.checksums.filename -ne 'SHA256SUMS' -or [string]$Index.checksums.algorithm -ne 'SHA256' -or [string]$Index.checksums.format -ne 'sha256-two-space-v1') { throw 'Release index checksum contract mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.preparation -Expected @('source_commit','tool_path') -Label 'Release index preparation'
    if ([string]$Index.preparation.source_commit -ne [string]$Context.Snapshot.Commit -or [string]$Index.preparation.tool_path -ne 'release.ps1') { throw 'Release index preparation identity mismatch.' }

    Assert-VllmReleaseExactProperties -Value $Index.upstream -Expected @('repository','tag','commit') -Label 'Release index upstream'
    Assert-VllmReleaseExactProperties -Value $Index.windows_patchset -Expected @('implementation_commit','tree','patch_sha256') -Label 'Release index Windows patchset'
    foreach ($name in @('repository','tag','commit')) { if ([string]$Index.upstream.$name -ne [string]$Context.Release.upstream.$name) { throw 'Release index upstream identity mismatch.' } }
    foreach ($name in @('implementation_commit','tree','patch_sha256')) {
        if (([string]$Index.windows_patchset.$name).ToUpperInvariant() -ne ([string]$Context.Release.windows_patchset.$name).ToUpperInvariant()) { throw 'Release index Windows patchset identity mismatch.' }
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
        if (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames).Count -ne 0) { throw 'Release artifacts directory does not contain exactly the expected four assets.' }

        $wheel = Assert-VllmReleaseWheel -WheelPath (Join-Path $root ([string]$context.Release.wheel.filename)) -Context $context
        $bundlePath = Join-Path $root ([string]$context.BundleFilename)
        Assert-VllmReleaseCanonicalZip -Context $context -Path $bundlePath
        $bundle = Get-VllmReleaseFileIdentity -Path $bundlePath

        $indexPath = Join-Path $root 'release-index.json'
        $indexText=[IO.File]::ReadAllText($indexPath,[Text.Encoding]::UTF8)
        try { $index = $indexText | ConvertFrom-Json } catch { throw 'release-index.json is invalid JSON.' }
        $canonicalIndexText=(ConvertTo-VllmReleaseCanonicalJsonValue -Value $index)+[char]10
        if (-not $indexText.Equals($canonicalIndexText,[StringComparison]::Ordinal)) { throw 'release-index.json is not canonical deterministic JSON.' }
        Assert-VllmReleaseIndex -Index $index -Context $context -Wheel $wheel -Bundle $bundle

        $checksums = Read-VllmReleaseChecksums -Path (Join-Path $root 'SHA256SUMS')
        $expectedChecksumNames = @([string]$wheel.Filename,[string]$context.BundleFilename,'release-index.json')
        if ($checksums.Count -ne 3) { throw 'SHA256SUMS must contain exactly three payload entries.' }
        foreach ($name in $expectedChecksumNames) {
            $key = $name.ToLowerInvariant()
            if (-not $checksums.ContainsKey($key)) { throw "SHA256SUMS is missing asset: $name" }
            $actual = Get-VllmReleaseFileIdentity -Path (Join-Path $root $name)
            if ([string]$checksums[$key].Filename -ne $name -or [string]$checksums[$key].Sha256 -ne [string]$actual.Sha256) { throw "SHA256SUMS identity mismatch: $name" }
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

function Write-VllmOfflineRelease {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$ProjectCommit,
        [Parameter(Mandatory)][string]$ReleaseManifestPath,
        [Parameter(Mandatory)][string]$WheelPath,
        [Parameter(Mandatory)][string]$ArtifactsDirectory
    )
    $snapshot = Get-VllmReleaseGitSnapshot -Repository $Repository -Commit $ProjectCommit
    try {
        $context = Get-VllmReleaseContext -Snapshot $snapshot -ReleaseManifestPath $ReleaseManifestPath
        $wheel = Assert-VllmReleaseWheel -WheelPath $WheelPath -Context $context
        $root = [IO.Path]::GetFullPath($ArtifactsDirectory)
        if (Test-Path -LiteralPath $root) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Release artifacts path is not a directory: $root" }
            $rootEntry=Get-VllmPathEntryInfo -Path $root
            if ($rootEntry.IsReparsePoint) { throw "Release artifacts directory must not be a reparse point: $root" }
            $entries = @(Get-ChildItem -LiteralPath $root -Force)
            if ($entries.Count -gt 0) { throw "Release artifacts directory is not empty: $root" }
        } else { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $rootPhysical=Get-VllmCanonicalExistingPath -Path $root -Format Dos
        if (-not $rootPhysical.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { throw "Release artifacts directory resolves through a filesystem alias: $root -> $rootPhysical" }

        $destWheel = Join-Path $root ([string]$wheel.Filename)
        if ([IO.Path]::GetFullPath($wheel.Path).Equals([IO.Path]::GetFullPath($destWheel),[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Source wheel must be outside the release artifacts directory during preparation.'
        }
        Copy-Item -LiteralPath $wheel.Path -Destination $destWheel
        $copiedWheel = Assert-VllmReleaseWheel -WheelPath $destWheel -Context $context

        $bundlePath = Join-Path $root ([string]$context.BundleFilename)
        $bundle = Write-VllmReleaseCanonicalZip -Context $context -Path $bundlePath

        $index = Get-VllmReleaseIndex -Context $context -Wheel $copiedWheel -Bundle $bundle
        $indexPath = Join-Path $root 'release-index.json'
        Write-VllmReleaseCanonicalJson -Value $index -Path $indexPath
        $indexIdentity = Get-VllmReleaseFileIdentity -Path $indexPath

        $sumPath = Join-Path $root 'SHA256SUMS'
        $identities = @{
            ([string]$copiedWheel.Filename)=[string]$copiedWheel.Sha256
            ([string]$context.BundleFilename)=[string]$bundle.Sha256
            'release-index.json'=[string]$indexIdentity.Sha256
        }
        Write-VllmReleaseChecksums -Identities $identities -Path $sumPath

        return Assert-VllmOfflineRelease -Repository $Repository -ProjectCommit $snapshot.Commit -ReleaseManifestPath $ReleaseManifestPath -ArtifactsDirectory $root
    } finally { Close-VllmReleaseGitSnapshot -Snapshot $snapshot }
}
