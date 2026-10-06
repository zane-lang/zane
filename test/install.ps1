# Offline Windows installer tests. Downloads are mocked; hashing and replacement are real.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$installDir = Join-Path $scratch 'install with spaces'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalPath = $env:Path
$originalArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
$script:failure = $false
$script:corrupt = $false
$script:requests = @()
$script:contents = [Text.Encoding]::UTF8.GetBytes('test release binary')

function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $script:requests += $Uri
    if ($script:failure) { throw 'Simulated failed download' }
    switch ($Uri) {
        'https://github.com/zane-lang/zane/releases/latest' {
            return [pscustomobject]@{ BaseResponse = [pscustomobject]@{
                ResponseUri = [uri]'https://github.com/zane-lang/zane/releases/tag/v0.0'
            } }
        }
        'https://github.com/zane-lang/zane/releases/download/v0.0/zane-windows-x86_64.exe' {
            $bytes = if ($script:corrupt) { [byte[]]@(1, 2, 3) } else { $script:contents }
            [IO.File]::WriteAllBytes($OutFile, $bytes)
        }
        'https://github.com/zane-lang/zane/releases/download/v0.0/SHA256SUMS' {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($script:contents)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            [IO.File]::WriteAllText($OutFile, "$hash  zane-windows-x86_64.exe`n")
        }
        default { throw "Unexpected download: $Uri" }
    }
}

function Assert-Installed {
    $actual = [IO.File]::ReadAllBytes((Join-Path $installDir 'zane.exe'))
    if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($script:contents)) {
        throw 'Installed binary changed unexpectedly'
    }
}

function Expect-Failure {
    param([string]$Version)
    $failed = $false
    try { & "$root/install.ps1" -Version $Version -InstallDir $installDir }
    catch { $failed = $true }
    if (-not $failed) { throw "Installer unexpectedly accepted $Version" }
    Assert-Installed
    if (Get-ChildItem -LiteralPath $installDir -Filter '.zane-*') { throw 'A staged binary was left behind' }
}

try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:PROCESSOR_ARCHITEW6432 = ''
    # Exercise installation for a user with no PATH; restore it below.
    [Environment]::SetEnvironmentVariable('Path', '', 'User')
    & "$root/install.ps1" -InstallDir $installDir
    Assert-Installed
    if ($script:requests.Count -ne 3) { throw 'Latest was not resolved exactly once' }
    if (($env:Path -split ';') -notcontains $installDir) { throw 'Current PATH was not updated' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $installDir) { throw 'User PATH was not updated' }
    [IO.File]::WriteAllText((Join-Path $installDir 'zane.exe'), 'old binary')
    & "$root/install.ps1" -Version v0.0 -InstallDir $installDir
    Assert-Installed
    $script:corrupt = $true
    Expect-Failure v0.0
    $script:corrupt = $false
    $script:failure = $true
    Expect-Failure v0.0
    Expect-Failure latest
    $script:failure = $false
    Expect-Failure 'v0.0; unexpected'
    Expect-Failure "v0.0`n"
    Expect-Failure v00.0
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Expect-Failure v0.0
    Write-Host 'Windows installer integration tests passed'
} finally {
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    $env:Path = $originalPath
    $env:PROCESSOR_ARCHITECTURE = $originalArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $originalArchitectureW6432
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
