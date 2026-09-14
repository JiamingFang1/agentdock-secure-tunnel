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
$TunnelErr = Join-Path $Runtime 'tunnel-client.err.log'
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

function Get-AutoWorkspaceName([string]$Path) {
    $trimmed = $Path.Trim().TrimEnd('\','/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { Fail "Cannot derive workspace name from path: $Path" }
    $parts = $trimmed -split '[\\/]'
    $name = [string]$parts[-1]
    if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[A-Za-z0-9._-]+$') {
        Fail "Cannot use directory name '$name' as a workspace name. Add an explicit name using only letters, numbers, '.', '_' or '-'."
    }
    return $name
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) {
        Copy-Item (Join-Path $Root 'config.example.yaml') $ConfigPath
        Fail 'Created config.yaml. Edit it, then run again.'
    }

    $top = @{}
    $items = New-Object System.Collections.Generic.List[object]
    $inWorkspaces = $false
    $current = $null

    foreach ($line in Get-Content $ConfigPath) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -eq 'workspaces:') { $inWorkspaces = $true; continue }

        if (-not $inWorkspaces) {
            if ($s -notmatch '^([A-Za-z0-9_]+)\s*:\s*(.*)$') { Fail "Invalid config line: $line" }
            $top[$matches[1]] = Unquote $matches[2]
            continue
        }

        if ($s -match '^-\s*(name|path|mode)\s*:\s*(.*)$') {
            if ($null -ne $current) { $items.Add([pscustomobject]$current) }
            $current = @{ Name=''; Path=''; Mode='rw' }
            $key = $matches[1]
            $value = Unquote $matches[2]
            switch ($key) {
                'name' { $current.Name = $value }
                'path' { $current.Path = $value }
                'mode' { $current.Mode = $value.ToLowerInvariant() }
            }
            continue
        }

        if ($null -eq $current) { Fail "Workspace property before workspace item: $line" }
        if ($s -match '^(name|path|mode)\s*:\s*(.*)$') {
            $key = $matches[1]
            $value = Unquote $matches[2]
            switch ($key) {
                'name' { $current.Name = $value }
                'path' { $current.Path = $value }
                'mode' { $current.Mode = $value.ToLowerInvariant() }
            }
            continue
        }
        Fail "Invalid workspace line: $line"
    }

    if ($null -ne $current) { $items.Add([pscustomobject]$current) }

    foreach ($key in @('tunnel_id','runtime_api_key','agentdock_port','default_workspace')) {
        if (-not $top.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$top[$key])) { Fail "Missing config key: $key" }
    }
    if ($items.Count -eq 0) { Fail 'At least one workspace is required.' }

    $deployment = if ($top.ContainsKey('deployment_mode')) { ([string]$top.deployment_mode).ToLowerInvariant() } else { 'auto' }
    if (@('auto','docker','native') -notcontains $deployment) { Fail 'deployment_mode must be auto, docker, or native' }
    if ($top.tunnel_id -eq 'TUNNEL_ID_HERE') { Fail 'Set tunnel_id in config.yaml' }
    if ($top.runtime_api_key -eq 'RUNTIME_API_KEY_HERE') { Fail 'Set runtime_api_key in config.yaml' }

    $port = 0
    if (-not [int]::TryParse([string]$top.agentdock_port,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { Fail 'Invalid agentdock_port' }

    $seen = @{}
    $workspaces = New-Object System.Collections.Generic.List[object]
    foreach ($ws in $items) {
        if ([string]::IsNullOrWhiteSpace($ws.Path)) { Fail 'Workspace has an empty path' }
        if (@('rw','ro') -notcontains $ws.Mode) { Fail "Workspace mode must be rw or ro for path: $($ws.Path)" }

        $name = if ([string]::IsNullOrWhiteSpace($ws.Name)) { Get-AutoWorkspaceName $ws.Path } else { [string]$ws.Name }
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { Fail "Invalid workspace name: $name" }
        if ($seen.ContainsKey($name)) { Fail "Duplicate workspace name: $name" }
        $seen[$name] = $true

        if (Test-WslPath $ws.Path) {
            $workspaces.Add([pscustomobject]@{Name=$name;Path=$ws.Path;Mode=$ws.Mode;PathType='wsl'})
        } else {
            $p = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ws.Path))
            if (-not (Test-Path $p -PathType Container)) { New-Item -ItemType Directory -Force $p | Out-Null }
            $workspaces.Add([pscustomobject]@{Name=$name;Path=$p;Mode=$ws.Mode;PathType='windows'})
        }
    }

    $defaultName = [string]$top.default_workspace
    if (-not $seen.ContainsKey($defaultName)) {
        Fail "default_workspace '$defaultName' is not defined. With no explicit name, use the source directory's final name."
    }

    return [pscustomobject]@{
        TunnelId=[string]$top.tunnel_id
        RuntimeApiKey=[string]$top.runtime_api_key
        Port=$port
        RequestedMode=$deployment
        DefaultWorkspace=$defaultName
        Workspaces=$workspaces
        HasWslWorkspace=[bool]($workspaces | Where-Object {$_.PathType -eq 'wsl'} | Select-Object -First 1)
    }
}

function Get-Workspace($Config,[string]$Name) {
    $ws = $Config.Workspaces | Where-Object {$_.Name -eq $Name} | Select-Object -First 1
    if (-not $ws) { Fail "Unknown workspace: $Name" }
    return $ws
}

function Get-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { Fail "Unsupported architecture: $arch" }
    }
}

function Get-ReleaseAsset([string]$Repo,[string]$Pattern) {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='agentdock-secure-tunnel'}
    $a = $r.assets | Where-Object {$_.name -match $Pattern} | Select-Object -First 1
    if (-not $a) { Fail "No matching release asset in ${Repo}: $Pattern" }
    return $a
}

function Expand-ZipBinary([string]$Url,[string]$BinaryName,[string]$Destination) {
    New-Item -ItemType Directory -Force $Runtime,$Bin | Out-Null
    $archive = Join-Path $Runtime 'download.zip'
    $extract = Join-Path $Runtime 'extract'
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    Expand-Archive $archive $extract -Force
    $binary = Get-ChildItem $extract -Recurse -File | Where-Object {$_.Name -eq $BinaryName} | Select-Object -First 1
    if (-not $binary) { Fail "$BinaryName not found in downloaded archive" }
    Copy-Item $binary.FullName $Destination -Force
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-TunnelClient {
    if (-not (Test-Path $TunnelExe)) { Fail 'tunnel-client is missing. Run agentdock.cmd again so bootstrap can install it.' }
}

function Install-NativeAgentDock([switch]$Force) {
    if ((Test-Path $AgentDockExe) -and -not $Force) { return }
    $arch = Get-Arch
    $asset = Get-ReleaseAsset 'uvwt/agentdock' "^agentdock_windows_${arch}\.zip$"
    Write-Host 'Installing AgentDock for native mode...'
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

function Invoke-WslExitCode([string[]]$WslArgs) {
    & wsl.exe @WslArgs *> $null
    return $LASTEXITCODE
}

function Invoke-WslCapture([string[]]$WslArgs) {
    $output = @(& wsl.exe @WslArgs 2>$null)
    $code = $LASTEXITCODE
    if ($code -ne 0) { return $null }
    foreach ($line in $output) {
        $value = ([string]$line).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return $null
}

function Test-WslDocker {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    if ((Invoke-WslExitCode -WslArgs @('-u','root','--exec','docker','info')) -ne 0) { return $false }
    return ((Invoke-WslExitCode -WslArgs @('-u','root','--exec','docker','compose','version')) -eq 0)
}

function Select-Deployment($Config) {
    if ($Config.RequestedMode -eq 'native') { return 'native' }
    if ($Config.HasWslWorkspace) {
        if (Test-WslDocker) { return 'docker-wsl' }
        if ($Config.RequestedMode -eq 'docker') { Fail 'WSL workspace paths require Docker Engine inside WSL.' }
    } else {
        if (Test-WindowsDocker) { return 'docker-windows' }
        if (Test-WslDocker) { return 'docker-wsl' }
        if ($Config.RequestedMode -eq 'docker') { Fail 'Docker mode requested but no Docker runtime was found.' }
    }
    Write-Warning 'Docker unavailable. Native mode has no container directory isolation.'
    $answer = Read-Host 'Continue with native AgentDock? [y/N]'
    if ($answer -match '^(?i:y|yes)$') { return 'native' }
    Fail 'Install/start Docker Engine and retry.'
}

function Assert-ModeAvailable([string]$Mode) {
    switch ($Mode) {
        'docker-windows' { if (-not (Test-WindowsDocker)) { Fail 'Windows Docker runtime is not available.' } }
        'docker-wsl' { if (-not (Test-WslDocker)) { Fail 'WSL Docker runtime is not available.' } }
        'native' { return }
        default { Fail "Unknown installed deployment mode: $Mode" }
    }
}

function New-Token {
    $b = New-Object byte[] 32
    $r = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $r.GetBytes($b) } finally { $r.Dispose() }
    return -join ($b | ForEach-Object {$_.ToString('x2')})
}

function Get-Token {
    New-Item -ItemType Directory -Force $Runtime | Out-Null
    if (Test-Path $TokenPath) {
        $t = (Get-Content $TokenPath -Raw).Trim()
        if ($t) { return $t }
    }
    $t = New-Token
    Set-Content $TokenPath $t -Encoding ASCII
    return $t
}

function Get-InstalledMode {
    if (-not (Test-Path $ModePath)) { Fail 'Run install first.' }
    return (Get-Content $ModePath -Raw).Trim()
}

function Convert-ToWslPath([string]$Path) {
    if (Test-WslPath $Path) { return $Path }
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        $d = $matches[1].ToLowerInvariant()
        $r = $matches[2].Replace('\','/')
        return "/mnt/$d/$r"
    }
    Fail "Unsupported Windows path for WSL Docker: $Path"
}

function Get-WslRuntimeIdentity {
    $uid = Invoke-WslCapture -WslArgs @('--exec','id','-u')
    $gid = Invoke-WslCapture -WslArgs @('--exec','id','-g')
    if ([string]::IsNullOrWhiteSpace($uid) -or [string]::IsNullOrWhiteSpace($gid)) {
        Fail 'Unable to determine the default WSL user UID/GID.'
    }
    if ($uid -notmatch '^\d+$' -or $gid -notmatch '^\d+$') { Fail "Invalid WSL UID/GID: $uid`:$gid" }
    if ($uid -eq '0') { Fail 'The default WSL user is root. Configure a non-root WSL default user before using Docker isolation.' }
    return [pscustomobject]@{Uid=$uid;Gid=$gid}
}

function Get-DockerRuntimeIdentity([string]$Mode) {
    if ($Mode -eq 'docker-wsl') { return Get-WslRuntimeIdentity }
    return [pscustomobject]@{Uid='10001';Gid='10001'}
}

function Write-TunnelProfile($Config,[string]$Token) {
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
    [IO.File]::WriteAllText($TunnelProfile,$text,(New-Object Text.UTF8Encoding($false)))
}

function Get-DockerSource($Ws,[string]$Mode) {
    if ($Mode -eq 'docker-windows' -and $Ws.PathType -eq 'wsl') { Fail "Workspace '$($Ws.Name)' uses a WSL path and requires WSL Docker." }
    if ($Mode -eq 'docker-wsl') { return Convert-ToWslPath $Ws.Path }
    return $Ws.Path.Replace('\','/')
}

function Test-WslCondition([string]$Flag,[string]$Path) {
    return ((Invoke-WslExitCode -WslArgs @('--exec','test',$Flag,$Path)) -eq 0)
}

function Test-WslWorkspaceAccess($Config,[string]$Mode) {
    if ($Mode -ne 'docker-wsl') { return }
    foreach ($ws in $Config.Workspaces) {
        $source = Get-DockerSource $ws $Mode
        if (-not (Test-WslCondition '-r' $source)) { Fail "WSL user cannot read workspace '$($ws.Name)': $source" }
        if (-not (Test-WslCondition '-x' $source)) { Fail "WSL user cannot enter workspace '$($ws.Name)': $source" }
        if ($ws.Mode -eq 'rw' -and -not (Test-WslCondition '-w' $source)) {
            Fail "WSL user cannot write workspace '$($ws.Name)' configured as rw: $source"
        }
    }
}

function Assert-DockerConfig($Config,[string]$Mode) {
    [void](Get-DockerRuntimeIdentity $Mode)
    Test-WslWorkspaceAccess $Config $Mode
    $defaultWs = Get-Workspace $Config $Config.DefaultWorkspace
    if ($defaultWs.Mode -ne 'rw') {
        Fail "default_workspace '$($Config.DefaultWorkspace)' must use mode: rw because AgentDock secures its default directory at startup."
    }
}

function Write-Compose($Config,[string]$Mode,[string]$Token) {
    Assert-DockerConfig $Config $Mode
    $safeRoot = '/home/agentdock/AgentDock'
    $identity = Get-DockerRuntimeIdentity $Mode
    $defaultDir = "$safeRoot/workspaces/$($Config.DefaultWorkspace)"
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('services:')
    $lines.Add('  agentdock-init:')
    $lines.Add('    image: ghcr.io/uvwt/agentdock:latest')
    $lines.Add('    user: "0:0"')
    $lines.Add('    entrypoint: ["/bin/sh", "-c"]')
    $lines.Add("    command: ['chown -R $($identity.Uid):$($identity.Gid) /home/agentdock/.agentdock /home/agentdock/AgentDock && chmod 700 /home/agentdock/.agentdock /home/agentdock/AgentDock']")
    $lines.Add('    restart: "no"')
    $lines.Add('    volumes:')
    $lines.Add('      - agentdock_home:/home/agentdock/.agentdock')
    $lines.Add('      - agentdock_root:/home/agentdock/AgentDock')

    $lines.Add('  agentdock:')
    $lines.Add('    image: ghcr.io/uvwt/agentdock:latest')
    $lines.Add('    container_name: agentdock-secure-tunnel')
    $lines.Add('    restart: unless-stopped')
    $lines.Add('    depends_on:')
    $lines.Add('      agentdock-init:')
    $lines.Add('        condition: service_completed_successfully')
    $lines.Add("    user: `"$($identity.Uid):$($identity.Gid)`"")
    $lines.Add('    ports:')
    $lines.Add("      - `"127.0.0.1:$($Config.Port):8765`"")
    $lines.Add('    environment:')
    $lines.Add('      HOME: "/home/agentdock"')
    $lines.Add('      AGENTDOCK_HOME: "/home/agentdock/.agentdock"')
    $lines.Add('      AGENTDOCK_HOST: "0.0.0.0"')
    $lines.Add('      AGENTDOCK_PORT: "8765"')
    $lines.Add('      AGENTDOCK_OAUTH_ENABLED: "false"')
    $lines.Add("      AGENTDOCK_AUTH_TOKEN: `"$Token`"")
    $lines.Add("      AGENTDOCK_DEFAULT_DIR: `"$defaultDir`"")
    $lines.Add('    volumes:')
    $lines.Add('      - agentdock_home:/home/agentdock/.agentdock')
    $lines.Add('      - agentdock_root:/home/agentdock/AgentDock')

    foreach ($ws in $Config.Workspaces) {
        $source = (Get-DockerSource $ws $Mode).Replace("'","''")
        $lines.Add("      - '$source`:$safeRoot/workspaces/$($ws.Name):$($ws.Mode)'")
    }

    $lines.Add('    security_opt:')
    $lines.Add('      - no-new-privileges:true')
    $lines.Add('volumes:')
    $lines.Add('  agentdock_home:')
    $lines.Add('  agentdock_root:')
    [IO.File]::WriteAllLines($Compose,$lines,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-Compose([string[]]$ComposeArgs) {
    $mode = Get-InstalledMode
    if ($mode -eq 'docker-windows') {
        & docker compose -f $Compose @ComposeArgs
    } elseif ($mode -eq 'docker-wsl') {
        $cp = Convert-ToWslPath $Compose
        $wslArgs = @('-u','root','--exec','docker','compose','-f',$cp) + $ComposeArgs
        & wsl.exe @wslArgs
    } else {
        Fail 'Current deployment is not Docker mode.'
    }
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose failed' }
}

function Test-PidFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    $v = (Get-Content $Path -Raw).Trim()
    if ($v -notmatch '^\d+$') { return $false }
    try {
        Get-Process -Id ([int]$v) -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Start-Native($Config,[string]$Token) {
    Install-NativeAgentDock
    $ws = Get-Workspace $Config $Config.DefaultWorkspace
    if ($ws.PathType -eq 'wsl') { Fail 'Native Windows AgentDock cannot use a WSL default workspace.' }
    Write-Warning 'Native mode does not enforce workspace mount isolation.'
    $env:AGENTDOCK_HOST = '127.0.0.1'
    $env:AGENTDOCK_PORT = [string]$Config.Port
    $env:AGENTDOCK_HOME = $AgentDockHome
    $env:AGENTDOCK_DEFAULT_DIR = $ws.Path
    $env:AGENTDOCK_AUTH_TOKEN = $Token
    $env:AGENTDOCK_OAUTH_ENABLED = 'false'
    if (-not (Test-PidFile $NativePid)) {
        $p = Start-Process -FilePath $AgentDockExe -WindowStyle Hidden -PassThru -RedirectStandardOutput $NativeOut -RedirectStandardError $NativeErr
        Set-Content $NativePid $p.Id -Encoding ASCII
    }
}

function Start-Tunnel($Config,[string]$Token) {
    $env:CONTROL_PLANE_API_KEY = $Config.RuntimeApiKey
    $env:AGENTDOCK_BEARER_HEADER = "Bearer $Token"
    if (-not (Test-PidFile $TunnelPid)) {
        Remove-Item $TunnelLog,$TunnelErr -Force -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $TunnelExe -ArgumentList @('run','--profile-file',$TunnelProfile) -WindowStyle Hidden -PassThru -RedirectStandardOutput $TunnelLog -RedirectStandardError $TunnelErr
        Set-Content $TunnelPid $p.Id -Encoding ASCII
        Start-Sleep 2
        if (-not (Test-PidFile $TunnelPid)) { Fail 'tunnel-client failed to start. Run logs.' }
    }
}

function Wait-AgentDock([int]$Port) {
    for ($i=0; $i -lt 50; $i++) {
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/healthz" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    Fail 'AgentDock health check failed. Run logs.'
}

function Test-StartPreflight {
    $cfg = Read-Config
    Install-TunnelClient
    $mode = Get-InstalledMode
    Assert-ModeAvailable $mode
    if ($mode -like 'docker-*') {
        Assert-DockerConfig $cfg $mode
    } else {
        $ws = Get-Workspace $cfg $cfg.DefaultWorkspace
        if ($ws.PathType -eq 'wsl') { Fail 'Native Windows AgentDock cannot use a WSL default workspace.' }
    }
}

function Install-Command {
    $cfg = Read-Config
    New-Item -ItemType Directory -Force $Runtime,$Bin | Out-Null
    Install-TunnelClient
    $mode = Select-Deployment $cfg
    $token = Get-Token
    Write-TunnelProfile $cfg $token
    Set-Content $ModePath $mode -Encoding ASCII
    if ($mode -like 'docker-*') {
        Assert-ModeAvailable $mode
        Write-Compose $cfg $mode $token
        Invoke-Compose -ComposeArgs @('pull')
    } else {
        Install-NativeAgentDock
    }
    Write-Host "Installed. Default workspace: $($cfg.DefaultWorkspace)" -ForegroundColor Green
    Write-Host 'Next: .\agentdock.cmd start'
}

function Start-Command {
    $cfg = Read-Config
    Install-TunnelClient
    $mode = Get-InstalledMode
    Assert-ModeAvailable $mode
    $token = Get-Token
    Write-TunnelProfile $cfg $token
    if ($mode -like 'docker-*') {
        Write-Compose $cfg $mode $token
        Invoke-Compose -ComposeArgs @('up','-d','--force-recreate')
    } else {
        Start-Native $cfg $token
    }
    Wait-AgentDock $cfg.Port
    Start-Tunnel $cfg $token
    Write-Host 'AgentDock : RUNNING' -ForegroundColor Green
    Write-Host 'Tunnel    : RUNNING' -ForegroundColor Green
    Write-Host "Mode      : $mode"
    Write-Host "Default   : $($cfg.DefaultWorkspace) -> /home/agentdock/AgentDock/workspaces/$($cfg.DefaultWorkspace)"
    Write-Host "MCP       : http://127.0.0.1:$($cfg.Port)/mcp"
}

function Stop-Command {
    if (Test-PidFile $TunnelPid) {
        Stop-Process -Id ([int](Get-Content $TunnelPid -Raw).Trim()) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $TunnelPid -Force -ErrorAction SilentlyContinue
    if (Test-Path $ModePath) {
        $mode = Get-InstalledMode
        if ($mode -like 'docker-*') {
            if (Test-Path $Compose) { Invoke-Compose -ComposeArgs @('down') }
        } elseif (Test-PidFile $NativePid) {
            Stop-Process -Id ([int](Get-Content $NativePid -Raw).Trim()) -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $NativePid -Force -ErrorAction SilentlyContinue
    Write-Host 'Stopped.'
}

function Status-Command {
    $cfg = Read-Config
    $a = 'STOPPED'
    $t = 'STOPPED'
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$($cfg.Port)/healthz" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { $a = 'RUNNING' }
    } catch {}
    if (Test-PidFile $TunnelPid) { $t = 'RUNNING' }
    $mode = if (Test-Path $ModePath) { Get-InstalledMode } else { 'NOT INSTALLED' }
    Write-Host "AgentDock : $a"
    Write-Host "Tunnel    : $t"
    Write-Host "Mode      : $mode"
    Write-Host "Default   : $($cfg.DefaultWorkspace)"
    Write-Host "MCP       : http://127.0.0.1:$($cfg.Port)/mcp"
}

function Logs-Command {
    if (Test-Path $ModePath) {
        $m = Get-InstalledMode
        if ($m -like 'docker-*' -and (Test-Path $Compose)) { Invoke-Compose -ComposeArgs @('logs','--tail','100','agentdock') }
    }
    if (Test-Path $NativeOut) { Get-Content $NativeOut -Tail 100 }
    if (Test-Path $NativeErr) { Get-Content $NativeErr -Tail 100 }
    if (Test-Path $TunnelLog) { Get-Content $TunnelLog -Tail 100 }
    if (Test-Path $TunnelErr) { Get-Content $TunnelErr -Tail 100 }
}

function Apply-Command {
    Test-StartPreflight
    Stop-Command
    Start-Command
}

function Update-Command {
    $cfg = Read-Config
    if (-not (Test-Path $ModePath)) { Fail 'Run install first.' }
    $mode = Get-InstalledMode
    Assert-ModeAvailable $mode
    if ($mode -like 'docker-*') {
        $token = Get-Token
        Write-Compose $cfg $mode $token
        Invoke-Compose -ComposeArgs @('pull')
    } else {
        Install-NativeAgentDock -Force
    }
}

$Command = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
switch ($Command) {
    'install' { Install-Command }
    'start' { Start-Command }
    'stop' { Stop-Command }
    'restart' { Apply-Command }
    'apply' { Apply-Command }
    'status' { Status-Command }
    'logs' { Logs-Command }
    'update' { Update-Command }
    default { Write-Host 'Usage: .\agentdock.cmd {install|start|stop|restart|apply|status|logs|update}' }
}
