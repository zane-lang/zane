# Install the CLI for the current Windows user, without administrator access.
param(
    [string]$Version = 'latest',
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Zane\bin"
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Use install.sh on Linux or macOS.'
}
$architecture = $env:PROCESSOR_ARCHITEW6432
if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
if ($architecture -ne 'AMD64') { throw 'The Windows release requires x86_64.' }

# Windows PowerShell 5.1 may otherwise negotiate an older TLS version.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repo = 'https://github.com/zane-lang/zane'
if ($Version -eq 'latest') {
    $release = Invoke-WebRequest -UseBasicParsing -Uri "$repo/releases/latest"
    if ($release.BaseResponse.PSObject.Properties['ResponseUri']) {
        $url = $release.BaseResponse.ResponseUri.AbsoluteUri
    } else {
        $url = $release.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    }
    if (-not $url.StartsWith("$repo/releases/tag/")) { throw 'GitHub did not return a release tag.' }
    $Version = $url.Substring($url.LastIndexOf('/') + 1)
}
if ($Version -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?\z') {
    throw 'Use a version such as v0.0 or v0.1.0.'
}

$asset = 'zane-windows-x86_64.exe'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$staged = $null
try {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $binary = Join-Path $tempDir 'zane.exe'
    $checksums = Join-Path $tempDir 'SHA256SUMS'
    $base = "$repo/releases/download/$Version"
    Write-Host "Downloading zane $Version ($asset)"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $binary
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $checksums
    $rows = @(Get-Content $checksums | Where-Object { $_ -cmatch ('^[0-9a-f]{64}  ' + [regex]::Escape($asset) + '$') })
    if ($rows.Count -ne 1) { throw 'The release has no valid checksum for this binary.' }
    $expected = $rows[0].Substring(0, 64)
    if ((Get-FileHash -Algorithm SHA256 -Path $binary).Hash.ToLowerInvariant() -cne $expected) {
        throw 'Checksum mismatch; nothing was installed.'
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $destination = Join-Path $InstallDir 'zane.exe'
    $staged = Join-Path $InstallDir ('.zane-' + [Guid]::NewGuid().ToString() + '.exe')
    Copy-Item -LiteralPath $binary -Destination $staged
    if (Test-Path -LiteralPath $destination) {
        # Replace atomically, and fail without deleting the old file if it is in use.
        [IO.File]::Replace($staged, $destination, [NullString]::Value)
    } else {
        [IO.File]::Move($staged, $destination)
    }
    $staged = $null
    $userPath = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $InstallDir) {
        $newPath = ($userPath.TrimEnd(';') + ';' + $InstallDir).TrimStart(';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }
    if (($env:Path -split ';') -notcontains $InstallDir) { $env:Path += ";$InstallDir" }
    Write-Host "Installed zane $Version at $destination"
    Write-Host 'The CLI also needs a compiler: put zanec on PATH or set ZANE_COMPILER.'
} finally {
    if ($staged -and (Test-Path -LiteralPath $staged)) { Remove-Item -LiteralPath $staged -Force }
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
