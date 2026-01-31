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

Configura tu cliente MCP para ejecutar EnriLSP como servidor `stdio`.

### Ejemplo: Claude Code / Claude Desktop (stdio)

Formato típico (similar al que ya usas con `EnriWeb`):

```jsonc
{
  "EnriLSP": {
    "type": "stdio",
    "command": "node",
    "args": ["C:\\\\Users\\\\Administrator\\\\Projects\\\\EnriLSP\\\\dist\\\\index.js"],
    "env": {
      // Recomendado: ruta ABSOLUTA al config que quieres usar
      "ENRILSP_CONFIG_PATH": "C:\\\\path\\\\to\\\\your\\\\project\\\\.enrilsp.json"
    }
  }
}
```

Notas:
- `ENRILSP_CONFIG_PATH` es la forma más robusta. Si no lo seteas, EnriLSP intenta encontrar `.enrilsp.json` relativo al `cwd` del proceso (que depende del cliente MCP).
- Dentro de `.enrilsp.json` define `rootDir` para cada server para que el LSP arranque “parado” en el proyecto correcto aunque el `cwd` del MCP sea otro.

### Ejemplo: COpenCode (local)

Si tu host MCP usa `type: "local"` y `command` como array (como tu ejemplo de Playwright):

```jsonc
{
  "EnriLSP": {
    "type": "local",
    "command": ["node", "C:\\\\Users\\\\Administrator\\\\Projects\\\\EnriLSP\\\\dist\\\\index.js"],
    "enabled": true,
    "env": {
      "ENRILSP_CONFIG_PATH": "C:\\\\path\\\\to\\\\your\\\\project\\\\.enrilsp.json"
    }
  }
}
```

### Ejemplo: archivo `.enrilsp.json`

```jsonc
{
  "servers": [
    {
      "name": "csharp-ls",
      "extensions": ["cs", "csx"],
      "command": ["C:\\\\Users\\\\Administrator\\\\.dotnet\\\\tools\\\\csharp-ls.exe", "--stdio"],
      "rootDir": "C:\\\\path\\\\to\\\\your\\\\project",
      "warmupMs": 500
    }
  ]
}
```

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
