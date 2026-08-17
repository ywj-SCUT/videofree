[CmdletBinding()]
param(
    [string]$ApkPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedPath = Join-Path $repoRoot '.signing\EXPECTED_CERT_SHA256'
if (-not (Test-Path -LiteralPath $expectedPath)) {
    throw "Missing expected certificate file: $expectedPath"
}
$expected = (Get-Content -LiteralPath $expectedPath -Raw).Trim().Replace(':', '').ToLowerInvariant()

if (-not $ApkPath) {
    $ApkPath = Join-Path $repoRoot 'mobile\build\app\outputs\flutter-apk\app-release.apk'
}
$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path

$sdkRoots = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    'C:\Android\Sdk',
    'D:\Android\Sdk'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$apksigner = $null
foreach ($sdkRoot in $sdkRoots) {
    $buildTools = Join-Path $sdkRoot 'build-tools'
    if (-not (Test-Path -LiteralPath $buildTools)) {
        continue
    }
    $candidate = Get-ChildItem -LiteralPath $buildTools -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ($candidate) {
        $apksigner = $candidate
        break
    }
}

if (-not $apksigner) {
    throw 'apksigner.bat was not found in the configured Android SDK.'
}

$verification = @(& $apksigner verify --verbose --print-certs $resolvedApk 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "APK signature verification failed:`n$($verification -join "`n")"
}

$match = [regex]::Match(
    ($verification -join "`n"),
    'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F:]+)'
)
if (-not $match.Success) {
    throw 'The APK certificate SHA-256 digest was not reported by apksigner.'
}

$actual = $match.Groups[1].Value.Replace(':', '').ToLowerInvariant()
if ($actual -ne $expected) {
    throw "Android signing certificate changed. Expected $expected, got $actual."
}

Write-Output "Android signing certificate verified: $actual"
