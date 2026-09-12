Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-VllmContainedEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    if (-not [System.IO.Path]::IsPathRooted($Root)) {
        throw "Containment root must be an absolute path: $Root"
    }

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $volumeRoot = [System.IO.Path]::GetPathRoot($rootPath)
    if ($rootPath.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Containment root must not be a volume root: $rootPath"
    }
    $rootPath = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($rootPath)) {
        throw 'Containment root resolved to an empty path.'
    }

    $paths = [ordered]@{
        CacheRoot = Join-Path $rootPath 'cache'
        ConfigRoot = Join-Path $rootPath 'config'
        StateRoot = Join-Path $rootPath 'state'
        TempRoot = Join-Path $rootPath 'tmp'

        HfRoot = Join-Path $rootPath 'cache\huggingface'
        HfHub = Join-Path $rootPath 'cache\huggingface\hub'
        HfXet = Join-Path $rootPath 'cache\huggingface\xet'
        HfAssets = Join-Path $rootPath 'cache\huggingface\assets'
        HfToken = Join-Path $rootPath 'state\huggingface\token'

        VllmCache = Join-Path $rootPath 'cache\vllm'
        VllmConfig = Join-Path $rootPath 'config\vllm'
        VllmAssets = Join-Path $rootPath 'cache\vllm\assets'
        VllmMedia = Join-Path $rootPath 'cache\vllm\media'
        VllmFlashInfer = Join-Path $rootPath 'cache\vllm\flashinfer-autotune'

        Torch = Join-Path $rootPath 'cache\torch'
        TorchInductor = Join-Path $rootPath 'cache\torchinductor'
        Triton = Join-Path $rootPath 'cache\triton'
        Pip = Join-Path $rootPath 'cache\pip'
        Cuda = Join-Path $rootPath 'cache\cuda'
        XdgCache = Join-Path $rootPath 'cache\xdg'
        XdgConfig = Join-Path $rootPath 'config\xdg'
    }

    $directories = @(
        $paths.CacheRoot,
        $paths.ConfigRoot,
        $paths.StateRoot,
        $paths.TempRoot,
        $paths.HfRoot,
        $paths.HfHub,
        $paths.HfXet,
        $paths.HfAssets,
        (Split-Path -Parent $paths.HfToken),
        $paths.VllmCache,
        $paths.VllmConfig,
        $paths.VllmAssets,
        $paths.VllmMedia,
        $paths.VllmFlashInfer,
        $paths.Torch,
        $paths.TorchInductor,
        $paths.Triton,
        $paths.Pip,
        $paths.Cuda,
        $paths.XdgCache,
        $paths.XdgConfig
    ) | Select-Object -Unique

    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $environment = [ordered]@{
        HF_HOME = $paths.HfRoot
        HF_HUB_CACHE = $paths.HfHub
        HF_XET_CACHE = $paths.HfXet
        HF_ASSETS_CACHE = $paths.HfAssets
        HF_TOKEN_PATH = $paths.HfToken

        VLLM_CACHE_ROOT = $paths.VllmCache
        VLLM_CONFIG_ROOT = $paths.VllmConfig
        VLLM_ASSETS_CACHE = $paths.VllmAssets
        VLLM_MEDIA_CACHE = $paths.VllmMedia
        VLLM_FLASHINFER_AUTOTUNE_CACHE_DIR = $paths.VllmFlashInfer

        TORCH_HOME = $paths.Torch
        TORCHINDUCTOR_CACHE_DIR = $paths.TorchInductor
        TRITON_CACHE_DIR = $paths.Triton
        PIP_CACHE_DIR = $paths.Pip
        CUDA_CACHE_PATH = $paths.Cuda
        XDG_CACHE_HOME = $paths.XdgCache
        XDG_CONFIG_HOME = $paths.XdgConfig

        TEMP = $paths.TempRoot
        TMP = $paths.TempRoot
        PYTHONNOUSERSITE = '1'
    }

    foreach ($entry in $environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }

    return [pscustomobject]@{
        Root = $rootPath
        Paths = [pscustomobject]$paths
        Environment = [pscustomobject]$environment
    }
}
