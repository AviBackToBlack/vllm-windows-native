[CmdletBinding()]
param([Parameter(Mandatory)][string] $PythonExe)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'SM120 NVFP4 trusted acceptance is native-Windows only.'}
$python=[IO.Path]::GetFullPath($PythonExe)
if(-not(Test-Path -LiteralPath $python -PathType Leaf)){throw "Python executable not found: $python"}
& $python (Join-Path $PSScriptRoot 'sm120-nvfp4.py')
if($LASTEXITCODE -ne 0){throw "SM120 NVFP4 regression failed with exit $LASTEXITCODE."}
Write-Host 'SM120_NVFP4_ACCEPTANCE_OK'