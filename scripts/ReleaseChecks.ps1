#Requires -Version 5.1

function Get-ReleasePage([string]$Url) {
    if ($Url -notlike 'https://api.github.com/repos/*/releases*') {
        throw "Unexpected release API: $Url"
    }
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:SCOOP_GH_TOKEN) { $headers.Authorization = "Bearer $env:SCOOP_GH_TOKEN" }
    (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing).Content
}

function Get-ManifestReleaseMatch($Manifest, [string]$Page) {
    $result = & {
        param($lines, $page)
        & ([scriptblock]::Create(($lines -join "`n")))
    } $Manifest.checkver.script $Page
    $match = [regex]::Match(($result -join "`n").Trim(), $Manifest.checkver.regex)
    if (!$match.Success -or !$match.Groups['version'].Success -or !$match.Groups['tag'].Success) {
        throw 'Release selector did not return a version and tag.'
    }
    return $match
}

function Assert-ManifestReleaseAssets($Manifest, [string]$Page) {
    $match = Get-ManifestReleaseMatch $Manifest $Page
    if ($Manifest.version -cne $match.Groups['version'].Value) {
        throw "Upstream changed while updating: expected $($match.Groups['version'].Value), got $($Manifest.version). Retry."
    }
    $tag = $match.Groups['tag'].Value
    $releases = @($Page | ConvertFrom-Json)
    $release = @($releases | Where-Object { !$_.draft -and $_.tag_name -ceq $tag })
    if ($release.Count -ne 1) { throw "Expected one published release for $tag." }
    foreach ($arch in $Manifest.architecture.PSObject.Properties) {
        $url = $arch.Value.url
        $asset = @($release[0].assets | Where-Object {
            $_.state -eq 'uploaded' -and $_.browser_download_url -ceq $url
        })
        if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
            throw "Release asset or SHA-256 is unavailable: $url"
        }
        if ($arch.Value.hash -ine $Matches[1]) {
            throw "Release asset changed while updating: $url. Retry."
        }
    }
}

function New-UpdateCommitMessage([array]$Changes) {
    $changesByName = @($Changes | Sort-Object Name)
    $details = @(foreach ($change in $changesByName) {
        $before = $change.Before
        $after = $change.After
        if ($before.version -cne $after.version) {
            "$($change.Name): $($before.version) -> $($after.version)"
            continue
        }
        $architectures = @(@($before.architecture.PSObject.Properties.Name) + @($after.architecture.PSObject.Properties.Name) | Sort-Object -Unique)
        $labels = @{ url = 'download URL'; hash = 'SHA-256'; extract_dir = 'extraction directory'; extract_to = 'extraction destination' }
        $fields = @(foreach ($field in 'url', 'hash', 'extract_dir', 'extract_to') {
            $oldValues = @($before.$field)
            $newValues = @($after.$field)
            foreach ($arch in $architectures) {
                $oldValues += $before.architecture.$arch.$field
                $newValues += $after.architecture.$arch.$field
            }
            if ((ConvertTo-Json -InputObject $oldValues -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $newValues -Depth 20 -Compress)) {
                $labels[$field]
            }
        })
        if (!$fields.Count) { $fields = @('manifest metadata') }
        "$($change.Name): refresh $($fields -join ' and ') for $($after.version)"
    })
    if (!$details.Count) { return '' }
    if ($details.Count -eq 1) { return $details[0] }
    $subject = "Update $($details.Count) apps: $($changesByName.Name -join ', ')"
    return $subject + "`n`n" + (($details | ForEach-Object { "- $_" }) -join "`n")
}
