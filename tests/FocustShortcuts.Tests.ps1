#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][PSCustomObject]$Manifest,
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [string]$VersionDirectory,
    [ValidateSet('64bit', 'arm64')][string]$Architecture = '64bit'
)

$ErrorActionPreference = 'Stop'
$shortcutPath = Join-Path (shortcut_folder $false) 'Focust.lnk'

function Assert-FocustShortcut([string]$Stage) {
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace((Split-Path $shortcutPath))
    $item = $folder.ParseName('Focust.lnk')
    if (!$item) { throw "Focust shortcut is missing after $Stage." }
    $identity = $item.ExtendedProperty('System.AppUserModel.ID')
    if ($identity -ne 'com.fesmoph.focust') {
        throw "Focust notification identity is missing after ${Stage}: '$identity'."
    }
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    if ($shortcut.TargetPath -ine (Join-Path $InstallDirectory 'focust.exe')) {
        throw "Focust shortcut does not target the current installation after $Stage."
    }
    if ($shortcut.WorkingDirectory -ine $InstallDirectory) {
        throw "Focust shortcut has the wrong working directory after $Stage."
    }
    Write-BucketStatus "Focust notification identity: $Stage" -Level PASS
}

Assert-FocustShortcut 'installation'

# Scoop reset invokes this real shortcut creator without running post_install.
create_startmenu_shortcuts $Manifest $InstallDirectory $false $Architecture
Assert-FocustShortcut 'the shortcut step used by scoop reset'

# The hook must be safe to rerun in the same PowerShell process.
Invoke-HookScript -HookType post_install -Manifest $Manifest -ProcessorArchitecture $Architecture
Assert-FocustShortcut 'repeated post_install'

# A fresh shortcut must regain the identity, even without any Shell cache.
Remove-Item -LiteralPath $shortcutPath -Force
create_startmenu_shortcuts $Manifest $InstallDirectory $false $Architecture
Invoke-HookScript -HookType post_install -Manifest $Manifest -ProcessorArchitecture $Architecture
Assert-FocustShortcut 'shortcut recreation followed by post_install'

if ($VersionDirectory) {
    # Exercise the real junction switch used during an update, with a copy of the exe.
    $nextVersion = Join-Path (Split-Path $VersionDirectory) ('notification-update-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item $nextVersion -ItemType Directory
    try {
        Copy-Item (Join-Path $VersionDirectory 'focust.exe') (Join-Path $nextVersion 'focust.exe')
        $InstallDirectory = link_current $nextVersion
        $dir = $InstallDirectory
        create_startmenu_shortcuts $Manifest $dir $false $Architecture
        Invoke-HookScript -HookType post_install -Manifest $Manifest -ProcessorArchitecture $Architecture
        Assert-FocustShortcut 'a version switch'
    } finally {
        $null = link_current $VersionDirectory
        Remove-Item -LiteralPath $nextVersion -Recurse -Force
    }
}
