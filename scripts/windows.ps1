#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.yaml'
$Runtime = Join-Path $Root '.runtime'
$Bin = Join-Path $Runtime 'bin'
$Compose = Join-Path $Runtime 'compose.yaml'
$TunnelProfile = Join-Path $Runtime 'tunnel-profile.yaml'
$TokenPath = Join-Path $Runtime 'agentdock.token'
$ModePath = Join-Path $Runtime 'deployment.txt'
$TunnelPid = Join-Path $Runtime 'tunnel-client.pid'
$NativePid = Join-Path $Runtime 'agentdock-native.pid'
$TunnelLog = Join-Path $Runtime 'tunnel-client.log'
$NativeOut = Join-Path $Runtime 'agentdock-native.out.log'
$NativeErr = Join-Path $Runtime 'agentdock-native.err.log'
$TunnelExe = Join-Path $Bin 'tunnel-client.exe'
$AgentDockExe = Join-Path $Bin 'agentdock.exe'
$AgentDockHome = Join-Path $Runtime 'agentdock-home'

function Fail([string]$Message) { throw $Message }

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        Copy-Item (Join-Path $Root 'config.example.yaml') $ConfigPath
        Fail 'Created config.yaml. Edit it, then run install again.'
    }

    $values = @{}
    foreach ($line in Get-Content $ConfigPath) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { Fail "Invalid config line: $line" }
        $key = $matches[1]
        $value = $matches[2].Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }

    foreach ($key in @('tunnel_id','runtime_api_key','agentdock_port','workspace_path')) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$values[$key])) { Fail "Missing config key: $key" }
    }

    $mode = if ($values.ContainsKey('deployment_mode')) { ([string]$values.deployment_mode).ToLowerInvariant() } else { 'auto' }
    if (@('auto','docker','native') -notcontains $mode) { Fail 'deployment_mode must be auto, docker, or native' }
    if ($values.tunnel_id -eq 'TUNNEL_ID_HERE') { Fail 'Set tunnel_id in config.yaml' }
    if ($values.runtime_api_key -eq 'RUNTIME_API_KEY_HERE') { Fail 'Set runtime_api_key in config.yaml' }
    if ($values.workspace_path -eq 'CHANGE_ME') { Fail 'Set workspace_path in config.yaml' }

    $port = 0
    if (-not [int]::TryParse([string]$values.agentdock_port, [ref]$port)) { Fail 'agentdock_port must be a number' }
    if ($port -lt 1 -or $port -gt 65535) { Fail 'agentdock_port is out of range' }

    $workspace = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$values.workspace_path))
    if (-not (Test-Path $workspace -PathType Container)) { New-Item -ItemType Directory -Force $workspace | Out-Null }

    [pscustomobject]@{
        TunnelId = [string]$values.tunnel_id
        RuntimeApiKey = [string]$values.runtime_api_key
        Port = $port
        Workspace = $workspace
        RequestedMode = $mode
    }
}

function Get-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { Fail "Unsupported Windows architecture: $arch" }
    }
}

function Get-ReleaseAsset([string]$Repo, [string]$Pattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='agentdock-secure-tunnel'}
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { Fail "No matching release asset in ${Repo}: $Pattern" }
    return $asset
}

function Expand-ZipBinary([string]$Url, [string]$BinaryName, [string]$Destination) {
    New-Item -ItemType Directory -Force $Runtime, $Bin | Out-Null
    $archive = Join-Path $Runtime 'download.zip'
    $extract = Join-Path $Runtime 'extract'
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $binary = Get-ChildItem $extract -Recurse -File | Where-Object { $_.Name -eq $BinaryName } | Select-Object -First 1
    if (-not $binary) { Fail "$BinaryName not found in downloaded archive" }
    Copy-Item $binary.FullName $Destination -Force
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-TunnelClient([switch]$Force) {
    if ((Test-Path $TunnelExe) -and -not $Force) { return }
    Write-Host 'Installing OpenAI tunnel-client...'
    $arch = Get-Arch
    $asset = Get-ReleaseAsset 'openai/tunnel-client' "^tunnel-client-runtime-cloudflared-v.+-windows-${arch}\.zip$"
    Expand-ZipBinary $asset.browser_download_url 'tunnel-client.exe' $TunnelExe
}

function Install-NativeAgentDock([switch]$Force) {
    if ((Test-Path $AgentDockExe) -and -not $Force) { return }
    Write-Host 'Installing AgentDock for native mode...'
    $arch = Get-Arch
    $asset = Get-ReleaseAsset 'uvwt/agentdock' "^agentdock_windows_${arch}\.zip$"
    Expand-ZipBinary $asset.browser_download_url 'agentdock.exe' $AgentDockExe
    New-Item -ItemType Directory -Force $AgentDockHome | Out-Null
}

function Test-WindowsDocker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & docker compose version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-WslDocker {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    & wsl.exe -u root -- docker info *> $null
    if ($LASTEXITCODE -ne 0) { return $false }
    & wsl.exe -u root -- docker compose version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Select-Deployment($Config) {
    if ($Config.RequestedMode -eq 'native') { return 'native' }
    if (Test-WindowsDocker) { return 'docker-windows' }
    if (Test-WslDocker) { return 'docker-wsl' }
    if ($Config.RequestedMode -eq 'docker') { Fail 'Docker mode requested but no working Docker runtime was found.' }

    Write-Warning 'Docker is not available. Docker is recommended because it isolates AgentDock from unrelated host directories.'
    $answer = Read-Host 'Continue with native AgentDock instead? Native mode has NO container directory isolation. [y/N]'
    if ($answer -match '^(?i:y|yes)$') { return 'native' }
    Fail 'Install/start Docker Engine and retry, or set deployment_mode: native explicitly.'
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-Token {
    New-Item -ItemType Directory -Force $Runtime | Out-Null
    if (Test-Path $TokenPath) {
        $token = (Get-Content $TokenPath -Raw).Trim()
        if ($token) { return $token }
    }
    $token = New-Token
    Set-Content $TokenPath $token -Encoding ASCII
    return $token
}

function Get-InstalledMode {
    if (-not (Test-Path $ModePath)) { Fail 'Run install first.' }
    return (Get-Content $ModePath -Raw).Trim()
}

function Convert-ToWslPath([string]$Path) {
    $result = (& wsl.exe -- wslpath -a -u $Path | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $result) { Fail "Unable to convert Windows path to WSL path: $Path" }
    return $result.Trim()
}

function Write-TunnelProfile($Config, [string]$Token) {
    $text = @"
config_version: 1
control_plane:
  tunnel_id: $($Config.TunnelId)
  api_key: env:CONTROL_PLANE_API_KEY
mcp:
  server_urls:
    - channel: main
      url: http://127.0.0.1:$($Config.Port)/mcp
  extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
  discovery_extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
admin_ui:
  open_browser: false
"@
    [IO.File]::WriteAllText($TunnelProfile, $text, (New-Object Text.UTF8Encoding($false)))
}

function Write-Compose($Config, [string]$Mode, [string]$Token) {
    $mount = if ($Mode -eq 'docker-wsl') { Convert-ToWslPath $Config.Workspace } else { $Config.Workspace.Replace('\','/') }
    $mount = $mount.Replace("'", "''")
    $text = @"
services:
  agentdock:
    image: ghcr.io/uvwt/agentdock:latest
    container_name: agentdock-secure-tunnel
    restart: unless-stopped
    ports:
      - "127.0.0.1:$($Config.Port):8765"
    environment:
      AGENTDOCK_HOST: "0.0.0.0"
      AGENTDOCK_PORT: "8765"
      AGENTDOCK_OAUTH_ENABLED: "false"
      AGENTDOCK_AUTH_TOKEN: "$Token"
      AGENTDOCK_DEFAULT_DIR: "/home/agentdock/AgentDock"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - '${mount}:/home/agentdock/AgentDock'
    security_opt:
      - no-new-privileges:true
volumes:
  agentdock_home:
"@
    [IO.File]::WriteAllText($Compose, $text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Compose([Parameter(ValueFromRemainingArguments=$true)][string[]]$ComposeArgs) {
    $mode = Get-InstalledMode
    if ($mode -eq 'docker-windows') {
        & docker compose -f $Compose @ComposeArgs
    } elseif ($mode -eq 'docker-wsl') {
        $composePath = Convert-ToWslPath $Compose
        & wsl.exe -u root -- docker compose -f $composePath @ComposeArgs
    } else {
        Fail 'Current deployment is not Docker mode.'
    }
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose failed' }
}

function Test-PidFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    $value = (Get-Content $Path -Raw).Trim()
    if ($value -notmatch '^\d+$') { return $false }
    try { Get-Process -Id ([int]$value) -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Start-Native($Config, [string]$Token) {
    Install-NativeAgentDock
    $env:AGENTDOCK_HOST = '127.0.0.1'
    $env:AGENTDOCK_PORT = [string]$Config.Port
    $env:AGENTDOCK_HOME = $AgentDockHome
    $env:AGENTDOCK_DEFAULT_DIR = $Config.Workspace
    $env:AGENTDOCK_AUTH_TOKEN = $Token
    $env:AGENTDOCK_OAUTH_ENABLED = 'false'

    if (-not (Test-PidFile $NativePid)) {
        $process = Start-Process -FilePath $AgentDockExe -WindowStyle Hidden -PassThru -RedirectStandardOutput $NativeOut -RedirectStandardError $NativeErr
        Set-Content $NativePid $process.Id -Encoding ASCII
    }
}

function Start-Tunnel($Config, [string]$Token) {
    $env:CONTROL_PLANE_API_KEY = $Config.RuntimeApiKey
    $env:AGENTDOCK_BEARER_HEADER = "Bearer $Token"
    if (-not (Test-PidFile $TunnelPid)) {
        $process = Start-Process -FilePath $TunnelExe -ArgumentList @('run','--profile-file',$TunnelProfile) -WindowStyle Hidden -PassThru -RedirectStandardOutput $TunnelLog -RedirectStandardError $TunnelLog
        Set-Content $TunnelPid $process.Id -Encoding ASCII
        Start-Sleep -Seconds 2
        if (-not (Test-PidFile $TunnelPid)) { Fail 'tunnel-client failed to start. Run logs.' }
    }
}

function Wait-AgentDock([int]$Port) {
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $response = Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    Fail 'AgentDock health check failed. Run logs.'
}

function Install-Command {
    $cfg = Read-Config
    New-Item -ItemType Directory -Force $Runtime, $Bin | Out-Null
    Install-TunnelClient
    $mode = Select-Deployment $cfg
    $token = Get-Token
    Write-TunnelProfile $cfg $token
    Set-Content $ModePath $mode -Encoding ASCII

    if ($mode -like 'docker-*') {
        Write-Compose $cfg $mode $token
        Invoke-Compose pull
        Write-Host "Installed in Docker mode ($mode)." -ForegroundColor Green
    } else {
        Install-NativeAgentDock
        Write-Warning 'Native mode installed. AgentDock is not container-isolated.'
    }
    Write-Host 'Next: .\agentdock.cmd start'
}

function Start-Command {
    $cfg = Read-Config
    Install-TunnelClient
    $mode = Get-InstalledMode
    $token = Get-Token
    Write-TunnelProfile $cfg $token

    if ($mode -like 'docker-*') {
        Write-Compose $cfg $mode $token
        Invoke-Compose up -d
    } else {
        Start-Native $cfg $token
    }

    Wait-AgentDock $cfg.Port
    Start-Tunnel $cfg $token
    Write-Host "AgentDock : RUNNING  http://127.0.0.1:$($cfg.Port)/mcp" -ForegroundColor Green
    Write-Host "Tunnel    : RUNNING  $($cfg.TunnelId)" -ForegroundColor Green
    Write-Host "Mode      : $mode"
    Write-Host "Workspace : $($cfg.Workspace)"
}

function Stop-Command {
    if (Test-PidFile $TunnelPid) {
        Stop-Process -Id ([int](Get-Content $TunnelPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $TunnelPid -Force -ErrorAction SilentlyContinue

    if (Test-Path $ModePath) {
        $mode = Get-InstalledMode
        if ($mode -like 'docker-*') {
            if (Test-Path $Compose) { Invoke-Compose down }
        } elseif (Test-PidFile $NativePid) {
            Stop-Process -Id ([int](Get-Content $NativePid -Raw).Trim()) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $NativePid -Force -ErrorAction SilentlyContinue
    Write-Host 'Stopped.'
}

function Status-Command {
    $cfg = Read-Config
    $agentdock = 'STOPPED'
    $tunnel = if (Test-PidFile $TunnelPid) { 'RUNNING' } else { 'STOPPED' }
    try {
        $response = Invoke-WebRequest "http://127.0.0.1:$($cfg.Port)/healthz" -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -eq 200) { $agentdock = 'RUNNING' }
    } catch {}
    $mode = if (Test-Path $ModePath) { Get-InstalledMode } else { 'NOT INSTALLED' }
    Write-Host "AgentDock : $agentdock"
    Write-Host "Tunnel    : $tunnel"
    Write-Host "Mode      : $mode"
    Write-Host "MCP       : http://127.0.0.1:$($cfg.Port)/mcp"
    Write-Host "Workspace : $($cfg.Workspace)"
}

function Logs-Command {
    if (Test-Path $ModePath) {
        $mode = Get-InstalledMode
        if ($mode -like 'docker-*') {
            if (Test-Path $Compose) { Invoke-Compose logs --tail 100 agentdock }
        } else {
            if (Test-Path $NativeOut) { Get-Content $NativeOut -Tail 100 }
            if (Test-Path $NativeErr) { Get-Content $NativeErr -Tail 100 }
        }
    }
    if (Test-Path $TunnelLog) { Write-Host '--- tunnel-client ---'; Get-Content $TunnelLog -Tail 100 }
}

function Update-Command {
    $cfg = Read-Config
    Install-TunnelClient -Force
    $mode = Get-InstalledMode
    if ($mode -like 'docker-*') {
        Write-Compose $cfg $mode (Get-Token)
        Invoke-Compose pull
    } else {
        Install-NativeAgentDock -Force
    }
    Write-Host 'Updated runtime components.'
}

$Command = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
switch ($Command) {
    'install' { Install-Command }
    'start' { Start-Command }
    'stop' { Stop-Command }
    'restart' { Stop-Command; Start-Sleep -Seconds 1; Start-Command }
    'status' { Status-Command }
    'logs' { Logs-Command }
    'update' { Update-Command }
    default { Write-Host 'Usage: .\agentdock.cmd {install|start|stop|restart|status|logs|update}' }
}
