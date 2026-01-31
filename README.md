# EnriLSP

EnriLSP es un **servidor MCP** que hace de puente con **Language Server Protocol (LSP)**.
La idea es simple: cualquier cliente que soporte **MCP tools** puede obtener capacidades tipo IDE (definición, referencias, rename, diagnósticos) **aunque ese cliente no soporte LSP**.

## Qué incluye

- Servidor MCP por `stdio` (para que lo puedas usar desde Claude Desktop, Cursor/Continue, tu propio host MCP, etc.).
- Un cliente LSP interno que corre servidores LSP por `--stdio`.
- Workaround incluido para servidores que piden `window/workDoneProgress/create` (caso típico: `csharp-ls`).
- Scripts PowerShell para **auto-instalar** runtimes/servidores en Windows (carpeta `installers/`).

## Requisitos

- Node.js `>= 18`
- Que el/los LSP server(s) que quieras usar estén instalados en tu sistema (o usa los scripts de `installers/`).

## Build

```powershell
npm install
npm run build
```

## Configuración

EnriLSP lee config desde (en este orden):

1) `ENRILSP_CONFIG_PATH` (si está seteada), o  
2) `.enrilsp.json` / `enrilsp.json` en el proyecto, o  
3) Windows: `%LOCALAPPDATA%\EnriLSP\enrilsp.json`

Para generar una config rápida (desde el proyecto que quieras analizar):

```powershell
# Crea .enrilsp.json (por defecto, C# usando csharp-ls)
node C:\path\to\EnriLSP\dist\index.js setup

# Windows: además intenta instalar dependencias para C# (csharp-ls + .NET SDK)
node C:\path\to\EnriLSP\dist\index.js setup --install
```

Ejemplo de config: `enrilsp.config.example.json`.

## Ejecutar como MCP server

Configura tu cliente MCP para ejecutar:

- Command: `node`
- Args: `C:\path\to\EnriLSP\dist\index.js`

## MCP Tools disponibles

- `find_definition`
- `find_references`
- `rename_symbol` (con `dry_run` o aplicando cambios en disco con backups `.bak`)
- `get_diagnostics`
- `restart_servers`

## Instaladores (Windows)

La carpeta `installers/` contiene scripts `check-*.ps1` reutilizables para instalar runtimes/servers.

Ejemplo (C# / `csharp-ls`):

```powershell
pwsh -ExecutionPolicy Bypass -File installers\check-omnisharp.ps1
```

## Nota importante sobre “soporta todos los LSP”

La arquitectura MCP↔LSP permite que **cualquier cliente MCP** use LSP *a través* de EnriLSP, pero:

- Cada LSP server tiene sus particularidades. Si uno requiere requests extra del lado “cliente LSP”, EnriLSP puede necesitar soporte adicional.
- Hoy los tools están centrados en “símbolo por nombre en un archivo” (declaración → posición → LSP). Si quieres “go-to-definition desde un uso en line/col”, conviene agregar tools tipo `definition_at_position`.

## Licencia

MIT (ver `LICENSE.md`).

