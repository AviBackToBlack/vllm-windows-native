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
        $output = & git -C $Repository @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($Arguments -join ' ') failed in '$Repository':`n$($output -join "`n")"
        }
        return ($output -join "`n").Trim()
    }
    & git -C $Repository @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed in '$Repository' (exit $LASTEXITCODE)."
    }
}
