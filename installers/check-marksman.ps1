#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Marksman (Markdown LSP) installer
.DESCRIPTION
    Checks for marksman installation and auto-installs from GitHub releases if missing.
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

  [string] FindExistingFile([string[]] $paths) {
    foreach ($path in $paths) {
      if (Test-Path $path -PathType Leaf) {
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

class PackageInstaller {
  hidden [EnvironmentManager] $EnvManager

  PackageInstaller([EnvironmentManager] $envManager) {
    $this.EnvManager = $envManager
  }

  [PackageManagerResult] InstallWithWinget([string] $packageId) {
    if (-not $this.EnvManager.IsPackageManagerAvailable("winget")) {
      return [PackageManagerResult]::new($false, "winget not available", "")
    }

    $this.EnvManager.WriteInfo("Installing via winget...")
    & winget install $packageId --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed successfully", "winget")
    }
    return [PackageManagerResult]::new($false, "Installation failed", "winget")
  }
}

class MarksmanInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Centralized bin directory for EnriLSP-installed executables
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string[]] $LspKnownPaths = @(
    # Preferred centralized location
    "$env:LOCALAPPDATA\EnriLSP\bin\marksman.exe",

    # Legacy locations (kept for compatibility)
    "$env:LOCALAPPDATA\marksman\marksman.exe",
    "$env:LOCALAPPDATA\Programs\marksman\marksman.exe",
    "C:\Program Files\marksman\marksman.exe"
  )
  hidden [string] $GitHubApiUrl = "https://api.github.com/repos/artempyanykh/marksman/releases/latest"

  MarksmanInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("marksman")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [void] AddLspToPath() {
    # Prefer the centralized bin directory to minimize PATH entries
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP-Installer" }
      $release = Invoke-RestMethod -Uri $this.GitHubApiUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
      
      foreach ($asset in $release.assets) {
        if ($asset.name -like "*windows*" -and $asset.name -like "*x64*" -and $asset.name -like "*.exe") {
          return $asset.browser_download_url
        }
        if ($asset.name -eq "marksman-windows-x64.exe" -or $asset.name -eq "marksman.exe") {
          return $asset.browser_download_url
        }
      }
      
      foreach ($asset in $release.assets) {
        if ($asset.name -like "*windows*" -and $asset.name -like "*.exe") {
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

    [string] $exePath = Join-Path $this.InstallDir "marksman.exe"

    # Backward-compat: if legacy location exists, migrate it to the centralized bin
    [string] $legacyExe = "$env:LOCALAPPDATA\marksman\marksman.exe"
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
        $this.EnvManager.WriteSuccess("marksman installed to: $exePath")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $_")
    }
    
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("marksman is not installed. Attempting to install...")

    [bool] $githubInstalled = $this.InstallFromGitHub()
    if ($githubInstalled) {
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install marksman. Please install manually:")
    $this.EnvManager.WriteError("  Download from: https://github.com/artempyanykh/marksman/releases")
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("marksman is already installed")
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

[MarksmanInstaller] $installer = [MarksmanInstaller]::new()
exit $installer.Run()
