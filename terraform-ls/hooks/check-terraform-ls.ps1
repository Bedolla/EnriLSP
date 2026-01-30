#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Terraform Language Server installer
.DESCRIPTION
    Checks for terraform-ls installation and auto-installs via winget or direct download.
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

class TerraformLsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Centralized bin directory for EnriLSP-installed executables
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string[]] $LspKnownPaths = @(
    # Preferred centralized location
    "$env:LOCALAPPDATA\EnriLSP\bin\terraform-ls.exe",

    # Legacy location (kept for compatibility)
    "$env:LOCALAPPDATA\terraform-ls\terraform-ls.exe",

    # Other possible locations (winget, program files)
    "C:\Program Files\terraform-ls\terraform-ls.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform-ls.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform-LS_*\terraform-ls.exe"
  )
  hidden [string] $WingetPackageId = "Hashicorp.Terraform-LS"
  hidden [string] $ProxySourcePath
  hidden [string] $ProxyDestDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string] $ProxyDestPath = "$env:LOCALAPPDATA\EnriLSP\bin\enrilsp-lsp-proxy.ps1"

  TerraformLsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("terraform-ls")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    $this.ProxySourcePath = Join-Path $PSScriptRoot "enrilsp-lsp-proxy.ps1"
  }

  [bool] IsLspInstalled() {
    # Check paths with wildcards
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
      [string] $target = Join-Path $this.InstallDir "terraform-ls.exe"
      if (Test-Path $target -PathType Leaf) {
        return $true
      }

      # Backward-compat: if legacy install exists, migrate it to the centralized bin
      [string] $legacyExe = "$env:LOCALAPPDATA\terraform-ls\terraform-ls.exe"
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
        $this.EnvManager.WriteError("terraform-ls executable not found after install")
        return $false
      }

      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      Copy-Item -Path $found -Destination $target -Force
      return (Test-Path $target -PathType Leaf)
    }
    catch {
      $this.EnvManager.WriteError("Failed to ensure stable terraform-ls install: $($_.Exception.Message)")
      return $false
    }
  }

  [void] AddLspToPath() {
    # Prefer the centralized bin directory to minimize PATH entries.
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestVersion() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest version from HashiCorp...")
      $versionsUrl = "https://checkpoint-api.hashicorp.com/v1/check/terraform-ls"
      $versionInfo = Invoke-RestMethod -Uri $versionsUrl -TimeoutSec 30 -ErrorAction Stop
      return $versionInfo.current_version
    }
    catch {
      $this.EnvManager.WriteError("Failed to fetch version info: $_")
    }
    return "0.38.3"  # Fallback to known working version
  }

  [bool] InstallFromHashiCorp() {
    [string] $version = $this.GetLatestVersion()
    [string] $downloadUrl = "https://releases.hashicorp.com/terraform-ls/$version/terraform-ls_${version}_windows_amd64.zip"

    try {
      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      [string] $zipPath = "$env:TEMP\terraform-ls.zip"
      $this.EnvManager.WriteInfo("Downloading terraform-ls v$version...")
      $previousProgressPreference = (Get-Variable -Name ProgressPreference -ValueOnly)
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
      }
      finally {
        $ProgressPreference = $previousProgressPreference
      }

      $this.EnvManager.WriteInfo("Extracting...")
      Expand-Archive -Path $zipPath -DestinationPath $this.InstallDir -Force

      # Some zips include a folder; if terraform-ls.exe isn't at root, try to locate it and move it
      [string] $expected = Join-Path $this.InstallDir "terraform-ls.exe"
      if (-not (Test-Path $expected -PathType Leaf)) {
        $foundExe = Get-ChildItem -Path $this.InstallDir -Recurse -Filter "terraform-ls.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
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
    $this.EnvManager.WriteInfo("Installing terraform-ls...")
    
    # PRIMARY: winget
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success) {
      $this.EnvManager.RefreshSessionPath()
      if ($this.IsLspInstalled()) {
        $this.AddLspToPath()
        $this.EnvManager.WriteSuccess("terraform-ls installed via winget")
        return $true
      }
    }

    # FALLBACK: HashiCorp releases
    $this.EnvManager.WriteInfo("Downloading from HashiCorp releases...")
    if ($this.InstallFromHashiCorp() -and $this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("terraform-ls installed from HashiCorp")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install terraform-ls")
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
      $this.EnvManager.WriteSuccess("terraform-ls is already installed")
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

[TerraformLsInstaller] $installer = [TerraformLsInstaller]::new()
exit $installer.Run()
