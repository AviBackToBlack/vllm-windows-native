[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\common.ps1')
$manifestPath=Join-Path $repoRoot 'manifests\release\v0.27.1-windows-x86_64.json'
$runtimePath=Join-Path $repoRoot 'manifests\runtime\vllm-runtime-v0.27.1-windows-x86_64.json'
$acceptedPath=Join-Path $repoRoot 'manifests\runtime\v0.27.1-rtx5090-sm120.json'
foreach($p in @($manifestPath,$runtimePath,$acceptedPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required manifest missing: $p"}}
$release=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$runtime=Get-Content -LiteralPath $runtimePath -Raw|ConvertFrom-Json
$accepted=Get-Content -LiteralPath $acceptedPath -Raw|ConvertFrom-Json
if([int]$release.schema_version -ne 1 -or [string]$release.component -ne 'runtime-release' -or [string]$release.platform -ne 'windows-x86_64'){throw 'Unsupported release manifest identity.'}
if([string]$release.self_path -ne 'manifests/release/v0.27.1-windows-x86_64.json'){throw 'Unexpected release manifest self_path.'}
if(@($release.files).Count -ne 30){throw "Expected 30 owned distribution files, got $(@($release.files).Count)."}
$seen=@{}
foreach($entry in @($release.files)){
    $relative=Assert-VllmSafeRelativePath -RelativePath ([string]$entry.path) -Label 'Release file path'
    $key=$relative.Replace('\','/').ToLowerInvariant();if($seen.ContainsKey($key)){throw "Duplicate release file: $relative"};$seen[$key]=$true
    $props=@($entry.PSObject.Properties.Name|Sort-Object);if(Compare-Object @('path','sha256','size_bytes') $props){throw "Unexpected release file schema: $relative"}
    $file=Join-Path $repoRoot $relative;if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Release file missing: $relative"}
    $item=Get-Item -LiteralPath $file;$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if($item.Length -ne [int64]$entry.size_bytes -or $hash -ne [string]$entry.sha256){throw "Release file identity mismatch: $relative"}
}foreach($required in @('install.ps1','start.ps1','update.ps1','uninstall.ps1','scripts/common.ps1','scripts/lifecycle.ps1','scripts/update-planner.ps1','scripts/update-staging.ps1','scripts/update-transaction.ps1','scripts/update-integration.ps1','scripts/env.ps1','config.example.psd1','LICENSE','THIRD_PARTY_NOTICES.md','docs/provenance/windows-reference-review-v0.27.1.json')){if(-not$seen.ContainsKey($required.ToLowerInvariant())){throw "Required distribution file missing from release manifest: $required"}}
$provPath=Join-Path $repoRoot 'docs\provenance\windows-reference-review-v0.27.1.json'
if(-not(Test-Path -LiteralPath $provPath -PathType Leaf)){throw 'SM-21 provenance evidence missing.'}
$prov=Get-Content -LiteralPath $provPath -Raw|ConvertFrom-Json
$aiv=$prov.references.aivrar_vllm_windows_build;$sp=$prov.references.systempanic_vllm_windows
if([int]$prov.schema_version -ne 1 -or [string]$prov.canonical_patchset.sha256 -ne [string]$accepted.accepted_delta.patch_sha256 -or [string]$prov.canonical_patchset.implementation_commit -ne [string]$accepted.accepted_delta.implementation_commit){throw 'SM-21 provenance evidence is not bound to the accepted patchset.'}
if([string]$aiv.historical_commit -ne '05402d4283f5a52e0fffcc2e04b115f6666ccbb1' -or [string]$aiv.patch_sha256 -ne '4B6C9CD543414EF3ED1EB7FCBD7F39CE6BE10BDC97D901261977EE905346C988' -or [int]$aiv.exact_added_block_match_count -ne 36 -or [int]$aiv.matched_file_count -ne 15){throw 'aivrar provenance evidence drifted.'}
if([string]$sp.historical_commit -ne '98dff2a81d747d1dba01a47f939f48c3526d4206' -or [int]$sp.exact_added_block_match_count -ne 0){throw 'SystemPanic provenance evidence drifted.'}
$notice=Get-Content -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Raw;if(-not $notice.Contains('Copyright (c) 2025 aivrar')){throw 'Required aivrar MIT notice missing.'}
if(-not ([string]$accepted.provenance_note).StartsWith('SM-21 line-level community Windows provenance/licensing review completed.') -or ([string]$accepted.provenance_note).Contains('remains required before a public release')){throw 'SM-21 provenance gate is not recorded complete.'}
if([string]$release.upstream.repository -ne [string]$accepted.upstream.repository -or [string]$release.upstream.tag -ne [string]$accepted.upstream.tag -or [string]$release.upstream.commit -ne [string]$accepted.upstream.commit){throw 'Release upstream identity does not match accepted runtime provenance.'}
if([string]$release.windows_patchset.implementation_commit -ne [string]$accepted.accepted_delta.implementation_commit -or [string]$release.windows_patchset.tree -ne [string]$accepted.accepted_delta.tree -or [string]$release.windows_patchset.patch_sha256 -ne [string]$accepted.accepted_delta.patch_sha256){throw 'Release Windows patchset identity does not match accepted runtime provenance.'}
if([string]$release.wheel.filename -ne [string]$runtime.project_wheel.filename -or [string]$release.wheel.version -ne [string]$runtime.project_wheel.version -or [int64]$release.wheel.size_bytes -ne [int64]$runtime.project_wheel.size_bytes -or [string]$release.wheel.sha256 -ne [string]$runtime.project_wheel.sha256){throw 'Release wheel identity does not match managed runtime contract.'}
$expectedManaged=@('.vllm-operation.lock','cache/uv','forensic/python-bootstrap-3.13.15.json','forensic/runtime-dependencies-v0.27.1.json','forensic/runtime-vllm-v0.27.1.json','forensic/uv-bootstrap-0.12.13.json','forensic/venv-bootstrap-v0.27.1.json','python/managed/cpython-3.13.15-windows-x86_64-none','runtime/venv','state/install-orchestrator.lock','state/install-state.json','state/update-transaction.json','tools/uv/0.12.13','work/update-transaction')|Sort-Object
$actualManaged=@($release.managed_paths|ForEach-Object{(Assert-VllmSafeRelativePath -RelativePath ([string]$_) -Label 'Managed path').Replace('\','/')}|Sort-Object)
if(Compare-Object $expectedManaged $actualManaged){throw 'Release managed_paths set does not match the accepted installer ownership contract.'}
$requiredOrchestration=@('python_manifest','uv_manifest','venv_manifest','dependency_manifest','runtime_manifest','python_receipt','uv_receipt','venv_receipt','dependency_receipt','runtime_receipt','runtime_root')
if(Compare-Object ($requiredOrchestration|Sort-Object) (@($release.orchestration.PSObject.Properties.Name)|Sort-Object)){throw 'Release orchestration schema is incomplete or contains unexpected fields.'}
$outerPatchPath=Join-Path $repoRoot ([string]$accepted.accepted_delta.patch)
if(-not(Test-Path -LiteralPath $outerPatchPath -PathType Leaf)){throw "Accepted Windows patch missing: $outerPatchPath"}
$outerPatchLines=@(Get-Content -LiteralPath $outerPatchPath -Encoding UTF8)
$provenanceSha=[Security.Cryptography.SHA256]::Create()
try{
    $validatedFiles=@{}
    foreach($match in @($aiv.matches)){
        $range=@($match.canonical_patch_lines)
        if($range.Count -ne 2){throw 'Malformed canonical provenance patch-line range.'}
        $start=[int]$range[0];$end=[int]$range[1]
        if($start -lt 1 -or $end -lt $start -or $end -gt $outerPatchLines.Count){throw "Canonical provenance range is out of bounds: $start-$end"}
        if(($end-$start+1) -ne [int]$match.added_lines){throw "Canonical provenance added-line count drifted: $start-$end"}
        $file=[string]$match.file
        $fileHeader='+++ b/'+$file
        $headerFound=$false
        for($scan=$start-2;$scan -ge 0;$scan--){
            $candidate=[string]$outerPatchLines[$scan]
            if($candidate.StartsWith('diff --git ')){break}
            if($candidate -ceq $fileHeader){$headerFound=$true;break}
        }
        if(-not $headerFound){throw "Canonical provenance range is not inside expected file diff: $file $start-$end"}
        $added=@()
        for($lineNo=$start;$lineNo -le $end;$lineNo++){
            $line=[string]$outerPatchLines[$lineNo-1]
            if(-not $line.StartsWith('+') -or $line.StartsWith('+++')){throw "Canonical provenance range includes a non-added line: $file $start-$end"}
            $added += $line.Substring(1)
        }
        $payload=([string]::Join([char]10,[string[]]$added))+[char]10
        $actual=([BitConverter]::ToString($provenanceSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-','')
        if($actual -ne [string]$match.block_sha256){throw "Canonical provenance block digest drifted: $file $start-$end"}
        $validatedFiles[$file]=$true
    }
    if(@($aiv.matches).Count -ne [int]$aiv.exact_added_block_match_count -or $validatedFiles.Count -ne [int]$aiv.matched_file_count){throw 'Canonical provenance match records do not agree with recorded totals.'}
}finally{$provenanceSha.Dispose()}
Write-Host "PUBLIC_RELEASE_PROVENANCE_OK aivrar_blocks=$([int]$aiv.exact_added_block_match_count) files=$([int]$aiv.matched_file_count) systempanic_blocks=$([int]$sp.exact_added_block_match_count)"
$utf8NoBom=New-Object System.Text.UTF8Encoding($false)
$sha256=[System.Security.Cryptography.SHA256]::Create()
try{
    foreach($embedded in @($accepted.embedded_dependency_patches.PSObject.Properties)){
        $name=[string]$embedded.Name
        $expected=([string]$embedded.Value).ToUpperInvariant()
        $header="diff --git a/$name b/$name"
        $start=-1
        for($i=0;$i -lt $outerPatchLines.Count;$i++){
            if([string]$outerPatchLines[$i] -ceq $header){$start=$i;break}
        }
        if($start -lt 0){throw "Embedded dependency patch diff missing from accepted Windows patch: $name"}
        if($start+4 -ge $outerPatchLines.Count -or [string]$outerPatchLines[$start+1] -cne 'new file mode 100644' -or [string]$outerPatchLines[$start+3] -cne '--- /dev/null' -or [string]$outerPatchLines[$start+4] -cne "+++ b/$name"){
            throw "Embedded dependency patch is not represented as a canonical new file: $name"
        }
        $hunk=$start+5
        if($hunk -ge $outerPatchLines.Count -or [string]$outerPatchLines[$hunk] -notmatch '^@@ -0,0 \+1,([0-9]+) @@$'){
            throw "Embedded dependency patch new-file hunk is malformed: $name"
        }
        $expectedLines=[int]$Matches[1]
        $content=New-Object System.Collections.Generic.List[string]
        for($i=$hunk+1;$i -lt $outerPatchLines.Count;$i++){
            $line=[string]$outerPatchLines[$i]
            if($line.StartsWith('diff --git ')){break}
            if($line -eq '\ No newline at end of file'){throw "Embedded dependency patch must end with LF: $name"}
            if(-not $line.StartsWith('+')){throw "Unexpected non-addition in embedded dependency patch new-file hunk: $name"}
            $content.Add($line.Substring(1))
        }
        if($content.Count -ne $expectedLines){throw "Embedded dependency patch line-count mismatch for ${name}: expected $expectedLines, got $($content.Count)"}
        $canonicalText=([string]::Join([char]10,$content.ToArray()))+[char]10
        $bytes=$utf8NoBom.GetBytes($canonicalText)
        $actual=([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','')
        if($actual -ne $expected){throw "Embedded dependency patch LF SHA-256 mismatch for ${name}: expected $expected, got $actual"}
    }
}finally{$sha256.Dispose()}
Write-Host "EMBEDDED_DEPENDENCY_PATCH_PROVENANCE_OK count=$(@($accepted.embedded_dependency_patches.PSObject.Properties).Count)"
Write-Host "RELEASE_MANIFEST_OK files=$(@($release.files).Count) sha256=$((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash)"
