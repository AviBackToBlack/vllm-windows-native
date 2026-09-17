[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Model = $env:VLLM_MODEL,
    [string] $VllmExe = $env:VLLM_RUNTIME_EXE,
    [string] $ContainmentRoot = $env:VLLM_RUNTIME_CONTAINMENT_ROOT,
    [string] $ListenHost = '127.0.0.1',
    [ValidateRange(1, 65535)]
    [int] $ListenPort = 8000,
    [string[]] $VllmArgs = @(),
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\lifecycle.ps1')
. (Join-Path $PSScriptRoot 'scripts\env.ps1')

if ($env:OS -ne 'Windows_NT') {
    throw 'This runtime launcher currently supports native Windows only.'
}

$projectRoot = Get-ProjectRoot

if ([string]::IsNullOrWhiteSpace($Model)) {
    throw 'Model is required. Pass it as the first argument, use -Model, or set VLLM_MODEL.'
}
if ([string]::IsNullOrWhiteSpace($ListenHost)) {
    throw 'ListenHost must not be empty.'
}

foreach ($argument in $VllmArgs) {
    if ($argument -match '^--(?:host|port)(?:=|$)') {
        throw "VllmArgs must not override launcher-controlled option '$argument'. Use -ListenHost or -ListenPort instead."
    }
}

if ([string]::IsNullOrWhiteSpace($ContainmentRoot)) {
    $ContainmentRoot = $projectRoot
}
$ContainmentRoot = Get-VllmNormalizedPath $ContainmentRoot

if ([string]::IsNullOrWhiteSpace($VllmExe)) {
    $VllmExe = Join-Path $projectRoot 'runtime\venv\Scripts\vllm.exe'
}
$VllmExe = [System.IO.Path]::GetFullPath($VllmExe)
if (-not (Test-Path -LiteralPath $VllmExe -PathType Leaf)) {
    throw "vLLM launcher not found: $VllmExe. Pass -VllmExe or set VLLM_RUNTIME_EXE."
}

$arguments = @(
    'serve',
    $Model,
    '--host', $ListenHost,
    '--port', [string]$ListenPort
)
if ($VllmArgs) {
    $arguments += $VllmArgs
}

$managedRoot = Resolve-VllmStartManagedRoot -ProjectRoot $projectRoot -ContainmentRoot $ContainmentRoot -VllmExe $VllmExe
$operationLock = $null
$originalEnvironment = $null
try {
    if ($null -ne $managedRoot) {
        $operationLock = Enter-VllmOperationLock -InstallationRoot $managedRoot -Operation $(if ($ValidateOnly) { 'start-validate' } else { 'start' })

        # Maintenance presence is checked under the operation lock before full generation
        # validation so an interrupted update reports recovery state rather than payload drift.
        Assert-VllmUpdateMaintenanceAbsent -InstallationRoot $managedRoot

        $lockedRoot = Resolve-VllmStartManagedRoot -ProjectRoot $projectRoot -ContainmentRoot $ContainmentRoot -VllmExe $VllmExe
        if ($null -eq $lockedRoot -or -not $lockedRoot.Equals($managedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Managed start ownership changed while acquiring the operation lock.'
        }
        $context = Get-VllmCommittedInstallationContext -InstallationRoot $managedRoot
        Assert-VllmStartMatchesCommittedContext -Context $context -VllmExe $VllmExe
    }

    $originalEnvironment = Get-VllmProcessEnvironmentSnapshot
    $containment = Initialize-VllmContainedEnvironment -Root $ContainmentRoot
    $ContainmentRoot = $containment.Root

    # Do not allow host Python customization to leak into the managed runtime.
    [Environment]::SetEnvironmentVariable('PYTHONPATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('PYTHONHOME', $null, 'Process')

    Write-Host 'RUNTIME_ENVIRONMENT_OK'
    Write-Host "Containment: $ContainmentRoot"
    Write-Host "vLLM:       $VllmExe"
    Write-Host "Model:      $Model"
    Write-Host "Endpoint:   http://${ListenHost}:$ListenPort"
    if ($null -ne $managedRoot) { Write-Host "Managed:    $managedRoot" }

    if ($ValidateOnly) {
        Write-Host 'Runtime arguments validated; passthrough values are not displayed.'
        Write-Host 'RUNTIME_VALIDATE_ONLY_OK'
        return
    }

    & $VllmExe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "vLLM exited with code $exitCode."
    }
}
finally {
    if ($null -ne $originalEnvironment) {
        Restore-VllmProcessEnvironment -Snapshot $originalEnvironment
    }
    if ($null -ne $operationLock) {
        Exit-VllmOperationLock -Lock $operationLock
    }
}
