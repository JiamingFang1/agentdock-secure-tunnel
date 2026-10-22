#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$Script = Join-Path $PSScriptRoot 'manage.py'
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) { exit 1 }
try {
    $listener = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 18880 -State Listen -ErrorAction SilentlyContinue
    if ($listener) { exit 0 }
} catch {}
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    [Console]::Error.WriteLine('Python is unavailable; Web Manager requires Python 3.8+.')
    exit 1
}
New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
$stdout = Join-Path $Runtime 'web-manager.out.log'
$stderr = Join-Path $Runtime 'web-manager.err.log'
$quotedScript = '"' + $Script.Replace('"', '') + '"'
$p = Start-Process -FilePath $python.Source -ArgumentList $quotedScript -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
Set-Content -LiteralPath (Join-Path $Runtime 'web-manager.pid') -Value $p.Id -Encoding ASCII
Start-Sleep -Milliseconds 300
if ($p.HasExited) { exit 1 }
Write-Host 'Web Manager : http://127.0.0.1:18880/'
exit 0
