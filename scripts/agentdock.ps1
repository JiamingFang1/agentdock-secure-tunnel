#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$Config = Join-Path $RootDir 'config.yaml'
$Runtime = Join-Path $RootDir '.runtime'
$Compose = Join-Path $Runtime 'compose.yaml'
$Profile = Join-Path $Runtime 'tunnel-profile.yaml'
$TokenFile = Join-Path $Runtime 'agentdock.token'
$PidFile = Join-Path $Runtime 'tunnel-client.pid'
$TunnelOut = Join-Path $Runtime 'tunnel-client.out.log'
$TunnelErr = Join-Path $Runtime 'tunnel-client.err.log'
$BackendFile = Join-Path $Runtime 'backend.txt'

function Fail([string]$Message) { throw $Message }

function Read-Config {
    if (-not (Test-Path $Config)) {
        Copy-Item (Join-Path $RootDir 'config.example.yaml') $Config
        Fail 'Created config.yaml. Edit it, then run again.'
    }
    $m = @{}
    foreach ($line in Get-Content $Config) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { Fail "Cannot parse config.yaml line: $line" }
        $k = $matches[1]
        $v = $matches[2].Trim()
        if (($v.StartsWith("'") -and $v.EndsWith("'")) -or ($v.StartsWith('"') -and $v.EndsWith('"'))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $m[$k] = $v
    }
    foreach ($k in @('tunnel_id','runtime_api_key','agentdock_port','workspace_path')) {
        if (-not $m.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$m[$k])) { Fail "Missing config key: $k" }
    }
    if ($m.tunnel_id -eq 'TUNNEL_ID_HERE') { Fail 'Set tunnel_id in config.yaml' }
    if ($m.runtime_api_key -eq 'RUNTIME_API_KEY_HERE') { Fail 'Set runtime_api_key in config.yaml' }
    if ($m.workspace_path -eq 'CHANGE_ME') { Fail 'Set workspace_path in config.yaml' }
    $port = 0
    if (-not [int]::TryParse([string]$m.agentdock_port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Fail 'Invalid agentdock_port' }
    $workspace = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$m.workspace_path))
    if (-not (Test-Path $workspace -PathType Container)) { New-Item -ItemType Directory -Force $workspace | Out-Null }
    return [pscustomobject]@{ TunnelId=[string]$m.tunnel_id; RuntimeApiKey=[string]$m.runtime_api_key; Port=$port; Workspace=$workspace }
}

function New-RandomToken {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
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

function Select-Backend {
    if (Test-WindowsDocker) { return 'windows' }
    if (Test-WslDocker) { return 'wsl' }
    Fail 'No working Docker runtime found. Start Docker Desktop or install/start Docker Engine in WSL. See README.'
}

function Wsl-Path([string]$Path) {
    $v = (& wsl.exe -- wslpath -a -u $Path | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $v) { Fail "Cannot convert Windows path to WSL path: $Path" }
    return $v.Trim()
}

function Get-Backend {
    if (-not (Test-Path $BackendFile)) { Fail '.runtime/backend.txt missing. Run install first.' }
    return (Get-Content $BackendFile -Raw).Trim()
}

function Invoke-Compose([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args) {
    $backend = Get-Backend
    if ($backend -eq 'windows') {
        & docker compose -f $Compose @Args
    } elseif ($backend -eq 'wsl') {
        $cf = Wsl-Path $Compose
        & wsl.exe -u root -- docker compose -f $cf @Args
    } else { Fail "Unknown Docker backend: $backend" }
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose failed' }
}

function Prepare-Runtime($C, [string]$Backend) {
    New-Item -ItemType Directory -Force $Runtime | Out-Null
    $token = if (Test-Path $TokenFile) { (Get-Content $TokenFile -Raw).Trim() } else { '' }
    if (-not $token) { $token = New-RandomToken; Set-Content $TokenFile $token -Encoding ASCII }
    $mount = if ($Backend -eq 'wsl') { Wsl-Path $C.Workspace } else { $C.Workspace.Replace('\','/') }
    $mount = $mount.Replace("'","''")
    $composeText = @"
services:
  agentdock:
    image: ghcr.io/uvwt/agentdock:latest
    container_name: agentdock-secure-tunnel
    restart: unless-stopped
    ports:
      - "127.0.0.1:$($C.Port):8765"
    environment:
      AGENTDOCK_HOST: "0.0.0.0"
      AGENTDOCK_PORT: "8765"
      AGENTDOCK_OAUTH_ENABLED: "false"
      AGENTDOCK_AUTH_TOKEN: "$token"
      AGENTDOCK_DEFAULT_DIR: "/home/agentdock/AgentDock"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - '${mount}:/home/agentdock/AgentDock'
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "agentdock-healthcheck"]
      interval: 15s
      timeout: 5s
      start_period: 10s
      retries: 4
volumes:
  agentdock_home:
"@
    [IO.File]::WriteAllText($Compose, $composeText, (New-Object Text.UTF8Encoding($false)))
    $profileText = @"
config_version: 1
control_plane:
  tunnel_id: $($C.TunnelId)
  api_key: env:CONTROL_PLANE_API_KEY
mcp:
  server_urls:
    - channel: main
      url: http://127.0.0.1:$($C.Port)/mcp
  extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
  discovery_extra_headers:
    Authorization: env:AGENTDOCK_BEARER_HEADER
admin_ui:
  open_browser: false
"@
    [IO.File]::WriteAllText($Profile, $profileText, (New-Object Text.UTF8Encoding($false)))
    Set-Content $BackendFile $Backend -Encoding ASCII
}

function Require-TunnelClient {
    $cmd = Get-Command tunnel-client -ErrorAction SilentlyContinue
    if (-not $cmd) { Fail 'tunnel-client not found in PATH. Install the official release and retry. See README.' }
}

function Test-PidAlive {
    if (-not (Test-Path $PidFile)) { return $false }
    $v = (Get-Content $PidFile -Raw).Trim()
    if ($v -notmatch '^\d+$') { return $false }
    try { Get-Process -Id ([int]$v) -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Install-Command {
    $c = Read-Config
    Require-TunnelClient
    $backend = Select-Backend
    Prepare-Runtime $c $backend
    Invoke-Compose pull
    Write-Host "Installed using Docker backend: $backend" -ForegroundColor Green
    Write-Host 'Next: .\agentdock.cmd start'
}

function Start-Command {
    $c = Read-Config
    Require-TunnelClient
    if (-not (Test-Path $BackendFile)) { Fail 'Run install first.' }
    Prepare-Runtime $c (Get-Backend)
    Invoke-Compose up -d
    $ok = $false
    for ($i=0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 500
        try { $r = Invoke-WebRequest "http://127.0.0.1:$($c.Port)/healthz" -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { $ok=$true; break } } catch {}
    }
    if (-not $ok) { Fail 'AgentDock health check failed. Run logs.' }
    $token = (Get-Content $TokenFile -Raw).Trim()
    $env:CONTROL_PLANE_API_KEY = $c.RuntimeApiKey
    $env:AGENTDOCK_BEARER_HEADER = "Bearer $token"
    if (-not (Test-PidAlive)) {
        $p = Start-Process -FilePath 'tunnel-client' -ArgumentList @('run','--profile-file',$Profile) -WindowStyle Hidden -PassThru -RedirectStandardOutput $TunnelOut -RedirectStandardError $TunnelErr
        Set-Content $PidFile $p.Id -Encoding ASCII
        Start-Sleep -Seconds 2
        if (-not (Test-PidAlive)) { Fail 'tunnel-client failed. Run logs.' }
    }
    Write-Host "AgentDock : RUNNING  http://127.0.0.1:$($c.Port)/mcp" -ForegroundColor Green
    Write-Host "Tunnel    : RUNNING  $($c.TunnelId)" -ForegroundColor Green
    Write-Host "Workspace : $($c.Workspace)"
}

function Stop-Command {
    if (Test-PidAlive) { Stop-Process -Id ([int](Get-Content $PidFile -Raw).Trim()) -Force -ErrorAction SilentlyContinue }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $Compose) { Invoke-Compose down }
    Write-Host 'Stopped.'
}

function Status-Command {
    $c = Read-Config
    $a='STOPPED'; $t='STOPPED'
    try { $r=Invoke-WebRequest "http://127.0.0.1:$($c.Port)/healthz" -UseBasicParsing -TimeoutSec 2; if($r.StatusCode -eq 200){$a='RUNNING'} } catch {}
    if(Test-PidAlive){$t='RUNNING'}
    Write-Host "AgentDock : $a"
    Write-Host "Tunnel    : $t"
    Write-Host "MCP       : http://127.0.0.1:$($c.Port)/mcp"
    Write-Host "Workspace : $($c.Workspace)"
}

function Logs-Command {
    if(Test-Path $Compose){ Invoke-Compose logs --tail 100 agentdock }
    if(Test-Path $TunnelOut){ Write-Host '--- tunnel-client stdout ---'; Get-Content $TunnelOut -Tail 100 }
    if(Test-Path $TunnelErr){ Write-Host '--- tunnel-client stderr ---'; Get-Content $TunnelErr -Tail 100 }
}

$Command = if($args.Count -gt 0){[string]$args[0]}else{'help'}
switch($Command){
    'install' { Install-Command }
    'start' { Start-Command }
    'stop' { Stop-Command }
    'restart' { Stop-Command; Start-Sleep -Seconds 1; Start-Command }
    'status' { Status-Command }
    'logs' { Logs-Command }
    'update' { $c=Read-Config; Require-TunnelClient; Prepare-Runtime $c (Get-Backend); Invoke-Compose pull; Write-Host 'Updated AgentDock image.' }
    default { Write-Host 'Usage: .\agentdock.cmd {install|start|stop|restart|status|logs|update}' }
}
