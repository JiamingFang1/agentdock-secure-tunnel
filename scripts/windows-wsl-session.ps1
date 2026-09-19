#requires -Version 5.1
# Keep docker-wsl alive using one foreground Linux command attached to wsl.exe.
# Do not change WSL configuration or terminate a distribution.
function Get-WslSessionPaths([string]$RuntimeDir) {
    return [pscustomobject]@{
        State = Join-Path $RuntimeDir 'wsl-session.json'
        Lease = Join-Path $RuntimeDir 'wsl-session.lease'
        Out = Join-Path $RuntimeDir 'wsl-session.out.log'
        Err = Join-Path $RuntimeDir 'wsl-session.err.log'
        Lock = Join-Path $RuntimeDir 'wsl-session.lock'
    }
}

function Read-WslSessionRecord([string]$RuntimeDir) {
    try {
        $path = (Get-WslSessionPaths $RuntimeDir).State
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

function Get-WslSessionProcess($Record) {
    # A PID alone is not enough: Windows may have reused it after a reboot.
    try {
        if ($null -eq $Record -or $Record.Marker -notmatch '^[0-9a-f]{32}$' -or [int]$Record.ProcessId -le 0) { return $null }
        $p = Get-Process -Id ([int]$Record.ProcessId) -ErrorAction Stop
        if (-not [string]::Equals($p.Path, $Record.Executable, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if ($p.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$Record.StartTicks) { return $null }
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$Record.ProcessId) -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($cim.CommandLine) -or -not $cim.CommandLine.Contains([string]$Record.Marker)) { return $null }
        return $p
    } catch { return $null }
}

function Invoke-WslSessionText([string[]]$WslArguments) {
    $text = @(& wsl.exe @WslArguments)
    if ($LASTEXITCODE -ne 0) { throw "WSL session query failed (exit $LASTEXITCODE). Existing WSL/data will not be reinstalled." }
    return (($text -join "`n").Replace([string][char]0,[string]::Empty).Replace([string][char]0xFEFF,[string]::Empty).Trim())
}

function Quote-WslSessionArgument([string]$Value) {
    # Paths are file paths, not shell fragments; sh reads a separate script file.
    if ($Value -match '["\r\n\x00]' -or $Value.EndsWith('\')) { throw 'Unsupported WSL session argument.' }
    return '"' + $Value + '"'
}

function New-WslSessionProcess([string]$Executable,[string]$ArgumentLine,$Paths) {
    # Keep unnecessary OpenAI credentials out of the idle session's environment.
    $names = @('CONTROL_PLANE_API_KEY','OPENAI_API_KEY','RUNTIME_API_KEY','AGENTDOCK_AUTH_TOKEN','AGENTDOCK_BEARER_HEADER')
    $saved = @{}
    foreach ($name in $names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
        [Environment]::SetEnvironmentVariable($name,$null,'Process')
    }
    try {
        return (Start-Process -FilePath $Executable -ArgumentList $ArgumentLine -WindowStyle Hidden -PassThru -RedirectStandardOutput $Paths.Out -RedirectStandardError $Paths.Err)
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
}

function Assert-WslSessionDefault([string]$RuntimeDir) {
    # Current deployment commands use the default distribution. Never silently
    # reuse a holder from a different distribution if that default was changed.
    $distro = Invoke-WslSessionText -WslArguments @('--exec','printenv','WSL_DISTRO_NAME')
    if ([string]::IsNullOrWhiteSpace($distro) -or $distro -match '[\r\n]') { throw 'Unable to identify the default WSL distribution.' }
    $old = Read-WslSessionRecord $RuntimeDir
    if ($null -ne $old -and $old.Distro -ne $distro) {
        throw "Default WSL distribution changed from '$($old.Distro)' to '$distro'. Restore the intended default before operating this deployment. Nothing was stopped or reinstalled."
    }
    return $distro
}

function Start-AgentDockWslSession([string]$RuntimeDir,[string]$HelperScript) {
    $paths = Get-WslSessionPaths $RuntimeDir
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    $lock = [IO.File]::Open($paths.Lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $distro = Assert-WslSessionDefault $RuntimeDir
        $old = Read-WslSessionRecord $RuntimeDir
        $existing = Get-WslSessionProcess $old
        if ($null -ne $existing -and (Test-Path -LiteralPath $paths.Lease)) {
            if ([IO.File]::ReadAllText($paths.Lease).Trim() -eq $old.Marker) {
                Write-Host "WSL session : RUNNING ($distro; reused)"
                return
            }
        }
        if (-not (Test-Path -LiteralPath $HelperScript -PathType Leaf)) { throw 'Missing scripts/wsl-session.sh; pull the complete update.' }
        $exe = (Get-Command wsl.exe -CommandType Application -ErrorAction Stop).Source
        $linuxHelper = Invoke-WslSessionText -WslArguments @('--distribution',$distro,'--exec','wslpath','-a','-u',[IO.Path]::GetFullPath($HelperScript))
        $linuxLease = Invoke-WslSessionText -WslArguments @('--distribution',$distro,'--exec','wslpath','-a','-u',[IO.Path]::GetFullPath($paths.Lease))
        $marker = [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($paths.Lease,$marker,[Text.Encoding]::ASCII)
        $arguments = @('--distribution',$distro,'--exec','sh',$linuxHelper,$linuxLease,$marker)
        $line = ($arguments | ForEach-Object { Quote-WslSessionArgument $_ }) -join ' '
        $p = $null
        try {
            $p = New-WslSessionProcess -Executable $exe -ArgumentLine $line -Paths $paths
            $record = [pscustomobject]@{ ProcessId=$p.Id; StartTicks=$p.StartTime.ToUniversalTime().Ticks.ToString(); Executable=$exe; Distro=$distro; Marker=$marker }
            [IO.File]::WriteAllText($paths.State,($record | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
            for ($i=0; $i -lt 120; $i++) {
                $p.Refresh()
                if ($p.HasExited) { throw 'WSL foreground session exited before readiness.' }
                if ((Test-Path -LiteralPath $paths.Out) -and ([IO.File]::ReadAllText($paths.Out).Contains("READY $marker"))) {
                    Write-Host "WSL session : RUNNING ($distro; managed)"
                    return
                }
                Start-Sleep -Milliseconds 500
            }
            throw 'WSL foreground session did not become ready within 60 seconds.'
        } catch {
            # Revoke only this lease; never kill a distro or an unrelated process.
            if ((Test-Path -LiteralPath $paths.Lease) -and [IO.File]::ReadAllText($paths.Lease).Trim() -eq $marker) { Remove-Item -LiteralPath $paths.Lease -Force }
            $owned = Get-WslSessionProcess (Read-WslSessionRecord $RuntimeDir)
            if ($null -ne $owned) { Stop-Process -Id $owned.Id -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $paths.State -Force -ErrorAction SilentlyContinue
            throw ("WSL keepalive failed. Check .runtime/wsl-session.err.log. " + $_.Exception.Message)
        }
    } finally { $lock.Dispose() }
}

function Stop-AgentDockWslSession([string]$RuntimeDir) {
    $paths = Get-WslSessionPaths $RuntimeDir
    if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) { return }
    $lock = [IO.File]::Open($paths.Lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $record = Read-WslSessionRecord $RuntimeDir
        Remove-Item -LiteralPath $paths.Lease -Force -ErrorAction SilentlyContinue
        for ($i=0; $i -lt 20; $i++) {
            $p = Get-WslSessionProcess $record
            if ($null -eq $p) { break }
            Start-Sleep -Milliseconds 250
        }
        $p = Get-WslSessionProcess $record
        if ($null -ne $p) { Stop-Process -Id $p.Id -ErrorAction Stop }
        Remove-Item -LiteralPath $paths.State -Force -ErrorAction SilentlyContinue
        Write-Host 'WSL session : RELEASED (other WSL sessions were not stopped)'
    } finally { $lock.Dispose() }
}

function Show-AgentDockWslSession([string]$RuntimeDir) {
    $record = Read-WslSessionRecord $RuntimeDir
    if ($null -eq $record) { Write-Host 'WSL session : NOT MANAGED (run start to enable)'; return }
    $p = Get-WslSessionProcess $record
    $state = if ($null -ne $p) { 'RUNNING' } else { 'INACTIVE' }
    Write-Host "WSL session : $state ($($record.Distro))"
    try {
        # Listing does not execute Linux commands or wake a stopped distribution.
        $running = (Invoke-WslSessionText -WslArguments @('--list','--running','--quiet')) -split '\r\n|\n|\r'
        $distroState = if ($record.Distro -in $running) { 'RUNNING' } else { 'STOPPED' }
        Write-Host "WSL distro  : $distroState"
    } catch { Write-Host 'WSL distro  : UNVERIFIED' }
}
