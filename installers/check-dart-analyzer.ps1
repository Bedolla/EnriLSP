#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Dart Analyzer Language Server installer
.DESCRIPTION
    Checks for Dart analyzer installation and auto-installs Dart SDK if missing.
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
    $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $found) {
      return $found.FullName
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

  [PackageManagerResult] InstallWithChocolatey([string] $packageName) {
    if (-not $this.EnvManager.IsPackageManagerAvailable("choco")) {
      return [PackageManagerResult]::new($false, "chocolatey not available", "")
    }

    $this.EnvManager.WriteInfo("Installing via Chocolatey...")
    & choco install $packageName -y --limit-output 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via Chocolatey", "choco")
    }
    return [PackageManagerResult]::new($false, "Chocolatey installation failed", "choco")
  }
}

class DartAnalyzerInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Known paths for Dart SDK (winget installs to AppData\Local\Microsoft\WinGet\Packages)
  hidden [string[]] $DartKnownPaths = @(
    "$env:LOCALAPPDATA\Programs\Dart\dart-sdk\bin\dart.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\dart.exe"
  )
  # Wildcard patterns for dynamic Dart detection (winget uses versioned folders)
  hidden [string[]] $DartWildcardPatterns = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.DartSDK*\dart-sdk\bin\dart.exe",
    "C:\tools\dart*\bin\dart.exe",
    "$env:ProgramFiles\Dart\dart-sdk*\bin\dart.exe"
  )
  hidden [string[]] $FlutterKnownPaths = @(
    "$env:LOCALAPPDATA\flutter\bin\flutter.bat",
    "$env:USERPROFILE\flutter\bin\flutter.bat",
    "$env:ProgramFiles\flutter\bin\flutter.bat"
  )
  # Correct winget package ID
  hidden [string] $WingetDartPackageId = "Google.DartSDK"

  DartAnalyzerInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("dart-analyzer")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [string] FindDartExe() {
    # First try known paths
    [string] $found = $this.EnvManager.FindExistingFile($this.DartKnownPaths)
    if (-not [string]::IsNullOrEmpty($found)) {
      return $found
    }
    # Try wildcard patterns
    foreach ($pattern in $this.DartWildcardPatterns) {
      $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $found
      }
    }
    return ""
  }

  [bool] IsDartInstalled() {
    # Check standalone Dart via known paths or wildcards
    [string] $dartPath = $this.FindDartExe()
    if (-not [string]::IsNullOrEmpty($dartPath)) {
      return $true
    }
    
    # Check Flutter (includes Dart)
    foreach ($flutterPath in $this.FlutterKnownPaths) {
      if (Test-Path $flutterPath -PathType Leaf) {
        [string] $flutterBin = Split-Path -Parent $flutterPath
        [string] $dartInFlutter = Join-Path $flutterBin "cache\dart-sdk\bin\dart.exe"
        if (Test-Path $dartInFlutter -PathType Leaf) {
          return $true
        }
      }
    }
    
    return $false
  }

  [void] AddDartToPath() {
    # Check standalone Dart first (using FindDartExe for wildcards)
    [string] $foundPath = $this.FindDartExe()
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
      return
    }
    
    # Check Flutter Dart
    foreach ($flutterPath in $this.FlutterKnownPaths) {
      if (Test-Path $flutterPath -PathType Leaf) {
        [string] $flutterBin = Split-Path -Parent $flutterPath
        [string] $dartBin = Join-Path $flutterBin "cache\dart-sdk\bin"
        if (Test-Path $dartBin) {
          $this.EnvManager.AddToUserPath($flutterBin)
          $this.EnvManager.AddToUserPath($dartBin)
          $this.EnvManager.RefreshSessionPath()
          return
        }
      }
    }
  }

  [bool] InstallDart() {
    $this.EnvManager.WriteInfo("Dart SDK is not installed. Attempting to install...")

    # PRIMARY: winget (Google.DartSDK is the correct package)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetDartPackageId)
    if ($wingetResult.Success -and $this.IsDartInstalled()) {
      $this.AddDartToPath()
      $this.EnvManager.WriteSuccess("Dart SDK installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Dart SDK. Please install manually:")
    $this.EnvManager.WriteError("  winget install Google.DartSDK")
    $this.EnvManager.WriteError("  Or install Flutter (includes Dart): winget install Google.Flutter")
    return $false
  }

  [int] Run() {
    # Check if Dart is already available (standalone or via Flutter)
    if ($this.IsDartInstalled()) {
      # Always ensure it's in PATH
      $this.AddDartToPath()
      $this.EnvManager.WriteSuccess("dart analyzer is already installed")
      return 0
    }

    # Install Dart SDK
    [bool] $dartInstalled = $this.InstallDart()
    if (-not $dartInstalled) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[DartAnalyzerInstaller] $installer = [DartAnalyzerInstaller]::new()
exit $installer.Run()
