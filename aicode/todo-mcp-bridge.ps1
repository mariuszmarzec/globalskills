param(
    [ValidateSet("Ensure", "Connect")]
    [string]$Action = "Ensure",
    [string]$RelayAddress,
    [ValidateRange(1, 65535)]
    [int]$RelayPort = 18766,
    [ValidateRange(1, 16)]
    [int]$ChannelCount = 4,
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
        $processInfo.CommandLine -match '(?i)-Action\s+(Connect|Serve)'
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

if ($Action -eq "Connect") {
    if (-not (Test-IPv4Address $RelayAddress)) {
        throw "The reverse relay address must be a concrete private IPv4 address."
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
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

    public static void Run(string relayAddress, int relayPort, int channelCount, string logPath)
    {
        IPAddress relay = IPAddress.Parse(relayAddress);
        List<Task> workers = new List<Task>();
        for (int i = 0; i < channelCount; i++)
        {
            int channelNumber = i + 1;
            workers.Add(Task.Run(() => MaintainChannel(relay, relayPort, channelNumber, logPath)));
        }
        Task.WaitAll(workers.ToArray());
    }

    private static void MaintainChannel(IPAddress relay, int relayPort, int channelNumber, string logPath)
    {
        while (true)
        {
            using (TcpClient channel = new TcpClient(AddressFamily.InterNetwork))
            {
                try
                {
                    IAsyncResult pending = channel.BeginConnect(relay, relayPort, null, null);
                    if (!pending.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(5)))
                        throw new TimeoutException("Reverse relay connection timed out.");
                    channel.EndConnect(pending);
                    Log(logPath, "Connected reverse channel " + channelNumber + " to WSL relay.");
                    HandleChannel(channel, logPath);
                }
                catch (Exception error)
                {
                    Log(logPath, "Reverse channel " + channelNumber + " failed: " + error.GetType().Name);
                }
            }
            Thread.Sleep(750);
        }
    }

    private static void HandleChannel(TcpClient channel, string logPath)
    {
        TcpClient upstream = null;
        try
        {
            NetworkStream channelStream = channel.GetStream();
            byte[] requestHeader = ReadRequestHeader(channelStream);

            upstream = new TcpClient(AddressFamily.InterNetwork);
            upstream.Connect(IPAddress.Loopback, 8765);
            NetworkStream upstreamStream = upstream.GetStream();
            byte[] rewrittenHeader = RewriteRequestHeader(requestHeader);
            upstreamStream.Write(rewrittenHeader, 0, rewrittenHeader.Length);

            // Todo receives Connection: close, so its response stream ending is
            // the lifecycle boundary for this one-request reverse channel.
            // Do not wait for requestPump: an HTTP client may keep its request
            // socket open after sending Content-Length bytes.
            Task requestPump = channelStream.CopyToAsync(upstreamStream);
            Task responsePump = upstreamStream.CopyToAsync(channelStream);
            responsePump.GetAwaiter().GetResult();
        }
        catch (Exception error)
        {
            Log(logPath, "Reverse channel request failed: " + error.GetType().Name);
        }
        finally
        {
            try { if (upstream != null) upstream.Close(); } catch { }
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
                    throw new IOException("Reverse channel closed before HTTP headers arrived.");
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

    [TodoMcpWindowsBridge]::Run($RelayAddress, $RelayPort, $ChannelCount, $logFile)
    exit 0
}

if (-not (Test-IPv4Address $RelayAddress)) {
    throw "The reverse relay address must be a concrete private IPv4 address."
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
    $same = $existing.relayAddress -eq $RelayAddress -and
        [int]$existing.relayPort -eq $RelayPort -and
        [int]$existing.channelCount -eq $ChannelCount -and
        $existing.sourceHash -eq $SourceHash
    if ($same) {
        $process = Get-Process -Id ([int]$existing.pid) -ErrorAction SilentlyContinue
        if ($process) {
            Write-Output ("Todo MCP Windows reverse bridge already connecting to {0}:{1}." -f $RelayAddress, $RelayPort)
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

$relayProbe = $null
try {
    $relayProbe = New-Object System.Net.Sockets.TcpClient
    $relayProbe.Connect($RelayAddress, $RelayPort)
    $relayProbe.Close()
}
catch [System.Net.Sockets.SocketException] {
    if ($relayProbe) { $relayProbe.Close() }
    throw ("WSL reverse relay {0}:{1} is not reachable from Windows." -f $RelayAddress, $RelayPort)
}

$powerShellPath = Join-Path $PSHOME "powershell.exe"
$argumentList = @(
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-File", $cachedScript,
    "-Action", "Connect",
    "-RelayAddress", $RelayAddress,
    "-RelayPort", [string]$RelayPort,
    "-ChannelCount", [string]$ChannelCount,
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
    relayAddress = $RelayAddress
    relayPort = $RelayPort
    channelCount = $ChannelCount
    sourceHash = $SourceHash
}
$state | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding ASCII
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
        throw "Todo MCP Windows reverse bridge exited during startup; inspect $errorLog."
    }
    if ((Test-Path -LiteralPath $logFile) -and
        (Select-String -LiteralPath $logFile -Pattern "Connected reverse channel" -Quiet)) {
        Write-Output ("Todo MCP Windows reverse bridge connected to WSL {0}:{1} with {2} channels." -f $RelayAddress, $RelayPort, $ChannelCount)
        exit 0
    }
    Start-Sleep -Milliseconds 125
}
throw "Todo MCP Windows reverse bridge did not connect to WSL; inspect $logFile and $errorLog."
