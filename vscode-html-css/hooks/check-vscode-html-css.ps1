#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - VSCode HTML CSS Language Server installer
.DESCRIPTION
    Checks for vscode-html-css language server installation and auto-installs Node.js if missing.
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

  [PackageManagerResult] InstallWithNpm([string[]] $packageNames) {
    $this.EnvManager.WriteInfo("Installing via npm...")
    foreach ($pkg in $packageNames) {
      & npm install -g $pkg 2>&1 | Out-Null
    }

    return [PackageManagerResult]::new($true, "Installed via npm", "npm")
  }
}

class VscodeHtmlCssInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $NpmGlobalPath = "$env:APPDATA\npm"
  hidden [string[]] $LspKnownPaths = @(
    "$env:APPDATA\npm\html-languageserver.cmd",
    "$env:APPDATA\npm\css-languageserver.cmd",
    "$env:APPDATA\npm\vscode-html-languageserver.cmd",
    "$env:APPDATA\npm\vscode-css-languageserver.cmd"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "C:\Program Files\nodejs\npm.cmd",
    "$env:LOCALAPPDATA\Programs\nodejs\npm.cmd",
    "$env:ProgramFiles\nodejs\npm.cmd"
  )
  hidden [string] $WingetPackageId = "OpenJS.NodeJS.LTS"

  VscodeHtmlCssInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("vscode-html-css")
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

    # PRIMARY: winget (cleanest installation)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeInstalled()) {
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess("Node.js installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install Node.js. Please install manually:")
    $this.EnvManager.WriteInfo("  winget install OpenJS.NodeJS.LTS")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing HTML/CSS language servers...")
    
    # Ensure npm global path exists
    if (-not (Test-Path $this.NpmGlobalPath)) {
      New-Item -ItemType Directory -Path $this.NpmGlobalPath -Force | Out-Null
    }
    
    $this.AddLspToPath()
    
    [string[]] $packages = @(
      "vscode-html-languageserver-bin",
      "vscode-css-languageserver-bin"
    )
    
    [void] $this.PkgInstaller.InstallWithNpm($packages)

    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("HTML/CSS language servers installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install HTML/CSS language servers. Please run manually:")
    $this.EnvManager.WriteInfo("  npm install -g vscode-html-languageserver-bin vscode-css-languageserver-bin")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("vscode-html-css is already installed")
      return 0
    }

    # Check if runtime is installed, if not install it
    if (-not $this.IsRuntimeInstalled()) {
      [bool] $runtimeInstalled = $this.InstallRuntime()
      if (-not $runtimeInstalled) {
        return 0
      }
    }

    # Install LSP
    $this.InstallLsp()
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[VscodeHtmlCssInstaller] $installer = [VscodeHtmlCssInstaller]::new()
exit $installer.Run()
