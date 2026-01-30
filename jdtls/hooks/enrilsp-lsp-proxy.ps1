#Requires -Version 5.1
<#
.SYNOPSIS
  EnriLSP - LSP stdio proxy for Windows quirks.
.DESCRIPTION
  Workarounds for LSP servers that are strict about RFC 8089 file URIs and/or
  require extra initialize options (e.g. Astro tsdk).

  This proxy sits between Claude Code (client) and the real language server.

  Features:
  - Fixes broken Windows file URIs: file://C:\path -> file:///C:/path
  - Optionally injects initializationOptions.typescript.tsdk when
    ENRILSP_TSDK_PATH is set.

  Usage:
    powershell -ExecutionPolicy Bypass -File enrilsp-lsp-proxy.ps1 <server> [args...]
#>

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string] $ServerCommand,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $ServerArgs
)

$ErrorActionPreference = "Stop"

function Write-ProxyError([string] $message) {
  [Console]::Error.WriteLine("[enrilsp-lsp-proxy] $message")
}

function Normalize-FileUri([string] $value) {
  if ([string]::IsNullOrEmpty($value)) {
    return $value
  }

  if (-not $value.StartsWith("file://")) {
    return $value
  }

  # Already-correct drive URI, just normalize slashes.
  if ($value -match '^file:///[A-Za-z]:') {
    return ($value -replace '\\', '/')
  }

  # Common broken form observed in Claude logs: file://C:\Users\...
  if ($value -match '^file://[A-Za-z]:') {
    [string] $rest = $value.Substring(7)
    $rest = $rest -replace '\\', '/'
    return "file:///$rest"
  }

  return $value
}

function Fix-Value([object] $value) {
  if ($null -eq $value) {
    return $null
  }

  if ($value -is [string]) {
    return (Normalize-FileUri $value)
  }

  if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
    if ($value -is [System.Collections.IList]) {
      for ([int] $i = 0; $i -lt $value.Count; $i++) {
        $value[$i] = Fix-Value $value[$i]
      }
    }
    return $value
  }

  if ($value -is [psobject]) {
    foreach ($prop in $value.PSObject.Properties) {
      $value.$($prop.Name) = Fix-Value $prop.Value
    }
    return $value
  }

  return $value
}

function Ensure-ObjectProperty([psobject] $obj, [string] $name) {
  if ($null -eq $obj) {
    return $null
  }

  $existing = $obj.PSObject.Properties[$name]
  if ($null -eq $existing -or $null -eq $existing.Value) {
    $child = New-Object psobject
    if ($null -eq $existing) {
      $obj | Add-Member -MemberType NoteProperty -Name $name -Value $child
    }
    else {
      $obj.$name = $child
    }
    return $child
  }

  if (-not ($existing.Value -is [psobject])) {
    $child = New-Object psobject
    $obj.$name = $child
    return $child
  }

  return $existing.Value
}

function Try-InjectTsdk([psobject] $message) {
  [string] $tsdk = $env:ENRILSP_TSDK_PATH
  if ([string]::IsNullOrWhiteSpace($tsdk)) {
    return
  }

  if ($null -eq $message) {
    return
  }

  if ($message.PSObject.Properties["method"] -and $message.method -eq "initialize") {
    $params = Ensure-ObjectProperty $message "params"
    $initOptions = Ensure-ObjectProperty $params "initializationOptions"
    $ts = Ensure-ObjectProperty $initOptions "typescript"

    $existing = $ts.PSObject.Properties["tsdk"]
    if ($null -eq $existing -or [string]::IsNullOrWhiteSpace([string] $existing.Value)) {
      if ($null -eq $existing) {
        $ts | Add-Member -MemberType NoteProperty -Name "tsdk" -Value $tsdk
      }
      else {
        $ts.tsdk = $tsdk
      }
    }
  }
}

function Normalize-InitializeClientCapabilities([psobject] $message) {
  if ($null -eq $message) {
    return
  }

  if (-not ($message.PSObject.Properties["method"] -and $message.method -eq "initialize")) {
    return
  }

  $paramsProp = $message.PSObject.Properties["params"]
  if ($null -eq $paramsProp -or -not ($paramsProp.Value -is [psobject])) {
    return
  }

  $capsProp = $paramsProp.Value.PSObject.Properties["capabilities"]
  if ($null -eq $capsProp -or -not ($capsProp.Value -is [psobject])) {
    return
  }

  $generalProp = $capsProp.Value.PSObject.Properties["general"]
  if ($null -eq $generalProp -or -not ($generalProp.Value -is [psobject])) {
    return
  }

  $general = $generalProp.Value

  # Claude Code on Windows has been observed sending a string instead of a string[] for
  # capabilities.general.positionEncodings. Some servers (e.g. texlab) reject this.
  $posEnc = $general.PSObject.Properties["positionEncodings"]
  if ($posEnc -and $posEnc.Value -is [string]) {
    $general.positionEncodings = @($posEnc.Value)
  }

  # Some clients use the singular form; normalize to the plural, array form.
  $posEncSingle = $general.PSObject.Properties["positionEncoding"]
  if ($posEncSingle -and $posEncSingle.Value -is [string]) {
    if (-not $general.PSObject.Properties["positionEncodings"] -or $null -eq $general.positionEncodings) {
      $general.positionEncodings = @($posEncSingle.Value)
    }
    [void] $general.PSObject.Properties.Remove("positionEncoding")
  }
}

function Find-HeaderEnd([System.Collections.Generic.List[byte]] $buffer) {
  for ([int] $i = 0; $i -le $buffer.Count - 4; $i++) {
    if ($buffer[$i] -eq 13 -and $buffer[$i + 1] -eq 10 -and $buffer[$i + 2] -eq 13 -and $buffer[$i + 3] -eq 10) {
      return $i
    }
  }
  return -1
}

function Get-ContentLength([string] $headersText) {
  foreach ($line in ($headersText -split "`r`n")) {
    if ($line -match '^Content-Length:\s*(\d+)\s*$') {
      return [int] $Matches[1]
    }
  }
  return 0
}

function Start-ServerProcess([string] $cmd, [string[]] $serverArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  # In PowerShell 7+, Process.ErrorDataReceived event handlers can run on threads
  # without an attached Runspace, which causes a fatal PSInvalidOperationException.
  # Let stderr inherit so it still reaches Claude Code logs without async handlers.
  $psi.RedirectStandardError = $false
  $psi.CreateNoWindow = $true

  if ($cmd -match '\.(cmd|bat)$') {
    $psi.FileName = "cmd.exe"
    $escapedArgs = ($serverArgs | ForEach-Object {
      if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "

    # cmd.exe quoting is subtle when the invoked .cmd path contains spaces.
    # Use a single, fully-quoted command string after /c:
    #   /c ""C:\Path With Spaces\server.cmd" arg1 "arg 2""
    if ([string]::IsNullOrWhiteSpace($escapedArgs)) {
      $commandLine = "`"$cmd`""
    }
    else {
      $commandLine = "`"$cmd`" $escapedArgs"
    }
    $psi.Arguments = "/c `"$commandLine`""
  }
  else {
    $psi.FileName = $cmd
    $psi.Arguments = ($serverArgs | ForEach-Object {
      if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
  }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi

  if (-not $proc.Start()) {
    throw "Failed to start server process"
  }
  return $proc
}

try {
  $server = Start-ServerProcess $ServerCommand $ServerArgs
}
catch {
  Write-ProxyError("Unable to start server '$ServerCommand': $($_.Exception.Message)")
  exit 1
}

$clientIn = [Console]::OpenStandardInput()
$clientOut = [Console]::OpenStandardOutput()

$serverIn = $server.StandardInput.BaseStream
$serverOut = $server.StandardOutput.BaseStream

# Server -> Client (no modifications)
$copyTask = $serverOut.CopyToAsync($clientOut)

# Client -> Server (rewrite JSON payloads)
$buffer = New-Object System.Collections.Generic.List[byte]
$readBuf = New-Object byte[] 8192

try {
  while ($true) {
    $headerEnd = Find-HeaderEnd $buffer
    while ($headerEnd -lt 0) {
      $n = $clientIn.Read($readBuf, 0, $readBuf.Length)
      if ($n -le 0) {
        break
      }
      # NOTE: In Windows PowerShell 5.1, slicing a byte[] (e.g. $readBuf[0..($n-1)])
      # yields System.Object[], which breaks List[byte].AddRange(IEnumerable[byte]).
      # Copy into a real byte[] before AddRange.
      $chunk = New-Object byte[] $n
      [System.Array]::Copy($readBuf, 0, $chunk, 0, $n)
      $buffer.AddRange($chunk)
      $headerEnd = Find-HeaderEnd $buffer
    }

    if ($headerEnd -lt 0) {
      break
    }

    $headersBytes = $buffer.GetRange(0, $headerEnd).ToArray()
    [string] $headersText = [System.Text.Encoding]::ASCII.GetString($headersBytes)
    [int] $contentLength = Get-ContentLength $headersText
    if ($contentLength -le 0) {
      Write-ProxyError("Missing or invalid Content-Length header")
      break
    }

    [int] $bodyStart = $headerEnd + 4
    while ($buffer.Count -lt ($bodyStart + $contentLength)) {
      $n = $clientIn.Read($readBuf, 0, $readBuf.Length)
      if ($n -le 0) {
        break
      }
      $chunk = New-Object byte[] $n
      [System.Array]::Copy($readBuf, 0, $chunk, 0, $n)
      $buffer.AddRange($chunk)
    }

    if ($buffer.Count -lt ($bodyStart + $contentLength)) {
      break
    }

    $bodyBytes = $buffer.GetRange($bodyStart, $contentLength).ToArray()
    $buffer.RemoveRange(0, $bodyStart + $contentLength)

    [string] $jsonIn = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')) {
      $msg = $jsonIn | ConvertFrom-Json -Depth 100
    }
    else {
      $msg = $jsonIn | ConvertFrom-Json
    }
    $msg = Fix-Value $msg
    Try-InjectTsdk $msg
    Normalize-InitializeClientCapabilities $msg

    [string] $jsonOut = $msg | ConvertTo-Json -Depth 100 -Compress
    [byte[]] $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)

    [string] $outHeaders = "Content-Length: $($outBytes.Length)`r`n`r`n"
    [byte[]] $outHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($outHeaders)

    $serverIn.Write($outHeaderBytes, 0, $outHeaderBytes.Length)
    $serverIn.Write($outBytes, 0, $outBytes.Length)
    try {
      $serverIn.Flush()
    }
    catch [System.IO.IOException] {
      break
    }
  }
}
catch {
  $msg = [string]$_.Exception.Message
  if ($msg -notmatch 'pipe is being closed') {
    Write-ProxyError("Proxy error: $msg")
  }
}
finally {
  try { $serverIn.Close() } catch {}
}

try { $copyTask.Wait() } catch {}
try { $server.WaitForExit(2000) | Out-Null } catch {}
