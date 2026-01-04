#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - PowerShell Editor Services installer
.DESCRIPTION
    Checks for PowerShellEditorServices installation and auto-installs from GitHub.
    Provides PowerShell IntelliSense, diagnostics, and debugging support.
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

class PowerShellLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\PowerShellEditorServices"
  hidden [string] $StartScript

  PowerShellLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("powershell-lsp")
    $this.StartScript = Join-Path $this.InstallDir "PowerShellEditorServices\Start-EditorServices.ps1"
  }

  [bool] IsInstalled() {
    return Test-Path $this.StartScript
  }

  [string] GetLatestReleaseUrl() {
    try {
      $response = Invoke-RestMethod "https://api.github.com/repos/PowerShell/PowerShellEditorServices/releases/latest" -ErrorAction Stop
      $asset = $response.assets | Where-Object { $_.name -eq "PowerShellEditorServices.zip" } | Select-Object -First 1
      if ($asset) {
        return $asset.browser_download_url
      }
    }
    catch {
      $this.EnvManager.WriteError("Failed to get latest release: $_")
    }
    return $null
  }

  [bool] Install() {
    $this.EnvManager.WriteInfo("Downloading PowerShellEditorServices from GitHub...")
    
    $downloadUrl = $this.GetLatestReleaseUrl()
    if (-not $downloadUrl) {
      # Fallback to known version
      $downloadUrl = "https://github.com/PowerShell/PowerShellEditorServices/releases/download/v4.4.0/PowerShellEditorServices.zip"
      $this.EnvManager.WriteInfo("Using fallback URL: v4.4.0")
    }

    $tempFile = Join-Path $env:TEMP "PowerShellEditorServices.zip"

    try {
      # Download the release
      $this.EnvManager.WriteInfo("Downloading from: $downloadUrl")
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -ErrorAction Stop

      # Create install directory
      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      # Extract
      $this.EnvManager.WriteInfo("Extracting to $($this.InstallDir)...")
      Expand-Archive -Path $tempFile -DestinationPath $this.InstallDir -Force

      # Cleanup
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

      if ($this.IsInstalled()) {
        $this.EnvManager.WriteSuccess("PowerShellEditorServices installed successfully")
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
      $this.EnvManager.WriteSuccess("PowerShell Editor Services is ready")
      $this.EnvManager.WriteInfo("Start script: $($this.StartScript)")
      return
    }

    $this.EnvManager.WriteInfo("PowerShell Editor Services not found. Installing...")
    if ($this.Install()) {
      if ($this.IsInstalled()) {
        $this.EnvManager.WriteSuccess("Installation complete!")
        $this.EnvManager.WriteInfo("Start script: $($this.StartScript)")
      }
      else {
        $this.EnvManager.WriteError("Installation completed but Start-EditorServices.ps1 not found")
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

$installer = [PowerShellLspInstaller]::new()
$installer.Run()
