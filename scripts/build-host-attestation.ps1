Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$BaselineTag = 'v0.27.1'
$BaselineCommit = '6e448d0ea9bf3d88d898b65449ca6dc2aec170ac'
$InstallRoot = 'D:\AI\vLLM'

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host $Title
    Write-Host ('=' * 78)
}

function Write-KV {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][object]$Value
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        $Value = '<not found>'
    }
    Write-Host ('{0,-28}: {1}' -f $Key, $Value)
}

function Get-ToolCommand {
    param([Parameter(Mandatory)][string]$Name)
    Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Show-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$VersionArgs = @('--version')
    )

    $cmd = Get-ToolCommand $Name
    if (-not $cmd) {
        Write-KV $Name '<not found on process PATH>'
        return
    }

    Write-KV ($Name + ' path') $cmd.Source
    try {
        $output = & $cmd.Source @VersionArgs 2>&1 | Select-Object -First 12
        if ($output) {
            $text = ($output | ForEach-Object { $_.ToString().TrimEnd() }) -join ' | '
            Write-KV ($Name + ' version') $text
        }
    }
    catch {
        Write-KV ($Name + ' version') ('<query failed: ' + $_.Exception.Message + '>')
    }
}

function Show-RegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        Write-KV $Label $item.$Name
    }
    catch {
        Write-KV $Label '<not found>'
    }
}

Write-Host 'vLLM Windows Native - build host attestation'
Write-Host ('Timestamp (UTC): ' + [DateTime]::UtcNow.ToString('o'))
Write-KV 'Official baseline tag' $BaselineTag
Write-KV 'Official baseline commit' $BaselineCommit
Write-KV 'Intended install root' $InstallRoot
Write-Host 'Mode: READ-ONLY. This script does not install software or persist environment changes.'

Write-Section 'Identity / OS / PowerShell'
Write-KV 'Computer name' $env:COMPUTERNAME
Write-KV 'User' ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-KV 'Is 64-bit OS' [Environment]::Is64BitOperatingSystem
Write-KV 'Is 64-bit process' [Environment]::Is64BitProcess
Write-KV 'PowerShell edition' $PSVersionTable.PSEdition
Write-KV 'PowerShell version' $PSVersionTable.PSVersion
Write-KV 'PowerShell process path' (Get-Process -Id $PID).Path

try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-KV 'Windows caption' $os.Caption
    Write-KV 'Windows version' $os.Version
    Write-KV 'Windows build' $os.BuildNumber
    Write-KV 'OS architecture' $os.OSArchitecture
}
catch {
    Write-KV 'Win32_OperatingSystem' ('<query failed: ' + $_.Exception.Message + '>')
}

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-KV 'DisplayVersion' $cv.DisplayVersion
    Write-KV 'EditionID' $cv.EditionID
    Write-KV 'UBR' $cv.UBR
}
catch {}

Write-Host ''
Write-Host 'Execution policy:'
Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String | Write-Host

Write-Section 'Machine resources'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-KV 'Manufacturer' $cs.Manufacturer
    Write-KV 'Model' $cs.Model
    Write-KV 'Logical processors' $cs.NumberOfLogicalProcessors
    Write-KV 'Total RAM GiB' ([math]::Round($cs.TotalPhysicalMemory / 1GB, 2))
}
catch {}

try {
    Get-CimInstance Win32_Processor | ForEach-Object {
        Write-KV 'CPU' $_.Name
        Write-KV 'CPU cores/threads' (('{0}/{1}' -f $_.NumberOfCores, $_.NumberOfLogicalProcessors))
    }
}
catch {}

try {
    $d = Get-PSDrive -Name D -ErrorAction Stop
    Write-KV 'D: used GiB' ([math]::Round($d.Used / 1GB, 2))
    Write-KV 'D: free GiB' ([math]::Round($d.Free / 1GB, 2))
}
catch {
    Write-KV 'D: drive' '<not available>'
}

Write-KV 'D:\AI exists' (Test-Path -LiteralPath 'D:\AI')
Write-KV 'D:\AI\vLLM exists' (Test-Path -LiteralPath $InstallRoot)
if (Test-Path -LiteralPath $InstallRoot) {
    try {
        $item = Get-Item -LiteralPath $InstallRoot -Force
        Write-KV 'InstallRoot attributes' $item.Attributes
        Write-KV 'InstallRoot link type' $item.LinkType
        Write-KV 'InstallRoot target' ($item.Target -join ', ')
    }
    catch {}
}

Write-Section 'NVIDIA GPU / driver'
try {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-KV 'Video controller' $_.Name
        Write-KV 'PnP device ID' $_.PNPDeviceID
        Write-KV 'Driver version (WMI)' $_.DriverVersion
    }
}
catch {}

$nvsmi = Get-ToolCommand 'nvidia-smi.exe'
if (-not $nvsmi) { $nvsmi = Get-ToolCommand 'nvidia-smi' }
if ($nvsmi) {
    Write-KV 'nvidia-smi path' $nvsmi.Source
    try {
        & $nvsmi.Source --query-gpu=name,driver_version,pci.bus_id,memory.total,compute_cap --format=csv,noheader 2>&1 | ForEach-Object { Write-Host $_ }
    }
    catch {
        & $nvsmi.Source 2>&1 | Select-Object -First 30 | ForEach-Object { Write-Host $_ }
    }
}
else {
    Write-KV 'nvidia-smi' '<not found>'
}

Write-Section 'Command-line build/runtime tools on current process PATH'
Show-Tool 'git.exe'
Show-Tool 'git'
Show-Tool 'python.exe'
Show-Tool 'python'
Show-Tool 'py.exe' @('--version')
Show-Tool 'uv.exe'
Show-Tool 'uv'
Show-Tool 'cmake.exe'
Show-Tool 'cmake'
Show-Tool 'ninja.exe'
Show-Tool 'ninja'
Show-Tool 'nvcc.exe' @('--version')
Show-Tool 'nvcc' @('--version')
Show-Tool 'cl.exe' @('/Bv')
Show-Tool 'cl' @('/Bv')
Show-Tool 'rustc.exe' @('--version')
Show-Tool 'cargo.exe' @('--version')
Show-Tool 'protoc.exe' @('--version')

Write-Section 'Visual Studio / MSVC discovery'
$vswhereCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$vswhere = $vswhereCandidates | Select-Object -First 1
if ($vswhere) {
    Write-KV 'vswhere path' $vswhere
    try {
        $vsJson = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8 | ConvertFrom-Json
        if (-not $vsJson) {
            Write-KV 'VS C++ workload' '<not found>'
        }
        foreach ($vs in $vsJson) {
            Write-KV 'VS display name' $vs.displayName
            Write-KV 'VS version' $vs.installationVersion
            Write-KV 'VS path' $vs.installationPath

            $vcVersionFile = Join-Path $vs.installationPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
            if (Test-Path -LiteralPath $vcVersionFile) {
                $vcVersion = (Get-Content -LiteralPath $vcVersionFile -Raw).Trim()
                Write-KV 'VCTools version' $vcVersion
                $clPath = Join-Path $vs.installationPath ('VC\Tools\MSVC\' + $vcVersion + '\bin\Hostx64\x64\cl.exe')
                Write-KV 'Resolved cl.exe' $clPath
                Write-KV 'Resolved cl exists' (Test-Path -LiteralPath $clPath)
                if (Test-Path -LiteralPath $clPath) {
                    try {
                        $clOut = & $clPath /Bv 2>&1 | Select-Object -First 20
                        Write-Host ($clOut -join [Environment]::NewLine)
                    }
                    catch {}
                }
            }
        }
    }
    catch {
        Write-KV 'vswhere query' ('<failed: ' + $_.Exception.Message + '>')
    }
}
else {
    Write-KV 'vswhere' '<not found>'
}

Write-Section 'CUDA Toolkit discovery'
Write-KV 'CUDA_HOME (process)' $env:CUDA_HOME
Write-KV 'CUDA_PATH (process)' $env:CUDA_PATH
Write-KV 'CUDA_PATH_V13_0' $env:CUDA_PATH_V13_0

$cudaRoot = Join-Path $env:ProgramFiles 'NVIDIA GPU Computing Toolkit\CUDA'
if (Test-Path -LiteralPath $cudaRoot) {
    Get-ChildItem -LiteralPath $cudaRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        Write-KV ('CUDA directory ' + $_.Name) $_.FullName
        $candidateNvcc = Join-Path $_.FullName 'bin\nvcc.exe'
        if (Test-Path -LiteralPath $candidateNvcc) {
            try {
                $nvccOut = & $candidateNvcc --version 2>&1 | Select-Object -Last 4
                Write-Host ($nvccOut -join [Environment]::NewLine)
            }
            catch {}
        }
    }
}
else {
    Write-KV 'CUDA toolkit root' '<not found>'
}

try {
    $cudaReg = Get-ItemProperty 'HKLM:\SOFTWARE\NVIDIA Corporation\GPU Computing Toolkit\CUDA' -ErrorAction Stop
    Write-Host 'CUDA registry values:'
    $cudaReg.PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } |
        Select-Object Name, Value |
        Format-Table -AutoSize | Out-String | Write-Host
}
catch {
    Write-KV 'CUDA registry key' '<not found>'
}

Write-Section 'Windows SDK / long path policy'
Show-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' 'KitsRoot10' 'Windows KitsRoot10'
Show-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 'LongPathsEnabled'

try {
    $sdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction Stop).KitsRoot10
    if ($sdkRoot) {
        $sdkInclude = Join-Path $sdkRoot 'Include'
        if (Test-Path -LiteralPath $sdkInclude) {
            Get-ChildItem -LiteralPath $sdkInclude -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name |
                ForEach-Object { Write-KV 'Windows SDK include' $_.Name }
        }
    }
}
catch {}

Write-Section 'Python registrations / contamination baseline'
foreach ($root in @('HKCU:\SOFTWARE\Python', 'HKLM:\SOFTWARE\Python', 'HKLM:\SOFTWARE\WOW6432Node\Python')) {
    if (Test-Path -LiteralPath $root) {
        Write-KV 'Python registry root' $root
        try {
            Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 80 |
                ForEach-Object { Write-Host ('  ' + $_.Name) }
        }
        catch {}
    }
}

Write-Section 'Environment locations relevant to containment'
foreach ($name in @(
    'TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA',
    'HF_HOME','HF_HUB_CACHE','HF_XET_CACHE','HF_ASSETS_CACHE',
    'TORCH_HOME','TORCHINDUCTOR_CACHE_DIR','TRITON_CACHE_DIR',
    'VLLM_CACHE_ROOT','VLLM_CONFIG_ROOT','VLLM_ASSETS_CACHE','VLLM_MEDIA_CACHE',
    'CUDA_CACHE_PATH','PIP_CACHE_DIR','UV_CACHE_DIR','UV_PYTHON_INSTALL_DIR','UV_INSTALL_DIR'
)) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    Write-KV $name $value
}

Write-Section 'Persistent PATH summary (read-only)'
foreach ($scope in @('User','Machine')) {
    $pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
    $entries = if ($pathValue) { $pathValue -split ';' | Where-Object { $_ } } else { @() }
    Write-KV ($scope + ' PATH entries') $entries.Count
    foreach ($entry in $entries) {
        if ($entry -match '(?i)(python|cuda|nvidia|visual studio|cmake|ninja|rust|cargo|uv)') {
            Write-Host ('  [{0}] {1}' -f $scope, $entry)
        }
    }
}

Write-Section 'VC++ Redistributable discovery'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
try {
    Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Microsoft Visual C\+\+.*Redistributable' } |
        Sort-Object DisplayName, DisplayVersion -Unique |
        Select-Object DisplayName, DisplayVersion, Publisher |
        Format-Table -AutoSize | Out-String | Write-Host
}
catch {}

Write-Section 'Attestation complete'
Write-Host 'No installation or persistent environment modification was performed by this script.'
