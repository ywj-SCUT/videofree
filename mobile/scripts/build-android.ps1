[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [string]$ProxyUrl = '',
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$mobileRoot = Split-Path -Parent $PSScriptRoot
$flutter = if ($env:FLUTTER_ROOT) {
    Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
} elseif (Test-Path -LiteralPath 'D:\tools\flutter\bin\flutter.bat') {
    'D:\tools\flutter\bin\flutter.bat'
} else {
    (Get-Command flutter.bat -ErrorAction Stop).Source
}

$env:PUB_CACHE = Join-Path $mobileRoot '.pub-cache'
New-Item -ItemType Directory -Path $env:PUB_CACHE -Force | Out-Null
if ($ProxyUrl) {
    $uri = [Uri]$ProxyUrl
    $env:HTTP_PROXY = $ProxyUrl
    $env:HTTPS_PROXY = $ProxyUrl
    $env:GRADLE_OPTS = "-Dhttp.proxyHost=$($uri.Host) -Dhttp.proxyPort=$($uri.Port) -Dhttps.proxyHost=$($uri.Host) -Dhttps.proxyPort=$($uri.Port)"
}

Push-Location $mobileRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $SkipChecks) {
        & $flutter analyze
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & $flutter test
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    & $flutter build apk "--$Mode"
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
