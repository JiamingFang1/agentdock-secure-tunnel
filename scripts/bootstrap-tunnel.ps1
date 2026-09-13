#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$Bin = Join-Path $Runtime 'bin'
$Destination = Join-Path $Bin 'tunnel-client.exe'

if (Test-Path $Destination) { exit 0 }

function Get-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { throw "Unsupported Windows architecture: $arch" }
    }
}

New-Item -ItemType Directory -Force $Runtime, $Bin | Out-Null
$arch = Get-Arch
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/openai/tunnel-client/releases/latest' -Headers @{'User-Agent'='agentdock-secure-tunnel'}
$asset = $release.assets | Where-Object { $_.name -match "^tunnel-client-runtime-cloudflared-v.+-windows-${arch}\.zip$" } | Select-Object -First 1
if (-not $asset) { throw "Unable to locate tunnel-client runtime-cloudflared asset for Windows $arch" }

Write-Host "Installing OpenAI tunnel-client from $($asset.name)..."
$archive = Join-Path $Runtime 'tunnel-client.zip'
$extract = Join-Path $Runtime 'tunnel-client-extract'
Remove-Item $archive -Force -ErrorAction SilentlyContinue
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing
Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force

$binary = Get-ChildItem $extract -Recurse -File | Where-Object {
    $_.Name -match '^tunnel-client-runtime-cloudflared.*\.exe$'
} | Select-Object -First 1

if (-not $binary) {
    $binary = Get-ChildItem $extract -Recurse -File | Where-Object {
        $_.Extension -eq '.exe' -and $_.Name -match '^tunnel-client.*\.exe$'
    } | Select-Object -First 1
}

if (-not $binary) {
    $files = (Get-ChildItem $extract -Recurse -File | Select-Object -ExpandProperty FullName) -join "`n"
    throw "No tunnel-client executable found in downloaded archive. Archive contents:`n$files"
}

Copy-Item $binary.FullName $Destination -Force
Remove-Item $archive -Force -ErrorAction SilentlyContinue
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue

& $Destination --version
