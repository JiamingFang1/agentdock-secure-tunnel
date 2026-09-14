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

        if ($s -match '^(name|path|mode)\s*:\s*(.*)$') {
            if ($null -eq $current) { Fail "Workspace field without list item: $line" }
            $key = $matches[1]
            $value = Unquote $matches[2]
            switch ($key) {
                'name' { $current.Name = $value }
                'path' { $current.Path = $value }
                'mode' { $current.Mode = $value.ToLowerInvariant() }
            }
            continue
        }

        Fail "Invalid config line: $line"
    }
    if ($null -ne $current) { $items.Add([pscustomobject]$current) }

    foreach ($required in @('tunnel_id','runtime_api_key','agentdock_port','default_workspace')) {
        if (-not $top.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$top[$required])) { Fail "Missing config value: $required" }
    }

    $requestedMode = if ($top.ContainsKey('deployment_mode')) { ([string]$top['deployment_mode']).ToLowerInvariant() } else { 'auto' }
    if ($requestedMode -notin @('auto','docker','native')) { Fail 'deployment_mode must be auto, docker or native.' }

    $workspaces = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace($item.Path)) { Fail 'Each workspace requires path.' }
        if ([string]::IsNullOrWhiteSpace($item.Name)) { $item.Name = Get-AutoWorkspaceName $item.Path }
        if ($item.Mode -notin @('rw','ro')) { Fail "Workspace '$($item.Name)' mode must be rw or ro." }
        $pathType = if (Test-WslPath $item.Path) { 'wsl' } else { 'windows' }
        $workspaces.Add([pscustomobject]@{Name=$item.Name;Path=$item.Path;Mode=$item.Mode;PathType=$pathType})
    }
    if ($workspaces.Count -eq 0) { Fail 'At least one workspace is required.' }

    $default = [string]$top['default_workspace']
    if (-not ($workspaces | Where-Object {$_.Name -eq $default})) { Fail "default_workspace '$default' does not match any workspace name." }

    $port = 0
    if (-not [int]::TryParse([string]$top['agentdock_port'],[ref]$port) -or $port -lt 1 -or $port -gt 65535) { Fail 'agentdock_port must be 1-65535.' }

    return [pscustomobject]@{
        TunnelId=[string]$top['tunnel_id']
        RuntimeApiKey=[string]$top['runtime_api_key']
        Port=$port
        DefaultWorkspace=$default
        RequestedMode=$requestedMode
        Workspaces=$workspaces
        HasWslWorkspace=[bool]($workspaces | Where-Object {$_.PathType -eq 'wsl'})
    }
}

function Get-Workspace($Config,[string]$Name) {
    $ws = $Config.Workspaces | Where-Object {$_.Name -eq $Name} | Select-Object -First 1
    if (-not $ws) { Fail "Workspace not found: $Name" }
    return $ws
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { Fail "Unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
}

function Get-ReleaseAsset([string]$Repo,[string]$Pattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{'User-Agent'='agentdock-secure-tunnel'}
    $asset = $release.assets | Where-Object {$_.name -match $Pattern} | Select-Object -First 1
    if (-not $asset) { Fail "No release asset matched $Pattern in $Repo" }
    return $asset
}

function Expand-ZipBinary([string]$Url,[string]$BinaryName,[string]$Destination) {
    $archive = Join-Path $Runtime ([IO.Path]::GetRandomFileName() + '.zip')
    $extract = Join-Path $Runtime ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force $extract | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing
    Expand-Archive $archive $extract -Force
    $binary = Get-ChildItem $extract -Recurse -File | Where-Object {$_.Name -eq $BinaryName} | Select-Object -First 1
    if (-not $binary) { Fail "$BinaryName not found in downloaded archive" }
    Copy-Item $binary.FullName $Destination -Force
    Remove-Item $archive -Force -ErrorAction SilentlyContinue
    Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
}

function Install-TunnelClient {
    if (Test-Path $TunnelExe) { return }
    $arch = Get-Arch
    $asset = Get-ReleaseAsset 'openai/tunnel-client' "^tunnel-client-runtime-cloudflared-v.*-windows-$arch\.zip$"
    Write-Host "Installing OpenAI tunnel-client from $($asset.name)..."
    Expand-ZipBinary $asset.browser_download_url 'tunnel-client.exe' $TunnelExe
    & $TunnelExe --version
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
    try {
        & docker info *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        & docker compose version *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-DockerDesktopPath {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\Docker Desktop.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe') }
    return ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
}

function Test-DockerDesktopInstalled {
    return [bool](Get-DockerDesktopPath)
}

function Start-DockerDesktopAndWait {
    $desktop = Get-DockerDesktopPath
    if (-not $desktop) { return $false }
    Write-Host 'Starting Docker Desktop...'
    Start-Process -FilePath $desktop | Out-Null
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if (Test-WindowsDocker) {
            Write-Host 'Docker Desktop is ready.' -ForegroundColor Green
            return $true
        }
    }
    Write-Warning 'Docker Desktop did not become ready.'
    return $false
}

function Invoke-WslExitCode([string[]]$WslArgs) {
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & wsl.exe @WslArgs *> $null; return $LASTEXITCODE }
        finally { $ErrorActionPreference = $old }
    } catch {
        return 1
    }
}

function Invoke-WslCapture([string[]]$WslArgs) {
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $output = @(& wsl.exe @WslArgs 2>$null)
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $old
        }
        if ($code -ne 0) { return $null }
        foreach ($line in $output) {
            $value = ([string]$line).Replace([char]0,'').Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
        return $null
    } catch {
        return $null
    }
}

function Get-WslDistributions {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $output = @(& wsl.exe --list --quiet 2>$null)
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $old
        }
        if ($code -ne 0) { return @() }
        $items = @()
        foreach ($line in $output) {
            $value = ([string]$line).Replace([char]0,'').Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { $items += $value }
        }
        return @($items)
    } catch {
        return @()
    }
}

function Test-WslDistributionAvailable {
    return (@(Get-WslDistributions).Count -gt 0)
}

function Get-WslDistroId {
    if (-not (Test-WslDistributionAvailable)) { return $null }
    return Invoke-WslCapture -WslArgs @('-u','root','--exec','sh','-lc','. /etc/os-release 2>/dev/null || exit 1; printf "%s" "$ID"')
}

function Test-WslDocker {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    if (-not (Test-WslDistributionAvailable)) { return $false }
    if ((Invoke-WslExitCode -WslArgs @('-u','root','--exec','docker','info')) -ne 0) { return $false }
    return ((Invoke-WslExitCode -WslArgs @('-u','root','--exec','docker','compose','version')) -eq 0)
}

function Start-WslDockerService {
    if (-not (Test-WslDistributionAvailable)) { return $false }
    [void](Invoke-WslExitCode -WslArgs @('-u','root','--exec','sh','-lc','if command -v systemctl >/dev/null 2>&1; then systemctl start docker >/dev/null 2>&1 || true; fi; if command -v service >/dev/null 2>&1; then service docker start >/dev/null 2>&1 || true; fi'))
    Start-Sleep -Seconds 1
    return (Test-WslDocker)
}

function Install-WslUbuntu {
    Write-Host ''
    Write-Host 'WSL + Ubuntu will be installed using the Microsoft-supported wsl --install command.'
    Write-Host 'Administrator permission is required. Windows may require a restart.'
    Write-Host 'After installation, launch Ubuntu once and create the Linux user/password before rerunning this installer.'
    Write-Host ''

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Fail 'wsl.exe is not available. On Windows 10 2004+ or Windows 11, open an elevated PowerShell and run: wsl --install -d Ubuntu'
    }

    $confirm = Read-Host 'Type INSTALL to install WSL + Ubuntu'
    if ($confirm -cne 'INSTALL') { return $false }

    $arguments = @('--install','-d','Ubuntu','--no-launch')
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & wsl.exe @arguments; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $old }
    } else {
        Write-Host 'Requesting administrator permission for WSL installation...'
        try {
            $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
            $code = $p.ExitCode
        } catch {
            Write-Warning 'Administrator elevation was cancelled or WSL installation could not be started.'
            return $false
        }
    }

    if ($code -ne 0) {
        Write-Warning "wsl --install exited with code $code."
        return $false
    }

    Write-Host ''
    Write-Host 'WSL/Ubuntu installation command completed.' -ForegroundColor Green
    Write-Host 'Restart Windows if requested, then launch Ubuntu once and create your Linux username/password.'
    Write-Host 'After that, run: .\agentdock.cmd install'
    Fail 'WSL first-run initialization is required before AgentDock can continue.'
}

function Install-DockerEngineInWsl {
    if (-not (Test-WslDistributionAvailable)) { return $false }
    $distroId = (Get-WslDistroId)
    if ([string]::IsNullOrWhiteSpace($distroId)) {
        Write-Warning 'Unable to identify the default WSL distribution.'
        return $false
    }
    $distroId = $distroId.ToLowerInvariant()
    if ($distroId -notin @('ubuntu','debian')) {
        Write-Warning "Automatic Docker Engine installation currently supports Ubuntu and Debian WSL distributions only. Detected: $distroId"
        return $false
    }

    $uid = Invoke-WslCapture -WslArgs @('--exec','id','-u')
    if ([string]::IsNullOrWhiteSpace($uid) -or $uid -eq '0') {
        Write-Warning 'The default WSL user is root or the distribution has not completed first-run setup.'
        Write-Host 'Launch the Linux distribution once, create a normal Linux user, then rerun this installer.'
        return $false
    }

    Write-Host ''
    Write-Warning 'This will install Docker Engine from Docker official APT repository inside WSL.'
    Write-Warning 'Docker official installation may remove conflicting distro-provided Docker/containerd packages.'
    $confirm = Read-Host 'Type INSTALL to continue with Docker Engine installation'
    if ($confirm -cne 'INSTALL') { return $false }

    $script = @'
set -eu
. /etc/os-release
case "$ID" in
  ubuntu|debian) ;;
  *) echo "Unsupported distribution: $ID" >&2; exit 42 ;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl

# Docker documents these packages as conflicts with the official Docker Engine packages.
DEBIAN_FRONTEND=noninteractive apt-get remove -y \
  docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [ -z "$codename" ]; then
  echo "Unable to determine distribution codename" >&2
  exit 43
fi
arch="$(dpkg --print-architecture)"
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
fi
if command -v service >/dev/null 2>&1; then
  service docker start >/dev/null 2>&1 || true
fi

docker info >/dev/null
docker compose version >/dev/null
'@

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe -u root --exec bash -lc $script
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }

    if ($code -ne 0) {
        Write-Warning "Docker Engine installation in WSL exited with code $code."
        return $false
    }
    if (-not (Test-WslDocker)) {
        Write-Warning 'Docker Engine was installed but is not ready.'
        return $false
    }
    Write-Host 'Docker Engine in WSL is ready.' -ForegroundColor Green
    return $true
}

function Ensure-WslDockerInteractive {
    if (Test-WslDocker) { return $true }
    if (Test-WslDistributionAvailable) {
        if (Start-WslDockerService) {
            Write-Host 'Docker Engine in WSL is ready.' -ForegroundColor Green
            return $true
        }

        Write-Warning 'A WSL Linux distribution is available, but Docker Engine/Compose is not ready.'
        while ($true) {
            Write-Host ''
            Write-Host '[1] Install or repair Docker Engine in WSL (Ubuntu/Debian)'
            Write-Host '[2] Go back without preparing WSL Docker'
            Write-Host '[3] Cancel installation'
            $choice = Read-Host 'Choose WSL option'
            switch ($choice) {
                '1' {
                    if (Install-DockerEngineInWsl) { return $true }
                    Write-Warning 'WSL Docker could not be prepared.'
                }
                '2' { return $false }
                '3' { Fail 'Installation cancelled.' }
                default { Write-Warning 'Enter 1, 2 or 3.' }
            }
        }
    }

    Write-Warning 'No usable WSL Linux distribution was found.'
    Write-Host 'WSL does not normally include Docker Engine by itself; Docker must be installed separately or provided by Docker Desktop integration.'
    while ($true) {
        Write-Host ''
        Write-Host '[1] Install WSL + Ubuntu'
        Write-Host '[2] Go back without installing WSL'
        Write-Host '[3] Cancel installation'
        $choice = Read-Host 'Choose WSL option'
        switch ($choice) {
            '1' {
                if (Install-WslUbuntu) { return $false }
            }
            '2' { return $false }
            '3' { Fail 'Installation cancelled.' }
            default { Write-Warning 'Enter 1, 2 or 3.' }
        }
    }
}

function Confirm-NativeDeployment($Config) {
    if ($Config.HasWslWorkspace) {
        Fail 'Native Windows AgentDock cannot use WSL workspace paths. Configure Windows paths or prepare Docker Engine inside WSL.'
    }
    if ($Config.RequestedMode -eq 'docker') {
        Fail 'deployment_mode is docker, so native fallback is disabled. Prepare Docker Desktop or WSL Docker and retry.'
    }

    Write-Host ''
    Write-Warning 'NATIVE MODE SECURITY WARNING'
    Write-Warning 'Native AgentDock has NO container-level workspace isolation.'
    Write-Warning 'Its file and shell tools run with the permissions of your Windows user and may access, modify, or delete files outside the configured workspaces.'
    Write-Warning 'The configured workspace is a default working directory, not a hard security boundary.'

    if ($Config.RequestedMode -eq 'native') {
        Write-Warning 'deployment_mode is explicitly set to native; continuing with native deployment.'
        return 'native'
    }

    $answer = Read-Host 'Type NATIVE to accept this risk and continue, or press Enter to cancel'
    if ($answer -ceq 'NATIVE') { return 'native' }
    Fail 'Installation cancelled. Install/start Docker Desktop or configure WSL + Docker Engine, then retry.'
}

function Select-Deployment($Config) {
    if ($Config.RequestedMode -eq 'native') { return Confirm-NativeDeployment $Config }

    if ($Config.HasWslWorkspace) {
        if (Test-WslDocker) { return 'docker-wsl' }
        if (Start-WslDockerService) { return 'docker-wsl' }
        Write-Warning 'At least one configured workspace uses a WSL/Linux path, so WSL Docker is required.'
        if (Ensure-WslDockerInteractive) { return 'docker-wsl' }
        if ($Config.RequestedMode -eq 'docker') { Fail 'WSL Docker is required but could not be prepared.' }
        Fail 'Native Windows mode cannot use WSL workspace paths. Prepare WSL Docker and retry.'
    }

    if (Test-WindowsDocker) { return 'docker-windows' }

    $desktopInstalled = Test-DockerDesktopInstalled
    if ($desktopInstalled) {
        Write-Warning 'Docker Desktop is installed, but its Docker engine is not running.'
        while ($true) {
            Write-Host ''
            Write-Host '[1] Start Docker Desktop and use it'
            Write-Host '[2] Use or prepare Docker Engine in WSL instead'
            if ($Config.RequestedMode -ne 'docker') { Write-Host '[3] Use native AgentDock (NO container isolation)' }
            Write-Host '[4] Cancel'
            $choice = Read-Host 'Choose deployment option'
            switch ($choice) {
                '1' {
                    if (Start-DockerDesktopAndWait) { return 'docker-windows' }
                    Write-Warning 'Docker Desktop could not be started or did not become ready.'
                }
                '2' {
                    if (Ensure-WslDockerInteractive) { return 'docker-wsl' }
                    Write-Warning 'WSL Docker is still unavailable.'
                }
                '3' {
                    if ($Config.RequestedMode -eq 'docker') { Write-Warning 'Native mode is disabled because deployment_mode is docker.'; continue }
                    return Confirm-NativeDeployment $Config
                }
                '4' { Fail 'Installation cancelled.' }
                default { Write-Warning 'Enter 1, 2, 3 or 4.' }
            }
        }
    }

    if (Test-WslDocker) { return 'docker-wsl' }
    if (Start-WslDockerService) { return 'docker-wsl' }

    Write-Warning 'No working Docker runtime was detected.'
    while ($true) {
        Write-Host ''
        if (Test-WslDistributionAvailable) {
            Write-Host '[1] Install or prepare Docker Engine in existing WSL'
        } else {
            Write-Host '[1] Install WSL + Ubuntu, then install Docker Engine'
        }
        if ($Config.RequestedMode -ne 'docker') { Write-Host '[2] Use native AgentDock (NO container isolation)' }
        Write-Host '[3] Cancel'
        $choice = Read-Host 'Choose deployment option'
        switch ($choice) {
            '1' {
                if (Ensure-WslDockerInteractive) { return 'docker-wsl' }
                Write-Warning 'No WSL Docker runtime is available yet.'
            }
            '2' {
                if ($Config.RequestedMode -eq 'docker') { Write-Warning 'Native mode is disabled because deployment_mode is docker.'; continue }
                return Confirm-NativeDeployment $Config
            }
            '3' { Fail 'Installation cancelled.' }
            default { Write-Warning 'Enter 1, 2 or 3.' }
        }
    }
}

function Assert-ModeAvailable([string]$Mode) {
    switch ($Mode) {
        'docker-windows' {
            if (Test-WindowsDocker) { return }
            if ((Test-DockerDesktopInstalled) -and (Start-DockerDesktopAndWait)) { return }
            Fail 'Windows Docker runtime is not available. Start Docker Desktop or rerun install to choose WSL Docker.'
        }
        'docker-wsl' {
            if (Test-WslDocker) { return }
            if (Start-WslDockerService) { return }
            Fail 'WSL Docker runtime is not available. Rerun install to repair or reinstall Docker Engine in WSL.'
        }
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
    if ($uid -eq '0') { Fail 'The default WSL user is root. Launch the WSL distribution once and configure a non-root default user before using Docker isolation.' }
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
    if ($mode -like 'docker-*') {
        Write-Host "Default   : $($cfg.DefaultWorkspace) -> /home/agentdock/AgentDock/workspaces/$($cfg.DefaultWorkspace)"
    } else {
        Write-Host "Default   : $($cfg.DefaultWorkspace)"
    }
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
