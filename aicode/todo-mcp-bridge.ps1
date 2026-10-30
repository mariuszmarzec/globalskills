param(
    [ValidateSet("Ensure", "Serve")]
    [string]$Action = "Ensure",
    [string]$BindAddress,
    [string]$AllowedClientAddress,
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 18765,
    [string]$StateDirectory,
    [string]$SourceHash
)

$ErrorActionPreference = "Stop"

function Get-BridgeStateDirectory {
    if ($StateDirectory) {
        return $StateDirectory
    }
    return (Join-Path $env:LOCALAPPDATA "GlobalSkills\TodoMcpBridge")
}

function Test-IPv4Address([string]$Value) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) {
        return $false
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        [System.Net.IPAddress]::IsLoopback($parsed) -or
        $parsed.Equals([System.Net.IPAddress]::Any) -or
        $parsed.Equals([System.Net.IPAddress]::Broadcast)) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    $private = $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
    return $private
}

function Test-ManagedBridgeProcess([int]$ProcessId, [string]$ScriptPath) {
    if ($ProcessId -le 0) {
        return $false
    }
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if (-not $processInfo -or -not $processInfo.CommandLine) {
        return $false
    }
    return $processInfo.CommandLine.IndexOf($ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $processInfo.CommandLine -match '(?i)-Action\s+Serve'
}

$stateRoot = Get-BridgeStateDirectory
if (-not (Test-Path -LiteralPath $stateRoot)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
}
$stateItem = Get-Item -LiteralPath $stateRoot -Force
if (($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing a reparse-point bridge state directory."
}
$stateFile = Join-Path $stateRoot "bridge.json"
$logFile = Join-Path $stateRoot "bridge.log"
$stdoutLog = Join-Path $stateRoot "bridge-stdout.log"
$errorLog = Join-Path $stateRoot "bridge-error.log"
$cachedScript = Join-Path $stateRoot "todo-mcp-bridge.ps1"

if ($Action -eq "Serve") {
    if (-not (Test-IPv4Address $BindAddress) -or -not (Test-IPv4Address $AllowedClientAddress)) {
        throw "The bridge requires concrete private IPv4 bind/client addresses."
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public static class TodoMcpWindowsBridge
{
    private static readonly object LogLock = new object();

    private static void Log(string path, string value)
    {
        lock (LogLock)
        {
            File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + value + Environment.NewLine);
        }
    }

    public static void Run(string bindAddress, string allowedClientAddress, int port, string logPath)
    {
        IPAddress bind = IPAddress.Parse(bindAddress);
        IPAddress allowed = IPAddress.Parse(allowedClientAddress);
        if (bind.AddressFamily != AddressFamily.InterNetwork ||
            allowed.AddressFamily != AddressFamily.InterNetwork ||
            IPAddress.IsLoopback(bind) || bind.Equals(IPAddress.Any))
            throw new InvalidOperationException("The bridge must bind one concrete Windows host IPv4 address.");

        TcpListener listener = new TcpListener(bind, port);
        listener.Start(64);
        Log(logPath, "Listening on the WSL-facing host interface; expected WSL source IP " + allowed + ".");
        while (true)
        {
            TcpClient client = listener.AcceptTcpClient();
            Task.Run(() => HandleClient(client, bind, allowed, logPath));
        }
    }

    private static void HandleClient(TcpClient client, IPAddress bind, IPAddress allowed, string logPath)
    {
        TcpClient upstream = null;
        try
        {
            IPEndPoint remote = client.Client.RemoteEndPoint as IPEndPoint;
            if (remote == null)
            {
                Log(logPath, "Rejected a connection with no IPv4 remote endpoint.");
                client.Close();
                return;
            }
            if (remote.Address.Equals(bind))
            {
                // Ensure() performs a local TCP readiness probe from Windows.
                // It must not be confused with a rejected WSL client connection.
                Log(logPath, "Ignored local Windows readiness probe from " + remote.Address + ".");
                client.Close();
                return;
            }
            if (!remote.Address.Equals(allowed))
            {
                Log(logPath, "Rejected connection from " + remote.Address + "; expected WSL source " + allowed + ".");
                client.Close();
                return;
            }

            upstream = new TcpClient(AddressFamily.InterNetwork);
            upstream.Connect(IPAddress.Loopback, 8765);
            NetworkStream clientStream = client.GetStream();
            NetworkStream upstreamStream = upstream.GetStream();
            byte[] requestHeader = ReadRequestHeader(clientStream);
            byte[] rewrittenHeader = RewriteRequestHeader(requestHeader);
            upstreamStream.Write(rewrittenHeader, 0, rewrittenHeader.Length);

            Task requestPump = clientStream.CopyToAsync(upstreamStream);
            Task responsePump = upstreamStream.CopyToAsync(clientStream);
            responsePump.GetAwaiter().GetResult();
        }
        catch (Exception error)
        {
            Log(logPath, "Bridge request failed: " + error.GetType().Name);
        }
        finally
        {
            try { if (upstream != null) upstream.Close(); } catch { }
            try { client.Close(); } catch { }
        }
    }

    private static byte[] ReadRequestHeader(NetworkStream stream)
    {
        using (MemoryStream buffer = new MemoryStream())
        {
            while (buffer.Length < 65536)
            {
                int next = stream.ReadByte();
                if (next < 0)
                    throw new IOException("Client closed before sending HTTP headers.");
                buffer.WriteByte((byte)next);
                if (buffer.Length >= 4)
                {
                    byte[] bytes = buffer.GetBuffer();
                    int n = (int)buffer.Length;
                    if (bytes[n - 4] == 13 && bytes[n - 3] == 10 &&
                        bytes[n - 2] == 13 && bytes[n - 1] == 10)
                        return buffer.ToArray();
                }
            }
        }
        throw new IOException("HTTP request headers exceeded the bridge limit.");
    }

    private static byte[] RewriteRequestHeader(byte[] rawHeader)
    {
        string text = Encoding.ASCII.GetString(rawHeader);
        string[] lines = text.Split(new string[] { "\r\n" }, StringSplitOptions.None);
        if (lines.Length < 2)
            throw new IOException("Invalid HTTP request.");

        string[] requestLine = lines[0].Split(' ');
        if (requestLine.Length != 3 ||
            (requestLine[0] != "GET" && requestLine[0] != "POST" && requestLine[0] != "DELETE") ||
            (requestLine[1] != "/mcp" && !requestLine[1].StartsWith("/mcp?", StringComparison.Ordinal)) ||
            (requestLine[2] != "HTTP/1.0" && requestLine[2] != "HTTP/1.1"))
            throw new IOException("Only HTTP GET/POST/DELETE requests to /mcp are allowed.");

        List<string> output = new List<string>();
        output.Add(lines[0]);
        bool hostSeen = false;
        for (int i = 1; i < lines.Length && lines[i].Length > 0; i++)
        {
            string line = lines[i];
            if (line.StartsWith("Host:", StringComparison.OrdinalIgnoreCase))
            {
                if (hostSeen)
                    throw new IOException("Duplicate Host header.");
                output.Add("Host: 127.0.0.1:8765");
                hostSeen = true;
            }
            else if (line.StartsWith("Origin:", StringComparison.OrdinalIgnoreCase))
            {
                output.Add("Origin: http://127.0.0.1:8765");
            }
            else if (!line.StartsWith("Connection:", StringComparison.OrdinalIgnoreCase))
            {
                output.Add(line);
            }
        }
        if (!hostSeen)
            throw new IOException("Missing Host header.");

        output.Add("Connection: close");
        output.Add("");
        output.Add("");
        return Encoding.ASCII.GetBytes(String.Join("\r\n", output.ToArray()));
    }
}
'@

    [TodoMcpWindowsBridge]::Run($BindAddress, $AllowedClientAddress, $ListenPort, $logFile)
    exit 0
}

if (-not (Test-IPv4Address $BindAddress) -or -not (Test-IPv4Address $AllowedClientAddress)) {
    throw "The bridge requires concrete private IPv4 bind/client addresses."
}

if (-not $SourceHash) {
    $SourceHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
}
Copy-Item -LiteralPath $PSCommandPath -Destination $cachedScript -Force
$existing = $null
if (Test-Path -LiteralPath $stateFile) {
    try { $existing = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { $existing = $null }
}
if ($existing -and (Test-ManagedBridgeProcess ([int]$existing.pid) $cachedScript)) {
    $same = $existing.bindAddress -eq $BindAddress -and
        $existing.allowedClientAddress -eq $AllowedClientAddress -and
        [int]$existing.listenPort -eq $ListenPort -and
        $existing.sourceHash -eq $SourceHash
    if ($same) {
        $process = Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue
        if ($process) {
            Write-Output ("Todo MCP Windows bridge already running on {0}:{1}." -f $BindAddress, $ListenPort)
            exit 0
        }
    }
    Stop-Process -Id ([int]$existing.pid) -Force -ErrorAction SilentlyContinue
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not (Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
    }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}
elseif (Test-Path -LiteralPath $stateFile) {
    Remove-Item -LiteralPath $stateFile -Force
}

$listenerProbe = $null
try {
    $listenerProbe = New-Object System.Net.Sockets.TcpClient
    $listenerProbe.Connect($BindAddress, $ListenPort)
    $listenerProbe.Close()
    throw "Port $ListenPort is occupied by a listener not managed by this bridge."
}
catch [System.Net.Sockets.SocketException] {
    if ($listenerProbe) { $listenerProbe.Close() }
}

$powerShellPath = Join-Path $PSHOME "powershell.exe"
$argumentList = @(
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", $cachedScript,
    "-Action", "Serve",
    "-BindAddress", $BindAddress,
    "-AllowedClientAddress", $AllowedClientAddress,
    "-ListenPort", [string]$ListenPort,
    "-StateDirectory", $stateRoot,
    "-SourceHash", $SourceHash
)
$quotedArguments = foreach ($argument in $argumentList) {
    '"' + $argument.Replace('"', '\"') + '"'
}
Remove-Item -LiteralPath $logFile, $stdoutLog, $errorLog -Force -ErrorAction SilentlyContinue
$process = Start-Process -FilePath $powerShellPath -ArgumentList ($quotedArguments -join " ") -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $errorLog -PassThru
$state = [ordered]@{
    pid = $process.Id
    bindAddress = $BindAddress
    allowedClientAddress = $AllowedClientAddress
    listenPort = $ListenPort
    sourceHash = $SourceHash
}
$state | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding ASCII
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
        throw "Todo MCP Windows bridge exited during startup; inspect $errorLog."
    }
    $probe = $null
    try {
        $probe = New-Object System.Net.Sockets.TcpClient
        $probe.Connect($BindAddress, $ListenPort)
        $probe.Close()
        Write-Output ("Todo MCP Windows bridge listening on {0}:{1} for WSL source {2}." -f $BindAddress, $ListenPort, $AllowedClientAddress)
        exit 0
    }
    catch [System.Net.Sockets.SocketException] {
        if ($probe) { $probe.Close() }
        Start-Sleep -Milliseconds 125
    }
}
throw "Todo MCP Windows bridge did not become ready; inspect $errorLog."
