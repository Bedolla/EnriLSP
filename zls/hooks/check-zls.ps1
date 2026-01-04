#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - ZLS (Zig Language Server) installer
.DESCRIPTION
    Checks for zls installation and auto-installs from GitHub releases.
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
    Write-Host "[$($this.PluginName)] $message" -ForegroundColor Red
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
    if ($oldUserPath -notlike "*$binPath*") {
      [System.Environment]::SetEnvironmentVariable("Path", "$oldUserPath;$binPath", "User")
      $this.WriteInfo("Added to user PATH: $binPath")
    }
  }

  [void] RefreshSessionPath() {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
      [System.Environment]::GetEnvironmentVariable("Path", "User")
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

    $this.EnvManager.WriteInfo("Installing via winget (user scope)...")
    $process = Start-Process -FilePath "winget" -ArgumentList "install", $packageId, "--silent", "--accept-package-agreements", "--accept-source-agreements" -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0) {
      return [PackageManagerResult]::new($true, "Installed successfully", "winget")
    }
    return [PackageManagerResult]::new($false, "Installation failed", "winget")
  }
}

class ZlsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\zls"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\zls\zls.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\zig.zls_*\zls.exe"
  )
  hidden [string] $WingetPackageId = "zig.zls"
  hidden [string] $GitHubReleaseApi = "https://api.github.com/repos/zigtools/zls/releases/latest"

  ZlsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("zls")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    foreach ($path in $this.LspKnownPaths) {
      if ($path -match '\*') {
        $found = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) {
          return $true
        }
      }
      elseif (Test-Path $path -PathType Leaf) {
        return $true
      }
    }
    return $false
  }

  [void] AddLspToPath() {
    foreach ($path in $this.LspKnownPaths) {
      if ($path -match '\*') {
        $found = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) {
          $binDir = Split-Path -Parent $found.FullName
          $this.EnvManager.AddToUserPath($binDir)
          $this.EnvManager.RefreshSessionPath()
          return
        }
      }
      elseif (Test-Path $path -PathType Leaf) {
        $binDir = Split-Path -Parent $path
        $this.EnvManager.AddToUserPath($binDir)
        $this.EnvManager.RefreshSessionPath()
        return
      }
    }
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP" }
      $release = Invoke-RestMethod -Uri $this.GitHubReleaseApi -Headers $headers -ErrorAction Stop
      
      foreach ($asset in $release.assets) {
        if ($asset.name -match "zls.*x86_64-windows\.zip$") {
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
    [string] $downloadUrl = $this.GetLatestReleaseUrl()
    if ([string]::IsNullOrEmpty($downloadUrl)) {
      return $false
    }

    try {
      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      [string] $zipPath = "$env:TEMP\zls.zip"
      $this.EnvManager.WriteInfo("Downloading zls...")
      Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing

      $this.EnvManager.WriteInfo("Extracting...")
      Expand-Archive -Path $zipPath -DestinationPath $this.InstallDir -Force
      Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

      $this.EnvManager.AddToUserPath($this.InstallDir)
      $this.EnvManager.RefreshSessionPath()

      return $true
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $_")
    }
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing zls...")
    
    # PRIMARY: winget
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success) {
      $this.EnvManager.RefreshSessionPath()
      if ($this.IsLspInstalled()) {
        $this.AddLspToPath()
        $this.EnvManager.WriteSuccess("zls installed via winget")
        return $true
      }
    }

    # FALLBACK: GitHub releases
    $this.EnvManager.WriteInfo("Downloading from GitHub...")
    if ($this.InstallFromGitHub() -and $this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("zls installed from GitHub")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install zls")
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("zls is already installed")
      return 0
    }

    $this.InstallLsp()
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[ZlsInstaller] $installer = [ZlsInstaller]::new()
exit $installer.Run()
