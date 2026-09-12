[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrap = Join-Path $repoRoot 'bootstrap-python.ps1'
$archive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Test archive not found: $archive" }

function Test-ExpectedFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        & $Action
        throw "Expected failure did not occur: $Name"
    } catch {
        if ($_.Exception.Message -eq "Expected failure did not occur: $Name") { throw }
        Write-Host "REJECT $Name :: $($_.Exception.Message)"
    }
}

function Invoke-TestBootstrap {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Force
    )
    $parameters = @{ InstallationRoot=$Root; ArchivePath=$archive; Json=$true }
    if ($Force) { $parameters.Force = $true }
    $json = & $bootstrap @parameters
    return ($json | ConvertFrom-Json)
}

$base = Join-Path $env:TEMP ('vllm-portable-python-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
try {
    $root = Join-Path $base 'valid'
    $result = Invoke-TestBootstrap -Root $root
    if (-not $result.ready) { throw 'Valid bootstrap did not report ready.' }
    if (-not (Test-Path -LiteralPath $result.python -PathType Leaf)) { throw 'Materialized python.exe is missing.' }
    $files = @(Get-ChildItem -LiteralPath $result.root -Recurse -File)
    if ($files.Count -ne 3303) { throw "Materialized file count mismatch: $($files.Count)" }
    if (-not (Test-Path -LiteralPath $result.receipt -PathType Leaf)) { throw 'Forensic receipt is missing.' }
    Write-Host 'VALID_BOOTSTRAP_OK'

    Test-ExpectedFailure { & $bootstrap -InstallationRoot $root -ArchivePath $archive -Json | Out-Null } 'existing-target-without-force'
    if (-not (Test-Path -LiteralPath $result.python -PathType Leaf)) { throw 'Existing target was modified after fail-closed rerun.' }

    $marker = Join-Path $result.root 'replace-me.marker'
    Set-Content -LiteralPath $marker -Value 'old' -Encoding ascii
    $forced = Invoke-TestBootstrap -Root $root -Force
    if (Test-Path -LiteralPath $marker) { throw 'Force replacement preserved stale target content.' }
    if (@(Get-ChildItem -LiteralPath $forced.root -Recurse -File).Count -ne 3303) { throw 'Force replacement produced unexpected file count.' }
    Write-Host 'FORCE_REPLACEMENT_OK'

    $badArchive = Join-Path $base 'corrupt.tar.gz'
    [IO.File]::WriteAllBytes($badArchive, [byte[]](1,2,3,4,5))
    $badRoot = Join-Path $base 'corrupt-root'
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $badRoot -ArchivePath $badArchive -Json | Out-Null } 'corrupt-archive'
    Write-Host 'CORRUPT_ARCHIVE_REJECTED'

    $junctionRoot = Join-Path $base 'junction-root'
    $outside = Join-Path $base 'outside-python'
    [void][IO.Directory]::CreateDirectory($junctionRoot)
    [void][IO.Directory]::CreateDirectory($outside)
    $sentinel = Join-Path $outside 'sentinel.txt'
    Set-Content -LiteralPath $sentinel -Value 'DO-NOT-TOUCH' -Encoding ascii
    New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'python') -Target $outside | Out-Null
    Test-ExpectedFailure { & $bootstrap -InstallationRoot $junctionRoot -ArchivePath $archive -Json | Out-Null } 'managed-python-junction'
    if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'DO-NOT-TOUCH') { throw 'Junction rejection modified outside sentinel.' }
    Write-Host 'JUNCTION_SENTINEL_PRESERVED'

    Write-Host 'PORTABLE_PYTHON_BOOTSTRAP_REGRESSION_OK'
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
