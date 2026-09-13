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
function Unquote([string]$Value) {
    $v = $Value.Trim()
    if (($v.StartsWith("'") -and $v.EndsWith("'")) -or ($v.StartsWith('"') -and $v.EndsWith('"'))) {
        return $v.Substring(1, $v.Length - 2)
    }
    return $v
}
function Test-WslPath([string]$Path) { return $Path.StartsWith('/') }

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        Copy-Item (Join-Path $Root 'config.example.yaml') $ConfigPath
        Fail 'Created config.yaml. Edit it, then run install again.'
    }

    $top = @{}
    $workspaces = New-Object System.Collections.Generic.List[object]
    $inWorkspaces = $false
    $current = $null

    foreach ($line in Get-Content $ConfigPath) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        if ($trimmed -eq 'workspaces:') {
            $inWorkspaces = $true
            continue
        }

        if (-not $inWorkspaces) {
            if ($trimmed -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { Fail "Invalid config line: $line" }
            $top[$matches[1]] = Unquote $matches[2]
            continue
        }

        if ($trimmed -match '^-\s+name\s*:\s*(.*)$') {
            if ($null -ne $current) { $workspaces.Add([pscustomobject]$current) }
            $current = @{ Name = (Unquote $matches[1]); Path = ''; Mode = 'rw' }
            continue
        }
        if ($null -eq $current) { Fail "Workspace property appeared before a workspace name: $line" }
        if ($trimmed -match '^path\s*:\s*(.*)$') { $current.Path = Unquote $matches[1]; continue }
        if ($trimmed -match '^mode\s*:\s*(.*)$') { $current.Mode = (Unquote $matches[1]).ToLowerInvariant(); continue }
        Fail "Invalid workspace config line: $line"
    }
    if ($null -ne $current) { $workspaces.Add([pscustomobject]$current) }

    foreach ($key in @('tunnel_id','runtime_api_key','agentdock_port','default_workspace')) {
        if (-not $top.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$top[$key])) { Fail "Missing config key: $key" }
    }
    if ($workspaces.Count -eq 0) { Fail 'At least one workspace is required.' }

    $deployment = if ($top.ContainsKey('deployment_mode')) { ([string]$top.deployment_mode).ToLowerInvariant() } else { 'auto' }
    if (@('auto','docker','native') -notcontains $deployment) { Fail 'deployment_mode must be auto, docker, or native' }
    if ($top.tunnel_id -eq 'TUNNEL_ID_HERE') { Fail 'Set tunnel_id in config.yaml' }
    if ($top.runtime_api_key -eq 'RUNTIME_API_KEY_HERE') { Fail 'Set runtime_api_key in config.yaml' }

    $port = 0
    if (-not [int]::TryParse([string]$top.agentdock_port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { Fail 'Invalid agentdock_port' }

    $names = @{}
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($ws in $workspaces) {
        if ([string]::IsNullOrWhiteSpace($ws.Name) -or $ws.Name -notmatch '^[A-Za-z0-9._-]+$') { Fail "Invalid workspace name: $($ws.Name)" }
        if ($names.ContainsKey($ws.Name)) { Fail "Duplicate workspace name: $($ws.Name)" }
        $names[$ws.Name] = $true
        if ([string]::IsNullOrWhiteSpace($ws.Path)) { Fail "Workspace $($ws.Name) has an empty path" }
        if (@('rw','ro') -notcontains $ws.Mode) { Fail "Workspace $($ws.Name) mode must be rw or ro" }

        if (Test-WslPath $ws.Path) {
            $normalized.Add([pscustomobject]@{ Name=$ws.Name; Path=$ws.Path; Mode=$ws.Mode; PathType='wsl' })
        } else {
            $p = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ws.Path))
            if (-not (Test-Path $p -PathType Container)) { New-Item -ItemType Directory -Force $p | Out-Null }
            $normalized.Add([pscustomobject]@{ Name=$ws.Name; Path=$p; Mode=$ws.Mode; PathType='windows' })
        }
    }

    $defaultName = [string]$top.default_workspace
    if (-not $names.ContainsKey($defaultName)) { Fail "default_workspace '$defaultName' is not defined under workspaces" }

    [pscustomobject]@{
        TunnelId = [string]$top.tunnel_id
        RuntimeApiKey = [string]$top.runtime_api_key
        Port = $port
        RequestedMode = $deployment
        DefaultWorkspace = $defaultName
        Workspaces = $normalized
        HasWslWorkspace = [bool]($normalized | Where-Object { $_.PathType -eq 'wsl' } | Select-Object -First 1)
    }
}

function Get-Workspace($Config, [string]$Name) {
    $ws = $Config.Workspaces | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $ws) { Fail "Unknown workspace: $Name" }
    return $ws
}
function Get-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { Fail "Unsupported architecture: $arch" } }
}
function Get-ReleaseAsset([string]$Repo, [string]$Pattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='agentdock-secure-tunnel'}
    $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { Fail "No matching release asset in ${Repo}: $Pattern" }
    return $asset
}
function Expand-ZipBinary([string]$Url, [string]$BinaryName, [string]$Destination) {
    New-Item -ItemType Directory -Force $Runtime, $Bin | Out-Null
    $archive = Join-Path $Runtime 'download.zip'; $extract = Join-Path $Runtime 'extract'
    Remove-Item $archive -Force -ErrorAction SilentlyContinue; Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $binary = Get-ChildItem $extract -Recurse -File | Where-Object { $_.Name -eq $BinaryName } | Select-Object -First 1
    if (-not $binary) { Fail "$BinaryName not found in downloaded archive" }
    Copy-Item $binary.FullName $Destination -Force
    Remove-Item $archive -Force -ErrorAction SilentlyContinue; Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}
function Install-TunnelClient([switch]$Force) {
    if ((Test-Path $TunnelExe) -and -not $Force) { return }
    $arch = Get-Arch; $asset = Get-ReleaseAsset 'openai/tunnel-client' "^tunnel-client-runtime-cloudflared-v.+-windows-${arch}\.zip$"
    Write-Host 'Installing OpenAI tunnel-client...'; Expand-ZipBinary $asset.browser_download_url 'tunnel-client.exe' $TunnelExe
}
function Install-NativeAgentDock([switch]$Force) {
    if ((Test-Path $AgentDockExe) -and -not $Force) { return }
    $arch = Get-Arch; $asset = Get-ReleaseAsset 'uvwt/agentdock' "^agentdock_windows_${arch}\.zip$"
    Write-Host 'Installing AgentDock for native mode...'; Expand-ZipBinary $asset.browser_download_url 'agentdock.exe' $AgentDockExe
    New-Item -ItemType Directory -Force $AgentDockHome | Out-Null
}
function Test-WindowsDocker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null; if ($LASTEXITCODE -ne 0) { return $false }
    & docker compose version *> $null; return ($LASTEXITCODE -eq 0)
}
function Test-WslDocker {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    & wsl.exe -u root -- docker info *> $null; if ($LASTEXITCODE -ne 0) { return $false }
    & wsl.exe -u root -- docker compose version *> $null; return ($LASTEXITCODE -eq 0)
}
function Select-Deployment($Config) {
    if ($Config.RequestedMode -eq 'native') { return 'native' }
    if ($Config.HasWslWorkspace) {
        if (Test-WslDocker) { return 'docker-wsl' }
        if ($Config.RequestedMode -eq 'docker') { Fail 'WSL workspace paths require Docker Engine inside WSL.' }
        Write-Warning 'A WSL workspace is configured, but WSL Docker Engine is not available.'
    } else {
        if (Test-WindowsDocker) { return 'docker-windows' }
        if (Test-WslDocker) { return 'docker-wsl' }
        if ($Config.RequestedMode -eq 'docker') { Fail 'Docker mode requested but no working Docker runtime was found.' }
    }
    Write-Warning 'Docker is unavailable. Docker mode is recommended for host-directory isolation.'
    $answer = Read-Host 'Continue with native AgentDock instead? Native mode has NO container directory isolation. [y/N]'
    if ($answer -match '^(?i:y|yes)$') { return 'native' }
    Fail 'Install/start Docker Engine and retry, or set deployment_mode: native explicitly.'
}
function New-Token {
    $bytes = New-Object byte[] 32; $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}
function Get-Token {
    New-Item -ItemType Directory -Force $Runtime | Out-Null
    if (Test-Path $TokenPath) { $t=(Get-Content $TokenPath -Raw).Trim(); if($t){return $t} }
    $t=New-Token; Set-Content $TokenPath $t -Encoding ASCII; return $t
}
function Get-InstalledMode { if(-not(Test-Path $ModePath)){Fail 'Run install first.'}; return (Get-Content $ModePath -Raw).Trim() }
function Convert-ToWslPath([string]$Path) {
    if (Test-WslPath $Path) { return $Path }
    $result = (& wsl.exe -- wslpath -a -u $Path | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $result) { Fail "Unable to convert Windows path to WSL path: $Path" }
    return $result.Trim()
}
function Write-TunnelProfile($Config, [string]$Token) {
    $text=@"
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
    [IO.File]::WriteAllText($TunnelProfile,$text,(New-Object Text.UTF8Encoding($false)))
}
function Write-Compose($Config, [string]$Mode, [string]$Token) {
    $defaultDir = "/workspaces/$($Config.DefaultWorkspace)"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('services:'); $lines.Add('  agentdock:'); $lines.Add('    image: ghcr.io/uvwt/agentdock:latest'); $lines.Add('    container_name: agentdock-secure-tunnel'); $lines.Add('    restart: unless-stopped')
    $lines.Add('    ports:'); $lines.Add("      - `"127.0.0.1:$($Config.Port):8765`"")
    $lines.Add('    environment:'); $lines.Add('      AGENTDOCK_HOST: "0.0.0.0"'); $lines.Add('      AGENTDOCK_PORT: "8765"'); $lines.Add('      AGENTDOCK_OAUTH_ENABLED: "false"'); $lines.Add("      AGENTDOCK_AUTH_TOKEN: `"$Token`""); $lines.Add("      AGENTDOCK_DEFAULT_DIR: `"$defaultDir`"")
    $lines.Add('    volumes:'); $lines.Add('      - agentdock_home:/home/agentdock/.agentdock')
    foreach($ws in $Config.Workspaces){
        if($Mode -eq 'docker-windows' -and $ws.PathType -eq 'wsl'){ Fail "Workspace '$($ws.Name)' uses a WSL path and cannot be mounted by the selected Windows Docker backend." }
        $source = if($Mode -eq 'docker-wsl'){ Convert-ToWslPath $ws.Path } else { $ws.Path.Replace('\','/') }
        $source = $source.Replace("'","''")
        $lines.Add("      - '$source`:/workspaces/$($ws.Name):$($ws.Mode)'")
    }
    $lines.Add('    security_opt:'); $lines.Add('      - no-new-privileges:true'); $lines.Add('volumes:'); $lines.Add('  agentdock_home:')
    [IO.File]::WriteAllLines($Compose,$lines,(New-Object Text.UTF8Encoding($false)))
}
function Invoke-Compose([Parameter(ValueFromRemainingArguments=$true)][string[]]$ComposeArgs) {
    $mode=Get-InstalledMode
    if($mode -eq 'docker-windows'){ & docker compose -f $Compose @ComposeArgs }
    elseif($mode -eq 'docker-wsl'){ $cp=Convert-ToWslPath $Compose; & wsl.exe -u root -- docker compose -f $cp @ComposeArgs }
    else{ Fail 'Current deployment is not Docker mode.' }
    if($LASTEXITCODE -ne 0){ Fail 'docker compose failed' }
}
function Test-PidFile([string]$Path) {
    if(-not(Test-Path $Path)){return $false}; $v=(Get-Content $Path -Raw).Trim(); if($v -notmatch '^\d+$'){return $false}
    try{Get-Process -Id([int]$v)-ErrorAction Stop|Out-Null;return $true}catch{return $false}
}
function Start-Native($Config,[string]$Token) {
    Install-NativeAgentDock
    $defaultWs=Get-Workspace $Config $Config.DefaultWorkspace
    if($defaultWs.PathType -eq 'wsl'){Fail 'Native Windows AgentDock cannot use a WSL path as default_workspace. Use Docker/WSL or choose a Windows default workspace.'}
    Write-Warning 'Native mode does not enforce workspace ro/rw mounts; AgentDock has the permissions of the Windows user.'
    $env:AGENTDOCK_HOST='127.0.0.1'; $env:AGENTDOCK_PORT=[string]$Config.Port; $env:AGENTDOCK_HOME=$AgentDockHome; $env:AGENTDOCK_DEFAULT_DIR=$defaultWs.Path; $env:AGENTDOCK_AUTH_TOKEN=$Token; $env:AGENTDOCK_OAUTH_ENABLED='false'
    if(-not(Test-PidFile $NativePid)){ $p=Start-Process -FilePath $AgentDockExe -WindowStyle Hidden -PassThru -RedirectStandardOutput $NativeOut -RedirectStandardError $NativeErr; Set-Content $NativePid $p.Id -Encoding ASCII }
}
function Start-Tunnel($Config,[string]$Token) {
    $env:CONTROL_PLANE_API_KEY=$Config.RuntimeApiKey; $env:AGENTDOCK_BEARER_HEADER="Bearer $Token"
    if(-not(Test-PidFile $TunnelPid)){ $p=Start-Process -FilePath $TunnelExe -ArgumentList @('run','--profile-file',$TunnelProfile) -WindowStyle Hidden -PassThru -RedirectStandardOutput $TunnelLog; Set-Content $TunnelPid $p.Id -Encoding ASCII; Start-Sleep -Seconds 2; if(-not(Test-PidFile $TunnelPid)){Fail 'tunnel-client failed to start. Run logs.'} }
}
function Wait-AgentDock([int]$Port) { for($i=0;$i -lt 50;$i++){try{$r=Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2;if($r.StatusCode -eq 200){return}}catch{};Start-Sleep -Milliseconds 500};Fail 'AgentDock health check failed. Run logs.' }
function Install-Command {
    $cfg=Read-Config; New-Item -ItemType Directory -Force $Runtime,$Bin|Out-Null; Install-TunnelClient; $mode=Select-Deployment $cfg; $token=Get-Token; Write-TunnelProfile $cfg $token; Set-Content $ModePath $mode -Encoding ASCII
    if($mode -like 'docker-*'){Write-Compose $cfg $mode $token;Invoke-Compose pull}else{Install-NativeAgentDock;Write-Warning 'Native mode installed. AgentDock is not container-isolated.'}
    Write-Host "Installed. Default workspace: $($cfg.DefaultWorkspace)" -ForegroundColor Green; Write-Host 'Next: .\agentdock.cmd start'
}
function Start-Command {
    $cfg=Read-Config; Install-TunnelClient; $mode=Get-InstalledMode; $token=Get-Token; Write-TunnelProfile $cfg $token
    if($mode -like 'docker-*'){Write-Compose $cfg $mode $token;Invoke-Compose up -d --force-recreate}else{Start-Native $cfg $token}
    Wait-AgentDock $cfg.Port; Start-Tunnel $cfg $token
    Write-Host 'AgentDock : RUNNING' -ForegroundColor Green; Write-Host 'Tunnel    : RUNNING' -ForegroundColor Green; Write-Host "Mode      : $mode"; Write-Host "Default   : $($cfg.DefaultWorkspace)"; Write-Host "MCP       : http://127.0.0.1:$($cfg.Port)/mcp"
}
function Stop-Command {
    if(Test-PidFile $TunnelPid){Stop-Process -Id([int](Get-Content $TunnelPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue};Remove-Item $TunnelPid -Force -ErrorAction SilentlyContinue
    if(Test-Path $ModePath){$mode=Get-InstalledMode;if($mode -like 'docker-*'){if(Test-Path $Compose){Invoke-Compose down}}elseif(Test-PidFile $NativePid){Stop-Process -Id([int](Get-Content $NativePid -Raw).Trim()) -Force -ErrorAction SilentlyContinue}}
    Remove-Item $NativePid -Force -ErrorAction SilentlyContinue;Write-Host 'Stopped.'
}
function Status-Command {
    $cfg=Read-Config;$a='STOPPED';$t='STOPPED';try{$r=Invoke-WebRequest "http://127.0.0.1:$($cfg.Port)/healthz" -UseBasicParsing -TimeoutSec 2;if($r.StatusCode -eq 200){$a='RUNNING'}}catch{};if(Test-PidFile $TunnelPid){$t='RUNNING'};$mode=if(Test-Path $ModePath){Get-InstalledMode}else{'NOT INSTALLED'}
    Write-Host "AgentDock : $a";Write-Host "Tunnel    : $t";Write-Host "Mode      : $mode";Write-Host "Default   : $($cfg.DefaultWorkspace)";Write-Host "MCP       : http://127.0.0.1:$($cfg.Port)/mcp"
}
function Logs-Command {if(Test-Path $ModePath){$m=Get-InstalledMode;if($m -like 'docker-*' -and (Test-Path $Compose)){Invoke-Compose logs --tail 100 agentdock}};if(Test-Path $NativeOut){Get-Content $NativeOut -Tail 100};if(Test-Path $NativeErr){Get-Content $NativeErr -Tail 100};if(Test-Path $TunnelLog){Get-Content $TunnelLog -Tail 100}}
function Apply-Command {Stop-Command;Start-Command}
function Update-Command { $cfg=Read-Config;if(-not(Test-Path $ModePath)){Fail 'Run install first.'};$mode=Get-InstalledMode;if($mode -like 'docker-*'){$token=Get-Token;Write-Compose $cfg $mode $token;Invoke-Compose pull}else{Install-NativeAgentDock -Force};Install-TunnelClient -Force }

$Command=if($args.Count -gt 0){[string]$args[0]}else{'help'}
switch($Command){
    'install'{Install-Command}
    'start'{Start-Command}
    'stop'{Stop-Command}
    'restart'{Apply-Command}
    'apply'{Apply-Command}
    'status'{Status-Command}
    'logs'{Logs-Command}
    'update'{Update-Command}
    default{Write-Host 'Usage: .\agentdock.cmd {install|start|stop|restart|apply|status|logs|update}'}
}
