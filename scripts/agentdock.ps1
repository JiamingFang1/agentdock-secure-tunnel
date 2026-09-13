#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
$Config = Join-Path $RootDir 'config.yaml'
$Runtime = Join-Path $RootDir '.runtime'
$BinDir = Join-Path $Runtime 'bin'
$Compose = Join-Path $Runtime 'compose.yaml'
$Profile = Join-Path $Runtime 'tunnel-profile.yaml'
$TokenFile = Join-Path $Runtime 'agentdock.token'
$ModeFile = Join-Path $Runtime 'deployment.txt'
$TunnelPidFile = Join-Path $Runtime 'tunnel-client.pid'
$TunnelOut = Join-Path $Runtime 'tunnel-client.out.log'
$TunnelErr = Join-Path $Runtime 'tunnel-client.err.log'
$NativePidFile = Join-Path $Runtime 'agentdock-native.pid'
$NativeOut = Join-Path $Runtime 'agentdock-native.out.log'
$NativeErr = Join-Path $Runtime 'agentdock-native.err.log'
$TunnelExe = Join-Path $BinDir 'tunnel-client.exe'
$NativeExe = Join-Path $BinDir 'agentdock.exe'
$NativeHome = Join-Path $Runtime 'agentdock-home'

function Fail([string]$Message) { throw $Message }

function Read-Config {
    if (-not (Test-Path $Config)) {
        Copy-Item (Join-Path $RootDir 'config.example.yaml') $Config
        Fail 'Created config.yaml. Edit it, then run again.'
    }
    $m = @{}
    foreach ($line in Get-Content $Config) {
        $s = $line.Trim(); if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { Fail "Cannot parse config.yaml line: $line" }
        $k=$matches[1]; $v=$matches[2].Trim()
        if (($v.StartsWith("'") -and $v.EndsWith("'")) -or ($v.StartsWith('"') -and $v.EndsWith('"'))) { $v=$v.Substring(1,$v.Length-2) }
        $m[$k]=$v
    }
    foreach ($k in @('tunnel_id','runtime_api_key','agentdock_port','workspace_path')) {
        if (-not $m.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$m[$k])) { Fail "Missing config key: $k" }
    }
    $mode = if($m.ContainsKey('deployment_mode')){([string]$m.deployment_mode).ToLowerInvariant()}else{'auto'}
    if(@('auto','docker','native') -notcontains $mode){ Fail 'deployment_mode must be auto, docker, or native' }
    if ($m.tunnel_id -eq 'TUNNEL_ID_HERE') { Fail 'Set tunnel_id in config.yaml' }
    if ($m.runtime_api_key -eq 'RUNTIME_API_KEY_HERE') { Fail 'Set runtime_api_key in config.yaml' }
    if ($m.workspace_path -eq 'CHANGE_ME') { Fail 'Set workspace_path in config.yaml' }
    $port=0; if(-not [int]::TryParse([string]$m.agentdock_port,[ref]$port)-or $port-lt 1-or $port-gt 65535){Fail 'Invalid agentdock_port'}
    $workspace=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$m.workspace_path))
    if(-not(Test-Path $workspace -PathType Container)){New-Item -ItemType Directory -Force $workspace|Out-Null}
    [pscustomobject]@{TunnelId=[string]$m.tunnel_id;RuntimeApiKey=[string]$m.runtime_api_key;Port=$port;Workspace=$workspace;Mode=$mode}
}

function New-RandomToken {
    $b=New-Object byte[] 32; $r=[Security.Cryptography.RandomNumberGenerator]::Create(); try{$r.GetBytes($b)}finally{$r.Dispose()};
    -join($b|ForEach-Object{$_.ToString('x2')})
}
function Get-Arch {
    $a=$env:PROCESSOR_ARCHITECTURE; if($env:PROCESSOR_ARCHITEW6432){$a=$env:PROCESSOR_ARCHITEW6432}
    switch($a.ToUpperInvariant()){'AMD64'{'amd64'}'ARM64'{'arm64'}default{Fail "Unsupported architecture: $a"}}
}
function Get-LatestAsset([string]$Repo,[string]$Pattern){
    $release=Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='agentdock-secure-tunnel'}
    $asset=$release.assets|Where-Object{$_.name -match $Pattern}|Select-Object -First 1
    if(-not $asset){Fail "No matching release asset in $Repo: $Pattern"}; $asset
}
function Install-TunnelClient([switch]$Force){
    New-Item -ItemType Directory -Force $BinDir|Out-Null
    if((Test-Path $TunnelExe)-and -not $Force){return}
    Write-Host 'Installing tunnel-client locally...'
    $arch=Get-Arch; $asset=Get-LatestAsset 'openai/tunnel-client' "^tunnel-client-runtime-cloudflared-v.+-windows-$arch\.zip$"
    $zip=Join-Path $Runtime 'tunnel-client.zip'; $tmp=Join-Path $Runtime 'tunnel-client-extract'
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive $zip $tmp -Force
    $exe=Get-ChildItem $tmp -Recurse -File|Where-Object{$_.Name -match '^tunnel-client.*\.exe$'}|Select-Object -First 1
    if(-not $exe){Fail 'tunnel-client.exe not found in release archive'}
    Copy-Item $exe.FullName $TunnelExe -Force; Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
}
function Install-NativeAgentDock([switch]$Force){
    New-Item -ItemType Directory -Force $BinDir,$NativeHome|Out-Null
    if((Test-Path $NativeExe)-and -not $Force){return}
    Write-Host 'Installing AgentDock locally (native mode)...'
    $arch=Get-Arch; $asset=Get-LatestAsset 'uvwt/agentdock' "^agentdock_windows_${arch}\.zip$"
    $zip=Join-Path $Runtime 'agentdock.zip'; $tmp=Join-Path $Runtime 'agentdock-extract'
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive $zip $tmp -Force
    $exe=Get-ChildItem $tmp -Recurse -File|Where-Object{$_.Name -eq 'agentdock.exe'}|Select-Object -First 1
    if(-not $exe){Fail 'agentdock.exe not found in release archive'}
    Copy-Item $exe.FullName $NativeExe -Force; Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
}
function Test-WindowsDocker {
    if(-not(Get-Command docker -ErrorAction SilentlyContinue)){return $false}; & docker info *> $null; if($LASTEXITCODE-ne 0){return $false}; & docker compose version *> $null; $LASTEXITCODE-eq 0
}
function Test-WslDocker {
    if(-not(Get-Command wsl.exe -ErrorAction SilentlyContinue)){return $false}; & wsl.exe -u root -- docker info *> $null; if($LASTEXITCODE-ne 0){return $false}; & wsl.exe -u root -- docker compose version *> $null; $LASTEXITCODE-eq 0
}
function Select-Mode($C){
    if($C.Mode -eq 'native'){return 'native'}
    if(Test-WindowsDocker){return 'docker-windows'}
    if(Test-WslDocker){return 'docker-wsl'}
    if($C.Mode -eq 'docker'){Fail 'Docker mode requested, but no working Docker runtime was found. Install Docker Desktop or Docker Engine in WSL.'}
    Write-Host ''; Write-Warning 'Docker was not found. Docker mode is recommended because it isolates AgentDock from other host directories.'
    $answer=Read-Host 'Continue with native host installation instead? Native mode has NO container directory isolation. [y/N]'
    if($answer -match '^(?i:y|yes)$'){return 'native'}
    Fail 'Install/start Docker Engine, then run install again; or set deployment_mode: native explicitly.'
}
function Wsl-Path([string]$Path){$v=(& wsl.exe -- wslpath -a -u $Path|Select-Object -First 1);if($LASTEXITCODE-ne 0-or-not $v){Fail "Cannot convert path: $Path"};$v.Trim()}
function Get-Mode { if(-not(Test-Path $ModeFile)){Fail 'Run install first.'};(Get-Content $ModeFile -Raw).Trim() }
function Invoke-Compose([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args){
    $mode=Get-Mode; if($mode-eq'docker-windows'){& docker compose -f $Compose @Args}elseif($mode-eq'docker-wsl'){$cf=Wsl-Path $Compose;& wsl.exe -u root -- docker compose -f $cf @Args}else{Fail 'Not in Docker mode'};if($LASTEXITCODE-ne 0){Fail 'docker compose failed'}
}
function Ensure-Token {New-Item -ItemType Directory -Force $Runtime|Out-Null;$t=if(Test-Path $TokenFile){(Get-Content $TokenFile -Raw).Trim()}else{''};if(-not$t){$t=New-RandomToken;Set-Content $TokenFile $t -Encoding ASCII};$t}
function Prepare-Profile($C,[string]$Token){
    $text=@"
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
"@;[IO.File]::WriteAllText($Profile,$text,(New-Object Text.UTF8Encoding($false)))
}
function Prepare-Docker($C,[string]$Mode,[string]$Token){
    $mount=if($Mode-eq'docker-wsl'){Wsl-Path $C.Workspace}else{$C.Workspace.Replace('\','/')};$mount=$mount.Replace("'","''")
    $text=@"
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
      AGENTDOCK_AUTH_TOKEN: "$Token"
      AGENTDOCK_DEFAULT_DIR: "/home/agentdock/AgentDock"
    volumes:
      - agentdock_home:/home/agentdock/.agentdock
      - '${mount}:/home/agentdock/AgentDock'
    security_opt:
      - no-new-privileges:true
volumes:
  agentdock_home:
"@;[IO.File]::WriteAllText($Compose,$text,(New-Object Text.UTF8Encoding($false)))
}
function Test-Pid([string]$File){if(-not(Test-Path $File)){return $false};$v=(Get-Content $File -Raw).Trim();if($v-notmatch'^\d+$'){return $false};try{Get-Process -Id([int]$v)-ErrorAction Stop|Out-Null;$true}catch{$false}}
function Start-Native($C,[string]$Token){
    Install-NativeAgentDock
    $env:AGENTDOCK_HOST='127.0.0.1';$env:AGENTDOCK_PORT=[string]$C.Port;$env:AGENTDOCK_HOME=$NativeHome;$env:AGENTDOCK_DEFAULT_DIR=$C.Workspace;$env:AGENTDOCK_AUTH_TOKEN=$Token;$env:AGENTDOCK_OAUTH_ENABLED='false'
    if(-not(Test-Pid $NativePidFile)){$p=Start-Process -FilePath $NativeExe -WindowStyle Hidden -PassThru -RedirectStandardOutput $NativeOut -RedirectStandardError $NativeErr;Set-Content $NativePidFile $p.Id -Encoding ASCII}
}
function Start-Tunnel($C,[string]$Token){
    $env:CONTROL_PLANE_API_KEY=$C.RuntimeApiKey;$env:AGENTDOCK_BEARER_HEADER="Bearer $Token"
    if(-not(Test-Pid $TunnelPidFile)){$p=Start-Process -FilePath $TunnelExe -ArgumentList @('run','--profile-file',$Profile)-WindowStyle Hidden-PassThru-RedirectStandardOutput $TunnelOut-RedirectStandardError $TunnelErr;Set-Content $TunnelPidFile $p.Id-Encoding ASCII;Start-Sleep -Seconds 2;if(-not(Test-Pid $TunnelPidFile)){Fail 'tunnel-client failed. Run logs.'}}
}
function Install-Command {
    $c=Read-Config;New-Item -ItemType Directory -Force $Runtime,$BinDir|Out-Null;Install-TunnelClient;$mode=Select-Mode $c;$token=Ensure-Token;Prepare-Profile $c $token;Set-Content $ModeFile $mode-Encoding ASCII
    if($mode -like 'docker-*'){Prepare-Docker $c $mode $token;Invoke-Compose pull;Write-Host "Installed in Docker mode ($mode)." -ForegroundColor Green}else{Install-NativeAgentDock;Write-Warning 'Native mode installed: AgentDock is NOT container-isolated and can access paths allowed to your Windows user.'}
    Write-Host 'Next: .\agentdock.cmd start'
}
function Start-Command {
    $c=Read-Config;Install-TunnelClient;$mode=Get-Mode;$token=Ensure-Token;Prepare-Profile $c $token
    if($mode -like 'docker-*'){Prepare-Docker $c $mode $token;Invoke-Compose up -d}else{Start-Native $c $token}
    for($i=0;$i-lt 50;$i++){Start-Sleep -Milliseconds 500;try{$r=Invoke-WebRequest "http://127.0.0.1:$($c.Port)/healthz"-UseBasicParsing-TimeoutSec 2;if($r.StatusCode-eq200){break}}catch{};if($i-eq49){Fail 'AgentDock health check failed. Run logs.'}}
    Start-Tunnel $c $token;Write-Host "AgentDock : RUNNING  http://127.0.0.1:$($c.Port)/mcp"-ForegroundColor Green;Write-Host "Tunnel    : RUNNING  $($c.TunnelId)"-ForegroundColor Green;Write-Host "Mode      : $mode";Write-Host "Workspace : $($c.Workspace)"
}
function Stop-Command {
    if(Test-Pid $TunnelPidFile){Stop-Process -Id([int](Get-Content $TunnelPidFile-Raw).Trim())-Force-ErrorAction SilentlyContinue};Remove-Item $TunnelPidFile-Force-ErrorAction SilentlyContinue
    if(Test-Path $ModeFile){$mode=Get-Mode;if($mode-like'docker-*'){if(Test-Path $Compose){Invoke-Compose down}}elseif(Test-Pid $NativePidFile){Stop-Process -Id([int](Get-Content $NativePidFile-Raw).Trim())-Force-ErrorAction SilentlyContinue}}
    Remove-Item $NativePidFile-Force-ErrorAction SilentlyContinue;Write-Host 'Stopped.'
}
function Status-Command {$c=Read-Config;$a='STOPPED';$t='STOPPED';try{$r=Invoke-WebRequest "http://127.0.0.1:$($c.Port)/healthz"-UseBasicParsing-TimeoutSec 2;if($r.StatusCode-eq200){$a='RUNNING'}}catch{};if(Test-Pid $TunnelPidFile){$t='RUNNING'};$mode=if(Test-Path $ModeFile){Get-Mode}else{'NOT INSTALLED'};Write-Host "AgentDock : $a";Write-Host "Tunnel    : $t";Write-Host "Mode      : $mode";Write-Host "MCP       : http://127.0.0.1:$($c.Port)/mcp";Write-Host "Workspace : $($c.Workspace)"}
function Logs-Command {if(Test-Path $ModeFile){$m=Get-Mode;if($m-like'docker-*'){if(Test-Path $Compose){Invoke-Compose logs --tail 100 agentdock}}else{if(Test-Path $NativeOut){Get-Content $NativeOut-Tail 100};if(Test-Path $NativeErr){Get-Content $NativeErr-Tail 100}}};if(Test-Path $TunnelOut){Write-Host '--- tunnel-client ---';Get-Content $TunnelOut-Tail 100};if(Test-Path $TunnelErr){Get-Content $TunnelErr-Tail 100}}
function Update-Command {$c=Read-Config;Install-TunnelClient -Force;$m=Get-Mode;if($m-like'docker-*'){Prepare-Docker $c $m (Ensure-Token);Invoke-Compose pull}else{Install-NativeAgentDock -Force};Write-Host 'Updated local runtime components.'}

$Command=if($args.Count-gt0){[string]$args[0]}else{'help'}
switch($Command){'install'{Install-Command}'start'{Start-Command}'stop'{Stop-Command}'restart'{Stop-Command;Start-Sleep -Seconds 1;Start-Command}'status'{Status-Command}'logs'{Logs-Command}'update'{Update-Command}default{Write-Host 'Usage: .\agentdock.cmd {install|start|stop|restart|status|logs|update}'}}
