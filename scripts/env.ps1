Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-VllmContainedEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    $inputRoot = [System.IO.Path]::GetPathRoot($Root)
    $isDriveQualified = $inputRoot -match '^[A-Za-z]:[\\/]$'
    $isUncQualified = $inputRoot -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?$'
    if (-not ($isDriveQualified -or $isUncQualified)) {
        throw "Containment root must be a fully-qualified drive or UNC path: $Root"
    }

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $volumeRoot = [System.IO.Path]::GetPathRoot($rootPath)
    $rootCompare = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $volumeCompare = $volumeRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($rootCompare.Equals($volumeCompare, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Containment root must not be a volume root: $rootPath"
    }
    $rootPath = $rootCompare
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
        HfDatasets = Join-Path $rootPath 'cache\huggingface\datasets'
        HfModules = Join-Path $rootPath 'cache\huggingface\modules'
        HfToken = Join-Path $rootPath 'state\huggingface\token'

        VllmCache = Join-Path $rootPath 'cache\vllm'
        VllmConfig = Join-Path $rootPath 'config\vllm'
        VllmAssets = Join-Path $rootPath 'cache\vllm\assets'
        VllmMedia = Join-Path $rootPath 'cache\vllm\media'
        VllmFlashInfer = Join-Path $rootPath 'cache\vllm\flashinfer-autotune'

        Torch = Join-Path $rootPath 'cache\torch'
        TorchInductor = Join-Path $rootPath 'cache\torchinductor'
        TorchExtensions = Join-Path $rootPath 'cache\torch-extensions'
        DeepGemm = Join-Path $rootPath 'cache\deep-gemm'
        Triton = Join-Path $rootPath 'cache\triton'
        Pip = Join-Path $rootPath 'cache\pip'
        Cuda = Join-Path $rootPath 'cache\cuda'
        XdgCache = Join-Path $rootPath 'cache\xdg'
        XdgConfig = Join-Path $rootPath 'config\xdg'
    }

    $directories = @(
        $rootPath,
        $paths.CacheRoot,
        $paths.ConfigRoot,
        $paths.StateRoot,
        $paths.TempRoot,
        $paths.HfRoot,
        $paths.HfHub,
        $paths.HfXet,
        $paths.HfAssets,
        $paths.HfDatasets,
        $paths.HfModules,
        (Split-Path -Parent $paths.HfToken),
        $paths.VllmCache,
        $paths.VllmConfig,
        $paths.VllmAssets,
        $paths.VllmMedia,
        $paths.VllmFlashInfer,
        $paths.Torch,
        $paths.TorchInductor,
        $paths.TorchExtensions,
        $paths.DeepGemm,
        $paths.Triton,
        $paths.Pip,
        $paths.Cuda,
        $paths.XdgCache,
        $paths.XdgConfig
    ) | Select-Object -Unique

    foreach ($directory in $directories) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $environment = [ordered]@{
        HF_HOME = $paths.HfRoot
        HF_HUB_CACHE = $paths.HfHub
        HUGGINGFACE_HUB_CACHE = $paths.HfHub
        HF_XET_CACHE = $paths.HfXet
        HF_ASSETS_CACHE = $paths.HfAssets
        HF_DATASETS_CACHE = $paths.HfDatasets
        HF_MODULES_CACHE = $paths.HfModules
        TRANSFORMERS_CACHE = $paths.HfHub
        PYTORCH_PRETRAINED_BERT_CACHE = $paths.HfHub
        PYTORCH_TRANSFORMERS_CACHE = $paths.HfHub
        HF_TOKEN_PATH = $paths.HfToken

        VLLM_CACHE_ROOT = $paths.VllmCache
        VLLM_CONFIG_ROOT = $paths.VllmConfig
        VLLM_ASSETS_CACHE = $paths.VllmAssets
        VLLM_MEDIA_CACHE = $paths.VllmMedia
        VLLM_FLASHINFER_AUTOTUNE_CACHE_DIR = $paths.VllmFlashInfer

        TORCH_HOME = $paths.Torch
        TORCHINDUCTOR_CACHE_DIR = $paths.TorchInductor
        TORCH_EXTENSIONS_DIR = $paths.TorchExtensions
        DG_JIT_CACHE_DIR = $paths.DeepGemm
        TRITON_CACHE_DIR = $paths.Triton
        PIP_CACHE_DIR = $paths.Pip
        CUDA_CACHE_PATH = $paths.Cuda
        XDG_CACHE_HOME = $paths.XdgCache
        XDG_CONFIG_HOME = $paths.XdgConfig

        TMPDIR = $paths.TempRoot
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
