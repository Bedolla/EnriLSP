#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Lua Language Server installer
.DESCRIPTION
    Checks for lua-language-server installation and auto-installs from GitHub releases.
    Uses OOP patterns with explicit types.
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

  [void] WriteWarning([string] $message) {
    Write-Host "[$($this.PluginName)] $message" -ForegroundColor Yellow
  }

  [void] WriteError([string] $message) {
    # Write to stderr so Claude Code Setup hooks display the message to user
    [Console]::Error.WriteLine("[$($this.PluginName)] $message")
  }

  [bool] FileExists([string] $path) {
    return (Test-Path $path -PathType Leaf)
  }

  [bool] AnyFileExists([string[]] $paths) {
    foreach ($path in $paths) {
      if (Test-Path $path -PathType Leaf) {
        return $true
      }
    }
    return $false
  }

  [string] FindExistingFile([string[]] $paths) {
    foreach ($path in $paths) {
      if ($path -match '\*|\?') {
        $found = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) {
          return $found.FullName
        }
      }
      elseif (Test-Path $path -PathType Leaf) {
        return $path
      }
    }
    return ""
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

  [bool] IsPackageManagerAvailable([string] $managerName) {
    $cmd = Get-Command $managerName -ErrorAction SilentlyContinue
    return ($null -ne $cmd)
  }
}

class LuaLanguageServerInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\lua-language-server"
  hidden [string] $LegacyInstallDir = "$env:LOCALAPPDATA\lua-language-server"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\EnriLSP\lua-language-server\bin\lua-language-server.exe",
    "$env:LOCALAPPDATA\lua-language-server\bin\lua-language-server.exe"
  )
  hidden [string] $GitHubReleaseApi = "https://api.github.com/repos/LuaLS/lua-language-server/releases/latest"

  LuaLanguageServerInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("lua-language-server")
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
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
      $this.EnvManager.WriteWarning("Could not migrate legacy lua-language-server install (continuing): $($_.Exception.Message)")
    }
  }

  [void] AddLspToPath() {
    $binPath = "$($this.InstallDir)\bin"
    $this.EnvManager.AddToUserPath($binPath)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP" }
      $release = Invoke-RestMethod -Uri $this.GitHubReleaseApi -Headers $headers -TimeoutSec 30 -ErrorAction Stop
      
      foreach ($asset in $release.assets) {
        if ($asset.name -match "lua-language-server.*win32-x64\.zip$") {
          return $asset.browser_download_url
        }
      }
    }
    catch {
      $this.EnvManager.WriteError("Failed to fetch release info: $_")
    }
    return ""
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing lua-language-server...")
    
    [string] $downloadUrl = $this.GetLatestReleaseUrl()
    if ([string]::IsNullOrEmpty($downloadUrl)) {
      $this.EnvManager.WriteError("Could not find download URL")
      return $false
    }

    try {
      # Create install directory
      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      # Download
      [string] $zipPath = "$env:TEMP\lua-language-server.zip"
      $this.EnvManager.WriteInfo("Downloading lua-language-server...")
      Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop

      # Extract
      $this.EnvManager.WriteInfo("Extracting...")
      Expand-Archive -Path $zipPath -DestinationPath $this.InstallDir -Force
      Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

      $this.AddLspToPath()

      if ($this.IsLspInstalled()) {
        $this.EnvManager.WriteSuccess("lua-language-server installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Installation failed: $_")
    }

    $this.EnvManager.WriteError("Failed to install lua-language-server")
    return $false
  }

  [int] Run() {
    $this.MigrateLegacyInstallIfNeeded()

    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("lua-language-server is already installed")
      return 0
    }

    [bool] $lspInstalled = $this.InstallLsp()
    if (-not $lspInstalled) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[LuaLanguageServerInstaller] $installer = [LuaLanguageServerInstaller]::new()
exit $installer.Run()
