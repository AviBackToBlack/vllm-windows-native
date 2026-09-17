Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $BasePath = (Get-ProjectRoot)
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Read-RuntimeManifest {
    param(
        [Parameter(Mandatory)] [string] $ManifestPath
    )
    $resolved = Resolve-ProjectPath -Path $ManifestPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Runtime manifest not found: $resolved"
    }
    return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
}

function Get-FileSha256 {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedSha256
    )
    $actual = Get-FileSha256 -Path $Path
    if ($actual -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "SHA-256 mismatch for '$Path'. Expected $ExpectedSha256, got $actual."
    }
    return $actual
}

function Assert-VllmSafeRelativePath {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$Label = 'Managed relative path'
    )
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -ne $RelativePath.Trim()) {
        throw "$Label must be a non-empty relative path without leading/trailing whitespace: $RelativePath"
    }
    $value = $RelativePath.Replace('/','\')
    if ([System.IO.Path]::IsPathRooted($value)) {
        throw "$Label must not be rooted: $RelativePath"
    }
    $parts = @($value.Split([char]92))
    if ($parts.Count -eq 0 -or $parts -contains '' -or $parts -contains '.' -or $parts -contains '..') {
        throw "$Label contains an unsafe path segment: $RelativePath"
    }
    foreach ($part in $parts) {
        if ($part.Contains(':')) { throw "$Label contains unsupported colon/ADS syntax: $RelativePath" }
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "$Label has a Windows-ambiguous trailing dot/space: $RelativePath" }
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { throw "$Label uses a reserved Windows device name: $RelativePath" }
    }
    $probeRoot = 'C:\__vllm_relative_probe__'
    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($probeRoot, $value))
    $prefix = $probeRoot + '\'
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label resolves outside its parent: $RelativePath"
    }
    return $resolved.Substring($prefix.Length)
}

function Assert-VllmSafeArchiveLayout {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$TarCommand,
        [Parameter(Mandatory)][string]$ExpectedRoot,
        [int]$ExpectedEntryCount = 0,
        [ValidateSet('RegularFilesOnly','FilesAndDirectories')][string]$EntryPolicy = 'RegularFilesOnly',
        [string]$Label = 'Archive'
    )
    $root = (Assert-VllmSafeRelativePath -RelativePath $ExpectedRoot -Label "$Label extraction root").Replace('\','/').TrimEnd('/')
    $entries = @(& $TarCommand.Source -tf $Path)
    if ($LASTEXITCODE -ne 0) { throw "$Label listing failed (exit $LASTEXITCODE)." }
    $verbose = @(& $TarCommand.Source -tvf $Path)
    if ($LASTEXITCODE -ne 0) { throw "$Label verbose listing failed (exit $LASTEXITCODE)." }
    if ($entries.Count -ne $verbose.Count) { throw "$Label normal and verbose listings disagree on entry count." }
    if ($ExpectedEntryCount -gt 0 -and $entries.Count -ne $ExpectedEntryCount) {
        throw "$Label entry count mismatch. Expected $ExpectedEntryCount, got $($entries.Count)."
    }

    $prefix = $root + '/'
    $seen = @{}
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = ([string]$entries[$index]).Replace('\','/')
        $line = [string]$verbose[$index]
        if ([string]::IsNullOrEmpty($line)) { throw "$Label contains an entry with missing type metadata: $entry" }
        $type = $line[0]
        if ($EntryPolicy -eq 'RegularFilesOnly' -and $type -ne '-') {
            throw "$Label contains a non-regular-file entry: $line"
        }
        if ($EntryPolicy -eq 'FilesAndDirectories' -and $type -ne '-' -and $type -ne 'd') {
            throw "$Label contains an unsupported non-file/directory entry: $line"
        }

        $isRootDirectory = $type -eq 'd' -and $entry.TrimEnd('/').Equals($root, [System.StringComparison]::Ordinal)
        if (-not $isRootDirectory) {
            if ([string]::IsNullOrWhiteSpace($entry) -or -not $entry.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                throw "$Label entry escapes expected root '$root': $entry"
            }
            $relative = $entry.Substring($prefix.Length).TrimEnd('/')
            [void](Assert-VllmSafeRelativePath -RelativePath $relative -Label "$Label member")
        }
        $duplicateKey = $entry.TrimEnd('/')
        if ($seen.ContainsKey($duplicateKey)) { throw "$Label contains duplicate entry: $entry" }
        $seen[$duplicateKey] = $true
    }
    return $entries
}


function Invoke-Git {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $Capture
    )
    if ($Capture) {
        $output = & git -C $Repository -c core.longpaths=true @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed in '$Repository':`n$($output -join "`n")"
        }
        return ($output -join "`n").Trim()
    }
    & git -C $Repository -c core.longpaths=true @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed in '$Repository' (exit $LASTEXITCODE)."
    }
}
function Materialize-GitTree {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Tree
    )

    $tarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tarCommand) {
        throw 'tar.exe is required to materialize canonical Git tree bytes on Windows.'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('vllm-windows-native-' + [guid]::NewGuid().ToString('N'))
    $archive = Join-Path $tempRoot 'tree.tar'
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        & git -C $Repository -c core.longpaths=true archive --format=tar --output=$archive $Tree
        if ($LASTEXITCODE -ne 0) {
            throw "git archive failed for tree $Tree (exit $LASTEXITCODE)."
        }
        & $tarCommand.Source -xf $archive -C $Repository
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed for tree $Tree (exit $LASTEXITCODE)."
        }
        Invoke-Git -Repository $Repository -Arguments @('update-index','--refresh') | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Final-path Win32 interop adapted from AviBackToBlack/unsloth-studio-windows-native
# (MIT; reviewed tree 9df9219ce85f3536f6b40e95662c997ba53b42d2,
# common.ps1 blob cbf6a29fde7b9dc48707f2782ef9894bcb264fc9).
if (-not ('VllmWindowsNative.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace VllmWindowsNative {
    public static class NativePath {
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint VOLUME_NAME_DOS = 0x0;
        private const uint VOLUME_NAME_GUID = 0x1;
        private const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_PATH_NOT_FOUND = 3;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle hFile, StringBuilder lpszFilePath,
            uint cchFilePath, uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFileAttributes(string lpFileName);

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle hFile, out ByHandleFileInformation fileInformation);

        private static SafeFileHandle OpenPath(string path) {
            SafeFileHandle handle = CreateFile(
                path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }

        private static string GetFinalPathWithFlags(SafeFileHandle handle, uint flags) {
            var buffer = new StringBuilder(32768);
            uint result = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, flags);
            if (result == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (result >= buffer.Capacity) {
                buffer = new StringBuilder((int)result + 1);
                result = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, flags);
                if (result == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return buffer.ToString();
        }

        public static string GetFinalPathDos(string path) {
            using (SafeFileHandle handle = OpenPath(path)) {
                return GetFinalPathWithFlags(handle, VOLUME_NAME_DOS);
            }
        }

        public static string GetFinalPathGuid(string path) {
            using (SafeFileHandle handle = OpenPath(path)) {
                try { return GetFinalPathWithFlags(handle, VOLUME_NAME_GUID); }
                catch (Win32Exception) { return GetFinalPathWithFlags(handle, VOLUME_NAME_DOS); }
            }
        }

        public static string GetFinalPathDos(SafeFileHandle handle) {
            if (handle == null || handle.IsInvalid) throw new ArgumentException("Invalid file handle.");
            return GetFinalPathWithFlags(handle, VOLUME_NAME_DOS);
        }

        public static string GetFinalPathGuid(SafeFileHandle handle) {
            if (handle == null || handle.IsInvalid) throw new ArgumentException("Invalid file handle.");
            try { return GetFinalPathWithFlags(handle, VOLUME_NAME_GUID); }
            catch (Win32Exception) { return GetFinalPathWithFlags(handle, VOLUME_NAME_DOS); }
        }

        public static uint GetLinkCount(SafeFileHandle handle) {
            if (handle == null || handle.IsInvalid) throw new ArgumentException("Invalid file handle.");
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return info.NumberOfLinks;
        }

        public static long GetAttributesNoFollow(string path) {
            uint attributes = GetFileAttributes(path);
            if (attributes != INVALID_FILE_ATTRIBUTES) return (long)attributes;
            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return -1L;
            throw new Win32Exception(error);
        }
    }
}
'@
}


if (-not ('VllmWindowsNative.NativeEnvironment' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VllmWindowsNative {
    public static class NativeEnvironment {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetEnvironmentVariable(string lpName, string lpValue);

        public static void SetProcessVariable(string name, string value) {
            if (!SetEnvironmentVariable(name, value)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        public static void DeleteProcessVariable(string name) {
            if (!SetEnvironmentVariable(name, null)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
}

function Get-VllmProcessEnvironmentSnapshot {
    $snapshot = @{}
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $snapshot[[string]$entry.Key] = [string]$entry.Value
    }
    return $snapshot
}

function Restore-VllmProcessEnvironment {
    param([Parameter(Mandatory)][hashtable]$Snapshot)
    $current = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in @($current.Keys)) {
        $name = [string]$key
        if (-not $Snapshot.ContainsKey($name)) {
            [VllmWindowsNative.NativeEnvironment]::DeleteProcessVariable([string]$name)
        }
    }
    foreach ($name in $Snapshot.Keys) {
        [VllmWindowsNative.NativeEnvironment]::SetProcessVariable([string]$name, [string]$Snapshot[$name])
    }
}



function Get-VllmPathWithoutTrailingSeparator {
    param([Parameter(Mandatory)][string]$Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($Path)
    if ($pathRoot -and $Path.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $Path.TrimEnd([char[]]'\/')
}

function Get-VllmNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $trimmed = $Path.Trim().Trim('"')
    if ($trimmed.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = ConvertFrom-VllmExtendedDosPath $trimmed
    }
    $driveAbsolute = $trimmed.Length -ge 3 -and [char]::IsLetter($trimmed[0]) -and $trimmed[1] -eq ':' -and ($trimmed[2] -eq [char]92 -or $trimmed[2] -eq [char]47)
    $uncAbsolute = $false
    if ($trimmed.Length -ge 5 -and $trimmed[0] -eq [char]92 -and $trimmed[1] -eq [char]92) {
        $uncParts = $trimmed.Substring(2).Split([char[]]@([char]92, [char]47), [System.StringSplitOptions]::RemoveEmptyEntries)
        $uncAbsolute = $uncParts.Length -ge 2
    }
    if (-not ($driveAbsolute -or $uncAbsolute)) {
        throw "Path must be fully qualified: $Path"
    }
    return Get-VllmPathWithoutTrailingSeparator ([System.IO.Path]::GetFullPath($trimmed))
}

function ConvertTo-VllmExtendedPath {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = Get-VllmNormalizedPath $Path
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalized
    }
    if ($normalized.StartsWith('\\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\?\UNC\' + $normalized.Substring(2)
    }
    return '\\?\' + $normalized
}

function ConvertFrom-VllmExtendedDosPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-VllmPathEntryInfo {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = Get-VllmNormalizedPath $Path
    $native = ConvertTo-VllmExtendedPath $normalized
    $attributes = [VllmWindowsNative.NativePath]::GetAttributesNoFollow($native)
    if ($attributes -lt 0) {
        return [pscustomobject]@{ Path=$normalized; Exists=$false; IsDirectory=$false; IsReparsePoint=$false; Attributes=[long]-1 }
    }
    return [pscustomobject]@{
        Path=$normalized
        Exists=$true
        IsDirectory=(($attributes -band 0x10) -ne 0)
        IsReparsePoint=(($attributes -band 0x400) -ne 0)
        Attributes=[long]$attributes
    }
}


function Get-VllmCanonicalExistingPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Dos','Guid')][string]$Format = 'Guid'
    )
    $normalized = Get-VllmNormalizedPath $Path
    $entry = Get-VllmPathEntryInfo -Path $normalized
    if (-not $entry.Exists) {
        throw "Cannot canonicalize a path that does not exist: $normalized"
    }
    $nativeInput = ConvertTo-VllmExtendedPath $normalized
    if ($Format -eq 'Dos') {
        $resolved = [VllmWindowsNative.NativePath]::GetFinalPathDos($nativeInput)
        return Get-VllmPathWithoutTrailingSeparator (ConvertFrom-VllmExtendedDosPath $resolved)
    }
    $resolved = [VllmWindowsNative.NativePath]::GetFinalPathGuid($nativeInput)
    return Get-VllmPathWithoutTrailingSeparator $resolved
}

function Get-VllmPhysicalCandidatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Dos','Guid')][string]$Format = 'Guid'
    )
    $normalized = Get-VllmNormalizedPath $Path
    $entry = Get-VllmPathEntryInfo -Path $normalized
    if ($entry.Exists) {
        return Get-VllmCanonicalExistingPath -Path $normalized -Format $Format
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    $cursor = $normalized
    while (-not (Get-VllmPathEntryInfo -Path $cursor).Exists) {
        $leaf = [System.IO.Path]::GetFileName($cursor)
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            throw "Could not find an existing ancestor for path: $normalized"
        }
        $segments.Insert(0, $leaf)
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) {
            throw "Could not find an existing ancestor for path: $normalized"
        }
        $cursor = $parent.FullName
    }

    $candidate = Get-VllmCanonicalExistingPath -Path $cursor -Format $Format
    foreach ($segment in $segments) {
        $candidate = [System.IO.Path]::Combine($candidate, $segment)
    }
    return Get-VllmPathWithoutTrailingSeparator $candidate
}

function Test-VllmPathInsideOrEqual {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [switch]$Physical
    )
    if ($Physical) {
        $child = Get-VllmPhysicalCandidatePath -Path $Path -Format Guid
        $root = Get-VllmPhysicalCandidatePath -Path $Parent -Format Guid
    } else {
        $child = Get-VllmNormalizedPath $Path
        $root = Get-VllmNormalizedPath $Parent
    }
    if ($child.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = if ($root.EndsWith('\') -or $root.EndsWith('/')) { $root } else { $root + '\' }
    return $child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-VllmSafeInstallationRoot {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $root = Get-VllmNormalizedPath $InstallationRoot
    $volumeRoot = Get-VllmPathWithoutTrailingSeparator ([System.IO.Path]::GetPathRoot($root))
    if ($root.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installation root must not be a volume root: $root"
    }
    $rootEntry = Get-VllmPathEntryInfo -Path $root
    if ($rootEntry.Exists -and -not $rootEntry.IsDirectory) {
        throw "Installation root exists but is not a directory: $root"
    }
    $physicalDos = Get-VllmPhysicalCandidatePath -Path $root -Format Dos
    if (-not $physicalDos.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installation root resolves through a filesystem alias or redirected ancestor. Expected '$root', physical candidate '$physicalDos'."
    }
    return $root
}

function Get-VllmManagedTopLevelNames {
    return @('runtime','python','tools','cache','config','tmp','downloads','logs','work','forensic','state')
}

function Assert-VllmManagedChildPhysicalLocation {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Managed relative path must not be rooted: $RelativePath"
    }
    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    $actual = Get-VllmNormalizedPath $Path
    $expected = Get-VllmNormalizedPath ([System.IO.Path]::Combine($root, $RelativePath))
    if ($expected.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-VllmPathInsideOrEqual -Path $expected -Parent $root)) {
        throw "Managed relative path must resolve strictly inside installation root: $RelativePath"
    }
    if (-not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path must use expected location '$expected': $actual"
    }
    $rootPhysical = Get-VllmPhysicalCandidatePath -Path $root -Format Guid
    $actualPhysical = Get-VllmPhysicalCandidatePath -Path $actual -Format Guid
    $rootPrefix = if ($root.EndsWith('\')) { $root } else { $root + '\' }
    $normalizedRelative = $expected.Substring($rootPrefix.Length)
    $expectedPhysical = Get-VllmPathWithoutTrailingSeparator ([System.IO.Path]::Combine($rootPhysical, $normalizedRelative))
    if (-not $actualPhysical.Equals($expectedPhysical, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path resolves through a filesystem alias outside expected location '$expected': $actualPhysical"
    }
    return $actual
}

function Assert-VllmExistingManagedTopLevelLocations {
    param([Parameter(Mandatory)][string]$InstallationRoot)
    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    foreach ($relative in Get-VllmManagedTopLevelNames) {
        $path = [System.IO.Path]::Combine($root, $relative)
        $entry = Get-VllmPathEntryInfo -Path $path
        if ($entry.Exists) {
            if (-not $entry.IsDirectory) { throw "Managed top-level path exists but is not a directory: $path" }
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $path -RelativePath $relative)
        }
    }
    return $root
}

function Assert-VllmSafeModelsRoot {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$ModelsRoot
    )
    $root = Assert-VllmExistingManagedTopLevelLocations -InstallationRoot $InstallationRoot
    $models = Get-VllmNormalizedPath $ModelsRoot
    $modelsEntry = Get-VllmPathEntryInfo -Path $models
    if ($modelsEntry.Exists -and -not $modelsEntry.IsDirectory) {
        throw "ModelsRoot exists but is not a directory: $models"
    }
    $defaultModels = Get-VllmNormalizedPath ([System.IO.Path]::Combine($root, 'models'))
    if ($models.Equals($defaultModels, [System.StringComparison]::OrdinalIgnoreCase)) {
        [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $models -RelativePath 'models')
        return $models
    }
    if ((Test-VllmPathInsideOrEqual -Path $models -Parent $root) -or
        (Test-VllmPathInsideOrEqual -Path $root -Parent $models)) {
        throw "ModelsRoot must be default '$defaultModels' or a non-overlapping external path: $models"
    }
    if ((Test-VllmPathInsideOrEqual -Path $models -Parent $root -Physical) -or
        (Test-VllmPathInsideOrEqual -Path $root -Parent $models -Physical)) {
        throw "ModelsRoot physically overlaps the installation root through a filesystem alias or redirected ancestor: $models"
    }
    return $models
}

function Test-VllmOperationLockHandle {
    param(
        [Parameter(Mandatory)]$Lock,
        [Parameter(Mandatory)][string]$InstallationRoot
    )
    try {
        if ($null -eq $Lock -or $null -eq $Lock.Stream) { return $false }
        $handle = $Lock.Stream.SafeFileHandle
        if ($null -eq $handle -or $handle.IsClosed -or $handle.IsInvalid) { return $false }
        $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
        if (-not (Get-VllmNormalizedPath ([string]$Lock.Root)).Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $rootPhysical = Get-VllmPhysicalCandidatePath -Path $root -Format Guid
        $expectedPhysical = Get-VllmPathWithoutTrailingSeparator ([IO.Path]::Combine($rootPhysical, '.vllm-operation.lock'))
        $actualPhysical = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($handle))
        if (-not $actualPhysical.Equals($expectedPhysical, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([VllmWindowsNative.NativePath]::GetLinkCount($handle) -ne 1) { return $false }
        return $true
    } catch {
        return $false
    }
}
function Register-VllmInheritedOperationLock {
    param([Parameter(Mandatory)]$Lock)
    if (($Lock.PSObject.Properties.Name -contains 'Borrowed') -and [bool]$Lock.Borrowed) {
        throw 'A borrowed operation lock cannot become the inheritance owner.'
    }
    if (-not (Test-VllmOperationLockHandle -Lock $Lock -InstallationRoot ([string]$Lock.Root))) {
        throw 'Cannot register an invalid or closed operation lock for inheritance.'
    }
    $existing = Get-Variable -Name VllmWindowsNativeInheritedOperationLock -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $null -ne $existing.Value) {
        throw 'An inherited vLLM operation lock is already registered in this process.'
    }
    Set-Variable -Name VllmWindowsNativeInheritedOperationLock -Scope Global -Value $Lock
}

function Clear-VllmInheritedOperationLock {
    param([Parameter(Mandatory)]$Lock)
    $existing = Get-Variable -Name VllmWindowsNativeInheritedOperationLock -Scope Global -ErrorAction SilentlyContinue
    if ($null -eq $existing -or $null -eq $existing.Value) { return }
    if (-not [object]::ReferenceEquals($existing.Value, $Lock)) {
        throw 'Refusing to clear a different inherited vLLM operation lock.'
    }
    Remove-Variable -Name VllmWindowsNativeInheritedOperationLock -Scope Global -Force
}

function Enter-VllmOperationLock {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Operation
    )
    if ([string]::IsNullOrWhiteSpace($Operation)) { throw 'Operation name must not be empty.' }
    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot

    $inheritedVariable = Get-Variable -Name VllmWindowsNativeInheritedOperationLock -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $inheritedVariable -and $null -ne $inheritedVariable.Value) {
        $inherited = $inheritedVariable.Value
        $inheritedRoot = Get-VllmNormalizedPath ([string]$inherited.Root)
        if (-not $inheritedRoot.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Inherited vLLM operation lock belongs to '$inheritedRoot'. Refusing nested '$Operation' for different root '$root'."
        }
        if (-not (Test-VllmOperationLockHandle -Lock $inherited -InstallationRoot $root)) {
            throw "Inherited vLLM operation lock for '$root' is invalid or closed."
        }
        return [pscustomobject]@{
            Stream=$inherited.Stream
            Path=$inherited.Path
            Root=$root
            Operation=$Operation
            Borrowed=$true
            OwnerOperation=[string]$inherited.Operation
        }
    }

    if (-not (Get-VllmPathEntryInfo -Path $root).Exists) {
        [void][System.IO.Directory]::CreateDirectory($root)
        $root = Assert-VllmSafeInstallationRoot -InstallationRoot $root
    }
    $lockPath = [System.IO.Path]::Combine($root, '.vllm-operation.lock')
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $lockPath -RelativePath '.vllm-operation.lock')

    try {
        $stream = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [System.IO.IOException] {
        throw "Another vLLM Windows Native lifecycle operation is active for '$root'. Refusing '$Operation'."
    } catch [System.UnauthorizedAccessException] {
        throw "Operation lock path cannot be acquired safely: $lockPath"
    }

    try {
        $rootPhysical = Get-VllmPhysicalCandidatePath -Path $root -Format Guid
        $expectedPhysical = Get-VllmPathWithoutTrailingSeparator ([System.IO.Path]::Combine($rootPhysical, '.vllm-operation.lock'))
        $actualPhysical = Get-VllmPathWithoutTrailingSeparator ([VllmWindowsNative.NativePath]::GetFinalPathGuid($stream.SafeFileHandle))
        if (-not $actualPhysical.Equals($expectedPhysical, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Operation lock handle resolves outside expected location '$lockPath': $actualPhysical"
        }
        $linkCount = [VllmWindowsNative.NativePath]::GetLinkCount($stream.SafeFileHandle)
        if ($linkCount -ne 1) {
            throw "Operation lock path has unexpected hard-link count $linkCount; refusing to modify it: $lockPath"
        }

        $stream.SetLength(0)
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)), 1024, $true)
        try {
            $writer.WriteLine("operation=$Operation")
            $writer.WriteLine("pid=$PID")
            $writer.WriteLine("started=$((Get-Date).ToString('o'))")
            $writer.Flush()
            $stream.Flush()
        } finally { $writer.Dispose() }
        return [pscustomobject]@{ Stream=$stream; Path=$lockPath; Root=$root; Operation=$Operation; Borrowed=$false }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Exit-VllmOperationLock {
    param([Parameter(Mandatory)]$Lock)
    if (($Lock.PSObject.Properties.Name -contains 'Borrowed') -and [bool]$Lock.Borrowed) { return }
    $stream = $Lock.Stream
    if ($null -ne $stream) { $stream.Dispose() }
    # Deliberately leave the coordination file in place. The next Enter call
    # safely reclaims a stale path before atomically creating its own lock file.
}
