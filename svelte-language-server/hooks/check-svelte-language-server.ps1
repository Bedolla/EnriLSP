#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Svelte Language Server installer
.DESCRIPTION
    Checks for svelte-language-server installation and auto-installs Node.js runtime if missing.
    Uses OOP patterns with explicit types.
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
      if (Test-Path $path -PathType Leaf) {
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

  [PackageManagerResult] InstallWithNpm([string] $packageName) {
    $this.EnvManager.WriteInfo("Installing via npm...")
    & npm install -g $packageName 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via npm", "npm")
    }
    return [PackageManagerResult]::new($false, "npm installation failed", "npm")
  }
}

class SvelteLanguageServerInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $NpmGlobalPath = "$env:APPDATA\npm"
  hidden [string[]] $LspKnownPaths = @(
    "$env:APPDATA\npm\svelteserver.cmd",
    "$env:APPDATA\npm\svelteserver.ps1"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "C:\Program Files\nodejs\npm.cmd",
    "$env:LOCALAPPDATA\Programs\nodejs\npm.cmd",
    "$env:ProgramFiles\nodejs\npm.cmd"
  )
  hidden [string] $WingetPackageId = "OpenJS.NodeJS.LTS"

  SvelteLanguageServerInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("svelte-language-server")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [bool] IsRuntimeInstalled() {
    return $this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)
  }

  [void] AddLspToPath() {
    $this.EnvManager.AddToUserPath($this.NpmGlobalPath)
    $this.EnvManager.RefreshSessionPath()
  }

  [void] AddRuntimeToPath() {
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.AddToUserPath($this.NpmGlobalPath)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallRuntime() {
    $this.EnvManager.WriteInfo("Node.js/npm is not installed. Attempting to install...")

    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeInstalled()) {
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess("Node.js installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Node.js. Please install manually:")
    $this.EnvManager.WriteError("  winget install OpenJS.NodeJS.LTS")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing svelte-language-server...")
    
    if (-not (Test-Path $this.NpmGlobalPath)) {
      New-Item -ItemType Directory -Path $this.NpmGlobalPath -Force | Out-Null
    }
    
    $this.AddLspToPath()
    $this.PkgInstaller.InstallWithNpm("svelte-language-server")

    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("svelte-language-server installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install. Please run manually:")
    $this.EnvManager.WriteError("  npm install -g svelte-language-server")
    return $false
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("svelte-language-server is already installed")
      return 0
    }

    if (-not $this.IsRuntimeInstalled()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }
    }

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

[SvelteLanguageServerInstaller] $installer = [SvelteLanguageServerInstaller]::new()
exit $installer.Run()
