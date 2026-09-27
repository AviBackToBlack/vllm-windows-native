[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [string]$Repository = 'AviBackToBlack/vllm-windows-native',
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$AllowedSignersPath,
    [Parameter(Mandatory)][string]$CacheRoot,
    [string]$InstallationRoot = '',
    [switch]$Json,
    [string]$GhExecutable = 'gh'
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

. (Join-Path $PSScriptRoot 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-bundle.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-verification.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-acquisition.ps1')
. (Join-Path $PSScriptRoot 'scripts\release-handoff.ps1')

if($env:OS-ne'Windows_NT'-or-not[Environment]::Is64BitOperatingSystem){
    throw 'update-release.ps1 supports native Windows x64 only.'
}

$acquisition=Invoke-VllmReleaseAcquisition -RepositorySlug $Repository -Tag $Tag -AllowedSignersPath $AllowedSignersPath -CacheRoot $CacheRoot -GhExecutable $GhExecutable
$params=[ordered]@{Acquisition=$acquisition}
if(-not[string]::IsNullOrWhiteSpace($InstallationRoot)){$params.InstallationRoot=$InstallationRoot}
if($WhatIfPreference){$params.WhatIf=$true}
if($PSBoundParameters.ContainsKey('Confirm')){$params.Confirm=[bool]$PSBoundParameters['Confirm']}
if($Json){$params.Json=$true}
Invoke-VllmAcquisitionUpdateHandoff @params
