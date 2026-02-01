#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - clangd Language Server installer
.DESCRIPTION
    Checks for clangd installation and auto-installs LLVM if missing.
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
      # If path contains wildcard, resolve it first
      if ($path -match '\*|\?') {
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

    $this.EnvManager.WriteInfo("Installing via winget (user scope)...")

    # NOTE: winget prints progress bars and other control characters that can overwhelm
    # upstream hook runners. Suppress output and just rely on exit code.
    [string[]] $wingetArgs = @(
      "install",
      $packageId,
      "--silent",
      "--disable-interactivity",
      "--scope",
      "user",
      "--accept-package-agreements",
      "--accept-source-agreements"
    )

    & winget @wingetArgs 2>&1 | Out-Null

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

class ClangdInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string[]] $KnownPaths = @(
    "C:\Program Files\LLVM\bin\clangd.exe",
    "C:\Program Files (x86)\LLVM\bin\clangd.exe",
    "$env:LOCALAPPDATA\Programs\LLVM\bin\clangd.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\clangd.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LLVM.clangd*\clangd_*\bin\clangd.exe"
  )
  # Use LLVM.clangd (smaller, just clangd) as PRIMARY, LLVM.LLVM as fallback
  hidden [string] $WingetPrimaryId = "LLVM.clangd"
  hidden [string] $WingetFallbackId = "LLVM.LLVM"

  ClangdInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("clangd")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    # Check known installation paths DIRECTLY - never trust PATH
    return $this.EnvManager.AnyFileExists($this.KnownPaths)
  }

  [void] AddLspToPath() {
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.KnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("clangd is not installed. Attempting to install...")

    # PRIMARY: winget with LLVM.clangd (smaller package, just clangd)
    [PackageManagerResult] $primaryResult = $this.PkgInstaller.InstallWithWinget($this.WingetPrimaryId)
    if ($primaryResult.Success -and $this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("clangd installed via winget (LLVM.clangd)")
      return $true
    }

    # FALLBACK 1: winget with full LLVM
    $this.EnvManager.WriteWarning("LLVM.clangd not available, trying full LLVM...")
    [PackageManagerResult] $fallbackResult = $this.PkgInstaller.InstallWithWinget($this.WingetFallbackId)
    if ($fallbackResult.Success -and $this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("clangd installed via winget (LLVM.LLVM)")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install clangd. Please install manually:")
    $this.EnvManager.WriteError("  winget install LLVM.clangd")
    $this.EnvManager.WriteError("  Or: winget install LLVM.LLVM")
    $this.EnvManager.WriteError("  Or: Visual Studio with 'C++ Clang tools for Windows' workload")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("clangd is already installed")
      return 0
    }

    # Install LSP (clangd is standalone, no separate runtime needed)
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

[ClangdInstaller] $installer = [ClangdInstaller]::new()
exit $installer.Run()
