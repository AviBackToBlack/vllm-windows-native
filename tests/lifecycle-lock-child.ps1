param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$InstallRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'scripts\common.ps1')
try {
    $lock = Enter-VllmOperationLock -InstallationRoot $InstallRoot -Operation 'child'
    Exit-VllmOperationLock $lock
    exit 0
}
catch {
    exit 23
}
