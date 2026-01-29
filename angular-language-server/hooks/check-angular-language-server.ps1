#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Angular Language Server installer
.DESCRIPTION
    Checks for @angular/language-server installation and auto-installs via npm.
    Provides Angular framework IntelliSense and diagnostics.
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

class AngularLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $NpmBinPath = "$env:APPDATA\npm"
  hidden [string] $GlobalNodeModulesPath = (Join-Path $env:APPDATA "npm\node_modules")

  AngularLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("angular-lsp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] PackageFolderExists([string] $relativePath) {
    return Test-Path (Join-Path $this.GlobalNodeModulesPath $relativePath) -PathType Container
  }

  [bool] AreDependenciesInstalled() {
    # ngserver requires explicit probe locations for both TypeScript and @angular/language-service
    return (
      $this.PackageFolderExists("typescript") -and
      $this.PackageFolderExists("@angular\\language-service")
    )
  }

  [bool] IsInstalled() {
    $this.EnvManager.RefreshSessionPath()
    $ngServerPath = Join-Path $this.NpmBinPath "ngserver.cmd"
    return (Test-Path $ngServerPath) -or $this.EnvManager.CommandExists("ngserver")
  }

  [bool] EnsureNodeJs() {
    if ($this.EnvManager.CommandExists("node")) {
      return $true
    }
    $this.EnvManager.WriteInfo("Node.js not found. Installing...")
    $result = $this.PkgInstaller.InstallWithWinget("OpenJS.NodeJS.LTS", "Node.js LTS")
    if ($result.Success) {
      $this.EnvManager.RefreshSessionPath()
      return $this.EnvManager.CommandExists("node")
    }
    return $false
  }

  [bool] Install() {
    if (-not $this.EnsureNodeJs()) {
      $this.EnvManager.WriteError("Node.js installation failed")
      return $false
    }

    $this.EnvManager.WriteInfo("Installing Angular LSP dependencies via npm...")

    try {
      $npmPath = (Get-Command npm -ErrorAction SilentlyContinue).Source
      if (-not $npmPath) {
        $this.EnvManager.WriteError("npm not found in PATH")
        return $false
      }

      # ngserver needs TypeScript and @angular/language-service. Install all globally to avoid per-project setup.
      & $npmPath install -g "@angular/language-server" "@angular/language-service" "typescript" 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        $this.EnvManager.AddToUserPath($this.NpmBinPath)
        $this.EnvManager.RefreshSessionPath()
        $this.EnvManager.WriteSuccess("Angular language server installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Installation failed: $_")
    }
    return $false
  }

  [int] Run() {
    if ($this.IsInstalled()) {
      # Ensure ngserver is reachable from PATH
      $this.EnvManager.AddToUserPath($this.NpmBinPath)
      $this.EnvManager.RefreshSessionPath()

      # Ensure required global deps exist (typescript + @angular/language-service)
      if (-not $this.AreDependenciesInstalled()) {
        $this.EnvManager.WriteInfo("Missing dependencies detected. Repairing global install...")
        if (-not $this.Install()) {
          $this.EnvManager.WriteError("Dependency installation failed")
          return 2
        }
      }
      $this.EnvManager.WriteSuccess("Angular Language Server is ready")
      return 0
    }

    $this.EnvManager.WriteInfo("Angular Language Server not found. Installing...")
    if ($this.Install()) {
      if ($this.IsInstalled()) {
        $this.EnvManager.WriteSuccess("Installation complete!")
        return 0
      }
      else {
        $this.EnvManager.WriteError("Installation completed but ngserver not found in PATH")
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
    }
    else {
      $this.EnvManager.WriteError("Installation failed")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[AngularLspInstaller] $installer = [AngularLspInstaller]::new()
exit $installer.Run()
