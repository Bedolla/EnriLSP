#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - JSON Language Server installer
.DESCRIPTION
    Checks for vscode-json-languageserver installation and auto-installs via npm.
    Provides JSON IntelliSense, schema validation and formatting.
.NOTES
    Author: Bedolla
    License: MIT
#>

# ============================================================================
# CLASSES
# ============================================================================

class PackageManagerResult {
  [bool] $Success
  [string] $Message
  [string] $ManagerUsed

  PackageManagerResult([bool] $success, [string] $message, [string] $managerUsed) {
    $this.Success = $success
    $this.Message = $message
    $this.ManagerUsed = $managerUsed
  }
}

class EnvironmentManager {
  hidden [string] $PluginName

  EnvironmentManager([string] $pluginName) {
    $this.PluginName = $pluginName
  }

  [void] WriteInfo([string] $message) {
    Write-Host "[$($this.PluginName)] $message"
  }

  [void] WriteSuccess([string] $message) {
    Write-Host "[$($this.PluginName)] $message" -ForegroundColor Green
  }

  [void] WriteError([string] $message) {
    Write-Host "[$($this.PluginName)] $message" -ForegroundColor Red
  }

  [bool] CommandExists([string] $command) {
    return [bool](Get-Command $command -ErrorAction SilentlyContinue)
  }

  [void] AddToUserPath([string] $binPath) {
    [string] $oldUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($oldUserPath -notlike "*$binPath*") {
      [System.Environment]::SetEnvironmentVariable("Path", "$oldUserPath;$binPath", "User")
      $this.WriteInfo("Added to user PATH: $binPath")
    }
  }

  [void] RefreshSessionPath() {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
      [System.Environment]::GetEnvironmentVariable("Path", "User")
  }
}

class PackageInstaller {
  hidden [EnvironmentManager] $EnvManager

  PackageInstaller([EnvironmentManager] $envManager) {
    $this.EnvManager = $envManager
  }

  [PackageManagerResult] InstallWithWinget([string] $packageId, [string] $packageName) {
    if (-not $this.EnvManager.CommandExists("winget")) {
      return [PackageManagerResult]::new($false, "winget not available", "none")
    }

    $this.EnvManager.WriteInfo("Installing $packageName via winget...")
    try {
      $process = Start-Process -FilePath "winget" -ArgumentList "install", "--id", $packageId, "-e", "--accept-source-agreements", "--accept-package-agreements", "--scope", "user" -Wait -PassThru -NoNewWindow
      if ($process.ExitCode -eq 0) {
        return [PackageManagerResult]::new($true, "$packageName installed successfully", "winget")
      }
    }
    catch {
      return [PackageManagerResult]::new($false, "winget installation failed: $_", "winget")
    }
    return [PackageManagerResult]::new($false, "winget installation failed", "winget")
  }
}

class JsonLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $NpmBinPath = "$env:APPDATA\npm"

  JsonLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("json-lsp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsInstalled() {
    $this.EnvManager.RefreshSessionPath()
    $serverPath = Join-Path $this.NpmBinPath "vscode-json-languageserver.cmd"
    return (Test-Path $serverPath) -or $this.EnvManager.CommandExists("vscode-json-languageserver")
  }

  [bool] EnsureNodeJs() {
    if ($this.EnvManager.CommandExists("node")) {
      return $true
    }
    $this.EnvManager.WriteInfo("Node.js not found. Installing...")
    $result = $this.PkgInstaller.InstallWithWinget("OpenJS.NodeJS.LTS", "Node.js LTS")
    if ($result.Success) {
      $this.EnvManager.RefreshSessionPath()
      return $this.EnvManager.CommandExists("node")
    }
    return $false
  }

  [bool] Install() {
    if (-not $this.EnsureNodeJs()) {
      $this.EnvManager.WriteError("Node.js installation failed")
      return $false
    }

    $this.EnvManager.WriteInfo("Installing vscode-json-languageserver via npm...")

    try {
      $npmPath = (Get-Command npm -ErrorAction SilentlyContinue).Source
      if (-not $npmPath) {
        $this.EnvManager.WriteError("npm not found in PATH")
        return $false
      }

      $process = Start-Process -FilePath $npmPath -ArgumentList "install", "-g", "vscode-json-languageserver" -Wait -PassThru -NoNewWindow
      if ($process.ExitCode -eq 0) {
        $this.EnvManager.AddToUserPath($this.NpmBinPath)
        $this.EnvManager.RefreshSessionPath()
        $this.EnvManager.WriteSuccess("vscode-json-languageserver installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Installation failed: $_")
    }
    return $false
  }

  [void] Run() {
    if ($this.IsInstalled()) {
      $this.EnvManager.WriteSuccess("JSON Language Server is ready")
      return
    }

    $this.EnvManager.WriteInfo("JSON Language Server not found. Installing...")
    if ($this.Install()) {
      if ($this.IsInstalled()) {
        $this.EnvManager.WriteSuccess("Installation complete!")
      }
      else {
        $this.EnvManager.WriteError("Installation completed but server not found in PATH")
      }
    }
    else {
      $this.EnvManager.WriteError("Installation failed")
    }
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

$installer = [JsonLspInstaller]::new()
$installer.Run()
