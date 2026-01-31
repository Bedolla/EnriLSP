#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Solargraph (Ruby) Language Server installer
.DESCRIPTION
    Checks for solargraph installation and auto-installs Ruby runtime if missing.
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

  [PackageManagerResult] InstallWithGem([string] $gemName) {
    $this.EnvManager.WriteInfo("Installing via gem...")
    
    # Try to find gem.cmd in known locations (AppData first, then legacy)
    [string[]] $gemPaths = @(
      "$env:LOCALAPPDATA\Ruby\bin\gem.cmd",
      "C:\Ruby34-x64\bin\gem.cmd",
      "C:\Ruby33-x64\bin\gem.cmd"
    )
    
    [string] $gemExe = "gem"
    foreach ($path in $gemPaths) {
      if (Test-Path $path) {
        $gemExe = $path
        break
      }
    }
    
    & $gemExe install $gemName --no-document 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via gem", "gem")
    }
    return [PackageManagerResult]::new($false, "gem installation failed", "gem")
  }
}

class SolargraphInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Ruby installed to AppData (clean location)
  hidden [string] $RubyInstallDir = "$env:LOCALAPPDATA\Ruby"
  hidden [string] $RubyBinDir = "$env:LOCALAPPDATA\Ruby\bin"
  # Known paths for solargraph (AppData first, then legacy locations)
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\Ruby\bin\solargraph.bat",
    "$env:LOCALAPPDATA\Ruby\bin\solargraph.cmd",
    "C:\Ruby34-x64\bin\solargraph.bat",
    "C:\Ruby33-x64\bin\solargraph.bat"
  )
  # Known paths for Ruby runtime (AppData first, then legacy)
  hidden [string[]] $RuntimeKnownPaths = @(
    "$env:LOCALAPPDATA\Ruby\bin\gem.cmd",
    "C:\Ruby34-x64\bin\gem.cmd",
    "C:\Ruby33-x64\bin\gem.cmd"
  )
  # RubyInstaller download URL (Ruby 3.4.x recommended for maximum gem compatibility)
  # Ruby 4.0 exists but 3.4.x is recommended by RubyInstaller for stability
  hidden [string] $RubyInstallerUrl = "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-3.4.8-1/rubyinstaller-devkit-3.4.8-1-x64.exe"
  hidden [string] $RubyInstallerVersion = "3.4.8-1"

  SolargraphInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("solargraph")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [bool] IsRuntimeInstalled() {
    return $this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)
  }

  [void] AddLspToPath() {
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.LspKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [void] AddRuntimeToPath() {
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallRuntime() {
    $this.EnvManager.WriteInfo("Ruby is not installed. Downloading RubyInstaller...")

    try {
      # Download RubyInstaller
      [string] $tempFile = "$env:TEMP\rubyinstaller-$($this.RubyInstallerVersion).exe"
      
      $this.EnvManager.WriteInfo("Downloading Ruby $($this.RubyInstallerVersion) from GitHub...")
      Invoke-WebRequest -Uri $this.RubyInstallerUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
      
      if (-not (Test-Path $tempFile)) {
        $this.EnvManager.WriteError("Download failed")
        return $false
      }

      # Install to LOCALAPPDATA (clean location)
      $this.EnvManager.WriteInfo("Installing Ruby to $($this.RubyInstallDir)...")
      
      # Silent install to custom directory in AppData
      # /currentuser = per-user install with write permissions
      # /dir = custom install directory  
      # /tasks = skip file associations, PATH modification (we do it ourselves), and ridk install
      $installArgs = "/verysilent /currentuser /dir=`"$($this.RubyInstallDir)`" /tasks=`"noassocfiles,nomodpath,noridkinstall`""
      
      $process = Start-Process -FilePath $tempFile -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
      
      # Clean up installer
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
      
      if ($process.ExitCode -ne 0) {
        $this.EnvManager.WriteError("Installation failed with exit code $($process.ExitCode)")
        return $false
      }

      # Verify installation
      if (-not (Test-Path "$($this.RubyBinDir)\gem.cmd")) {
        $this.EnvManager.WriteError("Ruby installation verification failed")
        return $false
      }

      # Add to PATH
      $this.EnvManager.AddToUserPath($this.RubyBinDir)
      $this.EnvManager.RefreshSessionPath()

      # Run ridk install to set up MSYS2 for native gem compilation
      $this.EnvManager.WriteInfo("Setting up MSYS2 development toolchain...")
      [string] $ridkPath = "$($this.RubyBinDir)\ridk.cmd"
      if (Test-Path $ridkPath) {
        # ridk install 1 = base MSYS2, 3 = MINGW development toolchain
        $ridkProcess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$ridkPath`" install 1 3" -Wait -PassThru -NoNewWindow
        if ($ridkProcess.ExitCode -eq 0) {
          $this.EnvManager.WriteSuccess("MSYS2 toolchain installed")
        }
      }

      $this.EnvManager.WriteSuccess("Ruby $($this.RubyInstallerVersion) installed to $($this.RubyInstallDir)")
      return $true
    }
    catch {
      $this.EnvManager.WriteError("Installation failed: $($_.Exception.Message)")
      return $false
    }
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing solargraph...")
    
    [void] $this.PkgInstaller.InstallWithGem("solargraph")

    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("solargraph installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install solargraph. Please run manually:")
    $this.EnvManager.WriteError("  gem install solargraph")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("solargraph is already installed")
      return 0
    }

    # Check if runtime is installed, if not install it
    if (-not $this.IsRuntimeInstalled()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
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

[SolargraphInstaller] $installer = [SolargraphInstaller]::new()
exit $installer.Run()
