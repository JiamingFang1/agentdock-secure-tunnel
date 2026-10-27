#requires -Version 5.1
# Record only workspace evidence, bound to a particular native process.
function Save-NativeWorkspace($Process, $Workspace) {
    $state = @{
        pid = $Process.Id
        started = $Process.StartTime.ToUniversalTime().Ticks.ToString()
        executable = $AgentDockExe
        workspace = $Workspace.Name
        path = $Workspace.Path
    }
    $temp = "$NativeState.tmp"
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $NativeState -Force
}

function Get-NativeWorkspace($Config) {
    try {
        $state = Get-Content -LiteralPath $NativeState -Raw | ConvertFrom-Json
        $processId = [int](Get-Content -LiteralPath $NativePid -Raw).Trim()
        if ($processId -le 0 -or $state.pid -ne $processId) { return 'UNKNOWN' }
        $process = Get-Process -Id $processId -ErrorAction Stop
        if ($process.Path -ne $AgentDockExe -or $state.executable -ne $AgentDockExe -or
            $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $state.started) { return 'UNKNOWN' }
        $workspace = @($Config.Workspaces | Where-Object { $_.Name -ceq $state.workspace -and $_.Path -eq $state.path })
        if ($workspace.Count -ne 1) { return 'CUSTOM' }
        return [string]$state.workspace
    } catch { return 'UNKNOWN' }
}
