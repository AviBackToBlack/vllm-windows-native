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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle hFile, StringBuilder lpszFilePath,
            uint cchFilePath, uint dwFlags);

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
    }
}
'@
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

function Get-VllmCanonicalExistingPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Dos','Guid')][string]$Format = 'Guid'
    )
    $normalized = Get-VllmNormalizedPath $Path
    if (-not (Test-Path -LiteralPath $normalized)) {
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
    if (Test-Path -LiteralPath $normalized) {
        return Get-VllmCanonicalExistingPath -Path $normalized -Format $Format
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    $cursor = $normalized
    while (-not (Test-Path -LiteralPath $cursor)) {
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
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $root -PathType Container)) {
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
    if (-not $actual.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path must use expected location '$expected': $actual"
    }
    $rootPhysical = Get-VllmPhysicalCandidatePath -Path $root -Format Guid
    $actualPhysical = Get-VllmPhysicalCandidatePath -Path $actual -Format Guid
    $expectedPhysical = Get-VllmPathWithoutTrailingSeparator ([System.IO.Path]::Combine($rootPhysical, $RelativePath))
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
        if (Test-Path -LiteralPath $path) {
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

function Enter-VllmOperationLock {
    param(
        [Parameter(Mandatory)][string]$InstallationRoot,
        [Parameter(Mandatory)][string]$Operation
    )
    if ([string]::IsNullOrWhiteSpace($Operation)) { throw 'Operation name must not be empty.' }
    $root = Assert-VllmSafeInstallationRoot -InstallationRoot $InstallationRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root = Assert-VllmSafeInstallationRoot -InstallationRoot $root
    }
    $lockPath = [System.IO.Path]::Combine($root, '.vllm-operation.lock')
    [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $lockPath -RelativePath '.vllm-operation.lock')
    $stream = $null
    for ($attempt = 1; $attempt -le 3 -and $null -eq $stream; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, 'CreateNew', 'ReadWrite', 'None')
            break
        } catch [System.IO.IOException] {
            $staleStream = $null
            try {
                $staleStream = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'None')
            } catch [System.IO.IOException] {
                throw "Another vLLM Windows Native lifecycle operation is active for '$root'. Refusing '$Operation'."
            } catch [System.UnauthorizedAccessException] {
                throw "Existing operation lock path cannot be validated safely: $lockPath"
            }
            $staleStream.Dispose()
            try { [System.IO.File]::Delete($lockPath) }
            catch { throw "Stale operation lock path could not be removed safely: $lockPath. $($_.Exception.Message)" }
            [void](Assert-VllmManagedChildPhysicalLocation -InstallationRoot $root -Path $lockPath -RelativePath '.vllm-operation.lock')
        }
    }
    if ($null -eq $stream) {
        throw "Could not acquire operation lock for '$root' after repeated safe create attempts."
    }
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)), 1024, $true)
        try {
            $writer.WriteLine("operation=$Operation")
            $writer.WriteLine("pid=$PID")
            $writer.WriteLine("started=$((Get-Date).ToString('o'))")
            $writer.Flush()
            $stream.Flush()
        } finally { $writer.Dispose() }
        return [pscustomobject]@{ Stream=$stream; Path=$lockPath; Root=$root; Operation=$Operation }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Exit-VllmOperationLock {
    param([Parameter(Mandatory)]$Lock)
    $path = [string]$Lock.Path
    $stream = $Lock.Stream
    if ($null -ne $stream) { $stream.Dispose() }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        try { [System.IO.File]::Delete($path) }
        catch [System.IO.IOException] { Write-Verbose 'Lock file cleanup deferred because another owner may have acquired it.' }
        catch [System.UnauthorizedAccessException] { Write-Verbose 'Lock file cleanup was not permitted; a stale file is harmless without an open exclusive handle.' }
    }
}
