#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Kotlin Language Server installer
.DESCRIPTION
    Checks for kotlin-language-server installation and auto-installs Java 11+ runtime if missing.
    Uses OOP patterns with explicit types. Verifies by file path, not PATH env.
.NOTES
    Author: Bedolla
    License: MIT
    Requirements: Java 11+ (auto-installed if missing)
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
    # Use Get-ChildItem with wildcard pattern to find files
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

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via Chocolatey", "choco")
    }
    return [PackageManagerResult]::new($false, "Chocolatey installation failed", "choco")
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

class KotlinLsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [JavaVersionChecker] $JavaChecker
  # Kotlin LS requires Java 11+ but we install the LATEST (OpenJDK 25)
  hidden [int] $MinJavaVersion = 11
  hidden [string] $ManualInstallPath = "$env:LOCALAPPDATA\kotlin-language-server"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\kotlin-language-server\bin\kotlin-language-server.bat",
    "$env:LOCALAPPDATA\kotlin-language-server\server\bin\kotlin-language-server.bat"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "C:\Program Files\Microsoft\jdk-25*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-24*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-21*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-17*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-24*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-21*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-17*\bin\java.exe"
  )
  # Wildcard patterns for dynamic Java version detection (prioritize newer versions)
  hidden [string[]] $RuntimeWildcardPatterns = @(
    "C:\Program Files\Microsoft\jdk-25*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-24*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-21*\bin\java.exe",
    "C:\Program Files\Microsoft\jdk-17*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-25*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-24*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-21*\bin\java.exe",
    "C:\Program Files\Eclipse Adoptium\jdk-17*\bin\java.exe",
    "C:\Program Files\Java\jdk-25*\bin\java.exe",
    "C:\Program Files\Java\jdk-24*\bin\java.exe"
  )
  # Install LATEST Microsoft Build of OpenJDK 25 (official, secure)
  hidden [string] $WingetJavaPackageId = "Microsoft.OpenJDK.25"

  KotlinLsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("kotlin-language-server")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
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
    return $this.JavaChecker.FindJavaExe()
  }

  [bool] IsRuntimeVersionValid() {
    return $this.JavaChecker.MeetsMinimumVersion()
  }

  [void] AddLspToPath() {
    # Check which path has kotlin-language-server and add it
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.LspKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
    }
    elseif (Test-Path "$($this.ManualInstallPath)\bin") {
      $this.EnvManager.AddToUserPath("$($this.ManualInstallPath)\bin")
    }
    elseif (Test-Path "$($this.ManualInstallPath)\server\bin") {
      $this.EnvManager.AddToUserPath("$($this.ManualInstallPath)\server\bin")
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
      $this.EnvManager.WriteInfo("Java is not installed. Attempting to install Java $($this.MinJavaVersion)+...")
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

    $this.EnvManager.WriteError("Could not auto-install Java $($this.MinJavaVersion)+. Please install manually:")
    $this.EnvManager.WriteError("  winget install Microsoft.OpenJDK.25")
    $this.EnvManager.WriteError("  Or run: winget install EclipseAdoptium.Temurin.17.JDK")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing kotlin-language-server...")
    
    # Download directly from GitHub
    $this.EnvManager.WriteInfo("Downloading from GitHub...")
    [bool] $downloaded = $this.DownloadKotlinLs()
    if ($downloaded -and $this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("kotlin-language-server installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install kotlin-language-server. Please install manually:")
    $this.EnvManager.WriteError("  Download from https://github.com/fwcd/kotlin-language-server/releases")
    return $false
  }

  [bool] DownloadKotlinLs() {
    try {
      [string] $installDir = "$env:LOCALAPPDATA\kotlin-language-server"
      [string] $binDir = "$installDir\server\bin"
      
      # Create directory
      if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
      }
      
      # Download latest release from GitHub
      [string] $downloadUrl = "https://github.com/fwcd/kotlin-language-server/releases/latest/download/server.zip"
      [string] $tempFile = "$env:TEMP\kotlin-ls.zip"
      
      $this.EnvManager.WriteInfo("Downloading kotlin-language-server from GitHub...")
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 120
      
      # Extract (creates server/ subfolder)
      $this.EnvManager.WriteInfo("Extracting kotlin-language-server...")
      Expand-Archive -Path $tempFile -DestinationPath $installDir -Force
      
      # Clean up
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
      
      # Add to PATH (the zip extracts to server/bin)
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
      
      return (Test-Path "$binDir\kotlin-language-server.bat")
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $($_.Exception.Message)")
      return $false
    }
  }

  [int] Run() {
    # ALWAYS check if Java is installed with correct version first (required for kotlin-ls)
    if (-not $this.IsRuntimeInstalled() -or -not $this.IsRuntimeVersionValid()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
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
      $this.EnvManager.WriteSuccess("kotlin-language-server is already installed")
      return 0
    }

    # Install LSP
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

[KotlinLsInstaller] $installer = [KotlinLsInstaller]::new()
exit $installer.Run()
