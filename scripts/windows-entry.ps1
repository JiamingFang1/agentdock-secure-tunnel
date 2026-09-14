#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MainScript = Join-Path $PSScriptRoot 'windows.ps1'
$MetricsUrl = 'http://127.0.0.1:8080/metrics'

function Normalize-ProxyUrl([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match '^[A-Za-z][A-Za-z0-9+.-]*://') { return $v }
    return "http://$v"
}

function Get-SystemProxy {
    try {
        $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$settings.ProxyEnable -ne 1) { return $null }
        $raw = [string]$settings.ProxyServer
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        $http = $null
        $https = $null
        if ($raw.Contains('=')) {
            foreach ($part in ($raw -split ';')) {
                $pair = $part.Split('=', 2)
                if ($pair.Count -ne 2) { continue }
                $name = $pair[0].Trim().ToLowerInvariant()
                $value = Normalize-ProxyUrl $pair[1]
                switch ($name) {
                    'http'  { $http = $value }
                    'https' { $https = $value }
                }
            }
        } else {
            $http = Normalize-ProxyUrl $raw
            $https = $http
        }

        if (-not $https) { $https = $http }
        if (-not $http) { $http = $https }
        if (-not $http -and -not $https) { return $null }
        return [pscustomobject]@{ Http=$http; Https=$https; Raw=$raw }
    } catch {
        return $null
    }
}

function Add-LoopbackNoProxy {
    $items = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:NO_PROXY)) {
        foreach ($item in ($env:NO_PROXY -split '[,;]')) {
            $v = $item.Trim()
            if ($v -and -not $items.Contains($v)) { $items.Add($v) }
        }
    }
    foreach ($required in @('127.0.0.1','localhost','::1')) {
        if (-not $items.Contains($required)) { $items.Add($required) }
    }
    $env:NO_PROXY = ($items -join ',')
}

function Configure-TunnelProxy {
    $proxySource = $null

    if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) {
        if ([string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) { $env:HTTPS_PROXY = $env:HTTP_PROXY }
        if ([string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) { $env:HTTP_PROXY = $env:HTTPS_PROXY }
        $proxySource = 'environment'
    } else {
        $systemProxy = Get-SystemProxy
        if ($null -ne $systemProxy) {
            $env:HTTP_PROXY = $systemProxy.Http
            $env:HTTPS_PROXY = $systemProxy.Https
            $proxySource = 'Windows System Proxy'
        }
    }

    if ($proxySource) {
        Add-LoopbackNoProxy
        Write-Host "Tunnel proxy : $proxySource -> $($env:HTTPS_PROXY)"
    }
}

function Get-MetricValue([string]$Name) {
    try {
        $response = Invoke-WebRequest $MetricsUrl -UseBasicParsing -TimeoutSec 2
        foreach ($line in ($response.Content -split "`n")) {
            if ($line -match ('^' + [regex]::Escape($Name) + '(?:\{[^}]*\})?\s+([0-9eE+.-]+)\s*$')) {
                $value = 0.0
                if ([double]::TryParse($matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                    return $value
                }
            }
        }
    } catch {}
    return 0.0
}

function Test-ControlPlaneConnected {
    return ((Get-MetricValue 'commands_poll_last_successful_timestamp_seconds') -gt 0)
}

function Wait-ControlPlaneConnected {
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-ControlPlaneConnected) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Show-ControlPlaneFailure {
    $errors = Get-MetricValue 'commands_poll_errors_total'
    Write-Host ''
    Write-Warning 'Tunnel process is running, but OpenAI Control Plane polling has not succeeded.'
    Write-Host "Control Plane poll errors: $errors"
    Write-Host 'If you use Clash or another Windows system proxy, make sure its local proxy is running.'
    Write-Host 'You can also set HTTP_PROXY / HTTPS_PROXY explicitly before starting AgentDock.'
    Write-Host ''
    try { & $MainScript logs } catch {}
}

Configure-TunnelProxy

$command = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
try {
    & $MainScript @args
} catch {
    Write-Error $_
    if ($command -in @('start','restart','apply')) {
        try { & $MainScript logs } catch {}
    }
    exit 1
}

if ($command -in @('start','restart','apply')) {
    if (-not (Wait-ControlPlaneConnected)) {
        Show-ControlPlaneFailure
        exit 1
    }
    Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
} elseif ($command -eq 'status') {
    if (Test-ControlPlaneConnected) {
        Write-Host 'Control Plane : CONNECTED' -ForegroundColor Green
    } elseif (Test-Path (Join-Path (Split-Path -Parent $PSScriptRoot) '.runtime\tunnel-client.pid')) {
        Write-Host 'Control Plane : UNAVAILABLE' -ForegroundColor Yellow
    }
}
