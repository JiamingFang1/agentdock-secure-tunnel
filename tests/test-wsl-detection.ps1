#requires -Version 5.1
# Offline tests: import function definitions only, never dispatch the installer.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'windows.ps1 failed to parse.' }
$wanted = @('Fail','ConvertFrom-WslOutputText','Invoke-WslCapture','Get-WslDistributions','Test-WslDistributionAvailable','Get-WslDistroId','Invoke-WslExitCode','Test-WslDocker','Get-WslRuntimeIdentity','Start-WslDockerService','Ensure-WslDockerInteractive','Select-Deployment')
$definitions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $false))
if ($definitions.Count -ne $wanted.Count) { throw 'Missing WSL functions in production source.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

function Assert-Equal($Expected,$Actual) {
    if ([string]$Expected -cne [string]$Actual) { throw "Expected [$Expected], got [$Actual]." }
}
function Assert-Throws([scriptblock]$Body,[string]$Pattern) {
    $message = $null
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or $message -notmatch $Pattern) { throw "Expected exception matching [$Pattern], got [$message]." }
}
function With-Nuls([string]$Text) {
    return (($Text.ToCharArray() | ForEach-Object { [string]$_ + [char]0 }) -join '')
}
function Reset-Mocks {
    $script:ListOutput = @('Ubuntu-22.04')
    $script:ListExit = 0
    $script:ThrowWsl = $false
    $script:UidOutput = '1000'
    $script:GidOutput = '1000'
    $script:CaptureExit = 0
    $script:DistroId = 'ubuntu'
    $script:DockerExit = 0
    $script:ComposeExit = 0
    $script:Prompts = 0
    $script:InstallCalls = 0
    $script:Calls = New-Object System.Collections.Generic.List[string]
}
# This function shadows wsl.exe. No real distro, daemon, download or Key is used.
function wsl.exe {
    $command = $args -join ' '
    $script:Calls.Add($command)
    if ($script:ThrowWsl) { throw 'mock WSL invocation failed' }
    switch -Exact ($command) {
        '--list --quiet' { $global:LASTEXITCODE = $script:ListExit; $script:ListOutput; return }
        '--exec id -u' { $global:LASTEXITCODE = $script:CaptureExit; $script:UidOutput; return }
        '--exec id -g' { $global:LASTEXITCODE = $script:CaptureExit; $script:GidOutput; return }
        '-u root --exec docker info' { $global:LASTEXITCODE = $script:DockerExit; return }
        '-u root --exec docker compose version' { $global:LASTEXITCODE = $script:ComposeExit; return }
    }
    if ($command -like '*/etc/os-release*') { $global:LASTEXITCODE = $script:CaptureExit; $script:DistroId; return }
    throw "Unexpected mocked WSL command: $command"
}
function Read-Host { $script:Prompts++; throw 'Unexpected installation prompt' }
function Install-WslUbuntu { $script:InstallCalls++; throw 'Unexpected WSL installation' }
function Install-DockerEngineInWsl { $script:InstallCalls++; throw 'Unexpected Docker installation' }
$script:Passed = 0
$script:Failed = 0
function Test-Case([string]$Name,[scriptblock]$Body) {
    Reset-Mocks
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name : $($_.Exception.Message)"
    }
}

Test-Case 'reproduce legacy char-overload bug on Windows PowerShell 5.1' {
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        $raised = $false
        try { [void]('Ubuntu'.Replace([char]0,'')) } catch { $raised = $true }
        Assert-Equal $true $raised
    }
}
Test-Case 'ordinary distro name is not mistaken for an empty list' {
    $names = @(Get-WslDistributions)
    Assert-Equal 1 $names.Count
    Assert-Equal 'Ubuntu-22.04' $names[0]
    Assert-Equal $true (Test-WslDistributionAvailable)
}
Test-Case 'NUL and BOM normalization preserves distro names' {
    $script:ListOutput = @(([string][char]0xFEFF + (With-Nuls 'Ubuntu-22.04')), (With-Nuls 'Debian'))
    Assert-Equal 'Ubuntu-22.04|Debian' (@(Get-WslDistributions) -join '|')
}
Test-Case 'CRLF LF and CR chunks are split without joining distro names' {
    $script:ListOutput = @("Ubuntu`r`nDebian`nAlpine`rFedora`r`n")
    Assert-Equal 'Ubuntu|Debian|Alpine|Fedora' (@(Get-WslDistributions) -join '|')
}
Test-Case 'blank lines and duplicate names are ignored' {
    $script:ListOutput = @('  ',[string][char]0,'Ubuntu','Ubuntu',"`r",'Debian')
    Assert-Equal 'Ubuntu|Debian' (@(Get-WslDistributions) -join '|')
}
Test-Case 'decoded non-ASCII characters are preserved' {
    $name = 'Ubuntu-' + [char]0x6D4B + [char]0x8BD5
    $script:ListOutput = @($name)
    Assert-Equal $name (@(Get-WslDistributions)[0])
}
Test-Case 'successful empty enumeration is genuinely empty' {
    $script:ListOutput = @()
    Assert-Equal 0 (@(Get-WslDistributions).Count)
    Assert-Equal $false (Test-WslDistributionAvailable)
}
Test-Case 'all installed distros are requested not only running ones' {
    [void](Get-WslDistributions)
    Assert-Equal '--list --quiet' ($script:Calls -join '|')
}
Test-Case 'UID and GID capture succeeds for ordinary Linux output' {
    $identity = Get-WslRuntimeIdentity
    Assert-Equal '1000' $identity.Uid
    Assert-Equal '1000' $identity.Gid
}
Test-Case 'UID and GID capture tolerates NUL characters' {
    $script:UidOutput = With-Nuls '1000'
    $script:GidOutput = With-Nuls '1001'
    $identity = Get-WslRuntimeIdentity
    Assert-Equal '1000' $identity.Uid
    Assert-Equal '1001' $identity.Gid
}
Test-Case 'root runtime user is still rejected' {
    $script:UidOutput = '0'
    Assert-Throws { Get-WslRuntimeIdentity } 'default WSL user is root'
}
Test-Case 'Linux distro ID capture succeeds' {
    Assert-Equal 'ubuntu' (Get-WslDistroId)
}
Test-Case 'failed Linux capture is not accepted as a value' {
    $script:CaptureExit = 1
    Assert-Equal $true ($null -eq (Invoke-WslCapture -WslArgs @('--exec','id','-u')))
}
Test-Case 'nonzero list exit is a detection error not an absent distro' {
    $script:ListExit = 42
    Assert-Throws { Get-WslDistributions } 'detection failed.*does NOT mean WSL is uninstalled.*code 42'
}
Test-Case 'WSL invocation exception is not silently swallowed by enumeration' {
    $script:ThrowWsl = $true
    Assert-Throws { Get-WslDistributions } 'detection failed.*mock WSL invocation failed'
}
Test-Case 'normalization exceptions do not become an empty enumeration' {
    function ConvertFrom-WslOutputText { throw 'mock normalization failure' }
    Assert-Throws { Get-WslDistributions } 'detection failed.*mock normalization failure'
}
Test-Case 'existing WSL Docker is reused without installation or prompts' {
    $config = [pscustomobject]@{ RequestedMode='docker'; HasWslWorkspace=$true }
    Assert-Equal 'docker-wsl' (Select-Deployment $config)
    Assert-Equal $true (Ensure-WslDockerInteractive)
    Assert-Equal 0 $script:Prompts
    Assert-Equal 0 $script:InstallCalls
}
Test-Case 'stopped Docker daemon does not mean WSL is missing' {
    $script:DockerExit = 1
    Assert-Equal $false (Test-WslDocker)
    Assert-Equal $true (Test-WslDistributionAvailable)
}
Test-Case 'missing Compose does not mean WSL is missing' {
    $script:ComposeExit = 1
    Assert-Equal $false (Test-WslDocker)
    Assert-Equal $true (Test-WslDistributionAvailable)
}
Test-Case 'list failure aborts deployment selection before install menu' {
    $script:ListExit = 1
    $config = [pscustomobject]@{ RequestedMode='docker'; HasWslWorkspace=$true }
    Assert-Throws { Select-Deployment $config } 'WSL distribution detection failed'
    Assert-Equal 0 $script:Prompts
    Assert-Equal 0 $script:InstallCalls
}
Write-Host "WSL detection tests: $script:Passed passed, $script:Failed failed. PowerShell $($PSVersionTable.PSVersion)"
if ($script:Failed -gt 0) { exit 1 }
