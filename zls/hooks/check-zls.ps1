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

class ZlsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Centralized bin directory for EnriLSP-installed executables
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string[]] $LspKnownPaths = @(
    # Preferred centralized location
    "$env:LOCALAPPDATA\EnriLSP\bin\zls.exe",

    # Legacy location (kept for compatibility)
    "$env:LOCALAPPDATA\zls\zls.exe",

    # Other possible locations (winget)
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\zls.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\zig.zls_*\zls.exe"
  )
  hidden [string] $WingetPackageId = "zig.zls"
  hidden [string] $GitHubReleaseApi = "https://api.github.com/repos/zigtools/zls/releases/latest"
  hidden [string] $ProxySourcePath
  hidden [string] $ProxyDestDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string] $ProxyDestPath = "$env:LOCALAPPDATA\EnriLSP\bin\enrilsp-lsp-proxy.ps1"

  ZlsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("zls")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    $this.ProxySourcePath = Join-Path $PSScriptRoot "enrilsp-lsp-proxy.ps1"
  }

  [bool] EnsureProxyInstalled() {
    try {
      if (-not (Test-Path $this.ProxyDestDir)) {
        New-Item -ItemType Directory -Path $this.ProxyDestDir -Force | Out-Null
      }

      if (Test-Path $this.ProxySourcePath -PathType Leaf) {
        Copy-Item -Path $this.ProxySourcePath -Destination $this.ProxyDestPath -Force
        return (Test-Path $this.ProxyDestPath -PathType Leaf)
      }

      $this.EnvManager.WriteError("Proxy source not found: $($this.ProxySourcePath)")
      return $false
    }
    catch {
      $this.EnvManager.WriteError("Failed to install EnriLSP proxy: $($_.Exception.Message)")
      return $false
    }
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

  [string] FindInstalledExe() {
    foreach ($path in $this.LspKnownPaths) {
      if ($path -match '\*') {
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

  [bool] EnsureStableInstall() {
    try {
      [string] $target = Join-Path $this.InstallDir "zls.exe"
      if (Test-Path $target -PathType Leaf) {
        return $true
      }

      # Backward-compat: if legacy install exists, migrate it to the centralized bin
      [string] $legacyExe = "$env:LOCALAPPDATA\zls\zls.exe"
      if ((Test-Path $legacyExe -PathType Leaf) -and -not (Test-Path $target -PathType Leaf)) {
        try {
          if (-not (Test-Path $this.InstallDir)) {
            New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
          }
          Copy-Item -Path $legacyExe -Destination $target -Force
        }
        catch { }

        if (Test-Path $target -PathType Leaf) {
          return $true
        }
      }

      [string] $found = $this.FindInstalledExe()
      if ([string]::IsNullOrWhiteSpace($found)) {
        $this.EnvManager.WriteError("zls executable not found after install")
        return $false
      }

      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      Copy-Item -Path $found -Destination $target -Force
      return (Test-Path $target -PathType Leaf)
    }
    catch {
      $this.EnvManager.WriteError("Failed to ensure stable zls install: $($_.Exception.Message)")
      return $false
    }
  }

  [void] AddLspToPath() {
    # Prefer the centralized bin directory to minimize PATH entries.
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP" }
      $release = Invoke-RestMethod -Uri $this.GitHubReleaseApi -Headers $headers -TimeoutSec 30 -ErrorAction Stop
      
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
      Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop

      $this.EnvManager.WriteInfo("Extracting...")
      Expand-Archive -Path $zipPath -DestinationPath $this.InstallDir -Force

      # Some zips include a folder; if zls.exe isn't at root, try to locate it and move it
      [string] $expected = Join-Path $this.InstallDir "zls.exe"
      if (-not (Test-Path $expected -PathType Leaf)) {
        $foundExe = Get-ChildItem -Path $this.InstallDir -Recurse -Filter "zls.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $foundExe) {
          Copy-Item -Path $foundExe.FullName -Destination $expected -Force
        }
      }

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
    if (-not $this.EnsureProxyInstalled()) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      if (-not $this.EnsureStableInstall()) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
      $this.EnvManager.WriteSuccess("zls is already installed")
      return 0
    }

    [bool] $lspInstalled = $this.InstallLsp()
    if (-not $lspInstalled) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    if (-not $this.EnsureStableInstall()) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[ZlsInstaller] $installer = [ZlsInstaller]::new()
exit $installer.Run()
