#requires -Version 5.1
# Offline lifecycle tests. No installed WSL, Docker, or real secrets are used.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/windows-wsl-session.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('wsl-session-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$helper = Join-Path $temp 'helper.sh'
[IO.File]::WriteAllText($helper,'test helper')
$runtime = Join-Path $temp 'runtime'
$script:Passed = 0
$script:Failed = 0

function Assert-Equal($Expected,$Actual) {
    if ([string]$Expected -cne [string]$Actual) { throw "Expected [$Expected], got [$Actual]" }
}
function Assert-Throws([scriptblock]$Body,[string]$Pattern) {
    $message = ''
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) { throw "Expected exception [$Pattern], got [$message]" }
}
function Get-Command { param($Name,$CommandType,$ErrorAction); return [pscustomobject]@{Source='C:\Windows\System32\wsl.exe'} }
function Invoke-WslSessionText([string[]]$WslArguments) {
    $script:Calls.Add(($WslArguments -join '|'))
    if ($WslArguments[0] -eq '--list') { return $script:RunningNames }
    if ($WslArguments -contains 'printenv') { return $script:DefaultDistro }
    if ($WslArguments -contains 'wslpath') { return '/mnt/c/test files/' + [IO.Path]::GetFileName($WslArguments[-1]) }
    throw 'Unexpected WSL command in test'
}
function Get-Process { param($Id,$ErrorAction); if (-not $script:Live) { throw 'not running' }; return $script:Process }
function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); return [pscustomobject]@{CommandLine=$script:CommandLine} }
function Start-Sleep { param($Milliseconds) }
function Stop-Process { param($Id,[switch]$Force,$ErrorAction); $script:Stops++; $script:Live=$false }
function New-WslSessionProcess([string]$Executable,[string]$ArgumentLine,$Paths) {
    $script:Spawns++
    $script:CommandLine=$ArgumentLine
    $script:Live=$true
    $script:Process = [pscustomobject]@{Id=4242;StartTime=[DateTime]::Now;Path=$Executable;HasExited=$false}
    $script:Process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
    return $script:Process
}
function Reset-Test {
    Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
    $script:DefaultDistro='Ubuntu-22.04'
    $script:RunningNames='Ubuntu-22.04'
    $script:Live=$false
    $script:Spawns=0
    $script:Stops=0
    $script:CommandLine=''
    $script:Calls=New-Object System.Collections.Generic.List[string]
}
function Test-Case([string]$Name,[scriptblock]$Body) {
    Reset-Test
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}

try {
    Test-Case 'create foreground holder and store exact process identity' {
        Start-AgentDockWslSession $runtime $helper
        $record=Read-WslSessionRecord $runtime
        Assert-Equal 1 $script:Spawns
        Assert-Equal 'Ubuntu-22.04' $record.Distro
        Assert-Equal 4242 (Get-WslSessionProcess $record).Id
        if ($script:CommandLine -match 'root|sudo|--shutdown|--terminate') { throw 'Privileged or destructive command detected' }
        if ($script:CommandLine -notmatch 'agentdock-keepalive-[0-9a-f]{32}') { throw 'Marker missing from command line' }
    }
    Test-Case 'repeated start and restart reuse holder rather than spawn duplicates' {
        Start-AgentDockWslSession $runtime $helper
        Start-AgentDockWslSession $runtime $helper
        Assert-Equal 1 $script:Spawns
    }
    Test-Case 'dead holder is replaced without reinstalling WSL' {
        Start-AgentDockWslSession $runtime $helper
        $old=Read-WslSessionRecord $runtime
        $script:Live=$false
        Start-AgentDockWslSession $runtime $helper
        Assert-Equal 2 $script:Spawns
        if ((Read-WslSessionRecord $runtime).Marker -eq $old.Marker) { throw 'Lease was not renewed' }
    }
    Test-Case 'changed default distro fails before touching existing holder' {
        Start-AgentDockWslSession $runtime $helper
        $script:DefaultDistro='Debian'
        Assert-Throws { Start-AgentDockWslSession $runtime $helper } 'Default WSL distribution changed'
        Assert-Equal 1 $script:Spawns
        Assert-Equal 0 $script:Stops
        Assert-Equal $true $script:Live
    }
    Test-Case 'PID reuse with wrong start time is not accepted' {
        Start-AgentDockWslSession $runtime $helper
        $record=Read-WslSessionRecord $runtime
        $script:Process.StartTime=$script:Process.StartTime.AddMinutes(1)
        Assert-Equal $null (Get-WslSessionProcess $record)
    }
    Test-Case 'foreign executable is not accepted' {
        Start-AgentDockWslSession $runtime $helper
        $record=Read-WslSessionRecord $runtime
        $script:Process.Path='C:\other\wsl.exe'
        Assert-Equal $null (Get-WslSessionProcess $record)
    }
    Test-Case 'nonce must be present in live process command line' {
        Start-AgentDockWslSession $runtime $helper
        $script:CommandLine='unrelated WSL command'
        Assert-Equal $null (Get-WslSessionProcess (Read-WslSessionRecord $runtime))
    }
    Test-Case 'stop kills only the recorded keepalive process' {
        Start-AgentDockWslSession $runtime $helper
        Stop-AgentDockWslSession $runtime
        Assert-Equal $false $script:Live
        Assert-Equal $false (Test-Path -LiteralPath (Get-WslSessionPaths $runtime).State)
        Assert-Equal 1 $script:Stops
    }
    Test-Case 'stop does not kill unrelated process from reused PID' {
        Start-AgentDockWslSession $runtime $helper
        $script:CommandLine='unrelated WSL command'
        Stop-AgentDockWslSession $runtime
        Assert-Equal 0 $script:Stops
        Assert-Equal $true $script:Live
    }
    Test-Case 'status lists running distros without a Linux exec or wake command' {
        Start-AgentDockWslSession $runtime $helper
        $script:Calls.Clear()
        $script:RunningNames=''
        $script:Live=$false
        Show-AgentDockWslSession $runtime
        Assert-Equal '--list|--running|--quiet' ($script:Calls -join ',')
    }
    Test-Case 'no-state status and stop never launch WSL' {
        Show-AgentDockWslSession $runtime
        Stop-AgentDockWslSession $runtime
        Assert-Equal 0 $script:Calls.Count
        Assert-Equal 0 $script:Spawns
    }
    Test-Case 'argument quoting preserves spaces and rejects injection/newlines' {
        Assert-Equal '"/mnt/c/path with spaces/a.sh"' (Quote-WslSessionArgument '/mnt/c/path with spaces/a.sh')
        Assert-Throws { Quote-WslSessionArgument "bad`nargument" } 'Unsupported'
        Assert-Throws { Quote-WslSessionArgument 'bad"argument' } 'Unsupported'
    }
    Test-Case 'spawn implementation avoids Start-Process and strips child secrets' {
        $sourceText = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/windows-wsl-session.ps1'))
        if ($sourceText -notmatch 'System\.Diagnostics\.ProcessStartInfo') { throw 'ProcessStartInfo implementation missing' }
        if ($sourceText -match 'Start-Process\s+-FilePath\s+\$Executable') { throw 'legacy Start-Process launcher still present' }
        foreach ($name in @('CONTROL_PLANE_API_KEY','OPENAI_API_KEY','RUNTIME_API_KEY','AGENTDOCK_AUTH_TOKEN','AGENTDOCK_BEARER_HEADER')) {
            if ($sourceText -notmatch [regex]::Escape($name)) { throw "secret filter missing: $name" }
        }
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CONTROL_PLANE_API_KEY,Env:AGENTDOCK_BEARER_HEADER -ErrorAction SilentlyContinue
}
Write-Host "WSL session tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
exit 0
