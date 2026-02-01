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
  hidden [string] $InstallRoot = "$env:LOCALAPPDATA\EnriLSP\jdtls"
  hidden [string] $LegacyInstallRoot = "$env:LOCALAPPDATA\jdtls"
  hidden [string] $ManualInstallPath = "$env:LOCALAPPDATA\EnriLSP\jdtls\bin"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\EnriLSP\jdtls\bin\jdtls.bat",
    "$env:LOCALAPPDATA\EnriLSP\jdtls\bin\jdtls"
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
  hidden [string] $ProxySourcePath
  hidden [string] $ProxyDestDir = "$env:LOCALAPPDATA\EnriLSP\bin"
  hidden [string] $ProxyDestPath = "$env:LOCALAPPDATA\EnriLSP\bin\enrilsp-lsp-proxy.ps1"

  JdtlsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("jdtls")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    # Pass wildcard patterns to JavaVersionChecker
    $this.JavaChecker = [JavaVersionChecker]::new($this.MinJavaVersion, $this.RuntimeKnownPaths, $this.RuntimeWildcardPatterns, $this.EnvManager)
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

  [void] MigrateLegacyInstallIfNeeded() {
    try {
      if ($this.LegacyInstallRoot -eq $this.InstallRoot) {
        return
      }

      if ((Test-Path $this.LegacyInstallRoot) -and -not (Test-Path $this.InstallRoot)) {
        [string] $parent = Split-Path -Parent $this.InstallRoot
        if (-not (Test-Path $parent)) {
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $this.EnvManager.WriteInfo("Migrating legacy jdtls install to: $($this.InstallRoot)")
        Move-Item -Path $this.LegacyInstallRoot -Destination $this.InstallRoot -Force
      }
    }
    catch {
      $this.EnvManager.WriteWarning("Could not migrate legacy jdtls install (continuing): $($_.Exception.Message)")
    }
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
    $this.EnvManager.WriteError("  winget install Microsoft.OpenJDK.25")
    $this.EnvManager.WriteError("  Or run: winget install EclipseAdoptium.Temurin.21.JDK")
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
    $this.EnvManager.WriteError("  Download from https://download.eclipse.org/jdtls/milestones/")
    return $false
  }

  [bool] DownloadJdtls() {
    try {
      [string] $jdtlsDir = $this.InstallRoot
      [string] $jdtlsBin = "$jdtlsDir\bin"

      # Create directory
      if (-not (Test-Path $jdtlsDir)) {
        New-Item -ItemType Directory -Path $jdtlsDir -Force | Out-Null
      }

      # Fetch the latest version from Eclipse milestones directory
      $this.EnvManager.WriteInfo("Fetching latest jdtls version from Eclipse...")
      [string] $milestonesPage = "https://download.eclipse.org/jdtls/milestones/"
      [string] $pageContent = (Invoke-WebRequest -Uri $milestonesPage -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content

      # Extract version numbers (format: 1.XX.X) and find the latest
      [regex] $versionPattern = '(1\.\d+\.\d+)'
      $versionMatches = $versionPattern.Matches($pageContent)
      [string[]] $versions = $versionMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique { [version]$_ } -Descending

      if ($null -eq $versions -or $versions.Count -eq 0) {
        $this.EnvManager.WriteWarning("Could not detect latest version, using fallback 1.55.0")
        [string] $latestVersion = "1.55.0"
      }
      else {
        [string] $latestVersion = $versions[0]
        if ([string]::IsNullOrEmpty($latestVersion)) {
          $this.EnvManager.WriteWarning("Could not detect latest version, using fallback 1.55.0")
          $latestVersion = "1.55.0"
        }
      }

      $this.EnvManager.WriteInfo("Latest jdtls version: $latestVersion")

      # List the version folder to find the exact tar.gz filename
      [string] $versionFolder = "https://download.eclipse.org/jdtls/milestones/$latestVersion/"
      [string] $folderContent = (Invoke-WebRequest -Uri $versionFolder -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content

      # Extract tar.gz filename (format: jdt-language-server-X.XX.X-YYYYMMDDHHSS.tar.gz)
      [regex] $tarPattern = '(jdt-language-server-[\d\.]+-\d+\.tar\.gz)'
      $tarMatch = $tarPattern.Match($folderContent)

      if (-not $tarMatch.Success) {
        $this.EnvManager.WriteError("Could not find tar.gz file in version folder")
        return $false
      }

      [string] $tarFilename = $tarMatch.Groups[1].Value
      [string] $downloadUrl = "https://www.eclipse.org/downloads/download.php?file=/jdtls/milestones/$latestVersion/$tarFilename&r=1"
      [string] $tempFile = "$env:TEMP\jdtls.tar.gz"

      $this.EnvManager.WriteInfo("Downloading jdtls $latestVersion from Eclipse...")
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop

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
    if (-not $this.EnsureProxyInstalled()) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    $this.MigrateLegacyInstallIfNeeded()

    # ALWAYS check if Java is installed with correct version first (required for jdtls)
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
      $this.EnvManager.WriteSuccess("jdtls is already installed")
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

[JdtlsInstaller] $installer = [JdtlsInstaller]::new()
exit $installer.Run()
