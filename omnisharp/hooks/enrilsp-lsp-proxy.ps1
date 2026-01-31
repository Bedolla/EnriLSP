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
    pwsh -ExecutionPolicy Bypass -File enrilsp-lsp-proxy.ps1 <server> [args...]
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

function Normalize-InitializeWorkspaceFolders([psobject] $message) {
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

  $params = $paramsProp.Value
  $wfProp = $params.PSObject.Properties["workspaceFolders"]
  if ($null -eq $wfProp -or $null -eq $wfProp.Value) {
    return
  }

  $wf = $wfProp.Value

  # LSP spec: workspaceFolders must be an array (or null). Some clients send a single object.
  if ($wf -is [psobject]) {
    if ($wf.PSObject.Properties["uri"]) {
      $params.workspaceFolders = @($wf)
      return
    }

    # Or a map/dictionary-like object; convert its values to a list.
    $values = @()
    foreach ($prop in $wf.PSObject.Properties) {
      if ($null -ne $prop.Value) {
        $values += $prop.Value
      }
    }
    if ($values.Count -gt 0) {
      $params.workspaceFolders = $values
    }
    return
  }

  # If it's any other enumerable (but not a string), leave it as-is.
}

function Ensure-InitializeWorkspaceFolderCapability([psobject] $message) {
  if ($null -eq $message) {
    return
  }

  if (-not ($message.PSObject.Properties["method"] -and $message.method -eq "initialize")) {
    return
  }

  $params = Ensure-ObjectProperty $message "params"
  if ($null -eq $params) {
    return
  }

  # Some servers warn if workspaceFolders are sent but the client doesn't declare support.
  $wfProp = $params.PSObject.Properties["workspaceFolders"]
  if ($null -eq $wfProp -or $null -eq $wfProp.Value) {
    return
  }

  $caps = Ensure-ObjectProperty $params "capabilities"
  $workspace = Ensure-ObjectProperty $caps "workspace"
  $workspaceFoldersCaps = Ensure-ObjectProperty $workspace "workspaceFolders"

  $supported = $workspaceFoldersCaps.PSObject.Properties["supported"]
  if ($null -eq $supported) {
    $workspaceFoldersCaps | Add-Member -MemberType NoteProperty -Name "supported" -Value $true
  }
  else {
    $workspaceFoldersCaps.supported = $true
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

[bool] $fixShutdownErrors = -not [string]::IsNullOrWhiteSpace($env:ENRILSP_FIX_SHUTDOWN_ERRORS)
$shutdownRequestIds = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()

$headerTerminatorBytes = [byte[]]@(13, 10, 13, 10)

function Write-RawMessage([System.IO.Stream] $dest, [byte[]] $headersBytes, [byte[]] $bodyBytes) {
  $dest.Write($headersBytes, 0, $headersBytes.Length)
  $dest.Write($headerTerminatorBytes, 0, $headerTerminatorBytes.Length)
  $dest.Write($bodyBytes, 0, $bodyBytes.Length)
}

function Process-ClientBuffer([System.Collections.Generic.List[byte]] $clientBuffer) {
  while ($true) {
    $headerEnd = Find-HeaderEnd $clientBuffer
    if ($headerEnd -lt 0) {
      return
    }

    $headersBytes = $clientBuffer.GetRange(0, $headerEnd).ToArray()
    [string] $headersText = [System.Text.Encoding]::ASCII.GetString($headersBytes)
    [int] $contentLength = Get-ContentLength $headersText
    if ($contentLength -le 0) {
      Write-ProxyError("Missing or invalid Content-Length header")
      throw "Missing Content-Length"
    }

    [int] $bodyStart = $headerEnd + 4
    if ($clientBuffer.Count -lt ($bodyStart + $contentLength)) {
      return
    }

    $bodyBytes = $clientBuffer.GetRange($bodyStart, $contentLength).ToArray()
    $clientBuffer.RemoveRange(0, $bodyStart + $contentLength)

    [string] $jsonIn = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')) {
      $msg = $jsonIn | ConvertFrom-Json -Depth 100
    }
    else {
      $msg = $jsonIn | ConvertFrom-Json
    }

    if ($fixShutdownErrors -and $msg.PSObject.Properties["method"] -and $msg.method -eq "shutdown" -and $msg.PSObject.Properties["id"]) {
      $idKey = [string] $msg.id
      if (-not [string]::IsNullOrEmpty($idKey)) {
        $shutdownRequestIds[$idKey] = $true
      }
    }

    $msg = Fix-Value $msg
    Try-InjectTsdk $msg
    Normalize-InitializeWorkspaceFolders $msg
    Normalize-InitializeClientCapabilities $msg
    if ($msg.PSObject.Properties["method"] -and $msg.method -eq "shutdown") {
      $paramsProp = $msg.PSObject.Properties["params"]
      if ($paramsProp) {
        $paramsValue = $paramsProp.Value
        [bool] $removeParams = $false

        if ($null -eq $paramsValue) {
          $removeParams = $true
        }
        elseif (($paramsValue -is [System.Collections.IEnumerable]) -and -not ($paramsValue -is [string])) {
          # Some clients send shutdown params as [null] (or []). Strict servers (e.g. rust-analyzer)
          # expect no params at all.
          [bool] $allNull = $true
          foreach ($item in $paramsValue) {
            if ($null -ne $item) {
              $allNull = $false
              break
            }
          }
          if ($allNull) {
            $removeParams = $true
          }
        }

        if ($removeParams) {
          [void] $msg.PSObject.Properties.Remove("params")
        }
      }
    }
    [string] $jsonOut = $msg | ConvertTo-Json -Depth 100 -Compress
    [byte[]] $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)

    [string] $outHeaders = "Content-Length: $($outBytes.Length)`r`n`r`n"
    [byte[]] $outHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($outHeaders)

    $serverIn.Write($outHeaderBytes, 0, $outHeaderBytes.Length)
    $serverIn.Write($outBytes, 0, $outBytes.Length)
    $serverIn.Flush()
  }
}

function Process-ServerBuffer([System.Collections.Generic.List[byte]] $serverBuffer) {
  while ($true) {
    $headerEnd = Find-HeaderEnd $serverBuffer
    if ($headerEnd -lt 0) {
      return
    }

    $headersBytes = $serverBuffer.GetRange(0, $headerEnd).ToArray()
    [string] $headersText = [System.Text.Encoding]::ASCII.GetString($headersBytes)
    [int] $contentLength = Get-ContentLength $headersText
    if ($contentLength -le 0) {
      Write-ProxyError("Missing or invalid Content-Length header from server")
      throw "Missing Content-Length from server"
    }

    [int] $bodyStart = $headerEnd + 4
    if ($serverBuffer.Count -lt ($bodyStart + $contentLength)) {
      return
    }

    $bodyBytes = $serverBuffer.GetRange($bodyStart, $contentLength).ToArray()
    $serverBuffer.RemoveRange(0, $bodyStart + $contentLength)

    if (-not $fixShutdownErrors -or $shutdownRequestIds.Count -eq 0) {
      Write-RawMessage $clientOut $headersBytes $bodyBytes
      continue
    }

    # Only parse/modify if it's a response to a tracked shutdown request.
    [string] $jsonIn = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    if ($jsonIn -notmatch '\"id\"') {
      Write-RawMessage $clientOut $headersBytes $bodyBytes
      continue
    }

    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')) {
      $msg = $jsonIn | ConvertFrom-Json -Depth 100
    }
    else {
      $msg = $jsonIn | ConvertFrom-Json
    }

    $idProp = $msg.PSObject.Properties["id"]
    if ($null -eq $idProp -or $null -eq $idProp.Value) {
      Write-RawMessage $clientOut $headersBytes $bodyBytes
      continue
    }

    $idKey = [string] $idProp.Value
    if (-not $shutdownRequestIds.ContainsKey($idKey)) {
      Write-RawMessage $clientOut $headersBytes $bodyBytes
      continue
    }

    $errorProp = $msg.PSObject.Properties["error"]
    if ($null -ne $errorProp -and $null -ne $errorProp.Value) {
      # Dart analyzer sometimes returns an internal error for shutdown (-32001).
      # Claude Code treats that as a failure to stop. Rewrite to a successful null result.
      [void] $msg.PSObject.Properties.Remove("error")
      if ($msg.PSObject.Properties["result"]) {
        $msg.result = $null
      }
      else {
        $msg | Add-Member -MemberType NoteProperty -Name "result" -Value $null
      }
    }

    [bool] $ignored = $false
    $shutdownRequestIds.TryRemove($idKey, [ref] $ignored) | Out-Null

    [string] $jsonOut = $msg | ConvertTo-Json -Depth 100 -Compress
    [byte[]] $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)

    [string] $outHeaders = "Content-Length: $($outBytes.Length)`r`n`r`n"
    [byte[]] $outHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($outHeaders)

    $clientOut.Write($outHeaderBytes, 0, $outHeaderBytes.Length)
    $clientOut.Write($outBytes, 0, $outBytes.Length)
    $clientOut.Flush()
  }
}

$clientBuffer = New-Object System.Collections.Generic.List[byte]
$serverBuffer = New-Object System.Collections.Generic.List[byte]

$clientReadBuf = New-Object byte[] 8192
$serverReadBuf = New-Object byte[] 8192

$clientReadTask = $clientIn.ReadAsync($clientReadBuf, 0, $clientReadBuf.Length)
$serverReadTask = $serverOut.ReadAsync($serverReadBuf, 0, $serverReadBuf.Length)

[bool] $clientEof = $false
[bool] $serverEof = $false

try {
  while (-not ($clientEof -and $serverEof)) {
    $tasks = @()
    $taskKinds = @()

    if (-not $clientEof) {
      $tasks += $clientReadTask
      $taskKinds += "client"
    }

    if (-not $serverEof) {
      $tasks += $serverReadTask
      $taskKinds += "server"
    }

    if ($tasks.Count -eq 0) {
      break
    }

    $completedIndex = [System.Threading.Tasks.Task]::WaitAny($tasks)
    $kind = $taskKinds[$completedIndex]

    if ($kind -eq "client") {
      $n = $clientReadTask.Result
      if ($n -le 0) {
        $clientEof = $true
        try { $serverIn.Close() } catch {}
      }
      else {
        $chunk = New-Object byte[] $n
        [System.Array]::Copy($clientReadBuf, 0, $chunk, 0, $n)
        $clientBuffer.AddRange($chunk)
        Process-ClientBuffer $clientBuffer
      }

      if (-not $clientEof) {
        $clientReadTask = $clientIn.ReadAsync($clientReadBuf, 0, $clientReadBuf.Length)
      }
    }
    else {
      $n = $serverReadTask.Result
      if ($n -le 0) {
        $serverEof = $true
      }
      else {
        $chunk = New-Object byte[] $n
        [System.Array]::Copy($serverReadBuf, 0, $chunk, 0, $n)
        $serverBuffer.AddRange($chunk)
        Process-ServerBuffer $serverBuffer
      }

      if (-not $serverEof) {
        $serverReadTask = $serverOut.ReadAsync($serverReadBuf, 0, $serverReadBuf.Length)
      }
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

try { $server.WaitForExit(2000) | Out-Null } catch {}
