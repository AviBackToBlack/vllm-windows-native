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
