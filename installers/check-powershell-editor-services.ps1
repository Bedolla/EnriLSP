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
    # Write to stderr so Claude Code Setup hooks display the message to user
    [Console]::Error.WriteLine("[$($this.PluginName)] $message")
  }

  [bool] CommandExists([string] $command) {
    return [bool](Get-Command $command -ErrorAction SilentlyContinue)
  }

  [void] AddToUserPath([string] $binPath) {
    [string] $oldUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    # Normalize path for comparison (remove trailing backslash)
    [string] $normalizedBin = $binPath.TrimEnd('\')
    [string[]] $existingPaths = $oldUserPath -split ';' | ForEach-Object { $_.TrimEnd('\') }

    if ($normalizedBin -notin $existingPaths) {
      [System.Environment]::SetEnvironmentVariable("Path", "$oldUserPath;$binPath", "User")
      $this.WriteInfo("Added to user PATH: $binPath")
    }
  }

  [void] RefreshSessionPath() {
    # Combine Machine and User PATH, avoiding empty separators
    [string] $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    [string] $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $machinePath = $machinePath.TrimEnd(';')
    $userPath = $userPath.TrimEnd(';')
    $env:Path = "$machinePath;$userPath"
  }
}

class PowerShellLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\PowerShellEditorServices"
  hidden [string] $LegacyInstallDir = "$env:LOCALAPPDATA\PowerShellEditorServices"
  hidden [string] $StartScript

  PowerShellLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("powershell-lsp")
    $this.StartScript = Join-Path $this.InstallDir "PowerShellEditorServices\Start-EditorServices.ps1"
  }

  [bool] IsInstalled() {
    return Test-Path $this.StartScript
  }

  [bool] IsLegacyInstalled() {
    [string] $legacyStart = Join-Path $this.LegacyInstallDir "PowerShellEditorServices\Start-EditorServices.ps1"
    return Test-Path $legacyStart
  }

  [void] MigrateLegacyInstallIfNeeded() {
    try {
      if ($this.LegacyInstallDir -eq $this.InstallDir) {
        return
      }

      if ((Test-Path $this.LegacyInstallDir) -and -not (Test-Path $this.InstallDir)) {
        [string] $parent = Split-Path -Parent $this.InstallDir
        if (-not (Test-Path $parent)) {
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $this.EnvManager.WriteInfo("Migrating legacy install to: $($this.InstallDir)")
        Move-Item -Path $this.LegacyInstallDir -Destination $this.InstallDir -Force
      }
    }
    catch {
      $this.EnvManager.WriteError("Could not migrate legacy PowerShellEditorServices install (continuing): $($_.Exception.Message)")
    }
  }

  [string] GetLatestReleaseUrl() {
    try {
      $response = Invoke-RestMethod "https://api.github.com/repos/PowerShell/PowerShellEditorServices/releases/latest" -TimeoutSec 30 -ErrorAction Stop
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
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop

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

  [int] Run() {
    $this.MigrateLegacyInstallIfNeeded()

    if ($this.IsInstalled()) {
      $this.EnvManager.WriteSuccess("PowerShell Editor Services is ready")
      $this.EnvManager.WriteInfo("Start script: $($this.StartScript)")
      return 0
    }

    $this.EnvManager.WriteInfo("PowerShell Editor Services not found. Installing...")
    if ($this.Install()) {
      if ($this.IsInstalled()) {
        $this.EnvManager.WriteSuccess("Installation complete!")
        $this.EnvManager.WriteInfo("Start script: $($this.StartScript)")
        return 0
      }
      else {
        $this.EnvManager.WriteError("Installation completed but Start-EditorServices.ps1 not found")
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
    }
    else {
      $this.EnvManager.WriteError("Installation failed")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[PowerShellLspInstaller] $installer = [PowerShellLspInstaller]::new()
exit $installer.Run()
