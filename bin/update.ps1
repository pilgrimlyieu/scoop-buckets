#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$App = '*',
    [switch]$ForceUpdate,
    [switch]$ArchiveOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Tools.ps1"
. "$PSScriptRoot\..\scripts\ReleaseChecks.ps1"
$previous = Enter-BucketEnvironment
$root = Get-BucketRoot
$staging = Join-Path $root ('.local\updates\' + [guid]::NewGuid().ToString('N'))
$messagePath = Join-Path $root '.local\update-message.txt'
try {
    if (Test-Path $messagePath) { Remove-Item $messagePath -Force }
    $core = Initialize-BucketTools
    $null = New-Item $staging -ItemType Directory -Force
    Copy-Item "$root\bucket\*.json" $staging
    $files = @(Get-ChildItem $staging -Filter "$App.json" -File)
    if (!$files.Count) { throw "No manifest matches $App." }

    Start-BucketLogGroup "Check upstream versions and release assets: $App"
    try {
        & "$core\bin\checkver.ps1" -Dir $staging -App $App -Update -ForceUpdate:$ForceUpdate -ThrowError
        . "$core\lib\versions.ps1"
        foreach ($file in $files) {
            $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-ManifestReleaseAssets $manifest (Get-ReleasePage $manifest.checkver.url)
            Write-BucketStatus "$($file.BaseName) $($manifest.version): release assets match." -Level PASS
        }
    } finally {
        Stop-BucketLogGroup
    }
    & "$PSScriptRoot\test.ps1" -ManifestDirectory $staging

    $changed = @($files | Where-Object {
        [IO.File]::ReadAllText($_.FullName) -cne [IO.File]::ReadAllText("$root\bucket\$($_.Name)")
    })
    Write-BucketStatus "Checked $($files.Count) manifests; $($changed.Count) need updating."
    # Check actual packages before publishing new versions or hashes.
    foreach ($file in $changed) {
        & "$PSScriptRoot\test-packages.ps1" -App $file.BaseName -ManifestDirectory $staging -ArchiveOnly:$ArchiveOnly
        $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.architecture.arm64) {
            & "$PSScriptRoot\test-packages.ps1" -App $file.BaseName -ManifestDirectory $staging -Architecture arm64 -ArchiveOnly
        }
    }
    # Rolling releases may have changed during package verification.
    Start-BucketLogGroup 'Confirm upstream assets have not changed during verification'
    try {
        foreach ($file in $files) {
            $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-ManifestReleaseAssets $manifest (Get-ReleasePage $manifest.checkver.url)
        }
        Write-BucketStatus 'All selected release identities and hashes still match.' -Level PASS
    } finally {
        Stop-BucketLogGroup
    }
    $changes = @(foreach ($file in $changed) {
        [PSCustomObject]@{
            Name = $file.BaseName
            Before = (Get-Content "$root\bucket\$($file.Name)" -Raw -Encoding UTF8 | ConvertFrom-Json)
            After = (Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
    })
    if ($changes.Count) {
        Write-Utf8File $messagePath (New-UpdateCommitMessage $changes)
    }
    foreach ($file in $changed) {
        Copy-Item $file.FullName "$root\bucket\$($file.Name)" -Force
    }
    if ($changes.Count) {
        Write-BucketStatus (New-UpdateCommitMessage $changes) -Level UPDATE
        Write-BucketStatus "Applied $($changes.Count) verified manifest updates." -Level PASS
    } else {
        Write-BucketStatus 'All manifests are current. No package downloads or commit needed.' -Level PASS
    }
} catch {
    Write-BucketStatus $_.Exception.Message -Level FAIL
    throw
} finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    Exit-BucketEnvironment $previous
}
