#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Postgres Language Server installer
.DESCRIPTION
    Checks for postgres-language-server installation and auto-installs from GitHub releases.
    Provides PostgreSQL development support with autocompletion and diagnostics.
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

  [bool] AnyFileExists([string[]] $paths) {
    foreach ($path in $paths) {
      if (Test-Path $path -PathType Leaf) {
        return $true
      }
    }
    return $false
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

class PostgresLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  # Centralized bin directory for EnriLSP-installed executables
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string[]] $LspKnownPaths = @(
    # Preferred centralized location
    "$env:LOCALAPPDATA\EnriLSP\bin\postgres-language-server.exe",

    # Legacy location (kept for compatibility)
    "$env:LOCALAPPDATA\postgres-language-server\postgres-language-server.exe"
  )
  hidden [string] $GitHubApiUrl = "https://api.github.com/repos/supabase-community/postgres-language-server/releases/latest"

  PostgresLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("postgres-lsp")
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [void] AddLspToPath() {
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP-Installer" }
      $release = Invoke-RestMethod -Uri $this.GitHubApiUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
      
      foreach ($asset in $release.assets) {
        if ($asset.name -eq "postgres-language-server_x86_64-pc-windows-msvc") {
          return $asset.browser_download_url
        }
      }
    }
    catch {
      $this.EnvManager.WriteError("Failed to fetch release info: $_")
    }
    return ""
  }

  [bool] InstallFromGitHub() {
    $this.EnvManager.WriteInfo("Installing from GitHub releases...")
    
    [string] $downloadUrl = $this.GetLatestReleaseUrl()
    if ([string]::IsNullOrEmpty($downloadUrl)) {
      $this.EnvManager.WriteError("Could not find Windows binary in release")
      return $false
    }

    $this.EnvManager.WriteInfo("Downloading: $downloadUrl")
    
    if (-not (Test-Path $this.InstallDir)) {
      New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
    }

    [string] $exePath = Join-Path $this.InstallDir "postgres-language-server.exe"

    # Backward-compat: if legacy location exists, migrate it to the centralized bin
    [string] $legacyExe = "$env:LOCALAPPDATA\postgres-language-server\postgres-language-server.exe"
    if ((Test-Path $legacyExe -PathType Leaf) -and -not (Test-Path $exePath -PathType Leaf)) {
      try {
        Copy-Item -Path $legacyExe -Destination $exePath -Force
      }
      catch { }
    }
    
    try {
      $previousProgressPreference = (Get-Variable -Name ProgressPreference -ValueOnly)
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $exePath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
      }
      finally {
        $ProgressPreference = $previousProgressPreference
      }

      if (Test-Path $exePath) {
        $this.AddLspToPath()
        $this.EnvManager.WriteSuccess("postgres-language-server installed to: $($this.InstallDir)")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $_")
    }
    
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("postgres-language-server is already installed")
      return 0
    }

    if (-not $this.InstallFromGitHub()) {
      $this.EnvManager.WriteError("Failed to install. Please install manually:")
      $this.EnvManager.WriteError("  Download from: https://github.com/supabase-community/postgres-language-server/releases")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[PostgresLspInstaller] $installer = [PostgresLspInstaller]::new()
exit $installer.Run()
