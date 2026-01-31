#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - rust-analyzer Language Server installer
.DESCRIPTION
    Checks for rust-analyzer installation and auto-installs Rust runtime if missing.
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

  [PackageManagerResult] InstallWithRustup([string] $component) {
    $this.EnvManager.WriteInfo("Installing via rustup...")
    & rustup component add $component 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via rustup", "rustup")
    }
    return [PackageManagerResult]::new($false, "rustup installation failed", "rustup")
  }
}

class RustAnalyzerInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  # Use AppData for Cargo/Rustup to keep user root clean
  hidden [string] $CleanCargoHome = "$env:APPDATA\Rust\cargo"
  hidden [string] $CleanRustupHome = "$env:APPDATA\Rust\rustup"
  hidden [string] $CleanCargoBinPath = "$env:APPDATA\Rust\cargo\bin"
  # rust-analyzer is installed in toolchain bin, but rustup creates a proxy in cargo/bin
  hidden [string[]] $LspKnownPaths = @(
    "$env:APPDATA\Rust\cargo\bin\rust-analyzer.exe",
    "$env:APPDATA\Rust\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe",
    "$env:USERPROFILE\.cargo\bin\rust-analyzer.exe",
    "$env:USERPROFILE\.rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "$env:APPDATA\Rust\cargo\bin\rustup.exe",
    "$env:USERPROFILE\.cargo\bin\rustup.exe"
  )
  hidden [string] $WingetPackageId = "Rustlang.Rustup"

  RustAnalyzerInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("rust-analyzer")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    # Set CARGO_HOME and RUSTUP_HOME to AppData to avoid polluting user root
    $this.SetCleanRustPaths()
  }

  [void] SetCleanRustPaths() {
    # Set environment variables for this session
    $env:CARGO_HOME = $this.CleanCargoHome
    $env:RUSTUP_HOME = $this.CleanRustupHome
    # Persist to user environment
    [System.Environment]::SetEnvironmentVariable("CARGO_HOME", $this.CleanCargoHome, [System.EnvironmentVariableTarget]::User)
    [System.Environment]::SetEnvironmentVariable("RUSTUP_HOME", $this.CleanRustupHome, [System.EnvironmentVariableTarget]::User)
  }

  [string] GetCargoBinPath() {
    # Return clean path if it exists, otherwise fallback to default
    if (Test-Path "$($this.CleanCargoBinPath)\rustup.exe") {
      return $this.CleanCargoBinPath
    }
    if (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe") {
      return "$env:USERPROFILE\.cargo\bin"
    }
    return $this.CleanCargoBinPath
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [bool] IsRuntimeInstalled() {
    return $this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)
  }

  [void] AddCargoToPath() {
    [string] $binPath = $this.GetCargoBinPath()
    $this.EnvManager.AddToUserPath($binPath)
    
    # Also add toolchain bin where rust-analyzer actually lives
    [string] $toolchainBin = "$($this.CleanRustupHome)\toolchains\stable-x86_64-pc-windows-msvc\bin"
    if (Test-Path $toolchainBin) {
      $this.EnvManager.AddToUserPath($toolchainBin)
    }
    
    $this.EnvManager.RefreshSessionPath()
    # Ensure stable toolchain is set as default
    if (Test-Path "$binPath\rustup.exe") {
      & "$binPath\rustup.exe" default stable 2>&1 | Out-Null
    }
  }

  [bool] InstallRuntime() {
    $this.EnvManager.WriteInfo("Rust is not installed. Attempting to install...")

    # PRIMARY: winget (cleanest installation)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeInstalled()) {
      $this.AddCargoToPath()
      # Initialize default toolchain
      [string] $binPath = $this.GetCargoBinPath()
      & "$binPath\rustup.exe" default stable 2>&1 | Out-Null
      $this.EnvManager.WriteSuccess("Rust installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Rust. Please install manually:")
    $this.EnvManager.WriteError("  winget install Rustlang.Rustup")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing rust-analyzer...")
    
    $this.AddCargoToPath()
    
    # Install via rustup component
    [void] $this.PkgInstaller.InstallWithRustup("rust-analyzer")

    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("rust-analyzer installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install rust-analyzer. Please run manually:")
    $this.EnvManager.WriteError("  rustup component add rust-analyzer")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddCargoToPath()
      $this.EnvManager.WriteSuccess("rust-analyzer is already installed")
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

[RustAnalyzerInstaller] $installer = [RustAnalyzerInstaller]::new()
exit $installer.Run()
