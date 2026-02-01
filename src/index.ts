#!/usr/bin/env node

import { resolve } from "node:path";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";

import { configService } from "./config.js";
import { workspaceEditApplier } from "./file-edits.js";
import { LspClient } from "./lsp/client.js";
import { packageInfoService } from "./package-info.js";

type McpToolContent = { type: "text"; text: string };
type McpToolResponse = { content: McpToolContent[] };

type FindDefinitionArgs = { file_path: string; symbol_name: string; symbol_kind?: string };
type FindReferencesArgs = {
  file_path: string;
  symbol_name: string;
  symbol_kind?: string;
  include_declaration?: boolean;
};
type RenameSymbolArgs = { file_path: string; symbol_name: string; symbol_kind?: string; new_name: string; dry_run?: boolean };
type GetDiagnosticsArgs = { file_path: string };
type RestartServersArgs = { extensions?: string[] };

class EnriLspMcpServer {
  private readonly server: Server;

  public constructor(
    private readonly lspClient: LspClient,
    private readonly serverInfo: { name: string; version: string } = { name: "EnriLSP", version: packageInfoService.getVersion() }
  ) {
    this.server = new Server(this.serverInfo, { capabilities: { tools: {} } });
  }

  private listTools(): { tools: Array<Record<string, unknown>> } {
    return {
      tools: [
        {
          name: "find_definition",
          description: "Find the definition location(s) for a symbol (by name) in a file using the configured LSP server.",
          inputSchema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to the file" },
              symbol_name: { type: "string", description: "Symbol name" },
              symbol_kind: { type: "string", description: "Optional kind hint (class, method, function, etc.)" },
            },
            required: ["file_path", "symbol_name"],
          },
        },
        {
          name: "find_references",
          description: "Find all references to a symbol (by name) across the workspace using the configured LSP server.",
          inputSchema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to the file" },
              symbol_name: { type: "string", description: "Symbol name" },
              symbol_kind: { type: "string", description: "Optional kind hint (class, method, function, etc.)" },
              include_declaration: { type: "boolean", description: "Whether to include the declaration in results", default: true },
            },
            required: ["file_path", "symbol_name"],
          },
        },
        {
          name: "rename_symbol",
          description: "Rename a symbol (by name) and optionally apply the WorkspaceEdit to disk. Use dry_run to preview.",
          inputSchema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to the file" },
              symbol_name: { type: "string", description: "Symbol name" },
              symbol_kind: { type: "string", description: "Optional kind hint (class, method, function, etc.)" },
              new_name: { type: "string", description: "New name" },
              dry_run: { type: "boolean", description: "If true, returns edits without applying them", default: false },
            },
            required: ["file_path", "symbol_name", "new_name"],
          },
        },
        {
          name: "get_diagnostics",
          description: "Get the latest published diagnostics for a file.",
          inputSchema: {
            type: "object",
            properties: {
              file_path: { type: "string", description: "Path to the file" },
            },
            required: ["file_path"],
          },
        },
        {
          name: "restart_servers",
          description: "Restart LSP server processes (all, or filtered by extensions).",
          inputSchema: {
            type: "object",
            properties: {
              extensions: {
                type: "array",
                items: { type: "string" },
                description: 'Extensions (without dot) to restart, e.g. ["cs","ts"]. If omitted, restarts all.',
              },
            },
            required: [],
          },
        },
      ],
    };
  }

  private text(text: string): McpToolResponse {
    return { content: [{ type: "text", text }] };
  }

  private async handleFindDefinition(toolArgs: unknown): Promise<McpToolResponse> {
    const { file_path, symbol_name, symbol_kind } = toolArgs as FindDefinitionArgs;

    const absolutePath = resolve(file_path);
    const { matches, warning } = await this.lspClient.findSymbolsByName(absolutePath, symbol_name, symbol_kind);

    if (matches.length === 0) {
      return this.text((warning ? `${warning}\n\n` : "") + `No symbols found with name "${symbol_name}" in ${file_path}.`);
    }

    const blocks: string[] = [];
    for (const match of matches) {
      const locations = await this.lspClient.findDefinition(absolutePath, match.position);
      const formatted = this.lspClient.formatLocations(locations).join("\n");
      blocks.push(
        `Results for ${match.name} (${this.lspClient.symbolKindToString(match.kind)}) at ${file_path}:${match.position.line + 1}:${match.position.character + 1}:\n${
          formatted || "(no definition found)"
        }`
      );
    }

    const response = warning ? `${warning}\n\n${blocks.join("\n\n")}` : blocks.join("\n\n");
    return this.text(response);
  }

  private async handleFindReferences(toolArgs: unknown): Promise<McpToolResponse> {
    const { file_path, symbol_name, symbol_kind, include_declaration = true } = toolArgs as FindReferencesArgs;

    const absolutePath = resolve(file_path);
    const { matches, warning } = await this.lspClient.findSymbolsByName(absolutePath, symbol_name, symbol_kind);

    if (matches.length === 0) {
      return this.text((warning ? `${warning}\n\n` : "") + `No symbols found with name "${symbol_name}" in ${file_path}.`);
    }

    const blocks: string[] = [];
    for (const match of matches) {
      const locations = await this.lspClient.findReferences(absolutePath, match.position, include_declaration);
      const formatted = this.lspClient.formatLocations(locations).join("\n");
      blocks.push(
        `References for ${match.name} (${this.lspClient.symbolKindToString(match.kind)}) at ${file_path}:${match.position.line + 1}:${match.position.character + 1}:\n${
          formatted || "(no references found)"
        }`
      );
    }

    const response = warning ? `${warning}\n\n${blocks.join("\n\n")}` : blocks.join("\n\n");
    return this.text(response);
  }

  private async handleRenameSymbol(toolArgs: unknown): Promise<McpToolResponse> {
    const { file_path, symbol_name, symbol_kind, new_name, dry_run = false } = toolArgs as RenameSymbolArgs;

    const absolutePath = resolve(file_path);
    const { matches, warning } = await this.lspClient.findSymbolsByName(absolutePath, symbol_name, symbol_kind);

    if (matches.length === 0) {
      return this.text((warning ? `${warning}\n\n` : "") + `No symbols found with name "${symbol_name}" in ${file_path}.`);
    }

    if (matches.length > 1) {
      const candidates = matches
        .map(
          (m) =>
            `${file_path}:${m.position.line + 1}:${m.position.character + 1} (${this.lspClient.symbolKindToString(m.kind)})`
        )
        .join("\n");
      return this.text(
        (warning ? `${warning}\n\n` : "") +
          `Multiple symbols match "${symbol_name}". Please narrow with symbol_kind.\n\nCandidates:\n${candidates}`
      );
    }

      const match = matches[0]!;
      const edit = await this.lspClient.renameSymbol(absolutePath, match.position, new_name);

    if (dry_run) {
      const fileCount = edit.changes ? Object.keys(edit.changes).length : 0;
      return this.text(
        (warning ? `${warning}\n\n` : "") + `Rename preview for ${symbol_name} -> ${new_name}\nFiles touched: ${fileCount}`
      );
    }

    const applyResult = await workspaceEditApplier.applyWorkspaceEditToDisk(edit, { createBackups: true });
    if (!applyResult.success) {
      return this.text(
        (warning ? `${warning}\n\n` : "") + `Failed to apply rename edits: ${applyResult.error ?? "unknown error"}`
      );
    }

    for (const file of applyResult.filesModified) {
      await this.lspClient.syncFileContent(file);
    }

    return this.text(
      (warning ? `${warning}\n\n` : "") +
        `Renamed ${symbol_name} -> ${new_name}\nModified files:\n${applyResult.filesModified.join("\n")}\nBackups:\n${applyResult.backupFiles.join("\n")}`
    );
  }

  private async handleGetDiagnostics(toolArgs: unknown): Promise<McpToolResponse> {
    const { file_path } = toolArgs as GetDiagnosticsArgs;
    const absolutePath = resolve(file_path);
    const diagnostics = await this.lspClient.getDiagnostics(absolutePath);

    if (diagnostics.length === 0) {
      return this.text("No diagnostics.");
    }

    const formatted = diagnostics
      .map((d) => {
        const start = d.range.start;
        return `${file_path}:${start.line + 1}:${start.character + 1} ${d.message}`;
      })
      .join("\n");

    return this.text(formatted);
  }

  private async handleRestartServers(toolArgs: unknown): Promise<McpToolResponse> {
    const { extensions } = toolArgs as RestartServersArgs;
    const result = await this.lspClient.restartServers(extensions);
    return this.text(result.message);
  }

  public async start(): Promise<void> {
    this.server.setRequestHandler(ListToolsRequestSchema, async () => this.listTools());

    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: toolArgs } = request.params;

      if (name === "find_definition") return this.handleFindDefinition(toolArgs);
      if (name === "find_references") return this.handleFindReferences(toolArgs);
      if (name === "rename_symbol") return this.handleRenameSymbol(toolArgs);
      if (name === "get_diagnostics") return this.handleGetDiagnostics(toolArgs);
      if (name === "restart_servers") return this.handleRestartServers(toolArgs);

      throw new Error(`Unknown tool: ${name}`);
    });

    await this.server.connect(new StdioServerTransport());
  }
}

class EnriLspProgram {
  private printHelp(): void {
    console.log("EnriLSP");
    console.log("");
    console.log("This is an MCP server over stdio (bridging to one or more LSP servers).");
    console.log("");
    console.log("Usage:");
    console.log("  enrilsp              (start MCP server over stdio)");
    console.log("  enrilsp setup        (create a .enrilsp.json config in the current directory)");
    console.log("  enrilsp menu         (interactive installer/config menu)");
    console.log("  enrilsp prune        (remove LocalAppData folders created by installers)");
    console.log("  enrilsp --version");
    console.log("  enrilsp --help");
    console.log("");
    console.log("Config resolution order:");
    console.log("  1) ENRILSP_CONFIG_PATH");
    console.log("  2) .enrilsp.json / enrilsp.json in the current directory");
    console.log(`  3) ${configService.getDefaultConfigPath()}`);
  }

  private printVersion(): void {
    console.log(packageInfoService.getVersion());
  }

  public async run(argv: string[]): Promise<void> {
    const args = argv.slice(2);

    if (args[0] === "--version" || args[0] === "-v" || args[0] === "version") {
      this.printVersion();
      process.exit(0);
    }

    if (args[0] === "--help" || args[0] === "-h" || args[0] === "help") {
      this.printHelp();
      process.exit(0);
    }

    if (args[0] === "setup") {
      const { SetupCommand } = await import("./setup.js");
      await new SetupCommand().run(argv.slice(3));
      process.exit(0);
    }
    if (args[0] === "menu") {
      const { MenuCommand } = await import("./menu.js");
      await new MenuCommand().run(argv.slice(3));
      process.exit(0);
    }
    if (args[0] === "prune") {
      const { PruneCommand } = await import("./prune.js");
      await new PruneCommand().run(argv.slice(3));
      process.exit(0);
    }

    const config = configService.loadConfigOrThrow();
    const lspClient = new LspClient(config);
    const mcpServer = new EnriLspMcpServer(lspClient);
    await mcpServer.start();
  }
}

await new EnriLspProgram().run(process.argv);
