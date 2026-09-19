#requires -Version 5.1
# Local diagnostics only; this file never installs or starts a service.
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
                $value = Normalize-ProxyUrl $pair[1]
                switch ($pair[0].Trim().ToLowerInvariant()) {
                    'http' { $http = $value }
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
        return [pscustomobject]@{ Http=$http; Https=$https }
    } catch { return $null }
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
    $env:NO_PROXY = $items -join ','
}

function Configure-TunnelProxy {
    $source = $null
    if (-not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY) -or -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) {
        if ([string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)) { $env:HTTPS_PROXY = $env:HTTP_PROXY }
        if ([string]::IsNullOrWhiteSpace($env:HTTP_PROXY)) { $env:HTTP_PROXY = $env:HTTPS_PROXY }
        $source = 'environment'
    } else {
        $proxy = Get-SystemProxy
        if ($null -ne $proxy) {
            $env:HTTP_PROXY = $proxy.Http
            $env:HTTPS_PROXY = $proxy.Https
            $source = 'Windows System Proxy'
        }
    }
    Add-LoopbackNoProxy
    # A URL can contain credentials. Log only its source, never the full value.
    if ($source) { Write-Host "Tunnel proxy : $source (credentials hidden)" }
}

function Get-PollTimestamp([string]$Content) {
    $latest = 0.0
    foreach ($line in ($Content -split "`n")) {
        if ($line -match '^commands_poll_last_successful_timestamp_seconds(?:\{[^}]*\})?\s+([0-9eE+.-]+)\s*$') {
            $value = 0.0
            if ([double]::TryParse($matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                if (-not [double]::IsInfinity($value) -and -not [double]::IsNaN($value) -and $value -gt $latest) { $latest = $value }
            }
        }
    }
    return $latest
}

function Read-LocalTunnelMetrics {
    # Never use a proxy for the loopback diagnostics endpoint.
    $request = [Net.WebRequest]::Create('http://127.0.0.1:8080/metrics')
    $request.Proxy = $null
    $request.Timeout = 2000
    $request.ReadWriteTimeout = 2000
    $response = $request.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Close() }
}

function Test-ControlPlaneConnected([string]$RuntimeDir) {
    # Current releases default to metrics port 8080. If it is moved/disabled, or
    # provenance cannot be established, report UNVERIFIED rather than guessing.
    try {
        $pidPath = Join-Path $RuntimeDir 'tunnel-client.pid'
        if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) { return $false }
        $text = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        $processId = 0
        if (-not [int]::TryParse($text, [ref]$processId) -or $processId -le 0) { return $false }
        $process = Get-Process -Id $processId -ErrorAction Stop
        $expected = [IO.Path]::GetFullPath((Join-Path $RuntimeDir 'bin\tunnel-client.exe'))
        if (-not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $listeners = @(Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction Stop)
        $owners = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
        if ($owners.Count -ne 1 -or $owners[0] -ne $processId) { return $false }

        $content = Read-LocalTunnelMetrics
        $stamp = Get-PollTimestamp $content
        $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
        $now = ([DateTime]::UtcNow - $epoch).TotalSeconds
        $started = ($process.StartTime.ToUniversalTime() - $epoch).TotalSeconds
        return ($stamp -gt 0 -and $stamp -ge $started - 2 -and $stamp -ge $now - 120 -and $stamp -le $now + 5)
    } catch { return $false }
}

function Wait-ControlPlaneConnected([string]$RuntimeDir) {
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-ControlPlaneConnected -RuntimeDir $RuntimeDir) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}
