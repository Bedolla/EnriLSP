# EnriLSP

EnriLSP is a **Model Context Protocol (MCP)** server over `stdio` that bridges to one or more **Language Server Protocol (LSP)** servers.

If your client can run MCP tools, it can use LSP-style features (definition, references, rename, diagnostics) even if that client does not support LSP directly.

## What this project is

- An MCP server process your MCP host launches (OpenCode, Claude Code, Codex, etc.)
- An internal LSP client that spawns language servers
- A routing layer that chooses which server handles which file

## What this project is NOT

- Not an IDE plugin
- Not an LSP server itself
- Not able to work with remote files unless EnriLSP runs on the machine that has those files

## Requirements

- Node.js `>= 22` (recommended: Node 24 LTS)
- Language servers installed locally (or use `installers/` on Windows)

## Install

```powershell
# Recommended: global install
npm install -g enrilsp

# Or run without installing (downloads a temporary copy)
npx -y enrilsp@latest --help
```

## Build

```powershell
npm install
npm run typecheck
npm run build
```

## Usage

### 1) Create a config file

If you want a ready-to-copy starting point, this repo includes example configs:

- `enrilsp.config.example.json` (minimal)
- `enrilsp.config.all.example.json` (large preset list)

Per-project config (recommended, creates `.enrilsp.json` in the current directory):

```powershell
cd C:\path\to\your\project
enrilsp setup
```

User-global config (written to `~/.Enri/EnriLSP/Config.json`):

```powershell
enrilsp menu --print-config-path
enrilsp menu
```

### 2) Configure your MCP host

EnriLSP runs as an MCP server over `stdio`. Your MCP host is responsible for launching the process.

Example: Claude Code / Claude Desktop (global npm install)

```jsonc
{
  "EnriLSP": {
    "type": "stdio",
    "command": "enrilsp",
    "args": [],
    "env": {
      "ENRILSP_CONFIG_PATH": "C:\\path\\to\\your\\project\\.enrilsp.json"
    }
  }
}
```

Example: no install (always uses whatever npm currently tags as `latest`)

```jsonc
{
  "EnriLSP": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "enrilsp@latest"],
    "env": {
      "ENRILSP_CONFIG_PATH": "C:\\path\\to\\your\\project\\.enrilsp.json"
    }
  }
}
```

<details>
<summary>More MCP host config patterns</summary>

Pin a specific version for reproducibility (recommended for teams):

```jsonc
{
  "EnriLSP": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "enrilsp@0.1.0"],
    "env": {
      "ENRILSP_CONFIG_PATH": "C:\\path\\to\\your\\project\\.enrilsp.json"
    }
  }
}
```

Use a local dev checkout:

```jsonc
{
  "EnriLSP": {
    "type": "stdio",
    "command": "node",
    "args": ["C:\\Users\\Administrator\\Projects\\EnriLSP\\dist\\index.js"],
    "env": {
      "ENRILSP_CONFIG_PATH": "C:\\path\\to\\your\\project\\.enrilsp.json"
    }
  }
}
```

</details>

### 3) Call MCP tools from your client

EnriLSP exposes tools like `find_definition`, `find_references`, and `rename_symbol`.
Your client must call them explicitly (MCP is tool-based; there is no automatic "go to definition mode").

## Configuration

### Config resolution order

EnriLSP loads config from (in this order):

1) `ENRILSP_CONFIG_PATH` (if set), otherwise
2) `.enrilsp.json` / `enrilsp.json` in the current working directory, otherwise
3) User config: `~/.Enri/EnriLSP/Config.json`

### Minimal config example (C#)

```jsonc
{
  "servers": [
    {
      "name": "csharp-ls",
      "extensions": ["cs", "csx"],
      "command": ["%USERPROFILE%\\.dotnet\\tools\\csharp-ls.exe", "--stdio", "--loglevel", "error"],
      "rootDir": "C:\\path\\to\\your\\project",
      "warmupMs": 500
    }
  ]
}
```

<details>
<summary>Config fields (option-by-option)</summary>

Top-level:

- `servers` (`EnriLspServerConfig[]`, required): list of server definitions.

Per server:

- `name` (`string`, optional): friendly label (mostly for logs).
- `extensions` (`string[]`, required): routing tokens (without the dot).
  - Simple: `"cs"`, `"ts"`, `"json"`, `"yaml"`
  - Compound: `"module.css"`, `"d.ts"`
  - Filename token (extensionless): `"dockerfile"`, `"gitignore"`
- `command` (`string[]`, required): argv array to start the LSP server.
  - `command[0]` is the executable
  - The server must speak LSP over stdio (usually `--stdio`)
- `rootDir` (`string`, optional): workspace root for that server.
  - If omitted, EnriLSP will try to auto-detect a workspace root from the file path.
- `initializationOptions` (`unknown`, optional): forwarded to the LSP `initialize` request.
- `warmupMs` (`number`, optional): delay after `initialized` (some servers need time on Windows).

Windows note:

- LSP servers are spawned with a shell on Windows, so `%APPDATA%` / `%USERPROFILE%` inside `command` will expand.

</details>

<details>
<summary>Workspace root (rootDir) auto-detection rules</summary>

If `rootDir` is not set for a server, EnriLSP walks up from the file's folder and uses the first match:

- C# / .NET: `*.sln`, `*.csproj`, `*.fsproj`
- TypeScript/JavaScript/Web: `package.json`, `tsconfig.json`
- Python: `pyproject.toml`, `setup.py`, `requirements.txt`, `Pipfile`
- Rust: `Cargo.toml`
- Go: `go.mod`
- Java/Kotlin: `pom.xml`, `build.gradle`, `settings.gradle`, `gradlew`
- Generic fallback: `.git`

If nothing is found, it uses the file's folder.

</details>

<details>
<summary>File routing rules (extensions, compound extensions, aliases)</summary>

Routing keys EnriLSP considers for a file:

- Extension: `Program.cs` -> `cs`
- Compound extension: `styles.module.css` -> `module.css`, `types.d.ts` -> `d.ts`
- Filename tokens:
  - `Dockerfile` and `Dockerfile.*` map to `dockerfile`
  - `.gitignore` and `.gitignore.*` map to `gitignore`

For extensionless files like `Dockerfile`, configure the server using the canonical token in `extensions` (example: `"dockerfile"`).

</details>

<details>
<summary>Windows paths in JSON (why you see double backslashes)</summary>

In JSON, `\\` is how you represent a literal `\`.

- Good: `"C:\\Users\\Fer\\project\\file.cs"`
- Also good (often easier): `"C:/Users/Fer/project/file.cs"` (Node handles forward slashes on Windows)

</details>

<details>
<summary>Automation for TypeScript-family servers (auto tsdk)</summary>

Some TS-family language servers need `initializationOptions.typescript.tsdk` to point at a TypeScript install.

EnriLSP will auto-inject `initializationOptions.typescript.tsdk` if:

- The server looks TS-family (by name or by extensions like `ts/tsx/js/jsx/vue/svelte/astro`)
- And TypeScript can be resolved from the workspace root
- Or (on Windows) from `%APPDATA%\\npm\\node_modules`

If you set `initializationOptions.typescript.tsdk` yourself in config, EnriLSP does not override it.

</details>

## MCP tools

EnriLSP exposes these MCP tools:

- `find_definition`
- `find_references`
- `rename_symbol`
- `get_diagnostics`
- `restart_servers`

<details>
<summary>Tool inputs (option-by-option)</summary>

General notes (applies to every tool):

- All tools accept a single JSON object as their input (the MCP `arguments` for that tool).
- All paths are **local disk paths** on the machine where EnriLSP runs.
- `file_path` can be absolute or relative:
  - Absolute paths are recommended (most reliable).
  - Relative paths are resolved relative to the EnriLSP process working directory (which depends on your MCP host).
- Most tools accept `symbol_name`/`symbol_kind` because MCP hosts commonly do not provide a cursor position.
  - EnriLSP currently resolves symbols by querying the LSP server for **document symbols** (declarations) in the provided file.
  - This means the `file_path` should usually be the file that **declares** the symbol, not just a random file where it is used.

`symbol_kind` values (case-insensitive, optional filter):

EnriLSP uses LSP `SymbolKind` names. Common ones:

- `class`, `interface`, `struct`, `enum`
- `method`, `function`, `constructor`, `property`, `field`, `variable`, `constant`
- Also supported: `namespace`, `module`, `package`, `event`, `operator`, `typeParameter`, `enumMember`, etc.

---

### `find_definition`

Find definition location(s) for one or more matching declarations in a file.

Inputs:

- `file_path` (`string`, required)
  - Path to the file on disk (prefer absolute).
  - Used for routing (which LSP server to use) and for the LSP document URI.
- `symbol_name` (`string`, required)
  - Exact symbol name to match (case-sensitive; must match what the LSP reports).
  - Important: EnriLSP matches against **document symbols** in `file_path` (declarations), not arbitrary text.
- `symbol_kind` (`string`, optional)
  - Narrows matches when multiple declarations share the same name.
  - Example: `"method"` vs `"property"`.

Behavior notes:

- If multiple declarations match, EnriLSP will query definition for each one and return multiple result blocks.
- If no declaration matches, EnriLSP returns a warning and a "No symbols found" message.

Example `arguments` object:

```jsonc
{
  "file_path": "C:\\path\\to\\project\\Program.cs",
  "symbol_name": "MyClass",
  "symbol_kind": "class"
}
```

---

### `find_references`

Find references for one or more matching declarations in a file (workspace-wide, if the server supports it).

Inputs:

- `file_path` (`string`, required): same semantics as `find_definition`.
- `symbol_name` (`string`, required): same semantics as `find_definition`.
- `symbol_kind` (`string`, optional): same semantics as `find_definition`.
- `include_declaration` (`boolean`, optional, default `true`)
  - If `true`, the declaration location may be included among the returned references (depends on the server).
  - If `false`, EnriLSP requests references excluding the declaration.

Behavior notes:

- If multiple declarations match, EnriLSP will run a references query for each one and return multiple blocks.

Example `arguments` object:

```jsonc
{
  "file_path": "C:\\path\\to\\project\\Program.cs",
  "symbol_name": "MyClass",
  "symbol_kind": "class",
  "include_declaration": false
}
```

---

### `rename_symbol`

Rename a symbol (via LSP `textDocument/rename`) and optionally apply the returned `WorkspaceEdit` to disk.

Inputs:

- `file_path` (`string`, required): same semantics as `find_definition`.
- `symbol_name` (`string`, required): same semantics as `find_definition`.
- `new_name` (`string`, required)
  - New symbol name to request from the LSP server.
- `symbol_kind` (`string`, optional)
  - Strongly recommended when the same symbol name exists multiple times in the file.
  - Unlike other tools, `rename_symbol` requires the match to be unambiguous.
- `dry_run` (`boolean`, optional, default `false`)
  - If `true`, EnriLSP will request the rename edit from the server but will NOT write files.
  - Current behavior: EnriLSP returns a **summary** (files touched count), not the full patch.
  - If `false`, EnriLSP applies the edit to disk and creates `*.bak` backups next to modified files.

Behavior notes:

- If more than one declaration matches `symbol_name`, EnriLSP refuses to rename and prints candidate locations.
- Applying edits writes to disk and then re-syncs the modified files back into the running LSP server(s).

Example `arguments` object:

```jsonc
{
  "file_path": "C:\\path\\to\\project\\Program.cs",
  "symbol_name": "MyClass",
  "symbol_kind": "class",
  "new_name": "MyRenamedClass",
  "dry_run": true
}
```

---

### `get_diagnostics`

Get the latest diagnostics EnriLSP has seen for a file from the configured server(s).

Inputs:

- `file_path` (`string`, required)
  - EnriLSP opens the file in the relevant server(s) and then returns the most recently published diagnostics.

Behavior notes:

- Some servers publish diagnostics asynchronously. If you get "No diagnostics." immediately after opening,
  call the tool again after a short wait.

Example `arguments` object:

```jsonc
{
  "file_path": "C:\\path\\to\\project\\Program.cs"
}
```

---

### `restart_servers`

Kill running LSP server process(es). They will be started again on-demand during the next tool call.

Inputs:

- `extensions` (`string[]`, optional)
  - Filters which running servers to restart.
  - EnriLSP matches against the `extensions` array in your config.
  - If omitted, EnriLSP restarts all currently-running servers.

Example `arguments` object:

```jsonc
{
  "extensions": ["cs", "ts"]
}
```

</details>

## Windows installers / presets

On Windows, `installers/*.ps1` can install language servers and runtimes.

- Use `enrilsp menu` to interactively select presets, run installers, and write `~/.Enri/EnriLSP/Config.json`.
- Installer caches and downloaded binaries typically live under `%LOCALAPPDATA%\\EnriLSP`.
- For the full preset list: `enrilsp menu --help`

Cleanup:

```powershell
enrilsp prune --list
enrilsp prune --dry-run
enrilsp prune --yes --all
```

## Troubleshooting

<details>
<summary>Config not found ("EnriLSP config not found ...")</summary>

EnriLSP could not find a config file. It searches (in order):

1) `ENRILSP_CONFIG_PATH`
2) `.enrilsp.json` / `enrilsp.json` in the current directory
3) `~/.Enri/EnriLSP/Config.json`

Fix options:

- Generate a per-project config:

```powershell
cd C:\path\to\your\project
enrilsp setup
```

- Or generate a user-global config via menu:

```powershell
enrilsp menu
```

- Or explicitly point EnriLSP at the config from your MCP host via env:
  - PowerShell example: `$env:ENRILSP_CONFIG_PATH = "C:\\path\\to\\project\\.enrilsp.json"`

</details>

<details>
<summary>No LSP server configured for file ("No LSP server configured for file: ...")</summary>

Your config has no server whose `extensions` match the file you are asking about.

Fix:

- Add a server entry whose `extensions` include the right routing token(s).

Examples:

- `Program.cs` -> add `"cs"`
- `types.d.ts` -> add `"d.ts"` (compound extension)
- `styles.module.css` -> add `"module.css"` (compound extension, useful for css-modules server)
- `Dockerfile` / `Dockerfile.dev` -> add `"dockerfile"`
- `.gitignore` / `.gitignore.local` -> add `"gitignore"`

If you are on Windows, the fastest way is usually:

```powershell
enrilsp menu
```

</details>

<details>
<summary>LSP server exits immediately ("[EnriLSP] LSP server exited: ...")</summary>

EnriLSP started the LSP process, but the server exited (wrong command, missing runtime, missing args, etc.).

Checklist:

- Ensure the server command is correct and includes stdio mode (typically `--stdio`).
- Run the exact `command` from your config directly in a terminal to see its error output.
- On Windows, many npm-installed servers are `*.cmd` shims. Use `cmd.exe /c ...` in the `command` array (the presets already do this).

Example pattern for npm-based servers on Windows:

```jsonc
{
  "command": ["cmd.exe", "/c", "%APPDATA%\\npm\\vtsls.cmd", "--stdio"]
}
```

</details>

<details>
<summary>TypeScript-family servers complain about tsdk / cannot find TypeScript</summary>

Some TS-family servers need `initializationOptions.typescript.tsdk` to point at a TypeScript install.

EnriLSP tries to auto-inject `typescript.tsdk` if it can resolve TypeScript from:

- The workspace root, or
- On Windows: `%APPDATA%\\npm\\node_modules`

Fix options (pick one):

- Install TypeScript in the project (recommended):

```powershell
cd C:\path\to\your\project
npm install -D typescript
```

- Or install TypeScript globally (Windows):

```powershell
npm install -g typescript
```

- Or set it manually in your EnriLSP config:

```jsonc
{
  "initializationOptions": {
    "typescript": {
      "tsdk": "%APPDATA%\\npm\\node_modules\\typescript\\lib"
    }
  }
}
```

</details>

<details>
<summary>rename_symbol: "Multiple symbols match" / renames the wrong thing</summary>

`rename_symbol` is name-based: if multiple symbols in the file match `symbol_name`, EnriLSP refuses and asks you to narrow it.

Fix:

- Provide `symbol_kind` (examples: `class`, `method`, `function`, `interface`, `property`).
- Use a more specific symbol name (or rename in a smaller file scope).

Also note:

- Not all LSP servers support rename. If the server does not advertise rename capability, rename will fail for that file.

</details>

<details>
<summary>menu/prune require a TTY (interactive terminal)</summary>

- `enrilsp menu` needs an interactive terminal (TTY). If you run it in a non-interactive environment, it will fail.
- `enrilsp prune` can be non-interactive, but requires explicit confirmation flags.

Non-interactive prune examples:

```powershell
enrilsp prune --list
enrilsp prune --yes --all
enrilsp prune --yes --target enrilsp
```

</details>

<details>
<summary>PowerShell installer scripts are blocked (ExecutionPolicy)</summary>

If you run an installer script manually and Windows blocks it, run with policy bypass:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File installers\\check-vtsls.ps1
```

If you use `enrilsp menu`, it already runs installers with `-ExecutionPolicy Bypass`.

</details>
