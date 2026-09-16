#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$App = '*',
    [switch]$Update,
    [switch]$ForceUpdate
)

$ErrorActionPreference = 'Stop'
if ($Update -or $ForceUpdate) {
    & "$PSScriptRoot\update.ps1" -App $App -ForceUpdate:$ForceUpdate
    return
}
. "$PSScriptRoot\..\scripts\Tools.ps1"
$previous = Enter-BucketEnvironment
try {
    Start-BucketLogGroup "Check upstream versions: $App"
    $core = Initialize-BucketTools
    & "$core\bin\checkver.ps1" -Dir "$PSScriptRoot\..\bucket" -App $App -ThrowError
} finally {
    Stop-BucketLogGroup
    Exit-BucketEnvironment $previous
}
