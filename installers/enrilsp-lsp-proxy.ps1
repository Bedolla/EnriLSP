#Requires -Version 5.1
<#
.SYNOPSIS
  EnriLSP - LSP stdio proxy for Windows quirks.
.DESCRIPTION
  Workarounds for LSP servers that are strict about RFC 8089 file URIs and/or
  require extra initialize options (e.g. Astro tsdk).

  This proxy sits between the MCP client and the real language server.

  Features:
  - Fixes broken Windows file URIs: file://C:\path -> file:///C:/path
  - Optionally injects initializationOptions.typescript.tsdk when ENRILSP_TSDK_PATH is set.

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

class EnriLspLspProxy {
  hidden [string] $Prefix
  hidden [string] $ServerCommand
  hidden [string[]] $ServerArgs

  hidden [System.Diagnostics.Process] $Server

  hidden [System.IO.Stream] $ClientIn
  hidden [System.IO.Stream] $ClientOut

  hidden [System.IO.Stream] $ServerIn
  hidden [System.IO.Stream] $ServerOut

  hidden [bool] $FixShutdownErrors
  hidden [System.Collections.Concurrent.ConcurrentDictionary[string, bool]] $ShutdownRequestIds
  hidden [byte[]] $HeaderTerminatorBytes

  hidden [string] $TsdkPath

  EnriLspLspProxy([string] $serverCommand, [string[]] $serverArgs) {
    $this.Prefix = "[EnriLSP]"
    $this.ServerCommand = $serverCommand
    $this.ServerArgs = $serverArgs

    $this.TsdkPath = [string] $env:ENRILSP_TSDK_PATH
    $this.FixShutdownErrors = -not [string]::IsNullOrWhiteSpace($env:ENRILSP_FIX_SHUTDOWN_ERRORS)
    $this.ShutdownRequestIds = [System.Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
    $this.HeaderTerminatorBytes = [byte[]]@(13, 10, 13, 10)
  }

  hidden [void] WriteProxyError([string] $message) {
    [Console]::Error.WriteLine("$($this.Prefix) $message")
  }

  hidden [psobject] ConvertFromJson([string] $json, [int] $depth) {
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("Depth")) {
      return ($json | ConvertFrom-Json -Depth $depth)
    }
    return ($json | ConvertFrom-Json)
  }

  hidden [string] ConvertToJson([object] $value, [int] $depth) {
    return ($value | ConvertTo-Json -Depth $depth -Compress)
  }

  hidden [string] NormalizeFileUri([string] $value) {
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

    # Common broken form observed on Windows: file://C:\Users\...
    if ($value -match '^file://[A-Za-z]:') {
      [string] $rest = $value.Substring(7)
      $rest = [string] ($rest -replace '\\', '/')
      return "file:///$rest"
    }

    return $value
  }

  hidden [object] FixValue([object] $value) {
    if ($null -eq $value) {
      return $null
    }

    if ($value -is [string]) {
      return $this.NormalizeFileUri([string] $value)
    }

    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [string])) {
      if ($value -is [System.Collections.IList]) {
        for ([int] $index = 0; $index -lt $value.Count; $index++) {
          $value[$index] = $this.FixValue($value[$index])
        }
      }
      return $value
    }

    if ($value -is [psobject]) {
      foreach ($prop in $value.PSObject.Properties) {
        $value.$($prop.Name) = $this.FixValue($prop.Value)
      }
      return $value
    }

    return $value
  }

  hidden [psobject] EnsureObjectProperty([psobject] $obj, [string] $name) {
    if ($null -eq $obj) {
      return $null
    }

    [System.Management.Automation.PSPropertyInfo] $existing = $obj.PSObject.Properties[$name]
    if ($null -eq $existing -or $null -eq $existing.Value) {
      [psobject] $child = New-Object psobject
      if ($null -eq $existing) {
        $obj | Add-Member -MemberType NoteProperty -Name $name -Value $child
      }
      else {
        $obj.$name = $child
      }
      return $child
    }

    if (-not ($existing.Value -is [psobject])) {
      [psobject] $child = New-Object psobject
      $obj.$name = $child
      return $child
    }

    return [psobject] $existing.Value
  }

  hidden [void] TryInjectTsdk([psobject] $message) {
    if ([string]::IsNullOrWhiteSpace($this.TsdkPath)) {
      return
    }

    if ($null -eq $message) {
      return
    }

    if ($message.PSObject.Properties["method"] -and $message.method -eq "initialize") {
      [psobject] $params = $this.EnsureObjectProperty($message, "params")
      [psobject] $initOptions = $this.EnsureObjectProperty($params, "initializationOptions")
      [psobject] $ts = $this.EnsureObjectProperty($initOptions, "typescript")

      [System.Management.Automation.PSPropertyInfo] $existing = $ts.PSObject.Properties["tsdk"]
      if ($null -eq $existing -or [string]::IsNullOrWhiteSpace([string] $existing.Value)) {
        if ($null -eq $existing) {
          $ts | Add-Member -MemberType NoteProperty -Name "tsdk" -Value $this.TsdkPath
        }
        else {
          $ts.tsdk = $this.TsdkPath
        }
      }
    }
  }

  hidden [void] NormalizeInitializeClientCapabilities([psobject] $message) {
    if ($null -eq $message) {
      return
    }

    if (-not ($message.PSObject.Properties["method"] -and $message.method -eq "initialize")) {
      return
    }

    [System.Management.Automation.PSPropertyInfo] $paramsProp = $message.PSObject.Properties["params"]
    if ($null -eq $paramsProp -or -not ($paramsProp.Value -is [psobject])) {
      return
    }

    [System.Management.Automation.PSPropertyInfo] $capsProp = $paramsProp.Value.PSObject.Properties["capabilities"]
    if ($null -eq $capsProp -or -not ($capsProp.Value -is [psobject])) {
      return
    }

    [System.Management.Automation.PSPropertyInfo] $generalProp = $capsProp.Value.PSObject.Properties["general"]
    if ($null -eq $generalProp -or -not ($generalProp.Value -is [psobject])) {
      return
    }

    [psobject] $general = [psobject] $generalProp.Value

    # Some clients send a string instead of a string[] for capabilities.general.positionEncodings.
    [System.Management.Automation.PSPropertyInfo] $posEnc = $general.PSObject.Properties["positionEncodings"]
    if ($posEnc -and $posEnc.Value -is [string]) {
      $general.positionEncodings = @($posEnc.Value)
    }

    # Some clients use the singular form; normalize to the plural, array form.
    [System.Management.Automation.PSPropertyInfo] $posEncSingle = $general.PSObject.Properties["positionEncoding"]
    if ($posEncSingle -and $posEncSingle.Value -is [string]) {
      if (-not $general.PSObject.Properties["positionEncodings"] -or $null -eq $general.positionEncodings) {
        $general.positionEncodings = @($posEncSingle.Value)
      }
      [void] $general.PSObject.Properties.Remove("positionEncoding")
    }
  }

  hidden [void] NormalizeInitializeWorkspaceFolders([psobject] $message) {
    if ($null -eq $message) {
      return
    }

    if (-not ($message.PSObject.Properties["method"] -and $message.method -eq "initialize")) {
      return
    }

    [System.Management.Automation.PSPropertyInfo] $paramsProp = $message.PSObject.Properties["params"]
    if ($null -eq $paramsProp -or -not ($paramsProp.Value -is [psobject])) {
      return
    }

    [psobject] $params = [psobject] $paramsProp.Value
    [System.Management.Automation.PSPropertyInfo] $wfProp = $params.PSObject.Properties["workspaceFolders"]
    if ($null -eq $wfProp -or $null -eq $wfProp.Value) {
      return
    }

    [object] $wf = $wfProp.Value

    # LSP spec: workspaceFolders must be an array (or null). Some clients send a single object.
    if ($wf -is [psobject]) {
      if ($wf.PSObject.Properties["uri"]) {
        $params.workspaceFolders = @($wf)
        return
      }

      # Or a map/dictionary-like object; convert its values to a list.
      [object[]] $values = @()
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
  }

  hidden [int] FindHeaderEnd([System.Collections.Generic.List[byte]] $buffer) {
    for ([int] $index = 0; $index -le $buffer.Count - 4; $index++) {
      if ($buffer[$index] -eq 13 -and $buffer[$index + 1] -eq 10 -and $buffer[$index + 2] -eq 13 -and $buffer[$index + 3] -eq 10) {
        return $index
      }
    }
    return -1
  }

  hidden [int] GetContentLength([string] $headersText) {
    foreach ($line in ($headersText -split "`r`n")) {
      if ($line -match '^Content-Length:\s*(\d+)\s*$') {
        return [int] $Matches[1]
      }
    }
    return 0
  }

  hidden [System.Diagnostics.Process] StartServerProcess([string] $cmd, [string[]] $serverArgs) {
    [System.Diagnostics.ProcessStartInfo] $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    # In PowerShell 7+, Process.ErrorDataReceived event handlers can run on threads
    # without an attached Runspace, which causes a fatal PSInvalidOperationException.
    # Let stderr inherit so it still reaches logs without async handlers.
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    if ($cmd -match '\.(cmd|bat)$') {
      $psi.FileName = "cmd.exe"
      [string] $escapedArgs = ($serverArgs | ForEach-Object {
        if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
      }) -join " "

      # cmd.exe quoting is subtle when the invoked .cmd path contains spaces.
      # Use a single, fully-quoted command string after /c:
      #   /c ""C:\Path With Spaces\server.cmd" arg1 "arg 2""
      if ([string]::IsNullOrWhiteSpace($escapedArgs)) {
        [string] $commandLine = "`"$cmd`""
      }
      else {
        [string] $commandLine = "`"$cmd`" $escapedArgs"
      }
      $psi.Arguments = "/c `"$commandLine`""
    }
    else {
      $psi.FileName = $cmd
      $psi.Arguments = ($serverArgs | ForEach-Object {
        if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
      }) -join " "
    }

    [System.Diagnostics.Process] $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    if (-not $proc.Start()) {
      throw "Failed to start server process"
    }
    return $proc
  }

  hidden [void] WriteRawMessage([System.IO.Stream] $dest, [byte[]] $headersBytes, [byte[]] $bodyBytes) {
    $dest.Write($headersBytes, 0, $headersBytes.Length)
    $dest.Write($this.HeaderTerminatorBytes, 0, $this.HeaderTerminatorBytes.Length)
    $dest.Write($bodyBytes, 0, $bodyBytes.Length)
  }

  hidden [void] ProcessClientBuffer([System.Collections.Generic.List[byte]] $clientBuffer) {
    while ($true) {
      [int] $headerEnd = $this.FindHeaderEnd($clientBuffer)
      if ($headerEnd -lt 0) {
        return
      }

      [byte[]] $headersBytes = $clientBuffer.GetRange(0, $headerEnd).ToArray()
      [string] $headersText = [System.Text.Encoding]::ASCII.GetString($headersBytes)
      [int] $contentLength = $this.GetContentLength($headersText)
      if ($contentLength -le 0) {
        $this.WriteProxyError("Missing or invalid Content-Length header")
        throw "Missing Content-Length"
      }

      [int] $bodyStart = $headerEnd + 4
      if ($clientBuffer.Count -lt ($bodyStart + $contentLength)) {
        return
      }

      [byte[]] $bodyBytes = $clientBuffer.GetRange($bodyStart, $contentLength).ToArray()
      $clientBuffer.RemoveRange(0, $bodyStart + $contentLength)

      [string] $jsonIn = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
      [psobject] $msg = $this.ConvertFromJson($jsonIn, 100)

      if ($this.FixShutdownErrors -and $msg.PSObject.Properties["method"] -and $msg.method -eq "shutdown" -and $msg.PSObject.Properties["id"]) {
        [string] $idKey = [string] $msg.id
        if (-not [string]::IsNullOrEmpty($idKey)) {
          $this.ShutdownRequestIds[$idKey] = $true
        }
      }

      $msg = [psobject] $this.FixValue($msg)
      $this.TryInjectTsdk($msg)
      $this.NormalizeInitializeWorkspaceFolders($msg)
      $this.NormalizeInitializeClientCapabilities($msg)

      if ($msg.PSObject.Properties["method"] -and $msg.method -eq "shutdown") {
        [System.Management.Automation.PSPropertyInfo] $paramsProp = $msg.PSObject.Properties["params"]
        if ($paramsProp) {
          [object] $paramsValue = $paramsProp.Value
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

      [string] $jsonOut = $this.ConvertToJson($msg, 100)
      [byte[]] $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)

      [string] $outHeaders = "Content-Length: $($outBytes.Length)`r`n`r`n"
      [byte[]] $outHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($outHeaders)

      $this.ServerIn.Write($outHeaderBytes, 0, $outHeaderBytes.Length)
      $this.ServerIn.Write($outBytes, 0, $outBytes.Length)
      $this.ServerIn.Flush()
    }
  }

  hidden [void] ProcessServerBuffer([System.Collections.Generic.List[byte]] $serverBuffer) {
    while ($true) {
      [int] $headerEnd = $this.FindHeaderEnd($serverBuffer)
      if ($headerEnd -lt 0) {
        return
      }

      [byte[]] $headersBytes = $serverBuffer.GetRange(0, $headerEnd).ToArray()
      [string] $headersText = [System.Text.Encoding]::ASCII.GetString($headersBytes)
      [int] $contentLength = $this.GetContentLength($headersText)
      if ($contentLength -le 0) {
        $this.WriteProxyError("Missing or invalid Content-Length header from server")
        throw "Missing Content-Length from server"
      }

      [int] $bodyStart = $headerEnd + 4
      if ($serverBuffer.Count -lt ($bodyStart + $contentLength)) {
        return
      }

      [byte[]] $bodyBytes = $serverBuffer.GetRange($bodyStart, $contentLength).ToArray()
      $serverBuffer.RemoveRange(0, $bodyStart + $contentLength)

      # Some clients do not implement `window/workDoneProgress/create`. Some servers (notably csharp-ls)
      # treat a "method not found" response as fatal and crash. This request only affects progress UI;
      # it is safe to short-circuit it here.
      if ($bodyBytes.Length -lt 16384) {
        try {
          [string] $maybeJson = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
          if ($maybeJson -match '\"method\"') {
            [psobject] $req = $this.ConvertFromJson($maybeJson, 50)

            [System.Management.Automation.PSPropertyInfo] $methodProp = $req.PSObject.Properties["method"]
            if ($methodProp -and $methodProp.Value -eq "window/workDoneProgress/create") {
              [System.Management.Automation.PSPropertyInfo] $idProp = $req.PSObject.Properties["id"]
              if ($null -ne $idProp -and $null -ne $idProp.Value) {
                [psobject] $resp = [pscustomobject]@{
                  jsonrpc = "2.0"
                  id      = $idProp.Value
                  result  = $null
                }
                [string] $respJson = $this.ConvertToJson($resp, 10)
                [byte[]] $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                [string] $respHeaders = "Content-Length: $($respBytes.Length)`r`n`r`n"
                [byte[]] $respHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($respHeaders)

                $this.ServerIn.Write($respHeaderBytes, 0, $respHeaderBytes.Length)
                $this.ServerIn.Write($respBytes, 0, $respBytes.Length)
                $this.ServerIn.Flush()
              }

              # Do not forward this request to the client.
              continue
            }
          }
        }
        catch { }
      }

      if (-not $this.FixShutdownErrors -or $this.ShutdownRequestIds.Count -eq 0) {
        $this.WriteRawMessage($this.ClientOut, $headersBytes, $bodyBytes)
        continue
      }

      # Only parse/modify if it is a response to a tracked shutdown request.
      [string] $jsonIn = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
      if ($jsonIn -notmatch '\"id\"') {
        $this.WriteRawMessage($this.ClientOut, $headersBytes, $bodyBytes)
        continue
      }

      [psobject] $msg = $this.ConvertFromJson($jsonIn, 100)
      [System.Management.Automation.PSPropertyInfo] $idProp = $msg.PSObject.Properties["id"]
      if ($null -eq $idProp -or $null -eq $idProp.Value) {
        $this.WriteRawMessage($this.ClientOut, $headersBytes, $bodyBytes)
        continue
      }

      [string] $idKey = [string] $idProp.Value
      if (-not $this.ShutdownRequestIds.ContainsKey($idKey)) {
        $this.WriteRawMessage($this.ClientOut, $headersBytes, $bodyBytes)
        continue
      }

      [System.Management.Automation.PSPropertyInfo] $errorProp = $msg.PSObject.Properties["error"]
      if ($null -ne $errorProp -and $null -ne $errorProp.Value) {
        # Dart analyzer sometimes returns an internal error for shutdown (-32001).
        # Some clients treat that as a failure to stop. Rewrite to a successful null result.
        [void] $msg.PSObject.Properties.Remove("error")
        if ($msg.PSObject.Properties["result"]) {
          $msg.result = $null
        }
        else {
          $msg | Add-Member -MemberType NoteProperty -Name "result" -Value $null
        }
      }

      [bool] $ignored = $false
      $this.ShutdownRequestIds.TryRemove($idKey, [ref] $ignored) | Out-Null

      [string] $jsonOut = $this.ConvertToJson($msg, 100)
      [byte[]] $outBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)

      [string] $outHeaders = "Content-Length: $($outBytes.Length)`r`n`r`n"
      [byte[]] $outHeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($outHeaders)

      $this.ClientOut.Write($outHeaderBytes, 0, $outHeaderBytes.Length)
      $this.ClientOut.Write($outBytes, 0, $outBytes.Length)
      $this.ClientOut.Flush()
    }
  }

  [int] Run() {
    try {
      $this.Server = $this.StartServerProcess($this.ServerCommand, $this.ServerArgs)
    }
    catch {
      $this.WriteProxyError("Unable to start server '$($this.ServerCommand)': $($_.Exception.Message)")
      return 1
    }

    $this.ClientIn = [Console]::OpenStandardInput()
    $this.ClientOut = [Console]::OpenStandardOutput()

    $this.ServerIn = $this.Server.StandardInput.BaseStream
    $this.ServerOut = $this.Server.StandardOutput.BaseStream

    [System.Collections.Generic.List[byte]] $clientBuffer = [System.Collections.Generic.List[byte]]::new()
    [System.Collections.Generic.List[byte]] $serverBuffer = [System.Collections.Generic.List[byte]]::new()

    [byte[]] $clientReadBuf = New-Object byte[] 8192
    [byte[]] $serverReadBuf = New-Object byte[] 8192

    [System.Threading.Tasks.Task] $clientReadTask = $this.ClientIn.ReadAsync($clientReadBuf, 0, $clientReadBuf.Length)
    [System.Threading.Tasks.Task] $serverReadTask = $this.ServerOut.ReadAsync($serverReadBuf, 0, $serverReadBuf.Length)

    [bool] $clientEof = $false
    [bool] $serverEof = $false

    try {
      while (-not ($clientEof -and $serverEof)) {
        [System.Threading.Tasks.Task[]] $tasks = @()
        [string[]] $taskKinds = @()

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

        [int] $completedIndex = [System.Threading.Tasks.Task]::WaitAny($tasks)
        [string] $kind = [string] $taskKinds[$completedIndex]

        if ($kind -eq "client") {
          [int] $readCount = $clientReadTask.Result
          if ($readCount -le 0) {
            $clientEof = $true
            try { $this.ServerIn.Close() } catch {}
          }
          else {
            [byte[]] $chunk = New-Object byte[] $readCount
            [System.Array]::Copy($clientReadBuf, 0, $chunk, 0, $readCount)
            $clientBuffer.AddRange($chunk)
            $this.ProcessClientBuffer($clientBuffer)
          }

          if (-not $clientEof) {
            $clientReadTask = $this.ClientIn.ReadAsync($clientReadBuf, 0, $clientReadBuf.Length)
          }
        }
        else {
          [int] $readCount = $serverReadTask.Result
          if ($readCount -le 0) {
            $serverEof = $true
          }
          else {
            [byte[]] $chunk = New-Object byte[] $readCount
            [System.Array]::Copy($serverReadBuf, 0, $chunk, 0, $readCount)
            $serverBuffer.AddRange($chunk)
            $this.ProcessServerBuffer($serverBuffer)
          }

          if (-not $serverEof) {
            $serverReadTask = $this.ServerOut.ReadAsync($serverReadBuf, 0, $serverReadBuf.Length)
          }
        }
      }
    }
    catch {
      [string] $msg = [string] $_.Exception.Message
      if ($msg -notmatch 'pipe is being closed') {
        $this.WriteProxyError("Proxy error: $msg")
      }
    }
    finally {
      try { $this.ServerIn.Close() } catch {}
    }

    try { $this.Server.WaitForExit(2000) | Out-Null } catch {}
    return 0
  }
}

$proxy = [EnriLspLspProxy]::new($ServerCommand, $ServerArgs)
exit ($proxy.Run())
