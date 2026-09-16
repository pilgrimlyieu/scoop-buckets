#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$App = '*',
    [string]$ManifestDirectory,
    [ValidateSet('64bit', 'arm64')][string]$Architecture = '64bit',
    [switch]$ArchiveOnly
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\Tools.ps1"
$root = Get-BucketRoot
if (!$ManifestDirectory) { $ManifestDirectory = Join-Path $root 'bucket' }
if (!$ArchiveOnly -and $root.StartsWith('\\')) {
    throw 'Full package tests need a Windows local filesystem for junctions. Use CI, or -ArchiveOnly for WSL archive checks.'
}
if (!$ArchiveOnly -and $Architecture -ne '64bit') {
    throw 'Native integration tests currently run on x64. Use -ArchiveOnly for ARM64.'
}
$previous = Enter-BucketEnvironment
$originalPath = $env:PATH
$sandbox = Join-Path $root ('.local\package-tests\' + [guid]::NewGuid().ToString('N'))
$success = $false
try {
    $core = Initialize-BucketTools
    $ManifestDirectory = Assert-BucketPath $ManifestDirectory
    foreach ($library in 'core', 'json', 'versions', 'buckets', 'manifest', 'download', 'decompress', 'shortcuts', 'psmodules', 'install') {
        . "$core\lib\$library.ps1"
    }
    $scoopdir = "$sandbox\scoop"
    $globaldir = "$sandbox\global"
    $bucketsdir = "$scoopdir\buckets"
    $null = New-Item $scoopdir -ItemType Directory -Force
    $null = New-Item $bucketsdir -ItemType Directory -Force
    $supporting = "$scoopdir\apps\scoop\current\supporting"
    $null = New-Item $supporting -ItemType Directory -Force
    Copy-Item "$core\supporting\shims" $supporting -Recurse

    # Redirect the two OS integration boundaries; all Scoop file operations remain real.
    function Add-Path {
        param([string[]]$Path, [string]$TargetEnvVar = 'PATH', [switch]$Global, [switch]$Force, [switch]$Quiet)
        if ($Global -or $TargetEnvVar -ne 'PATH') { throw 'Only process PATH changes are allowed in package tests.' }
        $env:PATH = (@($Path) + @($env:PATH -split ';' | Where-Object { $_ -notin $Path })) -join ';'
    }
    function shortcut_folder($global) {
        if ($global) { throw 'Global shortcuts are not allowed in package tests.' }
        $folder = "$sandbox\shortcuts"
        $null = New-Item $folder -ItemType Directory -Force
        return $folder
    }

    $files = @(Get-ChildItem $ManifestDirectory -Filter "$App.json" -File)
    if (!$files.Count) { throw "No manifest matches $App." }
    foreach ($file in $files) {
        $app = $file.BaseName
        $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $arch = $manifest.architecture.$Architecture
        if (!$arch) { throw "$app does not declare $Architecture." }
        $version = $manifest.version
        Start-BucketLogGroup "$app $version [$Architecture]"
        try {
            $cmd = 'install'
            $dir = versiondir $app $version $false
            $original_dir = $dir
            $persist_dir = persistdir $app $false
            $null = New-Item $dir -ItemType Directory -Force
            $extension = [IO.Path]::GetExtension(([uri]$arch.url).AbsolutePath)
            $archive = Get-VerifiedDownload $arch.url $arch.hash $extension
            Write-BucketStatus "SHA-256 verified; checking archive contents."

            if ($extension -eq '.msi') {
                if ($root.StartsWith('\\')) {
                    throw 'The MSI hash is verified, but Windows Installer cannot open an MSI on WSL UNC storage. Run package extraction in Windows CI.'
                }
                $tool = (Get-Content "$PSScriptRoot\..\scripts\tools.json" -Raw | ConvertFrom-Json).lessmsi
                $toolArchive = Get-VerifiedDownload $tool.url $tool.hash
                $helper = "$scoopdir\apps\lessmsi\current"
                if (!(Test-Path "$helper\lessmsi.exe")) {
                    Expand-Archive -LiteralPath $toolArchive -DestinationPath $helper
                }
                $scoopConfig | Add-Member -MemberType NoteProperty -Name use_lessmsi -Value $true -Force
                Expand-MsiArchive -Path $archive -DestinationPath $dir -ExtractDir $arch.extract_dir
            } elseif ($extension -eq '.zip') {
                Expand-ZipArchive -Path $archive -DestinationPath $dir -ExtractDir $arch.extract_dir
            } else {
                throw "Unsupported archive type: $extension"
            }

            Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture $Architecture
            foreach ($entry in @($manifest.bin)) {
                $target = if ($entry -is [array]) { $entry[0] } else { $entry }
                if (!(Test-Path "$dir\$target" -PathType Leaf)) { throw "Missing bin target: $app/$target" }
            }
            foreach ($shortcut in @($manifest.shortcuts)) {
                if ($null -eq $shortcut) { continue }
                if (!(Test-Path "$dir\$($shortcut[0])" -PathType Leaf)) { throw "Missing shortcut target in $app." }
                if ($shortcut.Count -ge 4 -and !(Test-Path "$dir\$($shortcut[3])" -PathType Leaf)) { throw "Missing shortcut icon in $app." }
            }
            if ($app -eq 'focust' -and !(Test-Path "$dir\assets\sounds\soft-gong.mp3")) { throw 'Focust sound resources are missing.' }

            if (!$ArchiveOnly) {
                Write-BucketStatus 'Checking Scoop hooks, shims, shortcuts and persistence.'
                $dir = link_current $dir
                create_shims $manifest $dir $false $Architecture
                create_startmenu_shortcuts $manifest $dir $false $Architecture
                persist_data $manifest $original_dir $persist_dir
                Invoke-HookScript -HookType post_install -Manifest $manifest -ProcessorArchitecture $Architecture
                foreach ($shortcut in @($manifest.shortcuts)) {
                    if ($null -ne $shortcut -and !(Test-Path "$sandbox\shortcuts\$($shortcut[1]).lnk")) { throw "Shortcut creation failed for $app." }
                }
                if ($app -eq 'focust') {
                    & "$PSScriptRoot\..\tests\FocustShortcuts.Tests.ps1" -Manifest $manifest -InstallDirectory $dir -VersionDirectory $original_dir -Architecture $Architecture
                }
                if ($app -like 'neovim*') {
                    $shimText = Get-Content "$scoopdir\shims\win32yank.shim" -Raw
                    if (!$shimText.Contains("$dir\bin\win32yank.exe")) { throw 'win32yank shim points to the wrong package.' }
                    $probe = "$sandbox\nvim-check.lua"
                    Write-Utf8File $probe @'
assert(vim.fn.executable('win32yank.exe') == 1, 'win32yank is not discoverable')
print('Neovim ' .. tostring(vim.version()) .. ': clipboard executable found')
'@
                    $process = Start-Process "$scoopdir\shims\nvim.exe" -ArgumentList @('--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', "`"$probe`"") -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$sandbox\nvim.stdout" -RedirectStandardError "$sandbox\nvim.stderr"
                    if ($process.ExitCode -ne 0) { throw "Neovim smoke test failed: $([IO.File]::ReadAllText("$sandbox\nvim.stderr"))" }
                    if ($env:GITHUB_ACTIONS -eq 'true') {
                        Write-Utf8File $probe @'
vim.g.clipboard = 'win32yank'
local expected = { 'scoop-bucket-clipboard-test', 'second line' }
vim.fn.setreg('+', expected, 'V')
local actual, status
local copied = vim.wait(5000, function()
    actual = vim.fn.systemlist({ 'win32yank.exe', '-o', '--lf' })
    status = vim.v.shell_error
    return status == 0 and vim.deep_equal(expected, actual)
end, 50)
assert(copied, 'clipboard round trip failed: exit=' .. tostring(status) .. ', output=' .. vim.inspect(actual))
'@
                        $process = Start-Process "$scoopdir\shims\nvim.exe" -ArgumentList @('--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-l', "`"$probe`"") -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$sandbox\clipboard.stdout" -RedirectStandardError "$sandbox\clipboard.stderr"
                        if ($process.ExitCode -ne 0) { throw "Clipboard test failed: $([IO.File]::ReadAllText("$sandbox\clipboard.stderr"))" }
                    }
                }
                if ($app -eq 'anki-latest') {
                    Write-Utf8File "$dir\data\bucket-test.txt" 'persistent card-data marker'
                    if (!(Test-Path "$persist_dir\data\bucket-test.txt")) { throw 'Anki data is not persisted.' }
                }
                # Exercise cleanup without touching external application data.
                unlink_persist_data $manifest $dir
                rm_shims $app $manifest $false $Architecture
                rm_startmenu_shortcuts $manifest $false $Architecture
                unlink_current $original_dir | Out-Null
                Remove-Item $original_dir -Recurse -Force
                if ($app -eq 'anki-latest') {
                    if (!(Test-Path "$persist_dir\data\bucket-test.txt")) { throw 'Anki uninstall removed persisted data.' }
                    $dir = "$scoopdir\apps\$app\next-version"
                    $null = New-Item $dir -ItemType Directory -Force
                    persist_data $manifest $dir $persist_dir
                    if ((Get-Content "$dir\data\bucket-test.txt" -Raw).Trim() -ne 'persistent card-data marker') { throw 'Anki reinstall lost persisted data.' }
                    unlink_persist_data $manifest $dir
                }
            }
            $result = @{ app = $app; version = $version; architecture = $Architecture; sha256 = $arch.hash; archive_only = [bool]$ArchiveOnly; passed = $true }
            Write-Utf8File "$root\.local\results\$app-$Architecture.json" ($result | ConvertTo-Json)
        } catch {
            Write-BucketStatus "$app $version [$Architecture]: $($_.Exception.Message)" -Level FAIL
            throw
        } finally {
            Stop-BucketLogGroup
        }
        Write-BucketStatus "$app $version [$Architecture]" -Level PASS
    }
    Write-BucketStatus "Verified $($files.Count) packages [$Architecture]." -Level PASS
    $success = $true
} finally {
    $env:PATH = $originalPath
    if ($success -and (Test-Path $sandbox)) { Remove-Item $sandbox -Recurse -Force }
    Exit-BucketEnvironment $previous
}
