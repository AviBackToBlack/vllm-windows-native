[CmdletBinding()]
param(
    [string]$Repository = 'AviBackToBlack/vllm-windows-native',
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$AllowedSignersPath,
    [Parameter(Mandatory)][string]$CacheRoot,
    [string]$GhExecutable = 'gh',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-bundle.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-verification.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-acquisition.ps1')

if($env:OS-ne'Windows_NT'-or-not[Environment]::Is64BitOperatingSystem){
    throw 'acquire.ps1 supports native Windows x64 only.'
}

$result=Invoke-VllmReleaseAcquisition -RepositorySlug $Repository -Tag $Tag -AllowedSignersPath $AllowedSignersPath -CacheRoot $CacheRoot -GhExecutable $GhExecutable
if($Json){
    $result|ConvertTo-Json -Depth 10
}else{
    Write-Host "RELEASE_ACQUIRE_OK release=$($result.release) tag=$($result.tag) commit=$($result.project_commit)"
    Write-Host "Cache entry: $($result.cache_entry)"
    Write-Host "Wheel:       $($result.wheel_path)"
    Write-Host "Bundle:      $($result.bundle_path)"
    Write-Host "Receipt:     $($result.receipt_path)"
}
