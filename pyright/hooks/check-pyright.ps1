#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Pyright Language Server installer
.DESCRIPTION
    Checks for pyright installation and auto-installs Python runtime and pyright if missing.
    Uses OOP patterns with explicit types. Verifies by file path, not PATH env.
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
      # If path contains wildcard, resolve it first
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

  [string] FindWithWildcard([string] $pattern) {
    # Use Get-ChildItem with wildcard pattern to find files
    $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $found) {
      return $found.FullName
    }
    return ""
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

  [PackageManagerResult] InstallWithChocolatey([string] $packageName) {
    if (-not $this.EnvManager.IsPackageManagerAvailable("choco")) {
      return [PackageManagerResult]::new($false, "chocolatey not available", "")
    }

    $this.EnvManager.WriteInfo("Installing via Chocolatey...")
    & choco install $packageName -y --limit-output 2>&1 | Out-Null

    return [PackageManagerResult]::new($true, "Installed via Chocolatey", "choco")
  }

  [PackageManagerResult] InstallWithPip([string] $packageName) {
    $this.EnvManager.WriteInfo("Installing via pip...")
    & pip install $packageName 2>&1 | Out-Null

    return [PackageManagerResult]::new($true, "Installed via pip", "pip")
  }
}

class PyrightInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string[]] $LspKnownPaths = @(
    "$env:APPDATA\Python\Python314\Scripts\pyright.exe",
    "$env:APPDATA\Python\Python313\Scripts\pyright.exe",
    "$env:APPDATA\Python\Python312\Scripts\pyright.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python314\Scripts\pyright.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\Scripts\pyright.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts\pyright.exe",
    "C:\Python314\Scripts\pyright.exe",
    "C:\Python313\Scripts\pyright.exe",
    "C:\Program Files\Python314\Scripts\pyright.exe"
  )
  # Wildcard patterns for dynamic LSP detection
  hidden [string[]] $LspWildcardPatterns = @(
    "$env:APPDATA\Python\Python3*\Scripts\pyright.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python3*\Scripts\pyright.exe",
    "C:\Python3*\Scripts\pyright.exe",
    "C:\Program Files\Python3*\Scripts\pyright.exe"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "C:\Python314\python.exe",
    "C:\Python313\python.exe",
    "C:\Program Files\Python314\python.exe",
    "C:\Program Files\Python313\python.exe"
  )
  # Wildcard patterns for dynamic version detection
  hidden [string[]] $RuntimeWildcardPatterns = @(
    "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
    "C:\Python3*\python.exe",
    "C:\Program Files\Python3*\python.exe"
  )
  # Python 3.14 is the latest stable version (Dec 2025)
  hidden [string] $WingetPackageId = "Python.Python.3.14"

  PyrightInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("pyright")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    if ($this.EnvManager.AnyFileExists($this.LspKnownPaths)) {
      return $true
    }
    foreach ($pattern in $this.LspWildcardPatterns) {
      [string] $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $true
      }
    }
    return $false
  }

  [string] FindPyrightExe() {
    [string] $found = $this.EnvManager.FindExistingFile($this.LspKnownPaths)
    if (-not [string]::IsNullOrEmpty($found)) {
      return $found
    }
    foreach ($pattern in $this.LspWildcardPatterns) {
      $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $found
      }
    }
    return ""
  }

  [bool] IsRuntimeInstalled() {
    if ($this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)) {
      return $true
    }
    # Try wildcard search
    foreach ($pattern in $this.RuntimeWildcardPatterns) {
      [string] $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $true
      }
    }
    return $false
  }

  [string] FindPythonExe() {
    # First try known paths
    [string] $found = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($found)) {
      return $found
    }
    # Then try wildcard patterns
    foreach ($pattern in $this.RuntimeWildcardPatterns) {
      $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $found
      }
    }
    return ""
  }

  [void] AddLspToPath() {
    [string] $foundPath = $this.FindPyrightExe()
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [void] AddRuntimeToPath() {
    [string] $foundPath = $this.FindPythonExe()
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      # Also add Scripts folder
      [string] $scriptsDir = Join-Path $binDir "Scripts"
      if (Test-Path $scriptsDir -PathType Container) {
        $this.EnvManager.AddToUserPath($scriptsDir)
      }
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallRuntime() {
    $this.EnvManager.WriteInfo("Python/pip is not installed. Attempting to install...")

    # PRIMARY: winget (cleanest installation)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeInstalled()) {
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess("Python installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Python. Please install manually:")
    $this.EnvManager.WriteInfo("  winget install Python.Python.3.14")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing pyright...")
    
    # Find python executable and use it directly with -m pip
    [string] $pythonExe = $this.FindPythonExe()
    if (-not [string]::IsNullOrEmpty($pythonExe)) {
      $this.EnvManager.WriteInfo("Installing via pip...")
      & $pythonExe -m pip install pyright 2>&1 | Out-Null
    }

    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("pyright installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install pyright. Please run manually:")
    $this.EnvManager.WriteInfo("  pip install pyright")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("pyright is already installed")
      return 0
    }

    # Check if runtime is installed, if not install it
    if (-not $this.IsRuntimeInstalled()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        return 0
      }
    }

    # Install LSP
    $this.InstallLsp()
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[PyrightInstaller] $installer = [PyrightInstaller]::new()
exit $installer.Run()
