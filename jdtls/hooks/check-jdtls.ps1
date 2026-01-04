#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - JDTLS (Java) Language Server installer
.DESCRIPTION
    Checks for jdtls installation and auto-installs Java 21+ runtime and jdtls if missing.
    Uses OOP patterns with explicit types. Verifies by file path, not PATH env.
.NOTES
    Author: Bedolla
    License: MIT
    Requirements: Java 21+ (auto-installed if missing)
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
}

class JavaVersionChecker {
  hidden [int] $MinimumVersion
  hidden [string[]] $JavaPaths
  hidden [string[]] $WildcardPatterns
  hidden [EnvironmentManager] $EnvManager

  JavaVersionChecker([int] $minimumVersion, [string[]] $javaPaths, [string[]] $wildcardPatterns, [EnvironmentManager] $envManager) {
    $this.MinimumVersion = $minimumVersion
    $this.JavaPaths = $javaPaths
    $this.WildcardPatterns = $wildcardPatterns
    $this.EnvManager = $envManager
  }

  [string] FindJavaExe() {
    # First try wildcard patterns (finds latest installed versions)
    foreach ($pattern in $this.WildcardPatterns) {
      [string] $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $found
      }
    }
    # Then try known paths (fallback)
    foreach ($javaPath in $this.JavaPaths) {
      if (Test-Path $javaPath -PathType Leaf) {
        return $javaPath
      }
    }
    return ""
  }

  [int] GetInstalledVersion() {
    [string] $javaPath = $this.FindJavaExe()
    if (-not [string]::IsNullOrEmpty($javaPath)) {
      try {
        [string] $output = & $javaPath -version 2>&1 | Out-String
        [regex] $pattern = 'version "(\d+)'
        [System.Text.RegularExpressions.Match] $match = $pattern.Match($output)
        
        if ($match.Success) {
          return [int]$match.Groups[1].Value
        }
      }
      catch {
        # Ignore errors
      }
    }
    return 0
  }

  [bool] MeetsMinimumVersion() {
    [int] $version = $this.GetInstalledVersion()
    return ($version -ge $this.MinimumVersion)
  }
}

class JdtlsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [JavaVersionChecker] $JavaChecker
  # jdtls requires Java 21+ but we install the LATEST (OpenJDK 25)
  hidden [int] $MinJavaVersion = 21
  hidden [string] $ManualInstallPath = "$env:LOCALAPPDATA\jdtls\bin"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\jdtls\bin\jdtls.bat",
    "$env:LOCALAPPDATA\jdtls\bin\jdtls"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "C:\Program Files\Microsoft\jdk-25*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-24*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-21*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-24*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-21*\bin\java.exe"
  )
  # Wildcard patterns for dynamic Java version detection (prioritize newer versions)
  hidden [string[]] $RuntimeWildcardPatterns = @(
    "C:\Program Files\Microsoft\jdk-25*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-24*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-21*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-24*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-23*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-21*\bin\java.exe",
    "C:\Program Files\Java\jdk-25*\bin\java.exe",
    "C:\Program Files\Java\jdk-24*\bin\java.exe"
  )
  # Install LATEST Microsoft Build of OpenJDK 25 (official, secure)
  hidden [string] $WingetJavaPackageId = "Microsoft.OpenJDK.25"

  JdtlsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("jdtls")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    # Pass wildcard patterns to JavaVersionChecker
    $this.JavaChecker = [JavaVersionChecker]::new($this.MinJavaVersion, $this.RuntimeKnownPaths, $this.RuntimeWildcardPatterns, $this.EnvManager)
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [bool] IsRuntimeInstalled() {
    if ($this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)) {
      return $true
    }
    foreach ($pattern in $this.RuntimeWildcardPatterns) {
      [string] $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $true
      }
    }
    return $false
  }

  [string] FindJavaExe() {
    [string] $found = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($found)) {
      return $found
    }
    foreach ($pattern in $this.RuntimeWildcardPatterns) {
      $found = $this.EnvManager.FindWithWildcard($pattern)
      if (-not [string]::IsNullOrEmpty($found)) {
        return $found
      }
    }
    return ""
  }

  [bool] IsRuntimeVersionValid() {
    return $this.JavaChecker.MeetsMinimumVersion()
  }

  [void] AddLspToPath() {
    # Check which path has jdtls and add it
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.LspKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
    }
    elseif (Test-Path $this.ManualInstallPath) {
      $this.EnvManager.AddToUserPath($this.ManualInstallPath)
    }
    $this.EnvManager.RefreshSessionPath()
  }

  [void] AddRuntimeToPath() {
    [string] $foundPath = $this.FindJavaExe()
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallRuntime() {
    [int] $currentVersion = $this.JavaChecker.GetInstalledVersion()
    
    if ($currentVersion -eq 0) {
      $this.EnvManager.WriteInfo("Java is not installed. Attempting to install Java $($this.MinJavaVersion)...")
    }
    else {
      $this.EnvManager.WriteWarning("Java $currentVersion found, but Java $($this.MinJavaVersion)+ is required. Installing...")
    }

    # PRIMARY: winget (Microsoft OpenJDK 25 - official, secure)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetJavaPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeVersionValid()) {
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess("Java 25 installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Java 21+. Please install manually:")
    $this.EnvManager.WriteInfo("  winget install Microsoft.OpenJDK.25")
    $this.EnvManager.WriteInfo("  Or run: winget install EclipseAdoptium.Temurin.21.JDK")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing jdtls...")
    
    # Download directly from Eclipse
    $this.EnvManager.WriteInfo("Downloading from Eclipse...")
    [bool] $downloaded = $this.DownloadJdtls()
    if ($downloaded -and $this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("jdtls installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install jdtls. Please install manually:")
    $this.EnvManager.WriteInfo("  Download from https://download.eclipse.org/jdtls/milestones/")
    return $false
  }

  [bool] DownloadJdtls() {
    try {
      [string] $jdtlsDir = "$env:LOCALAPPDATA\jdtls"
      [string] $jdtlsBin = "$jdtlsDir\bin"
      
      # Create directory
      if (-not (Test-Path $jdtlsDir)) {
        New-Item -ItemType Directory -Path $jdtlsDir -Force | Out-Null
      }
      
      # Download latest milestone (1.54.0 as of Jan 2026)
      # Use Eclipse mirror redirect for automatic mirror selection
      [string] $downloadUrl = "https://www.eclipse.org/downloads/download.php?file=/jdtls/milestones/1.54.0/jdt-language-server-1.54.0-202511261751.tar.gz&r=1"
      [string] $tempFile = "$env:TEMP\jdtls.tar.gz"
      
      $this.EnvManager.WriteInfo("Downloading jdtls from Eclipse...")
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing
      
      # Extract using tar (available in Windows 10+)
      $this.EnvManager.WriteInfo("Extracting jdtls...")
      & tar -xzf $tempFile -C $jdtlsDir 2>&1 | Out-Null
      
      # Clean up
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
      
      # Add to PATH
      $this.EnvManager.AddToUserPath($jdtlsBin)
      $this.EnvManager.RefreshSessionPath()
      
      # Update known paths to include this location
      return (Test-Path "$jdtlsBin\jdtls.bat") -or (Test-Path "$jdtlsDir\bin\jdtls")
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $($_.Exception.Message)")
      return $false
    }
  }

  [int] Run() {
    # ALWAYS check if Java is installed with correct version first (required for jdtls)
    if (-not $this.IsRuntimeInstalled() -or -not $this.IsRuntimeVersionValid()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        return 0
      }
    }
    else {
      # Ensure Java is in PATH even if already installed
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess("Java runtime detected")
    }

    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("jdtls is already installed")
      return 0
    }

    # Install LSP
    $this.InstallLsp()
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[JdtlsInstaller] $installer = [JdtlsInstaller]::new()
exit $installer.Run()
