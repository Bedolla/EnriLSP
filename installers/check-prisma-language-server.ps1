#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Prisma Language Server installer
.DESCRIPTION
    Checks for @prisma/language-server installation and auto-installs via npm.
    Provides Prisma schema IntelliSense and formatting.
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

  [void] WriteError([string] $message) {
    # Write to stderr so Claude Code Setup hooks display the message to user
    [Console]::Error.WriteLine("[$($this.PluginName)] $message")
  }

  [bool] CommandExists([string] $command) {
    return [bool](Get-Command $command -ErrorAction SilentlyContinue)
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
}

class PackageInstaller {
  hidden [EnvironmentManager] $EnvManager

  PackageInstaller([EnvironmentManager] $envManager) {
    $this.EnvManager = $envManager
  }

  [PackageManagerResult] InstallWithWinget([string] $packageId, [string] $packageName) {
    if (-not $this.EnvManager.CommandExists("winget")) {
      return [PackageManagerResult]::new($false, "winget not available", "none")
    }

    $this.EnvManager.WriteInfo("Installing $packageName via winget...")
    try {
      & winget install --id $packageId -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements --scope user 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        return [PackageManagerResult]::new($true, "$packageName installed successfully", "winget")
      }
    }
    catch {
      return [PackageManagerResult]::new($false, "winget installation failed: $_", "winget")
    }
    return [PackageManagerResult]::new($false, "winget installation failed", "winget")
  }
}

class PrismaLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $NpmBinPath = "$env:APPDATA\npm"

  PrismaLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("prisma-lsp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsNodeInstalled() {
    return $this.EnvManager.CommandExists("node")
  }

  [bool] IsLspInstalled() {
    $this.EnvManager.RefreshSessionPath()
    return $this.EnvManager.CommandExists("prisma-language-server")
  }

  [bool] InstallNode() {
    $this.EnvManager.WriteInfo("Node.js not found. Installing...")
    [PackageManagerResult] $result = $this.PkgInstaller.InstallWithWinget("OpenJS.NodeJS.LTS", "Node.js LTS")
    
    if ($result.Success) {
      $this.EnvManager.WriteSuccess($result.Message)
      $this.EnvManager.RefreshSessionPath()
      return $true
    }
    
    $this.EnvManager.WriteError("Failed to install Node.js. Please install manually.")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing @prisma/language-server via npm...")
    
    try {
      & npm install -g "@prisma/language-server" 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        $this.EnvManager.AddToUserPath($this.NpmBinPath)
        $this.EnvManager.RefreshSessionPath()
        $this.EnvManager.WriteSuccess("@prisma/language-server installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("npm install failed: $_")
    }
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("prisma-language-server is already installed")
      return 0
    }

    if (-not $this.IsNodeInstalled()) {
      if (-not $this.InstallNode()) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
    }

    if (-not $this.InstallLsp()) {
      $this.EnvManager.WriteError("Failed to install. Please run manually:")
      $this.EnvManager.WriteError("  npm install -g @prisma/language-server")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[PrismaLspInstaller] $installer = [PrismaLspInstaller]::new()
exit $installer.Run()
