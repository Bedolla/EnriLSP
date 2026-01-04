#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - CMake Language Server installer
.DESCRIPTION
    Checks for cmake-language-server installation and auto-installs via pip.
    Provides CMake IntelliSense support.
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

class CmakeLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller

  CmakeLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("cmake-lsp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsPythonInstalled() {
    return $this.EnvManager.CommandExists("python") -or $this.EnvManager.CommandExists("python3")
  }

  [bool] IsLspInstalled() {
    $this.EnvManager.RefreshSessionPath()
    return $this.EnvManager.CommandExists("cmake-language-server")
  }

  [string] GetPythonCommand() {
    if ($this.EnvManager.CommandExists("python")) {
      return "python"
    }
    return "python3"
  }

  [bool] InstallPython() {
    $this.EnvManager.WriteInfo("Python not found. Installing...")
    [PackageManagerResult] $result = $this.PkgInstaller.InstallWithWinget("Python.Python.3.12", "Python 3.12")
    
    if ($result.Success) {
      $this.EnvManager.WriteSuccess($result.Message)
      $this.EnvManager.RefreshSessionPath()
      return $true
    }
    
    $this.EnvManager.WriteError("Failed to install Python. Please install manually.")
    return $false
  }

  [bool] InstallLsp() {
    [string] $python = $this.GetPythonCommand()
    $this.EnvManager.WriteInfo("Installing cmake-language-server via pip...")
    
    try {
      $process = Start-Process -FilePath $python -ArgumentList "-m", "pip", "install", "--user", "cmake-language-server" -Wait -PassThru -NoNewWindow
      if ($process.ExitCode -eq 0) {
        # Add Python Scripts to PATH - find the correct Python version
        [string[]] $pythonPaths = @(
          "$env:APPDATA\Python\Python314\Scripts",
          "$env:APPDATA\Python\Python313\Scripts",
          "$env:APPDATA\Python\Python312\Scripts",
          "$env:APPDATA\Python\Python311\Scripts"
        )
        foreach ($path in $pythonPaths) {
          if (Test-Path $path) {
            $this.EnvManager.AddToUserPath($path)
            break
          }
        }
        $this.EnvManager.RefreshSessionPath()
        $this.EnvManager.WriteSuccess("cmake-language-server installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("pip install failed: $_")
    }
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("cmake-language-server is already installed")
      return 0
    }

    if (-not $this.IsPythonInstalled()) {
      if (-not $this.InstallPython()) {
        return 0
      }
    }

    if (-not $this.InstallLsp()) {
      $this.EnvManager.WriteError("Failed to install. Please run manually:")
      $this.EnvManager.WriteInfo("  pip install --user cmake-language-server")
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[CmakeLspInstaller] $installer = [CmakeLspInstaller]::new()
exit $installer.Run()
