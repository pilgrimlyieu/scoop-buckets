#Requires -Version 5.1
param([hashtable]$Manifests)

function Assert-Equal($Expected, $Actual, [string]$Name) {
    if ($Expected -cne $Actual) { throw "$Name : expected '$Expected', got '$Actual'." }
    Write-BucketStatus $Name -Level PASS
}

function Assert-Fails([scriptblock]$Action, [string]$Name) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (!$failed) { throw "$Name : expected failure." }
    Write-BucketStatus $Name -Level PASS
}

function New-AnkiRelease([string]$Tag, [bool]$HasWindows = $true, [bool]$Draft = $false) {
    @{
        tag_name = $Tag; draft = $Draft
        assets = @(if ($HasWindows) { @{ name = "anki-$Tag-win-x64.msi"; state = 'uploaded' } })
    }
}

function Get-SelectedVersion([string]$Name, $Releases) {
    (Get-ManifestReleaseMatch $Manifests[$Name] ($Releases | ConvertTo-Json -Depth 20)).Groups['version'].Value
}

$ankiCases = @(
    (New-AnkiRelease '26.09b3'), (New-AnkiRelease '26.09.1' $false),
    (New-AnkiRelease '26.09'), (New-AnkiRelease '27.01' $true $true),
    (New-AnkiRelease '26.08.9')
)
Assert-Equal '26.09' (Get-SelectedVersion 'anki-latest' $ankiCases) 'Anki ignores draft and missing Windows builds, and prefers final over beta'
$ankiCases += New-AnkiRelease '26.10b1'
Assert-Equal '26.10-beta1' (Get-SelectedVersion 'anki-latest' $ankiCases) 'Anki accepts a newer beta'
$beta = Get-ManifestReleaseMatch $Manifests['anki-latest'] ((New-AnkiRelease '26.09b3') | ConvertTo-Json -Depth 20)
Assert-Equal '26.09b3' $beta.Groups['tag'].Value 'Anki keeps the original download tag'
Assert-Equal '26.09-alpha2' (Get-SelectedVersion 'anki-latest' (New-AnkiRelease '26.09a2')) 'Anki normalizes alpha'
Assert-Equal '26.09-rc1' (Get-SelectedVersion 'anki-latest' (New-AnkiRelease '26.09rc1')) 'Anki normalizes RC'
Assert-Equal 1 (Compare-Version -ReferenceVersion '26.09-beta3' -DifferenceVersion '26.09') 'Scoop upgrades beta to final'
Assert-Fails { Get-SelectedVersion 'anki-latest' (New-AnkiRelease '26.09' $false) } 'Anki fails closed when no usable package exists'

$neovide = @{
    tag_name = 'nightly'; draft = $false
    assets = @(@{ name = 'neovide-windows-x86_64.zip'; state = 'uploaded'; id = 10; updated_at = '2026-09-06T13:18:56+08:00' })
}
Assert-Equal '20260906.051856.10' (Get-SelectedVersion 'neovide-nightly' $neovide) 'Neovide uses UTC asset time'
$neovide.assets[0].id = 11
Assert-Equal '20260906.051856.11' (Get-SelectedVersion 'neovide-nightly' $neovide) 'Neovide detects a same-second rebuild'
Assert-Equal 1 (Compare-Version -ReferenceVersion '20260906.051856.10' -DifferenceVersion '20260906.051856.11') 'Scoop orders Neovide rebuilds'
$neovide.assets = @()
Assert-Fails { Get-SelectedVersion 'neovide-nightly' $neovide } 'Neovide rejects an incomplete release'

$nvim = @{
    tag_name = 'nightly'; draft = $false; body = 'NVIM v0.13.0-dev-1644+gabcdef'
    assets = @(
        @{ name = 'nvim-win64.zip'; state = 'uploaded'; id = 20 },
        @{ name = 'nvim-win-arm64.zip'; state = 'uploaded'; id = 21 }
    )
}
Assert-Equal '0.13.0-1644.21' (Get-SelectedVersion 'neovim-nightly' $nvim) 'Neovim records the build identity'
$nvim.assets[0].id = 22
Assert-Equal '0.13.0-1644.22' (Get-SelectedVersion 'neovim-nightly' $nvim) 'Neovim detects either architecture being rebuilt'
Assert-Equal 1 (Compare-Version -ReferenceVersion '0.13.0-1644.21' -DifferenceVersion '0.13.0-1644.22') 'Scoop orders Neovim rebuilds'
$nvim.assets = @($nvim.assets[0])
Assert-Fails { Get-SelectedVersion 'neovim-nightly' $nvim } 'Neovim requires both declared architectures'

$stable = @{ tag_name = 'v1.2.3'; draft = $false; prerelease = $false }
foreach ($name in 'focust', 'neovim') {
    Assert-Equal '1.2.3' (Get-SelectedVersion $name $stable) "$name follows stable releases"
}
$stable.prerelease = $true
Assert-Fails { Get-SelectedVersion 'focust' $stable } 'Stable channel rejects prereleases'

$copy = $Manifests['focust'] | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$release = @{
    tag_name = "v$($copy.version)"; draft = $false; prerelease = $false
    assets = @(@{ state = 'uploaded'; browser_download_url = $copy.architecture.'64bit'.url; digest = "sha256:$($copy.architecture.'64bit'.hash)" })
}
$page = $release | ConvertTo-Json -Depth 20
Assert-ManifestReleaseAssets $copy $page
Write-BucketStatus 'Release guard accepts a matching version, URL and hash' -Level PASS
$copy.architecture.'64bit'.hash = '0' * 64
Assert-Fails { Assert-ManifestReleaseAssets $copy $page } 'Release guard rejects mismatched hashes'
$copy = $Manifests['focust'] | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$copy.architecture.'64bit'.url = 'https://example.invalid/older-build.zip'
Assert-Fails { Assert-ManifestReleaseAssets $copy $page } 'Release guard rejects an asset from a different release'
$copy.version = '0'
Assert-Fails { Assert-ManifestReleaseAssets $copy $page } 'Release guard rejects a stale version'

$before = $Manifests['focust'] | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$after = $before | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$before.version = '0.4.0'
$after.version = '0.4.1'
$change = [PSCustomObject]@{ Name = 'focust'; Before = $before; After = $after }
Assert-Equal 'focust: 0.4.0 -> 0.4.1' (New-UpdateCommitMessage @($change)) 'Single-app commit names the old and new versions'
$other = [PSCustomObject]@{ Name = 'anki-latest'; Before = @{ version = '26.09.2' }; After = @{ version = '26.10-beta1' } }
$expected = "Update 2 apps: anki-latest, focust`n`n- anki-latest: 26.09.2 -> 26.10-beta1`n- focust: 0.4.0 -> 0.4.1"
Assert-Equal $expected (New-UpdateCommitMessage @($change, $other)) 'Multi-app commit lists every version change'
$before.version = $after.version
$after.architecture.'64bit'.hash = '0' * 64
Assert-Equal 'focust: refresh SHA-256 for 0.4.1' (New-UpdateCommitMessage @($change)) 'Same-version commit explains a hash refresh'
$after.architecture.'64bit'.url = 'https://example.invalid/new-download.zip'
Assert-Equal 'focust: refresh download URL and SHA-256 for 0.4.1' (New-UpdateCommitMessage @($change)) 'Same-version commit lists all changed download fields'
Assert-Equal '' (New-UpdateCommitMessage @()) 'No changes produce no commit message'
