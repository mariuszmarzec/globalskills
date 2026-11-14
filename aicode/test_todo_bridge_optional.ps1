$ErrorActionPreference = "Stop"

$bridgeScript = Join-Path $PSScriptRoot "todo-mcp-bridge.ps1"
$probe = New-Object System.Net.Sockets.TcpClient
$todoDesktopAvailable = $false
try {
    $pending = $probe.BeginConnect([System.Net.IPAddress]::Loopback, 8765, $null, $null)
    if ($pending.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(1))) {
        $probe.EndConnect($pending)
        $todoDesktopAvailable = $true
    }
}
catch [System.Net.Sockets.SocketException] {
}
finally {
    $probe.Close()
}
if ($todoDesktopAvailable) {
    throw "The optional bridge test requires Todo Desktop MCP to be unavailable on 127.0.0.1:8765."
}

$relayAddress = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -match '^(10|192\.168)\.' -or
        $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[01])\.'
    } |
    Select-Object -First 1 -ExpandProperty IPAddress
if (-not $relayAddress) {
    throw "No private IPv4 address is available for the test relay."
}

$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Parse($relayAddress),
    0
)
$listenerStarted = $false
$stateRoot = Join-Path $env:TEMP ("globalskills-todo-optional-" + [Guid]::NewGuid().ToString("N"))
$script:bridgeLogFile = Join-Path $stateRoot "bridge.log"

function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    [pscustomobject]@{
        Name = "powershell.exe"
        ProcessId = $PID
        CommandLine = "isolated Todo bridge behavior test"
    }
}

function Start-Process {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [object]$ArgumentList,
        [string]$WindowStyle,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError,
        [switch]$PassThru
    )
    Set-Content -LiteralPath $script:bridgeLogFile -Value "Connected reverse channel 1 to WSL relay."
    Set-Content -LiteralPath $RedirectStandardOutput -Value ""
    Set-Content -LiteralPath $RedirectStandardError -Value ""
    [pscustomobject]@{ Id = $PID }
}

try {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $listener.Start()
    $listenerStarted = $true
    $relayPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $result = . $bridgeScript `
        -Action Ensure `
        -RelayAddress $relayAddress `
        -RelayPort $relayPort `
        -ChannelCount 1 `
        -StateDirectory $stateRoot
    $resultText = $result | Out-String
    if ($resultText -notmatch "reverse bridge connected to WSL") {
        throw "Todo bridge Ensure did not report successful startup."
    }
    Write-Output "PASS: Ensure succeeds when Todo Desktop MCP is unavailable."
}
finally {
    if ($listenerStarted) {
        $listener.Stop()
    }
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
}
