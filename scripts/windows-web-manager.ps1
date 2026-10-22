#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Runtime = Join-Path $Root '.runtime'
$ManagerScript = Join-Path $PSScriptRoot 'manage.py'
if (-not (Test-Path -LiteralPath $ManagerScript -PathType Leaf)) { exit 1 }

try {
    $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 18880 -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $pidPath = Join-Path $Runtime 'web-manager.pid'
        $storedPid = 0
        $owned = $false
        if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
            $value = (Get-Content -LiteralPath $pidPath -Raw).Trim()
            if ([int]::TryParse($value, [ref]$storedPid) -and $storedPid -gt 0) {
                $sameOwner = @($listeners | Where-Object { $_.OwningProcess -eq $storedPid })
                if ($sameOwner.Count -eq $listeners.Count) {
                    $proc = Get-Process -Id $storedPid -ErrorAction SilentlyContinue
                    $owned = [bool]($proc -and $proc.ProcessName.StartsWith('python', [StringComparison]::OrdinalIgnoreCase))
                }
            }
        }
        if ($owned) { exit 0 }
        [Console]::Error.WriteLine('Port 18880 is occupied by an unverified listener.')
        exit 1
    }
} catch {
    [Console]::Error.WriteLine('Cannot confirm Web Manager port ownership.')
    exit 1
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    [Console]::Error.WriteLine('Python 3.8+ is required for Web Manager.')
    exit 1
}

New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
$stdout = Join-Path $Runtime 'web-manager.out.log'
$stderr = Join-Path $Runtime 'web-manager.err.log'
$quotedScript = '"' + $ManagerScript.Replace('"', '') + '"'
$process = Start-Process -FilePath $python.Source -ArgumentList $quotedScript -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
Set-Content -LiteralPath (Join-Path $Runtime 'web-manager.pid') -Value $process.Id -Encoding ASCII
Start-Sleep -Milliseconds 300
if ($process.HasExited) { exit 1 }
Write-Host 'Web Manager : http://127.0.0.1:18880/'
exit 0
