#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - OmniSharp (C#) Language Server installer
.DESCRIPTION
    Checks for OmniSharp/csharp-ls installation and auto-installs .NET SDK if missing.
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

  [string] FindWithWildcard([string] $pattern) {
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

  [PackageManagerResult] InstallWithDotnet([string] $toolName) {
    $this.EnvManager.WriteInfo("Installing via dotnet tool...")
    & dotnet tool install -g $toolName 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
      return [PackageManagerResult]::new($true, "Installed via dotnet", "dotnet")
    }
    return [PackageManagerResult]::new($false, "dotnet tool installation failed", "dotnet")
  }
}

class OmnisharpInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $DotnetToolsPath = "$env:USERPROFILE\.dotnet\tools"
  hidden [string[]] $LspKnownPaths = @(
    "$env:USERPROFILE\.dotnet\tools\csharp-ls.exe"
  )
  hidden [string[]] $RuntimeKnownPaths = @(
    "C:\Program Files\dotnet\dotnet.exe",
    "$env:LOCALAPPDATA\Programs\dotnet\dotnet.exe",
    "$env:ProgramFiles\dotnet\dotnet.exe"
  )
  # .NET SDK 10 is required for csharp-ls (latest version)
  hidden [string] $WingetPackageId = "Microsoft.DotNet.SDK.10"

  OmnisharpInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("omnisharp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
  }

  [string] FindDotnetExe() {
    [string] $found = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($found)) {
      return $found
    }
    return ""
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [bool] IsRuntimeInstalled() {
    return $this.EnvManager.AnyFileExists($this.RuntimeKnownPaths)
  }

  [void] AddLspToPath() {
    $this.EnvManager.AddToUserPath($this.DotnetToolsPath)
    $this.EnvManager.RefreshSessionPath()
  }

  [void] AddRuntimeToPath() {
    [string] $foundPath = $this.EnvManager.FindExistingFile($this.RuntimeKnownPaths)
    if (-not [string]::IsNullOrEmpty($foundPath)) {
      [string] $binDir = Split-Path -Parent $foundPath
      $this.EnvManager.AddToUserPath($binDir)
      $this.EnvManager.AddToUserPath($this.DotnetToolsPath)
      $this.EnvManager.RefreshSessionPath()
    }
  }

  [bool] InstallRuntime() {
    $this.EnvManager.WriteInfo(".NET SDK is not installed. Attempting to install...")

    # PRIMARY: winget (cleanest installation)
    [PackageManagerResult] $wingetResult = $this.PkgInstaller.InstallWithWinget($this.WingetPackageId)
    if ($wingetResult.Success -and $this.IsRuntimeInstalled()) {
      $this.AddRuntimeToPath()
      $this.EnvManager.WriteSuccess(".NET SDK installed via winget")
      return $true
    }

    $this.EnvManager.WriteError("Could not auto-install .NET SDK 10. Please install manually:")
    $this.EnvManager.WriteError("  winget install Microsoft.DotNet.SDK.10")
    return $false
  }

  [bool] InstallLsp() {
    $this.EnvManager.WriteInfo("Installing csharp-ls...")
    
    # Ensure dotnet tools path exists
    if (-not (Test-Path $this.DotnetToolsPath)) {
      New-Item -ItemType Directory -Path $this.DotnetToolsPath -Force | Out-Null
    }
    
    $this.AddLspToPath()
    
    # Find dotnet executable and use it directly
    [string] $dotnetExe = $this.FindDotnetExe()
    if (-not [string]::IsNullOrEmpty($dotnetExe)) {
      $this.EnvManager.WriteInfo("Installing via dotnet tool...")
      # Install latest version (0.21.0+ requires .NET 10 which we install)
      & $dotnetExe tool install -g csharp-ls 2>&1 | Out-Null
    }

    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("csharp-ls installed successfully")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install C# language server. Please run manually:")
    $this.EnvManager.WriteError("  dotnet tool install -g csharp-ls")
    return $false
  }

  [int] Run() {
    # Check if LSP is already installed
    if ($this.IsLspInstalled()) {
      # Always ensure it's in PATH
      $this.AddLspToPath()
      $this.EnvManager.WriteSuccess("csharp-ls is already installed")
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

[OmnisharpInstaller] $installer = [OmnisharpInstaller]::new()
exit $installer.Run()
