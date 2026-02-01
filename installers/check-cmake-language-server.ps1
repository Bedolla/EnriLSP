#Requires -Version 5.1
<#
.SYNOPSIS
    EnriLSP - CMake Language Server installer
.DESCRIPTION
    Installs cmake-language-server in a dedicated virtual environment to avoid
    breaking changes in newer Python versions (e.g. Python 3.14 removing
    asyncio child watchers used by older pygls stacks).

    Provides CMake IntelliSense support.
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

class PythonCommand {
  [string] $Exe
  [string[]] $Args

  PythonCommand([string] $exe, [string[]] $arguments) {
    $this.Exe = $exe
    $this.Args = $arguments
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

class CmakeLspInstaller {
  hidden [EnvironmentManager] $EnvManager
  hidden [PackageInstaller] $PkgInstaller
  hidden [string] $InstallRoot
  hidden [string] $VenvDir
  hidden [string] $VenvPython
  hidden [string] $VenvLspExe
  hidden [string[]] $PreferredPyLauncherArgs = @("-3.13", "-3.12")
  hidden [string[]] $PythonKnownPaths = @(
    "$env:LOCALAPPDATA\\Programs\\Python\\Python313\\python.exe",
    "$env:LOCALAPPDATA\\Programs\\Python\\Python312\\python.exe",
    "$env:ProgramFiles\\Python313\\python.exe",
    "$env:ProgramFiles\\Python312\\python.exe"
  )
  hidden [string[]] $CmakeBinCandidates

  CmakeLspInstaller() {
    $this.EnvManager = [EnvironmentManager]::new("cmake-lsp")
    $this.PkgInstaller = [PackageInstaller]::new($this.EnvManager)
    $this.InstallRoot = "$env:LOCALAPPDATA\\EnriLSP\\cmake-language-server"
    $this.VenvDir = Join-Path $this.InstallRoot ".venv"
    $this.VenvPython = Join-Path $this.VenvDir "Scripts\\python.exe"
    $this.VenvLspExe = Join-Path $this.VenvDir "Scripts\\cmake-language-server.exe"

    $programFilesX86 = [System.Environment]::GetFolderPath('ProgramFilesX86')
    $this.CmakeBinCandidates = @(
      (Join-Path $env:LOCALAPPDATA "Programs\\CMake\\bin"),
      (Join-Path $env:ProgramFiles "CMake\\bin"),
      (Join-Path $programFilesX86 "CMake\\bin")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  }

  [string] GetVenvPythonVersion() {
    if (-not (Test-Path $this.VenvPython -PathType Leaf)) {
      return ""
    }

    try {
      return (& $this.VenvPython -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2>$null).Trim()
    }
    catch {
      return ""
    }
  }

  [string] GetVenvPackageVersion([string] $packageName) {
    if (-not (Test-Path $this.VenvPython -PathType Leaf)) {
      return ""
    }

    try {
      return (& $this.VenvPython -c "import importlib.metadata as m; print(m.version('$packageName'))" 2>$null).Trim()
    }
    catch {
      return ""
    }
  }

  [PythonCommand] FindPythonCommand() {
    # Prefer a dedicated Python 3.13/3.12 install by absolute path. This avoids
    # the common Windows situation where `py -3.13` or `python` may resolve to
    # the default Python 3.14 (which breaks older pygls stacks).
    foreach ($path in $this.PythonKnownPaths) {
      if (Test-Path $path -PathType Leaf) {
        try {
          [string] $ver = (& $path -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null) -join " "
          if ($ver -match '^3\s+(12|13)$') {
            $this.EnvManager.WriteInfo("Using Python: $path (reported: $ver)")
            return [PythonCommand]::new($path, @())
          }
        }
        catch {}
      }
    }

    # Next preference: Windows Python launcher with explicit version.
    if ($this.EnvManager.CommandExists("py")) {
      foreach ($arg in $this.PreferredPyLauncherArgs) {
        try {
          [string] $ver = (& py $arg -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null) -join " "
          if ($LASTEXITCODE -eq 0 -and $ver -match '^3\s+(12|13)$') {
            $this.EnvManager.WriteInfo("Using Python: py $arg (reported: $ver)")
            return [PythonCommand]::new("py", @($arg))
          }
        }
        catch {}
      }
    }

    if ($this.EnvManager.CommandExists("python")) {
      try {
        [string] $ver = (& python -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null) -join " "
        if ($LASTEXITCODE -eq 0 -and $ver -match '^3\s+(12|13)$') {
          $this.EnvManager.WriteInfo("Using Python: python (reported: $ver)")
          return [PythonCommand]::new("python", @())
        }
      }
      catch {}
    }

    return $null
  }

  [bool] IsLspInstalled() {
    if (-not (Test-Path $this.VenvLspExe -PathType Leaf)) {
      return $false
    }

    [string] $venvVersion = $this.GetVenvPythonVersion()
    if ($venvVersion -match '^3\.(12|13)$') {
      # cmake-language-server (currently) expects pygls v1.x; pygls v2 changed API
      # and will crash at import time. If we detect pygls>=2, reinstall with pin.
      [string] $pyglsVersion = $this.GetVenvPackageVersion("pygls")
      if ($pyglsVersion -match '^1\.') {
        return $true
      }

      if (-not [string]::IsNullOrWhiteSpace($pyglsVersion)) {
        $this.EnvManager.WriteWarning("Existing venv has pygls $pyglsVersion. Reinstalling to pin pygls<2 for compatibility.")
      }
      else {
        $this.EnvManager.WriteWarning("Unable to determine pygls version. Reinstalling cmake-language-server to ensure compatibility.")
      }

      return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($venvVersion)) {
      $this.EnvManager.WriteWarning("Existing venv uses Python $venvVersion. Recreating to avoid Python 3.14 incompatibilities.")
    }

    return $false
  }

  [bool] EnsureInstallRoot() {
    try {
      if (-not (Test-Path $this.InstallRoot)) {
        New-Item -ItemType Directory -Path $this.InstallRoot -Force | Out-Null
      }
      return $true
    }
    catch {
      $this.EnvManager.WriteError("Failed to create install dir: $($_.Exception.Message)")
      return $false
    }
  }

  [bool] InstallPython() {
    $this.EnvManager.WriteInfo("Python 3.13/3.12 not found. Installing Python 3.13...")
    [PackageManagerResult] $result = $this.PkgInstaller.InstallWithWinget("Python.Python.3.13", "Python 3.13")
    
    if ($result.Success) {
      $this.EnvManager.WriteSuccess($result.Message)
      $this.EnvManager.RefreshSessionPath()
      return $true
    }
    
    $this.EnvManager.WriteError("Failed to install Python. Please install manually.")
    $this.EnvManager.WriteError("  winget install Python.Python.3.13")
    return $false
  }

  [bool] EnsureCmake() {
    $this.EnvManager.RefreshSessionPath()
    if ($this.EnvManager.CommandExists("cmake")) {
      return $true
    }

    # Try common install locations before attempting winget.
    foreach ($binPath in $this.CmakeBinCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($binPath) -and (Test-Path (Join-Path $binPath "cmake.exe") -PathType Leaf)) {
        $this.EnvManager.AddToUserPath($binPath)
        $this.EnvManager.RefreshSessionPath()
        if ($this.EnvManager.CommandExists("cmake")) {
          return $true
        }
      }
    }

    $this.EnvManager.WriteInfo("CMake not found. Installing CMake via winget...")
    [PackageManagerResult] $result = $this.PkgInstaller.InstallWithWinget("Kitware.CMake", "CMake")
    if ($result.Success) {
      $this.EnvManager.WriteSuccess($result.Message)
      $this.EnvManager.RefreshSessionPath()

      # Try common locations again (some installs won't update PATH for this session)
      foreach ($binPath in $this.CmakeBinCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($binPath) -and (Test-Path (Join-Path $binPath "cmake.exe") -PathType Leaf)) {
          $this.EnvManager.AddToUserPath($binPath)
          $this.EnvManager.RefreshSessionPath()
          break
        }
      }

      if ($this.EnvManager.CommandExists("cmake")) {
        return $true
      }

      $this.EnvManager.WriteWarning("CMake installed but not visible in PATH yet. Restart Claude Code to pick up PATH changes.")
      return $true
    }

    $this.EnvManager.WriteError("Failed to install CMake. Please install manually:")
    $this.EnvManager.WriteError("  winget install --id Kitware.CMake -e --scope user")
    return $false
  }

  [bool] EnsureVenv([PythonCommand] $pythonCommand) {
    if (-not $this.EnsureInstallRoot()) {
      return $false
    }

    if (Test-Path $this.VenvPython -PathType Leaf) {
      [string] $venvVersion = $this.GetVenvPythonVersion()
      if ($venvVersion -match '^3\.(12|13)$') {
        return $true
      }

      $this.EnvManager.WriteWarning("Existing venv Python version is '$venvVersion'. Removing venv so it can be recreated with Python 3.13/3.12.")
      try {
        Remove-Item -Path $this.VenvDir -Recurse -Force -ErrorAction Stop
      }
      catch {
        $this.EnvManager.WriteError("Failed to remove old venv: $($_.Exception.Message)")
        return $false
      }
    }

    $this.EnvManager.WriteInfo("Creating venv: $($this.VenvDir)")
    try {
      & $pythonCommand.Exe @($pythonCommand.Args) -m venv $this.VenvDir 2>&1 | Out-Null
      return (Test-Path $this.VenvPython -PathType Leaf)
    }
    catch {
      $this.EnvManager.WriteError("Failed to create venv: $($_.Exception.Message)")
      return $false
    }
  }

  [bool] InstallLsp() {
    [PythonCommand] $pythonCommand = $this.FindPythonCommand()
    if ($null -eq $pythonCommand) {
      if (-not $this.InstallPython()) {
        return $false
      }
      $pythonCommand = $this.FindPythonCommand()
    }

    if ($null -eq $pythonCommand) {
      $this.EnvManager.WriteError("Python is still not available after install attempt.")
      return $false
    }

    if (-not $this.EnsureVenv($pythonCommand)) {
      return $false
    }

    $this.EnvManager.WriteInfo("Installing cmake-language-server in venv...")
    try {
      & $this.VenvPython -m pip install -U pip 2>&1 | Out-Null
      # Pin pygls<2 to avoid import-time crashes on Windows (pygls v2 API changes).
      & $this.VenvPython -m pip install --upgrade --force-reinstall "pygls<2" "cmake-language-server==0.1.11" 2>&1 | Out-Null
      if (Test-Path $this.VenvLspExe -PathType Leaf) {
        $this.EnvManager.WriteSuccess("cmake-language-server installed successfully")
        return $true
      }
    }
    catch {
      $this.EnvManager.WriteError("pip install failed: $($_.Exception.Message)")
    }
    return $false
  }

  [int] Run() {
    if (-not $this.EnsureCmake()) {
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }

    if ($this.IsLspInstalled()) {
      $this.EnvManager.WriteSuccess("cmake-language-server is already installed")
      return 0
    }

    if (-not $this.InstallLsp()) {
      $this.EnvManager.WriteError("Failed to install. Please run manually:")
      $this.EnvManager.WriteError("  winget install Python.Python.3.13")
      $this.EnvManager.WriteError("  python -m pip install cmake-language-server")
      $this.EnvManager.WriteError("")
      $this.EnvManager.WriteError("Then ensure the venv exists at:")
      $this.EnvManager.WriteError("  $($this.VenvDir)")
      # Exit code 2: stderr shown to user for Setup hooks
      return 2
    }
    return 0
  }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

[CmakeLspInstaller] $installer = [CmakeLspInstaller]::new()
exit $installer.Run()
