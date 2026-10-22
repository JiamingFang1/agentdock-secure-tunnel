#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$Script = Join-Path $PSScriptRoot 'manage.py'
if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) { exit 1 }
try {
    $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 18880 -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $pidFile = Join-Path $Runtime 'web-manager.pid'
        $storedPid = 0
        if ((Test-Path -LiteralPath $pidFile -PathType Leaf) -and
            [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$storedPid) -and
            $storedPid -gt 0 -and
            (@($listeners | Where-Object { $_.OwningProcess -eq $storedPid }).Count -eq $listeners.Count)) {
            $existing = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
            if ($existing -and $existing.ProcessName -match '^python(?:w)?
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
) { exit 0 }
        }
        [Console]::Error.WriteLine('Port 18880 is occupied by an unverified process; refusing to reuse it.')
        exit 1
    }
} catch {
    [Console]::Error.WriteLine('Unable to verify Web Manager port ownership.')
    exit 1
}
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
