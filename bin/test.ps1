#Requires -Version 5.1
[CmdletBinding()]
param([string]$ManifestDirectory)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Tools.ps1"
. "$PSScriptRoot\..\scripts\ReleaseChecks.ps1"
if (!$ManifestDirectory) { $ManifestDirectory = Join-Path (Get-BucketRoot) 'bucket' }
$previous = Enter-BucketEnvironment
try {
    Start-BucketLogGroup "Schema, hooks and formatting (PowerShell $($PSVersionTable.PSVersion))"
    $core = Initialize-BucketTools
    $ManifestDirectory = Assert-BucketPath $ManifestDirectory
    . "$core\lib\versions.ps1"
    # .NET Framework needs byte loading for UNC paths; .NET uses its shared load context.
    foreach ($name in 'Newtonsoft.Json', 'Newtonsoft.Json.Schema', 'Scoop.Validator') {
        if (!([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $name })) {
            $assemblyPath = "$core\supporting\validator\bin\$name.dll"
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $null = [Runtime.Loader.AssemblyLoadContext]::Default.LoadFromAssemblyPath($assemblyPath)
            } else {
                $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assemblyPath))
            }
        }
    }
    $validator = New-Object Scoop.Validator("$core/schema.json", $true)
    $manifests = @{}
    foreach ($file in Get-ChildItem $ManifestDirectory -Filter '*.json' -File) {
        $null = $validator.Validate($file.FullName)
        if ($validator.Errors.Count) { throw "$($file.Name): $($validator.ErrorsAsString)" }
        $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($script in @($manifest.checkver.script, $manifest.pre_install, $manifest.post_install, $manifest.pre_uninstall, $manifest.post_uninstall)) {
            if (!$script) { continue }
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput(($script -join "`n"), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "$($file.Name): $($parseErrors.Message -join '; ')" }
        }
        $manifests[$file.BaseName] = $manifest
        Write-BucketStatus "Schema and hooks: $($file.Name)" -Level PASS
    }
    foreach ($required in 'anki-latest', 'focust', 'neovide-nightly', 'neovim', 'neovim-nightly') {
        if (!$manifests.ContainsKey($required)) { throw "Required manifest is missing: $required" }
    }

    foreach ($file in Get-BucketFiles) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            throw "UTF-8 BOM: $($file.FullName)"
        }
        $text = [IO.File]::ReadAllText($file.FullName)
        if (!$text.EndsWith("`n") -or $text -match '(?<!\r)\n|\r(?!\n)' -or $text -match '(?m)[ \t]+\r?$') {
            throw "Invalid whitespace or line endings: $($file.FullName)"
        }
        if ($file.Extension -eq '.ps1') {
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "$($file.Name): $($parseErrors.Message -join '; ')" }
        }
    }
    Stop-BucketLogGroup
    Start-BucketLogGroup 'Version selection, release consistency and commit messages'
    & "$PSScriptRoot\..\tests\Checkver.Tests.ps1" -Manifests $manifests
} catch {
    Write-BucketStatus $_.Exception.Message -Level FAIL
    throw
} finally {
    Stop-BucketLogGroup
    Exit-BucketEnvironment $previous
}
Write-BucketStatus 'All bucket checks passed.' -Level PASS
