#Requires -Version 5.1

function Write-BucketStatus {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'PASS', 'UPDATE', 'WARN', 'FAIL')][string]$Level = 'INFO'
    )
    $Level = $Level.ToUpperInvariant()
    $colors = @{ INFO = 'Cyan'; PASS = 'Green'; UPDATE = 'Yellow'; WARN = 'Yellow'; FAIL = 'Red' }
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $codes = @{ INFO = '1;36'; PASS = '1;32'; UPDATE = '1;33'; WARN = '1;33'; FAIL = '1;31' }
        # Explicit ANSI also works in the Windows PowerShell 5.1 runner.
        Write-Host ('{0}[{1}m[{2}] {3}{0}[0m' -f [char]27, $codes[$Level], $Level, $Message)
    } else {
        Write-Host "[$Level] $Message" -ForegroundColor $colors[$Level]
    }
}

function Start-BucketLogGroup([string]$Title) {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::group::$Title"
    } else {
        Write-BucketStatus $Title
    }
}

function Stop-BucketLogGroup {
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host '::endgroup::' }
}

function Get-BucketRoot {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Assert-BucketPath([string]$Path) {
    $root = (Get-BucketRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (!$fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be inside this bucket: $Path"
    }
    $fullPath
}

function Write-Utf8File([string]$Path, [string]$Text) {
    $Path = Assert-BucketPath $Path
    $null = New-Item (Split-Path $Path) -ItemType Directory -Force
    $Text = ($Text -replace '\r?\n', "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Enter-BucketEnvironment {
    $work = Join-Path (Get-BucketRoot) '.local'
    $values = @{
        SCOOP = "$work\scoop"
        SCOOP_GLOBAL = "$work\scoop-global"
        SCOOP_CACHE = "$work\cache"
        SCOOP_HOME = "$work\tools\scoop"
        XDG_CONFIG_HOME = "$work\config"
        XDG_DATA_HOME = "$work\data"
        XDG_STATE_HOME = "$work\state"
        XDG_CACHE_HOME = "$work\cache"
        TEMP = "$work\tmp"
        TMP = "$work\tmp"
    }
    $previous = @{}
    foreach ($key in $values.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        $null = New-Item $values[$key] -ItemType Directory -Force
        [Environment]::SetEnvironmentVariable($key, $values[$key], 'Process')
    }
    $previous['SCOOP_GH_TOKEN'] = $env:SCOOP_GH_TOKEN
    $previous['NVIM_LOG_FILE'] = $env:NVIM_LOG_FILE
    $env:NVIM_LOG_FILE = "$work\nvim.log"
    if (!$env:SCOOP_GH_TOKEN -and $env:GITHUB_TOKEN) {
        $env:SCOOP_GH_TOKEN = $env:GITHUB_TOKEN
    }
    $config = Join-Path $env:XDG_CONFIG_HOME 'scoop\config.json'
    if (!(Test-Path $config)) {
        Write-Utf8File $config '{"aria2-enabled":false,"last_update":"2099-01-01T00:00:00Z"}'
    }
    return $previous
}

function Exit-BucketEnvironment([hashtable]$Previous) {
    foreach ($key in $Previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $Previous[$key], 'Process')
    }
}

function Get-VerifiedDownload([string]$Url, [string]$Hash, [string]$Extension = '.zip') {
    $ProgressPreference = 'SilentlyContinue'
    if ($Hash -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SHA-256 for $Url" }
    $path = Join-Path (Get-BucketRoot) ".local\downloads\$Hash$Extension"
    $null = New-Item (Split-Path $path) -ItemType Directory -Force
    if (!(Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash -ine $Hash) {
        $partial = "$path.partial"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
            if ((Get-FileHash $partial -Algorithm SHA256).Hash -ine $Hash) {
                throw "SHA-256 mismatch: $Url"
            }
            Move-Item $partial $path -Force
        } finally {
            if (Test-Path $partial) { Remove-Item $partial -Force }
        }
    }
    return $path
}

function Initialize-BucketTools {
    $tool = (Get-Content "$PSScriptRoot\tools.json" -Raw -Encoding UTF8 | ConvertFrom-Json).scoop
    $destination = Join-Path (Get-BucketRoot) '.local\tools\scoop'
    $marker = Join-Path $destination '.bucket-source-revision'
    if ((Test-Path $marker) -and (Get-Content $marker -Raw).Trim() -eq $tool.revision) {
        return $destination
    }
    $archive = Get-VerifiedDownload $tool.url $tool.hash
    $staging = Join-Path (Get-BucketRoot) ('.local\tmp\scoop-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $staging
        $source = Join-Path $staging "Scoop-$($tool.revision)"
        if (!(Test-Path "$source\supporting\validator\bin\Scoop.Validator.dll")) {
            throw 'Scoop source archive is incomplete.'
        }
        if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
        Move-Item $source $destination
        Write-Utf8File $marker $tool.revision
    } finally {
        if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    }
    return $destination
}

function Get-BucketFiles([string]$Directory = (Get-BucketRoot)) {
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.Name -in '.git', '.jj', '.local') { continue }
        if ($item.PSIsContainer) {
            Get-BucketFiles $item.FullName
        } else {
            $item
        }
    }
}
