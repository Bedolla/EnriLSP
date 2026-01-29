# EnriLSP

Claude Code plugin marketplace providing LSP support for Windows. Includes 33 language server plugins.

Runtimes and language servers are installed automatically via winget when you run `claude --init`. No admin privileges required.

---

## New to Claude Code Plugins? Start Here

<details>
<summary><strong>What is Claude Code?</strong></summary>

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) is Anthropic's command-line tool that integrates Claude AI into your terminal. It can:

- Read and understand your codebase
- Edit files based on your instructions
- Run terminal commands to build, test, and deploy
- Navigate code using search and analysis

Install Claude Code:
```powershell
npm install -g @anthropic-ai/claude-code
```

</details>

<details>
<summary><strong>What are Plugins and Marketplaces?</strong></summary>

### Plugins

Plugins extend Claude Code with additional capabilities:

| Component | Description |
|-----------|-------------|
| Skills | Custom slash commands like `/format` or `/deploy` |
| Agents | Specialized sub-agents for specific tasks |
| Hooks | Automated actions triggered by events |
| MCP Servers | External tool integrations (databases, APIs) |
| LSP Servers | Code intelligence (diagnostics, go-to-definition) |

### Marketplaces

A marketplace is a catalog of plugins. To use one:

1. Add a marketplace - Register the catalog with Claude Code
2. Browse available plugins
3. Install the plugins you need

EnriLSP is a marketplace that provides 33 LSP plugins for Windows.

*Reference: [Claude Code Plugins Documentation](https://code.claude.com/docs/en/discover-plugins)*

</details>

<details>
<summary><strong>What is LSP (Language Server Protocol)?</strong></summary>

### The Problem LSP Solves

Before LSP, every code editor had to implement language features (autocomplete, error checking, go-to-definition) separately for each programming language:

- VS Code needed its own Python support
- Vim needed its own Python support
- Every editor × every language = duplication of effort

### The Solution

LSP (Language Server Protocol) is a standard created by Microsoft that separates:

- Language Server: A program that understands one language
- Editor/Tool: Any tool that wants language features

The language server runs as a separate process and communicates with editors via JSON-RPC. One language server works with any editor that supports LSP.

### What LSP Provides

| Feature | Description |
|---------|-------------|
| Diagnostics | Real-time error and warning detection |
| Go to Definition | Jump to where a function/class is defined |
| Find References | See everywhere a symbol is used |
| Hover Information | Type and documentation information |

### Why LSP Matters for Claude Code

With LSP support, Claude Code gains compiler-level understanding of your code:

- Knows exact types of variables
- Detects errors before you run code
- Understands project structure and imports
- Can navigate to definitions accurately

Without LSP, Claude relies on text pattern matching. With LSP, Claude has the same understanding as an IDE.

*Source: [Language Server Protocol Official Site](https://microsoft.github.io/language-server-protocol/)*

</details>

---

## Table of Contents

- [New to Claude Code Plugins?](#new-to-claude-code-plugins-start-here)
- [Quick Start](#quick-start)
- [Understanding `--init` vs Normal Usage](#understanding---init-vs-normal-usage)
- [How It Works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Updating Plugins](#updating-plugins)
- [Uninstalling](#uninstalling)
- [Command Reference](#command-reference)
- [Auto-Installation](#auto-installation)
- [Supported Languages](#supported-languages)
- [LSP Capabilities](#lsp-capabilities)
- [Permissions](#permissions)
- [Manual Installation](#manual-installation)
- [FAQ & Troubleshooting](#faq--troubleshooting)
- [Version](#version)

---

## Quick Start

Step 1: Add the marketplace (inside Claude Code)
```
/plugin marketplace add Bedolla/EnriLSP
```

Step 2: Install the plugins you need (inside Claude Code)
```
/plugin install pyright@EnriLSP       # Python
/plugin install vtsls@EnriLSP         # TypeScript/JavaScript
/plugin install gopls@EnriLSP         # Go
/plugin install rust-analyzer@EnriLSP # Rust
/plugin install omnisharp@EnriLSP     # C#
```

Step 3: Run setup once to install dependencies
```
/exit
```
Then in your terminal (PowerShell):
```powershell
claude --init
```

Step 4: Normal daily use
```powershell
claude
```

> Note: You only need `--init` once after installing plugins. For daily use, run `claude`. The LSP servers start automatically.

---

## Understanding `--init` vs Normal Usage

| Command | What it does | When to use |
|---------|--------------|-------------|
| `claude --init` | Runs setup hooks to install runtimes and LSP servers | Once after installing new plugins |
| `claude` | Starts Claude Code with LSP servers already running | Daily use |


### When do I need to run `--init` again?

| Scenario | Need `--init`? |
|----------|----------------|
| Daily use | No |
| After installing a new plugin | Yes |
| After updating plugins | Yes (recommended) |
| After Windows restart | No |
| After updating Claude Code | No |

---

## How It Works

### One-time setup (`claude --init`)

1. Setup Hook runs for each installed plugin
   - Checks if language server is installed
   - If missing, auto-installs via winget/pip/npm
   - Adds to PATH

2. Dependencies are now installed on your system
   - Python + pyright
   - Node.js + typescript-language-server
   - Go + gopls
   - etc.

### Daily use (`claude`)

1. Claude Code reads `.lsp.json` from installed plugins
   - Finds pyright, gopls, rust-analyzer, etc.
   - Automatically starts each LSP server

2. LSP Servers connect and provide intelligence
   - Real-time error detection
   - Go-to-definition
   - Type information

3. Claude gains deep code understanding
   - Sees exact types and errors
   - Navigates code like an IDE
   - Makes precise, context-aware edits

> The `--init` flag installs the tools. Claude Code automatically uses them every time you run `claude`.

### Plugin Structure

Each plugin contains:

```
pyright/
├── .claude-plugin/
│   └── plugin.json       # Plugin metadata
├── .lsp.json             # LSP server configuration
└── hooks/
    ├── hooks.json        # Setup hook definition
    └── check-pyright.ps1 # Installation script
```

| File | Purpose |
|------|---------|
| `plugin.json` | Name, version, author |
| `.lsp.json` | Tells Claude Code how to connect to the LSP server |
| `hooks.json` | Triggers installation on `claude --init` |
| `check-*.ps1` | PowerShell script that installs runtime + LSP server |

## Features

| Feature | Description |
|---------|-------------|
| Auto-install | Runtimes and LSP servers install when you run `claude --init` |
| Windows-native | PowerShell scripts, no bash or WSL required |
| User-level paths | Uses winget + AppData paths, does not require admin |
| 33 plugins | Go, Python, TypeScript, Java, C#, Rust, and [more](#supported-languages) |

## Requirements

| Requirement | Version | Notes |
|-------------|---------|-------|
| Windows | 10/11 | Windows 10 1809+ |
| Claude Code | 1.0.33+ | Requires plugin support ([install](https://www.npmjs.com/package/@anthropic-ai/claude-code)) |
| PowerShell | 5.1+ | Built-in since Windows 10 1607 |
| winget | 1.0+ | Built-in on Windows 11; [install on Windows 10](https://aka.ms/getwinget) |

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

There are two ways to run plugin commands:

| Method | Where | Syntax |
|--------|-------|--------|
| Interactive | Inside Claude Code session | `/plugin ...` |
| CLI | Terminal/PowerShell (outside Claude Code) | `claude plugin ...` |

Both methods are equivalent. Examples below show both syntaxes.

### Step 1: Add the Marketplace

Add the EnriLSP marketplace (only needed once):

Interactive (inside Claude Code):
```
/plugin marketplace add Bedolla/EnriLSP
```

CLI (in terminal):
```powershell
claude plugin marketplace add Bedolla/EnriLSP
```

### Step 2: Install Plugins

<details>
<summary><strong>Install a single plugin</strong></summary>

Interactive:
```
/plugin install pyright@EnriLSP
```

CLI:
```powershell
claude plugin install pyright@EnriLSP
```

</details>

<details>
<summary><strong>Install multiple plugins</strong></summary>

Interactive:
```
/plugin install pyright@EnriLSP
/plugin install vtsls@EnriLSP
/plugin install gopls@EnriLSP
```

CLI:
```powershell
claude plugin install pyright@EnriLSP
claude plugin install vtsls@EnriLSP
claude plugin install gopls@EnriLSP
```

</details>

<details>
<summary><strong>Install with a specific scope</strong></summary>

Plugins can be installed to different scopes:

| Scope | Description | Flag |
|-------|-------------|------|
| `user` | Personal, available across all projects (default) | `--scope user` |
| `project` | Shared with team via version control | `--scope project` |
| `local` | Project-specific, gitignored | `--scope local` |

CLI examples:
```powershell
# Install for yourself (default)
claude plugin install pyright@EnriLSP

# Install for team (adds to .claude/settings.json)
claude plugin install pyright@EnriLSP --scope project

# Install locally only (gitignored)
claude plugin install pyright@EnriLSP --scope local
```

Interactive: Use `/plugin`, go to the Discover tab, select a plugin, and choose the scope.

</details>

<details>
<summary><strong>Install all 33 plugins</strong></summary>

**CLI (copy and paste into terminal):**

```powershell
claude plugin marketplace add Bedolla/EnriLSP
claude plugin install angular-language-server@EnriLSP
claude plugin install astro-language-server@EnriLSP
claude plugin install bash-language-server@EnriLSP
claude plugin install clangd@EnriLSP
claude plugin install cmake-language-server@EnriLSP
claude plugin install cssmodules-language-server@EnriLSP
claude plugin install dart-analyzer@EnriLSP
claude plugin install dockerfile-language-server@EnriLSP
claude plugin install ember-language-server@EnriLSP
claude plugin install gopls@EnriLSP
claude plugin install graphql-lsp@EnriLSP
claude plugin install intelephense@EnriLSP
claude plugin install jdtls@EnriLSP
claude plugin install kotlin-language-server@EnriLSP
claude plugin install lua-language-server@EnriLSP
claude plugin install marksman@EnriLSP
claude plugin install omnisharp@EnriLSP
claude plugin install postgres-language-server@EnriLSP
claude plugin install powershell-editor-services@EnriLSP
claude plugin install prisma-language-server@EnriLSP
claude plugin install pyright@EnriLSP
claude plugin install rust-analyzer@EnriLSP
claude plugin install solargraph@EnriLSP
claude plugin install sqls@EnriLSP
claude plugin install svelte-language-server@EnriLSP
claude plugin install tailwindcss-language-server@EnriLSP
claude plugin install terraform-ls@EnriLSP
claude plugin install texlab@EnriLSP
claude plugin install vscode-langservers@EnriLSP
claude plugin install vtsls@EnriLSP
claude plugin install vue-language-server@EnriLSP
claude plugin install yaml-language-server@EnriLSP
claude plugin install zls@EnriLSP
```

**Interactive (inside Claude Code):**

```
/plugin install angular-language-server@EnriLSP
/plugin install astro-language-server@EnriLSP
/plugin install bash-language-server@EnriLSP
/plugin install clangd@EnriLSP
/plugin install cmake-language-server@EnriLSP
/plugin install cssmodules-language-server@EnriLSP
/plugin install dart-analyzer@EnriLSP
/plugin install dockerfile-language-server@EnriLSP
/plugin install ember-language-server@EnriLSP
/plugin install gopls@EnriLSP
/plugin install graphql-lsp@EnriLSP
/plugin install intelephense@EnriLSP
/plugin install jdtls@EnriLSP
/plugin install kotlin-language-server@EnriLSP
/plugin install lua-language-server@EnriLSP
/plugin install marksman@EnriLSP
/plugin install omnisharp@EnriLSP
/plugin install postgres-language-server@EnriLSP
/plugin install powershell-editor-services@EnriLSP
/plugin install prisma-language-server@EnriLSP
/plugin install pyright@EnriLSP
/plugin install rust-analyzer@EnriLSP
/plugin install solargraph@EnriLSP
/plugin install sqls@EnriLSP
/plugin install svelte-language-server@EnriLSP
/plugin install tailwindcss-language-server@EnriLSP
/plugin install terraform-ls@EnriLSP
/plugin install texlab@EnriLSP
/plugin install vscode-langservers@EnriLSP
/plugin install vtsls@EnriLSP
/plugin install vue-language-server@EnriLSP
/plugin install yaml-language-server@EnriLSP
/plugin install zls@EnriLSP
```

</details>

### Step 3: Run Setup (First Time Only)

After installing plugins, run the setup command to install missing runtimes and LSP servers:

```powershell
claude --init
```

This triggers the installation scripts for all installed plugins.

> After this, use `claude` for daily work. LSP servers start automatically.

### Step 4: Daily Use

```powershell
claude
```

That's it. Claude Code will automatically start all your LSP servers.

## Updating Plugins

Plugins are not updated automatically. When EnriLSP releases updates, you need to update manually.

### Update a single plugin

Interactive:
```
/plugin update pyright@EnriLSP
```

CLI:
```powershell
claude plugin update pyright@EnriLSP
```

After updating, run `claude --init` once to apply any new setup scripts, then use `claude` normally.

## Uninstalling

### Uninstall a single plugin

Interactive:
```
/plugin uninstall pyright@EnriLSP
```

CLI:
```powershell
claude plugin uninstall pyright@EnriLSP
```

### Uninstall multiple plugins

Run each command separately:

Interactive:
```
/plugin uninstall pyright@EnriLSP
/plugin uninstall vtsls@EnriLSP
/plugin uninstall gopls@EnriLSP
```

CLI:
```powershell
claude plugin uninstall pyright@EnriLSP
claude plugin uninstall vtsls@EnriLSP
claude plugin uninstall gopls@EnriLSP
```

### Disable a plugin (without uninstalling)

If you want to temporarily disable a plugin without removing it:

Interactive:
```
/plugin disable pyright@EnriLSP
```

CLI:
```powershell
claude plugin disable pyright@EnriLSP
```

To re-enable it later:

Interactive:
```
/plugin enable pyright@EnriLSP
```

CLI:
```powershell
claude plugin enable pyright@EnriLSP
```

### Remove the entire EnriLSP marketplace

To completely remove EnriLSP and all plugins installed from it:

Interactive:
```
/plugin marketplace remove EnriLSP
```

CLI:
```powershell
claude plugin marketplace remove EnriLSP
```

> Warning: Removing a marketplace will automatically uninstall all plugins you installed from it.

### What gets removed

| Command | What's Removed |
|---------|----------------|
| `plugin uninstall <plugin>@EnriLSP` | Only the specified plugin |
| `plugin marketplace remove EnriLSP` | The marketplace + ALL its installed plugins |

> Note: Uninstalling plugins does not remove the runtimes or LSP server binaries that were installed (Python, Node.js, gopls, etc.). These remain on your system. To remove them, use `winget uninstall <package>` or manually delete from their installation paths.

## Command Reference

Complete list of plugin commands according to the [official Claude Code documentation](https://code.claude.com/docs/en/plugins-reference).

### Marketplace commands

| Action | Interactive | CLI |
|--------|-------------|-----|
| Add | `/plugin marketplace add <source>` | `claude plugin marketplace add <source>` |
| List | `/plugin marketplace list` | `claude plugin marketplace list` |
| Update | `/plugin marketplace update <name>` | `claude plugin marketplace update <name>` |
| Remove | `/plugin marketplace remove <name>` | `claude plugin marketplace remove <name>` |

Shortcuts: `/plugin market` = `/plugin marketplace`, `rm` = `remove`

### Plugin commands

| Action | Interactive | CLI |
|--------|-------------|-----|
| Install | `/plugin install <plugin>@<marketplace>` | `claude plugin install <plugin>@<marketplace>` |
| Uninstall | `/plugin uninstall <plugin>@<marketplace>` | `claude plugin uninstall <plugin>@<marketplace>` |
| Enable | `/plugin enable <plugin>@<marketplace>` | `claude plugin enable <plugin>@<marketplace>` |
| Disable | `/plugin disable <plugin>@<marketplace>` | `claude plugin disable <plugin>@<marketplace>` |
| Update | `/plugin update <plugin>@<marketplace>` | `claude plugin update <plugin>@<marketplace>` |

CLI options:

| Option | Description |
|--------|-------------|
| `--scope user` | Install for yourself across all projects (default) |
| `--scope project` | Install for team (adds to `.claude/settings.json`) |
| `--scope local` | Install for yourself in this project only (gitignored) |

### Interactive UI

Run `/plugin` to open the plugin manager with tabs:

| Tab | Description |
|-----|-------------|
| Discover | Browse available plugins from all marketplaces |
| Installed | View and manage installed plugins |
| Marketplaces | Add, remove, or update marketplaces |
| Errors | View plugin loading errors |

Use Tab to switch between tabs, type to filter, Enter to select.

## Auto-Installation

EnriLSP uses Setup hooks to automatically install missing runtimes and language servers. This happens only once when you run `claude --init` — after that, just use `claude` normally.

### How it works

1. You run `claude --init` after installing plugins
2. Each plugin's `check-*.ps1` script runs and checks if the LSP server is available
3. If missing, it checks for the required runtime (Go, Python, Node.js, etc.)
4. If the runtime is also missing, it attempts auto-installation via:
   - winget (Windows 10+ built-in package manager, user scope)
   - GitHub releases (direct binary download as fallback)
5. Once the runtime is installed, the LSP server is installed via the language's package manager (pip, npm, gem, go install, etc.)
6. PATH is updated in both the user registry and current session

### When to run `--init`

| Scenario | Command | Frequency |
|----------|---------|-----------|
| First time after installing plugins | `claude --init` | Once |
| After installing new plugins | `claude --init` | Once per new plugin |
| After updating plugins | `claude --init` | Recommended |
| Daily use | `claude` | Always |

> Note: `--init` installs dependencies. After that, just run `claude`. LSP servers start automatically.

### Alternative: `--init-only`

If you want to run the setup hooks without starting an interactive session, use:

```powershell
claude --init-only
```

This is useful for CI/CD pipelines or automated setup scripts.

### Windows Restart and Environment Variables

#### When do I need to restart Windows?

| Installed via | Restart needed? | Why |
|---------------|-----------------|-----|
| winget (Node.js, Python, Go, .NET, Java, Rust, etc.) | Yes, first time only | winget modifies system PATH which requires restart/logoff |
| npm global (LSP servers) | No | Scripts update current session PATH |
| pip (LSP servers) | No | Scripts update current session PATH |
| go install (gopls, sqls) | No | Scripts update current session PATH |

> In practice: If you're installing runtimes for the first time (Node.js, Python, Go, etc.), restart Windows once after `claude --init`. After that, no more restarts needed.

#### Environment variables set automatically

Some plugins configure environment variables for you:

| Plugin | Variable | Value | Purpose |
|--------|----------|-------|---------|
| gopls | `GOPATH` | `%APPDATA%\go` | Go workspace location |
| rust-analyzer | `CARGO_HOME` | `%APPDATA%\cargo` | Cargo installation directory |
| rust-analyzer | `RUSTUP_HOME` | `%APPDATA%\rustup` | Rustup installation directory |

These are set automatically by the setup hooks — you don't need to configure them manually.

#### Quick fix if PATH isn't working

If after running `claude --init` the LSP servers aren't found, refresh your PATH without restarting:

PowerShell:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
```

Or: Close and reopen your terminal, then run `claude`.

## Supported Languages

| Plugin | Languages | Runtime | LSP Server |
|--------|-----------|---------|------------|
| angular-language-server | Angular | Node.js | @angular/language-server |
| astro-language-server | Astro | Node.js | @astrojs/language-server |
| bash-language-server | Bash, Shell | Node.js | bash-language-server |
| clangd | C, C++ | LLVM | clangd |
| cmake-language-server | CMake | Python | cmake-language-server |
| cssmodules-language-server | CSS Modules | Node.js | cssmodules-language-server |
| dart-analyzer | Dart, Flutter | Dart SDK | dart language-server |
| dockerfile-language-server | Dockerfile | Node.js | dockerfile-language-server-nodejs |
| ember-language-server | Ember.js | Node.js | @ember-tooling/ember-language-server |
| gopls | Go | Go | gopls |
| graphql-lsp | GraphQL | Node.js | graphql-language-service-cli |
| intelephense | PHP | Node.js | intelephense |
| jdtls | Java | Java 21+ | Eclipse JDT LS |
| kotlin-language-server | Kotlin | Java 11+ | kotlin-language-server |
| lua-language-server | Lua | Standalone | lua-language-server |
| marksman | Markdown | Standalone | marksman |
| omnisharp | C# | .NET SDK | csharp-ls |
| postgres-language-server | PostgreSQL, SQL | Standalone | postgres-language-server |
| powershell-editor-services | PowerShell | Standalone | PowerShellEditorServices |
| prisma-language-server | Prisma | Node.js | @prisma/language-server |
| pyright | Python | Python | pyright |
| rust-analyzer | Rust | Rust/Cargo | rust-analyzer |
| solargraph | Ruby | Ruby | solargraph |
| sqls | SQL | Standalone | sqls |
| svelte-language-server | Svelte | Node.js | svelte-language-server |
| tailwindcss-language-server | TailwindCSS | Node.js | @tailwindcss/language-server |
| terraform-ls | Terraform, HCL | Standalone | terraform-ls |
| texlab | LaTeX, BibTeX | Standalone | texlab |
| vscode-langservers | HTML, CSS, JSON, ESLint | Node.js | vscode-langservers-extracted |
| vtsls | TypeScript, JavaScript | Node.js | vtsls |
| vue-language-server | Vue.js | Node.js | @vue/language-server |
| yaml-language-server | YAML | Node.js | yaml-language-server |
| zls | Zig | Standalone | zls |

## LSP Capabilities

Once installed, Claude Code gains IDE-like intelligence:

| Capability | Description |
|------------|-------------|
| Diagnostics | Real-time errors and warnings after each edit |
| Go to Definition | Navigate to symbol declarations |
| Find References | Locate all usages across the codebase |
| Hover | View type information and documentation |

## Permissions

EnriLSP works without administrator privileges. All installations use user-level paths:

| Package Manager | Installation Path |
|-----------------|-------------------|
| winget | User scope (default) |
| npm | `%APPDATA%\npm` |
| pip | `%APPDATA%\Python\Scripts` |
| gem | `%APPDATA%\gem\bin` |
| go install | `%APPDATA%\go\bin` |
| dotnet tool | `%USERPROFILE%\.dotnet\tools` |
| rustup | `%USERPROFILE%\.cargo\bin` |
| GitHub download | `%LOCALAPPDATA%\[lsp-name]` |

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
<summary><strong>HTML/CSS/JSON/ESLint (vscode-langservers)</strong></summary>

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
<summary><strong>Do I need to run `--init` every time?</strong></summary>

No. You only need `--init` once after installing new plugins. For daily use, just run `claude`. The LSP servers start automatically.

| When | Command |
|------|---------|
| After installing new plugins | `claude --init` (once) |
| Daily use | `claude` |

</details>

<details>
<summary><strong>Do I need to restart Windows?</strong></summary>

Only once, after the first time you install runtimes (Node.js, Python, Go, etc.) via winget.

After that, no more restarts needed. The setup scripts update the current session PATH automatically.

Quick fix without restart:
```powershell
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
```

</details>

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
<summary><strong>Plugin works but slow on first run</strong></summary>

Some LSP servers (especially Java-based ones like jdtls) have a startup time. Subsequent runs will be faster.

</details>

---

## Version

| Component | Version |
|-----------|---------|
| EnriLSP Marketplace | 1.0.0 |
| Tested with Claude Code | 1.0.33+ |
| Plugins | 33 |
