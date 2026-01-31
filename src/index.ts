#!/usr/bin/env node

import { resolve } from "node:path";

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { loadConfigOrThrow } from "./config.js";
import { applyWorkspaceEditToDisk } from "./file-edits.js";
import { LspClient } from "./lsp/client.js";

// Subcommands
const args = process.argv.slice(2);
if (args[0] === "setup") {
  const { main } = await import("./setup.js");
  await main();
  process.exit(0);
}

const config = loadConfigOrThrow();
const lspClient = new LspClient(config);

const server = new Server(
  { name: "enrilsp", version: "0.1.0" },
  {
    capabilities: { tools: {} },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "find_definition",
        description:
          "Find the definition location(s) for a symbol (by name) in a file using the configured LSP server.",
        inputSchema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to the file" },
            symbol_name: { type: "string", description: "Symbol name" },
            symbol_kind: {
              type: "string",
              description: "Optional kind hint (class, method, function, etc.)",
            },
          },
          required: ["file_path", "symbol_name"],
        },
      },
      {
        name: "find_references",
        description:
          "Find all references to a symbol (by name) across the workspace using the configured LSP server.",
        inputSchema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to the file" },
            symbol_name: { type: "string", description: "Symbol name" },
            symbol_kind: {
              type: "string",
              description: "Optional kind hint (class, method, function, etc.)",
            },
            include_declaration: {
              type: "boolean",
              description: "Whether to include the declaration in results",
              default: true,
            },
          },
          required: ["file_path", "symbol_name"],
        },
      },
      {
        name: "rename_symbol",
        description:
          "Rename a symbol (by name) and optionally apply the WorkspaceEdit to disk. Use dry_run to preview.",
        inputSchema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to the file" },
            symbol_name: { type: "string", description: "Symbol name" },
            symbol_kind: {
              type: "string",
              description: "Optional kind hint (class, method, function, etc.)",
            },
            new_name: { type: "string", description: "New name" },
            dry_run: {
              type: "boolean",
              description: "If true, returns edits without applying them",
              default: false,
            },
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
        description:
          "Restart LSP server processes (all, or filtered by extensions).",
        inputSchema: {
          type: "object",
          properties: {
            extensions: {
              type: "array",
              items: { type: "string" },
              description:
                'Extensions (without dot) to restart, e.g. ["cs","ts"]. If omitted, restarts all.',
            },
          },
          required: [],
        },
      },
      {
        name: "enrilsp_ping",
        description: "Health check for EnriLSP MCP server",
        inputSchema: { type: "object", properties: {}, required: [] },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: toolArgs } = request.params;

  if (name === "enrilsp_ping") {
    return { content: [{ type: "text", text: "pong" }] };
  }

  if (name === "find_definition") {
    const { file_path, symbol_name, symbol_kind } = toolArgs as {
      file_path: string;
      symbol_name: string;
      symbol_kind?: string;
    };

    const absolutePath = resolve(file_path);
    const { matches, warning } = await lspClient.findSymbolsByName(
      absolutePath,
      symbol_name,
      symbol_kind
    );

    if (matches.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `No symbols found with name "${symbol_name}" in ${file_path}.`,
          },
        ],
      };
    }

    const blocks: string[] = [];
    for (const match of matches) {
      const locations = await lspClient.findDefinition(absolutePath, match.position);
      const formatted = lspClient.formatLocations(locations).join("\n");
      blocks.push(
        `Results for ${match.name} (${lspClient.symbolKindToString(match.kind)}) at ${file_path}:${match.position.line + 1}:${match.position.character + 1}:\n${formatted || "(no definition found)"}`
      );
    }

    const response = warning ? `${warning}\n\n${blocks.join("\n\n")}` : blocks.join("\n\n");
    return { content: [{ type: "text", text: response }] };
  }

  if (name === "find_references") {
    const {
      file_path,
      symbol_name,
      symbol_kind,
      include_declaration = true,
    } = toolArgs as {
      file_path: string;
      symbol_name: string;
      symbol_kind?: string;
      include_declaration?: boolean;
    };

    const absolutePath = resolve(file_path);
    const { matches, warning } = await lspClient.findSymbolsByName(
      absolutePath,
      symbol_name,
      symbol_kind
    );

    if (matches.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `No symbols found with name "${symbol_name}" in ${file_path}.`,
          },
        ],
      };
    }

    const blocks: string[] = [];
    for (const match of matches) {
      const locations = await lspClient.findReferences(
        absolutePath,
        match.position,
        include_declaration
      );
      const formatted = lspClient.formatLocations(locations).join("\n");
      blocks.push(
        `References for ${match.name} (${lspClient.symbolKindToString(match.kind)}) at ${file_path}:${match.position.line + 1}:${match.position.character + 1}:\n${formatted || "(no references found)"}`
      );
    }

    const response = warning ? `${warning}\n\n${blocks.join("\n\n")}` : blocks.join("\n\n");
    return { content: [{ type: "text", text: response }] };
  }

  if (name === "rename_symbol") {
    const { file_path, symbol_name, symbol_kind, new_name, dry_run = false } =
      toolArgs as {
        file_path: string;
        symbol_name: string;
        symbol_kind?: string;
        new_name: string;
        dry_run?: boolean;
      };

    const absolutePath = resolve(file_path);
    const { matches, warning } = await lspClient.findSymbolsByName(
      absolutePath,
      symbol_name,
      symbol_kind
    );

    if (matches.length === 0) {
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `No symbols found with name "${symbol_name}" in ${file_path}.`,
          },
        ],
      };
    }

    if (matches.length > 1) {
      const candidates = matches
        .map(
          (m) =>
            `${file_path}:${m.position.line + 1}:${m.position.character + 1} (${lspClient.symbolKindToString(m.kind)})`
        )
        .join("\n");
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `Multiple symbols match "${symbol_name}". Please narrow with symbol_kind.\n\nCandidates:\n${candidates}`,
          },
        ],
      };
    }

    const match = matches[0]!;
    const edit = await lspClient.renameSymbol(absolutePath, match.position, new_name);

    if (dry_run) {
      const fileCount = edit.changes ? Object.keys(edit.changes).length : 0;
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `Rename preview for ${symbol_name} → ${new_name}\nFiles touched: ${fileCount}`,
          },
        ],
      };
    }

    const applyResult = await applyWorkspaceEditToDisk(edit, { createBackups: true });
    if (!applyResult.success) {
      return {
        content: [
          {
            type: "text",
            text:
              (warning ? `${warning}\n\n` : "") +
              `Failed to apply rename edits: ${applyResult.error ?? "unknown error"}`,
          },
        ],
      };
    }

    for (const file of applyResult.filesModified) {
      await lspClient.syncFileContent(file);
    }

    return {
      content: [
        {
          type: "text",
          text:
            (warning ? `${warning}\n\n` : "") +
            `Renamed ${symbol_name} → ${new_name}\nModified files:\n${applyResult.filesModified.join("\n")}\nBackups:\n${applyResult.backupFiles.join("\n")}`,
        },
      ],
    };
  }

  if (name === "get_diagnostics") {
    const { file_path } = toolArgs as { file_path: string };
    const absolutePath = resolve(file_path);
    const diagnostics = await lspClient.getDiagnostics(absolutePath);

    if (diagnostics.length === 0) {
      return { content: [{ type: "text", text: "No diagnostics." }] };
    }

    const formatted = diagnostics
      .map((d) => {
        const start = d.range.start;
        return `${file_path}:${start.line + 1}:${start.character + 1} ${d.message}`;
      })
      .join("\n");

    return { content: [{ type: "text", text: formatted }] };
  }

  if (name === "restart_servers") {
    const { extensions } = toolArgs as { extensions?: string[] };
    const result = await lspClient.restartServers(extensions);
    return { content: [{ type: "text", text: result.message }] };
  }

  throw new Error(`Unknown tool: ${name}`);
});

await server.connect(new StdioServerTransport());
