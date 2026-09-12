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

if ([string]::IsNullOrWhiteSpace($ContainmentRoot)) {
    $ContainmentRoot = $projectRoot
}
$containment = Initialize-VllmContainedEnvironment -Root $ContainmentRoot
$ContainmentRoot = $containment.Root

# Do not allow host Python customization to leak into the managed runtime.
[Environment]::SetEnvironmentVariable('PYTHONPATH', $null, 'Process')
[Environment]::SetEnvironmentVariable('PYTHONHOME', $null, 'Process')

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

Write-Host 'RUNTIME_ENVIRONMENT_OK'
Write-Host "Containment: $ContainmentRoot"
Write-Host "vLLM:       $VllmExe"
Write-Host "Model:      $Model"
Write-Host "Endpoint:   http://${ListenHost}:$ListenPort"

if ($ValidateOnly) {
    Write-Host ('Arguments:   ' + ($arguments -join ' '))
    Write-Host 'RUNTIME_VALIDATE_ONLY_OK'
    return
}

& $VllmExe @arguments
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "vLLM exited with code $exitCode."
}
