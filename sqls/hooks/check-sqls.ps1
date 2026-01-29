#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - SQLS (SQL Language Server) installer
.DESCRIPTION
    Checks for sqls installation and auto-installs from GitHub releases.
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

class SqlsInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\sqls"
  hidden [string[]] $LspKnownPaths = @(
    "$env:LOCALAPPDATA\sqls\sqls.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\sqls.exe",
    "$env:APPDATA\Go\bin\sqls.exe",
    "$env:USERPROFILE\go\bin\sqls.exe"
  )
  hidden [string] $GitHubApiUrl = "https://api.github.com/repos/sqls-server/sqls/releases/latest"

  SqlsInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("sqls")
  }

  [bool] IsLspInstalled() {
    return $this.EnvManager.AnyFileExists($this.LspKnownPaths)
  }

  [void] AddLspToPath() {
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [string] GetLatestReleaseUrl() {
    try {
      $this.EnvManager.WriteInfo("Fetching latest release from GitHub...")
      $headers = @{ "User-Agent" = "EnriLSP-Installer" }
      $release = Invoke-RestMethod -Uri $this.GitHubApiUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop
      
      foreach ($asset in $release.assets) {
        if ($asset.name -like "*windows*.zip") {
          return $asset.browser_download_url
        }
      }
    }
    catch {
      $this.EnvManager.WriteError("Failed to fetch release info: $_")
    }
    return ""
  }

  [bool] InstallFromGitHub() {
    $this.EnvManager.WriteInfo("Installing from GitHub releases...")
    
    [string] $downloadUrl = $this.GetLatestReleaseUrl()
    if ([string]::IsNullOrEmpty($downloadUrl)) {
      $this.EnvManager.WriteError("Could not find Windows binary in release")
      return $false
    }

    $this.EnvManager.WriteInfo("Downloading: $downloadUrl")
    
    if (-not (Test-Path $this.InstallDir)) {
      New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
    }

    [string] $zipPath = "$env:TEMP\sqls.zip"
    
    try {
      $ProgressPreference = 'SilentlyContinue'
      Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
      $ProgressPreference = 'Continue'
      
      $this.EnvManager.WriteInfo("Extracting...")
      Expand-Archive -Path $zipPath -DestinationPath $this.InstallDir -Force
      Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
      
      # sqls might be in a subdirectory, find and move it
      [string] $sqlsExe = Get-ChildItem -Path $this.InstallDir -Filter "sqls.exe" -Recurse | Select-Object -First 1 -ExpandProperty FullName
      if ($sqlsExe -and $sqlsExe -ne (Join-Path $this.InstallDir "sqls.exe")) {
        Move-Item -Path $sqlsExe -Destination (Join-Path $this.InstallDir "sqls.exe") -Force
      }
      
      if (Test-Path (Join-Path $this.InstallDir "sqls.exe")) {
        $this.AddLspToPath()
        $this.EnvManager.WriteSuccess("sqls installed to: $($this.InstallDir)")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $_")
    }
    
    return $false
  }

  [string] GetDefaultConfigPath() {
    # sqls follows XDG config conventions; on Windows this defaults to ~/.config when XDG_CONFIG_HOME is not set.
    [string] $configHome = $env:XDG_CONFIG_HOME
    if ([string]::IsNullOrWhiteSpace($configHome)) {
      $configHome = Join-Path $env:USERPROFILE ".config"
    }

    return Join-Path (Join-Path $configHome "sqls") "config.yml"
  }

  [bool] EnsureDefaultConfig() {
    try {
      [string] $configPath = $this.GetDefaultConfigPath()

      if (Test-Path $configPath -PathType Leaf) {
        return $true
      }

      [string] $configDir = Split-Path -Parent $configPath
      if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
      }

      # NOTE: sqls can emit a window/showMessage notification ("no database connection") before responding to
      # initialize when it has no configured connections. Some clients crash when that happens. Provide a
      # safe default so the server behaves predictably on startup.
      [string] $content = @'
# Auto-generated by EnriLSP (sqls) to provide a safe default connection.
# Edit this file to add your real database connections.
connections:
  - alias: local_sqlite
    driver: sqlite3
    dataSourceName: ":memory:"
'@

      Set-Content -Path $configPath -Value $content -Encoding UTF8
      $this.EnvManager.WriteInfo("Created default config: $configPath")
      return $true
    }
    catch {
      $this.EnvManager.WriteError("Failed to create sqls config: $_")
      $this.EnvManager.WriteError("Create it manually at: $($this.GetDefaultConfigPath())")
      return $false
    }
  }

  [int] Run() {
    if ($this.IsLspInstalled()) {
      $this.AddLspToPath()

      if (-not $this.EnsureDefaultConfig()) {
        # Exit code 2: stderr shown to user for Setup hooks
        return 2
      }

      $this.EnvManager.WriteSuccess("sqls is already installed")
      return 0
    }

    if (-not $this.InstallFromGitHub()) {
      $this.EnvManager.WriteError("Failed to install. Please install manually:")
      $this.EnvManager.WriteError("  Download from: https://github.com/sqls-server/sqls/releases")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    if (-not $this.EnsureDefaultConfig()) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[SqlsInstaller] $installer = [SqlsInstaller]::new()
exit $installer.Run()
