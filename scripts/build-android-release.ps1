[CmdletBinding()]
param(
    [switch]$ResolveDependencies,
    [ValidateSet('android-arm', 'android-arm64', 'android-x64')]
    [string]$TargetPlatform
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$mobileRoot = Join-Path $repoRoot 'mobile'
$localProperties = Join-Path $mobileRoot 'android\local.properties'

if (-not (Test-Path -LiteralPath $localProperties)) {
    throw "Missing Flutter local.properties: $localProperties"
}

$flutterSdk = ((Get-Content -LiteralPath $localProperties) |
    Where-Object { $_ -match '^flutter\.sdk=' } |
    Select-Object -First 1) -replace '^flutter\.sdk=', ''
$flutter = Join-Path $flutterSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter executable not found: $flutter"
}

# Keep this on an ASCII path so native CMake/Ninja can resolve package sources.
if (-not $env:VIDEOGET_PUB_CACHE) {
    $env:VIDEOGET_PUB_CACHE = 'D:\flutter-pub-cache'
}
$env:PUB_CACHE = $env:VIDEOGET_PUB_CACHE

# Keep Gradle on the existing user cache even when Codex runs as SYSTEM.
if (-not $env:VIDEOGET_GRADLE_USER_HOME) {
    $env:VIDEOGET_GRADLE_USER_HOME = 'C:\Users\杨万杰\.gradle'
}
$env:GRADLE_USER_HOME = $env:VIDEOGET_GRADLE_USER_HOME

$proxy = Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort 7890 -ErrorAction SilentlyContinue
if ($proxy) {
    $proxyFlags = '-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890'
    $env:JAVA_TOOL_OPTIONS = (($env:JAVA_TOOL_OPTIONS, $proxyFlags) -join ' ').Trim()
}

$arguments = @('build', 'apk', '--release')
if (-not $ResolveDependencies) {
    $arguments += '--no-pub'
}
if ($TargetPlatform) {
    $arguments += @('--target-platform', $TargetPlatform)
}

Push-Location $mobileRoot
try {
    & $flutter @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter release build failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

$apk = Join-Path $mobileRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath $apk)) {
    throw "Flutter did not produce the expected APK: $apk"
}
Write-Output "Android release APK: $apk"
