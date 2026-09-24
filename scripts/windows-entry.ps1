#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$MainScript = Join-Path $PSScriptRoot 'windows.ps1'
$BootstrapScript = Join-Path $PSScriptRoot 'bootstrap-tunnel.ps1'
$Runtime = Join-Path $Root '.runtime'
$ChildPowerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $ChildPowerShell -PathType Leaf)) {
    $ChildPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
$script:EntryExitCode = 1
$command = if ($args.Count -gt 0) { ([string]$args[0]).ToLowerInvariant() } else { 'help' }
$known = @('help','install','start','stop','restart','apply','status','logs','update')

function Invoke-ScriptStep([string]$Path, [string[]]$Arguments) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing script: $Path" }
    # -File, not an interpolated -Command string. A fresh PowerShell process gives
    # us the script's exit code, not a stale native-probe LASTEXITCODE.
    & $ChildPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $script:EntryExitCode = $code
        throw "$(Split-Path -Leaf $Path) failed (exit $code)."
    }
}

try {
    if ($args.Count -gt 1 -or $command -notin $known) {
        [Console]::Error.WriteLine('Usage: .\agentdock.cmd {install|start|stop|restart|apply|status|logs|update|help}')
        exit 2
    }
    . (Join-Path $PSScriptRoot 'windows-runtime-checks.ps1')
    if ($command -in @('install','start','restart','apply','update')) {
        Configure-TunnelProxy
        Write-Host '==> Preparing tunnel-client'
        Invoke-ScriptStep -Path $BootstrapScript -Arguments @()
    }
    Invoke-ScriptStep -Path $MainScript -Arguments @($command)

    if ($command -in @('start','restart','apply')) {
        if (-not (Wait-ControlPlaneConnected -RuntimeDir $Runtime)) {
            Write-Host 'Control Plane : UNVERIFIED' -ForegroundColor Yellow
            [Console]::Error.WriteLine('Local services may be running, but this tunnel has no verified recent control-plane poll. They have NOT been stopped.')
            [Console]::Error.WriteLine('Run .\agentdock.cmd status and .\agentdock.cmd logs; check the proxy/network and Tunnel permissions. Exit code: 2.')
            exit 2
        }
        Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
        Write-Host 'Verify end-to-end access with a read-only tool call in ChatGPT.'
    } elseif ($command -eq 'status') {
        if (Test-ControlPlaneConnected -RuntimeDir $Runtime) {
            Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
        } else {
            Write-Host 'Control Plane : UNVERIFIED' -ForegroundColor Yellow
        }
    }
    exit 0
} catch {
    # Write-Error under ErrorActionPreference=Stop would throw before the handler
    # can finish. Do not auto-dump logs or configuration that may contain secrets.
    [Console]::Error.WriteLine("ERROR: Windows command '$command' failed. " + $_.Exception.Message)
    [Console]::Error.WriteLine('No configuration or runtime data was deleted. Run .\agentdock.cmd logs for service diagnostics; redact secrets before sharing.')
    exit $script:EntryExitCode
}
