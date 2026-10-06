# Offline Windows installer tests. Downloads are mocked; hashing and replacement are real.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
$installDir = Join-Path $scratch 'install with spaces'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalPath = $env:Path
$originalArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
$zaneTestState = @{
    Failure = $false
    Corrupt = $false
    Requests = @()
    Contents = [Text.Encoding]::UTF8.GetBytes('test release binary')
}

function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $zaneTestState.Requests += $Uri
    if ($zaneTestState.Failure) { throw 'Simulated failed download' }
    switch ($Uri) {
        'https://github.com/zane-lang/zane/releases/latest' {
            return [pscustomobject]@{ BaseResponse = [pscustomobject]@{
                ResponseUri = [uri]'https://github.com/zane-lang/zane/releases/tag/v0.0'
            } }
        }
        'https://github.com/zane-lang/zane/releases/download/v0.0/zane-windows-x86_64.exe' {
            $bytes = if ($zaneTestState.Corrupt) { [byte[]]@(1, 2, 3) } else { $zaneTestState.Contents }
            [IO.File]::WriteAllBytes($OutFile, $bytes)
        }
        'https://github.com/zane-lang/zane/releases/download/v0.0/SHA256SUMS' {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($zaneTestState.Contents)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            [IO.File]::WriteAllText($OutFile, "$hash  zane-windows-x86_64.exe`n")
        }
        default { throw "Unexpected download: $Uri" }
    }
}

function Assert-Installed {
    $actual = [IO.File]::ReadAllBytes((Join-Path $installDir 'zane.exe'))
    if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($zaneTestState.Contents)) {
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
    if ($zaneTestState.Requests.Count -ne 3) { throw 'Latest was not resolved exactly once' }
    if (($env:Path -split ';') -notcontains $installDir) { throw 'Current PATH was not updated' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $installDir) { throw 'User PATH was not updated' }
    [IO.File]::WriteAllText((Join-Path $installDir 'zane.exe'), 'old binary')
    & "$root/install.ps1" -Version v0.0 -InstallDir $installDir
    Assert-Installed
    $zaneTestState.Corrupt = $true
    Expect-Failure v0.0
    $zaneTestState.Corrupt = $false
    $zaneTestState.Failure = $true
    Expect-Failure v0.0
    Expect-Failure latest
    $zaneTestState.Failure = $false
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
