# EnriLSP

**Claude Code plugin marketplace — LSP support for Windows (Python, TypeScript, Go, Rust, C#, and 29 more)**

Runtimes and language servers auto-install via winget on first use. No admin required.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Auto-Installation](#auto-installation)
- [Supported Languages](#supported-languages)
- [LSP Capabilities](#lsp-capabilities)
- [Permissions](#permissions)
- [Manual Installation](#manual-installation)
- [FAQ & Troubleshooting](#faq--troubleshooting)

## Features

| Feature | Description |
|---------|-------------|
| **Auto-install** | Runtimes and LSP servers install on first use |
| **Windows-native** | PowerShell scripts, no bash or WSL required |
| **Clean installations** | Uses winget + AppData paths, no system pollution |
| **34 plugins** | Go, Python, TypeScript, Java, C#, Rust, and [more](#supported-languages) |
| **User-level install** | No admin privileges required |
| **Latest versions** | Always installs the newest stable versions |

## Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Windows** | 10/11 | Windows 10 1809+ |
| **Claude Code** | 2.0.74+ | First version with LSP support |
| **PowerShell** | 5.1+ | Built-in since Windows 10 1607 |
| **winget** | 1.0+ | Built-in on Windows 11; [install on Windows 10](https://aka.ms/getwinget) |

<details>
<summary><strong>Verify winget is available</strong></summary>

```powershell
# Check if winget is available
winget --version

# If not installed, get it from Microsoft Store:
# https://aka.ms/getwinget
```

</details>

## Installation

### Step 1: Add the Marketplace

First, add the EnriLSP marketplace to Claude Code (only needed once):

```
/plugin marketplace add Bedolla/EnriLSP
```

### Step 2: Install Plugins

<details>
<summary><strong>Install a single plugin</strong></summary>

```
/plugin install pyright@EnriLSP
```

</details>

<details>
<summary><strong>Install multiple plugins</strong></summary>

```
/plugin install pyright@EnriLSP vtsls@EnriLSP gopls@EnriLSP
```

</details>

<details>
<summary><strong>Install all 34 plugins at once</strong></summary>

```
/plugin install gopls@EnriLSP vtsls@EnriLSP pyright@EnriLSP clangd@EnriLSP omnisharp@EnriLSP jdtls@EnriLSP kotlin-language-server@EnriLSP intelephense@EnriLSP rust-analyzer@EnriLSP solargraph@EnriLSP vscode-html-css@EnriLSP dart-analyzer@EnriLSP bash-language-server@EnriLSP lua-language-server@EnriLSP yaml-language-server@EnriLSP dockerfile-language-server@EnriLSP terraform-ls@EnriLSP sqls@EnriLSP zls@EnriLSP texlab@EnriLSP vue-language-server@EnriLSP svelte-language-server@EnriLSP graphql-lsp@EnriLSP marksman@EnriLSP postgres-language-server@EnriLSP tailwindcss-language-server@EnriLSP prisma-language-server@EnriLSP astro-language-server@EnriLSP cmake-language-server@EnriLSP angular-language-server@EnriLSP json-language-server@EnriLSP ember-language-server@EnriLSP cssmodules-language-server@EnriLSP powershell-editor-services@EnriLSP
```

</details>

## Auto-Installation

EnriLSP automatically installs missing runtimes and language servers on first use. This means you can install a plugin and start coding immediately - no manual setup required.

### How It Works

1. When Claude Code invokes a plugin, the `check-*.ps1` script runs
2. The script checks if the LSP server is available by looking for executables in known paths
3. If missing, it checks for the required runtime (Go, Python, Node.js, etc.)
4. If the runtime is also missing, it attempts auto-installation via:
   - **winget** (Windows 10+ built-in package manager, user scope)
   - **GitHub releases** (direct binary download as fallback)
5. Once the runtime is installed, the LSP server is installed via the language's package manager (pip, npm, gem, go install, etc.)
6. PATH is updated in both the user registry and current session

### Important: Restart Windows After First Install

After the **first runtime installation**, you may need to **restart Windows** (or log out and log back in) for PATH changes to take full effect in all applications.

## Supported Languages

| Plugin | Languages | Runtime | LSP Server |
|--------|-----------|---------|------------|
| **angular-language-server** | Angular | Node.js | @angular/language-server |
| **astro-language-server** | Astro | Node.js | @astrojs/language-server |
| **bash-language-server** | Bash, Shell | Node.js | bash-language-server |
| **clangd** | C, C++ | LLVM | clangd |
| **cmake-language-server** | CMake | Python | cmake-language-server |
| **cssmodules-language-server** | CSS Modules | Node.js | cssmodules-language-server |
| **dart-analyzer** | Dart, Flutter | Dart SDK | dart language-server |
| **dockerfile-language-server** | Dockerfile | Node.js | dockerfile-language-server-nodejs |
| **ember-language-server** | Ember.js | Node.js | @ember-tooling/ember-language-server |
| **gopls** | Go | Go | gopls |
| **graphql-lsp** | GraphQL | Node.js | graphql-language-service-cli |
| **intelephense** | PHP | Node.js | intelephense |
| **jdtls** | Java | Java 21+ | Eclipse JDT LS |
| **json-language-server** | JSON | Node.js | vscode-json-languageserver |
| **kotlin-language-server** | Kotlin | Java 11+ | kotlin-language-server |
| **lua-language-server** | Lua | Standalone | lua-language-server |
| **marksman** | Markdown | Standalone | marksman |
| **omnisharp** | C# | .NET SDK | csharp-ls |
| **postgres-language-server** | PostgreSQL, SQL | Standalone | postgres-language-server |
| **powershell-editor-services** | PowerShell | Standalone | PowerShellEditorServices |
| **prisma-language-server** | Prisma | Node.js | @prisma/language-server |
| **pyright** | Python | Python | pyright |
| **rust-analyzer** | Rust | Rust/Cargo | rust-analyzer |
| **solargraph** | Ruby | Ruby | solargraph |
| **sqls** | SQL | Standalone | sqls |
| **svelte-language-server** | Svelte | Node.js | svelte-language-server |
| **tailwindcss-language-server** | TailwindCSS | Node.js | @tailwindcss/language-server |
| **terraform-ls** | Terraform, HCL | Standalone | terraform-ls |
| **texlab** | LaTeX, BibTeX | Standalone | texlab |
| **vscode-html-css** | HTML, CSS, SCSS | Node.js | vscode-langservers-extracted |
| **vtsls** | TypeScript, JavaScript | Node.js | vtsls |
| **vue-language-server** | Vue.js | Node.js | @vue/language-server |
| **yaml-language-server** | YAML | Node.js | yaml-language-server |
| **zls** | Zig | Standalone | zls |

## LSP Capabilities

Once installed, Claude Code gains IDE-like intelligence:

| Capability | Description |
|------------|-------------|
| **Diagnostics** | Real-time errors and warnings after each edit |
| **Go to Definition** | Navigate to symbol declarations |
| **Find References** | Locate all usages across the codebase |
| **Hover** | View type information and documentation |

## Permissions

EnriLSP works **without administrator privileges**. All installations use user-level paths:

| Package Manager | Installation Path |
|-----------------|-------------------|
| **winget** | User scope (default) |
| **npm** | `%APPDATA%\npm` |
| **pip** | `%APPDATA%\Python\Scripts` |
| **gem** | `%APPDATA%\gem\bin` |
| **go install** | `%APPDATA%\go\bin` |
| **dotnet tool** | `%USERPROFILE%\.dotnet\tools` |
| **rustup** | `%USERPROFILE%\.cargo\bin` |
| **GitHub download** | `%LOCALAPPDATA%\[lsp-name]` |

## Manual Installation

If auto-install fails, expand the section for your language:

<details>
<summary><strong>Angular (angular-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install angular-language-server
npm install -g @angular/language-server
```

</details>

<details>
<summary><strong>Astro (astro-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install astro-language-server
npm install -g @astrojs/language-server
```

</details>

<details>
<summary><strong>Bash (bash-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install bash-language-server
npm install -g bash-language-server
```

</details>

<details>
<summary><strong>C/C++ (clangd)</strong></summary>

```powershell
# Install LLVM (includes clangd)
winget install LLVM.LLVM

# Restart Windows or refresh PATH
```

</details>

<details>
<summary><strong>C# (csharp-ls)</strong></summary>

```powershell
# Install .NET SDK 10
winget install Microsoft.DotNet.SDK.10

# Install csharp-ls
dotnet tool install -g csharp-ls

# Restart Windows or refresh PATH
```

</details>

<details>
<summary><strong>CMake (cmake-language-server)</strong></summary>

```powershell
# Install Python 3.12+
winget install Python.Python.3.12

# Restart Windows, then install cmake-language-server
pip install --user cmake-language-server
```

</details>

<details>
<summary><strong>CSS Modules (cssmodules-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install cssmodules-language-server
npm install -g cssmodules-language-server
```

</details>

<details>
<summary><strong>Dart/Flutter</strong></summary>

```powershell
# Install Dart SDK
winget install Google.DartSDK

# Or install Flutter (includes Dart)
winget install Google.Flutter

# Restart Windows or refresh PATH
```

</details>

<details>
<summary><strong>Dockerfile (dockerfile-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install dockerfile-language-server
npm install -g dockerfile-language-server-nodejs
```

</details>

<details>
<summary><strong>Ember.js (ember-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install ember-language-server
npm install -g @ember-tooling/ember-language-server
```

</details>

<details>
<summary><strong>Go (gopls)</strong></summary>

```powershell
# Install Go
winget install GoLang.Go

# Restart Windows, then install gopls
go install golang.org/x/tools/gopls@latest
```

</details>

<details>
<summary><strong>GraphQL (graphql-lsp)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install graphql-lsp
npm install -g graphql-language-service-cli
```

</details>

<details>
<summary><strong>HTML/CSS (vscode-langservers)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install language servers
npm install -g vscode-langservers-extracted
```

</details>

<details>
<summary><strong>Java (jdtls)</strong></summary>

```powershell
# Install Microsoft OpenJDK 25
winget install Microsoft.OpenJDK.25

# Download jdtls from:
# https://download.eclipse.org/jdtls/snapshots/
# Extract to %LOCALAPPDATA%\jdtls and add bin to PATH
```

</details>

<details>
<summary><strong>JSON (json-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install json-language-server
npm install -g vscode-json-languageserver
```

</details>

<details>
<summary><strong>Kotlin (kotlin-language-server)</strong></summary>

```powershell
# Install Microsoft OpenJDK 25
winget install Microsoft.OpenJDK.25

# Download kotlin-language-server from:
# https://github.com/fwcd/kotlin-language-server/releases
# Extract to %LOCALAPPDATA%\kotlin-language-server and add bin to PATH
```

</details>

<details>
<summary><strong>LaTeX (texlab)</strong></summary>

```powershell
# Option 1: Install via winget
winget install texlab.texlab

# Option 2: Download from GitHub
# https://github.com/latex-lsp/texlab/releases
# Extract to %LOCALAPPDATA%\texlab and add to PATH
```

</details>

<details>
<summary><strong>Lua (lua-language-server)</strong></summary>

```powershell
# Download from GitHub:
# https://github.com/LuaLS/lua-language-server/releases

# Extract to %LOCALAPPDATA%\lua-language-server
# Add bin folder to PATH
```

</details>

<details>
<summary><strong>Markdown (marksman)</strong></summary>

```powershell
# Download from GitHub:
# https://github.com/artempyanykh/marksman/releases

# Extract marksman.exe to %LOCALAPPDATA%\marksman
# Add to PATH
```

</details>

<details>
<summary><strong>PHP (intelephense)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install intelephense
npm install -g intelephense
```

</details>

<details>
<summary><strong>PostgreSQL (postgres-language-server)</strong></summary>

```powershell
# Download from GitHub:
# https://github.com/supabase-community/postgres-language-server/releases

# Download postgres-language-server_x86_64-pc-windows-msvc
# Rename to postgres-language-server.exe
# Move to %LOCALAPPDATA%\postgres-language-server and add to PATH
```

</details>

<details>
<summary><strong>PowerShell (powershell-editor-services)</strong></summary>

```powershell
# Download from GitHub:
# https://github.com/PowerShell/PowerShellEditorServices/releases

# Download PowerShellEditorServices.zip
# Extract to %LOCALAPPDATA%\PowerShellEditorServices
```

</details>

<details>
<summary><strong>Prisma (prisma-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install prisma-language-server
npm install -g @prisma/language-server
```

</details>

<details>
<summary><strong>Python (pyright)</strong></summary>

```powershell
# Install Python 3.14
winget install Python.Python.3.14

# Restart Windows, then install pyright
pip install pyright
```

</details>

<details>
<summary><strong>Ruby (solargraph)</strong></summary>

```powershell
# Download RubyInstaller from:
# https://rubyinstaller.org/downloads/

# Install to %LOCALAPPDATA%\Ruby
# Then install solargraph:
gem install solargraph
```

</details>

<details>
<summary><strong>Rust (rust-analyzer)</strong></summary>

```powershell
# Install rustup
winget install Rustlang.Rustup

# Restart Windows, then install rust-analyzer
rustup component add rust-analyzer
```

</details>

<details>
<summary><strong>SQL (sqls)</strong></summary>

```powershell
# Install Go
winget install GoLang.Go

# Restart Windows, then install sqls
go install github.com/sqls-server/sqls@latest
```

</details>

<details>
<summary><strong>Svelte (svelte-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install svelte-language-server
npm install -g svelte-language-server
```

</details>

<details>
<summary><strong>TailwindCSS (tailwindcss-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install tailwindcss-language-server
npm install -g @tailwindcss/language-server
```

</details>

<details>
<summary><strong>Terraform (terraform-ls)</strong></summary>

```powershell
# Option 1: Install via winget
winget install Hashicorp.Terraform-LS

# Option 2: Download from GitHub
# https://github.com/hashicorp/terraform-ls/releases
# Extract to %LOCALAPPDATA%\terraform-ls and add to PATH
```

</details>

<details>
<summary><strong>TypeScript/JavaScript (vtsls)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install vtsls
npm install -g @vtsls/language-server
```

</details>

<details>
<summary><strong>Vue (vue-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install vue-language-server
npm install -g @vue/language-server
```

</details>

<details>
<summary><strong>YAML (yaml-language-server)</strong></summary>

```powershell
# Install Node.js LTS
winget install OpenJS.NodeJS.LTS

# Restart Windows, then install yaml-language-server
npm install -g yaml-language-server
```

</details>

<details>
<summary><strong>Zig (zls)</strong></summary>

```powershell
# Option 1: Install via winget
winget install zig.zls

# Option 2: Download from GitHub
# https://github.com/zigtools/zls/releases
# Extract to %LOCALAPPDATA%\zls and add to PATH
```

</details>

## FAQ & Troubleshooting

<details>
<summary><strong>PATH not updated after installation</strong></summary>

Restart Windows or run:

```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
```

</details>

<details>
<summary><strong>winget not found</strong></summary>

Install from Microsoft Store: https://aka.ms/getwinget

Or install via PowerShell:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

</details>

<details>
<summary><strong>npm install fails with permission error</strong></summary>

Ensure npm global prefix is in user space:

```powershell
npm config set prefix "$env:APPDATA\npm"
```

</details>

<details>
<summary><strong>LSP server not starting</strong></summary>

1. Check if the executable exists:
   ```powershell
   Get-Command <lsp-server-name>
   ```
2. Run the check script manually:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\hooks\check-<plugin>.ps1
   ```
3. Check Claude Code logs for errors

</details>

<details>
<summary><strong>Plugin works but slow on first use</strong></summary>

Some LSP servers (especially Java-based ones like jdtls) have a startup time. Subsequent invocations will be faster.

</details>
