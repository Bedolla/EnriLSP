#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - Kotlin LSP (official) installer
.DESCRIPTION
    Installs the JetBrains/Kotlin official Kotlin Language Server (kotlin-lsp) on Windows.

    Why this exists:
    - The legacy community server (fwcd/kotlin-language-server) can crash on very new Java versions
      (e.g. Java 25 parsing issues).
    - Kotlin LSP publishes a standalone Windows ZIP that bundles its own JRE (no separate Java install
      is required for the server to run).

    This hook:
    - Downloads the latest kotlin-lsp standalone zip
    - Verifies SHA-256 (best-effort)
    - Extracts it to %LOCALAPPDATA%\EnriLSP\kotlin-lsp
    - Adds that folder to user PATH
.NOTES
    Author: Bedolla
    License: MIT
#>

# ============================================================================
# CLASSES
# ============================================================================

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

  [void] AddToUserPath([string] $binPath) {
    [string] $oldUserPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    [string] $normalizedBin = $binPath.TrimEnd('\')
    [string[]] $existingPaths = $oldUserPath -split ';' | ForEach-Object { $_.TrimEnd('\') }

    if ($normalizedBin -notin $existingPaths) {
      [System.Environment]::SetEnvironmentVariable("Path", "$oldUserPath;$binPath", "User")
      $this.WriteInfo("Added to user PATH: $binPath")
    }
  }

  [void] RefreshSessionPath() {
    [string] $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    [string] $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $machinePath = $machinePath.TrimEnd(';')
    $userPath = $userPath.TrimEnd(';')
    $env:Path = "$machinePath;$userPath"
  }
}

class KotlinLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [string] $InstallDir = "$env:LOCALAPPDATA\EnriLSP\kotlin-lsp"
  hidden [string] $LegacyInstallDir = "$env:LOCALAPPDATA\kotlin-lsp"
  hidden [string] $GitHubApiUrl = "https://api.github.com/repos/Kotlin/kotlin-lsp/releases/latest"

  KotlinLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("kotlin-lsp")
  }

  [string] GetPlatformSuffix() {
    [string] $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "x86" -and -not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
      $arch = $env:PROCESSOR_ARCHITEW6432
    }

    if (-not [string]::IsNullOrWhiteSpace($arch) -and $arch.ToUpperInvariant() -eq "ARM64") {
      return "win-aarch64"
    }

    return "win-x64"
  }

  [string] GetLatestVersion() {
    try {
      $headers = @{ "User-Agent" = "EnriLSP-Installer" }
      $release = Invoke-RestMethod -Uri $this.GitHubApiUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop

      [string] $tag = [string] $release.tag_name
      if ($tag -match '^kotlin-lsp/v(.+)$') {
        return $Matches[1]
      }
      if ($tag -match '^v(.+)$') {
        return $Matches[1]
      }
      return $tag
    }
    catch {
      $this.EnvManager.WriteError("Failed to fetch latest Kotlin LSP version: $($_.Exception.Message)")
      return ""
    }
  }

  [string] GetZipUrl([string] $version, [string] $platformSuffix) {
    return "https://download-cdn.jetbrains.com/kotlin-lsp/$version/kotlin-lsp-$version-$platformSuffix.zip"
  }

  [string] GetShaUrl([string] $zipUrl) {
    return "$zipUrl.sha256"
  }

  [string] DecodeWebContent([object] $content) {
    if ($content -is [byte[]]) {
      return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return [string] $content
  }

  [string] GetExpectedSha256([string] $shaUrl) {
    try {
      $ProgressPreference = 'SilentlyContinue'
      $resp = Invoke-WebRequest -Uri $shaUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
      $ProgressPreference = 'Continue'

      [string] $text = $this.DecodeWebContent($resp.Content)
      # Format: "<hash> *filename"
      [string[]] $parts = $text.Split(@(' ', "`t", "`r", "`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
      if ($parts.Length -ge 1) {
        return $parts[0].Trim()
      }
    }
    catch {
      $this.EnvManager.WriteWarning("Could not fetch SHA-256 checksum (continuing): $($_.Exception.Message)")
    }
    return ""
  }

  [bool] IsInstalled() {
    return (Test-Path (Join-Path $this.InstallDir "kotlin-lsp.cmd") -PathType Leaf)
  }

  [void] MigrateLegacyInstallIfNeeded() {
    try {
      if ($this.LegacyInstallDir -eq $this.InstallDir) {
        return
      }

      if ((Test-Path $this.LegacyInstallDir) -and -not (Test-Path $this.InstallDir)) {
        [string] $parent = Split-Path -Parent $this.InstallDir
        if (-not (Test-Path $parent)) {
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $this.EnvManager.WriteInfo("Migrating legacy install to: $($this.InstallDir)")
        Move-Item -Path $this.LegacyInstallDir -Destination $this.InstallDir -Force
      }
    }
    catch {
      $this.EnvManager.WriteWarning("Could not migrate legacy Kotlin LSP install (continuing): $($_.Exception.Message)")
    }
  }

  [void] AddToPath() {
    $this.EnvManager.AddToUserPath($this.InstallDir)
    $this.EnvManager.RefreshSessionPath()
  }

  [bool] InstallOrUpdate() {
    [string] $version = $this.GetLatestVersion()
    if ([string]::IsNullOrWhiteSpace($version)) {
      return $false
    }

    [string] $platformSuffix = $this.GetPlatformSuffix()
    [string] $zipUrl = $this.GetZipUrl($version, $platformSuffix)
    [string] $shaUrl = $this.GetShaUrl($zipUrl)

    [string] $tempZip = Join-Path $env:TEMP "kotlin-lsp-$platformSuffix-$version.zip"

    # Try to prefer modern TLS. PowerShell 5.1 can be finicky depending on .NET defaults.
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    $this.EnvManager.WriteInfo("Downloading Kotlin LSP $version ($platformSuffix)...")
    $this.EnvManager.WriteInfo("URL: $zipUrl")

    try {
      $ProgressPreference = 'SilentlyContinue'
      Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
      $ProgressPreference = 'Continue'
    }
    catch {
      $this.EnvManager.WriteError("Download failed: $($_.Exception.Message)")
      return $false
    }

    # Best-effort SHA verification
    [string] $expected = $this.GetExpectedSha256($shaUrl)
    if (-not [string]::IsNullOrWhiteSpace($expected)) {
      try {
        [string] $actual = (Get-FileHash -Algorithm SHA256 -Path $tempZip).Hash
        if ($actual.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
          $this.EnvManager.WriteError("SHA-256 mismatch for downloaded kotlin-lsp zip")
          $this.EnvManager.WriteError("Expected: $expected")
          $this.EnvManager.WriteError("Actual:   $actual")
          return $false
        }
      }
      catch {
        $this.EnvManager.WriteWarning("Could not compute SHA-256 (continuing): $($_.Exception.Message)")
      }
    }

    try {
      if (-not (Test-Path $this.InstallDir)) {
        New-Item -ItemType Directory -Path $this.InstallDir -Force | Out-Null
      }

      $this.EnvManager.WriteInfo("Extracting to: $($this.InstallDir)")
      Expand-Archive -Path $tempZip -DestinationPath $this.InstallDir -Force

      # Record installed version (useful for debugging)
      Set-Content -Path (Join-Path $this.InstallDir "VERSION") -Value $version -Encoding ASCII

      Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

      if (-not $this.IsInstalled()) {
        $this.EnvManager.WriteError("Install finished but kotlin-lsp.cmd was not found in $($this.InstallDir)")
        return $false
      }

      $this.AddToPath()
      $this.EnvManager.WriteSuccess("Kotlin LSP installed successfully")
      return $true
    }
    catch {
      $this.EnvManager.WriteError("Extraction failed: $($_.Exception.Message)")
      return $false
    }
  }

  [int] Run() {
    $this.MigrateLegacyInstallIfNeeded()

    if ($this.IsInstalled()) {
      $this.AddToPath()
      $this.EnvManager.WriteSuccess("Kotlin LSP is already installed")
      return 0
    }

    $this.EnvManager.WriteInfo("Kotlin LSP not found. Installing...")
    if (-not $this.InstallOrUpdate()) {
      $this.EnvManager.WriteError("Failed to install Kotlin LSP.")
      $this.EnvManager.WriteError("Manual download: https://github.com/Kotlin/kotlin-lsp/releases/latest")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[KotlinLspInstaller] $installer = [KotlinLspInstaller]::new()
exit $installer.Run()
